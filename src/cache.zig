// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The engine's in-memory state: what one generation says about a tree, arranged so that a restart can be
//! incremental — directories by path with their children, files by path with their fingerprint, and a
//! `contentHash` that may be `null` because the engine hashes on demand.
//!
//! The persisted form of this is the trio itself, so loading is `validate` + `load` and there is no second cache
//! format to keep in step. The model is deliberately flat: every entry carries its full relative path, and a
//! directory keeps only the *names* of its children, because that is what a directory listing gives back.
//!
//! ## Two invariants this model exists to serve
//!
//! 1. **A directory's `mtimeNs` answers "is the child name list unchanged?"** — nothing else. A file's content,
//!    size or mtime can change without the containing directory's mtime moving, so a matching directory mtime
//!    never licenses skipping the files inside it.
//! 2. **A file's `mtimeNs` + `sizeBytes` (+ `fileId`) answer "may the cached `contentHash` be reused?"** — with
//!    the "may", not "is": equality of the pair is a pre-filter, and a client that needs certainty reads the
//!    bytes (FORMAT.md § 11 says the same in the other direction).

const std = @import("std");
const format = @import("format.zig");

pub const DirState = struct {
    /// The directory's own last-modified time; `0` means unknown, which always forces a listing.
    mtime_ns: u64,
    file_id_lo: u64,
    file_id_hi: u64,
    /// Names directly inside, `/`-free, in the trio's byte order.
    file_names: [][]const u8 = &.{},
    dir_names: [][]const u8 = &.{},
};

