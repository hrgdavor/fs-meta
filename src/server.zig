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
//! ## Two modes
//!
//! - **Replay (the default).** The connection ends after the replay; the client resumes by reconnecting
//!   with its new `from_batch`. This is the mode `test/socket.test.mjs` pins, and a one-shot consumer
//!   wants the connection to end.
//! - **Live (`fsmeta serve --live`).** One publisher task runs `engine.refresh` at the server's own
//!   cadence; a subscriber that has caught up stays connected and receives every new batch with the
//!   **same** `START_BATCH` / `CHANGE_ENTRY` / `END_BATCH` frames the replay uses. Live updates are
//!   already specified by `FORMAT.socket.md` § "Replay, resume and the two refusals" ("Live updates are
//!   the same messages"), so no kind, flag or payload was added — this is the publisher the protocol
//!   was waiting for, not a protocol change.
//!
//! `--live` is opt-in rather than the default because the replay-and-close contract is what the
//! existing socket suite asserts, and a client that asked from `from_batch` and wants a snapshot has no
//! reason to stay. Publishing stays the engine's job: the task calls `engine.refresh`, the one pass
//! that writes a generation and its batch, and never writes a batch itself.
//!
//! ## Concurrency
//!
//! One task per connection plus one publisher task, all in a `std.Io.Group` (`Group.concurrent`), which
//! is the shape Zig 0.17's `std.Io` makes simple: the group is long-lived and tasks are added as
//! connections arrive, each task owning its stream. The only shared state is `Live.newest`, an atomic
//! batch number. A connection copies it with acquire ordering, then loads and writes the batch through
//! its own directory handle — so there is **no lock**, and therefore none held across a socket write.
//! The publisher stores the number only after `batch.write` has returned, which is what makes a batch a
//! connection can read: `batch.write` creates its directory before its files, so the directory's
//! existence alone would expose a half-written batch.
//!
//! The publisher runs the engine pass on the server's own cadence (`poll_interval_ms`) and stamps each
//! pass with the wall clock, because a long-lived process's passes are not one instant; the engine core
//! deliberately has no clock of its own. A subscriber wakes every `wake_interval_ms` to read the atomic
//! — one sleep per wake, not a busy wait — because a delivery below a third of a second is well inside
//! the cost of the pass that produced it.
//!
//! `HELLO.capabilities` is 0 and `END_BATCH.changes_hash` is 0. `FORMAT.socket.md` still does not say
//! what `changes_hash` hashes, and its § Values this implementation pins says a client must not rely on
//! it; this server therefore does not advertise the capability and leaves the field zero. The counts in
//! `END_BATCH` are exact and are what the document actually defines.

const std = @import("std");
const format = @import("format.zig");
const cache_mod = @import("cache.zig");
const batch = @import("batch.zig");
const wire = @import("wire.zig");
const engine = @import("engine.zig");

/// The protocol major/minor this server speaks, as `HELLO.protocol` (`major << 8 | minor`). It is `wire.zig`'s
/// constant, not a second copy: the daemon's `STATE` frame moved it to 1.1, and a value written in two places
/// is a value that drifts. `FORMAT.socket.md` § Values this implementation pins states the number.
pub const protocol: u16 = wire.protocol;

/// The socket's name inside `<root>/.fs-meta`.
pub const socket_name = "socket";

/// The path the server listens on, relative to a root: `.fs-meta/socket`.
pub const socket_path = format.directory_name ++ "/" ++ socket_name;

/// How often live mode runs one engine pass. Small enough that a client sees a change promptly, large
/// enough that a full walk is not a busy wait; `--live` is a development tool, and a tree large enough
/// for one pass to be expensive should use the watcher, which publishes on file-system events.
pub const poll_interval_ms: u64 = 250;

/// How often a live subscriber reads the shared batch number. It reads one atomic and otherwise sleeps,
/// so delivery latency is bounded well below the pass interval at a negligible cost per connection.
const wake_interval_ms: u64 = 50;

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

