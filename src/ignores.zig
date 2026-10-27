// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The two root-level ignore sources of `plans/worktrees.md` § 5:
//!
//! * `<root>/.fs-meta/ignore` — fs-meta's own file. Its **user part** and its **managed block** (`# fsmeta-managed`)
//!   are two sub-sources: the block is evaluated after the user's lines, so a `!` written by a user cannot re-expose
//!   a nested root the managed block keeps out, while a `!` inside the block can (the plan's own escape hatch).
//! * `<common>/info/exclude` — git's repo-local exclude file. `<common>` is resolved by `gitdir.resolve`; when the
//!   root is not a repository the source simply does not exist.
//!
//! Both are parsed by the **existing** `gitignore.Rules` reader; this module adds no pattern syntax. It is also the
//! home of `appendManaged`, the writer M2 uses to put a nested root under the managed block. The write is atomic
//! (a temporary file, then a rename), the same discipline as `roots.json`.
//!
//! ## Precedence, and the no-cross-source negation rule
//!
//! The sources are consulted in the plan's order: the root's `.gitignore` chain (in the walker/lister, not here),
//! then `info/exclude`, then `.fs-meta/ignore`. A source's `!` only affects that source. `decide` therefore stops at
//! the first source that **excludes**: a later `!` is never asked, so it cannot re-include an earlier exclusion. A
//! negation that a source applies to one of its own earlier patterns still works, because `gitignore.Rules` answers
//! the source as a whole.
//!
//! **No mtime, no copy.** `load` is called on every pass and every walk: a hand edit takes effect on the next one.

const std = @import("std");
const gitignore = @import("gitignore.zig");
const gitdir = @import("gitdir.zig");

/// The source tokens used in `files.json`'s `scan.ignoreSources` and by `fsmeta ignored`. They name the source, not
/// necessarily the file: the `.gitignore` chain is a source even when no file in the tree is named that.
pub const Source = enum {
    gitignore,
    info_exclude,
    fs_meta,

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .gitignore => "gitignore",
            .info_exclude => "info/exclude",
            .fs_meta => "fs-meta/ignore",
        };
    }
};

/// The first line of the block M2 owns in `.fs-meta/ignore`.
pub const managed_marker = "# fsmeta-managed";

/// The file under `.fs-meta`.
pub const ignore_file_name = "ignore";

/// One parsed `.fs-meta/ignore` plus git's `info/exclude`, read once and consulted for the whole pass.
pub const Sources = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    respect_gitignore: bool,
    /// `<common>/info/exclude`; `null` when the root is not a repository or the file is absent.
    info_exclude: ?gitignore.Rules = null,
    /// The lines of `.fs-meta/ignore` above the managed marker (or the whole file when there is no marker).
    fs_meta_user: ?gitignore.Rules = null,
    /// The lines after the managed marker. Evaluated last, so a `!` here can undo a user line (the escape hatch).
    fs_meta_managed: ?gitignore.Rules = null,
    /// The sources actually in effect, in precedence order, for `scan.ignoreSources`.
    active: []const []const u8 = &.{},

    /// Read both files. A missing or unreadable file is an absent source, never a failed pass; a malformed pattern is
    /// a line the existing parser skips, which is the plan's rule too. Strings and rules belong to `arena`.
    pub fn load(arena: std.mem.Allocator, io: std.Io, root: []const u8, respect_gitignore: bool) !Sources {
        var self: Sources = .{
            .arena = arena,
            .io = io,
            .root = root,
            .respect_gitignore = respect_gitignore,
        };

        var active: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer active.deinit(arena);

        if (respect_gitignore) {
            // The `.gitignore` chain is always consulted when the flag allows it; whether one exists is the tree's
            // business, not a configuration fact. The two file-backed sources are listed only when their file is.
            try active.append(arena, Source.gitignore.name());
            if (try gitdir.resolve(arena, io, root)) |location| {
                if (try readCommon(arena, io, location.common_dir, "info/exclude")) |text| {
                    self.info_exclude = try gitignore.Rules.parse(arena, text);
                    try active.append(arena, Source.info_exclude.name());
                }
            }
        }

        if (try readRoot(arena, io, root, ".fs-meta/ignore")) |text| {
            const split = splitManaged(text);
            self.fs_meta_user = try gitignore.Rules.parse(arena, split.user);
            if (split.managed) |managed| {
                self.fs_meta_managed = try gitignore.Rules.parse(arena, managed);
            }
            try active.append(arena, Source.fs_meta.name());
        }

        self.active = try active.toOwnedSlice(arena);
        return self;
    }

    pub fn deinit(self: *Sources) void {
        if (self.info_exclude) |*rules| rules.deinit();
        if (self.fs_meta_user) |*rules| rules.deinit();
        if (self.fs_meta_managed) |*rules| rules.deinit();
        self.* = undefined;
    }

    /// Whether either file-backed source has at least one pattern. The walker/lister uses this to skip the matcher
    /// (and the path construction) on the common tree that has neither file.
    pub fn hasRules(self: Sources) bool {
        return ruleCount(self.info_exclude) > 0 or ruleCount(self.fs_meta_user) > 0 or
            ruleCount(self.fs_meta_managed) > 0;
    }

    /// Which source, if any, excludes `rel_path` (root-relative, `/`-separated, no trailing slash).
    ///
    /// The `.gitignore` chain is not part of this answer: its state lives in the walker (a stack of files) and in the
    /// lister (`gitignore.Stack`). Its exclusion outranks both sources here, and a `!` in either of them cannot undo
    /// it because this function is only reached when the chain did not exclude.
    pub fn decide(self: Sources, rel_path: []const u8, is_dir: bool) ?Source {
        if (self.info_exclude) |rules| {
            if (rules.decide(rel_path, is_dir) orelse false) return .info_exclude;
        }
        var user_excluded = false;
        if (self.fs_meta_user) |rules| {
            user_excluded = rules.decide(rel_path, is_dir) orelse false;
        }
        if (self.fs_meta_managed) |rules| {
            if (rules.decide(rel_path, is_dir)) |decision| {
                if (decision) return .fs_meta;
                // A managed `!` is the escape hatch: it re-includes what the user's part excluded. Nothing above
                // this source is re-opened, because each earlier source already returned.
                return null;
            }
        }
        if (user_excluded) return .fs_meta;
        return null;
    }
};

