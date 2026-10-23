// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! Batch change sets (FORMAT.md § 17).
//!
//! A batch is the diff between two generations, stored as a trio in the same format: one entry per changed name,
//! carrying exactly one change bit in `flags`. Together with `reconcile.zig` it is what lets a consumer that synced
//! at batch 11 learn what changed by batch 14 without walking the tree.
//!
//! The pair `diff` + `toEvents` is deliberately free of the file system: it takes two generations as `Item`s and
//! returns the change set, and the encode/decode of the trio is the same `format` code the main meta uses. That is
//! what makes a round trip testable without a directory.

const std = @import("std");
const format = @import("format.zig");
const reconcile = @import("reconcile.zig");
const json_doc = @import("json_doc.zig");
const pair = @import("pair.zig");

/// A name that did not exist in the parent generation.
pub const CHANGE_ADDED: u32 = 0x20;
/// A name that existed, and whose entry differs (§ 11).
pub const CHANGE_CHANGED: u32 = 0x40;
/// A name that existed, and is now absent.
pub const CHANGE_DELETED: u32 = 0x80;
/// Exactly one of these is set on every entry in a batch.
pub const CHANGE_MASK: u32 = CHANGE_ADDED | CHANGE_CHANGED | CHANGE_DELETED;

/// One name and its entry, as a generation holds it.
pub const Item = struct {
    name: []const u8,
    entry: format.Entry,
};

/// The change set: entries and their names, aligned and ordered by `(nameHash, name)`.
///
/// `name_offset` and `name_length` are left zero: a batch is written like any trio, and the writer that turns this
/// plan into bytes assigns the offsets from the names it lays out. Keeping that out of `diff` is what lets the
/// comparison be tested against a plan rather than against encoded bytes.
pub const Plan = struct {
    entries: []format.Entry,
    names: [][]const u8,
};

/// The change a batch entry describes, or `null` when its flags carry no change bit or more than one.
pub fn kindOf(entry: format.Entry) ?reconcile.Kind {
    const bits = entry.flags_word & CHANGE_MASK;
    return switch (bits) {
        CHANGE_ADDED => .added,
        CHANGE_CHANGED => .changed,
        CHANGE_DELETED => .deleted,
        else => null,
    };
}

