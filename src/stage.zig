// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Stage states (`plans/build-artifacts.md` § 7): one trio and batch archive per declared stage.
//!
//! A stage owns a list of workspace-relative output folders. This module scans only those folders, reuses the
//! previous stage state for unchanged files, hashes the dirty residue, and publishes a normal trio into
//! `<root>/.fs-meta/stages/<NN>/`. It never touches the root trio and never writes outside `.fs-meta`.
//!
//! The scanner deliberately uses `scan.scanDetailed(.hash_files = false)` for the walk: the walk supplies names,
//! mtimes, sizes and identities, and this module hashes only the files whose metadata moved. That is the
//! incremental check the plan promises, and it is the same reuse rule the root engine uses.
//!
//! ## Streaming
//!
//! `scan.Options.on_fact` lets this module settle, hash and classify each entry as the walk produces it. A caller
//! that supplies `Options.stream` therefore gets `on_start` before the first change and `on_change` while the walk
//! is still running; deletes are emitted after the walk because only then is the surviving set known, and
//! `on_finish` comes after the stage state is committed. `stage diff` and the CLI pass no stream and use the
//! resulting plan.

const std = @import("std");
const format = @import("format.zig");
const json = @import("json_doc.zig");
const validate = @import("validate.zig");
const cache_mod = @import("cache.zig");
const publish_mod = @import("publish.zig");
const batch_mod = @import("batch.zig");
const scan = @import("scan.zig");
const build_config = @import("build_config.zig");
const safe_dir = @import("safe_dir.zig");
const server = @import("server.zig");

pub const StateDir = "stages";
pub const Outcome = struct {
    stage: u16,
    generation: u64 = 0,
    published: bool = false,
    added: u64 = 0,
    changed: u64 = 0,
    deleted: u64 = 0,
    /// Entries that name a tracked workspace file rather than a stage-owned artifact. They are reported in the
    /// stage batch and never enter the stage state, because the root trio already owns that name.
    tracked: u64 = 0,
    /// The exact change set, for `stage scan --json` and for a future streamed stage batch.
    plan: ?batch_mod.Plan = null,
    /// A cold scan: there was no usable previous state, or its `configHash`/root identity did not match.
    cold: bool = false,
};

const Previous = struct {
    cache: cache_mod.Cache,
    created: []const u8,
    config_hash: u64,
    generation: u64,
};

pub const ChangeKind = enum { added, changed, deleted };

/// What an app says it did to one path when it closes a build batch (`APP_BATCH_FILE`). The app names the files;
/// the daemon reads and hashes them, so the stage state sees settled files rather than watcher events.
pub const IngestKind = enum { upsert, delete };

pub const IngestChange = struct {
    name: []const u8,
    kind: IngestKind,
};

/// One change as the scanner settles it. The entry carries the change bit, so a stream writer can hand it to
/// `wire.writeChangeEntryAs` unchanged.
pub const Change = struct {
    kind: ChangeKind,
    entry: format.Entry,
    name: []const u8,
};

/// A live stage-batch sink. `on_start` is called lazily before the first change (so an empty scan emits nothing);
/// `on_finish` is called after the state is committed, or by the caller with `ok = false` when the pass fails.
pub const Stream = struct {
    ctx: *anyopaque,
    on_start: ?*const fn (ctx: *anyopaque, stage: u16, generation: u64, parent: u64) void = null,
    on_change: ?*const fn (ctx: *anyopaque, change: Change) void = null,
    on_finish: ?*const fn (ctx: *anyopaque, stage: u16, generation: u64, added: u64, changed: u64, deleted: u64, ok: bool) void = null,
};

/// Run one stage pass. `write == false` is `stage diff`: scan and compare, publish nothing.
pub fn refresh(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    declaration: build_config.Config,
    stage_number: u16,
    options: Options,
) !Outcome {
    const stage = declaration.find(stage_number) orelse return error.StageNotDeclared;
    var outcome = Outcome{ .stage = stage.number };

    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta = try safe_dir.openOrCreateDirectory(io, root_dir, format.directory_name, .{ .iterate = true });
    defer meta.close(io);
    var stages_opt: ?std.Io.Dir = if (options.write)
        try safe_dir.openOrCreateDirectory(io, meta, StateDir, .{ .iterate = true })
    else
        try safe_dir.openExistingDirectory(io, meta, StateDir, .{ .iterate = true });
    defer if (stages_opt) |*dir| dir.close(io);

    var state_dir: ?std.Io.Dir = null;
    if (stages_opt) |stages| {
        var stage_name_buffer: [2]u8 = undefined;
        const stage_name = std.fmt.bufPrint(&stage_name_buffer, "{d:0>2}", .{stage.number}) catch unreachable;
        state_dir = if (options.write)
            try safe_dir.openOrCreateDirectory(io, stages, stage_name, .{ .iterate = true })
        else
            try safe_dir.openExistingDirectory(io, stages, stage_name, .{ .iterate = true });
    }
    defer if (state_dir) |*dir| dir.close(io);

    const identity = rootIdentity(arena, io, root);
    var previous: ?Previous = null;
    if (state_dir) |dir| {
        if (try loadPrevious(arena, io, dir, stage, identity)) |state| previous = state;
    }
    if (previous) |state| {
        outcome.generation = state.generation;
    } else {
        outcome.cold = true;
    }
    defer if (previous) |*state| state.cache.deinit();

    const scanned = try collectFacts(arena, io, root, &stage, if (previous) |state| &state.cache else null, options.stream);
    const facts = scanned.facts;
    std.mem.sort(scan.Fact, facts, {}, factLessThan);

    var cache = try cacheFromFacts(arena, facts, if (previous) |state| state.generation else 0);
    defer cache.deinit();

    const before = if (previous) |state| try cacheItems(arena, &state.cache) else try arena.alloc(batch_mod.Item, 0);
    const after = try cacheItems(arena, &cache);
    const plan = try batch_mod.diff(arena, before, after);
    // The plan's names point into the caches, which are freed when this pass returns; the caller owns the plan.
    const owned_names = try arena.alloc([]const u8, plan.names.len);
    for (plan.names, 0..) |name, index| owned_names[index] = try arena.dupe(u8, name);
    const owned_plan = batch_mod.Plan{ .entries = plan.entries, .names = owned_names };
    outcome.plan = owned_plan;
    for (owned_plan.entries) |entry| switch (batch_mod.kindOf(entry) orelse continue) {
        .added => outcome.added += 1,
        .changed => outcome.changed += 1,
        .deleted => outcome.deleted += 1,
    };

    const must_publish = options.write and (outcome.cold or owned_plan.entries.len > 0);
    if (!must_publish) {
        if (previous) |state| outcome.generation = state.generation;
        if (scanned.started) {
            if (options.stream) |stream| {
                if (stream.on_finish) |finish| finish(stream.ctx, stage.number, outcome.generation, outcome.added, outcome.changed, outcome.deleted, true);
            }
        }
        return outcome;
    }

    const generation = if (previous) |state| state.generation + 1 else 1;
    var created = options.updated;
    if (previous) |state| created = state.created;

    const dir = state_dir orelse return outcome;
    try writeStageState(arena, io, dir, &stage, &cache, owned_plan, .{
        .generation = generation,
        .created = created,
        .updated = options.updated,
        .identity = identity,
    });

    outcome.generation = generation;
    outcome.published = true;
    if (scanned.started) {
        if (options.stream) |stream| {
            if (stream.on_finish) |finish| finish(stream.ctx, stage.number, generation, outcome.added, outcome.changed, outcome.deleted, true);
        }
    }
    return outcome;
}

