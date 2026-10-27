// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Claiming a root, and cleaning up after a process that died holding it.
//!
//! The claim is **an OS file lock**, not a pid: `<base>/roots/<id>.pid` is opened and locked exclusively for
//! the lifetime of the serving process, and the kernel releases it when that process ends — whatever the
//! reason. A pid file answers "is this number alive", which is a different question and a dangerous one: pids
//! are reused, and a killed daemon's number can belong to anything by the time the next start reads it. The
//! pid is still *written* into the file, because a person reading `roots/` should see who is serving what; it
//! is a diagnostic, and never the authority.
//!
//! Two things are reaped on start:
//!
//! - a **claim** nobody holds (the process is gone) — and with it the socket it names, because a socket file
//!   left by a killed process is not a peer and would make `bind` fail;
//! - a **socket** with no live listener, which a crash between the two steps above can leave behind.
//!
//! Nothing here touches a root's batches. The data is not the daemon's to delete; `root remove` with
//! `on_remove = delete` is the only path that removes a generation, and it goes through the engine's own
//! rotation.

const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");

/// The current process's id, for the claim file and `daemon.json`.
///
/// It is written for a person reading `roots/`, never consulted to decide whether a process is alive — that
/// is the file lock's job, and pids are reused. `0` means "this platform did not give us one without libc",
/// which is honest and costs nothing that matters.
pub fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => if (builtin.link_libc) @intCast(std.c.getpid()) else 0,
    };
}

/// A held claim on one root. Dropping it (closing the file) releases the lock, which is why this is a value
/// the owner must keep alive for as long as it serves the root.
pub const Claim = struct {
    file: std.Io.File,
    path: []const u8,
    id: []const u8,
};

/// Take the claim on `id`, writing `content` (a pid, a timestamp) into it for diagnostics.
///
/// The error set is inferred: `error.AlreadyClaimed` (the one a caller branches on) plus whatever the open,
/// the lock and the write can raise.
pub fn claim(io: std.Io, allocator: std.mem.Allocator, layout: paths.Layout, id: []const u8, content: []const u8) !Claim {
    const path = try layout.rootClaim(allocator, id);
    errdefer allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);

    // `truncate = false` on purpose: truncating before the lock is acquired would erase a live claim's pid
    // just to discover the lock is held. The length is reset after the lock is ours.
    var file = std.Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.AlreadyClaimed,
        else => return err,
    };
    errdefer file.close(io);

    try file.setLength(io, 0);
    try file.writeStreamingAll(io, content);
    return .{ .file = file, .path = path, .id = id };
}

pub fn release(claim_value: *Claim, io: std.Io) void {
    claim_value.file.close(io); // the kernel drops the lock with the handle
}

/// Whether a claim can be taken right now, without keeping it: `true` means nobody is serving the root.
///
/// **It must not create the file.** An earlier version used `createFile` here, which on a missing claim
/// resurrected the very file `reap` had just removed — the reaper would report "claims removed: 1" and leave
/// one behind. `openFile` with an exclusive lock and `FileNotFound` meaning "free" is the whole answer.
pub fn isFree(io: std.Io, allocator: std.mem.Allocator, layout: paths.Layout, id: []const u8) bool {
    const path = layout.rootClaim(allocator, id) catch return false;
    defer allocator.free(path);
    var file = std.Io.Dir.openFileAbsolute(io, path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return false,
        error.FileNotFound => return true,
        else => return false,
    };
    file.close(io);
    return true;
}

pub const Report = struct {
    claims_removed: u64 = 0,
    sockets_removed: u64 = 0,

    pub fn anything(self: Report) bool {
        return self.claims_removed > 0 or self.sockets_removed > 0;
    }
};

/// Remove what a dead process left in `<base>/roots`, skipping the ids in `keep` (the roots this process is
/// about to serve, whose claims it already holds).
pub fn reap(io: std.Io, allocator: std.mem.Allocator, layout: paths.Layout, keep: []const []const u8) !Report {
    var report: Report = .{};
    var dir = std.Io.Dir.openDirAbsolute(io, try layout.rootsDir(allocator), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return report,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".pid")) continue;
        const id = name[0 .. name.len - ".pid".len];
        if (contains(keep, id)) continue;
        if (!isFree(io, allocator, layout, id)) continue; // a live process owns it

        const claim_path = try layout.rootClaim(allocator, id);
        defer allocator.free(claim_path);
        std.Io.Dir.deleteFileAbsolute(io, claim_path) catch |err| {
            std.debug.print("reap: cannot remove {s}: {s}\n", .{ claim_path, @errorName(err) });
        };
        report.claims_removed += 1;

        const socket_path = try layout.rootSocket(allocator, id);
        defer allocator.free(socket_path);
        if (removeStaleSocket(io, socket_path)) report.sockets_removed += 1;
    }

    // A socket whose claim is already gone: a crash between the claim's removal and the socket's.
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".sock")) continue;
        const id = name[0 .. name.len - ".sock".len];
        if (contains(keep, id)) continue;
        if (!isFree(io, allocator, layout, id)) continue; // still claimed: leave it alone
        const socket_path = try layout.rootSocket(allocator, id);
        defer allocator.free(socket_path);
        if (removeStaleSocket(io, socket_path)) report.sockets_removed += 1;
    }

    return report;
}

