// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! The socket server: a Unix-socket listener that speaks the binary protocol of `FORMAT.socket.md`.
//!
//! The wire format is **not** JSON-RPC. Every message is an 8-byte prefix (`u16 kind`, `u16 flags`,
//! `u32 length`, little-endian) followed by its payload, and every `kind` is below `0x7B` so a binary
//! message can never begin with `{"`. `wire.zig` owns the bytes; this module owns the transport:
//! greet the client, read its greeting, check it, take its `SUBSCRIBE`, and replay the batch archive
//! as `START_BATCH` / `CHANGE_ENTRY` / `END_BATCH`.
//!
//! Two deliberate limits:
//!
//! - **No live stream.** A pass publishes generations through the watcher, which is a different
//!   artifact; a `serve` process has no publisher to subscribe to, so the connection ends after the
//!   replay. The client resumes by reconnecting with its new `from_batch`, which is the replay path.
//! - **`HELLO.capabilities` is 0 and `END_BATCH.changes_hash` is 0.** `FORMAT.socket.md` still does not
//!   say what `changes_hash` hashes, and its § Values this implementation pins says a client must not rely
//!   on it; this server therefore does not advertise the capability and leaves the field zero. The counts
//!   in `END_BATCH` are exact and are what the document actually defines.
//!
//! Single-threaded: `run` accepts one connection at a time, serves it, closes it, and accepts the
//! next. With no publisher there is nothing to multiplex.

const std = @import("std");
const format = @import("format.zig");
const cache_mod = @import("cache.zig");
const batch = @import("batch.zig");
const wire = @import("wire.zig");

/// The protocol major/minor this server speaks, as `HELLO.protocol` (`major << 8 | minor`).
/// 1.0 is the layout the document describes; `FORMAT.socket.md` § Values this implementation pins states the
/// value, and `wire.zig`'s tests use it too.
pub const protocol: u16 = 0x0100;

/// The socket's name inside `<root>/.fs-meta`.
pub const socket_name = "socket";

/// The path the server listens on, relative to a root: `.fs-meta/socket`.
pub const socket_path = format.directory_name ++ "/" ++ socket_name;

/// Failure codes carried by `ERROR` (kind `0x05`). `FORMAT.socket.md` § Values this implementation pins
/// gives the numeric table; the UTF-8 message carries the same vocabulary (`protocol`, `batch-too-old`,
/// `batch-gap`).
pub const ErrorCode = enum(u16) {
    protocol = 1,
    batch_too_old = 2,
    batch_gap = 3,

    pub fn word(self: ErrorCode) []const u8 {
        return switch (self) {
            .protocol => "protocol",
            .batch_too_old => "batch-too-old",
            .batch_gap => "batch-gap",
        };
    }
};

/// The retained batch window. `first` is `null` when the archive is empty; `last` is the newest batch
/// number, and it is also the generation a `HELLO` advertises.
pub const BatchWindow = struct {
    dir: ?std.Io.Dir = null,
    first: ?u64 = null,
    last: u64 = 0,
};

/// Serve until the process is killed: bind `<root>/.fs-meta/socket` and replay batches to subscribers.
///
/// `cache` is the loaded trio. The binary protocol replays the batch archive, so the cache is not
/// read here; loading it is the readiness check `fsmeta serve` performs before binding, because a
/// server with no usable trio could only answer with errors. Its count is reported at startup.
pub fn run(io: std.Io, allocator: std.mem.Allocator, root: []const u8, cache: *const cache_mod.Cache) !void {
    const path = try absoluteSocketPath(io, allocator, root);
    defer allocator.free(path);

    const window = try openBatchWindow(io, root);
    defer if (window.dir) |dir| dir.close(io);

    // A socket left behind by a killed process is not a peer; remove it before binding. On Windows the
    // AF_UNIX bind does create a filesystem entry too, so the same rule applies on both platforms.
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const banner = try std.fmt.allocPrint(
        allocator,
        "fsmeta: listening on {s} ({d} names, generation {d})\n",
        .{ path, cache.fileCount() + cache.dirCount(), window.last },
    );
    try std.Io.File.stdout().writeStreamingAll(io, banner);

    while (true) {
        const stream = try server.accept(io);
        serveConnection(io, allocator, stream, window) catch {};
        stream.close(io);
    }
}

