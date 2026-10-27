// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Git's hooks, installed on request (`plans/worktrees.md` § 5c, M5).
//!
//! The metadata watch is the baseline: it always works, and its grouping of a checkout is guessed from files that
//! happen to change together. The hooks are the precision upgrade — git tells us *which* ref moved, from and to what,
//! and whether an operation was prepared, committed or aborted — and they cost an explicit install, never a side effect
//! of `root add`.
//!
//! Four rules, and each exists because its absence breaks something:
//!
//! 1. **A hook must never fail git.** A non-zero `reference-transaction` hook *aborts the ref update*, so every
//!    generated script ends `exit 0` on every path (a `trap`, `|| true` on every write, and no `fsmeta` spawn that
//!    could fail). An install that turns a broken spool into a failed `git commit` would be worse than no hooks.
//! 2. **The spool is per repository, not per root:** `<common>/fsmeta-events.log`. The hook runs in whichever worktree
//!    git is operating on — possibly one fs-meta does not serve — so a per-root file would create `.fs-meta` there.
//!    The script finds the common dir and its own worktree with `git rev-parse` rather than an embedded path, so a
//!    moved or repaired repo keeps working; one call answers both, because every process a hook starts is paid on
//!    every git operation.
//! 3. **The line is JSON, one per line, with an epoch-seconds timestamp** from POSIX `date +%s` (`%3N` is not portable
//!    to the `sh` git bundles, and a spool is a mailbox, not a log). The worktree path and the arguments are escaped
//!    for `\` and `"` with `sed` — only when one of those characters is actually present, which a path git printed is
//!    not; a path with a newline is not representable in a line-based mailbox (and is not a case worth representing —
//!    the managed ignore block refuses one for the same reason).
//! 4. **The spool is bounded by the hook**, not only by the daemon: a repo can go months without a daemon, and an
//!    unbounded file inside `.git` is not acceptable. The script truncates at the cap before appending.
//!
//! This module is the file half — generate, install, uninstall, report, and parse the spool. It runs no git and does
//! not need a daemon: `install` resolves the git dirs from the path it is given, which is what makes it usable before
//! the first start. The daemon's spool *reader* is `daemon/root.zig` (`readHookSpoolLocked`).

const std = @import("std");
const builtin = @import("builtin");
const gitdir = @import("../gitdir.zig");
const wire = @import("../wire.zig");

/// The hooks that carry a signal worth a per-operation spawn. `reference-transaction` is the backbone: it sees `HEAD`
/// as a symref update (the M4 spike), so a branch switch is a ref transaction after all.
pub const hook_names = [_][]const u8{
    "reference-transaction",
    "post-checkout",
    "post-merge",
    "post-rewrite",
    "post-index-change",
    "post-commit",
};

/// Every generated file starts with this line, so `uninstall` and a user edit can be told apart (`# fsmeta-managed`).
pub const marker = "# fsmeta-managed";

/// The spool's name inside the common dir (§ 5c).
pub const spool_name = "fsmeta-events.log";

/// The cap the hook itself enforces before appending: a few hundred lines, not a log to keep.
pub const spool_cap: usize = 64 * 1024;

/// What `status` says about one hook file.
pub const HookState = enum {
    absent,
    ours,
    /// A hook exists and is not ours: `install` refuses it unless `--force` chains it.
    foreign,
    /// Ours, with the original kept beside it as `<name>.fsmeta-orig`.
    chained,
};

/// One absent state per hook, built with a loop rather than the array-repeat operator.
fn emptyHookStates() [hook_names.len]HookState {
    var states: [hook_names.len]HookState = undefined;
    for (&states) |*slot| slot.* = .absent;
    return states;
}

pub const Status = struct {
    common_dir: []const u8,
    hooks: [hook_names.len]HookState,
    /// The spool's size in bytes, or 0 when it does not exist. A mailbox nobody has read is visible here.
    spool_bytes: u64,
    spool_path: []const u8,
};

pub const InstallError = error{
    /// A hook exists and is not ours, and `--force` was not given. The message names the file.
    HookExists,
    /// The repository has no readable `.git`, so there is nowhere to install.
    NotARepository,
};

pub const InstallSummary = struct {
    common_dir: []const u8,
    hooks_dir: []const u8,
    installed: u32 = 0,
    chained: u32 = 0,
};

pub const UninstallSummary = struct {
    removed: u32 = 0,
    restored: u32 = 0,
};

/// `<common>/hooks` and `<common>/fsmeta-events.log` for a repository root. `NotARepository` when there is no
/// readable `.git` (the caller reports the path it was given).
pub fn locate(arena: std.mem.Allocator, io: std.Io, repo_root: []const u8) (InstallError || std.mem.Allocator.Error)!struct { common: []const u8, hooks: []const u8, spool: []const u8 } {
    const location = (gitdir.resolve(arena, io, repo_root) catch return error.NotARepository) orelse return error.NotARepository;
    return .{
        .common = location.common_dir,
        .hooks = try std.fs.path.join(arena, &.{ location.common_dir, "hooks" }),
        .spool = try std.fs.path.join(arena, &.{ location.common_dir, spool_name }),
    };
}

