// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The control plane: JSON lines over `<base>/daemon.sock`.
//!
//! Deliberately **not** the binary batch protocol. This is a management interface — its callers are people
//! and scripts — so one request object per line in, one reply object per line out, connection closed. JSON is
//! diffable in a log and readable with `cat`; the consumer socket is where bytes are budgeted.
//!
//! `{"v":1,"cmd":"roots"}` in, `{"v":1,"ok":true,"roots":[…]}` out. A refusal carries the same `code` the CLI
//! exits with, so the two halves of the contract are one table (`Exit` below): `2` no such root, `3` daemon
//! not running, `4` refused by policy, `5` protocol mismatch. A client that does not speak this version is
//! refused rather than guessed at.
//!
//! This module owns the framing and the request schema. It owns no data: what a reply says about roots is
//! `host.zig`'s business, because that is where the registry and the runtimes are.

const std = @import("std");
const state = @import("state.zig");
const registry = @import("registry.zig");
const wire = @import("../wire.zig");

/// The control protocol's version. A CLI and a daemon that disagree here refuse each other rather than
/// exchanging fields one of them does not understand.
pub const version: u16 = 1;

/// The longest request line a daemon will read. A root path plus a retention block is well under a kilobyte;
/// this is a ceiling, not a target. A longer line is refused with a message, never truncated and parsed.
pub const max_line = 64 * 1024;

/// The exit codes, as documented and tested. One table for both sides: the daemon puts the number in the
/// reply's `code`, the CLI exits with it.
pub const Exit = struct {
    pub const ok: u8 = 0;
    pub const failure: u8 = 1;
    pub const no_such_root: u8 = 2;
    pub const daemon_not_running: u8 = 3;
    pub const refused: u8 = 4;
    pub const protocol_mismatch: u8 = 5;

    /// Map a reply's `code` to the process exit status.
    pub fn fromCode(code: u16) u8 {
        return switch (code) {
            ok => ok,
            no_such_root => no_such_root,
            daemon_not_running => daemon_not_running,
            refused => refused,
            protocol_mismatch => protocol_mismatch,
            else => failure,
        };
    }
};

/// How long each control operation may wait for one root's lock (`FORMAT.daemon.md` § 4b).
///
/// The right budget is a property of the *operation*, not of the root: a listing over many roots must answer
/// quickly and say which parts are not available yet; a single root asked for by name can afford a short wait;
/// a mutation must either happen or be refused, never report success it did not have. Lifecycle work
/// (`root.remove`, `daemon.shutdown`) is the exception: it waits without a budget, because the caller asked for
/// the work to be *finished*.
pub const Budget = struct {
    /// `roots`: wait this long per root, then report it as not available.
    pub const roots: i64 = 50;
    /// `root.status`: one root, asked for by name.
    pub const root_status: i64 = 250;
    /// `root.set`, `root.sleep`, `root.wake`, and the snapshot that confirms them.
    pub const mutation: i64 = 2_000;
};

pub const Command = enum {
    status,
    roots,
    root_add,
    root_remove,
    root_set,
    root_sleep,
    root_wake,
    root_status,
    daemon_shutdown,

    pub fn wire(self: Command) []const u8 {
        return switch (self) {
            .status => "status",
            .roots => "roots",
            .root_add => "root.add",
            .root_remove => "root.remove",
            .root_set => "root.set",
            .root_sleep => "root.sleep",
            .root_wake => "root.wake",
            .root_status => "root.status",
            .daemon_shutdown => "daemon.shutdown",
        };
    }

    pub fn parse(text: []const u8) ?Command {
        inline for (std.meta.tags(Command)) |tag| {
            if (std.mem.eql(u8, text, tag.wire())) return tag;
        }
        return null;
    }
};

