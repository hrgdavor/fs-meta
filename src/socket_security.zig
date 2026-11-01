// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Owner-only sockets and peer identity: **N3** of [`plans/non-root-daemon.md`](../plans/non-root-daemon.md) § 4C.
//!
//! A local socket is not a trust boundary. Every local user who can reach the socket is a client — and the
//! protocol has an executable dialect (`{{`, gated off by default by N4), so "can reach the socket" must not mean
//! "can ask a process to run a child". N3 therefore puts two independent controls in front of the protocol:
//!
//! 1. **Ownership.** The daemon's socket directory is created `0700` (`ensurePrivateDir`, used by the daemon's
//!    runtime directory) and, in both serving modes, the socket itself is narrowed to `0600` right after `bind`,
//!    before anything is accepted. A different user can then neither traverse the daemon's directory nor write to
//!    the socket, so the kernel refuses the connection and the server never sees the peer.
//! 2. **Peer identity.** On a platform that can answer *who is on the other end*, the accepted connection is
//!    compared against this process's own uid/gid and refused when it differs. This is the control that still
//!    holds where the socket's directory is not ours: `serve`'s socket lives in `<root>/.fs-meta`, and a root may
//!    be a shared checkout whose `.fs-meta` N6 created `0700` but did not own for us.
//!
//! ## What each platform enforces, stated so nobody assumes more
//!
//! | platform            | modes (`0700`/`0600`) | peer credentials             |
//! | ------------------- | --------------------- | ---------------------------- |
//! | Linux               | yes                   | `SO_PEERCRED` (`struct ucred`) |
//! | macOS/BSD/DragonFly | yes                   | `getpeereid(2)`              |
//! | Windows             | **no**                | **no** — see below           |
//! | WASI                | **no**                | **no**                       |
//!
//! **Windows is a documented gap, not a checked case.** Windows has no POSIX mode bits, and Zig 0.17's `std`
//! exposes neither a DACL surface nor any way to ask an `AF_UNIX` socket for its peer's SID (`SO_PEERCRED` is a
//! Linux mechanism; Windows `AF_UNIX` has no equivalent query). The daemon's runtime directory is
//! `%LOCALAPPDATA%\fsmeta\run`, which inherits the per-user profile ACL, so a second standard user cannot reach
//! the control socket there — that is an inherited property of where the directory lives, **not** a restriction
//! this code applies, and it does not hold for an explicit `--base` outside the profile. The `{{` dialect is off
//! by default (`fsmeta serve --allow-exec` opts in), the N2 non-elevated refusal is unchanged, and writing a
//! hand-rolled DACL is deliberately left to a later step: a DACL that is built wrong is worse than a documented
//! absence, and this file must not be the one place in the tree that gets Windows security descriptors subtly
//! wrong.
//!
//! ## Not attempted here
//!
//! `umask(2)` is process-global and `std.posix` has no portable wrapper for it in 0.17 (the Linux build links no
//! libc), so modes are set explicitly instead — `createDirPathStatus` with the mode, and `fchmodat` on the socket
//! immediately after `bind`. The residual window is between `bind` and the `chmod`; it is closed by the socket
//! living in a `0700` directory (the daemon) or by being a few microseconds in a process that has not started
//! accepting yet (`serve`). The socket file is narrowed *before* the accept loop starts, which is the property
//! that matters.

const std = @import("std");
const builtin = @import("builtin");

/// The mode of a socket's containing directory: owner-only.
pub const private_dir_mode: u32 = 0o700;

/// The mode of the socket itself: the owner may read and write it (that is what `connect` needs), nobody else.
pub const private_socket_mode: u32 = 0o600;

/// Whether this build can set a POSIX mode. Windows and WASI cannot, and pretending otherwise would be the one
/// thing this module must not do.
pub const has_posix_modes = builtin.os.tag != .windows and builtin.os.tag != .wasi;

const private_dir_permissions: std.Io.File.Permissions = if (has_posix_modes)
    @enumFromInt(private_dir_mode)
else
    .default_dir;

const private_socket_permissions: std.Io.File.Permissions = if (has_posix_modes)
    @enumFromInt(private_socket_mode)
else
    .default_file;

// --------------------------------------------------------------------------------------------- directories

/// Create `absolute_path` (and its missing parents) as an owner-only directory.
///
/// The mode is passed to `createDirPathStatus`, so a directory this call creates never exists with a wider mode
/// even for an instant — `umask` is not needed for that. A directory that already exists (an operator's `mkdir`,
/// or a directory an older release left at `0755`) is narrowed afterwards: an existing runtime directory is
/// exactly the case a "create with the right mode" call would otherwise silently accept.
pub fn ensurePrivateDir(io: std.Io, absolute_path: []const u8) !void {
    if (comptime !has_posix_modes) {
        // Windows: no mode to set, and the DACL gap is stated in the module comment.
        try std.Io.Dir.cwd().createDirPath(io, absolute_path);
        return;
    }
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, absolute_path, private_dir_permissions);
    try chmodAbsolute(io, absolute_path, private_dir_permissions);
}

