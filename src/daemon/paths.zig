// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Where the daemon keeps things.
//!
//! Two directories, and the difference matters:
//!
//! - the **runtime** directory (`<base>`) holds sockets, the daemon's pid file, the per-root claim files and
//!   the per-root logs. It is ephemeral — a tmpfs at `$XDG_RUNTIME_DIR`, cleared at logout — and losing it is
//!   normal. Everything in it is rebuilt on the next start;
//! - the **home** directory holds `roots.json`, the durable list of roots and their configuration. It is
//!   configuration, committed by a person through `fsmeta root add`, and it survives a reboot, a crashed
//!   daemon and an empty runtime directory.
//!
//! `<id>` is derived, not random: the low 32 bits of `wyhash(canonical root path)` as eight lowercase hex
//! digits. The same root therefore gets the same id across restarts and across daemons, and the socket name
//! is thirteen characters — `a1b2c3d4.sock` — because an AF_UNIX path is limited to about 104 bytes on
//! POSIX and a hash is the only way to stay short for a deeply nested root. The record beside it carries the
//! root path, which is what makes the short name resolvable; that record is host state, and the trio still
//! never contains an absolute path.
//!
//! Tests: id stability, id distinctness, the socket name's length bound, and base/config resolution per
//! platform from an injected environment.

const std = @import("std");
const builtin = @import("builtin");
const format = @import("../format.zig");

/// How many hex digits an id has: eight, the width of a `u32` in nibbles.
pub const id_len = 8;

/// The suffix of a per-root socket under `<base>/roots/`.
pub const socket_suffix = ".sock";

/// The control socket's name under `<base>`.
pub const control_socket_name = "daemon.sock";

/// The daemon's pid/protocol file under `<base>`.
pub const control_file_name = "daemon.json";

/// The daemon's own lock file under `<base>`. Held for the lifetime of the process: an OS file lock is
/// released by the kernel when the process dies, which is what makes "is another daemon live?" answerable
/// without trusting a pid.
pub const control_lock_name = "daemon.lock";

/// The directory under `<base>` that holds the per-root runtime entries.
pub const roots_dir_name = "roots";

/// The directory under `<base>` that holds the per-root logs.
pub const logs_dir_name = "logs";

/// The file name of a per-root claim under `<base>/roots/`. It is not `<id>.json`: the record lives in the
/// user home, and this is the ephemeral claim that says who is serving the root right now.
pub fn claimName(id: []const u8) [id_len + 4]u8 {
    var out: [id_len + 4]u8 = undefined;
    @memcpy(out[0..id_len], id[0..id_len]);
    @memcpy(out[id_len..], ".pid");
    return out;
}

/// `<id>` for a canonical root path: the low 32 bits of its wyhash, as eight lowercase hex digits.
///
/// Truncating the hash to 32 bits is deliberate. Eight digits are enough to keep tens of roots — even a few
/// thousand — collision-free in practice, and they are exactly four bytes, which is what keeps the socket
/// name short enough for AF_UNIX. `format.wyhash` is the hash the format itself uses for names, so there is
/// no second algorithm here.
pub fn idFor(canonical_root: []const u8) [id_len]u8 {
    const hashed: u32 = @truncate(format.wyhash(canonical_root));
    var out: [id_len]u8 = undefined;
    var index: usize = id_len;
    var value = hashed;
    while (index > 0) {
        index -= 1;
        out[index] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    }
    return out;
}

/// Whether `text` is a well-formed id: exactly eight lowercase hex digits.
pub fn isId(text: []const u8) bool {
    if (text.len != id_len) return false;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// An environment as the daemon sees it. `null` means "ask the process", which is what the CLI does; a test
/// passes a map so the resolution rules can be asserted on any host.
pub const Env = struct {
    map: ?*const std.process.Environ.Map = null,

    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        const map = self.map orelse return null;
        return map.get(name);
    }

    /// The platform's home directory variable, or `null` when the environment has none.
    fn home(self: Env) ?[]const u8 {
        return switch (builtin.os.tag) {
            .windows => self.get("USERPROFILE") orelse self.get("HOME"),
            else => self.get("HOME"),
        };
    }
};

/// Join `parts` with the platform's separator. The caller owns the result.
pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