/// Serve one connection: greet, check the client's greeting, take its `SUBSCRIBE`, replay, close.
///
/// The error path sends one `ERROR` and returns; a read error is the peer leaving and is propagated so
/// `run` can ignore it and accept the next connection.
pub fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, window: BatchWindow) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read_buffer: [8192]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);

    // Simultaneous greeting: both sides send HELLO without waiting for the other (FORMAT.socket.md).
    const ours = wire.Hello{
        .protocol = protocol,
        .entry_size = @intCast(format.entry_size),
        .hash_algorithm = 0,
        .role = .server,
        .capabilities = 0,
        .generation = window.last,
        .max_frame_bytes = wire.max_frame,
    };
    var hello_bytes: [wire.prefix_size + wire.hello_size]u8 = undefined;
    ours.write(&hello_bytes);
    try writeBytes(io, stream, &hello_bytes);

    const hello_frame = (try readFramePrefix(io, stream, &reader.interface)) orelse return;
    if (hello_frame.kind != .hello or hello_frame.length != wire.hello_size) {
        return refuse(io, stream, .protocol, "expected a 24-byte HELLO greeting", .{});
    }
    const hello_payload = try reader.interface.take(hello_frame.length);
    const theirs = wire.Hello.read(hello_payload) catch {
        return refuse(io, stream, .protocol, "malformed HELLO payload", .{});
    };
    const verdict = wire.checkHello(ours, theirs);
    if (verdict != .ok) {
        return refuse(io, stream, .protocol, "{s}", .{helloVerdictWord(verdict)});
    }

    const subscribe_frame = (try readFramePrefix(io, stream, &reader.interface)) orelse return;
    if (subscribe_frame.kind != .subscribe or subscribe_frame.length != 8) {
        return refuse(io, stream, .protocol, "expected SUBSCRIBE with a u64 from_batch", .{});
    }
    const subscribe_payload = try reader.interface.take(subscribe_frame.length);
    const from_batch = std.mem.readInt(u64, subscribe_payload[0..8], .little);

    if (from_batch > window.last) {
        // FORMAT.socket.md does not say what a client ahead of the server means; refusing it is the
        // only answer that cannot silently skip a change set.
        return refuse(io, stream, .protocol, "from_batch {d} is newer than the newest batch {d}", .{ from_batch, window.last });
    }
    if (window.first) |first| {
        if (from_batch + 1 < first) {
            return refuse(io, stream, .batch_too_old, "batches start at {d}, so from_batch {d} cannot be replayed", .{ first, from_batch });
        }
    }

    try replay(io, arena, stream, window, from_batch);
}

/// Send `START_BATCH` … `END_BATCH` for every generation after `from_batch`.
fn replay(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, window: BatchWindow, from_batch: u64) !void {
    const dir = window.dir orelse return;
    var generation = from_batch + 1;
    while (generation <= window.last) : (generation += 1) {
        const plan = loadBatch(allocator, io, dir, generation) catch |err| switch (err) {
            error.BatchGap => {
                return refuse(io, stream, .batch_gap, "no batch {d}; the archive ends at {d}", .{ generation, window.last });
            },
            else => return err,
        };

        try sendStartBatch(io, stream, generation, generation - 1);
        for (plan.entries, plan.names) |entry, name| {
            try sendChangeEntry(io, allocator, stream, entry, name);
        }
        try sendEndBatch(io, stream, generation, counts(plan));
    }
}

/// The change counts `END_BATCH` must agree with (FORMAT.socket.md: "the counts must equal the entries
/// counted by change bit, or the batch is discarded").
const Counts = struct { added: u64 = 0, changed: u64 = 0, deleted: u64 = 0 };

fn counts(plan: batch.Plan) Counts {
    var result = Counts{};
    for (plan.entries) |entry| switch (batch.kindOf(entry) orelse continue) {
        .added => result.added += 1,
        .changed => result.changed += 1,
        .deleted => result.deleted += 1,
    };
    return result;
}