/// The state write shared by a folder scan and an app batch: the trio first, then the archive batch when the plan
/// names a change. Keeping one writer is what makes `stage scan` and `APP_BATCH_END` produce the same state.
const StateWrite = struct {
    generation: u64,
    created: []const u8,
    updated: []const u8,
    identity: scan.FileId,
};

fn writeStageState(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    stage: *const build_config.Stage,
    cache: *const cache_mod.Cache,
    plan: batch_mod.Plan,
    request: StateWrite,
) !void {
    var hash_hex: [16]u8 = undefined;
    const config_hash = format.hex(stage.config_hash, &hash_hex);
    _ = try publish_mod.publish(arena, io, dir, cache, .{
        .generation = request.generation,
        .normalize = @tagName(stage.hash_mode),
        .root_dev = request.identity.hi,
        .root_ino = request.identity.lo,
        .created = request.created,
        .updated = request.updated,
        .writer = "fs-meta/stage/1",
        .scan = .{
            .hash_mode = @tagName(stage.hash_mode),
            .ignored_dir_names = &.{ ".git", ".fs-meta" },
            .respect_gitignore = false,
            .nested_repos = true,
            .ignore_sources = &.{"stage"},
        },
        .stage = .{
            .stage = stage.number,
            .folders = stage.folders,
            .hash = @tagName(stage.hash_mode),
            .config_hash = config_hash,
        },
    });

    if (plan.entries.len > 0) {
        try batch_mod.write(arena, io, dir, plan, .{
            .generation = request.generation,
            .parent = request.generation - 1,
            .normalize = @tagName(stage.hash_mode),
            .root_dev = request.identity.hi,
            .root_ino = request.identity.lo,
            .created = request.created,
            .updated = request.updated,
            .writer = "fs-meta/stage/1",
        });
    }
}

/// Ingest the files an app named in a build batch (`FORMAT.socket.md` § APP_BATCHES). The app has already written
/// them and closed them; this pass stats and hashes exactly those paths, merges them into the stage state, and
/// publishes one stage generation. It never walks a folder, so several concurrent app batches cannot see each
/// other's files: a batch names a set, and that set is the change.
///
/// A stage with no state is `error.NoStageState`: the caller first runs a cold `refresh`, which is the only way to
/// learn what the folder already held. A file that moves while it is hashed is `error.UnstableFile`; the caller
/// reports the batch as failed rather than publishing half of it.
pub fn ingest(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    declaration: build_config.Config,
    stage_number: u16,
    changes: []const IngestChange,
    options: Options,
) !Outcome {
    const stage = declaration.find(stage_number) orelse return error.StageNotDeclared;

    // A batch is one unit: validate every name before touching any file or the state. A name inside this stage's
    // declared folders is a stage-owned artifact; any other workspace name is a **tracked** output (the docs
    // snippet case), reported to the next stage but left to the root trio. Another stage's folder is an error.
    for (changes) |change| {
        if (!format.nameValid(change.name)) return error.InvalidName;
        if (std.fs.path.isAbsolute(change.name)) return error.InvalidName;
        if (reservedPath(change.name)) return error.InvalidName;
        if (declaration.stageOf(change.name)) |owner| {
            if (owner.number != stage.number) return error.StageFileOutside;
        }
    }

    var outcome = Outcome{ .stage = stage.number };

    var root_dir = try openRoot(io, root);
    defer root_dir.close(io);
    var meta = try safe_dir.openOrCreateDirectory(io, root_dir, format.directory_name, .{ .iterate = true });
    defer meta.close(io);
    var stages = try safe_dir.openOrCreateDirectory(io, meta, StateDir, .{ .iterate = true });
    defer stages.close(io);
    var stage_name_buffer: [2]u8 = undefined;
    const stage_name = std.fmt.bufPrint(&stage_name_buffer, "{d:0>2}", .{stage.number}) catch unreachable;
    var state_dir = try safe_dir.openOrCreateDirectory(io, stages, stage_name, .{ .iterate = true });
    defer state_dir.close(io);

    const identity = rootIdentity(arena, io, root);
    var previous = (try loadPrevious(arena, io, state_dir, stage, identity)) orelse return error.NoStageState;
    defer previous.cache.deinit();
    outcome.generation = previous.generation;

    // The state is a set of facts, so start from the previous generation and apply the batch on top. Unlisted
    // entries keep their cached fingerprints: an app batch changes only what it names.
    var by_name: std.StringArrayHashMapUnmanaged(scan.Fact) = .empty;
    defer by_name.deinit(arena);
    for (try cacheFacts(arena, &previous.cache)) |fact| try by_name.put(arena, fact.name, fact);

    // Tracked entries are notifications, not stage state: `docs/Guide.md` is already in the root trio, so putting it
    // in `.fs-meta/stages/<NN>/` would describe one tree twice. They still form one batch with the artifacts, so a
    // consumer sees the build round as a whole.
    var tracked_entries: std.ArrayListUnmanaged(format.Entry) = .empty;
    defer tracked_entries.deinit(arena);
    var tracked_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer tracked_names.deinit(arena);

    for (changes) |change| {
        const tracked = declaration.stageOf(change.name) == null;
        if (tracked) {
            const entry = switch (change.kind) {
                .delete => trackedDeleteEntry(change.name),
                .upsert => blk: {
                    const fact = try factForPath(arena, io, root, change.name, stage.hash_mode);
                    break :blk factEntry(fact, .changed);
                },
            };
            try tracked_entries.append(arena, entry);
            try tracked_names.append(arena, try arena.dupe(u8, change.name));
            outcome.tracked += 1;
            continue;
        }
        switch (change.kind) {
            .delete => try removeFact(arena, &by_name, change.name),
            .upsert => {
                try ensureParentDirs(arena, io, root, &by_name, change.name);
                const fact = try factForPath(arena, io, root, change.name, stage.hash_mode);
                try by_name.put(arena, fact.name, fact);
            },
        }
    }

    const facts = by_name.values();
    std.mem.sort(scan.Fact, facts, {}, factLessThan);
    var cache = try cacheFromFacts(arena, facts, previous.generation);
    defer cache.deinit();

    const before = try cacheItems(arena, &previous.cache);
    const after = try cacheItems(arena, &cache);
    const stage_plan = try batch_mod.diff(arena, before, after);

    // One batch, in report order for the tracked notifications and `(nameHash, name)` order for the stage diff.
    var merged_entries: std.ArrayListUnmanaged(format.Entry) = .empty;
    defer merged_entries.deinit(arena);
    var merged_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer merged_names.deinit(arena);
    try merged_entries.appendSlice(arena, tracked_entries.items);
    try merged_names.appendSlice(arena, tracked_names.items);
    try merged_entries.appendSlice(arena, stage_plan.entries);
    try merged_names.appendSlice(arena, stage_plan.names);

    const owned_names = try arena.alloc([]const u8, merged_names.items.len);
    for (merged_names.items, 0..) |name, index| owned_names[index] = try arena.dupe(u8, name);
    const owned_plan = batch_mod.Plan{
        .entries = try arena.dupe(format.Entry, merged_entries.items),
        .names = owned_names,
    };
    outcome.plan = owned_plan;
    for (owned_plan.entries) |entry| switch (batch_mod.kindOf(entry) orelse continue) {
        .added => outcome.added += 1,
        .changed => outcome.changed += 1,
        .deleted => outcome.deleted += 1,
    };

    // A batch that named only unchanged files (a touch, a rebuild that wrote the same bytes) publishes nothing
    // and does not move the generation, exactly like a folder scan with no diff.
    if (owned_plan.entries.len == 0) return outcome;
    const generation = previous.generation + 1;

    if (options.stream) |stream| {
        if (stream.on_start) |start| start(stream.ctx, stage.number, generation, previous.generation);
        if (stream.on_change) |change| {
            for (owned_plan.entries, owned_plan.names) |entry, name| {
                const kind = batch_mod.kindOf(entry) orelse continue;
                const change_kind: ChangeKind = switch (kind) {
                    .added => .added,
                    .changed => .changed,
                    .deleted => .deleted,
                };
                change(stream.ctx, .{ .kind = change_kind, .entry = entry, .name = name });
            }
        }
    }

    try writeStageState(arena, io, state_dir, &stage, &cache, owned_plan, .{
        .generation = generation,
        .created = previous.created,
        .updated = options.updated,
        .identity = identity,
    });

    outcome.generation = generation;
    outcome.published = true;
    if (options.stream) |stream| {
        if (stream.on_finish) |finish| finish(stream.ctx, stage.number, generation, outcome.added, outcome.changed, outcome.deleted, true);
    }
    return outcome;
}