/// The runtime base directory for this environment:
///
/// | platform                              | directory                         |
/// | ------------------------------------- | --------------------------------- |
/// | `FSMETA_RUNTIME_DIR` set               | `$FSMETA_RUNTIME_DIR`             |
/// | Linux/macOS, `$XDG_RUNTIME_DIR` set    | `$XDG_RUNTIME_DIR/fsmeta`         |
/// | macOS/Linux without it                 | `~/.cache/fsmeta/run`             |
/// | Windows                               | `%LOCALAPPDATA%\fsmeta\run`       |
///
/// `FSMETA_RUNTIME_DIR` is the test and container override: the suite must not write into the developer's
/// real runtime directory, and a server deployment wants to choose its own.
pub fn runtimeBase(allocator: std.mem.Allocator, env: Env) ![]u8 {
    if (env.get("FSMETA_RUNTIME_DIR")) |override| {
        if (override.len > 0) return allocator.dupe(u8, override);
    }
    return switch (builtin.os.tag) {
        .windows => blk: {
            const local = env.get("LOCALAPPDATA") orelse env.home() orelse return error.NoHomeDirectory;
            break :blk join(allocator, &.{ local, "fsmeta", "run" });
        },
        else => blk: {
            if (env.get("XDG_RUNTIME_DIR")) |runtime| {
                if (runtime.len > 0) break :blk join(allocator, &.{ runtime, "fsmeta" });
            }
            const home = env.home() orelse return error.NoHomeDirectory;
            break :blk join(allocator, &.{ home, ".cache", "fsmeta", "run" });
        },
    };
}

/// The durable root list for this environment:
///
/// | platform                 | file                                 |
/// | ------------------------ | ------------------------------------ |
/// | `FSMETA_CONFIG_HOME` set  | `$FSMETA_CONFIG_HOME/fsmeta/roots.json` |
/// | `$XDG_CONFIG_HOME` set    | `$XDG_CONFIG_HOME/fsmeta/roots.json` |
/// | otherwise (Linux/macOS)   | `~/.config/fsmeta/roots.json`        |
/// | Windows                  | `%APPDATA%\fsmeta\roots.json`        |
pub fn configFile(allocator: std.mem.Allocator, env: Env) ![]u8 {
    if (env.get("FSMETA_CONFIG_HOME")) |override| {
        if (override.len > 0) return join(allocator, &.{ override, "fsmeta", "roots.json" });
    }
    return switch (builtin.os.tag) {
        .windows => blk: {
            const roaming = env.get("APPDATA") orelse env.home() orelse return error.NoHomeDirectory;
            break :blk join(allocator, &.{ roaming, "fsmeta", "roots.json" });
        },
        else => blk: {
            if (env.get("XDG_CONFIG_HOME")) |config| {
                if (config.len > 0) break :blk join(allocator, &.{ config, "fsmeta", "roots.json" });
            }
            const home = env.home() orelse return error.NoHomeDirectory;
            break :blk join(allocator, &.{ home, ".config", "fsmeta", "roots.json" });
        },
    };
}

/// Where a running daemon keeps its ephemeral state, and where the durable list lives. Both paths are owned
/// by the arena the layout was resolved with; nothing here is freed individually.
pub const Layout = struct {
    /// The runtime directory: sockets, claims, the pid file, logs.
    base: []const u8,
    /// The durable root list in the user's config directory.
    config: []const u8,

    pub fn resolve(arena: std.mem.Allocator, env: Env, base_override: ?[]const u8) !Layout {
        const base = if (base_override) |path|
            try absolutePath(arena, path)
        else
            try runtimeBase(arena, env);
        return .{ .base = base, .config = try configFile(arena, env) };
    }

    pub fn controlSocket(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, &.{ self.base, control_socket_name });
    }

    pub fn controlFile(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, &.{ self.base, control_file_name });
    }

    pub fn controlLock(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, &.{ self.base, control_lock_name });
    }

    pub fn rootsDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, &.{ self.base, roots_dir_name });
    }

    pub fn logsDir(self: Layout, allocator: std.mem.Allocator) ![]u8 {
        return join(allocator, &.{ self.base, logs_dir_name });
    }

    /// `<base>/roots/<id>.sock` — always `<base>` plus exactly thirteen bytes, whatever the root's depth.
    pub fn rootSocket(self: Layout, allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return join(allocator, &.{ self.base, roots_dir_name, try std.fmt.allocPrint(allocator, "{s}{s}", .{ id, socket_suffix }) });
    }

    /// `<base>/roots/<id>.pid` — the claim file whose lock says a process is serving this root.
    pub fn rootClaim(self: Layout, allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        const name = claimName(id);
        return join(allocator, &.{ self.base, roots_dir_name, &name });
    }

    /// `<base>/logs/<id>.log`.
    pub fn rootLog(self: Layout, allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return join(allocator, &.{ self.base, logs_dir_name, try std.fmt.allocPrint(allocator, "{s}.log", .{id}) });
    }
};

/// Canonicalize a locator into an absolute path with no `.`/`..` and no symlink in it.
///
/// The argument is a **locator**, the same distinction `FORMAT.md` § 3.1 draws for the engine: it may be
/// relative, it is resolved once here, and it becomes the stored `root` of a record. A path that does not
/// exist resolves lexically (there is nothing to canonicalize), which is what lets `roots list` still name a
/// vanished root.
pub fn absolutePath(allocator: std.mem.Allocator, locator: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{locator});
}

