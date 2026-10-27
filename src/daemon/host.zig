// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The daemon's process: the runtime directory, the registry, one `RootRuntime` per root, and the control socket.
//! Each root schedules itself (see below).
//!
//! ## Startup, in the order the plan fixes
//!
//! 1. Take the daemon lock (`<base>/daemon.lock`) — a live lock means a live daemon, and it is the kernel's
//!    answer, not a pid's. A second daemon refuses, and says so.
//! 2. Read `roots.json` from the user's config directory. A missing file is a valid state: no roots, no
//!    error. A malformed record is reported and skipped.
//! 3. For each record, `stat` the root once. Present → claim it, bind its socket, start accepting. Missing →
//!    the root is `missing`: reported, not dropped, and recovered when it comes back.
//! 4. Reap what a dead process left in the runtime directory.
//! 5. Only then bind the control socket and write `daemon.json`, so a CLI never sees a half-loaded daemon.
//!
//! **Nothing here searches the file system for roots.** The work is proportional to the recorded list: one
//! `stat` per root, and nothing else. That is the invariant behind keeping the list in the user home.
//!
//! ## Scheduling belongs to the root, not to the host
//!
//! There is no daemon-wide scheduler task. Each root owns its own: a sleeping thread that wakes every
//! `root.tick_interval_ms` and checks that root's idle deadline and event burst. A batch belongs to one root, so
//! its latency must not depend on another root's scan — with one loop over every root, a slow pass (or a client
//! that stopped reading) in one root delayed every other root's tick, and therefore its batches. Root lifecycles
//! (add, remove, mode changes) happen on the control task, so the root list has its own mutex — never held across
//! a socket write, and never taken while a root's mutex is held.

const std = @import("std");
const batch_mod = @import("../batch.zig");
const format = @import("../format.zig");
const paths = @import("paths.zig");
const registry = @import("registry.zig");
const gitdir = @import("../gitdir.zig");
const reaper = @import("reaper.zig");
const state = @import("state.zig");
const control = @import("control.zig");
const gitwatch = @import("gitwatch.zig");
const root_mod = @import("root.zig");
const ignores = @import("../ignores.zig");
const nesting = @import("../nesting.zig");
const seed = @import("../seed.zig");
const wire = @import("../wire.zig");

pub const Options = struct {
    /// `--base`: the runtime directory, overriding the platform's rule.
    base: ?[]const u8 = null,
    /// The environment the layout resolves against (the tests pass a map; the CLI passes the process's).
    env: paths.Env = .{},
};

/// One queued worktree signal. The root that saw it is named because the policy (`on_worktree`) belongs to the
/// discovering root, not to the child that does not exist yet. `metadata_dir` is `<common>/worktrees/<id>`; it is
/// the only thing a removal can still name after the worktree path is gone.
const WorktreeSignal = struct {
    root: []const u8,
    phase: wire.GitPhase,
    path: []const u8,
    metadata_dir: []const u8,
};

/// Caps on one drain: confirmation is file I/O, and a burst of thousands of worktree metadata directories must not
/// turn into an unbounded walk on the daemon's discovery task (`plans/worktrees.md` § 5, the field report's caps).
const worktree_drain_cap: usize = 32;
const worktree_confirm_deadline_ms: i64 = 3_000;

