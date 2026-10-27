// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Git's own state, watched (`plans/worktrees.md` § 5b, M3).
//!
//! A working-tree watcher cannot see git's administration directory: `.git` is a reserved name, and in a linked
//! worktree it is not even inside the tree. This module is the second arm — the one on `$GIT_COMMON_DIR` — and the
//! pure rules behind it, so every decision is a test rather than a comment:
//!
//! * **Which paths matter** (`scopeOf`): a path under a root's `$GIT_DIR` is *tree-changing* for that root (`HEAD`,
//!   `index`, the pseudo-refs, `logs/HEAD`, its `*.lock`); a path anywhere else under the common dir is *repo-wide*
//!   (`refs/`, `packed-refs`, `logs/refs/`, `worktrees/`); `info/exclude` is both — it is shared, and it changes
//!   every root's visible set, so it forces a pass for every root of the repo. The split is by **path**, not by
//!   directory identity, because the main worktree's `$GIT_DIR` *is* the common dir.
//! * **What may be registered** (`shouldWatch`): the plan's set, and nothing else. `objects/`, `modules/`, `lfs/` and
//!   `hooks/` are refused, which is the balloon the field report describes. The predicate reaches the per-directory
//!   backends — inotify on Linux, kqueue on macOS/BSD — in nightwatch's generic layer, not in the backend file:
//!   `recurse_watch` asks `backend.handler.should_watch(sub, .dir)` before each subdirectory registration and skips the
//!   whole subtree on `false`, and the interceptor's `change_cb` asks again for a directory created later. That
//!   `INotify.zig` itself never mentions the predicate is not the criterion; a backend file that calls it directly is
//!   a shortcut, not the contract. On Windows (and FSEvents) one recursive registration covers the subtree, so the
//!   same predicate is a handler-side filter there (`filters_watches = false`) — it still never descends in the
//!   *scan*, and the arm is one handle either way. `hooks/` is refused on purpose and is not a gap: § 5b excludes
//!   it from the file watch, and the hook signal (M5) is the per-repo spool, not a file event.
//! * **When a pass is unsafe** (`hasTreeLock`): a `*.lock` directly in `$GIT_DIR`. Only this root's tree files, never
//!   a shared `refs/**/*.lock`, because a commit in one worktree must not block a sibling's pass.
//! * **What git is doing** (`readHead`, `readInProgress`): the `root status` fields, read from the files the watch
//!   already keeps warm.
//! * **Who shares an arm** (`Registry`): one watcher per common dir, refcounted by the roots that resolve to it.
//!   Adding two roots of one repo arms it once; removing one leaves it; removing the last disarms it.
//!
//! Nothing here runs git, and nothing here writes: the location strings are host state, exactly like `root`, and
//! never reach a trio (AGENTS.md § 2).

const std = @import("std");
const builtin = @import("builtin");
const nightwatch = @import("nightwatch");
const gitdir = @import("../gitdir.zig");
const boundary = @import("../boundary.zig");
const format = @import("../format.zig");

const Watcher = nightwatch.Default;

// --------------------------------------------------------------------------------------------- path shapes

/// What a metadata event means for one root (§ 5b "tree-changing signals versus repo-wide signals").
pub const Scope = enum {
    /// Only this root's own `$GIT_DIR` moved: its working tree may be half-written, and a pass belongs to it.
    tree,
    /// The repository moved (`refs/`, `packed-refs`, `logs/refs/`, `worktrees/`): an event for every served root of
    /// the repo, and a pass for none of them — their trees did not change.
    repo,
    /// Shared, but tree-changing for **every** root of the repo: `info/exclude` decides which names exist, so a pass
    /// is the only way an edit reaches the trio (§ 5b, "An ignore-file change must reach a pass").
    repo_tree,
    /// Not part of the metadata set: no event, no pass.
    ignored,
};

/// `$GIT_DIR` files that are a reason to pass *that* root: the branch/checkout marker, the index, the pseudo-refs
/// and the reflog of `HEAD`. The list is the plan's (§ 5b) and is compared by name, because a metadata path is
/// git's spelling, not the platform's.
const tree_files = [_][]const u8{
    "HEAD",
    "index",
    "ORIG_HEAD",
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "REBASE_HEAD",
    "BISECT_LOG",
};

/// Locks that mean **this working tree is mid-write** (§ 5b, § 5d): `index.lock` while a checkout or a merge writes
/// the index, `HEAD.lock` while the branch pointer moves, `shallow.lock` while a fetch rewrites the shallow file.
/// `refs/**/*.lock` and `packed-refs.lock` are deliberately absent: they are a shared ref update, an event and a
/// heuristic, never a reason to block a sibling's pass.
const tree_locks = [_][]const u8{ "index.lock", "HEAD.lock", "shallow.lock" };

/// Files at the top of a git dir that are in the metadata set (watched) besides the tree-changing ones.
const common_files = [_][]const u8{"packed-refs"};

/// Directories under the common dir that hold metadata. Everything else (`objects/`, `modules/`, `lfs/`, `hooks/`,
/// `config`, `branches/`, …) is not watched at all.
const metadata_dirs = [_][]const u8{ "refs", "logs", "worktrees", "info", "rebase-merge", "rebase-apply" };

/// Directories that must never be registered for the metadata arm (§ 5b, "Not watched"). They are large, they
/// change on every fetch and commit, and none of them changes what a trio describes.
const refused_dirs = [_][]const u8{ "objects", "modules", "lfs", "hooks" };

fn isSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn segmentEquals(a: []const u8, b: []const u8) bool {
    // Windows paths are case-insensitive, and a location may reach us through a `gitdir:` line written with the
    // on-disk case while the event path came from our own `watch()` call with another. Comparing segments that way
    // is what keeps two roots of one repo on one arm.
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn nextSegment(text: []const u8, index: *usize) ?[]const u8 {
    while (index.* < text.len and isSep(text[index.*])) index.* += 1;
    if (index.* >= text.len) return null;
    const start = index.*;
    while (index.* < text.len and !isSep(text[index.*])) index.* += 1;
    return text[start..index.*];
}

/// `path` relative to `base`, or `null` when it is not inside it. Separators and (on Windows) case are ignored,
/// because the two sides come from different sources: a `.git` directory we joined, a `gitdir:` line git wrote, and
/// an event path nightwatch resolved. The returned slice points into `path`.
pub fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    var base_index: usize = 0;
    var path_index: usize = 0;
    while (true) {
        const base_segment = nextSegment(base, &base_index) orelse break;
        const path_segment = nextSegment(path, &path_index) orelse return null;
        if (!segmentEquals(base_segment, path_segment)) return null;
    }
    while (path_index < path.len and isSep(path[path_index])) path_index += 1;
    return path[path_index..];
}

/// Whether two host paths name the same directory (same segments, same case rules).
pub fn samePath(a: []const u8, b: []const u8) bool {
    const forward = relativeTo(a, b) orelse return false;
    if (forward.len != 0) return false;
    const backward = relativeTo(b, a) orelse return false;
    return backward.len == 0;
}

fn firstSegment(path: []const u8) []const u8 {
    var index: usize = 0;
    return nextSegment(path, &index) orelse "";
}

fn isTreeLockName(name: []const u8) bool {
    for (tree_locks) |lock| if (std.mem.eql(u8, lock, name)) return true;
    return false;
}

fn isCommonFile(name: []const u8) bool {
    for (common_files) |file| if (std.mem.eql(u8, file, name)) return true;
    // A lock at the top of the common dir: `packed-refs.lock` is the ref update in flight, and any `<name>.lock`
    // here is a git write in progress. Watched, because it is cheap and it is the timeline's punctuation.
    return std.mem.endsWith(u8, name, ".lock");
}