/// What enables live mode and how it publishes. `null` at `run` is the replay-only server.
pub const LiveOptions = struct {
    /// The engine options the CLI parsed (`--hash`, `--no-gitignore`, `--per-file`). Each pass gets its
    /// own `updated` stamp, so this value supplies the rest of the `Options` and nothing else.
    engine: engine.Options,
    /// How often the publisher runs one pass; `--live` leaves it at `poll_interval_ms`.
    poll_ms: u64 = poll_interval_ms,
};

/// The state the publisher and every subscriber share. `newest` is the newest **batch** on disk; a pass
/// that publishes a generation but no batch (a touch that changes no entry) does not advance it, because
/// the stream's unit is the batch.
const Live = struct {
    io: std.Io,
    root: []const u8,
    options: engine.Options,
    poll_ms: u64,
    newest: std.atomic.Value(u64),
};

/// Serve until the process is killed: bind `<root>/.fs-meta/socket` and replay batches to subscribers.
///
/// `cache` is the loaded trio. The binary protocol replays the batch archive, so the cache is not
/// read here; loading it is the readiness check `fsmeta serve` performs before binding, because a
/// server with no usable trio could only answer with errors. Its count is reported at startup.
///
/// A non-null `live` starts the publisher task and keeps subscribers connected; a null one is the
/// replay-only server this command has always been.
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    cache: *const cache_mod.Cache,
    live: ?LiveOptions,
) !void {
    const path = try absoluteSocketPath(io, allocator, root);
    defer allocator.free(path);

    // The startup bounds are the banner's; each connection opens the archive for itself, because a live
    // server's archive grows while it runs and a `Dir` iteration position is not shared between tasks.
    const window = try openBatchWindow(io, root);
    defer if (window.dir) |dir| dir.close(io);

    // A socket left behind by a killed process is not a peer; remove it before binding. On Windows the
    // AF_UNIX bind does create a filesystem entry too, so the same rule applies on both platforms.
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const banner = if (live) |options|
        try std.fmt.allocPrint(
            allocator,
            "fsmeta: listening on {s} ({d} names, generation {d}), live (a pass every {d} ms)\n",
            .{ path, cache.fileCount() + cache.dirCount(), window.last, options.poll_ms },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "fsmeta: listening on {s} ({d} names, generation {d})\n",
            .{ path, cache.fileCount() + cache.dirCount(), window.last },
        );
    try std.Io.File.stdout().writeStreamingAll(io, banner);

    var state: Live = undefined;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    if (live) |options| {
        state = .{
            .io = io,
            .root = root,
            .options = options.engine,
            .poll_ms = options.poll_ms,
            .newest = std.atomic.Value(u64).init(window.last),
        };
        // One publisher for the whole process: two passes over the same root would race on the trio and
        // on the generation number, and a batch must have exactly one writer (§ 17).
        try group.concurrent(io, publisherTask, .{&state});
    }

    while (true) {
        const stream = try server.accept(io);
        if (live != null) {
            group.concurrent(io, connectionTask, .{ &state, stream }) catch {
                // A task could not be spawned; refuse the connection rather than serve it on the accept
                // thread, which would stall every other subscriber.
                std.debug.print("fsmeta: cannot start a connection task\n", .{});
                stream.close(io);
            };
        } else {
            serveConnection(io, allocator, stream, window) catch {};
            stream.close(io);
        }
    }
}

