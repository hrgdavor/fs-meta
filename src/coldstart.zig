// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Cold start: bring a trio loaded into a `Cache` up to date with the file system without a full walk.
//!
//! The design is one observation: **a directory listing can carry the metadata of its children**, so a restart
//! needs one listing syscall per directory — `FindFirstFileExW` on Windows, `getattrlistbulk` on macOS,
//! `getdents` + batched `statx` on Linux — instead of a `readdir` plus a `stat` per entry.
//!
//! ## Invariants this file must never break
//!
//! 1. **A directory's mtime is about its child *names*, nothing else.** Editing a file does not move the
//!    directory's mtime, so a matching directory mtime never licenses skipping the files in it. Only the file's
//!    own `mtimeNs` + `sizeBytes` (+ `fileId`) let a cached `contentHash` be reused.
//! 2. **`fileId` is identity, not content.** Same pair, different name = rename: the derived work is kept and the
//!    name updated. `0, 0` is *unknown* (FORMAT.md § 5) and then the name is the only identity there is.
//! 3. **Cold start never hashes.** A new or changed file is left dirty (`content_hash = null`) and the engine
//!    takes the hash when a client asks for it. Hashing 100k files on start is the cost this removes.
//!
//! ## Deliberate limits
//!
//! A renamed *directory* is a removal plus an addition of its subtree; relocating it is a later refinement. A file
//! inside a directory that was deleted has no rename candidate, because its old name went with the directory.

const std = @import("std");
const format = @import("format.zig");
const cache_mod = @import("cache.zig");
const boundary_mod = @import("boundary.zig");

pub const Cache = cache_mod.Cache;

/// One child as the OS bulk listing reports it. `name` is that child's base name.
pub const EntryInfo = struct {
    name: []const u8,
    kind: format.Kind,
    mtime_ns: u64,
    size_bytes: u64,
    file_id_lo: u64,
    file_id_hi: u64,
    /// Set for a directory that confirms as a nested repository (`boundary.zig`). The walker neither lists it
    /// nor enters it; the field is what carries that decision out of the listing, where the directory handle
    /// already exists, instead of reopening every directory to ask.
    boundary: boundary_mod.Kind = .none,
};

/// The metadata of one path: the directory's own mtime and identity.
pub const StatInfo = struct {
    mtime_ns: u64,
    file_id_lo: u64,
    file_id_hi: u64,
};

/// The OS boundary. Implementations live beside this file per platform; the tests implement it over a map.
pub const Lister = struct {
    ctx: *anyopaque,
    listFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, dir_path: []const u8) anyerror![]EntryInfo,
    statFn: *const fn (ctx: *anyopaque, path: []const u8) anyerror!?StatInfo,

    pub fn list(self: Lister, allocator: std.mem.Allocator, dir_path: []const u8) ![]EntryInfo {
        return self.listFn(self.ctx, allocator, dir_path);
    }

    pub fn stat(self: Lister, path: []const u8) !?StatInfo {
        return self.statFn(self.ctx, path);
    }
};

pub const Report = struct {
    dirs_stated: u64 = 0,
    dirs_listed: u64 = 0,
    dirs_skipped: u64 = 0,
    dirs_removed: u64 = 0,
    files_added: u64 = 0,
    files_removed: u64 = 0,
    files_modified: u64 = 0,
    files_unchanged: u64 = 0,
    renames: u64 = 0,

    /// Whether the trio this cache came from still describes the tree.
    pub fn changed(self: Report) bool {
        return self.dirs_removed > 0 or self.files_added > 0 or self.files_removed > 0 or
            self.files_modified > 0 or self.renames > 0;
    }
};

fn childPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

/// The path an OS call takes. The cache is relative to `root`; the root itself is `"."`.
fn osPath(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return allocator.dupe(u8, if (root.len == 0) "." else root);
    if (root.len == 0) return allocator.dupe(u8, rel);
    if (root[root.len - 1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, rel });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel });
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const Dropped = struct {
    path: []const u8, // owned by the cache allocator
    state: cache_mod.FileState,
};

