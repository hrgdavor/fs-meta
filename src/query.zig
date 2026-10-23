// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! Query the loaded cache: glob-search entries by name and filter by mtime.
//!
//! This is the read-side API the CLI and socket share. It takes a `*const Cache` (the engine's
//! in-memory state, FORMAT.md § 7) and returns matching entries with their full 64-byte metadata.
//!
//! ## The glob
//!
//! The pattern syntax follows gitignore's rules (which this project already applies in `gitignore.zig`):
//!
//! - `*` — any sequence of characters except `/`
//! - `**` — any sequence of characters including `/` (crosses directory boundaries)
//! - `?` — exactly one character
//! - `[abc]` — one character from the set
//! - `[!abc]` — one character not in the set
//! - literal characters match themselves
//!
//! The match is against the **relative path** as the cache keys it: `/`-separated, no trailing slash,
//! no `.` components. A directory's name has no trailing slash (the slash is the layout's, not the
//! name's — `cache.zig`'s `dirPath` says the same).
//!
//! ## The query
//!
//! `Query.run` walks both `cache.files` and `cache.dirs`, applies the optional glob and the optional
//! mtime filter, and returns the matches sorted by name. A directory's `DirState` is projected to a
//! `format.Entry` (kind = `.dir`, size 0, content_hash 0) so the result carries the same shape for
//! every kind.
//!
//! ## Timestamps
//!
//! `parseSince` accepts an ISO-8601 date-time (`2026-10-20T12:00:00Z`) or a relative form (`1h`, `30m`,
//! `2d`). The engine core has no clock, so the relative form takes a `now_ns` parameter: the caller
//! supplies the reference time.

const std = @import("std");
const format = @import("format.zig");
const cache_mod = @import("cache.zig");

pub const Cache = cache_mod.Cache;

// ──────────────────────────────────────────────
// Glob
// ──────────────────────────────────────────────

/// One compiled pattern element.
const Token = struct {
    /// 0=literal, 1=star, 2=starstar, 3=question, 4=char_class, 5=starstar_slash
    tag: u8,
    literal: u8 = 0,
    chars: ?[]const u8 = null,
    negated: bool = false,
};

/// A compiled glob pattern. Owns its tokens and any character-class slices.
pub const Glob = struct {
    tokens: []Token,

    pub fn deinit(self: *Glob, allocator: std.mem.Allocator) void {
        for (self.tokens) |token| {
            if (token.tag == 4) {
                if (token.chars) |chars| {
                    allocator.free(chars);
                }
            }
        }
        allocator.free(self.tokens);
    }

    /// Compile a glob pattern into a token list.
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Glob {
        var tokens: std.ArrayListUnmanaged(Token) = .empty;
        errdefer tokens.deinit(allocator);

        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];
            switch (c) {
                '*' => {
                    if (i + 1 < pattern.len and pattern[i + 1] == '*') {
                        if (i + 2 < pattern.len and pattern[i + 2] == '/') {
                            // `**/` matches zero or more path segments (gitignore: `**/foo` matches `foo` at any depth)
                            try tokens.append(allocator, .{ .tag = 5 });
                            i += 2; // consume `**/`
                        } else {
                            try tokens.append(allocator, .{ .tag = 2 });
                            i += 1; // consume the second `*`
                        }
                    } else {
                        try tokens.append(allocator, .{ .tag = 1 });
                    }
                },
                '?' => {
                    try tokens.append(allocator, .{ .tag = 3 });
                },
                '[' => {
                    var j: usize = i + 1;
                    var negated = false;
                    if (j < pattern.len and pattern[j] == '!') {
                        negated = true;
                        j += 1;
                    }
                    var chars: std.ArrayListUnmanaged(u8) = .empty;
                    defer chars.deinit(allocator);
                    while (j < pattern.len and pattern[j] != ']') : (j += 1) {
                        try chars.append(allocator, pattern[j]);
                    }
                    if (j < pattern.len) { // found `]`
                        const chars_slice = try chars.toOwnedSlice(allocator);
                        try tokens.append(allocator, .{ .tag = 4, .chars = chars_slice, .negated = negated });
                        i = j; // the loop's `i += 1` advances past `]`
                    }
                },
                else => {
                    try tokens.append(allocator, .{ .tag = 0, .literal = c });
                },
            }
        }

        return .{ .tokens = try tokens.toOwnedSlice(allocator) };
    }

    /// Match a relative path against this pattern.
    pub fn matches(self: *const Glob, name: []const u8) bool {
        return matchFrom(self.tokens, 0, name, 0);
    }
};