/// A path segment the walker never lists, so a batch may not name it either: an app must not publish into the
/// metadata directory or into git's store.
fn reservedPath(name: []const u8) bool {
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".git") or std.mem.eql(u8, segment, ".fs-meta")) return true;
    }
    return false;
}

/// A tracked deletion has no stage-state entry to borrow from: the root trio owns the name, so only its identity
/// and the delete bit are known here.
fn trackedDeleteEntry(name: []const u8) format.Entry {
    return .{
        .mtime_ns = 0,
        .size_bytes = 0,
        .content_hash = 0,
        .name_hash = format.wyhash(name),
        .name_offset = 0,
        .name_length = 0,
        .flags_word = format.flags.regular_file | 0x80,
        .file_id_lo = 0,
        .file_id_hi = 0,
    };
}

/// Every entry of a loaded stage state as a scan fact, so `ingest` can apply a batch without walking a folder.
fn cacheFacts(arena: std.mem.Allocator, cache: *const cache_mod.Cache) ![]scan.Fact {
    var facts: std.ArrayListUnmanaged(scan.Fact) = .empty;
    try facts.ensureTotalCapacity(arena, cache.files.count() + cache.dirs.count());
    for (cache.files.keys()) |name| {
        const state = cache.files.get(name).?;
        facts.appendAssumeCapacity(.{
            .name = name,
            .kind = state.kind,
            .mtime_ns = state.mtime_ns,
            .size_bytes = state.size_bytes,
            .content_hash = state.content_hash orelse 0,
            .hash_lf = state.hash_lf,
            .file_id_lo = state.file_id_lo,
            .file_id_hi = state.file_id_hi,
        });
    }
    for (cache.dirs.keys()) |name| {
        if (name.len == 0) continue; // the root is bookkeeping, never a listed entry
        const state = cache.dirs.get(name).?;
        facts.appendAssumeCapacity(.{
            .name = name,
            .kind = .dir,
            .mtime_ns = state.mtime_ns,
            .size_bytes = 0,
            .content_hash = 0,
            .hash_lf = false,
            .file_id_lo = state.file_id_lo,
            .file_id_hi = state.file_id_hi,
        });
    }
    return facts.toOwnedSlice(arena);
}

/// Remove one name from the pending set. A directory removes its subtree: a reported folder deletion is a delete
/// of every name below it, exactly as a folder scan's surviving-set diff produces.
fn removeFact(arena: std.mem.Allocator, map: *std.StringArrayHashMapUnmanaged(scan.Fact), name: []const u8) !void {
    if (map.get(name)) |fact| {
        if (fact.kind != .dir) {
            _ = map.orderedRemove(name);
            return;
        }
    }
    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doomed.deinit(arena);
    for (map.keys()) |key| {
        if (cache_mod.Cache.isUnder(key, name)) try doomed.append(arena, key);
    }
    for (doomed.items) |key| _ = map.orderedRemove(key);
}

