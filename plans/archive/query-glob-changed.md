# Plan: query the trio — glob search and changed-since, via CLI and socket

**Status:** the CLI half is implemented (`fsmeta match` — `glob` kept as an alias — with `--since` and `--json`, and
`fsmeta changed <root> <since>`), unit-tested in `src/query.zig`; the commands themselves still have no integration
test. The **socket half is superseded**: the socket speaks the binary protocol of `FORMAT.socket.md`, not JSON-RPC, so
"a JSON-RPC client gets the same results" is not a missing feature but a design that was replaced. Kept for the record;
the pattern it established (`query.run` over the loaded cache, one line per match) is what the CLI still uses.

**Goal in one line.** Give the runtime two query tools on top of the loaded cache — a glob that returns every
matching entry with its full 64-byte metadata, and a mtime filter that can be paired with the glob — exposed as
new `fsmeta` subcommands and as JSON-RPC methods on the socket.

**Definition of done.** `zig build test` green; `fsmeta glob <root> <pattern>` prints name-ordered matches with
all entry fields; `fsmeta changed <root> --since <ts>` prints mtime-filtered matches; the two compose
(`fsmeta glob <root> <pattern> --since <ts>`); a JSON-RPC client over the socket gets the same results as JSON.

## Where things are

- Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate: `cd fs-meta; D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all`.
- Only touch `fs-meta/`.
- The data model is `format.Entry` (64 bytes: mtime, size, contentHash, nameHash, flags, fileId) + the name from
  `files.txt`. The `Cache` holds both, keyed by path.
- The CLI is `fsmeta.zig` (three subcommands today: `verify`, `scan`, `refresh`).
- The socket wire is `wire.zig` (binary frames) + JSON-RPC (identified by `0x7B 0x22` prefix).
- The engine loads the trio into a `Cache` via `validate` + `Cache.load` (the cold-start path in `coldstart.zig`).

## What the runtime already has, and what is missing

| Has                                                       | Missing                                                     |
| --------------------------------------------------------- | ----------------------------------------------------------- |
| A `Cache` with every entry's full metadata                | A query API: "give me entries whose name matches pattern P" |
| A `scan` that walks the tree and prints one line per name | A glob matcher (Zig std has none)                           |
| A `refresh` that updates the trio                         | A mtime filter: "give me entries with mtime ≥ T"            |
| A socket with change streaming (binary frames)            | A JSON-RPC query method that returns entries as JSON        |
| A CLI with `verify` / `scan` / `refresh`                  | CLI subcommands for the above                               |

## Step 1 — `query.zig`: the glob matcher and the query

New module `src/query.zig`, added to the `build.zig` module list and the gate.

### 1a. Glob matching

A `Glob` struct that compiles a pattern and matches a relative path. The pattern syntax:

- `*` — any sequence of characters except `/`
- `**` — any sequence of characters including `/` (crosses directory boundaries)
- `?` — exactly one character
- `[abc]` — one character from the set
- `[!abc]` — one character not in the set
- literal characters match themselves

Implementation: a small recursive-descent matcher over the pattern and the name. No allocation in the match
path; the pattern is compiled once into a small instruction list (a slice of a `Token` enum) and matched in O(n·m).

```zig
pub const Glob = struct {
    tokens: []Token, // owned by the caller's arena
    // ...
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) Glob;
pub fn matches(self: Glob, name: []const u8) bool;
```

The match is against the **relative path** as the cache keys it: `/`-separated, no trailing slash, no `.`
components. `src/main.zig` matches `src/main.zig` and `**/*.zig`. `src/` (a directory) matches `src` — the
trailing slash is the layout's, not the name's, and the cache never stores it.

### 1b. The query

A `Query` struct that takes a `*const Cache` and optional filters, and returns matching entries:

```zig
pub const Query = struct {
    cache: *const Cache,
    glob: ?Glob = null,
    since_ns: ?u64 = null, // mtime_ns >= since_ns
};

pub const Match = struct {
    name: []const u8,
    entry: format.Entry,
};

pub fn run(allocator: std.mem.Allocator, q: Query) ![]Match;
```

