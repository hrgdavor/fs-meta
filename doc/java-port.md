# The Java port — what it must become

**Status: the reader is ported.** `FsMetaValidator` implements the twelve verdicts in § 8 order, the codec reads the
current § 5 layout, and `FsMetaConformanceTest` passes **14/14** cases of `conformance/fsmeta-vectors-v2.json`;
the module's suite is **62 tests, 0 failures, 1 skipped** (a symlink privilege). Writing stays with the Zig engine,
which is the only writer; what is described below is the plan that was followed, kept for the record.

*Historical note: this document was written when the Java module predated the format, so its original status line read
"not ported". The plan below is kept as the record of what was followed, not as pending work.*

## What exists, and what it is

`fs-meta/src/main/java` holds a scanner-and-writer built for the **first** version of this format:

| it has                                                      | it lacks                                              |
| ----------------------------------------------------------- | ----------------------------------------------------- |
| the 64-byte entry, in an order that no longer matches (§ 5) | directories and symlinks as entries (§ 16)            |
| `files.txt` and `files.json`                                | the `meta`/`txt` objects with whole-file hashes (§ 7) |
| a `wyhash` dependency (`hr.hrg:wyhash`)                     | any notion of a verdict (§ 8)                         |
| regular-file scanning                                       | `generation`, `hash.normalize`, `scan{}`              |

It is not a broken reader; it is a writer for a format that has moved. The Bun port went through exactly this and is
now a template: same three defects (entry offsets, flag bits, no verdicts), same order to fix them.

## The gate, which is the first thing to write

A JUnit test — `ConformanceTest` — that reads [`../conformance/fsmeta-vectors-v2.json`](../conformance/fsmeta-vectors-v2.json),
materialises each case's three files in a temporary directory, runs the port's validation, and asserts the wire
string equals `expect`:

```java
for (Vector c : Vectors.load("fsmeta-vectors-v2.json")) {
    Path dir = temp.resolve(c.name());
    Files.createDirectories(dir);
    Files.write(dir.resolve("files.meta"), c.meta());   // hex-decoded
    Files.writeString(dir.resolve("files.txt"), c.txt());
    Files.writeString(dir.resolve("files.json"), c.json());
    assertEquals(c.expect(), FsMeta.validate(dir).verdict().wire(), c.name());
}
```

That test is the definition of done. It fails on the current code for every case, which is correct — and it is what
tells a later change whether it helped. The Bun equivalent is
[`../js/conformance.mjs`](../js/conformance.mjs); it started at 8/14 and reached 14/14 in three changes, each one
small enough to verify.

## The three changes, in the order they paid off for Bun

### 1. The codec's offsets (§ 5)

| field         | offset | Java type                              |
| ------------- | -----: | -------------------------------------- |
| `mtimeNs`     | 0      | `long` (unsigned compare for ordering) |
| `sizeBytes`   | 8      | `long`                                 |
| `contentHash` | 16     | `long`                                 |
| `nameHash`    | 24     | `long`                                 |
| `nameOffset`  | 32     | `long`                                 |
| `nameLength`  | 40     | `int`                                  |
| `flags`       | 44     | `int`                                  |
| `fileIdLo`    | 48     | `long`                                 |
| `fileIdHi`    | 56     | `long`                                 |

The Bun defect was a **transposition** of `nameHash`/`sizeBytes` (8 ↔ 24); check the Java constants against this
table before anything else, because a swap there invalidates every per-entry verdict while leaving the sizes right —
which is exactly the confusing symptom the Bun port produced.

### 2. The flag bits (§ 6)

| flag            | value  | rule                              |
| --------------- | -----: | --------------------------------- |
| `CONTENT_KNOWN` | `0x01` | only when a hash was taken        |
| `REGULAR_FILE`  | `0x02` | exactly one kind bit              |
| `IS_DIR`        | `0x04` | never with `CONTENT_KNOWN`        |
| `HASH_LF`       | `0x08` | only with `CONTENT_KNOWN`         |
| `SYMLINK`       | `0x10` | exactly one kind bit              |
| type mask       | `0x16` | one bit set, no other bits at all |

Bun's `HASH_LF` was `0x04`, which § 6 defines as `IS_DIR` — so each hashed file claimed to be a file *and* a
directory. Any combination outside `0x1F`, or more than one kind bit, is `invalid-flags`; nothing is "untrusted but
usable" any more, which is why the old `untrusted` list has no counterpart in the vectors.

### 3. A verdict type (§ 8)

An enum with the twelve wire strings and the checks in the document's order — size before hash, hashes before
entries, names before flags:

```text
ok, unsupported-format, unsupported-version, unsupported-entry-size, unsupported-hash,
meta-size-mismatch, meta-hash-mismatch, txt-size-mismatch, txt-hash-mismatch,
entry-out-of-range, name-hash-mismatch, invalid-flags
```

Two Java-specific points:

- **Validation must not throw on user data.** A trio is input; every failure is a verdict with a detail string. The
  current code throws on malformed input, which is fine for a writer and wrong for a reader.
- **`long` is signed.** Name ordering is by unsigned bytes (`Long.compareUnsigned`, or compare the UTF-8 arrays
  directly), and a hash is compared as `long` bits, not as a number.

## Then, and only then, the writer

With the reader passing 14/14, the scanner has to learn what § 16 lists: directories (for their mtime), symlinks
(never followed), `.git`/`.fs-meta` reserved, `.gitignore` with the same precedence as the Zig and Bun matchers. That
is where the port's remaining behaviour lives, and it is easier to do once the reader can tell it what is wrong.

## The order, as a checklist

1. `ConformanceTest` + a vector loader (fails everywhere: expected).
2. Fix the codec offsets → the size and hash verdicts start matching.
3. Fix the flag bits → `invalid-flags` and the valid case pass (Bun's step that took it to 14/14).
4. Verdict enum and the document's check order → all fourteen.
5. Scanner: directories, symlinks, ignore rules — validated against `scan`-level expectations, not just trios.

Step 5 is the only one that is new code rather than alignment; the first four are the same three defects the Bun
port had, in the same order, against the same gate.