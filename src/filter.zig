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
//! - `length == 8`: the original form — `u64 from_batch`, no filter.
//! - `length >= 12`: the extended form — `u64 from_batch`, `u16 include_count`,
//!   `include_count × (u16 pattern_len + pattern_bytes)`, `u16 exclude_count`,
//!   `exclude_count × (u16 pattern_len + pattern_bytes)`.
//!
//! All integers are little-endian. A pattern is its UTF-8 bytes, no terminator.

const std = @import("std");
const gitignore = @import("gitignore.zig");

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

    /// Compile a filter from raw pattern strings. The patterns are copied; the caller keeps the
    /// originals. An empty slice compiles to an empty list (pass-all).
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

test "empty filter passes everything" {
    const f = Filter{ .include = &[_]Pattern{}, .exclude = &[_]Pattern{} };
    try std.testing.expect(f.matches("anything.txt"));
    try std.testing.expect(f.isPassAll());
}

test "include only: matching names pass" {
    const f = try Filter.compile(std.testing.allocator, &[_][]const u8{"*.md"}, &[_][]const u8{});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("README.md"));
    try std.testing.expect(f.matches("docs/guide.md"));
    try std.testing.expect(!f.matches("src/main.zig"));
    try std.testing.expect(!f.matches("README.txt"));
}

test "exclude wins over include" {
    const f = try Filter.compile(std.testing.allocator, &[_][]const u8{"*.md"}, &[_][]const u8{"draft*"});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("README.md"));
    try std.testing.expect(!f.matches("draft-notes.md"));
}

test "anchored pattern matches the whole path" {
    const f = try Filter.compile(std.testing.allocator, &[_][]const u8{"docs/*.md"}, &[_][]const u8{});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("docs/guide.md"));
    try std.testing.expect(!f.matches("other/docs/guide.md"));
    try std.testing.expect(!f.matches("guide.md"));
}

test "basename pattern matches at any depth" {
    const f = try Filter.compile(std.testing.allocator, &[_][]const u8{"*.zig"}, &[_][]const u8{});
    defer f.deinit(std.testing.allocator);
    try std.testing.expect(f.matches("main.zig"));
    try std.testing.expect(f.matches("src/deep/main.zig"));
    try std.testing.expect(!f.matches("main.zig.bak"));
}
