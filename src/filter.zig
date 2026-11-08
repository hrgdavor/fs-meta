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
//! - `SUBSCRIBE`, `length == 8`: the original form — `u64 from_batch`, no filter.
//! - `SUBSCRIBE`, `length > 8`: the extended form — `u64 from_batch`, `u16 include_count`,
//!   `include_count × (u16 pattern_len + pattern_bytes)`, `u16 exclude_count`,
//!   `exclude_count × (u16 pattern_len + pattern_bytes)`.
//! - `SUBSCRIBE_V2` (`FORMAT.socket.md` § BUILD_STAGES): the same filter section after a 12-byte header —
//!   `u64 from_batch`, `u16 stage`, `u16 flags` (bit 0 = builder).
//!
//! All integers are little-endian. A pattern is its UTF-8 bytes, no terminator. The extended section
//! must end exactly at the payload's end; a truncated length/count or trailing bytes are `Malformed`
//! (the protocol's `protocol` error). `decodeSubscribe` and `decodeSubscribeV2` are the one decoder both
//! socket paths use; the only difference is the header width.

const std = @import("std");
const gitignore = @import("gitignore.zig");
const wire = @import("wire.zig");

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
    /// The staged-build stage. The original `SUBSCRIBE` is stage 0 (`FORMAT.socket.md` § BUILD_STAGES).
    stage: u16 = 0,
    /// Whether this subscriber is a builder that acknowledges batches; a listener is `false`.
    builder: bool = false,
    /// The last stage batch the client has applied (`SUBSCRIBE_V3` only). `null` means "no cursor supplied";
    /// the daemon starts such a subscriber at the current stage head.
    from_stage_batch: ?u64 = null,
    /// The copied payload tail holding the pattern bytes; empty for the 8-byte pass-all form.
    storage: []const u8,

    pub fn deinit(self: *Subscribe, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.filter.deinit(allocator);
        self.* = undefined;
    }
};

/// Why a `SUBSCRIBE` payload could not be decoded. All are the protocol's `protocol` error (code 1) at
/// the socket: `FORMAT.socket.md` § Errors names a `SUBSCRIBE` shorter than 8 bytes, a malformed
/// extended filter section, and a reserved `SUBSCRIBE_V2` flag together.
pub const DecodeError = error{ TooShort, Malformed, ReservedFlags };

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
    return decodeFilterSection(allocator, payload, 8, from_batch, 0, false, null);
}

/// Decode `SUBSCRIBE_V2` (`FORMAT.socket.md` § BUILD_STAGES): `u64 from_batch`, `u16 stage`,
/// `u16 flags`, then the same include/exclude section the extended `SUBSCRIBE` carries.
///
/// `flags` bit 0 is the builder role; every other bit is reserved and refused rather than ignored, because
/// a role this server does not understand must not silently become a listener.
pub fn decodeSubscribeV2(allocator: std.mem.Allocator, payload: []const u8) (DecodeError || std.mem.Allocator.Error)!Subscribe {
    if (payload.len < 12) return error.TooShort;
    const flags = std.mem.readInt(u16, payload[10..12], .little);
    if ((flags & ~@as(u16, 0x01)) != 0) return error.ReservedFlags;
    const from_batch = std.mem.readInt(u64, payload[0..8], .little);
    const stage = std.mem.readInt(u16, payload[8..10], .little);
    // A stage is a small chain, not a namespace; the same limit the daemon's stage walk assumes.
    if (stage > wire.max_stage) return error.Malformed;
    // The filter section is mandatory in the v2 form (even when both counts are zero), so the payload must at
    // least carry the two `u16` counts.
    if (payload.len < 14) return error.Malformed;
    return decodeFilterSection(allocator, payload, 12, from_batch, stage, (flags & 0x01) != 0, null);
}

/// Decode `SUBSCRIBE_V3`: `u64 from_batch`, `u64 from_stage_batch`, `u16 stage`, `u16 flags`, then the filter
/// section. The only addition over v2 is the stage-batch replay cursor.
pub fn decodeSubscribeV3(allocator: std.mem.Allocator, payload: []const u8) (DecodeError || std.mem.Allocator.Error)!Subscribe {
    if (payload.len < 20) return error.TooShort;
    const flags = std.mem.readInt(u16, payload[18..20], .little);
    if ((flags & ~@as(u16, 0x01)) != 0) return error.ReservedFlags;
    const from_batch = std.mem.readInt(u64, payload[0..8], .little);
    const from_stage_batch = std.mem.readInt(u64, payload[8..16], .little);
    const stage = std.mem.readInt(u16, payload[16..18], .little);
    if (stage > wire.max_stage) return error.Malformed;
    if (payload.len < 22) return error.Malformed;
    return decodeFilterSection(allocator, payload, 20, from_batch, stage, (flags & 0x01) != 0, from_stage_batch);
}

