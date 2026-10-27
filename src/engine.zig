// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! One pass of the engine: "bring `<root>/.fs-meta` up to date".
//!
//! This is the composition the pieces were built for, and the only place that knows all of them:
//!
//! 1. read the trio, if there is one, and **validate** it (§ 8) — an invalid trio is not an error, it is the
//!    absence of a previous generation, and the pass starts from nothing (the whole design is "the trio is a
//!    cache, never a correctness input", FORMAT.md § 1);
//! 2. load it into a `Cache`;
//! 3. **cold start** against the real tree through the OS lister — one stat per directory and one bulk listing
//!    per directory, no hashing, no walk;
//! 4. `publish` a new generation **only if something changed**, in the §9 order.
//!
//! Nothing here reads a file's content. A file that changed is marked dirty and published as listing-only; the
//! engine hashes it when a client asks (the socket path), and the *next* pass publishes the hash.

const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const json = @import("json_doc.zig");
const validate = @import("validate.zig");
const cache_mod = @import("cache.zig");
const coldstart = @import("coldstart.zig");
const lister = @import("lister.zig");
const publish_mod = @import("publish.zig");
const batch_mod = @import("batch.zig");
const scan = @import("scan.zig");
const ignore_mod = @import("ignore.zig");
const ignores = @import("ignores.zig");
const boundary_mod = @import("boundary.zig");

pub const Cache = cache_mod.Cache;

pub const Options = struct {
    hash_mode: scan.HashMode = .text,
    respect_gitignore: bool = true,
    ignored_dir_names: []const []const u8 = &.{ ".git", ".fs-meta" },
    writer: []const u8 = "fs-meta/1",
    /// No clock in the engine core: the caller says when the pass ran, which keeps output reproducible.
    updated: []const u8,
    /// Preserved across generations; defaults to `updated` when the trio has never been written.
    created: ?[]const u8 = null,
    /// Write a generation even when nothing changed (a caller that wants a heartbeat).
    force: bool = false,
    /// How many generations of `batches/` the archive retains (FORMAT.md § 17.6). The newest is always kept, so
    /// a value below one is read as one. Rotation runs on a publishing pass, after the batch that describes it.
    keep_batches: usize = batch_mod.default_keep,
    /// Measure the naive listing against the batched one: a readdir plus a stat per entry.
    per_file: bool = false,
};

/// Open `root` as a directory handle. This is the **one** place the CLI's locator becomes a handle: everything
/// below works through `root_dir`, so no absolute path is interpolated into anything the trio stores or opens.
fn openRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
}

/// Open `<root>/.fs-meta`, creating it **through the root handle** when it is not there yet.
///
/// The create is a relative one, so it stays on the locator's own volume and needs no full path: a handle is
/// opened on the drive it points at, and a relative create through it resolves there. The failure of a create
/// is returned as an error the caller sees — the earlier `CreateDirectoryW` call discarded its `BOOL`, so a
/// refused create resurfaced one call later as `FileNotFound` from this very open.
fn openOrCreateMetaDir(io: std.Io, root_dir: std.Io.Dir) !std.Io.Dir {
    return root_dir.openDir(io, format.directory_name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try root_dir.createDirPath(io, format.directory_name);
            return root_dir.openDir(io, format.directory_name, .{ .iterate = true });
        },
        else => return err,
    };
}

/// Where a pass spends its time, in nanoseconds. Reported with `--stats`; the sum is the pass.
pub const Stats = struct {
    load_ns: i96 = 0,
    discover_ns: i96 = 0,
    hash_ns: i96 = 0,
    publish_ns: i96 = 0,

    pub fn totalNs(self: Stats) i96 {
        return self.load_ns + self.discover_ns + self.hash_ns + self.publish_ns;
    }
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.real.now(io).nanoseconds;
}

