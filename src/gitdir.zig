// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Where a root's git directories are (`plans/worktrees.md` § 5b). Pure file-system reads, no git process.
//!
//! A root's `.git` is one of three things:
//!
//! * **absent** — the root is not a repository (or is inside one but at a directory that is not its top);
//! * **a directory** — the main worktree (or a bare-ish layout): `$GIT_DIR` is `<root>/.git` and, unless the
//!   directory carries a `commondir` file, `$GIT_COMMON_DIR` is the same directory;
//! * **a gitfile** — a linked worktree or a submodule checkout: the file starts with `gitdir: `, the target is
//!   `$GIT_DIR`, and `$GIT_DIR/commondir` (when present) names `$GIT_COMMON_DIR`, resolved against `$GIT_DIR`.
//!
//! Relative links are resolved **against the directory that contains them**, never against the process's working
//! directory: a relative `gitdir:` is relative to the worktree, a relative `commondir` is relative to `$GIT_DIR` (§ 1).
//! The returned paths are host state — they are used to open watchers and read files, and are never written into a
//! trio (AGENTS.md: the registry and paths are host state).

const std = @import("std");

pub const Location = struct {
    /// `$GIT_DIR` — the per-worktree administrative directory (`HEAD`, `index`, `logs/HEAD`).
    git_dir: []const u8,
    /// `$GIT_COMMON_DIR` — the shared part (`refs/`, `objects/`, `hooks/`, `info/`, `config`).
    common_dir: []const u8,
    /// Whether `.git` is a gitfile (a linked worktree or a submodule), which is what `worktree` events key on.
    is_gitfile: bool,
};

/// Resolve `root`'s git directories, or `null` when the root has no `.git` entry. All strings are arena-owned.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, root: []const u8) !?Location {
    var root_dir = openRoot(io, root) catch return null;
    defer root_dir.close(io);

    const stat = root_dir.statFile(io, ".git", .{ .follow_symlinks = false }) catch return null;
    switch (stat.kind) {
        .directory => {
            const git_dir = try join(arena, root, ".git");
            // A directory marker may still carry `commondir` (a manually arranged repository); honour it.
            const common_dir = (try readCommondir(arena, io, git_dir)) orelse git_dir;
            return .{ .git_dir = git_dir, .common_dir = common_dir, .is_gitfile = false };
        },
        .file => {
            const target = (try readGitfileTarget(arena, io, root_dir)) orelse return null;
            const git_dir = if (std.fs.path.isAbsolute(target))
                target
            else
                try std.fs.path.resolve(arena, &.{ root, target });
            const common_dir = (try readCommondir(arena, io, git_dir)) orelse git_dir;
            return .{ .git_dir = git_dir, .common_dir = common_dir, .is_gitfile = true };
        },
        else => return null,
    }
}

fn openRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{})
    else
        std.Io.Dir.cwd().openDir(io, root, .{});
}

/// Whether `root` is a **linked worktree** in the sense `root add --worktree` asserts (`plans/worktrees.md` § 7):
/// `.git` is a gitfile, and the directory it names exists. A `.git` directory is a main worktree or a nested clone,
/// not this; a gitfile naming a missing directory is a broken link, not a worktree.
pub fn linkedWorktree(arena: std.mem.Allocator, io: std.Io, root: []const u8) bool {
    const location = (resolve(arena, io, root) catch return false) orelse return false;
    if (!location.is_gitfile) return false;
    var dir = if (std.fs.path.isAbsolute(location.git_dir))
        std.Io.Dir.openDirAbsolute(io, location.git_dir, .{}) catch return false
    else
        std.Io.Dir.cwd().openDir(io, location.git_dir, .{}) catch return false;
    dir.close(io);
    return true;
}

fn join(arena: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    if (root.len == 0 or std.mem.eql(u8, root, ".")) return arena.dupe(u8, name);
    return std.fs.path.join(arena, &.{ root, name });
}

/// The `gitdir: <path>` target of a root's `.git` file, trimmed; `null` when the file is not a gitfile.
fn readGitfileTarget(arena: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir) !?[]const u8 {
    const text = root_dir.readFileAlloc(io, ".git", arena, std.Io.Limit.limited(4096)) catch return null;
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const target = std.mem.trim(u8, text[prefix.len..], " \t\r\n");
    if (target.len == 0) return null;
    return target;
}

