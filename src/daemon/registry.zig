// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The durable root list: `roots.json` in the user home.
//!
//! This file is **configuration**, not host state. It holds the roots a person chose to serve, their mode,
//! idle timeout, retention and removal policy — the things that survive a reboot, a crashed daemon and an
//! emptied runtime directory. Sockets, pids and logs are facts about a running process on one machine and
//! live in the runtime directory instead (`paths.zig`).
//!
//! One document, not a directory of files: the list is small (tens of roots), read once at start and written
//! on every mutation, and one atomic rename is easier to reason about than N files plus a directory scan —
//! which on a network home can be slow. If it ever grows past a few hundred roots, per-root files under
//! `~/.config/fsmeta/roots/` are the documented alternative, read by one `readdir` (still not a search).
//!
//! The startup invariant this file exists for: **the daemon never walks the file system to discover roots.**
//! It reads this list, `stat`s each recorded path once, and creates the runtime entries from that. A daemon
//! that searched for `.git` directories would make every restart unbounded and would find roots nobody asked
//! for.
//!
//! ## Writing
//!
//! Every save writes `<path>.tmp` and renames it over the original, so a reader either sees the whole previous
//! document or the whole next one — never a half-written list, which on a crash would lose every root the
//! user configured. A malformed record is reported and **skipped**, never fatal to the other roots.
//!
//! Tests: record round-trip, a malformed record skipped and reported, atomic replace, and a missing file as a
//! valid empty state.

const std = @import("std");
const state = @import("state.zig");
const paths = @import("paths.zig");

/// How many generations of `batches/` one root retains. The format's own default (FORMAT.md § 17.6).
pub const default_max_batches: u64 = 32;

/// The byte ceiling on one root's batch archive: 64 MiB. Count alone is a poor ceiling — thirty-two
/// generations of a huge tree can fill a disk — and bytes alone is a poor one too, because a hundred tiny
/// generations are still a hundred handshakes to replay.
pub const default_max_bytes: u64 = 64 * 1024 * 1024;

pub const Retention = struct {
    max_batches: u64 = default_max_batches,
    max_bytes: u64 = default_max_bytes,
};

/// What removing a root does with its history. "Stop serving" and "delete my history" are different intents,
/// so the choice is explicit and per root.
pub const OnRemove = enum {
    keep,
    delete,

    pub fn name(self: OnRemove) []const u8 {
        return switch (self) {
            .keep => "keep",
            .delete => "delete",
        };
    }

    pub fn parse(text: []const u8) ?OnRemove {
        if (std.mem.eql(u8, text, "keep")) return .keep;
        if (std.mem.eql(u8, text, "delete")) return .delete;
        return null;
    }
};

/// What a root does when a pass discovers a worktree of its repository (`plans/worktrees.md` § 5, M6). The policy
/// belongs to the **discovering** root; the child does not exist when the decision is recorded. `ignore` is the
/// default (the boundary rule already keeps the worktree out); `serve` adds it as a root, seeded from the base trio.
pub const OnWorktree = enum {
    ignore,
    serve,

    pub fn name(self: OnWorktree) []const u8 {
        return switch (self) {
            .ignore => "ignore",
            .serve => "serve",
        };
    }

    pub fn parse(text: []const u8) ?OnWorktree {
        if (std.mem.eql(u8, text, "ignore")) return .ignore;
        if (std.mem.eql(u8, text, "serve")) return .serve;
        return null;
    }
};

/// The global defaults, copied into a root's record when it is added.
///
/// The copy is the point: changing a default later never silently mutates an existing root, which would make
/// `fsmeta root add` a decision that a future config edit could revoke.
pub const Defaults = struct {
    mode: state.Mode = .auto,
    idle_timeout_ms: u64 = state.default_idle_timeout_ms,
    retention: Retention = .{},
    on_remove: OnRemove = .keep,
    /// Worktree handling for this root (`plans/worktrees.md` § 5h): adoption, seeding, worktree events and the
    /// reaction to a removal. **Not** the boundary rule, which is always on (decision 30).
    worktrees: bool = true,
    /// Git signal handling for this root: the lock latch, metadata watch, hooks and `GIT_EVENT` frames.
    gitwatch: bool = true,
    /// A worktree discovered inside this root is ignored (default) or adopted as a root (§ 5, M6).
    on_worktree: OnWorktree = .ignore,
};

