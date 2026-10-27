// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Seeding a worktree root from a served base trio (`plans/worktrees.md` § 5e, R4).
//!
//! A new linked worktree is (almost) the base checkout on a different branch. Instead of a cold scan, this module
//! copies the base generation into the new archive, **refreshes each entry's own metadata** (the checkout gives new
//! inodes and mtimes), and publishes a generation-1 trio plus a genesis batch. The engine's first normal pass then
//! reuses the base content hashes for every file whose size still matches and re-hashes only the branch differences;
//! `engine.Outcome.hashed` is the evidence.
//!
//! The validity conjunction is § 5e's, and every part is checked here except the base's *runtime* state (no
//! `last_error`, no pass in flight), which the host knows: the two roots must resolve to the same common dir, the
//! `.fs-meta/ignore` files must be byte-identical, the trios' `scan` blocks must match, and the base trio must be
//! readable and validate. Anything else is `false` — a cold scan, never a wrong seed.
//!
//! Failure after the copy starts removes the seeded trio and the genesis batch and reports the error; a failed seed
//! must degrade to a cold scan, not leave a plausible-looking archive that describes nothing. The user's own
//! `.fs-meta/ignore` is never touched.

const std = @import("std");
const format = @import("format.zig");
const json = @import("json_doc.zig");
const validate = @import("validate.zig");
const cache_mod = @import("cache.zig");
const publish_mod = @import("publish.zig");
const pair = @import("pair.zig");
const batch_mod = @import("batch.zig");
const scan = @import("scan.zig");
const gitdir = @import("gitdir.zig");

pub const writer = "fs-meta/1";