fn isTreeFile(name: []const u8) bool {
    for (tree_files) |file| if (std.mem.eql(u8, file, name)) return true;
    return isTreeLockName(name);
}

fn hasPrefixSegment(rel: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, rel, name)) return false;
    return rel.len == name.len or isSep(rel[name.len]);
}

/// Whether a relative path is exactly `name`, segment for segment, whichever separator the event path used. A
/// metadata path may arrive as `info/exclude` from git and `info\exclude` from a Windows backend; they are the same
/// file, and a string comparison on one spelling would silently drop it.
fn relEquals(rel: []const u8, name: []const u8) bool {
    var rel_index: usize = 0;
    var name_index: usize = 0;
    while (true) {
        const rel_segment = nextSegment(rel, &rel_index);
        const name_segment = nextSegment(name, &name_index);
        if (rel_segment == null and name_segment == null) return true;
        if (rel_segment == null or name_segment == null) return false;
        if (!segmentEquals(rel_segment.?, name_segment.?)) return false;
    }
}

fn isMetadataDir(name: []const u8) bool {
    for (metadata_dirs) |dir| if (std.mem.eql(u8, dir, name)) return true;
    return false;
}

fn isRefusedDir(name: []const u8) bool {
    for (refused_dirs) |dir| if (std.mem.eql(u8, dir, name)) return true;
    return false;
}

/// Whether a relative path (below the common dir) changes **this** root's working tree.
fn treeChanging(rel: []const u8) bool {
    if (std.mem.indexOfAny(u8, rel, "/\\") == null) return isTreeFile(rel);
    // A rebase keeps its state in a directory (`rebase-merge/`, `rebase-apply/`): per-worktree state (§ 5b), so every
    // file in it is a tree-changing signal for the root whose git dir holds it.
    if (hasPrefixSegment(rel, "rebase-merge") or hasPrefixSegment(rel, "rebase-apply")) return true;
    // `logs/HEAD` is the per-worktree reflog of the branch pointer; `logs/refs/` is shared history.
    if (hasPrefixSegment(rel, "logs")) {
        const rest = std.mem.trimStart(u8, rel["logs".len..], "/\\");
        return relEquals(rest, "HEAD");
    }
    return false;
}

/// Whether a relative path (below the common dir) is shared repository state.
fn repoWide(rel: []const u8) bool {
    if (relEquals(rel, "packed-refs") or relEquals(rel, "packed-refs.lock")) return true;
    if (hasPrefixSegment(rel, "refs")) return true;
    if (hasPrefixSegment(rel, "logs")) {
        const rest = std.mem.trimStart(u8, rel["logs".len..], "/\\");
        return hasPrefixSegment(rest, "refs");
    }
    return hasPrefixSegment(rel, "worktrees");
}

/// The kind of git operation a metadata path implies, named exactly as the wire's table names it (`FORMAT.socket.md`
/// § `GIT_EVENT`). It is decided in the watcher's thread from the path alone — no file is read and nothing is
/// allocated — so one event carries a usable kind without the handler becoming a second pass.
pub const Kind = enum(u8) {
    branch = 0,
    checkout = 1,
    commit = 2,
    merge = 3,
    rebase = 4,
    index = 5,
    worktree = 6,
    other = 7,
};

/// A metadata change as one root sees it: who hears it (`scope`) and what kind of operation it was.
pub const Change = struct {
    scope: Scope,
    kind: Kind,
};

/// Classify one metadata path: the scope of § 5b and the kind of § 5d, together, because they are decided by the same
/// path and a caller that took only one of them would have to look at the path again.
///
/// A lock is not an event (§ 5b, "Lock files are a latch, not an event source"): it classifies as `ignored` here even
/// though `scopeOf` calls it tree-changing, because its only job is to stop a pass from starting, which the latch
/// does on its own.
pub fn changeOf(git_dir: []const u8, common_dir: []const u8, path: []const u8) Change {
    if (relativeTo(git_dir, path)) |rel| {
        if (isLockFile(rel)) return .{ .scope = .ignored, .kind = .other };
        if (treeChanging(rel)) return .{ .scope = .tree, .kind = treeKind(rel) };
    }
    if (relativeTo(common_dir, path)) |rel| {
        if (isLockFile(rel)) return .{ .scope = .ignored, .kind = .other };
        if (relEquals(rel, "info/exclude")) return .{ .scope = .repo_tree, .kind = .other };
        if (repoWide(rel)) return .{ .scope = .repo, .kind = repoKind(rel) };
    }
    return .{ .scope = .ignored, .kind = .other };
}

/// A lock file under either directory. It is **never** an event source (§ 5b, "Lock files are a latch, not an event
/// source": it lives for microseconds, so its create/delete pair would be two frames for one operation, and the
/// durable ref renames that follow it are the record). What a lock does is stop a pass from starting — the latch —
/// and on a backend that delivers it at all its only use here is to be dropped.
fn isLockFile(rel: []const u8) bool {
    return std.mem.endsWith(u8, rel, ".lock");
}

/// What a tree-changing file says about the operation. `HEAD` is a branch switch or a commit's ref move; the
/// pseudo-refs name the operation that left them; anything else is the index or the reflog, which is a checkout until
/// a hook says better (M5).
fn treeKind(rel: []const u8) Kind {
    if (relEquals(rel, "HEAD")) return .branch;
    if (relEquals(rel, "MERGE_HEAD")) return .merge;
    if (relEquals(rel, "REBASE_HEAD") or hasPrefixSegment(rel, "rebase-merge") or hasPrefixSegment(rel, "rebase-apply")) return .rebase;
    if (relEquals(rel, "index")) return .index;
    return .other;
}

/// What a shared path says about the operation: a branch ref is a commit (or the fetch that moved it), a worktree's
/// metadata is a worktree event, and everything else shared (tags, notes, stash, packed-refs, the reflog) is `other`.
fn repoKind(rel: []const u8) Kind {
    if (hasPrefixSegment(rel, "worktrees")) return .worktree;
    if (hasPrefixSegment(rel, "refs")) {
        const rest = std.mem.trimStart(u8, rel["refs".len..], "/\\");
        if (hasPrefixSegment(rest, "heads")) return .commit;
        return .other;
    }
    return .other;
}

/// What one root makes of a metadata path.
///
/// The git dir is checked first, because it is the narrower set: with `$GIT_DIR == $GIT_COMMON_DIR` (the main
/// worktree) a `refs/` change falls through to the repo-wide answer, while a worktree's own `HEAD` is matched by its
/// own `$GIT_DIR` and by no other root's.
pub fn scopeOf(git_dir: []const u8, common_dir: []const u8, path: []const u8) Scope {
    if (relativeTo(git_dir, path)) |rel| {
        if (treeChanging(rel)) return .tree;
    }
    if (relativeTo(common_dir, path)) |rel| {
        // The repo-local ignore is shared, and it changes every root's visible set: a pass, not just an event.
        if (relEquals(rel, "info/exclude")) return .repo_tree;
        if (repoWide(rel)) return .repo;
    }
    return .ignored;
}

/// A file directly in a git dir: the tree files, `packed-refs` and any `*.lock`.
fn metadataAtTop(rel: []const u8) bool {
    if (std.mem.indexOfAny(u8, rel, "/\\") != null) return false;
    return isTreeFile(rel) or isCommonFile(rel);
}

