// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `files.json` — the sidekick that makes the binary file headerless (§ 7 of `FORMAT.md`).
//!
//! Reading keeps the whole document as a `std.json.Value`: the spec says unknown keys are preserved by a
//! rewriter, and a typed struct would drop them. Writing is hand-rolled rather than delegated to `std.json`
//! because the emitted bytes are part of what the conformance vectors pin — key order and indentation included —
//! and a formatter change must not silently move them.

const std = @import("std");
const format = @import("format.zig");

pub const Value = std.json.Value;
pub const Map = std.json.ObjectMap;

/// Thrown for a document that is well-formed JSON but not the document this format describes (§ 8 check 1).
pub const Invalid = error{Invalid, OutOfMemory};

pub const ScanFields = struct {
    hash_mode: []const u8,
    ignored_dir_names: []const []const u8,
    respect_gitignore: bool,
    /// The nested-repository boundary rule was applied in this pass (`plans/worktrees.md` § 4). The reference
    /// engine always writes `true`; the key is **optional**, and absent means "the writer did not apply the
    /// rule", never "there was no nested repository". A port writer that does not implement the rule omits it.
    nested_repos: ?bool = null,
    /// The ignore sources actually in effect in this pass, in precedence order — `gitignore`, `info/exclude`,
    /// `fs-meta/ignore` (`plans/worktrees.md` § 5, § 5g). A source whose file is absent is omitted. Optional and
    /// additive: a reader that does not know the key ignores it, and a writer that did not read the sources omits
    /// the key rather than claiming an empty list.
    ignore_sources: ?[]const []const u8 = null,
};

/// A batch records itself (§ 17.2): the generation it produces, the one it follows, and the counts its entries
/// must agree with. Absent from the main meta.
pub const BatchFields = struct {
    number: u64,
    parent: u64,
    added: u64,
    changed: u64,
    deleted: u64,
};

/// One direct child of the root and where its subtree sits in `files.txt` (§ 18). `name` has no trailing slash:
/// the key is the folder's path, and the slash belongs to the text layout the range addresses.
pub const RootFields = struct {
    name: []const u8,
    offset: u64,
    length: u64,
};

pub const Fields = struct {
    generation: u64,
    count: u64,
    meta_bytes: u64,
    txt_bytes: u64,
    meta_hash: u64,
    txt_hash: u64,
    /// `"none"`, `"lf"` or `"text"` (§ 12).
    normalize: []const u8,
    root_dev: u64,
    root_ino: u64,
    created: []const u8,
    updated: []const u8,
    writer: []const u8,
    scan: ?ScanFields = null,
    /// The direct children of the root (§ 18). A writer that can compute it emits it, an empty map included: "this
    /// tree has no folders" is a fact, and it is not the same statement as "nobody computed the ranges".
    roots: ?[]const RootFields = null,
    /// Present only in a batch trio (§ 17.2).
    batch: ?BatchFields = null,
};