/// Whether `name` is strictly below `base` in the trio's `/`-separated namespace. The boundary directory itself
/// was never listed, so only its children can be found under it.
fn isUnder(name: []const u8, base: []const u8) bool {
    if (name.len <= base.len) return false;
    if (!std.mem.startsWith(u8, name, base)) return false;
    return name[base.len] == '/';
}

/// How many names the previous generation had under any of this pass's boundaries. That count is the migration:
/// the first pass after the rule lands deletes them, and the user is told why once rather than discovering it.
fn countUnderBoundaries(items: []const batch_mod.Item, boundaries: []const boundary_mod.Boundary) u64 {
    if (boundaries.len == 0) return 0;
    var total: u64 = 0;
    for (items) |item| {
        for (boundaries) |boundary| {
            if (isUnder(item.name, boundary.path)) {
                total += 1;
                break;
            }
        }
    }
    return total;
}

pub const Outcome = struct {
    /// `ok` when the previous trio was valid, or the verdict it failed with (the pass then rebuilt from nothing).
    previous_verdict: validate.Verdict = .ok,
    generation: u64 = 0,
    published: bool = false,
    count: u64 = 0,
    /// The reconciliation: what the pass actually saw change.
    report: coldstart.Report = .{},
    /// Entries whose content hash was taken by this pass (the dirty ones). Unchanged entries reuse theirs.
    hashed: u64 = 0,
    /// Nested repositories this pass refused to cross (`plans/worktrees.md` § 4). Recorded in the trio as
    /// `scan.nestedRepos = true`; reported by `scan --json` as a list, and counted here for the log.
    boundaries: u64 = 0,
    /// The boundaries themselves, workspace-relative. M6's pass-time discovery reads this: with `gitwatch` off there
    /// is no metadata event, so the pass that saw a new worktree is the only discovery route.
    boundary_paths: []const boundary_mod.Boundary = &.{},
    /// Names the previous generation described under a boundary and this pass does not. Non-zero means the
    /// boundary rule changed the answer for this root, which is what the one-line migration notice says.
    dropped_under_boundaries: u64 = 0,
    /// Where the pass spent its time.
    stats: Stats = .{},
};

