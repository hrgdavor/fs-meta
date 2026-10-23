// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! § 8 of `FORMAT.md`: does this trio describe one generation, and is every byte of it the byte the sidekick
//! claims? The checks run in the order the document lists them, and the first failure is the verdict — which is
//! what makes two different readers reach the same name for the same broken trio.
//!
//! The function allocates only for the entry array and for `detail`; it never touches the file system, so a
//! reader that has the three byte slices can call it without having a directory.

const std = @import("std");
const format = @import("format.zig");
const json = @import("json_doc.zig");

/// The vocabulary of § 8. The wire strings are the contract: output, tests and the vectors all use them.
pub const Verdict = enum {
    ok,
    unsupported_format,
    unsupported_version,
    unsupported_entry_size,
    unsupported_hash,
    meta_size_mismatch,
    meta_hash_mismatch,
    txt_size_mismatch,
    txt_hash_mismatch,
    entry_out_of_range,
    name_hash_mismatch,
    invalid_flags,

    pub fn wire(self: Verdict) []const u8 {
        return switch (self) {
            .ok => "ok",
            .unsupported_format => "unsupported-format",
            .unsupported_version => "unsupported-version",
            .unsupported_entry_size => "unsupported-entry-size",
            .unsupported_hash => "unsupported-hash",
            .meta_size_mismatch => "meta-size-mismatch",
            .meta_hash_mismatch => "meta-hash-mismatch",
            .txt_size_mismatch => "txt-size-mismatch",
            .txt_hash_mismatch => "txt-hash-mismatch",
            .entry_out_of_range => "entry-out-of-range",
            .name_hash_mismatch => "name-hash-mismatch",
            .invalid_flags => "invalid-flags",
        };
    }

    /// § 8: any failing verdict means the trio is not usable and the reader falls back to the file system.
    pub fn usable(self: Verdict) bool {
        return self == .ok;
    }
};

pub const Input = struct {
    json_bytes: []const u8,
    meta_bytes: []const u8,
    txt_bytes: []const u8,
};

pub const Outcome = struct {
    verdict: Verdict = .ok,
    /// A human sentence for the first failure; empty on `ok`.
    detail: []const u8 = "",
    count: u64 = 0,
    /// One per entry, in `files.txt` order — only on `ok`.
    entries: []const format.Entry = &.{},
    /// The name each entry points at, a slice of `input.txt_bytes` — only on `ok`.
    names: []const []const u8 = &.{},
};

fn fail(arena: std.mem.Allocator, verdict: Verdict, comptime wording: []const u8, args: anytype) !Outcome {
    return .{
        .verdict = verdict,
        .detail = try std.fmt.allocPrint(arena, wording, args),
    };
}

