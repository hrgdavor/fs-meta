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
///
/// `name` is **borrowed**: it must stay valid until `encode`/`write` has copied it into the batch, because a
/// deleted entry has no other copy of its path — the entry keeps only the hash. The engine builds its
/// `previous` snapshot before discovery mutates the cache, so it owns those names (a duplicate per item); a
/// writer that hands `diff` a slice into memory the cache can free or overwrite gets a churned name in the
/// batch's `files.txt`, which is the corruption this contract exists to prevent.
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

test "a deleted entry's name survives diff, encode and decode" {
    // A deleted entry is the one entry whose name exists nowhere else: `diff` zeroes its content and the entry
    // keeps only the name hash. So the round trip has to be asserted for a deletion on its own, not only as a
    // passenger of a mixed batch: the name must come back exactly, and the entry's offset/length must address it
    // in the batch's own `files.txt` (whose order is by name, while `files.meta` is by `(nameHash, name)`).
    const plan = try diff(testing.allocator, &.{
        item("src", 30, format.flags.is_dir),
        item("src/b.java", 20, format.flags.regular_file | format.flags.content_known),
    }, &.{});
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }
    try testing.expectEqual(@as(usize, 2), plan.entries.len);

    const encoded = try encode(testing.allocator, plan);
    defer {
        testing.allocator.free(encoded.meta);
        testing.allocator.free(encoded.txt);
    }
    // The layout's text order, with the directory in its stored `src/` form.
    try testing.expectEqualStrings("src/\nsrc/b.java\n", encoded.txt);

    const decoded = try decode(testing.allocator, encoded.meta, encoded.txt);
    defer {
        testing.allocator.free(decoded.entries);
        testing.allocator.free(decoded.names);
    }
    try testing.expectEqual(@as(usize, 2), decoded.entries.len);
    // `files.meta` is by `(nameHash, name)`: src/b.java (20) then src (30), the reverse of the text order.
    try testing.expectEqualStrings("src/b.java", decoded.names[0]);
    try testing.expectEqualStrings("src/", decoded.names[1]);
    for (decoded.entries, decoded.names) |entry, name| {
        try testing.expectEqual(reconcile.Kind.deleted, kindOf(entry).?);
        const end = entry.name_offset + entry.name_length;
        try testing.expectEqualStrings(name, encoded.txt[entry.name_offset..end]);
        try testing.expectEqual(@as(u8, '\n'), encoded.txt[end]);
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

// ---------------------------------------------------------------- retention (FORMAT.md § 17.6)

/// How many generations a batch archive keeps by default: the newest thirty-two (FORMAT.md § 17.6).
///
/// The window is a policy of the archive, not of one batch, so it is a parameter of `rotate` rather than of
/// `write`; the engine passes its own `keep_batches`, which defaults here. Thirty-two is about a month of one
/// pass a day, or half an hour of one pass a minute, and it is small enough that the archive a long-lived tree
/// accumulates stays bounded.
pub const default_keep: usize = 32;

/// The prefix a generation is renamed to while it is being removed. It is not eight hex digits, so a reader
/// never mistakes a leftover for a batch; the next rotation deletes it.
const trash_prefix = ".trash-";

/// What a rotation left behind, so a caller can report or test it.
pub const Rotation = struct {
    /// Generations retained: the newest `keep`, or every generation when the archive is smaller than the window.
    kept: usize = 0,
    /// Generations removed by this rotation: the oldest ones beyond the window, in ascending number order.
    dropped: u64 = 0,
};

/// Whether `name` is a batch id: exactly eight lowercase hex digits (§ 17.1). Anything else in `batches/` is a
/// foreign entry, not a batch, and rotation leaves it alone.
fn isBatchName(name: []const u8) bool {
    if (name.len != 8) return false;
    for (name) |char| switch (char) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The numbers a rotation removes: everything older than the newest `keep` generations, ascending.
///
/// Pure — no file system, no names — so the window arithmetic is testable on its own. The newest generation is
/// always kept: `keep` is clamped to at least one, which makes "never delete the current change set" a property
/// of this function rather than a promise of its caller. `numbers` need not be sorted, and a gap already in it
/// stays a gap: rotation removes a prefix, it neither creates nor repairs a hole in the middle.
pub fn toDrop(allocator: std.mem.Allocator, numbers: []const u64, keep_requested: usize) ![]u64 {
    const keep = @max(keep_requested, 1);
    if (numbers.len <= keep) return allocator.alloc(u64, 0);
    const sorted = try allocator.dupe(u64, numbers);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return allocator.dupe(u64, sorted[0 .. sorted.len - keep]);
}

/// Apply the retention window to `<meta_dir>/batches`: remove the oldest generations beyond `keep`.
///
/// Safe to run after every publish. It reads the archive as it is now, so a second run over the same state
/// removes nothing, and the newest generation is never a candidate (§ 17.6).
///
/// **Oldest first, one at a time.** A removal is a rename out of the batch namespace followed by a recursive
/// delete, so a reader sees a batch either whole or not at all — never a directory with some of its three files
/// already gone, which a consumer would read as a shortened change record. On the first failure the rotation
/// stops and returns the error: everything already removed is older than everything that remains, so the
/// archive is still a contiguous suffix of the sequence, and a later pass retries. A missing `batches/`
/// directory is not an error — a trio can exist before its first change batch.
pub fn rotate(
    allocator: std.mem.Allocator,
    io: std.Io,
    meta_dir: std.Io.Dir,
    keep_requested: usize,
) !Rotation {
    var batches = meta_dir.openDir(io, "batches", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer batches.close(io);

    var numbers: std.ArrayListUnmanaged(u64) = .empty;
    defer numbers.deinit(allocator);
    var trash: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (trash.items) |name| allocator.free(name);
        trash.deinit(allocator);
    }

    var iterator = batches.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, trash_prefix)) {
            // A removal that was interrupted after its rename: no longer a batch, and still our garbage.
            try trash.append(allocator, try allocator.dupe(u8, entry.name));
            continue;
        }
        if (entry.kind != .directory or !isBatchName(entry.name)) continue;
        const number = std.fmt.parseInt(u64, entry.name, 16) catch continue;
        try numbers.append(allocator, number);
    }

    // Finish the previous rotation's last step before starting this one: the rename below must not collide.
    for (trash.items) |name| try batches.deleteTree(io, name);

    const keep = @max(keep_requested, 1);
    const drop = try toDrop(allocator, numbers.items, keep);
    defer allocator.free(drop);

    for (drop) |number| {
        const name = try std.fmt.allocPrint(allocator, "{x:0>8}", .{number});
        defer allocator.free(name);
        const aside = try std.fmt.allocPrint(allocator, "{s}{s}", .{ trash_prefix, name });
        defer allocator.free(aside);
        // Rename is the atomic step: after it the generation is out of the archive. The delete is cleanup, and
        // a crash between the two leaves `aside`, which the next rotation removes.
        try batches.rename(name, batches, aside, io);
        try batches.deleteTree(io, aside);
    }

    return .{ .kept = @min(numbers.items.len, keep), .dropped = drop.len };
}