/// The generated hook, as bytes: POSIX `sh`, **LF only** (a CRLF script fails under git's bundled `sh` with
/// `\r: not found`), and `exit 0` on every path.
///
/// `orig` is the chained original's name when `--force` moved one aside, or `""` for a plain hook.
///
/// ## Why the body is shaped the way it is
///
/// A hook fires per git operation, so every process it starts is paid by the user: on this Windows host each spawn of
/// git's bundled `sh` or of an msys utility costs 25–50 ms, and a checkout fires the `reference-transaction` hook once
/// per phase per ref transaction. The body therefore (a) exits **before any work** on `preparing`, a notification
/// phase (git ≥ 2.44) that carries nothing this daemon reads; (b) asks git for the common dir *and* the worktree in
/// **one** `rev-parse` (two calls cost twice, and the two-line answer is split with `IFS`, not with another process);
/// (c) runs `sed` only when a `"` or a `\` is actually present, which a git-printed path ordinarily has not; and
/// (d) runs a chained original first, with `"$@"` untouched, because ours reshapes the positional parameters to split
/// the two-line answer. Measured effect on a one-file checkout: ~3.3 s with the plain body, ~1.3 s with this one
/// (a hook-less checkout is ~33 ms); the cost is interpreted-shell spawning, not the spool write.
pub fn script(arena: std.mem.Allocator, hook: []const u8, orig: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("#!/bin/sh\n");
    try writer.print("{s}: {s} — append one JSON line to this repository's fsmeta spool and exit 0. Do not edit;\n", .{ marker, hook });
    try writer.writeAll("# `fsmeta daemon hooks uninstall` removes it. A non-zero hook would abort a git operation.\n");
    try writer.writeAll("trap 'exit 0' EXIT HUP INT TERM\n");
    if (std.mem.eql(u8, hook, "reference-transaction")) {
        // `<prepared|committed|aborted>` on the argument, ref updates on stdin. Our own line takes the phase from
        // `$1`; the daemon maps it to start/finish/aborted. `preparing` is git's notification phase and is not read,
        // so it leaves before spending a process on it.
        try writer.writeAll("phase=\"$1\"\n");
        try writer.writeAll("case \"$phase\" in prepared|committed|aborted) ;; *) exit 0 ;; esac\n");
    } else {
        try writer.writeAll("phase=finish\n");
    }
    if (orig.len > 0) {
        // Chaining first: the user's hook runs with the arguments git gave it, before ours reshapes `$@` to split the
        // two-line `rev-parse` answer. `|| true`, because a failing user hook must not abort a git operation either.
        try writer.print("d=$(dirname \"$0\")\nif [ -x \"$d/{s}\" ]; then \"$d/{s}\" \"$@\" || true; fi\n", .{ orig, orig });
    }
    try writer.writeAll("hookargs=\"$*\"\n");
    // One `rev-parse` for both paths; `--path-format=absolute` needs git 2.31, so a failure falls back to the two-call
    // form (and to resolving a relative common dir against the worktree, which is what git itself prints).
    try writer.writeAll("paths=$(git rev-parse --path-format=absolute --git-common-dir --show-toplevel 2>/dev/null || true)\n");
    try writer.writeAll("common=\nworktree=\n");
    try writer.writeAll("if [ -n \"$paths\" ]; then\n");
    try writer.writeAll("  ifs='\n'\n  IFS=$ifs\n  set -- $paths\n  unset IFS\n  common=$1\n  worktree=${2:-$1}\nfi\n");
    try writer.writeAll("if [ -z \"$common\" ]; then\n");
    try writer.writeAll("  worktree=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n");
    try writer.writeAll("  common=$(git rev-parse --git-common-dir 2>/dev/null || echo .git)\n");
    try writer.writeAll("  case \"$common\" in /*) ;; *) common=\"$worktree/$common\" ;; esac\n");
    try writer.writeAll("fi\n");
    try writer.print("spool=\"$common/{s}\"\n", .{spool_name});
    // The cap is checked *before* appending, by the hook itself: a repo can go without a daemon for months.
    try writer.writeAll("if [ -f \"$spool\" ] && [ \"$(wc -c < \"$spool\" 2>/dev/null || echo 0)\" -gt ");
    try writer.print("{d} ]; then : > \"$spool\" 2>/dev/null || true; fi\n", .{spool_cap});
    try writer.writeAll("at=$(date +%s 2>/dev/null || echo 0)\n");
    try writer.writeAll("esc() { printf '%s' \"$1\" | sed -e 's/\\\\/\\\\\\\\/g' -e 's/\"/\\\\\"/g' 2>/dev/null || printf '%s' \"$1\"; }\n");
    // Escaping costs two `sed` processes; a git-printed path has neither character, so the common case skips them.
    try writer.writeAll("case \"$worktree$hookargs\" in\n");
    try writer.writeAll("  *'\"'* | *\\\\*) wf=$(esc \"$worktree\") ; af=$(esc \"$hookargs\") ;;\n");
    try writer.writeAll("  *) wf=$worktree ; af=$hookargs ;;\n");
    try writer.writeAll("esac\n");
    try writer.print("printf '{{\"at\":%s,\"hook\":\"{s}\",\"phase\":\"%s\",\"worktree\":\"%s\",\"args\":\"%s\"}}\\n' \"$at\" \"$phase\" \"$wf\" \"$af\" >> \"$spool\" 2>/dev/null || true\n", .{hook});
    try writer.writeAll("exit 0\n");
    return out.toOwnedSlice();
}