pub fn validate(arena: std.mem.Allocator, input: Input) !Outcome {
    // 1 — the document parses and carries the required keys with the right types.
    var parsed = json.parse(arena, input.json_bytes) catch
        return fail(arena, .unsupported_format, "files.json is not valid JSON", .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return fail(arena, .unsupported_format, "files.json is not a JSON object", .{}),
    };
    const format_name = json.stringField(root, "format") catch
        return fail(arena, .unsupported_format, "files.json has no string 'format'", .{});
    const version = json.intField(root, "version") catch
        return fail(arena, .unsupported_format, "files.json has no integer 'version'", .{});
    const entry_size = json.intField(root, "entrySize") catch
        return fail(arena, .unsupported_format, "files.json has no integer 'entrySize'", .{});
    const count = json.intField(root, "count") catch
        return fail(arena, .unsupported_format, "files.json has no integer 'count'", .{});
    const meta = json.objectField(root, "meta") catch
        return fail(arena, .unsupported_format, "files.json has no object 'meta'", .{});
    const meta_declared = json.intField(meta, "bytes") catch
        return fail(arena, .unsupported_format, "meta.bytes is not an integer", .{});
    const meta_hash = json.hexField(meta, "wyhash") catch
        return fail(arena, .unsupported_format, "meta.wyhash is not sixteen lowercase hex characters", .{});
    const txt = json.objectField(root, "txt") catch
        return fail(arena, .unsupported_format, "files.json has no object 'txt'", .{});
    const txt_declared = json.intField(txt, "bytes") catch
        return fail(arena, .unsupported_format, "txt.bytes is not an integer", .{});
    const txt_hash = json.hexField(txt, "wyhash") catch
        return fail(arena, .unsupported_format, "txt.wyhash is not sixteen lowercase hex characters", .{});
    const hash = json.objectField(root, "hash") catch
        return fail(arena, .unsupported_format, "files.json has no object 'hash'", .{});
    const hash_content = json.stringField(hash, "content") catch
        return fail(arena, .unsupported_format, "hash.content is not a string", .{});
    const hash_name = json.stringField(hash, "name") catch
        return fail(arena, .unsupported_format, "hash.name is not a string", .{});
    const hash_seed = json.intField(hash, "seed") catch
        return fail(arena, .unsupported_format, "hash.seed is not an integer", .{});

    // 2 — the format name.
    if (!std.mem.eql(u8, format_name, format.name)) {
        return fail(arena, .unsupported_format, "format is '{s}', not 'fs-meta'", .{format_name});
    }

    // 3 — the version.
    if (version != format.version) {
        return fail(arena, .unsupported_version, "version {d} is not this reader's {d}", .{ version, format.version });
    }

    // 4 — the entry size.
    if (entry_size != format.entry_size) {
        return fail(arena, .unsupported_entry_size, "entrySize {d} is not {d}", .{ entry_size, format.entry_size });
    }

    // 5 — the hash fields.
    if (!std.mem.eql(u8, hash_content, format.hash_algo) or !std.mem.eql(u8, hash_name, format.hash_algo)) {
        return fail(arena, .unsupported_hash, "hash.content/name are not '{s}'", .{format.hash_algo});
    }
    if (hash_seed != format.hash_seed) {
        return fail(arena, .unsupported_hash, "hash.seed is {d}, not {d}", .{ hash_seed, format.hash_seed });
    }
    if (json.optionalString(hash, "normalize")) |normalize| {
        if (!std.mem.eql(u8, normalize, "none") and !std.mem.eql(u8, normalize, "lf") and !std.mem.eql(u8, normalize, "text")) {
            return fail(arena, .unsupported_hash, "hash.normalize '{s}' is not none/lf/text", .{normalize});
        }
    }

    // 6 — the meta file's size, before its hash.
    if (input.meta_bytes.len % format.entry_size != 0) {
        return fail(arena, .meta_size_mismatch, "files.meta is {d} bytes, not a multiple of {d}", .{ input.meta_bytes.len, format.entry_size });
    }
    if (meta_declared != input.meta_bytes.len or meta_declared != count << 6) {
        return fail(arena, .meta_size_mismatch,
            "meta.bytes is {d}, files.meta is {d}, count<<6 is {d}", .{ meta_declared, input.meta_bytes.len, count << 6 });
    }
    // 6b — then its whole-file hash.
    if (format.wyhash(input.meta_bytes) != meta_hash) {
        return fail(arena, .meta_hash_mismatch, "wyhash(files.meta) is {x:0>16}, meta.wyhash says {x:0>16}",
            .{ format.wyhash(input.meta_bytes), meta_hash });
    }

    // 7 — the text file's size and line structure.
    if (txt_declared != input.txt_bytes.len) {
        return fail(arena, .txt_size_mismatch, "txt.bytes is {d}, files.txt is {d}", .{ txt_declared, input.txt_bytes.len });
    }
    var lines: u64 = 0;
    for (input.txt_bytes) |byte| {
        if (byte == '\n') lines += 1;
    }
    if (lines != count) {
        return fail(arena, .txt_size_mismatch, "files.txt has {d} LF, count says {d}", .{ lines, count });
    }
    if (count > 0 and input.txt_bytes[input.txt_bytes.len - 1] != '\n') {
        return fail(arena, .txt_size_mismatch, "files.txt does not end with LF", .{});
    }
    // 7b — then its whole-file hash.
    if (format.wyhash(input.txt_bytes) != txt_hash) {
        return fail(arena, .txt_hash_mismatch, "wyhash(files.txt) is {x:0>16}, txt.wyhash says {x:0>16}",
            .{ format.wyhash(input.txt_bytes), txt_hash });
    }

    // 8 — every entry's name slice is inside files.txt, non-empty and LF-terminated.
    const entry_count: usize = @intCast(count);
    const entries = try arena.alloc(format.Entry, entry_count);
    for (entries, 0..) |*entry, index| {
        const at = index * 64;
        var bytes: [format.entry_size]u8 = undefined;
        @memcpy(&bytes, input.meta_bytes[at..][0..format.entry_size]);
        entry.* = format.Entry.decode(&bytes);

        if (entry.name_length == 0) {
            return fail(arena, .entry_out_of_range, "entry {d} has nameLength 0", .{index});
        }
        const end = entry.name_offset + entry.name_length;
        if (end + 1 > input.txt_bytes.len) {
            return fail(arena, .entry_out_of_range,
                "entry {d} names bytes {d}..{d} of a {d}-byte files.txt", .{ index, entry.name_offset, end, input.txt_bytes.len });
        }
        if (input.txt_bytes[end] != '\n') {
            return fail(arena, .entry_out_of_range, "entry {d} is not followed by LF at {d}", .{ index, end });
        }
    }

    // 9 — the name at that slice is the name the entry hashed.
    const names = try arena.alloc([]const u8, entry_count);
    for (entries, 0..) |entry, index| {
        const start: usize = @intCast(entry.name_offset);
        const name = input.txt_bytes[start .. start + entry.name_length];
        names[index] = name;
        if (nameHashFor(entry, name) != entry.name_hash) {
            return fail(arena, .name_hash_mismatch, "entry {d} ({s}): wyhash(name) is {x:0>16}, nameHash says {x:0>16}",
                .{ index, name, format.wyhash(name), entry.name_hash });
        }
    }

    // 10 — the flags: exactly one kind bit, nothing undefined, and the per-kind rules of § 6.
    for (entries, 0..) |entry, index| {
        if (!format.flags.valid(entry.flags_word)) {
            return fail(arena, .invalid_flags, "entry {d} ({s}) has flags 0x{x:0>2}", .{ index, names[index], entry.flags_word });
        }
        switch (entry.kind().?) {
            .dir, .symlink => {
                if (entry.contentKnown()) {
                    return fail(arena, .invalid_flags, "entry {d} ({s}) is a directory or symlink with CONTENT_KNOWN",
                        .{ index, names[index] });
                }
            },
            .regular_file => {},
        }
        if (!entry.contentKnown() and entry.hashLf()) {
            return fail(arena, .invalid_flags, "entry {d} ({s}) sets HASH_LF without CONTENT_KNOWN", .{ index, names[index] });
        }
    }

    return .{ .verdict = .ok, .count = count, .entries = entries, .names = names };
}

