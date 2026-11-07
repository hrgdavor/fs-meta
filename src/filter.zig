// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! Consumer-side name filter for change streams (reconcile, merge, socket replay and live streaming).
//!
//! A consumer that only cares about markdown files should not receive every change in the tree and
//! filter client-side. This module gives it a server-side filter: the engine still tracks everything,
//! but only sends changes whose names match the consumer's patterns.
//!
//! ## Semantics
//!
//! Two lists, both gitignore-style patterns (the same `gitignore.globMatch` every wildcard in this
//! project uses, DEC-051):
//!
//! - **Include**: when non-empty, a name is sent only if it matches at least one include pattern.
//! - **Exclude**: a name matching any exclude pattern is suppressed, even if it matched an include.
//!
//! The exclude list wins: it is the consumer's way of saying "everything except these". When both are
//! empty, every name is sent (the existing behaviour).
//!
//! ## Anchoring
//!
//! The anchoring rule is gitignore's own (the same `query.zig`'s `Glob` uses):
//!
//! - A pattern **without a `/`** names a basename and matches it at any depth: `*.md` matches
//!   `README.md` and `docs/guide.md`.
//! - A pattern **with a `/`** is relative to the root and is matched against the whole name path:
//!   `docs/*.md` matches `docs/guide.md` but not `other/docs/guide.md`.
//!
//! Matching is case-sensitive, as git's is.
//!
//! ## Wire encoding (socket `SUBSCRIBE`)
//!
//! The `SUBSCRIBE` payload is length-prefixed by the frame, so the server distinguishes the forms by
//! `length`:
//!
//! - `length == 8`: the original form — `u64 from_batch`, no filter.
//! - `length > 8`: the extended form — `u64 from_batch`, `u16 include_count`,
//!   `include_count × (u16 pattern_len + pattern_bytes)`, `u16 exclude_count`,
//!   `exclude_count × (u16 pattern_len + pattern_bytes)`.
//!
//! All integers are little-endian. A pattern is its UTF-8 bytes, no terminator. The extended section
//! must end exactly at the payload's end; a truncated length/count or trailing bytes are `Malformed`
//! (the protocol's `protocol` error). `decodeSubscribe` is the one decoder both socket paths use.

const std = @import("std");
const gitignore = @import("gitignore.zig");

/// One compiled pattern: the pattern bytes plus the anchoring decision.
pub const Pattern = struct {
    bytes: []const u8,
    anchored: bool,

    fn matches(self: *const Pattern, name: []const u8) bool {
        const text = if (self.anchored) name else baseName(name);
        return gitignore.globMatch(self.bytes, text);
    }
};

/// The final segment of a `/`-separated path.
fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// A consumer's include/exclude filter. An empty filter (no patterns) passes every name.
pub const Filter = struct {
    include: []const Pattern,
    exclude: []const Pattern,

    /// The filter that passes every name: what a client that sent the original 8-byte `SUBSCRIBE` gets.
    pub fn passAll() Filter {
        return .{ .include = &[_]Pattern{}, .exclude = &[_]Pattern{} };
    }

    /// Compile a filter from raw pattern strings. The pattern lists are copied; the pattern **bytes** are
    /// borrowed, so the caller's strings must outlive the filter (the socket decoder copies the bytes
    /// instead — see `decodeSubscribe`). An empty slice compiles to an empty list (pass-all).
    pub fn compile(allocator: std.mem.Allocator, include_patterns: []const []const u8, exclude_patterns: []const []const u8) !Filter {
        var inc: std.ArrayListUnmanaged(Pattern) = .empty;
        defer inc.deinit(allocator);
        for (include_patterns) |p| {
            try inc.append(allocator, compileOne(p));
        }
        var exc: std.ArrayListUnmanaged(Pattern) = .empty;
        defer exc.deinit(allocator);
        for (exclude_patterns) |p| {
            try exc.append(allocator, compileOne(p));
        }
        return .{
            .include = try inc.toOwnedSlice(allocator),
            .exclude = try exc.toOwnedSlice(allocator),
        };
    }

    /// Free the compiled patterns.
    pub fn deinit(self: *Filter, allocator: std.mem.Allocator) void {
        allocator.free(self.include);
        allocator.free(self.exclude);
        self.* = undefined;
    }

    /// Whether a name passes this filter.
    ///
    /// - If `include` is non-empty, the name must match at least one include pattern.
    /// - If the name matches any exclude pattern, it is suppressed regardless of include.
    /// - If both lists are empty, every name passes.
    pub fn matches(self: *const Filter, name: []const u8) bool {
        for (self.exclude) |p| {
            if (p.matches(name)) return false;
        }
        if (self.include.len == 0) return true;
        for (self.include) |p| {
            if (p.matches(name)) return true;
        }
        return false;
    }

    /// True when the filter is the pass-all (no patterns at all).
    pub fn isPassAll(self: *const Filter) bool {
        return self.include.len == 0 and self.exclude.len == 0;
    }
};