/// Canonicalize a root that must exist: resolve through the file system so a symlinked root gets one stable
/// id. A missing path is `error.FileNotFound`, and the caller decides what that means.
pub fn canonicalRoot(io: std.Io, allocator: std.mem.Allocator, locator: []const u8) ![]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, locator, allocator);
}

/// Whether `child` lies strictly inside `parent`. Both are canonical absolute paths.
///
/// This is a **segment** test, not a string prefix: `/a/bc` is not inside `/a/b`, and a root is not inside
/// itself (that case is "already served", which the caller reports differently). Trailing separators on
/// `parent` are ignored, and Windows paths compare case-insensitively because the file system does.
///
/// This is the fact behind the nested-root guard (`plans/worktrees.md` § 5, M2): `root add` uses it to find the
/// served parents that must hide a new child and the served children a new parent must hide, and the managed
/// block in `.fs-meta/ignore` is what removes the overlap from the parent's trio.
pub fn isInside(parent: []const u8, child: []const u8) bool {
    const trimmed = trimTrailingSeparators(parent);
    if (trimmed.len == 0 or child.len <= trimmed.len) return false;
    const prefix_matches = if (builtin.os.tag == .windows)
        std.ascii.startsWithIgnoreCase(child, trimmed)
    else
        std.mem.startsWith(u8, child, trimmed);
    if (!prefix_matches) return false;
    // A volume root keeps its separator (`/`, `C:\`), so the parent itself ends the segment boundary: nothing
    // longer that starts with it can be anything but inside.
    const last = trimmed[trimmed.len - 1];
    if (last == '/' or (builtin.os.tag == .windows and last == '\\')) return true;
    const next = child[trimmed.len];
    return next == '/' or (builtin.os.tag == .windows and next == '\\');
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return path[0..end];
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

/// Compare two paths with either separator treated as the same one, so an assertion is about the *rule*
/// (base, then name) rather than about which separator this host happens to join with.
fn expectPath(expected: []const u8, actual: []const u8) !void {
    var expected_buffer: [1024]u8 = undefined;
    var actual_buffer: [1024]u8 = undefined;
    try testing.expectEqualStrings(slashes(expected, &expected_buffer), slashes(actual, &actual_buffer));
}

fn slashes(path: []const u8, buffer: []u8) []const u8 {
    const limit = @min(path.len, buffer.len);
    for (path[0..limit], 0..) |ch, index| buffer[index] = if (ch == '\\') '/' else ch;
    return buffer[0..limit];
}

fn envWith(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "the id of a root is stable, and two roots do not share one" {
    const first = idFor("/home/u/projects/app");
    const again = idFor("/home/u/projects/app");
    try testing.expectEqualSlices(u8, &first, &again);

    const other = idFor("/home/u/projects/other");
    try testing.expect(!std.mem.eql(u8, &first, &other));
    try testing.expect(isId(&first));
}

test "the id is eight lowercase hex digits for any path, long or short" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const deep = try arena.alloc(u8, 4000);
    @memset(deep, 'a');
    const cases = [_][]const u8{ "", "/", "a", "/home/u/x", deep };
    for (cases) |path| {
        const id = idFor(path);
        try testing.expectEqual(@as(usize, id_len), id.len);
        try testing.expect(isId(&id));
    }
}

test "a socket path has the same length for a short root and a four-thousand byte one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout: Layout = .{ .base = "/run/user/1000/fsmeta", .config = "/home/u/.config/fsmeta/roots.json" };

    const short = try layout.rootSocket(arena, &idFor("/s"));
    const deep_path = try arena.alloc(u8, 4000);
    @memset(deep_path, 'd');
    const deep = try layout.rootSocket(arena, &idFor(deep_path));

    try testing.expectEqual(short.len, deep.len);
    try testing.expectEqualStrings("a1b2c3d4.sock", "a1b2c3d4" ++ socket_suffix);
    // Thirteen bytes of name under a plausible base: well inside AF_UNIX's ~104-byte limit on POSIX, which is
    // the whole reason the name is a hash rather than the root's basename.
    try testing.expect(short.len <= 60);
    try testing.expect(std.mem.endsWith(u8, short, ".sock"));
}

