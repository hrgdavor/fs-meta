# fs-meta format, version 1

`fs-meta` stores the file-system state of one codebase folder as a **trio of files** that a watcher maintains and any number of other tools read, so that a tool can ask *"is this file still what I indexed last time?"* without walking the tree and re-reading every file.

This document is the **normative specification**, and the **Zig implementation is its reference**: the engine that scans, hashes, publishes and serves. `conformance/fsmeta-vectors.json` is the machine-checkable form of the format — every blob and verdict in it is produced by the reference, and every *reader* asserts it: the Java implementation and the Bun implementation, which read the trio directly.

So there are two kinds of consumer, and the difference is a design rule rather than a convenience. A tool **with** the engine running asks the engine over a local socket: that is the live path, and its protocol is specified separately from this format. A tool **without** one reads the trio: that is the durable path, and this document is all of it. Neither may assume the other — the trio is what survives when the engine stops, and the socket is what makes a running engine cheaper to ask than to re-read the tree.

| Item             | Value                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------- |
| Format name      | `fs-meta`                                                                                      |
| Version          | `1` — **pre-release**, so there is no backward compatibility to keep (§14)                     |
| Entry size       | 64 bytes, little-endian                                                                        |
| Hash             | `wyhash64`, seed 0 — Zig `std.hash.Wyhash`, the hash project's definition (`hr.hrg:wyhash`)    |
| Files            | `files.meta`, `files.txt`, `files.json`                                                        |
| Default location | `<root>/.fs-meta/`                                                                             |
| Reference        | the **Zig implementation** — it is the definition, and it is the engine that scans, publishes and serves |

## 1. Scope, and what the trio is not

The trio is a **snapshot**: it describes the files and directories of one folder as they were when the writer last published. It is a **cache and a starting point, never a correctness input**:

- A tool that finds the trio missing, unreadable or invalid falls back to reading the file system. Nothing built on `fs-meta` may become wrong *because* the trio was absent or stale — only slower.
- The trio does not observe the file system. No read of it can tell you that the file system has **not** changed since the snapshot; it can only tell you what the writer recorded. A tool that needs certainty about one file reads that file.
- A hash recorded here is a claim about the file **as of the generation it was written in**. It is evidence, not a substitute for reading the bytes a decision depends on.

