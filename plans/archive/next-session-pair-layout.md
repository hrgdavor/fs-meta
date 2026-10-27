# Next session: the main trio uses the shared pair layout

**Status: implemented.** `publish` lays its pair out through `pair.layout` with the count assertion in place, and
`files.json` carries § 18's `roots`; `engine`'s walker-agreement test compares names as a set. The document below is
the plan that was followed, kept for the record; `plans/archive/next-steps-done.md` § B is the summary and is now closed.

**Goal in one line.** Make `publish` lay out its pair through `pair.layout` — the function `batch.encode` already
uses — so the main trio and a batch have one ordering rule between them, and emit § 18's `roots` from the same layout.

**Definition of done.** `zig build test` green with the count assertion below in place; a published trio whose
`files.txt` is name-ordered with slashed directory names and whose `files.meta` is `(nameHash, name)`-ordered; `roots`
in `files.json`; and the engine's walker-agreement test passing with names compared as a set.

## Where things are

- Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate: `cd fs-meta; D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all`.
  Currently **37/37 steps, 96/98 tests** (2 platform skips).
- Only touch `fs-meta/`. Other subprojects (`socutil`, `wyhash`, `inject-examples`) have other agents working in them.

| commit    | what                                                                                         |
| --------- | -------------------------------------------------------------------------------------------- |
| `6b4e2e1` | FORMAT.md: § 4 two orderings (meta by hash, text by name), slashed directory names, exact ranges, § 18 `roots` |
| `4edb4a9` | `validate` hashes a directory name without its slash; `batch.encode` stores the slashed form |
| `59e0f65` | `pair.zig` — `Item`, `layout`, `RootRange`, `deinit` — with 3 tests, added to the gate       |
| `dd11395` | `batch.encode` calls `pair.layout` instead of laying out its own pair                        |

## The open defect that stopped the last attempt

Converting `publish` compiles and its own test passes, but the engine test `a pass and a full walk agree about the
tree, .gitignore included` fails with:

```
index 4: walk=src trio=src/        ← expected: slash representation, handled by trimming
length differs: walk=8 trio=9      ← real: the trio lists one name the walk does not
```

Nature of it: a producer/consumer disagreement about **what a trio lists**. `pair.layout` uses exactly the items it is
given, so the extra name comes from `publish`'s item loop or from the cache itself.

A synthetic reproduction that **did not** reproduce it (`fs-meta/.tmp` not involved; done by hand): a tree with
`.gitignore` = `build/`, `a.txt`, `src/b.txt`, `build/gen.txt` produced a trio and a walk that agreed on exactly four
names, with `build/` absent from both. So the pruning is right for that shape; the engine test's tree has something
else — it also has `*.log`, `!keep.log` and a `build/` directory, so the extra is plausibly a name produced by the
negation path or by a directory created between two passes.

## Step 1 — name the extra item, do not guess it

In `publish`, immediately before `pair.layout`:

```zig
// The loader and the walker both depend on this count; a mismatch here is the bug, not a symptom of it.
std.debug.assert(items.items.len == cache.files.count() + cache.dirs.count() - 1); // -1: the root is never listed
```

Run the gate.

- If the assertion **fires**, the item loop is wrong (a name appended twice, or the root not skipped in one branch).
- If it **holds**, the extra name is a real cache entry: then dump the names the engine test's own tree produces —
  add a temporary `std.debug.print` of `items.items` inside the test's publish call, or run
  `fsmeta scan <tree>` and `fsmeta refresh <tree>` on a copy of that tree and diff `files.txt` against the scan — and
  the question becomes "why is a name the walker prunes in the cache". The likely answer is a directory that the
  discovery path listed but the ignore rules excluded, whose removal should use
  `cache.dirs.fetchOrderedRemove(path)` (precedent: `coldstart.zig:235`, `:299`).

## Step 2 — convert `publish`

Replace the block from `// 1. The pair, in the trio's order` through `const txt_bytes = try allocator.dupe(u8, txt.items);`
with the items + layout code (the fragment last used is `fs-meta/.tmp/publish-items.zig` if it survives; otherwise
retype it):

```zig
    var items: std.ArrayListUnmanaged(pair.Item) = .empty;
    defer items.deinit(allocator);
    for (cache.files.keys()) |path| try items.append(allocator, .{ .name = path, .entry = fileEntry(path, cache.files.get(path).?) });
    for (cache.dirs.keys()) |path| {
        if (path.len == 0) continue; // the root is never listed (§ 3)
        try items.append(allocator, .{ .name = path, .entry = dirEntry(path, cache.dirs.get(path).?) });
    }

    const laid = try pair.layout(allocator, items.items);
    const meta = laid.meta;
    const txt_bytes = laid.txt;
    // roots (§ 18) is not emitted yet; free the ranges so the layout owns nothing on return.
    for (laid.roots) |range| allocator.free(range.name);
    allocator.free(laid.roots);
```

and add the two projections at file scope (they were written and compiled last time):