fn openHooksDir(io: std.Io, arena: std.mem.Allocator, common: []const u8, create: bool) !std.Io.Dir {
    if (create) try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ common, "hooks" }));
    const hooks = try std.fs.path.join(arena, &.{ common, "hooks" });
    return std.Io.Dir.openDirAbsolute(io, hooks, .{ .iterate = true });
}

fn readHook(io: std.Io, arena: std.mem.Allocator, hooks: std.Io.Dir, name: []const u8) ?[]const u8 {
    return hooks.readFileAlloc(io, name, arena, .limited(1 << 20)) catch null;
}

fn isOurs(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, marker) != null;
}

/// Install the set for the repository containing `repo_root`.
///
/// A hook that exists and is not ours is **never overwritten**: without `force` the call fails with `HookExists` (the
/// CLI prints the path), and with it the original is renamed to `<name>.fsmeta-orig` and a chaining wrapper is written.
/// Every write goes through a temporary in the same directory and a rename, so a crash cannot leave a half-written hook
/// that git would then fail to run.
pub fn install(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8, force: bool) (InstallError || anyerror)!InstallSummary {
    const place = try locate(arena, io, repo_root);
    var hooks = openHooksDir(io, arena, place.common, true) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.NotARepository,
        else => return err,
    };
    defer hooks.close(io);

    var summary = InstallSummary{ .common_dir = place.common, .hooks_dir = place.hooks };
    for (hook_names) |hook| {
        const existing = readHook(io, arena, hooks, hook);
        var orig: []const u8 = "";
        if (existing) |bytes| {
            if (!isOurs(bytes)) {
                if (!force) return error.HookExists;
                orig = try std.fmt.allocPrint(arena, "{s}.fsmeta-orig", .{hook});
                const backup = try std.fs.path.join(arena, &.{ place.hooks, orig });
                std.Io.Dir.deleteFileAbsolute(io, backup) catch {};
                try std.Io.Dir.rename(hooks, hook, hooks, orig, io);
                summary.chained += 1;
            } else if (std.mem.indexOf(u8, bytes, ".fsmeta-orig") != null) {
                // Already a chaining wrapper: keep the chain, and regenerate the body around it.
                orig = try std.fmt.allocPrint(arena, "{s}.fsmeta-orig", .{hook});
            }
        }
        try writeHook(io, arena, hooks, hook, orig);
        summary.installed += 1;
    }
    return summary;
}

/// Write one hook atomically: a temporary beside it, then a rename over it.
fn writeHook(io: std.Io, arena: std.mem.Allocator, hooks: std.Io.Dir, hook: []const u8, orig: []const u8) !void {
    const bytes = try script(arena, hook, orig);
    const temporary = try std.fmt.allocPrint(arena, ".{s}.fsmeta-tmp", .{hook});
    defer hooks.deleteFile(io, temporary) catch {};
    try hooks.writeFile(io, .{ .sub_path = temporary, .data = bytes });
    // The executable bit matters on POSIX (git refuses to run a hook without it); Windows has no such bit.
    if (builtin.os.tag != .windows) {
        var file = try hooks.openFile(io, temporary, .{ .mode = .read_write });
        defer file.close(io);
        try file.setPermissions(io, 0o755);
    }
    try std.Io.Dir.rename(hooks, temporary, hooks, hook, io);
}

/// Remove our hooks, restoring a chained original over its wrapper. A file that is not ours is left alone.
pub fn uninstall(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8) (InstallError || anyerror)!UninstallSummary {
    const place = try locate(arena, io, repo_root);
    var hooks = openHooksDir(io, arena, place.common, false) catch return UninstallSummary{};
    defer hooks.close(io);

    var summary = UninstallSummary{};
    for (hook_names) |hook| {
        const existing = readHook(io, arena, hooks, hook) orelse continue;
        if (!isOurs(existing)) continue;
        const backup = try std.fmt.allocPrint(arena, "{s}.fsmeta-orig", .{hook});
        if (readHook(io, arena, hooks, backup) != null) {
            hooks.deleteFile(io, hook) catch {};
            try std.Io.Dir.rename(hooks, backup, hooks, hook, io);
            summary.restored += 1;
        } else {
            hooks.deleteFile(io, hook) catch {};
            summary.removed += 1;
        }
    }
    return summary;
}