/// The predicate handed to nightwatch (`Handler.VTable.should_watch`) **and** applied in the handler, so a backend
/// that never consults it (Windows, FSEvents) still behaves the same way.
///
/// The predicate is keyed by the arm — the common dir — and not by a root's git dir, because one arm covers every
/// worktree of a repo. A directory is admitted when it *contains* metadata; a file when it *is* metadata. `unknown`
/// is a deleted object on Windows whose type can no longer be queried, so it is treated as either.
pub fn shouldWatch(common_dir: []const u8, path: []const u8, object_type: nightwatch.ObjectType) bool {
    const rel = relativeTo(common_dir, path) orelse return false;
    if (rel.len == 0) return true; // the arm itself
    if (object_type != .file) {
        var segments = std.mem.tokenizeAny(u8, rel, "/\\");
        while (segments.next()) |segment| {
            if (isRefusedDir(segment)) return false;
        }
        if (isMetadataDir(firstSegment(rel))) return true;
        if (object_type == .dir) return false;
        return metadataAtTop(rel);
    }
    if (isMetadataDir(firstSegment(rel))) return true;
    return metadataAtTop(rel);
}
/// The **working-tree** arm's predicate (`plans/worktrees.md` § 5b, G35): the root itself is admitted, `.git` and
/// `.fs-meta` are refused, and a directory that confirms as a nested repository is refused so a linked worktree or a
/// clone is never registered one directory at a time. A backend that honours `should_watch` (kqueue, and inotify
/// through nightwatch's generic `recurse_watch`/interceptor) prunes the subtree; the one-handle backends keep the
/// handler filter and pay nothing either way.
///
/// `arena` is scratch for the gitfile read in `boundary.confirm`; the caller on the watcher thread passes a fixed
/// buffer, so no shared allocator is touched. A read that cannot be confirmed is admitted — refusing an ordinary
/// directory would silently stop watching part of the tree, which is worse than registering a stray fixture.
pub fn shouldWatchTree(arena: std.mem.Allocator, io: std.Io, root_path: []const u8, path: []const u8, object_type: nightwatch.ObjectType) bool {
    if (object_type == .file) return true;
    // The served root is the starting point of the walk: when it is itself a worktree its `.git` confirms a
    // boundary, and refusing it would arm nothing at all.
    if (samePath(path, root_path)) return true;
    const name = std.fs.path.basename(path);
    if (std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, format.directory_name)) return false;
    if (!format.nameValid(name)) return true;
    const parent_path = std.fs.path.dirname(path) orelse return true;
    var parent = if (std.fs.path.isAbsolute(parent_path))
        std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return true
    else
        std.Io.Dir.cwd().openDir(io, parent_path, .{}) catch return true;
    defer parent.close(io);
    return boundary.confirm(arena, io, parent, name) == .none;
}
// --------------------------------------------------------------------------------------------- the lock latch

/// Whether `git_dir` holds a lock that means its working tree is being rewritten right now.
///
/// Only `$GIT_DIR/index.lock`, `HEAD.lock` and `shallow.lock` count (§ 5b): a shared `refs/**/*.lock` is a ref
/// update, and blocking a root on it would let one worktree's commit stall another's pass. The check is a poll —
/// the latch is cleared by asking the filesystem again, never by a delete event, because in a linked worktree there
/// is no tree watcher on git's directory to deliver one (§ 5b, "Its documented bug is the caveat").
pub fn hasTreeLock(io: std.Io, git_dir: []const u8) bool {
    if (git_dir.len == 0) return false;
    var dir = openDir(io, git_dir) catch return false;
    defer dir.close(io);
    for (tree_locks) |name| {
        const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind == .file) return true;
    }
    return false;
}

fn openDir(io: std.Io, path: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openDir(io, path, .{});
}

// --------------------------------------------------------------------------------------------- what git is doing

/// Longest branch name kept for display. A `HEAD` is one line; a branch name near this is pathological, and the
/// snapshot is a status field, not a general-purpose file reader.
pub const max_head = 200;

/// A branch name, or `detached:<sha8>`. Fixed storage: `Snapshot` is returned by value and must not point at a
/// buffer that dies with it.
pub const Head = struct {
    buffer: [max_head]u8 = undefined,
    len: usize = 0,
    detached: bool = false,

    pub fn text(self: *const Head) []const u8 {
        return self.buffer[0..self.len];
    }

    fn set(self: *Head, value: []const u8) void {
        const count = @min(value.len, max_head);
        @memcpy(self.buffer[0..count], value[0..count]);
        self.len = count;
    }
};

/// The operation git is in the middle of, from the files that mark it (§ 5b, `gitrepository-layout(5)`).
pub const InProgress = enum {
    none,
    merge,
    rebase,
    cherry_pick,
    revert,
    bisect,

    pub fn name(self: InProgress) []const u8 {
        return switch (self) {
            .none => "",
            .merge => "merge",
            .rebase => "rebase",
            .cherry_pick => "cherry-pick",
            .revert => "revert",
            .bisect => "bisect",
        };
    }
};

/// `$GIT_DIR/HEAD`: a symref (`ref: refs/heads/x`) or a detached object id.
pub fn readHead(io: std.Io, git_dir: []const u8) Head {
    var head: Head = .{};
    if (git_dir.len == 0) return head;
    var dir = openDir(io, git_dir) catch return head;
    defer dir.close(io);
    var buffer: [4096]u8 = undefined;
    const text = dir.readFile(io, "HEAD", &buffer) catch return head;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return head;
    const prefix = "ref: ";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const ref = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
        const heads = "refs/heads/";
        head.set(if (std.mem.startsWith(u8, ref, heads)) ref[heads.len..] else ref);
        return head;
    }
    if (isObjectId(trimmed)) {
        // `detached:<sha8>` is the plan's spelling (§ 5g): enough to tell two detached checkouts apart in a listing,
        // and the full id is in git's own files for anyone who needs it.
        var shortened: [9 + 8]u8 = undefined;
        const short: usize = @min(trimmed.len, 8);
        const total: usize = 9 + short;
        @memcpy(shortened[0..9], "detached:");
        @memcpy(shortened[9..total], trimmed[0..short]);
        head.detached = true;
        head.set(shortened[0..total]);
    }
    return head;
}

fn isObjectId(text: []const u8) bool {
    if (text.len < 40) return false;
    for (text[0..40]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

/// Which operation, if any, is in progress. Rebase is checked first: a rebase resolving a conflict also carries
/// merge-shaped state, and the outer operation is the one to report.
pub fn readInProgress(io: std.Io, git_dir: []const u8) InProgress {
    if (git_dir.len == 0) return .none;
    var dir = openDir(io, git_dir) catch return .none;
    defer dir.close(io);
    if (isDir(dir, io, "rebase-merge") or isDir(dir, io, "rebase-apply")) return .rebase;
    if (isFile(dir, io, "MERGE_HEAD")) return .merge;
    if (isFile(dir, io, "CHERRY_PICK_HEAD")) return .cherry_pick;
    if (isFile(dir, io, "REVERT_HEAD")) return .revert;
    if (isFile(dir, io, "BISECT_LOG")) return .bisect;
    return .none;
}

fn isFile(dir: std.Io.Dir, io: std.Io, name: []const u8) bool {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}

fn isDir(dir: std.Io.Dir, io: std.Io, name: []const u8) bool {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .directory;
}

/// Whether a resolved location is a repository this milestone should watch.
///
/// A `.git` **directory** must confirm the way the boundary rule confirms one (`plans/worktrees.md` § 4: `HEAD` plus
/// `objects/`), because a stray directory named `.git` — a fixture, a backup copy — is not a repository, and arming a
/// metadata watch on it would turn a write to its `HEAD` into a git event. That is M0's vocabulary for "is this a
/// nested repository", applied to "is this root inside one".
///
/// A **gitfile** already names its target (`gitdir:` is the confirmation, § 4), so only the target's `HEAD` is
/// required: a link into a directory that is not a working copy is a broken link — a state, not an error (§ 5b) —
/// and the root keeps scanning without git handling until it is repaired.
pub fn confirms(io: std.Io, location: gitdir.Location) bool {
    var dir = openDir(io, location.git_dir) catch return false;
    defer dir.close(io);
    if (!isFile(dir, io, "HEAD")) return false;
    if (location.is_gitfile) return true;
    return isDir(dir, io, "objects");
}

// --------------------------------------------------------------------------------------------- the shared arm

/// One root's window into an arm. The `ctx`/`notify` pair is how a root hears about an event without this module
/// depending on `root.zig`; `git_dir` is the root's own `$GIT_DIR`, which is what turns one event into a
/// per-root scope and kind.
///
/// `notify` is called from the watcher's thread, with the arm's mutex held, so it **must** be atomics only: no root
/// lock, no allocation, no log. A root that needs more does it on its next tick.
pub const Listener = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque, change: Change, path: []const u8) void,
    git_dir: []const u8 = "",
};