/// A second daemon on the same base refuses in `takeLock` with `error.AlreadyRunning`; the CLI turns that into
/// exit code 4.
pub const Host = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// The Host's own arena. It lives in the struct (not on a stack) because `arena` points into it and the
    /// daemon outlives any frame.
    arena_state: std.heap.ArenaAllocator,
    /// Long-lived state: the layout's paths, the log lines, the registry's strings.
    arena: std.mem.Allocator,
    layout: paths.Layout,
    registry: registry.Registry,
    roots: std.ArrayListUnmanaged(*root_mod.RootRuntime) = .empty,
    roots_mutex: std.Io.Mutex = .init,
    /// One metadata watcher per common dir (`plans/worktrees.md` § 5b, decision 6), refcounted by the roots that
    /// resolve to it. It lives on the daemon rather than on a root because the arm outlives a root: removing one
    /// worktree of a repo must leave the watcher serving its siblings.
    git_registry: gitwatch.Registry = undefined,
    /// The nested-root guard's immutable snapshot of served root paths (`plans/worktrees.md` § 5, M2). A pass
    /// repairs its own managed block from this list; the list is replaced, never mutated, and old arrays stay in
    /// `arena` so a callback can read a slice after releasing `guard_mutex` without a use-after-free. The mutex is
    /// never held while a root lock is taken, so it cannot deadlock with the control task's add path.
    guard_mutex: std.Io.Mutex = .init,
    guard_roots: []const []const u8 = &.{},
    /// M6's worktree signals: the root callbacks only append here (they hold their own root's lock, so they must not
    /// take `roots_mutex`); the daemon's worktree task drains the queue and performs the add/mark-missing mutation.
    worktree_mutex: std.Io.Mutex = .init,
    worktree_signals: std.ArrayListUnmanaged(WorktreeSignal) = .empty,
    worktree_group: std.Io.Group = .init,
    worktree_stop: std.atomic.Value(bool) = .init(false),
    control: ?std.Io.net.Server = null,
    control_path: []const u8 = "",
    lock_file: ?std.Io.File = null,
    pid: u32 = 0,
    started_at_ms: i64 = 0,
    shutting_down: bool = false,
    /// `FSMETA_WORKTREES` resolved at start (`plans/worktrees.md` § 5h): `null` = no override. `false` disables
    /// both `worktrees` and `gitwatch` for every root; `true` forces both on. Read once, so a root added later
    /// gets the same answer as one loaded from the list.
    worktrees_override: ?bool = null,
    /// `FSMETA_GITWATCH`: the finer knob. `false` disables git signals alone; it cannot re-enable anything
    /// `FSMETA_WORKTREES=0` turned off.
    gitwatch_override: ?bool = null,
    /// Test-only (`FORMAT.daemon.md` § 8): `FSMETA_GIT_ARM=off` does not arm the metadata watcher, so the hook spool
    /// path (M5) can be exercised on its own. Not a user switch: the git dirs are still resolved, the latch still
    /// polls, and the spool is still read; only the metadata *watch* — and so the timeline only it can see — is off.
    git_arm_disabled: bool = false,

    /// Start the daemon and serve until `daemon.shutdown`. `main` exits the process; this returns only when
    /// asked to stop, so tests can run it in a child process and drive it over the control socket.
    pub fn start(io: std.Io, allocator: std.mem.Allocator, options: Options) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .arena = undefined,
            .layout = undefined,
            .registry = undefined,
        };
        self.arena = self.arena_state.allocator();
        errdefer self.arena_state.deinit();
        // One metadata-watch registry for the whole daemon: arms are keyed by common dir and shared across roots.
        self.git_registry = gitwatch.Registry.init(io, allocator);

        self.layout = try paths.Layout.resolve(self.arena, options.env, options.base);
        self.registry = registry.Registry.init(self.arena, self.layout.config);

        // The emergency override is read before any root starts, so every root — loaded or added later — sees
        // one answer. `FSMETA_WORKTREES` is deliberately readable without a control socket: a daemon that
        // misbehaves must be standable-down by a restart.
        self.worktrees_override = parseFlagEnv(options.env.get("FSMETA_WORKTREES"));
        self.gitwatch_override = parseFlagEnv(options.env.get("FSMETA_GITWATCH"));
        // A test guard, not a feature (`FORMAT.daemon.md` § 8): the hook path is proved on its own by taking the
        // metadata timeline out of the picture, and an environment guard is the only way to do that without a second
        // build. It is logged, so a daemon that is quiet about git events says why.
        self.git_arm_disabled = testArmDisabled(options.env.get("FSMETA_GIT_ARM"));
        if (self.git_arm_disabled) {
            std.debug.print("fsmeta daemon: FSMETA_GIT_ARM=off — the metadata watch is not armed (test guard)\n", .{});
        }
        if (self.worktrees_override != null or self.gitwatch_override != null) {
            std.debug.print("fsmeta daemon: env override active — worktrees {s}, gitwatch {s}\n", .{
                flagText(self.effectiveWorktrees(null)),
                flagText(self.effectiveGitwatch(null)),
            });
        }

        try self.prepareDirectories();
        try self.takeLock();
        try self.loadRegistry();
        try self.startRoots();
        try self.bindControl();
        try self.writeDaemonFile();
        try self.worktree_group.concurrent(io, worktreeLoop, .{self});

        // No scheduler to spawn here: each root started its own in `RootRuntime.bindLocked`, so a root is
        // being ticked before the control socket answers.
        return self;
    }

    pub fn stop(self: *Host) void {
        const io = self.io;
        self.worktree_stop.store(true, .release);
        self.worktree_group.await(io) catch {};
        self.freeWorktreeSignals();
        self.roots_mutex.lockUncancelable(io);
        for (self.roots.items) |root| root.deinit();
        self.roots.clearRetainingCapacity();
        self.roots_mutex.unlock(io);

        if (self.control) |*listener| listener.deinit(io);
        self.control = null;
        std.Io.Dir.deleteFileAbsolute(io, self.control_path) catch {};
        const daemon_file = self.layout.controlFile(self.arena) catch "";
        if (daemon_file.len > 0) std.Io.Dir.deleteFileAbsolute(io, daemon_file) catch {};

        if (self.lock_file) |file| file.close(io);
        self.lock_file = null;

        self.roots.deinit(self.allocator);
        self.registry.deinit();
        // Every root released its reference in `deinit`; anything left would be a leak the registry reports.
        self.git_registry.deinit();
        self.arena_state.deinit();
        self.allocator.destroy(self);
    }

    /// The whole daemon, from a CLI: start, serve until told to stop, shut down.
    pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
        const self = try Host.start(io, allocator, options);
        defer self.stop();
        try self.serve();
    }

    // ---------------------------------------------------------------- startup steps

    fn prepareDirectories(self: *Host) !void {
        const io = self.io;
        try std.Io.Dir.cwd().createDirPath(io, self.layout.base);
        try std.Io.Dir.cwd().createDirPath(io, try self.layout.rootsDir(self.arena));
        try std.Io.Dir.cwd().createDirPath(io, try self.layout.logsDir(self.arena));
    }

    /// Hold `<base>/daemon.lock` for the life of the process. A second daemon on the same base is refused here,
    /// before it touches any root.
    fn takeLock(self: *Host) !void {
        const io = self.io;
        const path = try self.layout.controlLock(self.arena);
        var file = std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => return error.AlreadyRunning,
            else => return err,
        };
        errdefer file.close(io);
        self.lock_file = file;
        self.pid = reaper.currentPid();
        self.started_at_ms = root_mod.nowMs(io);
    }

    fn loadRegistry(self: *Host) !void {
        try self.registry.load(self.io);
        for (self.registry.diagnostics.items) |line| {
            std.debug.print("fsmeta daemon: {s}\n", .{line});
        }
    }

    fn startRoots(self: *Host) !void {
        const io = self.io;
        var claimed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer claimed.deinit(self.arena);

        // Reconcile every served parent's managed block **before any root starts**, so a pair that entered
        // `roots.json` by hand (or an older version) cannot publish one duplicate generation on the way up. A
        // missing root is not an error here: `startRoot` reports it as `missing`, and a parent that is not being
        // scanned cannot duplicate anything.
        self.reconcileAllRecords();

        for (self.registry.records.items) |record| {
            try self.startRoot(record);
            try claimed.append(self.arena, record.id);
        }
        self.refreshGuardPaths();

        // What a dead process left behind: claims nobody holds, sockets nobody listens on.
        _ = reaper.reap(io, self.arena, self.layout, claimed.items) catch |err| {
            std.debug.print("fsmeta daemon: reaping the runtime directory failed: {s}\n", .{@errorName(err)});
        };
    }

    fn startRoot(self: *Host, record: registry.Record) !void {
        // The effective `gitwatch`, not the stored one: `FSMETA_WORKTREES=0` / `FSMETA_GITWATCH=0` must turn the
        // handling off for a root whose record says on, and reporting it in `daemon status` is not the same thing.
        // `worktrees` is resolved the same way, because the runtime gates its own signals on this copy.
        var effective = record;
        effective.gitwatch = self.effectiveGitwatch(record);
        effective.worktrees = self.effectiveWorktrees(record);
        const runtime = try root_mod.RootRuntime.create(self.allocator, self.io, self.layout, effective, self.arena, &self.git_registry);
        errdefer self.allocator.destroy(runtime);
        runtime.guard = .{ .ctx = self, .reconcileFn = guardPass, .servedFn = guardServed };
        runtime.worktree_observer = .{ .ctx = self, .onWorktree = observeWorktree };
        // The daemon's start bounds the hook spool (§ 5c): a line from an earlier second is not this daemon's event.
        runtime.daemon_started_at_ms = self.started_at_ms;
        runtime.git_arm_enabled = !self.git_arm_disabled;

        // The socket path is rewritten on every start: the runtime directory may have moved since the record
        // was written, and a stale path in the list would point at nothing.
        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = try self.layout.rootLog(self.arena, record.id),
            .data = "",
        }) catch {};
        runtime.log_file = std.Io.Dir.cwd().createFile(self.io, try self.layout.rootLog(self.arena, record.id), .{ .truncate = true }) catch null;

        runtime.start() catch |err| switch (err) {
            error.AlreadyClaimed => {
                std.debug.print("fsmeta daemon: {s} is already served by another process; skipped\n", .{record.root});
                self.allocator.destroy(runtime);
                return;
            },
            else => {
                std.debug.print("fsmeta daemon: cannot serve {s}: {s}\n", .{ record.root, @errorName(err) });
                self.allocator.destroy(runtime);
                return;
            },
        };
        try self.roots.append(self.allocator, runtime);
    }

    fn bindControl(self: *Host) !void {
        const io = self.io;
        self.control_path = try self.layout.controlSocket(self.arena);
        std.Io.Dir.deleteFileAbsolute(io, self.control_path) catch {};
        const address = try std.Io.net.UnixAddress.init(self.control_path);
        self.control = try address.listen(io, .{});
    }

    fn writeDaemonFile(self: *Host) !void {
        var buffer: [32]u8 = undefined;
        const bytes = try (control.DaemonFile{
            .pid = self.pid,
            .started_at = root_mod.rfc3339Utc(self.started_at_ms, &buffer),
            .base = self.layout.base,
        }).encode(self.arena);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = try self.layout.controlFile(self.arena),
            .data = bytes,
        });
    }

    // ---------------------------------------------------------------- the control socket

    /// Accept control connections until `daemon.shutdown`. One request per connection, answered, closed.
    pub fn serve(self: *Host) !void {
        const io = self.io;
        while (!self.shutting_down) {
            const listener = if (self.control) |*value| value else return;
            const stream = listener.accept(io) catch |err| switch (err) {
                error.SocketNotListening => return,
                else => return err,
            };
            self.serveControlConnection(stream) catch |err| {
                std.debug.print("fsmeta daemon: control connection failed: {s}\n", .{@errorName(err)});
            };
            stream.close(io);
        }
    }

    fn serveControlConnection(self: *Host, stream: std.Io.net.Stream) !void {
        const io = self.io;
        // The request line is small (a root path plus a retention block); the ceiling is `control.max_line`, and
        // a longer line is refused rather than truncated.
        var read_buffer: [control.max_line]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);

        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            error.StreamTooLong => {
                try self.refuseLine(stream, control.Exit.failure, "the request line is too long");
                return;
            },
            else => return err,
        };

        const request = control.parseRequest(scratch, line) catch |err| {
            const message = control.describeParseError(err);
            std.debug.print("fsmeta daemon: refused control line ({d} bytes, {s}): [{s}]\n", .{ line.len, @errorName(err), line });
            try self.refuseLine(stream, if (err == error.UnsupportedVersion) control.Exit.protocol_mismatch else control.Exit.failure, message);
            return;
        };

        var out: std.Io.Writer.Allocating = .init(scratch);
        defer out.deinit();
        try self.handle(request, &out.writer);
        try root_mod.writeAll(io, stream, out.written());
    }

    fn refuseLine(self: *Host, stream: std.Io.net.Stream, code: u8, message: []const u8) !void {
        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        var out: std.Io.Writer.Allocating = .init(scratch_state.allocator());
        defer out.deinit();
        try control.beginError(&out.writer, code, message);
        try control.finish(&out.writer);
        try root_mod.writeAll(self.io, stream, out.written());
    }

    /// Dispatch one request. Every branch writes exactly one reply object and returns the close.
    pub fn handle(self: *Host, request: control.Request, writer: *std.Io.Writer) !void {
        const io = self.io;
        const now = root_mod.nowMs(io);

        switch (request.cmd) {
            .status => {
                try control.beginOk(writer);
                try control.intField(writer, "pid", self.pid);
                try control.stringField(writer, "base", self.layout.base);
                try control.stringField(writer, "config", self.layout.config);
                try control.intField(writer, "protocol", @import("../wire.zig").protocol);
                try control.intField(writer, "uptime_ms", now - self.started_at_ms);
                try control.intField(writer, "roots", self.roots.items.len);
                // The two switches (`plans/worktrees.md` § 5h): what a root would get right now, and whether an
                // environment override is why. A root record carries its own copy; the override wins at start.
                try control.boolField(writer, "worktrees", self.effectiveWorktrees(null));
                try control.boolField(writer, "gitwatch", self.effectiveGitwatch(null));
                try control.stringField(writer, "worktrees_override", if (self.worktrees_override) |value| flagText(value) else "");
                try control.stringField(writer, "gitwatch_override", if (self.gitwatch_override) |value| flagText(value) else "");
                try writer.writeAll(",\"diagnostics\":[");
                for (self.registry.diagnostics.items, 0..) |line, index| {
                    if (index > 0) try writer.writeByte(',');
                    try control.writeString(writer, line);
                }
                try writer.writeByte(']');
                try control.finish(writer);
            },
            .roots => {
                // Housekeeping over many roots (`FORMAT.daemon.md` § 4b): one root's lock at a time, each with
                // `Budget.roots`, so the listing answers even when a root is stuck mid-write — with
                // `available: false` for that root and `partial: true` on the reply.
                self.roots_mutex.lockUncancelable(io);
                defer self.roots_mutex.unlock(io);
                var partial = false;
                var objects: std.ArrayListUnmanaged([]const u8) = .empty;
                defer {
                    for (objects.items) |text| self.allocator.free(text);
                    objects.deinit(self.allocator);
                }
                for (self.roots.items) |runtime| {
                    if (runtime.snapshot(control.Budget.roots)) |snapshot| {
                        var out: std.Io.Writer.Allocating = .init(self.allocator);
                        writeSnapshot(&out.writer, snapshot) catch {
                            out.deinit();
                            continue;
                        };
                        try objects.append(self.allocator, try out.toOwnedSlice());
                    } else |_| {
                        partial = true;
                        const identity = runtime.identity();
                        var out: std.Io.Writer.Allocating = .init(self.allocator);
                        writeUnavailable(&out.writer, identity.id, identity.root) catch {
                            out.deinit();
                            continue;
                        };
                        try objects.append(self.allocator, try out.toOwnedSlice());
                    }
                }
                try control.beginOk(writer);
                try control.boolField(writer, "partial", partial);
                try writer.writeAll(",\"roots\":[");
                for (objects.items, 0..) |text, index| {
                    if (index > 0) try writer.writeByte(',');
                    try writer.writeAll(text);
                }
                try writer.writeByte(']');
                try control.finish(writer);
            },
            .root_status, .root_sleep, .root_wake, .root_set, .root_remove => {
                const target = request.root orelse {
                    try refuse(writer, control.Exit.failure, "this command needs \"root\": an id or a root path");
                    return;
                };
                self.roots_mutex.lockUncancelable(io);
                defer self.roots_mutex.unlock(io);

                const index = self.findRootLocked(target) orelse {
                    const message = try std.fmt.allocPrint(self.arena, "no such root: {s}", .{target});
                    try refuse(writer, control.Exit.no_such_root, message);
                    return;
                };
                // A single root asked for by name can afford a short wait; a mutation must either happen or be
                // refused, so it gets a longer one. Both are `§ 4b` budgets, not arbitrary sleeps.
                const budget = if (request.cmd == .root_status) control.Budget.root_status else control.Budget.mutation;
                switch (request.cmd) {
                    .root_status => {
                        const snapshot = self.roots.items[index].snapshot(budget) catch {
                            try refuseBusy(writer, self.arena, target);
                            return;
                        };
                        try control.beginOk(writer);
                        try writer.writeAll(",\"root\":");
                        try writeSnapshot(writer, snapshot);
                        try control.finish(writer);
                    },
                    .root_sleep => {
                        self.roots.items[index].sleepNow(now, budget) catch {
                            try refuseBusy(writer, self.arena, target);
                            return;
                        };
                        const snapshot = self.roots.items[index].snapshot(control.Budget.mutation) catch {
                            try refuseBusy(writer, self.arena, target);
                            return;
                        };
                        try control.beginOk(writer);
                        try writer.writeAll(",\"root\":");
                        try writeSnapshot(writer, snapshot);
                        try control.finish(writer);
                    },
                    .root_wake => {
                        self.roots.items[index].wakeNow(now, budget) catch |err| switch (err) {
                            error.RefusedByPolicy => {
                                try refuse(writer, control.Exit.refused, "mode is off: this root never watches, so it cannot be woken; set its mode first");
                                return;
                            },
                            error.Busy => {
                                try refuseBusy(writer, self.arena, target);
                                return;
                            },
                        };
                        const snapshot = self.roots.items[index].snapshot(control.Budget.mutation) catch {
                            try refuseBusy(writer, self.arena, target);
                            return;
                        };
                        try control.beginOk(writer);
                        try writer.writeAll(",\"root\":");
                        try writeSnapshot(writer, snapshot);
                        try control.finish(writer);
                    },
                    .root_set => try self.setRootLocked(index, request, now, writer),
                    .root_remove => try self.removeRootLocked(index, request, writer),
                    else => unreachable,
                }
            },
            .root_add => {
                try self.addRoot(request, writer);
            },
            .daemon_shutdown => {
                try control.beginOk(writer);
                try control.stringField(writer, "message", "stopping");
                try control.finish(writer);
                self.shutting_down = true;
            },
        }
    }

    fn findRootLocked(self: *Host, id_or_path: []const u8) ?usize {
        for (self.roots.items, 0..) |runtime, index| {
            if (std.mem.eql(u8, runtime.record.id, id_or_path)) return index;
            if (std.mem.eql(u8, runtime.record.root, id_or_path)) return index;
        }
        return null;
    }

    /// `root.add`: canonicalize, claim, bind, serve, and only then record it durably.
    ///
    /// The order matters. A record written before the socket is bound would claim a root this process may not
    /// be able to serve; the record is committed last, and rolled back if the start fails.
    fn addRoot(self: *Host, request: control.Request, writer: *std.Io.Writer) !void {
        const io = self.io;
        const locator = request.path orelse {
            try refuse(writer, control.Exit.failure, "root.add needs \"path\": the directory to serve");
            return;
        };

        const canonical = paths.canonicalRoot(io, self.arena, locator) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                const message = try std.fmt.allocPrint(self.arena, "no such directory: {s}", .{locator});
                try refuse(writer, control.Exit.no_such_root, message);
                return;
            },
            else => {
                const message = try std.fmt.allocPrint(self.arena, "cannot open {s}: {s}", .{ locator, @errorName(err) });
                try refuse(writer, control.Exit.failure, message);
                return;
            },
        };

        const id = paths.idFor(canonical);
        self.roots_mutex.lockUncancelable(io);
        defer self.roots_mutex.unlock(io);

        if (self.registry.findById(&id)) |_| {
            const message = try std.fmt.allocPrint(self.arena, "{s} is already served as {s}", .{ canonical, &id });
            try refuse(writer, control.Exit.refused, message);
            return;
        }

        // The defaults are copied at this moment, so a later change to a default never mutates this root.
        var overrides = self.registry.defaults;
        if (request.mode) |mode| overrides.mode = mode;
        if (request.idle_timeout_ms) |value| overrides.idle_timeout_ms = value;
        if (request.retention) |value| overrides.retention = value;
        if (request.on_remove) |value| overrides.on_remove = value;
        if (request.worktrees) |value| overrides.worktrees = value;
        if (request.gitwatch) |value| overrides.gitwatch = value;
        if (request.on_worktree) |value| overrides.on_worktree = value;

        // `root add --worktree` (`plans/worktrees.md` § 7, M7) asserts that the path is a **linked worktree**, not a
        // nested clone and not a plain directory: `.git` must be a gitfile whose target is an existing directory. The
        // assertion is checked rather than trusted, and it implies the adoption/seed path for this explicit add —
        // which is why the switch is forced on for the new record (unless an environment override says off).
        if (request.worktree) {
            if (!gitdir.linkedWorktree(self.arena, io, canonical)) {
                const message = try std.fmt.allocPrint(
                    self.arena,
                    "cannot add {s} with --worktree: its .git is not a gitfile naming an existing directory, so it is not a linked worktree",
                    .{canonical},
                );
                try refuse(writer, control.Exit.refused, message);
                return;
            }
            if (request.worktrees) |value| {
                if (!value) {
                    const message = try std.fmt.allocPrint(
                        self.arena,
                        "cannot add {s} with --worktree and --worktrees off: the first asks for the worktree path (seed/adoption), the second switches it off",
                        .{canonical},
                    );
                    try refuse(writer, control.Exit.refused, message);
                    return;
                }
            }
            overrides.worktrees = true;
        }

        // R4 (`plans/worktrees.md` § 5e): a worktree added to a repository with a served base is seeded from that
        // base's trio. This runs **before** the nested-root guard: the guard is about to add a managed line to the
        // base's `.fs-meta/ignore`, and § 5e compares the two ignore files — seeding first is the state the base
        // actually had when the copy was taken. The base's runtime state is the one input the seed cannot read, so
        // it is checked here. A refusal is a cold scan, never a failure.
        if (self.worktrees_override orelse overrides.worktrees) self.trySeedNewRoot(canonical);

        // R2 (`plans/worktrees.md` § 5): nesting is guarded, not warned about. The lines are arranged **before**
        // the new root is recorded or served, and each existing parent is passed once so the exclusion is in its
        // trio before the child's first pass can duplicate it. The guard is not gated by `worktrees`/`gitwatch`.
        var ancestors: std.ArrayListUnmanaged(*root_mod.RootRuntime) = .empty;
        defer ancestors.deinit(self.arena);
        var descendants: std.ArrayListUnmanaged([]const u8) = .empty;
        defer descendants.deinit(self.arena);
        for (self.roots.items) |runtime| {
            const existing = runtime.identity().root;
            if (paths.isInside(existing, canonical)) {
                try ancestors.append(self.arena, runtime);
            } else if (paths.isInside(canonical, existing)) {
                try descendants.append(self.arena, existing);
            }
        }

        // A new parent hides every already-served descendant before its first pass; one managed line each.
        for (descendants.items) |child| {
            const relative = nesting.relativePath(self.arena, canonical, child) catch {
                try self.refuseGuard(writer, canonical, child, "cannot describe it relative to the new root");
                return;
            };
            ignores.appendManaged(self.arena, self.io, canonical, relative) catch |err| {
                const message = try std.fmt.allocPrint(
                    self.arena,
                    "cannot add {s}: {s}/.fs-meta/ignore could not be written ({s}); it would scan {s} twice",
                    .{ canonical, canonical, @errorName(err), child },
                );
                try refuse(writer, control.Exit.refused, message);
                return;
            };
        }

        // Existing parents hide the new child, and each is passed exactly once — asleep or off included, with no
        // watcher armed — so the next reader of the parent's trio already sees it excluded (G39).
        for (ancestors.items) |runtime| {
            const parent = runtime.identity().root;
            const relative = nesting.relativePath(self.arena, parent, canonical) catch {
                try self.refuseGuard(writer, parent, canonical, "cannot describe the new root relative to it");
                return;
            };
            ignores.appendManaged(self.arena, self.io, parent, relative) catch |err| {
                const message = try std.fmt.allocPrint(
                    self.arena,
                    "cannot add {s}: {s}/.fs-meta/ignore could not be written ({s}); {s} would scan it twice",
                    .{ canonical, parent, @errorName(err), parent },
                );
                try refuse(writer, control.Exit.refused, message);
                return;
            };
            runtime.forcePass(root_mod.nowMs(io), control.Budget.mutation) catch |err| {
                const message = try std.fmt.allocPrint(
                    self.arena,
                    "cannot add {s}: {s}/.fs-meta/ignore was updated but {s} could not be passed ({s}); refusing rather than serving it twice",
                    .{ canonical, parent, parent, @errorName(err) },
                );
                try refuse(writer, control.Exit.refused, message);
                return;
            };
        }

        const socket = try self.layout.rootSocket(self.arena, &id);
        var stamp_buffer: [32]u8 = undefined;
        try self.registry.add(canonical, &id, socket, overrides, root_mod.rfc3339Utc(root_mod.nowMs(io), &stamp_buffer));
        const record = self.registry.records.items[self.registry.records.items.len - 1];

        // The effective `gitwatch`, resolved at add time as it is at start: an env override active while the root is
        // added must behave like one active at startup. The durable record keeps the configured value. `worktrees`
        // is resolved the same way so the runtime's own gates agree with `daemon status`.
        var effective = record;
        effective.gitwatch = self.effectiveGitwatch(record);
        effective.worktrees = self.effectiveWorktrees(record);
        const runtime = root_mod.RootRuntime.create(self.allocator, io, self.layout, effective, self.arena, &self.git_registry) catch |err| {
            _ = self.registry.records.pop();
            const message = try std.fmt.allocPrint(self.arena, "cannot create the runtime: {s}", .{@errorName(err)});
            try refuse(writer, control.Exit.failure, message);
            return;
        };
        runtime.guard = .{ .ctx = self, .reconcileFn = guardPass, .servedFn = guardServed };
        runtime.worktree_observer = .{ .ctx = self, .onWorktree = observeWorktree };
        runtime.daemon_started_at_ms = self.started_at_ms;
        runtime.git_arm_enabled = !self.git_arm_disabled;
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try self.layout.rootLog(self.arena, record.id),
            .data = "",
        }) catch {};
        runtime.log_file = std.Io.Dir.cwd().createFile(io, try self.layout.rootLog(self.arena, record.id), .{ .truncate = true }) catch null;
        runtime.start() catch |err| {
            _ = self.registry.records.pop();
            runtime.deinit();
            const message = try std.fmt.allocPrint(self.arena, "cannot serve {s}: {s}", .{ canonical, @errorName(err) });
            try refuse(writer, control.Exit.failure, message);
            return;
        };
        try self.roots.append(self.allocator, runtime);
        self.refreshGuardPaths();
        self.registry.save(io) catch |err| {
            std.debug.print("fsmeta daemon: cannot save the root list: {s}\n", .{@errorName(err)});
        };

        // Freshly started: nobody else can hold its lock, so the budget is a formality here.
        const snapshot = runtime.snapshot(control.Budget.mutation) catch {
            try refuseBusy(writer, self.arena, runtime.record.id);
            return;
        };
        try control.beginOk(writer);
        // `--nested` changes nothing it does not have to: the guard above still wrote the parent's managed line.
        // The reply says the intent was acknowledged, so a script can tell an explicit nested add from a silent one.
        if (request.nested) try control.stringField(writer, "nested", "acknowledged");
        try writer.writeAll(",\"root\":");
        try writeSnapshot(writer, snapshot);
        try control.finish(writer);
    }

    /// The root callback. It only queues: it runs with the discovering root's lock held, so it must never take
    /// `roots_mutex` or another root's lock.
    fn observeWorktree(ctx: *anyopaque, root: []const u8, phase: wire.GitPhase, path: []const u8, metadata_dir: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.enqueueWorktree(root, phase, path, metadata_dir) catch |err| {
            std.debug.print("fsmeta daemon: cannot queue a worktree signal: {s}\n", .{@errorName(err)});
        };
    }

    fn enqueueWorktree(self: *Host, root: []const u8, phase: wire.GitPhase, path: []const u8, metadata_dir: []const u8) !void {
        const owned_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(owned_root);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_metadata = try self.allocator.dupe(u8, metadata_dir);
        errdefer self.allocator.free(owned_metadata);
        self.worktree_mutex.lockUncancelable(self.io);
        defer self.worktree_mutex.unlock(self.io);
        try self.worktree_signals.append(self.allocator, .{
            .root = owned_root,
            .phase = phase,
            .path = owned_path,
            .metadata_dir = owned_metadata,
        });
    }

    fn freeWorktreeSignals(self: *Host) void {
        self.worktree_mutex.lockUncancelable(self.io);
        for (self.worktree_signals.items) |signal| {
            self.allocator.free(signal.root);
            self.allocator.free(signal.path);
            self.allocator.free(signal.metadata_dir);
        }
        self.worktree_signals.deinit(self.allocator);
        self.worktree_signals = .empty;
        self.worktree_mutex.unlock(self.io);
    }

    fn worktreeLoop(self: *Host) void {
        while (!self.worktree_stop.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(50), .real) catch {};
            self.drainWorktreeSignals();
        }
    }

    /// One bounded drain: a worktree burst must not turn into an unbounded confirmation walk (§ 5's caps).
    fn drainWorktreeSignals(self: *Host) void {
        const deadline = root_mod.nowMs(self.io) + worktree_confirm_deadline_ms;
        var handled: usize = 0;
        while (handled < worktree_drain_cap and root_mod.nowMs(self.io) < deadline) {
            var signal: WorktreeSignal = undefined;
            self.worktree_mutex.lockUncancelable(self.io);
            if (self.worktree_signals.items.len == 0) {
                self.worktree_mutex.unlock(self.io);
                return;
            }
            signal = self.worktree_signals.orderedRemove(0);
            self.worktree_mutex.unlock(self.io);
            defer {
                self.allocator.free(signal.root);
                self.allocator.free(signal.path);
                self.allocator.free(signal.metadata_dir);
            }
            self.handleWorktreeSignal(signal, deadline);
            handled += 1;
        }
        self.worktree_mutex.lockUncancelable(self.io);
        const left = self.worktree_signals.items.len;
        self.worktree_mutex.unlock(self.io);
        if (left > 0) {
            std.debug.print("fsmeta daemon: worktree discovery hit its cap/deadline; {d} signal(s) remain queued\n", .{left});
        }
    }

    fn handleWorktreeSignal(self: *Host, signal: WorktreeSignal, deadline_ms: i64) void {
        if (signal.phase == .finish and signal.path.len == 0 and signal.metadata_dir.len > 0) {
            self.markWorktreeMissing(signal.metadata_dir);
            return;
        }
        if (signal.phase != .finish or signal.path.len == 0) return;
        if (root_mod.nowMs(self.io) >= deadline_ms) return;

        // `git worktree move`/`repair` changes the `gitdir` back-pointer while the metadata directory stays: the
        // served root at the old path is gone even though no metadata directory disappeared (§ 5f).
        if (signal.metadata_dir.len > 0) self.markMovedWorktree(signal.metadata_dir, signal.path);

        const policy = self.worktreePolicy(signal.root) orelse return;
        if (!policy.worktrees) return;
        if (!policy.serve) {
            std.debug.print("fsmeta daemon: worktree {s} appeared (not adopted; use --on-worktree serve)\n", .{signal.path});
            return;
        }

        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const canonical = paths.canonicalRoot(self.io, scratch, signal.path) catch return;
        const id = paths.idFor(canonical);
        if (self.registry.findById(&id) != null) return;
        const location = (gitdir.resolve(scratch, self.io, canonical) catch return) orelse return;
        if (!location.is_gitfile) return;

        var out: std.Io.Writer.Allocating = .init(scratch);
        defer out.deinit();
        const request: control.Request = .{ .cmd = .root_add, .path = canonical };
        self.addRoot(request, &out.writer) catch |err| {
            std.debug.print("fsmeta daemon: adopting worktree {s} failed: {s}\n", .{ canonical, @errorName(err) });
        };
    }

    /// The discovering root's policy, copied out under the roots mutex.
    fn worktreePolicy(self: *Host, root: []const u8) ?struct { serve: bool, worktrees: bool } {
        self.roots_mutex.lockUncancelable(self.io);
        defer self.roots_mutex.unlock(self.io);
        for (self.roots.items) |runtime| {
            if (!std.mem.eql(u8, runtime.identity().root, root)) continue;
            return .{
                .serve = runtime.record.on_worktree == .serve,
                .worktrees = self.effectiveWorktrees(runtime.record),
            };
        }
        return null;
    }

    /// A worktree's `gitdir` now names a different path: the served root at the old one is `missing`. This is the
    /// `move`/`repair` case, where nothing disappeared from the metadata directory.
    fn markMovedWorktree(self: *Host, metadata_dir: []const u8, new_path: []const u8) void {
        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        self.roots_mutex.lockUncancelable(self.io);
        defer self.roots_mutex.unlock(self.io);
        for (self.roots.items) |runtime| {
            const location = (gitdir.resolve(scratch, self.io, runtime.record.root) catch continue) orelse continue;
            if (!gitwatch.samePath(location.git_dir, metadata_dir)) continue;
            if (gitwatch.samePath(runtime.record.root, new_path)) continue;
            if (!self.effectiveWorktrees(runtime.record)) continue;
            runtime.markMissing(control.Budget.mutation) catch continue;
            std.debug.print("fsmeta daemon: worktree moved from {s} to {s}; the old root is missing\n", .{ runtime.record.root, new_path });
        }
    }

    /// The metadata directory `<common>/worktrees/<id>` is gone: mark the worktree root it named `missing`, without
    /// touching its archive. The flag belongs to the affected root: with `worktrees` off there is no reaction.
    fn markWorktreeMissing(self: *Host, metadata_dir: []const u8) void {
        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        self.roots_mutex.lockUncancelable(self.io);
        defer self.roots_mutex.unlock(self.io);
        for (self.roots.items) |runtime| {
            const location = (gitdir.resolve(scratch, self.io, runtime.record.root) catch continue) orelse continue;
            if (!gitwatch.samePath(location.git_dir, metadata_dir)) continue;
            if (!self.effectiveWorktrees(runtime.record)) continue;
            runtime.markMissing(control.Budget.mutation) catch continue;
            std.debug.print("fsmeta daemon: worktree {s} left its repository; root is missing\n", .{runtime.record.root});
        }
    }

    /// Seed `canonical` from a served root of the same repository when § 5e allows it. The base must have a settled
    /// last pass (`snapshot` succeeds and `last_error` is empty); the remaining conjunction (same common dir,
    /// byte-identical internal ignore, matching `scan` blocks, readable/valid base trio) is the seed module's.
    fn trySeedNewRoot(self: *Host, canonical: []const u8) void {
        const io = self.io;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const new_location = (gitdir.resolve(arena, io, canonical) catch return) orelse return;
        if (!new_location.is_gitfile) return;
        for (self.roots.items) |base| {
            if (std.mem.eql(u8, base.root_path, canonical)) continue;
            const base_location = (gitdir.resolve(arena, io, base.root_path) catch continue) orelse continue;
            if (!gitwatch.samePath(base_location.common_dir, new_location.common_dir)) continue;
            const snapshot = base.snapshot(0) catch continue;
            if (snapshot.missing or snapshot.last_error.len != 0) continue;

            var stamp_buffer: [32]u8 = undefined;
            const updated = root_mod.rfc3339Utc(root_mod.nowMs(io), &stamp_buffer);
            const seeded = seed.trySeed(arena, io, base.root_path, canonical, updated) catch |err| {
                std.debug.print("fsmeta daemon: seed from {s} failed for {s} ({s}); falling back to a cold scan\n", .{
                    base.root_path, canonical, @errorName(err),
                });
                return;
            };
            if (seeded) {
                std.debug.print("fsmeta daemon: seeded {s} from {s}\n", .{ canonical, base.root_path });
                return;
            }
        }
    }

    /// A path that the segment rule says is not nested after all: the add is refused rather than guessed at.
    fn refuseGuard(self: *Host, writer: *std.Io.Writer, parent: []const u8, child: []const u8, why: []const u8) !void {
        const message = try std.fmt.allocPrint(
            self.arena,
            "cannot guard {s} inside {s}: {s}/.fs-meta/ignore {s}",
            .{ child, parent, parent, why },
        );
        try refuse(writer, control.Exit.refused, message);
    }

    fn setRootLocked(self: *Host, index: usize, request: control.Request, now: i64, writer: *std.Io.Writer) !void {
        const io = self.io;
        if (request.mode == null and request.idle_timeout_ms == null and request.retention == null and
            request.worktrees == null and request.gitwatch == null)
        {
            try refuse(writer, control.Exit.failure, "root.set needs one of \"mode\", \"idle_timeout_ms\", \"retention\", \"worktrees\" or \"gitwatch\"");
            return;
        }
        const runtime = self.roots.items[index];

        // The record in the registry and the one in the runtime are separate values; both are updated, and the
        // durable copy is written after the mutation so the running behaviour and the file agree.
        const registry_index = self.registry.findById(runtime.record.id) orelse {
            try refuse(writer, control.Exit.failure, "the root list no longer holds this root");
            return;
        };
        if (request.mode) |mode| {
            runtime.setMode(mode, now, control.Budget.mutation) catch {
                try refuseBusy(writer, self.arena, runtime.record.id);
                return;
            };
            self.registry.records.items[registry_index].mode = mode;
        }
        if (request.idle_timeout_ms) |value| {
            runtime.setIdleTimeout(value, now, control.Budget.mutation) catch {
                try refuseBusy(writer, self.arena, runtime.record.id);
                return;
            };
            self.registry.records.items[registry_index].idle_timeout_ms = value;
        }
        if (request.retention) |value| {
            runtime.setRetention(value, control.Budget.mutation) catch {
                try refuseBusy(writer, self.arena, runtime.record.id);
                return;
            };
            self.registry.records.items[registry_index].retention = value;
        }
        // The two switches (`plans/worktrees.md` § 5h, M7). The durable record keeps what was asked; the runtime is
        // handed the **effective** value, so `FSMETA_WORKTREES=0` / `FSMETA_GITWATCH=0` still wins over a live flip
        // and the reply reports what is actually in force rather than what was typed.
        if (request.worktrees) |value| {
            const effective = self.worktrees_override orelse value;
            runtime.setWorktrees(effective, control.Budget.mutation) catch {
                try refuseBusy(writer, self.arena, runtime.record.id);
                return;
            };
            self.registry.records.items[registry_index].worktrees = value;
        }
        if (request.gitwatch) |value| {
            const effective = self.gitwatch_override orelse self.worktrees_override orelse value;
            runtime.setGitwatch(effective, control.Budget.mutation) catch {
                try refuseBusy(writer, self.arena, runtime.record.id);
                return;
            };
            self.registry.records.items[registry_index].gitwatch = value;
        }
        self.registry.save(io) catch {};

        const snapshot = runtime.snapshot(control.Budget.mutation) catch {
            try refuseBusy(writer, self.arena, runtime.record.id);
            return;
        };
        try control.beginOk(writer);
        try writer.writeAll(",\"root\":");
        try writeSnapshot(writer, snapshot);
        try control.finish(writer);
    }

    fn removeRootLocked(self: *Host, index: usize, request: control.Request, writer: *std.Io.Writer) !void {
        const io = self.io;
        const runtime = self.roots.items[index];
        // `--force` does not need the client count, and the removal itself waits without a budget (§ 4b): the
        // caller asked for the root to be gone, so it waits for the work to finish. Without `--force` the count
        // decides, and a root that cannot be read in time is refused rather than guessed about.
        if (!request.force) {
            const snapshot = runtime.snapshot(control.Budget.root_status) catch {
                try refuseBusy(writer, self.arena, runtime.record.id);
                return;
            };
            if (snapshot.clients > 0) {
                const message = try std.fmt.allocPrint(self.arena, "{s} still has {d} subscriber(s); use --force", .{ snapshot.root, snapshot.clients });
                try refuse(writer, control.Exit.refused, message);
                return;
            }
        }

        // The record is the configuration half; the runtime is the serving half. They are written by the same
        // commands and cannot normally disagree, so a missing record means the list was edited underneath a
        // running daemon — remove the runtime, leave the list alone, and say so in the log.
        const registry_index = self.registry.findById(runtime.record.id);
        const record = if (registry_index) |found| self.registry.records.items[found] else registry.Record{
            .id = runtime.record.id,
            .root = runtime.record.root,
            .mode = runtime.record.mode,
            .idle_timeout_ms = runtime.record.idle_timeout_ms,
            .retention = runtime.record.retention,
            .on_remove = runtime.record.on_remove,
            .socket = runtime.record.socket,
            .served_by = runtime.record.served_by,
            .created_at = runtime.record.created_at,
        };
        const removed_id = record.id;
        const removed_root = record.root;

        _ = self.roots.orderedRemove(index);
        runtime.deinit(); // closes the socket, removes the claim and the log
        if (registry_index) |found| self.registry.removeAt(found);

        // A removed child's line is dropped, and every remaining parent's block is rewritten to exactly the
        // descendants still served (a stale line for a path that is gone is harmless, but it should not linger).
        self.reconcileAfterRemove(removed_root);
        self.refreshGuardPaths();

        // `keep` and `delete` are different intents: the history is not the daemon's to delete by default.
        if (record.on_remove == .delete) removeHistory(io, self.arena, removed_root);

        self.registry.save(io) catch |err| {
            std.debug.print("fsmeta daemon: cannot save the root list: {s}\n", .{@errorName(err)});
        };

        try control.beginOk(writer);
        try control.stringField(writer, "removed", removed_id);
        try control.stringField(writer, "root", removed_root);
        try control.stringField(writer, "history", record.on_remove.name());
        try control.finish(writer);
    }

    /// The per-pass hook installed on every `RootRuntime` (`root_mod.Guard`).
    fn guardPass(ctx: *anyopaque, root: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.reconcileRootGuard(root);
    }

    /// Whether a served root owns `path` (`root_mod.Guard.isServed`, M5's hook attribution): a hook line from an
    /// unserved worktree of a repository is an event for every served root of it, while one from a served sibling
    /// belongs to that sibling alone. It reads the same immutable snapshot as the pass callback and takes only its leaf
    /// mutex, because it runs under the discovering root's lock and must never touch `roots_mutex`.
    fn guardServed(ctx: *anyopaque, path: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.guard_mutex.lockUncancelable(self.io);
        const served = self.guard_roots;
        self.guard_mutex.unlock(self.io);
        for (served) |root| {
            if (gitwatch.samePath(root, path)) return true;
        }
        return false;
    }

    /// What a pass does to repair the guard: append a missing managed line for every served root inside `root`.
    ///
    /// **Append-only on purpose.** A full rewrite here could drop a line the control task just wrote, because the
    /// snapshot is refreshed after the add completes; appending an existing line is a no-op, so this is safe even
    /// with a slightly stale list, and it is what repairs a block a person deleted by hand. Removing stale lines is
    /// the startup/`root remove` reconciliation's job, where the exact served set is known.
    fn reconcileRootGuard(self: *Host, root: []const u8) void {
        self.guard_mutex.lockUncancelable(self.io);
        const served = self.guard_roots;
        self.guard_mutex.unlock(self.io);

        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const arena = scratch_state.allocator();
        for (served) |child| {
            if (!paths.isInside(root, child)) continue;
            const relative = nesting.relativePath(arena, root, child) catch continue;
            ignores.appendManaged(arena, self.io, root, relative) catch |err| {
                std.debug.print(
                    "fsmeta daemon: cannot repair the nested-root guard in {s}/.fs-meta/ignore: {s}\n",
                    .{ root, @errorName(err) },
                );
                return;
            };
        }
    }

    /// Startup reconciliation, before any root starts: one exact rewrite per record, from the durable list. A pair
    /// that entered `roots.json` by hand is guarded before its first pass rather than after it. A reconciliation
    /// that cannot allocate is logged and skipped for that root; the per-pass append still repairs it later.
    fn reconcileAllRecords(self: *Host) void {
        for (self.registry.records.items) |record| {
            self.reconcileRecord(record.root) catch |err| {
                std.debug.print(
                    "fsmeta daemon: cannot reconcile the nested-root guard for {s}: {s}\n",
                    .{ record.root, @errorName(err) },
                );
            };
        }
    }

    /// `root remove`: every remaining parent of the removed root is rewritten, which drops the line. A root that
    /// was not a parent is untouched.
    fn reconcileAfterRemove(self: *Host, removed_root: []const u8) void {
        for (self.roots.items) |runtime| {
            const parent = runtime.identity().root;
            if (!paths.isInside(parent, removed_root)) continue;
            self.reconcileRecord(parent) catch |err| {
                std.debug.print(
                    "fsmeta daemon: cannot reconcile the nested-root guard for {s}: {s}\n",
                    .{ parent, @errorName(err) },
                );
            };
        }
    }

    /// Rewrite `parent`'s managed block to exactly the served roots inside it. The registry is the durable list;
    /// `self.roots` is added because a runtime can be live while a hand-edited registry no longer names it.
    fn reconcileRecord(self: *Host, parent: []const u8) !void {
        var descendants: std.ArrayListUnmanaged([]const u8) = .empty;
        defer descendants.deinit(self.arena);
        for (self.registry.records.items) |record| {
            if (!paths.isInside(parent, record.root)) continue;
            if (!containsPath(descendants.items, record.root)) try descendants.append(self.arena, record.root);
        }
        for (self.roots.items) |runtime| {
            const other = runtime.identity().root;
            if (!paths.isInside(parent, other)) continue;
            if (!containsPath(descendants.items, other)) try descendants.append(self.arena, other);
        }
        nesting.reconcileDescendants(self.arena, self.io, parent, descendants.items) catch |err| {
            if (err != error.RootMissing) {
                std.debug.print(
                    "fsmeta daemon: cannot reconcile the nested-root guard in {s}/.fs-meta/ignore: {s}\n",
                    .{ parent, @errorName(err) },
                );
            }
        };
    }

    /// Publish the immutable list a pass reads. Called with `roots_mutex` held; the callback never takes that
    /// mutex, and old arrays stay in the host arena so a reader may hold a slice after this returns.
    fn refreshGuardPaths(self: *Host) void {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer list.deinit(self.arena);
        for (self.roots.items) |runtime| {
            list.append(self.arena, runtime.identity().root) catch return;
        }
        const owned = list.toOwnedSlice(self.arena) catch return;
        self.guard_mutex.lockUncancelable(self.io);
        self.guard_roots = owned;
        self.guard_mutex.unlock(self.io);
    }

    /// The effective `worktrees` flag: the environment override, or the record's own copy, or the configured
    /// default when no root is named. `off` here stops the *handling*; the boundary rule is not a switch.
    pub fn effectiveWorktrees(self: *Host, record: ?registry.Record) bool {
        const base = if (record) |r| r.worktrees else self.registry.defaults.worktrees;
        return self.worktrees_override orelse base;
    }

    /// The effective `gitwatch` flag. `FSMETA_WORKTREES=0` turns it off with everything else; `FSMETA_GITWATCH`
    /// can turn it off on its own but cannot re-enable what the coarser override disabled.
    pub fn effectiveGitwatch(self: *Host, record: ?registry.Record) bool {
        if (self.worktrees_override) |worktrees| {
            if (!worktrees) return false;
        }
        const base = if (record) |r| r.gitwatch else self.registry.defaults.gitwatch;
        return self.gitwatch_override orelse self.worktrees_override orelse base;
    }
};

