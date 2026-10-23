// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg

//! Query the loaded cache: glob-search entries by name and filter by mtime.
//!
//! This is the read-side API the CLI uses. It takes a `*const Cache` (the engine's
//! in-memory state, FORMAT.md § 7) and returns matching entries with their full 64-byte metadata.
//!
//! ## Query patterns (the `glob` command)
//!
//! A query pattern is a **git wildmatch pattern**, matched by the same `gitignore` dependency's
//! `globMatch` that the `.gitignore` chain uses. There is no second dialect (DEC-051): every wildcard in
//! this project is that matcher, so the query and the ignore chain cannot disagree.
//!
//! The anchoring rule is gitignore's own:
//!
//! - A pattern **without a `/`** names a basename and matches it at any depth: `*.txt` matches `a.txt`
//!   and `src/a.txt`.
//! - A pattern **with a `/`** — a leading one included — is relative to the query root and is matched
//!   against the whole name path: `src/*.txt` matches `src/a.txt` but not `other/src/a.txt`. A leading
//!   `/` is accepted and is not part of the pattern.
//!
//! Matching is case-sensitive on every platform, as git's is.
//!
//! `*` never crosses `/`; `**` follows git's three cases (a leading `**/`, a trailing `/**` and
//! `a/**/b`); `?` is one character; `[...]`, `[!...]` and `[^...]` are character classes with ranges;
//! `\` escapes. A consecutive run of asterisks that is not a whole segment is just asterisks.
//!
//! A query is a **pattern**, not a `.gitignore` line: it has no polarity (`!` is literal), no comment
//! syntax (`#` is literal), no trailing-space trimming and no directory-only notion. A query selects
//! names, and a name never ends in `/` (FORMAT.md § 3), so a pattern ending in `/` names nothing.
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
const gitignore = @import("gitignore.zig");
const format = @import("format.zig");
const cache_mod = @import("cache.zig");

pub const Cache = cache_mod.Cache;

// ──────────────────────────────────────────────
// Glob
// ──────────────────────────────────────────────

/// A query pattern: one git wildmatch pattern plus gitignore's anchoring decision.
///
/// This is deliberately **not** a compiler. `gitignore.globMatch` is the matcher (the dependency's segment
/// dynamic program, and the one implementation every wildcard in this project uses); this type only applies
/// gitignore's anchoring rule and owns the pattern bytes.
pub const Glob = struct {
    pattern: []u8,
    /// A `/` at the start or in the middle: match the whole name path, not just its basename.
    anchored: bool,

    /// Compile a query pattern. The only failure is allocation: an unterminated `[`, an empty pattern and a
    /// trailing `/` are all patterns wildmatch itself has an answer for (respectively: matches nothing, the
    /// empty name, and no name at all), so they are not compile errors.
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Glob {
        const anchored = (pattern.len > 0 and pattern[0] == '/') or
            std.mem.indexOfScalar(u8, pattern, '/') != null;
        const body = if (pattern.len > 0 and pattern[0] == '/') pattern[1..] else pattern;
        return .{ .pattern = try allocator.dupe(u8, body), .anchored = anchored };
    }

    pub fn deinit(self: *Glob, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }

    /// Match a name path against this pattern, with gitignore's anchoring rule.
    pub fn matches(self: *const Glob, name: []const u8) bool {
        const text = if (self.anchored) name else baseName(name);
        return gitignore.globMatch(self.pattern, text);
    }
};

/// The final segment of a `/`-separated path.
fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
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

test "glob: a pattern without a slash matches a basename at any depth" {
    var g = try Glob.compile(testing.allocator, "*.zig");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("a.zig"));
    try testing.expect(g.matches("main.zig"));
    // gitignore's anchoring rule, not the old full-path rule: no `/` means the basename, at any depth.
    try testing.expect(g.matches("src/a.zig"));
    try testing.expect(g.matches("src/deep/a.zig"));
    try testing.expect(!g.matches("src/a.txt"));
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