/// The shared metadata arm on one `$GIT_COMMON_DIR`. Its `handler` is a `nightwatch` `Handler` whose `should_watch`
/// vtable entry is `shouldWatchCallback`, so the predicate consulted by the dependency is the arm's own, keyed by the
/// common dir.
///
/// On a **per-directory** backend — inotify (Linux), kqueue (macOS/BSD) — that predicate is reached twice, both times
/// by nightwatch's generic layer rather than by the backend file: at arm time `recurse_watch` asks
/// `backend.handler.should_watch(sub, .dir)` before registering each enumerated directory and skips its whole subtree
/// on `false`, and when the backend reports a directory created later the interceptor's `change_cb` asks
/// `user_handler.should_watch(path, .dir)` before `add_watch`. That `backend/INotify.zig` never calls the predicate
/// itself is **not** the criterion — the generic layer calls it for inotify exactly as it does for kqueue. On Windows
/// (ReadDirectoryChangesW) and FSEvents one recursive registration covers the subtree, nightwatch does not consult the
/// predicate, and `filters_watches = false` says so; `deliver` is the handler-side filter there, so the same metadata
/// set is the only thing that reaches a listener either way.
pub const Arm = struct {
    registry: *Registry,
    common_dir: []const u8,
    refs: u32 = 0,
    listeners: std.ArrayListUnmanaged(Listener) = .empty,
    /// `nightwatch` keeps this pointer for the watcher's lifetime, so the arm is heap-allocated and never moved.
    handler: Watcher.Handler,
    watcher: ?Watcher = null,

    const vtable = Watcher.Handler.VTable{
        .change = change,
        .rename = rename,
        .should_watch = shouldWatchCallback,
    };

    fn change(handler: *Watcher.Handler, path: []const u8, _: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *Arm = @fieldParentPtr("handler", handler);
        self.deliver(path, object_type);
    }

    fn rename(handler: *Watcher.Handler, source: []const u8, destination: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *Arm = @fieldParentPtr("handler", handler);
        // A rename inside a git dir is a publish (`git update-ref` renames a lock over a ref) or a moved worktree:
        // both ends are metadata, and the destination is what the next reader will see.
        self.deliver(source, object_type);
        self.deliver(destination, object_type);
    }

    /// nightwatch asks this through our own `Handler`, so it can consult the arm (`@fieldParentPtr`), and a backend
    /// that honours it prunes a refused directory at arm time and for a newly created one.
    fn shouldWatchCallback(handler: *Watcher.Handler, path: []const u8, object_type: nightwatch.ObjectType) bool {
        const self: *Arm = @fieldParentPtr("handler", handler);
        return shouldWatch(self.common_dir, path, object_type);
    }

    /// The handler-side filter. It is not redundant with `shouldWatchCallback`: the Windows and FSEvents backends
    /// never consult the predicate, and the plan's "nothing else in git's directory" must hold there too.
    fn deliver(self: *Arm, path: []const u8, object_type: nightwatch.ObjectType) void {
        if (!shouldWatch(self.common_dir, path, object_type)) return;
        const registry = self.registry;
        registry.mutex.lockUncancelable(registry.io);
        defer registry.mutex.unlock(registry.io);
        for (self.listeners.items) |listener| {
            const classified = changeOf(listener.git_dir, self.common_dir, path);
            if (classified.scope == .ignored) continue;
            listener.notify(listener.ctx, classified, path);
        }
    }

    /// Release the platform watch. **Never call this while holding the registry mutex**: `deinit` joins
    /// nightwatch's thread, and that thread may be waiting for the mutex inside `deliver`.
    fn disarm(self: *Arm) void {
        var armed = self.watcher orelse return;
        self.watcher = null;
        armed.deinit();
    }
};

