// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The tree walk behind a trio: every regular file, directory and symlink under a root, with the facts
//! `FORMAT.md` § 5 stores for them.
//!
//! What is listed is § 16's answer and only that:
//!
//! * regular files, directories **and symlinks**. A symlink is listed as `SYMLINK` and never followed: every
//!   `statFile` here asks for `follow_symlinks = false`, so the mtime and file identity are the link's own.
//! * `.git` and `.fs-meta` are never listed, and no excluded directory is entered.
//! * a `.gitignore` in any directory applies to everything below it. The walk keeps a stack of parsed files,
//!   asks the deepest one with an opinion, and prunes an excluded directory instead of descending into it —
//!   which is also why a `!` pattern below an excluded directory can never resurrect anything (git's rule).
//!
//! Hashing follows § 12: `wyhash64`, seed 0, over the raw bytes (`none`), over LF-normalised bytes (`lf`), or
//! over normalised bytes unless the file contains a NUL (`text`). The normalisation is streamed, so a large
//! file is never held in memory; the raw and normalised hashes are both accumulated in one pass and `text`
//! picks one at the end.
//!
//! ## File identity, and the platform split
//!
//! `fileIdLo/Hi` is `{ ino, dev }` on POSIX and `{ FileIndex, VolumeSerialNumber }` on Windows (§ 5). Zig
//! 0.17's `std.Io.File.Stat` carries the inode but **not** the device, so the pair is fetched by a separate
//! call per entry. Both platforms return `0, 0` — the format's legal "unknown" — when the platform (or the
//! filesystem, or the caller's permissions) cannot provide it; a failed identity never fails the scan.
//!
//! * **Windows** opens the entry with `follow_symlinks = false` (which is `OPEN_REPARSE_POINT`) and
//!   `allow_directory = true` (which gives a backup-semantics handle), then asks
//!   `GetFileInformationByHandle` for `dwVolumeSerialNumber` and `nFileIndexHigh/Low`. Those are exactly the
//!   two numbers `FORMAT.md` names. (`std.os.windows.kernel32` no longer declares the function in 0.17, so
//!   the `extern` binding and its struct live at the bottom of this file.)
//! * **Linux** has no `st_dev` in Zig's `Io.File.Stat` and no public `std.posix.fstatat`, so the walk calls
//!   `statx` directly — the same call the std `Io` implementation makes — with `AT_SYMLINK_NOFOLLOW`. `ino`
//!   is `fileIdLo`; `fileIdHi` is the device's major/minor packed as `(major << 32) | minor`, which is a
//!   stable identity even though it is not glibc's `makedev` encoding.
//! * **Other POSIX** use `fstatat` with `AT_SYMLINK_NOFOLLOW` and store `st_ino` / `st_dev` directly, when
//!   libc is linked; without libc those targets return `0, 0`.
//! * **Anything else** (WASI, …) returns `0, 0`.

const std = @import("std");
const builtin = @import("builtin");

const format = @import("format.zig");
const gitignore = @import("gitignore.zig");
const boundary_mod = @import("boundary.zig");
const ignores = @import("ignores.zig");

pub const HashMode = enum { none, lf, text };

pub const Options = struct {
    hash_mode: HashMode = .text,
    respect_gitignore: bool = true,
    /// Directory names that are never listed and never entered. `.git` and `.fs-meta` are also skipped
    /// unconditionally, because § 16 makes that a rule of the format rather than a caller's choice.
    ignored_dir_names: []const []const u8 = &.{ ".git", ".fs-meta" },
};

/// One entry of a snapshot, before it becomes a 64-byte `format.Entry`.
pub const Fact = struct {
    /// Relative to the scan root, `/`-separated, no trailing slash, owned by the caller's arena (§ 3).
    name: []const u8,
    kind: format.Kind,
    /// ns since the unix epoch; 0 = unknown.
    mtime_ns: u64,
    /// File length; 0 for directories and symlinks.
    size_bytes: u64,
    /// wyhash of the content (§ 12); 0 for directories and symlinks.
    content_hash: u64,
    /// The hash was taken over LF-normalised bytes.
    hash_lf: bool,
    /// `{ ino, dev }` on POSIX, `{ FileIndex, VolumeSerialNumber }` on Windows; `0, 0` = unknown.
    file_id_lo: u64,
    file_id_hi: u64,
};

/// One directory the walk did not enter, with the answer to "why": an ignore source's name, `boundary`, or
/// `reserved` (a name the format reserves or the caller configured). `path` is workspace-relative.
pub const Pruned = struct { path: []const u8, source: []const u8 };

/// `scan` plus the things a writer may want to report but the trio does not store.
pub const Result = struct {
    facts: []Fact,
    /// Nested repositories the walk refused to cross (`plans/worktrees.md` § 4). Empty when there are none.
    boundaries: []const boundary_mod.Boundary,
    /// Every directory that was pruned rather than entered, with the deciding source (§ 5g). The `ignored`
    /// diagnostic prints this; the trio records only the sources that were in effect, in `ignore_sources`.
    pruned: []const Pruned,
    /// The root-level ignore sources actually in effect, in precedence order (`scan.ignoreSources`).
    ignore_sources: []const []const u8,
    /// Names skipped because they are not valid `FORMAT.md` § 3 names (a newline, a backslash, invalid
    /// UTF-8, ...). The format requires them to be absent; being silent about *why* a file is missing would
    /// make the trio a wrong answer rather than an incomplete one.
    skipped_names: usize,
};

