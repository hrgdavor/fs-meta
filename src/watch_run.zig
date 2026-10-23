// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The watch loop, minus the event source.
//!
//! [`watch.zig`](watch.zig) decides *when* to flush and [`watch_tuning.zig`](watch_tuning.zig) remembers what it
//! learned per project. This file is the glue: it owns one of each, runs a pass when the scheduler says so, and
//! folds the measured duration back into both. The pass itself is injected — a function that returns how long it
//! took — so the loop is exercised in tests with a counter instead of a file system and a clock, and the nightwatch
//! adapter that supplies events and time stays a thin shell with nothing to get wrong:
//!
//! ```text
//! var runner: watch_run.Runner = .{ .flush = flush, .ctx = &engine_ctx };
//! try runner.bootstrap();                 // one warm/cold pass before any event is trusted
//! while (events.next()) |event| {
//!     runner.event(now_ms(event));
//!     while (try runner.service(now_ms())) {}   // flush every batch that is due
//! }
//! try runner.shutdown();                  // persist the tuning
//! ```
//!
//! Two invariants the loop is responsible for, and which the tests pin:
//!
//! 1. **One pass per batch.** Events never run a pass themselves; only `service` does, and it does so at most once
//!    per call.
//! 2. **Every pass is measured and learned from.** A pass that the scheduler did not time is a run whose delay model
//!    drifts, so `notePass`/`observe` happen in one place, right after the flush.

const std = @import("std");
const watch = @import("watch.zig");
const tuning = @import("watch_tuning.zig");

/// Runs one engine pass and returns its measured duration in milliseconds. The adapter measures, because only it
/// has the clock; the runner does not guess.
pub const FlushFn = *const fn (ctx: *anyopaque) anyerror!f64;

pub const Runner = struct {
    scheduler: watch.Scheduler = .{},
    /// The persisted learning for this project; loaded by the caller before the first pass.
    state: tuning.State = .{},
    flush: FlushFn,
    ctx: *anyopaque,
    flushes: u64 = 0,

    /// The pass that establishes the trio before events are processed. It is measured like any other, so a project
    /// starts out tuned to its own first cost.
    pub fn bootstrap(self: *Runner) !void {
        try self.runPass();
    }

    /// An event arrived at `now_ms`.
    pub fn event(self: *Runner, now_ms: f64) void {
        self.scheduler.noteEvent(now_ms);
    }

    /// Run a pass if one is due; `true` when it did.
    pub fn service(self: *Runner, now_ms: f64) !bool {
        switch (self.scheduler.poll(now_ms)) {
            .none => return false,
            .quiet, .forced => {},
        }
        try self.runPass();
        self.scheduler.flushed();
        return true;
    }

    /// Persist what this session learned. Called on shutdown, and by the adapter whenever it likes.
    pub fn shutdown(self: *Runner, arena: std.mem.Allocator, io: std.Io, meta_dir: std.Io.Dir) !void {
        try tuning.save(arena, io, meta_dir, self.state);
    }

    fn runPass(self: *Runner) !void {
        const duration_ms = try self.flush(self.ctx);
        self.flushes += 1;
        self.scheduler.notePass(duration_ms);
        self.state.observe(duration_ms, self.scheduler.tuning);
        // Keep the persisted suggestion equal to what the live scheduler would use, so a pinned delay and the
        // reported one never disagree.
        self.state.suggested_delay_ms = self.scheduler.quietPeriodMs();
    }
};

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

const Fake = struct {
    calls: u64 = 0,
    duration_ms: f64 = 20,
};

fn fakeFlush(ctx: *anyopaque) anyerror!f64 {
    const fake: *Fake = @ptrCast(@alignCast(ctx));
    fake.calls += 1;
    return fake.duration_ms;
}

test "one pass per batch, however many events arrive" {
    var fake: Fake = .{ .duration_ms = 20 };
    var runner: Runner = .{ .flush = fakeFlush, .ctx = &fake };

    try runner.bootstrap();
    try testing.expectEqual(@as(u64, 1), fake.calls); // the bootstrap pass
    try testing.expectEqual(@as(u64, 1), runner.state.passes);

    // A burst of five events inside the quiet period runs nothing.
    for (1..6) |index| runner.event(@floatFromInt(index * 5));
    try testing.expect(!try runner.service(30));
    try testing.expectEqual(@as(u64, 1), fake.calls);

    // After the quiet period (1.5 × 20 = 30 ms past the last event at 25) exactly one pass runs.
    try testing.expect(try runner.service(60));
    try testing.expectEqual(@as(u64, 2), fake.calls);
    try testing.expectEqual(@as(u64, 2), runner.state.passes);
    // Nothing is due again until another event arrives.
    try testing.expect(!try runner.service(500));
}

test "a steady stream is served at the forced interval, not starved" {
    var fake: Fake = .{ .duration_ms = 20 };
    var runner: Runner = .{ .flush = fakeFlush, .ctx = &fake };
    try runner.bootstrap();

    var now: f64 = 0;
    var served: u64 = 0;
    while (now < 20_000) : (now += 10) {
        runner.event(now);
        if (try runner.service(now)) served += 1;
    }
    // max_wait is 5 s, so a 20 s stream is served at least four times even though no 30 ms gap ever opens.
    try testing.expect(served >= 3); // 5 s forced interval inside a 20 s stream
    try testing.expectEqual(served + 1, fake.calls); // plus the bootstrap
}

test "the learned delay follows a machine that slows down" {
    var fake: Fake = .{ .duration_ms = 15 };
    var runner: Runner = .{ .flush = fakeFlush, .ctx = &fake };
    try runner.bootstrap();
    const fast = runner.scheduler.quietPeriodMs();

    // The tree grows / the disk is busy: passes now take far longer.
    fake.duration_ms = 300;
    var now: f64 = 1000;
    for (0..5) |_| {
        runner.event(now);
        _ = try runner.service(now + 100_000); // force the flush immediately for this test
        now += 1000;
    }
    const slow = runner.scheduler.quietPeriodMs();
    try testing.expect(slow > fast);
    // The persisted suggestion agrees with the live scheduler, which is what a user is shown.
    try testing.expectApproxEqAbs(runner.scheduler.quietPeriodMs(), runner.state.suggested_delay_ms, 0.001);
}