/// Try to seed `new_root` from `base_root`. Returns `true` when a generation-1 trio and its genesis batch were
/// written; `false` when the § 5e conjunction does not hold; an error when the copy itself failed (the seeded files
/// have already been removed). The caller treats an error as "fall back to a cold scan" and logs it.
pub fn trySeed(arena: std.mem.Allocator, io: std.Io, base_root: []const u8, new_root: []const u8, updated: []const u8) !bool {
    const new_location = (try gitdir.resolve(arena, io, new_root)) orelse return false;
    if (!new_location.is_gitfile) return false;
    const base_location = (try gitdir.resolve(arena, io, base_root)) orelse return false;
    if (!samePath(new_location.common_dir, base_location.common_dir)) return false;

    // A worktree that already has an archive keeps it; seeding over a real history would be a rewrite, not a seed.
    if (try exists(io, new_root, ".fs-meta/files.json") or
        try exists(io, new_root, ".fs-meta/files.meta") or
        try exists(io, new_root, ".fs-meta/files.txt")) return false;

    const base_dir = try openRoot(io, base_root);
    defer base_dir.close(io);
    var base_meta = base_dir.openDir(io, ".fs-meta", .{ .iterate = true }) catch return false;
    defer base_meta.close(io);
    const base_meta_bytes = base_meta.readFileAlloc(io, format.meta_file, arena, std.Io.Limit.limited(1 << 28)) catch return false;
    const base_txt_bytes = base_meta.readFileAlloc(io, format.txt_file, arena, std.Io.Limit.limited(1 << 28)) catch return false;
    const base_json_bytes = base_meta.readFileAlloc(io, format.json_file, arena, std.Io.Limit.limited(1 << 28)) catch return false;

    const checked = try validate.validate(arena, .{
        .json_bytes = base_json_bytes,
        .meta_bytes = base_meta_bytes,
        .txt_bytes = base_txt_bytes,
    });
    if (!checked.verdict.usable()) return false;

    var parsed = json.parse(arena, base_json_bytes) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const document = &parsed.value.object;
    const base_scan = json.objectField(document, "scan") catch return false;
    if (!try scanMatches(arena, io, new_location.common_dir, new_root, base_scan)) return false;

    // § 5e: the source list does not capture the file's contents; the two files must be byte-identical.
    const base_ignore = try readRootFile(arena, io, base_root, ".fs-meta/ignore");
    const new_ignore = try readRootFile(arena, io, new_root, ".fs-meta/ignore");
    if (!sameOptional(base_ignore, new_ignore)) return false;

    var new_dir = try openRoot(io, new_root);
    defer new_dir.close(io);
    var new_meta = new_dir.openDir(io, ".fs-meta", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try new_dir.createDirPath(io, ".fs-meta");
            break :blk try new_dir.openDir(io, ".fs-meta", .{ .iterate = true });
        },
        else => return err,
    };
    defer new_meta.close(io);

    const identity = rootIdentity(arena, io, new_root) catch return false;

    // The copied generation, with metadata refreshed from the new checkout. A file whose size changed has a
    // different hash in all likelihood; its copied hash is dropped and the first pass hashes it. Files and
    // directories that disappeared (or changed kind) are omitted, so the diff reports them.
    var cache = try refreshCache(arena, io, new_root, checked.entries, checked.names, 1);
    defer cache.deinit();

    const published = publish_mod.publish(arena, io, new_meta, &cache, .{
        .generation = 1,
        .normalize = "text",
        .root_dev = identity.dev,
        .root_ino = identity.ino,
        .created = updated,
        .updated = updated,
        .writer = writer,
        .scan = .{
            .hash_mode = "text",
            .ignored_dir_names = &.{ ".git", ".fs-meta" },
            .respect_gitignore = true,
            .nested_repos = true,
            .ignore_sources = try expectedSources(arena, io, new_location.common_dir, new_root),
        },
    }) catch |err| {
        cleanup(io, new_meta);
        return err;
    };
    _ = published;

    var items: std.ArrayListUnmanaged(batch_mod.Item) = .empty;
    defer items.deinit(arena);
    const files_it = cache.files.keys();
    for (files_it) |path| try items.append(arena, batch_mod.fileItem(path, cache.files.get(path).?));
    const dirs_it = cache.dirs.keys();
    for (dirs_it) |path| {
        if (path.len == 0) continue;
        try items.append(arena, batch_mod.dirItem(path, cache.dirs.get(path).?));
    }
    const genesis = batch_mod.diff(arena, &.{}, items.items) catch |err| {
        cleanup(io, new_meta);
        return err;
    };
    batch_mod.write(arena, io, new_meta, genesis, .{
        .generation = 1,
        .parent = 0,
        .normalize = "text",
        .root_dev = identity.dev,
        .root_ino = identity.ino,
        .created = updated,
        .updated = updated,
        .writer = writer,
    }) catch |err| {
        cleanup(io, new_meta);
        return err;
    };
    return true;
}

/// The `scan` block a daemon pass would write for this root. The base must agree with it in every field (§ 5e);
/// `ignoreSources` is computed from the files this root actually has, not trusted from the base document.
fn scanMatches(arena: std.mem.Allocator, io: std.Io, common_dir: []const u8, root: []const u8, base_scan: *const json.Map) !bool {
    const hash_mode = json.optionalString(base_scan, "hashMode") orelse return false;
    if (!std.mem.eql(u8, hash_mode, "text")) return false;
    if (!(json.optionalBool(base_scan, "respectGitignore") orelse false)) return false;
    if (!(json.optionalBool(base_scan, "nestedRepos") orelse false)) return false;
    const names = base_scan.get("ignoredDirectoryNames") orelse return false;
    if (names != .array or names.array.items.len != 2) return false;
    if (names.array.items[0] != .string or !std.mem.eql(u8, names.array.items[0].string, ".git")) return false;
    if (names.array.items[1] != .string or !std.mem.eql(u8, names.array.items[1].string, ".fs-meta")) return false;

    const sources = base_scan.get("ignoreSources") orelse return false;
    if (sources != .array) return false;
    const expected = try expectedSources(arena, io, common_dir, root);
    if (sources.array.items.len != expected.len) return false;
    for (sources.array.items, expected) |value, wanted| {
        if (value != .string or !std.mem.eql(u8, value.string, wanted)) return false;
    }
    return true;
}