/// Walks `root_path` and returns the facts in `format.compareNames` order. Everything allocated — the names
/// and the returned slice — belongs to `arena`; there is no separate `deinit`. The order is unsigned byte
/// order, so a reader can binary-search the result.
pub fn scan(arena: std.mem.Allocator, io: std.Io, root_path: []const u8, options: Options) ![]Fact {
    return (try scanDetailed(arena, io, root_path, options)).facts;
}

/// `scan`, plus the count of names the walk had to skip. Same allocation contract.
pub fn scanDetailed(arena: std.mem.Allocator, io: std.Io, root_path: []const u8, options: Options) !Result {
    // The two root-level sources are re-read here, on every walk: no cache and no mtime (`plans/worktrees.md` § 5b).
    var sources = try ignores.Sources.load(arena, io, root_path, options.respect_gitignore);
    defer sources.deinit();
    var walker = Walker{ .arena = arena, .io = io, .options = options, .sources = &sources };
    // Every frame is popped by `walkDir`, but the stack's own buffer still needs releasing (a no-op under
    // the arena this API asks for, a real free under any other allocator).
    defer walker.ignore_stack.deinit(arena);
    defer walker.pruned.deinit(arena);
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);

    try walker.walkDir(root, "");
    const facts = try walker.facts.toOwnedSlice(arena);
    std.mem.sort(Fact, facts, {}, lessThanFact);
    return .{
        .facts = facts,
        .boundaries = try walker.boundaries.toOwnedSlice(arena),
        .pruned = try walker.pruned.toOwnedSlice(arena),
        .ignore_sources = sources.active,
        .skipped_names = walker.skipped_names,
    };
}

fn lessThanFact(_: void, left: Fact, right: Fact) bool {
    return format.compareNames(left.name, right.name) == .lt;
}

/// Names the format reserves whatever `Options.ignored_dir_names` says.
const reserved_names = [_][]const u8{ ".git", ".fs-meta" };

const IgnoreFrame = struct {
    /// Length of the directory path this `.gitignore` lives in, relative to the scan root (`0` at the root).
    /// The scoped path handed to the matcher is the entry path with this prefix and its `/` removed.
    dir_len: usize,
    rules: gitignore.Rules,
};

