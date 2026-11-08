// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `.fs-meta/build.json` — the stage declarations of a workspace.
//!
//! Each stage owns one or more **output folders**. The folders are workspace-relative, disjoint across stages and
//! hidden from the root walk; a stage state lists and hashes only the files below them
//! (`plans/build-artifacts.md` § 7). This module is the one parser and the one validator: the daemon, the CLI and
//! the tests all read the same `Config`.

const std = @import("std");
const format = @import("format.zig");
const json = @import("json_doc.zig");
const scan = @import("scan.zig");
const safe_dir = @import("safe_dir.zig");

pub const file_name = "build.json";

/// The protocol's stage limit. A stage is a small chain, not a namespace; the daemon's pump walks it in order.
pub const max_stage: u16 = 64;

pub const HashMode = scan.HashMode;

pub const Stage = struct {
    /// The stage number, `0..max_stage`.
    number: u16,
    /// Normalised workspace-relative folders, no trailing slash, in declaration order.
    folders: []const []const u8,
    hash_mode: HashMode,
    /// Hash of `(stage, hash_mode, folders)`. A stage state with a different hash is a cold scan.
    config_hash: u64,
};

pub const Config = struct {
    stages: []const Stage,
    /// Every declared folder, for the root walk's exclusion rule.
    folders: []const []const u8,

    pub fn empty() Config {
        return .{ .stages = &.{}, .folders = &.{} };
    }

    pub fn find(self: Config, number: u16) ?Stage {
        for (self.stages) |stage| {
            if (stage.number == number) return stage;
        }
        return null;
    }

    /// The stage that declares `path` (a workspace-relative file or directory), or `null`.
    pub fn stageOf(self: Config, path: []const u8) ?Stage {
        var best: ?Stage = null;
        var best_len: usize = 0;
        for (self.stages) |stage| {
            for (stage.folders) |folder| {
                if (!isUnderOrEqual(path, folder)) continue;
                if (best == null or folder.len > best_len) {
                    best = stage;
                    best_len = folder.len;
                }
            }
        }
        return best;
    }
};

pub const LoadError = error{
    BuildConfigNotObject,
    BuildConfigVersion,
    BuildConfigStages,
    BuildConfigStage,
    BuildConfigStageRange,
    BuildConfigFolders,
    BuildConfigFolder,
    BuildConfigOverlap,
    BuildConfigHash,
};

/// Read `<root>/.fs-meta/build.json`; a missing file is an empty configuration, not an error.
pub fn load(arena: std.mem.Allocator, io: std.Io, root: []const u8) !Config {
    var root_dir = if (std.fs.path.isAbsolute(root))
        try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    var meta = (try safe_dir.openExistingDirectory(io, root_dir, format.directory_name, .{ .iterate = true })) orelse return Config.empty();
    defer meta.close(io);
    const bytes = meta.readFileAlloc(io, file_name, arena, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return Config.empty(),
        else => return err,
    };
    return parse(arena, bytes);
}

/// Parse and validate a document. The caller owns `bytes` only for the duration of the call; every string in the
/// result is allocated from `arena`.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Config {
    var parsed = json.parse(arena, bytes) catch return error.BuildConfigNotObject;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BuildConfigNotObject;
    const object = &parsed.value.object;
    const version = json.optionalInt(object, "version") orelse 1;
    if (version != 1) return error.BuildConfigVersion;
    const stages_value = object.get("stages") orelse return error.BuildConfigStages;
    if (stages_value != .array) return error.BuildConfigStages;

    var stages: std.ArrayListUnmanaged(Stage) = .empty;
    errdefer stages.deinit(arena);
    var all_folders: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer all_folders.deinit(arena);

    for (stages_value.array.items) |item| {
        if (item != .object) return error.BuildConfigStage;
        const stage_object = &item.object;
        const number = json.optionalInt(stage_object, "stage") orelse return error.BuildConfigStage;
        if (number > max_stage) return error.BuildConfigStageRange;
        const stage_number: u16 = @intCast(number);
        const folders_value = stage_object.get("folders") orelse return error.BuildConfigFolders;
        if (folders_value != .array) return error.BuildConfigFolders;

        var folders: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer folders.deinit(arena);
        for (folders_value.array.items) |folder_value| {
            if (folder_value != .string) return error.BuildConfigFolder;
            const normalized = try normalizeFolder(arena, folder_value.string) orelse return error.BuildConfigFolder;
            var duplicate = false;
            for (folders.items) |existing| {
                if (std.mem.eql(u8, existing, normalized)) duplicate = true;
            }
            if (!duplicate) try folders.append(arena, normalized);
        }
        if (folders.items.len == 0) return error.BuildConfigFolders;

        const hash_mode = if (json.optionalString(stage_object, "hash")) |raw|
            parseHashMode(raw) orelse return error.BuildConfigHash
        else
            HashMode.text;

        const owned_folders = try folders.toOwnedSlice(arena);
        const config_hash = hashStage(stage_number, hash_mode, owned_folders);
        try stages.append(arena, .{
            .number = stage_number,
            .folders = owned_folders,
            .hash_mode = hash_mode,
            .config_hash = config_hash,
        });
        for (owned_folders) |folder| try all_folders.append(arena, folder);
    }

    // One stage per number, and no folder may belong to two stages. A stage with two output folders is fine; an
    // artifact with two producers is not, because its invalidation rule would be ambiguous.
    for (stages.items, 0..) |left, left_index| {
        for (stages.items[left_index + 1 ..]) |right| {
            if (left.number == right.number) return error.BuildConfigStage;
            for (left.folders) |left_folder| {
                for (right.folders) |right_folder| {
                    if (overlaps(left_folder, right_folder)) return error.BuildConfigOverlap;
                }
            }
        }
    }

    return .{
        .stages = try stages.toOwnedSlice(arena),
        .folders = try all_folders.toOwnedSlice(arena),
    };
}

