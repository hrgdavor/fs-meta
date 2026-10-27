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
//!
//! `STATE` (kind `0x09`) is the daemon's one addition, and it is why the protocol moves to `0x0101`: a consumer
//! that subscribes to a sleeping root could not otherwise tell "this root is waking, and here is how far behind
//! you will be" from "the server is slow" or "the tree is big". It carries state, reason, the idle timeout and
//! the newest published batch — and nothing the server would have to measure under a deadline.

const std = @import("std");
const format = @import("format.zig");

/// The protocol version this implementation speaks, as `HELLO.protocol` (`major << 8 | minor`).
///
/// `0x0101` adds the `STATE` frame (§ STATE), `0x0102` adds `GIT_EVENT` (§ GIT_EVENT). There are no deployed clients,
/// so the minor bump is the whole compatibility story: every implementation is updated together, and no capability
/// bit gate is carried for a population of zero. A `0x0100` peer is still accepted — `checkHello` compares majors —
/// but it will not understand `0x09` or `0x0A`, which is why the daemon speaks `0x0102` and the document says so.
/// `fsmeta serve` announces the same version and simply never emits either frame.
pub const protocol: u16 = 0x0102;

/// The prefix is 8 bytes: `u16 kind`, `u16 flags`, `u32 length`.
pub const prefix_size = 8;

/// The largest payload either side will accept (FORMAT.socket.md).
pub const max_frame: u32 = 1 << 20;

/// The payload of `STATE`: `u8 state`, `u8 reason`, `u32 idle_timeout_ms`, `u64 head_batch`.
pub const state_size = 14;

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
    /// What the root is doing (protocol `0x0101`). Server to client, always between batches.
    state = 0x09,
    /// A git operation's start or finish (protocol `0x0102`). Server to client, never inside a batch.
    git_event = 0x0A,

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
            0x09 => .state,
            0x0A => .git_event,
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
    InvalidState,
    InvalidGitEvent,
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

// ---------------------------------------------------------------- the state frame

/// `STATE` (kind `0x09`, protocol `0x0101`): the root's phase, why it is in it, how long it may stay there,
/// and the newest batch it considers published.
///
/// The four fields answer exactly the questions a consumer has when a `SUBSCRIBE` does not return at once:
/// *is it waking* (`state`, `reason`), *will it stop sending without warning* (`idle_timeout_ms`, `0` never),
/// and *how far behind will I be* (`head_batch`, compared with the consumer's own last applied batch). No
/// progress counters: on the measured workloads a scan of thousands of files is milliseconds, so progress
/// would flicker and be gone — and a state notification must not become a telemetry channel that has to be
/// kept honest under a deadline.
pub const State = struct {
    /// `0` = off, `1` = asleep, `2` = waking, `3` = watching.
    state: u8,
    /// `0` = none, `1` = a client subscribed, `2` = idle timeout, `3` = control request, `4` = watcher event.
    reason: u8,
    /// The root's current setting; `0` means it never sleeps.
    idle_timeout_ms: u32,
    /// The newest batch the server considers published.
    head_batch: u64,

    pub fn write(self: State, out: *[prefix_size + state_size]u8) void {
        writePrefix(out[0..prefix_size], .state, 0, state_size);
        // Packed, no padding: `u8 state` at 0, `u8 reason` at 1, `u32 idle_timeout_ms` at 2, `u64 head_batch`
        // at 6 — fourteen bytes in all.
        const body = out[prefix_size..];
        body[0] = self.state;
        body[1] = self.reason;
        std.mem.writeInt(u32, body[2..6], self.idle_timeout_ms, .little);
        std.mem.writeInt(u64, body[6..14], self.head_batch, .little);
    }

    /// Read a `STATE` payload, refusing a state or reason outside the documented tables: a value the peer
    /// cannot name is a value this reader must not guess at.
    pub fn read(payload: []const u8) ReadError!State {
        if (payload.len != state_size) return error.LengthMismatch;
        if (payload[0] > 3 or payload[1] > 4) return error.InvalidState;
        return .{
            .state = payload[0],
            .reason = payload[1],
            .idle_timeout_ms = std.mem.readInt(u32, payload[2..6], .little),
            .head_batch = std.mem.readInt(u64, payload[6..14], .little),
        };
    }
};

// ---------------------------------------------------------------- the git event frame

/// The fixed payload of `GIT_EVENT` (kind `0x0A`, protocol `0x0102`): four one-byte fields, the batch the event
/// belongs to, and when it was seen. `kind = worktree` appends a `u32 path_len` and the path, so its payload is
/// `24 + path_len`; every other kind is exactly these twenty bytes.
pub const git_event_size = 20;