// ---------------------------------------------------------------- frames out

fn sendStartBatch(io: std.Io, stream: std.Io.net.Stream, number: u64, parent: u64) !void {
    var payload: [24]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], number, .little);
    std.mem.writeInt(u64, payload[8..16], parent, .little);
    // `started_ns` is diagnostic only and the batch's own timestamp is an ISO string in files.json;
    // no clock is read here, so the field is 0 rather than a fabricated pass time.
    std.mem.writeInt(u64, payload[16..24], 0, .little);
    try writeFrame(io, stream, .start_batch, &payload);
}

fn sendEndBatch(io: std.Io, stream: std.Io.net.Stream, number: u64, counted: Counts) !void {
    var payload: [40]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], number, .little);
    std.mem.writeInt(u64, payload[8..16], counted.added, .little);
    std.mem.writeInt(u64, payload[16..24], counted.changed, .little);
    std.mem.writeInt(u64, payload[24..32], counted.deleted, .little);
    // Unspecified (see the module comment): 0, with the `changes_hash` capability not advertised.
    std.mem.writeInt(u64, payload[32..40], 0, .little);
    try writeFrame(io, stream, .end_batch, &payload);
}

fn sendChangeEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    entry: format.Entry,
    name: []const u8,
) !void {
    const frame = try allocator.alloc(u8, wire.prefix_size + format.entry_size + name.len);
    wire.writeChangeEntry(frame, entry, name);
    try writeBytes(io, stream, frame);
}

fn writeFrame(io: std.Io, stream: std.Io.net.Stream, kind: wire.Kind, payload: []const u8) !void {
    var prefix: [wire.prefix_size]u8 = undefined;
    wire.writePrefix(&prefix, kind, 0, @intCast(payload.len));
    var writer_buffer: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &writer_buffer);
    try writer.interface.writeAll(&prefix);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn writeBytes(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var writer_buffer: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &writer_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn refuse(io: std.Io, stream: std.Io.net.Stream, code: ErrorCode, comptime wording: []const u8, args: anytype) void {
    var code_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &code_bytes, @intFromEnum(code), .little);

    var message_buffer: [512]u8 = undefined;
    var message = std.Io.Writer.fixed(&message_buffer);
    message.writeAll(code.word()) catch {};
    message.writeAll(": ") catch {};
    message.print(wording, args) catch {};
    const text = message.buffered();

    var payload: [2 + 512]u8 = undefined;
    @memcpy(payload[0..2], &code_bytes);
    @memcpy(payload[2..][0..text.len], text);

    var prefix: [wire.prefix_size]u8 = undefined;
    wire.writePrefix(&prefix, .err, 0, @intCast(2 + text.len));
    var writer_buffer: [1024]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &writer_buffer);
    writer.interface.writeAll(&prefix) catch return;
    writer.interface.writeAll(payload[0 .. 2 + text.len]) catch return;
    writer.interface.flush() catch return;
}

// ---------------------------------------------------------------- frames in

/// Read a frame prefix, or `null` when the peer closed cleanly before starting one.
///
/// A prefix this reader refuses is answered with `ERROR` and closed. The reserved `MULTIPART` bit is the
/// case that matters: FORMAT.socket.md says a receiver must answer `unsupported-flags` rather than ignore
/// a bit it does not implement, because a skipped change set is a silently wrong index.
fn readFramePrefix(io: std.Io, stream: std.Io.net.Stream, reader: *std.Io.Reader) !?wire.Frame {
    const prefix = reader.takeArray(wire.prefix_size) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    return wire.readPrefix(prefix) catch |err| {
        refuse(io, stream, .protocol, "{s}", .{frameErrorWord(err)});
        return null;
    };
}

fn frameErrorWord(err: wire.ReadError) []const u8 {
    return switch (err) {
        error.PrefixTruncated => "prefix-truncated",
        error.UnknownKind => "unknown-kind",
        error.UnsupportedFlags => "unsupported-flags",
        error.FrameTooLarge => "frame-too-large",
        error.LengthMismatch => "length-mismatch",
        error.InvalidEntry => "invalid-entry",
    };
}