/// Serve one replay-only connection: greet, check the client's greeting, take its `SUBSCRIBE`, replay, close.
///
/// The error path sends one `ERROR` and returns; a read error is the peer leaving and is propagated so
/// `run` can ignore it and accept the next connection.
pub fn serveConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, window: BatchWindow) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read_buffer: [8192]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);

    // A connection is classified from its first eight bytes, which is both the smallest binary frame
    // prefix and the whole opener of the exec dialect (`{{ exec `). One read answers both questions,
    // and the bytes are not wasted: for a binary client they *are* the frame prefix.
    const opening = reader.interface.takeArray(opening_size) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
    if (std.mem.eql(u8, opening, exec_opening)) {
        try serveExec(io, arena, stream, &reader.interface);
        return;
    }

    const hello_frame = wire.readPrefix(opening) catch |err| {
        refuse(io, stream, .protocol, "{s}", .{frameErrorWord(err)});
        return;
    };
    const from_batch = (try negotiateWith(io, stream, &reader.interface, window, hello_frame)) orelse return;
    try replay(io, arena, stream, window, from_batch);
}

/// The eight bytes that open the exec dialect (`FORMAT.socket.md` § The `{{` dialect). Exactly eight,
/// so it is the same read that decides between the dialects.
const exec_opening = "{{ exec ";
const opening_size = wire.prefix_size;

fn takeByte(reader: *std.Io.Reader) !u8 {
    return reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        else => return err,
    };
}

/// Read up to and including `\n`, returning the line without it.
fn readLine(reader: *std.Io.Reader, buffer: []u8) ![]const u8 {
    var length: usize = 0;
    while (true) {
        const byte = try takeByte(reader);
        if (byte == '\n') return buffer[0..length];
        if (length == buffer.len) return error.ExecHeaderTooLarge;
        buffer[length] = byte;
        length += 1;
    }
}

/// `<length> <bytes>` — the length is what makes a value with a space or a newline safe.
fn readField(reader: *std.Io.Reader, arena: std.mem.Allocator) ![]const u8 {
    var digits: [24]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const byte = try takeByte(reader);
        if (byte == ' ') break;
        if (byte < '0' or byte > '9' or count == digits.len) return error.MalformedExecHeader;
        digits[count] = byte;
        count += 1;
    }
    if (count == 0) return error.MalformedExecHeader;
    const length = std.fmt.parseInt(usize, digits[0..count], 10) catch return error.MalformedExecHeader;
    if (length > 1 << 20) return error.ExecHeaderTooLarge;
    const bytes = try arena.alloc(u8, length);
    try reader.readSliceAll(bytes);
    if (try takeByte(reader) != '\n') return error.MalformedExecHeader;
    return bytes;
}

/// `{{ exec ` has been consumed; read `argc envc`, then the argv and env fields, and run the program
/// with the socket as its stdin and stdout.
///
/// The socket is handed to the child directly rather than relayed: `StdIo.file` passes an open file,
/// and a unix socket is a file descriptor, so the child's own writes go straight to the peer and the
/// server needs no copy loop. When the child exits the connection closes.
///
/// v1 runs argv[0] as given. The environment is parsed and currently ignored — the child inherits the
/// server's, which is what a daemon should do by default; a client that needs `NAME=VALUE` entries
/// honoured is talking to a server that has yet to implement them, and `FORMAT.socket.md` says so.
fn serveExec(io: std.Io, arena: std.mem.Allocator, stream: std.Io.net.Stream, reader: *std.Io.Reader) !void {
    var line_buffer: [64]u8 = undefined;
    const line = readLine(reader, &line_buffer) catch return;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    const argc_text = tokens.next() orelse return;
    const envc_text = tokens.next() orelse return;
    const argc = std.fmt.parseInt(usize, argc_text, 10) catch return;
    const envc = std.fmt.parseInt(usize, envc_text, 10) catch return;
    if (argc == 0 or argc > 4096 or envc > 4096) return;

    const argv = arena.alloc([]const u8, argc) catch return;
    for (argv) |*slot| slot.* = readField(reader, arena) catch return;
    for (0..envc) |_| _ = readField(reader, arena) catch return;

    // Everything still unread on the socket is the program's stdin.
    const socket_file: std.Io.File = .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = false } };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = socket_file },
        .stdout = .{ .file = socket_file },
        .stderr = .inherit,
    }) catch {
        return;
    };
    _ = child.wait(io) catch {};
}

