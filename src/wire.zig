// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! The socket wire format (FORMAT.socket.md): frame prefixes, the messages, and the checks a reader makes before it
//! trusts a payload.
//!
//! Two properties drive the design. **A frame is self-delimiting from its payload**, so `CHANGE_ENTRY` needs no second
//! length field: `length == entry_size + nameLength`, and a mismatch is refused rather than parsed. And **nothing is
//! guessed**: an unknown kind, any set bit in `flags` (the reserved `MULTIPART` included), or a capability the peer
//! marked required is an error that closes the connection — a skipped change is a silently wrong index.
//!
//! This module is pure bytes: no socket, no file system, which is what makes every rule testable without a peer.

const std = @import("std");
const format = @import("format.zig");

/// The prefix is 8 bytes: `u16 kind`, `u16 flags`, `u32 length`.
pub const prefix_size = 8;

/// The largest payload either side will accept (FORMAT.socket.md).
pub const max_frame: u32 = 1 << 20;

/// A fixed greeting: the size is known before any variable frame is parsed, so a wrong length assumption cannot
/// corrupt the stream.
pub const hello_size = 24;

/// Message kinds. Every value is below `0x7B`, so the first byte of a binary message can never be `{` and a JSON-RPC
/// request is identified by `0x7B 0x22` instead of by a guess.
pub const Kind = enum(u16) {
    hello = 0x01,
    start_batch = 0x02,
    change_entry = 0x03,
    end_batch = 0x04,
    err = 0x05,
    subscribe = 0x06,
    ping = 0x07,
    pong = 0x08,

    pub fn fromInt(value: u16) ?Kind {
        return switch (value) {
            0x01 => .hello,
            0x02 => .start_batch,
            0x03 => .change_entry,
            0x04 => .end_batch,
            0x05 => .err,
            0x06 => .subscribe,
            0x07 => .ping,
            0x08 => .pong,
            else => null,
        };
    }
};

/// `flags` bit 0: reserved for a frame carrying several `CHANGE_ENTRY` payloads (FORMAT.socket.md § Multipart).
/// Defined, unused, and rejected while set — "reserved" is not "supported".
pub const FLAG_MULTIPART: u16 = 0x01;

/// What a prefix says. The payload is read separately, so a caller can validate before it allocates.
pub const Frame = struct {
    kind: Kind,
    flags: u16,
    length: u32,
};

pub const ReadError = error{
    PrefixTruncated,
    UnknownKind,
    UnsupportedFlags,
    FrameTooLarge,
    LengthMismatch,
    InvalidEntry,
};

/// Write the 8-byte prefix for a payload of `length` bytes.
pub fn writePrefix(out: *[prefix_size]u8, kind: Kind, flags: u16, length: u32) void {
    std.mem.writeInt(u16, out[0..2], @intFromEnum(kind), .little);
    std.mem.writeInt(u16, out[2..4], flags, .little);
    std.mem.writeInt(u32, out[4..8], length, .little);
}

/// Read a prefix, refusing anything this implementation does not implement.
pub fn readPrefix(bytes: *const [prefix_size]u8) ReadError!Frame {
    const kind = Kind.fromInt(std.mem.readInt(u16, bytes[0..2], .little)) orelse return error.UnknownKind;
    const flags = std.mem.readInt(u16, bytes[2..4], .little);
    if (flags != 0) return error.UnsupportedFlags;
    const length = std.mem.readInt(u32, bytes[4..8], .little);
    if (length > max_frame) return error.FrameTooLarge;
    return .{ .kind = kind, .flags = flags, .length = length };
}

/// A `CHANGE_ENTRY` frame: the trio's entry followed by the name, with no LF and no NUL.
///
/// The name is stored whole, exactly as `files.txt` stores it, so a consumer's path is the one the trio has — and
/// `nameLength` in the entry makes the frame self-delimiting even if a prefix lied.
pub fn writeChangeEntry(out: []u8, entry: format.Entry, name: []const u8) void {
    std.debug.assert(out.len == prefix_size + format.entry_size + name.len);
    writePrefix(out[0..prefix_size], .change_entry, 0, @intCast(format.entry_size + name.len));
    var encoded: [format.entry_size]u8 = undefined;
    var with_name = entry;
    with_name.name_length = @intCast(name.len);
    with_name.encode(&encoded);
    @memcpy(out[prefix_size..][0..format.entry_size], &encoded);
    @memcpy(out[prefix_size + format.entry_size ..][0..name.len], name);
}