/// The source tokens `ignores.Sources.load` would produce for this tree, in precedence order.
fn expectedSources(arena: std.mem.Allocator, io: std.Io, common_dir: []const u8, root: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(arena);
    try list.append(arena, "gitignore");
    if (try existsInDir(io, common_dir, "info/exclude")) try list.append(arena, "info/exclude");
    if (try exists(io, root, ".fs-meta/ignore")) try list.append(arena, "fs-meta/ignore");
    return list.toOwnedSlice(arena);
}

/// The base entries with each surviving entry's identity refreshed from the new checkout. A size change drops the
/// copied content hash; a missing path (or a different kind) is omitted, and the first pass's diff reports it.
fn refreshCache(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    entries: []const format.Entry,
    names: []const []const u8,
    generation: u64,
) !cache_mod.Cache {
    var kept_entries: std.ArrayListUnmanaged(format.Entry) = .empty;
    defer kept_entries.deinit(arena);
    var kept_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer kept_names.deinit(arena);

    for (entries, names) |original, name| {
        const is_dir = original.kind() == .dir;
        const relative = if (is_dir and name.len > 0 and name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
        const current = statName(io, root, relative) catch continue;
        if (current.kind != original.kind()) continue;

        var entry = original;
        entry.mtime_ns = current.mtime_ns;
        entry.file_id_lo = current.file_id_lo;
        entry.file_id_hi = current.file_id_hi;
        if (original.kind() == .regular_file) {
            entry.size_bytes = current.size_bytes;
            // A checkout can change a file's identity, its mtime, or its byte size (`core.autocrlf` turns `\n` into
            // `\r\n`), so "metadata matches" cannot be the seed's proof for the *copied* hash. The seed verifies each
            // copied hash against the checkout once; a match is kept, a mismatch (or a same-size branch edit) drops
            // it and the first pass hashes exactly that file. `outcome.hashed` therefore counts branch differences,
            // which is what it means; the seed's own read is not a pass.
            if (original.contentKnown()) {
                const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, relative }) catch {
                    entry.content_hash = 0;
                    entry.flags_word &= ~(format.flags.content_known | format.flags.hash_lf);
                    continue;
                };
                const hashed = scan.hashFileAt(io, full, .text) catch null;
                if (hashed) |value| {
                    if (value.hash == original.content_hash) {
                        if (value.hash_lf) {
                            entry.flags_word |= format.flags.hash_lf;
                        } else {
                            entry.flags_word &= ~format.flags.hash_lf;
                        }
                    } else {
                        entry.content_hash = 0;
                        entry.flags_word &= ~(format.flags.content_known | format.flags.hash_lf);
                    }
                } else {
                    entry.content_hash = 0;
                    entry.flags_word &= ~(format.flags.content_known | format.flags.hash_lf);
                }
            }
        }
        try kept_entries.append(arena, entry);
        try kept_names.append(arena, name);
    }
    return cache_mod.Cache.load(arena, kept_entries.items, kept_names.items, generation);
}

const Found = struct {
    kind: format.Kind,
    mtime_ns: u64,
    size_bytes: u64,
    file_id_lo: u64,
    file_id_hi: u64,
};

fn statName(io: std.Io, root: []const u8, relative: []const u8) !Found {
    const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ root, relative });
    defer std.heap.page_allocator.free(full);
    const parent = std.fs.path.dirname(full) orelse ".";
    const base = std.fs.path.basename(full);
    var dir = if (std.fs.path.isAbsolute(parent))
        try std.Io.Dir.openDirAbsolute(io, parent, .{})
    else
        try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);
    const stat = try dir.statFile(io, base, .{ .follow_symlinks = false });
    const kind: format.Kind = switch (stat.kind) {
        .file => .regular_file,
        .directory => .dir,
        .sym_link => .symlink,
        else => return error.NotAFile,
    };
    const id = scan.fileIdAt(dir, io, base);
    return .{
        .kind = kind,
        .mtime_ns = if (stat.mtime.nanoseconds > 0) @intCast(stat.mtime.nanoseconds) else 0,
        .size_bytes = if (kind == .regular_file) stat.size else 0,
        .file_id_lo = id.lo,
        .file_id_hi = id.hi,
    };
}