pub fn compileOne(pattern: []const u8) Pattern {
    const anchored = (pattern.len > 0 and pattern[0] == '/') or
        std.mem.indexOfScalar(u8, pattern, '/') != null;
    const body = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
    return .{ .bytes = body, .anchored = anchored };
}

/// A decoded socket `SUBSCRIBE` payload: the client's `from_batch` and its filter.
///
/// `storage` is the copied pattern section the compiled patterns point into. It is one allocation, owned
/// by whoever receives this value; `deinit` frees it together with the filter's pattern arrays.
pub const Subscribe = struct {
    from_batch: u64,
    filter: Filter,
    /// The copied payload tail holding the pattern bytes; empty for the 8-byte pass-all form.
    storage: []const u8,

    pub fn deinit(self: *Subscribe, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.filter.deinit(allocator);
        self.* = undefined;
    }
};

/// Why a `SUBSCRIBE` payload could not be decoded. Both are the protocol's `protocol` error (code 1) at
/// the socket: `FORMAT.socket.md` § Errors names a `SUBSCRIBE` shorter than 8 bytes and a malformed
/// extended filter section together.
pub const DecodeError = error{ TooShort, Malformed };

/// Decode a `SUBSCRIBE` payload (`FORMAT.socket.md` § SUBSCRIBE filter patterns).
///
/// - `payload.len == 8`: the original form — `u64 from_batch`, pass-all filter.
/// - `payload.len > 8`: the extended form — `u64 from_batch`, `u16 include_count`, the include patterns
///   (`u16 length` + UTF-8 bytes each), `u16 exclude_count`, the exclude patterns the same way. The
///   section must end exactly at the end of the payload.
/// - `payload.len < 8`: `error.TooShort`.
///
/// The pattern bytes are **copied** into `allocator`, so the result outlives the buffer the caller
/// decoded from: a stream reader's `take` slice is recycled by its next read, and a subscriber's filter
/// has to keep working for the life of the connection, including while it reads `PING` frames.
pub fn decodeSubscribe(allocator: std.mem.Allocator, payload: []const u8) (DecodeError || std.mem.Allocator.Error)!Subscribe {
    if (payload.len < 8) return error.TooShort;
    const from_batch = std.mem.readInt(u64, payload[0..8], .little);
    if (payload.len == 8) return .{ .from_batch = from_batch, .filter = Filter.passAll(), .storage = &.{} };

    // One copy of the pattern section; every pattern below is a slice into it, so no per-pattern
    // allocation and one free.
    const storage = try allocator.dupe(u8, payload[8..]);
    errdefer allocator.free(storage);

    var include: std.ArrayListUnmanaged(Pattern) = .empty;
    errdefer include.deinit(allocator);
    var exclude: std.ArrayListUnmanaged(Pattern) = .empty;
    errdefer exclude.deinit(allocator);

    var pos: usize = 0;
    try decodePatternList(storage, &pos, allocator, &include);
    try decodePatternList(storage, &pos, allocator, &exclude);
    if (pos != storage.len) return error.Malformed;

    const include_slice = try include.toOwnedSlice(allocator);
    errdefer allocator.free(include_slice);
    const exclude_slice = try exclude.toOwnedSlice(allocator);
    return .{
        .from_batch = from_batch,
        .filter = .{ .include = include_slice, .exclude = exclude_slice },
        .storage = storage,
    };
}

