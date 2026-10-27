// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The state machine of one root, alone: asleep/waking/watching/off, and the rules that decide when to move.
//!
//! It is separated from `root.zig` on purpose. This is the part with the subtle behaviour — idle timeouts
//! racing subscribers, a mode change while a wake scan is running, `off` refusing a wake — and keeping it
//! free of sockets, threads and the file system makes every rule a unit test with an injected clock. The
//! socket, the pass and the watcher are plumbing around this file.
//!
//! ```text
//!             add root                       subscriber arrives / control wake
//!    (none) ─────────► off ──mode change──► asleep ◄──────────────┐
//!                        │                    │  wake              │ idle deadline
//!                        │ mode = always      │  (scan + diff)     │ (auto, no clients)
//!                        │ or auto + client   ▼                    │
//!                        └────────────────► waking ──► watching ───┘
//! ```
//!
//! Two invariants are worth stating because they are what the tests pin:
//!
//! 1. **Only a subscriber, a control request or a mode change starts a wake.** Nothing wakes on its own, so a
//!    sleeping root costs nothing until somebody asks for it.
//! 2. **`off` never watches.** `off` means never *watch*, not never *serve*: the socket stays bound and
//!    answers from a scan, and a control `wake` is refused rather than silently ignored.

const std = @import("std");
const wire = @import("../wire.zig");

pub const Mode = enum {
    off,
    always,
    auto,

    pub fn parse(text: []const u8) ?Mode {
        if (std.mem.eql(u8, text, "off")) return .off;
        if (std.mem.eql(u8, text, "always")) return .always;
        if (std.mem.eql(u8, text, "auto")) return .auto;
        return null;
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .always => "always",
            .auto => "auto",
        };
    }
};

/// What the root is doing right now. `waking` is a transient state with a scan running.
pub const Phase = enum {
    off,
    asleep,
    waking,
    watching,

    pub fn name(self: Phase) []const u8 {
        return switch (self) {
            .off => "off",
            .asleep => "asleep",
            .waking => "waking",
            .watching => "watching",
        };
    }

    pub fn code(self: Phase) u8 {
        return switch (self) {
            .off => 0,
            .asleep => 1,
            .waking => 2,
            .watching => 3,
        };
    }
};

/// Why the root is in the state it is in. Wire-level: `STATE.reason` (FORMAT.socket.md).
pub const Reason = enum(u8) {
    none = 0,
    client = 1,
    idle = 2,
    control = 3,
    watcher = 4,

    pub fn name(self: Reason) []const u8 {
        return switch (self) {
            .none => "none",
            .client => "client",
            .idle => "idle",
            .control => "control",
            .watcher => "watcher",
        };
    }
};

/// What the root's owner must do in response to a transition. The machine decides; `root.zig` performs.
pub const Action = union(enum) {
    /// Nothing changed.
    none,
    /// Run the wake scan now: one pass, then publish the difference.
    wake,
    /// Drop the watcher and the open tree handles now.
    sleep,
};

/// Five minutes: long enough that a working session never wakes, short enough that an abandoned root stops
/// costing a watcher. `0` means "never sleep".
pub const default_idle_timeout_ms: u64 = 300_000;

/// The refusal a control `wake` gets on a root whose mode is `off` (CLI exit code 4).
pub const WakeRefused = error{RefusedByPolicy};

