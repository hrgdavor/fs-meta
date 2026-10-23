# Path layout — what other systems do, and whether it would help us

The question: should the trio store **absolute paths only for directories**, with each file referring to its
parent directory by id and carrying only a basename? And should `files.txt` become a tree — a directory's full path
on one line, its files on the following lines — instead of the current flat, sorted name table?

Answered from prior art and from measurements on the two benchmark trees (see [`benchmark.md`](benchmark.md)).

> **Decision, 2026-10-18: full paths stay.** Names remain complete paths, one per line in `files.txt`; no
> directory table, no parent reference, no compression. The size saving is real but irrelevant at the scale this
> format is for — 130–310 KB on a 3000-entry tree — and **speed is the constraint that matters**, which none of
> the alternatives improves. This note exists so the question is answered once, with the numbers, instead of
> being reopened from a hunch; revisit only under the trigger at the end.

## What the systems that do this actually store

| System                           | Unit stored per child                                       | How a full path is recovered                      | Why that shape                                       |
| -------------------------------- | ----------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------- |
| ext4 (and every Unix filesystem) | directory entry: **name + inode**, looked up by a hash tree | by walking from the root, one directory at a time | the on-disk model; a full path is never stored anywhere ([`namei.c`](https://android.googlesource.com/kernel/hikey-linaro/+/4073723acb9cdcdbe4df9c0e0c376c65d1697e43/fs/ext4/namei.c#3)) |
| squashfs                         | directory table: **basename + inode reference**             | by walking the directory table                    | a read-only image optimised for size; readers walk it anyway ([`directory.go`](https://github.com/cusspvz/go-diskfs/blob/v1.2.1/filesystem/squashfs/directory.go#1)) |
| Watchman                         | a **dir node** holding a name table of files and child dirs | by walking the in-memory tree during a query      | queries start at a directory and descend ([`watchman_dir.h`](https://sources.debian.org/src/watchman/4.9.0-7/watchman_dir.h/)) |
| git index, version 4             | the **full path, sorted**, with the common prefix against the previous path stripped and a varint strip length in front | concatenating strip + suffix, sequentially | keeps a flat array that is still binary-searchable and still self-describing ([jgit's implementation](https://eclipse.googlesource.com/jgit/jgit/+/e9cb0a8e475f796e22d01fae63f5820e1fd1f318%5E%21/#F6)) |
| tar / zip central directory      | **name once**, entries carry an offset into the name area   | random access by offset                           | the same trick the trio already uses for `files.txt` |

So both models are established: the **tree-of-basenames** model (ext4, squashfs, Watchman) and the **sorted
flat list with prefix compression** model (git index v4). They are not in conflict; they answer different
constraints. A filesystem must resolve one name at a time, so a directory is the natural unit. An index must be
scanned and diffed whole, so a sorted array with a name table is the natural unit.

There is also a documented case of two indexes over one tree fighting each other — Watchman's index and git's
index — for exactly the reason this document is careful about: each was designed to be *the* description of the
tree ([the git/Watchman thread](http://public-inbox.org/git/1400182971.14179.49.camel@stross/)).

## What the trio already does

The premise "saving file names is more compact" does not apply to this format, because **names are not
duplicated**. Every name appears exactly once in `files.txt`, and each entry carries `nameOffset` + `nameLength`
into it (§ 5) — tar's and zip's central-directory trick, already applied. The file name is not stored in
`files.meta` at all.

What *is* duplicated is the **shared prefix of adjacent names** (`com/apache/fory/…` repeated for every file in a
package). Measured on the benchmark trees, sorted as the trio sorts them:

| Tree                  | Names | `files.txt` | Bytes per name | Repeated prefix bytes         | Prefix-compressed estimate |
| --------------------- | ----: | ----------: | -------------: | ----------------------------: | -------------------------: |
| jcodebuddy `7bfad9a`  | 1961  | 127,669 B   | 65.1           | 98,608 (78.4% of name bytes)  | 31,022 B (24.3%)           |
| Apache Fory `a11d257` | 3881  | 210,599 B   | 54.3           | 155,502 (75.2% of name bytes) | 58,978 B (28.0%)           |

So there *is* a real factor of ~3.5 available — from git v4's technique, which needs no structural change, only
that the reader decompress sequentially once.

## Why it would not help today

The cost that matters is not bytes. From [`benchmark.md`](benchmark.md):

| Operation                                                    | Apache Fory       |
| ------------------------------------------------------------ | ----------------: |
| warm `refresh` (nothing changed)                             | 5,847.7 ms        |
| `verify` (reads both files, hashes both, checks every entry) | 10.1 ms           |
| content hashing of the whole tree                            | +0.6% on the walk |

Reading and validating a 210 KB `files.txt` is inside a **10 ms** operation, in a pass that costs **5,847 ms**.
Compressing the names by 70% would move a fraction of one percent, and it would be paid for by:

- **random access**: with a prefix-compressed `files.txt`, `nameOffset` can no longer point at a name; a reader
  must reconstruct the whole table before it can serve any entry. Acceptable (59 KB), but it changes the contract
  that § 5 states and every reader ports;
- **the tree-of-basenames change is worse**: a file's full path would have to be assembled by walking parent
  references, which is what the *hot* code does constantly — `coldstart` joins `<root>` with a relative directory
  to list it, and the lister and the reconciler both speak in full paths. That trades a measured 0% gain for extra
  work in the one loop that is already 5,800 ms. **This is the "counterproductive" case, and it is the current
  one.**

## Options, with verdicts

| Option                                                                                   | Gain                                                         | Cost                                                                           | Verdict                                                         |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| A. **Status quo** — flat sorted names, offset+length                                     | none                                                         | none                                                                           | **keep now**                                                    |
| B. **Prefix-compressed `files.txt`** (git v4 style), decompressed on load                | ~72–76% of name bytes (210 KB → 59 KB on Fory)               | loses random name access; a reader-side decompressor per port; `files.txt` stops being readable text | keep as the *first* thing to do if the trigger below fires |
| C. **Directory table + parent reference per leaf**                                       | 47-49% of files.txt (73-77% of the trio)                     | a per-entry join for nameHash and for ordering, a directory table in every reader, and new work in the cold-start loop | **no** - measured worse than B on size and costlier on contract |
| D. **Optional sidecar index** (`files.paths.bin`), derived from `files.txt`, rebuildable | same as B, but the readable trio is untouched                | one more derived file; must be declared ignorable and never validated as truth | **preferred shape** if a trigger fires                          |

## Recommendation

**Do not change the path layout now.** Keep the flat sorted name table: it is the shape that keeps names
deduplicated, keeps `nameOffset` meaningful, keeps the text file diffable, and makes a reader's job a binary search
instead of a tree walk.

Record a **trigger** for revisiting, so this is a decision rather than an omission:

- when a tree's `files.txt` exceeds **8 MB** (roughly 150k entries at the observed 54–65 bytes per name), or
- when loading and validating the trio exceeds **20%** of a warm pass in the benchmark,

then adopt **option D**: a `files.paths.bin` sidecar holding git-v4-style prefix-compressed names, generated by the
engine at publish time, *derived* from `files.txt` and never the source of truth. Readers that can use it do;
readers that cannot are unaffected; `verify` ignores it. If the sidecar is deleted, the next publish regenerates it
— it needs no integrity commitment of its own beyond a hash, because it is reproducible from a file that already
has one.

**Option C** (the parent-id tree) should be reconsidered only if the *format's* consumers change shape — that is,
if tools start asking for "children of this directory" far more often than "the path of this file". That is not
the use case written so far: [`use-cases/01-on-demand-checks.md`](use-cases/01-on-demand-checks.md) keys verdicts
by **path**, and a path is what every check reports.

## What this means for the format document

Nothing changes in [`../FORMAT.md`](../FORMAT.md) today. If option D is adopted later it is an additive § 7 field
(`"paths"` in `files.json`, or a declared optional file with its own hash) and a § 9 note about generating it after
`files.txt`, before `files.json` — the commit record stays `files.json` last, because the sidecar is derived and a
reader that has the readable trio loses nothing by ignoring it.