fn ruleCount(rules: ?gitignore.Rules) usize {
    return if (rules) |parsed| parsed.ruleCount() else 0;
}

fn openRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{})
    else
        std.Io.Dir.cwd().openDir(io, root, .{});
}

fn openDirAny(io: std.Io, path: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openDir(io, path, .{});
}

/// Read a file below the root as a source. Absence, a directory of that name and a permission failure are all "the
/// source does not exist"; only an allocation failure is an error, because that is the pass's own failure.
fn readRoot(arena: std.mem.Allocator, io: std.Io, root: []const u8, sub_path: []const u8) !?[]u8 {
    var dir = openRoot(io, root) catch return null;
    defer dir.close(io);
    return readLimited(arena, io, dir, sub_path);
}

fn readCommon(arena: std.mem.Allocator, io: std.Io, common_dir: []const u8, sub_path: []const u8) !?[]u8 {
    var dir = openDirAny(io, common_dir) catch return null;
    defer dir.close(io);
    return readLimited(arena, io, dir, sub_path);
}

fn readLimited(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, sub_path, arena, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

/// Where the managed block starts and the two texts it separates. A marker line at EOF means an empty managed part.
const ManagedSplit = struct { user: []const u8, managed: ?[]const u8 };

fn splitManaged(text: []const u8) ManagedSplit {
    const at = findMarker(text) orelse return .{ .user = text, .managed = null };
    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    const start = if (line_end < text.len) line_end + 1 else text.len;
    return .{ .user = text[0..at], .managed = text[start..] };
}

/// The byte offset of the `# fsmeta-managed` line, or `null` when the file has none. CRLF is accepted.
fn findMarker(text: []const u8) ?usize {
    var offset: usize = 0;
    while (offset <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[offset..end], "\r");
        if (std.mem.eql(u8, line, managed_marker)) return offset;
        if (end == text.len) break;
        offset = end + 1;
    }
    return null;
}

// ---------------------------------------------------------------------------------------------------------------
// M2's append helper
// ---------------------------------------------------------------------------------------------------------------