/// Add the missing ancestors of `name` as directory facts. A generated file's new package folder is part of the
/// stage state, so the state's direct-child lists stay consistent without a folder walk.
fn ensureParentDirs(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    map: *std.StringArrayHashMapUnmanaged(scan.Fact),
    name: []const u8,
) !void {
    var parent = cache_mod.Cache.parentOf(name);
    while (parent.len > 0 and map.get(parent) == null) {
        const full = try joinPath(arena, root, parent);
        const stat = std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch return error.MissingParent;
        if (stat.kind != .directory) return error.MissingParent;
        const fact = scan.Fact{
            .name = try arena.dupe(u8, parent),
            .kind = .dir,
            .mtime_ns = mtimeNs(stat.mtime),
            .size_bytes = 0,
            .content_hash = 0,
            .hash_lf = false,
            .file_id_lo = 0,
            .file_id_hi = 0,
        };
        try map.put(arena, fact.name, fact);
        parent = cache_mod.Cache.parentOf(parent);
    }
}

/// Stat and hash one path an app reported. The pre/post stat is the same stability rule the folder walker uses:
/// a file that moved while it was hashed is not a settled artifact.
fn factForPath(arena: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8, hash_mode: build_config.HashMode) !scan.Fact {
    const full = try joinPath(arena, root, name);
    const stat = try std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false });
    const kind: format.Kind = switch (stat.kind) {
        .file => .regular_file,
        .directory => .dir,
        .sym_link => .symlink,
        else => return error.UnsupportedKind,
    };
    var fact = scan.Fact{
        .name = try arena.dupe(u8, name),
        .kind = kind,
        .mtime_ns = mtimeNs(stat.mtime),
        .size_bytes = if (kind == .dir) 0 else stat.size,
        .content_hash = 0,
        .hash_lf = false,
        .file_id_lo = 0,
        .file_id_hi = 0,
    };
    if (kind == .regular_file) {
        const hashed = try scan.hashFileAt(io, full, hash_mode);
        fact.content_hash = hashed.hash;
        fact.hash_lf = hashed.hash_lf;
        const after = std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch return error.UnstableFile;
        if (after.size != stat.size or mtimeNs(after.mtime) != fact.mtime_ns) return error.UnstableFile;
        const id = fileIdFor(arena, io, full);
        fact.file_id_lo = id.lo;
        fact.file_id_hi = id.hi;
    }
    return fact;
}

/// `{ dev, ino }` for one path, through its parent handle. Identity is a cache hint, so an unreadable path is
/// `0, 0` rather than an error.
fn fileIdFor(arena: std.mem.Allocator, io: std.Io, full: []const u8) scan.FileId {
    const absolute = std.Io.Dir.cwd().realPathFileAlloc(io, full, arena) catch return .{ .lo = 0, .hi = 0 };
    const parent_path = std.fs.path.dirname(absolute) orelse return .{ .lo = 0, .hi = 0 };
    const base = std.fs.path.basename(absolute);
    var parent = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return .{ .lo = 0, .hi = 0 };
    defer parent.close(io);
    return scan.fileIdAt(parent, io, base);
}

/// The stage batch archive, shaped like `server.BatchWindow` so the same loader fits.
pub fn openBatchWindow(io: std.Io, root: []const u8, number: u16) !server.BatchWindow {
    var root_dir = openRoot(io, root) catch return .{};
    defer root_dir.close(io);
    var meta = (try safe_dir.openExistingDirectory(io, root_dir, format.directory_name, .{ .iterate = true })) orelse return .{};
    defer meta.close(io);
    var stages = (try safe_dir.openExistingDirectory(io, meta, StateDir, .{ .iterate = true })) orelse return .{};
    defer stages.close(io);
    var name_buffer: [2]u8 = undefined;
    const stage_name = std.fmt.bufPrint(&name_buffer, "{d:0>2}", .{number}) catch unreachable;
    var state_dir = (try safe_dir.openExistingDirectory(io, stages, stage_name, .{ .iterate = true })) orelse return .{};
    defer state_dir.close(io);
    var batches = (try safe_dir.openExistingDirectory(io, state_dir, "batches", .{ .iterate = true })) orelse return .{};
    errdefer batches.close(io);

    var first: ?u64 = null;
    var last: u64 = 0;
    var count: usize = 0;
    var iterator = batches.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const generation = std.fmt.parseInt(u64, entry.name, 16) catch continue;
        if (count == 0 or generation < first.?) first = generation;
        if (count == 0 or generation > last) last = generation;
        count += 1;
    }
    if (count == 0) {
        batches.close(io);
        return .{};
    }
    return .{ .dir = batches, .first = first, .last = last };
}

pub const StateInfo = struct {
    generation: u64,
    updated: []const u8,
    config_hash: ?u64,
};

/// Read the header of one stage state for `stage status`. A missing or torn state is `null`, not an error.
pub fn stateInfo(arena: std.mem.Allocator, io: std.Io, root: []const u8, number: u16) !?StateInfo {
    var root_dir = openRoot(io, root) catch return null;
    defer root_dir.close(io);
    var meta = (try safe_dir.openExistingDirectory(io, root_dir, format.directory_name, .{ .iterate = true })) orelse return null;
    defer meta.close(io);
    var stages = (try safe_dir.openExistingDirectory(io, meta, StateDir, .{ .iterate = true })) orelse return null;
    defer stages.close(io);
    var name_buffer: [2]u8 = undefined;
    const stage_name = std.fmt.bufPrint(&name_buffer, "{d:0>2}", .{number}) catch unreachable;
    var state_dir = (try safe_dir.openExistingDirectory(io, stages, stage_name, .{ .iterate = true })) orelse return null;
    defer state_dir.close(io);
    const document = state_dir.readFileAlloc(io, format.json_file, arena, std.Io.Limit.limited(1 << 20)) catch return null;
    var parsed = json.parse(arena, document) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = &parsed.value.object;
    var config_hash: ?u64 = null;
    if (object.get("stage")) |stage_value| {
        if (stage_value == .object) {
            if (json.optionalString(&stage_value.object, "configHash")) |text| {
                config_hash = std.fmt.parseInt(u64, text, 16) catch null;
            }
        }
    }
    return .{
        .generation = json.optionalInt(object, "generation") orelse 0,
        .updated = json.optionalString(object, "updated") orelse "",
        .config_hash = config_hash,
    };
}

pub const Options = struct {
    /// `false` is `stage diff`: compare against the state, publish nothing.
    write: bool = true,
    /// The pass timestamp; the engine has no clock.
    updated: []const u8 = "1970-01-01T00:00:00Z",
    /// A live consumer. The CLI leaves it null; the daemon uses it to stream entries while the walk is running.
    stream: ?Stream = null,
};