/// What is installed for the repository containing `repo_root`, and how big the spool is. `null` when the path is not
/// a repository (the CLI reports that rather than inventing an answer).
pub fn status(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8) !?Status {
    const place = locate(arena, io, repo_root) catch |err| switch (err) {
        error.NotARepository => return null,
        else => return err,
    };
    var result = Status{
        .common_dir = place.common,
        .hooks = emptyHookStates(),
        .spool_bytes = 0,
        .spool_path = place.spool,
    };
    if (openHooksDir(io, arena, place.common, false)) |hooks_dir| {
        var hooks = hooks_dir;
        defer hooks.close(io);
        for (hook_names, 0..) |hook, index| {
            const bytes = readHook(io, arena, hooks, hook) orelse continue;
            if (!isOurs(bytes)) {
                result.hooks[index] = .foreign;
                continue;
            }
            const backup = try std.fmt.allocPrint(arena, "{s}.fsmeta-orig", .{hook});
            result.hooks[index] = if (readHook(io, arena, hooks, backup) != null) .chained else .ours;
        }
    } else |_| {}
    if (std.Io.Dir.openFileAbsolute(io, place.spool, .{})) |file| {
        defer file.close(io);
        if (file.stat(io)) |stat| result.spool_bytes = stat.size else |_| {}
    } else |_| {}
    return result;
}

// --------------------------------------------------------------------------------------------- what install checks

/// The one config key that makes our install silent (`plans/worktrees.md` § 5c): with `core.hooksPath` set, git never
/// looks in `<common>/hooks`, so installing there would be a hook that never runs — a trap dressed as a feature.
pub const hooks_path_key = "core.hooksPath";

/// `core.hooksPath` for the repository containing `repo_root`, or `null` when it is not set (or cannot be known).
///
/// Git itself is asked first, because it is the only reader that honours `include.path`, the global and system files
/// and the config syntax. A host without `git` on `PATH` falls back to reading `<common>/config` — the file a
/// repository-local `hooksPath` lives in — because `install` must work without git (it is a file operation), and a
/// local setting is the case worth refusing. A *global* setting on a host with no git is not detectable here, which is
/// stated in `FORMAT.daemon.md` § 6 rather than guessed at.
pub fn hooksPath(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8, common: []const u8) ?[]const u8 {
    if (hooksPathFromGit(io, arena, repo_root)) |value| return if (value.len > 0) value else null;
    return hooksPathFromConfig(io, arena, common);
}

fn hooksPathFromGit(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "git", "-C", repo_root, "config", "--get", hooks_path_key },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null; // no git: the repository's own config is the fallback
    const code = switch (result.term) {
        .exited => |value| value,
        else => return null,
    };
    if (code != 0) return null; // `git config --get` exits 1 for an unset key, and that is "not set"
    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    return arena.dupe(u8, text) catch null;
}

/// `<common>/config`'s `[core] hooksPath`, best effort. Used when git cannot be run; the last value wins, as in git.
fn hooksPathFromConfig(io: std.Io, arena: std.mem.Allocator, common: []const u8) ?[]const u8 {
    const path = std.fs.path.join(arena, &.{ common, "config" }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    var found: ?[]const u8 = null;
    var in_core = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const section = std.mem.trim(u8, line[1..close], " \t");
            in_core = std.ascii.eqlIgnoreCase(section, "core");
            continue;
        }
        if (!in_core) continue;
        const equals = std.mem.indexOfAny(u8, line, "=") orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "hooksPath")) continue;
        const value = unquote(std.mem.trim(u8, line[equals + 1 ..], " \t"));
        found = arena.dupe(u8, value) catch found;
    }
    if (found) |value| return if (value.len > 0) value else null;
    return null;
}

/// Git's config quoting, for the one value the fallback reads: a double-quoted string may carry escapes, and an
/// unquoted one ends at the first comment character.
fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"') {
        const close = std.mem.lastIndexOfScalar(u8, value, '"') orelse return value[1..];
        if (close == 0) return "";
        return value[1..close];
    }
    const comment = std.mem.indexOfAny(u8, value, "#;") orelse return value;
    return std.mem.trimEnd(u8, value[0..comment], " \t");
}