/// The payload of a `CHANGE_ENTRY`: the entry and its name, checked against each other.
pub const ChangeEntry = struct {
    entry: format.Entry,
    name: []const u8,
};

pub fn readChangeEntry(payload: []const u8) ReadError!ChangeEntry {
    if (payload.len < format.entry_size) return error.LengthMismatch;
    const entry = format.Entry.decode(payload[0..format.entry_size]);
    if (payload.len != format.entry_size + entry.name_length) return error.LengthMismatch;
    // The entry's own flags must describe a change (§ 17.2): exactly one change bit.
    if ((entry.flags_word & 0xE0) == 0 or @popCount(entry.flags_word & 0xE0) != 1) return error.InvalidEntry;
    return .{ .entry = entry, .name = payload[format.entry_size..] };
}

// ---------------------------------------------------------------- the handshake

pub const Role = enum(u8) { server = 0, client = 1 };

pub const Capabilities = struct {
    pub const snapshot: u8 = 0x01;
    pub const changes_hash: u8 = 0x02;
    /// Bits a peer may ignore. Anything outside this mask and outside `known` is refused when required.
    pub const known: u8 = snapshot | changes_hash;
};

/// `HELLO`: protocol version, layout, hash, role, capabilities, the newest batch known, and the frame limit.
pub const Hello = struct {
    protocol: u16,
    entry_size: u16,
    hash_algorithm: u8,
    role: Role,
    capabilities: u8,
    generation: u64,
    max_frame_bytes: u64,

    pub fn write(self: Hello, out: *[prefix_size + hello_size]u8) void {
        writePrefix(out[0..prefix_size], .hello, 0, hello_size);
        const body = out[prefix_size..];
        std.mem.writeInt(u16, body[0..2], self.protocol, .little);
        std.mem.writeInt(u16, body[2..4], self.entry_size, .little);
        body[4] = self.hash_algorithm;
        body[5] = @intFromEnum(self.role);
        body[6] = self.capabilities;
        body[7] = 0;
        std.mem.writeInt(u64, body[8..16], self.generation, .little);
        std.mem.writeInt(u64, body[16..24], self.max_frame_bytes, .little);
    }

    pub fn read(payload: []const u8) ReadError!Hello {
        if (payload.len != hello_size) return error.LengthMismatch;
        return .{
            .protocol = std.mem.readInt(u16, payload[0..2], .little),
            .entry_size = std.mem.readInt(u16, payload[2..4], .little),
            .hash_algorithm = payload[4],
            .role = switch (payload[5]) {
                0 => .server,
                1 => .client,
                else => return error.InvalidEntry,
            },
            .capabilities = payload[6],
            .generation = std.mem.readInt(u64, payload[8..16], .little),
            .max_frame_bytes = std.mem.readInt(u64, payload[16..24], .little),
        };
    }
};

/// Which side refuses a greeting, and with which verdict word. The names are the file format's, so a client reports
/// one vocabulary for a bad trio and a bad peer.
pub const HelloVerdict = enum {
    ok,
    unsupported_version,
    unsupported_entry_size,
    unsupported_hash,
    unsupported_capability,
};

pub fn checkHello(ours: Hello, theirs: Hello) HelloVerdict {
    if (theirs.entry_size != format.entry_size) return .unsupported_entry_size;
    if (theirs.hash_algorithm != 0) return .unsupported_hash;
    if ((theirs.protocol >> 8) != (ours.protocol >> 8)) return .unsupported_version;
    if ((theirs.capabilities & ~Capabilities.known) != 0) return .unsupported_capability;
    return .ok;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a prefix round-trips, and the kinds cannot look like JSON" {
    var bytes: [prefix_size]u8 = undefined;
    writePrefix(&bytes, .change_entry, 0, 100);
    const frame = try readPrefix(&bytes);
    try testing.expectEqual(Kind.change_entry, frame.kind);
    try testing.expectEqual(@as(u32, 100), frame.length);

    var kind: u16 = 0x01;
    while (kind <= 0x08) : (kind += 1) {
        var prefix: [prefix_size]u8 = undefined;
        writePrefix(&prefix, Kind.fromInt(kind).?, 0, 0);
        try testing.expect(prefix[0] < 0x7B);
        try testing.expectEqual(@as(u8, 0), prefix[1]);
    }
}

