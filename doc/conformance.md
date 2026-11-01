# How the ports stay one format

`conformance/fsmeta-vectors.json` is the contract. Its blobs are produced from this project's own definition
(§ 15 of `FORMAT.md`) and every *reader* asserts every byte of them — the Java and Bun readers today. The
**writer is the Zig engine**, which is the reference: a reader that agrees with the vectors agrees with the
reference, not with another implementation of it.

| Part of the file          | What it pins                                                                                    |
| ------------------------- | ----------------------------------------------------------------------------------------------- |
| `hashCases` (24)          | `wyhash64` at the lengths that walk its branches, against values produced by the library (and cross-checked against Zig's `std.hash.Wyhash`) |
| `cases` (15)              | complete `files.meta`/`files.txt`/`files.json` triples — the valid pair byte for byte, and every invalid one with the verdict a validator must reach, in the order § 8 checks them |
| `gitignoreCases` (16)     | trees to materialise and the file list a walk must produce, so the two walks are the same walk  |
| `repairCase`              | a pair whose offsets point at the wrong lines, and the entry-to-name pairing the hashes recover |

The vectors are **generated, not hand-written** — `bun fs-meta/conformance/gen-vectors.mjs` — and the generator
refuses to emit anything unless the JS `wyhash64` first reproduces the seven library-produced golden vectors
(the same ones `ContentHashTest` in `hipster-entity-tooling` pins its vendored copy to). The byte layout is
assembled in the generator straight from `FORMAT.md`'s field table, so an implementation that agrees with the
vectors agrees with the published specification rather than with the other implementation of it.

That is not a formality: the ignore vectors caught a real difference between the ports on their first run —
Java's `Matcher.matches()` anchors a pattern while JavaScript's `RegExp.test` searches, so an anchored
`.gitignore` pattern matched a path *suffix* in the Bun walk until it grew an explicit `^`.

`bun fs-meta/check-ports.mjs` closes the loop end to end, past the vectors: it scans one real tree (nested
directories, a CRLF file, a binary file, a name with non-ASCII characters, `.gitignore` rules with a negation
and an excluded directory) with both CLIs and compares what they wrote. `files.meta` and `files.txt` must be
byte-identical, `names` must be the same list, and the two `files.json` documents must agree on everything but
the fields that belong to a publish (`generation`, `created`, `updated`, `writer`) or to this machine (`root`).
It is how the Java port's missing UTF-8 output wrapper was found: the Bun port wrote
`docs/héllo — ünïcode.md`, and the Java one, on the Windows console code page, wrote
`docs/h?llo ? ?n?code.md`.