pub const Machine = struct {
    mode: Mode = .auto,
    phase: Phase = .asleep,
    idle_timeout_ms: u64 = default_idle_timeout_ms,
    /// Subscribed consumers. They are the reason to watch, not the reason to exist.
    clients: u32 = 0,
    /// When the root last had a reason to watch: a subscriber arrived, a pass published, a mode changed.
    last_activity_ms: i64 = 0,
    /// The newest batch the server considers published. Advertised in `HELLO` and in `STATE`.
    head_batch: u64 = 0,
    /// The reason for the current phase, carried in `STATE`.
    reason: Reason = .none,
    /// How many wake scans this root has run. Diagnostic only (`root status --json`).
    wakes: u64 = 0,
    /// How many passes it has published. Diagnostic only.
    passes: u64 = 0,

    /// A root is created `off` or `asleep`, never `watching`: nothing is watched until somebody asks.
    pub fn init(mode: Mode, idle_timeout_ms: u64) Machine {
        return .{
            .mode = mode,
            .phase = switch (mode) {
                .off => .off,
                .always, .auto => .asleep,
            },
            .idle_timeout_ms = idle_timeout_ms,
        };
    }

    pub fn stateCode(self: *const Machine) u8 {
        return self.phase.code();
    }

    /// A client subscribed. Only `auto`+`asleep` starts a wake; `always` is already awake, `off` never wakes,
    /// and a second subscriber during `waking` is served by the scan already running.
    pub fn subscribe(self: *Machine, now_ms: i64) Action {
        self.clients += 1;
        self.last_activity_ms = now_ms;
        return switch (self.phase) {
            .asleep => blk: {
                self.phase = .waking;
                self.reason = .client;
                self.wakes += 1;
                break :blk .wake;
            },
            .waking, .watching, .off => .none,
        };
    }

    /// A client left. Its departure is activity: the idle deadline starts now, not when the last pass ran.
    pub fn unsubscribe(self: *Machine, now_ms: i64) void {
        if (self.clients > 0) self.clients -= 1;
        self.last_activity_ms = now_ms;
    }

    /// Change the mode. `off` stops watching at once; `always` starts watching at once (it watches regardless
    /// of clients); `auto` from `off` goes to `asleep` and waits for a subscriber.
    pub fn setMode(self: *Machine, mode: Mode, now_ms: i64) Action {
        const previous = self.mode;
        self.mode = mode;
        self.last_activity_ms = now_ms;
        if (previous == mode) return .none;
        return switch (mode) {
            .off => blk: {
                const was_watching = self.phase == .watching or self.phase == .waking;
                self.phase = .off;
                self.reason = .control;
                break :blk if (was_watching) .sleep else .none;
            },
            .always => switch (self.phase) {
                .off, .asleep => blk: {
                    self.phase = .waking;
                    self.reason = .control;
                    self.wakes += 1;
                    break :blk .wake;
                },
                .waking, .watching => .none,
            },
            .auto => switch (self.phase) {
                .off => blk: {
                    self.phase = .asleep;
                    self.reason = .control;
                    break :blk .none;
                },
                // Already watching: the idle rule takes over from now, so a mode change is not a reason to
                // sleep on the spot.
                .waking, .watching, .asleep => .none,
            },
        };
    }

    pub fn setIdleTimeout(self: *Machine, idle_timeout_ms: u64, now_ms: i64) void {
        self.idle_timeout_ms = idle_timeout_ms;
        self.last_activity_ms = now_ms;
    }

    /// A control wake. Refused on `off`: the answer must say why rather than pretending the root watches.
    pub fn wake(self: *Machine, now_ms: i64) WakeRefused!Action {
        if (self.mode == .off) return error.RefusedByPolicy;
        self.last_activity_ms = now_ms;
        return switch (self.phase) {
            .asleep => blk: {
                self.phase = .waking;
                self.reason = .control;
                self.wakes += 1;
                break :blk .wake;
            },
            .waking, .watching => .none,
            .off => blk: {
                // Unreachable while `mode` and `phase` agree; a mode change is the only writer of both, and it
                // sets them together. Kept total rather than asserted so a future caller cannot corrupt it.
                self.phase = .waking;
                self.reason = .control;
                self.wakes += 1;
                break :blk .wake;
            },
        };
    }

    /// A control sleep: forced even in `always` mode. Batches and the socket stay; only the watcher goes.
    pub fn sleep(self: *Machine, now_ms: i64) Action {
        self.last_activity_ms = now_ms;
        return switch (self.phase) {
            .watching, .waking => blk: {
                self.phase = if (self.mode == .off) .off else .asleep;
                self.reason = .control;
                break :blk .sleep;
            },
            .asleep, .off => .none,
        };
    }

    /// The idle rule, evaluated whenever the owner wakes up. Only `auto` sleeps, and only with no clients:
    /// `always` ignores subscribers, `watching` with a client is exactly what a subscriber asked for.
    pub fn tick(self: *Machine, now_ms: i64) Action {
        if (self.phase != .watching) return .none;
        if (self.mode != .auto) return .none;
        if (self.clients != 0) return .none;
        if (self.idle_timeout_ms == 0) return .none;
        const idle_for = now_ms - self.last_activity_ms;
        if (idle_for < @as(i64, @intCast(self.idle_timeout_ms))) return .none;
        self.phase = .asleep;
        self.reason = .idle;
        return .sleep;
    }

    /// A wake scan finished: the root is watching, and the wake was a reason to stay awake for a while.
    pub fn woke(self: *Machine, now_ms: i64) void {
        self.phase = .watching;
        self.last_activity_ms = now_ms;
    }

    /// A pass published a batch: activity, and the head moves.
    pub fn published(self: *Machine, generation: u64, now_ms: i64) void {
        self.head_batch = generation;
        self.passes += 1;
        self.last_activity_ms = now_ms;
        if (self.phase == .waking) self.phase = .watching;
    }

    /// Say *why* the root is in its current phase: `STATE.reason` is what a client reads to tell "a watcher
    /// event published this" from "my own subscribe did", and both can produce a batch while `watching`.
    pub fn attribute(self: *Machine, reason: Reason) void {
        self.reason = reason;
    }

    /// Whether a pass should be running at all (`watching`), as opposed to serving from a stale generation.
    pub fn wantsWatch(self: *const Machine) bool {
        return self.phase == .watching;
    }

    /// Whether the root would move to `asleep` if nothing else happened before `now_ms + 1`.
    pub fn idleDeadlineMs(self: *const Machine) ?i64 {
        if (self.phase != .watching) return null;
        if (self.mode != .auto) return null;
        if (self.clients != 0) return null;
        if (self.idle_timeout_ms == 0) return null;
        return self.last_activity_ms + @as(i64, @intCast(self.idle_timeout_ms));
    }

    /// The `STATE` frame's payload for this machine (FORMAT.socket.md § STATE).
    pub fn frame(self: *const Machine) wire.State {
        return .{
            .state = self.phase.code(),
            .reason = @intFromEnum(self.reason),
            .idle_timeout_ms = @intCast(@min(self.idle_timeout_ms, std.math.maxInt(u32))),
            .head_batch = self.head_batch,
        };
    }
};

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "a new auto root sleeps, an always root sleeps until asked, and an off root is off" {
    try testing.expectEqual(Phase.asleep, Machine.init(.auto, default_idle_timeout_ms).phase);
    try testing.expectEqual(Phase.asleep, Machine.init(.always, default_idle_timeout_ms).phase);
    try testing.expectEqual(Phase.off, Machine.init(.off, default_idle_timeout_ms).phase);
}