/// Narrow an already-bound socket to `0600`. Called after `bind` and before the first `accept`.
///
/// A failure is returned rather than ignored: a socket this process cannot narrow is a socket it must not serve,
/// because the mode is the whole control on a platform without peer credentials.
pub fn restrictSocketFile(io: std.Io, absolute_path: []const u8) !void {
    if (comptime !has_posix_modes) return; // documented gap (module comment); nothing to set
    try chmodAbsolute(io, absolute_path, private_socket_permissions);
}

/// `chmod` by absolute path: the containing directory is opened once and the last component is narrowed, which
/// is what `fchmodat` needs and what keeps this independent of the process's directory.
fn chmodAbsolute(io: std.Io, absolute_path: []const u8, permissions: std.Io.File.Permissions) !void {
    const dir_path = std.fs.path.dirname(absolute_path) orelse ".";
    const name = std.fs.path.basename(absolute_path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    try dir.setFilePermissions(io, name, permissions, .{});
}

// --------------------------------------------------------------------------------------------- peers

/// One end's kernel-reported identity. The fields are the platform's, not a normalised invention: `uid`/`gid` are
/// the effective ids the peer had when it connected (`SO_PEERCRED` on Linux, `getpeereid(2)` elsewhere).
pub const Peer = struct {
    uid: u32,
    gid: u32,
};

/// The answer to "may this connection be served?".
///
/// `unavailable` is not `same_user`: a platform that cannot report credentials hands the decision entirely to
/// the socket mode, and the caller must be able to say so. Turning the gap into a pass would hide it; turning it
/// into a refusal would make the server unusable on Windows.
pub const PeerAuthentication = enum {
    same_user,
    other_user,
    unavailable,
};

/// Whether a peer's identity is this process's own. The uid is the boundary — a different uid has different
/// files — and the gid is checked too, as `plans/non-root-daemon.md` § 4C asks: a peer that shares the uid but
/// runs in another group is refused rather than assumed equivalent, and the client's fix (run it with the
/// server's group) is explicit rather than silent.
pub fn sameCredentials(ours: Peer, theirs: Peer) bool {
    return ours.uid == theirs.uid and ours.gid == theirs.gid;
}

/// This process's effective uid/gid, or `null` where the platform has no such notion.
pub fn ownPeer() ?Peer {
    return switch (comptime builtin.os.tag) {
        // Zig 0.17's `std.posix` does not re-export the ids, so each platform's own accessor is used: the Linux
        // build links no libc, and `std.os.linux` answers with a syscall.
        .linux => .{ .uid = @intCast(std.os.linux.geteuid()), .gid = @intCast(std.os.linux.getegid()) },
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => .{
            .uid = @intCast(std.c.geteuid()),
            .gid = @intCast(std.c.getegid()),
        },
        else => null,
    };
}

/// Ask the kernel who is on the other end of `stream` and compare it with this process.
///
/// A query that fails is `unavailable`, never `same_user`: a refused syscall is not evidence of a friend.
pub fn peerAuthentication(stream: std.Io.net.Stream) PeerAuthentication {
    const theirs = kernelPeer(stream) orelse return .unavailable;
    const ours = ownPeer() orelse return .unavailable;
    return if (sameCredentials(ours, theirs)) .same_user else .other_user;
}

/// The kernel's answer for `stream`, or `null` when this platform cannot answer or the query failed.
///
/// Linux reads `struct ucred` through `SO_PEERCRED`; macOS and the BSDs (including DragonFly) call
/// `getpeereid(2)`. Anything else — Windows, WASI — returns `null`, which the module comment documents as a gap.
fn kernelPeer(stream: std.Io.net.Stream) ?Peer {
    switch (comptime builtin.os.tag) {
        .linux => {
            // The Linux ABI's `struct ucred`: three 32-bit words, no padding at this size. It is `extern` so the
            // kernel fills exactly this layout, and the socklen check below refuses a shorter answer than the
            // three fields it has to fill.
            const Ucred = extern struct {
                pid: i32,
                uid: u32,
                gid: u32,
            };
            var cred: Ucred = undefined;
            var length: u32 = @sizeOf(Ucred);
            const rc = std.os.linux.getsockopt(
                stream.socket.handle,
                std.os.linux.SOL.SOCKET,
                std.os.linux.SO.PEERCRED,
                @ptrCast(&cred),
                &length,
            );
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                else => return null,
            }
            if (length < @sizeOf(Ucred)) return null;
            return .{ .uid = cred.uid, .gid = cred.gid };
        },
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            var uid: std.posix.uid_t = 0;
            var gid: std.posix.gid_t = 0;
            if (getpeereid(stream.socket.handle, &uid, &gid) != 0) return null;
            return .{ .uid = @intCast(uid), .gid = @intCast(gid) };
        },
        else => return null,
    }
}