// ---------------------------------------------------------------- batches

/// Open `<root>/.fs-meta/batches` and find the retained window. A missing directory or an empty
/// archive is not an error: a trio can exist before its first change batch.
pub fn openBatchWindow(io: std.Io, root: []const u8) !BatchWindow {
    var root_dir = openRootDir(io, root) catch return .{};
    defer root_dir.close(io);
    var meta_dir = root_dir.openDir(io, format.directory_name, .{ .iterate = true }) catch return .{};
    defer meta_dir.close(io);
    var batches = meta_dir.openDir(io, "batches", .{ .iterate = true }) catch return .{};

    var first: ?u64 = null;
    var last: u64 = 0;
    var count: usize = 0;
    var iterator = batches.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const number = std.fmt.parseInt(u64, entry.name, 16) catch continue;
        if (count == 0 or number < first.?) first = number;
        if (count == 0 or number > last) last = number;
        count += 1;
    }

    if (count == 0) {
        batches.close(io);
        return .{};
    }
    return .{ .dir = batches, .first = first, .last = last };
}

/// Read and decode `batches/<generation>`; a missing directory is `BatchGap`, which the replay turns
/// into the document's `ERROR {batch-gap}` rather than skipping the generation.
fn loadBatch(allocator: std.mem.Allocator, io: std.Io, batches: std.Io.Dir, generation: u64) !batch.Plan {
    const name = try std.fmt.allocPrint(allocator, "{x:0>8}", .{generation});
    var dir = batches.openDir(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.BatchGap,
        else => return err,
    };
    defer dir.close(io);

    const meta = try dir.readFileAlloc(io, format.meta_file, allocator, std.Io.Limit.limited(wire.max_frame));
    const txt = try dir.readFileAlloc(io, format.txt_file, allocator, std.Io.Limit.limited(wire.max_frame));
    return batch.decode(allocator, meta, txt);
}

fn openRootDir(io: std.Io, root: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(root))
        std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
}

/// `<root>/.fs-meta/socket`, made absolute because a Unix address must be: Zig's Windows AF_UNIX
/// bind rejects a relative path, and a relative socket would otherwise be resolved against the
/// process's directory rather than the root the user named.
fn absoluteSocketPath(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const absolute_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    return std.fs.path.resolveAlloc(allocator, &.{ absolute_root, format.directory_name, socket_name });
}

fn helloVerdictWord(verdict: wire.HelloVerdict) []const u8 {
    return switch (verdict) {
        .ok => "ok",
        .unsupported_version => "unsupported-version",
        .unsupported_entry_size => "unsupported-entry-size",
        .unsupported_hash => "unsupported-hash",
        .unsupported_capability => "unsupported-capability",
    };
}

test "the greeting is the document's fixed 24-byte payload, not the kind table's short one" {
    const ours = wire.Hello{
        .protocol = protocol,
        .entry_size = @intCast(format.entry_size),
        .hash_algorithm = 0,
        .role = .server,
        .capabilities = 0,
        .generation = 3,
        .max_frame_bytes = wire.max_frame,
    };
    var bytes: [wire.prefix_size + wire.hello_size]u8 = undefined;
    ours.write(&bytes);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x01), bytes[0]);
    try std.testing.expectEqual(@as(u32, wire.hello_size), std.mem.readInt(u32, bytes[4..8], .little));
    try std.testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, bytes[8..10], .little));
    try std.testing.expectEqual(@as(u16, 64), std.mem.readInt(u16, bytes[10..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bytes[14]); // role = server
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, bytes[16..24], .little));
}

test "the world is not JSON: a binary frame's first byte is never 0x7B" {
    var prefix: [wire.prefix_size]u8 = undefined;
    inline for (std.meta.tags(wire.Kind)) |kind| {
        wire.writePrefix(&prefix, kind, 0, 0);
        try std.testing.expect(prefix[0] < 0x7B);
    }
}