const Walker = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
    sources: *ignores.Sources,
    facts: std.ArrayList(Fact) = .empty,
    boundaries: std.ArrayList(boundary_mod.Boundary) = .empty,
    pruned: std.ArrayList(Pruned) = .empty,
    skipped_names: usize = 0,
    ignore_stack: std.ArrayList(IgnoreFrame) = .empty,

    fn walkDir(self: *Walker, dir: std.Io.Dir, rel_dir: []const u8) !void {
        // A directory's own .gitignore governs its contents and never the directory itself, so it is read
        // (and pushed) after the caller has decided to enter this directory.
        var pushed = false;
        if (self.options.respect_gitignore) {
            if (try readRules(self.arena, self.io, dir)) |rules| {
                try self.ignore_stack.append(self.arena, .{ .dir_len = rel_dir.len, .rules = rules });
                pushed = true;
            }
        }
        defer if (pushed) {
            var frame = self.ignore_stack.pop().?;
            frame.rules.deinit();
        };

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            const name = entry.name;

            // § 16: these two names are never listed, whatever the options say. A symlink or file with
            // one of these names is skipped too, not just a directory. A reserved *directory* is a prune with
            // no pattern source, which `fsmeta ignored` reports as such.
            if (isReservedName(name)) {
                const stat = dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch continue;
                if (stat.kind == .directory) {
                    try self.pruned.append(self.arena, .{
                        .path = try self.relName(rel_dir, name),
                        .source = "reserved",
                    });
                }
                continue;
            }

            const stat = try dir.statFile(self.io, name, .{ .follow_symlinks = false });
            const kind = factKind(stat.kind) orelse continue;

            const rel_name = try self.relName(rel_dir, name);

            // Extra configured names apply to directories only: the option is a *directory* name list.
            if (kind == .dir and self.isIgnoredDirName(name)) {
                try self.pruned.append(self.arena, .{ .path = rel_name, .source = "reserved" });
                continue;
            }

            if (!format.nameValid(rel_name)) {
                // A name the format cannot store: a newline, a backslash, invalid UTF-8, ... The walk must
                // not list it, and must not descend into it either (a directory with such a name would
                // otherwise leak its children into the snapshot).
                self.skipped_names += 1;
                continue;
            }

            // The boundary rule (`plans/worktrees.md` § 4): a directory whose `.git` entry confirms is another
            // repository and is neither listed nor entered. Checked before `.gitignore` so a nested clone that
            // is also ignored is still *reported* as the reason it is absent.
            if (kind == .dir) {
                const nested = boundary_mod.confirm(self.arena, self.io, dir, name);
                if (nested != .none) {
                    try self.boundaries.append(self.arena, .{ .path = rel_name, .kind = nested });
                    try self.pruned.append(self.arena, .{ .path = rel_name, .source = "boundary" });
                    continue;
                }
            }

            if (self.ignoreSource(rel_name, kind == .dir)) |source| {
                if (kind == .dir) try self.pruned.append(self.arena, .{ .path = rel_name, .source = source });
                continue;
            }

            var fact = Fact{
                .name = rel_name,
                .kind = kind,
                .mtime_ns = mtimeNs(stat.mtime),
                .size_bytes = 0,
                .content_hash = 0,
                .hash_lf = false,
                .file_id_lo = 0,
                .file_id_hi = 0,
            };

            const id = fileIdAt(dir, self.io, name);
            fact.file_id_lo = id.lo;
            fact.file_id_hi = id.hi;

            switch (kind) {
                .regular_file => {
                    fact.size_bytes = stat.size;
                    const hashed = try hashFile(self.io, dir, name, self.options.hash_mode);
                    fact.content_hash = hashed.hash;
                    fact.hash_lf = hashed.hash_lf;
                },
                // § 5/§ 6: a directory's and a symlink's size and content hash are 0. The symlink's mtime
                // and identity above are the link's own because every stat was an lstat.
                .dir, .symlink => {},
            }

            try self.facts.append(self.arena, fact);

            if (kind == .dir) {
                var child = try dir.openDir(self.io, name, .{ .iterate = true });
                defer child.close(self.io);
                try self.walkDir(child, rel_name);
            }
        }
    }

    fn relName(self: *Walker, rel_dir: []const u8, name: []const u8) ![]const u8 {
        if (rel_dir.len == 0) return self.arena.dupe(u8, name);
        return std.fmt.allocPrint(self.arena, "{s}/{s}", .{ rel_dir, name });
    }

    fn isIgnoredDirName(self: *Walker, name: []const u8) bool {
        for (self.options.ignored_dir_names) |ignored| {
            if (std.mem.eql(u8, name, ignored)) return true;
        }
        return false;
    }

    /// The four-source chain of § 5: the `.gitignore` stack, then `info/exclude`, then `.fs-meta/ignore` (whose
    /// managed block is evaluated last inside the source). The first source that excludes wins, and a later `!` is
    /// never asked — that is the no-cross-source negation rule. A source's own negation still works: the chain's
    /// stack returns `false` when the deepest file re-includes, and `Sources` does the same for its file.
    fn ignoreSource(self: *Walker, rel_name: []const u8, is_dir: bool) ?[]const u8 {
        if (self.options.respect_gitignore) {
            if (self.chainDecision(rel_name, is_dir)) |excluded| {
                if (excluded) return ignores.Source.gitignore.name();
            }
        }
        if (self.sources.decide(rel_name, is_dir)) |source| return source.name();
        return null;
    }

    /// The decision of the deepest applicable `.gitignore` that has one, or "no opinion" when none has.
    fn chainDecision(self: *Walker, rel_name: []const u8, is_dir: bool) ?bool {
        var index = self.ignore_stack.items.len;
        while (index > 0) {
            index -= 1;
            const frame = self.ignore_stack.items[index];
            const scoped = if (frame.dir_len == 0)
                rel_name
            else
                rel_name[frame.dir_len + 1 ..]; // skip the `.gitignore` directory and its '/'
            if (frame.rules.decide(scoped, is_dir)) |decision| return decision;
        }
        return null;
    }
};