pub const FileState = struct {
    kind: format.Kind,
    mtime_ns: u64,
    size_bytes: u64,
    /// `null` means "dirty": a change was seen and the hash will be taken when a client asks.
    content_hash: ?u64,
    hash_lf: bool,
    file_id_lo: u64,
    file_id_hi: u64,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    /// `/`-free keys are top-level names; the empty key is the root itself (mtime unknown, § 7 keeps only its
    /// identity), which is why a cold start always lists the root once.
    dirs: std.StringArrayHashMapUnmanaged(DirState) = .{},
    /// Regular files and symlinks; directories live in `dirs`.
    files: std.StringArrayHashMapUnmanaged(FileState) = .{},
    generation: u64 = 0,

    pub fn deinit(self: *Cache) void {
        for (self.dirs.values()) |state| {
            self.allocator.free(state.file_names);
            self.allocator.free(state.dir_names);
        }
        self.dirs.deinit(self.allocator);
        self.files.deinit(self.allocator);
    }

    /// The parent of a relative path, or `""` for a top-level name.
    pub fn parentOf(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
        return path[0..slash];
    }

    /// The last segment of a relative path.
    pub fn baseName(path: []const u8) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[slash + 1 ..];
    }

    /// § 4 stores a directory's name in `files.txt` with a trailing `/` so that its subtree is an exactly bounded
    /// byte range. That slash is the layout's, not the name's: every path this model holds, and every path a
    /// listing produces, names the folder without it.
    pub fn dirPath(stored: []const u8) []const u8 {
        if (stored.len > 1 and stored[stored.len - 1] == '/') return stored[0 .. stored.len - 1];
        return stored;
    }

    /// `true` when `path` is `base` or lies below it — the test a subtree removal needs.
    pub fn isUnder(path: []const u8, base: []const u8) bool {
        if (base.len == 0) return true;
        if (!std.mem.startsWith(u8, path, base)) return false;
        return path.len == base.len or path[base.len] == '/';
    }

    /// A cache from a validated trio: `entries` and `names` in `files.txt` order (§ 8 has already established
    /// that every name is a usable path and that the pair is consistent).
    ///
    /// A directory is keyed by its **path**, without the trailing slash § 4 stores in `files.txt` — that slash is
    /// the layout's rule for making a subtree a byte range, not part of the name. Keeping it here would put a key
    /// in the map that no listing can ever produce again (a listing reports `src`), so the directory would be
    /// re-added under its path while the slashed key survived as a second, unremovable entry — and a publish would
    /// list both, one of them as `src//`.
    pub fn load(allocator: std.mem.Allocator, entries: []const format.Entry, names: []const []const u8, generation: u64) !Cache {
        var cache: Cache = .{ .allocator = allocator, .generation = generation };
        errdefer cache.deinit();

        // The root itself is not listed by the trio (§ 3), but its children need somewhere to live.
        try cache.dirs.put(allocator, "", .{ .mtime_ns = 0, .file_id_lo = 0, .file_id_hi = 0 });

        for (entries, names) |entry, name| {
            switch (entry.kind() orelse continue) {
                .dir => try cache.dirs.put(allocator, dirPath(name), .{
                    .mtime_ns = entry.mtime_ns,
                    .file_id_lo = entry.file_id_lo,
                    .file_id_hi = entry.file_id_hi,
                }),
                .regular_file, .symlink => try cache.files.put(allocator, name, .{
                    .kind = entry.kind().?,
                    .mtime_ns = entry.mtime_ns,
                    .size_bytes = entry.size_bytes,
                    .content_hash = if (entry.contentKnown()) entry.content_hash else null,
                    .hash_lf = entry.hashLf(),
                    .file_id_lo = entry.file_id_lo,
                    .file_id_hi = entry.file_id_hi,
                }),
            }
        }

        // Second pass: the children of each directory, in the trio's order (the trio is sorted by name, so
        // appending in iteration order keeps every child list sorted too).
        try cache.fillChildren(allocator);
        return cache;
    }

    fn fillChildren(self: *Cache, allocator: std.mem.Allocator) !void {
        // Count first, so each list is one allocation.
        var file_counts = try allocator.alloc(usize, self.dirs.count());
        defer allocator.free(file_counts);
        var dir_counts = try allocator.alloc(usize, self.dirs.count());
        defer allocator.free(dir_counts);
        @memset(file_counts, 0);
        @memset(dir_counts, 0);

        const indexOf = struct {
            fn of(map: *const std.StringArrayHashMapUnmanaged(DirState), key: []const u8) ?usize {
                return map.getIndex(key);
            }
        }.of;

        const file_it = self.files.keys();
        for (file_it) |path| {
            if (indexOf(&self.dirs, parentOf(path))) |index| file_counts[index] += 1;
        }
        const dir_it = self.dirs.keys();
        for (dir_it) |path| {
            if (path.len == 0) continue;
            if (indexOf(&self.dirs, parentOf(path))) |index| dir_counts[index] += 1;
        }

        for (self.dirs.keys(), 0..) |_, index| {
            if (file_counts[index] > 0) {
                self.dirs.values()[index].file_names = try allocator.alloc([]const u8, file_counts[index]);
            }
            if (dir_counts[index] > 0) {
                self.dirs.values()[index].dir_names = try allocator.alloc([]const u8, dir_counts[index]);
            }
        }

        var written_files = try allocator.alloc(usize, self.dirs.count());
        defer allocator.free(written_files);
        var written_dirs = try allocator.alloc(usize, self.dirs.count());
        defer allocator.free(written_dirs);
        @memset(written_files, 0);
        @memset(written_dirs, 0);

        const file_iter = self.files.keys();
        for (file_iter) |path| {
            if (indexOf(&self.dirs, parentOf(path))) |index| {
                self.dirs.values()[index].file_names[written_files[index]] = baseName(path);
                written_files[index] += 1;
            }
        }
        const dir_iter = self.dirs.keys();
        for (dir_iter) |path| {
            if (path.len == 0) continue;
            if (indexOf(&self.dirs, parentOf(path))) |index| {
                self.dirs.values()[index].dir_names[written_dirs[index]] = baseName(path);
                written_dirs[index] += 1;
            }
        }

        // § 4 orders the trio by `(nameHash, name)`, so a child list no longer arrives sorted by name. Children
        // stay in name order — the listing merge and the walker search them by name — at the cost of one sort
        // per directory per publish, and only for directories that changed.
        for (self.dirs.values()) |*state| {
            std.mem.sort([]const u8, state.file_names, {}, nameLessThanByBytes);
            std.mem.sort([]const u8, state.dir_names, {}, nameLessThanByBytes);
        }
    }

    fn nameLessThanByBytes(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn fileCount(self: *const Cache) usize {
        return self.files.count();
    }

    /// Replace a directory's child names after a listing. The listing's order is kept; the trio's byte order is a
    /// publish decision, not this model's.
    pub fn setChildren(self: *Cache, dir: []const u8, file_names: []const []const u8, dir_names: []const []const u8) !void {
        const state = self.dirs.getPtr(dir) orelse return;
        if (state.file_names.len > 0) self.allocator.free(state.file_names);
        if (state.dir_names.len > 0) self.allocator.free(state.dir_names);
        state.file_names = try self.allocator.alloc([]const u8, file_names.len);
        for (file_names, 0..) |name, index| state.file_names[index] = try self.allocator.dupe(u8, name);
        state.dir_names = try self.allocator.alloc([]const u8, dir_names.len);
        for (dir_names, 0..) |name, index| state.dir_names[index] = try self.allocator.dupe(u8, name);
    }

    pub fn dirCount(self: *const Cache) usize {
        // The root is bookkeeping, not an entry: § 3 never lists it.
        return if (self.dirs.count() == 0) 0 else self.dirs.count() - 1;
    }
};