/// The frame a git operation produces. `start` is sent when the operation is seen to begin (a metadata guess, or a
/// hook's `prepared`), `finish` only **after** the pass that reflects it has been published to that client (§ 5d), and
/// `aborted` when git abandoned it — there is no result to show, so no pass is waited for.
pub const GitPhase = enum(u8) {
    start = 0,
    finish = 1,
    aborted = 2,
};

pub const GitKind = enum(u8) {
    branch = 0,
    checkout = 1,
    commit = 2,
    merge = 3,
    rebase = 4,
    index = 5,
    /// The only variable-length kind: it carries the worktree's path, and `path_len = 0` means the path is unknown
    /// (a removal, where the metadata that named it is already gone).
    worktree = 6,
    other = 7,
};

/// Where the signal came from. `metadata` is the file timeline, which always works and is a heuristic; `hook` is the
/// precise start/finish pair, which needs M5's install.
pub const GitSource = enum(u8) {
    metadata = 0,
    hook = 1,
};

/// Whether the pass an event waited for succeeded. A consumer that reads `failed` must treat its view as stale.
pub const GitStatus = enum(u8) {
    ok = 0,
    failed = 1,
    timed_out = 2,
};

pub const GitEvent = struct {
    phase: GitPhase,
    kind: GitKind,
    source: GitSource = .metadata,
    status: GitStatus = .ok,
    /// The receiving root's head batch. For `start` it is 0 when nothing has been published yet; for a **repo-wide**
    /// event it is that root's current head, not a generation the event produced — so it is not a batch to fetch.
    head_batch: u64,
    /// Epoch milliseconds, the same clock the daemon uses for `last_pass_ms`.
    at_ms: u64 = 0,
    /// Only meaningful for `kind = worktree`; `""` is legal and is what a removal sends.
    path: []const u8 = "",

    /// The payload length: `20`, or `24 + path.len` for a worktree event.
    pub fn payloadSize(self: GitEvent) u32 {
        if (self.kind != .worktree) return git_event_size;
        return @intCast(git_event_size + 4 + self.path.len);
    }

    /// Write the payload into `out`, which must be exactly `payloadSize()` bytes.
    pub fn write(self: GitEvent, out: []u8) void {
        const size = self.payloadSize();
        std.debug.assert(out.len == size);
        out[0] = @intFromEnum(self.phase);
        out[1] = @intFromEnum(self.kind);
        out[2] = @intFromEnum(self.source);
        out[3] = @intFromEnum(self.status);
        std.mem.writeInt(u64, out[4..12], self.head_batch, .little);
        std.mem.writeInt(u64, out[12..20], self.at_ms, .little);
        if (self.kind != .worktree) return;
        std.mem.writeInt(u32, out[20..24], @intCast(self.path.len), .little);
        @memcpy(out[24..][0..self.path.len], self.path);
    }

    /// Read a payload, checking every table and the length rule before trusting the path: `worktree` is the only
    /// kind whose length is not fixed, and `path_len` may never exceed what the frame actually carries.
    pub fn read(payload: []const u8) ReadError!GitEvent {
        if (payload.len < git_event_size) return error.LengthMismatch;
        if (payload[0] > 2 or payload[1] > 7 or payload[2] > 1 or payload[3] > 2) return error.InvalidGitEvent;
        const event = GitEvent{
            .phase = @enumFromInt(payload[0]),
            .kind = @enumFromInt(payload[1]),
            .source = @enumFromInt(payload[2]),
            .status = @enumFromInt(payload[3]),
            .head_batch = std.mem.readInt(u64, payload[4..12], .little),
            .at_ms = std.mem.readInt(u64, payload[12..20], .little),
        };
        if (event.kind != .worktree) {
            if (payload.len != git_event_size) return error.LengthMismatch;
            return event;
        }
        // A worktree event without its length field is truncated, not "no path".
        if (payload.len < git_event_size + 4) return error.LengthMismatch;
        const path_len = std.mem.readInt(u32, payload[20..24], .little);
        if (path_len > payload.len - (git_event_size + 4)) return error.LengthMismatch;
        if (payload.len != git_event_size + 4 + path_len) return error.LengthMismatch;
        var with_path = event;
        with_path.path = payload[24..][0..path_len];
        return with_path;
    }
};

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
    while (kind <= 0x0A) : (kind += 1) {
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
        .protocol = protocol,
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

test "the state frame is fourteen bytes and round-trips its four fields" {
    var bytes: [prefix_size + state_size]u8 = undefined;
    const frame = State{ .state = 2, .reason = 1, .idle_timeout_ms = 300_000, .head_batch = 42 };
    frame.write(&bytes);

    try testing.expectEqual(@as(u8, 0x09), bytes[0]);
    try testing.expectEqual(@as(u32, state_size), std.mem.readInt(u32, bytes[4..8], .little));

    const prefix = try readPrefix(bytes[0..prefix_size]);
    try testing.expectEqual(Kind.state, prefix.kind);
    try testing.expectEqual(@as(u32, 14), prefix.length);

    const read_back = try State.read(bytes[prefix_size..]);
    try testing.expectEqual(@as(u8, 2), read_back.state);
    try testing.expectEqual(@as(u8, 1), read_back.reason);
    try testing.expectEqual(@as(u32, 300_000), read_back.idle_timeout_ms);
    try testing.expectEqual(@as(u64, 42), read_back.head_batch);
}

test "a state or reason outside the documented tables is refused, not guessed" {
    var payload: [state_size]u8 = undefined;
    @memset(&payload, 0);
    payload[0] = 4; // there is no fifth state
    try testing.expectError(error.InvalidState, State.read(&payload));

    payload[0] = 3;
    payload[1] = 5; // there is no sixth reason
    try testing.expectError(error.InvalidState, State.read(&payload));

    payload[1] = 4; // the whole table, and nothing beyond it
    _ = try State.read(&payload);

    // A short payload is a length mismatch, not a partially-read state.
    try testing.expectError(error.LengthMismatch, State.read(payload[0 .. state_size - 1]));
}

test "a git event is exactly twenty bytes, and a worktree event is the only variable one" {
    var payload: [git_event_size]u8 = undefined;
    const finish = GitEvent{
        .phase = .finish,
        .kind = .branch,
        .source = .metadata,
        .status = .ok,
        .head_batch = 42,
        .at_ms = 1_700_000_000_000,
    };
    try testing.expectEqual(@as(u32, 20), finish.payloadSize());
    finish.write(&payload);
    try testing.expectEqual(@as(u8, 1), payload[0]);
    try testing.expectEqual(@as(u8, 0), payload[1]);
    const read_back = try GitEvent.read(&payload);
    try testing.expectEqual(GitPhase.finish, read_back.phase);
    try testing.expectEqual(GitKind.branch, read_back.kind);
    try testing.expectEqual(@as(u64, 42), read_back.head_batch);
    try testing.expectEqual(@as(u64, 1_700_000_000_000), read_back.at_ms);
    try testing.expectEqualStrings("", read_back.path);

    // Every other fixed kind is 20 bytes too, and a stray byte is a length mismatch.
    var started = finish;
    started.phase = .start;
    started.status = .failed;
    started.write(&payload);
    try testing.expectEqual(GitStatus.failed, (try GitEvent.read(&payload)).status);
    var too_long: [git_event_size + 1]u8 = undefined;
    var copy = finish;
    copy.kind = .checkout;
    copy.write(too_long[0..git_event_size]);
    too_long[git_event_size] = 0;
    try testing.expectError(error.LengthMismatch, GitEvent.read(&too_long));

    // A worktree event carries its path, and `path_len = 0` is legal ("the path is no longer knowable").
    var buffer: [git_event_size + 4 + 9]u8 = undefined;
    var worktree = finish;
    worktree.kind = .worktree;
    worktree.path = "/w/tree";
    const with_path_size: usize = 24 + "/w/tree".len;
    try testing.expectEqual(@as(u32, with_path_size), worktree.payloadSize());
    worktree.write(buffer[0..with_path_size]);
    const with_path = try GitEvent.read(buffer[0..with_path_size]);
    try testing.expectEqualStrings("/w/tree", with_path.path);

    worktree.path = "";
    worktree.write(buffer[0..24]);
    try testing.expectEqual(@as(u32, 24), worktree.payloadSize());
    try testing.expectEqualStrings("", (try GitEvent.read(buffer[0..24])).path);

    // A worktree event that is only the fixed part, or whose path_len runs past the frame, is refused.
    try testing.expectError(error.LengthMismatch, GitEvent.read(buffer[0..git_event_size]));
    var lying: [git_event_size + 4 + 2]u8 = undefined;
    worktree.path = "ab";
    worktree.write(&lying);
    std.mem.writeInt(u32, lying[20..24], 99, .little);
    try testing.expectError(error.LengthMismatch, GitEvent.read(&lying));
    std.mem.writeInt(u32, lying[20..24], 1, .little); // a short path_len is also a mismatch, not a truncation
    try testing.expectError(error.LengthMismatch, GitEvent.read(&lying));

    // A value outside a documented table is refused, not guessed at.
    finish.write(&payload);
    payload[1] = 8; // there is no ninth kind
    try testing.expectError(error.InvalidGitEvent, GitEvent.read(&payload));
    payload[1] = 2;
    payload[3] = 3; // there is no fourth status
    try testing.expectError(error.InvalidGitEvent, GitEvent.read(&payload));
}