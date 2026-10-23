// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The watcher: nightwatch delivers events, the batcher holds them while git is mid-transaction, and the runner
//! decides when a batch becomes one engine pass.
//!
//! ```text
//! nightwatch (background thread)          this file (polling thread)
//!   event ──► Batcher.note ──► drain ──► Runner.event  ──► one engine.refresh per due batch
//!                     ▲                      │
//!          git lock / grace window           └─► measured duration ──► tuning saved per project
//! ```
//!
//! The split matters: the event thread only appends to a mutex-guarded set, so it never runs a pass and never
//! blocks the watcher; the polling thread owns the scheduler and the engine, so the delay rules of
//! [`watch_run.zig`](watch_run.zig) apply unchanged.
//!
//! Two guards are carried over from the prototype because they are real: **events during a git transaction are
//! held** (a `*.lock` in `.git` means the tree is being rewritten, and a pass then would describe a half-written
//! tree), and **a grace window after the last event** so a burst that is still arriving is not split.

const std = @import("std");
const nightwatch = @import("nightwatch");
const engine = @import("engine.zig");
const watch = @import("watch.zig");
const tuning = @import("watch_tuning.zig");
const watch_run = @import("watch_run.zig");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.real.now(io).nanoseconds;
}

fn nowMs(io: std.Io) f64 {
    return @as(f64, @floatFromInt(nowNs(io))) / 1_000_000.0;
}

/// Events from the watcher thread, held until the tree is safe to read.
///
/// No lock: the handlers only *publish* facts (something happened, when, and whether git is mid-transaction) and
/// the poller only *consumes* them. A racing tick can at worst cause one early or one extra pass, which the
/// scheduler absorbs — it is not a correctness boundary, and the trio is republished from a full reconciliation.
const Batcher = struct {
    pending: std.atomic.Value(u32) = .init(0),
    dirty: std.atomic.Value(bool) = .init(false),
    /// A `*.lock` in `.git` means the tree is being rewritten; a pass then would describe a half-written tree.
    in_git_tx: std.atomic.Value(bool) = .init(false),
    last_event_ms: std.atomic.Value(i64) = .init(0),

    fn skipped(path: []const u8) bool {
        return std.mem.startsWith(u8, path, ".git/") or std.mem.eql(u8, path, ".git") or
            std.mem.startsWith(u8, path, ".fs-meta/") or std.mem.eql(u8, path, ".fs-meta");
    }

    fn note(self: *Batcher, io: std.Io, path: []const u8) void {
        if (skipped(path)) return; // our own output must never feed back into a pass
        _ = self.pending.fetchAdd(1, .monotonic);
        self.last_event_ms.store(@intFromFloat(nowMs(io)), .monotonic);
        self.dirty.store(true, .release);
    }

    fn noteGit(self: *Batcher, io: std.Io, path: []const u8, event: nightwatch.EventType) void {
        const base = std.fs.path.basename(path);
        const is_lock = std.mem.endsWith(u8, base, ".lock");
        if (!is_lock and !std.mem.eql(u8, base, "HEAD")) return;
        if (is_lock) self.in_git_tx.store(event != .deleted, .release);
        self.last_event_ms.store(@intFromFloat(nowMs(io)), .monotonic);
        self.dirty.store(true, .release);
    }

    /// Whether the poller should treat the burst as finished, and the tree as safe to read.
    fn take(self: *Batcher, io: std.Io, grace_ms: f64) bool {
        if (!self.dirty.load(.acquire)) return false;
        if (hasGitLock(io)) {
            self.in_git_tx.store(true, .release);
            return false;
        }
        // The poll decides, not an event: no lock present means the transaction is over. Clearing this from a
        // git-watcher delete event stranded the latch whenever `.git` is a file (a git worktree), because then
        // no git watcher exists at all.
        if (self.in_git_tx.load(.acquire)) self.in_git_tx.store(false, .release);
        const last: f64 = @floatFromInt(self.last_event_ms.load(.monotonic));
        if (nowMs(io) - last < grace_ms) return false;
        self.dirty.store(false, .release);
        self.pending.store(0, .monotonic);
        return true;
    }
};

/// Whether git is mid-transaction: a lock file exists in `.git`.
fn hasGitLock(io: std.Io) bool {
    const locks = [_][]const u8{ ".git/index.lock", ".git/HEAD.lock", ".git/packed-refs.lock", ".git/shallow.lock" };
    for (locks) |path| {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        file.close(io);
        return true;
    }
    return false;
}

