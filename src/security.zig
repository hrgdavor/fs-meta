// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The non-root deployment gate for the serving modes, and the startup hardening that follows it.
//!
//! The daemon watches trees, writes `.fs-meta`, and serves a Unix socket that includes an executable dialect. A bug
//! in any of those paths must stay at the caller's ordinary privilege; it must never become root/Administrator code
//! execution. `plans/non-root-daemon.md` records the full policy and the remaining enforcement work.
//!
//! Two small jobs live here. `ensureUnprivileged()` answers "is this process privileged?" and refuses (N2).
//! `hardenAfterStart()` restricts the process after that gate has passed (N5). The second is **defense in depth,
//! never a privilege drop**: it changes no uid/gid, and it cannot make a privileged start acceptable. Socket modes
//! and peer credentials are separate steps (N3) in the same plan.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Error = error{
    /// The process is uid 0, an elevated Administrator token, or something we cannot prove is unprivileged.
    PrivilegedUser,
    /// The platform query itself failed; serving would be a guess, so refuse.
    CannotDeterminePrivilege,
};

/// Refuse the serving process unless it is an ordinary unprivileged user.
pub fn ensureUnprivileged() Error!void {
    if (try isPrivileged()) return error.PrivilegedUser;
}

/// Whether this process runs with elevated privileges on the host.
///
/// POSIX uses the effective uid. Windows uses the process token's `TokenElevation`; an Administrator running in a
/// filtered token is allowed (that is an ordinary user for this rule), while an elevated token is not. A query
/// failure refuses rather than guessing.
pub fn isPrivileged() Error!bool {
    if (builtin.os.tag == .windows) {
        return windowsIsElevated();
    }
    if (builtin.os.tag == .wasi) {
        return false;
    }
    return std.posix.system.geteuid() == 0;
}

/// A stable, user-facing explanation. The caller prints it and exits; no stack trace is useful here.
pub fn refusalMessage(err: Error) []const u8 {
    return switch (err) {
        error.PrivilegedUser =>
        \\refusing to serve as a privileged user.
        \\
        \\Run fs-meta as your ordinary user, never with sudo, as root, or from an elevated
        \\Administrator/ SYSTEM prompt. The daemon parses project trees and serves a local
        \\socket with an executable dialect; a bug there must not have elevated permissions.
        ,
        error.CannotDeterminePrivilege =>
        \\refusing to serve because this process's privilege level could not be determined.
        \\
        \\Run fs-meta as an ordinary user. A failed privilege query is not treated as proof of
        \\safety; see plans/non-root-daemon.md.
        ,
    };
}

// ---------------------------------------------------------------------------------------------------------------
// Windows: TokenElevation. Zig's std exposes the pseudo-handle and CloseHandle but not the token query, so the two
// advapi32 entry points are declared here (the system library is linked by the Windows build).
// ---------------------------------------------------------------------------------------------------------------

const TOKEN_QUERY: windows.DWORD = 0x0008;
const TOKEN_ELEVATION_CLASS: windows.DWORD = 20;
const TOKEN_USER_CLASS: windows.DWORD = 1;
const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: windows.DWORD,
};
const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};
const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: windows.DWORD,
};
const SID = extern struct {
    Revision: u8,
    SubAuthorityCount: u8,
    IdentifierAuthority: [6]u8,
    SubAuthority: [1]windows.DWORD,
};

extern "advapi32" fn OpenProcessToken(
    process: windows.HANDLE,
    desired_access: windows.DWORD,
    token: *windows.HANDLE,
) callconv(.winapi) i32;

extern "advapi32" fn GetTokenInformation(
    token: windows.HANDLE,
    information_class: windows.DWORD,
    information: ?*anyopaque,
    information_length: windows.DWORD,
    return_length: *windows.DWORD,
) callconv(.winapi) i32;

fn windowsIsElevated() Error!bool {
    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(windows.current_process, TOKEN_QUERY, &token) == 0) {
        return error.CannotDeterminePrivilege;
    }
    defer windows.CloseHandle(token);

    var elevation: TOKEN_ELEVATION = undefined;
    var returned: windows.DWORD = 0;
    if (GetTokenInformation(
        token,
        TOKEN_ELEVATION_CLASS,
        @ptrCast(&elevation),
        @sizeOf(TOKEN_ELEVATION),
        &returned,
    ) == 0) {
        return error.CannotDeterminePrivilege;
    }
    if (elevation.TokenIsElevated != 0) return true;

    // A SYSTEM / LocalService / NetworkService token is not an ordinary user even when its elevation bit is clear.
    // Reject it explicitly rather than relying on TokenElevation to cover every service configuration.
    return windowsIsServiceSid(token);
}