test "glob: consecutive asterisks inside a segment are just asterisks" {
    var g = try Glob.compile(testing.allocator, "a**c");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("ac"));
    try testing.expect(g.matches("abc"));
    try testing.expect(g.matches("abbc"));
    // `**` is special only as a whole segment (git's rule): a run inside a segment cannot cross a `/`.
    try testing.expect(!g.matches("a/b/c"));
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

test "glob: character classes have ranges, a caret negation and escapes" {
    var range = try Glob.compile(testing.allocator, "file[0-9].txt");
    defer range.deinit(testing.allocator);
    try testing.expect(range.matches("file7.txt"));
    try testing.expect(!range.matches("filex.txt"));

    var caret = try Glob.compile(testing.allocator, "[^a].txt");
    defer caret.deinit(testing.allocator);
    try testing.expect(caret.matches("b.txt"));
    try testing.expect(!caret.matches("a.txt"));

    var escape = try Glob.compile(testing.allocator, "a\\*b");
    defer escape.deinit(testing.allocator);
    try testing.expect(escape.matches("a*b"));
    try testing.expect(!escape.matches("axb"));
}

test "glob: an unterminated class matches nothing (git's wildmatch aborts it)" {
    var g = try Glob.compile(testing.allocator, "[abc");
    defer g.deinit(testing.allocator);
    try testing.expect(!g.matches("[abc"));
    try testing.expect(!g.matches("a"));
}

test "glob: a query has no polarity and no comment syntax" {
    // A query is a wildmatch pattern, not a `.gitignore` line: `!` and `#` are ordinary characters.
    var bang = try Glob.compile(testing.allocator, "!keep.log");
    defer bang.deinit(testing.allocator);
    try testing.expect(bang.matches("!keep.log"));
    try testing.expect(!bang.matches("keep.log"));

    var hash = try Glob.compile(testing.allocator, "#notes.txt");
    defer hash.deinit(testing.allocator);
    try testing.expect(hash.matches("#notes.txt"));
    try testing.expect(!hash.matches("notes.txt"));
}

test "glob: a leading slash anchors the same way a middle slash does" {
    var g = try Glob.compile(testing.allocator, "/build");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("build"));
    try testing.expect(!g.matches("src/build"));
}