/// Reconcile `cache` with the tree at `root`. `arena` is scratch for the call; the cache keeps its own memory.
pub fn coldStart(arena: std.mem.Allocator, cache: *Cache, lister: Lister, root: []const u8) !Report {
    var report: Report = .{};

    // Every key this pass inserts is duplicated below, so the cache becomes the owner of its keys: `deinit` may
    // free them, and so may a removal. A cache loaded from a trio is already in that state (`Cache.load`
    // duplicates too) and a fresh one is not, which is why this is a fact set here rather than a constructor
    // parameter. Without it, a loaded cache's keys were borrowed slices of `files.txt` and freeing one poisoned
    // the trio's own bytes.
    cache.owns_keys = true;

    // The root is bookkeeping rather than an entry (§ 3), and it needs a state like any other directory: its own
    // mtime and identity are what the *next* pass compares, and its child lists are what a removal is looked for
    // against. A cache loaded from a trio carries it; the first pass over a tree starts from an empty cache, and
    // without it `Cache.dirCount` — which subtracts this one key — reports one directory too few.
    if (cache.dirs.getPtr("") == null) {
        try cache.dirs.put(cache.allocator, "", .{ .mtime_ns = 0, .file_id_lo = 0, .file_id_hi = 0 });
    }

    // Breadth-first over the directories this run visits. The root is always visited: § 7 keeps the root's
    // identity but not its mtime, so there is nothing to compare against.
    const Queued = struct {
        path: []const u8,
        /// What the parent's listing said about this directory. `null` only for the root, which nothing listed.
        known: ?StatInfo,
    };
    var queue: std.ArrayListUnmanaged(Queued) = .empty;
    defer queue.deinit(arena);
    try queue.append(arena, .{ .path = "", .known = null });

    // Files the previous generation had under a name this run no longer sees, kept for rename matching.
    var dropped: std.ArrayListUnmanaged(Dropped) = .empty;
    defer {
        for (dropped.items) |entry| cache.allocator.free(entry.path);
        dropped.deinit(cache.allocator);
    }
    var added: std.ArrayListUnmanaged([]const u8) = .empty;
    defer added.deinit(arena);

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        const dir = item.path;
        const dir_path = try osPath(arena, root, dir);
        // A listed directory already told us its mtime and identity; only the root needs a stat. This is the
        // per-directory saving: three syscalls per directory become zero for everything below the root.
        const dir_stat: StatInfo = if (item.known) |known| known else blk: {
            const found = try lister.stat(dir_path);
            report.dirs_stated += 1;
            if (found == null) return error.RootMissing;
            break :blk found.?;
        };

        // Informational only: the listing happens either way, because it is where the children's metadata comes
        // from. A matching mtime says the *name list* cannot have changed.
        if (cache.dirs.get(dir)) |state| {
            if (state.mtime_ns != 0 and state.mtime_ns == dir_stat.mtime_ns and
                state.file_id_lo == dir_stat.file_id_lo and state.file_id_hi == dir_stat.file_id_hi)
            {
                report.dirs_skipped += 1;
            }
        }

        const listing = try lister.list(arena, dir_path);
        report.dirs_listed += 1;
        const cached_dir = cache.dirs.get(dir);

        var listed_files: std.ArrayListUnmanaged([]const u8) = .empty;
        defer listed_files.deinit(arena);
        var listed_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer listed_dirs.deinit(arena);

        for (listing) |entry| {
            // A listing never reports "." or "..". An empty name would mean the directory itself, and treating
            // it as a child re-queues the directory forever.
            if (entry.name.len == 0) continue;
            const child = try childPath(arena, dir, entry.name);
            switch (entry.kind) {
                .dir => {
                    try listed_dirs.append(arena, entry.name);
                    if (cache.dirs.getPtr(child)) |state| {
                        state.mtime_ns = entry.mtime_ns;
                        state.file_id_lo = entry.file_id_lo;
                        state.file_id_hi = entry.file_id_hi;
                    } else {
                        try cache.dirs.put(cache.allocator, try cache.allocator.dupe(u8, child), .{
                            .mtime_ns = entry.mtime_ns,
                            .file_id_lo = entry.file_id_lo,
                            .file_id_hi = entry.file_id_hi,
                        });
                    }
                    // Every listed directory is visited — a cached one included, because its own children still
                    // have to be checked. Not queueing it is how a restart used to miss a whole subtree.
                    {
                        try queue.append(arena, .{
                            .path = try arena.dupe(u8, child),
                            .known = .{
                                .mtime_ns = entry.mtime_ns,
                                .file_id_lo = entry.file_id_lo,
                                .file_id_hi = entry.file_id_hi,
                            },
                        });
                    }
                },
                .regular_file, .symlink => {
                    try listed_files.append(arena, entry.name);
                    if (cache.files.getPtr(child)) |state| {
                        const same = state.mtime_ns == entry.mtime_ns and state.size_bytes == entry.size_bytes and
                            (entry.file_id_lo == 0 or
                                (state.file_id_lo == entry.file_id_lo and state.file_id_hi == entry.file_id_hi));
                        if (same) {
                            report.files_unchanged += 1;
                        } else {
                            // Invariant 1: the directory's mtime said nothing about this file; its own pair did.
                            state.content_hash = null;
                            state.hash_lf = false;
                            state.mtime_ns = entry.mtime_ns;
                            state.size_bytes = entry.size_bytes;
                            state.kind = entry.kind;
                            state.file_id_lo = entry.file_id_lo;
                            state.file_id_hi = entry.file_id_hi;
                            report.files_modified += 1;
                        }
                    } else {
                        try cache.files.put(cache.allocator, try cache.allocator.dupe(u8, child), .{
                            .kind = entry.kind,
                            .mtime_ns = entry.mtime_ns,
                            .size_bytes = entry.size_bytes,
                            .content_hash = null, // invariant 3: dirty until asked
                            .hash_lf = false,
                            .file_id_lo = entry.file_id_lo,
                            .file_id_hi = entry.file_id_hi,
                        });
                        try added.append(arena, try arena.dupe(u8, child));
                        report.files_added += 1;
                    }
                },
            }
        }

        // What the cache had under this directory and the listing does not show: a deletion, or the other half
        // of a rename (kept aside until the whole tree has been listed).
        if (cached_dir) |state| {
            for (state.file_names) |name| {
                if (containsName(listed_files.items, name)) continue;
                const child = try childPath(arena, dir, name);
                if (cache.files.fetchOrderedRemove(child)) |removed| {
                    try dropped.append(cache.allocator, .{ .path = removed.key, .state = removed.value });
                    report.files_removed += 1;
                }
            }
            for (state.dir_names) |name| {
                if (containsName(listed_dirs.items, name)) continue;
                const child = try childPath(arena, dir, name);
                removeSubtree(cache, child, &report);
            }
        }

        if (cache.dirs.getPtr(dir)) |state| {
            state.mtime_ns = dir_stat.mtime_ns;
            state.file_id_lo = dir_stat.file_id_lo;
            state.file_id_hi = dir_stat.file_id_hi;
            try cache.setChildren(dir, listed_files.items, listed_dirs.items);
        }
    }

    // Invariant 2: a file that disappeared and a file that appeared with the same identity are one file that
    // moved. The old entry's hash is still the file's hash, so it moves with the name.
    for (added.items) |new_path| {
        const new_state = cache.files.getPtr(new_path) orelse continue;
        if (new_state.file_id_lo == 0 and new_state.file_id_hi == 0) continue;
        for (dropped.items, 0..) |old, index| {
            if (old.state.file_id_lo != new_state.file_id_lo or old.state.file_id_hi != new_state.file_id_hi) continue;
            new_state.content_hash = old.state.content_hash;
            new_state.hash_lf = old.state.hash_lf;
            report.renames += 1;
            report.files_added -= 1;
            report.files_removed -= 1;
            cache.allocator.free(old.path);
            dropped.items[index] = dropped.items[dropped.items.len - 1];
            dropped.items.len -= 1;
            break;
        }
    }

    return report;
}

