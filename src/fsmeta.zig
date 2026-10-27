// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `fsmeta` — the engine's command line: what you can ask a trio to do.
//!
//! ```text
//! fsmeta verify  <root>      # does the trio describe what it claims? (§ 8) — exit 1 when it does not
//! fsmeta scan    <root>      # what does the walker see? one line per name, no trio written
//! fsmeta ignored <root>      # which source pruned which directory (read-only; never writes)
//! fsmeta refresh <root>      # bring <root>/.fs-meta up to date; publishes only if something changed
//! fsmeta serve   <root>      # serve <root>/.fs-meta/socket (FORMAT.socket.md binary protocol)
//! fsmeta daemon  start|stop|status        # the background daemon (FORMAT.daemon.md)
//! fsmeta root    add|remove|set|status|sleep|wake
//! fsmeta roots   list
//! ```
//!
//! `refresh` is the engine pass; `verify` is the reader's gate; `scan` is the diagnostic that shows what a walk
//! would put in a fresh trio; `serve` is the live path, and it loads the trio first because a server with no
//! usable state can only answer with an error. `--no-gitignore` and `--hash none|lf|text` mirror the engine's
//! options, and `--updated` supplies the pass's timestamp, because the engine core deliberately has no clock.
//!
//! The daemon subcommands are a different plane: they talk to a long-lived process over its control socket
//! (`daemon/cli.zig`), and they never write a trio themselves — the engine remains the only writer.

const std = @import("std");
const format = @import("format.zig");
const validate = @import("validate.zig");
const scan = @import("scan.zig");
const engine = @import("engine.zig");
const query = @import("query.zig");
const cache_mod = @import("cache.zig");
const batch = @import("batch.zig");
const reconcile = @import("reconcile.zig");
const server = @import("server.zig");
const boundary_mod = @import("boundary.zig");
const gitdir = @import("gitdir.zig");
const ignores = @import("ignores.zig");
const daemon_cli = @import("daemon/cli.zig");
const socutil = @import("socutil");