fn windowsIsServiceSid(token: windows.HANDLE) Error!bool {
    var buffer: [256]u8 align(@alignOf(TOKEN_USER)) = undefined;
    var returned: windows.DWORD = 0;
    if (GetTokenInformation(
        token,
        TOKEN_USER_CLASS,
        &buffer,
        buffer.len,
        &returned,
    ) == 0) {
        return error.CannotDeterminePrivilege;
    }

    const user: *const TOKEN_USER = @ptrCast(&buffer);
    const raw = user.User.Sid orelse return error.CannotDeterminePrivilege;
    const sid: *align(1) const SID = @ptrCast(raw);
    if (sid.Revision != 1 or sid.SubAuthorityCount != 1) return false;

    // S-1-5-18 (LocalSystem), S-1-5-19 (LocalService), S-1-5-20 (NetworkService): NT authority (5), one sub-authority.
    const authority = sid.IdentifierAuthority;
    for (authority[0..5]) |byte| {
        if (byte != 0) return false;
    }
    if (authority[5] != 5) return false;
    return switch (sid.SubAuthority[0]) {
        18, 19, 20 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------------------------------------------
// N5: startup hardening (`plans/non-root-daemon.md` § 4B).
//
// Every call here is a restriction an ordinary user may apply to itself. There is deliberately no setuid/setgid
// dance and no capability *raise*: the plan prefers starting unprivileged, and a half-applied drop is worse than
// none. `ensureUnprivileged()` still runs first and remains the actual gate.
//
// Supplementary groups are not dropped: `setgroups(2)` requires CAP_SETGID, so an unprivileged process cannot do
// it, and swallowing the failure would be theater. Capabilities are touched only where an ordinary user may do so
// (the Linux ambient set); `no_new_privs` is what stops a later `execve` from gaining new ones.
// ---------------------------------------------------------------------------------------------------------------

/// Owner-only: a requested file mode keeps at most `0600`, a directory at most `0700`.
pub const RESTRICTIVE_UMASK: u32 = 0o077;

pub const HardeningError = error{
    /// Linux refused `PR_SET_NO_NEW_PRIVS`, or reading it back did not show it set.
    NoNewPrivileges,
};

/// Restrict this process after `ensureUnprivileged()` has passed, before the daemon starts watching or `serve`
/// starts its socket.
///
/// Per platform:
/// - **Linux (real):** `PR_SET_NO_NEW_PRIVS` is set and read back, the ambient capability set is cleared, and the
///   umask becomes `RESTRICTIVE_UMASK`. `no_new_privs` is kernel-enforced and inherited across `execve`, so a
///   set-uid binary, file capabilities or an LSM cannot raise privilege when the daemon later spawns a git hook or
///   the `{{` executable dialect. A refusal means the kernel would not take it, and the caller must not continue.
/// - **macOS / BSD (partial):** only the umask. There is no portable `no_new_privs`: macOS has no equivalent,
///   FreeBSD's Capsicum would confine the daemon's own sockets and spawned hooks as well, and OpenBSD's `pledge`
///   needs a program-specific promise set that has not been designed. That is a documented gap, not a silent pass;
///   the unprivileged start remains the control.
/// - **Windows (partial):** there is no `no_new_privs` equivalent for this process, and no umask; the socket DACL
///   is the N3 control. The extension-point mitigation policy (AppInit DLLs, IMEs, non-Microsoft hooks) is applied
///   best effort; older builds that reject the policy keep running, because the elevated-token/service-SID refusal
///   of N2 is the actual gate. A restricted token or job object is not applied: that needs a re-exec or a
///   privileged token operation.
///
/// Safe to call more than once. The precondition is `ensureUnprivileged()`: this function never checks or changes
/// the process identity, so it must not be used on its own to justify serving.
pub fn hardenAfterStart() HardeningError!void {
    setRestrictiveUmask();
    if (builtin.os.tag == .linux) {
        try setNoNewPrivileges();
        clearAmbientCapabilities();
    } else if (builtin.os.tag == .windows) {
        disableWindowsExtensionPoints();
    }
}

/// The mode a requested file or directory mode keeps after `RESTRICTIVE_UMASK`. Pure, so the policy is testable
/// without creating a file or changing the test process's umask.
fn modeAfterRestrictiveUmask(mode: u32) u32 {
    return mode & ~RESTRICTIVE_UMASK;
}

/// A stable, user-facing explanation for a hardening refusal. The caller prints it and exits: the process is not
/// safe to serve without the protection it asked for.
pub fn hardeningMessage(err: HardeningError) []const u8 {
    return switch (err) {
        error.NoNewPrivileges =>
        \\refusing to serve because the process could not be hardened.
        \\
        \\The kernel refused PR_SET_NO_NEW_PRIVS, or did not report it as set. Without it, a
        \\child spawned later (a git hook, or the {{ executable dialect) could regain
        \\privileges through a set-uid binary or file capabilities. Run fs-meta as an ordinary
        \\user on a Linux kernel that supports no_new_privs (3.5 or later); see
        \\plans/non-root-daemon.md.
        ,
    };
}

fn setRestrictiveUmask() void {
    if (builtin.os.tag == .linux) {
        // Zig 0.17 has no std.posix.umask; the raw syscall keeps the Linux build libc-independent.
        _ = std.os.linux.syscall1(.umask, RESTRICTIVE_UMASK);
        return;
    }
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    // macOS and the BSDs reach umask(2) through libc, which those targets link anyway. Without libc there is no
    // portable call and the gap above is the honest answer rather than faking one.
    if (builtin.link_libc) {
        _ = std.c.umask(@intCast(RESTRICTIVE_UMASK));
    }
}

fn setNoNewPrivileges() HardeningError!void {
    _ = std.posix.prctl(.SET_NO_NEW_PRIVS, .{ 1, 0, 0, 0 }) catch return error.NoNewPrivileges;
    // A drop is verified, not assumed: read the flag back rather than trusting the set call.
    const current = std.posix.prctl(.GET_NO_NEW_PRIVS, .{ 0, 0, 0, 0 }) catch return error.NoNewPrivileges;
    if (current != 1) return error.NoNewPrivileges;
}

fn clearAmbientCapabilities() void {
    // Best effort: kernels before 4.3 have no ambient set and answer EINVAL. `no_new_privs` already prevents
    // gaining capabilities across execve; this keeps an ambient set the daemon was started with from being
    // inherited by the children it spawns.
    const linux = std.os.linux;
    _ = linux.prctl(
        @backingInt(linux.PR.CAP_AMBIENT),
        linux.PR.CAP_AMBIENT_CLEAR_ALL,
        0,
        0,
        0,
    );
}

// Windows: `PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY` is one DWORD of flags whose bit 0 is
// DisableExtensionPoints. Best effort by design: the policy exists only on Windows 10 1709+, and the actual
// privilege gate is N2's token check.
const PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY_CLASS: windows.DWORD = 6;
const PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY = extern struct {
    Flags: windows.DWORD,
};

extern "kernel32" fn SetProcessMitigationPolicy(
    mitigation_policy: windows.DWORD,
    buffer: *anyopaque,
    buffer_length: usize,
) callconv(.winapi) i32;

fn disableWindowsExtensionPoints() void {
    var policy = PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY{ .Flags = 1 };
    _ = SetProcessMitigationPolicy(
        PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY_CLASS,
        @ptrCast(&policy),
        @sizeOf(PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY),
    );
}

test "a non-zero uid is not the root uid" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    // The pure predicate is deliberately separated from the live query, so this test never needs to be root.
    try std.testing.expect(!isRootUid(1000));
    try std.testing.expect(isRootUid(0));
}

fn isRootUid(uid: u32) bool {
    return uid == 0;
}

test "the restrictive umask leaves files 0600 and directories 0700" {
    // Pure policy, no umask(2) call: the test runner's own umask must stay untouched and this must not need root.
    try std.testing.expectEqual(@as(u32, 0o600), modeAfterRestrictiveUmask(0o666));
    try std.testing.expectEqual(@as(u32, 0o700), modeAfterRestrictiveUmask(0o777));
    try std.testing.expectEqual(@as(u32, 0o600), modeAfterRestrictiveUmask(0o644));
    try std.testing.expectEqual(@as(u32, 0o000), modeAfterRestrictiveUmask(0o070));
    // A group/other bit cannot survive any requested mode.
    var requested: u32 = 0;
    while (requested < 0o1000) : (requested += 1) {
        try std.testing.expectEqual(@as(u32, 0), modeAfterRestrictiveUmask(requested) & 0o077);
    }
}