fn containsPath(paths_list: []const []const u8, wanted: []const u8) bool {
    for (paths_list) |path| {
        if (std.mem.eql(u8, path, wanted)) return true;
    }
    return false;
}

fn refuse(writer: *std.Io.Writer, code: u8, message: []const u8) !void {
    try control.beginError(writer, code, message);
    try control.finish(writer);
}

/// A root whose lock could not be taken within the operation's budget: name it, say why, and carry nothing that
/// would have been a torn read. `FORMAT.daemon.md` § 4b — an expired budget is "not yet available", not a guess.
pub fn writeUnavailable(writer: *std.Io.Writer, id: []const u8, root: []const u8) !void {
    try writer.writeAll("{\"available\":false,\"id\":");
    try control.writeString(writer, id);
    try writer.writeAll(",\"root\":");
    try control.writeString(writer, root);
    try writer.writeAll(",\"reason\":\"busy\"}");
}

/// The refusal a single-root command gets when its budget expires: the same rule, without a `partial` escape.
fn refuseBusy(writer: *std.Io.Writer, allocator: std.mem.Allocator, id_or_path: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "{s} is busy (a pass or a client write holds it); this is not available yet, try again", .{id_or_path});
    try refuse(writer, control.Exit.refused, message);
}

/// One root as JSON. The field names are the ones `FORMAT.daemon.md` documents and the CLI reads.
///
/// `available` is always present, so a caller never has to infer it from a missing field: a full object says
/// `true`, and `writeUnavailable` says `false` and carries nothing else that could be a torn read (§ 4b).
///
/// The first member is written without the leading comma the `field` helpers emit: an object that begins
/// `{,"id"` is not JSON, and a CLI would refuse the whole reply.
pub fn writeSnapshot(writer: *std.Io.Writer, snapshot: root_mod.Snapshot) !void {
    try writer.writeAll("{\"available\":true,\"id\":");
    try control.writeString(writer, snapshot.id);
    try control.stringField(writer, "root", snapshot.root);
    try control.stringField(writer, "mode", snapshot.mode.name());
    try control.stringField(writer, "state", snapshot.phase.name());
    try control.stringField(writer, "reason", snapshot.reason.name());
    try control.intField(writer, "clients", snapshot.clients);
    try control.intField(writer, "idle_timeout_ms", snapshot.idle_timeout_ms);
    try writer.writeAll(",\"retention\":{");
    try writer.print("\"max_batches\":{d},\"max_bytes\":{d}", .{ snapshot.retention.max_batches, snapshot.retention.max_bytes });
    try writer.writeByte('}');
    try control.stringField(writer, "on_remove", snapshot.on_remove.name());
    try control.stringField(writer, "on_worktree", snapshot.on_worktree.name());
    // What git is doing to this root (`plans/worktrees.md` § 5g). Empty / `none` when `gitwatch` is off, because the
    // metadata is then never read — the switch is the promise, not a hint.
    try control.stringField(writer, "head", snapshot.head.text());
    try control.boolField(writer, "detached", snapshot.head.detached);
    try control.stringField(writer, "in_progress", snapshot.in_progress.name());
    // `GIT_EVENT` counters (§ 5d): frames sent to this root's subscribers, and passes a finish waited for.
    try control.intField(writer, "git_events", snapshot.git_events);
    try control.intField(writer, "git_passes", snapshot.git_passes);
    // The root's own switches, so a caller that is not this daemon (`fsmeta daemon hooks install`) can ask whether a
    // hook spool for it would ever be read (`plans/worktrees.md` § 5c).
    try control.boolField(writer, "gitwatch", snapshot.gitwatch);
    try control.boolField(writer, "worktrees", snapshot.worktrees);
    // Where this root sits in its repository (`plans/worktrees.md` § 5g, M7): a linked worktree and the common dir
    // it groups under. Empty/false with `gitwatch` off or outside a repository; host state, never a stored byte.
    try control.boolField(writer, "worktree", snapshot.worktree);
    try control.stringField(writer, "common_dir", snapshot.common_dir);
    try control.stringField(writer, "socket", snapshot.socket);
    try control.stringField(writer, "served_by", snapshot.served_by);
    try control.boolField(writer, "missing", snapshot.missing);
    try control.intField(writer, "head_batch", snapshot.head_batch);
    try control.intField(writer, "passes", snapshot.passes);
    try control.intField(writer, "wakes", snapshot.wakes);
    try control.intField(writer, "rotated_by_bytes", snapshot.rotated_by_bytes);
    try control.intField(writer, "event_passes", snapshot.event_passes);
    try control.intField(writer, "safety_passes", snapshot.safety_passes);
    try control.intField(writer, "last_pass_ms", snapshot.last_pass_ms);
    // `last_pass_ms` is *when*; these four are *what it cost* — duration, names, hashed entries, batch bytes. § 4
    // names them; `last_pass_hashed` is the seed measurement (`plans/worktrees.md` § 5e).
    try control.intField(writer, "last_pass_duration_ms", snapshot.last_pass_duration_ms);
    try control.intField(writer, "last_pass_files", snapshot.last_pass_files);
    try control.intField(writer, "last_pass_hashed", snapshot.last_pass_hashed);
    try control.intField(writer, "last_pass_batch_bytes", snapshot.last_pass_batch_bytes);
    try control.stringField(writer, "last_error", snapshot.last_error);
    try control.stringField(writer, "created_at", snapshot.created_at);
    try writer.writeByte('}');
}

