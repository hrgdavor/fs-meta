// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! The pair's layout, shared by every writer (FORMAT.md § 4, § 18).
//!
//! `files.meta` and `files.txt` are ordered differently on purpose, and a writer that lays them out itself would
//! re-decide those orders — which is how two writers drift. This module is the one place they are decided:
//!
//! - `files.txt` by **name in stored form**, a directory's name carrying its trailing `/`, so a subtree is the exact
//!   byte range `[dir + "/", dir + "0")`;
//! - `files.meta` by **`(nameHash, name)`**, the order an id lookup binary-searches, with the name as the tie-break
//!   that separates a collision;
//! - an entry addresses its name by offset, never by position, which is what lets the two orders differ at all;
//! - `roots` (§ 18) falls out of the text layout for free: a range each time the first path segment changes.

const std = @import("std");
const format = @import("format.zig");

/// One name and its entry, as a writer has it. The entry's `name_offset`/`name_length` are ignored: the layout
/// assigns them.
pub const Item = struct {
    name: []const u8,
    entry: format.Entry,
};

/// A direct child of the root and where its subtree sits in `files.txt` (§ 18).
pub const RootRange = struct {
    name: []const u8,
    offset: u64,
    length: u64,
};

pub const Layout = struct {
    meta: []u8,
    txt: []u8,
    /// Empty for a tree with no direct child folders; a reader that finds none scans `files.txt`.
    roots: []RootRange,
};

const Laid = struct {
    name: []const u8,
    stored: []const u8,
    entry: format.Entry,
    offset: u64 = 0,
    length: u32 = 0,
};

fn storedLessThan(_: void, a: Laid, b: Laid) bool {
    return std.mem.lessThan(u8, a.stored, b.stored);
}

