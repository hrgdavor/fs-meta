// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! N6 (`plans/non-root-daemon.md` § 4E): create and write the state directory through directory handles, never
//! through a link.
//!
//! Two operations live here, because both guard the same boundary — the `.fs-meta` handle the engine holds:
//!
//! 1. **`openOrCreateDirectory` never follows a link.** It classifies the final component with
//!    `statFile(.follow_symlinks = false)`, opens it with `OpenOptions.follow_symlinks = false`, and then verifies
//!    the opened handle's *own* kind. On POSIX the open is `O_NOFOLLOW | O_DIRECTORY`, so the kernel refuses a
//!    symlink; on Windows it is `OPEN_REPARSE_POINT`, and the post-open stat is what refuses a junction or any
//!    other reparse point that `NtCreateFile` may have opened as a directory.
//! 2. **`createExclusiveFile` never truncates through a link.** Publication uses well-known temporary names
//!    (`files.meta.tmp`, ...). An entry already at that name is removed *as an entry* (unlinkat / a
//!    reparse-point-aware delete, never a follow) and the file is created `O_EXCL` / `FILE_CREATE`, so a planted
//!    symlink or junction cannot redirect the bytes. A stale temporary file left by a crash is still replaced.
//!
//! ## What this does not cover, stated once
//!
//! * POSIX relies on `O_NOFOLLOW` for the final component. A bind mount, or a directory reached through a *parent*
//!   symlink, is not detected here — but the parent is the root handle the caller resolved once, and only the
//!   final `.fs-meta` component is opened relative to it. Haiku is the one POSIX target where Zig 0.17's
//!   `dirOpenDirHaiku` ignores `follow_symlinks`; the post-open stat cannot distinguish a followed link from a
//!   real directory there, so Haiku keeps the old behaviour until a platform-specific open is added.
//! * Windows may refuse a directory symlink in `NtCreateFile` with `NOT_A_DIRECTORY` before the handle can be
//!   inspected. That is still a refusal; only the error is `MetaDirNotDirectory` instead of `MetaDirSymlink`.
//! * Owner-only modes are POSIX-only: `0700` for a directory this module creates and `0600` for a file it creates
//!   when there is no existing file to inherit a mode from. Windows has no mode bits; a new object inherits the
//!   ACL of its parent, which is that platform's ownership mechanism. An existing trio file keeps its mode, so a
//!   reader that could read the previous generation can still read the next one.
//! * A symlink at a *final* trio name is not followed by a write: the rename replaces the entry. The files at
//!   those names are read with the ordinary reader path, which does follow a link; that is a read-side concern,
//!   not a write redirection, and is not changed here.

const std = @import("std");
const builtin = @import("builtin");

/// `.fs-meta` exists but is a symbolic link, a directory junction, or another reparse point. Refused: opening it
/// would let the tree choose where its state (and every later write) lives.
pub const Error = error{
    MetaDirSymlink,
    MetaDirNotDirectory,
};

/// The mode a state directory gets when this module creates it. Ignored on Windows (see the module comment).
pub const owner_only_dir: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_dir
else
    .fromMode(0o700);

/// The mode a data file gets when this module creates it and there is no existing file whose mode should survive.
pub const owner_only_file: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    .fromMode(0o600);

pub const OpenOptions = struct {
    /// Iteration is needed by the engine (`readTrio`, the directory fsync) and is harmless elsewhere.
    iterate: bool = true,
    /// Used only when this call creates the directory; an existing directory is never chmod-ed.
    permissions: std.Io.File.Permissions = owner_only_dir,
};