/// `on_remove = delete`: remove the root's generations. The trio's own files are the engine's, and the tree's
/// content is the user's — only `batches/` is the daemon's history to drop.
fn removeHistory(io: std.Io, allocator: std.mem.Allocator, root: []const u8) void {
    _ = allocator;
    var root_dir = if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return
    else
        std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer root_dir.close(io);
    var meta_dir = root_dir.openDir(io, format.directory_name, .{ .iterate = true }) catch return;
    defer meta_dir.close(io);
    meta_dir.deleteTree(io, "batches") catch {};
}

/// The test guard's only value (`FSMETA_GIT_ARM`): `off`/`0`/`false` disarms the metadata watcher. Anything else —
/// including a typo and an empty value — is no guard, because a mistyped variable must not silently change behaviour.
fn testArmDisabled(value: ?[]const u8) bool {
    const text = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "off") or std.ascii.eqlIgnoreCase(text, "false");
}

/// `on`/`off` for a resolved flag, for the log and the status reply.
fn flagText(value: bool) []const u8 {
    return if (value) "on" else "off";
}

/// Parse one of the two emergency env variables. Unrecognised text is no override: a typo must not silently
/// disable a feature, and `FSMETA_WORKTREES=` (empty) means "nothing".
fn parseFlagEnv(value: ?[]const u8) ?bool {
    const text = std.mem.trim(u8, value orelse return null, " \t\r\n");
    if (text.len == 0) return null;
    // Case-insensitive: an environment variable set from a Windows shell is often upper-case.
    if (std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "off") or std.ascii.eqlIgnoreCase(text, "false")) return false;
    if (std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "on") or std.ascii.eqlIgnoreCase(text, "true")) return true;
    return null;
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn sampleSnapshot() root_mod.Snapshot {
    return .{
        .id = "a1b2c3d4",
        .root = "/home/u/app",
        .mode = .auto,
        .phase = .asleep,
        .reason = .idle,
        .clients = 0,
        .idle_timeout_ms = 300_000,
        .retention = .{ .max_batches = 32, .max_bytes = 64 * 1024 * 1024 },
        .on_remove = .keep,
        .on_worktree = .ignore,
        .socket = "/run/user/1000/fsmeta/roots/a1b2c3d4.sock",
        .served_by = "inproc",
        .missing = false,
        .head_batch = 12,
        .passes = 7,
        .wakes = 2,
        .rotated_by_bytes = 1,
        .event_passes = 5,
        .safety_passes = 0,
        .last_pass_ms = 1_700_000_000_000,
        .last_pass_duration_ms = 12,
        .last_pass_files = 4000,
        .last_pass_hashed = 7,
        .last_pass_batch_bytes = 512 * 1024,
        .last_error = "",
        .created_at = "2026-10-26T06:50:00Z",
    };
}