/// One request. Every field but `v` and `cmd` is optional, and which ones a command needs is checked by the
/// handler: `root.set` needs at least one of `mode`, `idle_timeout_ms`, `retention`, `worktrees` or `gitwatch`, and
/// `root.add` needs a path. Parsing stays permissive so a future field is ignorable by an older daemon that shares the
/// version.
pub const Request = struct {
    v: u16 = version,
    cmd: Command,
    /// An id or a root path, for the commands that address one root.
    root: ?[]const u8 = null,
    /// The locator a `root.add` was given (may be relative; the daemon canonicalizes it).
    path: ?[]const u8 = null,
    mode: ?state.Mode = null,
    idle_timeout_ms: ?u64 = null,
    retention: ?registry.Retention = null,
    on_remove: ?registry.OnRemove = null,
    /// `root.add --worktrees on|off`: the per-root worktree handling switch (`plans/worktrees.md` § 5h).
    worktrees: ?bool = null,
    /// `root.add --gitwatch on|off`: the per-root git signal switch.
    gitwatch: ?bool = null,
    /// `root.add --on-worktree ignore|serve`: what this root does when a worktree of its repo is discovered.
    on_worktree: ?registry.OnWorktree = null,
    /// `root.add --worktree`: the path is asserted to be a linked worktree (`.git` is a gitfile whose target is an
    /// existing directory); the add is adopted/seeded like `--on-worktree serve` would (`plans/worktrees.md` § 7).
    worktree: bool = false,
    /// `root.add --nested`: the operator acknowledges an intentional nested root. It changes no behaviour — the guard
    /// still writes the parent's managed line — and is echoed in the reply (`plans/worktrees.md` § 7, M7).
    nested: bool = false,
    /// `root.remove --force`: remove a root that still has subscribers.
    force: bool = false,
};

pub const ParseError = error{
    InvalidJson,
    NotAnObject,
    UnsupportedVersion,
    UnknownCommand,
    MissingCommand,
    WrongType,
    OutOfMemory,
};

/// Parse one request line. `allocator` must outlive the request: the strings point into it.
pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) ParseError!Request {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.NotAnObject,
    };

    if (object.get("v")) |value| {
        const requested = switch (value) {
            .integer => |i| i,
            else => return error.WrongType,
        };
        if (requested != version) return error.UnsupportedVersion;
    }

    const cmd_text = switch (object.get("cmd") orelse return error.MissingCommand) {
        .string => |text| text,
        else => return error.WrongType,
    };
    const cmd = Command.parse(cmd_text) orelse return error.UnknownCommand;

    var request: Request = .{ .cmd = cmd };
    request.root = try optionalString(object, "root");
    request.path = try optionalString(object, "path");
    if (object.get("mode")) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return error.WrongType,
        };
        request.mode = state.Mode.parse(text) orelse return error.WrongType;
    }
    if (object.get("idle_timeout_ms")) |value| {
        request.idle_timeout_ms = switch (value) {
            .integer => |i| if (i < 0) return error.WrongType else @intCast(i),
            else => return error.WrongType,
        };
    }
    if (object.get("retention")) |value| {
        request.retention = try parseRetention(value);
    }
    if (object.get("on_remove")) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return error.WrongType,
        };
        request.on_remove = registry.OnRemove.parse(text) orelse return error.WrongType;
    }
    if (object.get("force")) |value| {
        request.force = switch (value) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    if (object.get("worktrees")) |value| {
        request.worktrees = switch (value) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    if (object.get("gitwatch")) |value| {
        request.gitwatch = switch (value) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    if (object.get("on_worktree")) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return error.WrongType,
        };
        request.on_worktree = registry.OnWorktree.parse(text) orelse return error.WrongType;
    }
    if (object.get("worktree")) |value| {
        request.worktree = switch (value) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    if (object.get("nested")) |value| {
        request.nested = switch (value) {
            .bool => |b| b,
            else => return error.WrongType,
        };
    }
    return request;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ParseError!?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.WrongType,
    };
}

fn parseRetention(value: std.json.Value) ParseError!registry.Retention {
    if (value != .object) return error.WrongType;
    var retention: registry.Retention = .{};
    if (value.object.get("max_batches")) |member| {
        retention.max_batches = switch (member) {
            .integer => |i| if (i < 0) return error.WrongType else @intCast(i),
            else => return error.WrongType,
        };
    }
    if (value.object.get("max_bytes")) |member| {
        retention.max_bytes = switch (member) {
            .integer => |i| if (i < 0) return error.WrongType else @intCast(i),
            else => return error.WrongType,
        };
    }
    return retention;
}

// ---------------------------------------------------------------- replies

/// Start a successful reply. The caller appends `,"field":…` members and closes it with `finish`.
pub fn beginOk(writer: *std.Io.Writer) !void {
    try writer.print("{{\"v\":{d},\"ok\":true", .{version});
}

/// Start a refusal: the same shape, with the code the CLI exits with.
pub fn beginError(writer: *std.Io.Writer, code: u8, message: []const u8) !void {
    try writer.print("{{\"v\":{d},\"ok\":false,\"code\":{d},\"message\":", .{ version, code });
    try writeString(writer, message);
}