/// Prove that `<common>/hooks` can be written to before writing anything into it. The check is a real write (a probe
/// file created and removed), because that is what `install` does: a read-only `<common>` or a `hooks` path that is
/// not a directory must be reported with its path at install time, not discovered as a hook git cannot run.
pub fn checkWritable(io: std.Io, arena: std.mem.Allocator, common: []const u8) !void {
    const hooks = try std.fs.path.join(arena, &.{ common, "hooks" });
    try std.Io.Dir.cwd().createDirPath(io, hooks);
    var dir = try std.Io.Dir.openDirAbsolute(io, hooks, .{});
    defer dir.close(io);
    const probe = ".fsmeta-write-test";
    try dir.writeFile(io, .{ .sub_path = probe, .data = "" });
    dir.deleteFile(io, probe) catch {};
}

// --------------------------------------------------------------------------------------------- what a line means

/// A spool line's meaning on the wire (`plans/worktrees.md` § 5c): the kind of operation and the phase of the event.
pub const Signal = struct {
    kind: wire.GitKind,
    /// `.start` for `prepared`, `.finish` for `committed` (and for every other hook, which fires at the end), and
    /// `.aborted` for `aborted`.
    phase: wire.GitPhase,
};

/// Map one line to an event, or `null` for a line that carries no signal (an unknown hook, an unknown phase, a hook
/// whose arguments the spool did not record).
///
/// `reference-transaction` is the start/finish pair: its line carries the phase on the argument and the ref names only
/// on stdin, which the generator deliberately does not consume (reading stdin from a hook is the one thing that can
/// block git). Its kind is therefore `other`: a ref transaction whose refs the spool does not name is reported as what
/// it is, not guessed at as a commit. The hooks that are specific about what happened (`post-checkout`, `post-merge`,
/// `post-rewrite`, `post-index-change`, `post-commit`) supply the kind, and `post-checkout`'s flag is the
/// `branch`/`checkout` split § 5d defines.
pub fn signalOf(line: Line) ?Signal {
    if (std.mem.eql(u8, line.hook, "reference-transaction")) {
        if (std.mem.eql(u8, line.phase, "prepared")) return .{ .kind = .other, .phase = .start };
        if (std.mem.eql(u8, line.phase, "committed")) return .{ .kind = .other, .phase = .finish };
        if (std.mem.eql(u8, line.phase, "aborted")) return .{ .kind = .other, .phase = .aborted };
        return null;
    }
    // Every other generated hook writes `phase = finish`; a line that says anything else is not ours to interpret.
    if (!std.mem.eql(u8, line.phase, "finish")) return null;
    if (std.mem.eql(u8, line.hook, "post-checkout")) {
        return .{ .kind = if (checkoutFlag(line.args) == 0) .checkout else .branch, .phase = .finish };
    }
    if (std.mem.eql(u8, line.hook, "post-merge")) return .{ .kind = .merge, .phase = .finish };
    if (std.mem.eql(u8, line.hook, "post-rewrite")) {
        const rebase = std.mem.startsWith(u8, std.mem.trim(u8, line.args, " \t"), "rebase");
        return .{ .kind = if (rebase) .rebase else .other, .phase = .finish };
    }
    if (std.mem.eql(u8, line.hook, "post-index-change")) return .{ .kind = .index, .phase = .finish };
    if (std.mem.eql(u8, line.hook, "post-commit")) return .{ .kind = .commit, .phase = .finish };
    return null;
}

/// `post-checkout`'s third argument: `1` = a branch checkout, `0` = a file checkout. A line that lost the argument is
/// read as a file checkout, because that is the weaker claim: it says "files were checked out", not "the branch moved".
fn checkoutFlag(args: []const u8) u8 {
    var fields = std.mem.tokenizeAny(u8, args, " \t");
    var last: []const u8 = "";
    while (fields.next()) |field| last = field;
    if (std.mem.eql(u8, last, "1")) return 1;
    return 0;
}

// --------------------------------------------------------------------------------------------- the spool

/// How many lines one read of the spool accepts. A mailbox that has grown past this has not been read for a long time
/// (or was written by something else); the reader drops it and starts again, because replaying a year of git history
/// as live events is worse than losing it — the batch a consumer missed is still readable.
pub const spool_max_lines = 512;

/// One line of `<common>/fsmeta-events.log`, as the hook wrote it.
pub const Line = struct {
    at: i64,
    hook: []const u8,
    phase: []const u8,
    worktree: []const u8,
    args: []const u8,
};