/// Remove `base` and everything below it (§ 11: "entry missing or IS_DIR = new/deleted").
fn removeSubtree(cache: *Cache, base: []const u8, report: *Report) void {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(cache.allocator);
    const files_it = cache.files.keys();
    for (files_it) |path| {
        if (cache_mod.Cache.isUnder(path, base)) files.append(cache.allocator, path) catch {};
    }
    for (files.items) |path| {
        if (cache.files.fetchOrderedRemove(path)) |removed| {
            cache.allocator.free(removed.key);
            report.files_removed += 1;
        }
    }

    var dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer dirs.deinit(cache.allocator);
    const dirs_it = cache.dirs.keys();
    for (dirs_it) |path| {
        if (path.len != 0 and cache_mod.Cache.isUnder(path, base)) dirs.append(cache.allocator, path) catch {};
    }
    for (dirs.items) |path| {
        if (cache.dirs.fetchOrderedRemove(path)) |removed| {
            cache.allocator.free(removed.value.file_names);
            cache.allocator.free(removed.value.dir_names);
            cache.allocator.free(removed.key);
            report.dirs_removed += 1;
        }
    }
}

// --------------------------------------------------------------------------------------------- tests

const Fact = struct {
    kind: format.Kind,
    mtime_ns: u64,
    size_bytes: u64,
    file_id_lo: u64,
    file_id_hi: u64,
};