/// Append `path` under the `# fsmeta-managed` block of `<root>/.fs-meta/ignore`, creating the directory and the file
/// when they are absent. The entry is directory-shaped (`path/`), root-relative and `/`-separated.
///
/// **Idempotent**: an exact entry anywhere in the file is a no-op. The file is replaced atomically — a temporary
/// beside it and a rename — because a pass may be reading it under the parent's lock.
///
/// A path that cannot be represented in a line-based gitignore file is refused rather than mangled:
/// * a newline, carriage return or NUL (`error.InvalidPath`);
/// * an absolute path, `.` or `..` (`error.InvalidPath`);
/// * a path that starts with `!` or `#` or contains `*`, `?`, `[` or `]` **is** representable: the characters are
///   escaped with gitignore's backslash escape. A path starting with `!` is therefore escaped, not refused.
pub fn appendManaged(arena: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) !void {
    const entry = try managedEntry(arena, path);

    var root_dir = openRoot(io, root) catch return error.RootMissing;
    defer root_dir.close(io);
    var meta_dir = try openOrCreateMeta(io, root_dir);
    defer meta_dir.close(io);

    const existing = readIgnore(arena, io, meta_dir) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (existing) |text| {
        if (hasLine(text, entry)) return;
        const updated = try appendUnderBlock(arena, text, entry);
        try writeAtomic(meta_dir, io, updated);
    } else {
        const updated = try std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ managed_marker, entry });
        try writeAtomic(meta_dir, io, updated);
    }
}

/// Replace the managed block with exactly `paths` (each directory-shaped and escaped like `appendManaged`),
/// leaving everything above the `# fsmeta-managed` marker byte-for-byte intact. A path that was served before and
/// is not in `paths` is dropped; a path that is already there is not duplicated. M2 reconciliation uses this, and it
/// is the operation that makes "a user's own lines survive a managed-block rewrite" true.
///
/// An absent file with no paths stays absent; an existing block is rewritten to an empty one rather than removed,
/// so the marker keeps saying where the managed entries belong.
pub fn rewriteManaged(arena: std.mem.Allocator, io: std.Io, root: []const u8, paths: []const []const u8) !void {
    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer entries.deinit(arena);
    for (paths) |path| {
        const entry = try managedEntry(arena, path);
        if (!hasEntry(entries.items, entry)) try entries.append(arena, entry);
    }
    // Deterministic block order, independent of the order roots happened to be added in.
    std.mem.sort([]const u8, entries.items, {}, lessThanSlice);

    var root_dir = openRoot(io, root) catch return error.RootMissing;
    defer root_dir.close(io);
    var meta_dir = root_dir.openDir(io, ".fs-meta", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (entries.items.len == 0) return;
            try root_dir.createDirPath(io, ".fs-meta");
            var created = try root_dir.openDir(io, ".fs-meta", .{});
            defer created.close(io);
            const text = try renderManaged(arena, "", entries.items);
            try writeAtomic(created, io, text);
            return;
        },
        else => return err,
    };
    defer meta_dir.close(io);

    const existing = readIgnore(arena, io, meta_dir) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const text = existing orelse "";
    // A file with user lines and no managed marker is not ours to make a block in when there is nothing to manage.
    if (entries.items.len == 0 and findMarker(text) == null) return;

    const updated = try renderManaged(arena, userPart(text), entries.items);
    if (existing != null and std.mem.eql(u8, existing.?, updated)) return;
    try writeAtomic(meta_dir, io, updated);
}

fn lessThanSlice(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

// ---------------------------------------------------------------------------------------------------------------
// `fsmeta exclude`: the marked block in git's repo-local exclude file
// ---------------------------------------------------------------------------------------------------------------

/// The two lines `fsmeta exclude` owns in `<common>/info/exclude` (`plans/worktrees.md` § 5f, M7). The marker names
/// us so a person can find the edit; the entry hides `.fs-meta` from git's "untracked files" test, which is what
/// makes `git worktree remove` of a served worktree work without `--force`.
pub const exclude_marker = "# fsmeta: our own directory";
pub const exclude_entry = ".fs-meta/";

/// Append the marked block to `<common>/info/exclude`, creating `info/` and the file when they are absent.
///
/// **Idempotent**: when the marker and the entry are already present, nothing is written and `false` is returned.
/// **LF only**: the append uses `\n` even when the existing file ended with CRLF, so the bytes we add are the ones
/// tests can assert. **Atomic**: a temporary beside the file, then a rename, the same discipline as `roots.json` and
/// `.fs-meta/ignore` — git may be reading the file while we rewrite it.
///
/// A *later* `!` line in the same file overrides the entry (git's last-match-wins rule); the docs say so rather than
/// pretending the block cannot be undone.
pub fn appendExclude(arena: std.mem.Allocator, io: std.Io, common_dir: []const u8) !bool {
    var dir = openDirAny(io, common_dir) catch return error.RootMissing;
    defer dir.close(io);

    var info = dir.openDir(io, "info", .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try dir.createDirPath(io, "info");
            break :blk try dir.openDir(io, "info", .{});
        },
        else => return err,
    };
    defer info.close(io);

    const existing = info.readFileAlloc(io, "exclude", arena, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    const updated = if (existing) |text| blk: {
        if (hasExcludeBlock(text)) return false;
        break :blk try appendExcludeBlock(arena, text);
    } else try std.fmt.allocPrint(arena, "{s}\n{s}\n", .{ exclude_marker, exclude_entry });
    try writeAtomicNamed(info, io, "exclude", updated);
    return true;
}

/// Whether the marker is present and the entry follows it. Both are required: a half-edited block (the marker left,
/// the entry removed) is repaired by appending the block again, which is still idempotent from then on.
fn hasExcludeBlock(text: []const u8) bool {
    var offset: usize = 0;
    var marker_seen = false;
    while (offset <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[offset..end], "\r");
        if (std.mem.eql(u8, line, exclude_marker)) {
            marker_seen = true;
        } else if (marker_seen and std.mem.eql(u8, line, exclude_entry)) {
            return true;
        }
        if (end == text.len) break;
        offset = end + 1;
    }
    return false;
}