const usage =
    \\fsmeta — the fs-meta engine
    \\
    \\usage:
    \\  fsmeta verify  <root>        validate <root>/.fs-meta and report the verdict
    \\  fsmeta scan    <root>        list what the walker sees (no trio written)
    \\  fsmeta ignored <root> [--json]
    \\                               list every pruned directory with the source that excluded it; text mode
    \\                               prints one "<source> <path>" line per directory, sources are gitignore,
    \\                               info/exclude, fs-meta/ignore, boundary and reserved; writes nothing
    \\  fsmeta exclude <root>        append ".fs-meta/" under "# fsmeta: our own directory" to <common>/info/exclude
    \\                               (marked, idempotent, LF; a later "!" line in that file overrides it)
    \\  fsmeta refresh <root>        bring <root>/.fs-meta up to date
    \\  fsmeta match   <root> <pattern> [--since <timestamp>]
    \\                                   wildmatch the trio (git's syntax, never glob's); one line per match
    \\                                   `glob` is a deprecated alias of `match`
    \\  fsmeta changed <root> <since>  files changed since <since>; one line per match
    \\  fsmeta reconcile <root> <from> [to] [--json] [--baseline <root>]
    \\                                   the change record after <from>; batch-gap and batch-too-old are errors
    \\  fsmeta merge   <root> <start> [end] [--json]
    \\                                   deprecated: an alias of reconcile, kept for scripts
    \\  fsmeta serve   <root> [--live] [--http]
    \\                               serve <root>/.fs-meta/socket over the binary protocol of FORMAT.socket.md;
    \\                               --http also exposes an optional HTTP endpoint via the socutil library (port 8765)
    \\  fsmeta daemon  start [--base <dir>] [--foreground]
    \\  fsmeta daemon  stop | status [--json]
    \\                               the background daemon: one socket per root, sleep and wake (FORMAT.daemon.md)
    \\  fsmeta roots   list [--json] [--state watching,asleep]
    \\  fsmeta root    add|remove|set|status|sleep|wake …
    \\                               manage the daemon's roots
    \\
    \\options:
    \\  --no-gitignore               list everything except the reserved directories
    \\  --hash none|lf|text          content hash mode recorded in the trio (default: text)
    \\  --updated <ISO-8601>         the pass timestamp; the engine has no clock of its own
    \\  --per-file                   naive listing (stat per entry) instead of the batched one
    \\  --live                       serve: keep subscribers connected and publish a pass every 250 ms
    \\  --http                       serve: also expose an HTTP endpoint via the socutil library (port 8765)
    \\  --stats                      print where the pass spent its time
    \\  --since <timestamp>          mtime filter for glob (ISO-8601 or relative: 1h, 30m, 2d)
    \\  --keep-batches <n>           how many generations of batch history to retain (default 32)
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

    // The daemon's subcommands are their own plane: they talk to a control socket and never touch a trio, so
    // they are dispatched before any of the engine's option parsing applies to them.
    if (std.mem.eql(u8, command, "daemon") or std.mem.eql(u8, command, "root") or std.mem.eql(u8, command, "roots")) {
        var rest: std.ArrayListUnmanaged([]const u8) = .empty;
        defer rest.deinit(gpa);
        while (args.next()) |arg| try rest.append(gpa, arg);
        return daemon_cli.run(io, gpa, init.environ_map, command, rest.items);
    }

    var root: ?[]const u8 = null;
    var second: ?[]const u8 = null;
    var third: ?[]const u8 = null;
    var options: engine.Options = .{ .updated = "1970-01-01T00:00:00Z" };
    var respect_gitignore = true;
    var show_stats = false;
    var hash_mode = scan.HashMode.text;
    var since: ?[]const u8 = null;
    var json_output = false;
    var baseline_root: ?[]const u8 = null;
    var live = false;
    var http_port: ?u16 = null;
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
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            baseline_root = args.next() orelse return fail(io, gpa, "--baseline needs a root directory");
        } else if (std.mem.eql(u8, arg, "--keep-batches")) {
            const value = args.next() orelse return fail(io, gpa, "--keep-batches needs a count");
            options.keep_batches = std.fmt.parseInt(usize, value, 10) catch return fail(io, gpa, "--keep-batches needs a count");
        } else if (std.mem.eql(u8, arg, "--live")) {
            live = true;
        } else if (std.mem.eql(u8, arg, "--http")) {
            // The HTTP endpoint belongs to `serve` alone. Parsed globally, `refresh --http` would be accepted and
            // do nothing, so refuse it for every other command rather than ignore it.
            if (!std.mem.eql(u8, command, "serve")) return fail(io, gpa, "--http is only valid for the serve command");
            http_port = 8765;
        } else if (arg.len > 0 and arg[0] == '-') {
            return fail(io, gpa, "unknown option");
        } else if (root == null) {
            root = arg;
        } else if (second == null) {
            second = arg;
        } else {
            third = arg;
        }
    }

    const target = root orelse return fail(io, gpa, "a root directory is required");

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    if (std.mem.eql(u8, command, "exclude")) return runExclude(io, arena, target);
    if (std.mem.eql(u8, command, "verify")) return verify(io, arena, target);
    if (std.mem.eql(u8, command, "scan")) {
        return listFacts(io, arena, target, .{
            .hash_mode = hash_mode,
            .respect_gitignore = respect_gitignore,
        }, json_output);
    }
    if (std.mem.eql(u8, command, "ignored")) {
        return runIgnored(io, arena, target, respect_gitignore, json_output);
    }
    if (std.mem.eql(u8, command, "refresh") or std.mem.eql(u8, command, "publish")) {
        options.respect_gitignore = respect_gitignore;
        options.hash_mode = hash_mode;
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
        if (outcome.dropped_under_boundaries > 0) {
            // The migration the boundary rule implies: a trio written before the rule described a nested clone's
            // files, and this pass removes them. Say it once, with the count, rather than letting a consumer
            // discover a large deletion batch and guess.
            const notice = try std.fmt.allocPrint(arena, "{d} names under nested repositories are no longer described\n", .{outcome.dropped_under_boundaries});
            try write(io, notice);
        }
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
    // `glob` is abandoned as a name and as a dialect; `match` is the command, and the old name stays for scripts.
    if (std.mem.eql(u8, command, "match") or std.mem.eql(u8, command, "glob")) {
        const pattern = second orelse return fail(io, gpa, "match needs a pattern");
        return runGlob(io, arena, gpa, target, pattern, since, json_output);
    }
    if (std.mem.eql(u8, command, "changed")) {
        const since_arg = second orelse return fail(io, gpa, "changed needs a since timestamp");
        return runChanged(io, arena, gpa, target, since_arg, json_output);
    }
    if (std.mem.eql(u8, command, "reconcile") or std.mem.eql(u8, command, "merge")) {
        // `merge` is a deprecated alias: its name stays because it is in the usage text and may be scripted, but the
        // batch history has exactly one reader, so both names run the range-checked implementation below.
        const from_arg = second orelse {
            const message = try std.fmt.allocPrint(arena, "{s} needs a from generation", .{command});
            return fail(io, gpa, message);
        };
        return runReconcile(io, arena, gpa, target, from_arg, third, baseline_root, json_output);
    }
    if (std.mem.eql(u8, command, "serve")) {
        // The live publisher runs the same pass `refresh` does, so it must see the same options the
        // user gave the command (`--hash`, `--no-gitignore`, `--per-file`).
        options.respect_gitignore = respect_gitignore;
        options.hash_mode = hash_mode;
        return runServe(io, arena, gpa, target, options, live, http_port);
    }
    return fail(io, gpa, "unknown command");
}

