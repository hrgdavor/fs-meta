# `.gitignore` rules, and how the engine is fast

Two parts: **what the matcher implements**, and **every optimisation that makes it cheap**, each with the code that
does it injected from the source. The code blocks are generated — run
`node node_modules/@hrg/inject-examples/cli.mjs` from the repository root, and `--check` in CI, so a sample cannot
drift from the engine.

## Part 1 — the rules

A `.gitignore` is a list of patterns, one per line. The matcher decides one question: *is this path excluded, and if
the answer comes from a pattern high up the tree, is a pattern deeper down allowed to override it?*

### Pattern forms

| Written               | Means                                                                        | Class                               |
| --------------------- | ---------------------------------------------------------------------------- | ----------------------------------- |
| `build`               | any file **or directory** named `build`, at any depth                        | literal                             |
| `build/`              | only a **directory** named `build` (and, by the ancestor rule, its contents) | literal, directory-only             |
| `*.log`               | any path whose final segment ends `.log`                                     | suffix                              |
| `docs/api.txt`        | that path, relative to the directory holding the `.gitignore`                | anchored literal                    |
| `/docs`               | `docs` in the directory holding the file, not deeper                         | anchored literal                    |
| `**/target`           | a `target` directory at any depth                                            | normalised to an unanchored literal |
| `**/*.cpp`            | any `.cpp` file at any depth                                                 | normalised to a suffix              |
| `a/**/b`              | `a`, then zero or more directories, then `b`                                 | anchored glob                       |
| `*.pyc` + `!keep.pyc` | excluded, then re-included by the later rule                                 | suffix + negation                   |

Small rules that matter, each one a test in [`../src/gitignore.zig`](../src/gitignore.zig):

- `#` starts a comment, a blank line is nothing, `\#` and `\!` are literals.
- Trailing spaces are trimmed unless escaped (`foo\ ` keeps the space); CR before LF is stripped, so a CRLF checkout
  parses like an LF one.