/// The existing bytes, then (after a newline if the file did not end with one) the marker and the entry.
fn appendExcludeBlock(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try writer.writeByte('\n');
    try writer.writeAll(exclude_marker);
    try writer.writeByte('\n');
    try writer.writeAll(exclude_entry);
    try writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn hasEntry(entries: []const []const u8, wanted: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry, wanted)) return true;
    return false;
}

/// The bytes above the marker when there is one, the whole file otherwise. The marker line itself is not a user line.
fn userPart(text: []const u8) []const u8 {
    const at = findMarker(text) orelse return text;
    return text[0..at];
}

/// The user part, then the marker, then one entry per line. The separator before a marker appended to a file that
/// did not end in a newline is added here, so the user's last line is not glued to our comment.
fn renderManaged(arena: std.mem.Allocator, user: []const u8, entries: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll(user);
    if (user.len > 0 and user[user.len - 1] != '\n') try writer.writeByte('\n');
    try writer.writeAll(managed_marker);
    try writer.writeByte('\n');
    for (entries) |entry| {
        try writer.writeAll(entry);
        try writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn openOrCreateMeta(io: std.Io, root_dir: std.Io.Dir) !std.Io.Dir {
    return root_dir.openDir(io, ".fs-meta", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try root_dir.createDirPath(io, ".fs-meta");
            return root_dir.openDir(io, ".fs-meta", .{});
        },
        else => return err,
    };
}

fn readIgnore(arena: std.mem.Allocator, io: std.Io, meta_dir: std.Io.Dir) ![]u8 {
    return meta_dir.readFileAlloc(io, ignore_file_name, arena, std.Io.Limit.limited(1 << 20));
}

/// The escaped, directory-shaped line an entry needs. `!` and `#` are escaped only where gitignore treats them
/// specially (the first byte); the wildcard bytes are escaped everywhere so a literal `[id]` stays literal.
fn managedEntry(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, '\n') != null or
        std.mem.indexOfScalar(u8, path, '\r') != null or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;

    var trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..") or
        std.mem.startsWith(u8, trimmed, "./") or std.mem.startsWith(u8, trimmed, "../")) return error.InvalidPath;
    // A backslash is a path separator on Windows and is not a legal stored name on POSIX (`FORMAT.md` § 3), so it is
    // normalised to `/` rather than escaped as a literal byte.
    if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) {
        const normalised = try arena.dupe(u8, trimmed);
        for (normalised) |*byte| if (byte.* == '\\') {
            byte.* = '/';
        };
        trimmed = normalised;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    for (trimmed, 0..) |byte, index| {
        if (index == 0 and (byte == '!' or byte == '#')) try writer.writeByte('\\');
        switch (byte) {
            '*', '?', '[', ']' => try writer.writeByte('\\'),
            else => {},
        }
        try writer.writeByte(byte);
    }
    try writer.writeByte('/');
    return out.toOwnedSlice();
}

