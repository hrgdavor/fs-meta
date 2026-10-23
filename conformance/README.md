> **Status:** `fsmeta-vectors-v2.json` is generated from the engine by `gen-vectors-v2.mjs`, and the cases
> reflect the current format: `files.meta` ordered by `(nameHash, name)`, `files.txt` by name, and a
> directory's stored name ending with `/` (the hash is over the name without it). The older
> `fsmeta-vectors.json` predates both and is kept for history, not for conformance.
# fs-meta conformance vectors

`fsmeta-vectors.json` is the machine-checkable form of [`../FORMAT.md`](../FORMAT.md): every *reader* of the
format asserts it — the Java and Bun readers today — and its blobs are produced from this project's definition
rather than from a reader. The writer is the Zig engine, which is the reference; it is being built, and the day
it can publish these cases are generated from it. The file exists because a format with readers and one writer is
a format with several meanings unless the bytes are pinned.

| Member           | Count | What it pins                                                                                        |
| ---------------- | ----- | --------------------------------------------------------------------------------------------------- |
| `hashCases`      | 24    | `wyhash64` over the lengths that walk its branches — the `<= 16` short path, the 48-byte block loop, multi-block tails — plus the text fixtures the repository already uses |
| `cases`          | 15    | complete trios: the valid pair byte for byte, and every invalid one with the verdict a validator must reach |
| `gitignoreCases` | 16    | trees to materialise plus the file list a walk must produce (the walk's rules are `FORMAT.md` § 16) |
| `repairCase`     | 1     | a pair whose offsets point at the wrong lines, and the entry-to-name pairing `nameHash` recovers    |

Each `cases` entry carries `label`, `verdict`, `untrusted`, `txtHex`, `metaHex` and the sidekick document as
`json`, so a test needs no knowledge of the format beyond *"decode these bytes and tell me what you think"*.
The verdicts are `FORMAT.md` § 8's fixed vocabulary, and the cases include two whose whole point is the order
of the checks (`unsupported-format-beats-meta-size`, `range-beats-name-hash`).

## How the file is produced

```sh
bun fs-meta/conformance/gen-vectors.mjs
```

The generator is committed because the numbers in it must be reproducible and reviewable, and **neither kind of
number in the file may be derived from the implementation it is meant to check**:

- **The hashes** come from the [`wyhash`](https://github.com/hrgdavor/wyhash) project, whose JavaScript port this
  generator imports: that project's reference is the Zig builtin `std.hash.Wyhash`, and the seven
  library-produced golden vectors it asserts — the same ones `ContentHashTest` pins the engine's vendored copy
  to — are the ones `hr.hrg.wyhash:wyhash:1.0.0` produced. The generator refuses to emit anything until that
  implementation reproduces them, so a broken hash cannot become a contract. The binary-pattern cases were
  additionally cross-checked against the builtin directly, which reproduced every one of those library vectors,
  and then this whole generated file byte for byte, apart from the generator's own name in `note`.
- **The byte layout** is assembled in the generator straight from `FORMAT.md`'s field table, with no encoder
  shared with either implementation. An implementation that agrees with these blobs agrees with the published
  spec rather than with another implementation of it — which is the difference between a conformance vector
  and a change detector.
- **The ignore cases** are trees (paths plus `.gitignore` contents) and the expected walk result. Both ports
  materialise them and compare lists, so what is pinned is the *behaviour* and not the regexes behind it.

The file carries its **own** copy of the hash cases rather than pointing at the `wyhash` project's vector file:
a conformance file that says "go and read another project's vectors to know whether this format is intact" is a
file where the contract is not written down. The duplication is 24 cases, and both copies are generated from
the same implementation.

## What has already been caught by it

Recorded because it is the argument for the file existing at all:

- The Java port's first encoder wrote every entry at offset 0 (absolute `putLong` calls plus a manual position
  advance) — the byte-exactness assertion on the `valid` case failed immediately, with the offending offset.
- The Bun port's `.gitignore` matcher anchored only the end of a pattern, so an anchored pattern matched a path
  suffix and the `anchored-pattern` case walked to one file instead of two. Java's `Matcher.matches()` anchors
  the whole pattern; JavaScript's `RegExp.test` searches. Two implementations that had both read the same prose
  disagreed about one character, and the vectors found it on the first run.