fn entryLessThan(_: void, a: Item, b: Item) bool {
    if (a.entry.name_hash != b.entry.name_hash) return a.entry.name_hash < b.entry.name_hash;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Whether two entries describe the same file (§ 11): the content hash, the size, and the flags.
fn sameFile(a: format.Entry, b: format.Entry) bool {
    return a.content_hash == b.content_hash and a.size_bytes == b.size_bytes and a.flags_word == b.flags_word;
}

/// The diff between two generations, as a change plan ordered by `(nameHash, name)`.
///
/// `before` and `after` may be in any order; the caller does not have to sort them. The result is owned by
/// `allocator`, and a name appears at most once.
pub fn diff(
    allocator: std.mem.Allocator,
    before: []const Item,
    after: []const Item,
) !Plan {
    const before_sorted = try allocator.dupe(Item, before);
    defer allocator.free(before_sorted);
    const after_sorted = try allocator.dupe(Item, after);
    defer allocator.free(after_sorted);
    std.mem.sort(Item, before_sorted, {}, entryLessThan);
    std.mem.sort(Item, after_sorted, {}, entryLessThan);

    var entries: std.ArrayListUnmanaged(format.Entry) = .empty;
    errdefer entries.deinit(allocator);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer names.deinit(allocator);

    var old_index: usize = 0;
    var new_index: usize = 0;
    while (old_index < before_sorted.len or new_index < after_sorted.len) {
        const take_old = new_index >= after_sorted.len or
            (old_index < before_sorted.len and entryLessThan({}, before_sorted[old_index], after_sorted[new_index]));
        const take_new = old_index >= before_sorted.len or
            (new_index < after_sorted.len and entryLessThan({}, after_sorted[new_index], before_sorted[old_index]));

        if (take_old) {
            // Only in the parent. Its entry describes what the name was, with no content of its own.
            var entry = before_sorted[old_index].entry;
            entry.flags_word = (entry.flags_word & ~format.flags.content_known) | CHANGE_DELETED;
            entry.content_hash = 0;
            entry.mtime_ns = 0;
            entry.size_bytes = 0;
            try entries.append(allocator, entry);
            try names.append(allocator, before_sorted[old_index].name);
            old_index += 1;
            continue;
        }
        if (take_new) {
            var entry = after_sorted[new_index].entry;
            entry.flags_word = (entry.flags_word & ~CHANGE_MASK) | CHANGE_ADDED;
            try entries.append(allocator, entry);
            try names.append(allocator, after_sorted[new_index].name);
            new_index += 1;
            continue;
        }

        // The same name on both sides: a change only when what it describes differs.
        const old_item = before_sorted[old_index];
        const new_item = after_sorted[new_index];
        if (!sameFile(old_item.entry, new_item.entry)) {
            var entry = new_item.entry;
            entry.flags_word = (entry.flags_word & ~CHANGE_MASK) | CHANGE_CHANGED;
            try entries.append(allocator, entry);
            try names.append(allocator, new_item.name);
        }
        old_index += 1;
        new_index += 1;
    }

    return .{ .entries = try entries.toOwnedSlice(allocator), .names = try names.toOwnedSlice(allocator) };
}

/// A batch laid out as the two byte files a trio carries, without the sidekick.
pub const Encoded = struct {
    meta: []u8,
    txt: []u8,
};

/// Lay the plan out as `files.meta` and `files.txt`: entries in plan order, names LF-terminated, offsets assigned
/// here because `diff` leaves them zero — the layout is the writer's business, the change set is not.
pub fn encode(allocator: std.mem.Allocator, plan: Plan) !Encoded {
    // One layout for every writer (§ 4): the text by name, the meta by (nameHash, name), the offsets assigned
    // there. A batch that laid out its own pair could order it differently from the main trio and still be
    // valid, which is exactly the drift the shared function prevents.
    const items = try allocator.alloc(pair.Item, plan.entries.len);
    defer allocator.free(items);
    for (plan.entries, 0..) |entry, index| {
        items[index] = .{ .name = plan.names[index], .entry = entry };
    }

    const laid = try pair.layout(allocator, items);
    // The batch has no use for the ranges; free them here rather than making Encoded own them.
    for (laid.roots) |range| allocator.free(range.name);
    allocator.free(laid.roots);
    return .{ .meta = laid.meta, .txt = laid.txt };
}

/// The inverse: entries and their names, with every entry required to carry exactly one change bit.
pub fn decode(allocator: std.mem.Allocator, meta: []const u8, txt: []const u8) !Plan {
    if (meta.len % format.entry_size != 0) return error.MetaSizeMismatch;
    const count = meta.len / format.entry_size;
    const entries = try allocator.alloc(format.Entry, count);
    errdefer allocator.free(entries);
    const names = try allocator.alloc([]const u8, count);
    errdefer allocator.free(names);

    for (0..count) |index| {
        const entry = format.Entry.decode(meta[index * format.entry_size ..][0..format.entry_size]);
        if (kindOf(entry) == null) return error.InvalidChangeFlags;
        if (entry.name_length == 0) return error.EntryOutOfRange;
        const end = entry.name_offset + entry.name_length;
        if (end >= txt.len or txt[end] != '\n') return error.EntryOutOfRange;
        entries[index] = entry;
        names[index] = txt[entry.name_offset..end];
    }

    return .{ .entries = entries, .names = names };
}

/// The change set as the events `reconcile.collapse` consumes.
pub fn toEvents(allocator: std.mem.Allocator, plan: Plan) ![]reconcile.Event {
    const events = try allocator.alloc(reconcile.Event, plan.entries.len);
    for (plan.entries, plan.names, 0..) |entry, name, index| {
        const kind = kindOf(entry) orelse return error.InvalidChangeFlags;
        events[index] = .{
            .nameHash = entry.name_hash,
            .name = name,
            .kind = kind,
            .entry = if (kind == .deleted) null else .{
                .contentHash = entry.content_hash,
                .sizeBytes = entry.size_bytes,
                .flags = entry.flags_word & ~CHANGE_MASK,
            },
        };
    }
    std.mem.sort(reconcile.Event, events, {}, eventLessThan);
    return events;
}

fn eventLessThan(_: void, a: reconcile.Event, b: reconcile.Event) bool {
    if (a.nameHash != b.nameHash) return a.nameHash < b.nameHash;
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn item(name: []const u8, hash: u32, flags: u32) Item {
    var entry = std.mem.zeroes(format.Entry);
    entry.name_hash = hash;
    entry.content_hash = hash * 7;
    entry.size_bytes = hash * 3;
    entry.flags_word = flags;
    return .{ .name = name, .entry = entry };
}

test "a diff reports the added, the changed and the deleted, each with one change bit" {
    const plan = try diff(testing.allocator, &.{
        item("a.txt", 1, format.flags.regular_file | format.flags.content_known),
        item("b.txt", 2, format.flags.regular_file | format.flags.content_known),
    }, &.{
        item("a.txt", 1, format.flags.regular_file | format.flags.content_known | format.flags.hash_lf),
        item("c.txt", 3, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }

    try testing.expectEqual(@as(usize, 3), plan.entries.len);
    try testing.expectEqual(reconcile.Kind.changed, kindOf(plan.entries[0]).?);
    try testing.expectEqual(reconcile.Kind.deleted, kindOf(plan.entries[1]).?);
    try testing.expectEqual(reconcile.Kind.added, kindOf(plan.entries[2]).?);
    try testing.expectEqualStrings("a.txt", plan.names[0]);
    try testing.expectEqualStrings("b.txt", plan.names[1]);
    try testing.expectEqualStrings("c.txt", plan.names[2]);
    for (plan.entries) |entry| try testing.expectEqual(@as(u32, 1), @popCount(entry.flags_word & CHANGE_MASK));
}

test "a deletion carries no content but keeps its name and what it was" {
    const plan = try diff(testing.allocator, &.{
        item("gone", 5, format.flags.is_dir),
    }, &.{});
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }
    try testing.expectEqual(@as(usize, 1), plan.entries.len);
    const entry = plan.entries[0];
    try testing.expectEqual(reconcile.Kind.deleted, kindOf(entry).?);
    try testing.expectEqual(@as(u64, 0), entry.content_hash);
    try testing.expectEqual(@as(u64, 0), entry.size_bytes);
    try testing.expect(entry.flags_word & format.flags.content_known == 0);
    try testing.expect(entry.flags_word & format.flags.is_dir != 0);
    try testing.expectEqualStrings("gone", plan.names[0]);
}

test "an unchanged generation produces an empty plan" {
    const before = [_]Item{ item("a.txt", 1, format.flags.regular_file), item("src", 2, format.flags.is_dir) };
    const plan = try diff(testing.allocator, &before, &before);
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }
    try testing.expectEqual(@as(usize, 0), plan.entries.len);
}

test "a round trip: diff, then events, then collapse is the same change set" {
    const plan = try diff(testing.allocator, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known),
        item("b.txt", 20, format.flags.regular_file | format.flags.content_known),
    }, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known | format.flags.hash_lf),
        item("c.txt", 30, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }

    const events = try toEvents(testing.allocator, plan);
    defer testing.allocator.free(events);
    const changes = try reconcile.collapse(testing.allocator, events, null);
    defer testing.allocator.free(changes);

    try testing.expectEqual(@as(usize, 3), changes.len);
    // Ordered by (nameHash, name): a.txt (10), b.txt (20), c.txt (30).
    try testing.expectEqualStrings("a.txt", changes[0].name);
    try testing.expectEqual(reconcile.Kind.changed, changes[0].kind);
    try testing.expectEqualStrings("b.txt", changes[1].name);
    try testing.expectEqual(reconcile.Kind.deleted, changes[1].kind);
    try testing.expectEqualStrings("c.txt", changes[2].name);
    try testing.expectEqual(reconcile.Kind.added, changes[2].kind);
}