/// Load the trio, then serve it over `<root>/.fs-meta/socket` until the process is killed.
///
/// The load is the readiness check: a server whose state is missing or fails validation can only answer
/// with errors, and saying so on stdout is more useful than binding a socket that refuses every request.
///
/// With `live`, the server also publishes: it runs one `engine.refresh` pass every
/// `server.poll_interval_ms` and streams each new batch to the clients that are already connected. The
/// pass is the engine's, not the server's — `serve` calls it and never writes a batch itself.
///
/// With `http_port`, the server also exposes an optional HTTP endpoint via the socutil library: a browser
/// UI that can connect to the fs-meta unix socket and relay bytes. The HTTP server runs in its own thread
/// with its own I/O context, so it does not interfere with the unix socket server's I/O.
fn runServe(
    io: std.Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    root: []const u8,
    options: engine.Options,
    live: bool,
    http_port: ?u16,
) !void {
    var cache = loadCache(arena, io, root) catch |err| {
        const message = switch (err) {
            error.TrioMissing => try std.fmt.allocPrint(arena, "no usable trio under {s}: .fs-meta/files.meta, files.txt and files.json are all required; run `fsmeta refresh {s}` first", .{ root, root }),
            error.TrioInvalid => try std.fmt.allocPrint(arena, "the trio under {s}/.fs-meta is not usable; run `fsmeta verify {s}` for the verdict", .{ root, root }),
            else => try std.fmt.allocPrint(arena, "cannot load the trio from {s}: {s}", .{ root, @errorName(err) }),
        };
        return fail(io, gpa, message);
    };
    defer cache.deinit();
    const live_options: ?server.LiveOptions = if (live) .{ .engine = options } else null;

    // The optional HTTP endpoint: a socutil server that exposes the fs-meta unix socket through a browser
    // UI. It runs in its own thread with its own I/O context, so it does not share the unix socket server's
    // I/O. The socket directory is `<root>/.fs-meta`, which is where the fs-meta socket lives.
    if (http_port) |port| {
        const socket_dir = try std.fmt.allocPrint(arena, "{s}/.fs-meta", .{root});
        // The list is kept by the HTTP thread for the life of the process, so it belongs to the arena that
        // outlives this function rather than to an untracked gpa allocation.
        var dirs = try std.ArrayList(socutil.sockets.Dir).initCapacity(arena, 1);
        try dirs.append(arena, .{ .path = socket_dir, .name = "fs-meta" });
        const config = socutil.Config{
            .port = port,
            .dirs = dirs,
        };
        _ = std.Thread.spawn(.{}, httpThread, .{ gpa, config }) catch {
            std.debug.print("fsmeta: cannot start the HTTP thread\n", .{});
        };
    }

    return server.run(io, arena, root, &cache, live_options);
}

/// The HTTP server thread: creates its own I/O context and runs the socutil HTTP server.
fn httpThread(gpa: std.mem.Allocator, config: socutil.Config) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    socutil.run(io, gpa, config) catch |err| {
        std.debug.print("fsmeta: HTTP server error: {s}\n", .{@errorName(err)});
    };
}