/// Parse one line. `null` for a blank line, a malformed one, or a line missing a field: a spool is a mailbox, and a
/// torn line is dropped (logged once by the reader) rather than turned into an error that stops the daemon.
pub fn parseLine(arena: std.mem.Allocator, line: []const u8) ?Line {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, arena, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const at_value = object.get("at") orelse return null;
    if (at_value != .integer or at_value.integer < 0) return null;
    const hook = stringField(object, "hook") orelse return null;
    const phase = stringField(object, "phase") orelse return null;
    return .{
        .at = @intCast(at_value.integer),
        .hook = arena.dupe(u8, hook) catch return null,
        .phase = arena.dupe(u8, phase) catch return null,
        .worktree = arena.dupe(u8, stringField(object, "worktree") orelse "") catch return null,
        .args = arena.dupe(u8, stringField(object, "args") orelse "") catch return null,
    };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

/// One read of the spool from `offset` to its end, and the offset to resume from. A file that shrank (the hook's own
/// truncate, or a rotation) is read from the start rather than from a stale offset.
pub const Read = struct {
    lines: []const []const u8,
    offset: u64,
};

pub fn readNew(io: std.Io, arena: std.mem.Allocator, spool_path: []const u8, offset: u64, cap: usize) !Read {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, spool_path, arena, .limited(spool_cap * 4)) catch
        return .{ .lines = &.{}, .offset = offset };
    const from: usize = if (bytes.len < offset) 0 else @intCast(offset);
    if (from >= bytes.len) return .{ .lines = &.{}, .offset = @intCast(bytes.len) };
    const text = bytes[from..];
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    var consumed: usize = 0;
    var cursor: usize = 0;
    // Only complete lines are consumed; a torn tail (the hook is mid-write) is left for the next read.
    while (cursor < text.len) : (cursor += 1) {
        if (text[cursor] != '\n') continue;
        const line = text[start..cursor];
        start = cursor + 1;
        consumed = start;
        if (lines.items.len >= cap) return error.SpoolBacklog;
        lines.append(arena, line) catch break;
    }
    return .{ .lines = lines.items, .offset = @intCast(from + consumed) };
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn scratchRoot(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try dir.realPath(io, &buffer);
    return arena.dupe(u8, buffer[0..count]);
}

test "the generated hook is POSIX sh, LF, marker-carrying and exits 0 on every path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (hook_names) |hook| {
        const bytes = try script(arena, hook, "");
        try testing.expect(std.mem.startsWith(u8, bytes, "#!/bin/sh\n"));
        try testing.expect(std.mem.indexOf(u8, bytes, marker) != null);
        try testing.expect(std.mem.endsWith(u8, bytes, "exit 0\n"));
        try testing.expect(std.mem.indexOf(u8, bytes, "trap 'exit 0'") != null);
        // The bytes matter: a CRLF script fails under git's bundled sh with `\r: not found`.
        try testing.expect(std.mem.indexOfScalar(u8, bytes, '\r') == null);
        // The spool is found with git, not embedded, so a moved repository keeps working.
        try testing.expect(std.mem.indexOf(u8, bytes, "--git-common-dir") != null);
        try testing.expect(std.mem.indexOf(u8, bytes, spool_name) != null);
        try testing.expect(std.mem.indexOf(u8, bytes, "|| true") != null);
    }
    // `reference-transaction` carries the phase on its argument and leaves without work on `preparing`; the others
    // finish straight away.
    const reference = try script(arena, "reference-transaction", "");
    try testing.expect(std.mem.indexOf(u8, reference, "phase=\"$1\"") != null);
    try testing.expect(std.mem.indexOf(u8, reference, "case \"$phase\" in prepared|committed|aborted) ;; *) exit 0 ;; esac") != null);
    try testing.expect(std.mem.indexOf(u8, try script(arena, "post-checkout", ""), "phase=\"$1\"") == null);
    // One `rev-parse` answers both paths: a hook fires per ref transaction, and each extra process is paid on every
    // git operation (the reason this body is shaped the way it is).
    try testing.expect(std.mem.indexOf(u8, reference, "git rev-parse --path-format=absolute --git-common-dir --show-toplevel") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, reference, "rev-parse --path-format=absolute"));
    // Escaping is conditional: the plain path must not spawn `sed` twice per hook.
    try testing.expect(std.mem.indexOf(u8, reference, "  *) wf=$worktree ; af=$hookargs ;;") != null);
    // A chained hook runs the original with the same arguments.
    const chained = try script(arena, "post-checkout", "post-checkout.fsmeta-orig");
    try testing.expect(std.mem.indexOf(u8, chained, "post-checkout.fsmeta-orig") != null);
    try testing.expect(std.mem.indexOf(u8, chained, "\"$d/post-checkout.fsmeta-orig\" \"$@\" || true") != null);
}