- `?`, `[...]` (with ranges and `]` first), and `\` escapes work inside one path segment; a `*` never crosses `/`.
- A `**` that is a whole segment matches zero or more segments; a **trailing** `**` requires at least one, because
  `foo/**` is everything *inside* `foo`, not `foo`.
- An excluded directory is **not listed and not entered** — which is git's rule, and the reason a negation inside an
  excluded directory cannot re-include anything.

### Precedence

Two orderings, both required:

1. **Inside one file, the last matching pattern wins** — a negation after a pattern re-includes.
2. **A deeper file beats a shallower one.** The `.gitignore` in `src/` governs what is below `src/`, and when it has
   an opinion it wins regardless of what the root file said.

`decide` returns three values, not two: `true` (exclude), `false` (re-include), and `null` (**this file has no
opinion**). `null` is what makes precedence work — the chain keeps asking shallower files, and only "no file has an
opinion" becomes "included".

### What the matcher does not do

- It does not read `.git/info/exclude` or a global `core.excludesFile`; a watcher describes *the tree*, and those are
  per-clone configuration.
- It does not implement `**` inside a segment (`a**b`) differently from `*`; git's manual says the same.
- It does not decide whether a file is *tracked* — `git check-ignore` cares, a tree description does not.

## Part 2 — the optimisations

The pass on a tree of 3800 entries went from **~4,700 ms to ~105 ms** on a tree whose `.gitignore` is deliberately
hostile (146 rules, 50 of them `**`). Nine changes did that; each one is here with its measured effect.

### 1. One listing per directory, not one stat per file

The cheapest way to learn a directory's contents is a single platform call that returns the children **with their
metadata**: `NtQueryDirectoryFile` with `FileIdBothDirectoryInformation` on Windows — name, mtime, size, attributes
and the 64-bit `FileId` in one syscall, so no entry needs a handle opened. The portable path (`readdir` + `stat` +
a handle for the identity) is kept as the oracle the Windows path is tested against, and can be forced with
`--per-file` to measure the difference.

Measured: a cold pass **183.6 → 320.6 ms** slower with `--per-file` on jcodebuddy, i.e. the batch is worth ~40%
there; on Fory, where matching dominated, it was worth only 5% — the reason the next optimisations exist.

[../src/lister.zig#listWindows](../src/lister.zig#listWindows)

```zig
fn listWindows(tree: *Tree, allocator: std.mem.Allocator, dir_path: []const u8) ![]coldstart.EntryInfo {
    const io = tree.io;
    var dir = try openDirAny(io, dir_path);
    defer dir.close(io);

    const buffer_bytes = 64 * 1024;
    const buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(8), buffer_bytes);
    defer allocator.free(buffer);

    var out: std.ArrayListUnmanaged(coldstart.EntryInfo) = .empty;
    errdefer out.deinit(allocator);

    var restart = true;
    while (true) {
        var status_block: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtQueryDirectoryFile(
            dir.handle,
            null,
            null,
            null,
            &status_block,
            buffer.ptr,
            @intCast(buffer_bytes),
            file_id_both_directory_information,
            w.BOOLEAN.FALSE,
            null,
            @enumFromInt(@intFromBool(restart)),
        );
        restart = false;
        switch (status) {
            .SUCCESS => {},
            .NO_MORE_FILES => break,
            .BUFFER_OVERFLOW => {}, // entries were returned; the next call continues
            else => return error.DirectoryListingFailed,
        }

        var offset: usize = 0;
        while (true) {
            const info: *const FileIdBothDirInformation = @ptrCast(@alignCast(buffer.ptr + offset));
            const name_bytes = info.FileNameLength / 2;
            const name_ptr: [*]const u16 = @ptrCast(&info.FileName);
            const name_utf16 = name_ptr[0..name_bytes];

            const name_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, name_utf16);
            errdefer allocator.free(name_utf8);
            if (!std.mem.eql(u8, name_utf8, ".") and !std.mem.eql(u8, name_utf8, "..")) {
                try out.append(allocator, .{
                    .name = name_utf8,
                    .kind = kindOfWindows(info.FileAttributes),
                    .mtime_ns = filetimeToNs(info.LastWriteTime),
                    .size_bytes = if (kindOfWindows(info.FileAttributes) == .regular_file) @intCast(info.EndOfFile) else 0,
                    .file_id_lo = @as(u64, @bitCast(info.FileId)),
                    .file_id_hi = 0, // filled from the volume serial below
                });
            } else {
                allocator.free(name_utf8);
            }

            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
        // One lookup per pass: the serial belongs to the volume, not to the directory.
        if (out.items.len > 0) {
            const serial = tree.volume_serial orelse blk: {
                const id = scan.fileIdAt(dir, io, out.items[0].name);
                tree.volume_serial = id.hi;
                break :blk id.hi;
            };
            for (out.items) |*fact| fact.file_id_hi = serial;
        }
    }

    // Keep the trio's order deterministic without depending on the OS enumeration order.
    std.mem.sort(coldstart.EntryInfo, out.items, {}, entryLessThan);
    return out.toOwnedSlice(allocator);
}
```

### 2. `**/pattern` is an unanchored pattern

`**/pat` means "applies at any depth", which is exactly what an unanchored pattern already means. Keeping it
*anchored* pushed fifty of Fory's rules into the general-glob class, where every entry paid an ancestor-prefix walk
for each of them. Normalising the prefix at parse time moves `**/*.cpp` into the suffix class and `**/target` into
the literal class — same meaning, indexed instead of scanned.

Measured: Fory's warm pass **~218 → ~148 ms**.

[../src/gitignore.zig#doublestar-normalise](../src/gitignore.zig#doublestar-normalise)

```zig
{//doublestar-normalise
            if (anchored and std.mem.startsWith(u8, line, "**/")) {
                line = line[3..];
                anchored = false;
            }
}
```

### 3. Classify once, at parse time

Every pattern is sorted into one of three classes when the file is parsed — `literal` (no wildcard bytes), `suffix`
(a single leading `*` then a literal tail, e.g. `*.log`), or `glob`. A literal is answered with a string compare, a
suffix with `endsWith`, and only a general glob reaches the matcher. Patterns containing an escape are deliberately
left in the `glob` class, because an escape needs interpretation (`\#foo` is a literal `#foo`, not a comment).

This is the single change that makes the common case free: in a real `.gitignore`, most patterns are literals or
`*.ext`.

### 4. `globMatch` is a segment dynamic program

The original matcher recursed over path boundaries and re-tested `**` at every depth — exponential on a deep path, so
a single `**/*.pyc` against a 14-segment Java path cost milliseconds. It is now a DP over segments: `ok[j]` means
"the pattern so far matches the first `j` path segments", an ordinary segment advances one row, and `**` is a
prefix-OR over the row. O(pattern segments × path segments), no backtracking, bounded so a pathologically deep path
is refused rather than recursed into.

Measured: Fory's warm pass **~4,700 → ~232 ms**. This was the change that mattered most, and every earlier
optimisation had failed because it reduced *how often* an exponential function was called.

