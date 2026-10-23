// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! The socket server: a Unix-socket listener that answers JSON-RPC `glob` and `changed` requests
//! from the in-memory `Cache`.
//!
//! The wire format (FORMAT.socket.md) is binary frames with an 8-byte prefix; a JSON-RPC request is
//! identified by its first two bytes `{"` (0x7B 0x22), which no binary frame can produce because
//! every `kind` is below 0x7B. This module is the server half of that contract: it listens on a
//! Unix socket, reads one request per connection, dispatches it, and writes the JSON response.
//!
//! Single-threaded: the polling thread owns the `Cache`, and the socket handler runs on that same
//! thread (FORMAT.socket.md: "the socket's Cache is single-threaded").

const std = @import("std");
const query = @import("query.zig");
const cache_mod = @import("cache.zig");
const wire = @import("wire.zig");

/// The socket path under which the server listens.
pub const socket_path = ".fs-meta/socket";

/// A JSON-RPC request: `{"method": "glob"|"changed", "params": {"pattern": "...", "since": "..."}}`.
pub const Request = struct {
    method: []const u8,
    pattern: ?[]const u8 = null,
    since: ?[]const u8 = null,
};

/// Parse a JSON-RPC request from its bytes. The returned strings are owned by the caller
/// (allocated from `allocator`) and must be freed after use.
pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.root;
    const method_raw = try jsonString(root, "method");
    const method = try allocator.dupe(method_raw);

    const params = root.objectGet("params") catch return .{ .method = method };

    const pattern_raw = params.objectGet("pattern") catch null;
    const since_raw = params.objectGet("since") catch null;

    return .{
        .method = method,
        .pattern = if (pattern_raw) |p| try allocator.dupe(p) else null,
        .since = if (since_raw) |s| try allocator.dupe(s) else null,
    };
}

/// Dispatch a parsed request against the cache and return the JSON response bytes.
/// Frees the request's owned strings on exit.
pub fn handle(allocator: std.mem.Allocator, cache: *const cache_mod.Cache, req: Request, now_ns: u64) ![]u8 {
    const since_ns = if (req.since) |s| query.parseSince(s, now_ns) else null;

    const glob = if (req.pattern) |p| blk: {
        var g = try query.Glob.compile(allocator, p);
        break :blk &g;
    } else null;

    const results = try query.run(allocator, .{
        .cache = cache,
        .glob = glob,
        .since_ns = since_ns,
    });
    defer allocator.free(results);

    if (glob) |g| g.deinit(allocator);

    const response = try query.toJson(allocator, results);

    // Free the request's owned strings.
    allocator.free(req.method);
    if (req.pattern) |p| allocator.free(p);
    if (req.since) |s| allocator.free(s);

    return response;
}

/// Serve one connection: read the request, dispatch it, write the response, close.
pub fn serveConnection(io: std.Io, allocator: std.mem.Allocator, cache: *const cache_mod.Cache, stream: std.Io.net.Stream) !void {
    const now_ns: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);

    // Read the request: a JSON-RPC request is a bare JSON object (no binary prefix).
    var buf: [4096]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &buf);
    const bytes = reader.interface.readAll(allocator);

    if (bytes.len == 0) return;

    // Check the JSON-RPC signature: `{"` = 0x7B 0x22.
    if (bytes.len < 2 or bytes[0] != 0x7B or bytes[1] != 0x22) return;

    const req = try parseRequest(allocator, bytes);
    const response = try handle(allocator, cache, req, now_ns);
    defer allocator.free(response);

    // Write the response.
    var wbuf: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &wbuf);
    try writer.interface.writeAll(response);
    writer.deinit();
    reader.deinit();
}

/// Run the server loop: listen on the Unix socket and accept connections until the caller cancels.
pub fn run(io: std.Io, allocator: std.mem.Allocator, cache: *const cache_mod.Cache) !void {
    // Remove a stale socket file from a previous run.
    _ = std.Io.File.deleteAbsolute(io, socket_path) catch {};

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    while (true) {
        const stream = try server.accept(io);
        try serveConnection(io, allocator, cache, stream);
        stream.close(io);
    }
}

// ──────────────────────────────────────────────
// Minimal JSON helpers
// ──────────────────────────────────────────────

fn jsonString(root: std.json.Value, key: []const u8) ![]const u8 {
    const value = root.objectGet(key) catch return error.MissingField;
    if (value.tag != .string) return error.TypeMismatch;
    return value.string;
}
