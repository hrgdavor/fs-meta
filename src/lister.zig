// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The OS boundary `coldstart.zig` calls: one directory listing that comes back **with its children's metadata**,
//! and one stat of a directory. The point is to trade a `readdir` plus one `stat` per entry for a single
//! enumeration syscall per directory — and, on Windows, for one that carries the file identity too, so no entry
//! needs a handle opened.
//!
//! ## Windows (implemented and tested here)
//!
//! `NtQueryDirectoryFile` with `FileIdBothDirectoryInformation` (class 37) returns, per entry: the name, the
//! last-write time, the size, the attributes **and the 64-bit `FileId`** — exactly the four facts the cache
//! needs, in one syscall, with no `GetFileInformationByHandle` per file. The volume serial number, which the
//! format pairs with the index (§ 5), is a property of the volume rather than the entry, so it is fetched once
//! per directory through the existing `scan.fileIdAt` helper (one handle, not one per child) and applied to every
//! entry in that listing.
//!
//! ## Everywhere else
//!
//! The portable listing (`Dir.iterate` + `statFile` + `scan.fileIdAt`) is correct on every platform and is also
//! the oracle the Windows test compares against. Linux can replace its per-entry `statx` with an `io_uring`
//! batch and macOS can replace the whole thing with `getattrlistbulk`; both are the same `Lister` shape and can
//! land without touching `coldstart.zig`.

const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const scan = @import("scan.zig");
const coldstart = @import("coldstart.zig");
const cache_mod = @import("cache.zig");
const ignore_mod = @import("ignore.zig");

const w = std.os.windows;

/// The context a `Lister` closes over: the I/O implementation, and nothing else. Paths arrive fully qualified
/// from `coldstart.coldStart`, which joined them with the root it was given.
pub const Tree = struct {
    io: std.Io,
    /// Names never listed, whatever their kind (§ 16: `.git` and `.fs-meta` are unconditional).
    reserved: []const []const u8 = &.{ ".git", ".fs-meta" },
    /// Directory names never entered, on top of `reserved`.
    ignored_dir_names: []const []const u8 = &.{},
    /// The `.gitignore` stack of this pass; `null` lists without consulting rules.
    ignore: ?*ignore_mod.Stack = null,
    /// Force the naive listing — a readdir plus a `stat` (and an identity handle) per entry — instead of the
    /// platform bulk call. It exists to be measured against, not to be used.
    per_file: bool = false,
    /// The volume serial number of this tree's volume, looked up at most once per pass: every entry in every
    /// directory shares it, so fetching it per directory costs a handle open for no information.
    volume_serial: ?u64 = null,

    /// Whether a child is visible to the engine. Applied in the listing, so an excluded directory is never
    /// queued and never listed — git's rule, and the reason the engine cannot describe its own output.
    pub fn visible(self: *const Tree, name: []const u8, is_dir: bool) bool {
        for (self.reserved) |reserved| {
            if (std.mem.eql(u8, name, reserved)) return false;
        }
        if (is_dir) {
            for (self.ignored_dir_names) |ignored| {
                if (std.mem.eql(u8, name, ignored)) return false;
            }
        }
        return true;
    }

    pub fn lister(self: *Tree) coldstart.Lister {
        return .{ .ctx = @ptrCast(self), .listFn = listFn, .statFn = statFn };
    }
};

fn treeOf(ctx: *anyopaque) *Tree {
    return @ptrCast(@alignCast(ctx));
}

/// The listing: the OS-specific path on Windows, the portable one elsewhere. `pub` so a test can ask for one
/// implementation directly and compare the two.
pub fn list(self: *Tree, allocator: std.mem.Allocator, dir_path: []const u8) ![]coldstart.EntryInfo {
    var entries = if (!self.per_file and builtin.os.tag == .windows)
        try listWindows(self, allocator, dir_path)
    else
        try listPortable(self.io, allocator, dir_path);
    // Drop the excluded names in place; the alternatives are a second array or leaking the tail. The same rules
    // the walker applies: reserved names always, configured directory names for directories, then `.gitignore`
    // — because the two paths must never disagree about which names exist.
    // Resolved once for the whole directory; with no rule anywhere above it, the matcher is never entered.
    const check_rules = if (self.ignore) |stack| try stack.hasRules(dir_path) else false;
    var kept: usize = 0;
    for (entries) |entry| {
        if (!self.visible(entry.name, entry.kind == .dir)) continue;
        if (check_rules) {
            if (try self.ignore.?.ignored(dir_path, entry.name, entry.kind == .dir)) continue;
        }
        entries[kept] = entry;
        kept += 1;
    }
    return entries[0..kept];
}

fn listFn(ctx: *anyopaque, allocator: std.mem.Allocator, dir_path: []const u8) anyerror![]coldstart.EntryInfo {
    return list(treeOf(ctx), allocator, dir_path);
}

