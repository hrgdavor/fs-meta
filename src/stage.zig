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
    var hash_hex: [16]u8 = undefined;
    const config_hash = format.hex(stage.config_hash, &hash_hex);
    var created = options.updated;
    if (previous) |state| created = state.created;

    const dir = state_dir orelse return outcome;
    const written = try publish_mod.publish(arena, io, dir, &cache, .{
        .generation = generation,
        .normalize = @tagName(stage.hash_mode),
        .root_dev = identity.hi,
        .root_ino = identity.lo,
        .created = created,
        .updated = options.updated,
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
    _ = written;

    if (owned_plan.entries.len > 0) {
        try batch_mod.write(arena, io, dir, owned_plan, .{
            .generation = generation,
            .parent = generation - 1,
            .normalize = @tagName(stage.hash_mode),
            .root_dev = identity.hi,
            .root_ino = identity.lo,
            .created = created,
            .updated = options.updated,
            .writer = "fs-meta/stage/1",
        });
    }

    outcome.generation = generation;
    outcome.published = true;
    if (scanned.started) {
        if (options.stream) |stream| {
            if (stream.on_finish) |finish| finish(stream.ctx, stage.number, generation, outcome.added, outcome.changed, outcome.deleted, true);
        }
    }
    return outcome;
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