pub fn finish(writer: *std.Io.Writer) !void {
    try writer.writeAll("}\n");
}

/// Append `,"key":value` to a reply body, for values the caller renders itself.
pub fn stringField(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.writeByte(',');
    try writeString(writer, key);
    try writer.writeByte(':');
    try writeString(writer, value);
}

pub fn intField(writer: *std.Io.Writer, key: []const u8, value: anytype) !void {
    try writer.writeByte(',');
    try writeString(writer, key);
    try writer.print(":{d}", .{value});
}

pub fn boolField(writer: *std.Io.Writer, key: []const u8, value: bool) !void {
    try writer.writeByte(',');
    try writeString(writer, key);
    try writer.writeAll(if (value) ":true" else ":false");
}

/// Escape a string as a JSON string literal.
pub fn writeString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{x:0>4}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// The human-readable name of a parse failure. These are shown to a person who typed a command, so they name
/// the field rather than the error enum member.
pub fn describeParseError(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidJson => "the request is not valid JSON",
        error.NotAnObject => "the request is not a JSON object",
        error.UnsupportedVersion => "this control protocol version is not supported (this daemon speaks version 1)",
        error.UnknownCommand => "unknown command",
        error.MissingCommand => "the request has no \"cmd\"",
        error.WrongType => "a request field has the wrong type",
        error.OutOfMemory => "out of memory",
    };
}

// ---------------------------------------------------------------- `daemon.json`

/// `<base>/daemon.json`: what a CLI reads before it connects.
///
/// It is **not** the authority on whether a daemon is live — the control socket is, and the lock file settles
/// a race — it is the cheap answer to "is there a daemon, and where is its base?" without speaking protocol to
/// a stale socket.
pub const DaemonFile = struct {
    v: u16 = version,
    pid: u32,
    started_at: []const u8,
    protocol: u16 = wire.protocol,
    base: []const u8,

    pub fn encode(self: DaemonFile, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;
        try writer.print("{{\n  \"v\": {d},\n  \"pid\": {d},\n  \"started_at\": ", .{ self.v, self.pid });
        try writeString(writer, self.started_at);
        try writer.print(",\n  \"protocol\": {d},\n  \"base\": ", .{self.protocol});
        try writeString(writer, self.base);
        try writer.writeAll("\n}\n");
        return out.toOwnedSlice();
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !DaemonFile {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const v = unsignedField(object, "v") orelse version;
        return .{
            .v = @intCast(@min(v, std.math.maxInt(u16))),
            .pid = @intCast(@min(unsignedField(object, "pid") orelse 0, std.math.maxInt(u32))),
            .started_at = stringFieldValue(object, "started_at") orelse "",
            .protocol = @intCast(@min(unsignedField(object, "protocol") orelse wire.protocol, std.math.maxInt(u16))),
            .base = stringFieldValue(object, "base") orelse "",
        };
    }
};

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    return switch (object.get(key) orelse return null) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn stringFieldValue(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "a request parses into the command it names, with the fields it carries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const add = try parseRequest(arena, "{\"v\":1,\"cmd\":\"root.add\",\"path\":\"/home/u/app\",\"mode\":\"always\",\"idle_timeout_ms\":1000,\"retention\":{\"max_batches\":4,\"max_bytes\":1024},\"on_remove\":\"delete\"}");
    try testing.expectEqual(Command.root_add, add.cmd);
    try testing.expectEqualStrings("/home/u/app", add.path.?);
    try testing.expectEqual(state.Mode.always, add.mode.?);
    try testing.expectEqual(@as(u64, 1_000), add.idle_timeout_ms.?);
    try testing.expectEqual(@as(u64, 4), add.retention.?.max_batches);
    try testing.expectEqual(registry.OnRemove.delete, add.on_remove.?);

    const remove = try parseRequest(arena, "{\"v\":1,\"cmd\":\"root.remove\",\"root\":\"a1b2c3d4\",\"force\":true}");
    try testing.expectEqual(Command.root_remove, remove.cmd);
    try testing.expectEqualStrings("a1b2c3d4", remove.root.?);
    try testing.expect(remove.force);

    // `v` may be omitted by a lenient caller, and is then assumed current.
    const status = try parseRequest(arena, "{\"cmd\":\"status\"}");
    try testing.expectEqual(Command.status, status.cmd);
    try testing.expectEqual(@as(?[]const u8, null), status.root);

    // The two per-root switches travel as booleans; absent is `null`, which the daemon reads as "copy the default".
    const switches = try parseRequest(arena, "{\"v\":1,\"cmd\":\"root.add\",\"path\":\"/home/u/app\",\"worktrees\":false,\"gitwatch\":true}");
    try testing.expectEqual(false, switches.worktrees.?);
    try testing.expectEqual(true, switches.gitwatch.?);
    const unset = try parseRequest(arena, "{\"v\":1,\"cmd\":\"root.add\",\"path\":\"/home/u/app\"}");
    try testing.expectEqual(@as(?bool, null), unset.worktrees);
    try testing.expectEqual(@as(?bool, null), unset.gitwatch);
}

test "a request that is not this protocol is refused, not guessed at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.InvalidJson, parseRequest(arena, "not json"));
    try testing.expectError(error.NotAnObject, parseRequest(arena, "[]"));
    try testing.expectError(error.MissingCommand, parseRequest(arena, "{\"v\":1}"));
    try testing.expectError(error.UnknownCommand, parseRequest(arena, "{\"v\":1,\"cmd\":\"root.explode\"}"));
    try testing.expectError(error.UnsupportedVersion, parseRequest(arena, "{\"v\":2,\"cmd\":\"status\"}"));
    try testing.expectError(error.WrongType, parseRequest(arena, "{\"v\":1,\"cmd\":\"root.set\",\"mode\":7}"));
    try testing.expectError(error.WrongType, parseRequest(arena, "{\"v\":1,\"cmd\":\"roots\",\"root\":5}"));
    // A switch is a boolean, not a string: `--worktrees on` is CLI spelling, and the CLI converts it.
    try testing.expectError(error.WrongType, parseRequest(arena, "{\"v\":1,\"cmd\":\"root.add\",\"worktrees\":\"on\"}"));
}