/// One root, as the list stores it. Everything the daemon needs to rebuild the root's runtime entry.
pub const Record = struct {
    /// `hex8(wyhash(canonical root path))` — stable across restarts, and short enough for a socket name.
    id: []const u8,
    /// The canonical root path. This is host state: the trio itself never contains an absolute path.
    root: []const u8,
    mode: state.Mode,
    idle_timeout_ms: u64,
    retention: Retention,
    on_remove: OnRemove,
    /// The effective worktree/gitwatch flags for this root, copied from `Defaults` at add time. A record written
    /// before these fields existed parses them from `defaults` (or `true` when the default itself is absent).
    worktrees: bool = true,
    gitwatch: bool = true,
    /// Recorded per root at add time, like the two switches above; see `Defaults.on_worktree`.
    on_worktree: OnWorktree = .ignore,
    /// The runtime socket path. Rewritten on every start, because the runtime directory may have moved.
    socket: []const u8,
    /// `inproc`, or `child:<pid>` when a future split serves this root from its own process.
    served_by: []const u8,
    /// When the record was created, RFC3339 UTC.
    created_at: []const u8,
};

/// The document, plus where it came from and what was wrong with it.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    /// The file this list was read from and will be written to.
    path: []const u8,
    version: u32 = 1,
    defaults: Defaults = .{},
    records: std.ArrayListUnmanaged(Record) = .empty,
    /// Records that were skipped, one human-readable line each. Reported by `roots list` and the daemon log;
    /// never fatal, because one bad record must not take the other roots down with it.
    diagnostics: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Registry {
        return .{ .allocator = allocator, .path = path };
    }

    pub fn deinit(self: *Registry) void {
        self.records.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    /// Find a record by id or by root path. Both are accepted because a person types whichever they have.
    pub fn find(self: *Registry, id_or_path: []const u8) ?usize {
        for (self.records.items, 0..) |record, index| {
            if (std.mem.eql(u8, record.id, id_or_path)) return index;
            if (std.mem.eql(u8, record.root, id_or_path)) return index;
        }
        return null;
    }

    pub fn findById(self: *Registry, id: []const u8) ?usize {
        for (self.records.items, 0..) |record, index| {
            if (std.mem.eql(u8, record.id, id)) return index;
        }
        return null;
    }

    /// Add a record. The caller supplies the derived id and socket path, because it is the one that knows the
    /// layout; the defaults are copied here, at the moment of the add. `Defaults` is a set of starting values,
    /// not a live inheritance.
    pub fn add(
        self: *Registry,
        canonical_root: []const u8,
        id: []const u8,
        socket: []const u8,
        overrides: Defaults,
        now: []const u8,
    ) !void {
        try self.records.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .root = try self.allocator.dupe(u8, canonical_root),
            .mode = overrides.mode,
            .idle_timeout_ms = overrides.idle_timeout_ms,
            .retention = overrides.retention,
            .on_remove = overrides.on_remove,
            .worktrees = overrides.worktrees,
            .gitwatch = overrides.gitwatch,
            .on_worktree = overrides.on_worktree,
            .socket = try self.allocator.dupe(u8, socket),
            .served_by = try self.allocator.dupe(u8, "inproc"),
            .created_at = try self.allocator.dupe(u8, now),
        });
    }

    pub fn removeAt(self: *Registry, index: usize) void {
        _ = self.records.orderedRemove(index);
    }

    /// Read the list. A missing file is a valid state — no roots, no error — because the first start of a
    /// daemon and the last stop of one both leave nothing behind.
    pub fn load(self: *Registry, io: std.Io) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, std.Io.Limit.limited(1 << 26)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        try self.parse(bytes);
    }

    /// Parse the document's bytes. The parsed tree is freed before this returns; every string a `Record` keeps
    /// is duplicated into the registry's own allocator, so nothing points into a document that is gone.
    fn parse(self: *Registry, bytes: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch |err| {
            try self.report("the root list is not valid JSON ({s}); treating it as empty", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => {
                try self.report("the root list is not a JSON object; treating it as empty", .{});
                return;
            },
        };

        if (root.get("version")) |value| {
            if (value != .integer or value.integer < 1) {
                try self.report("the root list's version is not a positive integer; reading it as version 1", .{});
            } else {
                self.version = @intCast(@min(value.integer, std.math.maxInt(u32)));
            }
        }

        if (root.get("defaults")) |value| {
            if (value == .object) {
                self.defaults = parseDefaults(&value.object) catch blk: {
                    try self.report("the root list's defaults block is malformed; using the built-in defaults", .{});
                    break :blk .{};
                };
            } else {
                try self.report("the root list's defaults block is not an object; using the built-in defaults", .{});
            }
        }

        const roots_value = root.get("roots") orelse {
            try self.report("the root list has no roots array; treating it as empty", .{});
            return;
        };
        if (roots_value != .array) {
            try self.report("the root list's roots member is not an array; treating it as empty", .{});
            return;
        }

        for (roots_value.array.items, 0..) |item, index| {
            if (item != .object) {
                try self.report("root {d} is not an object; skipped", .{index});
                continue;
            }
            const record = parseRecord(&item.object) catch |err| {
                try self.report("root {d} is malformed ({s}); skipped", .{ index, @errorName(err) });
                continue;
            };
            try self.records.append(self.allocator, try self.copyRecord(record));
        }
    }

    fn copyRecord(self: *Registry, record: Record) !Record {
        var copied = record;
        copied.id = try self.allocator.dupe(u8, record.id);
        copied.root = try self.allocator.dupe(u8, record.root);
        copied.socket = try self.allocator.dupe(u8, record.socket);
        copied.served_by = try self.allocator.dupe(u8, record.served_by);
        copied.created_at = try self.allocator.dupe(u8, record.created_at);
        return copied;
    }

    fn report(self: *Registry, comptime format: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.allocator, format, args);
        try self.diagnostics.append(self.allocator, line);
    }

    /// Write the list atomically: `<path>.tmp`, then a rename over the original.
    ///
    /// The temporary is cleaned up on every path out of this function, so a failed save leaves the previous
    /// document in place and no debris beside it.
    pub fn save(self: *Registry, io: std.Io) !void {
        if (std.fs.path.dirname(self.path)) |parent| {
            if (parent.len > 0) std.Io.Dir.cwd().createDirPath(io, parent) catch |err| return err;
        }

        const bytes = try self.encode();
        defer self.allocator.free(bytes);

        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(temporary);
        defer std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes });
        try std.Io.Dir.renameAbsolute(temporary, self.path, io);
    }

    /// The document's bytes, in the layout `FORMAT.daemon.md` documents.
    pub fn encode(self: *Registry) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;

        try writer.writeAll("{\n");
        try writer.print("  \"version\": {d},\n", .{self.version});
        try writer.writeAll("  \"defaults\": {\n");
        try writer.writeAll("    \"mode\": ");
        try writeString(writer, self.defaults.mode.name());
        try writer.print(",\n    \"idle_timeout_ms\": {d},\n", .{self.defaults.idle_timeout_ms});
        try writer.print("    \"retention\": {{ \"max_batches\": {d}, \"max_bytes\": {d} }},\n", .{
            self.defaults.retention.max_batches,
            self.defaults.retention.max_bytes,
        });
        try writer.writeAll("    \"on_remove\": ");
        try writeString(writer, self.defaults.on_remove.name());
        try writer.print(",\n    \"worktrees\": {s},\n    \"gitwatch\": {s},\n    \"on_worktree\": ", .{
            if (self.defaults.worktrees) "true" else "false",
            if (self.defaults.gitwatch) "true" else "false",
        });
        try writeString(writer, self.defaults.on_worktree.name());
        try writer.writeAll("\n  },\n");

        if (self.records.items.len == 0) {
            try writer.writeAll("  \"roots\": []\n");
        } else {
            try writer.writeAll("  \"roots\": [\n");
            for (self.records.items, 0..) |record, index| {
                try writeRecord(writer, record, "    ");
                try writer.writeAll(if (index + 1 == self.records.items.len) "\n" else ",\n");
            }
            try writer.writeAll("  ]\n");
        }
        try writer.writeAll("}\n");
        return out.toOwnedSlice();
    }
};

