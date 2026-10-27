// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `fsmeta daemon …`, `fsmeta roots …` and `fsmeta root …`: the CLI half of the control plane.
//!
//! Every command but `daemon start --foreground` is a client: it computes the same base directory the daemon
//! would, reads `<base>/daemon.json` to confirm there is one, connects to `<base>/daemon.sock`, sends one JSON
//! line and prints the one JSON line that comes back. The daemon is the only writer of `roots.json`, the only
//! process that binds a socket, and the only one that decides when a root wakes — so the CLI cannot drift
//! from it, because it holds no state at all.
//!
//! ## Exit codes
//!
//! | code | meaning                                                                 |
//! | ---- | ----------------------------------------------------------------------- |
//! | `0`  | ok                                                                      |
//! | `1`  | a usage error, or a failure the daemon reported without a table entry    |
//! | `2`  | no such root (or `root add` of a directory that does not exist)          |
//! | `3`  | the daemon is not running                                               |
//! | `4`  | refused by policy (`wake` on `off`, `remove` with live clients, a duplicate add) |
//! | `5`  | the CLI and the daemon do not share a control protocol version           |
//!
//! The codes come from `control.Exit`, so the daemon's `code` field and the process's status are one table.

const std = @import("std");
const paths = @import("paths.zig");
const control = @import("control.zig");
const registry = @import("registry.zig");
const host = @import("host.zig");
const hooks = @import("hooks.zig");
const gitwatch = @import("gitwatch.zig");

pub const usage =
    \\fsmeta daemon — serve roots in the background
    \\
    \\usage:
    \\  fsmeta daemon start [--base <dir>] [--foreground]
    \\  fsmeta daemon stop
    \\  fsmeta daemon status [--json]
    \\  fsmeta roots list [--json] [--state watching,asleep]
    \\  fsmeta root add <path> [--mode off|always|auto] [--idle <duration>]
    \\                         [--keep-batches <n>] [--max-bytes <bytes>] [--on-remove keep|delete]
    \\                         [--worktrees on|off] [--gitwatch on|off] [--on-worktree ignore|serve]
    \\                         [--worktree] [--nested]
    \\  fsmeta root remove <id|path> [--force]
    \\  fsmeta root set <id> mode off|always|auto
    \\  fsmeta root set <id> idle <duration>
    \\  fsmeta root set <id> keep-batches <n>
    \\  fsmeta root set <id> worktrees on|off
    \\  fsmeta root set <id> gitwatch on|off
    \\  fsmeta root sleep <id>
    \\  fsmeta root wake <id>
    \\  fsmeta root status <id> [--json]
    \\  fsmeta daemon hooks install <root> [--force]
    \\  fsmeta daemon hooks uninstall <root>
    \\  fsmeta daemon hooks status [<root>] [--json]
    \\
    \\hooks: git calls the generated scripts on every ref transaction, checkout, merge, rewrite and index write; they
    \\append one line to <git-common-dir>/fsmeta-events.log and the daemon reads it, so git events are exact. An
    \\existing hook is chained with --force (<name>.fsmeta-orig), never overwritten silently; uninstall restores it.
    \\
    \\--worktree: the path is a linked worktree (.git is a gitfile naming an existing directory); it is seeded from a
    \\served base and the worktrees switch is forced on for the new record. --nested: the add is an intentional nested
    \\root; it is still hidden from every served parent, and the reply says the intent was acknowledged.
    \\
    \\durations: 500ms, 30s, 10m, 0 (0 = never sleep)
    \\environment: FSMETA_RUNTIME_DIR, FSMETA_CONFIG_HOME (tests and containers); FSMETA_WORKTREES=0 and
    \\FSMETA_GITWATCH=0 at `daemon start` override both switches for every root of that daemon
    \\
;

/// Everything the subcommands share: the CLI's flags, in the shape the parser leaves them.
const Args = struct {
    base: ?[]const u8 = null,
    json: bool = false,
    foreground: bool = false,
    force: bool = false,
    mode: ?[]const u8 = null,
    idle: ?[]const u8 = null,
    keep_batches: ?[]const u8 = null,
    max_bytes: ?[]const u8 = null,
    on_remove: ?[]const u8 = null,
    worktrees: ?[]const u8 = null,
    gitwatch: ?[]const u8 = null,
    on_worktree: ?[]const u8 = null,
    /// `root add --worktree`: assert a linked worktree and take the seed/adoption path for this add (M7).
    worktree: bool = false,
    /// `root add --nested`: acknowledge an intentional nested root; the guard still applies (M7).
    nested: bool = false,
    states: ?[]const u8 = null,
    positional: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map, group: []const u8, args: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = parseArgs(arena, args) catch |err| switch (err) {
        error.UnknownOption => return fail(io, "unknown option\n{s}", .{usage}),
        error.MissingValue => return fail(io, "an option is missing its value\n{s}", .{usage}),
        else => return err,
    };
    const layout = paths.Layout.resolve(arena, .{ .map = env }, parsed.base) catch |err| {
        return fail(io, "cannot resolve the runtime directory: {s}", .{@errorName(err)});
    };

    if (std.mem.eql(u8, group, "daemon")) return daemonCommand(io, arena, layout, env, parsed);
    if (std.mem.eql(u8, group, "roots")) return rootsCommand(io, arena, layout, parsed);
    if (std.mem.eql(u8, group, "root")) return rootCommand(io, arena, layout, parsed);
    return fail(io, "unknown daemon command: {s}\n{s}", .{ group, usage });
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Args {
    var parsed: Args = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.json = true;
        } else if (std.mem.eql(u8, arg, "--foreground")) {
            parsed.foreground = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            parsed.force = true;
        } else if (std.mem.eql(u8, arg, "--base")) {
            parsed.base = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            parsed.mode = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--idle")) {
            parsed.idle = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--keep-batches")) {
            parsed.keep_batches = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--max-bytes")) {
            parsed.max_bytes = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--on-remove")) {
            parsed.on_remove = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--worktrees")) {
            parsed.worktrees = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--gitwatch")) {
            parsed.gitwatch = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--on-worktree")) {
            parsed.on_worktree = try valueArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--worktree")) {
            parsed.worktree = true;
        } else if (std.mem.eql(u8, arg, "--nested")) {
            parsed.nested = true;
        } else if (std.mem.eql(u8, arg, "--state")) {
            parsed.states = try valueArg(args, &index);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            try parsed.positional.append(arena, arg);
        }
    }
    return parsed;
}

fn valueArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

// SECTION: daemon

fn daemonCommand(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, env: *const std.process.Environ.Map, args: Args) !void {
    const command = if (args.positional.items.len > 0) args.positional.items[0] else "";
    if (std.mem.eql(u8, command, "start")) return daemonStart(io, arena, layout, env, args);
    if (std.mem.eql(u8, command, "stop")) return daemonStop(io, arena, layout);
    if (std.mem.eql(u8, command, "status")) return daemonStatus(io, arena, layout, args);
    if (std.mem.eql(u8, command, "hooks")) return hooksCommand(io, arena, layout, args);
    return fail(io, "unknown command: fsmeta daemon {s}\n{s}", .{ command, usage });
}