/// What a flush needs: the tree, the engine options, and the clock. The pass is arena-scoped, so a long-running
/// watcher cannot accumulate the engine's temporary paths.
const Flush = struct {
    io: std.Io,
    root: []const u8,
    options: engine.Options,

    fn call(ctx: *anyopaque) anyerror!f64 {
        const self: *Flush = @ptrCast(@alignCast(ctx));
        const started = nowNs(self.io);
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const outcome = try engine.refresh(arena_state.allocator(), self.io, self.root, self.options);
        const elapsed = @as(f64, @floatFromInt(nowNs(self.io) - started)) / 1_000_000.0;
        std.debug.print("[fs-meta] pass {d} ms — {d} names, {s}, {d} hashed\n", .{
            @as(u64, @intFromFloat(elapsed)),
            outcome.count,
            if (outcome.published) "published" else "no change",
            outcome.hashed,
        });
        return elapsed;
    }
};

const WtHandler = struct {
    handler: nightwatch.Default.Handler,
    batcher: *Batcher,
    io: std.Io,
    const vtable = nightwatch.Default.Handler.VTable{ .change = change, .rename = rename };
    fn change(h: *nightwatch.Default.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *WtHandler = @fieldParentPtr("handler", h);
        _ = event;
        self.batcher.note(self.io, path);
    }
    fn rename(h: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *WtHandler = @fieldParentPtr("handler", h);
        self.batcher.note(self.io, src);
        self.batcher.note(self.io, dst);
    }
};

const GitHandler = struct {
    handler: nightwatch.Default.Handler,
    batcher: *Batcher,
    io: std.Io,
    const vtable = nightwatch.Default.Handler.VTable{ .change = change, .rename = rename };
    fn change(h: *nightwatch.Default.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *GitHandler = @fieldParentPtr("handler", h);
        self.batcher.noteGit(self.io, path, event);
    }
    fn rename(h: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *GitHandler = @fieldParentPtr("handler", h);
        self.batcher.noteGit(self.io, src, .modified);
        self.batcher.noteGit(self.io, dst, .modified);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const root = try gpa.dupe(u8, ".");

    // The tuning lives with the trio, in a directory the walker never lists.
    var meta_dir = std.Io.Dir.cwd().openDir(io, ".fs-meta", .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try std.Io.Dir.cwd().createDirPath(io, ".fs-meta");
            break :blk try std.Io.Dir.cwd().openDir(io, ".fs-meta", .{});
        },
        else => return err,
    };
    defer meta_dir.close(io);

    var tuning_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer tuning_arena_state.deinit();
    const tuning_arena = tuning_arena_state.allocator();

    var flush_ctx: Flush = .{ .io = io, .root = root, .options = .{ .updated = "watch" } };
    var runner: watch_run.Runner = .{ .flush = Flush.call, .ctx = &flush_ctx };
    runner.state = try tuning.load(tuning_arena, io, meta_dir);
    {
        var buffer: [256]u8 = undefined;
        std.debug.print("[fs-meta] {s}\n", .{runner.state.describe(&buffer)});
    }

    var batcher: Batcher = .{};
    var wh = WtHandler{ .handler = .{ .vtable = &WtHandler.vtable }, .batcher = &batcher, .io = io };
    var gh = GitHandler{ .handler = .{ .vtable = &GitHandler.vtable }, .batcher = &batcher, .io = io };

    var watcher_wt = try nightwatch.Default.init(io, gpa, &wh.handler);
    defer watcher_wt.deinit();
    var watcher_git = try nightwatch.Default.init(io, gpa, &gh.handler);
    defer watcher_git.deinit();
    try watcher_wt.watch(".");
    // In a git *worktree* `.git` is a file pointing at the real git directory, so it cannot be watched as a
    // directory. The lock poll in `hasGitLock` covers that case either way: watching `.git` makes transaction
    // detection immediate, it is not a requirement.
    const git_is_dir = blk: {
        const stat = std.Io.Dir.cwd().statFile(io, ".git", .{ .follow_symlinks = false }) catch break :blk false;
        break :blk stat.kind == .directory;
    };
    if (git_is_dir) {
        try watcher_git.watch(".git");
    } else {
        std.debug.print("[fs-meta] .git is a file (worktree) — using the lock poll for git transactions\n", .{});
    }

    try runner.bootstrap();
    std.debug.print("[fs-meta] watching . — git-guarded, self-tuning (grace {d} ms)\n", .{@as(u64, @intFromFloat(runner.scheduler.quietPeriodMs()))});

    const grace_ms = 2 * runner.scheduler.quietPeriodMs();
    var passes_since_save: u64 = 0;
    while (true) {
        io.sleep(.fromMilliseconds(20), .real) catch {};
        // NOTE: service every tick, not only when a batch was taken.     ake consumes the dirty flag, and the
        // event it reports starts a *new* quiet period — so a pass becomes due on a later tick, when no event
        // has arrived. Servicing only inside the if is what made every batch after the bootstrap wait forever.
        if (batcher.take(io, grace_ms)) runner.event(nowMs(io));
        while (try runner.service(nowMs(io))) {
            passes_since_save += 1;
            if (passes_since_save >= 20) {
                passes_since_save = 0;
                try tuning.save(tuning_arena, io, meta_dir, runner.state);
            }
        }
    }
}