`run` walks `cache.files` (the `StringArrayHashMapUnmanaged`), applies the glob (if set) and the mtime filter
(if set), and collects the matches. Directories are included: `cache.dirs` is walked too, and a directory's
`DirState` is projected to a `format.Entry` (kind = `.dir`, mtime from `DirState.mtime_ns`, size 0, file_id from
`DirState`). The result is sorted by name (the cache's iteration order is arbitrary; the output is name-ordered
so it is diffable and matches `files.txt`).

### 1c. Timestamps

The CLI and socket accept an ISO-8601 timestamp (`2026-10-20T12:00:00Z`) or a relative form (`1h`, `30m`, `2d`).
The query module exposes a `parseSince` function that converts either form to `u64` nanoseconds since the unix
epoch. The engine core has no clock (per its own doc), so the timestamp is always supplied by the caller.

### 1d. Tests

- Glob: `*` does not cross `/`, `**` does; `?` is one char; `[abc]` and `[!abc]`; literal paths; empty pattern
  matches nothing; a pattern with no wildcard is a literal compare.
- Query: a cache with known entries; glob only; mtime only; both; no filter (returns everything); directories
  included; result is name-ordered.
- `parseSince`: ISO-8601, relative, and the edge cases (year boundary, leap day, `Z` vs offset).

## Step 2 — CLI subcommands in `fsmeta.zig`

Two new subcommands, added to the usage string and the dispatch in `main`:

### 2a. `fsmeta glob <root> <pattern> [--since <ts>] [--json]`

- Loads the trio into a `Cache` (the same path `refresh` uses: `validate` → `Cache.load`, or a cold `scan` if the
  trio is absent/invalid).
- Compiles the glob.
- Runs the query.
- Prints one line per match: `name\tkind\tmtime_iso\tsize\tcontent_hash\thash_lf\tfile_id_lo\tfile_id_hi`.
  (Tab-separated so a shell can `cut` or `awk` it; the kind is `file`, `dir` or `symlink`.)
- With `--json`, prints a JSON array of objects, one per match, with all entry fields plus the name.

### 2b. `fsmeta changed <root> --since <ts> [--glob <pattern>] [--json]`

- Same loading path.
- The mtime filter is mandatory (`--since` is required).
- The glob is optional.
- Same output format as `glob`.

### 2c. The loading helper

A shared `loadCache(allocator, io, root, options)` function that both subcommands call: it does `validate` →
`Cache.load` when the trio is present and valid, and falls back to `scan` + a fresh `Cache` when it is not (the
same "the trio is a cache, never a correctness input" rule, FORMAT.md § 1). This is the one place that knows
how to get a `Cache` from a root; `refresh` already has this logic in `engine.refresh`, and the two new commands
reuse the same shape.

### 2d. Tests

The CLI is thin over `query.run`, so the tests are: a `fsmeta glob` on a scratch tree prints the expected lines;
`fsmeta changed --since` on a scratch tree with known mtimes prints the expected subset; `--json` produces
parseable JSON. These are integration tests that use `std.testing.tmpDir` (the same pattern the `scan` and
`engine` tests use).

## Step 3 — JSON-RPC methods on the socket