fn daemonStart(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, env: *const std.process.Environ.Map, args: Args) !void {
    if (args.foreground) {
        // The test and debug path: the daemon runs in this process, on this terminal.
        host.Host.run(io, arena, .{ .base = layout.base, .env = .{ .map = env } }) catch |err| switch (err) {
            error.AlreadyRunning => {
                printError(io, "a daemon is already running on {s}\n", .{layout.base});
                std.process.exit(control.Exit.refused);
            },
            else => {
                printError(io, "the daemon could not start: {s}\n", .{@errorName(err)});
                std.process.exit(control.Exit.failure);
            },
        };
        return;
    }

    // Daemonize: spawn this executable again, detached, with no console and no inherited streams. The child
    // is not waited for; the control socket answering *is* the readiness signal.
    const executable = try std.process.executablePathAlloc(io, arena);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ executable, "daemon", "start", "--foreground", "--base", layout.base });
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Windows: no console window for a background process. On POSIX the child stays in this session's
        // process group, which is why a logout needs an explicit `fsmeta daemon stop` — stated in the docs.
        .create_no_window = true,
    }) catch |err| {
        printError(io, "cannot start the daemon: {s}\n", .{@errorName(err)});
        std.process.exit(control.Exit.failure);
    };
    _ = &child;

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try request(io, arena, layout, "{\"v\":1,\"cmd\":\"status\"}")) |reply| {
            const pid = integerField(result(reply), "pid") orelse 0;
            print(io, "started (pid {d}) on {s}", .{ pid, layout.base });
            return;
        }
        io.sleep(.fromMilliseconds(50), .real) catch {};
    }
    printError(io, "the daemon did not answer on {s}; check its logs under {s}\n", .{ layout.base, layout.base });
    std.process.exit(control.Exit.daemon_not_running);
}

fn daemonStop(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout) !void {
    _ = (try request(io, arena, layout, "{\"v\":1,\"cmd\":\"daemon.shutdown\"}")) orelse exitNotRunning(io, layout);
    // Wait for the socket to disappear, so a `stop` followed by a `start` cannot race the old process.
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const socket = try layout.controlSocket(arena);
        std.Io.Dir.accessAbsolute(io, socket, .{}) catch break;
        io.sleep(.fromMilliseconds(50), .real) catch {};
    }
    print(io, "stopped", .{});
}

fn daemonStatus(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const reply = (try request(io, arena, layout, "{\"v\":1,\"cmd\":\"status\"}")) orelse exitNotRunning(io, layout);
    if (args.json) {
        print(io, "{s}", .{reply.raw});
        return;
    }
    print(io, "pid {d}, base {s}, {d} root(s), up {d} s, worktrees {s}, gitwatch {s}", .{
        integerField(result(reply), "pid") orelse 0,
        layout.base,
        integerField(result(reply), "roots") orelse 0,
        (integerField(result(reply), "uptime_ms") orelse 0) / 1000,
        onOff(boolFieldValue(result(reply), "worktrees") orelse true),
        onOff(boolFieldValue(result(reply), "gitwatch") orelse true),
    });
    if (stringFieldValue(result(reply), "worktrees_override")) |value| {
        if (value.len > 0) print(io, "  note: FSMETA_WORKTREES={s} is active", .{value});
    }
    if (stringFieldValue(result(reply), "gitwatch_override")) |value| {
        if (value.len > 0) print(io, "  note: FSMETA_GITWATCH={s} is active", .{value});
    }
    if (result(reply).object.get("diagnostics")) |diagnostics| {
        for (diagnostics.array.items) |item| {
            print(io, "  note: {s}", .{item.string});
        }
    }
}

// SECTION: hooks

/// `fsmeta daemon hooks install|uninstall|status` (`plans/worktrees.md` § 5c, M5).
///
/// This half of the command is a **local file operation**: it resolves the git directories from the path it is given
/// and writes (or removes) files in `$GIT_COMMON_DIR/hooks`, so it works with no daemon running — the hooks are for the
/// next checkout, not for this process. Only the `gitwatch` question consults the daemon, and that asks which roots
/// exist rather than doing the work.
fn hooksCommand(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const action = if (args.positional.items.len > 1) args.positional.items[1] else "";
    if (std.mem.eql(u8, action, "install")) return hooksInstall(io, arena, layout, args);
    if (std.mem.eql(u8, action, "uninstall")) return hooksUninstall(io, arena, args);
    if (std.mem.eql(u8, action, "status")) return hooksStatus(io, arena, layout, args);
    return fail(io, "unknown command: fsmeta daemon hooks {s}\n{s}", .{ action, usage });
}

fn hooksInstall(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const absolute = try hooksRootArgument(io, arena, args, "install");
    const place = hooks.locate(arena, io, absolute) catch |err| switch (err) {
        error.NotARepository => return refuse(io, "hooks install: {s} is not a git working copy (no readable .git), so there is nowhere to install", .{absolute}),
        else => return fail(io, "hooks install: {s}", .{@errorName(err)}),
    };

    // 1. `core.hooksPath` moves the directory git reads: installing ours into `<common>/hooks` would be silent.
    if (hooks.hooksPath(io, arena, absolute, place.common)) |configured| {
        return refuse(io, "hooks install: core.hooksPath is set to {s}, so git would never run the hooks in {s}; nothing was installed", .{ configured, place.hooks });
    }

    // 2. A hook that writes a spool nobody reads is a trap (`plans/worktrees.md` § 5c): check the root's own switch.
    const served = try servedRoot(io, arena, layout, absolute);
    if (!served.found) {
        return refuse(io, "hooks install: cannot tell whether {s} is served with gitwatch on: no daemon is running and {s} has no record for it; add the root first (`fsmeta root add {s}`), because a hook that writes a spool nobody reads is a trap", .{ absolute, layout.config, absolute });
    }
    if (!served.gitwatch) {
        return refuse(io, "hooks install: {s} has gitwatch off, so the daemon would never read its hook spool; nothing was installed (a hook that writes a spool nobody reads is a trap)", .{absolute});
    }

    // 3. Prove `<common>` can be written *before* writing anything into it: a read-only repository must be a refusal
    //    with its path in the message, not a hook git cannot run.
    hooks.checkWritable(io, arena, place.common) catch |err| {
        return refuse(io, "hooks install: {s} cannot be written ({s}); a read-only repository cannot report git events", .{ place.hooks, @errorName(err) });
    };

    // 4. A hook that is not ours is never overwritten silently (`plans/worktrees.md` § 5c): name the file, offer
    //    `--force`, which keeps it as `<name>.fsmeta-orig` and chains it.
    if (try hooks.status(io, arena, absolute)) |current| {
        for (current.hooks, 0..) |state, index| {
            if (state != .foreign or args.force) continue;
            const target = try std.fs.path.join(arena, &.{ place.hooks, hooks.hook_names[index] });
            return refuse(io, "hooks install: {s} already exists and is not fsmeta's; use --force to keep it as {s}.fsmeta-orig and chain it", .{ target, target });
        }
    }

    const summary = hooks.install(io, arena, absolute, args.force) catch |err| switch (err) {
        error.HookExists => return refuse(io, "hooks install: a hook in {s} is not fsmeta's; use --force to chain it", .{place.hooks}),
        error.NotARepository => return refuse(io, "hooks install: {s} is not a git working copy", .{absolute}),
        else => return fail(io, "hooks install: {s}: {s}", .{ place.hooks, @errorName(err) }),
    };
    if (summary.chained > 0) {
        print(io, "installed {d} hook(s) in {s}, chained {d} existing hook(s) as *.fsmeta-orig", .{ summary.installed, summary.hooks_dir, summary.chained });
    } else {
        print(io, "installed {d} hook(s) in {s}", .{ summary.installed, summary.hooks_dir });
    }
    print(io, "  the daemon reads {s} on its tick; `fsmeta daemon hooks uninstall {s}` removes them", .{ place.spool, absolute });
}