test "a snapshot reply is valid JSON with the documented field names" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try control.beginOk(&out.writer);
    try out.writer.writeAll(",\"root\":");
    try writeSnapshot(&out.writer, sampleSnapshot());
    try control.finish(&out.writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqual(true, object.get("ok").?.bool);
    const root = object.get("root").?.object;
    try testing.expectEqualStrings("a1b2c3d4", root.get("id").?.string);
    try testing.expectEqualStrings("asleep", root.get("state").?.string);
    try testing.expectEqualStrings("auto", root.get("mode").?.string);
    try testing.expectEqualStrings("idle", root.get("reason").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("clients").?.integer);
    try testing.expectEqual(@as(i64, 12), root.get("head_batch").?.integer);
    // A timestamp and a duration, both present: the CLI and a test can tell "when" from "how long".
    try testing.expectEqual(@as(i64, 1_700_000_000_000), root.get("last_pass_ms").?.integer);
    try testing.expectEqual(@as(i64, 12), root.get("last_pass_duration_ms").?.integer);
    try testing.expectEqual(@as(i64, 4000), root.get("last_pass_files").?.integer);
    try testing.expectEqual(@as(i64, 7), root.get("last_pass_hashed").?.integer);
    try testing.expectEqual(@as(i64, 512 * 1024), root.get("last_pass_batch_bytes").?.integer);
    try testing.expectEqual(false, root.get("missing").?.bool);
    try testing.expectEqual(@as(i64, 32), root.get("retention").?.object.get("max_batches").?.integer);
    try testing.expectEqualStrings("keep", root.get("on_remove").?.string);
    try testing.expect(std.mem.endsWith(u8, out.written(), "\n"));
}