/// The handshake: send `HELLO` for the window's newest batch, read the peer's, then its `SUBSCRIBE`.
/// Returns the client's `from_batch`, or `null` when the request was refused (an `ERROR` has been sent).
fn negotiate(
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: *std.Io.Reader,
    window: BatchWindow,
) !?u64 {
    const first = (try readFramePrefix(io, stream, reader)) orelse return null;
    return negotiateWith(io, stream, reader, window, first);
}

/// The handshake once the client's first frame prefix is already in hand — which it is when the dialect
/// was decided from those same eight bytes.
fn negotiateWith(
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: *std.Io.Reader,
    window: BatchWindow,
    hello_frame: wire.Frame,
) !?u64 {
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

    if (hello_frame.kind != .hello or hello_frame.length != wire.hello_size) {
        refuse(io, stream, .protocol, "expected a 24-byte HELLO greeting", .{});
        return null;
    }
    const hello_payload = try reader.take(hello_frame.length);
    const theirs = wire.Hello.read(hello_payload) catch {
        refuse(io, stream, .protocol, "malformed HELLO payload", .{});
        return null;
    };
    const verdict = wire.checkHello(ours, theirs);
    if (verdict != .ok) {
        refuse(io, stream, .protocol, "{s}", .{helloVerdictWord(verdict)});
        return null;
    }

    const subscribe_frame = (try readFramePrefix(io, stream, reader)) orelse return null;
    if (subscribe_frame.kind != .subscribe or subscribe_frame.length != 8) {
        refuse(io, stream, .protocol, "expected SUBSCRIBE with a u64 from_batch", .{});
        return null;
    }
    const subscribe_payload = try reader.take(subscribe_frame.length);
    const from_batch = std.mem.readInt(u64, subscribe_payload[0..8], .little);

    if (from_batch > window.last) {
        // FORMAT.socket.md does not say what a client ahead of the server means; refusing it is the
        // only answer that cannot silently skip a change set.
        refuse(io, stream, .protocol, "from_batch {d} is newer than the newest batch {d}", .{ from_batch, window.last });
        return null;
    }
    if (window.first) |first| {
        if (from_batch + 1 < first) {
            refuse(io, stream, .batch_too_old, "batches start at {d}, so from_batch {d} cannot be replayed", .{ first, from_batch });
            return null;
        }
    }
    return from_batch;
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

// ---------------------------------------------------------------- live streaming

/// One live connection: negotiate, replay what the archive has, then stay subscribed.
fn liveConnection(io: std.Io, root: []const u8, stream: std.Io.net.Stream, live: *Live) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read_buffer: [8192]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);

    var window = try openBatchWindow(io, root);
    defer if (window.dir) |dir| dir.close(io);

    const from_batch = (try negotiate(io, stream, &reader.interface, window)) orelse return;
    try replay(io, arena, stream, window, from_batch);

    // The replay's own handle is no longer needed; the live loop opens the archive per delivery so it
    // sees batches written after this connection started, and never shares an iteration position.
    const replayed = window.last;
    if (window.dir) |dir| dir.close(io);
    window.dir = null;

    try streamBatches(io, stream, live, replayed);
}