fn openRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
}

fn loadPrevious(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    stage: build_config.Stage,
    identity: scan.FileId,
) !?Previous {
    const meta = dir.readFileAlloc(io, format.meta_file, arena, std.Io.Limit.limited(1 << 28)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const txt = dir.readFileAlloc(io, format.txt_file, arena, std.Io.Limit.limited(1 << 28)) catch return null;
    const document = dir.readFileAlloc(io, format.json_file, arena, std.Io.Limit.limited(1 << 28)) catch return null;

    const result = try validate.validate(arena, .{
        .json_bytes = document,
        .meta_bytes = meta,
        .txt_bytes = txt,
    });
    if (result.verdict != .ok) return null;

    var parsed = json.parse(arena, document) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = &parsed.value.object;
    const stage_value = object.get("stage") orelse return null;
    if (stage_value != .object) return null;
    const config_text = json.optionalString(&stage_value.object, "configHash") orelse return null;
    const config_hash = std.fmt.parseInt(u64, config_text, 16) catch return null;
    if (config_hash != stage.config_hash) return null;

    // A state from another checkout describes another tree. The stored identity may be unknown (`0, 0`), in
    // which case `configHash` is the only key, as it was before identity recording.
    if (identity.lo != 0 and identity.hi != 0) {
        if (object.get("root")) |root_value| {
            if (root_value == .object) {
                const dev = json.optionalInt(&root_value.object, "dev") orelse 0;
                const ino = json.optionalInt(&root_value.object, "ino") orelse 0;
                if ((dev != 0 or ino != 0) and (dev != identity.hi or ino != identity.lo)) return null;
            }
        }
    }

    var generation: u64 = 0;
    if (json.optionalInt(object, "generation")) |value| generation = value;
    var created: []const u8 = "1970-01-01T00:00:00Z";
    if (json.optionalString(object, "created")) |value| created = value;

    const cache = cache_mod.Cache.load(arena, result.entries, result.names, generation) catch return null;
    return .{ .cache = cache, .created = created, .config_hash = config_hash, .generation = generation };
}

/// Facts for every declared folder, with names prefixed back to workspace-relative form. The folder's ancestor
/// directories are included too, so a stage state describes its own path and a removed folder becomes a delete.
const Scanned = struct {
    facts: []scan.Fact,
    started: bool,
    generation: u64,
    added: u64,
    changed: u64,
    deleted: u64,
};

const ScanContext = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    stage: *const build_config.Stage,
    previous: ?*const cache_mod.Cache,
    stream: ?Stream,
    folder: []const u8 = "",
    by_name: std.StringArrayHashMapUnmanaged(scan.Fact) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    started: bool = false,
    generation: u64 = 0,
    parent: u64 = 0,
    added: u64 = 0,
    changed: u64 = 0,
    deleted: u64 = 0,
    failure: ?anyerror = null,

    fn ensureStarted(self: *ScanContext) void {
        if (self.started) return;
        self.started = true;
        if (self.stream) |stream| {
            if (stream.on_start) |start| start(stream.ctx, self.stage.number, self.generation, self.parent);
        }
    }

    fn emit(self: *ScanContext, kind: ChangeKind, entry: format.Entry, name: []const u8) void {
        self.ensureStarted();
        if (self.stream) |stream| {
            if (stream.on_change) |change| change(stream.ctx, .{ .kind = kind, .entry = entry, .name = name });
        }
        switch (kind) {
            .added => self.added += 1,
            .changed => self.changed += 1,
            .deleted => self.deleted += 1,
        }
    }

    fn note(self: *ScanContext, fact: *scan.Fact) void {
        if (self.by_name.get(fact.name) != null) return;

        var old_file: ?cache_mod.FileState = null;
        if (self.previous) |cache| {
            if (cache.files.get(fact.name)) |old| {
                old_file = old;
                if (old.kind == fact.kind and old.mtime_ns == fact.mtime_ns and old.size_bytes == fact.size_bytes and
                    old.file_id_lo == fact.file_id_lo and old.file_id_hi == fact.file_id_hi)
                {
                    if (old.content_hash) |hash| {
                        fact.content_hash = hash;
                        fact.hash_lf = old.hash_lf;
                    }
                }
            }
        }
        if (fact.kind == .regular_file and fact.content_hash == 0) {
            const full = joinPath(self.arena, self.root, fact.name) catch {
                self.failure = error.OutOfMemory;
                return;
            };
            const hashed = scan.hashFileAt(self.io, full, self.stage.hash_mode) catch null;
            if (hashed) |value| {
                fact.content_hash = value.hash;
                fact.hash_lf = value.hash_lf;
                // A file that moved while it was being hashed is not a settled artifact. Abort the pass rather
                // than publish a hash for one state and metadata for another; the next pass sees the settled file.
                if (std.Io.Dir.cwd().statFile(self.io, full, .{ .follow_symlinks = false })) |after| {
                    if (after.size != fact.size_bytes or mtimeNs(after.mtime) != fact.mtime_ns) {
                        self.failure = error.UnstableFile;
                        return;
                    }
                } else |_| {
                    self.failure = error.UnstableFile;
                    return;
                }
            }
        }

        const old_dir: ?cache_mod.DirState = if (self.previous) |cache| cache.dirs.get(fact.name) else null;
        var change: ?ChangeKind = null;
        if (old_file == null and old_dir == null) {
            change = .added;
        } else if (old_file) |old| {
            if (old.kind != fact.kind or old.size_bytes != fact.size_bytes or
                (old.content_hash orelse 0) != fact.content_hash)
            {
                change = .changed;
            }
        } else if (old_dir) |old| {
            if (old.mtime_ns != fact.mtime_ns or old.file_id_lo != fact.file_id_lo or old.file_id_hi != fact.file_id_hi) {
                change = .changed;
            }
        }

        self.seen.put(self.arena, fact.name, {}) catch {
            self.failure = error.OutOfMemory;
            return;
        };
        self.by_name.put(self.arena, fact.name, fact.*) catch {
            self.failure = error.OutOfMemory;
            return;
        };
        if (change) |kind| self.emit(kind, factEntry(fact.*, kind), fact.name);
    }
};

fn onFact(raw: *anyopaque, fact: *scan.Fact) void {
    const ctx: *ScanContext = @ptrCast(@alignCast(raw));
    if (ctx.folder.len > 0) {
        const name = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.folder, fact.name }) catch {
            ctx.failure = error.OutOfMemory;
            return;
        };
        fact.name = name;
    }
    ctx.note(fact);
}