fn writeRecord(writer: *std.Io.Writer, record: Record, indent: []const u8) !void {
    try writer.writeAll(indent);
    try writer.writeAll("{\n");
    try writer.writeAll(indent);
    try writer.writeAll("  \"id\": ");
    try writeString(writer, record.id);
    try writer.writeAll(",\n");
    try writer.writeAll(indent);
    try writer.writeAll("  \"root\": ");
    try writeString(writer, record.root);
    try writer.writeAll(",\n");
    try writer.writeAll(indent);
    try writer.writeAll("  \"mode\": ");
    try writeString(writer, record.mode.name());
    try writer.print(",\n{s}  \"idle_timeout_ms\": {d},\n", .{ indent, record.idle_timeout_ms });
    try writer.print("{s}  \"retention\": {{ \"max_batches\": {d}, \"max_bytes\": {d} }},\n", .{
        indent,
        record.retention.max_batches,
        record.retention.max_bytes,
    });
    try writer.writeAll(indent);
    try writer.writeAll("  \"on_remove\": ");
    try writeString(writer, record.on_remove.name());
    try writer.print(",\n{s}  \"worktrees\": {s},\n{s}  \"gitwatch\": {s},\n{s}  \"on_worktree\": ", .{
        indent,
        if (record.worktrees) "true" else "false",
        indent,
        if (record.gitwatch) "true" else "false",
        indent,
    });
    try writeString(writer, record.on_worktree.name());
    try writer.writeAll(",\n");
    try writer.writeAll(indent);
    try writer.writeAll("  \"socket\": ");
    try writeString(writer, record.socket);
    try writer.writeAll(",\n");
    try writer.writeAll(indent);
    try writer.writeAll("  \"served_by\": ");
    try writeString(writer, record.served_by);
    try writer.writeAll(",\n");
    try writer.writeAll(indent);
    try writer.writeAll("  \"created_at\": ");
    try writeString(writer, record.created_at);
    try writer.writeAll("\n");
    try writer.writeAll(indent);
    try writer.writeAll("}");
}