/// One `u16 count` list of `u16 length` + bytes, read from `storage` at `pos`.
fn decodePatternList(
    storage: []const u8,
    pos: *usize,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Pattern),
) (DecodeError || std.mem.Allocator.Error)!void {
    const count = try takeU16(storage, pos);
    for (0..count) |_| {
        const length: usize = try takeU16(storage, pos);
        const start = pos.*;
        if (length > storage.len - start) return error.Malformed;
        pos.* = start + length;
        try out.append(allocator, compileOne(storage[start..][0..length]));
    }
}

/// A little-endian `u16` at `pos`, advancing it. A list that runs past the payload is `Malformed`, never
/// a read past the end.
fn takeU16(bytes: []const u8, pos: *usize) error{Malformed}!u16 {
    const start = pos.*;
    if (start + 2 > bytes.len) return error.Malformed;
    pos.* = start + 2;
    return std.mem.readInt(u16, bytes[start..][0..2], .little);
}

test "empty filter passes everything" {
    const f = Filter{ .include = &[_]Pattern{}, .exclude = &[_]Pattern{} };
    try std.testing.expect(f.matches("anything.txt"));
    try std.testing.expect(f.isPassAll());
}

test "include only: matching names pass" {
    var f = try Filter.compile(std.testing.allocator, &[_][]const u8{"*.md"}, &[_][]const u8{});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("README.md"));
    try std.testing.expect(f.matches("docs/guide.md"));
    try std.testing.expect(!f.matches("src/main.zig"));
    try std.testing.expect(!f.matches("README.txt"));
}

test "exclude wins over include" {
    var f = try Filter.compile(std.testing.allocator, &[_][]const u8{"*.md"}, &[_][]const u8{"draft*"});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("README.md"));
    try std.testing.expect(!f.matches("draft-notes.md"));
}

test "anchored pattern matches the whole path" {
    var f = try Filter.compile(std.testing.allocator, &[_][]const u8{"docs/*.md"}, &[_][]const u8{});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("docs/guide.md"));
    try std.testing.expect(!f.matches("other/docs/guide.md"));
    try std.testing.expect(!f.matches("guide.md"));
}

test "basename pattern matches at any depth" {
    var f = try Filter.compile(std.testing.allocator, &[_][]const u8{"*.zig"}, &[_][]const u8{});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("main.zig"));
    try std.testing.expect(f.matches("src/deep/main.zig"));
    try std.testing.expect(!f.matches("main.zig.bak"));
}

/// Build an extended `SUBSCRIBE` payload into `buffer` and return the filled slice. The helper is
/// deliberately unchecked apart from the assertions: a test writes the bytes the wire documents.
fn encodeSubscribe(buffer: []u8, from_batch: u64, include: []const []const u8, exclude: []const []const u8) []u8 {
    var pos: usize = 8;
    std.mem.writeInt(u64, buffer[0..8], from_batch, .little);
    for ([_][]const []const u8{ include, exclude }) |patterns| {
        std.debug.assert(pos + 2 <= buffer.len);
        std.mem.writeInt(u16, buffer[pos..][0..2], @intCast(patterns.len), .little);
        pos += 2;
        for (patterns) |pattern| {
            std.debug.assert(pos + 2 + pattern.len <= buffer.len);
            std.mem.writeInt(u16, buffer[pos..][0..2], @intCast(pattern.len), .little);
            pos += 2;
            @memcpy(buffer[pos..][0..pattern.len], pattern);
            pos += pattern.len;
        }
    }
    return buffer[0..pos];
}

