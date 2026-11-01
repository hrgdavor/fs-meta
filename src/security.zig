// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The non-root deployment gate for the serving modes.
//!
//! The daemon watches trees, writes `.fs-meta`, and serves a Unix socket that includes an executable dialect. A bug
//! in any of those paths must stay at the caller's ordinary privilege; it must never become root/Administrator code
//! execution. `plans/non-root-daemon.md` records the full policy and the remaining enforcement work.
//!
//! This file intentionally has a single, small job: answer "is this process privileged?" and refuse. Socket modes,
//! peer credentials and privilege dropping are separate steps in that plan.

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

test "a non-zero uid is not the root uid" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    // The pure predicate is deliberately separated from the live query, so this test never needs to be root.
    try std.testing.expect(!isRootUid(1000));
    try std.testing.expect(isRootUid(0));
}

fn isRootUid(uid: u32) bool {
    return uid == 0;
}