test "the runtime base follows the platform's rules from an injected environment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var map = try envWith(testing.allocator, &.{
        .{ "XDG_RUNTIME_DIR", "/run/user/1000" },
        .{ "HOME", "/home/u" },
        .{ "LOCALAPPDATA", "/mnt/c/Users/u/AppData/Local" },
        .{ "APPDATA", "/mnt/c/Users/u/AppData/Roaming" },
        .{ "XDG_CONFIG_HOME", "/home/u/.config" },
        .{ "FSMETA_RUNTIME_DIR", "/scratch/run" },
        .{ "FSMETA_CONFIG_HOME", "/scratch/config" },
    });
    defer map.deinit();
    const env = Env{ .map = &map };

    // The overrides win, and that is what makes the test suite hermetic. The runtime base is returned exactly
    // as given; the config file is joined under it, so it carries the platform's separator.
    try testing.expectEqualStrings("/scratch/run", try runtimeBase(arena, env));
    try expectPath("/scratch/config/fsmeta/roots.json", try configFile(arena, env));

    // Without them the platform's own variables decide.
    _ = map.orderedRemove("FSMETA_RUNTIME_DIR");
    _ = map.orderedRemove("FSMETA_CONFIG_HOME");
    const expected_base = switch (builtin.os.tag) {
        .windows => "/mnt/c/Users/u/AppData/Local/fsmeta/run",
        else => "/run/user/1000/fsmeta",
    };
    const expected_config = switch (builtin.os.tag) {
        .windows => "/mnt/c/Users/u/AppData/Roaming/fsmeta/roots.json",
        else => "/home/u/.config/fsmeta/roots.json",
    };
    try expectPath(expected_base, try runtimeBase(arena, env));
    try expectPath(expected_config, try configFile(arena, env));

    // And the fallbacks, when neither override nor platform variable is set.
    _ = map.orderedRemove("XDG_RUNTIME_DIR");
    _ = map.orderedRemove("XDG_CONFIG_HOME");
    const fallback_base = switch (builtin.os.tag) {
        .windows => "/mnt/c/Users/u/AppData/Local/fsmeta/run",
        else => "/home/u/.cache/fsmeta/run",
    };
    const fallback_config = switch (builtin.os.tag) {
        .windows => "/mnt/c/Users/u/AppData/Roaming/fsmeta/roots.json",
        else => "/home/u/.config/fsmeta/roots.json",
    };
    try expectPath(fallback_base, try runtimeBase(arena, env));
    try expectPath(fallback_config, try configFile(arena, env));
}

test "inside means inside a path segment, not sharing a string prefix" {
    try testing.expect(isInside("/a/b", "/a/b/c"));
    try testing.expect(isInside("/a/b", "/a/b/c/d.txt"));
    try testing.expect(!isInside("/a/b", "/a/bc")); // shares the prefix, not the segment
    try testing.expect(!isInside("/a/b", "/a/b")); // the same root is "already served", not nesting
    try testing.expect(!isInside("/a/b", "/a"));
    try testing.expect(isInside("/a/b/", "/a/b/c")); // a trailing separator on the parent does not matter
    try testing.expect(isInside("/", "/anything")); // the root of a volume contains everything else
}

test "a windows path is inside with either separator, and compares case-insensitively" {
    if (builtin.os.tag != .windows) return error.SkipZigTest; // `\` is a name character elsewhere, not a separator
    try testing.expect(isInside("C:\\work", "C:\\work\\app"));
    try testing.expect(isInside("C:\\work", "C:\\work/app"));
    try testing.expect(isInside("C:\\work", "C:\\work\\"));
    try testing.expect(isInside("c:\\WORK", "C:\\Work\\app")); // the file system does not care about case
    try testing.expect(!isInside("C:\\work", "C:\\workaround"));
    try testing.expect(!isInside("C:\\work", "C:\\work"));
}

test "the layout puts every runtime entry under its base and keeps the record in the home" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout: Layout = .{ .base = "/run/user/1000/fsmeta", .config = "/home/u/.config/fsmeta/roots.json" };
    try expectPath("/run/user/1000/fsmeta/daemon.sock", try layout.controlSocket(arena));
    try expectPath("/run/user/1000/fsmeta/daemon.json", try layout.controlFile(arena));
    try expectPath("/run/user/1000/fsmeta/daemon.lock", try layout.controlLock(arena));
    try expectPath("/run/user/1000/fsmeta/roots", try layout.rootsDir(arena));
    try expectPath("/run/user/1000/fsmeta/logs", try layout.logsDir(arena));
    try expectPath("/run/user/1000/fsmeta/roots/a1b2c3d4.sock", try layout.rootSocket(arena, "a1b2c3d4"));
    try expectPath("/run/user/1000/fsmeta/roots/a1b2c3d4.pid", try layout.rootClaim(arena, "a1b2c3d4"));
    try expectPath("/run/user/1000/fsmeta/logs/a1b2c3d4.log", try layout.rootLog(arena, "a1b2c3d4"));
    // The durable list is not under the runtime base: it is configuration, not host state.
    try testing.expect(!std.mem.startsWith(u8, layout.config, layout.base));
}