/// The document a publish writes: `FORMAT.md` § 7's keys, in the order a reader sees them.
pub fn encode(gpa: std.mem.Allocator, fields: Fields) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n");
    try writer.writeAll("  \"format\": \"fs-meta\",\n");
    try writer.writeAll("  \"version\": 1,\n");
    try writer.writeAll("  \"entrySize\": 64,\n");
    try writer.writeAll("  \"order\": \"utf8-bytes\",\n");
    try writer.print("  \"generation\": {d},\n", .{fields.generation});
    try writer.print("  \"count\": {d},\n", .{fields.count});
    try writer.print("  \"meta\": {{ \"bytes\": {d}, \"wyhash\": \"{x:0>16}\" }},\n", .{ fields.meta_bytes, fields.meta_hash });
    try writer.print("  \"txt\": {{ \"bytes\": {d}, \"wyhash\": \"{x:0>16}\" }},\n", .{ fields.txt_bytes, fields.txt_hash });
    if (fields.roots) |roots| {
        // § 18: keyed by the direct child's name, in the order the text layout gave them, which is name order.
        if (roots.len == 0) {
            try writer.writeAll("  \"roots\": {},\n");
        } else {
            try writer.writeAll("  \"roots\": {\n");
            for (roots, 0..) |root, index| {
                try writer.writeAll("    ");
                try writeString(writer, root.name);
                try writer.print(": {{ \"offset\": {d}, \"length\": {d} }}", .{ root.offset, root.length });
                try writer.writeAll(if (index + 1 == roots.len) "\n" else ",\n");
            }
            try writer.writeAll("  },\n");
        }
    }

    try writer.writeAll("  \"hash\": { \"content\": \"wyhash64\", \"name\": \"wyhash64\", \"seed\": 0");
    try writer.writeAll(", \"normalize\": ");
    try writeString(writer, fields.normalize);
    try writer.writeAll(" },\n");

    try writer.print("  \"root\": {{ \"dev\": {d}, \"ino\": {d} }},\n", .{ fields.root_dev, fields.root_ino });
    if (fields.batch) |batch| {
        try writer.print("  \"batch\": {{ \"number\": {d}, \"parent\": {d}, \"added\": {d}, \"changed\": {d}, \"deleted\": {d} }},\n",
            .{ batch.number, batch.parent, batch.added, batch.changed, batch.deleted });
    }
    if (fields.scan) |scan| {
        try writer.writeAll("  \"scan\": { \"hashMode\": ");
        try writeString(writer, scan.hash_mode);
        try writer.writeAll(", \"ignoredDirectoryNames\": [");
        for (scan.ignored_dir_names, 0..) |name, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeString(writer, name);
        }
        try writer.writeAll("], \"respectGitignore\": ");
        try writer.writeAll(if (scan.respect_gitignore) "true" else "false");
        if (scan.nested_repos) |nested| {
            try writer.writeAll(", \"nestedRepos\": ");
            try writer.writeAll(if (nested) "true" else "false");
        }
        if (scan.ignore_sources) |sources| {
            try writer.writeAll(", \"ignoreSources\": [");
            for (sources, 0..) |source, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeString(writer, source);
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(" },\n");
    }
    try writer.writeAll("  \"created\": ");
    try writeString(writer, fields.created);
    try writer.writeAll(",\n  \"updated\": ");
    try writeString(writer, fields.updated);
    try writer.writeAll(",\n  \"writer\": ");
    try writeString(writer, fields.writer);
    try writer.writeAll("\n}\n");

    return out.toOwnedSlice();
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

// --------------------------------------------------------------------------------------------- reading

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, gpa, bytes, .{});
}

fn field(map: *const Map, key: []const u8) Invalid!Value {
    return map.get(key) orelse error.Invalid;
}

/// A required object member, as a pointer **into** the document. The map is self-referential once it is
/// initialised, so a pointer to a copy of it (a by-value `Value`) is not a usable map — hence `getPtr`.
pub fn objectField(map: *const Map, key: []const u8) Invalid!*const Map {
    const value = map.getPtr(key) orelse return error.Invalid;
    return switch (value.*) {
        .object => |*object| object,
        else => error.Invalid,
    };
}

pub fn stringField(map: *const Map, key: []const u8) Invalid![]const u8 {
    return switch (try field(map, key)) {
        .string => |s| s,
        else => error.Invalid,
    };
}