/// `getpeereid(2)`. `std.c` does not declare it in 0.17, so it is declared here; every platform that reaches
/// this declaration ships it in libc.
extern "c" fn getpeereid(sockfd: std.posix.fd_t, euid: *std.posix.uid_t, egid: *std.posix.gid_t) c_int;

/// The detail a refused peer is told, in `FORMAT.socket.md`'s `<code>: <detail>` shape. One definition, so
/// `serve` and the daemon refuse in the same words.
pub const refusal_detail = "refused a peer that is not the serving user";

// --------------------------------------------------------------------------------------------- tests

test "a peer is this user only when it shares the uid and the gid" {
    const ours: Peer = .{ .uid = 1000, .gid = 1000 };
    try std.testing.expect(sameCredentials(ours, .{ .uid = 1000, .gid = 1000 }));
    try std.testing.expect(!sameCredentials(ours, .{ .uid = 1001, .gid = 1000 }));
    try std.testing.expect(!sameCredentials(ours, .{ .uid = 1000, .gid = 1001 }));
    // uid 0 is not special-cased here: N2 refuses to serve as uid 0 at all, so a root peer is unreachable.
    try std.testing.expect(!sameCredentials(ours, .{ .uid = 0, .gid = 0 }));
}

test "the process's own peer is the identity the kernel reports for its own socket" {
    if (!has_posix_modes) return error.SkipZigTest; // the Windows gap is documented in the module comment

    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var created = std.testing.tmpDir(.{});
    defer created.cleanup();
    // A socket's address must be absolute, and the test's temporary directory is relative to the build root.
    // `std.fs.path.resolve` does not prepend the current directory in Zig 0.17, so resolve through the file
    // system instead of joining by hand.
    const created_rel = try std.fs.path.join(arena, &.{ ".zig-cache/tmp", &created.sub_path });
    const created_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, created_rel, arena);
    const socket_path = try std.fs.path.join(arena, &.{ created_abs, "socket" });

    const address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    // The mode is the first control: narrow the socket before anything is accepted, then read it back.
    try restrictSocketFile(io, socket_path);
    const stat = try created.dir.statFile(io, "socket", .{});
    try std.testing.expectEqual(@as(u32, private_socket_mode), @intFromEnum(stat.permissions));

    // A connection from this process is this process's own identity — what the kernel says, not what we assume.
    const client = try address.connect(io);
    defer client.close(io);
    const server_side = try listener.accept(io);
    defer server_side.close(io);

    // `same_user` already means the kernel's answer for this connection equals `ownPeer()`; the point of the
    // assertion is that the syscall ran and agreed, not that a particular uid is in the test's source.
    try std.testing.expectEqual(PeerAuthentication.same_user, peerAuthentication(server_side));
    try std.testing.expect(ownPeer() != null);
}

test "a private directory is created 0700 and an existing wider one is narrowed" {
    if (!has_posix_modes) return error.SkipZigTest;

    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `ensurePrivateDir` takes an absolute path, and a test's temporary directory is relative to the build
    // root (`std.fs.path.resolve` does not prepend the current directory in Zig 0.17). The directory that is
    // created does not exist yet, so its parent is what gets resolved.
    const tmp_rel = try std.fs.path.join(arena, &.{ ".zig-cache/tmp", &tmp.sub_path });
    const tmp_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_rel, arena);
    const relative = try std.fs.path.join(arena, &.{ tmp_abs, "run" });
    try ensurePrivateDir(io, relative);
    const parent_abs = std.fs.path.dirname(relative).?;
    const name = std.fs.path.basename(relative);
    var parent = try std.Io.Dir.openDirAbsolute(io, parent_abs, .{});
    defer parent.close(io);
    const ours = try parent.statFile(io, name, .{});
    try std.testing.expectEqual(@as(u32, private_dir_mode), @intFromEnum(ours.permissions));

    // An operator's `0755` directory (an older release, a hand-made runtime dir) is narrowed, not accepted.
    if (std.posix.mode_t != u0) {
        try parent.setFilePermissions(io, name, @enumFromInt(0o755), .{});
        try ensurePrivateDir(io, relative);
        const narrowed = try parent.statFile(io, name, .{});
        try std.testing.expectEqual(@as(u32, private_dir_mode), @intFromEnum(narrowed.permissions));
    }
}