fn matchFrom(tokens: []const Token, ti: usize, name: []const u8, ni: usize) bool {
    if (ti == tokens.len) return ni == name.len;
    switch (tokens[ti].tag) {
        0 => { // literal
            if (ni < name.len and name[ni] == tokens[ti].literal) return matchFrom(tokens, ti + 1, name, ni + 1);
            return false;
        },
        1 => { // star: any sequence of non-slash characters
            if (matchFrom(tokens, ti + 1, name, ni)) return true;
            var i = ni;
            while (i < name.len and name[i] != '/') : (i += 1) {
                if (matchFrom(tokens, ti + 1, name, i + 1)) return true;
            }
            return false;
        },
        2 => { // starstar: any sequence including `/`
            var i = ni;
            while (i <= name.len) : (i += 1) {
                if (matchFrom(tokens, ti + 1, name, i)) return true;
            }
            return false;
        },
        3 => { // question: exactly one character
            if (ni < name.len) return matchFrom(tokens, ti + 1, name, ni + 1);
            return false;
        },
        4 => { // char_class
            if (ni < name.len) {
                const ch = name[ni];
                const chars = tokens[ti].chars.?;
                const in_set = std.mem.indexOfScalar(u8, chars, ch) != null;
                const matches = if (tokens[ti].negated) !in_set else in_set;
                if (matches) return matchFrom(tokens, ti + 1, name, ni + 1);
            }
            return false;
        },
        5 => { // starstar_slash: matches "" or "any/any/.../any/" (zero or more path segments)
            // Try matching the rest at the current position (matched empty).
            if (matchFrom(tokens, ti + 1, name, ni)) return true;
            // Try matching up to and including each '/'.
            var i = ni;
            while (i < name.len) : (i += 1) {
                if (name[i] == '/') {
                    if (matchFrom(tokens, ti + 1, name, i + 1)) return true;
                }
            }
            return false;
        },
        else => unreachable,
    }
}

// ──────────────────────────────────────────────
// Query
// ──────────────────────────────────────────────

/// One matching entry: the name (borrowed from the cache) and its full 64-byte metadata.
pub const Match = struct {
    name: []const u8,
    entry: format.Entry,
};

/// The query parameters.
pub const Query = struct {
    cache: *const Cache,
    glob: ?*const Glob = null,
    since_ns: ?u64 = null,
};

/// Run the query: walk the cache, apply the filters, return the matches sorted by name.
///
/// `name` in each `Match` borrows from the cache; the caller must keep the cache alive as long as
/// it uses the result.
pub fn run(allocator: std.mem.Allocator, q: Query) ![]Match {
    var results: std.ArrayListUnmanaged(Match) = .empty;
    errdefer results.deinit(allocator);

    // Files: regular files and symlinks.
    const it = q.cache.files.keys();
    for (it) |name| {
        if (q.glob) |g| {
            if (!g.matches(name)) continue;
        }
        const state = q.cache.files.get(name).?;
        if (q.since_ns) |since| {
            if (state.mtime_ns < since) continue;
        }
        const entry = entryFromFileState(name, state);
        try results.append(allocator, .{ .name = name, .entry = entry });
    }

    // Directories: projected to a `format.Entry`.
    const dit = q.cache.dirs.keys();
    for (dit) |name| {
        if (name.len == 0) continue; // the root is never listed (§ 3)
        if (q.glob) |g| {
            if (!g.matches(name)) continue;
        }
        const state = q.cache.dirs.get(name).?;
        if (q.since_ns) |since| {
            if (state.mtime_ns < since) continue;
        }
        const entry = entryFromDirState(name, state);
        try results.append(allocator, .{ .name = name, .entry = entry });
    }

    // Sort by name: the cache's iteration order is arbitrary; the output is name-ordered so it is
    // diffable and matches `files.txt`.
    std.mem.sort(Match, results.items, {}, matchLessThan);

    return try results.toOwnedSlice(allocator);
}