/// Stream every batch after `from` as the publisher makes it the newest, without reconnecting.
///
/// The loop reads one atomic per wake. A batch that the atomic names must be readable because the
/// publisher stores the number only after `batch.write` returned; if it is missing anyway the archive
/// has a hole, and a hole is `batch-gap` rather than a silent skip (FORMAT.md § 17.1, FORMAT.socket.md
/// § Replay, resume and the two refusals).
fn streamBatches(io: std.Io, stream: std.Io.net.Stream, live: *Live, from: u64) !void {
    var sent = from;
    while (true) {
        const newest = live.newest.load(.acquire);
        if (newest <= sent) {
            try io.sleep(.fromMilliseconds(wake_interval_ms), .real);
            continue;
        }

        const window = try openBatchWindow(io, live.root);
        defer if (window.dir) |dir| dir.close(io);
        const dir = window.dir orelse {
            return refuse(io, stream, .batch_gap, "no batch {d}; the archive is empty", .{sent + 1});
        };

        // One arena per wake, so a long-lived connection does not accumulate every batch it ever sent.
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var generation = sent + 1;
        while (generation <= newest) : (generation += 1) {
            const plan = loadBatch(arena, io, dir, generation) catch |err| switch (err) {
                error.BatchGap => {
                    return refuse(io, stream, .batch_gap, "no batch {d}; the archive ends at {d}", .{ generation, sent });
                },
                else => return err,
            };

            try sendStartBatch(io, stream, generation, generation - 1);
            for (plan.entries, plan.names) |entry, name| {
                try sendChangeEntry(io, arena, stream, entry, name);
            }
            try sendEndBatch(io, stream, generation, counts(plan));
        }
        sent = newest;
    }
}

/// The publisher task: one engine pass per `poll_ms`, forever. A pass that fails is reported once and
/// retried on the next tick; it must never stop the publisher, because a transient read error is not a
/// reason to leave every subscriber stale.
fn publisherTask(live: *Live) void {
    var reported_failure = false;
    while (true) {
        const interval: i64 = @intCast(live.poll_ms);
        live.io.sleep(.fromMilliseconds(interval), .real) catch return; // only `Canceled`: shut down
        publishOnce(live) catch |err| {
            if (!reported_failure) {
                std.debug.print("fsmeta: live pass failed: {s}\n", .{@errorName(err)});
                reported_failure = true;
            }
            continue;
        };
        reported_failure = false;
    }
}

/// One pass for live mode: refresh the root, then advertise the batch the pass wrote, if any.
fn publishOnce(live: *Live) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var options = live.options;
    // The engine core has no clock, so the caller supplies the instant. A long-lived server runs many
    // passes, and one start-up instant for all of them would describe none of them.
    var stamp: [32]u8 = undefined;
    options.updated = rfc3339Utc(live.io, &stamp);

    const outcome = try engine.refresh(arena, live.io, live.root, options);
    if (!outcome.published) return;
    if (outcome.generation <= live.newest.load(.acquire)) return;
    // A pass can publish a generation without a batch (a touched file whose hash and size did not
    // change produces an empty diff). The stream's unit is the batch, so only a written batch advances
    // the advertised number. `batchExists` runs after `batch.write` returned in this same task, so the
    // directory it finds is complete.
    if (!batchExists(live.io, live.root, outcome.generation)) return;
    live.newest.store(outcome.generation, .release);
}

/// Whether `batches/<generation>` exists under the root.
fn batchExists(io: std.Io, root: []const u8, generation: u64) bool {
    var name_buffer: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "{x:0>8}", .{generation}) catch return false;

    var root_dir = openRootDir(io, root) catch return false;
    defer root_dir.close(io);
    var meta_dir = root_dir.openDir(io, format.directory_name, .{}) catch return false;
    defer meta_dir.close(io);
    var batches = meta_dir.openDir(io, "batches", .{}) catch return false;
    defer batches.close(io);
    var dir = batches.openDir(io, name, .{}) catch return false;
    dir.close(io);
    return true;
}