fn parseHashMode(raw: []const u8) ?HashMode {
    if (std.mem.eql(u8, raw, "none")) return .none;
    if (std.mem.eql(u8, raw, "lf")) return .lf;
    if (std.mem.eql(u8, raw, "text")) return .text;
    return null;
}

/// Normalise one workspace-relative folder: no leading/trailing slash, no `.`/`..` segment, no reserved names,
/// and a name the trio can store. Returns `null` for a path that is not a folder.
fn normalizeFolder(arena: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (raw.len == 0) return null;
    if (std.fs.path.isAbsolute(raw)) return null;
    var text = std.mem.trim(u8, raw, "/");
    while (std.mem.startsWith(u8, text, "./")) text = text[2..];
    text = std.mem.trimEnd(u8, text, "/");
    if (text.len == 0) return null;
    var segments = std.mem.splitScalar(u8, text, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return null;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
        if (std.mem.eql(u8, segment, ".git") or std.mem.eql(u8, segment, ".fs-meta")) return null;
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) return null;
    }
    if (!format.nameValid(text)) return null;
    return try arena.dupe(u8, text);
}

fn isUnderOrEqual(path: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

fn overlaps(left: []const u8, right: []const u8) bool {
    return isUnderOrEqual(left, right) or isUnderOrEqual(right, left);
}

fn hashStage(number: u16, mode: HashMode, folders: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var number_buffer: [2]u8 = undefined;
    std.mem.writeInt(u16, &number_buffer, number, .little);
    hasher.update(&number_buffer);
    hasher.update(@tagName(mode));
    for (folders) |folder| {
        hasher.update(&[_]u8{0});
        hasher.update(folder);
    }
    return hasher.final();
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn testConfig(arena_state: *std.heap.ArenaAllocator, text: []const u8) !Config {
    return parse(arena_state.allocator(), text);
}

test "the documented build.json parses into stages and folders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const config = try testConfig(&arena_state,
        \\{
        \\  "version": 1,
        \\  "stages": [
        \\    { "stage": 0, "folders": ["build/classes/", "build/generated/"], "hash": "text" },
        \\    { "stage": 1, "folders": ["build/libs/"] },
        \\    { "stage": 2, "folders": ["dist/"] }
        \\  ]
        \\}
    );
    try testing.expectEqual(@as(usize, 3), config.stages.len);
    try testing.expectEqual(@as(u16, 0), config.stages[0].number);
    try testing.expectEqualStrings("build/classes", config.stages[0].folders[0]);
    try testing.expectEqualStrings("build/generated", config.stages[0].folders[1]);
    try testing.expectEqual(HashMode.text, config.stages[0].hash_mode);
    try testing.expectEqual(HashMode.text, config.stages[1].hash_mode);
    try testing.expectEqual(@as(usize, 4), config.folders.len);
    try testing.expect(config.stageOf("build/classes/A.class") != null);
    try testing.expectEqual(@as(u16, 1), config.stageOf("build/libs/app.jar").?.number);
    try testing.expect(config.stageOf("src/main.zig") == null);
}

test "a missing build.json is an empty configuration, not an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const config = try testConfig(&arena_state, "{\"version\":1,\"stages\":[]}");
    try testing.expectEqual(@as(usize, 0), config.stages.len);
}

test "build.json refuses absolute, escaping, reserved and overlapping folders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cases = [_][]const u8{
        \\{"stages":[{"stage":0,"folders":["/abs"]}]}
        ,
        \\{"stages":[{"stage":0,"folders":["../out"]}]}
        ,
        \\{"stages":[{"stage":0,"folders":[".git/objects"]}]}
        ,
        \\{"stages":[{"stage":0,"folders":[".fs-meta/cache"]}]}
        ,
        \\{"stages":[{"stage":0,"folders":["build"]},{"stage":1,"folders":["build/classes"]}]}
        ,
        \\{"stages":[{"stage":0,"folders":["build"]},{"stage":0,"folders":["dist"]}]}
        ,
        \\{"stages":[{"stage":65,"folders":["dist"]}]}
        ,
        \\{"stages":[{"stage":0,"folders":[]}]}
        ,
        \\{"stages":[{"stage":0,"folders":["dist"],"hash":"sha1"}]}
    };
    for (cases) |text| {
        if (testConfig(&arena_state, text)) |_| {
            return error.TestUnexpectedSuccess;
        } else |_| {}
    }
}

test "a stage's configHash changes when its folders or hash mode change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const first = try testConfig(&arena_state,
        \\{"stages":[{"stage":0,"folders":["build/classes"],"hash":"text"}]}
    );
    const same = try testConfig(&arena_state,
        \\{"stages":[{"stage":0,"folders":["build/classes/"],"hash":"text"}]}
    );
    const changed = try testConfig(&arena_state,
        \\{"stages":[{"stage":0,"folders":["build/classes"],"hash":"lf"}]}
    );
    try testing.expectEqual(first.stages[0].config_hash, same.stages[0].config_hash);
    try testing.expect(first.stages[0].config_hash != changed.stages[0].config_hash);
}