// --------------------------------------------------------------------------------------------- tests

const Trio = struct {
    gpa: std.mem.Allocator,
    entries: []format.Entry,
    names: []const []const u8,
    txt: []u8,
    meta: []u8,
    fields: json.Fields,

    fn deinit(self: *Trio) void {
        self.gpa.free(self.txt);
        self.gpa.free(self.meta);
        self.gpa.free(self.entries);
    }

    fn input(self: *Trio, arena: std.mem.Allocator) !Input {
        return .{ .json_bytes = try json.encode(arena, self.fields), .meta_bytes = self.meta, .txt_bytes = self.txt };
    }
};

/// A trio that § 8 accepts: two files and a directory, hashed, sorted by name.
fn validTrio(gpa: std.mem.Allocator) !Trio {
    const names = [_][]const u8{ "a.txt", "src", "src/b.java" };
    const contents = [_][]const u8{ "hello\n", "", "class B {}\n" };
    const kinds = [_]format.Kind{ .regular_file, .dir, .regular_file };
    const mtimes = [_]u64{ 1_700_000_000_123_000_000, 1_700_000_001_000_000_000, 1_700_000_001_456_000_000 };

    const txt = try gpa.alloc(u8, 5 + 1 + 3 + 1 + 10 + 1);
    var txt_len: usize = 0;
    const entries = try gpa.alloc(format.Entry, names.len);
    var offset: u64 = 0;
    for (names, 0..) |name, index| {
        @memcpy(txt[txt_len..][0..name.len], name);
        txt_len += name.len;
        txt[txt_len] = '\n';
        txt_len += 1;

        const content_hash: u64 = switch (kinds[index]) {
            .regular_file => format.wyhash(contents[index]),
            else => 0,
        };
        entries[index] = .{
            .mtime_ns = mtimes[index],
            .size_bytes = if (kinds[index] == .regular_file) contents[index].len else 0,
            .content_hash = content_hash,
            .name_hash = format.wyhash(name),
            .name_offset = offset,
            .name_length = @intCast(name.len),
            .flags_word = switch (kinds[index]) {
                .dir => format.flags.is_dir,
                .symlink => format.flags.symlink,
                .regular_file => format.flags.regular_file | format.flags.content_known,
            },
            .file_id_lo = 1000 + index,
            .file_id_hi = 42,
        };
        offset += name.len + 1;
    }

    const meta = try gpa.alloc(u8, entries.len * 64);
    for (entries, 0..) |entry, index| {
        entry.encode(meta[index * 64 ..][0..64]);
    }

    return .{
        .gpa = gpa,
        .entries = entries,
        .names = &names,
        .txt = txt[0..txt_len],
        .meta = meta,
        .fields = .{
            .generation = 1,
            .count = names.len,
            .meta_bytes = meta.len,
            .txt_bytes = txt_len,
            .meta_hash = format.wyhash(meta),
            .txt_hash = format.wyhash(txt[0..txt_len]),
            .normalize = "text",
            .root_dev = 42,
            .root_ino = 1,
            .created = "2026-10-17T00:00:00Z",
            .updated = "2026-10-17T00:00:01Z",
            .writer = "fs-meta/1",
        },
    };
}