fn isReservedName(name: []const u8) bool {
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

/// § 6's type bits, from the file system's kind. Anything that is neither a regular file, a directory nor a
/// symlink (a device, a pipe, a socket) is not part of a snapshot and is skipped silently.
fn factKind(kind: std.Io.File.Kind) ?format.Kind {
    return switch (kind) {
        .file => .regular_file,
        .directory => .dir,
        .sym_link => .symlink,
        else => null,
    };
}

/// § 5: `mtimeNs` is unsigned nanoseconds since the epoch, and `0` means unknown (a negative timestamp is
/// before 1970 and therefore "unknown" rather than a huge unsigned value).
fn mtimeNs(timestamp: std.Io.Timestamp) u64 {
    return std.math.cast(u64, timestamp.nanoseconds) orelse 0;
}

// ---------------------------------------------------------------------------------------------------------------
// .gitignore reading — one file per directory, consulted deepest-first by the walk
// ---------------------------------------------------------------------------------------------------------------

/// The parsed `.gitignore` in `dir`, or `null` when the directory has none. A directory named `.gitignore` is
/// not a file to read; it is listed by the walk like any other directory.
fn readRules(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?gitignore.Rules {
    const file = dir.openFile(io, gitignore.file_name, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return null,
        else => return err,
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const text = try reader.interface.allocRemaining(arena, .unlimited);
    return try gitignore.Rules.parse(arena, text);
}

// ---------------------------------------------------------------------------------------------------------------
// Hashing (§ 12) — one streaming pass per regular file
// ---------------------------------------------------------------------------------------------------------------

pub const Hashed = struct {
    hash: u64,
    hash_lf: bool,
};

/// Reads one regular file and hashes it as `mode` says. The file is streamed: normalisation is a byte-level
/// transform (`\r\n` -> `\n`, lone `\r` -> `\n`), so no whole-file buffer is needed, and `text` can decide
/// between the raw and the normalised hash only after it has seen whether the file contains a NUL.
/// Hash one file by its whole path, as the engine passes it. Splitting the path here keeps one hashing
/// implementation for the walker and for the pass.
pub fn hashFileAt(io: std.Io, path: []const u8, mode: HashMode) !Hashed {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    if (base.len == 0) return error.FileNotFound;
    var dir = if (std.fs.path.isAbsolute(parent))
        try std.Io.Dir.openDirAbsolute(io, parent, .{})
    else
        try std.Io.Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);
    return hashFile(io, dir, base, mode);
}

fn hashFile(io: std.Io, dir: std.Io.Dir, name: []const u8, mode: HashMode) !Hashed {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var state = Hashing{};
    switch (mode) {
        .none => state.raw = std.hash.Wyhash.init(format.hash_seed),
        .lf => state.normalized = std.hash.Wyhash.init(format.hash_seed),
        .text => {
            state.raw = std.hash.Wyhash.init(format.hash_seed);
            state.normalized = std.hash.Wyhash.init(format.hash_seed);
            state.detect_nul = true;
        },
    }

    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        state.feed(buffer[0..count]);
    }

    return switch (mode) {
        .none => .{ .hash = state.raw.?.final(), .hash_lf = false },
        .lf => .{ .hash = state.normalized.?.final(), .hash_lf = true },
        .text => if (state.has_nul)
            .{ .hash = state.raw.?.final(), .hash_lf = false }
        else
            .{ .hash = state.normalized.?.final(), .hash_lf = true },
    };
}

/// One streaming pass over the file's bytes, feeding whichever hashes the mode needs.
const Hashing = struct {
    raw: ?std.hash.Wyhash = null,
    normalized: ?std.hash.Wyhash = null,
    detect_nul: bool = false,
    has_nul: bool = false,
    /// The previous chunk ended with `\r`: it already emitted `\n`, so a `\n` at the start of the next chunk
    /// is the second half of a `\r\n` and must be skipped. This is the one piece of state normalisation
    /// needs across a chunk boundary.
    pending_cr: bool = false,

    fn feed(self: *Hashing, chunk: []const u8) void {
        if (self.raw) |*raw| raw.update(chunk);
        if (self.detect_nul and std.mem.indexOfScalar(u8, chunk, 0) != null) self.has_nul = true;

        const normalized = if (self.normalized) |*hash| hash else return;
        var index: usize = 0;
        if (self.pending_cr) {
            self.pending_cr = false;
            if (chunk.len > 0 and chunk[0] == '\n') index = 1;
        }
        while (index < chunk.len) {
            const start = index;
            if (std.mem.indexOfScalarPos(u8, chunk, index, '\r')) |cr| {
                if (cr > start) normalized.update(chunk[start..cr]);
                normalized.update("\n");
                index = cr + 1;
                if (index < chunk.len) {
                    if (chunk[index] == '\n') index += 1;
                } else {
                    // The `\r` was the chunk's last byte; the next chunk has to swallow a leading `\n`.
                    self.pending_cr = true;
                }
            } else {
                normalized.update(chunk[start..]);
                index = chunk.len;
            }
        }
    }
};

// ---------------------------------------------------------------------------------------------------------------
// File identity (§ 5), per platform — the one part whose implementation is OS-specific
// ---------------------------------------------------------------------------------------------------------------

/// The identity the format asks for: inode/dev on POSIX, FileIndex/VolumeSerialNumber on Windows. Shared
/// with the engine lister so there is one binding per platform.
pub const FileId = struct { lo: u64, hi: u64 };

const unknown_file_id = FileId{ .lo = 0, .hi = 0 };

/// The `{ lo, hi }` pair for one entry. Never fails: a platform or filesystem that cannot answer returns the
/// legal "unknown" pair instead.
pub fn fileIdAt(dir: std.Io.Dir, io: std.Io, name: []const u8) FileId {
    return switch (builtin.os.tag) {
        .windows => fileIdWindows(dir, io, name),
        .linux => fileIdLinux(dir, name),
        .wasi => unknown_file_id,
        // `std.posix.Stat` and `fstatat` exist for a non-Linux POSIX target only when libc is linked;
        // without it the platform simply cannot answer, which the format allows.
        else => if (builtin.link_libc) fileIdPosix(dir, name) else unknown_file_id,
    };
}

/// Windows: `dwVolumeSerialNumber` is the high word (the "device") and `nFileIndexHigh/Low` combine into the
/// low word (the "inode"), exactly as § 5 lists.
fn fileIdWindows(dir: std.Io.Dir, io: std.Io, name: []const u8) FileId {
    // `follow_symlinks = false` becomes NtCreateFile's OPEN_REPARSE_POINT, and `allow_directory = true`
    // becomes a backup-semantics handle, so this opens the link (not its target) and works for directories.
    const file = dir.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = true }) catch
        return unknown_file_id;
    defer file.close(io);

    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (!GetFileInformationByHandle(file.handle, &info).toBool()) return unknown_file_id;

    return .{
        .lo = (@as(u64, info.nFileIndexHigh) << 32) | @as(u64, info.nFileIndexLow),
        .hi = info.dwVolumeSerialNumber,
    };
}