fn collectFacts(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    stage: *const build_config.Stage,
    previous: ?*const cache_mod.Cache,
    stream: ?Stream,
) !Scanned {
    var ctx = ScanContext{
        .arena = arena,
        .io = io,
        .root = root,
        .stage = stage,
        .previous = previous,
        .stream = stream,
        .parent = if (previous) |state| state.generation else 0,
        .generation = if (previous) |state| state.generation + 1 else 1,
    };
    defer ctx.by_name.deinit(arena);
    defer ctx.seen.deinit(arena);

    for (stage.folders) |folder| {
        try noteFolderDirs(&ctx, folder);
        ctx.folder = folder;
        const full = try joinPath(arena, root, folder);
        _ = scan.scanDetailed(arena, io, full, .{
            .hash_mode = .none,
            .hash_files = false,
            .respect_gitignore = false,
            .on_fact = .{ .ctx = &ctx, .on_fact = onFact },
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        ctx.folder = "";
    }

    // Deletes are only knowable after every folder has been walked; they are still emitted before the commit end.
    if (previous) |cache| {
        for (cache.files.keys()) |name| {
            if (ctx.seen.get(name) != null) continue;
            const old = cache.files.get(name).?;
            ctx.emit(.deleted, fileStateEntry(name, old, .deleted), name);
        }
        for (cache.dirs.keys()) |name| {
            if (name.len == 0 or ctx.seen.get(name) != null) continue;
            const old = cache.dirs.get(name).?;
            ctx.emit(.deleted, dirStateEntry(name, old, .deleted), name);
        }
    }

    if (ctx.failure) |err| return err;
    return .{
        .facts = try arena.dupe(scan.Fact, ctx.by_name.values()),
        .started = ctx.started,
        .generation = ctx.generation,
        .added = ctx.added,
        .changed = ctx.changed,
        .deleted = ctx.deleted,
    };
}

fn noteFolderDirs(ctx: *ScanContext, folder: []const u8) !void {
    var candidate: ?[]const u8 = folder;
    while (candidate) |prefix| {
        if (ctx.by_name.get(prefix) == null) {
            if (std.Io.Dir.cwd().statFile(ctx.io, try joinPath(ctx.arena, ctx.root, prefix), .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .directory) {
                    var fact = scan.Fact{
                        .name = try ctx.arena.dupe(u8, prefix),
                        .kind = .dir,
                        .mtime_ns = mtimeNs(stat.mtime),
                        .size_bytes = 0,
                        .content_hash = 0,
                        .hash_lf = false,
                        .file_id_lo = 0,
                        .file_id_hi = 0,
                    };
                    ctx.note(&fact);
                }
            } else |_| {}
        }
        candidate = if (std.mem.lastIndexOfScalar(u8, prefix, '/')) |slash| prefix[0..slash] else null;
    }
}

fn factEntry(fact: scan.Fact, change: ChangeKind) format.Entry {
    var flags: u32 = switch (fact.kind) {
        .dir => format.flags.is_dir,
        .symlink => format.flags.symlink,
        .regular_file => format.flags.regular_file |
            (if (fact.content_hash != 0) format.flags.content_known else 0) |
            (if (fact.content_hash != 0 and fact.hash_lf) format.flags.hash_lf else 0),
    };
    flags |= switch (change) {
        .added => 0x20,
        .changed => 0x40,
        .deleted => 0x80,
    };
    return .{
        .mtime_ns = fact.mtime_ns,
        .size_bytes = fact.size_bytes,
        .content_hash = fact.content_hash,
        .name_hash = format.wyhash(fact.name),
        .name_offset = 0,
        .name_length = 0,
        .flags_word = flags,
        .file_id_lo = fact.file_id_lo,
        .file_id_hi = fact.file_id_hi,
    };
}

fn fileStateEntry(name: []const u8, state: cache_mod.FileState, change: ChangeKind) format.Entry {
    const known = state.content_hash != null;
    var flags: u32 = switch (state.kind) {
        .dir => unreachable,
        .symlink => format.flags.symlink,
        .regular_file => format.flags.regular_file |
            (if (known) format.flags.content_known else 0) |
            (if (known and state.hash_lf) format.flags.hash_lf else 0),
    };
    flags |= switch (change) {
        .added => 0x20,
        .changed => 0x40,
        .deleted => 0x80,
    };
    return .{
        .mtime_ns = state.mtime_ns,
        .size_bytes = state.size_bytes,
        .content_hash = state.content_hash orelse 0,
        .name_hash = format.wyhash(name),
        .name_offset = 0,
        .name_length = 0,
        .flags_word = flags,
        .file_id_lo = state.file_id_lo,
        .file_id_hi = state.file_id_hi,
    };
}

fn dirStateEntry(name: []const u8, state: cache_mod.DirState, change: ChangeKind) format.Entry {
    var flags: u32 = format.flags.is_dir;
    flags |= switch (change) {
        .added => 0x20,
        .changed => 0x40,
        .deleted => 0x80,
    };
    return .{
        .mtime_ns = state.mtime_ns,
        .size_bytes = 0,
        .content_hash = 0,
        .name_hash = format.wyhash(name),
        .name_offset = 0,
        .name_length = 0,
        .flags_word = flags,
        .file_id_lo = state.file_id_lo,
        .file_id_hi = state.file_id_hi,
    };
}

fn cacheFromFacts(arena: std.mem.Allocator, facts: []const scan.Fact, generation: u64) !cache_mod.Cache {
    const entries = try arena.alloc(format.Entry, facts.len);
    const names = try arena.alloc([]const u8, facts.len);
    for (facts, 0..) |fact, index| {
        names[index] = fact.name;
        entries[index] = .{
            .mtime_ns = fact.mtime_ns,
            .size_bytes = fact.size_bytes,
            .content_hash = fact.content_hash,
            .name_hash = format.wyhash(fact.name),
            .name_offset = 0,
            .name_length = 0,
            .flags_word = switch (fact.kind) {
                .dir => format.flags.is_dir,
                .symlink => format.flags.symlink,
                .regular_file => format.flags.regular_file |
                    (if (fact.content_hash != 0) format.flags.content_known else 0) |
                    (if (fact.content_hash != 0 and fact.hash_lf) format.flags.hash_lf else 0),
            },
            .file_id_lo = fact.file_id_lo,
            .file_id_hi = fact.file_id_hi,
        };
    }
    return cache_mod.Cache.load(arena, entries, names, generation);
}

fn cacheItems(arena: std.mem.Allocator, cache: *const cache_mod.Cache) ![]batch_mod.Item {
    var items: std.ArrayListUnmanaged(batch_mod.Item) = .empty;
    try items.ensureTotalCapacity(arena, cache.files.count() + cache.dirs.count());
    for (cache.files.keys()) |name| {
        items.appendAssumeCapacity(batch_mod.fileItem(name, cache.files.get(name).?));
    }
    for (cache.dirs.keys()) |name| {
        if (name.len == 0) continue;
        items.appendAssumeCapacity(batch_mod.dirItem(name, cache.dirs.get(name).?));
    }
    return items.items;
}

/// `{ dev, ino }` for the root directory itself. `scan.fileIdAt` needs the parent handle and the basename; a
/// relative locator is resolved once, exactly as the engine's boundary does.
fn rootIdentity(arena: std.mem.Allocator, io: std.Io, root: []const u8) scan.FileId {
    const absolute = std.Io.Dir.cwd().realPathFileAlloc(io, root, arena) catch return .{ .lo = 0, .hi = 0 };
    const parent_path = std.fs.path.dirname(absolute) orelse "/";
    const name = std.fs.path.basename(absolute);
    var parent = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return .{ .lo = 0, .hi = 0 };
    defer parent.close(io);
    return scan.fileIdAt(parent, io, name);
}

fn joinPath(arena: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    if (root.len == 0) return arena.dupe(u8, name);
    return std.fs.path.join(arena, &.{ root, name });
}

fn mtimeNs(timestamp: std.Io.Timestamp) u64 {
    return std.math.cast(u64, timestamp.nanoseconds) orelse 0;
}

fn factLessThan(_: void, left: scan.Fact, right: scan.Fact) bool {
    return format.compareNames(left.name, right.name) == .lt;
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn writeTestFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(name) orelse ".");
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

fn testRoot(arena: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(testing.io, &path_buffer);
    return arena.dupe(u8, path_buffer[0..count]);
}

test "a stage scan writes a state under .fs-meta/stages and reuses unchanged hashes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try writeTestFile(tmp.dir, io, "src/main.zig", "source");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);

    const first = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:00Z" });
    try testing.expect(first.published);
    try testing.expectEqual(@as(u64, 1), first.generation);
    // `build` and `build/classes` are directories in the state, plus the class itself.
    try testing.expectEqual(@as(u64, 3), first.added);
    const state_document = try tmp.dir.readFileAlloc(io, ".fs-meta/stages/00/files.json", arena, std.Io.Limit.limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, state_document, "\"root\": { \"dev\": 0, \"ino\": 0 }") == null);

    const second = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:01Z" });
    try testing.expect(!second.published);
    try testing.expectEqual(@as(u64, 1), second.generation);

    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAB");
    const third = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:02Z" });
    try testing.expect(third.published);
    try testing.expectEqual(@as(u64, 1), third.changed);
}

