// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The wire format of `FORMAT.md` version 1 — the 64-byte entry, the flag bits, the name rules and the file
//! names — and the hash the format fixes: Zig's `std.hash.Wyhash` with seed 0.
//!
//! This is the reference implementation. The document is normative; where this file and `FORMAT.md` disagree,
//! this file is the bug. Nothing here allocates, nothing here touches a file system: an `Entry` is a value and
//! `encode`/`decode` are its only two directions.

const std = @import("std");

pub const name = "fs-meta";
pub const version: u32 = 1;
pub const entry_size: u32 = 64;
pub const order = "utf8-bytes";
pub const hash_algo = "wyhash64";
pub const hash_seed: u64 = 0;
pub const meta_file = "files.meta";
pub const txt_file = "files.txt";
pub const json_file = "files.json";
pub const directory_name = ".fs-meta";

/// § 6. Exactly one of the three type bits is set on a valid entry.
pub const flags = struct {
    pub const content_known: u32 = 0x01;
    pub const regular_file: u32 = 0x02;
    pub const is_dir: u32 = 0x04;
    pub const hash_lf: u32 = 0x08;
    pub const symlink: u32 = 0x10;

    pub const type_mask: u32 = regular_file | is_dir | symlink;
    pub const known_mask: u32 = content_known | type_mask | hash_lf;

    /// The verdict rule of § 6: unknown bits, or not exactly one type bit, make the trio invalid.
    pub fn valid(word: u32) bool {
        if ((word & ~known_mask) != 0) return false;
        return @popCount(word & type_mask) == 1;
    }
};

pub const Kind = enum {
    regular_file,
    dir,
    symlink,
};

pub const Entry = struct {
    /// ns since the unix epoch; 0 = unknown. § 5.
    mtime_ns: u64,
    size_bytes: u64,
    content_hash: u64,
    name_hash: u64,
    name_offset: u64,
    name_length: u32,
    flags_word: u32,
    file_id_lo: u64,
    file_id_hi: u64,

    pub fn decode(bytes: *const [entry_size]u8) Entry {
        return .{
            .mtime_ns = std.mem.readInt(u64, bytes[0..8], .little),
            .size_bytes = std.mem.readInt(u64, bytes[8..16], .little),
            .content_hash = std.mem.readInt(u64, bytes[16..24], .little),
            .name_hash = std.mem.readInt(u64, bytes[24..32], .little),
            .name_offset = std.mem.readInt(u64, bytes[32..40], .little),
            .name_length = std.mem.readInt(u32, bytes[40..44], .little),
            .flags_word = std.mem.readInt(u32, bytes[44..48], .little),
            .file_id_lo = std.mem.readInt(u64, bytes[48..56], .little),
            .file_id_hi = std.mem.readInt(u64, bytes[56..64], .little),
        };
    }

    pub fn encode(self: Entry, out: *[entry_size]u8) void {
        std.mem.writeInt(u64, out[0..8], self.mtime_ns, .little);
        std.mem.writeInt(u64, out[8..16], self.size_bytes, .little);
        std.mem.writeInt(u64, out[16..24], self.content_hash, .little);
        std.mem.writeInt(u64, out[24..32], self.name_hash, .little);
        std.mem.writeInt(u64, out[32..40], self.name_offset, .little);
        std.mem.writeInt(u32, out[40..44], self.name_length, .little);
        std.mem.writeInt(u32, out[44..48], self.flags_word, .little);
        std.mem.writeInt(u64, out[48..56], self.file_id_lo, .little);
        std.mem.writeInt(u64, out[56..64], self.file_id_hi, .little);
    }

    pub fn contentKnown(self: Entry) bool {
        return (self.flags_word & flags.content_known) != 0;
    }

    pub fn hashLf(self: Entry) bool {
        return (self.flags_word & flags.hash_lf) != 0;
    }

    /// § 6: an entry is trustworthy when every bit it sets is one this version defines.
    pub fn trusted(self: Entry) bool {
        return (self.flags_word & ~flags.known_mask) == 0;
    }

    pub fn kind(self: Entry) ?Kind {
        if ((self.flags_word & flags.is_dir) != 0) return .dir;
        if ((self.flags_word & flags.symlink) != 0) return .symlink;
        if ((self.flags_word & flags.regular_file) != 0) return .regular_file;
        return null;
    }

    /// The bytes of the entry at `index`: `index << 6` (§ 2).
    pub fn offsetOf(index: usize) u64 {
        return @as(u64, @intCast(index)) << 6;
    }

    /// § 2: the count is a shift, not a division, because the entry is 64 bytes.
    pub fn countOf(meta_bytes: u64) u64 {
        return meta_bytes >> 6;
    }
};

/// The hash the format fixes: Zig's `std.hash.Wyhash`, seed 0 — the reference itself, not a port of it.
pub fn wyhash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(hash_seed, bytes);
}