[../src/gitignore.zig#globMatch](../src/gitignore.zig#globMatch)

```zig
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pattern_segments: [max_segments][]const u8 = undefined;
    var path_segments: [max_segments][]const u8 = undefined;
    const pattern_count = splitSegments(pattern, &pattern_segments);
    const path_count = splitSegments(path, &path_segments);
    if (pattern_count > max_segments or path_count > max_segments) return false;
    if (pattern_count == 0) return path_count == 0;

    // `ok[j]`: the pattern segments seen so far match the first `j` path segments.
    var ok: [max_segments + 1]bool = undefined;
    var next: [max_segments + 1]bool = undefined;
    for (0..path_count + 1) |j| ok[j] = j == 0;

    for (pattern_segments[0..pattern_count], 0..) |segment, index| {
        const trailing = index + 1 == pattern_count;
        if (std.mem.eql(u8, segment, "**")) {
            if (trailing) {
                // One or more segments below the previous match.
                var reachable = false;
                for (0..path_count + 1) |j| {
                    next[j] = reachable;
                    reachable = reachable or ok[j];
                }
            } else {
                // Zero or more.
                var reachable = false;
                for (0..path_count + 1) |j| {
                    reachable = reachable or ok[j];
                    next[j] = reachable;
                }
            }
        } else {
            next[0] = false;
            for (1..path_count + 1) |j| {
                next[j] = ok[j - 1] and wildMatchSegment(segment, path_segments[j - 1]);
            }
        }
        @memcpy(ok[0 .. path_count + 1], next[0 .. path_count + 1]);
    }
    return ok[path_count];
}
```

The splitter it depends on, with its bound:

[../src/gitignore.zig#splitSegments](../src/gitignore.zig#splitSegments)

```zig
fn splitSegments(input: []const u8, out: *[max_segments][]const u8) usize {
    var count: usize = 0;
    if (input.len == 0) return 0;
    var start: usize = 0;
    while (start <= input.len) {
        const slash = std.mem.indexOfScalarPos(u8, input, start, '/') orelse input.len;
        if (count == max_segments) return max_segments + 1; // signals "too deep"
        out[count] = input[start..slash];
        count += 1;
        if (slash == input.len) break;
        start = slash + 1;
    }
    return count;
}
```

### 5. The chain: one matcher per directory, with per-kind lists

The ancestor files are flattened **once per chain** — deepest file first, each file reversed — and the chain is
cached by its deepest rules file, so a tree with 14 ignore files has 14 chains, not one per directory. Anchored
patterns are scoped by prefixing their owner's path at build time, so a lookup needs no per-entry scoping string.

Lookup is then the **minimum chain position among the lists that match**: literal maps probed by path segment,
suffixes against the final segment, wildcards and anchored rules against the path. Because rules are appended in
chain order, each list is ascending, and a list can stop at the first position later than the best found so far.

The per-kind lists are worth recording as a *negative* result: they replaced the flattened scan and moved nothing
(148 → 145 ms), which is precisely how the next change was found.

[../src/ignore.zig#decide](../src/ignore.zig#decide)

```zig
    fn decide(self: Chain, path: []const u8, base: []const u8, is_dir: bool) ?bool {
        var best: ?usize = null;
        var start: usize = 0;
        while (start <= path.len) {
            const slash = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
            const segment = path[start..slash];
            if (self.literals.get(segment)) |at| {
                if (best == null or at < best.?) best = at;
            }
            const last_segment = slash == path.len;
            if (!last_segment or is_dir) {
                if (self.literals_dir_only.get(segment)) |at| {
                    if (best == null or at < best.?) best = at;
                }
            }
            if (last_segment) break;
            start = slash + 1;
        }

        for (self.suffixes) |entry| {
            if (best) |limit| if (entry.at > limit) break;
            if (base.len >= entry.suffix.len and std.mem.endsWith(u8, base, entry.suffix)) {
                best = entry.at;
                break;
            }
        }
        for (self.wilds) |entry| {
            if (best) |limit| if (entry.at > limit) break;
            if (chainRuleMatches(entry.rule, path, base, is_dir)) {
                best = entry.at;
                break;
            }
        }
        for (self.anchored) |entry| {
            if (best) |limit| if (entry.at > limit) break;
            if (chainRuleMatches(entry.rule, path, base, is_dir)) {
                best = entry.at;
                break;
            }
        }

        if (best) |at| return !self.items[at].negated;
        return null;
    }
```

### 6. Anchored rules are pruned by their first segment

The last expensive class was rules that carry a path (`java/fory-core/build/`, `a/**/b`): each walked the ancestor
prefixes with a glob for every entry. An anchored rule whose first segment is literal can only match a path that
starts with that segment, so one comparison rejects the ~99% of entries outside its subtree. In the chain the pattern
is prefixed with its owner's path, so the first segment is recomputed after prefixing — the parse-time value
describes the unprefixed pattern.

Measured: Fory's warm pass **~145 → ~105 ms**, which brought it inside the 2× budget.

[../src/ignore.zig#chain-anchored-prune](../src/ignore.zig#chain-anchored-prune)

```zig
{//chain-anchored-prune
    if (rule.first_segment) |head| {
        const path_first = path[0..(std.mem.indexOfScalar(u8, path, '/') orelse path.len)];
        if (!std.mem.eql(u8, head, path_first)) return false;
    }
    if (!rule.directory_only) return chainMatchText(rule, if (rule.anchored) path else base);
    if (is_dir and chainMatchText(rule, path)) return true;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            if (chainMatchText(rule, path[0..index])) return true;
        }
    }
    return false;
}
```

### 7. A directory's identity comes from its parent's listing

`coldstart` used to stat every directory to learn its mtime and `FileId` — three syscalls (open parent, stat child,
open a handle for the identity). The parent's bulk listing already reported both, so the queue carries them and only
the root is stat'ed. This is the per-directory saving the design called for: for everything below the root, three
syscalls become zero.

A directory's mtime answers one question — *did its child names change* — and never licenses skipping the files
inside it: editing a file does not move the directory's mtime, so every directory is still listed, and only the
listing's own metadata decides whether a file's hash is reusable.

### 8. Hash on discovery, reuse afterwards

A pass hashes the entries that are still dirty — new, changed, or never hashed — and leaves every entry whose
`mtimeNs` + `sizeBytes` + `fileId` still match the previous generation alone. The hashes are written into the trio,
so the *next* pass has something to reuse; the pass reports how many it took, which is why `hashed 0` on an unchanged
tree is a fact rather than a hope.

Measured: an unchanged tree takes **zero** hashes; a full discovery takes one per file, and the hashing itself is
cheap (38 MB through wyhash added 0.6% to a walk) — the cost is opening the files, not the hash.

[../src/engine.zig#hashDirty](../src/engine.zig#hashDirty)

```zig
fn hashDirty(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    cache: *Cache,
    mode: scan.HashMode,
) !u64 {
    const paths = try arena.alloc([]const u8, cache.files.count());
    var count: usize = 0;
    const keys = cache.files.keys();
    for (keys) |path| {
        paths[count] = path;
        count += 1;
    }
    var hashed: u64 = 0;
    for (paths[0..count]) |path| {
        const state = cache.files.getPtr(path) orelse continue;
        if (state.kind != .regular_file) continue; // directories and symlinks carry no content hash
        if (state.content_hash != null) continue; // unchanged: reuse what the previous generation recorded
        const full = if (root.len == 0)
            path
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, path });
        const result = scan.hashFileAt(io, full, mode) catch continue; // unreadable now: stays dirty
        state.content_hash = result.hash;
        state.hash_lf = result.hash_lf;
        hashed += 1;
    }
    return hashed;
}
```

### 9. The flush delay tunes itself

Watch mode has no configured delay. Each pass is measured, and the quiet period that ends a burst is
`clamp(1.5 × pass_ewma, 25 ms, 2000 ms)`, with a 5 s forced flush so a permanently busy tree is never starved and a
25 ms floor so a fast machine feels immediate. The EWMA (weight 0.3) lets the delay fall again when the machine
speeds up, and the learned state is persisted per project in `.fs-meta/watch.json`, so a restart resumes tuned and
the runtime can print the delay a fixed configuration should use.

[../src/watch.zig#quietPeriodMs](../src/watch.zig#quietPeriodMs)

```zig
    pub fn quietPeriodMs(self: *const Scheduler) f64 {
        // Before any pass has been measured, use the floor: a first flush should not wait on a guess.
        const estimate = self.tuning.factor * self.pass_ewma_ms;
        const bounded = std.math.clamp(estimate, self.tuning.min_delay_ms, self.tuning.max_delay_ms);
        return @max(bounded, self.tuning.idle_quiet_ms);
    }
```

## What is not optimised, and why

- **Path compression** is not used: names are stored once and entries carry offsets, so the only redundancy is shared
  prefixes, worth ~70 KB on a 4000-entry trio — against a pass whose cost is per entry. The trigger for revisiting
  (an 8 MB `files.txt`) is recorded in [`path-layout-research.md`](path-layout-research.md).
- **The root is always listed**, because `files.json` records the root's identity but not its mtime; adding
  `root.mtimeNs` would make the top level skippable, and is a format question, not a code one.
- **The trio is not compressed or memory-mapped**: reading and validating it is ~10 ms for 3900 entries, and it is
  the one part of the system whose whole job is to be simple enough to trust.