test "two batches fold to the net effect: added then deleted is nothing" {
    const first = try diff(testing.allocator, &.{}, &.{
        item("tmp", 1, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        testing.allocator.free(first.entries);
        testing.allocator.free(first.names);
    }
    const second = try diff(testing.allocator, &.{
        item("tmp", 1, format.flags.regular_file | format.flags.content_known),
    }, &.{});
    defer {
        testing.allocator.free(second.entries);
        testing.allocator.free(second.names);
    }

    const first_events = try toEvents(testing.allocator, first);
    defer testing.allocator.free(first_events);
    const second_events = try toEvents(testing.allocator, second);
    defer testing.allocator.free(second_events);

    const both = try testing.allocator.alloc(reconcile.Event, first_events.len + second_events.len);
    defer testing.allocator.free(both);
    @memcpy(both[0..first_events.len], first_events);
    @memcpy(both[first_events.len..], second_events);

    const changes = try reconcile.collapse(testing.allocator, both, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 0), changes.len);
}
test "encode then decode is the same plan, byte for byte in both files" {
    const plan = try diff(testing.allocator, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known),
        item("gone.txt", 25, format.flags.regular_file | format.flags.content_known),
    }, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known | format.flags.hash_lf),
        item("new.txt", 30, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }

    const encoded = try encode(testing.allocator, plan);
    defer {
        testing.allocator.free(encoded.meta);
        testing.allocator.free(encoded.txt);
    }
    try testing.expectEqual(@as(usize, 3 * format.entry_size), encoded.meta.len);
    try testing.expectEqualStrings("a.txt\ngone.txt\nnew.txt\n", encoded.txt);

    const decoded = try decode(testing.allocator, encoded.meta, encoded.txt);
    defer {
        testing.allocator.free(decoded.entries);
        testing.allocator.free(decoded.names);
    }
    try testing.expectEqual(@as(usize, plan.entries.len), decoded.entries.len);
    for (plan.names, decoded.names) |want, got| try testing.expectEqualStrings(want, got);
    for (plan.entries, decoded.entries) |want, got| {
        try testing.expectEqual(kindOf(want).?, kindOf(got).?);
        try testing.expectEqual(want.name_hash, got.name_hash);
        try testing.expectEqual(want.content_hash, got.content_hash);
        try testing.expectEqual(want.flags_word & ~CHANGE_MASK, got.flags_word & ~CHANGE_MASK);
    }
}