// ---------------------------------------------------------------- retention by bytes

/// What a byte-budget rotation left behind.
pub const ByteRotation = struct {
    /// Generations retained after the rotation.
    kept: usize = 0,
    /// Generations removed by this rotation, oldest first.
    dropped: u64 = 0,
    /// The archive's size after the rotation.
    bytes: u64 = 0,
};

/// The total size of every generation under `<meta_dir>/batches`, and the generations themselves.
///
/// A generation is three files, so its size is their sum; anything else in the directory (a leftover
/// `.trash-…`, a foreign entry) is not a generation and is not counted as one.
pub fn measureArchive(allocator: std.mem.Allocator, io: std.Io, meta_dir: std.Io.Dir) !struct {
    numbers: []u64,
    sizes: []u64,
    bytes: u64,
} {
    var batches = meta_dir.openDir(io, "batches", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .numbers = try allocator.alloc(u64, 0), .sizes = try allocator.alloc(u64, 0), .bytes = 0 },
        else => return err,
    };
    defer batches.close(io);

    var numbers: std.ArrayListUnmanaged(u64) = .empty;
    errdefer numbers.deinit(allocator);
    var sizes: std.ArrayListUnmanaged(u64) = .empty;
    errdefer sizes.deinit(allocator);
    var total: u64 = 0;

    var iterator = batches.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or !isBatchName(entry.name)) continue;
        const number = std.fmt.parseInt(u64, entry.name, 16) catch continue;
        var dir = batches.openDir(io, entry.name, .{}) catch continue;
        defer dir.close(io);
        var size: u64 = 0;
        for ([_][]const u8{ format.meta_file, format.txt_file, format.json_file }) |file_name| {
            const stat = dir.statFile(io, file_name, .{}) catch continue;
            size += stat.size;
        }
        try numbers.append(allocator, number);
        try sizes.append(allocator, size);
        total += size;
    }

    return .{
        .numbers = try numbers.toOwnedSlice(allocator),
        .sizes = try sizes.toOwnedSlice(allocator),
        .bytes = total,
    };
}