/// Linux: `statx` with `AT_SYMLINK_NOFOLLOW`, because 0.17's `Io.File.Stat` drops the device and the public
/// `std.posix` surface has no `Stat` on Linux.
fn fileIdLinux(dir: std.Io.Dir, name: []const u8) FileId {
    const linux = std.os.linux;
    var name_buffer: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    const name_z = std.mem.printSentinel(&name_buffer, "{s}", .{name}, 0) catch return unknown_file_id;

    var statx: linux.Statx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(
        dir.handle,
        name_z.ptr,
        linux.AT.SYMLINK_NOFOLLOW | linux.AT.NO_AUTOMOUNT,
        linux.STATX.BASIC_STATS,
        &statx,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return unknown_file_id,
    }

    // `statx` reports the device as major/minor, not as `st_dev`. Pack them into one stable value: every
    // entry this walk emits uses the same encoding, which is all rename detection needs.
    return .{
        .lo = statx.ino,
        .hi = (@as(u64, statx.dev_major) << 32) | @as(u64, statx.dev_minor),
    };
}

/// The POSIX `fstatat` case: `st_ino` is the low word, `st_dev` the high word.
fn fileIdPosix(dir: std.Io.Dir, name: []const u8) FileId {
    var name_buffer: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    const name_z = std.mem.printSentinel(&name_buffer, "{s}", .{name}, 0) catch return unknown_file_id;

    var stat: std.posix.Stat = undefined;
    const rc = std.posix.system.fstatat(dir.handle, name_z.ptr, &stat, std.posix.AT.SYMLINK_NOFOLLOW);
    if (std.posix.errno(rc) != .SUCCESS) return unknown_file_id;

    return .{ .lo = @intCast(stat.ino), .hi = @intCast(stat.dev) };
}

// Windows' kernel32 binding. `std.os.windows.kernel32` declares only `CreateProcessW` in 0.17, so the one
// function this file needs is declared here; the struct is the documented `BY_HANDLE_FILE_INFORMATION`.
const windows = std.os.windows;

const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: windows.DWORD,
    ftCreationTime: windows.FILETIME,
    ftLastAccessTime: windows.FILETIME,
    ftLastWriteTime: windows.FILETIME,
    dwVolumeSerialNumber: windows.DWORD,
    nFileSizeHigh: windows.DWORD,
    nFileSizeLow: windows.DWORD,
    nNumberOfLinks: windows.DWORD,
    nFileIndexHigh: windows.DWORD,
    nFileIndexLow: windows.DWORD,
};

extern "kernel32" fn GetFileInformationByHandle(
    hFile: windows.HANDLE,
    lpFileInformation: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) windows.BOOL;

// ---------------------------------------------------------------------------------------------------------------
// Tests — hermetic temp trees only; nothing here reads a repository file
// ---------------------------------------------------------------------------------------------------------------

const testing = std.testing;

const TestArena = struct {
    state: std.heap.ArenaAllocator,

    fn init() TestArena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestArena) void {
        self.state.deinit();
    }

    fn allocator(self: *TestArena) std.mem.Allocator {
        return self.state.allocator();
    }
};

/// The absolute path of a `tmpDir` handle, so `scan` (which takes a path) can walk the tree the test built.
fn tmpRoot(io: std.Io, dir: std.Io.Dir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const count = try dir.realPath(io, buffer);
    return buffer[0..count];
}

fn findFact(facts: []const Fact, name: []const u8) ?Fact {
    for (facts) |fact| {
        if (std.mem.eql(u8, fact.name, name)) return fact;
    }
    return null;
}

fn expectNames(facts: []const Fact, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, facts.len);
    for (expected, facts) |wanted, actual| {
        try testing.expectEqualStrings(wanted, actual.name);
    }
}

fn findPruned(result: Result, path: []const u8) ?Pruned {
    for (result.pruned) |pruned| {
        if (std.mem.eql(u8, pruned.path, path)) return pruned;
    }
    return null;
}

fn writeTestFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(name) orelse ".");
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "names are sorted by bytes, and files, directories and file identities are recorded" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, "sub/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/c.txt", .data = "c" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep/d.txt", .data = "d" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{});
    try expectNames(facts, &.{
        "a.txt",
        "b.txt",
        "empty",
        "sub",
        "sub/c.txt",
        "sub/deep",
        "sub/deep/d.txt",
    });

    const a = findFact(facts, "a.txt").?;
    try testing.expectEqual(format.Kind.regular_file, a.kind);
    try testing.expectEqual(@as(u64, 1), a.size_bytes);
    try testing.expect(a.mtime_ns != 0);
    try testing.expectEqual(format.wyhash("a"), a.content_hash);
    try testing.expect(a.hash_lf); // .text, no NUL: normalised
    try testing.expect(a.file_id_lo != 0 or a.file_id_hi != 0); // `0, 0` is legal, but NTFS/ext4 answer

    const empty = findFact(facts, "empty").?;
    try testing.expectEqual(format.Kind.dir, empty.kind);
    try testing.expectEqual(@as(u64, 0), empty.size_bytes);
    try testing.expectEqual(@as(u64, 0), empty.content_hash);
    try testing.expect(!empty.hash_lf);
    try testing.expect(empty.mtime_ns != 0);
    try testing.expect(empty.file_id_lo != 0 or empty.file_id_hi != 0);
}

