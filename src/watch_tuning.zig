// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Per-project watch tuning, persisted next to the trio.
//!
//! The scheduler learns a project's pass durations; a *folder* is the right scope for that knowledge, because it is
//! the folder's tree — its depth, its `.gitignore`, its ignored content — that decides what a pass costs. So the
//! learned state lives in `<project>/.fs-meta/watch.json`, a directory the walker never lists:
//!
//! ```json
//! { "version": 1, "passes": 42, "ewmaMs": 18.234, "lastMs": 17.900, "maxMs": 61.200, "suggestedDelayMs": 27.351 }
//! ```
//!
//! Two consequences, both deliberate:
//!
//! - **A restart resumes tuned.** The next watch session begins with the delay this project actually needs, instead
//!   of re-learning it from the first burst.
//! - **The runtime can tell the user what to configure.** `suggestedDelayMs` is what a fixed-delay mode should use,
//!   and it is derived from measurements rather than a table of guesses. A user who pins a delay gets the number
//!   that has been observed to work for *their* tree.
//!
//! The file is derived state: losing it costs one burst of re-learning, never correctness. It is written atomically
//! (temporary file, then rename) so a crash mid-write leaves the previous values, which is the same discipline the
//! trio itself follows for a much smaller stake.

const std = @import("std");
const watch = @import("watch.zig");

pub const file_name = "watch.json";

pub const State = struct {
    version: u64 = 1,
    /// Completed passes observed for this project, across sessions.
    passes: u64 = 0,
    ewma_ms: f64 = 0,
    last_ms: f64 = 0,
    max_ms: f64 = 0,
    /// The delay the scheduler would use right now, in milliseconds.
    suggested_delay_ms: f64 = 0,

    /// What a fixed-delay configuration should use, rounded up to whole milliseconds and at least the floor.
    pub fn suggestedDelayMs(self: State) u64 {
        if (self.suggested_delay_ms <= 0) return 25;
        return @intFromFloat(@ceil(self.suggested_delay_ms));
    }

    /// A line a CLI can print: what was measured and what to configure.
    pub fn describe(self: State, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(
            buffer,
            "watch tuning for this project: {d} passes, ewma {d:.1} ms, last {d:.1} ms, max {d:.1} ms → suggested delay {d} ms",
            .{ self.passes, self.ewma_ms, self.last_ms, self.max_ms, self.suggestedDelayMs() },
        ) catch buffer[0..0];
    }

    /// Fold one more measured pass into the state.
    pub fn observe(self: *State, duration_ms: f64, scheduler_tuning: watch.Tuning) void {
        self.passes += 1;
        self.last_ms = duration_ms;
        self.max_ms = @max(self.max_ms, duration_ms);
        if (self.passes == 1) {
            self.ewma_ms = duration_ms;
        } else {
            self.ewma_ms = self.ewma_ms * 0.7 + duration_ms * 0.3;
        }
        const estimate = scheduler_tuning.factor * self.ewma_ms;
        self.suggested_delay_ms = std.math.clamp(
            @max(estimate, scheduler_tuning.idle_quiet_ms),
            scheduler_tuning.min_delay_ms,
            scheduler_tuning.max_delay_ms,
        );
    }
};

/// Load the tuning state of a project, or defaults when it has never been watched.
pub fn load(arena: std.mem.Allocator, io: std.Io, meta_dir: std.Io.Dir) !State {
    const text = meta_dir.readFileAlloc(io, file_name, arena, std.Io.Limit.limited(1 << 16)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const object = &parsed.value.object;
    var state: State = .{};
    if (object.get("version")) |value| state.version = asInt(value) orelse 1;
    if (object.get("passes")) |value| state.passes = asInt(value) orelse 0;
    if (object.get("ewmaMs")) |value| state.ewma_ms = asFloat(value) orelse 0;
    if (object.get("lastMs")) |value| state.last_ms = asFloat(value) orelse 0;
    if (object.get("maxMs")) |value| state.max_ms = asFloat(value) orelse 0;
    if (object.get("suggestedDelayMs")) |value| state.suggested_delay_ms = asFloat(value) orelse 0;
    return state;
}

/// Store it, atomically.
pub fn save(arena: std.mem.Allocator, io: std.Io, meta_dir: std.Io.Dir, state: State) !void {
    const text = try std.fmt.allocPrint(
        arena,
        "{{\"version\":{d},\"passes\":{d},\"ewmaMs\":{d:.3},\"lastMs\":{d:.3},\"maxMs\":{d:.3},\"suggestedDelayMs\":{d:.3}}}\n",
        .{ state.version, state.passes, state.ewma_ms, state.last_ms, state.max_ms, state.suggested_delay_ms },
    );
    try meta_dir.writeFile(io, .{ .sub_path = file_name ++ ".tmp", .data = text });
    try std.Io.Dir.rename(meta_dir, file_name ++ ".tmp", meta_dir, file_name, io);
}

fn asInt(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| @intCast(number),
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

fn asFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "a project's tuning is measured, persisted and suggested" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".fs-meta");
    var meta_dir = try tmp.dir.openDir(io, ".fs-meta", .{});
    defer meta_dir.close(io);

    // Never watched: defaults, and a suggestion at the floor.
    var state = try load(arena, io, meta_dir);
    try testing.expectEqual(@as(u64, 0), state.passes);
    try testing.expectEqual(@as(u64, 25), state.suggestedDelayMs());

    // A handful of passes on a fast machine.
    for ([_]f64{ 18, 20, 17, 19, 21 }) |duration| state.observe(duration, .{});
    try testing.expectEqual(@as(u64, 5), state.passes);
    try testing.expectEqual(@as(f64, 21), state.max_ms);
    try testing.expect(state.suggestedDelayMs() >= 25);

    // Persisted, then read back by a new session with the same numbers.
    try save(arena, io, meta_dir, state);
    const restored = try load(arena, io, meta_dir);
    try testing.expectEqual(state.passes, restored.passes);
    try testing.expectEqual(state.max_ms, restored.max_ms);
    try testing.expectEqual(state.suggestedDelayMs(), restored.suggestedDelayMs());

    // A slow machine raises the suggestion; the state says so in words a CLI can print.
    var slow = restored;
    for (0..8) |_| slow.observe(700, .{});
    try testing.expect(slow.suggestedDelayMs() > restored.suggestedDelayMs());
    var buffer: [256]u8 = undefined;
    const line = slow.describe(&buffer);
    try testing.expect(std.mem.indexOf(u8, line, "suggested delay") != null);
}

test "a corrupt or absent file costs one re-learning, never an error" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".fs-meta");
    var meta_dir = try tmp.dir.openDir(io, ".fs-meta", .{});
    defer meta_dir.close(io);

    try meta_dir.writeFile(io, .{ .sub_path = file_name, .data = "not json at all" });
    const state = try load(arena, io, meta_dir);
    try testing.expectEqual(@as(u64, 0), state.passes);
}