/// A file system in a map, so the algorithm can be tested without one. Paths are relative; the root is `""`.
const Fake = struct {
    facts: std.StringArrayHashMapUnmanaged(Fact) = .{},
    allocator: std.mem.Allocator,

    fn put(self: *Fake, path: []const u8, fact: Fact) !void {
        try self.facts.put(self.allocator, try self.allocator.dupe(u8, path), fact);
    }

    fn lister(self: *Fake) Lister {
        return .{ .ctx = @ptrCast(self), .listFn = listFn, .statFn = statFn };
    }

    fn listFn(ctx: *anyopaque, allocator: std.mem.Allocator, dir_path: []const u8) anyerror![]EntryInfo {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const dir = if (std.mem.eql(u8, dir_path, ".")) "" else dir_path;
        var out: std.ArrayListUnmanaged(EntryInfo) = .empty;
        var it = self.facts.iterator();
        while (it.next()) |pair| {
            // The root is its own parent in this map; a real listing never returns ".". Neither does this one.
            if (pair.key_ptr.len == 0) continue;
            if (!std.mem.eql(u8, cache_mod.Cache.parentOf(pair.key_ptr.*), dir)) continue;
            const fact = pair.value_ptr.*;
            try out.append(allocator, .{
                .name = cache_mod.Cache.baseName(pair.key_ptr.*),
                .kind = fact.kind,
                .mtime_ns = fact.mtime_ns,
                .size_bytes = fact.size_bytes,
                .file_id_lo = fact.file_id_lo,
                .file_id_hi = fact.file_id_hi,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn statFn(ctx: *anyopaque, path: []const u8) anyerror!?StatInfo {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const key = if (std.mem.eql(u8, path, ".")) "" else path;
        const fact = self.facts.get(key) orelse return null;
        return .{ .mtime_ns = fact.mtime_ns, .file_id_lo = fact.file_id_lo, .file_id_hi = fact.file_id_hi };
    }
};

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return switch (format.compareNames(left, right)) {
        .lt => true,
        else => false,
    };
}

/// A cache loaded from the fake, the way a restart loads it from a validated trio.
fn cacheFromFake(allocator: std.mem.Allocator, fake: *const Fake) !Cache {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);
    const it = fake.facts.keys();
    for (it) |path| try paths.append(allocator, path);
    std.mem.sort([]const u8, paths.items, {}, lessThan);

    const entries = try allocator.alloc(format.Entry, paths.items.len);
    defer allocator.free(entries);
    for (paths.items, 0..) |path, index| {
        const fact = fake.facts.get(path).?;
        entries[index] = .{
            .mtime_ns = fact.mtime_ns,
            .size_bytes = fact.size_bytes,
            .content_hash = if (fact.kind == .regular_file) 0xabcdef else 0,
            .name_hash = format.wyhash(path),
            .name_offset = 0,
            .name_length = @intCast(path.len),
            .flags_word = switch (fact.kind) {
                .dir => format.flags.is_dir,
                .symlink => format.flags.symlink,
                .regular_file => format.flags.regular_file | format.flags.content_known,
            },
            .file_id_lo = fact.file_id_lo,
            .file_id_hi = fact.file_id_hi,
        };
    }
    return Cache.load(allocator, entries, paths.items, 1);
}

fn baseTree(fake: *Fake) !void {
    try fake.put("", .{ .kind = .dir, .mtime_ns = 10, .size_bytes = 0, .file_id_lo = 1, .file_id_hi = 5 });
    try fake.put("src", .{ .kind = .dir, .mtime_ns = 20, .size_bytes = 0, .file_id_lo = 2, .file_id_hi = 5 });
    try fake.put("a.txt", .{ .kind = .regular_file, .mtime_ns = 30, .size_bytes = 6, .file_id_lo = 3, .file_id_hi = 5 });
    try fake.put("src/b.java", .{ .kind = .regular_file, .mtime_ns = 40, .size_bytes = 11, .file_id_lo = 4, .file_id_hi = 5 });
}

test "an unchanged tree is unchanged, and every hash is reusable" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try baseTree(&fake);

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expect(!report.changed());
    try std.testing.expectEqual(@as(u64, 2), report.files_unchanged);
    try std.testing.expectEqual(@as(?u64, 0xabcdef), cache.files.get("a.txt").?.content_hash);
    try std.testing.expectEqual(@as(?u64, 0xabcdef), cache.files.get("src/b.java").?.content_hash);
}

test "a file edit is seen even when its directory's mtime did not move (invariant 1)" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try baseTree(&fake);

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    // The file changed; the directory's own mtime and identity are untouched.
    try fake.put("a.txt", .{ .kind = .regular_file, .mtime_ns = 31, .size_bytes = 7, .file_id_lo = 3, .file_id_hi = 5 });

    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expect(report.changed());
    try std.testing.expectEqual(@as(u64, 1), report.files_modified);
    try std.testing.expectEqual(@as(?u64, null), cache.files.get("a.txt").?.content_hash);
    try std.testing.expectEqual(@as(?u64, 0xabcdef), cache.files.get("src/b.java").?.content_hash);
}