fn readOptional(io: std.Io, dir: std.Io.Dir, name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    return dir.readFileAlloc(io, name, allocator, std.Io.Limit.limited(1 << 28)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Read a trio's three files, or nothing when there is no trio to read.
const Trio = struct {
    meta: []u8,
    txt: []u8,
    json: []u8,
};

fn readTrio(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator) !?Trio {
    const meta = try readOptional(io, dir, format.meta_file, allocator) orelse return null;
    const txt = try readOptional(io, dir, format.txt_file, allocator) orelse return null;
    const document = try readOptional(io, dir, format.json_file, allocator) orelse return null;
    return .{ .meta = meta, .txt = txt, .json = document };
}

/// One pass over `root`. `arena` holds everything for the pass; the returned outcome is a value.
pub fn refresh(arena: std.mem.Allocator, io: std.Io, root: []const u8, options: Options) !Outcome {
    var outcome: Outcome = .{};
// Filled right after Cache.load: the only moment the previous generation still exists.
var previous: std.ArrayListUnmanaged(batch_mod.Item) = .empty;
    const t0 = nowNs(io);

    // The root is the CLI's **locator**, and this is the one place it becomes a handle. From here the pass works
    // through `root_dir`: `.fs-meta` is opened and, when missing, created relative to it — so the pass never hands
    // an absolute path to a path-based API and never stores one.
    var root_dir = openRoot(io, root) catch return error.RootMissing;
    defer root_dir.close(io);
    var meta_dir = try openOrCreateMetaDir(io, root_dir);
    defer meta_dir.close(io);

    // 1-2. The previous generation, if it is one this reader understands.
    var cache: Cache = .{ .allocator = arena };
    defer cache.deinit();
    var created: []const u8 = options.updated;
    if (try readTrio(io, meta_dir, arena)) |trio| {
        const result = try validate.validate(arena, .{
            .json_bytes = trio.json,
            .meta_bytes = trio.meta,
            .txt_bytes = trio.txt,
        });
        outcome.previous_verdict = result.verdict;
        if (result.verdict == .ok) {
            // The generation is the document's, not the count's: a pass must continue the numbering.
            var parsed = json.parse(arena, trio.json) catch return error.InvalidJson;
            defer parsed.deinit();
            var generation: u64 = 0;
            if (parsed.value == .object) {
                generation = json.optionalInt(&parsed.value.object, "generation") orelse 0;
                if (json.optionalString(&parsed.value.object, "created")) |value| created = value;
            }
            cache = try Cache.load(arena, result.entries, result.names, generation);
// The previous generation exists only here: discovery mutates the cache in place.
//
// Only the entries may be borrowed from the cache; **the names are duplicated**. A cache loaded from a trio
// keys its entries by interior slices of that trio's `files.txt`, and `coldstart` frees the name of every entry
// it removes — `Allocator.free` writes `undefined` (0xAA in a debug build) over the slice, and only then is the
// arena free a no-op. A snapshot holding those slices would read a dead name for exactly the deleted entries,
// which are the only names `diff` takes from `previous`: a deletion keeps the hash and no bytes, so a batch
// cannot recover the path from the entry. Owning the names here is what puts the path that was deleted into
// `batches/<generation>/files.txt`.
for (cache.files.keys()) |name| try previous.append(arena, batch_mod.fileItem(try arena.dupe(u8, name), cache.files.get(name).?));
for (cache.dirs.keys()) |name| {
if (name.len == 0) continue;
try previous.append(arena, batch_mod.dirItem(try arena.dupe(u8, name), cache.dirs.get(name).?));
}
        }
    }

    // 3. The tree, through the OS lister. The two root-level ignore sources are re-read here on every pass — no
    // cached copy and no mtime (`plans/worktrees.md` § 5b), which is what makes a hand edit land on the next one.
    const t1 = nowNs(io);
    var rules = ignore_mod.Stack.init(arena, io, root, options.respect_gitignore);
    defer rules.deinit();
    var sources = try ignores.Sources.load(arena, io, root, options.respect_gitignore);
    defer sources.deinit();
    var tree: lister.Tree = .{
        .io = io,
        .root = root,
        .reserved = &.{ ".git", ".fs-meta" },
        .ignored_dir_names = options.ignored_dir_names,
        .ignore = &rules,
        .sources = &sources,
        .per_file = options.per_file,
    };
    outcome.report = try coldstart.coldStart(arena, &cache, tree.lister(), root);
    outcome.boundaries = tree.boundaries.items.len;
    outcome.boundary_paths = tree.boundaries.items;
    outcome.dropped_under_boundaries = countUnderBoundaries(previous.items, tree.boundaries.items);
    const t2 = nowNs(io);
    outcome.count = cache.files.count() + cache.dirCount();

    // 3b. The content hashes, for the entries that need one. A file whose mtime and size still match the
    // previous generation keeps its hash; everything else is hashed once, here, and written into the trio so
    // the *next* pass has hashes to reuse.
    if (options.hash_mode != .none) {
        outcome.hashed = try hashDirty(arena, io, root, &cache, options.hash_mode);
    }
    const t3 = nowNs(io);

    // 4. Publish only when there is something to say.
    const root_stat = (try tree.lister().stat(root)) orelse return error.RootMissing;
    const needs_publish = options.force or outcome.previous_verdict != .ok or outcome.report.changed() or
        outcome.hashed > 0;
    if (!needs_publish) {
        outcome.generation = cache.generation;
        outcome.stats = .{ .load_ns = t1 - t0, .discover_ns = t2 - t1, .hash_ns = t3 - t2 };
        return outcome;
    }

    const generation = cache.generation + 1;
    const written = try publish_mod.publish(arena, io, meta_dir, &cache, .{
        .generation = generation,
        .normalize = switch (options.hash_mode) {
            .none => "none",
            .lf => "lf",
            .text => "text",
        },
        .root_dev = root_stat.file_id_hi,
        .root_ino = root_stat.file_id_lo,
        .created = created,
        .updated = options.updated,
        .writer = options.writer,
        .scan = .{
            .hash_mode = switch (options.hash_mode) {
                .none => "none",
                .lf => "lf",
                .text => "text",
            },
            .ignored_dir_names = options.ignored_dir_names,
            .respect_gitignore = options.respect_gitignore,
            // The engine always applies the boundary rule, so the record is always present. Absent in a trio
            // means an older engine (or a port) that did not, and a reader may not infer the rule from it.
            .nested_repos = true,
            // What this pass actually consulted, in precedence order. A missing file is absent from the list
            // rather than present as a stale entry; `.gitignore` is listed whenever the flag allowed the chain.
            .ignore_sources = sources.active,
        },
    });
    outcome.published = true;
    outcome.generation = generation;
    outcome.count = written.count;
// The change set, after the commit record: nothing changed means no batch, so the sequence does not advance.
if (outcome.previous_verdict == .ok) {
var current: std.ArrayListUnmanaged(batch_mod.Item) = .empty;
for (cache.files.keys()) |name| try current.append(arena, batch_mod.fileItem(name, cache.files.get(name).?));
for (cache.dirs.keys()) |name| {
if (name.len == 0) continue;
try current.append(arena, batch_mod.dirItem(name, cache.dirs.get(name).?));
}
const plan = try batch_mod.diff(arena, previous.items, current.items);
if (plan.entries.len > 0) {
try batch_mod.write(arena, io, meta_dir, plan, .{
.generation = generation,
.parent = generation - 1,
.normalize = switch (options.hash_mode) {
.none => "none",
.lf => "lf",
.text => "text",
},
.root_dev = root_stat.file_id_hi,
.root_ino = root_stat.file_id_lo,
.created = created,
.updated = options.updated,
.writer = options.writer,
});
}
}

    // Retention (§ 17.6): the archive is a window, not a history. It runs after the commit record and after the
    // batch that describes it, oldest first, so a failure can only leave the oldest generations removed. A
    // rotation failure is reported rather than swallowed: the trio is already committed, but a writer that
    // claims to have trimmed the archive and did not is lying about its own output.
    _ = try batch_mod.rotate(arena, io, meta_dir, options.keep_batches);

    outcome.stats = .{ .load_ns = t1 - t0, .discover_ns = t2 - t1, .hash_ns = t3 - t2, .publish_ns = nowNs(io) - t3 };
    return outcome;
}

/// Hash every entry still marked dirty, reusing the hash of every entry that did not change.
fn hashDirty(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cache: *Cache,
    mode: scan.HashMode,
) !u64 {
    const paths = try arena.alloc([]const u8, cache.files.count());
    var count: usize = 0;
    const keys = cache.files.keys();
    for (keys) |path| {
        paths[count] = path;
        count += 1;
    }
    var hashed: u64 = 0;
    for (paths[0..count]) |path| {
        const state = cache.files.getPtr(path) orelse continue;
        if (state.kind != .regular_file) continue; // directories and symlinks carry no content hash
        if (state.content_hash != null) continue; // unchanged: reuse what the previous generation recorded
        const full = if (root.len == 0)
            path
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, path });
        const result = scan.hashFileAt(io, full, mode) catch continue; // unreadable now: stays dirty
        state.content_hash = result.hash;
        state.hash_lf = result.hash_lf;
        hashed += 1;
    }
    return hashed;
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(name) orelse ".");
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "a pass over a fresh tree publishes one generation, and a second pass changes nothing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    try writeFile(tmp.dir, io, "src/b.java", "class B {}\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const first = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:00Z" });
    try testing.expect(first.published);
    try testing.expectEqual(validate.Verdict.ok, first.previous_verdict); // no trio: "ok" by absence
    try testing.expectEqual(@as(u64, 1), first.generation);
    try testing.expectEqual(@as(u64, 3), first.count); // a.txt, src, src/b.java

    // The trio on disk validates.
    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta_dir = try root_dir.openDir(io, format.directory_name, .{ .iterate = true });
    defer meta_dir.close(io);
    {
        const trio = (try readTrio(io, meta_dir, arena)).?;
        const result = try validate.validate(arena, .{ .json_bytes = trio.json, .meta_bytes = trio.meta, .txt_bytes = trio.txt });
        try testing.expectEqual(validate.Verdict.ok, result.verdict);
        try testing.expectEqual(@as(u64, 3), result.count);
        // With the default hash mode the pass hashes what it discovered, so the generation carries fingerprints —
        // and only the discovery pass pays for them.
        var files_with_hash: usize = 0;
        for (result.entries) |entry| {
            if (entry.kind() == .regular_file) {
                try testing.expect(entry.contentKnown());
                files_with_hash += 1;
            }
        }
        try testing.expectEqual(@as(usize, 2), files_with_hash);
        try testing.expectEqual(@as(u64, 2), first.hashed);
    }

    // Nothing changed -> no new generation.
    const second = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:01Z" });
    // Nothing changed, so no hash was taken: the second pass reused what the first one published.
    try testing.expectEqual(@as(u64, 0), second.hashed);
    try testing.expect(!second.published);
    try testing.expectEqual(@as(u64, 1), second.generation);
    try testing.expect(!second.report.changed());
}