fn hooksUninstall(io: std.Io, arena: std.mem.Allocator, args: Args) !void {
    const absolute = try hooksRootArgument(io, arena, args, "uninstall");
    const place = hooks.locate(arena, io, absolute) catch |err| switch (err) {
        error.NotARepository => return refuse(io, "hooks uninstall: {s} is not a git working copy (no readable .git)", .{absolute}),
        else => return fail(io, "hooks uninstall: {s}", .{@errorName(err)}),
    };
    const summary = hooks.uninstall(io, arena, absolute) catch |err| {
        return fail(io, "hooks uninstall: {s}: {s}", .{ place.hooks, @errorName(err) });
    };
    if (summary.removed == 0 and summary.restored == 0) {
        print(io, "no fsmeta hooks in {s}", .{place.hooks});
        return;
    }
    print(io, "removed {d} fsmeta hook(s) from {s}, restored {d} original(s)", .{ summary.removed, place.hooks, summary.restored });
}

/// What `status` reports for one repository, in the order the hooks are generated.
fn writeHookStatusJson(writer: *std.Io.Writer, repository: RepositoryStatus) !void {
    // The first member is written without the leading comma the `field` helpers emit: `{,"common":…` is not JSON.
    try writer.writeAll("{\"common\":");
    try control.writeString(writer, repository.common);
    try control.stringField(writer, "hooks_dir", repository.hooks_dir);
    try control.stringField(writer, "spool", repository.spool);
    try control.intField(writer, "spool_bytes", repository.spool_bytes);
    try writer.writeAll(",\"roots\":[");
    for (repository.roots, 0..) |root, index| {
        if (index > 0) try writer.writeByte(',');
        try control.writeString(writer, root);
    }
    try writer.writeAll("],\"hooks\":{");
    for (repository.states, 0..) |state, index| {
        if (index > 0) try writer.writeByte(',');
        try control.writeString(writer, hooks.hook_names[index]);
        try writer.writeByte(':');
        try control.writeString(writer, hookStateWord(state));
    }
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn hookStateWord(state: hooks.HookState) []const u8 {
    return switch (state) {
        .absent => "absent",
        .ours => "ours",
        .foreign => "foreign",
        .chained => "chained",
    };
}

/// One repository's answer: what `status` reads once per common dir, however many roots resolve to it.
const RepositoryStatus = struct {
    common: []const u8,
    hooks_dir: []const u8,
    spool: []const u8,
    spool_bytes: u64,
    states: [hooks.hook_names.len]hooks.HookState,
    roots: []const []const u8,
};

fn hooksStatus(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    // With a root, report that repository. Without one, report every served root's — grouped by repository, because
    // the hooks live in the common dir and several served worktrees share them (`plans/worktrees.md` § 5c).
    var repositories: std.ArrayListUnmanaged(RepositoryStatus) = .empty;

    if (args.positional.items.len > 2) {
        const absolute = try hooksRootArgument(io, arena, args, "status");
        const status = hooks.status(io, arena, absolute) catch |err| {
            return fail(io, "hooks status: {s}", .{@errorName(err)});
        };
        const current = status orelse return refuse(io, "hooks status: {s} is not a git working copy (no readable .git)", .{absolute});
        const roots = try arena.alloc([]const u8, 1);
        roots[0] = absolute;
        try repositories.append(arena, .{
            .common = current.common_dir,
            .hooks_dir = try std.fs.path.join(arena, &.{ current.common_dir, "hooks" }),
            .spool = current.spool_path,
            .spool_bytes = current.spool_bytes,
            .states = current.hooks,
            .roots = roots,
        });
    } else {
        const served = try servedRoots(io, arena, layout);
        for (served.entries) |entry| {
            const status = hooks.status(io, arena, entry.root) catch continue;
            const current = status orelse continue;
            // One repository, one answer: two roots of one repo must not report the same files twice.
            var existing: ?*RepositoryStatus = null;
            for (repositories.items) |*candidate| {
                if (gitwatch.samePath(candidate.common, current.common_dir)) existing = candidate;
            }
            if (existing) |repository| {
                var merged = std.ArrayListUnmanaged([]const u8).empty;
                try merged.appendSlice(arena, repository.roots);
                try merged.append(arena, entry.root);
                repository.roots = merged.items;
                continue;
            }
            const roots = try arena.alloc([]const u8, 1);
            roots[0] = entry.root;
            try repositories.append(arena, .{
                .common = current.common_dir,
                .hooks_dir = try std.fs.path.join(arena, &.{ current.common_dir, "hooks" }),
                .spool = current.spool_path,
                .spool_bytes = current.spool_bytes,
                .states = current.hooks,
                .roots = roots,
            });
        }
        if (served.entries.len == 0) {
            if (args.json) {
                print(io, "{{\"v\":1,\"ok\":true,\"source\":\"none\",\"repositories\":[]}}", .{});
            } else {
                print(io, "no served roots: start the daemon or add one with `fsmeta root add`", .{});
            }
            return;
        }
    }

    if (args.json) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try control.beginOk(&out.writer);
        try out.writer.writeAll(",\"repositories\":[");
        for (repositories.items, 0..) |repository, index| {
            if (index > 0) try out.writer.writeByte(',');
            try writeHookStatusJson(&out.writer, repository);
        }
        try out.writer.writeAll("]");
        try control.finish(&out.writer);
        print(io, "{s}", .{out.written()});
        return;
    }
    for (repositories.items) |repository| {
        print(io, "{s}", .{repository.common});
        for (repository.roots) |root| print(io, "  served by {s}", .{root});
        for (repository.states, 0..) |state, index| {
            print(io, "  {s}  {s}{s}", .{
                hooks.hook_names[index],
                hookStateWord(state),
                switch (state) {
                    .foreign => " (not fsmeta's: install refuses unless --force chains it)",
                    .chained => " (chained: <name>.fsmeta-orig runs after ours)",
                    else => "",
                },
            });
        }
        var buffer: [32]u8 = undefined;
        print(io, "  spool {s}: {s}", .{ repository.spool, formatBytes(repository.spool_bytes, &buffer) });
    }
}