test "every command has a wire name, and the name parses back" {
    inline for (std.meta.tags(Command)) |tag| {
        try testing.expectEqual(tag, Command.parse(tag.wire()).?);
        try testing.expect(std.mem.indexOf(u8, tag.wire(), " ") == null);
    }
    try testing.expectEqual(@as(?Command, null), Command.parse("root.broken"));
}

test "a reply is one JSON line, and a refusal carries the CLI's exit code" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const writer = &out.writer;

    try beginOk(writer);
    try stringField(writer, "root", "/home/u/app");
    try intField(writer, "clients", 2);
    try boolField(writer, "missing", false);
    try finish(writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expect(object.get("ok").?.bool);
    try testing.expectEqualStrings("/home/u/app", object.get("root").?.string);
    try testing.expectEqual(@as(i64, 2), object.get("clients").?.integer);
    try testing.expectEqual(false, object.get("missing").?.bool);
    try testing.expect(std.mem.endsWith(u8, out.written(), "\n"));

    var failure: std.Io.Writer.Allocating = .init(testing.allocator);
    defer failure.deinit();
    try beginError(&failure.writer, Exit.refused, "mode is off");
    try finish(&failure.writer);
    var failed = try std.json.parseFromSlice(std.json.Value, testing.allocator, failure.written(), .{});
    defer failed.deinit();
    try testing.expectEqual(false, failed.value.object.get("ok").?.bool);
    try testing.expectEqual(@as(u8, Exit.refused), Exit.fromCode(@intCast(failed.value.object.get("code").?.integer)));
    try testing.expectEqualStrings("mode is off", failed.value.object.get("message").?.string);
    // A code outside the table is a plain failure, never a success.
    try testing.expectEqual(Exit.failure, Exit.fromCode(99));
}

test "the daemon file round-trips and reads back its protocol" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try (DaemonFile{
        .pid = 4_242,
        .started_at = "2026-10-26T06:50:00Z",
        .base = "/run/user/1000/fsmeta",
    }).encode(arena);

    const read_back = try DaemonFile.parse(arena, bytes);
    try testing.expectEqual(@as(u32, 4_242), read_back.pid);
    try testing.expectEqualStrings("2026-10-26T06:50:00Z", read_back.started_at);
    try testing.expectEqual(wire.protocol, read_back.protocol);
    try testing.expectEqualStrings("/run/user/1000/fsmeta", read_back.base);
}