test "the three hash modes, and a CR/LF pair split across the read buffer" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "crlf.txt", .data = "a\r\nb\r\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lf.txt", .data = "a\nb\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nul.txt", .data = "a\r\nb\x00" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lone-cr.txt", .data = "x\ry" });

    // 64 KiB is the read buffer, so the `\r` is the last byte of the first chunk and the `\n` opens the
    // second: normalisation must carry its pending state across the boundary.
    const edge = try testing.allocator.alloc(u8, 64 * 1024 + 1);
    defer testing.allocator.free(edge);
    @memset(edge[0 .. 64 * 1024], 'a');
    edge[64 * 1024] = '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "edge.txt", .data = edge });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    {
        var arena = TestArena.init();
        defer arena.deinit();
        const facts = try scan(arena.allocator(), io, root, .{ .hash_mode = .text });

        const crlf = findFact(facts, "crlf.txt").?;
        const lf = findFact(facts, "lf.txt").?;
        try testing.expect(crlf.hash_lf and lf.hash_lf);
        try testing.expectEqual(format.wyhash("a\nb\n"), crlf.content_hash);
        try testing.expectEqual(lf.content_hash, crlf.content_hash);

        const nul = findFact(facts, "nul.txt").?;
        try testing.expect(!nul.hash_lf); // a NUL means the file is not text: hashed raw
        try testing.expectEqual(format.wyhash("a\r\nb\x00"), nul.content_hash);

        const lone = findFact(facts, "lone-cr.txt").?;
        try testing.expect(lone.hash_lf);
        try testing.expectEqual(format.wyhash("x\ny"), lone.content_hash);

        var expected = std.hash.Wyhash.init(format.hash_seed);
        expected.update(edge[0 .. 64 * 1024]);
        expected.update("\n");
        try testing.expectEqual(expected.final(), findFact(facts, "edge.txt").?.content_hash);
    }
    {
        var arena = TestArena.init();
        defer arena.deinit();
        const facts = try scan(arena.allocator(), io, root, .{ .hash_mode = .lf });

        const nul = findFact(facts, "nul.txt").?;
        try testing.expect(nul.hash_lf); // `.lf` normalises regardless of a NUL
        try testing.expectEqual(format.wyhash("a\nb\x00"), nul.content_hash);

        const crlf = findFact(facts, "crlf.txt").?;
        try testing.expect(crlf.hash_lf);
        try testing.expectEqual(format.wyhash("a\nb\n"), crlf.content_hash);
    }
    {
        var arena = TestArena.init();
        defer arena.deinit();
        const facts = try scan(arena.allocator(), io, root, .{ .hash_mode = .none });

        const crlf = findFact(facts, "crlf.txt").?;
        try testing.expect(!crlf.hash_lf);
        try testing.expectEqual(format.wyhash("a\r\nb\r\n"), crlf.content_hash);

        const nul = findFact(facts, "nul.txt").?;
        try testing.expect(!nul.hash_lf);
        try testing.expectEqual(format.wyhash("a\r\nb\x00"), nul.content_hash);
    }
}

test ".git and .fs-meta are never listed, and configured directory names are not entered" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "git" });
    try tmp.dir.createDirPath(io, ".fs-meta");
    try tmp.dir.writeFile(io, .{ .sub_path = ".fs-meta/files.txt", .data = "meta" });
    try tmp.dir.createDirPath(io, "skipdir/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "skipdir/nested/x.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{
        .ignored_dir_names = &.{ ".git", ".fs-meta", "skipdir" },
    });
    try expectNames(facts, &.{"a.txt"});
}

test "a root .gitignore is honoured, and is itself listed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n!keep.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "debug.log", .data = "d" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.log", .data = "k" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{});
    try expectNames(facts, &.{ ".gitignore", "a.txt", "keep.log" });
    try testing.expectEqual(format.wyhash("*.log\n!keep.log\n"), findFact(facts, ".gitignore").?.content_hash);
}

test "a nested .gitignore beats the outer one, and only governs its own directory" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.tmp\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.gitignore", .data = "!keep.tmp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root.tmp", .data = "r" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.tmp", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/keep.tmp", .data = "k" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.txt", .data = "b" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{});
    try expectNames(facts, &.{
        ".gitignore",
        "src",
        "src/.gitignore",
        "src/b.txt",
        "src/keep.tmp",
    });
}

test "an excluded directory is not listed and not entered, so a negation inside it cannot re-include" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "build/\n!build/keep.txt\n" });
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = "build/x.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build/keep.txt", .data = "k" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{});
    try expectNames(facts, &.{ ".gitignore", "a.txt" });
}

test "respect_gitignore = false lists everything except the reserved directories" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "build/\n!build/keep.txt\n" });
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = "build/x.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build/keep.txt", .data = "k" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "git" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{ .respect_gitignore = false });
    try expectNames(facts, &.{
        ".gitignore",
        "a.txt",
        "build",
        "build/keep.txt",
        "build/x.txt",
    });
}

test ".fs-meta/ignore excludes a subtree, and deleting the line brings it back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, io, ".fs-meta/ignore", "worktrees/w1/\n");
    try writeTestFile(tmp.dir, io, "worktrees/w1/secret.txt", "s");
    try writeTestFile(tmp.dir, io, "worktrees/w2/keep.txt", "k");
    try writeTestFile(tmp.dir, io, "top.txt", "t");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const first = try scanDetailed(arena.allocator(), io, root, .{});
    try expectNames(first.facts, &.{ "top.txt", "worktrees", "worktrees/w2", "worktrees/w2/keep.txt" });
    const pruned = findPruned(first, "worktrees/w1").?;
    try testing.expectEqualStrings("fs-meta/ignore", pruned.source);

    // A hand edit is visible on the very next walk: the source is re-read, never cached.
    try writeTestFile(tmp.dir, io, ".fs-meta/ignore", "");
    const second = try scanDetailed(arena.allocator(), io, root, .{});
    try testing.expect(findPruned(second, "worktrees/w1") == null);
    try testing.expect(findFact(second.facts, "worktrees/w1/secret.txt") != null);
}