const Identity = struct { dev: u64, ino: u64 };

fn rootIdentity(arena: std.mem.Allocator, io: std.Io, root: []const u8) !Identity {
    _ = arena;
    const trimmed = std.mem.trimEnd(u8, root, "/\\");
    const parent = std.fs.path.dirname(trimmed) orelse ".";
    const base = std.fs.path.basename(trimmed);
    if (base.len == 0) return error.InvalidPath;
    var dir = if (std.fs.path.isAbsolute(parent))
        try std.Io.Dir.openDirAbsolute(io, parent, .{})
    else
        try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);
    const id = scan.fileIdAt(dir, io, base);
    return .{ .dev = id.hi, .ino = id.lo };
}

fn cleanup(io: std.Io, meta_dir: std.Io.Dir) void {
    meta_dir.deleteFile(io, format.json_file) catch {};
    meta_dir.deleteFile(io, format.meta_file) catch {};
    meta_dir.deleteFile(io, format.txt_file) catch {};
    meta_dir.deleteFile(io, format.json_file ++ ".tmp") catch {};
    meta_dir.deleteFile(io, format.meta_file ++ ".tmp") catch {};
    meta_dir.deleteFile(io, format.txt_file ++ ".tmp") catch {};
    meta_dir.deleteTree(io, "batches/00000001") catch {};
}

fn openRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{})
    else
        std.Io.Dir.cwd().openDir(io, root, .{});
}