fn entryFromFileState(name: []const u8, state: cache_mod.FileState) format.Entry {
    return .{
        .mtime_ns = state.mtime_ns,
        .size_bytes = state.size_bytes,
        .content_hash = state.content_hash orelse 0,
        .name_hash = format.wyhash(name),
        .name_offset = 0,
        .name_length = @intCast(name.len),
        .flags_word = if (state.kind == .symlink)
            format.flags.symlink | (if (state.content_hash != null) format.flags.content_known else @as(u32, 0))
        else
            format.flags.regular_file | (if (state.content_hash != null) format.flags.content_known else @as(u32, 0)),
        .file_id_lo = state.file_id_lo,
        .file_id_hi = state.file_id_hi,
    };
}

fn entryFromDirState(name: []const u8, state: cache_mod.DirState) format.Entry {
    return .{
        .mtime_ns = state.mtime_ns,
        .size_bytes = 0,
        .content_hash = 0,
        .name_hash = format.wyhash(name),
        .name_offset = 0,
        .name_length = @intCast(name.len),
        .flags_word = format.flags.is_dir,
        .file_id_lo = state.file_id_lo,
        .file_id_hi = state.file_id_hi,
    };
}

fn matchLessThan(_: void, a: Match, b: Match) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ──────────────────────────────────────────────
// JSON output
// ──────────────────────────────────────────────

/// Serialize a `[]Match` to a JSON array. Hand-rolled (same rule as `json_doc.zig`): the emitted
/// bytes are part of the contract, and a formatter change must not silently move them.
pub fn toJson(allocator: std.mem.Allocator, matches: []const Match) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    if (matches.len == 0) {
        try writer.writeAll("[]\n");
        return out.toOwnedSlice();
    }

    try writer.writeAll("[\n");
    for (matches, 0..) |match, index| {
        const e = match.entry;
        try writer.writeAll("  {\n");
        try writer.writeAll("    \"name\": ");
        try jsonWriteString(writer, match.name);
        try writer.writeAll(",\n");
        try writer.print("    \"mtime_ns\": {d},\n", .{e.mtime_ns});
        try writer.print("    \"size_bytes\": {d},\n", .{e.size_bytes});
        try writer.print("    \"content_hash\": {d},\n", .{e.content_hash});
        try writer.print("    \"name_hash\": {d},\n", .{e.name_hash});
        try writer.print("    \"name_offset\": {d},\n", .{e.name_offset});
        try writer.print("    \"name_length\": {d},\n", .{e.name_length});
        try writer.print("    \"flags_word\": {d},\n", .{e.flags_word});
        try writer.print("    \"file_id_lo\": {d},\n", .{e.file_id_lo});
        try writer.print("    \"file_id_hi\": {d}\n", .{e.file_id_hi});
        try writer.writeAll(if (index + 1 == matches.len) "  }\n" else "  },\n");
    }
    try writer.writeAll("]\n");

    return out.toOwnedSlice();
}

fn jsonWriteString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u{x:0>4}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ──────────────────────────────────────────────
// Timestamps
// ──────────────────────────────────────────────

/// Parse a `since` timestamp. Accepts:
///
/// - ISO-8601: `2026-10-20T12:00:00Z`, `2026-10-20T12:00:00+02:00`, `2026-10-20` (midnight UTC)
/// - Relative: `1h`, `30m`, `2d`, `1h30m` — relative to `now_ns`
///
/// Returns nanoseconds since the unix epoch, or `null` if unparseable.
pub fn parseSince(text: []const u8, now_ns: u64) ?u64 {
    if (isRelativeForm(text)) {
        return parseRelative(text, now_ns);
    }
    return parseIso8601(text);
}

/// Whether the text is a relative form: one or more digit-unit pairs, unit in `s`, `m`, `h`, `d`, `w`.
fn isRelativeForm(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    var saw_digit = false;
    while (i < text.len) {
        if (text[i] >= '0' and text[i] <= '9') {
            saw_digit = true;
            i += 1;
        } else if (text[i] == 's' or text[i] == 'm' or text[i] == 'h' or text[i] == 'd' or text[i] == 'w') {
            if (!saw_digit) return false;
            saw_digit = false;
            i += 1;
        } else {
            return false;
        }
    }
    return !saw_digit; // must end with a unit
}