test "install writes the set, refuses a foreign hook, and --force chains it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A repository enough for `gitdir.resolve`: `.git` with `objects/` (the § 4 confirmation the daemon uses).
    try tmp.dir.createDirPath(io, "repo/.git/objects");
    try tmp.dir.createDirPath(io, "repo/.git/hooks");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    const root = try std.fs.path.join(arena, &.{ try scratchRoot(arena, io, tmp.dir), "repo" });

    const first = try install(io, arena, root, false);
    try testing.expectEqual(@as(u32, hook_names.len), first.installed);
    try testing.expectEqual(@as(u32, 0), first.chained);
    const installed = (try status(io, arena, root)).?;
    for (installed.hooks) |state| try testing.expectEqual(HookState.ours, state);
    try testing.expectEqual(@as(u64, 0), installed.spool_bytes);

    // Idempotent: installing again rewrites our own files and does not chain them.
    const again = try install(io, arena, root, false);
    try testing.expectEqual(@as(u32, 0), again.chained);

    // A user hook is refused, and the file is untouched.
    const hooks_path = try std.fs.path.join(arena, &.{ root, ".git", "hooks" });
    var hooks = try std.Io.Dir.openDirAbsolute(io, hooks_path, .{});
    defer hooks.close(io);
    try hooks.writeFile(io, .{ .sub_path = "post-checkout", .data = "#!/bin/sh\necho mine\n" });
    try testing.expectError(error.HookExists, install(io, arena, root, false));
    try testing.expectEqualStrings("#!/bin/sh\necho mine\n", (try hooks.readFileAlloc(io, "post-checkout", arena, .limited(4096))));

    // With --force the original is kept beside it and the wrapper chains it.
    const forced = try install(io, arena, root, true);
    try testing.expectEqual(@as(u32, 1), forced.chained);
    const own = try hooks.readFileAlloc(io, "post-checkout", arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, own, marker) != null);
    try testing.expect(std.mem.indexOf(u8, own, "post-checkout.fsmeta-orig") != null);
    const original = try hooks.readFileAlloc(io, "post-checkout.fsmeta-orig", arena, .limited(4096));
    try testing.expectEqualStrings("#!/bin/sh\necho mine\n", original);
    try testing.expectEqual(HookState.chained, (try status(io, arena, root)).?.hooks[1]);

    // Uninstall restores the original byte-for-byte and removes our files.
    const removed = try uninstall(io, arena, root);
    try testing.expectEqual(@as(u32, 1), removed.restored);
    try testing.expectEqual(@as(u32, hook_names.len - 1), removed.removed);
    const restored = try hooks.readFileAlloc(io, "post-checkout", arena, .limited(4096));
    try testing.expectEqualStrings("#!/bin/sh\necho mine\n", restored);
    try testing.expectError(error.FileNotFound, hooks.readFileAlloc(io, "reference-transaction", arena, .limited(4096)));

    // A path that is not a repository is a refusal, not an empty answer.
    try testing.expectError(error.NotARepository, install(io, arena, try scratchRoot(arena, io, tmp.dir), false));
    try testing.expectEqual(@as(?Status, null), try status(io, arena, try scratchRoot(arena, io, tmp.dir)));
}

test "a spool line round-trips, and a malformed line is dropped rather than raising" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = parseLine(arena, "{\"at\":1793000000,\"hook\":\"post-checkout\",\"phase\":\"finish\",\"worktree\":\"/w/tree with \\\"quote\\\"\",\"args\":\"old new 1\"}").?;
    try testing.expectEqual(@as(i64, 1_793_000_000), line.at);
    try testing.expectEqualStrings("post-checkout", line.hook);
    try testing.expectEqualStrings("finish", line.phase);
    try testing.expectEqualStrings("/w/tree with \"quote\"", line.worktree);
    try testing.expectEqualStrings("old new 1", line.args);

    try testing.expectEqual(@as(?Line, null), parseLine(arena, ""));
    try testing.expectEqual(@as(?Line, null), parseLine(arena, "not json"));
    try testing.expectEqual(@as(?Line, null), parseLine(arena, "{\"at\":1,\"hook\":\"post-commit\"}"));
    try testing.expectEqual(@as(?Line, null), parseLine(arena, "{\"at\":-1,\"hook\":\"post-commit\",\"phase\":\"finish\"}"));
}

test "the spool is read in complete lines from an offset, and a shrunken file restarts at zero" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try scratchRoot(arena, io, tmp.dir);
    const spool = try std.fmt.allocPrint(arena, "{s}{c}spool", .{ base, std.fs.path.sep });

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spool, .data = "one\ntwo\nthree\n" });
    const whole = try readNew(io, arena, spool, 0, 100);
    try testing.expectEqual(@as(usize, 3), whole.lines.len);
    try testing.expectEqualStrings("two", whole.lines[1]);
    try testing.expectEqual(@as(u64, 14), whole.offset);

    // A torn tail is not consumed until its newline arrives.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spool, .data = "one\ntwo\nthree\nfour" });
    const torn = try readNew(io, arena, spool, whole.offset, 100);
    try testing.expectEqual(@as(usize, 0), torn.lines.len);
    try testing.expectEqual(@as(u64, 14), torn.offset);

    // A file that shrank (the hook's cap truncate) is read from the start.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = spool, .data = "fresh\n" });
    const restart = try readNew(io, arena, spool, 14, 100);
    try testing.expectEqual(@as(usize, 1), restart.lines.len);
    try testing.expectEqualStrings("fresh", restart.lines[0]);
    try testing.expectEqual(@as(u64, 6), restart.offset);

    // No spool (a repo with no hooks installed) is an empty read, not an error.
    const missing = try readNew(io, arena, try std.fmt.allocPrint(arena, "{s}{c}nope", .{ base, std.fs.path.sep }), 0, 100);
    try testing.expectEqual(@as(usize, 0), missing.lines.len);
}