test "decode refuses an entry with no change bit" {
    const plan = try diff(testing.allocator, &.{
        item("a.txt", 1, format.flags.regular_file | format.flags.content_known),
    }, &.{});
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }
    const encoded = try encode(testing.allocator, plan);
    defer {
        testing.allocator.free(encoded.meta);
        testing.allocator.free(encoded.txt);
    }
    // Clear the change bit in place: the entry is still a valid entry, just not a change.
    encoded.meta[44] = 0;
    try testing.expectError(error.InvalidChangeFlags, decode(testing.allocator, encoded.meta, encoded.txt));
}
/// A file from a cache state, as an entry. The identity fields are the ones diff compares (section 11); the layout
/// fields are the writer's and stay zero.
pub fn fileItem(name: []const u8, state: anytype) Item {
    var entry = std.mem.zeroes(format.Entry);
    entry.mtime_ns = state.mtime_ns;
    entry.size_bytes = state.size_bytes;
    entry.content_hash = state.content_hash orelse 0;
    entry.name_hash = format.wyhash(name);
    entry.file_id_lo = state.file_id_lo;
    entry.file_id_hi = state.file_id_hi;
    entry.flags_word = format.flags.regular_file |
        (if (state.content_hash != null) format.flags.content_known else 0) |
        (if (state.hash_lf) format.flags.hash_lf else 0);
    return .{ .name = name, .entry = entry };
}

/// A directory from a cache state: listed for its mtime, never carrying a content hash (section 16).
pub fn dirItem(name: []const u8, state: anytype) Item {
    var entry = std.mem.zeroes(format.Entry);
    entry.mtime_ns = state.mtime_ns;
    entry.name_hash = format.wyhash(name);
    entry.file_id_lo = state.file_id_lo;
    entry.file_id_hi = state.file_id_hi;
    entry.flags_word = format.flags.is_dir;
    return .{ .name = name, .entry = entry };
}

/// What a batch needs beyond its change set to write a sidekick.
pub const Context = struct {
    generation: u64,
    parent: u64,
    normalize: []const u8 = "text",
    root_dev: u64 = 0,
    root_ino: u64 = 0,
    created: []const u8 = "",
    updated: []const u8 = "",
    writer: []const u8 = "fsmeta-zig/1",
};