/// Apply the **byte ceiling** to `<meta_dir>/batches`, oldest first, until the archive fits `max_bytes`.
///
/// The count limit and the byte limit are both needed and neither is sufficient: thirty-two generations are
/// bounded in number but not in size, and a byte budget alone leaves a hundred tiny generations that are a
/// hundred handshakes to replay. The newest generation is always kept, even when it alone exceeds the budget:
/// refusing to keep it would break the commit that just happened, and one oversized generation is better than
/// a missing one.
///
/// The removal is the same rename-then-delete the count rotation uses, so a reader never sees a generation
/// with some of its files already gone.
pub fn rotateToBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    meta_dir: std.Io.Dir,
    max_bytes: u64,
) !ByteRotation {
    const archive = try measureArchive(allocator, io, meta_dir);
    defer allocator.free(archive.numbers);
    defer allocator.free(archive.sizes);
    if (archive.numbers.len == 0) return .{};

    // Sort generations by number so "oldest" is unambiguous even though a directory listing has no order.
    const Order = struct {
        fn lessThan(context: void, left: u64, right: u64) bool {
            _ = context;
            return left < right;
        }
    };
    const sorted_numbers = try allocator.dupe(u64, archive.numbers);
    defer allocator.free(sorted_numbers);
    std.mem.sort(u64, sorted_numbers, {}, Order.lessThan);

    var total = archive.bytes;
    var drop_count: usize = 0;
    while (total > max_bytes and drop_count + 1 < sorted_numbers.len) : (drop_count += 1) {
        const number = sorted_numbers[drop_count];
        for (archive.numbers, archive.sizes) |candidate, size| {
            if (candidate == number) {
                total -= size;
                break;
            }
        }
    }

    var batches = try meta_dir.openDir(io, "batches", .{ .iterate = true });
    defer batches.close(io);

    // Finish an interrupted rotation before starting this one: the rename below must not collide.
    var leftovers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (leftovers.items) |name| allocator.free(name);
        leftovers.deinit(allocator);
    }
    {
        var iterator = batches.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, trash_prefix)) continue;
            try leftovers.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    for (leftovers.items) |name| try batches.deleteTree(io, name);

    for (sorted_numbers[0..drop_count]) |number| {
        const name = try std.fmt.allocPrint(allocator, "{x:0>8}", .{number});
        defer allocator.free(name);
        const aside = try std.fmt.allocPrint(allocator, "{s}{s}", .{ trash_prefix, name });
        defer allocator.free(aside);
        try batches.rename(name, batches, aside, io);
        try batches.deleteTree(io, aside);
    }

    return .{
        .kept = sorted_numbers.len - drop_count,
        .dropped = drop_count,
        .bytes = total,
    };
}

test "the byte ceiling removes the oldest generations, and always keeps the newest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var number: u64 = 1;
    while (number <= 3) : (number += 1) {
        const plan = try diff(testing.allocator, &.{}, &.{
            item("a.txt", 10, format.flags.regular_file | format.flags.content_known),
            item("b.txt", 20, format.flags.regular_file | format.flags.content_known),
        });
        defer {
            testing.allocator.free(plan.entries);
            testing.allocator.free(plan.names);
        }
        try write(testing.allocator, io, tmp.dir, plan, .{
            .generation = number,
            .parent = number - 1,
            .created = "2026-10-19T00:00:00Z",
            .updated = "2026-10-19T00:00:00Z",
        });
    }

    const measured = try measureArchive(testing.allocator, io, tmp.dir);
    defer testing.allocator.free(measured.numbers);
    defer testing.allocator.free(measured.sizes);
    try testing.expectEqual(@as(usize, 3), measured.numbers.len);
    const per_generation = measured.bytes / 3;
    try testing.expect(per_generation > 0);

    // A budget for two generations: the oldest goes, and nothing else does.
    const rotation = try rotateToBytes(testing.allocator, io, tmp.dir, per_generation * 2);
    try testing.expectEqual(@as(u64, 1), rotation.dropped);
    try testing.expectEqual(@as(usize, 2), rotation.kept);
    try testing.expectEqual(per_generation * 2, rotation.bytes);

    tmp.dir.access(io, "batches/00000001", .{}) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
    };
    var kept = try tmp.dir.openDir(io, "batches/00000003", .{});
    kept.close(io);

    // Running it again at the same budget removes nothing: rotation is a function of the archive, not a clock.
    const again = try rotateToBytes(testing.allocator, io, tmp.dir, per_generation * 2);
    try testing.expectEqual(@as(u64, 0), again.dropped);
}

test "a generation larger than the whole budget is kept rather than leaving the archive empty" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plan = try diff(testing.allocator, &.{}, &.{
        item("a.txt", 10, format.flags.regular_file | format.flags.content_known),
    });
    defer {
        testing.allocator.free(plan.entries);
        testing.allocator.free(plan.names);
    }
    try write(testing.allocator, io, tmp.dir, plan, .{
        .generation = 7,
        .parent = 6,
        .created = "2026-10-19T00:00:00Z",
        .updated = "2026-10-19T00:00:00Z",
    });

    const rotation = try rotateToBytes(testing.allocator, io, tmp.dir, 1);
    try testing.expectEqual(@as(u64, 0), rotation.dropped);
    try testing.expectEqual(@as(usize, 1), rotation.kept);
    var kept = try tmp.dir.openDir(io, "batches/00000007", .{});
    kept.close(io);
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