test "info/exclude excludes a subtree, and deleting the line brings it back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, io, ".git/info/exclude", "cache/\n");
    try writeTestFile(tmp.dir, io, "cache/generated.txt", "g");
    try writeTestFile(tmp.dir, io, "keep.txt", "k");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const first = try scanDetailed(arena.allocator(), io, root, .{});
    try expectNames(first.facts, &.{"keep.txt"});
    try testing.expectEqualStrings("info/exclude", findPruned(first, "cache").?.source);

    try writeTestFile(tmp.dir, io, ".git/info/exclude", "");
    const second = try scanDetailed(arena.allocator(), io, root, .{});
    try testing.expect(findFact(second.facts, "cache/generated.txt") != null);
    try testing.expect(findPruned(second, "cache") == null);

    // The list of sources says what was consulted: `info/exclude` stays present because the file still is.
    try testing.expectEqual(@as(usize, 2), second.ignore_sources.len);
    try testing.expectEqualStrings("gitignore", second.ignore_sources[0]);
    try testing.expectEqualStrings("info/exclude", second.ignore_sources[1]);
}

test "a later source cannot re-include an earlier exclusion" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // `.gitignore` excludes; `.fs-meta/ignore`'s `!` must not re-open it.
    try writeTestFile(tmp.dir, io, ".gitignore", "worktrees/w1/\n");
    try writeTestFile(tmp.dir, io, ".fs-meta/ignore", "!worktrees/w1/\n");
    // `info/exclude` excludes; `.fs-meta/ignore`'s `!` must not re-open it either.
    try writeTestFile(tmp.dir, io, ".git/info/exclude", "cache/\n!cache/\n");
    try writeTestFile(tmp.dir, io, "worktrees/w1/secret.txt", "s");
    try writeTestFile(tmp.dir, io, "cache/x.txt", "x");
    try writeTestFile(tmp.dir, io, "keep.txt", "k");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const result = try scanDetailed(arena.allocator(), io, root, .{});
    try testing.expect(findFact(result.facts, "keep.txt") != null);
    try testing.expect(findFact(result.facts, "worktrees/w1/secret.txt") == null);
    try testing.expectEqualStrings("gitignore", findPruned(result, "worktrees/w1").?.source);
    // info/exclude's own `!cache/` cancels its `cache/`, so the later `.fs-meta/ignore` `!` has nothing to override
    // and the directory is listed; this is per-source negation, not cross-source.
    try testing.expect(findFact(result.facts, "cache/x.txt") != null);

    // Now `info/exclude` excludes and `.fs-meta/ignore` negates: the earlier decision stands.
    try writeTestFile(tmp.dir, io, ".git/info/exclude", "cache/\n");
    try writeTestFile(tmp.dir, io, ".fs-meta/ignore", "!cache/\n");
    const second = try scanDetailed(arena.allocator(), io, root, .{});
    try testing.expect(findFact(second.facts, "cache/x.txt") == null);
    try testing.expectEqualStrings("info/exclude", findPruned(second, "cache").?.source);
}

test "--no-gitignore keeps .fs-meta/ignore, and .gitignore/info/exclude are not consulted" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, io, ".gitignore", "a.txt\n");
    try writeTestFile(tmp.dir, io, ".git/info/exclude", "cache/\n");
    try writeTestFile(tmp.dir, io, ".fs-meta/ignore", "worktrees/w1/\n");
    try writeTestFile(tmp.dir, io, "a.txt", "a");
    try writeTestFile(tmp.dir, io, "cache/c.txt", "c");
    try writeTestFile(tmp.dir, io, "worktrees/w1/w.txt", "w");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const result = try scanDetailed(arena.allocator(), io, root, .{ .respect_gitignore = false });
    try testing.expect(findFact(result.facts, "a.txt") != null);
    try testing.expect(findFact(result.facts, "cache/c.txt") != null);
    try testing.expect(findFact(result.facts, "worktrees/w1/w.txt") == null);
    try testing.expectEqual(@as(usize, 1), result.ignore_sources.len);
    try testing.expectEqualStrings("fs-meta/ignore", result.ignore_sources[0]);
}

test "a linked worktree reads info/exclude from its common dir during the walk" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try writeTestFile(tmp.dir, io, "main/.git/info/exclude", "cache/\n");
    try writeTestFile(tmp.dir, io, "main/.git/worktrees/wt/commondir", "../..\n");
    try writeTestFile(tmp.dir, io, "wt/.git", "gitdir: ../main/.git/worktrees/wt\n");
    try writeTestFile(tmp.dir, io, "wt/cache/generated.txt", "g");
    try writeTestFile(tmp.dir, io, "wt/keep.txt", "k");

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();
    const root = try std.fs.path.join(arena.allocator(), &.{ base, "wt" });

    const result = try scanDetailed(arena.allocator(), io, root, .{});
    try testing.expect(findFact(result.facts, "keep.txt") != null);
    try testing.expect(findFact(result.facts, "cache/generated.txt") == null);
    try testing.expectEqualStrings("info/exclude", findPruned(result, "cache").?.source);
}