fn hooksRootArgument(io: std.Io, arena: std.mem.Allocator, args: Args, action: []const u8) ![]const u8 {
    if (args.positional.items.len < 3) return fail(io, "hooks {s} needs a root directory\n{s}", .{ action, usage });
    const path = args.positional.items[2];
    return std.fs.path.resolve(arena, &.{path}) catch |err| {
        return fail(io, "hooks {s}: cannot resolve {s}: {s}", .{ action, path, @errorName(err) });
    };
}

/// A served root, as the daemon reports it or as the durable list remembers it.
const ServedRoot = struct { found: bool, gitwatch: bool };

/// One root's `gitwatch`, asked of the daemon when there is one and of `roots.json` otherwise (`plans/worktrees.md`
/// § 5c: `install` refuses while the switch is off, and must work with no daemon running).
fn servedRoot(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, root: []const u8) !ServedRoot {
    const served = try servedRoots(io, arena, layout);
    for (served.entries) |entry| {
        if (gitwatch.samePath(entry.root, root)) return .{ .found = true, .gitwatch = entry.gitwatch };
    }
    return .{ .found = false, .gitwatch = false };
}

const ServedEntry = struct { id: []const u8, root: []const u8, gitwatch: bool };
const ServedList = struct { entries: []ServedEntry, from_daemon: bool };

/// The roots this machine serves: the running daemon's list when it answers, the durable list otherwise. A daemon
/// that is not running is not an error here — `hooks install` must work without one.
fn servedRoots(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout) !ServedList {
    var entries: std.ArrayListUnmanaged(ServedEntry) = .empty;
    if (try request(io, arena, layout, "{\"v\":1,\"cmd\":\"roots\"}")) |reply| {
        if (result(reply).object.get("roots")) |roots_value| {
            for (roots_value.array.items) |item| {
                const root = stringFieldValue(item, "root") orelse continue;
                try entries.append(arena, .{
                    .id = stringFieldValue(item, "id") orelse "",
                    .root = root,
                    .gitwatch = boolFieldValue(item, "gitwatch") orelse true,
                });
            }
        }
        return .{ .entries = entries.items, .from_daemon = true };
    }
    var durable = registry.Registry.init(arena, layout.config);
    defer durable.deinit();
    durable.load(io) catch {};
    for (durable.records.items) |record| {
        entries.append(arena, .{ .id = record.id, .root = record.root, .gitwatch = record.gitwatch }) catch continue;
    }
    return .{ .entries = entries.items, .from_daemon = false };
}

// SECTION: roots

fn rootsCommand(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const command = if (args.positional.items.len > 0) args.positional.items[0] else "";
    if (!std.mem.eql(u8, command, "list")) return fail(io, "unknown command: fsmeta roots {s}\n{s}", .{ command, usage });

    const reply = (try request(io, arena, layout, "{\"v\":1,\"cmd\":\"roots\"}")) orelse exitNotRunning(io, layout);
    if (args.json) {
        print(io, "{s}", .{reply.raw});
        return;
    }
    const roots = result(reply).object.get("roots") orelse {
        print(io, "no roots", .{});
        return;
    };
    // Grouping by common dir is **sorted adjacency**: roots of one repository are adjacent under a `repo <common
    // dir>` header, and a root with no repository (or `gitwatch` off) has an empty key and comes last
    // (`plans/worktrees.md` § 5g). `--json` stays the flat array with the same two fields.
    var listings: std.ArrayListUnmanaged(RootListing) = .empty;
    defer listings.deinit(arena);
    for (roots.array.items) |item| {
        if (!matchesStates(item, args.states)) continue;
        try listings.append(arena, .{
            .item = item,
            .index = listings.items.len,
            .key = stringFieldValue(item, "common_dir") orelse "",
            .worktree = boolFieldValue(item, "worktree") orelse false,
        });
    }
    std.mem.sort(RootListing, listings.items, {}, listingLessThan);

    var shown: usize = 0;
    var last_key: ?[]const u8 = null;
    for (listings.items) |listing| {
        const item = listing.item;
        if (listing.key.len > 0) {
            if (last_key == null or !std.mem.eql(u8, last_key.?, listing.key)) {
                if (last_key != null) print(io, "", .{});
                print(io, "repo {s}", .{listing.key});
            }
            last_key = listing.key;
        }
        // A root the daemon could not read in time is named, not guessed at (`FORMAT.daemon.md` § 4b).
        if (item.object.get("available")) |available| {
            if (!available.bool) {
                print(io, "{s}  {s:<8}  {s}  {s}", .{
                    stringFieldValue(item, "id") orelse "?",
                    "n/a",
                    "(not available yet: the root is busy)",
                    stringFieldValue(item, "root") orelse "?",
                });
                shown += 1;
                continue;
            }
        }
        var idle_buffer: [32]u8 = undefined;
        print(io, "{s}  {s:<8}  {s:<6}  {d} client(s)  idle {s}  {s}{s}", .{
            stringFieldValue(item, "id") orelse "?",
            stringFieldValue(item, "state") orelse "?",
            stringFieldValue(item, "mode") orelse "?",
            integerFieldValue(item, "clients") orelse 0,
            formatDuration(integerFieldValue(item, "idle_timeout_ms") orelse 0, &idle_buffer),
            stringFieldValue(item, "root") orelse "?",
            if (listing.worktree) "  worktree" else "",
        });
        shown += 1;
    }
    if (shown == 0) print(io, "no roots", .{});
    if (result(reply).object.get("partial")) |partial| {
        if (partial.bool) print(io, "note: some roots were busy; `--json` says which and why", .{});
    }
}

/// One row of `roots list`'s text output: the root object, its original position (a stable tiebreak inside a repo)
/// and the common dir it groups under (empty = no group, printed last).
const RootListing = struct {
    item: std.json.Value,
    index: usize,
    key: []const u8,
    worktree: bool,
};

fn listingLessThan(_: void, left: RootListing, right: RootListing) bool {
    if (left.key.len == 0 and right.key.len > 0) return false;
    if (left.key.len > 0 and right.key.len == 0) return true;
    const order = std.mem.order(u8, left.key, right.key);
    if (order != .eq) return order == .lt;
    return left.index < right.index;
}