test "stage scan ignores a root .gitignore, skips a same-content touch, and cold-scans on a config change" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "build/\n" });
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);

    const first = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:00Z" });
    try testing.expect(first.published);
    try testing.expect(first.added >= 1); // despite the root .gitignore
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    const touched = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:01Z" });
    try testing.expect(!touched.published);

    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"],"hash":"lf"}]}
    );
    const reconfigured = try build_config.load(arena, io, root);
    const cold = try refresh(arena, io, root, reconfigured, 0, .{ .updated = "2026-11-08T00:00:02Z" });
    try testing.expect(cold.cold);
    try testing.expect(cold.published);
}

test "deleting a stage folder yields deletes, and deleting the stage state forces a cold scan" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);

    _ = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:00Z" });
    try tmp.dir.deleteTree(io, "build");
    const deleted = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:01Z" });
    try testing.expect(deleted.published);
    try testing.expect(deleted.deleted >= 3);

    try tmp.dir.deleteTree(io, ".fs-meta/stages");
    const cold = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:02Z" });
    try testing.expect(cold.cold);
    try testing.expect(cold.published);

    try writeTestFile(tmp.dir, io, "build/classes/B.class", "BBB");
    const recreated = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-08T00:00:03Z" });
    try testing.expect(recreated.published);
    try testing.expect(recreated.added >= 2); // the recreated folder/files
}

test "live stage entries follow the walk order, not the hash order" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/z.class", "Z");
    try writeTestFile(tmp.dir, io, "build/classes/a.class", "A");
    try writeTestFile(tmp.dir, io, "build/classes/m.class", "M");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);

    const Walk = struct {
        arena: std.mem.Allocator,
        names: std.ArrayListUnmanaged([]const u8) = .empty,
        fn onFact(raw: *anyopaque, fact: *scan.Fact) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (fact.kind == .regular_file) self.names.append(self.arena, fact.name) catch {};
        }
    };
    var walk = Walk{ .arena = arena };
    defer walk.names.deinit(arena);
    const folder = try joinPath(arena, root, "build/classes");
    _ = try scan.scanDetailed(arena, io, folder, .{
        .hash_mode = .none,
        .hash_files = false,
        .on_fact = .{ .ctx = &walk, .on_fact = Walk.onFact },
    });

    const StreamProbe = struct {
        names: std.ArrayListUnmanaged([]const u8) = .empty,
        arena: std.mem.Allocator,
        fn change(raw: *anyopaque, item: Change) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (item.entry.flags_word & format.flags.regular_file != 0) {
                self.names.append(self.arena, item.name) catch {};
            }
        }
    };
    var probe = StreamProbe{ .arena = arena };
    defer probe.names.deinit(arena);
    _ = try refresh(arena, io, root, declaration, 0, .{
        .updated = "2026-11-08T00:00:00Z",
        .stream = .{ .ctx = &probe, .on_change = StreamProbe.change },
    });

    try testing.expectEqual(walk.names.items.len, probe.names.items.len);
    for (walk.names.items, probe.names.items) |expected, actual| {
        const prefixed = try std.fmt.allocPrint(arena, "build/classes/{s}", .{expected});
        try testing.expectEqualStrings(prefixed, actual);
    }
}