test "a changed file makes the next pass publish, and the change is listing-only until it is hashed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    _ = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:00Z" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello there\n" });

    const after = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:02Z" });
    try testing.expect(after.published);
    try testing.expectEqual(@as(u64, 2), after.generation);
    try testing.expectEqual(@as(u64, 1), after.report.files_modified);
}

test "a deleted name survives into the batch that records it" {
    // The regression this guards: the `previous` snapshot is built *before* discovery, discovery frees the cache
    // entry of a name it no longer sees (for a trio-loaded cache that is an interior slice of `files.txt`), and
    // the batch writer then copies the name. Without an owned snapshot the deleted entry's path in the batch's
    // `files.txt` is a dead run of one byte, which still passes the self-delimiting LF check in `batch.decode`
    // and reaches a consumer as `deleted <mojibake>`.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "a.txt", "one\n");
    try writeFile(tmp.dir, io, "src/b.java", "class B {}\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    _ = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:00Z" });
    try tmp.dir.deleteFile(io, "src/b.java");
    const second = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:01Z" });
    try testing.expect(second.published);
    try testing.expectEqual(@as(u64, 2), second.generation);

    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta_dir = try root_dir.openDir(io, format.directory_name, .{ .iterate = true });
    defer meta_dir.close(io);
    var batch_dir = try meta_dir.openDir(io, "batches/00000002", .{});
    defer batch_dir.close(io);
    const txt = try batch_dir.readFileAlloc(io, format.txt_file, arena, std.Io.Limit.limited(1 << 16));

    try testing.expect(std.mem.indexOf(u8, txt, "src/b.java\n") != null);
    // And no line is a single repeated byte: a dead name is a run of the allocator's poison (0xAA in debug),
    // and no real path is. A one-byte name is skipped because `aaaa` would trivially match.
    var lines = std.mem.splitScalar(u8, txt, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        var all_same = true;
        for (line[1..]) |byte| {
            if (byte != line[0]) {
                all_same = false;
                break;
            }
        }
        try testing.expect(!all_same);
    }
}