fn hashOrderLessThan(_: void, a: Laid, b: Laid) bool {
    if (a.entry.name_hash != b.entry.name_hash) return a.entry.name_hash < b.entry.name_hash;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The first path segment of a name, or `null` for a name directly in the root.
fn topSegment(name: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    return name[0..slash];
}

pub fn layout(allocator: std.mem.Allocator, items: []const Item) !Layout {
    var work = try allocator.alloc(Laid, items.len);
    defer allocator.free(work);
    for (items, 0..) |item, index| {
        work[index] = .{
            .name = item.name,
            .stored = if (item.entry.kind() == .dir)
                try std.fmt.allocPrint(allocator, "{s}/", .{item.name})
            else
                item.name,
            .entry = item.entry,
        };
    }

    // The synthesized `dir/` names are ours; the caller's names are not.
    defer for (work) |item| {
        if (item.entry.kind() == .dir) allocator.free(item.stored);
    };

    // 1. The text file, by name: the order that makes a subtree a range and a file readable by a human.
    std.mem.sort(Laid, work, {}, storedLessThan);
    var txt: std.ArrayListUnmanaged(u8) = .empty;
    errdefer txt.deinit(allocator);
    for (work) |*item| {
        item.offset = txt.items.len;
        item.length = @intCast(item.stored.len);
        try txt.appendSlice(allocator, item.stored);
        try txt.append(allocator, '\n');
    }

    // 2. `roots`, from the same order. A folder's own `dir/` line and every name below it are contiguous in the
    //    text order (that is what the slash buys, § 4), so a range starts there and ends at the first name that is
    //    *not* under it. That name is often the next folder — but it can be a root-level file, and ending the
    //    range at the next folder would then swallow the file and report a sibling as part of the subtree.
    var roots: std.ArrayListUnmanaged(RootRange) = .empty;
    errdefer roots.deinit(allocator);
    const Open = struct { folder: []const u8, start: u64 };
    var open: ?Open = null;
    for (work) |item| {
        if (open) |range| {
            if (std.mem.startsWith(u8, item.stored, range.folder)) continue; // still inside the open folder
            try roots.append(allocator, .{
                .name = try allocator.dupe(u8, range.folder[0 .. range.folder.len - 1]),
                .offset = range.start,
                .length = item.offset - range.start,
            });
            open = null;
        }
        // A range belongs to a direct child of the root: a nested folder is inside its parent's range, which the
        // parent's own name says by being the same as the folder's first path segment.
        if (item.entry.kind() != .dir) continue;
        const segment = topSegment(item.stored) orelse continue;
        if (segment.len != item.stored.len - 1) continue;
        open = .{ .folder = item.stored, .start = item.offset };
    }
    if (open) |range| {
        try roots.append(allocator, .{
            .name = try allocator.dupe(u8, range.folder[0 .. range.folder.len - 1]),
            .offset = range.start,
            .length = txt.items.len - range.start,
        });
    }

    // 3. The meta, by `(nameHash, name)`, with each entry pointing at its name in the text layout.
    std.mem.sort(Laid, work, {}, hashOrderLessThan);
    const meta = try allocator.alloc(u8, work.len * format.entry_size);
    errdefer allocator.free(meta);
    for (work, 0..) |item, index| {
        var entry = item.entry;
        entry.name_offset = item.offset;
        entry.name_length = item.length;
        entry.encode(meta[index * format.entry_size ..][0..format.entry_size]);
    }

    return .{ .meta = meta, .txt = try txt.toOwnedSlice(allocator), .roots = try roots.toOwnedSlice(allocator) };
}


/// Free a layout, including the range names it owns.
pub fn deinit(allocator: std.mem.Allocator, value: Layout) void {
    allocator.free(value.meta);
    allocator.free(value.txt);
    for (value.roots) |range| allocator.free(range.name);
    allocator.free(value.roots);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn file(name: []const u8, hash: u64) Item {
    var entry = std.mem.zeroes(format.Entry);
    entry.name_hash = format.wyhash(name);
    entry.content_hash = hash;
    entry.size_bytes = 1;
    entry.flags_word = format.flags.regular_file | format.flags.content_known;
    return .{ .name = name, .entry = entry };
}

fn directory(name: []const u8) Item {
    var entry = std.mem.zeroes(format.Entry);
    entry.name_hash = format.wyhash(name);
    entry.flags_word = format.flags.is_dir;
    return .{ .name = name, .entry = entry };
}

test "the text file is by name with a slashed directory, the meta by name hash" {
    const layout_result = try layout(testing.allocator, &.{
        file("a.txt", 1),
        file("src/b.java", 2),
        directory("src"),
    });
    defer deinit(testing.allocator, layout_result);

    try testing.expectEqualStrings("a.txt\nsrc/\nsrc/b.java\n", layout_result.txt);

    // The three hashes sort as a.txt (0x6a91…), src/b.java (0x79d4…), src (0xaa19…).
    const first = format.Entry.decode(layout_result.meta[0..format.entry_size]);
    const second = format.Entry.decode(layout_result.meta[format.entry_size..][0..format.entry_size]);
    const third = format.Entry.decode(layout_result.meta[2 * format.entry_size ..][0..format.entry_size]);
    try testing.expectEqual(format.wyhash("a.txt"), first.name_hash);
    try testing.expectEqual(format.wyhash("src/b.java"), second.name_hash);
    try testing.expectEqual(format.wyhash("src"), third.name_hash);

    // Each entry points at its own name in the text file, whatever order it sits in.
    for (0..3) |index| {
        const entry = format.Entry.decode(layout_result.meta[index * format.entry_size ..][0..format.entry_size]);
        const slice = layout_result.txt[entry.name_offset..][0..entry.name_length];
        const slash = std.mem.indexOfScalar(u8, slice, '/') == slice.len - 1;
        const stripped = if (entry.kind() == .dir and slice[slice.len - 1] == '/') slice[0 .. slice.len - 1] else slice;
        _ = slash;
        try testing.expectEqual(entry.name_hash, format.wyhash(stripped));
    }
}

test "roots gives one range per direct child, covering its own entry and its subtree" {
    const layout_result = try layout(testing.allocator, &.{
        file("a.txt", 1),
        directory("src"),
        file("src/b.java", 2),
        directory("docs"),
        file("docs/readme.md", 3),
        file("e.txt", 4), // a root-level file between two folders: not part of either range
        file("z.txt", 5),
    });
    defer deinit(testing.allocator, layout_result);

    try testing.expectEqualStrings("a.txt\ndocs/\ndocs/readme.md\ne.txt\nsrc/\nsrc/b.java\nz.txt\n", layout_result.txt);
    try testing.expectEqual(@as(usize, 2), layout_result.roots.len);
    try testing.expectEqualStrings("docs", layout_result.roots[0].name);
    try testing.expectEqualStrings("src", layout_result.roots[1].name);
    // Each range is exactly the folder's own line and everything below it — the range ends where the prefix stops
    // matching, which is `e.txt` here and not `src/` (§ 18: the range must not return a sibling).
    const docs = layout_result.roots[0];
    try testing.expectEqualStrings("docs/\ndocs/readme.md\n", layout_result.txt[docs.offset..][0..docs.length]);
    const src = layout_result.roots[1];
    try testing.expectEqualStrings("src/\nsrc/b.java\n", layout_result.txt[src.offset..][0..src.length]);
    // Root-level files are not ranges, and the ranges do not overlap.
    try testing.expect(docs.offset < src.offset);
    try testing.expect(docs.offset + docs.length <= src.offset);
}

test "an empty tree lays out as two empty files and no roots" {
    const layout_result = try layout(testing.allocator, &.{});
    defer deinit(testing.allocator, layout_result);
    try testing.expectEqual(@as(usize, 0), layout_result.meta.len);
    try testing.expectEqual(@as(usize, 0), layout_result.txt.len);
    try testing.expectEqual(@as(usize, 0), layout_result.roots.len);
}