/// One metadata watcher per common dir (`plans/worktrees.md` § 5b, decision 6).
///
/// The arm is refcounted by the roots that resolve to it, and keyed by the common dir because that is the only
/// directory that covers every worktree of a repo: a linked worktree's `$GIT_DIR` is `<common>/worktrees/<id>/` and a
/// submodule's is `<common>/modules/<name>/`, so `$GIT_DIR` is always the common dir or below it. Events reach roots
/// by path prefix, through each listener's own `git_dir` — not by a second watch.
pub const Registry = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    arms: std.ArrayListUnmanaged(*Arm) = .empty,
    /// `false` in unit tests: the refcount is exercised without spawning a platform watcher (and without its
    /// thread), which is the only way "add two, remove one, remove the last" is a deterministic assertion.
    watch_platform: bool = true,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Registry {
        return .{ .io = io, .allocator = allocator };
    }

    /// A registry that counts arms and listeners but registers no watcher. Tests only: the mutex still needs a real
    /// `Io`, so the caller passes the test's own.
    pub fn initCounting(io: std.Io, allocator: std.mem.Allocator) Registry {
        return .{ .io = io, .allocator = allocator, .watch_platform = false };
    }

    pub fn deinit(self: *Registry) void {
        self.lock();
        const leftovers = self.arms.items.len;
        self.arms.clearRetainingCapacity();
        self.unlock();
        if (leftovers != 0) {
            std.debug.print("fsmeta daemon: {d} git metadata watch(es) were still armed at shutdown\n", .{leftovers});
        }
        self.arms.deinit(self.allocator);
    }

    pub fn count(self: *Registry) usize {
        self.lock();
        defer self.unlock();
        return self.arms.items.len;
    }

    /// How many roots currently share this arm.
    pub fn rootCount(self: *Registry, arm: *Arm) u32 {
        self.lock();
        defer self.unlock();
        return arm.refs;
    }

    /// Take the repo's arm, arming it when this is the first root, or join an existing one. The caller owns one
    /// reference and must hand it back with `release`.
    pub fn acquire(self: *Registry, common_dir: []const u8, listener: *Listener) !*Arm {
        self.lock();
        if (self.findLocked(common_dir)) |arm| {
            const joined = self.joinLocked(arm, listener);
            self.unlock();
            return joined;
        }
        self.unlock();

        const fresh = try self.createArm(common_dir);

        self.lock();
        if (self.findLocked(common_dir)) |existing| {
            // Another root armed the same repo while we were arming ours. Keep theirs and drop ours, so there is
            // still exactly one watcher per common dir.
            const joined = self.joinLocked(existing, listener);
            self.unlock();
            fresh.disarm();
            self.destroyArm(fresh);
            return joined;
        }
        fresh.refs = 1;
        fresh.listeners.append(self.allocator, listener.*) catch |err| {
            self.unlock();
            fresh.disarm();
            self.destroyArm(fresh);
            return err;
        };
        self.arms.append(self.allocator, fresh) catch |err| {
            self.unlock();
            fresh.disarm();
            self.destroyArm(fresh);
            return err;
        };
        self.unlock();
        return fresh;
    }

    /// Give the reference back. Returns how many roots still share the arm; `0` means this call disarmed it.
    pub fn release(self: *Registry, arm: *Arm, listener: *Listener) u32 {
        var remaining: u32 = 0;
        var last = false;
        self.lock();
        if (Registry.leaveLocked(arm, listener, &remaining)) {
            last = true;
            for (self.arms.items, 0..) |candidate, index| {
                if (candidate == arm) {
                    _ = self.arms.orderedRemove(index);
                    break;
                }
            }
        }
        self.unlock();
        if (!last) return remaining;
        arm.disarm();
        if (self.watch_platform) {
            std.debug.print("fsmeta daemon: git metadata watch released for {s}\n", .{arm.common_dir});
        }
        self.destroyArm(arm);
        return 0;
    }

    /// The root's `$GIT_DIR` moved (a gitfile was repaired, a worktree was moved): the prefix mapping changes and
    /// the watcher is left alone. The listener's new `git_dir` is arena-owned by the root, so it is stored as is.
    pub fn updateListener(self: *Registry, arm: *Arm, listener: *Listener, git_dir: []const u8) bool {
        self.lock();
        defer self.unlock();
        for (arm.listeners.items) |*candidate| {
            if (candidate.ctx == listener.ctx) {
                candidate.git_dir = git_dir;
                return true;
            }
        }
        return false;
    }

    fn lock(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io);
    }

    fn findLocked(self: *Registry, common_dir: []const u8) ?*Arm {
        for (self.arms.items) |arm| {
            if (samePath(arm.common_dir, common_dir)) return arm;
        }
        return null;
    }

    fn joinLocked(self: *Registry, arm: *Arm, listener: *Listener) !*Arm {
        try arm.listeners.append(self.allocator, listener.*);
        arm.refs += 1;
        return arm;
    }

    fn leaveLocked(arm: *Arm, listener: *Listener, remaining: *u32) bool {
        for (arm.listeners.items, 0..) |candidate, index| {
            // Identity is the context pointer: it is the root's own `Listener`, stable for its lifetime.
            if (candidate.ctx == listener.ctx) {
                _ = arm.listeners.orderedRemove(index);
                break;
            }
        }
        if (arm.refs > 0) arm.refs -= 1;
        remaining.* = arm.refs;
        return arm.refs == 0;
    }

    /// Arm one common dir. `Watcher.watch` registers the common dir itself and, on a per-directory backend, recurses
    /// through `recurse_watch`, which consults the arm's `should_watch` before every recursive `add_watch`: a refused
    /// directory such as `objects/` is never registered and its subtree is never opened. (On Windows/FSEvents there is
    /// one recursive registration and the filter is in `deliver` instead — see `Arm`.)
    fn createArm(self: *Registry, common_dir: []const u8) !*Arm {
        const owned = try self.allocator.dupe(u8, common_dir);
        const arm = self.allocator.create(Arm) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        arm.* = .{
            .registry = self,
            .common_dir = owned,
            .handler = .{ .vtable = &Arm.vtable },
        };
        if (!self.watch_platform) return arm;

        arm.watcher = Watcher.init(self.io, self.allocator, &arm.handler) catch |err| {
            self.destroyArm(arm);
            return err;
        };
        arm.watcher.?.watch(common_dir) catch |err| {
            arm.disarm();
            self.destroyArm(arm);
            return err;
        };
        std.debug.print("fsmeta daemon: git metadata watch armed for {s} ({d} registration(s), should_watch {s})\n", .{
            common_dir,
            arm.watcher.?.watch_count(),
            if (Watcher.filters_watches) "honoured by this backend" else "filtered in the handler (one recursive registration)",
        });
        return arm;
    }

    fn destroyArm(self: *Registry, arm: *Arm) void {
        arm.listeners.deinit(self.allocator);
        self.allocator.free(arm.common_dir);
        self.allocator.destroy(arm);
    }
};
// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn scratchPath(arena: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try dir.realPath(io, &buffer);
    return arena.dupe(u8, buffer[0..count]);
}

test "a path is found under a base across separators, and a sibling prefix is not" {
    try testing.expectEqualStrings("b", relativeTo("C:\\a", "C:\\a\\b").?);
    try testing.expectEqualStrings("b", relativeTo("C:\\a", "C:/a/b").?);
    try testing.expectEqualStrings("refs\\heads\\main", relativeTo("C:/a/.git", "C:\\a\\.git\\refs\\heads\\main").?);
    try testing.expectEqualStrings("", relativeTo("C:\\a\\.git", "C:\\a\\.git").?);
    try testing.expectEqualStrings("", relativeTo("C:\\a\\.git\\", "C:\\a\\.git").?);
    // Not a prefix: `a` must be a whole segment.
    try testing.expectEqual(@as(?[]const u8, null), relativeTo("C:\\a", "C:\\ab\\c"));
    try testing.expectEqual(@as(?[]const u8, null), relativeTo("C:\\a\\b", "C:\\a"));
    if (builtin.os.tag == .windows) {
        // Windows paths are case-insensitive; two spellings of one directory must not become two arms.
        try testing.expect(relativeTo("C:\\A\\.git", "c:\\a\\.git\\HEAD") != null);
        try testing.expect(samePath("C:\\A\\.git", "c:\\a\\.git"));
    }
    try testing.expect(samePath("C:\\a\\.git\\", "C:\\a\\.git"));
    try testing.expect(!samePath("C:\\a\\.git", "C:\\a\\.git\\worktrees\\wt"));
}