test "glob: a trailing slash names no name" {
    // Directory-only is a `.gitignore` notion and a query has no file kind. A name never ends in `/`
    // (FORMAT.md § 3), so the pattern as written cannot match one; say so rather than guessing a kind.
    var g = try Glob.compile(testing.allocator, "src/");
    defer g.deinit(testing.allocator);
    try testing.expect(!g.matches("src"));
    try testing.expect(!g.matches("a/src"));
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

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expectEqualStrings("a.txt", results[0].name);
    try testing.expectEqualStrings("b.txt", results[1].name);
    // No `/` in the pattern, so gitignore's rule reaches the basename at any depth.
    try testing.expectEqualStrings("src/c.txt", results[2].name);
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

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("b.txt", results[0].name);
    try testing.expectEqualStrings("src/c.txt", results[1].name);
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
// Conformance: the shared gitignore vectors, through the query path
// ──────────────────────────────────────────────

// The vectors the `gitignore` project gates its matcher with, vendored into this repository so this test
// cannot drift from the matcher the `.gitignore` chain uses. Read from the checkout, not copied: one file
// is the definition for every port.
const gitignore_vectors_path = "conformance/gitignore-vectors.json";

// Every shared vector that a query pattern can express, matched through `Glob` — the same query path the
// `glob` command uses.
//
// A query is one wildmatch pattern at the query root. The cases that do **not** apply are the ignore-rule
// notions a query deliberately has none of: precedence across rule files or pattern lines (4 vectors), a
// comment line (1), a negation (0 single-line vectors; the 2 negation vectors are multi-line and are already
// skipped as precedence), directory-only patterns (3 — a query has no file kind), trailing-space trimming
// (1) and CRLF line-ending trimming (1). That leaves 24 of the 34 vectors as pure pattern-versus-name cases.
test "conformance: every gitignore vector a query pattern can express" {
    const vectors_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        gitignore_vectors_path,
        testing.allocator,
        std.Io.Limit.limited(1 << 20),
    );
    defer testing.allocator.free(vectors_text);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, vectors_text, .{});
    defer parsed.deinit();

    const vectors = parsed.value.object.get("cases").?.array.items;
    var applied: usize = 0;
    var skipped: usize = 0;

    for (vectors) |vector_value| {
        const vector = vector_value.object;
        const rule_files = vector.get("ruleFiles").?.array.items;

        // A query is one pattern rooted at the query root, so a vector with a second rule file, with a
        // rule file below the root, or with more than one pattern line is a precedence case.
        if (rule_files.len != 1) {
            skipped += 1;
            continue;
        }
        const rule_file = rule_files[0].object;
        if (!std.mem.eql(u8, rule_file.get("dir").?.string, "")) {
            skipped += 1;
            continue;
        }

        const rule_text = rule_file.get("rules").?.string;
        var pattern_line: ?[]const u8 = null;
        var line_count: usize = 0;
        var lines = std.mem.splitScalar(u8, rule_text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            line_count += 1;
            pattern_line = line;
        }
        if (line_count != 1) {
            skipped += 1;
            continue;
        }
        const line = pattern_line.?;

        // The rule-file notions a query does not have: a comment (`#`), a negation (`!`; a query has no
        // polarity), a directory-only trailing slash (a query has no kind), and the CRLF / trailing-space
        // trimming a `.gitignore` line receives. What remains is pure wildmatch.
        if (line.len == 0 or line[0] == '#' or line[0] == '!') {
            skipped += 1;
            continue;
        }
        if (endsWithUnescaped(line, '/') or endsWithUnescaped(line, ' ') or line[line.len - 1] == '\r') {
            skipped += 1;
            continue;
        }

        const expected = vector.get("expect").?.string;
        const should_match = !std.mem.eql(u8, expected, "no-opinion");
        const path = vector.get("path").?.string;

        var glob = try Glob.compile(testing.allocator, line);
        defer glob.deinit(testing.allocator);
        const got = glob.matches(path);
        if (got != should_match) {
            std.debug.print("vector '{s}': pattern '{s}' against '{s}', expected {s}, got {s}\n", .{
                vector.get("name").?.string,
                line,
                path,
                if (should_match) "match" else "no match",
                if (got) "match" else "no match",
            });
        }
        try testing.expectEqual(should_match, got);
        applied += 1;
    }

    // Pin the split: a future vector edit cannot quietly turn this into a test that skips most of its cases.
    try testing.expectEqual(@as(usize, 24), applied);
    try testing.expectEqual(@as(usize, 10), skipped);
}

/// Whether `text` ends with `byte` and that byte is not escaped by an odd number of backslashes.
fn endsWithUnescaped(text: []const u8, byte: u8) bool {
    if (text.len == 0 or text[text.len - 1] != byte) return false;
    var backslashes: usize = 0;
    var index = text.len - 1;
    while (index > 0 and text[index - 1] == '\\') : (index -= 1) backslashes += 1;
    return (backslashes & 1) == 0;
}

test "glob: a doublestar prefix works when a slash follows it too" {
    // git's `**/` is zero or more directories wherever it appears, so this is `foo/*` at any depth —
    // not the basename-only reading an ignore rule's `**/name` shorthand would suggest.
    var g = try Glob.compile(testing.allocator, "**/foo/*");
    defer g.deinit(testing.allocator);
    try testing.expect(g.matches("foo/x"));
    try testing.expect(g.matches("a/foo/x"));
    try testing.expect(!g.matches("a/foo"));
    try testing.expect(!g.matches("foo/x/y"));
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