/// The pass timestamp as RFC3339 UTC (`FORMAT.md` § 5 describes `updated` as an RFC3339 instant).
/// Seconds precision: the field is informational, and a server stamping every 250 ms does not need
/// sub-second digits to say when a pass ran.
fn rfc3339Utc(io: std.Io, buffer: *[32]u8) []const u8 {
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    const secs: u64 = if (seconds < 0) 0 else @intCast(seconds);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

/// The change counts `END_BATCH` must agree with (FORMAT.socket.md: "the counts must equal the entries
/// counted by change bit, or the batch is discarded").
pub const Counts = struct { added: u64 = 0, changed: u64 = 0, deleted: u64 = 0 };

pub fn counts(plan: batch.Plan) Counts {
    var result = Counts{};
    for (plan.entries) |entry| switch (batch.kindOf(entry) orelse continue) {
        .added => result.added += 1,
        .changed => result.changed += 1,
        .deleted => result.deleted += 1,
    };
    return result;
}

// ---------------------------------------------------------------- frames out

pub fn sendStartBatch(io: std.Io, stream: std.Io.net.Stream, number: u64, parent: u64) !void {
    var payload: [24]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], number, .little);
    std.mem.writeInt(u64, payload[8..16], parent, .little);
    // `started_ns` is diagnostic only and the batch's own timestamp is an ISO string in files.json;
    // no clock is read here, so the field is 0 rather than a fabricated pass time.
    std.mem.writeInt(u64, payload[16..24], 0, .little);
    try writeFrame(io, stream, .start_batch, &payload);
}

pub fn sendEndBatch(io: std.Io, stream: std.Io.net.Stream, number: u64, counted: Counts) !void {
    var payload: [40]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], number, .little);
    std.mem.writeInt(u64, payload[8..16], counted.added, .little);
    std.mem.writeInt(u64, payload[16..24], counted.changed, .little);
    std.mem.writeInt(u64, payload[24..32], counted.deleted, .little);
    // Unspecified (see the module comment): 0, with the `changes_hash` capability not advertised.
    std.mem.writeInt(u64, payload[32..40], 0, .little);
    try writeFrame(io, stream, .end_batch, &payload);
}