fn writeString(writer: *std.Io.Writer, s: []const u8) !void {
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
// SECTION: encoding
const ParseError = error{
    Malformed,
    MissingField,
    WrongType,
    InvalidMode,
    InvalidRetention,
    InvalidOnRemove,
    InvalidOnWorktree,
};

fn parseDefaults(object: *const std.json.ObjectMap) ParseError!Defaults {
    var defaults: Defaults = .{};
    if (object.get("mode")) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return error.WrongType,
        };
        defaults.mode = state.Mode.parse(text) orelse return error.InvalidMode;
    }
    if (object.get("idle_timeout_ms")) |value| {
        defaults.idle_timeout_ms = unsigned(value) orelse return error.WrongType;
    }
    if (object.get("retention")) |value| {
        defaults.retention = parseRetention(value) orelse return error.InvalidRetention;
    }
    if (object.get("on_remove")) |value| {
        defaults.on_remove = OnRemove.parse(stringValue(value) orelse return error.WrongType) orelse return error.InvalidOnRemove;
    }
    if (object.get("worktrees")) |value| {
        defaults.worktrees = boolValue(value) orelse return error.WrongType;
    }
    if (object.get("gitwatch")) |value| {
        defaults.gitwatch = boolValue(value) orelse return error.WrongType;
    }
    if (object.get("on_worktree")) |value| {
        defaults.on_worktree = OnWorktree.parse(stringValue(value) orelse return error.WrongType) orelse return error.InvalidOnWorktree;
    }
    return defaults;
}