/// Load the trio, run a match/glob query, and print one line per match (or a JSON array with --json).
fn runGlob(io: std.Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, root: []const u8, pattern: []const u8, since: ?[]const u8, json: bool) !void {
    var cache = try loadCache(arena, io, root);
    defer cache.deinit();

    var glob = try query.Glob.compile(gpa, pattern);
    defer glob.deinit(gpa);

    const now_ns: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
    // A `--since` that does not parse is an error, not "no filter": silently matching everything would answer a
    // narrower question than the one asked, and the caller would believe it. `runChanged` already refuses.
    const since_ns = if (since) |s| query.parseSince(s, now_ns) orelse return fail(io, gpa, "invalid since timestamp") else null;

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

/// Open the root argument as a directory handle.
///
/// The argument is a **locator**: it may be absolute or relative, and it is resolved here, once, into a handle. It
/// is never interpolated into a stored byte — a trio describes a workspace, and names in it are workspace-relative
/// (FORMAT.md § 3).
fn openRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
}

/// Open the `.fs-meta/batches/` directory.
fn openBatchesDir(io: std.Io, root: []const u8) !std.Io.Dir {
    var root_dir = try openRoot(io, root);
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
    var root_dir = openRoot(io, root) catch return error.TrioMissing;
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
    var root_dir = openRoot(io, root) catch return write(io, "no .fs-meta directory\n");
    defer root_dir.close(io);
    var dir = root_dir.openDir(io, format.directory_name, .{ .iterate = true }) catch {
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

fn listFacts(io: std.Io, arena: std.mem.Allocator, root: []const u8, options: scan.Options, json: bool) !void {
    const result = try scan.scanDetailed(arena, io, root, options);
    if (json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        const writer = &out.writer;
        try writer.writeAll("{\"names\":[");
        for (result.facts, 0..) |fact, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try writeJsonString(writer, fact.name);
            try writer.writeAll(",\"kind\":");
            try writeJsonString(writer, switch (fact.kind) {
                .dir => "dir",
                .symlink => "symlink",
                .regular_file => "file",
            });
            try writer.print(",\"size\":{d},\"mtime\":{d}}}", .{ fact.size_bytes, fact.mtime_ns });
        }
        try writer.print("],\"count\":{d},\"boundaries\":[", .{result.facts.len});
        for (result.boundaries, 0..) |boundary, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, boundary.path);
            try writer.writeAll(",\"kind\":");
            try writeJsonString(writer, boundary.kind.name());
            try writer.writeByte('}');
        }
        try writer.writeAll("]}\n");
        try write(io, out.written());
        return;
    }
    for (result.facts) |fact| {
        const kind = switch (fact.kind) {
            .dir => "dir",
            .symlink => "symlink",
            .regular_file => "file",
        };
        const line = try std.fmt.allocPrint(arena, "{s} {d} {d} {s}\n", .{ kind, fact.size_bytes, fact.mtime_ns, fact.name });
        try write(io, line);
    }
    const total = try std.fmt.allocPrint(arena, "{d} names\n", .{result.facts.len});
    try write(io, total);
}

/// `fsmeta ignored`: which source pruned which directory (`plans/worktrees.md` § 5g).
///
/// It is a diagnostic over a fresh walk, not over the trio: a trio records the sources that were in effect, not
/// the answer for one path, and "why is this subtree absent" is a question about the current tree. Nothing here
/// writes, so it is safe on a root the daemon is serving.
fn runIgnored(io: std.Io, arena: std.mem.Allocator, root: []const u8, respect_gitignore: bool, json: bool) !void {
    const result = try scan.scanDetailed(arena, io, root, .{
        .hash_mode = .none,
        .respect_gitignore = respect_gitignore,
    });
    // The walk's order is the file system's. A diagnostic is easier to diff when it is ordered by path.
    const items = try arena.dupe(scan.Pruned, result.pruned);
    std.mem.sort(scan.Pruned, items, {}, prunedLessThan);

    if (json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        const writer = &out.writer;
        try writer.writeByte('[');
        for (items, 0..) |item, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, item.path);
            try writer.writeAll(",\"source\":");
            try writeJsonString(writer, item.source);
            try writer.writeByte('}');
        }
        try writer.writeAll("]\n");
        return write(io, out.written());
    }

    for (items) |item| {
        const line = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ item.source, item.path });
        try write(io, line);
    }
}