fn parseRelative(text: []const u8, now_ns: u64) ?u64 {
    var i: usize = 0;
    var total_ns: u64 = 0;
    while (i < text.len) {
        var num: u64 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
            num = num * 10 + @as(u64, text[i] - '0');
        }
        if (i >= text.len) return null;
        const unit = text[i];
        i += 1;
        const unit_ns: u64 = switch (unit) {
            's' => 1_000_000_000,
            'm' => 60_000_000_000,
            'h' => 3_600_000_000_000,
            'd' => 86_400_000_000_000,
            'w' => 604_800_000_000_000,
            else => return null,
        };
        total_ns += num * unit_ns;
    }
    if (total_ns > now_ns) return 0;
    return now_ns - total_ns;
}

/// Parse an ISO-8601 date-time. Handles `Z` (UTC) and `±HH:MM` offsets.
fn parseIso8601(text: []const u8) ?u64 {
    if (text.len < 10) return null;

    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    if (text[4] != '-') return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    if (text[7] != '-') return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var hours: i64 = 0;
    var minutes: i64 = 0;
    var seconds: i64 = 0;
    var offset_sign: i64 = 1;
    var offset_hours: i64 = 0;
    var offset_minutes: i64 = 0;

    var i: usize = 10;
    if (i < text.len and text[i] == 'T') {
        i += 1;
        if (i + 2 <= text.len) {
            hours = std.fmt.parseInt(i64, text[i .. i + 2], 10) catch return null;
            i += 2;
        }
        if (i < text.len and text[i] == ':') {
            i += 1;
            if (i + 2 <= text.len) {
                minutes = std.fmt.parseInt(i64, text[i .. i + 2], 10) catch return null;
                i += 2;
            }
        }
        if (i < text.len and text[i] == ':') {
            i += 1;
            if (i + 2 <= text.len) {
                seconds = std.fmt.parseInt(i64, text[i .. i + 2], 10) catch return null;
                i += 2;
            }
        }
    }

    // Offset: `Z` is UTC; `+HH:MM` or `-HH:MM` is the local offset from UTC.
    if (i < text.len) {
        if (text[i] == 'Z') {
            // UTC, nothing to adjust.
        } else if (text[i] == '+' or text[i] == '-') {
            offset_sign = if (text[i] == '+') 1 else -1;
            i += 1;
            if (i + 2 <= text.len) {
                offset_hours = std.fmt.parseInt(i64, text[i .. i + 2], 10) catch return null;
                i += 2;
                if (i < text.len and text[i] == ':') {
                    i += 1;
                    if (i + 2 <= text.len) {
                        offset_minutes = std.fmt.parseInt(i64, text[i .. i + 2], 10) catch return null;
                        i += 2;
                    }
                }
            }
        }
    }

    const days = daysSinceEpoch(year, month, day);
    // The text's time is UTC + offset, so UTC = text_time - offset.
    // All values fit in i64: days * 86.4e9 ≈ 1.7e15 for year 2026.
    const days_ns: i64 = days * 86_400_000_000_000;
    const time_ns: i64 = hours * 3_600_000_000_000 + minutes * 60_000_000_000 + seconds * 1_000_000_000;
    const offset_ns: i64 = offset_sign * (offset_hours * 3_600_000_000_000 +
        offset_minutes * 60_000_000_000);
    const ns: i64 = days_ns + time_ns - offset_ns;

    if (ns < 0) return null;
    if (ns > std.math.maxInt(u64)) return null;
    return @bitCast(ns);
}

/// Days since 1970-01-01, from the civil date. Algorithm from Howard Hinnant's `date.h`.
fn daysSinceEpoch(year: i64, month: i64, day: i64) i64 {
    var y: i64 = year;
    if (month <= 2) y -= 1;
    const era: i64 = @divTrunc(y, 400);
    const yoe: i64 = y - era * 400; // [0 - 399]
    const doy: i64 = @divTrunc((month - 3 + 12) * 153 + 2, 5) + day - 1; // [0 - 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe - 1, 4) - @divTrunc(yoe - 1, 100) + doy; // [0 - 146096]
    return era * 146097 + doe - 719468;
}

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