fn boolValue(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn parseRetention(value: std.json.Value) ?Retention {
    if (value != .object) return null;
    const object = &value.object;
    var retention: Retention = .{};
    if (object.get("max_batches")) |member| {
        retention.max_batches = unsigned(member) orelse return null;
    }
    if (object.get("max_bytes")) |member| {
        retention.max_bytes = unsigned(member) orelse return null;
    }
    return retention;
}

fn unsigned(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn optionalString(object: *const std.json.ObjectMap, key: []const u8) ParseError![]const u8 {
    const value = object.get(key) orelse return "";
    return stringValue(value) orelse error.WrongType;
}

fn parseRecord(object: *const std.json.ObjectMap) ParseError!Record {
    const id = stringValue(object.get("id") orelse return error.MissingField) orelse return error.WrongType;
    if (!paths.isId(id)) return error.Malformed;
    const root_path = stringValue(object.get("root") orelse return error.MissingField) orelse return error.WrongType;
    if (root_path.len == 0) return error.Malformed;

    var record: Record = .{
        .id = id,
        .root = root_path,
        .mode = .auto,
        .idle_timeout_ms = state.default_idle_timeout_ms,
        .retention = .{},
        .on_remove = .keep,
        .worktrees = true,
        .gitwatch = true,
        .on_worktree = .ignore,
        .socket = "",
        .served_by = "inproc",
        .created_at = "",
    };

    if (object.get("mode")) |value| {
        record.mode = state.Mode.parse(stringValue(value) orelse return error.WrongType) orelse return error.InvalidMode;
    }
    if (object.get("idle_timeout_ms")) |value| {
        record.idle_timeout_ms = unsigned(value) orelse return error.WrongType;
    }
    if (object.get("retention")) |value| {
        record.retention = parseRetention(value) orelse return error.InvalidRetention;
    }
    if (object.get("on_remove")) |value| {
        record.on_remove = OnRemove.parse(stringValue(value) orelse return error.WrongType) orelse return error.InvalidOnRemove;
    }
    if (object.get("worktrees")) |value| {
        record.worktrees = boolValue(value) orelse return error.WrongType;
    }
    if (object.get("gitwatch")) |value| {
        record.gitwatch = boolValue(value) orelse return error.WrongType;
    }
    if (object.get("on_worktree")) |value| {
        record.on_worktree = OnWorktree.parse(stringValue(value) orelse return error.WrongType) orelse return error.InvalidOnWorktree;
    }
    record.socket = try optionalString(object, "socket");
    record.served_by = try optionalString(object, "served_by");
    record.created_at = try optionalString(object, "created_at");
    return record;
}
const testing = std.testing;

fn scratchPath(arena: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try dir.realPath(io, &buffer);
    return std.fmt.allocPrint(arena, "{s}{c}{s}", .{ buffer[0..count], std.fs.path.sep, name });
}

test "a written list reads back with every field intact" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try scratchPath(arena, tmp.dir, io, "roots.json");
    var registry = Registry.init(arena, path);
    defer registry.deinit();
    registry.defaults = .{
        .mode = .always,
        .idle_timeout_ms = 1_000,
        .on_remove = .delete,
        .retention = .{ .max_batches = 4, .max_bytes = 1024 },
        .worktrees = false,
        .gitwatch = true,
    };

    try registry.add("/home/u/app", "a1b2c3d4", "/run/user/1000/fsmeta/roots/a1b2c3d4.sock", .{
        .mode = .auto,
        .idle_timeout_ms = 300_000,
        .retention = .{ .max_batches = 32, .max_bytes = 64 * 1024 * 1024 },
        .on_remove = .keep,
        .worktrees = false,
        .gitwatch = true,
    }, "2026-10-26T06:50:00Z");
    try registry.add("/home/u/lib", "deadbeef", "/run/user/1000/fsmeta/roots/deadbeef.sock", .{
        .mode = .off,
        .idle_timeout_ms = 0,
        .retention = .{ .max_batches = 8, .max_bytes = 4096 },
        .on_remove = .delete,
        .worktrees = true,
        .gitwatch = false,
    }, "2026-10-26T06:51:00Z");
    try registry.save(io);

    var loaded = Registry.init(arena, path);
    defer loaded.deinit();
    try loaded.load(io);
    try testing.expectEqual(@as(usize, 0), loaded.diagnostics.items.len);
    try testing.expectEqual(@as(usize, 2), loaded.records.items.len);
    // The defaults block survives too, so a later add copies what the person configured, not a built-in.
    try testing.expectEqual(state.Mode.always, loaded.defaults.mode);
    try testing.expectEqual(@as(u64, 1_000), loaded.defaults.idle_timeout_ms);
    try testing.expectEqual(OnRemove.delete, loaded.defaults.on_remove);
    try testing.expectEqual(false, loaded.defaults.worktrees);
    try testing.expectEqual(true, loaded.defaults.gitwatch);

    const first = loaded.records.items[0];
    try testing.expectEqualStrings("a1b2c3d4", first.id);
    try testing.expectEqualStrings("/home/u/app", first.root);
    try testing.expectEqual(state.Mode.auto, first.mode);
    try testing.expectEqual(@as(u64, 300_000), first.idle_timeout_ms);
    try testing.expectEqual(@as(u64, 32), first.retention.max_batches);
    try testing.expectEqual(@as(u64, 64 * 1024 * 1024), first.retention.max_bytes);
    try testing.expectEqual(OnRemove.keep, first.on_remove);
    try testing.expectEqual(false, first.worktrees);
    try testing.expectEqual(true, first.gitwatch);
    try testing.expectEqualStrings("/run/user/1000/fsmeta/roots/a1b2c3d4.sock", first.socket);
    try testing.expectEqualStrings("inproc", first.served_by);
    try testing.expectEqualStrings("2026-10-26T06:50:00Z", first.created_at);

    const second = loaded.records.items[1];
    try testing.expectEqual(state.Mode.off, second.mode);
    try testing.expectEqual(@as(u64, 0), second.idle_timeout_ms);
    try testing.expectEqual(OnRemove.delete, second.on_remove);
    try testing.expectEqual(true, second.worktrees);
    try testing.expectEqual(false, second.gitwatch);

    const bytes = try loaded.encode();
    defer arena.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"version\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"roots\": [") != null);
}