/// An exact line, CRLF tolerated. It may be in the user's part or in the managed block: either way the path is already
/// represented, and a second line would be a duplicate.
fn hasLine(text: []const u8, entry: []const u8) bool {
    var offset: usize = 0;
    while (offset <= text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[offset..end], "\r");
        if (std.mem.eql(u8, line, entry)) return true;
        if (end == text.len) break;
        offset = end + 1;
    }
    return false;
}

/// Append the entry at the end of the file. Everything after the marker belongs to the managed block, so appending at
/// EOF keeps it inside the block even when a hand edit has put lines below the last managed one.
fn appendUnderBlock(arena: std.mem.Allocator, text: []const u8, entry: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll(text);
    if (text.len > 0 and text[text.len - 1] != '\n') try writer.writeByte('\n');
    if (findMarker(text) == null) {
        try writer.writeAll(managed_marker);
        try writer.writeByte('\n');
    }
    try writer.writeAll(entry);
    try writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeAtomic(meta_dir: std.Io.Dir, io: std.Io, bytes: []const u8) !void {
    return writeAtomicNamed(meta_dir, io, ignore_file_name, bytes);
}

/// Write `name` through `name.tmp` and a rename, beside the file that is being replaced.
fn writeAtomicNamed(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const temporary = std.fmt.bufPrint(&buffer, "{s}.tmp", .{name}) catch return error.NameTooLong;
    try dir.writeFile(io, .{ .sub_path = temporary, .data = bytes });
    try std.Io.Dir.rename(dir, temporary, dir, name, io);
}

// ---------------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------------

const testing = std.testing;

const TestArena = struct {
    state: std.heap.ArenaAllocator,

    fn init() TestArena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestArena) void {
        self.state.deinit();
    }

    fn allocator(self: *TestArena) std.mem.Allocator {
        return self.state.allocator();
    }
};

fn tmpRoot(io: std.Io, dir: std.Io.Dir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const count = try dir.realPath(io, buffer);
    return buffer[0..count];
}

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(name) orelse ".");
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

fn readText(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, name, arena, std.Io.Limit.limited(1 << 20));
}

test "the two file sources are read and the precedence lists them in plan order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".git/info/exclude", "cache/\n");
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "worktrees/w1/\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();
    var sources = try Sources.load(arena.allocator(), io, root, true);
    defer sources.deinit();

    try testing.expectEqual(@as(usize, 3), sources.active.len);
    try testing.expectEqualStrings("gitignore", sources.active[0]);
    try testing.expectEqualStrings("info/exclude", sources.active[1]);
    try testing.expectEqualStrings("fs-meta/ignore", sources.active[2]);
    try testing.expectEqual(Source.info_exclude, sources.decide("cache", true).?);
    try testing.expectEqual(Source.fs_meta, sources.decide("worktrees/w1", true).?);
    try testing.expect(sources.decide("other", false) == null);
}

test "a missing source is absent from the list, not present as an empty entry" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();
    var sources = try Sources.load(arena.allocator(), io, root, true);
    defer sources.deinit();
    try testing.expectEqual(@as(usize, 1), sources.active.len);
    try testing.expectEqualStrings("gitignore", sources.active[0]);

    // `--no-gitignore` disables the chain and git's own source; `.fs-meta/ignore` is still fs-meta's guard.
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "worktrees/w1/\n");
    var off = try Sources.load(arena.allocator(), io, root, false);
    defer off.deinit();
    try testing.expectEqual(@as(usize, 1), off.active.len);
    try testing.expectEqualStrings("fs-meta/ignore", off.active[0]);
    try testing.expectEqual(Source.fs_meta, off.decide("worktrees/w1", true).?);
}

test "a later source cannot re-include an earlier exclusion" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".git/info/exclude", "cache/\n!cache/\n"); // its own negation, not a cross-source one
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "cache/\n!cache/\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();
    var sources = try Sources.load(arena.allocator(), io, root, true);
    defer sources.deinit();

    // Both files negate their own pattern, so neither excludes: a `!` cancels within its own source.
    try testing.expect(sources.decide("cache", true) == null);

    // Now `info/exclude` excludes and the later `.fs-meta/ignore` negates: the earlier decision stands.
    try writeFile(tmp.dir, io, ".git/info/exclude", "cache/\n");
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "!cache/\n");
    var second = try Sources.load(arena.allocator(), io, root, true);
    defer second.deinit();
    try testing.expectEqual(Source.info_exclude, second.decide("cache", true).?);
}