const testing = std.testing;

test "glob: literal matches exactly" {
    var g = try Glob.compile(testing.allocator, "src/main.zig");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("src/main.zig"));
    try testing.expect(!g.matches("src/other.zig"));
    try testing.expect(!g.matches("src/main.zig/"));
}

test "glob: star does not cross a slash" {
    var g = try Glob.compile(testing.allocator, "*.zig");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("a.zig"));
    try testing.expect(g.matches("main.zig"));
    try testing.expect(!g.matches("src/a.zig"));
}

test "glob: starstar crosses slashes" {
    var g = try Glob.compile(testing.allocator, "**/*.zig");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("a.zig"));
    try testing.expect(g.matches("src/a.zig"));
    try testing.expect(g.matches("src/deep/a.zig"));
    try testing.expect(!g.matches("a.txt"));
}

test "glob: question is one character" {
    var g = try Glob.compile(testing.allocator, "a?c");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("abc"));
    try testing.expect(g.matches("axc"));
    try testing.expect(!g.matches("ac"));
    try testing.expect(!g.matches("abbc"));
}

test "glob: character class" {
    var g = try Glob.compile(testing.allocator, "[abc]");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("a"));
    try testing.expect(g.matches("b"));
    try testing.expect(g.matches("c"));
    try testing.expect(!g.matches("d"));
}

test "glob: negated character class" {
    var g = try Glob.compile(testing.allocator, "[!abc]");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("d"));
    try testing.expect(g.matches("z"));
    try testing.expect(!g.matches("a"));
    try testing.expect(!g.matches("b"));
}

test "glob: star matches zero characters" {
    var g = try Glob.compile(testing.allocator, "a*c");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("ac"));
    try testing.expect(g.matches("abc"));
    try testing.expect(g.matches("abbc"));
}

test "glob: starstar matches zero characters" {
    var g = try Glob.compile(testing.allocator, "a**c");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("ac"));
    try testing.expect(g.matches("abc"));
    try testing.expect(g.matches("a/b/c"));
}

test "glob: src prefix matches the directory and everything under it" {
    var g = try Glob.compile(testing.allocator, "src/**");
    defer g.deinit(testing.allocator);
    // gitignore: `foo/**` matches everything *inside* foo, not foo itself.
    try testing.expect(!g.matches("src"));
    try testing.expect(g.matches("src/a"));
    try testing.expect(g.matches("src/a/b"));
    try testing.expect(!g.matches("srcx"));
    try testing.expect(!g.matches("other"));
}

test "glob: empty pattern matches only the empty string" {
    var g = try Glob.compile(testing.allocator, "");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches(""));
    try testing.expect(!g.matches("a"));
}

test "glob: a slash in the pattern is literal" {
    var g = try Glob.compile(testing.allocator, "src/*.zig");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("src/a.zig"));
    try testing.expect(!g.matches("a.zig"));
    try testing.expect(!g.matches("src/deep/a.zig"));
}

test "query: no filter returns everything, name-ordered" {
    var cache = makeTestCache();
    defer cache.deinit();

    const q = Query{ .cache = &cache };
    const results = try run(testing.allocator, q);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 4), results.len);
    try testing.expectEqualStrings("a.txt", results[0].name);
    try testing.expectEqualStrings("b.txt", results[1].name);
    try testing.expectEqualStrings("src", results[2].name);
    try testing.expectEqualStrings("src/c.txt", results[3].name);
}

test "query: glob filter" {
    var cache = makeTestCache();
    defer cache.deinit();

    var g = try Glob.compile(testing.allocator, "*.txt");
    defer g.deinit(testing.allocator);
    const q = Query{ .cache = &cache, .glob = &g };
    const results = try run(testing.allocator, q);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("a.txt", results[0].name);
    try testing.expectEqualStrings("b.txt", results[1].name);
}

test "query: mtime filter" {
    var cache = makeTestCache();
    defer cache.deinit();

    // a.txt has mtime 100, b.txt has 200, src has 150, src/c.txt has 300.
    const q = Query{ .cache = &cache, .since_ns = 150 };
    const results = try run(testing.allocator, q);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("b.txt", results[0].name);
    try testing.expectEqualStrings("src", results[1].name);
    try testing.expectEqualStrings("src/c.txt", results[2].name);
}