test "a nested repository is absent from the trio, and the trio records the boundary rule" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, "visible.txt", "v\n");
    try tmp.dir.createDirPath(io, "clone/.git/objects");
    try writeFile(tmp.dir, io, "clone/.git/HEAD", "ref: refs/heads/main\n");
    try writeFile(tmp.dir, io, "clone/secret.txt", "s\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const first = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:00Z" });
    try testing.expect(first.published);
    try testing.expectEqual(@as(u64, 1), first.boundaries);

    // The trio describes one tree: the boundary's files are absent, and the record says why without growing.
    const names = try trioNames(arena, root, io);
    try testing.expect(hasName(names, "visible.txt"));
    try testing.expect(!hasName(names, "clone/secret.txt"));
    try testing.expect(!hasName(names, "clone"));

    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta_dir = try root_dir.openDir(io, format.directory_name, .{ .iterate = true });
    defer meta_dir.close(io);
    const document = try meta_dir.readFileAlloc(io, format.json_file, arena, std.Io.Limit.limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, document, "\"nestedRepos\": true") != null);

    // A second pass is unchanged: the rule is stable, not a one-time deletion.
    const second = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:01Z" });
    try testing.expect(!second.published);
    try testing.expectEqual(@as(u64, 0), second.dropped_under_boundaries);
}