fn prunedLessThan(_: void, left: scan.Pruned, right: scan.Pruned) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

/// A failure of the subject (exit 1, no usage dump): `exclude` has nothing to write because the path is not a
/// repository, so printing the whole usage text would be noise rather than an answer.
fn excludeFail(io: std.Io, arena: std.mem.Allocator, comptime format_text: []const u8, args: anytype) noreturn {
    const message = std.fmt.allocPrint(arena, format_text, args) catch "exclude: cannot format the failure";
    const text = std.fmt.allocPrint(arena, "fsmeta: {s}\n", .{message}) catch message;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
    std.process.exit(1);
}

/// `fsmeta exclude <root>` (`plans/worktrees.md` § 5f, M7): append the marked `.fs-meta/` block to git's own,
/// repo-local `<common>/info/exclude`, so a served worktree can be removed with `git worktree remove` without
/// `--force` (the untracked `.fs-meta` is what makes git refuse otherwise).
///
/// It is a local file operation, not a control request: it needs no daemon and writes nothing inside the working
/// tree. It refuses — naming the path — when the root is not a repository, because there is no `<common>` to write.
/// A **later** `!` line in the same file overrides the entry (git's last-match-wins rule); this command never rewrites
/// a line a person put there.
fn runExclude(io: std.Io, arena: std.mem.Allocator, root: []const u8) !void {
    // Resolve the locator once, by opening it: `std.fs.path.resolve` is a virtual path operation in Zig 0.17 and
    // does not consult the process directory, so a relative root must be opened from the cwd to become absolute.
    const opened = if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{})
    else
        std.Io.Dir.cwd().openDir(io, root, .{});
    var root_dir = opened catch |err| {
        excludeFail(io, arena, "exclude: cannot open {s}: {s}", .{ root, @errorName(err) });
    };
    defer root_dir.close(io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = root_dir.realPath(io, &path_buffer) catch |err| {
        excludeFail(io, arena, "exclude: cannot resolve {s}: {s}", .{ root, @errorName(err) });
    };
    const absolute = try arena.dupe(u8, path_buffer[0..count]);

    const parent = std.fs.path.dirname(absolute) orelse {
        excludeFail(io, arena, "exclude: {s} is not a git working copy (it names a filesystem root)", .{absolute});
    };
    const name = std.fs.path.basename(absolute);
    var parent_dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| {
        excludeFail(io, arena, "exclude: cannot open {s}: {s}", .{ parent, @errorName(err) });
    };
    defer parent_dir.close(io);
    // The same confirmation the boundary rule uses: a `.git` file must name an existing directory, a `.git` directory
    // must carry `HEAD` and `objects/`. A stray `.git` directory is not a repository, so it has no `info/exclude`.
    if (boundary_mod.confirm(arena, io, parent_dir, name) == .none) {
        excludeFail(io, arena, "exclude: {s} is not a git working copy (no confirmed .git entry); nothing was written", .{absolute});
    }
    const location = (gitdir.resolve(arena, io, absolute) catch null) orelse {
        excludeFail(io, arena, "exclude: {s} has a .git entry that cannot be read; nothing was written", .{absolute});
    };

    const path = try std.fs.path.join(arena, &.{ location.common_dir, "info", "exclude" });
    const wrote = ignores.appendExclude(arena, io, location.common_dir) catch |err| {
        excludeFail(io, arena, "exclude: cannot write {s}: {s}", .{ path, @errorName(err) });
    };
    if (wrote) {
        const line = try std.fmt.allocPrint(arena, "exclude: appended the marked .fs-meta/ block to {s} (a later ! line in that file overrides it)\n", .{path});
        try write(io, line);
    } else {
        const line = try std.fmt.allocPrint(arena, "exclude: {s} already carries the marked .fs-meta/ block; nothing written\n", .{path});
        try write(io, line);
    }
}