fn statFn(ctx: *anyopaque, path: []const u8) anyerror!?coldstart.StatInfo {
    const self = treeOf(ctx);
    if (builtin.os.tag == .windows) return statWindows(self.io, path);
    return statPortable(self.io, path);
}

fn mtimeOf(timestamp: std.Io.Timestamp) u64 {
    if (timestamp.nanoseconds <= 0) return 0;
    const value: u128 = @intCast(timestamp.nanoseconds);
    return @intCast(value);
}

fn kindOf(kind: std.Io.File.Kind) ?format.Kind {
    return switch (kind) {
        .file => .regular_file,
        .directory => .dir,
        .sym_link => .symlink,
        else => null,
    };
}

// --------------------------------------------------------------------------------------------- portable

fn openDirAny(io: std.Io, path: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
}

fn listPortable(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![]coldstart.EntryInfo {
    var dir = try openDirAny(io, dir_path);
    defer dir.close(io);

    var out: std.ArrayListUnmanaged(coldstart.EntryInfo) = .empty;
    errdefer out.deinit(allocator);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        const kind = kindOf(stat.kind) orelse continue;
        const id = scan.fileIdAt(dir, io, entry.name);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = kind,
            .mtime_ns = mtimeOf(stat.mtime),
            .size_bytes = if (kind == .regular_file) stat.size else 0,
            .file_id_lo = id.lo,
            .file_id_hi = id.hi,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn statPortable(io: std.Io, path: []const u8) !?coldstart.StatInfo {
    // The directory's own metadata: its parent handle gives the child's stat and identity without a second call.
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (base.len == 0) return null;
    var dir = openDirAny(io, parent) catch |err| return switch (err) {
        error.FileNotFound => null,
        else => err,
    };
    defer dir.close(io);
    const stat = dir.statFile(io, base, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => null,
        else => err,
    };
    const id = scan.fileIdAt(dir, io, base);
    return .{ .mtime_ns = mtimeOf(stat.mtime), .file_id_lo = id.lo, .file_id_hi = id.hi };
}

// --------------------------------------------------------------------------------------------- Windows

/// `FILE_ID_BOTH_DIR_INFORMATION`: the Windows structure that carries the identity inside the listing. Zig's
/// standard library declares `FILE_BOTH_DIR_INFORMATION` (no `FileId`), so the one field this project needs is
/// declared here rather than opening a handle per file to ask for it.
const FileIdBothDirInformation = extern struct {
    NextEntryOffset: w.ULONG,
    FileIndex: w.ULONG,
    CreationTime: w.LARGE_INTEGER,
    LastAccessTime: w.LARGE_INTEGER,
    LastWriteTime: w.LARGE_INTEGER,
    ChangeTime: w.LARGE_INTEGER,
    EndOfFile: w.LARGE_INTEGER,
    AllocationSize: w.LARGE_INTEGER,
    FileAttributes: w.ULONG,
    FileNameLength: w.ULONG,
    EaSize: w.ULONG,
    ShortNameLength: w.CHAR,
    ShortName: [12]w.WCHAR,
    FileId: w.LARGE_INTEGER,
    FileName: [1]w.WCHAR,
};

/// `FileIdBothDirectoryInformation` from `FILE_INFORMATION_CLASS`.
const file_id_both_directory_information: w.FILE.INFORMATION_CLASS = @enumFromInt(37);

const FILE_ATTRIBUTE_DIRECTORY: w.ULONG = 0x0000_0010;
const FILE_ATTRIBUTE_REPARSE_POINT: w.ULONG = 0x0000_0400;

/// Windows FILETIME counts 100 ns ticks from 1601-01-01; this is the offset to 1970-01-01 in ticks.
const filetime_unix_epoch: i64 = 116_444_736_000_000_000;

fn filetimeToNs(filetime: w.LARGE_INTEGER) u64 {
    const ticks = filetime - filetime_unix_epoch;
    if (ticks <= 0) return 0;
    return @intCast(@as(u128, @intCast(ticks)) * 100);
}

fn kindOfWindows(attributes: w.ULONG) format.Kind {
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) return .dir;
    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) return .symlink;
    return .regular_file;
}

