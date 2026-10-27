// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The nested-repository boundary rule (`plans/worktrees.md` § 4).
//!
//! A directory whose `.git` entry **confirms** is a nested repository: a clone, a submodule checkout or a linked
//! worktree. The scanner never descends into it, because a trio describes one tree and a nested working copy is a
//! different tree with its own history, its own ignores and its own watcher. The rule is general (it is about
//! nested repositories, of which a worktree is one case) and it is **not** a switch: `worktrees = off` stops the
//! worktree *handling*, never this rule (`plans/worktrees.md` § 5h, decision 30).
//!
//! ## Confirmation, not pattern matching
//!
//! * **A `.git` file** is a gitfile (linked worktree or submodule). It must start with `gitdir: `, and the target
//!   it names must exist and be a directory. The back-pointer (`<target>/gitdir` naming `<dir>/.git`) is
//!   confirmation *when it matches* and not a requirement: `git worktree repair` exists precisely because a manual
//!   move leaves that pointer stale, and a stale pointer is still a worktree. A mismatch is tolerated silently here;
//!   what it changes is only which kind of boundary it is, not whether it is one.
//! * **A `.git` directory** is a nested clone. Two entries confirm it: `HEAD` is a file whose first line is a
//!   symbolic ref (`ref: …`) or a 40-character object id, and `objects/` is a directory. Anything else — a
//!   directory that merely contains a file named `.git`, a fixture, a backup copy — is **not** a boundary and is
//!   listed like any other directory.
//! * **A symlink is never followed.** `.git` as a symlink does not confirm; a symlink to a directory is an entry,
//!   not a descent.
//!
//! The engine never shells out to git: every fact here is a file-system read. `git worktree list --porcelain` is
//! the oracle for tests, not a runtime dependency.

const std = @import("std");

/// What a confirmed boundary is. `none` is the ordinary directory.
pub const Kind = enum {
    none,
    /// A nested clone: `.git` is a directory that carries `HEAD` and `objects/`.
    repo,
    /// A linked worktree or a submodule checkout: `.git` is a gitfile.
    worktree,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .none => "none",
            .repo => "repo",
            .worktree => "worktree",
        };
    }
};

/// One nested repository the scan refused to cross. `path` is workspace-relative and has no trailing slash; it is
/// owned by the caller's arena.
pub const Boundary = struct {
    path: []const u8,
    kind: Kind,
};

pub const gitfile_prefix = "gitdir: ";

/// Confirm whether `parent/name` is a nested repository. `arena` is used only when a gitfile has to be read and a
/// relative target resolved; a directory without a `.git` entry costs one stat and nothing else.
pub fn confirm(arena: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, name: []const u8) Kind {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dot_git = std.fmt.bufPrint(&path_buffer, "{s}/.git", .{name}) catch return .none;
    const stat = parent.statFile(io, dot_git, .{ .follow_symlinks = false }) catch return .none;
    return switch (stat.kind) {
        .file => confirmGitfile(arena, io, parent, name),
        .directory => confirmRepo(io, parent, name),
        else => .none,
    };
}

/// `.git` is a gitfile: read it, require the `gitdir: ` prefix, and require the target to be a directory.
fn confirmGitfile(arena: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, name: []const u8) Kind {
    var child = parent.openDir(io, name, .{}) catch return .none;
    defer child.close(io);

    var file = child.openFile(io, ".git", .{ .allow_directory = false }) catch return .none;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .unlimited) catch return .none;
    if (!std.mem.startsWith(u8, text, gitfile_prefix)) return .none;
    const raw = std.mem.trim(u8, text[gitfile_prefix.len..], " \t\r\n");
    if (raw.len == 0) return .none;

    // The target must exist and be a directory. A relative `gitdir:` is resolved against the worktree directory,
    // never against the process's current directory (§ 1).
    var target: ?std.Io.Dir = null;
    if (std.fs.path.isAbsolute(raw)) {
        target = std.Io.Dir.openDirAbsolute(io, raw, .{}) catch null;
    } else {
        var absolute_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const count = child.realPath(io, &absolute_buffer) catch return .none;
        const resolved = std.fs.path.resolve(arena, &.{ absolute_buffer[0..count], raw }) catch return .none;
        target = std.Io.Dir.openDirAbsolute(io, resolved, .{}) catch null;
    }
    if (target) |*dir| {
        dir.close(io);
        return .worktree;
    }
    return .none;
}

/// `.git` is a directory: `HEAD` must be a file naming a ref or an object id, and `objects/` must be a directory.
fn confirmRepo(io: std.Io, parent: std.Io.Dir, name: []const u8) Kind {
    var child = parent.openDir(io, name, .{}) catch return .none;
    defer child.close(io);

    const objects = child.statFile(io, ".git/objects", .{ .follow_symlinks = false }) catch return .none;
    if (objects.kind != .directory) return .none;

    var head = child.openFile(io, ".git/HEAD", .{ .allow_directory = false }) catch return .none;
    defer head.close(io);
    var buffer: [128]u8 = undefined;
    var reader = head.reader(io, &buffer);
    const count = reader.interface.readSliceShort(&buffer) catch return .none;
    const first_line = std.mem.sliceTo(buffer[0..count], '\n');
    if (std.mem.startsWith(u8, first_line, "ref: ")) return .repo;
    if (first_line.len >= 40 and std.ascii.isHex(first_line[0])) {
        for (first_line[0..40]) |byte| {
            if (!std.ascii.isHex(byte)) return .none;
        }
        return .repo;
    }
    return .none;
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn writeFile(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

test "a directory without .git is not a boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "plain");
    try writeFile(tmp.dir, io, "plain/a.txt", "hello\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.none, confirm(arena_state.allocator(), io, tmp.dir, "plain"));
}

test "a stray .git directory is not a boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "fixture");
    try tmp.dir.createDirPath(io, "fixture/.git");
    try writeFile(tmp.dir, io, "fixture/.git/notes.txt", "not a repository\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.none, confirm(arena_state.allocator(), io, tmp.dir, "fixture"));
}

test "a .git directory with HEAD and objects confirms a nested clone" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "clone");
    try tmp.dir.createDirPath(io, "clone/.git");
    try tmp.dir.createDirPath(io, "clone/.git/objects");
    try writeFile(tmp.dir, io, "clone/.git/HEAD", "ref: refs/heads/main\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.repo, confirm(arena_state.allocator(), io, tmp.dir, "clone"));
}

test "a detached HEAD with objects still confirms a nested clone" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "clone");
    try tmp.dir.createDirPath(io, "clone/.git/objects");
    try writeFile(tmp.dir, io, "clone/.git/HEAD", "0123456789abcdef0123456789abcdef01234567\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.repo, confirm(arena_state.allocator(), io, tmp.dir, "clone"));
}

test "a gitfile whose target exists confirms a worktree" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(io, "wt");
    try writeFile(tmp.dir, io, "wt/.git", "gitdir: ../main/.git/worktrees/wt\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.worktree, confirm(arena_state.allocator(), io, tmp.dir, "wt"));
}

test "a gitfile with a missing target is not confirmed as a boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "orphan");
    try writeFile(tmp.dir, io, "orphan/.git", "gitdir: ../gone/worktrees/orphan\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.none, confirm(arena_state.allocator(), io, tmp.dir, "orphan"));
}

test "a .git file without the gitdir prefix is not a boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stray");
    try writeFile(tmp.dir, io, "stray/.git", "this is not a gitfile\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqual(Kind.none, confirm(arena_state.allocator(), io, tmp.dir, "stray"));
}