/// A hash as the sixteen lowercase hex characters `files.json` carries (§ 7).
pub fn hex(value: u64, out: *[16]u8) []const u8 {
    return std.fmt.bufPrint(out, "{x:0>16}", .{value}) catch unreachable;
}

/// § 3. A name is a path relative to the root: UTF-8, `/`-separated, and none of the shapes that would make the
/// pair ambiguous.
pub fn nameValid(candidate: []const u8) bool {
    if (candidate.len == 0) return false;
    if (candidate[0] == '/') return false;
    if (candidate[candidate.len - 1] == '/') return false;
    for (candidate) |byte| {
        if (byte == 0x00 or byte == 0x0a or byte == 0x0d or byte == '\\') return false;
    }
    var segments = std.mem.splitScalar(u8, candidate, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return std.unicode.utf8ValidateSlice(candidate);
}

/// § 3: the order is an unsigned byte comparison of the UTF-8 encodings (`memcmp`), not a string order.
pub fn compareNames(left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

test "an entry survives encode/decode byte for byte" {
    const original = Entry{
        .mtime_ns = 1_700_000_000_123_000_000,
        .size_bytes = 6,
        .content_hash = 0xe6d129338e065990,
        .name_hash = 0x6a917dd1ac09c082,
        .name_offset = 0,
        .name_length = 5,
        .flags_word = flags.regular_file | flags.content_known,
        .file_id_lo = 12_345,
        .file_id_hi = 16_777_216,
    };
    var bytes: [entry_size]u8 = undefined;
    original.encode(&bytes);
    const decoded = Entry.decode(&bytes);
    try std.testing.expectEqualDeep(original, decoded);
    try std.testing.expectEqual(Kind.regular_file, decoded.kind().?);
    try std.testing.expect(decoded.contentKnown());
    try std.testing.expect(!decoded.hashLf());
}

test "the field offsets are the ones FORMAT.md § 5 lists" {
    var bytes = std.mem.zeroes([entry_size]u8);
    const entry = Entry{
        .mtime_ns = 0xAABBCCDDEEFF0011,
        .size_bytes = 0x1122334455667788,
        .content_hash = 0x99AABBCCDDEEFF00,
        .name_hash = 0x0102030405060708,
        .name_offset = 0x0A0B0C0D0E0F1011,
        .name_length = 0xDEADBEEF,
        .flags_word = 0x0000001B, // content_known | regular_file | hash_lf | symlink is invalid, but this tests bytes
        .file_id_lo = 0x1112131415161718,
        .file_id_hi = 0x2122232425262728,
    };
    entry.encode(&bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x00, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA }, bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, bytes[8..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE }, bytes[40..44]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11 }, bytes[48..56]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21 }, bytes[56..64]);
}

test "the flag rules of § 6" {
    try std.testing.expect(flags.valid(flags.regular_file));
    try std.testing.expect(flags.valid(flags.regular_file | flags.content_known));
    try std.testing.expect(flags.valid(flags.is_dir));
    try std.testing.expect(flags.valid(flags.symlink));
    try std.testing.expect(!flags.valid(0));
    try std.testing.expect(!flags.valid(flags.is_dir | flags.symlink));
    try std.testing.expect(!flags.valid(flags.regular_file | flags.hash_lf | flags.is_dir));
    try std.testing.expect(!flags.valid(flags.regular_file | 0x20));
}

test "the name rules of § 3" {
    try std.testing.expect(nameValid("a.txt"));
    try std.testing.expect(nameValid("src/b.java"));
    try std.testing.expect(nameValid("h\u{e9}llo.txt"));
    try std.testing.expect(!nameValid(""));
    try std.testing.expect(!nameValid("/abs"));
    try std.testing.expect(!nameValid("dir/"));
    try std.testing.expect(!nameValid("a//b"));
    try std.testing.expect(!nameValid("./a"));
    try std.testing.expect(!nameValid("a/../b"));
    try std.testing.expect(!nameValid("line\nbreak"));
    try std.testing.expect(!nameValid("cr\rname"));
    try std.testing.expect(!nameValid("back\\slash"));
}

test "the hash is the reference's, and hex is sixteen characters" {
    // The three vectors of Zig's own `std.hash.Wyhash` test block.
    try std.testing.expectEqual(@as(u64, 0x0409638ee2bde459), wyhash(""));
    try std.testing.expectEqual(@as(u64, 0xa8412d091b5fe0a9), std.hash.Wyhash.hash(1, "a"));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0409638ee2bde459", hex(0x0409638ee2bde459, &buffer));
}

test "the count and the offset are shifts" {
    try std.testing.expectEqual(@as(u64, 0), Entry.countOf(0));
    try std.testing.expectEqual(@as(u64, 2), Entry.countOf(128));
    try std.testing.expectEqual(@as(u64, 0), Entry.offsetOf(0));
    try std.testing.expectEqual(@as(u64, 128), Entry.offsetOf(2));
}
