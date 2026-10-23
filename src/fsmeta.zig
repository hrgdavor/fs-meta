// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `fsmeta` — the engine's command line: the three things you can ask a trio to do.
//!
//! ```text
//! fsmeta verify  <root>      # does the trio describe what it claims? (§ 8) — exit 1 when it does not
//! fsmeta scan    <root>      # what does the walker see? one line per name, no trio written
//! fsmeta refresh <root>      # bring <root>/.fs-meta up to date; publishes only if something changed
//! ```
//!
//! `refresh` is the engine pass; `verify` is the reader's gate; `scan` is the diagnostic that shows what a walk
//! would put in a fresh trio. `--no-gitignore` and `--hash none|lf|text` mirror the engine's options, and
//! `--updated` supplies the pass's timestamp, because the engine core deliberately has no clock.

const std = @import("std");
const format = @import("format.zig");
const validate = @import("validate.zig");
const scan = @import("scan.zig");
const engine = @import("engine.zig");
const query = @import("query.zig");
const cache_mod = @import("cache.zig");
const batch = @import("batch.zig");
const reconcile = @import("reconcile.zig");

const usage =
    \\fsmeta — the fs-meta engine
    \\
    \\usage:
    \\  fsmeta verify  <root>        validate <root>/.fs-meta and report the verdict
    \\  fsmeta scan    <root>        list what the walker sees (no trio written)
    \\  fsmeta refresh <root>        bring <root>/.fs-meta up to date
    \\  fsmeta glob    <root> <pattern> [--since <timestamp>]
    \\                                   glob-search the trio; one line per match
    \\  fsmeta changed <root> <since>  files changed since <since>; one line per match
    \\  fsmeta merge   <root> <start> [end] [--json]
    \\                                   merge batches start+1..end; added+changed only
    \\
    \\options:
    \\  --no-gitignore               list everything except the reserved directories
    \\  --hash none|lf|text          content hash mode recorded in the trio (default: text)
    \\  --updated <ISO-8601>         the pass timestamp; the engine has no clock of its own
    \\  --per-file                   naive listing (stat per entry) instead of the batched one
    \\  --stats                      print where the pass spent its time
    \\  --since <timestamp>          mtime filter for glob (ISO-8601 or relative: 1h, 30m, 2d)
    \\  --json                       emit results as a JSON array
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // the program itself

    const command = args.next() orelse {
        try write(io, usage);
        return;
    };

    var root: ?[]const u8 = null;
    var second: ?[]const u8 = null;
    var options: engine.Options = .{ .updated = "1970-01-01T00:00:00Z" };
    var respect_gitignore = true;
    var show_stats = false;
    var hash_mode = scan.HashMode.text;
    var since: ?[]const u8 = null;
    var json_output = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-gitignore")) {
            respect_gitignore = false;
        } else if (std.mem.eql(u8, arg, "--hash")) {
            const value = args.next() orelse return fail(io, gpa, "--hash needs a value");
            hash_mode = if (std.mem.eql(u8, value, "none"))
                .none
            else if (std.mem.eql(u8, value, "lf"))
                .lf
            else if (std.mem.eql(u8, value, "text"))
                .text
            else
                return fail(io, gpa, "--hash must be none, lf or text");
        } else if (std.mem.eql(u8, arg, "--stats")) {
            show_stats = true;
        } else if (std.mem.eql(u8, arg, "--per-file")) {
            options.per_file = true;
        } else if (std.mem.eql(u8, arg, "--updated")) {
            options.updated = args.next() orelse return fail(io, gpa, "--updated needs a value");
        } else if (std.mem.eql(u8, arg, "--since")) {
            since = args.next() orelse return fail(io, gpa, "--since needs a value");
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            return fail(io, gpa, "unknown option");
        } else if (root == null) {
            root = arg;
        } else {
            second = arg;
        }
    }

    const target = root orelse return fail(io, gpa, "a root directory is required");

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    if (std.mem.eql(u8, command, "verify")) return verify(io, arena, target);
    if (std.mem.eql(u8, command, "scan")) {
        return listFacts(io, arena, target, .{
            .hash_mode = hash_mode,
            .respect_gitignore = respect_gitignore,
        });
    }
    if (std.mem.eql(u8, command, "refresh") or std.mem.eql(u8, command, "publish")) {
        options.respect_gitignore = respect_gitignore;
        options.hash_mode = hash_mode;
        options.root_path = target;
        const outcome = try engine.refresh(arena, io, target, options);
        const line = try std.fmt.allocPrint(arena, "generation {d}, {d} names, published {s} (added {d}, removed {d}, modified {d}, renamed {d}, hashed {d})\n", .{
            outcome.generation,
            outcome.count,
            if (outcome.published) "yes" else "no",
            outcome.report.files_added,
            outcome.report.files_removed,
            outcome.report.files_modified,
            outcome.report.renames,
            outcome.hashed,
        });
        try write(io, line);
        if (show_stats) {
            const stats = try std.fmt.allocPrint(arena, "stats: load {d:.1} ms, discover {d:.1} ms, hash {d:.1} ms, publish {d:.1} ms\n", .{
                @as(f64, @floatFromInt(outcome.stats.load_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(outcome.stats.discover_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(outcome.stats.hash_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(outcome.stats.publish_ns)) / 1_000_000.0,
            });
            try write(io, stats);
        }
        return;
    }
    if (std.mem.eql(u8, command, "glob")) {
        const pattern = second orelse return fail(io, gpa, "glob needs a pattern");
        return runGlob(io, arena, gpa, target, pattern, since, json_output);
    }
    if (std.mem.eql(u8, command, "changed")) {
        const since_arg = second orelse return fail(io, gpa, "changed needs a since timestamp");
        return runChanged(io, arena, gpa, target, since_arg, json_output);
    }
    if (std.mem.eql(u8, command, "merge")) {
        const start_arg = second orelse return fail(io, gpa, "merge needs a start batch number");
        const end_arg = args.next() orelse null;
        return runMerge(io, arena, gpa, target, start_arg, end_arg, json_output);
    }
    return fail(io, gpa, "unknown command");
}

/// Load the trio, run a glob query, and print one line per match (or a JSON array with --json).
fn runGlob(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, root: []const u8, pattern: []const u8, since: ?[]const u8, json: bool) !void {
    var cache = try loadCache(arena, io, root);
    defer cache.deinit();

    var glob = try query.Glob.compile(gpa, pattern);
    defer glob.deinit(gpa);

    const now_ns: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
    const since_ns = if (since) |s| query.parseSince(s, now_ns) else null;

    const results = try query.run(arena, .{
        .cache = &cache,
        .glob = &glob,
        .since_ns = since_ns,
    });
    defer arena.free(results);

    if (json) {
        const out = try query.toJson(arena, results);
        try write(io, out);
    } else {
        for (results) |match| {
            const line = try std.fmt.allocPrint(arena, "{s} {d} {d} {d}\n", .{
                match.name,
                match.entry.mtime_ns,
                match.entry.size_bytes,
                match.entry.content_hash,
            });
            try write(io, line);
        }
        const total = try std.fmt.allocPrint(arena, "{d} names\n", .{results.len});
        try write(io, total);
    }
}

/// Load the trio, run a since-only query, and print one line per match (or a JSON array with --json).
fn runChanged(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, root: []const u8, since_arg: []const u8, json: bool) !void {
    var cache = try loadCache(arena, io, root);
    defer cache.deinit();

    const now_ns: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
    const since_ns = query.parseSince(since_arg, now_ns) orelse return fail(io, gpa, "invalid since timestamp");

    const results = try query.run(arena, .{
        .cache = &cache,
        .glob = null,
        .since_ns = since_ns,
    });
    defer arena.free(results);

    if (json) {
        const out = try query.toJson(arena, results);
        try write(io, out);
    } else {
        for (results) |match| {
            const line = try std.fmt.allocPrint(arena, "{s} {d} {d} {d}\n", .{
                match.name,
                match.entry.mtime_ns,
                match.entry.size_bytes,
                match.entry.content_hash,
            });
            try write(io, line);
        }
        const total = try std.fmt.allocPrint(arena, "{d} names\n", .{results.len});
        try write(io, total);
    }
}

/// Merge batches from start+1 to end (inclusive), outputting added and changed names only.
fn runMerge(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, root: []const u8, start_arg: []const u8, end_arg: ?[]const u8, json: bool) !void {
    const start_num = std.fmt.parseInt(usize, start_arg, 10) catch return fail(io, gpa, "start must be a number");
    const end_num: usize = if (end_arg) |e|
        std.fmt.parseInt(usize, e, 10) catch return fail(io, gpa, "end must be a number")
    else
        blk: {
            // Find the latest batch number.
            const batches_dir = try openBatchesDir(io, arena, root);
            defer batches_dir.close(io);
            var max: usize = 0;
            var iter = batches_dir.iterate();
            while (try iter.next(io)) |entry| {
                const name = entry.name;
                if (entry.kind == .directory) {
                    const n = std.fmt.parseInt(usize, name, 16) catch continue;
                    if (n > max) max = n;
                }
            }
            break :blk max;
        };

    if (end_num <= start_num) {
        try write(io, "0 names\n");
        return;
    }

    // Collect events from all batches in range.
    var events: std.ArrayListUnmanaged(reconcile.Event) = .empty;
    errdefer events.deinit(arena);

    const batches_dir = try openBatchesDir(io, arena, root);
    defer batches_dir.close(io);

    for (start_num + 1 .. end_num + 1) |n| {
        const dir_name = try std.fmt.allocPrint(arena, "{x}", .{n});
        var batch_dir = batches_dir.openDir(io, dir_name, .{ .iterate = true }) catch continue;
        defer batch_dir.close(io);

        const meta = try readOptional(io, batch_dir, format.meta_file, arena) orelse continue;
        const txt = try readOptional(io, batch_dir, format.txt_file, arena) orelse continue;
        const plan = try batch.decode(arena, meta, txt);
        defer {
            arena.free(plan.entries);
            arena.free(plan.names);
        }
        const batch_events = try batch.toEvents(arena, plan);
        defer arena.free(batch_events);
        for (batch_events) |ev| {
            try events.append(arena, ev);
        }
    }

    const all_events = try events.toOwnedSlice(arena);

    // Merge: the first batch becomes the change set, subsequent batches merge into it.
    // This is the collapse matrix without a baseline — (first, last) → net kind.
    const changes = try reconcile.collapse(arena, all_events, null);
    defer arena.free(changes);
    arena.free(all_events);

    // Filter: added + changed only (no deleted).
    var count: usize = 0;
    for (changes) |c| {
        if (c.kind == .deleted) continue;
        count += 1;
    }

    if (json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const writer = &out.writer;

        if (count == 0) {
            try writer.writeAll("[]\n");
        } else {
            try writer.writeAll("[\n");
            var first = true;
            for (changes) |c| {
                if (c.kind == .deleted) continue;
                if (!first) try writer.writeAll(",\n");
                first = false;
                try writer.writeAll("  {\n");
                try writer.writeAll("    \"name\": ");
                try jsonWriteString(writer, c.name);
                try writer.writeAll(",\n");
                const kind_str = if (c.kind == .added) "added" else "changed";
                try writer.print("    \"kind\": \"{s}\"\n", .{kind_str});
                try writer.writeAll("  }");
            }
            try writer.writeAll("\n]\n");
        }
        const result = try out.toOwnedSlice();
        try write(io, result);
    } else {
        for (changes) |c| {
            if (c.kind == .deleted) continue;
            const line = try std.fmt.allocPrint(arena, "{s}\n", .{c.name});
            try write(io, line);
        }
        const total = try std.fmt.allocPrint(arena, "{d} names\n", .{count});
        try write(io, total);
    }
}

/// Open the `.fs-meta/batches/` directory.
fn openBatchesDir(io: std.Io, arena: std.mem.Allocator, root: []const u8) !std.Io.Dir {
    _ = arena;
    const root_dir: std.Io.Dir = if (std.fs.path.isAbsolute(root))
        try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    const meta_dir: std.Io.Dir = root_dir.openDir(io, format.directory_name, .{ .iterate = true }) catch return error.BatchesMissing;
    defer meta_dir.close(io);
    return meta_dir.openDir(io, "batches", .{ .iterate = true }) catch return error.BatchesMissing;
}

/// Escape a string for JSON output.
fn jsonWriteString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Load the trio from `<root>/.fs-meta` into a Cache.
fn loadCache(arena: std.mem.Allocator, io: std.Io, root: []const u8) !cache_mod.Cache {
    var root_dir = if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return error.TrioMissing
    else
        std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return error.TrioMissing;
    defer root_dir.close(io);

    var meta_dir = root_dir.openDir(io, format.directory_name, .{ .iterate = true }) catch return error.TrioMissing;
    defer meta_dir.close(io);

    const meta = try readOptional(io, meta_dir, format.meta_file, arena) orelse return error.TrioMissing;
    const txt = try readOptional(io, meta_dir, format.txt_file, arena) orelse return error.TrioMissing;
    const json_bytes = try readOptional(io, meta_dir, format.json_file, arena) orelse return error.TrioMissing;

    const result = try validate.validate(arena, .{
        .json_bytes = json_bytes,
        .meta_bytes = meta,
        .txt_bytes = txt,
    });
    if (!result.verdict.usable()) {
        return error.TrioInvalid;
    }
    return cache_mod.Cache.load(arena, result.entries, result.names, 0);
}

fn readOptional(io: std.Io, dir: std.Io.Dir, name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    return dir.readFileAlloc(io, name, allocator, std.Io.Limit.limited(1 << 28)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn verify(io: std.Io, arena: std.mem.Allocator, root: []const u8) !void {
    const dir_path = if (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\'))
        try std.fmt.allocPrint(arena, "{s}{s}", .{ root, format.directory_name })
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, format.directory_name });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return write(io, "no .fs-meta directory\n");
    };
    defer dir.close(io);

    const names = [_][]const u8{ format.meta_file, format.txt_file, format.json_file };
    var bytes: [3]?[]u8 = .{ null, null, null };
    for (names, 0..) |name, index| {
        bytes[index] = dir.readFileAlloc(io, name, arena, std.Io.Limit.limited(1 << 28)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
    if (bytes[0] == null or bytes[1] == null or bytes[2] == null) {
        return write(io, "incomplete trio\n");
    }

    const result = try validate.validate(arena, .{
        .json_bytes = bytes[2].?,
        .meta_bytes = bytes[0].?,
        .txt_bytes = bytes[1].?,
    });
    if (result.verdict == .ok) {
        const line = try std.fmt.allocPrint(arena, "ok ({d} names)\n", .{result.count});
        try write(io, line);
        return;
    }
    const line = try std.fmt.allocPrint(arena, "{s}: {s}\n", .{ result.verdict.wire(), result.detail });
    try write(io, line);
    std.process.exit(1);
}

fn listFacts(io: std.Io, arena: std.mem.Allocator, root: []const u8, options: scan.Options) !void {
    const facts = try scan.scan(arena, io, root, options);
    for (facts) |fact| {
        const kind = switch (fact.kind) {
            .dir => "dir",
            .symlink => "symlink",
            .regular_file => "file",
        };
        const line = try std.fmt.allocPrint(arena, "{s} {d} {d} {s}\n", .{ kind, fact.size_bytes, fact.mtime_ns, fact.name });
        try write(io, line);
    }
    const total = try std.fmt.allocPrint(arena, "{d} names\n", .{facts.len});
    try write(io, total);
}

fn write(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn fail(io: std.Io, allocator: std.mem.Allocator, message: []const u8) !void {
    const text = try std.fmt.allocPrint(allocator, "fsmeta: {s}\n{s}", .{ message, usage });
    try std.Io.File.stdout().writeStreamingAll(io, text);
    std.process.exit(2);
}