test "the managed block is evaluated after the user's lines" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".fs-meta/ignore",
        \\worktrees/
        \\# fsmeta-managed
        \\!worktrees/w1/
        \\
    );

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();
    var sources = try Sources.load(arena.allocator(), io, root, true);
    defer sources.deinit();

    // A user line excludes `worktrees`, but the managed block's `!` is the escape hatch for w1 ...
    try testing.expect(sources.decide("worktrees/w1", true) == null);
    // ... and `w2` remains excluded by the user's part.
    try testing.expectEqual(Source.fs_meta, sources.decide("worktrees/w2", true).?);

    // The reverse: the managed block excludes, and a user `!` before it cannot re-include.
    try writeFile(tmp.dir, io, ".fs-meta/ignore",
        \\!worktrees/w1/
        \\# fsmeta-managed
        \\worktrees/w1/
        \\
    );
    var second = try Sources.load(arena.allocator(), io, root, true);
    defer second.deinit();
    try testing.expectEqual(Source.fs_meta, second.decide("worktrees/w1", true).?);
}

test "a linked worktree reads info/exclude from the common dir, not its own git dir" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // main/.git is the common dir; the worktree's own git dir is main/.git/worktrees/wt.
    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try writeFile(tmp.dir, io, "main/.git/info/exclude", "cache/\n");
    try writeFile(tmp.dir, io, "main/.git/worktrees/wt/commondir", "../..\n");
    try writeFile(tmp.dir, io, "wt/.git", "gitdir: ../main/.git/worktrees/wt\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const root = try std.fs.path.join(arena.allocator(), &.{ base, "wt" });

    var sources = try Sources.load(arena.allocator(), io, root, true);
    defer sources.deinit();
    try testing.expectEqual(@as(usize, 2), sources.active.len); // gitignore + info/exclude
    try testing.expectEqualStrings("info/exclude", sources.active[1]);
    try testing.expectEqual(Source.info_exclude, sources.decide("cache", true).?);
}

test "appendManaged writes a directory entry under the managed block" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try appendManaged(allocator, io, root, "worktrees/w1");
    const first = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings("# fsmeta-managed\nworktrees/w1/\n", first);

    // Idempotent: the same request does not add a second line.
    try appendManaged(allocator, io, root, "worktrees/w1/");
    const second = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings(first, second);

    // The file it wrote is a source the loader accepts.
    var sources = try Sources.load(allocator, io, root, true);
    defer sources.deinit();
    try testing.expectEqual(Source.fs_meta, sources.decide("worktrees/w1", true).?);
}

test "appendManaged keeps a user's part and appends a missing marker" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "*.log\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try appendManaged(allocator, io, root, "nested/root");
    const text = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings("*.log\n# fsmeta-managed\nnested/root/\n", text);
}

test "appendManaged recreates a deleted parent" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try appendManaged(allocator, io, root, "child");
    try tmp.dir.deleteFile(io, ".fs-meta/ignore");
    try tmp.dir.deleteDir(io, ".fs-meta");
    try appendManaged(allocator, io, root, "child");
    const text = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings("# fsmeta-managed\nchild/\n", text);
}

test "appendManaged escapes spaces, a leading ! and a character class" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try appendManaged(allocator, io, root, "my worktrees/w1");
    try appendManaged(allocator, io, root, "!important");
    try appendManaged(allocator, io, root, "[id]");
    const text = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expect(std.mem.indexOf(u8, text, "my worktrees/w1/\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\!important/\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\[id\\]/\n") != null);

    var sources = try Sources.load(allocator, io, root, true);
    defer sources.deinit();
    try testing.expectEqual(Source.fs_meta, sources.decide("my worktrees/w1", true).?);
    try testing.expectEqual(Source.fs_meta, sources.decide("!important", true).?);
    try testing.expectEqual(Source.fs_meta, sources.decide("[id]", true).?);
}

test "rewriteManaged replaces only the managed block and keeps the user's lines" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".fs-meta/ignore",
        \\*.log
        \\# fsmeta-managed
        \\stale/line/
        \\
    );

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try rewriteManaged(allocator, io, root, &.{ "worktrees/w2", "worktrees/w1" });
    const first = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings("*.log\n# fsmeta-managed\nworktrees/w1/\nworktrees/w2/\n", first);
    try testing.expect(std.mem.indexOf(u8, first, "stale/line/") == null);

    // Idempotent, and a subset drops the other entry without touching the user's line.
    try rewriteManaged(allocator, io, root, &.{ "worktrees/w1" });
    const second = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings("*.log\n# fsmeta-managed\nworktrees/w1/\n", second);
    try rewriteManaged(allocator, io, root, &.{ "worktrees/w1" });
    try testing.expectEqualStrings(second, try readText(allocator, io, tmp.dir, ".fs-meta/ignore"));

    // An empty set keeps the marker (so the block has a home) but no entries.
    try rewriteManaged(allocator, io, root, &.{});
    try testing.expectEqualStrings("*.log\n# fsmeta-managed\n", try readText(allocator, io, tmp.dir, ".fs-meta/ignore"));
}