// SECTION: root-commands

fn rootCommand(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const command = if (args.positional.items.len > 0) args.positional.items[0] else "";
    if (std.mem.eql(u8, command, "add")) return rootAdd(io, arena, layout, args);
    if (std.mem.eql(u8, command, "remove")) return rootRemove(io, arena, layout, args);
    if (std.mem.eql(u8, command, "set")) return rootSet(io, arena, layout, args);
    if (std.mem.eql(u8, command, "sleep")) return rootSimple(io, arena, layout, args, "root.sleep", "asleep");
    if (std.mem.eql(u8, command, "wake")) return rootSimple(io, arena, layout, args, "root.wake", "waking");
    if (std.mem.eql(u8, command, "status")) return rootStatus(io, arena, layout, args);
    return fail(io, "unknown command: fsmeta root {s}\n{s}", .{ command, usage });
}

fn rootAdd(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    if (args.positional.items.len < 2) return fail(io, "root add needs a directory\n{s}", .{usage});
    // The locator is resolved here, against *this* process's directory. The daemon has its own working
    // directory — a daemonized process keeps the one it was started from — so sending a relative path would
    // make the daemon resolve it somewhere the caller never meant.
    const path = args.positional.items[1];
    const absolute = std.fs.path.resolve(arena, &.{path}) catch |err| {
        return fail(io, "cannot resolve {s}: {s}", .{ path, @errorName(err) });
    };

    var request_bytes: std.Io.Writer.Allocating = .init(arena);
    const writer = &request_bytes.writer;
    try writer.writeAll("{\"v\":1,\"cmd\":\"root.add\",\"path\":");
    try control.writeString(writer, absolute);
    if (args.mode) |mode| {
        try writer.writeAll(",\"mode\":");
        try control.writeString(writer, mode);
    }
    if (args.idle) |idle| {
        const value = parseDuration(idle) orelse return fail(io, "--idle needs a duration such as 500ms, 30s, 10m or 0", .{});
        try writer.print(",\"idle_timeout_ms\":{d}", .{value});
    }
    if (args.keep_batches != null or args.max_bytes != null) {
        try writer.writeAll(",\"retention\":{");
        var first = true;
        if (args.keep_batches) |text| {
            const value = std.fmt.parseInt(u64, text, 10) catch return fail(io, "--keep-batches needs a number", .{});
            try writer.print("\"max_batches\":{d}", .{value});
            first = false;
        }
        if (args.max_bytes) |text| {
            const value = parseBytes(text) orelse return fail(io, "--max-bytes needs a number, optionally in K/M/G", .{});
            if (!first) try writer.writeByte(',');
            try writer.print("\"max_bytes\":{d}", .{value});
        }
        try writer.writeByte('}');
    }
    if (args.on_remove) |value| {
        try writer.writeAll(",\"on_remove\":");
        try control.writeString(writer, value);
    }
    if (args.worktrees) |value| {
        try writer.writeAll(",\"worktrees\":");
        try writer.writeAll(if (parseFlagValue(value) orelse return fail(io, "--worktrees needs on or off", .{})) "true" else "false");
    }
    if (args.gitwatch) |value| {
        try writer.writeAll(",\"gitwatch\":");
        try writer.writeAll(if (parseFlagValue(value) orelse return fail(io, "--gitwatch needs on or off", .{})) "true" else "false");
    }
    if (args.on_worktree) |value| {
        if (registry.OnWorktree.parse(value) == null) return fail(io, "--on-worktree needs ignore or serve", .{});
        try writer.writeAll(",\"on_worktree\":");
        try control.writeString(writer, value);
    }
    if (args.worktree) try writer.writeAll(",\"worktree\":true");
    if (args.nested) try writer.writeAll(",\"nested\":true");
    try writer.writeByte('}');

    const reply = (try request(io, arena, layout, request_bytes.written())) orelse exitNotRunning(io, layout);
    const added = result(reply).object.get("root") orelse result(reply);
    print(io, "added {s} ({s}, {s}) {s}", .{
        stringFieldValue(added, "id") orelse "?",
        stringFieldValue(added, "state") orelse "?",
        stringFieldValue(added, "mode") orelse "?",
        stringFieldValue(added, "root") orelse path,
    });
    if (stringFieldValue(result(reply), "nested")) |value| {
        print(io, "  nested: {s} (the parent's managed ignore still applies; the flag does not weaken the guard)", .{value});
    }
    if (boolFieldValue(added, "worktree") orelse false) {
        print(io, "  linked worktree of {s}", .{stringFieldValue(added, "common_dir") orelse "?"});
    }
    // A nested root is guarded, not warned about (`plans/worktrees.md` § 5, M2): `root.add` either arranged the
    // parent's managed line (this reply) or refused with exit 4 and a message naming the file and the parent.
}

fn rootRemove(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const target = rootTarget(args) orelse return fail(io, "root remove needs an id or a root path\n{s}", .{usage});
    var request_bytes: std.Io.Writer.Allocating = .init(arena);
    const writer = &request_bytes.writer;
    try writer.writeAll("{\"v\":1,\"cmd\":\"root.remove\",\"root\":");
    try control.writeString(writer, target);
    if (args.force) try writer.writeAll(",\"force\":true");
    try writer.writeByte('}');

    const reply = (try request(io, arena, layout, request_bytes.written())) orelse exitNotRunning(io, layout);
    print(io, "removed {s} ({s}, history {s})", .{
        stringFieldValue(result(reply), "removed") orelse target,
        stringFieldValue(result(reply), "root") orelse "?",
        stringFieldValue(result(reply), "history") orelse "?",
    });
}