The consumers are a watcher (the writer — this project's Zig engine) and the tools that keep derived state: an index, a parser cache, a codegen cache, an LSP server, or a build step that wants to know which of its outputs are still fresh. The writer is the engine; a client never publishes.

## 2. The three files

All three live in one directory (default `<root>/.fs-meta/`), and none is meaningful without the other two:

| File         | Kind               | Role                                                                             |
| ------------ | ------------------ | -------------------------------------------------------------------------------- |
| `files.txt`  | text, LF-delimited | the names, one per line, in order — the debuggable half                          |
| `files.meta` | binary, fixed-size | one 64-byte entry per name, **same order** — the half programs read              |
| `files.json` | JSON object        | the housekeeping: version, counts, sizes, hashes, generation — the commit record |

`files.meta` and `files.txt` are a **pair**: entry `i` describes the name on line `i`. `files.json` exists so that the compact binary file needs no header, no magic and no self-description: everything a reader must know before interpreting the bytes is in the sidekick, and its hashes make a torn publish detectable.

`files.meta` carries **no header, no magic and no padding**. Entry count is `size / 64`, which is exactly why the entry is 64 bytes (a power of two: `entry(i)` is at `i << 6`, and a count is a shift, not a division). One entry is one cache line.

## 3. Names

A name is the file's or directory's **whole path relative to the project root** — never a basename on its own
(except for an entry that sits directly in the root) and never absolute — with these rules:

- `/` is the separator on every platform (`\` is normalised to `/`, never stored).
- UTF-8. No LF (`0x0A`), no CR (`0x0D`), no NUL.
- No leading `/`, no trailing `/`, no empty segment, no `.` or `..` segment, and never empty. The root itself is never listed; its identity is in `files.json` `root`.
- Case is preserved exactly as the file system reports it; nothing is case-folded. On a case-insensitive file system, two names that differ only in case cannot both be listed.
- Names are ordered by **unsigned byte comparison of their UTF-8 encoding** (i.e. `memcmp`), which is a different order from Java's `String.compareTo` (UTF-16 code units) for some non-BMP characters — a writer must sort on bytes, not on strings.
- Both files and directories are listed. A directory's **path** is written without a trailing slash (`src`): that is the name the hash is taken over and the name a lookup is given. Only its stored line in `files.txt` carries the `/` (§ 4), because the slash is what makes the folder's subtree an exactly bounded byte range. A directory's existence is what carries its mtime for fast readdir skipping.

**A name is the whole path, deliberately.** The alternative — a directory table with each file carrying a parent
reference and only a basename — was measured on two real trees and rejected: it halves `iles.txt (47–49%) and
prefix compression would cut it further (23–26%), but the trio is 130–310 KB on a 3000-entry tree, and **speed
matters more than that size**. Neither alternative makes a pass faster, because the cost of a pass is per entry,
not per byte ([doc/benchmark.md](doc/benchmark.md)); and a full path keeps the shape with the fewest moving
parts — no directory table to index before a name can be compared, hashed or joined, and no path assembly in
front of every check that reports a path. The measurements, the alternatives and the trigger for revisiting are
in [doc/path-layout-research.md](doc/path-layout-research.md).

Two files, two orders, because they answer two different questions.

**`files.meta` is sorted by `(nameHash, name)`** — the hash as unsigned 64-bit, the name as unsigned bytes. An id
lookup has no filename, only a hash, so the hash is the only key that can be binary-searched; the name is the
tie-break that keeps two names sharing a hash adjacent and distinguishable. Two snapshots are joined by one ordered
walk on this key, which is also how a consumer reconciles without comparing paths.

**`files.txt` is sorted by name**, unsigned byte compare of the stored form. It is the file a human reads, a `grep`
searches and a diff between generations compares — and it is where prefix structure is visible, because sorting by
name groups a subtree. Its order is independent of the entries' order in `files.meta`: an entry addresses its name
by `nameOffset`/`nameLength`, not by its position.

**A directory entry's name in `files.txt` ends with `/`** (`src/`, `node_modules/`). A directory is listed like any
other entry — it has an mtime and an id — and the trailing slash is what makes its subtree a contiguous, exactly
bounded region:

```text
src/     <  src/a.java     the folder's own entry comes first
src-b    <  src/a.java     because '-' (0x2D) < '/' (0x2F)
src/a    <  src0           because '/' (0x2F) < '0' (0x30)
```

so a subtree is the byte range `[dir + "/", dir + "0")` — a range a reader can slice without examining a single
name. Without the slash, `[dir, dir + "0")` would also contain `src-b`, a sibling that is not in the subtree.

The **name hash is over the name without the trailing slash** (`wyhash("src")`, not `wyhash("src/")`), because a
lookup is given the path and the path of the folder is `src`. A reader that needs a directory entry's hash strips
the slash; a reader that needs the entry from a name keeps it.

### 3.1 No absolute path, anywhere (invariant)

**A trio contains no absolute path.** Names are workspace-relative (§ 3 above), and nothing else in the three
files records where the workspace is: `root` in `files.json` carries the root's **identity** (`dev`/`inode`), never
its path, and there is no path member at all. `fs-meta` is for tools bound to a **workspace**, so the trio is
evidence about a tree that can be found at any path.

The root a tool is given is therefore a **locator**: it may be absolute or relative, and it is resolved **once**,
at the boundary, into a directory handle. It is never interpolated into a stored byte. Three consequences, and each
one is a test (`test/portability.test.mjs`):

- **Byte-identical publication.** Publishing the same tree from an absolute root and from a relative root produces
  the same `files.meta`, `files.txt` and `files.json` bytes, because the root argument reaches none of them.
- **Portable.** A workspace copied to another directory — the trio included — still verifies there.
- **Relocatable.** A workspace renamed in place still verifies, and its batches still name files by their
  workspace-relative names.

The identity pair in `root` is the one thing that does move: a copied tree has a new identity and a renamed one
keeps the old, so a reader can tell that the directory it was handed is not the one the trio was published for —
without the trio ever recording a location. Nothing in § 8 validates `root`, so a trio is usable whatever it says,
which is what makes a copy or a rename a supported case rather than a tolerated one.

That invariant is also why the format has no optional "where this was scanned" member: an informational path would
be the one field a copy, a rename or a second machine would invalidate, and an informational field that cannot be
trusted is worse than no field at all.

## 4. `files.txt`

The names in order, each **followed by a single LF**, including the last one. So for `n` names:

```
txtBytes = sum(utf8Length(name[i]) + 1)
```

`nameOffset[i]` is the byte offset of the name's first byte; `nameLength[i]` is its length **excluding** the LF; the byte at `nameOffset[i] + nameLength[i]` is the LF. There is no BOM, no CR and no blank line: a blank line would be an empty name, which §3 forbids.

## 5. `files.meta`

One 64-byte record per name, in the same order as `files.txt`, little-endian throughout.

| Offset | Size | Type | Field         | Meaning                                                                        |
| ------ | ---- | ---- | ------------- | ------------------------------------------------------------------------------ |
| 0      | 8    | u64  | `mtimeNs`     | last-modified time, ns since unix epoch; `0` = unknown                         |
| 8      | 8    | u64  | `sizeBytes`   | file length in bytes; `0` for directories                                      |
| 16     | 8    | u64  | `contentHash` | `wyhash64(content)`, per §12; `0` if not known or entry is dir/symlink         |
| 24     | 8    | u64  | `nameHash`    | `wyhash64(name bytes)`, LF excluded - what recovers a broken pairing           |
| 32     | 8    | u64  | `nameOffset`  | byte offset of name in `files.txt`                                             |
| 40     | 4    | u32  | `nameLength`  | byte length of name, LF excluded                                               |
| 44     | 4    | u32  | `flags`       | bit field, §6                                                                  |
| 48     | 8    | u64  | `fileIdLo`    | identity low: `st_ino` on Unix, `dwFileIndex` on Windows                       |
| 56     | 8    | u64  | `fileIdHi`    | identity high: `st_dev` on Unix, `dwVolumeSerialNumber` on Windows             |

Why this order and size:

- **64 bytes** = one cache line, index = `i << 6`. Sequential scan touches one cache line per entry.
- **Fingerprint triple leads**: `mtimeNs`, `sizeBytes`, `contentHash` are first 24 bytes - what a lookup needs first.
- **nameHash next** - for pairing recovery.
- **fileId pair at end** - for rename detection: same `fileIdLo/Hi`, different name = rename, not delete+create. It is one identity in two words, and it is the same two numbers `files.json` keeps for the root: `{ ino, dev }` on Unix, `{ FileIndex, VolumeSerialNumber }` on Windows - not a bit packing, so no port has to guess which bits mean what. A writer fills it in the call that already yields mtime and size (`statx` on Linux, `GetFileInformationByHandle` on Windows); `0, 0` means *unknown* and is legal - such an entry simply loses rename detection, never correctness.
- `mtimeNs` is ns, not ms. ms loses modifications within 1ms, common during builds. Value `0` is unknown. Stored as unsigned ns since epoch, fits until 2262. Comparison is equality only.

## 6. Entry flags

| Bit    | Name            | Meaning                                                          |
| ------ | --------------- | ---------------------------------------------------------------- |
| `0x01` | `CONTENT_KNOWN` | `mtimeNs`, `contentHash`, `sizeBytes` valid (dirs never have it) |
| `0x02` | `REGULAR_FILE`  | regular file                                                     |
| `0x04` | `IS_DIR`        | directory - `sizeBytes` and `contentHash` are 0                  |
| `0x08` | `HASH_LF`       | `contentHash` was over LF-normalised content                     |
| `0x10` | `SYMLINK`       | symlink - listed but not followed                                |
| rest   | —               | reserved, must be 0                                              |

Rules:

- Exactly one of `REGULAR_FILE`, `IS_DIR`, `SYMLINK` must be set.
- `CONTENT_KNOWN` clear means "listing only" - file exists, no fingerprint taken. Different from zero-length file which has `CONTENT_KNOWN` set and `size=0`.
- `IS_DIR` entries never have `CONTENT_KNOWN`, never have `contentHash`. Their `mtimeNs` is the directory's own mtime - what makes cold-start readdir skipping work.
- `SYMLINK` entries describe the link, not its target: `sizeBytes` is 0, `contentHash` is 0, and `mtimeNs` and the `fileId` pair are the link's own (an `lstat`, never a `stat`).
- `HASH_LF` is only meaningful with `CONTENT_KNOWN` and MUST be 0 otherwise.
- **No forward compatibility in v1.** A bit this document does not define - or a flag word that does not set exactly one type bit - makes the **trio invalid** (`invalid-flags`, §8 check 10). The engine is the only writer, so such a bit is corruption rather than a newer writer. *Untrusted* is a different and legitimate state: an entry with `CONTENT_KNOWN` clear.

## 7. `files.json`

UTF-8 JSON object, no comment. The commit record.

| Key              | Type   | Meaning                                                                                       |
| ---------------- | ------ | --------------------------------------------------------------------------------------------- |
| `format`         | string | `"fs-meta"`                                                                                   |
| `version`        | number | `1`                                                                                           |
| `entrySize`      | number | `64`                                                                                          |
| `order`          | string | `"utf8-bytes"`                                                                                |
| `generation`     | number | increments on every publish                                                                   |
| `count`          | number | number of entries                                                                             |
| `meta`           | object | `{ "bytes": number, "wyhash": "hex u64" }`                                                    |
| `txt`            | object | `{ "bytes": number, "wyhash": "hex u64" }`                                                    |
| `hash.content`   | string | `"wyhash64"`                                                                                  |
| `hash.name`      | string | `"wyhash64"`                                                                                  |
| `hash.seed`      | number | `0`                                                                                           |
| `hash.normalize` | string | `"none"`, `"lf"`, or `"text"`                                                                 |
| `updated`        | string | RFC3339 instant of this publish, informational                                                |
| `created`        | string | RFC3339 instant of the trio's first publish, informational; a rewriter keeps it               |
| `writer`         | string | tool/version, informational (`fs-meta/1` is the engine)                                       |
| `root`           | object | `{ "dev": number, "ino": number }` - identity of the root directory; a copied tree has a different one, a renamed tree keeps it (§ 3.1) |
| `scan`           | object | optional, the settings the engine used: `{ "hashMode": "text" \| "lf" \| "none", "ignoredDirectoryNames": [string], "respectGitignore": boolean }` |
| `roots`          | object | optional, § 18: `{ "<direct child>": { "offset": number, "length": number } }` — byte ranges in `files.txt`, each covering the folder's own `dir/` line and its subtree |

Required keys: `format`, `version`, `entrySize`, `count`, `meta.bytes`, `meta.wyhash`, `txt.bytes`, `txt.wyhash`, `hash.content`, `hash.name`, `hash.seed`. Unknown keys ignored and preserved by rewriter.

`meta.wyhash` and `txt.wyhash` are wyhash64 of the entire file bytes. They detect torn publish and bitrot, not just size mismatch.

## 8. Validation

First failure wins, in order:

| Order | Check                                                                                           | Verdict                                     |
| ----- | ----------------------------------------------------------------------------------------------- | ------------------------------------------- |
| 1     | `files.json` parses, has the required keys, and their types are right — a `wyhash` value is 16 lowercase hex characters | `unsupported-format` |
| 2     | `format == "fs-meta"`                                                                           | `unsupported-format`                        |
| 3     | `version == 1`                                                                                  | `unsupported-version`                       |
| 4     | `entrySize == 64`                                                                               | `unsupported-entry-size`                    |
| 5     | hash fields match                                                                               | `unsupported-hash`                          |
| 6     | size first: `meta.bytes % 64 == 0`, `meta.bytes == count << 6`, `meta.bytes == json.meta.bytes` | `meta-size-mismatch`                        |
| 6b    | then: `wyhash(files.meta) == json.meta.wyhash`                                                  | `meta-hash-mismatch`                        |
| 7     | size and lines first: `txt.bytes == json.txt.bytes`, LF count == count, ends with LF (unless count 0) | `txt-size-mismatch`                   |
| 7b    | then: `wyhash(files.txt) == json.txt.wyhash`                                                    | `txt-hash-mismatch`                         |
| 8     | each entry: `nameLength>0`, `nameOffset+nameLength+1 <= txtBytes`, byte at end is LF            | `entry-out-of-range`                        |
| 9     | each entry: `wyhash(name slice) == nameHash`                                                    | `name-hash-mismatch`                        |
| 10    | each entry: exactly one type bit set, reserved bits 0                                           | `invalid-flags`                             |

Verdicts: `ok`, `unsupported-format`, `unsupported-version`, `unsupported-entry-size`, `unsupported-hash`, `meta-size-mismatch`, `meta-hash-mismatch`, `txt-size-mismatch`, `txt-hash-mismatch`, `entry-out-of-range`, `name-hash-mismatch`, `invalid-flags`.

Name order is not validated - it would make two readers diverge. A reader that needs mapping builds one by hash.

Failing verdict = trio unusable, fall back to FS.

## 9. Publishing

Write order that makes torn publish detectable:

1. Write `files.meta.tmp`, flush, fsync file
2. Write `files.txt.tmp`, flush, fsync file
3. Compute `wyhash` of both tmp files
4. Write `files.json.tmp` containing `meta.bytes`, `meta.wyhash`, `txt.bytes`, `txt.wyhash`, `count`, `generation+1`, flush, fsync
5. `fsync` parent directory fd
6. Rename `files.meta.tmp` -> `files.meta` (atomic)
7. Rename `files.txt.tmp` -> `files.txt` (atomic)
8. Rename `files.json.tmp` -> `files.json` (atomic, last - commit record)
9. `fsync` parent directory fd again

`fsync` on a directory is a promise Unix can keep and Windows cannot: there is no directory handle to flush in the JDK, and `fsync` on a directory fd is not part of Win32. The engine treats steps 5 and 9 as **best effort** — where the platform allows it, it happens; where it does not, the file fsyncs are the guarantee and the window left open is exactly what the whole-file hashes in `files.json` close.

A crash before step 8 leaves old json with old hashes - check 6/7 catches new files. A crash after step 8 but before 9 may lose rename on ext4 - second dir fsync ensures durability.

One writer owns the trio. No lock. Two concurrent writers = undefined.

## 10. Recovery

`nameHash` allows rebuilding pairing if offsets are wrong: match each entry to distinct line in `files.txt` whose bytes hash to `nameHash`, then verify byte equality to handle collision. If every entry finds distinct line, pairing rebuilt and re-sorted, then republished. Reader does not repair, only validates.

`fileIdLo/Hi` allows rename recovery: if two entries in old and new snapshot have same fileId but different names, it's a rename, not delete+create.

## 11. Using the trio: incremental pattern

1. Tool records `mtimeNs`, `sizeBytes`, `contentHash`, `fileId`, `generation`.
2. To revalidate:
  - fileId same but name different = rename, keep derived work, update name
  - all three `mtimeNs`, `sizeBytes`, `contentHash` equal = still valid, no read
  - hash equal, mtime/size differ = touched, work valid
  - hash differ or size differ = changed, re-read
  - entry missing or `IS_DIR` = new/deleted, check FS
  - untrusted/listing-only = read file
3. `mtimeNs` equality never proves content equality. It's pre-filter.
4. Dir entries: if `IS_DIR` and `mtimeNs` equal to cached, child name list is same, no readdir needed. Still need to stat children for their own mtime changes - dir mtime does not change on child content change.

Warm start reads one `files.meta` (one cache line per file) instead of walking tree.

## 12. Hashing

- wyhash64 seed 0 over bytes as read. Name hashes without LF.
- `hash.normalize` selects default content mode, per-entry `HASH_LF` authoritative:
  - `none` = raw bytes
  - `lf` = normalize `\r\n` and `\r` -> `\n` before hash
  - `text` = per-file decision, NUL => raw, else normalized
- Algorithm fixed: Zig `std.hash.Wyhash`, published as `hr.hrg:wyhash` — the hash project in this repository's tree is where its ports and vectors live.

## 13. Worked example

Two files, one dir:

| Name         | Type | Content        | mtimeNs               |
| ------------ | ---- | -------------- | --------------------- |
| `a.txt`      | file | `hello\n`      | `1700000000123000000` |
| `src`        | dir  | -              | `1700000001000000000` |
| `src/b.java` | file | `class B {}\n` | `1700000001456000000` |

`files.txt`: `a.txt\nsrc\nsrc/b.java\n` = 21 bytes

`files.meta` 192 bytes, 3 entries:

Entry 0 file `a.txt`: mtime `0x1760...`, size 6, contentHash wyhash(`hello\n`), nameHash wyhash(`a.txt`), offset 0 len 5 flags `REGULAR_FILE|CONTENT_KNOWN`, fileIdLo=ino, fileIdHi=dev

Entry 1 dir `src`: mtime dir, size 0, contentHash 0, nameHash wyhash(`src`), offset 6 len 3 flags `IS_DIR`, fileId = dir inode

Entry 2 file `src/b.java`: ...

`files.json`:

```json
{
  "format": "fs-meta",
  "version": 1,
  "entrySize": 64,
  "order": "utf8-bytes",
  "generation": 1,
  "count": 3,
  "meta": { "bytes": 192, "wyhash": "0123abcd..." },
  "txt": { "bytes": 21, "wyhash": "4567ef01..." },
  "hash": { "content": "wyhash64", "name": "wyhash64", "seed": 0, "normalize": "text" },
  "root": { "dev": 16777220, "ino": 1 },
  "updated": "2026-10-16T11:33:30.123Z",
  "writer": "fs-meta/1"
}
```

The vectors are the worked form of this section: each case in `conformance/fsmeta-vectors.json` carries the exact `files.meta` and `files.txt` bytes, the `files.json` that describes them, and the verdict a reader must reach. The example above stays illustrative on purpose — a document that repeats byte counts rots, and the vectors are generated.

## 14. Versioning

**Version 1 is pre-release.** No trio exists outside this repository, no other tool reads one, and the version has already been revised once while the format was being designed. There is therefore **no backward compatibility to keep**: a reader may reject anything that is not exactly this document, and the implementation is changed rather than versioned.

That ends at the first release. From then on a new version is required for a layout, entry-size, hash-algorithm or order-rule change, or for any change to what a field means. An optional JSON key, an informational key or a clarification does not need one. A reader rejects an unknown version (`unsupported-version`) and never guesses.

## 15. Deliberate omissions

- No tombstones - deletion = absent name, history = diff generations
- No per-file mode/permissions - not needed for content identity, add in v2 if needed
- No lock - one writer
- No per-file checksum of pair beyond wyhash in json - sizes+hashes detect torn publish
- No allocation map - dense ordered array is intentional

## 16. What a writer lists

- Regular files, directories, and symlinks (symlink listed as SYMLINK, not followed)
- `.git` and `.fs-meta` never listed
- `.gitignore` honoured with git precedence: patterns apply only below its dir, last match wins, `!` re-includes, trailing `/` = dirs only, excluded dir not entered, `**` follows git's three cases. Matching case-sensitive on every platform.
- Writer default hash mode `text`: CRLF and LF checkout produce same hash for text, NUL = raw
- Writer must `lstat` not `stat` to see symlink, and `statx`/`GetFileInformationByHandle` to get fileId+mtimeNs+size in one syscall
- The writer is the engine. A client does not publish; it reads the trio, or asks the engine over the socket for the live path

Vectors in `conformance/fsmeta-vectors.json` pin ignore cases and hashes.

## 17. Batches

**Status: working design.** The folder layout is fixed enough to implement; the storage is not. The long-term
shape is one append-only log with rotation (a WAL), not a directory of small files, and that change must not be
visible to a consumer — see § 17.6.

### 17.1 What a batch is

A tool that maintains its own index needs to know what changed since it last synced, without walking the tree.
A **batch** is the set of names whose state changed between one generation and the next, stored in the same trio
format as the main meta.

```text
.fs-meta/
  files.meta  files.txt  files.json    the current state (generation N)
  batches/
    00000001/  files.meta files.txt files.json   the change set for generation 1
    00000002/  ...
```

- A batch directory is named with the generation in **lowercase hex, zero-padded to eight digits** (`0000000a` is
  generation 10). Hex is a requirement rather than a style: a bit count divided by four is a digit count, so the
  digits needed, the parse and any modulo are shifts and masks rather than divisions by ten, and the digits line up
  with the bits the id already occupies. A validator that sees a name which is not hex is looking at a foreign file,
  not at a batch.
- The number is the **generation** the batch produces: batch `N` describes the step from generation `N-1` to
  `N`, and the main trio after that publish carries `"generation": N`.
- Numbers are dense from 1. A gap or a duplicate is diagnosed (`batch-gap`), never skipped: a consumer that
  skipped a batch would silently miss a change.
- **A merge of changes needs no baseline.** A consumer that recorded generation `4` reads batches `5`, `6`, `7` … and
  those *are* the changes from `4`; the state at `4` is not needed in order to see them. `--baseline <root>` is
  optional and secondary: it lets a merge drop a change whose identity has already returned to what the consumer holds,
  which is useful when rebuilding a full state from a snapshot. That recovery case is **not the focus**. The usual
  consumer keeps the latest state (sometimes the previous one as well), streams each change to its event listeners as
  the batch arrives, and builds the next state from the current one — so the change stream, not the snapshot, is the
  interface that matters.
- A consumer reconciles from the generation it recorded: `fsmeta reconcile <root> <from> [to] [--json]` folds the batches
  after `from` into one record of `added`, `changed` and `deleted`. Two refusals are **errors**, not empty answers:
  **`batch-gap`** when a batch in the range is absent, and **`batch-too-old`** when `from` predates the oldest batch
  still retained. Either means the consumer must rescan; neither may be reported as "nothing changed".
- A pass that changes nothing writes **no** batch, so the sequence advances only when the tree does.
- The first trio is generation `0` and may have no `batches/` folder at all.

### 17.2 The entry, and the change bits

A batch entry is an ordinary § 5 entry for the **new** state of the name, with one change bit set in `flags`:

| Flag             | Value  | Meaning                                         |
| ---------------- | ------ | ----------------------------------------------- |
| `CHANGE_ADDED`   | `0x20` | the name did not exist in the parent generation |
| `CHANGE_CHANGED` | `0x40` | it existed, and its entry (§ 11) differs        |
| `CHANGE_DELETED` | `0x80` | it existed, and is now absent                   |

- **Exactly one** change bit is set on every entry in a batch. A batch entry without one, or with two, is
  `invalid-flags`.
- The change bits are **never** set in the main trio: there they are unknown bits, which § 6 already makes
  `invalid-flags`. Validation therefore has two modes, `meta` and `batch`.
- A `CHANGE_DELETED` entry carries no content: `CONTENT_KNOWN` and `HASH_LF` are clear, `sizeBytes` and
  `mtimeNs` are `0`, and the kind bits describe what the name **was** (a deleted directory is `IS_DIR`). The
  name is still present in `files.txt`, because the batch must say *which* name disappeared.
- A batch is otherwise a trio: `files.meta` is the entries, `files.txt` the names (whole path relative to the
  root, LF-terminated, sorted), `files.json` the same sidekick with `count`, `meta`, `txt`, `hash`, and
  `generation` equal to the batch number.

Additional required JSON keys for a batch:

```json
"batch": { "number": 14, "parent": 13, "added": 2, "changed": 5, "deleted": 1 }
```

The three counts must equal the entries with the matching change bit; a mismatch is `batch-count-mismatch`.

### 17.2a Order: the meta by name hash, the text by name

A batch follows both orders of § 4: its `files.meta` by `(nameHash, name)`, its `files.txt` by name in stored form,
the directory slash included. The hash is the key a consumer *joins* on, so the meta order is the one a batch
cannot spell differently — and it is why a batch and the main meta are consumed by the same ordered walk:

- two batches are combined by one ordered walk over two lists — no lookup, no allocation, no string compare;
- a name history across N batches is a join on the same key;
- a batch needs no name index of its own to be consumed, and a consumer needs no trie.

The sort key is the pair (nameHash, name), name compared as unsigned bytes. A 64-bit hash can collide, and the
name is the tie-break that keeps such a pair ordered deterministically and distinguishable — a fold that keyed on
the hash alone would report two different files as one file changing twice.

`files.txt` in a batch is written in name order, so `nameOffset`/`nameLength` still address the names (a name is
stored whole, as always), and the entry order stays the meta order: the two orders are independent by
construction, because an entry addresses its name by offset (§ 4).

A consumer that walks a batch must therefore compare hashes first and names only when they are equal. Ports that
cannot express an unsigned 64-bit order (Java's signed long) compare with an unsigned comparison.

### 17.3 Why it is not a tombstone log

A batch supersedes "deletion = absent name" (§ 15) **for the window it covers only**: the main trio still has no
tombstones, and a name that is gone is absent from it. The batch is the only place the disappearance is recorded,
which is why a consumer must not delete its batches before every reader has advanced past them (§ 17.6).

### 17.4 Reconcile: from a batch to a batch

A tool knows it synced at batch 11. It is called again when the latest is 14. It needs the **combined** change:
what to add, update or remove in its own index, as if 11 to 14 had happened in one step.

```text
reconcile(root, from = 11, to = 14, baseline?) -> Change[]

Change = { name, kind: added | changed | deleted, entry? }
```

`baseline` is an optional map `name -> entry` describing the state at `from` as the **consumer** recorded it.
It is optional because a consumer may not have kept it — but without it one case is undecidable (§ 17.5).

The algorithm reads batches `from + 1` to `to` in order and, per name, keeps the first and last event:

| first → last      | combined                                                             |
| ----------------- | -------------------------------------------------------------------- |
| added → changed   | `added` (final entry)                                                |
| added → deleted   | **nothing** (it never existed at `from`, and does not exist at `to`) |
| changed → changed | `changed` (final entry)                                              |
| changed → deleted | `deleted`                                                            |
| deleted → added   | `changed` (it existed at `from`; the name is back)                   |
| deleted → changed | `changed` (final entry)                                              |
| deleted → deleted | `deleted`                                                            |
| any → (same)      | as the first row of the pair, with the final entry                   |

Then the **baseline check**, which is the case the design exists for: switching to a branch and back changes a
file twice, ending at the hash it started with. With a baseline entry for that name,

- `changed` whose final entry equals the baseline entry (§ 11 identity: same `contentHash`, `sizeBytes`, flags)
  is **dropped** — the consumer's index already holds exactly that state;
- `deleted` whose baseline says the name was absent is dropped (it cannot be absent twice);
- `added` whose baseline says the name was present with the final entry is dropped.

Without a baseline, `changed → changed` collapses to one `changed`, which is correct but may reconcile to a
no-op the consumer does not need. That is a cost, not a wrong answer: the record is still a superset of the
real change, and applying it is idempotent.

### 17.5 What a consumer must not do

- **Must not parse `batches/` itself.** The layout is working design (§ 17.1) and becomes a log; the API is the
  contract. A port that walks the folder will break when the storage changes, and the format exists so that it
  does not have to.
- **Must not assume dense batches are permanent forever**: retention (§ 17.6) will delete old ones. A consumer
  whose `from` is older than the oldest retained batch is told `batch-too-old` and must fall back to a full
  pass — an explicit answer, never a silent partial reconcile.
- **Must not infer "unchanged" from the main trio alone** in the window it is reconciling: the trio is the end
  state, and a file that changed and changed back is invisible in it.

### 17.6 Storage, retention, and what is deliberately not decided yet

The directory of trios is chosen because it needs no new parser and lets a batch be validated exactly like a
trio. It is **not** the final design:

- One append-only file per generation, with a header per batch, is cheaper (one open instead of three, no
  directory per write) and can be rotated by appending a sequence marker; a reader replays from an offset.
- Retention: a window (e.g. the last 32 generations, or everything a socket client could need) plus a
  `reconcile` answer of `batch-too-old` when the window is exceeded. Deleting batches is safe only for
  consumers known to be past them; the socket (§ 12) is the place to know that.
- Whether a batch is written before or after the main trio: the tentative answer is **after** (the trio is the
  commit record, § 9), with a missing batch diagnosed as `batch-gap` rather than reconstructed, because a
  guessed batch is a wrong change record.

None of that changes the API in § 17.4, which is why the API is specified first.

## 18. roots: where the direct children live

`files.json` carries one lookup accelerator:

```json
"roots": {
  "docs": { "offset": 91, "length": 1200 },
  "src":  { "offset": 1300, "length": 8400 }
}
```

- Keys are the **direct children of the root only**. A folder nested deeper is reached through its parent's range; a
  nested folder never gets a key of its own.
- `offset` and `length` are **bytes in `files.txt`**, covering the folder's own entry (the `dir/` name) and
  everything below it, so one range is the whole subtree.
- The range is exactly `[dir + "/", dir + "0")` (§ 4). A consumer reads it without checking a name; a prefix check is
  needed only when the range answers a *lookup* rather than a scan, so a malformed range cannot quietly return a
  sibling.
- **Root-level files are not listed.** They are whatever no range covers, and nothing needs a range over them: a direct
  lookup is a binary search in `files.txt`, and an id lookup never reads the text file at all.
- The map is **optional**. A reader that finds no `roots` scans `files.txt`; a writer that cannot compute it cheaply
  omits it. Nothing may be inferred from its absence, and an unknown key must survive a rewrite (§ 7).

The cost is two numbers per top-level folder and no per-file data, which is why this belongs in the sidekick rather
than in a second index file.