/// A JSON string for the scan report. The names are already valid UTF-8 (§ 3), so only the two characters JSON
/// requires are escaped; everything else is written through as the format's bytes.
fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn write(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn fail(io: std.Io, allocator: std.mem.Allocator, message: []const u8) !void {
    const text = try std.fmt.allocPrint(allocator, "fsmeta: {s}\n{s}", .{ message, usage });
    try std.Io.File.stdout().writeStreamingAll(io, text);
    std.process.exit(2);
}

/// A range of batches is what a consumer asks for: everything after the generation it recorded, up to one it names.
pub const RangeError = error{ BatchGap, BatchTooOld };

/// Whether batches `from+1` to `to` can be read from an archive that retains `first` to `last`.
///
/// Dense numbering is the format's rule (FORMAT.md § 17.1), so bounds are enough: a range that starts before the archive
/// begins is `BatchTooOld`, and one that reaches past a missing batch is `BatchGap`. Neither is skippable — a consumer
/// that skipped a batch would silently miss a change, which is the failure the sequence exists to prevent.
pub fn checkRange(first: usize, last: usize, from: usize, to: usize) RangeError!void {
    if (to <= from) return;
    if (first > 0 and from + 1 < first) return error.BatchTooOld;
    if (to > last) return error.BatchGap;
}

/// Reconcile the batches after `from` up to `to` (default: the latest) into one record.
fn runReconcile(
    io: std.Io,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    root: []const u8,
    from_arg: []const u8,
    to_arg: ?[]const u8,
    baseline_root: ?[]const u8,
    json: bool,
) !void {
    const from = std.fmt.parseInt(usize, from_arg, 10) catch return fail(io, gpa, "from must be a number");

    const batches_dir = try openBatchesDir(io, root);
    defer batches_dir.close(io);

    var first: usize = 0;
    var last: usize = 0;
    var count: usize = 0;
    var iter = batches_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = std.fmt.parseInt(usize, entry.name, 16) catch continue;
        if (count == 0 or number < first) first = number;
        if (count == 0 or number > last) last = number;
        count += 1;
    }

    if (count == 0) {
        try write(io, if (json) "[]\n" else "0 names\n");
        return;
    }

    const to = if (to_arg) |value|
        std.fmt.parseInt(usize, value, 10) catch return fail(io, gpa, "to must be a number")
    else
        last;

    checkRange(first, last, from, to) catch |err| switch (err) {
        error.BatchTooOld => {
            const message = try std.fmt.allocPrint(arena, "batch-too-old: batches start at {d}, so generation {d} cannot be reconciled from\n", .{ first, from });
            try write(io, message);
            // A refusal is a failure: a consumer that reads exit 0 would treat "rescan" as "nothing changed".
            std.process.exit(1);
        },
        error.BatchGap => {
            const message = try std.fmt.allocPrint(arena, "batch-gap: no batch {d}; the archive holds {d}..{d}\n", .{ to, first, last });
            try write(io, message);
            // A refusal is a failure: a consumer that reads exit 0 would treat "rescan" as "nothing changed".
            std.process.exit(1);
        },
    };

    var events: std.ArrayListUnmanaged(reconcile.Event) = .empty;
    errdefer events.deinit(arena);
    for (from + 1 .. to + 1) |n| {
        const dir_name = try std.fmt.allocPrint(arena, "{x:0>8}", .{n});
        var batch_dir = batches_dir.openDir(io, dir_name, .{ .iterate = true }) catch {
            const message = try std.fmt.allocPrint(arena, "batch-gap: no batch {d}\n", .{n});
            try write(io, message);
            // A refusal is a failure: a consumer that reads exit 0 would treat "rescan" as "nothing changed".
            std.process.exit(1);
        };
        defer batch_dir.close(io);

        const meta = try readOptional(io, batch_dir, format.meta_file, arena) orelse continue;
        const txt = try readOptional(io, batch_dir, format.txt_file, arena) orelse continue;
        const plan = try batch.decode(arena, meta, txt);
        defer {
            arena.free(plan.entries);
            arena.free(plan.names);
        }
        const batch_events = try batch.toEvents(arena, plan);
        try events.appendSlice(arena, batch_events);
    }

    // The baseline is the consumer's own state at `from`, given as a trio: without it a name that changed and changed
    // back still reports `changed`, which is the event history rather than the difference.
    var store = BaselineStore{};
    defer store.deinit();
    var baseline: ?reconcile.Baseline = null;
    if (baseline_root) |baseline_path| {
        try store.load(arena, io, baseline_path);
        baseline = .{ .context = &store, .lookup = BaselineStore.lookup };
    }

    const changes = try reconcile.collapse(arena, events.items, baseline);
    defer arena.free(changes);

    if (json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const writer = &out.writer;
        try writer.writeAll("[\n");
        for (changes, 0..) |change, index| {
            if (index > 0) try writer.writeAll(",\n");
            try writer.writeAll("  {\"name\": ");
            try jsonWriteString(writer, change.name);
            const kind = switch (change.kind) {
                .added => "added",
                .changed => "changed",
                .deleted => "deleted",
            };
            try writer.print(", \"kind\": \"{s}\"}}", .{kind});
        }
        try writer.writeAll("\n]\n");
        try write(io, out.written());
        return;
    }

    for (changes) |change| {
        const kind = switch (change.kind) {
            .added => "added",
            .changed => "changed",
            .deleted => "deleted",
        };
        const line = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ kind, change.name });
        try write(io, line);
    }
    const total = try std.fmt.allocPrint(arena, "{d} names\n", .{changes.len});
    try write(io, total);
}