The socket already recognises JSON-RPC by the `0x7B 0x22` prefix (FORMAT.socket.md: "a JSON object starts `{"`").
Two new methods are added to the JSON-RPC handler (which lives in the watcher's socket server, `main.zig`'s
polling thread, or a dedicated server module — whichever module owns the socket):

### 3a. Method `glob`

```json
{ "method": "glob", "params": { "pattern": "**/*.zig", "since": "2026-10-20T00:00:00Z" } }
```

Response:

```json
{ "result": [
  { "name": "src/main.zig", "kind": "file", "mtime": "2026-10-20T12:00:00Z", "size": 1234,
    "contentHash": "ab12cd34ef567890", "hashLf": true, "fileId": "1:2:3" },
  ...
] }
```

- `pattern` is required; `since` is optional.
- The entries carry the full metadata, same fields as the CLI's `--json` output.
- The response is a JSON array, one object per match, name-ordered.

### 3b. Method `changed`

```json
{ "method": "changed", "params": { "since": "2026-10-20T00:00:00Z", "pattern": "src/**" } }
```

Response: same shape as `glob`.

- `since` is required; `pattern` is optional.

### 3c. The handler

The handler takes the loaded `Cache` (the same one the watcher keeps in memory), builds a `Query`, calls
`query.run`, and serialises the result to JSON. The JSON serialisation is a small function in `query.zig`
(`toJson(allocator, matches)`) that emits the array by hand (the same "hand-rolled JSON, not `std.json`" rule
that `json_doc.zig` follows, because the emitted bytes are part of the conformance vectors).

### 3d. Tests

A test that builds a `Cache` with known entries, calls the query, and asserts the JSON output is the expected
string (the same pattern `json_doc.zig`'s tests use). The socket itself is not tested in `query.zig`'s tests —
the watcher's socket tests (in `main.zig` or the server module) cover the frame framing.

## Step 4 — `build.zig` and the gate

- Add `"query"` to the `modules` list in `build.zig`.
- The gate (`zig build test --summary all`) picks it up automatically.
- No new third-party dependency: the glob is hand-rolled, the JSON is hand-rolled, the timestamp parser uses
  `std.time` (which is in the std).

## Step 5 — Commit sequence

| commit | what                                                                                |
| ------ | ----------------------------------------------------------------------------------- |
| `A`    | `query.zig` — `Glob.compile`, `Glob.matches`, with glob tests                       |
| `B`    | `query.zig` — `Query.run`, `parseSince`, with query and timestamp tests             |
| `C`    | `fsmeta.zig` — `glob` and `changed` subcommands, `loadCache` helper, with CLI tests |
| `D`    | `query.zig` — `toJson`, with JSON output tests                                      |
| `E`    | socket handler — `glob` and `changed` JSON-RPC methods, with handler tests          |

Each commit is green on its own. The gate is run after each.

## Risks and open questions

1. **Glob `**` semantics.** `**` crosses `/`, `*` does not. This is gitignore's rule (which the project already
   follows in `gitignore.zig`), and it is the rule a user expects from `find -name` or `fd`. The matcher must
   get this right on the first pass; a test with `src/**/*.zig` matching `src/a/zig/b.zig` and not matching
   `src/a.txt` pins it.

2. **Directory entries in the glob result.** A glob like `src/**` should match the directory `src` itself as
   well as everything under it. The query includes `cache.dirs` entries, projected to `format.Entry`. The kind
   field in the output makes this visible.

3. **The `since` filter and mtime granularity.** `mtime_ns` is nanoseconds, but the OS reports it at a
   coarser resolution (Windows: 100 ns; Linux: 1 ns, but the VFS may round). The filter is `>=`, so a file
   whose mtime is exactly the threshold is included. A test pins this.

4. **The socket's `Cache` freshness.** The watcher's `Cache` is updated on every pass. A JSON-RPC query runs
   against the current `Cache`, so it sees the latest generation. No lock is needed: the `Cache` is only
   mutated by the polling thread, and the socket handler runs on the same thread (the watcher's architecture
   is single-threaded for the engine; the event thread only appends to the batcher).

5. **`std.time` for the timestamp parser.** Zig 0.17's `std.time` has `Timestamp` and ISO-8601 parsing. The
   parser must handle `Z` (UTC), `+02:00` offsets, and the relative forms (`1h`, `30m`, `2d`). If `std.time`
   does not cover the relative forms, a small parser in `query.zig` handles them.

## Acceptance

```text
cd fs-meta
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
# → all steps succeed; query tests pass; fsmeta CLI tests pass

# and, on a scratch tree:
fsmeta glob <root> "**/*.zig"
# → name-ordered lines with all fields

fsmeta changed <root> --since 2026-10-20T00:00:00Z --glob "src/**"
# → only entries under src/ with mtime >= the threshold

fsmeta glob <root> "**/*.zig" --json
# → a JSON array, parseable, with all entry fields
```

Do not commit with a red gate.