test "a roots reply is a JSON array of the same objects" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try control.beginOk(&out.writer);
    try out.writer.writeAll(",\"roots\":[");
    try writeSnapshot(&out.writer, sampleSnapshot());
    var second = sampleSnapshot();
    second.id = "deadbeef";
    second.root = "/home/u/lib";
    try out.writer.writeByte(',');
    try writeSnapshot(&out.writer, second);
    try out.writer.writeByte(']');
    try control.finish(&out.writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const roots = parsed.value.object.get("roots").?.array;
    try testing.expectEqual(@as(usize, 2), roots.items.len);
    try testing.expectEqualStrings("deadbeef", roots.items[1].object.get("id").?.string);
}

test "the environment override resolves the two switches, and a typo is no override" {
    try testing.expectEqual(@as(?bool, null), parseFlagEnv(null));
    try testing.expectEqual(@as(?bool, false), parseFlagEnv("0"));
    try testing.expectEqual(@as(?bool, false), parseFlagEnv("off"));
    try testing.expectEqual(@as(?bool, false), parseFlagEnv(" FALSE "));
    try testing.expectEqual(@as(?bool, true), parseFlagEnv("1"));
    try testing.expectEqual(@as(?bool, true), parseFlagEnv("on"));
    try testing.expectEqual(@as(?bool, true), parseFlagEnv("true"));
    // An unrecognised value must not silently disable a feature; empty means "nothing".
    try testing.expectEqual(@as(?bool, null), parseFlagEnv("maybe"));
    try testing.expectEqual(@as(?bool, null), parseFlagEnv(""));

    var host: Host = .{
        .io = undefined,
        .allocator = testing.allocator,
        .arena_state = undefined,
        .arena = undefined,
        .layout = undefined,
        .registry = registry.Registry.init(testing.allocator, "unused.json"),
    };
    defer host.registry.deinit();
    host.registry.defaults.worktrees = false;
    host.registry.defaults.gitwatch = false;

    try testing.expectEqual(false, host.effectiveWorktrees(null));
    try testing.expectEqual(false, host.effectiveGitwatch(null));

    // `FSMETA_WORKTREES=1` forces both on, whichever the record or defaults say.
    host.worktrees_override = true;
    try testing.expectEqual(true, host.effectiveWorktrees(null));
    try testing.expectEqual(true, host.effectiveGitwatch(null));

    // `FSMETA_GITWATCH=0` narrows it: worktrees stay on, signals stop.
    host.gitwatch_override = false;
    try testing.expectEqual(true, host.effectiveWorktrees(null));
    try testing.expectEqual(false, host.effectiveGitwatch(null));

    // `FSMETA_WORKTREES=0` turns both off, and the finer knob cannot re-enable one.
    host.worktrees_override = false;
    host.gitwatch_override = true;
    try testing.expectEqual(false, host.effectiveWorktrees(null));
    try testing.expectEqual(false, host.effectiveGitwatch(null));
}