fn readRootFile(arena: std.mem.Allocator, io: std.Io, root: []const u8, sub_path: []const u8) !?[]u8 {
    var dir = openRoot(io, root) catch return null;
    defer dir.close(io);
    return dir.readFileAlloc(io, sub_path, arena, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

fn exists(io: std.Io, root: []const u8, sub_path: []const u8) !bool {
    var dir = openRoot(io, root) catch return false;
    defer dir.close(io);
    var file = dir.openFile(io, sub_path, .{ .allow_directory = false }) catch return false;
    file.close(io);
    return true;
}

fn existsInDir(io: std.Io, dir_path: []const u8, sub_path: []const u8) !bool {
    var dir = if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return false
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    var file = dir.openFile(io, sub_path, .{ .allow_directory = false }) catch return false;
    file.close(io);
    return true;
}

fn sameOptional(a: ?[]u8, b: ?[]u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Separator- and case-tolerant path equality (Windows paths from the registry and gitdir resolution can differ in
/// spelling). Both values are canonical paths; this is not a prefix test.
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        const l = if (left == '\\') '/' else left;
        const r = if (right == '\\') '/' else right;
        if (@import("builtin").os.tag == .windows) {
            if (std.ascii.toLower(l) != std.ascii.toLower(r)) return false;
        } else if (l != r) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------------

const testing = std.testing;
const engine = @import("engine.zig");

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

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(name) orelse ".");
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

fn tmpRoot(io: std.Io, dir: std.Io.Dir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const count = try dir.realPath(io, buffer);
    return buffer[0..count];
}

test "a seed copies the base generation, writes genesis 1, and the diff pass hashes only the difference" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A synthetic repository: base/.git with HEAD and objects; wt is a linked worktree of it.
    try writeFile(tmp.dir, io, "base/.git/objects/.keep", "");
    try writeFile(tmp.dir, io, "base/.git/HEAD", "ref: refs/heads/main\n");
    try writeFile(tmp.dir, io, "base/one.txt", "one\n");
    try writeFile(tmp.dir, io, "base/two.txt", "two\n");
    try writeFile(tmp.dir, io, "base/src/three.txt", "three\n");
    try writeFile(tmp.dir, io, "base/.git/worktrees/wt/commondir", "../..\n");
    try writeFile(tmp.dir, io, "wt/.git", "gitdir: ../base/.git/worktrees/wt\n");
    try writeFile(tmp.dir, io, "wt/one.txt", "one\n");
    // Same size as the base, different bytes: only a content check can tell the seed not to reuse the base hash.
    try writeFile(tmp.dir, io, "wt/two.txt", "TWO\n");
    try writeFile(tmp.dir, io, "wt/src/three.txt", "three\n");
    try writeFile(tmp.dir, io, "wt/branch.txt", "branch\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const base = try std.fs.path.join(allocator, &.{ home, "base" });
    const wt = try std.fs.path.join(allocator, &.{ home, "wt" });

    const base_outcome = try engine.refresh(allocator, io, base, .{ .updated = "2026-10-27T00:00:00Z" });
    try testing.expect(base_outcome.published);

    try testing.expect(try trySeed(allocator, io, base, wt, "2026-10-27T00:01:00Z"));

    var wt_dir = try openRoot(io, wt);
    defer wt_dir.close(io);
    var wt_meta = try wt_dir.openDir(io, ".fs-meta", .{ .iterate = true });
    defer wt_meta.close(io);
    const document = try wt_meta.readFileAlloc(io, format.json_file, allocator, std.Io.Limit.limited(1 << 20));
    var parsed = try json.parse(allocator, document);
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 1), json.optionalInt(&parsed.value.object, "generation").?);
    var genesis = try wt_meta.openDir(io, "batches/00000001", .{});
    genesis.close(io);

    const diff = try engine.refresh(allocator, io, wt, .{ .updated = "2026-10-27T00:02:00Z" });
    try testing.expect(diff.published);
    try testing.expectEqual(@as(u64, 2), diff.generation);
    // `two.txt` is a same-size branch edit and `branch.txt` is new: exactly those two are hashed by the diff. The
    // other two copied files reuse the base hashes.
    try testing.expectEqual(@as(u64, 2), diff.hashed);
}

test "a seed is refused when the ignore files differ, the scan block differs, or a trio already exists" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "base/.git/objects/.keep", "");
    try writeFile(tmp.dir, io, "base/.git/HEAD", "ref: refs/heads/main\n");
    try writeFile(tmp.dir, io, "base/a.txt", "a\n");
    try writeFile(tmp.dir, io, "base/.git/worktrees/wt/commondir", "../..\n");
    try writeFile(tmp.dir, io, "wt/.git", "gitdir: ../base/.git/worktrees/wt\n");
    try writeFile(tmp.dir, io, "wt/a.txt", "a\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    const base = try std.fs.path.join(allocator, &.{ home, "base" });
    const wt = try std.fs.path.join(allocator, &.{ home, "wt" });
    _ = try engine.refresh(allocator, io, base, .{ .updated = "2026-10-27T00:00:00Z" });

    // The new worktree's ignore file is not the base's: no seed.
    try writeFile(tmp.dir, io, "wt/.fs-meta/ignore", "different/\n");
    try testing.expect(!try trySeed(allocator, io, base, wt, "2026-10-27T00:01:00Z"));

    // A base published with --no-gitignore has a different scan block: no seed.
    try tmp.dir.deleteTree(io, "wt/.fs-meta");
    _ = try engine.refresh(allocator, io, base, .{ .updated = "2026-10-27T00:02:00Z", .respect_gitignore = false, .force = true });
    try testing.expect(!try trySeed(allocator, io, base, wt, "2026-10-27T00:03:00Z"));

    // A trio already present is a history, not a seed target.
    _ = try engine.refresh(allocator, io, base, .{ .updated = "2026-10-27T00:04:00Z", .force = true });
    try writeFile(tmp.dir, io, "wt/.fs-meta/files.json", "");
    try testing.expect(!try trySeed(allocator, io, base, wt, "2026-10-27T00:06:00Z"));
}