pub fn optionalString(map: *const Map, key: []const u8) ?[]const u8 {
    return switch (map.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn intField(map: *const Map, key: []const u8) Invalid!u64 {
    const value = try field(map, key);
    return switch (value) {
        .integer => |i| if (i < 0) error.Invalid else @intCast(i),
        else => error.Invalid,
    };
}

pub fn optionalInt(map: *const Map, key: []const u8) ?u64 {
    return switch (map.get(key) orelse return null) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

/// A `wyhash` member: exactly sixteen lowercase hex characters (§ 8 check 1).
pub fn hexField(map: *const Map, key: []const u8) Invalid!u64 {
    const text = try stringField(map, key);
    if (text.len != 16) return error.Invalid;
    var value: u64 = 0;
    for (text) |byte| {
        const digit: u64 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            else => return error.Invalid,
        };
        value = (value << 4) | digit;
    }
    return value;
}

pub fn boolField(map: *const Map, key: []const u8) Invalid!bool {
    return switch (try field(map, key)) {
        .bool => |b| b,
        else => error.Invalid,
    };
}

pub fn optionalBool(map: *const Map, key: []const u8) ?bool {
    return switch (map.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

test "the emitted document has the keys § 7 requires, and reads back" {
    const gpa = std.testing.allocator;
    const bytes = try encode(gpa, .{
        .generation = 3,
        .count = 2,
        .meta_bytes = 128,
        .txt_bytes = 17,
        .meta_hash = 0x7b68e5cf8b010000,
        .txt_hash = 0x1234abcd5678ef90,
        .normalize = "text",
        .root_dev = 16_777_220,
        .root_ino = 1,
        .created = "2026-10-17T00:00:00Z",
        .updated = "2026-10-17T00:00:01Z",
        .writer = "fs-meta/1",
        .scan = .{
            .hash_mode = "text",
            .ignored_dir_names = &.{ ".git", ".fs-meta" },
            .respect_gitignore = true,
            .nested_repos = true,
            .ignore_sources = &.{ "gitignore", "info/exclude", "fs-meta/ignore" },
        },
    });
    defer gpa.free(bytes);

    var parsed = try parse(gpa, bytes);
    defer parsed.deinit();
    const root = &parsed.value.object;

    try std.testing.expectEqualStrings("fs-meta", try stringField(root, "format"));
    try std.testing.expectEqual(@as(u64, 1), try intField(root, "version"));
    try std.testing.expectEqual(@as(u64, 64), try intField(root, "entrySize"));
    try std.testing.expectEqual(@as(u64, 3), try intField(root, "generation"));
    try std.testing.expectEqual(@as(u64, 2), try intField(root, "count"));
    const meta = try objectField(root, "meta");
    try std.testing.expectEqual(@as(u64, 128), try intField(meta, "bytes"));
    try std.testing.expectEqual(@as(u64, 0x7b68e5cf8b010000), try hexField(meta, "wyhash"));
    const txt = try objectField(root, "txt");
    try std.testing.expectEqual(@as(u64, 17), try intField(txt, "bytes"));
    try std.testing.expectEqual(@as(u64, 0x1234abcd5678ef90), try hexField(txt, "wyhash"));
    const hash = try objectField(root, "hash");
    try std.testing.expectEqualStrings("wyhash64", try stringField(hash, "content"));
    try std.testing.expectEqualStrings("wyhash64", try stringField(hash, "name"));
    try std.testing.expectEqual(@as(u64, 0), try intField(hash, "seed"));
    try std.testing.expectEqualStrings("text", try stringField(hash, "normalize"));
    const root_identity = try objectField(root, "root");
    try std.testing.expectEqual(@as(u64, 16_777_220), try intField(root_identity, "dev"));
    try std.testing.expectEqual(@as(u64, 1), try intField(root_identity, "ino"));
    // A trio describes a workspace, not a path: no member carries one (§ 3, § 7).
    try std.testing.expect(root.get("rootPath") == null);
    try std.testing.expectEqualStrings("fs-meta/1", try stringField(root, "writer"));
    // The two additive scan keys are written by the reference engine and remain readable as the values they are.
    const scan = try objectField(root, "scan");
    try std.testing.expectEqual(true, try boolField(scan, "nestedRepos"));
    const ignore_sources = scan.get("ignoreSources").?.array;
    try std.testing.expectEqual(@as(usize, 3), ignore_sources.items.len);
    try std.testing.expectEqualStrings("info/exclude", ignore_sources.items[1].string);

    // A `wyhash` member that is not sixteen lowercase hex characters is not this document.
    try std.testing.expectError(error.Invalid, hexField(meta, "nope"));
}

test "unknown keys survive a read and a rewrite of the same value" {
    const gpa = std.testing.allocator;
    var parsed = try parse(gpa,
        \\{"format":"fs-meta","version":1,"entrySize":64,"count":0,
        \\ "meta":{"bytes":0,"wyhash":"0000000000000000"},
        \\ "txt":{"bytes":0,"wyhash":"0000000000000000"},
        \\ "hash":{"content":"wyhash64","name":"wyhash64","seed":0},
        \\ "somethingNew":{"kept":true}}
    );
    defer parsed.deinit();
    const root = &parsed.value.object;
    try std.testing.expect(root.get("somethingNew") != null);
    try std.testing.expectEqual(@as(u64, 0), try intField(root, "count"));
}

// `rootPath` used to be the field this test exercised; the escaping rules belong to `writeString`, which every
// string member goes through, so the test moved to `writer` rather than testing a field that no longer exists.
test "a string member is escaped correctly" {
    const gpa = std.testing.allocator;
    const escaped = "C:\\a \"quoted\" path\nnext";
    const bytes = try encode(gpa, .{
        .generation = 0,
        .count = 0,
        .meta_bytes = 0,
        .txt_bytes = 0,
        .meta_hash = 0,
        .txt_hash = 0,
        .normalize = "none",
        .root_dev = 0,
        .root_ino = 0,
        .created = "x",
        .updated = "y",
        .writer = escaped,
    });
    defer gpa.free(bytes);
    var parsed = try parse(gpa, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(escaped, optionalString(&parsed.value.object, "writer").?);
}

test "a batch block is emitted when present, and absent from the main meta" {
    const gpa = std.testing.allocator;
    const fields = Fields{
        .generation = 14,
        .count = 3,
        .meta_bytes = 192,
        .txt_bytes = 21,
        .meta_hash = 0x1234,
        .txt_hash = 0x5678,
        .normalize = "text",
        .root_dev = 1,
        .root_ino = 2,
        .created = "2026-10-19T00:00:00Z",
        .updated = "2026-10-19T00:00:00Z",
        .writer = "fsmeta-zig/1",
        .batch = .{ .number = 14, .parent = 13, .added = 1, .changed = 1, .deleted = 1 },
    };
    const with_batch = try encode(gpa, fields);
    defer gpa.free(with_batch);
    try std.testing.expect(std.mem.indexOf(u8, with_batch, "\"batch\": { \"number\": 14, \"parent\": 13, \"added\": 1, \"changed\": 1, \"deleted\": 1 }") != null);

    var plain = fields;
    plain.batch = null;
    const without_batch = try encode(gpa, plain);
    defer gpa.free(without_batch);
    try std.testing.expect(std.mem.indexOf(u8, without_batch, "\"batch\"") == null);
}

test "a roots map is emitted when present, an empty one too, and absent otherwise" {
    const gpa = std.testing.allocator;
    var fields = Fields{
        .generation = 2,
        .count = 3,
        .meta_bytes = 192,
        .txt_bytes = 21,
        .meta_hash = 0x1234,
        .txt_hash = 0x5678,
        .normalize = "text",
        .root_dev = 1,
        .root_ino = 2,
        .created = "2026-10-20T00:00:00Z",
        .updated = "2026-10-20T00:00:00Z",
        .writer = "fsmeta-zig/1",
    };

    // Nothing to say about the tree's folders and nothing claimed (§ 18: the map is optional).
    const without = try encode(gpa, fields);
    defer gpa.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "\"roots\"") == null);

    fields.roots = &.{
        .{ .name = "docs", .offset = 0, .length = 18 },
        .{ .name = "src", .offset = 18, .length = 12 },
    };
    const with_roots = try encode(gpa, fields);
    defer gpa.free(with_roots);
    try std.testing.expect(std.mem.indexOf(u8, with_roots,
        "  \"roots\": {\n" ++
            "    \"docs\": { \"offset\": 0, \"length\": 18 },\n" ++
            "    \"src\": { \"offset\": 18, \"length\": 12 }\n" ++
            "  },\n") != null);

    // And it reads back as the object it is, keyed by the child's name.
    var parsed = try parse(gpa, with_roots);
    defer parsed.deinit();
    const roots = try objectField(&parsed.value.object, "roots");
    const src = try objectField(roots, "src");
    try std.testing.expectEqual(@as(u64, 18), try intField(src, "offset"));
    try std.testing.expectEqual(@as(u64, 12), try intField(src, "length"));

    // An empty map is the statement "computed, and this tree has no folders" — not the same as no map at all.
    fields.roots = &.{};
    const empty = try encode(gpa, fields);
    defer gpa.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "  \"roots\": {},\n") != null);
}