// ---------------------------------------------------------------- retention tests

/// A batch directory as rotation sees it: a name and one file, so a removal exercises the recursive delete rather
/// than an empty directory.
fn makeBatch(io: std.Io, meta_dir: std.Io.Dir, number: u64) !void {
    const relative = try std.fmt.allocPrint(testing.allocator, "batches/{x:0>8}", .{number});
    defer testing.allocator.free(relative);
    try meta_dir.createDirPath(io, relative);
    var dir = try meta_dir.openDir(io, relative, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = format.meta_file, .data = "entry" });
}

/// Whether `batches/<number>` is still there, with its file.
fn batchExists(io: std.Io, meta_dir: std.Io.Dir, number: u64) !bool {
    const relative = try std.fmt.allocPrint(testing.allocator, "batches/{x:0>8}/{s}", .{ number, format.meta_file });
    defer testing.allocator.free(relative);
    const bytes = meta_dir.readFileAlloc(io, relative, testing.allocator, std.Io.Limit.limited(64)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    testing.allocator.free(bytes);
    return true;
}

test "the retention window is the newest N, and never fewer than the newest one" {
    // Unsorted on purpose: the directory hands entries over in whatever order the file system chose.
    const numbers = [_]u64{ 5, 2, 9, 1, 7 };

    const keep_three = try toDrop(testing.allocator, &numbers, 3);
    defer testing.allocator.free(keep_three);
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, keep_three);

    // Keep zero is read as one: the generation a consumer is about to read must never disappear.
    const keep_zero = try toDrop(testing.allocator, &numbers, 0);
    defer testing.allocator.free(keep_zero);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 5, 7 }, keep_zero);

    // A window larger than the archive removes nothing.
    const keep_all = try toDrop(testing.allocator, &numbers, 99);
    defer testing.allocator.free(keep_all);
    try testing.expectEqual(@as(usize, 0), keep_all.len);
}

test "a rotation drops the oldest generations, keeps the newest, and leaves what is not a batch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]u64{ 1, 2, 3, 4, 5 }) |number| try makeBatch(io, tmp.dir, number);
    // A leftover from an interrupted rotation, and a foreign entry: neither is a batch.
    try tmp.dir.createDirPath(io, "batches/.trash-00000001");
    try tmp.dir.createDirPath(io, "batches/notes");

    const rotation = try rotate(testing.allocator, io, tmp.dir, 3);
    try testing.expectEqual(@as(usize, 3), rotation.kept);
    try testing.expectEqual(@as(u64, 2), rotation.dropped);

    try testing.expect(!try batchExists(io, tmp.dir, 1));
    try testing.expect(!try batchExists(io, tmp.dir, 2));
    for ([_]u64{ 3, 4, 5 }) |number| try testing.expect(try batchExists(io, tmp.dir, number));
    // The older three disappeared as whole batches: no half-deleted directory is left behind.
    for ([_]u64{ 1, 2 }) |number| {
        const relative = try std.fmt.allocPrint(testing.allocator, "batches/{x:0>8}", .{number});
        defer testing.allocator.free(relative);
        try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, relative, .{}));
    }
    // The interrupted rotation's leftover was cleaned, and the foreign entry was not touched.
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "batches/.trash-00000001", .{}));
    var notes = try tmp.dir.openDir(io, "batches/notes", .{});
    notes.close(io);

    // Running it again removes nothing: rotation is idempotent after a publish.
    const again = try rotate(testing.allocator, io, tmp.dir, 3);
    try testing.expectEqual(@as(u64, 0), again.dropped);
    try testing.expectEqual(@as(usize, 3), again.kept);
}

test "a rotation that may keep only one still keeps the newest batch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try makeBatch(io, tmp.dir, 1);
    try makeBatch(io, tmp.dir, 2);
    const rotation = try rotate(testing.allocator, io, tmp.dir, 0);
    try testing.expectEqual(@as(usize, 1), rotation.kept);
    try testing.expectEqual(@as(u64, 1), rotation.dropped);
    try testing.expect(!try batchExists(io, tmp.dir, 1));
    try testing.expect(try batchExists(io, tmp.dir, 2));
}

test "a rotation with no batches directory is a no-op, not an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rotation = try rotate(testing.allocator, std.testing.io, tmp.dir, 4);
    try testing.expectEqual(@as(u64, 0), rotation.dropped);
    try testing.expectEqual(@as(usize, 0), rotation.kept);
}