/// Write the plan as batches/<generation>/ under the meta directory: three files, no renames.
///
/// A batch is derived output: a torn batch fails its own hashes and is reported, never repaired, because a repaired
/// batch would be a guessed change record. The main trio keeps the section 9 rename order, which is where a torn
/// write would matter.
pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    meta_dir: std.Io.Dir,
    plan: Plan,
    context: Context,
) !void {
    const encoded = try encode(allocator, plan);
    defer allocator.free(encoded.meta);
    defer allocator.free(encoded.txt);

    var added: u64 = 0;
    var changed: u64 = 0;
    var deleted: u64 = 0;
    for (plan.entries) |entry| switch (kindOf(entry) orelse return error.InvalidChangeFlags) {
        .added => added += 1,
        .changed => changed += 1,
        .deleted => deleted += 1,
    };

    const json_bytes = try json_doc.encode(allocator, .{
        .generation = context.generation,
        .count = plan.entries.len,
        .meta_bytes = encoded.meta.len,
        .txt_bytes = encoded.txt.len,
        .meta_hash = format.wyhash(encoded.meta),
        .txt_hash = format.wyhash(encoded.txt),
        .normalize = context.normalize,
        .root_dev = context.root_dev,
        .root_ino = context.root_ino,
        .created = context.created,
        .updated = context.updated,
        .writer = context.writer,
        .batch = .{
            .number = context.generation,
            .parent = context.parent,
            .added = added,
            .changed = changed,
            .deleted = deleted,
        },
    });
    defer allocator.free(json_bytes);

    // The batch id is the generation in **lowercase hex**, zero-padded to eight digits. Hex is not cosmetic: a
// bit count divided by four is a digit count, so padding, parsing and modulo are shifts and masks rather than
// divisions by ten, and the digits line up with the bits a consumer already has.
const relative = try std.fmt.allocPrint(allocator, "batches/{x:0>8}", .{context.generation});
    defer allocator.free(relative);
    try meta_dir.createDirPath(io, relative);
    const dir = try meta_dir.openDir(io, relative, .{});
    defer dir.close(io);

    try dir.writeFile(io, .{ .sub_path = format.meta_file, .data = encoded.meta });
    try dir.writeFile(io, .{ .sub_path = format.txt_file, .data = encoded.txt });
    try dir.writeFile(io, .{ .sub_path = format.json_file, .data = json_bytes });
}

test "a written batch lands under batches/<generation>, three files, decodable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plan = try diff(testing.allocator, &.{}, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known),
        item("b.txt", 20, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }

    try write(testing.allocator, io, tmp.dir, plan, .{
        .generation = 2,
        .parent = 1,
        .created = "2026-10-19T00:00:00Z",
        .updated = "2026-10-19T00:00:00Z",
    });

    const dir = try tmp.dir.openDir(io, "batches/00000002", .{});
    defer dir.close(io);

    const meta = try dir.readFileAlloc(io, format.meta_file, testing.allocator, std.Io.Limit.limited(1 << 16));
    defer testing.allocator.free(meta);
    const txt = try dir.readFileAlloc(io, format.txt_file, testing.allocator, std.Io.Limit.limited(1 << 16));
    defer testing.allocator.free(txt);
    const json = try dir.readFileAlloc(io, format.json_file, testing.allocator, std.Io.Limit.limited(1 << 16));
    defer testing.allocator.free(json);

    try testing.expectEqual(@as(usize, 2 * format.entry_size), meta.len);
    try testing.expectEqualStrings("a.txt\nb.txt\n", txt);
    try testing.expect(std.mem.indexOf(u8, json, "\"batch\": { \"number\": 2, \"parent\": 1, \"added\": 2, \"changed\": 0, \"deleted\": 0 }") != null);

    const decoded = try decode(testing.allocator, meta, txt);
    defer {
        testing.allocator.free(decoded.entries);
        testing.allocator.free(decoded.names);
    }
    try testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try testing.expectEqual(reconcile.Kind.added, kindOf(decoded.entries[0]).?);
}

test "a batch directory is named in lowercase hex, so the id arithmetic is nibble-aligned" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plan = try diff(std.testing.allocator, &.{}, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        std.testing.allocator.free(plan.entries);
        std.testing.allocator.free(plan.names);
    }

    try write(std.testing.allocator, io, tmp.dir, plan, .{
        .generation = 16,
        .parent = 15,
        .created = "2026-10-19T00:00:00Z",
        .updated = "2026-10-19T00:00:00Z",
    });

    // Generation 16 is `00000010` in hex and `00000016` in decimal. This is the only value that can tell the two
    // apart, which is why the test uses it: a base-ten padding passes every smaller number.
    var dir = try tmp.dir.openDir(io, "batches/00000010", .{});
    defer dir.close(io);
}