test "a subscriber wakes a sleeping auto root, and only once" {
    var machine = Machine.init(.auto, default_idle_timeout_ms);
    try testing.expectEqual(Action.wake, machine.subscribe(1_000));
    try testing.expectEqual(Phase.waking, machine.phase);
    try testing.expectEqual(Reason.client, machine.reason);
    try testing.expectEqual(@as(u64, 1), machine.wakes);

    // A second subscriber during the wake is served by the same scan: no second pass.
    try testing.expectEqual(Action.none, machine.subscribe(1_010));
    try testing.expectEqual(@as(u64, 1), machine.wakes);
    try testing.expectEqual(@as(u32, 2), machine.clients);

    machine.woke(1_200);
    try testing.expectEqual(Phase.watching, machine.phase);
    // Already watching: a third subscriber changes nothing.
    try testing.expectEqual(Action.none, machine.subscribe(1_300));
}

test "the idle rule sleeps an auto root with no clients, and never one with clients" {
    var machine = Machine.init(.auto, 100);
    _ = machine.subscribe(0);
    machine.woke(10);

    // A client is subscribed: the idle deadline does not exist, whatever the clock says.
    try testing.expectEqual(@as(?i64, null), machine.idleDeadlineMs());
    try testing.expectEqual(Action.none, machine.tick(10_000));

    machine.unsubscribe(10_000);
    try testing.expectEqual(@as(?i64, 10_100), machine.idleDeadlineMs());
    try testing.expectEqual(Action.none, machine.tick(10_099));
    try testing.expectEqual(Action.sleep, machine.tick(10_100));
    try testing.expectEqual(Phase.asleep, machine.phase);
    try testing.expectEqual(Reason.idle, machine.reason);

    // Sleeping is not a scan: the next subscriber wakes it again.
    try testing.expectEqual(Action.wake, machine.subscribe(11_000));
    try testing.expectEqual(@as(u64, 2), machine.wakes);
}