/// Open `sub_path` below `parent` as a directory, creating it when it is genuinely absent.
///
/// The path is always one component relative to a handle; no absolute path is built here. A missing entry is
/// created with `permissions` (`0700` on POSIX when the default is used). An entry that exists but is a link, a
/// reparse point or a non-directory is refused with `Error.MetaDirSymlink` / `Error.MetaDirNotDirectory`; it is
/// never opened through, so the caller cannot be redirected to another tree.
pub fn openOrCreateDirectory(
    io: std.Io,
    parent: std.Io.Dir,
    sub_path: []const u8,
    options: OpenOptions,
) !std.Io.Dir {
    const open_options: std.Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .iterate = options.iterate,
        .follow_symlinks = false,
    };

    // Classify first. This is not the security boundary (the no-follow open below is), but it gives a link its
    // own error on Windows, where `NtCreateFile` can report NOT_A_DIRECTORY for a directory symlink before the
    // opened handle can be inspected.
    if (parent.statFile(io, sub_path, .{ .follow_symlinks = false })) |stat| {
        switch (stat.kind) {
            .directory => {},
            .sym_link, .unknown => return error.MetaDirSymlink,
            else => return error.MetaDirNotDirectory,
        }
    } else |err| switch (err) {
        error.FileNotFound => {
            // `createDirPathStatus` is one component here. If a link appeared after the failed stat, its own
            // no-follow kind check refuses it with NotDir instead of creating through it.
            _ = parent.createDirPathStatus(io, sub_path, options.permissions) catch |create_err| switch (create_err) {
                error.NotDir => return error.MetaDirNotDirectory,
                else => return create_err,
            };
        },
        else => return err,
    }

    const dir = parent.openDir(io, sub_path, open_options) catch |err| switch (err) {
        // POSIX `O_NOFOLLOW` reports a symlink as ELOOP.
        error.SymLinkLoop => return error.MetaDirSymlink,
        // A file, a device, or (on Windows) a symlink the kernel refused before the open.
        error.NotDir => return error.MetaDirNotDirectory,
        else => return err,
    };
    errdefer dir.close(io);

    // The authoritative check on Windows: `OPEN_REPARSE_POINT` can hand back the link object itself, and a
    // junction does not need `SeCreateSymbolicLinkPrivilege` to exist. On POSIX this is a directory by
    // construction (`O_DIRECTORY`), so the check is a cheap invariant.
    const opened = try dir.stat(io);
    if (opened.kind != .directory) {
        return switch (opened.kind) {
            .sym_link, .unknown => error.MetaDirSymlink,
            else => error.MetaDirNotDirectory,
        };
    }
    return dir;
}