fn rootSet(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    // `fsmeta root set <id> mode <value>` / `... idle <duration> / ... keep-batches <n>` / `... worktrees on|off`
    // / `... gitwatch on|off`: two words, one setting.
    if (args.positional.items.len < 4) return fail(io, "root set needs <id> <mode|idle|keep-batches|worktrees|gitwatch> <value>\n{s}", .{usage});
    const target = args.positional.items[1];
    const what = args.positional.items[2];
    const value = args.positional.items[3];

    var request_bytes: std.Io.Writer.Allocating = .init(arena);
    const writer = &request_bytes.writer;
    try writer.writeAll("{\"v\":1,\"cmd\":\"root.set\",\"root\":");
    try control.writeString(writer, target);
    if (std.mem.eql(u8, what, "mode")) {
        try writer.writeAll(",\"mode\":");
        try control.writeString(writer, value);
    } else if (std.mem.eql(u8, what, "idle")) {
        const milliseconds = parseDuration(value) orelse return fail(io, "idle needs a duration such as 500ms, 30s, 10m or 0", .{});
        try writer.print(",\"idle_timeout_ms\":{d}", .{milliseconds});
    } else if (std.mem.eql(u8, what, "keep-batches")) {
        const count = std.fmt.parseInt(u64, value, 10) catch return fail(io, "keep-batches needs a number", .{});
        try writer.print(",\"retention\":{{\"max_batches\":{d}}}", .{count});
    } else if (std.mem.eql(u8, what, "worktrees")) {
        const enabled = parseFlagValue(value) orelse return fail(io, "worktrees needs on or off", .{});
        try writer.writeAll(if (enabled) ",\"worktrees\":true" else ",\"worktrees\":false");
    } else if (std.mem.eql(u8, what, "gitwatch")) {
        const enabled = parseFlagValue(value) orelse return fail(io, "gitwatch needs on or off", .{});
        try writer.writeAll(if (enabled) ",\"gitwatch\":true" else ",\"gitwatch\":false");
    } else {
        return fail(io, "root set understands mode, idle, keep-batches, worktrees and gitwatch", .{});
    }
    try writer.writeByte('}');

    const reply = (try request(io, arena, layout, request_bytes.written())) orelse exitNotRunning(io, layout);
    const root = result(reply).object.get("root") orelse result(reply);
    var idle_buffer: [32]u8 = undefined;
    print(io, "set {s}: mode {s}, state {s}, idle {s}, worktrees {s}, gitwatch {s}", .{
        stringFieldValue(root, "id") orelse target,
        stringFieldValue(root, "mode") orelse what,
        stringFieldValue(root, "state") orelse "?",
        formatDuration(integerFieldValue(root, "idle_timeout_ms") orelse 0, &idle_buffer),
        onOff(boolFieldValue(root, "worktrees") orelse true),
        onOff(boolFieldValue(root, "gitwatch") orelse true),
    });
    // A live flip is applied as the *effective* value, so an environment override can mask it. Say so rather than
    // printing a value that is not in force.
    if ((std.mem.eql(u8, what, "worktrees") or std.mem.eql(u8, what, "gitwatch"))) {
        const requested = parseFlagValue(value) orelse false;
        const effective = boolFieldValue(root, what) orelse requested;
        if (requested != effective) {
            print(io, "  note: FSMETA_WORKTREES/FSMETA_GITWATCH is active; the record says {s}, the daemon runs {s}", .{
                onOff(requested),
                onOff(effective),
            });
        }
    }
}

fn rootSimple(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args, command: []const u8, verb: []const u8) !void {
    const target = rootTarget(args) orelse return fail(io, "this command needs an id or a root path\n{s}", .{usage});
    var request_bytes: std.Io.Writer.Allocating = .init(arena);
    const writer = &request_bytes.writer;
    try writer.writeAll("{\"v\":1,\"cmd\":");
    try control.writeString(writer, command);
    try writer.writeAll(",\"root\":");
    try control.writeString(writer, target);
    try writer.writeByte('}');

    const reply = (try request(io, arena, layout, request_bytes.written())) orelse exitNotRunning(io, layout);
    const root = result(reply).object.get("root") orelse result(reply);
    print(io, "{s}: {s} is {s}", .{ verb, stringFieldValue(root, "id") orelse target, stringFieldValue(root, "state") orelse "?" });
}

fn rootStatus(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, args: Args) !void {
    const target = rootTarget(args) orelse return fail(io, "root status needs an id or a root path\n{s}", .{usage});
    var request_bytes: std.Io.Writer.Allocating = .init(arena);
    const writer = &request_bytes.writer;
    try writer.writeAll("{\"v\":1,\"cmd\":\"root.status\",\"root\":");
    try control.writeString(writer, target);
    try writer.writeByte('}');

    const reply = (try request(io, arena, layout, request_bytes.written())) orelse exitNotRunning(io, layout);
    if (args.json) {
        print(io, "{s}", .{reply.raw});
        return;
    }
    const root = result(reply).object.get("root") orelse result(reply);
    var idle_buffer: [32]u8 = undefined;
    print(io, "{s}  {s}", .{ stringFieldValue(root, "id") orelse "?", stringFieldValue(root, "root") orelse "?" });
    print(io, "  mode {s}, state {s} ({s}), {d} client(s)", .{
        stringFieldValue(root, "mode") orelse "?",
        stringFieldValue(root, "state") orelse "?",
        stringFieldValue(root, "reason") orelse "?",
        integerFieldValue(root, "clients") orelse 0,
    });
    print(io, "  idle {s}, head batch {d}, {d} pass(es), {d} wake(s)", .{
        formatDuration(integerFieldValue(root, "idle_timeout_ms") orelse 0, &idle_buffer),
        integerFieldValue(root, "head_batch") orelse 0,
        integerFieldValue(root, "passes") orelse 0,
        integerFieldValue(root, "wakes") orelse 0,
    });
    // What the last pass cost, not when it ran (`last_pass_ms` is a timestamp). A root that has never scanned
    // says so rather than showing three zeroes that look like a measured pass.
    if ((integerFieldValue(root, "last_pass_ms") orelse 0) == 0) {
        print(io, "  last pass: none yet", .{});
    } else {
        var batch_buffer: [32]u8 = undefined;
        print(io, "  last pass: {d} ms, {d} file(s), {s} batch", .{
            integerFieldValue(root, "last_pass_duration_ms") orelse 0,
            integerFieldValue(root, "last_pass_files") orelse 0,
            formatBytes(integerFieldValue(root, "last_pass_batch_bytes") orelse 0, &batch_buffer),
        });
    }
    // The split that tells an idle watcher from a dead one: safety passes are the net looking for itself after
    // `safety_pass_interval_ms` of silence, and one that keeps finding work means the watcher is missing events.
    print(io, "  passes by cause: {d} event, {d} safety", .{
        integerFieldValue(root, "event_passes") orelse 0,
        integerFieldValue(root, "safety_passes") orelse 0,
    });
    // What git is doing (`plans/worktrees.md` § 5g): the branch or `detached:<sha8>`, and any operation in
    // progress. A root with `gitwatch` off (or outside a repository) has no head, and says so rather than printing
    // an empty label that could be mistaken for a detached checkout.
    const head = stringFieldValue(root, "head") orelse "";
    if (head.len > 0) {
        const in_progress = stringFieldValue(root, "in_progress") orelse "";
        const detached = blk: {
            const value = root.object.get("detached") orelse break :blk false;
            break :blk value == .bool and value.bool;
        };
        if (in_progress.len > 0) {
            print(io, "  git: {s}{s}, {s} in progress", .{ head, if (detached) " (detached)" else "", in_progress });
        } else {
            print(io, "  git: {s}{s}", .{ head, if (detached) " (detached)" else "" });
        }
    } else {
        print(io, "  git: no state (gitwatch off, or not a git working copy)", .{});
    }
    // `GIT_EVENT` counters (§ 5d): frames sent, and passes a finish waited for. Both stay 0 with `gitwatch` off.
    const git_events = integerFieldValue(root, "git_events") orelse 0;
    if (git_events > 0 or (integerFieldValue(root, "git_passes") orelse 0) > 0) {
        print(io, "  git events: {d} sent, {d} pass(es) a finish waited for", .{
            git_events,
            integerFieldValue(root, "git_passes") orelse 0,
        });
    }
    // The most recent signal (`plans/worktrees.md` § 8.12), so a stale root and a quiet one are distinguishable.
    const last_git_kind = stringFieldValue(root, "last_git_kind") orelse "";
    if (last_git_kind.len > 0) {
        print(io, "  last git event: {s} {s}", .{
            last_git_kind,
            stringFieldValue(root, "last_git_phase") orelse "",
        });
    }
    if (root.object.get("retention")) |retention| {
        print(io, "  retention: {d} batch(es), {d} bytes; the last byte rotation dropped {d} generation(s)", .{
            integerFieldValue(retention, "max_batches") orelse 0,
            integerFieldValue(retention, "max_bytes") orelse 0,
            integerFieldValue(root, "rotated_by_bytes") orelse 0,
        });
    }
    print(io, "  socket {s}", .{stringFieldValue(root, "socket") orelse "?"});
    if (root.object.get("missing")) |missing| {
        if (missing.bool) print(io, "  missing: the root directory is gone", .{});
    }
    const error_text = stringFieldValue(root, "last_error") orelse "";
    if (error_text.len > 0) print(io, "  last error: {s}", .{error_text});
}