test "a valid trio is ok, with the entries and names in order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var trio = try validTrio(gpa);
    defer trio.deinit();

    const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
    try std.testing.expectEqual(Verdict.ok, outcome.verdict);
    try std.testing.expectEqual(@as(u64, 3), outcome.count);
    try std.testing.expectEqual(@as(usize, 3), outcome.names.len);
    try std.testing.expectEqualStrings("a.txt", outcome.names[0]);
    try std.testing.expectEqualStrings("src", outcome.names[1]);
    try std.testing.expectEqualStrings("src/b.java", outcome.names[2]);
    try std.testing.expectEqual(format.Kind.dir, outcome.entries[1].kind().?);
}

test "the verdicts, one per check" {
    const gpa = std.testing.allocator;

    // 2/3/4/5: a document the reader does not understand, mutated at the document level.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        const original = try json.encode(gpa, trio.fields);
        defer gpa.free(original);

        const cases = [_]struct { from: []const u8, to: []const u8, verdict: Verdict }{
            .{ .from = "\"format\": \"fs-meta\"", .to = "\"format\": \"other\"", .verdict = .unsupported_format },
            .{ .from = "\"version\": 1", .to = "\"version\": 2", .verdict = .unsupported_version },
            .{ .from = "\"entrySize\": 64", .to = "\"entrySize\": 32", .verdict = .unsupported_entry_size },
            .{ .from = "\"seed\": 0", .to = "\"seed\": 1", .verdict = .unsupported_hash },
            .{ .from = "\"content\": \"wyhash64\"", .to = "\"content\": \"sha256\"", .verdict = .unsupported_hash },
            .{ .from = "\"meta\":", .to = "\"meta\": \"no\"", .verdict = .unsupported_format },
        };
        for (cases) |case| {
            const mutated = try std.mem.replaceOwned(u8, gpa, original, case.from, case.to);
            defer gpa.free(mutated);
            const outcome = try validate(arena.allocator(), .{ .json_bytes = mutated, .meta_bytes = trio.meta, .txt_bytes = trio.txt });
            try std.testing.expectEqual(case.verdict, outcome.verdict);
        }
    }

    // 6: a truncated meta file.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        const outcome = try validate(arena.allocator(), .{
            .json_bytes = try json.encode(arena.allocator(), trio.fields),
            .meta_bytes = trio.meta[0 .. trio.meta.len - 8],
            .txt_bytes = trio.txt,
        });
        try std.testing.expectEqual(Verdict.meta_size_mismatch, outcome.verdict);
    }

    // 6b: the meta bytes changed after the sidekick hashed them.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        trio.meta[0] ^= 0xff;
        const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
        try std.testing.expectEqual(Verdict.meta_hash_mismatch, outcome.verdict);
    }

    // 7: the text file lost its final LF.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        const outcome = try validate(arena.allocator(), .{
            .json_bytes = try json.encode(arena.allocator(), trio.fields),
            .meta_bytes = trio.meta,
            .txt_bytes = trio.txt[0 .. trio.txt.len - 1],
        });
        try std.testing.expectEqual(Verdict.txt_size_mismatch, outcome.verdict);
    }

    // 7b: the text bytes changed after the sidekick hashed them (same length, same LF count).
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        trio.txt[0] = 'b';
        const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
        try std.testing.expectEqual(Verdict.txt_hash_mismatch, outcome.verdict);
    }

    // 8: an entry points past the end of files.txt.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        var entry = trio.entries[0];
        entry.name_offset = 1000;
        entry.encode(trio.meta[0..64]);
        trio.fields.meta_hash = format.wyhash(trio.meta);
        const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
        try std.testing.expectEqual(Verdict.entry_out_of_range, outcome.verdict);
    }

    // 9: a name whose hash disagrees with the entry.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        var entry = trio.entries[0];
        entry.name_hash ^= 1;
        entry.encode(trio.meta[0..64]);
        trio.fields.meta_hash = format.wyhash(trio.meta);
        const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
        try std.testing.expectEqual(Verdict.name_hash_mismatch, outcome.verdict);
    }

    // 10: flags that are not exactly one kind bit, and a directory that claims a fingerprint.
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        var entry = trio.entries[0];
        entry.flags_word = 0;
        entry.encode(trio.meta[0..64]);
        trio.fields.meta_hash = format.wyhash(trio.meta);
        const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
        try std.testing.expectEqual(Verdict.invalid_flags, outcome.verdict);
    }
    {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var trio = try validTrio(gpa);
        defer trio.deinit();
        var entry = trio.entries[1]; // the directory
        entry.flags_word = format.flags.is_dir | format.flags.content_known;
        entry.encode(trio.meta[64..128]);
        trio.fields.meta_hash = format.wyhash(trio.meta);
        const outcome = try validate(arena.allocator(), try trio.input(arena.allocator()));
        try std.testing.expectEqual(Verdict.invalid_flags, outcome.verdict);
    }
}

test "the wire strings are the ones § 8 lists" {
    try std.testing.expectEqualStrings("ok", Verdict.ok.wire());
    try std.testing.expectEqualStrings("unsupported-format", Verdict.unsupported_format.wire());
    try std.testing.expectEqualStrings("meta-hash-mismatch", Verdict.meta_hash_mismatch.wire());
    try std.testing.expectEqualStrings("txt-hash-mismatch", Verdict.txt_hash_mismatch.wire());
    try std.testing.expectEqualStrings("invalid-flags", Verdict.invalid_flags.wire());
    try std.testing.expectEqualStrings("name-hash-mismatch", Verdict.name_hash_mismatch.wire());
    try std.testing.expect(Verdict.ok.usable());
    try std.testing.expect(!Verdict.invalid_flags.usable());
}

/// § 4: a directory entry's stored name carries a trailing slash; the hash is over the name without it,
/// because a lookup is given a path and the path of the folder has no slash.
fn nameHashFor(entry: format.Entry, stored: []const u8) u64 {
    if (entry.kind() == .dir and stored.len > 0 and stored[stored.len - 1] == '/') {
        return format.wyhash(stored[0 .. stored.len - 1]);
    }
    return format.wyhash(stored);
}