test "a spool line maps to the wire's kind and phase, and one that carries none is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mapped = struct {
        fn of(a: std.mem.Allocator, hook: []const u8, phase: []const u8, args: []const u8) ?Signal {
            const text = std.fmt.allocPrint(a, "{{\"at\":1,\"hook\":\"{s}\",\"phase\":\"{s}\",\"args\":\"{s}\"}}", .{ hook, phase, args }) catch return null;
            return signalOf(parseLine(a, text) orelse return null);
        }
    };

    // `reference-transaction` is the start/finish pair, and the phase comes from its argument.
    const prepared = mapped.of(arena, "reference-transaction", "prepared", "prepared").?;
    try testing.expectEqual(wire.GitPhase.start, prepared.phase);
    try testing.expectEqual(wire.GitKind.other, prepared.kind);
    try testing.expectEqual(wire.GitPhase.finish, mapped.of(arena, "reference-transaction", "committed", "committed").?.phase);
    try testing.expectEqual(wire.GitPhase.aborted, mapped.of(arena, "reference-transaction", "aborted", "aborted").?.phase);
    // A phase the generated script never writes is not guessed at.
    try testing.expectEqual(@as(?Signal, null), mapped.of(arena, "reference-transaction", "finished", "x"));

    // `post-checkout`'s flag is the branch/checkout split; a line that lost its arguments claims the weaker one.
    try testing.expectEqual(wire.GitKind.branch, mapped.of(arena, "post-checkout", "finish", "old new 1").?.kind);
    try testing.expectEqual(wire.GitKind.checkout, mapped.of(arena, "post-checkout", "finish", "old new 0").?.kind);
    try testing.expectEqual(wire.GitKind.checkout, mapped.of(arena, "post-checkout", "finish", "").?.kind);
    try testing.expectEqual(wire.GitKind.branch, mapped.of(arena, "post-checkout", "finish", "only one argument 1").?.kind);

    // The specific hooks supply their own kind.
    try testing.expectEqual(wire.GitKind.merge, mapped.of(arena, "post-merge", "finish", "0").?.kind);
    try testing.expectEqual(wire.GitKind.rebase, mapped.of(arena, "post-rewrite", "finish", "rebase").?.kind);
    try testing.expectEqual(wire.GitKind.other, mapped.of(arena, "post-rewrite", "finish", "amend").?.kind);
    try testing.expectEqual(wire.GitKind.index, mapped.of(arena, "post-index-change", "finish", "1 1").?.kind);
    try testing.expectEqual(wire.GitKind.commit, mapped.of(arena, "post-commit", "finish", "").?.kind);

    // An unknown hook, or a hook claiming a phase its script never writes, is not an event.
    try testing.expectEqual(@as(?Signal, null), mapped.of(arena, "pre-receive", "finish", ""));
    try testing.expectEqual(@as(?Signal, null), mapped.of(arena, "post-commit", "prepared", ""));
}

test "core.hooksPath is read from the repository's config when git is not asked, and a hooks path that cannot be written is an error" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, "repo/.git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    const root = try std.fs.path.join(arena, &.{ try scratchRoot(arena, io, tmp.dir), "repo" });
    const common = try std.fs.path.join(arena, &.{ root, ".git" });

    // No config: no value, and the default hooks directory is writable (install creates it).
    try testing.expectEqual(@as(?[]const u8, null), hooksPath(io, arena, root, common));
    try checkWritable(io, arena, common);

    // Our own line, in git's own spelling: section, key case, quotes and a trailing comment.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/config", .data = "[core]\n\tbare = false\n[CORE]\n\thooksPath = \".my hooks\"  # ours\n" });
    try testing.expectEqualStrings(".my hooks", hooksPath(io, arena, root, common).?);
    // A value in another section does not count, and the last value wins.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/config", .data = "[user]\n\thooksPath = nope\n[core]\n\thooksPath = first\n\thooksPath = second\n" });
    try testing.expectEqualStrings("second", hooksPath(io, arena, root, common).?);

    // A `hooks` path that is a file cannot be written: the refusal says which path, which is the whole point. This is
    // the portable stand-in for a read-only `.git`, which Windows does not express with a directory attribute.
    try tmp.dir.deleteDir(io, "repo/.git/hooks");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/hooks", .data = "not a directory\n" });
    if (checkWritable(io, arena, common)) |_| {
        return error.ExpectedWriteRefusal;
    } else |_| {}
}