/// `$GIT_DIR/commondir`, resolved against `$GIT_DIR`; `null` when the file is absent (the common dir is the git dir).
fn readCommondir(arena: std.mem.Allocator, io: std.Io, git_dir: []const u8) !?[]const u8 {
    var dir = if (std.fs.path.isAbsolute(git_dir))
        std.Io.Dir.openDirAbsolute(io, git_dir, .{}) catch return null
    else
        std.Io.Dir.cwd().openDir(io, git_dir, .{}) catch return null;
    defer dir.close(io);
    const text = dir.readFileAlloc(io, "commondir", arena, std.Io.Limit.limited(4096)) catch return null;
    const target = std.mem.trim(u8, text, " \t\r\n");
    if (target.len == 0) return null;
    if (std.fs.path.isAbsolute(target)) return target;
    return @as(?[]const u8, try std.fs.path.resolve(arena, &.{ git_dir, target }));
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn writeFile(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

fn rootPath(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try dir.realPath(io, &buffer);
    return arena.dupe(u8, buffer[0..count]);
}

test "no .git means no location" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try rootPath(arena, io, tmp.dir);
    try testing.expectEqual(@as(?Location, null), try resolve(arena, io, root));
}

test "a .git directory is its own common dir" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git/objects");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try rootPath(arena, io, tmp.dir);
    const location = (try resolve(arena, io, root)).?;
    try testing.expect(!location.is_gitfile);
    try testing.expect(std.mem.endsWith(u8, location.git_dir, ".git"));
    try testing.expectEqualStrings(location.git_dir, location.common_dir);
}

test "a gitfile resolves its target and commondir against the right directories" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Layout: main/.git/worktrees/wt with a commondir pointing back at main/.git.
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(io, "main/.git/objects");
    try tmp.dir.createDirPath(io, "wt");
    try writeFile(tmp.dir, io, "main/.git/worktrees/wt/commondir", "../..\n");
    try writeFile(tmp.dir, io, "wt/.git", "gitdir: ../main/.git/worktrees/wt\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try rootPath(arena, io, tmp.dir);
    const root = try std.fs.path.join(arena, &.{ base, "wt" });
    const location = (try resolve(arena, io, root)).?;
    try testing.expect(location.is_gitfile);
    try testing.expectEqualStrings("wt", std.fs.path.basename(location.git_dir));
    try testing.expect(std.mem.indexOf(u8, location.git_dir, "worktrees") != null);
    try testing.expectEqualStrings(".git", std.fs.path.basename(location.common_dir));
    try testing.expectEqualStrings("main", std.fs.path.basename(std.fs.path.dirname(location.common_dir).?));
}

test "a gitfile that is not a gitfile is refused, not guessed at" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".git", "this is not a gitfile\n");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try rootPath(arena, io, tmp.dir);
    try testing.expectEqual(@as(?Location, null), try resolve(arena, io, root));
}

test "only a gitfile naming an existing directory is a linked worktree" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(io, "main/.git/objects");
    try writeFile(tmp.dir, io, "main/.git/worktrees/wt/commondir", "../..\n");
    try tmp.dir.createDirPath(io, "wt");
    try writeFile(tmp.dir, io, "wt/.git", "gitdir: ../main/.git/worktrees/wt\n");
    try tmp.dir.createDirPath(io, "clone/.git/objects");
    try writeFile(tmp.dir, io, "clone/.git/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(io, "broken");
    try writeFile(tmp.dir, io, "broken/.git", "gitdir: ../nowhere\n");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try rootPath(arena, io, tmp.dir);
    const wt = try std.fs.path.join(arena, &.{ base, "wt" });
    const clone = try std.fs.path.join(arena, &.{ base, "clone" });
    const broken = try std.fs.path.join(arena, &.{ base, "broken" });
    const plain = try std.fs.path.join(arena, &.{ base, "main" });
    try testing.expect(linkedWorktree(arena, io, wt));
    try testing.expect(!linkedWorktree(arena, io, clone));
    try testing.expect(!linkedWorktree(arena, io, broken));
    try testing.expect(!linkedWorktree(arena, io, plain));
}