test "tree-changing, repo-wide and shared-ignore are told apart by path" {
    const common = "C:\\repo\\.git";
    const main_git = common;
    const worktree_git = "C:\\repo\\.git\\worktrees\\wt";

    // The main worktree's own files are tree-changing, even though its git dir *is* the common dir.
    for ([_][]const u8{ "HEAD", "index", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "BISECT_LOG", "logs\\HEAD" }) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ main_git, name });
        defer testing.allocator.free(path);
        try testing.expectEqual(Scope.tree, scopeOf(main_git, common, path));
    }
    // A lock in the git dir is tree-changing (it is the latch's own event); a ref lock is not.
    try testing.expectEqual(Scope.tree, scopeOf(main_git, common, "C:\\repo\\.git\\index.lock"));
    try testing.expectEqual(Scope.tree, scopeOf(main_git, common, "C:\\repo\\.git\\HEAD.lock"));
    // Refs, packed-refs, ref logs and worktree metadata are repo-wide: an event, never a pass of their own.
    for ([_][]const u8{ "refs\\heads\\main", "refs\\heads\\feat.lock", "packed-refs", "packed-refs.lock", "logs\\refs\\heads\\main", "worktrees\\wt", "worktrees\\wt\\gitdir", "worktrees\\wt\\locked" }) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ common, name });
        defer testing.allocator.free(path);
        try testing.expectEqual(Scope.repo, scopeOf(main_git, common, path));
    }
    // The shared ignore is repo-wide *and* tree-changing for every root.
    try testing.expectEqual(Scope.repo_tree, scopeOf(main_git, common, "C:\\repo\\.git\\info\\exclude"));
    // The four big directories, hooks and everything else are not metadata at all.
    for ([_][]const u8{ "objects\\ab\\cdef", "modules\\sub\\HEAD", "lfs\\objects\\x", "hooks\\post-checkout", "config", "COMMIT_EDITMSG" }) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}\\{s}", .{ common, name });
        defer testing.allocator.free(path);
        try testing.expectEqual(Scope.ignored, scopeOf(main_git, common, path));
    }

    // The prefix mapping: the same path is the worktree's tree and the main worktree's repo-wide event.
    try testing.expectEqual(Scope.tree, scopeOf(worktree_git, common, "C:\\repo\\.git\\worktrees\\wt\\HEAD"));
    try testing.expectEqual(Scope.tree, scopeOf(worktree_git, common, "C:\\repo\\.git\\worktrees\\wt\\index"));
    try testing.expectEqual(Scope.tree, scopeOf(worktree_git, common, "C:\\repo\\.git\\worktrees\\wt\\logs\\HEAD"));
    try testing.expectEqual(Scope.repo, scopeOf(worktree_git, common, "C:\\repo\\.git\\worktrees\\wt\\gitdir"));
    try testing.expectEqual(Scope.repo, scopeOf(worktree_git, common, "C:\\repo\\.git\\worktrees\\other\\HEAD"));
    try testing.expectEqual(Scope.repo, scopeOf(worktree_git, common, "C:\\repo\\.git\\refs\\heads\\main"));
    try testing.expectEqual(Scope.repo_tree, scopeOf(worktree_git, common, "C:\\repo\\.git\\info\\exclude"));
    // `HEAD` at the common root belongs to the main worktree: a linked worktree does not treat it as its own tree,
    // and it is not shared state either — so it is not that root's event at all.
    try testing.expectEqual(Scope.tree, scopeOf(main_git, common, "C:\\repo\\.git\\HEAD"));
    try testing.expectEqual(Scope.ignored, scopeOf(worktree_git, common, "C:\\repo\\.git\\HEAD"));

    // A path outside the repository is not this arm's business at all.
    try testing.expectEqual(Scope.ignored, scopeOf(main_git, common, "C:\\elsewhere\\HEAD"));
}

test "the watch predicate refuses the four big directories and admits only the metadata set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const common = "C:/repo/.git";
    const at = struct {
        fn path(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
        }
    }.path;

    // Directories that hold metadata: admitted, so their files can be watched.
    for ([_][]const u8{ "refs", "refs/heads", "logs", "logs/refs", "worktrees", "worktrees/wt", "info" }) |dir| {
        try testing.expect(shouldWatch(common, try at(arena, common, dir), .dir));
        const child = try std.fmt.allocPrint(arena, "{s}/{s}/x", .{ common, dir });
        try testing.expect(shouldWatch(common, child, .unknown));
    }
    // The balloon: refused at any depth, whichever type the backend reports.
    for ([_][]const u8{ "objects", "objects/ab", "objects/ab/cdef", "modules", "modules/sub", "lfs", "lfs/objects", "hooks" }) |dir| {
        const path = try at(arena, common, dir);
        try testing.expect(!shouldWatch(common, path, .dir));
        try testing.expect(!shouldWatch(common, path, .unknown));
    }
    // Files: the metadata set only.
    for ([_][]const u8{ "HEAD", "index", "ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "BISECT_LOG", "index.lock", "HEAD.lock", "shallow.lock", "packed-refs", "packed-refs.lock", "refs/heads/main", "logs/HEAD", "logs/refs/heads/main", "worktrees/wt/gitdir", "worktrees/wt/locked", "worktrees/wt/HEAD", "info/exclude" }) |name| {
        try testing.expect(shouldWatch(common, try at(arena, common, name), .file));
    }
    for ([_][]const u8{ "config", "description", "COMMIT_EDITMSG", "hooks/post-checkout", "objects/ab/cdef" }) |name| {
        try testing.expect(!shouldWatch(common, try at(arena, common, name), .file));
    }
    // The arm's own directory, and anything outside it.
    try testing.expect(shouldWatch(common, "C:/repo/.git", .dir));
    try testing.expect(!shouldWatch(common, "C:/repo/src/main.zig", .file));

    // The same predicate is the arm's `Handler.VTable.should_watch` — the function nightwatch calls at arm time and
    // for a directory created later on a per-directory backend. Construct the arm without a platform watcher and ask
    // it through the vtable, so the wiring (`Arm.shouldWatchCallback` -> `shouldWatch`) is pinned, not just the free
    // function above.
    var registry = Registry.initCounting(testing.io, testing.allocator);
    defer registry.deinit();
    var counter: Counting = .{};
    var listener = Listener{ .ctx = &counter, .notify = Counting.notify, .git_dir = common };
    const arm = try registry.acquire(common, &listener);
    defer _ = registry.release(arm, &listener);
    for ([_][]const u8{ "objects/ab/cdef", "modules/sub/HEAD", "lfs/objects/x", "hooks/post-checkout" }) |name| {
        const path = try at(arena, common, name);
        try testing.expect(!arm.handler.should_watch(path, .dir));
        try testing.expect(!arm.handler.should_watch(path, .file));
        try testing.expect(!arm.handler.should_watch(path, .unknown));
    }
    for ([_][]const u8{ "refs/heads/main", "HEAD", "index", "info/exclude" }) |name| {
        const path = try at(arena, common, name);
        try testing.expect(arm.handler.should_watch(path, .file));
        try testing.expect(arm.handler.should_watch(path, .unknown));
    }
}

test "the backend contract: filters_watches is true only where a watch is per directory" {
    // `filters_watches = !Backend.watches_recursively` (`nightwatch.zig:128`): true on a per-directory backend —
    // inotify on Linux, kqueue on macOS/BSD — where the generic layer consults `should_watch` while arming
    // (`recurse_watch`) and when a directory is created later (the interceptor's `change_cb`); false on Windows
    // (ReadDirectoryChangesW) and FSEvents, where one registration covers the subtree, the predicate is never
    // consulted, and `Arm.deliver` filters instead.
    //
    // This host runs the `false` leg: Windows. The `true` leg runs on Linux and on macOS/BSD (this build passes no
    // `macos_fsevents` option, so `nightwatch.Default` is kqueue there). Asserted at comptime as well as at runtime,
    // so a dependency bump that flips a backend fails on the platform it changed instead of silently here.
    const expected: bool = switch (builtin.os.tag) {
        .windows => false,
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => @compileError("nightwatch has no backend for this OS"),
    };
    comptime {
        if (Watcher.filters_watches != expected) {
            @compileError("nightwatch changed which backends consult should_watch: re-read the Arm contract");
        }
    }
    try testing.expectEqual(expected, Watcher.filters_watches);
}