test "the reserved multipart bit is refused, not ignored" {
    var bytes: [prefix_size]u8 = undefined;
    writePrefix(&bytes, .change_entry, FLAG_MULTIPART, 64);
    try testing.expectError(error.UnsupportedFlags, readPrefix(&bytes));
}

test "an unknown kind and an oversized frame are refused" {
    var bytes: [prefix_size]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], 0x7A, .little);
    std.mem.writeInt(u16, bytes[2..4], 0, .little);
    std.mem.writeInt(u32, bytes[4..8], 0, .little);
    try testing.expectError(error.UnknownKind, readPrefix(&bytes));

    writePrefix(&bytes, .ping, 0, max_frame + 1);
    try testing.expectError(error.FrameTooLarge, readPrefix(&bytes));
}

test "a change entry is self-delimiting: its name length must match the payload" {
    var entry = std.mem.zeroes(format.Entry);
    entry.name_hash = format.wyhash("a.txt");
    entry.content_hash = 0xabc;
    entry.size_bytes = 5;
    entry.flags_word = format.flags.regular_file | format.flags.content_known | 0x20;

    var bytes: [prefix_size + format.entry_size + 5]u8 = undefined;
    writeChangeEntry(&bytes, entry, "a.txt");

    const frame = try readPrefix(bytes[0..prefix_size]);
    try testing.expectEqual(@as(u32, format.entry_size + 5), frame.length);
    const change = try readChangeEntry(bytes[prefix_size..][0..frame.length]);
    try testing.expectEqualStrings("a.txt", change.name);
    try testing.expectEqual(@as(u64, 0xabc), change.entry.content_hash);
    try testing.expectEqual(@as(u32, 5), change.entry.name_length);
}

test "a change entry with no change bit, or two, is refused" {
    var plain = std.mem.zeroes(format.Entry);
    plain.flags_word = format.flags.regular_file;
    plain.name_length = 1;
    var payload: [format.entry_size + 1]u8 = undefined;
    plain.encode(payload[0..format.entry_size]);
    payload[format.entry_size] = 'x';
    try testing.expectError(error.InvalidEntry, readChangeEntry(&payload));

    plain.flags_word = format.flags.regular_file | 0x60; // added and changed
    plain.encode(payload[0..format.entry_size]);
    try testing.expectError(error.InvalidEntry, readChangeEntry(&payload));
}

test "a greeting round-trips and is checked in the file format's vocabulary" {
    const ours = Hello{
        .protocol = 0x0100,
        .entry_size = format.entry_size,
        .hash_algorithm = 0,
        .role = .client,
        .capabilities = 0,
        .generation = 14,
        .max_frame_bytes = max_frame,
    };
    var bytes: [prefix_size + hello_size]u8 = undefined;
    ours.write(&bytes);
    const frame = try readPrefix(bytes[0..prefix_size]);
    try testing.expectEqual(Kind.hello, frame.kind);
    try testing.expectEqual(@as(u32, hello_size), frame.length);

    const theirs = try Hello.read(bytes[prefix_size..]);
    try testing.expectEqual(@as(u64, 14), theirs.generation);
    try testing.expectEqual(HelloVerdict.ok, checkHello(ours, theirs));

    var wrong_entry = ours;
    wrong_entry.entry_size = 48;
    try testing.expectEqual(HelloVerdict.unsupported_entry_size, checkHello(ours, wrong_entry));

    var wrong_hash = ours;
    wrong_hash.hash_algorithm = 1;
    try testing.expectEqual(HelloVerdict.unsupported_hash, checkHello(ours, wrong_hash));

    var wrong_major = ours;
    wrong_major.protocol = 0x0200;
    try testing.expectEqual(HelloVerdict.unsupported_version, checkHello(ours, wrong_major));

    var newer_minor = ours;
    newer_minor.protocol = 0x0101;
    try testing.expectEqual(HelloVerdict.ok, checkHello(ours, newer_minor));

    var unknown_capability = ours;
    unknown_capability.capabilities = 0x80;
    try testing.expectEqual(HelloVerdict.unsupported_capability, checkHello(ours, unknown_capability));
}