test "the idle rule never applies to always mode and never to a zero timeout" {
    var always = Machine.init(.always, 10);
    _ = always.subscribe(0);
    always.woke(1);
    always.unsubscribe(2);
    try testing.expectEqual(Action.none, always.tick(1_000_000));
    try testing.expectEqual(Phase.watching, always.phase);

    var never = Machine.init(.auto, 0);
    _ = never.subscribe(0);
    never.woke(1);
    never.unsubscribe(2);
    try testing.expectEqual(Action.none, never.tick(1_000_000));
    try testing.expectEqual(Phase.watching, never.phase);
}

test "off never watches: a subscriber is served from a scan but nothing wakes" {
    var machine = Machine.init(.off, default_idle_timeout_ms);
    try testing.expectEqual(Action.none, machine.subscribe(0));
    try testing.expectEqual(Phase.off, machine.phase);
    try testing.expectEqual(Action.none, machine.tick(1_000_000));
    // And a wake is a refusal, not a silent no-op: the CLI turns this into exit code 4.
    try testing.expectError(error.RefusedByPolicy, machine.wake(50));
    try testing.expectEqual(Phase.off, machine.phase);
}

test "mode changes do what their names say" {
    // auto -> always starts a wake immediately, with no client at all.
    var always = Machine.init(.auto, 100);
    try testing.expectEqual(Action.wake, always.setMode(.always, 10));
    try testing.expectEqual(Phase.waking, always.phase);
    always.woke(20);
    try testing.expectEqual(Action.none, always.setMode(.always, 30));

    // always -> auto keeps watching, but now the idle rule applies, counted from the mode change.
    try testing.expectEqual(Action.none, always.setMode(.auto, 40));
    try testing.expectEqual(Action.none, always.tick(139));
    try testing.expectEqual(Action.sleep, always.tick(140));

    // -> off stops watching at once.
    var off = Machine.init(.auto, 100);
    _ = off.subscribe(0);
    off.woke(10);
    try testing.expectEqual(Action.sleep, off.setMode(.off, 20));
    try testing.expectEqual(Phase.off, off.phase);
    try testing.expectError(error.RefusedByPolicy, off.wake(30));

    // off -> auto goes to asleep and waits, rather than scanning on its own.
    try testing.expectEqual(Action.none, off.setMode(.auto, 40));
    try testing.expectEqual(Phase.asleep, off.phase);
    try testing.expectEqual(Action.wake, off.subscribe(50));
}

test "a control sleep forces even always mode, and a control wake resumes it" {
    var machine = Machine.init(.always, 100);
    _ = machine.subscribe(0);
    machine.woke(10);
    try testing.expectEqual(Action.sleep, machine.sleep(20));
    try testing.expectEqual(Phase.asleep, machine.phase);
    // Nothing wakes it on its own: an always root that was forced asleep stays asleep until asked.
    try testing.expectEqual(Action.none, machine.tick(1_000_000));
    try testing.expectEqual(Action.wake, try machine.wake(1_000_001));
    try testing.expectEqual(Phase.waking, machine.phase);
    try testing.expectEqual(Reason.control, machine.reason);
}

test "a wake that publishes reaches watching, and the head batch moves with it" {
    var machine = Machine.init(.auto, 100);
    _ = machine.subscribe(0);
    try testing.expectEqual(@as(u64, 0), machine.frame().head_batch);
    machine.published(7, 30);
    try testing.expectEqual(Phase.watching, machine.phase);
    try testing.expectEqual(@as(u64, 7), machine.head_batch);
    try testing.expectEqual(@as(u64, 1), machine.passes);
    try testing.expectEqual(@as(u64, 7), machine.frame().head_batch);
    // The machine's state code is the wire's table, not a second mapping.
    try testing.expectEqual(@as(u8, 3), machine.stateCode());
    try testing.expectEqual(Phase.watching.code(), machine.frame().state);
}

test "the frame's idle timeout is clamped to the wire's u32, not truncated" {
    var machine = Machine.init(.auto, 5_000_000_000);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), machine.frame().idle_timeout_ms);
}