fn rootTarget(args: Args) ?[]const u8 {
    if (args.positional.items.len < 2) return null;
    return args.positional.items[1];
}

/// A reply line and its parsed value. `raw` is what `--json` prints, byte for byte; `document` owns the memory
/// `value` points into, so it must stay alive for as long as the value is read.
const Reply = struct {
    raw: []const u8,
    value: std.json.Value,
    document: std.json.Parsed(std.json.Value),
};

fn result(reply: Reply) std.json.Value {
    return reply.value;
}

/// Send one request line and read one reply line. `null` means the daemon is not running: no `daemon.json`,
/// no live daemon lock, or nothing answering on the socket.
///
/// The lock is checked before the connect on purpose. On Windows a refused AF_UNIX connect is not a clean
/// error — Zig reports an unmapped NTSTATUS and aborts — so "connect and see" is not a safe probe for a socket
/// a dead daemon left behind.
fn request(io: std.Io, arena: std.mem.Allocator, layout: paths.Layout, line: []const u8) !?Reply {
    const daemon_file = try layout.controlFile(arena);
    std.Io.Dir.accessAbsolute(io, daemon_file, .{}) catch return null;
    if (!@import("reaper.zig").daemonLive(io, arena, layout)) return null;

    const socket = try layout.controlSocket(arena);
    const address = std.Io.net.UnixAddress.init(socket) catch return null;
    const stream = address.connect(io) catch return null;
    defer stream.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &write_buffer);
    writer.interface.writeAll(line) catch return null;
    writer.interface.writeByte('\n') catch return null;
    writer.interface.flush() catch return null;

    const buffer = try arena.alloc(u8, 256 * 1024);
    var reader = std.Io.net.Stream.Reader.init(stream, io, buffer);
    const reply_line = reader.interface.takeDelimiterExclusive('\n') catch return null;

    const document = std.json.parseFromSlice(std.json.Value, arena, reply_line, .{}) catch |err| {
        printError(io, "the daemon's reply is not JSON ({s})\n", .{@errorName(err)});
        std.process.exit(control.Exit.failure);
    };
    const reply = Reply{ .raw = reply_line, .value = document.value, .document = document };

    const ok = switch (reply.value) {
        .object => |object| switch (object.get("ok") orelse std.json.Value{ .bool = false }) {
            .bool => |value| value,
            else => false,
        },
        else => false,
    };
    if (!ok) {
        const code: u8 = @intCast(@min(integerFieldValue(reply.value, "code") orelse control.Exit.failure, 255));
        const message = stringFieldValue(reply.value, "message") orelse "the daemon refused the request";
        printError(io, "{s}\n", .{message});
        std.process.exit(control.Exit.fromCode(code));
    }
    return reply;
}

fn matchesStates(item: std.json.Value, states: ?[]const u8) bool {
    const wanted = states orelse return true;
    const state = stringFieldValue(item, "state") orelse return false;
    var iterator = std.mem.splitScalar(u8, wanted, ',');
    while (iterator.next()) |candidate| {
        if (std.mem.eql(u8, std.mem.trim(u8, candidate, " "), state)) return true;
    }
    return false;
}

fn integerField(value: std.json.Value, key: []const u8) ?u64 {
    return integerFieldValue(value, key);
}

fn integerFieldValue(value: std.json.Value, key: []const u8) ?u64 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return switch (object.get(key) orelse return null) {
        .integer => |number| if (number < 0) null else @intCast(number),
        else => null,
    };
}

fn stringFieldValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn boolFieldValue(value: std.json.Value, key: []const u8) ?bool {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return switch (object.get(key) orelse return null) {
        .bool => |flag| flag,
        else => null,
    };
}

fn onOff(value: bool) []const u8 {
    return if (value) "on" else "off";
}

/// `on`/`off` for the two switches (`root add` and `root set`), accepting `1`/`0` and `true`/`false` for scripting.
fn parseFlagValue(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "on") or std.mem.eql(u8, text, "1") or std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "off") or std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "false")) return false;
    return null;
}

// SECTION: durations and output

/// `500ms`, `30s`, `10m`, `2h`, or a bare number of milliseconds. `0` means "never sleep".
pub fn parseDuration(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "0")) return 0;

    var multiplier: u64 = 1;
    var digits = trimmed;
    if (std.mem.endsWith(u8, trimmed, "ms")) {
        digits = trimmed[0 .. trimmed.len - 2];
    } else if (std.mem.endsWith(u8, trimmed, "s")) {
        multiplier = 1_000;
        digits = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "m")) {
        multiplier = 60_000;
        digits = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "h")) {
        multiplier = 3_600_000;
        digits = trimmed[0 .. trimmed.len - 1];
    }
    const amount = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, amount, multiplier) catch null;
}

/// `1024`, `64K`, `64M`, `1G` — a byte budget for `--max-bytes`.
pub fn parseBytes(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return null;
    var multiplier: u64 = 1;
    var digits = trimmed;
    switch (trimmed[trimmed.len - 1]) {
        'k', 'K' => {
            multiplier = 1024;
            digits = trimmed[0 .. trimmed.len - 1];
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            digits = trimmed[0 .. trimmed.len - 1];
        },
        'g', 'G' => {
            multiplier = 1024 * 1024 * 1024;
            digits = trimmed[0 .. trimmed.len - 1];
        },
        else => {},
    }
    const amount = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, amount, multiplier) catch null;
}