test "a directory whose mtime moved but whose names did not reports nothing changed" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try baseTree(&fake);

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    // `touch src`: the directory mtime moves, the children are untouched.
    try fake.put("src", .{ .kind = .dir, .mtime_ns = 21, .size_bytes = 0, .file_id_lo = 2, .file_id_hi = 5 });

    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expect(!report.changed());
    try std.testing.expectEqual(@as(u64, 2), report.files_unchanged);
}

test "a rename keeps the hash (invariant 2)" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try baseTree(&fake);

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    // Same fileId, new name: one file that moved, not a delete plus a create.
    _ = fake.facts.orderedRemove("a.txt");
    try fake.put("renamed.txt", .{ .kind = .regular_file, .mtime_ns = 30, .size_bytes = 6, .file_id_lo = 3, .file_id_hi = 5 });

    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expectEqual(@as(u64, 1), report.renames);
    try std.testing.expectEqual(@as(u64, 0), report.files_added);
    try std.testing.expectEqual(@as(u64, 0), report.files_removed);
    try std.testing.expect(cache.files.get("renamed.txt") != null);
    try std.testing.expect(cache.files.get("a.txt") == null);
    try std.testing.expectEqual(@as(?u64, 0xabcdef), cache.files.get("renamed.txt").?.content_hash);
}

test "new and deleted files and a new directory are reconciled" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try baseTree(&fake);

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    _ = fake.facts.orderedRemove("a.txt");
    try fake.put("new.txt", .{ .kind = .regular_file, .mtime_ns = 50, .size_bytes = 3, .file_id_lo = 6, .file_id_hi = 5 });
    try fake.put("docs", .{ .kind = .dir, .mtime_ns = 60, .size_bytes = 0, .file_id_lo = 7, .file_id_hi = 5 });
    try fake.put("docs/readme.md", .{ .kind = .regular_file, .mtime_ns = 61, .size_bytes = 9, .file_id_lo = 8, .file_id_hi = 5 });

    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expectEqual(@as(u64, 1), report.files_removed);
    try std.testing.expectEqual(@as(u64, 2), report.files_added);
    try std.testing.expect(cache.files.get("new.txt") != null);
    try std.testing.expect(cache.files.get("docs/readme.md") != null);
    try std.testing.expectEqual(@as(?u64, null), cache.files.get("docs/readme.md").?.content_hash);
    try std.testing.expect(cache.dirs.contains("docs"));
}

test "a directory deleted offline takes its subtree with it" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try baseTree(&fake);

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    _ = fake.facts.orderedRemove("src");
    _ = fake.facts.orderedRemove("src/b.java");

    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expectEqual(@as(u64, 1), report.dirs_removed);
    try std.testing.expectEqual(@as(u64, 1), report.files_removed);
    try std.testing.expect(cache.dirs.get("src") == null);
    try std.testing.expect(cache.files.get("src/b.java") == null);
}

test "unknown fileId falls back to the name, and nothing is called a rename" {
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var fake: Fake = .{ .allocator = arena };
    try fake.put("", .{ .kind = .dir, .mtime_ns = 10, .size_bytes = 0, .file_id_lo = 0, .file_id_hi = 0 });
    try fake.put("fat.txt", .{ .kind = .regular_file, .mtime_ns = 30, .size_bytes = 6, .file_id_lo = 0, .file_id_hi = 0 });

    var cache = try cacheFromFake(arena, &fake);
    defer cache.deinit();

    // Same name, new mtime: a modification, because `0, 0` is not identity.
    try fake.put("fat.txt", .{ .kind = .regular_file, .mtime_ns = 31, .size_bytes = 6, .file_id_lo = 0, .file_id_hi = 0 });
    const report = try coldStart(arena, &cache, fake.lister(), "");
    try std.testing.expectEqual(@as(u64, 1), report.files_modified);
    try std.testing.expectEqual(@as(u64, 0), report.renames);
}