/// The common tail of both subscription forms: the include/exclude pattern section after `header_size`.
/// The section must end exactly at the payload's end.
fn decodeFilterSection(
    allocator: std.mem.Allocator,
    payload: []const u8,
    header_size: usize,
    from_batch: u64,
    stage: u16,
    builder: bool,
    from_stage_batch: ?u64,
) (DecodeError || std.mem.Allocator.Error)!Subscribe {
    // The `len == 8` fast path is the caller's; every path here has a filter section.
    const storage = try allocator.dupe(u8, payload[header_size..]);
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
        .stage = stage,
        .builder = builder,
        .from_stage_batch = from_stage_batch,
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

/// Build a `SUBSCRIBE_V2` payload (`FORMAT.socket.md` § BUILD_STAGES) into `buffer` and return the filled slice.
fn encodeSubscribeV2(buffer: []u8, from_batch: u64, stage: u16, flags: u16, include: []const []const u8, exclude: []const []const u8) []u8 {
    var pos: usize = 12;
    std.mem.writeInt(u64, buffer[0..8], from_batch, .little);
    std.mem.writeInt(u16, buffer[8..10], stage, .little);
    std.mem.writeInt(u16, buffer[10..12], flags, .little);
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

/// Build a `SUBSCRIBE_V3` payload into `buffer` and return the filled slice.
fn encodeSubscribeV3(buffer: []u8, from_batch: u64, from_stage_batch: u64, stage: u16, flags: u16, include: []const []const u8, exclude: []const []const u8) []u8 {
    var pos: usize = 20;
    std.mem.writeInt(u64, buffer[0..8], from_batch, .little);
    std.mem.writeInt(u64, buffer[8..16], from_stage_batch, .little);
    std.mem.writeInt(u16, buffer[16..18], stage, .little);
    std.mem.writeInt(u16, buffer[18..20], flags, .little);
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

test "SUBSCRIBE_V2 decodes stage and builder, and a plain SUBSCRIBE stays stage 0" {
    var buffer: [128]u8 = undefined;
    const payload = encodeSubscribeV2(&buffer, 9, 2, 0x01, &.{"*.class"}, &.{"generated/*"});
    var sub = try decodeSubscribeV2(std.testing.allocator, payload);
    defer sub.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 9), sub.from_batch);
    try std.testing.expectEqual(@as(u16, 2), sub.stage);
    try std.testing.expect(sub.builder);
    try std.testing.expect(sub.filter.matches("build/Main.class"));
    try std.testing.expect(!sub.filter.matches("generated/Main.class"));

    // No filter still carries both zero counts; a listener needs no builder flag.
    const empty = encodeSubscribeV2(&buffer, 4, 1, 0, &.{}, &.{});
    var listener = try decodeSubscribeV2(std.testing.allocator, empty);
    defer listener.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), listener.stage);
    try std.testing.expect(!listener.builder);
    try std.testing.expect(listener.filter.isPassAll());

    // The original form's defaults are the documented ones.
    var legacy_payload: [8]u8 = undefined;
    std.mem.writeInt(u64, &legacy_payload, 3, .little);
    var legacy = try decodeSubscribe(std.testing.allocator, &legacy_payload);
    defer legacy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 0), legacy.stage);
    try std.testing.expect(!legacy.builder);
}

test "SUBSCRIBE_V3 carries the stage replay cursor and keeps the other fields" {
    var buffer: [128]u8 = undefined;
    const payload = encodeSubscribeV3(&buffer, 9, 3, 2, 0x01, &.{"*.jar"}, &.{});
    var sub = try decodeSubscribeV3(std.testing.allocator, payload);
    defer sub.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 9), sub.from_batch);
    try std.testing.expectEqual(@as(u64, 3), sub.from_stage_batch.?);
    try std.testing.expectEqual(@as(u16, 2), sub.stage);
    try std.testing.expect(sub.builder);
    try std.testing.expect(sub.filter.matches("build/libs/app.jar"));

    // v2 has no cursor; the daemon reads `null` as "start at the stage head".
    var old_buffer: [128]u8 = undefined;
    const old = encodeSubscribeV2(&old_buffer, 4, 1, 0, &.{}, &.{});
    var old_sub = try decodeSubscribeV2(std.testing.allocator, old);
    defer old_sub.deinit(std.testing.allocator);
    try std.testing.expect(old_sub.from_stage_batch == null);
}

test "SUBSCRIBE_V2 refuses a reserved flag and a missing filter section" {
    var buffer: [64]u8 = undefined;
    // Bit 1 is reserved: a role this server does not understand must not become a listener silently.
    const reserved = encodeSubscribeV2(&buffer, 0, 0, 0x02, &.{}, &.{});
    try std.testing.expectError(error.ReservedFlags, decodeSubscribeV2(std.testing.allocator, reserved));

    // The 12-byte header without the two filter counts is malformed, not pass-all: the v2 layout is exact.
    var header_only: [12]u8 = undefined;
    @memset(&header_only, 0);
    try std.testing.expectError(error.Malformed, decodeSubscribeV2(std.testing.allocator, &header_only));

    // A truncated pattern section is still malformed.
    const full = encodeSubscribeV2(&buffer, 0, 0, 0, &.{"*.md"}, &.{});
    try std.testing.expectError(error.Malformed, decodeSubscribeV2(std.testing.allocator, full[0 .. full.len - 1]));

    // A stage beyond the documented chain is refused rather than turned into a 65 000-step pump.
    const too_deep = encodeSubscribeV2(&buffer, 0, wire.max_stage + 1, 0, &.{}, &.{});
    try std.testing.expectError(error.Malformed, decodeSubscribeV2(std.testing.allocator, too_deep));
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