/// Open an existing `sub_path` below `parent` as a directory, without following a link.
///
/// Unlike `openOrCreateDirectory`, this never creates anything: `null` means the entry is genuinely absent, which
/// lets a reader or a rotation preserve its own "missing archive" behaviour instead of fabricating an empty one.
/// The no-follow and post-open kind checks are the same as the creating form.
pub fn openExistingDirectory(
    io: std.Io,
    parent: std.Io.Dir,
    sub_path: []const u8,
    options: OpenOptions,
) !?std.Io.Dir {
    const dir = parent.openDir(io, sub_path, .{
        .access_sub_paths = true,
        .iterate = options.iterate,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop => return error.MetaDirSymlink,
        error.NotDir => return error.MetaDirNotDirectory,
        else => return err,
    };
    errdefer dir.close(io);

    const opened = try dir.stat(io);
    if (opened.kind != .directory) {
        return switch (opened.kind) {
            .sym_link, .unknown => error.MetaDirSymlink,
            else => error.MetaDirNotDirectory,
        };
    }
    return dir;
}

/// The mode for a new temporary file that will be renamed over `final_name`.
///
/// Creating owner-only is the default, but an existing regular file keeps its mode so that tightening the writer
/// does not silently make an already-published trio unreadable to a reader that is not the daemon's user. A link
/// or a directory at the destination has no mode worth inheriting (it is replaced by the rename), so those get
/// `owner_only_file`. A failed stat is also treated as "new": tightening is the safe direction.
pub fn filePermissionsFor(io: std.Io, dir: std.Io.Dir, final_name: []const u8) std.Io.File.Permissions {
    const stat = dir.statFile(io, final_name, .{ .follow_symlinks = false }) catch return owner_only_file;
    if (stat.kind != .file) return owner_only_file;
    return stat.permissions;
}

/// Create `name` below `dir` as a brand-new file, without following anything already at that name.
///
/// A stale entry (a crash between the write and the rename) is removed first. The removal is an unlink of the
/// entry itself, never of its target; on Windows it opens with `OPEN_REPARSE_POINT`, and a directory-shaped link
/// is removed with `deleteDir`, which unlinks the junction instead of deleting into it. The create is then
/// `O_EXCL`/`FILE_CREATE`: if a second writer — or an attacker — recreates the name in that window, this fails
/// with `error.PathAlreadyExists` and the pass aborts. Failing is the point; following is what N6 removes.
pub fn createExclusiveFile(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    permissions: std.Io.File.Permissions,
) !std.Io.File {
    removeEntry(io, dir, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return dir.createFile(io, name, .{
        .truncate = false,
        .exclusive = true,
        .permissions = permissions,
    });
}

/// Remove whatever is at `name` without following it. A file is unlinked; a directory-shaped entry (including a
/// directory symlink or junction, which `deleteFile` refuses on Windows) is removed with `deleteDir`, which
/// removes the link itself. A non-empty real directory is left in place: the create then fails and the pass
/// reports it rather than deleting someone else's tree.
fn removeEntry(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    dir.deleteFile(io, name) catch |file_err| {
        if (file_err == error.FileNotFound) return;
        dir.deleteDir(io, name) catch |dir_err| {
            if (dir_err == error.FileNotFound) return;
            return file_err;
        };
    };
}

// --------------------------------------------------------------------------------------------- tests

test "openExistingDirectory returns null for missing and refuses a file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing = try openExistingDirectory(io, tmp.dir, "absent", .{});
    try std.testing.expect(missing == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "occupied", .data = "not a directory\n" });
    try std.testing.expectError(error.MetaDirNotDirectory, openExistingDirectory(io, tmp.dir, "occupied", .{}));

    try tmp.dir.createDirPath(io, "present");
    const dir = (try openExistingDirectory(io, tmp.dir, "present", .{})) orelse return error.TestUnexpectedResult;
    defer dir.close(io);
}

test "openOrCreateDirectory creates a missing directory and createExclusiveFile ignores a stale entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try openOrCreateDirectory(io, tmp.dir, "state", .{});
    defer dir.close(io);

    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        const dir_stat = try dir.stat(io);
        try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);
    }

    // A stale ordinary file is removed as an entry, then the new file is created with the requested mode.
    try dir.writeFile(io, .{ .sub_path = "fresh", .data = "stale\n" });
    var file = try createExclusiveFile(io, dir, "fresh", owner_only_file);
    defer file.close(io);
    try file.writeStreamingAll(io, "new\n");
    const stat = try dir.statFile(io, "fresh", .{});
    try std.testing.expectEqual(@as(u64, 4), stat.size);
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "a non-empty directory at a file name is refused, not deleted" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "occupied");
    try tmp.dir.writeFile(io, .{ .sub_path = "occupied/keep", .data = "keep\n" });
    if (createExclusiveFile(io, tmp.dir, "occupied", owner_only_file)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {
        // Refused: the non-empty directory was not deleted into or removed.
    }
    const kept = try tmp.dir.readFileAlloc(io, "occupied/keep", std.testing.allocator, std.Io.Limit.limited(16));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("keep\n", kept);
}

test "a POSIX symlink at the state directory is refused" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.symLink(io, "outside", "link", .{ .is_directory = true });
    try std.testing.expectError(error.MetaDirSymlink, openExistingDirectory(io, tmp.dir, "link", .{}));
    try std.testing.expectError(error.MetaDirSymlink, openOrCreateDirectory(io, tmp.dir, "link", .{}));
}