test "a batch range is refused rather than silently shortened" {
    // Everything the archive has.
    try checkRange(1, 3, 0, 3);
    try checkRange(1, 3, 1, 3);
    // Nothing to do.
    try checkRange(1, 3, 3, 3);
    // The baseline predates the archive.
    try std.testing.expectError(error.BatchTooOld, checkRange(2, 3, 0, 2));
    // The range reaches a batch the archive does not have.
    try std.testing.expectError(error.BatchGap, checkRange(1, 3, 1, 4));
}


/// The state a consumer recorded at `from`, keyed by the same root-relative name a batch uses.
const BaselineStore = struct {
    allocator: std.mem.Allocator = undefined,
    by_name: std.StringHashMapUnmanaged(reconcile.Identity) = .{},

    fn deinit(self: *BaselineStore) void {
        self.by_name.deinit(self.allocator);
    }

    /// Loads `<root>/.fs-meta` and rebuilds each name's identity exactly as `batch.toEvents` does: the flags word with the
    /// change bits cleared, so a file is REGULAR_FILE or SYMLINK (plus CONTENT_KNOWN when the hash is known and HASH_LF when
    /// the file is stored with LF), and a directory is IS_DIR.
    fn load(self: *BaselineStore, arena: std.mem.Allocator, io: std.Io, root: []const u8) !void {
        self.allocator = arena;
        var cache = try loadCache(arena, io, root);
        defer cache.deinit();

        var files = cache.files.iterator();
        while (files.next()) |entry| {
            const state = entry.value_ptr.*;
            var flags: u32 = switch (state.kind) {
                .regular_file => format.flags.regular_file,
                .symlink => format.flags.symlink,
                .dir => format.flags.is_dir,
            };
            if (state.content_hash != null) flags |= format.flags.content_known;
            if (state.hash_lf) flags |= format.flags.hash_lf;
            // The key is copied: the cache dies at the end of this function and its keys are the cache's own
            // (`Cache.load` duplicates them, `Cache.deinit` frees them), so a borrowed key here would leave a map of
            // dangling names and a baseline that silently matches nothing. Directory keys below are formatted for
            // the same reason.
            try self.by_name.put(arena, try arena.dupe(u8, entry.key_ptr.*), .{
                .contentHash = state.content_hash orelse 0,
                .sizeBytes = state.size_bytes,
                .flags = flags,
            });
        }

        var dirs = cache.dirs.iterator();
        while (dirs.next()) |entry| {
            const name = entry.key_ptr.*;
            if (name.len == 0) continue; // the root itself is not a name a batch carries
            const stored = try std.fmt.allocPrint(arena, "{s}/", .{name});
            try self.by_name.put(arena, stored, .{
                .contentHash = 0,
                .sizeBytes = 0,
                .flags = format.flags.is_dir,
            });
        }
    }

    fn lookup(context: *anyopaque, name_hash: u64, name: []const u8) ?reconcile.Identity {
        _ = name_hash; // the map is by name: the hash only orders the trio
        const self: *BaselineStore = @ptrCast(@alignCast(context));
        return self.by_name.get(name);
    }
};