/// `0` is a setting, not a missing value: it is printed as "never" rather than as "0 ms".
pub fn formatDuration(milliseconds: u64, buffer: *[32]u8) []const u8 {
    if (milliseconds == 0) return "never";
    if (milliseconds % 3_600_000 == 0) return std.fmt.bufPrint(buffer, "{d}h", .{milliseconds / 3_600_000}) catch "?";
    if (milliseconds % 60_000 == 0) return std.fmt.bufPrint(buffer, "{d}m", .{milliseconds / 60_000}) catch "?";
    if (milliseconds % 1_000 == 0) return std.fmt.bufPrint(buffer, "{d}s", .{milliseconds / 1_000}) catch "?";
    return std.fmt.bufPrint(buffer, "{d}ms", .{milliseconds}) catch "?";
}

/// A byte count for a human: `512 B`, `1.5 KiB`, `4.0 MiB`. The exact number is in `--json`; this is the summary
/// line, so one decimal is enough and a second unit would imply a precision nobody reads.
pub fn formatBytes(bytes: u64, buffer: *[32]u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "?";
    const kib = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kib < 1024.0) return std.fmt.bufPrint(buffer, "{d:.1} KiB", .{kib}) catch "?";
    const mib = kib / 1024.0;
    if (mib < 1024.0) return std.fmt.bufPrint(buffer, "{d:.1} MiB", .{mib}) catch "?";
    return std.fmt.bufPrint(buffer, "{d:.1} GiB", .{mib / 1024.0}) catch "?";
}

fn print(io: std.Io, comptime format_text: []const u8, args: anytype) void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print(format_text, args) catch return;
    writer.writeByte('\n') catch return;
    std.Io.File.stdout().writeStreamingAll(io, writer.buffered()) catch {};
}

fn printError(io: std.Io, comptime format_text: []const u8, args: anytype) void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("fsmeta: ", .{}) catch return;
    writer.print(format_text, args) catch return;
    std.Io.File.stderr().writeStreamingAll(io, writer.buffered()) catch {};
}

fn fail(io: std.Io, comptime format_text: []const u8, args: anytype) noreturn {
    exitWith(io, control.Exit.failure, format_text, args);
}

/// A refusal: the CLI's exit code 4 (`FORMAT.daemon.md` § 6), for a command that declines by policy — a hook path
/// that would never run, a root whose `gitwatch` is off, a foreign hook without `--force`.
fn refuse(io: std.Io, comptime format_text: []const u8, args: anytype) noreturn {
    exitWith(io, control.Exit.refused, format_text, args);
}

fn exitWith(io: std.Io, code: u8, comptime format_text: []const u8, args: anytype) noreturn {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("fsmeta: ", .{}) catch {};
    writer.print(format_text, args) catch {};
    writer.writeByte('\n') catch {};
    std.Io.File.stderr().writeStreamingAll(io, writer.buffered()) catch {};
    std.process.exit(code);
}

fn exitNotRunning(io: std.Io, layout: paths.Layout) noreturn {
    printError(io, "the daemon is not running (no control socket under {s})\n", .{layout.base});
    std.process.exit(control.Exit.daemon_not_running);
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "a duration is parsed with its unit, and 0 means never" {
    try testing.expectEqual(@as(?u64, 0), parseDuration("0"));
    try testing.expectEqual(@as(?u64, 500), parseDuration("500ms"));
    try testing.expectEqual(@as(?u64, 30_000), parseDuration("30s"));
    try testing.expectEqual(@as(?u64, 600_000), parseDuration("10m"));
    try testing.expectEqual(@as(?u64, 7_200_000), parseDuration("2h"));
    try testing.expectEqual(@as(?u64, 300_000), parseDuration("300000"));

    try testing.expectEqual(@as(?u64, null), parseDuration(""));
    try testing.expectEqual(@as(?u64, null), parseDuration("soon"));
    try testing.expectEqual(@as(?u64, null), parseDuration("5x"));
    try testing.expectEqual(@as(?u64, null), parseDuration("-5s"));
}

test "a byte budget takes K, M and G suffixes" {
    try testing.expectEqual(@as(?u64, 1024), parseBytes("1024"));
    try testing.expectEqual(@as(?u64, 64 * 1024), parseBytes("64K"));
    try testing.expectEqual(@as(?u64, 64 * 1024 * 1024), parseBytes("64M"));
    try testing.expectEqual(@as(?u64, 2 * 1024 * 1024 * 1024), parseBytes("2G"));
    try testing.expectEqual(@as(?u64, null), parseBytes("lots"));
}

test "a switch takes on/off, and the CLI's spelling is converted to a boolean" {
    try testing.expectEqual(@as(?bool, true), parseFlagValue("on"));
    try testing.expectEqual(@as(?bool, false), parseFlagValue("off"));
    try testing.expectEqual(@as(?bool, true), parseFlagValue("1"));
    try testing.expectEqual(@as(?bool, false), parseFlagValue("0"));
    try testing.expectEqual(@as(?bool, true), parseFlagValue("true"));
    try testing.expectEqual(@as(?bool, false), parseFlagValue("false"));
    try testing.expectEqual(@as(?bool, null), parseFlagValue("maybe"));
    try testing.expectEqualStrings("on", onOff(true));
    try testing.expectEqualStrings("off", onOff(false));
}

test "a duration is printed in the largest whole unit, and never as zero" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("never", formatDuration(0, &buffer));
    try testing.expectEqualStrings("10m", formatDuration(600_000, &buffer));
    try testing.expectEqualStrings("30s", formatDuration(30_000, &buffer));
    try testing.expectEqualStrings("500ms", formatDuration(500, &buffer));
    try testing.expectEqualStrings("2h", formatDuration(7_200_000, &buffer));
}

test "a byte count is printed in the largest unit a human reads" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatBytes(0, &buffer));
    try testing.expectEqualStrings("512 B", formatBytes(512, &buffer));
    try testing.expectEqualStrings("1.5 KiB", formatBytes(1536, &buffer));
    try testing.expectEqualStrings("512.0 KiB", formatBytes(512 * 1024, &buffer));
    try testing.expectEqualStrings("4.0 MiB", formatBytes(4 * 1024 * 1024, &buffer));
    try testing.expectEqualStrings("2.0 GiB", formatBytes(2 * 1024 * 1024 * 1024, &buffer));
}

test "the CLI's exit codes are the daemon's table" {
    try testing.expectEqual(@as(u8, 0), control.Exit.fromCode(0));
    try testing.expectEqual(@as(u8, 2), control.Exit.fromCode(control.Exit.no_such_root));
    try testing.expectEqual(@as(u8, 3), control.Exit.fromCode(control.Exit.daemon_not_running));
    try testing.expectEqual(@as(u8, 4), control.Exit.fromCode(control.Exit.refused));
    try testing.expectEqual(@as(u8, 5), control.Exit.fromCode(control.Exit.protocol_mismatch));
}