test "rewriteManaged does not create a block when there is nothing to manage" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    // No file and no paths: no file is created.
    try rewriteManaged(allocator, io, root, &.{});
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, ".fs-meta", .{}));

    // A user-only file stays user-only when there is nothing to manage.
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "*.log\n");
    try rewriteManaged(allocator, io, root, &.{});
    try testing.expectEqualStrings("*.log\n", try readText(allocator, io, tmp.dir, ".fs-meta/ignore"));
}

test "rewriteManaged keeps a managed entry's escaping and is idempotent" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try rewriteManaged(allocator, io, root, &.{ "!important", "[id]" });
    const text = try readText(allocator, io, tmp.dir, ".fs-meta/ignore");
    try testing.expectEqualStrings("# fsmeta-managed\n\\!important/\n\\[id\\]/\n", text);
    try rewriteManaged(allocator, io, root, &.{ "[id]", "!important" });
    try testing.expectEqualStrings(text, try readText(allocator, io, tmp.dir, ".fs-meta/ignore"));
}

test "appendManaged refuses a path a line cannot represent" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectError(error.InvalidPath, appendManaged(allocator, io, root, ""));
    try testing.expectError(error.InvalidPath, appendManaged(allocator, io, root, "a\nb"));
    try testing.expectError(error.InvalidPath, appendManaged(allocator, io, root, "../escape"));
    try testing.expectError(error.InvalidPath, appendManaged(allocator, io, root, "/absolute"));
    // Nothing was written for a refusal.
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, ".fs-meta", .{}));
}

test "appendExclude appends one marked block, keeps existing content and writes LF" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "info/exclude",
        \\*.log
        \\# a user's own line
        \\
    );

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const common = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expect(try appendExclude(allocator, io, common));
    const first = try readText(allocator, io, tmp.dir, "info/exclude");
    try testing.expectEqualStrings(
        "*.log\n# a user's own line\n# fsmeta: our own directory\n.fs-meta/\n",
        first,
    );
    try testing.expect(std.mem.indexOfScalar(u8, first, '\r') == null);
    try testing.expect(std.mem.endsWith(u8, first, ".fs-meta/\n"));

    // Idempotent: the second run writes nothing, including after a CRLF file's last line.
    try testing.expect(!try appendExclude(allocator, io, common));
    try testing.expectEqualStrings(first, try readText(allocator, io, tmp.dir, "info/exclude"));

    // A file that does not end in a newline still gets our marker on its own line, and our bytes are LF.
    try writeFile(tmp.dir, io, "info/exclude", "*.log");
    try testing.expect(try appendExclude(allocator, io, common));
    try testing.expectEqualStrings(
        "*.log\n# fsmeta: our own directory\n.fs-meta/\n",
        try readText(allocator, io, tmp.dir, "info/exclude"),
    );
}

test "appendExclude creates info/exclude when it is missing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const common = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expect(try appendExclude(allocator, io, common));
    try testing.expectEqualStrings(
        "# fsmeta: our own directory\n.fs-meta/\n",
        try readText(allocator, io, tmp.dir, "info/exclude"),
    );
    // A one-line `!` later in the file overrides it; the helper never touches the user's lines.
    try writeFile(tmp.dir, io, "info/exclude", "# fsmeta: our own directory\n.fs-meta/\n!.fs-meta/\n");
    try testing.expect(!try appendExclude(allocator, io, common));
    try testing.expectEqualStrings(
        "# fsmeta: our own directory\n.fs-meta/\n!.fs-meta/\n",
        try readText(allocator, io, tmp.dir, "info/exclude"),
    );

    // Not a directory at all is a refusal, not a created file elsewhere.
    const absent = try joinPath(allocator, common, "absent");
    try testing.expectError(error.RootMissing, appendExclude(allocator, io, absent));
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, name });
}