test "the ignore sources exclude, are recorded, and a hand edit lands on the next pass" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".gitignore", "*.log\n");
    try writeFile(tmp.dir, io, ".git/info/exclude", "cache/\n");
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "worktrees/w1/\n");
    try writeFile(tmp.dir, io, "a.txt", "a\n");
    try writeFile(tmp.dir, io, "debug.log", "d\n");
    try writeFile(tmp.dir, io, "cache/generated.txt", "g\n");
    try writeFile(tmp.dir, io, "worktrees/w1/secret.txt", "s\n");
    try writeFile(tmp.dir, io, "worktrees/w2/keep.txt", "k\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const first = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:00Z" });
    try testing.expect(first.published);

    // Both root-level sources did their job, and the walk and the pass agree about the result.
    const from_pass = try trioNames(arena, root, io);
    const from_walk = try scanNames(arena, root, io);
    try expectNameSets(from_walk, from_pass);
    try testing.expect(hasName(from_pass, "a.txt"));
    try testing.expect(hasName(from_pass, "worktrees/w2/keep.txt"));
    try testing.expect(!hasName(from_pass, "debug.log"));
    try testing.expect(!hasName(from_pass, "worktrees/w1/secret.txt"));
    try testing.expect(!hasName(from_pass, "cache/generated.txt"));

    // The trio records what it consulted, in precedence order.
    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta_dir = try root_dir.openDir(io, format.directory_name, .{ .iterate = true });
    defer meta_dir.close(io);
    var document = try meta_dir.readFileAlloc(io, format.json_file, arena, std.Io.Limit.limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, document,
        "\"ignoreSources\": [\"gitignore\", \"info/exclude\", \"fs-meta/ignore\"]") != null);

    // A hand edit to `.fs-meta/ignore` is re-read on the next pass; nothing cached the old rules.
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "");
    const second = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:01Z" });
    try testing.expect(second.published);
    const relaxed = try trioNames(arena, root, io);
    try testing.expect(hasName(relaxed, "worktrees/w1/secret.txt"));

    // Deleting git's line brings its subtree back too, and the source leaves the recorded list with the file.
    try tmp.dir.deleteFile(io, ".git/info/exclude");
    const third = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:02Z" });
    try testing.expect(third.published);
    const restored = try trioNames(arena, root, io);
    try testing.expect(hasName(restored, "cache/generated.txt"));
    document = try meta_dir.readFileAlloc(io, format.json_file, arena, std.Io.Limit.limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, document,
        "\"ignoreSources\": [\"gitignore\", \"fs-meta/ignore\"]") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"info/exclude\"") == null);
}