test "a stage stream emits entries before the state is committed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);
    const state_path = try joinPath(arena, root, ".fs-meta/stages/00/files.json");

    const Probe = struct {
        state_path: []const u8,
        started: bool = false,
        finished: bool = false,
        changes: usize = 0,
        saw_before_state: bool = false,
        finished_with_state: bool = false,

        fn onStart(raw: *anyopaque, stage: u16, generation: u64, parent: u64) void {
            _ = stage;
            _ = generation;
            _ = parent;
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started = true;
        }

        fn onChange(raw: *anyopaque, change: Change) void {
            _ = change;
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.changes += 1;
            std.Io.Dir.accessAbsolute(testing.io, self.state_path, .{}) catch {
                self.saw_before_state = true;
            };
        }

        fn onFinish(raw: *anyopaque, stage: u16, generation: u64, added: u64, changed: u64, deleted: u64, ok: bool) void {
            _ = stage;
            _ = generation;
            _ = added;
            _ = changed;
            _ = deleted;
            _ = ok;
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.finished = true;
            self.finished_with_state = if (std.Io.Dir.accessAbsolute(testing.io, self.state_path, .{})) |_| true else |err| err != error.FileNotFound;
        }
    };

    var probe = Probe{ .state_path = state_path };
    _ = try refresh(arena, io, root, declaration, 0, .{
        .updated = "2026-11-08T00:00:00Z",
        .stream = .{
            .ctx = &probe,
            .on_start = Probe.onStart,
            .on_change = Probe.onChange,
            .on_finish = Probe.onFinish,
        },
    });
    try testing.expect(probe.started);
    try testing.expect(probe.changes > 0);
    try testing.expect(probe.saw_before_state);
    try testing.expect(probe.finished);
    try testing.expect(probe.finished_with_state);
}

test "an app batch ingests exactly the files it names and never scans the folder" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);
    const first = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-20T00:00:00Z" });
    try testing.expectEqual(@as(u64, 1), first.generation);

    // Two files are named; the folder contains a third that the batch does not name, and it must stay untouched
    // (the point of an app batch is that it is not a folder scan).
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAB");
    try writeTestFile(tmp.dir, io, "build/classes/Inner.class", "INNER");
    try writeTestFile(tmp.dir, io, "build/classes/Unreported.class", "UNREPORTED");
    const second = try ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "build/classes/A.class", .kind = .upsert },
        .{ .name = "build/classes/Inner.class", .kind = .upsert },
    }, .{ .updated = "2026-11-20T00:00:01Z" });
    try testing.expect(second.published);
    try testing.expectEqual(@as(u64, 2), second.generation);
    try testing.expectEqual(@as(u64, 1), second.changed);
    try testing.expectEqual(@as(u64, 1), second.added);
    const state_document = try tmp.dir.readFileAlloc(io, ".fs-meta/stages/00/files.txt", arena, std.Io.Limit.limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, state_document, "Unreported.class") == null);

    // Writing the same bytes again is not a change, so the generation does not move.
    const untouched = try ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "build/classes/A.class", .kind = .upsert },
        .{ .name = "build/classes/Inner.class", .kind = .upsert },
    }, .{ .updated = "2026-11-20T00:00:02Z" });
    try testing.expect(!untouched.published);
    try testing.expectEqual(@as(u64, 2), untouched.generation);

    // A reported delete removes that name only.
    try tmp.dir.deleteFile(io, "build/classes/Inner.class");
    const deleted = try ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "build/classes/Inner.class", .kind = .delete },
    }, .{ .updated = "2026-11-20T00:00:03Z" });
    try testing.expect(deleted.published);
    try testing.expectEqual(@as(u64, 3), deleted.generation);
    try testing.expectEqual(@as(u64, 1), deleted.deleted);
}

test "an app batch outside its stage's folders, or without a stage state, is refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]},{"stage":1,"folders":["dist"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);

    // No state yet: the caller must cold-scan first, because only a scan knows the folder's older files.
    try testing.expectError(error.NoStageState, ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "build/classes/A.class", .kind = .upsert },
    }, .{}));

    _ = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-20T00:00:00Z" });
    try testing.expectError(error.StageFileOutside, ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "dist/app.jar", .kind = .upsert },
    }, .{}));
    // A tracked name is legal, but it must exist when the batch closes (the app wrote it before END).
    try testing.expectError(error.FileNotFound, ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "src/Main.java", .kind = .upsert },
    }, .{}));
    try testing.expectError(error.InvalidName, ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "build/classes/../escape.class", .kind = .upsert },
    }, .{}));
}

test "a tracked app output is reported in the batch but never enters the stage state" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "build/classes/A.class", "AAA");
    try writeTestFile(tmp.dir, io, "docs/Guide.md", "old");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":0,"folders":["build/classes"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);
    _ = try refresh(arena, io, root, declaration, 0, .{ .updated = "2026-11-20T00:00:00Z" });

    // The docs file is a regular tracked file: the snippet injector writes it in place. The stage batch names it,
    // so the next stage is notified, but the stage state must not describe a tree the root trio owns.
    try writeTestFile(tmp.dir, io, "docs/Guide.md", "new snippet");
    const outcome = try ingest(arena, io, root, declaration, 0, &.{
        .{ .name = "docs/Guide.md", .kind = .upsert },
    }, .{ .updated = "2026-11-20T00:00:01Z" });
    try testing.expect(outcome.published);
    try testing.expectEqual(@as(u64, 1), outcome.tracked);
    try testing.expectEqual(@as(u64, 2), outcome.generation);
    const plan = outcome.plan.?;
    try testing.expectEqual(@as(usize, 1), plan.entries.len);
    try testing.expectEqualStrings("docs/Guide.md", plan.names[0]);
    const state_files = try tmp.dir.readFileAlloc(io, ".fs-meta/stages/00/files.txt", arena, std.Io.Limit.limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, state_files, "docs/Guide.md") == null);
}

test "a stage diff reports changes without publishing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, io, "dist/app.jar", "jar");
    try tmp.dir.createDirPath(io, ".fs-meta");
    try writeTestFile(tmp.dir, io, ".fs-meta/build.json",
        \\{"version":1,"stages":[{"stage":2,"folders":["dist"]}]}
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try testRoot(arena, &tmp);
    const declaration = try build_config.load(arena, io, root);

    const diff = try refresh(arena, io, root, declaration, 2, .{ .write = false, .updated = "2026-11-08T00:00:00Z" });
    try testing.expect(!diff.published);
    try testing.expectEqual(@as(u64, 2), diff.added); // `dist` and the jar
    try testing.expectEqual(@as(u64, 0), diff.generation);
}