test "query: glob and mtime together" {
    var cache = makeTestCache();
    defer cache.deinit();

    var g = try Glob.compile(testing.allocator, "*.txt");
    defer g.deinit(testing.allocator);
    const q = Query{ .cache = &cache, .glob = &g, .since_ns = 150 };
    const results = try run(testing.allocator, q);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("b.txt", results[0].name);
}

test "query: directories are included" {
    var cache = makeTestCache();
    defer cache.deinit();

    var g = try Glob.compile(testing.allocator, "src");
    defer g.deinit(testing.allocator);
    const q = Query{ .cache = &cache, .glob = &g };
    const results = try run(testing.allocator, q);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqualStrings("src", results[0].name);
    try testing.expectEqual(format.Kind.dir, results[0].entry.kind());
}

test "parseSince: ISO-8601 UTC" {
    const ns = parseSince("2026-01-01T00:00:00Z", 0) orelse {
        try testing.expect(false);
        return;
    };
    // 2026-01-01 is 20454 days after 1970-01-01.
    try testing.expectEqual(@as(u64, 20454 * 86_400_000_000_000), ns);
}

test "parseSince: ISO-8601 date only is midnight UTC" {
    const ns = parseSince("2026-01-01", 0) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(u64, 20454 * 86_400_000_000_000), ns);
}

test "parseSince: ISO-8601 with time" {
    const ns = parseSince("2026-01-01T01:30:00Z", 0) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(u64, 20454 * 86_400_000_000_000 + 5_400_000_000_000), ns);
}

test "parseSince: ISO-8601 with positive offset" {
    // 12:00:00+02:00 is 10:00:00 UTC.
    const ns = parseSince("2026-01-01T12:00:00+02:00", 0) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(u64, 20454 * 86_400_000_000_000 + 36_000_000_000_000), ns);
}

test "parseSince: relative one hour" {
    const now: u64 = 1_000_000_000_000_000; // 1e15 ns ≈ 2001-11-17
    const ns = parseSince("1h", now) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(now - 3_600_000_000_000, ns);
}

test "parseSince: relative 30 minutes" {
    const now: u64 = 1_000_000_000_000_000;
    const ns = parseSince("30m", now) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(now - 1_800_000_000_000, ns);
}

test "parseSince: relative 2 days" {
    const now: u64 = 1_000_000_000_000_000;
    const ns = parseSince("2d", now) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(now - 172_800_000_000_000, ns);
}

test "parseSince: relative 1h30m" {
    const now: u64 = 1_000_000_000_000_000;
    const ns = parseSince("1h30m", now) orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(now - 5_400_000_000_000, ns);
}

test "parseSince: unparseable returns null" {
    try testing.expect(parseSince("not a date", 0) == null);
    try testing.expect(parseSince("", 0) == null);
    try testing.expect(parseSince("2026-13-01", 0) == null); // month 13
}

// ──────────────────────────────────────────────
// Test helper
// ──────────────────────────────────────────────

fn makeTestCache() Cache {
    const gpa = testing.allocator;
    var cache = Cache{ .allocator = gpa };

    _ = cache.files.put(
        gpa,
        "a.txt",
        .{ .kind = .regular_file, .mtime_ns = 100, .size_bytes = 1, .content_hash = 1, .hash_lf = false, .file_id_lo = 1, .file_id_hi = 1 },
    ) catch {};
    _ = cache.files.put(
        gpa,
        "b.txt",
        .{ .kind = .regular_file, .mtime_ns = 200, .size_bytes = 2, .content_hash = 2, .hash_lf = false, .file_id_lo = 2, .file_id_hi = 2 },
    ) catch {};
    _ = cache.files.put(
        gpa,
        "src/c.txt",
        .{ .kind = .regular_file, .mtime_ns = 300, .size_bytes = 3, .content_hash = 3, .hash_lf = false, .file_id_lo = 3, .file_id_hi = 3 },
    ) catch {};
    _ = cache.dirs.put(
        gpa,
        "src",
        .{ .mtime_ns = 150, .file_id_lo = 4, .file_id_hi = 4 },
    ) catch {};

    return cache;
}