test "a nested clone is a boundary: its files are absent and the boundary is reported" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "v" });
    try tmp.dir.createDirPath(io, "clone");
    try tmp.dir.createDirPath(io, "clone/.git/objects");
    try tmp.dir.writeFile(io, .{ .sub_path = "clone/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "clone/secret.txt", .data = "s" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const result = try scanDetailed(arena.allocator(), io, root, .{});
    // The boundary directory itself is absent too: a trio describes one tree, and a directory whose contents
    // are all missing would be a half-description.
    try expectNames(result.facts, &.{"visible.txt"});
    try testing.expectEqual(@as(usize, 1), result.boundaries.len);
    try testing.expectEqualStrings("clone", result.boundaries[0].path);
    try testing.expectEqual(boundary_mod.Kind.repo, result.boundaries[0].kind);
}

test "a stray .git directory is entered like any other directory, and is not a boundary" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "fixture/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/.git/notes.txt", .data = "not a repo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture/a.txt", .data = "a" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const result = try scanDetailed(arena.allocator(), io, root, .{});
    try expectNames(result.facts, &.{ "fixture", "fixture/a.txt" });
    try testing.expectEqual(@as(usize, 0), result.boundaries.len);
}

/// A symlink cannot be created without the privilege that creates one: on Windows that is
/// `SeCreateSymbolicLinkPrivilege` (or Developer Mode), and on a restricted POSIX host it is the parent
/// directory's permission or the mount's options. The skip is a platform guard with a printed reason, so a
/// `SKIP` line is never an unexplained absence; the kind mapping itself is covered by
/// `the kind mapping covers all three listed kinds` below.
fn symlinkSkipped(err: anyerror) error{SkipZigTest} {
    std.debug.print(
        "skip: this {s} host refused to create a symbolic link (error.{t}): Windows needs " ++
            "SeCreateSymbolicLinkPrivilege or Developer Mode, so the walk's symlink case needs a host that grants it\n",
        .{ @tagName(builtin.os.tag), err },
    );
    return error.SkipZigTest;
}

test "a symlink is listed as a symlink and never followed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "realdir");
    try tmp.dir.writeFile(io, .{ .sub_path = "realdir/inside.txt", .data = "inside" });

    tmp.dir.symLink(io, "target.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return symlinkSkipped(err),
        else => return err,
    };
    tmp.dir.symLink(io, "realdir", "linkdir", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return symlinkSkipped(err),
        else => return err,
    };

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const facts = try scan(arena.allocator(), io, root, .{});
    try expectNames(facts, &.{
        "link.txt",
        "linkdir",
        "realdir",
        "realdir/inside.txt",
        "target.txt",
    });

    const link = findFact(facts, "link.txt").?;
    try testing.expectEqual(format.Kind.symlink, link.kind);
    try testing.expectEqual(@as(u64, 0), link.size_bytes);
    try testing.expectEqual(@as(u64, 0), link.content_hash);
    try testing.expect(!link.hash_lf);
    try testing.expect(link.mtime_ns != 0); // the link's own, not the target's
    try testing.expect(link.file_id_lo != 0 or link.file_id_hi != 0);

    // The directory link is a symlink too: its children are not visited (only `realdir`'s are listed once).
    try testing.expectEqual(format.Kind.symlink, findFact(facts, "linkdir").?.kind);
    try testing.expect(findFact(facts, "linkdir/inside.txt") == null);
}

test "the kind mapping covers all three listed kinds" {
    try testing.expectEqual(format.Kind.regular_file, factKind(.file).?);
    try testing.expectEqual(format.Kind.dir, factKind(.directory).?);
    try testing.expectEqual(format.Kind.symlink, factKind(.sym_link).?);
    try testing.expect(factKind(.named_pipe) == null);
    try testing.expect(factKind(.unix_domain_socket) == null);
}

test "a name the format cannot store is skipped and counted" {
    if (builtin.os.tag == .windows) {
        // `\` is the path separator here, and Win32/NT reject the control characters and invalid UTF-16 that
        // are the other shapes § 3 forbids, so none of them can be created as a name. The skip is a platform
        // guard with a printed reason rather than a silent pass; POSIX exercises the case below.
        std.debug.print(
            "skip: this {s} host cannot construct a name § 3 forbids (`\\` is the path separator, and Win32/NT " ++
                "reject control characters and invalid UTF-16), so the case is POSIX-only\n",
            .{@tagName(builtin.os.tag)},
        );
        return error.SkipZigTest;
    }

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "a" });
    // A backslash is a legal POSIX filename byte but § 3 forbids it in a stored name. A failure here is a real
    // failure, not a platform skip: on the platforms that run this test the write is expected to succeed.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad\\name", .data = "b" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(io, tmp.dir, &path_buffer);

    var arena = TestArena.init();
    defer arena.deinit();

    const result = try scanDetailed(arena.allocator(), io, root, .{});
    try expectNames(result.facts, &.{"a.txt"});
    try testing.expectEqual(@as(usize, 1), result.skipped_names);
}