test "a missing file is a valid empty list, not an error" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try scratchPath(arena, tmp.dir, io, "does-not-exist.json");
    var registry = Registry.init(arena, path);
    defer registry.deinit();
    try registry.load(io);
    try testing.expectEqual(@as(usize, 0), registry.records.items.len);
    try testing.expectEqual(@as(usize, 0), registry.diagnostics.items.len);
    try testing.expectEqual(state.Mode.auto, registry.defaults.mode);
}

test "a malformed record is reported and skipped, and the good ones still load" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try scratchPath(arena, tmp.dir, io, "roots.json");
    try tmp.dir.writeFile(io, .{ .sub_path = "roots.json", .data = 
        \\{"version":1,"defaults":{"mode":"auto"},
        \\ "roots":[
        \\   {"id":"a1b2c3d4","root":"/home/u/app","mode":"auto","idle_timeout_ms":300000},
        \\   {"id":"nothex!!","root":"/home/u/bad"},
        \\   {"id":"deadbeef","root":"/home/u/good","mode":"nonsense"},
        \\   {"id":"0badc0de","root":"/home/u/fine","mode":"off","on_remove":"delete"}
        \\ ]}
    });

    var registry = Registry.init(arena, path);
    defer registry.deinit();
    try registry.load(io);

    try testing.expectEqual(@as(usize, 2), registry.records.items.len);
    try testing.expectEqual(@as(usize, 2), registry.diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, registry.diagnostics.items[0], "skipped") != null);
    try testing.expectEqualStrings("a1b2c3d4", registry.records.items[0].id);
    try testing.expectEqualStrings("0badc0de", registry.records.items[1].id);
    try testing.expectEqual(state.Mode.off, registry.records.items[1].mode);
    try testing.expectEqual(OnRemove.delete, registry.records.items[1].on_remove);
    // A record written before the switches existed reads as "on": the default is the documented behaviour, and
    // an old list must not silently opt a root out of handling it never heard about.
    try testing.expectEqual(true, registry.records.items[0].worktrees);
    try testing.expectEqual(true, registry.records.items[0].gitwatch);
    try testing.expectEqual(true, registry.records.items[1].worktrees);
}

test "a save replaces the whole document and leaves no temporary behind" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try scratchPath(arena, tmp.dir, io, "roots.json");
    var registry = Registry.init(arena, path);
    defer registry.deinit();
    try registry.add("/home/u/one", "11111111", "/run/one.sock", .{}, "2026-01-01T00:00:00Z");
    try registry.save(io);

    var loaded = Registry.init(arena, path);
    defer loaded.deinit();
    try loaded.load(io);
    try testing.expectEqual(@as(usize, 1), loaded.records.items.len);

    // Mutate and save again: the second document replaces the first, it does not merge with it.
    loaded.records.items[0].mode = .always;
    try loaded.add("/home/u/two", "22222222", "/run/two.sock", .{}, "2026-01-01T00:00:01Z");
    try loaded.save(io);

    var reloaded = Registry.init(arena, path);
    defer reloaded.deinit();
    try reloaded.load(io);
    try testing.expectEqual(@as(usize, 2), reloaded.records.items.len);
    try testing.expectEqual(state.Mode.always, reloaded.records.items[0].mode);

    // The rename is atomic, so the temporary never survives a successful save.
    var dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path).?, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}

test "a record is found by id or by path, and removing one keeps the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = Registry.init(arena, "/nowhere/roots.json");
    defer registry.deinit();
    try registry.add("/home/u/app", "a1b2c3d4", "/run/a.sock", .{}, "2026-01-01T00:00:00Z");
    try registry.add("/home/u/lib", "deadbeef", "/run/b.sock", .{}, "2026-01-01T00:00:00Z");

    try testing.expectEqual(@as(?usize, 0), registry.find("a1b2c3d4"));
    try testing.expectEqual(@as(?usize, 1), registry.find("/home/u/lib"));
    try testing.expectEqual(@as(?usize, null), registry.find("cafebabe"));

    const index = registry.find("a1b2c3d4").?;
    registry.removeAt(index);
    try testing.expectEqual(@as(usize, 1), registry.records.items.len);
    try testing.expectEqualStrings("deadbeef", registry.records.items[0].id);
    try testing.expectEqual(@as(?usize, null), registry.find("a1b2c3d4"));
}