/// The names a trio describes, sorted the way the trio sorts them.
fn trioNames(arena: std.mem.Allocator, root: []const u8, io: std.Io) ![][]const u8 {
    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta_dir = try root_dir.openDir(io, format.directory_name, .{ .iterate = true });
    defer meta_dir.close(io);
    const trio = (try readTrio(io, meta_dir, arena)).?;
    const result = try validate.validate(arena, .{ .json_bytes = trio.json, .meta_bytes = trio.meta, .txt_bytes = trio.txt });
    try testing.expectEqual(validate.Verdict.ok, result.verdict);
    const names = try arena.alloc([]const u8, result.names.len);
    @memcpy(names, result.names);
    return names;
}

/// The names a full walk reports, in the order the file system handed them over. The agreement with a trio is
/// about membership, not order: the trio is sorted by `(nameHash, name)` (§ 4) and a walk has no order to offer.
fn scanNames(arena: std.mem.Allocator, root: []const u8, io: std.Io) ![][]const u8 {
    const facts = try scan.scan(arena, io, root, .{ .hash_mode = .none, .respect_gitignore = true, .ignored_dir_names = &.{ ".git", ".fs-meta" } });
    const names = try arena.alloc([]const u8, facts.len);
    for (facts, 0..) |fact, index| names[index] = fact.name;
    return names;
}

/// § 4 stores a directory's name with a trailing `/`; the walk reports a folder by its path, which has none. The
/// two describe the same tree, so a name is compared in the form that is not a layout decision.
fn trimSlash(name: []const u8) []const u8 {
    if (name.len > 1 and name[name.len - 1] == 0x2F) return name[0 .. name.len - 1];
    return name;
}

fn hasName(names: [][]const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, trimSlash(name), trimSlash(wanted))) return true;
    }
    return false;
}

/// Same names, same count — the order each side has is its own (§ 4 orders the trio, nothing orders a walk).
fn expectNameSets(a: [][]const u8, b: [][]const u8) !void {
    if (a.len != b.len) {
        std.debug.print("length differs: walk={d} trio={d}\n", .{ a.len, b.len });
        for (a) |name| std.debug.print("  walk: {s}\n", .{name});
        for (b) |name| std.debug.print("  trio: {s}\n", .{name});
    }
    try testing.expectEqual(a.len, b.len);
    for (a) |want| {
        if (!hasName(b, want)) std.debug.print("the trio has no '{s}'\n", .{want});
        try testing.expect(hasName(b, want));
    }
}

test "a pass and a full walk agree about the tree, .gitignore included" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n!keep.log\nbuild/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x.log", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.log", .data = "k\n" });
    try writeFile(tmp.dir, io, "build/y.txt", "y\n");
    try writeFile(tmp.dir, io, "src/z.txt", "z\n");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const first = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:00Z" });
    try testing.expect(first.published);

    // The pass skipped the log file and the excluded directory, and kept the negation.
    const from_pass = try trioNames(arena, root, io);
    const from_walk = try scanNames(arena, root, io);
    try expectNameSets(from_walk, from_pass);

    const expected = [_][]const u8{ ".gitignore", "a.txt", "keep.log", "src", "src/z.txt" };
    try testing.expectEqual(@as(usize, expected.len), from_pass.len);
        // The trio is ordered by (nameHash, name) (section 4) while the expectation is written in name order, so
        // the agreement is about membership: same names, same count. The order itself is asserted by publish's test.
        try testing.expectEqual(expected.len, from_pass.len);
        for (expected) |want| try testing.expect(hasName(from_pass, want));

    // Relax the rules: the previously excluded file and directory must appear, through the pass as well.
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "!keep.log\n" });
    const second = try refresh(arena, io, root, .{ .updated = "2026-10-18T00:00:05Z" });
    try testing.expect(second.published);
    const relaxed = try trioNames(arena, root, io);
    const relaxed_walk = try scanNames(arena, root, io);
    try expectNameSets(relaxed_walk, relaxed);
    try testing.expect(hasName(relaxed, "x.log"));
    try testing.expect(hasName(relaxed, "build"));
    try testing.expect(hasName(relaxed, "build/y.txt"));
}
