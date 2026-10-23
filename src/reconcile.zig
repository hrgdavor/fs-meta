// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! Reconciliation of batch change records (FORMAT.md § 17.4).
//!
//! A consumer knows it synced at batch 11 and is called when the latest is 14. What it needs is the *combined*
//! change — add, update or remove — as if 11 through 14 had happened in one step: a file created and then deleted
//! in the window is not a change at all, and a file changed twice is one change carrying the final entry.
//!
//! **A batch is ordered by `nameHash`, not by path.** The hash is the name's id (§ 3), so two batches merge in one
//! ordered walk over two lists — no lookup, no allocation, no string comparison — and a name's history across N
//! batches is found the same way. The name travels with the hash as the tie-break for the (rare, but possible) case
//! of two names hashing to the same 64-bit value: ordering by the pair stays deterministic, and comparing the pair
//! keeps a collision from being read as one name changing twice.
//!
//! The collapse table is the whole algorithm; the baseline check afterwards is what makes "changed away and back
//! again" (a branch switch and back) reconcile to nothing, and it needs the state the consumer recorded at `from`,
//! because the batches only carry post-states. Without a baseline the answer is a superset — correct, idempotent,
//! occasionally a no-op the consumer did not need.

const std = @import("std");

/// How a name changed in one batch.
pub const Kind = enum { added, changed, deleted };

/// The part of an entry that decides identity (§ 11): two entries that agree here describe the same file.
pub const Identity = struct {
    contentHash: u64,
    sizeBytes: u64,
    flags: u32,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.contentHash == b.contentHash and a.sizeBytes == b.sizeBytes and a.flags == b.flags;
    }
};

/// One change read from one batch, in batch order. `nameHash` is the entry's name hash — the batch's sort key.
pub const Event = struct {
    nameHash: u64,
    name: []const u8,
    kind: Kind,
    /// The name's entry after this change; `null` only for `deleted`.
    entry: ?Identity = null,
};

/// A combined change the consumer should apply, ordered by `(nameHash, name)`.
pub const Change = struct {
    nameHash: u64,
    name: []const u8,
    kind: Kind,
    /// The final entry; `null` only for `deleted`.
    entry: ?Identity = null,
};

/// The state the consumer recorded at `from`: the identity it has for a name, or `null` for absent.
pub const Baseline = struct {
    context: *anyopaque,
    lookup: *const fn (context: *anyopaque, nameHash: u64, name: []const u8) ?Identity,

    pub fn find(self: Baseline, nameHash: u64, name: []const u8) ?Identity {
        return self.lookup(self.context, nameHash, name);
    }
};

const Record = struct {
    nameHash: u64,
    name: []const u8,
    first: Kind,
    last: Kind,
    entry: ?Identity,
};

/// Collapse per-name events into the combined change record, dropping names whose net effect is nothing.
///
/// `events` are in batch order, oldest first; a batch's own order is by `nameHash`, so a stream from one batch is
/// already grouped and spanning batches needs only this fold.
pub fn collapse(
    allocator: std.mem.Allocator,
    events: []const Event,
    baseline: ?Baseline,
) ![]Change {
    var records: std.ArrayListUnmanaged(Record) = .empty;
    defer records.deinit(allocator);
    // Keyed by the hash, which is the id; the name is compared to tell a collision from a repeat.
    var index_by_hash: std.AutoHashMapUnmanaged(u64, usize) = .{};
    defer index_by_hash.deinit(allocator);

    for (events) |event| {
        if (index_by_hash.get(event.nameHash)) |index| {
            const record = &records.items[index];
            if (std.mem.eql(u8, record.name, event.name)) {
                record.last = event.kind;
                record.entry = event.entry;
                continue;
            }
            // A collision: the first name keeps the slot, the second becomes its own record below.
        }
        try records.append(allocator, .{
            .nameHash = event.nameHash,
            .name = event.name,
            .first = event.kind,
            .last = event.kind,
            .entry = event.entry,
        });
        if (!index_by_hash.contains(event.nameHash)) {
            try index_by_hash.put(allocator, event.nameHash, records.items.len - 1);
        }
    }

    var changes: std.ArrayListUnmanaged(Change) = .empty;
    errdefer changes.deinit(allocator);

    for (records.items) |record| {
        const kind: ?Kind = switch (record.first) {
            // It did not exist at `from`.
            .added => switch (record.last) {
                .added, .changed => .added,
                .deleted => null, // created and removed inside the window: no change at all
            },
            .changed => switch (record.last) {
                .added, .changed => .changed,
                .deleted => .deleted,
            },
            // It existed at `from` (the first event proves it), whatever happens afterwards.
            .deleted => switch (record.last) {
                .deleted => .deleted,
                .added, .changed => .changed,
            },
        };
        const chosen = kind orelse continue;

        // The baseline check: a state the consumer already holds is not a change. `deleted` is checked by
        // absence, `added` and `changed` by identity.
        if (baseline) |state| {
            const before = state.find(record.nameHash, record.name);
            switch (chosen) {
                .deleted => if (before == null) continue,
                .added, .changed => {
                    if (before) |current| {
                        if (record.entry) |final| {
                            if (current.eql(final)) continue;
                        }
                    }
                },
            }
        }

        try changes.append(allocator, .{
            .nameHash = record.nameHash,
            .name = record.name,
            .kind = chosen,
            .entry = record.entry,
        });
    }

    std.mem.sort(Change, changes.items, {}, changeLessThan);
    return changes.toOwnedSlice(allocator);
}