test "the 8-byte SUBSCRIBE form decodes to the pass-all filter" {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u64, &payload, 42, .little);
    var sub = try decodeSubscribe(std.testing.allocator, &payload);
    defer sub.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), sub.from_batch);
    try std.testing.expect(sub.filter.isPassAll());
    try std.testing.expect(sub.filter.matches("anything.txt"));
}

test "the extended SUBSCRIBE form applies include, and exclude wins" {
    var buffer: [128]u8 = undefined;
    const payload = encodeSubscribe(&buffer, 7, &.{ "*.md", "docs/*.txt" }, &.{"draft*"});
    var sub = try decodeSubscribe(std.testing.allocator, payload);
    defer sub.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), sub.from_batch);
    try std.testing.expect(sub.filter.matches("README.md"));
    try std.testing.expect(sub.filter.matches("docs/guide.txt"));
    try std.testing.expect(!sub.filter.matches("src/main.zig"));
    // Exclude wins even though `draft*.md` matches the include list.
    try std.testing.expect(!sub.filter.matches("draft-notes.md"));
    try std.testing.expect(!sub.filter.matches("docs/draft.txt"));
}

test "extended SUBSCRIBE: two empty counts is still pass-all" {
    var buffer: [32]u8 = undefined;
    const payload = encodeSubscribe(&buffer, 3, &.{}, &.{});
    var sub = try decodeSubscribe(std.testing.allocator, payload);
    defer sub.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), sub.from_batch);
    try std.testing.expect(sub.filter.isPassAll());
}

test "decoded patterns outlive the payload buffer they came from" {
    // The server reads the frame into a reusable reader buffer; a subscriber then reads and writes more
    // frames. The pattern bytes must be a copy, not a slice into that buffer.
    var buffer: [64]u8 = undefined;
    const payload = encodeSubscribe(&buffer, 1, &.{"*.md"}, &.{});
    var sub = try decodeSubscribe(std.testing.allocator, payload);
    defer sub.deinit(std.testing.allocator);

    @memset(&buffer, 0);
    try std.testing.expect(sub.filter.matches("README.md"));
    try std.testing.expect(!sub.filter.matches("main.zig"));
}

test "malformed SUBSCRIBE payloads are refused, never read past the end" {
    // Shorter than the u64 the original form requires.
    try std.testing.expectError(error.TooShort, decodeSubscribe(std.testing.allocator, &[_]u8{ 1, 2, 3, 4, 5, 6, 7 }));

    // Extended, but the include count's second byte is missing.
    const truncated_count = std.mem.zeroes([9]u8);
    try std.testing.expectError(error.Malformed, decodeSubscribe(std.testing.allocator, &truncated_count));

    // Include count says one pattern; the payload ends before its length.
    var count_only: [10]u8 = undefined;
    @memset(&count_only, 0);
    std.mem.writeInt(u16, count_only[8..10], 1, .little);
    try std.testing.expectError(error.Malformed, decodeSubscribe(std.testing.allocator, &count_only));

    // The pattern's stated length runs past the payload.
    var overrun: [14]u8 = undefined;
    @memset(&overrun, 0);
    std.mem.writeInt(u16, overrun[8..10], 1, .little);
    std.mem.writeInt(u16, overrun[10..12], 5, .little);
    try std.testing.expectError(error.Malformed, decodeSubscribe(std.testing.allocator, &overrun));

    // The include list is complete but the exclude count is missing.
    var buffer: [32]u8 = undefined;
    const no_exclude = encodeSubscribe(&buffer, 0, &.{"*.md"}, &.{});
    try std.testing.expectError(error.Malformed, decodeSubscribe(std.testing.allocator, no_exclude[0 .. no_exclude.len - 2]));

    // Trailing bytes after the exclude list are not ignored: the layout is exact.
    var trailing: [40]u8 = undefined;
    const exact = encodeSubscribe(&trailing, 0, &.{}, &.{});
    const with_trailing = trailing[0 .. exact.len + 1];
    with_trailing[exact.len] = 0;
    try std.testing.expectError(error.Malformed, decodeSubscribe(std.testing.allocator, with_trailing));
}