/// Compare two name lists by content: a child name is a subslice of its path, so pointer equality is not it.
fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a trio loads into directories with their children, sorted" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // The names in § 4's stored form, as `files.txt` carries them: a directory's name ends with '/'.
    const names = [_][]const u8{ "a.txt", "src/", "src/b.java", "src/sub/", "src/sub/c.txt" };
    const kinds = [_]format.Kind{ .regular_file, .dir, .regular_file, .dir, .regular_file };
    const entries = try a.alloc(format.Entry, names.len);
    for (entries, 0..) |*entry, index| {
        entry.* = .{
            .mtime_ns = 100 + index,
            .size_bytes = if (kinds[index] == .regular_file) 10 else 0,
            .content_hash = if (kinds[index] == .regular_file) 0x1234 else 0,
            .name_hash = format.wyhash(Cache.dirPath(names[index])),
            .name_offset = 0,
            .name_length = @intCast(names[index].len),
            .flags_word = if (kinds[index] == .regular_file)
                format.flags.regular_file | format.flags.content_known
            else
                format.flags.is_dir,
            .file_id_lo = 1000 + index,
            .file_id_hi = 7,
        };
    }

    var cache = try Cache.load(a, entries, &names, 3);
    defer cache.deinit();

    try std.testing.expectEqual(@as(usize, 3), cache.files.count());
    try std.testing.expectEqual(@as(usize, 2), cache.dirCount()); // src and src/sub; the root is bookkeeping, never an entry
    try std.testing.expect(cache.dirs.contains("src"));
    try std.testing.expect(cache.dirs.contains("src/sub"));
    // The slash is the stored form, not the key: a listing reports `src`, so that is what the model must hold.
    try std.testing.expect(!cache.dirs.contains("src/"));

    const root = cache.dirs.get("") orelse return error.MissingRoot;
    try expectNames(&.{"a.txt"}, root.file_names);
    try expectNames(&.{"src"}, root.dir_names);

    const src = cache.dirs.get("src") orelse return error.MissingSrc;
    try expectNames(&.{"b.java"}, src.file_names);
    try expectNames(&.{"sub"}, src.dir_names);

    const file = cache.files.get("src/b.java") orelse return error.MissingFile;
    try std.testing.expectEqual(@as(?u64, 0x1234), file.content_hash);
    try std.testing.expectEqual(@as(u64, 1000 + 2), file.file_id_lo);
}

test "path helpers" {
    try std.testing.expectEqualStrings("", Cache.parentOf("a.txt"));
    try std.testing.expectEqualStrings("src", Cache.parentOf("src/b.java"));
    try std.testing.expectEqualStrings("src/sub", Cache.parentOf("src/sub/c.txt"));
    try std.testing.expectEqualStrings("b.java", Cache.baseName("src/b.java"));
    try std.testing.expectEqualStrings("a.txt", Cache.baseName("a.txt"));
    try std.testing.expect(Cache.isUnder("src/b.java", "src"));
    try std.testing.expect(Cache.isUnder("src", "src"));
    try std.testing.expect(!Cache.isUnder("srcx/b.java", "src"));
    try std.testing.expect(Cache.isUnder("anything", ""));
}

test "a listing-only file has no hash to reuse" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const names = [_][]const u8{"x.bin"};
    const entries = [_]format.Entry{.{
        .mtime_ns = 5,
        .size_bytes = 3,
        .content_hash = 0,
        .name_hash = format.wyhash("x.bin"),
        .name_offset = 0,
        .name_length = 5,
        .flags_word = format.flags.regular_file, // CONTENT_KNOWN clear: listing only
        .file_id_lo = 1,
        .file_id_hi = 2,
    }};
    var cache = try Cache.load(a, &entries, &names, 0);
    defer cache.deinit();
    try std.testing.expectEqual(@as(?u64, null), cache.files.get("x.bin").?.content_hash);
}