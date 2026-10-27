// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The nested-root guard's path arithmetic (`plans/worktrees.md` § 5, R2):
//!
//! * the **relative** path of a served descendant inside a served parent — the one line `root add` writes under
//!   the parent's `# fsmeta-managed` block;
//! * the two file operations the guard needs: append one child (idempotent, for a pass that repairs a deleted
//!   block) and rewrite the block to exactly the served descendants (for startup and removal, which must also
//!   drop a stale line).
//!
//! The pattern syntax and the escaping live in `ignores.zig`; this module never invents a matcher. The prefix test
//! is `paths.isInside`, the same segment rule (not a string-prefix test) the old nesting warning used, so `/a/bc`
//! is not inside `/a/b`. Paths are canonical and absolute by the time they reach here.

const std = @import("std");
const paths = @import("daemon/paths.zig");
const ignores = @import("ignores.zig");

/// `child` relative to `parent`, `/`-separated and without a leading separator. `error.NotNested` when the
/// segment rule says the two do not nest, or when they are the same path.
pub fn relativePath(arena: std.mem.Allocator, parent: []const u8, child: []const u8) ![]const u8 {
    const trimmed = trimTrailingSeparators(parent);
    if (!paths.isInside(trimmed, child)) return error.NotNested;
    var relative = child[trimmed.len..];
    if (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
    if (relative.len == 0) return error.NotNested;

    const out = try arena.dupe(u8, relative);
    for (out) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
    return out;
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    return path[0..end];
}

/// Append one managed line per descendant. Idempotent, and never rewrites the user's lines: this is the form a
/// pass uses to repair a block that was deleted or edited by hand.
pub fn guardDescendants(
    arena: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    descendants: []const []const u8,
) !void {
    for (descendants) |child| {
        const relative = try relativePath(arena, parent, child);
        try ignores.appendManaged(arena, io, parent, relative);
    }
}

/// Rewrite the parent's managed block to exactly `descendants` (dropping stale entries, adding missing ones) and
/// leave the user's lines alone. Used at daemon start and after `root remove`.
pub fn reconcileDescendants(
    arena: std.mem.Allocator,
    io: std.Io,
    parent: []const u8,
    descendants: []const []const u8,
) !void {
    var relatives: std.ArrayListUnmanaged([]const u8) = .empty;
    defer relatives.deinit(arena);
    for (descendants) |child| {
        const relative = try relativePath(arena, parent, child);
        try relatives.append(arena, relative);
    }
    try ignores.rewriteManaged(arena, io, parent, relatives.items);
}

// ---------------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------------

const testing = std.testing;

const TestArena = struct {
    state: std.heap.ArenaAllocator,

    fn init() TestArena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestArena) void {
        self.state.deinit();
    }

    fn allocator(self: *TestArena) std.mem.Allocator {
        return self.state.allocator();
    }
};

fn tmpRoot(io: std.Io, dir: std.Io.Dir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const count = try dir.realPath(io, buffer);
    return buffer[0..count];
}

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(name) orelse ".");
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "a child is made relative to its parent, never with a leading separator" {
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("packages/a", try relativePath(allocator, "/work/app", "/work/app/packages/a"));
    try testing.expectEqualStrings("packages/a", try relativePath(allocator, "/work/app/", "/work/app/packages/a"));
    try testing.expectEqualStrings("a", try relativePath(allocator, "/", "/a"));
    try testing.expectError(error.NotNested, relativePath(allocator, "/work/app", "/work/application"));
    try testing.expectError(error.NotNested, relativePath(allocator, "/work/app", "/work/app"));

    if (@import("builtin").os.tag == .windows) {
        try testing.expectEqualStrings("packages/a", try relativePath(allocator, "C:\\work\\app", "C:\\work\\app\\packages\\a"));
        try testing.expectEqualStrings("a", try relativePath(allocator, "C:\\", "C:\\a"));
        // Canonical paths can differ only in case on Windows; the rule is the file system's.
        try testing.expectEqualStrings("packages/a", try relativePath(allocator, "c:\\WORK\\app", "C:\\work\\app\\packages\\a"));
    }
}

test "guardDescendants appends, and reconcileDescendants drops stale lines and keeps the user's" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, io, ".fs-meta/ignore", "*.log\n# fsmeta-managed\nold/root/\n");
    try writeFile(tmp.dir, io, "one/tree/a.txt", "a");
    try writeFile(tmp.dir, io, "two/tree/b.txt", "b");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    const one = try std.fs.path.join(allocator, &.{ root, "one", "tree" });
    const two = try std.fs.path.join(allocator, &.{ root, "two", "tree" });

    try guardDescendants(allocator, io, root, &.{ one, two });
    try guardDescendants(allocator, io, root, &.{one}); // idempotent
    const after_append = try tmp.dir.readFileAlloc(io, ".fs-meta/ignore", allocator, std.Io.Limit.limited(1 << 16));
    try testing.expectEqualStrings(
        "*.log\n# fsmeta-managed\nold/root/\none/tree/\ntwo/tree/\n",
        after_append,
    );

    try reconcileDescendants(allocator, io, root, &.{two});
    const after_reconcile = try tmp.dir.readFileAlloc(io, ".fs-meta/ignore", allocator, std.Io.Limit.limited(1 << 16));
    try testing.expectEqualStrings("*.log\n# fsmeta-managed\ntwo/tree/\n", after_reconcile);

    try reconcileDescendants(allocator, io, root, &.{});
    const empty = try tmp.dir.readFileAlloc(io, ".fs-meta/ignore", allocator, std.Io.Limit.limited(1 << 16));
    try testing.expectEqualStrings("*.log\n# fsmeta-managed\n", empty);
}

test "guardDescendants refuses a path that is not inside the parent" {
    var arena = TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectError(error.NotNested, guardDescendants(allocator, testing.io, "/work/app", &.{"/work/other"}));
    try testing.expectError(error.NotNested, reconcileDescendants(allocator, testing.io, "/work/app", &.{"/work/other"}));
}