fn listWindows(tree: *Tree, allocator: std.mem.Allocator, dir_path: []const u8) ![]coldstart.EntryInfo {
    const io = tree.io;
    var dir = try openDirAny(io, dir_path);
    defer dir.close(io);

    const buffer_bytes = 64 * 1024;
    const buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(8), buffer_bytes);
    defer allocator.free(buffer);

    var out: std.ArrayListUnmanaged(coldstart.EntryInfo) = .empty;
    errdefer out.deinit(allocator);

    var restart = true;
    while (true) {
        var status_block: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtQueryDirectoryFile(
            dir.handle,
            null,
            null,
            null,
            &status_block,
            buffer.ptr,
            @intCast(buffer_bytes),
            file_id_both_directory_information,
            w.BOOLEAN.FALSE,
            null,
            @enumFromInt(@intFromBool(restart)),
        );
        restart = false;
        switch (status) {
            .SUCCESS => {},
            .NO_MORE_FILES => break,
            .BUFFER_OVERFLOW => {}, // entries were returned; the next call continues
            else => return error.DirectoryListingFailed,
        }

        var offset: usize = 0;
        while (true) {
            const info: *const FileIdBothDirInformation = @ptrCast(@alignCast(buffer.ptr + offset));
            const name_bytes = info.FileNameLength / 2;
            const name_ptr: [*]const u16 = @ptrCast(&info.FileName);
            const name_utf16 = name_ptr[0..name_bytes];

            const name_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, name_utf16);
            errdefer allocator.free(name_utf8);
            if (!std.mem.eql(u8, name_utf8, ".") and !std.mem.eql(u8, name_utf8, "..")) {
                try out.append(allocator, .{
                    .name = name_utf8,
                    .kind = kindOfWindows(info.FileAttributes),
                    .mtime_ns = filetimeToNs(info.LastWriteTime),
                    .size_bytes = if (kindOfWindows(info.FileAttributes) == .regular_file) @intCast(info.EndOfFile) else 0,
                    .file_id_lo = @as(u64, @bitCast(info.FileId)),
                    .file_id_hi = 0, // filled from the volume serial below
                });
            } else {
                allocator.free(name_utf8);
            }

            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
        // One lookup per pass: the serial belongs to the volume, not to the directory.
        if (out.items.len > 0) {
            const serial = tree.volume_serial orelse blk: {
                const id = scan.fileIdAt(dir, io, out.items[0].name);
                tree.volume_serial = id.hi;
                break :blk id.hi;
            };
            for (out.items) |*fact| fact.file_id_hi = serial;
        }
    }

    // Keep the trio's order deterministic without depending on the OS enumeration order.
    std.mem.sort(coldstart.EntryInfo, out.items, {}, entryLessThan);
    return out.toOwnedSlice(allocator);
}

fn entryLessThan(_: void, left: coldstart.EntryInfo, right: coldstart.EntryInfo) bool {
    return switch (format.compareNames(left.name, right.name)) {
        .lt => true,
        else => false,
    };
}

fn statWindows(io: std.Io, path: []const u8) !?coldstart.StatInfo {
    return statPortable(io, path);
}

// --------------------------------------------------------------------------------------------- tests

fn expectSameFacts(expected: []const coldstart.EntryInfo, actual: []const coldstart.EntryInfo) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqual(want.size_bytes, got.size_bytes);
        try std.testing.expectEqual(want.mtime_ns, got.mtime_ns);
        try std.testing.expectEqual(want.file_id_lo, got.file_id_lo);
        try std.testing.expectEqual(want.file_id_hi, got.file_id_hi);
    }
}

test "the bulk listing and the portable listing agree, entry for entry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.bin", .data = "12345678" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/c.java", .data = "class C {}\n" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_count];
    const sub = try std.fmt.allocPrint(std.testing.allocator, "{s}/src", .{root});
    defer std.testing.allocator.free(sub);

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const portable_root = try listPortable(io, arena, root);
    const portable_sub = try listPortable(io, arena, sub);
    // Two files and one directory at the root, one file below it.
    try std.testing.expectEqual(@as(usize, 3), portable_root.len);
    try std.testing.expectEqual(@as(usize, 1), portable_sub.len);
    for (portable_root) |fact| {
        if (fact.kind == .regular_file) try std.testing.expect(fact.file_id_lo != 0 or fact.file_id_hi != 0);
    }

    if (builtin.os.tag == .windows) {
        var tree_for_bulk: Tree = .{ .io = io };
        const bulk_root = try listWindows(&tree_for_bulk, arena, root);
        const bulk_sub = try listWindows(&tree_for_bulk, arena, sub);
        try expectSameFacts(portable_root, bulk_root);
        try expectSameFacts(portable_sub, bulk_sub);
    }
}

test "a stat hears a directory that went away" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "gone");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_count = try tmp.dir.realPath(io, &path_buffer);
    const root = try std.fmt.allocPrint(std.testing.allocator, "{s}/gone", .{path_buffer[0..base_count]});
    defer std.testing.allocator.free(root);
    var tree: Tree = .{ .io = io };
    try std.testing.expect((try statFn(&tree, root)) != null);
    try tmp.dir.deleteDir(io, "gone");
    try std.testing.expect((try statFn(&tree, root)) == null);
}