pub fn sendChangeEntry(
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

pub fn writeFrame(io: std.Io, stream: std.Io.net.Stream, kind: wire.Kind, payload: []const u8) !void {
    var prefix: [wire.prefix_size]u8 = undefined;
    wire.writePrefix(&prefix, kind, 0, @intCast(payload.len));
    var writer_buffer: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &writer_buffer);
    try writer.interface.writeAll(&prefix);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

pub fn writeBytes(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var writer_buffer: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &writer_buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn refuse(io: std.Io, stream: std.Io.net.Stream, code: ErrorCode, comptime wording: []const u8, args: anytype) void {
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
        error.InvalidState => "invalid-state",
        error.InvalidGitEvent => "invalid-git-event",
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

/// The largest batch *file* this reader will load. It is deliberately not `wire.max_frame`.
///
/// `max_frame` bounds one frame on the wire, and a `CHANGE_ENTRY` is 64 bytes plus a name — a batch is a *chain* of
/// frames, so a large generation is many small frames and is fine on the wire. Reusing the frame limit here meant a
/// batch whose `files.meta` or `files.txt` exceeded 1 MiB (about 16 384 names) could not be read back at all: the
/// generation was published, the consumer got `STATE(waking)` → `STATE(watching)` and no batch, and the daemon only
/// reported `StreamTooLong`. A first batch of a 20 000-name tree is exactly that case, which is why this is a
/// separate limit rather than a comment on the old one.
pub const max_batch_file_bytes: u64 = 1 << 28;

/// Read and decode `batches/<generation>`; a missing directory is `BatchGap`, which the replay turns
/// into the document's `ERROR {batch-gap}` rather than skipping the generation.
///
/// The returned plan's names point into the `files.txt` bytes, which this function does not free: the caller
/// supplies an arena that outlives the plan (a per-connection or per-pass arena in every caller). A general-purpose
/// allocator would leak the two file buffers, which is why the tests pass one too.
pub fn loadBatch(allocator: std.mem.Allocator, io: std.Io, batches: std.Io.Dir, generation: u64) !batch.Plan {
    const name = try std.fmt.allocPrint(allocator, "{x:0>8}", .{generation});
    var dir = batches.openDir(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.BatchGap,
        else => return err,
    };
    defer dir.close(io);

    const meta = try dir.readFileAlloc(io, format.meta_file, allocator, std.Io.Limit.limited(max_batch_file_bytes));
    const txt = try dir.readFileAlloc(io, format.txt_file, allocator, std.Io.Limit.limited(max_batch_file_bytes));
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

pub fn helloVerdictWord(verdict: wire.HelloVerdict) []const u8 {
    return switch (verdict) {
        .ok => "ok",
        .unsupported_version => "unsupported-version",
        .unsupported_entry_size => "unsupported-entry-size",
        .unsupported_hash => "unsupported-hash",
        .unsupported_capability => "unsupported-capability",
    };
}

// ---------------------------------------------------------------- live helpers

/// A connection task: the stream belongs to it, and it ends when the peer leaves or streaming fails.
fn connectionTask(live: *Live, stream: std.Io.net.Stream) void {
    defer stream.close(live.io);
    liveConnection(live.io, live.root, stream, live) catch {};
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
    try std.testing.expectEqual(@as(u16, 0x0102), std.mem.readInt(u16, bytes[8..10], .little));
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

test "the live pass timestamp is an RFC3339 instant, not a bare word" {
    var buffer: [32]u8 = undefined;
    const text = rfc3339Utc(std.testing.io, &buffer);
    try std.testing.expectEqual(@as(usize, 20), text.len);
    try std.testing.expectEqual(@as(u8, '-'), text[4]);
    try std.testing.expectEqual(@as(u8, '-'), text[7]);
    try std.testing.expectEqual(@as(u8, 'T'), text[10]);
    try std.testing.expectEqual(@as(u8, ':'), text[13]);
    try std.testing.expectEqual(@as(u8, ':'), text[16]);
    try std.testing.expectEqual(@as(u8, 'Z'), text[19]);
}

test "a batch bigger than one frame is loaded, not refused" {
    // The bug this pins: `loadBatch` used to read with `wire.max_frame` (1 MiB), so a genesis batch of more than
    // ~16 384 names could not be read back — the root published its first generation and every consumer got no
    // batch at all. A batch is many small frames on the wire; only the *files* on disk can be large.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const count: usize = 16_500; // 16 500 * 64 B = 1 056 000 B of meta, over the old limit
    const items = try std.testing.allocator.alloc(batch.Item, count);
    defer std.testing.allocator.free(items);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| std.testing.allocator.free(name);
        names.deinit(std.testing.allocator);
    }
    var entry = std.mem.zeroes(format.Entry);
    entry.flags_word = format.flags.regular_file | format.flags.content_known;
    entry.size_bytes = 1;
    for (items, 0..) |*item, index| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "file-{d:0>5}.txt", .{index});
        try names.append(std.testing.allocator, name);
        var named = entry;
        named.name_hash = format.wyhash(name);
        item.* = .{ .name = name, .entry = named };
    }

    const plan = try batch.diff(std.testing.allocator, &.{}, items);
    defer {
        std.testing.allocator.free(plan.entries);
        std.testing.allocator.free(plan.names);
    }
    try batch.write(std.testing.allocator, io, tmp.dir, plan, .{
        .generation = 1,
        .parent = 0,
        .created = "2026-10-26T00:00:00Z",
        .updated = "2026-10-26T00:00:00Z",
    });

    var batches = try tmp.dir.openDir(io, "batches", .{ .iterate = true });
    defer batches.close(io);
    var meta_dir = try batches.openDir(io, "00000001", .{});
    defer meta_dir.close(io);
    const meta_bytes = (try meta_dir.statFile(io, format.meta_file, .{})).size;
    try std.testing.expect(meta_bytes > wire.max_frame); // this test is only meaningful above the old limit

    // `loadBatch` borrows its file buffers from the allocator it is given and never frees them (they hold the name
    // slices), so a general-purpose allocator would report them as leaks. Every real caller passes an arena.
    var load_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer load_arena_state.deinit();
    const loaded = try loadBatch(load_arena_state.allocator(), io, batches, 1);
    try std.testing.expectEqual(count, loaded.entries.len);
}