/// `(nameHash, name)` — the batch order, so the result can be merged or diffed the same way.
fn changeLessThan(_: void, a: Change, b: Change) bool {
    if (a.nameHash != b.nameHash) return a.nameHash < b.nameHash;
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---------------------------------------------------------------- tests: the collapse table, row by row

const testing = std.testing;

fn entry(hash: u64, size: u64, flags: u32) Identity {
    return .{ .contentHash = hash, .sizeBytes = size, .flags = flags };
}

/// The fold never recomputes the hash, which is what lets a batch be merged without reading its names.
fn ev(nameHash: u64, name: []const u8, kind: Kind, identity: ?Identity) Event {
    return .{ .nameHash = nameHash, .name = name, .kind = kind, .entry = identity };
}

const MapBaseline = struct {
    entries: std.AutoHashMapUnmanaged(u64, Identity) = .{},

    fn lookup(context: *anyopaque, nameHash: u64, _: []const u8) ?Identity {
        const self: *MapBaseline = @ptrCast(@alignCast(context));
        return self.entries.get(nameHash);
    }

    fn asBaseline(self: *MapBaseline) Baseline {
        return .{ .context = self, .lookup = lookup };
    }
};

test "added then changed is one added, with the final entry" {
    const final = entry(0xbb, 20, 0x02);
    const changes = try collapse(testing.allocator, &.{
        ev(1, "a.txt", .added, entry(0xaa, 10, 0x02)),
        ev(1, "a.txt", .changed, final),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Kind.added, changes[0].kind);
    try testing.expect(changes[0].entry.?.eql(final));
}

test "added then deleted is nothing: it never existed at from" {
    const changes = try collapse(testing.allocator, &.{
        ev(2, "tmp.txt", .added, entry(1, 1, 0x02)),
        ev(2, "tmp.txt", .deleted, null),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 0), changes.len);
}

test "changed then changed collapses to the last state" {
    const final = entry(0xcc, 30, 0x02);
    const changes = try collapse(testing.allocator, &.{
        ev(3, "b.txt", .changed, entry(0xbb, 20, 0x02)),
        ev(3, "b.txt", .changed, final),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Kind.changed, changes[0].kind);
    try testing.expect(changes[0].entry.?.eql(final));
}

test "changed then deleted is a deletion" {
    const changes = try collapse(testing.allocator, &.{
        ev(4, "c.txt", .changed, entry(0xbb, 20, 0x02)),
        ev(4, "c.txt", .deleted, null),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Kind.deleted, changes[0].kind);
    try testing.expectEqual(@as(?Identity, null), changes[0].entry);
}

test "deleted then added is a change: the first event proves it existed at from" {
    const final = entry(0xdd, 40, 0x02);
    const changes = try collapse(testing.allocator, &.{
        ev(5, "d.txt", .deleted, null),
        ev(5, "d.txt", .added, final),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Kind.changed, changes[0].kind);
    try testing.expect(changes[0].entry.?.eql(final));
}

test "deleted then changed is a change with the final entry" {
    const final = entry(0xee, 50, 0x02);
    const changes = try collapse(testing.allocator, &.{
        ev(6, "e.txt", .deleted, null),
        ev(6, "e.txt", .changed, final),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Kind.changed, changes[0].kind);
    try testing.expect(changes[0].entry.?.eql(final));
}

test "a branch switch and back reconciles to nothing with a baseline" {
    const consumer_has = entry(0x11, 100, 0x03);
    var map = MapBaseline{};
    defer map.entries.deinit(testing.allocator);
    try map.entries.put(testing.allocator, 7, consumer_has);

    const changes = try collapse(testing.allocator, &.{
        ev(7, "a.txt", .changed, entry(0x22, 90, 0x03)),
        ev(7, "a.txt", .changed, consumer_has),
    }, map.asBaseline());
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 0), changes.len);
}

test "without a baseline the same window is one changed, a superset not a wrong answer" {
    const consumer_has = entry(0x11, 100, 0x03);
    const changes = try collapse(testing.allocator, &.{
        ev(7, "a.txt", .changed, entry(0x22, 90, 0x03)),
        ev(7, "a.txt", .changed, consumer_has),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(Kind.changed, changes[0].kind);
}

test "a deletion the baseline says was already absent is dropped" {
    var map = MapBaseline{};
    defer map.entries.deinit(testing.allocator);
    const changes = try collapse(testing.allocator, &.{
        ev(8, "other.txt", .changed, entry(0x33, 30, 0x02)),
        ev(9, "gone.txt", .deleted, null),
    }, map.asBaseline());
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("other.txt", changes[0].name);
}

test "two different names with one hash are two records, ordered by the pair" {
    // A 64-bit hash can collide. Ordering by `(nameHash, name)` keeps the output deterministic, and comparing the
    // pair keeps the fold from reading a collision as one name changing twice.
    const changes = try collapse(testing.allocator, &.{
        ev(42, "b.txt", .added, entry(1, 1, 0x02)),
        ev(42, "a.txt", .added, entry(2, 2, 0x02)),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("a.txt", changes[0].name);
    try testing.expectEqualStrings("b.txt", changes[1].name);
    try testing.expectEqual(@as(u64, 42), changes[0].nameHash);
}

test "the result is ordered by name hash, so it merges with a batch by one walk" {
    const changes = try collapse(testing.allocator, &.{
        ev(30, "src/b.java", .added, entry(1, 1, 0x02)),
        ev(10, "a.txt", .added, entry(2, 2, 0x02)),
        ev(20, "docs/readme.md", .added, entry(3, 3, 0x02)),
    }, null);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqual(@as(u64, 10), changes[0].nameHash);
    try testing.expectEqual(@as(u64, 20), changes[1].nameHash);
    try testing.expectEqual(@as(u64, 30), changes[2].nameHash);
}