test "the tree predicate admits the root, refuses .git/.fs-meta, and prunes a confirmed boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.createDirPath(io, ".fs-meta");
    try tmp.dir.createDirPath(io, "plain");
    try tmp.dir.createDirPath(io, "clone/.git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = "clone/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.createDirPath(io, "stray/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "stray/.git/notes.txt", .data = "fixture\n" });
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(io, "wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../main/.git/worktrees/wt\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &buffer);
    const root = try arena.dupe(u8, buffer[0..count]);
    const at = struct {
        fn path(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(allocator, &.{ base, name });
        }
    }.path;

    // The root is the walk's starting point and is always admitted — even when it is itself a worktree.
    try testing.expect(shouldWatchTree(arena, io, root, root, .dir));
    const wt_root = try at(arena, root, "wt");
    try testing.expect(shouldWatchTree(arena, io, wt_root, wt_root, .dir));

    // Internal names never get a registration of their own.
    try testing.expect(!shouldWatchTree(arena, io, root, try at(arena, root, ".git"), .dir));
    try testing.expect(!shouldWatchTree(arena, io, root, try at(arena, root, ".fs-meta"), .dir));

    // Ordinary directories are admitted; a confirmed nested repository is not; a stray `.git` fixture is.
    try testing.expect(shouldWatchTree(arena, io, root, try at(arena, root, "plain"), .dir));
    try testing.expect(!shouldWatchTree(arena, io, root, try at(arena, root, "clone"), .dir));
    try testing.expect(shouldWatchTree(arena, io, root, try at(arena, root, "stray"), .dir));
    try testing.expect(!shouldWatchTree(arena, io, root, try at(arena, root, "wt"), .dir));

    // Files are never refused here: the handler decides what a file event means.
    try testing.expect(shouldWatchTree(arena, io, root, try at(arena, root, "clone/.git/HEAD"), .file));
}

test "a lock is a latch only when it is this tree's lock" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "git/refs/heads");
    const base = try scratchPath(arena, tmp.dir, io);
    const git_dir = try std.fmt.allocPrint(arena, "{s}{c}git", .{ base, std.fs.path.sep });

    try testing.expect(!hasTreeLock(io, git_dir));

    // A shared ref lock is a ref update in flight: not a reason to defer this root's pass.
    try tmp.dir.writeFile(io, .{ .sub_path = "git/refs/heads/main.lock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "git/packed-refs.lock", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "git/refs/heads/main", .data = "ref\n" });
    try testing.expect(!hasTreeLock(io, git_dir));

    // Each of the three tree locks latches, and the poll — not a delete event — is what lifts it.
    for (tree_locks) |name| {
        const sub_path = try std.fmt.allocPrint(arena, "git/{s}", .{name});
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "" });
        try testing.expect(hasTreeLock(io, git_dir));
        try tmp.dir.deleteFile(io, sub_path);
        try testing.expect(!hasTreeLock(io, git_dir));
    }

    // A directory named like a lock is not a lock either.
    try tmp.dir.createDirPath(io, "git/index.lock");
    try testing.expect(!hasTreeLock(io, git_dir));
    // A missing git dir is "no lock", never an error.
    try testing.expect(!hasTreeLock(io, "C:/nowhere/at/all"));
    try testing.expect(!hasTreeLock(io, ""));
}

test "HEAD, detached HEAD and the in-progress markers are read without running git" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try scratchPath(arena, tmp.dir, io);
    const git_dir = try std.fmt.allocPrint(arena, "{s}{c}git", .{ base, std.fs.path.sep });
    try tmp.dir.createDirPath(io, "git");

    try tmp.dir.writeFile(io, .{ .sub_path = "git/HEAD", .data = "ref: refs/heads/feature/x\n" });
    var head = readHead(io, git_dir);
    try testing.expectEqualStrings("feature/x", head.text());
    try testing.expect(!head.detached);
    try testing.expectEqual(InProgress.none, readInProgress(io, git_dir));

    try tmp.dir.writeFile(io, .{ .sub_path = "git/HEAD", .data = "0123456789abcdef0123456789abcdef01234567\n" });
    head = readHead(io, git_dir);
    try testing.expect(head.detached);
    try testing.expectEqualStrings("detached:01234567", head.text());

    // A symref that is not a branch is reported as it is, rather than guessed at.
    try tmp.dir.writeFile(io, .{ .sub_path = "git/HEAD", .data = "ref: refs/tags/v1\n" });
    try testing.expectEqualStrings("refs/tags/v1", readHead(io, git_dir).text());

    // The markers, in the order a nested operation is resolved.
    try tmp.dir.writeFile(io, .{ .sub_path = "git/MERGE_HEAD", .data = "0123\n" });
    try testing.expectEqual(InProgress.merge, readInProgress(io, git_dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "git/CHERRY_PICK_HEAD", .data = "0123\n" });
    try testing.expectEqual(InProgress.merge, readInProgress(io, git_dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "git/REVERT_HEAD", .data = "0123\n" });
    try testing.expectEqual(InProgress.merge, readInProgress(io, git_dir));
    try tmp.dir.createDirPath(io, "git/rebase-merge");
    try testing.expectEqual(InProgress.rebase, readInProgress(io, git_dir));
    try tmp.dir.deleteTree(io, "git/rebase-merge");
    try tmp.dir.deleteFile(io, "git/MERGE_HEAD");
    try testing.expectEqual(InProgress.cherry_pick, readInProgress(io, git_dir));
    try tmp.dir.deleteFile(io, "git/CHERRY_PICK_HEAD");
    try testing.expectEqual(InProgress.revert, readInProgress(io, git_dir));
    try tmp.dir.deleteFile(io, "git/REVERT_HEAD");
    try tmp.dir.writeFile(io, .{ .sub_path = "git/BISECT_LOG", .data = "git bisect start\n" });
    try testing.expectEqual(InProgress.bisect, readInProgress(io, git_dir));

    // A git dir that vanishes is an empty answer, not an error: a root can go missing between two status reads.
    try tmp.dir.deleteTree(io, "git");
    try testing.expectEqualStrings("", readHead(io, git_dir).text());
    try testing.expectEqual(InProgress.none, readInProgress(io, git_dir));
    try testing.expectEqualStrings("", readHead(io, "").text());
}