```zig
const cache_mod = @import("cache.zig");   // for FileState / DirState (they are NOT inside Cache)

fn fileEntry(path: []const u8, file: cache_mod.FileState) format.Entry {
    const known = file.content_hash != null;
    return .{
        .mtime_ns = file.mtime_ns,
        .size_bytes = file.size_bytes,
        .content_hash = file.content_hash orelse 0,
        .name_hash = format.wyhash(path),
        .name_offset = 0,
        .name_length = 0,
        .flags_word = switch (file.kind) {
            .dir => unreachable, // directories live in cache.dirs
            .symlink => format.flags.symlink,
            .regular_file => format.flags.regular_file |
                (if (known) format.flags.content_known else 0) |
                (if (known and file.hash_lf) format.flags.hash_lf else 0),
        },
        .file_id_lo = file.file_id_lo,
        .file_id_hi = file.file_id_hi,
    };
}

fn dirEntry(path: []const u8, directory: cache_mod.DirState) format.Entry {
    return .{
        .mtime_ns = directory.mtime_ns,
        .size_bytes = 0,
        .content_hash = 0,
        .name_hash = format.wyhash(path),
        .name_offset = 0,
        .name_length = 0,
        .flags_word = format.flags.is_dir,
        .file_id_lo = directory.file_id_lo,
        .file_id_hi = directory.file_id_hi,
    };
}
```

Also: `const pair = @import("pair.zig");`, `.count = items.items.len` in the sidekick, and **do not** `defer pair.deinit`
for `meta`/`txt` — `Outcome` returns them and the caller frees them; free only `roots` as shown.

## Step 3 — the two tests that move with it

1. **`publish.zig`'s own test**: the expected text becomes the name order with the slashed directory —
   `"a.txt\nsrc/\nsrc/b.java\n"` — because `files.txt` is now name-ordered and `src/` sorts before `src/b.java`.
2. **`engine.zig`'s walker agreement**: the walk reports `src`, the trio stores `src/`. Add

   ```zig
   fn trimSlash(name: []const u8) []const u8 {
       if (name.len > 1 and name[name.len - 1] == 0x2F) return name[0 .. name.len - 1];
       return name;
   }
   ```

   use it inside `hasName`, and replace the positional compare
   `for (a, b) |left, right| try testing.expectEqualStrings(left, right);` with
   `for (a) |want| try testing.expect(hasName(b, want));`.

   **Warning, learned the hard way:** `expectNameSets` contains a diagnostic loop `for (a, b, 0..)` that **panics on
   unequal lengths** (`for loop over objects with non-equal lengths`). Remove that loop first if the lengths still
   differ, otherwise the failure reads as a crash instead of the real mismatch, and do not try to cut it out by brace
   counting — that left the file uncompilable twice. Edit it by hand.

## Step 4 — `roots` in the sidekick

In `json_doc.zig`, mirror the existing `batch` block:

```zig
pub const RootFields = struct { name: []const u8, offset: u64, length: u64 };
// Fields gains: roots: ?[]const RootFields = null,
```

and emit an object (`"roots": { "src": { "offset": 1300, "length": 8400 }, … }`) when present. Then `publish` passes
`laid.roots` (converted to `RootFields`) instead of freeing them. Add a test like the batch block's: present when set,
absent otherwise.

## Step 5 — commit sequence

One commit per step, message via a file (`git commit -F .tmp/msg.txt`) — quoting a message with backticks through
PowerShell has broken twice:

1. `fs-meta: publish lists items, and pair.layout lays them out`
2. `fs-meta: the walker agreement compares names as a set` (if separated)
3. `fs-meta: roots in the sidekick`

## Pitfalls collected in this session (each cost a round)

- **Anchors must be read, not remembered.** `Fields` is at column 0 with four-space members; `flags` is called
  `flags_word`; the flag constants live in `format.flags.*`; `FileState`/`DirState` are top-level in `cache.zig`.
- **A backtick inside a JS template literal is a syntax error** — for prose with backticks, write a `.mjs` file or a
  plain fragment and read it, never `bun -e` with a template.
- **`[System.IO.File]` resolves against the process cwd, not PowerShell's `cd`** — use absolute paths.
- **Zig comparators need a concrete type**: `anytype` parameters do not satisfy `fn (void, Item, Item) bool`. Put the
  type at file scope (that is why `pair.Item` is public).
- **`pair.deinit` owns meta, txt, every range name and the range slice** — a caller that frees half of it is a
  use-after-free that debug builds render as `UUUU` (that was the `roots` bug).
- **A layout outside `build.zig`'s module list is not tested** — `pair` is in the list, keep it there.

## Acceptance

```text
cd fs-meta
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
# → all steps succeed; the engine walker test passes; pair/batch/reconcile/wire tests pass

# and, on a scratch tree with a nested folder:
fsmeta refresh <tree> --hash text --updated <iso>
cat <tree>/.fs-meta/files.txt      # name order, directories with a trailing slash
# files.json carries "roots": { "<child>": { "offset": …, "length": … } }
```

Do not commit with a red gate. If the count assertion fires, that is the next fact to chase and it is worth a commit
on its own only after it is understood.