test "an unavailable root is named, carries no state, and makes the listing partial" {
    // The § 4b shape: a listing that could not wait for one root is still a valid answer — it says which root it
    // could not read and marks itself partial, rather than blocking or inventing a state for it.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try control.beginOk(&out.writer);
    try control.boolField(&out.writer, "partial", true);
    try out.writer.writeAll(",\"roots\":[");
    try writeUnavailable(&out.writer, "a1b2c3d4", "/home/u/app");
    try out.writer.writeByte(',');
    try writeSnapshot(&out.writer, sampleSnapshot());
    try out.writer.writeByte(']');
    try control.finish(&out.writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(true, root.get("partial").?.bool);
    const entries = root.get("roots").?.array.items;
    try testing.expectEqual(@as(usize, 2), entries.len);

    // The unavailable one: its identity and the reason, and nothing that could have been a torn read.
    const busy = entries[0].object;
    try testing.expectEqual(false, busy.get("available").?.bool);
    try testing.expectEqualStrings("a1b2c3d4", busy.get("id").?.string);
    try testing.expectEqualStrings("/home/u/app", busy.get("root").?.string);
    try testing.expectEqualStrings("busy", busy.get("reason").?.string);
    try testing.expect(busy.get("state") == null);
    try testing.expect(busy.get("head_batch") == null);

    // The available one is a whole snapshot, and says so rather than relying on a missing field.
    try testing.expectEqual(true, entries[1].object.get("available").?.bool);
}