test "a metadata path names the operation kind the wire will report" {
    const common = "C:\\repo\\.git";
    const main_git = common;
    const wt_git = "C:\\repo\\.git\\worktrees\\wt";
    // Tree-changing files, per root.
    try testing.expectEqual(Change{ .scope = .tree, .kind = .branch }, changeOf(main_git, common, "C:\\repo\\.git\\HEAD"));
    try testing.expectEqual(Change{ .scope = .tree, .kind = .index }, changeOf(main_git, common, "C:\\repo\\.git\\index"));
    try testing.expectEqual(Change{ .scope = .tree, .kind = .merge }, changeOf(main_git, common, "C:\\repo\\.git\\MERGE_HEAD"));
    try testing.expectEqual(Change{ .scope = .tree, .kind = .rebase }, changeOf(main_git, common, "C:\\repo\\.git\\REBASE_HEAD"));
    try testing.expectEqual(Change{ .scope = .tree, .kind = .rebase }, changeOf(main_git, common, "C:\\repo\\.git\\rebase-merge\\head-name"));
    try testing.expectEqual(Change{ .scope = .tree, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\ORIG_HEAD"));
    try testing.expectEqual(Change{ .scope = .tree, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\logs\\HEAD"));
    // A lock is a latch, not an event: no kind, no frame — `index.lock` for this root's tree, and a shared ref lock
    // (`refs/heads/feat.lock`, `packed-refs.lock`) as well, because the durable rename that follows it is the event.
    try testing.expectEqual(Change{ .scope = .ignored, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\index.lock"));
    try testing.expectEqual(Change{ .scope = .ignored, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\refs\\heads\\feat.lock"));
    try testing.expectEqual(Change{ .scope = .ignored, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\packed-refs.lock"));
    // Repo-wide: a branch ref is a commit, the rest of the shared state is `other`, and worktree metadata is a
    // worktree event even for the main root.
    try testing.expectEqual(Change{ .scope = .repo, .kind = .commit }, changeOf(main_git, common, "C:\\repo\\.git\\refs\\heads\\main"));
    try testing.expectEqual(Change{ .scope = .repo, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\refs\\stash"));
    try testing.expectEqual(Change{ .scope = .repo, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\packed-refs"));
    try testing.expectEqual(Change{ .scope = .repo, .kind = .worktree }, changeOf(main_git, common, "C:\\repo\\.git\\worktrees\\wt"));
    try testing.expectEqual(Change{ .scope = .repo, .kind = .worktree }, changeOf(wt_git, common, "C:\\repo\\.git\\worktrees\\other\\gitdir"));
    // The worktree's own HEAD is a branch event for it, and nothing at all for its sibling.
    try testing.expectEqual(Change{ .scope = .tree, .kind = .branch }, changeOf(wt_git, common, "C:\\repo\\.git\\worktrees\\wt\\HEAD"));
    try testing.expectEqual(Change{ .scope = .ignored, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\objects\\ab\\cdef"));
    try testing.expectEqual(Change{ .scope = .repo_tree, .kind = .other }, changeOf(main_git, common, "C:\\repo\\.git\\info\\exclude"));
}

test "a stray .git directory is not a repository, and a broken gitfile is a state" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try scratchPath(arena, tmp.dir, io);
    const git_dir = try std.fmt.allocPrint(arena, "{s}{c}git", .{ base, std.fs.path.sep });

    // An empty directory named `.git`, and one with only a HEAD: neither is a repository (§ 4).
    try tmp.dir.createDirPath(io, "git");
    try testing.expect(!confirms(io, .{ .git_dir = git_dir, .common_dir = git_dir, .is_gitfile = false }));
    try tmp.dir.writeFile(io, .{ .sub_path = "git/HEAD", .data = "ref: refs/heads/main\n" });
    try testing.expect(!confirms(io, .{ .git_dir = git_dir, .common_dir = git_dir, .is_gitfile = false }));
    // A real main worktree: HEAD plus objects/.
    try tmp.dir.createDirPath(io, "git/objects");
    try testing.expect(confirms(io, .{ .git_dir = git_dir, .common_dir = git_dir, .is_gitfile = false }));

    // A linked worktree's git dir has no objects/ of its own, but its gitfile names it explicitly: HEAD is enough.
    try tmp.dir.createDirPath(io, "linked");
    try tmp.dir.writeFile(io, .{ .sub_path = "linked/HEAD", .data = "ref: refs/heads/wt\n" });
    const linked = try std.fmt.allocPrint(arena, "{s}{c}linked", .{ base, std.fs.path.sep });
    try testing.expect(confirms(io, .{ .git_dir = linked, .common_dir = linked, .is_gitfile = true }));
    try tmp.dir.deleteFile(io, "linked/HEAD");
    try testing.expect(!confirms(io, .{ .git_dir = linked, .common_dir = linked, .is_gitfile = true }));

    // A path that does not exist is not a repository either.
    try testing.expect(!confirms(io, .{ .git_dir = "C:/nowhere/.git", .common_dir = "C:/nowhere/.git", .is_gitfile = false }));
}

const Counting = struct {
    count: u32 = 0,
    fn notify(ctx: *anyopaque, _: Change, _: []const u8) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

test "one arm per common dir, refcounted by the roots that share it" {
    var registry = Registry.initCounting(testing.io, testing.allocator);
    defer registry.deinit();

    var first_count: Counting = .{};
    var second_count: Counting = .{};
    var first = Listener{ .ctx = &first_count, .notify = Counting.notify, .git_dir = "C:\\repo\\.git" };
    var second = Listener{ .ctx = &second_count, .notify = Counting.notify, .git_dir = "C:\\repo\\.git\\worktrees\\wt" };

    // Two roots of one repo: one arm, even when the common dir is spelled with different separators and case.
    const arm = try registry.acquire("C:\\repo\\.git", &first);
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqual(@as(u32, 1), registry.rootCount(arm));
    const same = try registry.acquire("c:/repo/.git", &second);
    try testing.expectEqual(arm, same);
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqual(@as(u32, 2), registry.rootCount(arm));

    // Removing one leaves the arm; removing the last disarms it.
    try testing.expectEqual(@as(u32, 1), registry.release(arm, &first));
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqual(@as(u32, 0), registry.release(same, &second));
    try testing.expectEqual(@as(usize, 0), registry.count());

    // A different repository is a different arm, and each is released on its own.
    const other = try registry.acquire("C:\\other\\.git", &first);
    try testing.expectEqual(@as(usize, 1), registry.count());
    _ = registry.release(other, &first);
    try testing.expectEqual(@as(usize, 0), registry.count());

    // Acquiring again after a full release arms anew rather than resurrecting the dead one.
    const again = try registry.acquire("C:\\repo\\.git", &first);
    try testing.expectEqual(@as(u32, 1), registry.rootCount(again));
    try testing.expectEqual(@as(usize, 1), registry.count());
    _ = registry.release(again, &first);
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "a listener is re-mapped to a new git dir for the same arm" {
    var registry = Registry.initCounting(testing.io, testing.allocator);
    defer registry.deinit();
    var counter: Counting = .{};
    var listener = Listener{ .ctx = &counter, .notify = Counting.notify, .git_dir = "C:\\repo\\.git" };
    const arm = try registry.acquire("C:\\repo\\.git", &listener);
    try testing.expect(registry.updateListener(arm, &listener, "C:\\repo\\.git\\worktrees\\wt"));
    try testing.expectEqualStrings("C:\\repo\\.git\\worktrees\\wt", arm.listeners.items[0].git_dir);
    _ = registry.release(arm, &listener);
}

test "resolution and classification agree for a real worktree layout" {
    // The layout `gitdir.resolve` handles (gitfile + commondir), tied to the classification that consumes it: the
    // same path is the worktree's tree change and the main worktree's repo-wide event.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(io, "main/.git/objects");
    try tmp.dir.createDirPath(io, "wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = "../..\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../main/.git/worktrees/wt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/worktrees/wt/HEAD", .data = "ref: refs/heads/wt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.git/HEAD", .data = "ref: refs/heads/main\n" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try scratchPath(arena, tmp.dir, io);
    const main_root = try std.fs.path.join(arena, &.{ base, "main" });
    const wt_root = try std.fs.path.join(arena, &.{ base, "wt" });

    const main = (try gitdir.resolve(arena, io, main_root)).?;
    const worktree = (try gitdir.resolve(arena, io, wt_root)).?;
    try testing.expect(worktree.is_gitfile);
    try testing.expect(samePath(main.common_dir, worktree.common_dir));

    const head_path = try std.fs.path.join(arena, &.{ worktree.git_dir, "HEAD" });
    try testing.expectEqual(Scope.tree, scopeOf(worktree.git_dir, worktree.common_dir, head_path));
    try testing.expectEqual(Scope.repo, scopeOf(main.git_dir, main.common_dir, head_path));

    // A refs update is repo-wide for both, and an object is watched by neither.
    const ref_path = try std.fs.path.join(arena, &.{ main.common_dir, "refs", "heads", "main" });
    try testing.expectEqual(Scope.repo, scopeOf(worktree.git_dir, worktree.common_dir, ref_path));
    try testing.expectEqual(Scope.repo, scopeOf(main.git_dir, main.common_dir, ref_path));
    const object_path = try std.fs.path.join(arena, &.{ main.common_dir, "objects", "ab", "cdef" });
    try testing.expectEqual(Scope.ignored, scopeOf(main.git_dir, main.common_dir, object_path));
    try testing.expect(!shouldWatch(main.common_dir, object_path, .file));

    // The watch is the common dir alone: the working tree is not part of it.
    try testing.expect(!shouldWatch(main.common_dir, try std.fs.path.join(arena, &.{ wt_root, "README" }), .file));
}