/// Whether a daemon holds this base right now.
///
/// The lock file is the authority. A CLI checks it *before* connecting, because on Windows a refused AF_UNIX
/// connect is not a clean error — Zig reports an unmapped NTSTATUS and aborts — so probing a socket left by a
/// dead daemon is not a safe way to ask whether one is running.
pub fn daemonLive(io: std.Io, allocator: std.mem.Allocator, layout: paths.Layout) bool {
    const path = layout.controlLock(allocator) catch return false;
    defer allocator.free(path);
    var file = std.Io.Dir.openFileAbsolute(io, path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return true,
        else => return false,
    };
    file.close(io);
    return false;
}

/// Remove a stale socket file. The caller has already established that no live process claims its root, which
/// is the evidence a listener would otherwise provide — and the only evidence available: probing a dead AF_UNIX
/// address panics on Windows, so a connect is not an option here.
fn removeStaleSocket(io: std.Io, socket_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, socket_path, .{}) catch return false;
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch return false;
    return true;
}

/// Everything the daemon owns for one root, removed together: the socket, the claim and the log.
pub fn removeRootFiles(io: std.Io, allocator: std.mem.Allocator, layout: paths.Layout, id: []const u8) void {
    const socket_path = layout.rootSocket(allocator, id) catch return;
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    const claim_path = layout.rootClaim(allocator, id) catch return;
    defer allocator.free(claim_path);
    std.Io.Dir.deleteFileAbsolute(io, claim_path) catch {};

    const log_path = layout.rootLog(allocator, id) catch return;
    defer allocator.free(log_path);
    std.Io.Dir.deleteFileAbsolute(io, log_path) catch {};
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn scratchLayout(arena: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) !paths.Layout {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try dir.realPath(io, &buffer);
    const base = try std.fmt.allocPrint(arena, "{s}{c}run", .{ buffer[0..count], std.fs.path.sep });
    return .{ .base = base, .config = try std.fmt.allocPrint(arena, "{s}{c}roots.json", .{ buffer[0..count], std.fs.path.sep }) };
}

test "a claim is exclusive: the second taker is refused until the first releases it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout = try scratchLayout(arena, tmp.dir, io);
    var first = try claim(io, arena, layout, "a1b2c3d4", "123");
    try testing.expectError(error.AlreadyClaimed, claim(io, arena, layout, "a1b2c3d4", "456"));
    try testing.expect(!isFree(io, arena, layout, "a1b2c3d4"));

    release(&first, io);
    try testing.expect(isFree(io, arena, layout, "a1b2c3d4"));

    // The claim file holds the diagnostic content, and the same id can be claimed again after the release.
    var second = try claim(io, arena, layout, "a1b2c3d4", "789");
    release(&second, io);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, first.path, arena, std.Io.Limit.limited(64));
    try testing.expectEqualStrings("789", text);
}

test "reaping removes the claim and socket of a dead process, and keeps the live ones" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout = try scratchLayout(arena, tmp.dir, io);

    // A live root: claimed by this process, with a socket file beside it.
    const live_id = "11111111";
    var live_claim = try claim(io, arena, layout, live_id, "1");
    defer release(&live_claim, io);
    const live_socket = try layout.rootSocket(arena, live_id);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = live_socket, .data = "" });

    // A dead root: a claim nobody holds, and a socket nobody listens on.
    const dead_id = "22222222";
    {
        var dead = try claim(io, arena, layout, dead_id, "2");
        release(&dead, io);
    }
    const dead_socket = try layout.rootSocket(arena, dead_id);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dead_socket, .data = "" });

    const keep = [_][]const u8{live_id};
    const report = try reap(io, arena, layout, &keep);

    try testing.expectEqual(@as(u64, 1), report.claims_removed);
    try testing.expectEqual(@as(u64, 1), report.sockets_removed);
    try testing.expect(report.anything());

    // The dead root is gone; the live one still has its claim and socket.
    const dead_claim_path = try layout.rootClaim(arena, dead_id);
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dead_claim_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dead_socket, .{}));
    try std.Io.Dir.accessAbsolute(io, live_socket, .{});
    try testing.expect(!isFree(io, arena, layout, live_id));
}

test "removing a root's files takes the socket, the claim and the log, and nothing else" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout = try scratchLayout(arena, tmp.dir, io);
    const id = "abcdef01";

    var held = try claim(io, arena, layout, id, "9");
    const socket_path = try layout.rootSocket(arena, id);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = socket_path, .data = "" });
    // The daemon creates `<base>/logs` at start; the test creates it here for the same reason.
    try std.Io.Dir.cwd().createDirPath(io, try layout.logsDir(arena));
    const log_path = try layout.rootLog(arena, id);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = "log\n" });

    // A root's batches live in the tree, not in the runtime directory: nothing here may touch them.
    const root_socket = try layout.rootSocket(arena, id);
    try testing.expect(std.mem.indexOf(u8, root_socket, ".fs-meta") == null);

    // The claim must be released before its file is removed: Windows refuses to delete a file that still has
    // an open handle, and the daemon's own shutdown releases first for exactly this reason.
    release(&held, io);
    removeRootFiles(io, arena, layout, id);

    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, socket_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, layout.rootClaim(arena, id) catch unreachable, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, log_path, .{}));
}
