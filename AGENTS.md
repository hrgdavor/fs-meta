# AGENTS.md — rules for this repository

`fs-meta` is a **format and its reference implementation**: the trio (`files.meta`, `files.txt`, `files.json`), the batch
history under `batches/`, and the Zig engine that writes both. It has its own repository, its own version and no parent
(see `jcodebuddy`'s `AGENTS.md` § 2), and it is consumed as an artifact or a checkout.

## 1. The engine writes; ports read

The Zig implementation is the **only writer**. A port (Bun, Java, and anything added later) validates, decodes and loads
what the engine published; it never lays a trio out. A port's tests are therefore a **reader** suite, and its
writing-side tests are kept but gated (`FSMETA_PORT_WRITER=1`) rather than deleted, so that porting the writing side stays
possible. Do not add a writer to a port to make a test pass.

## 2. Format invariants that must not drift

- **`glob` is abandoned and strictly not supported; `wildmatch` is the only wildcard syntax.** That applies here, in
  `gitignore` and in `jcodebuddy`; `java-watch*` predates the decision and is exempt for now. Do not accept braces,
  extglob or any other dialect, and do not add a pattern syntax of your own: a change to the syntax is a change to
  `gitignore`, its vectors, and every implementation that answers them.

- **One wildcard implementation.** Every wildcard is git's `wildmatch` semantics via the `gitignore` project
  (DEC-051); fs-meta has no glob dialect of its own. A new pattern syntax anywhere — the `glob` query, the
  `.gitignore` chain, a future socket request — is a format change, not a local convenience, and it goes
  through that matcher. Do not add a second matcher "for compatibility".
- **A trio contains no absolute path.** Names are workspace-relative, and the root a tool is given is a **locator**:
  it may be absolute or relative, it is resolved once at the boundary into a directory handle, and it is never
  interpolated into a stored byte. Publishing one tree from an absolute root and from a relative root must be
  byte-identical, and a copied or renamed workspace must still verify. `FORMAT.md` § 3.1 states it, and
  `test/portability.test.mjs` is the test: do not add a "where this was scanned" field back, and do not pass a root
  path into a publish.
- **Two orders, one meaning.** `files.meta` is sorted by `(nameHash, name)`; `files.txt` by name in its stored form. They
  describe the same set; a publish that produces them in one order only is a bug, not an optimisation.
- **A directory's stored name ends with `/`**; its `nameHash` and every lookup use the name **without** the slash.
- **Batch ids are the generation in lowercase hex, zero-padded to eight digits** (`batches/0000000a` is generation 10).
  Hex is mandatory, not cosmetic: a bit count divided by four is a digit count, so padding, parsing and any modulo are
  shifts and masks rather than divisions by ten, and the digits line up with the bits the id already occupies. Both the
  writer (`src/batch.zig`) and the CLI (`src/fsmeta.zig`) follow this, and `batch.zig` has a test at generation 16 —
  `00000010` in hex, `00000016` in decimal — because it is the only value that can tell the two apart.
- **The twelve verdicts are vocabulary.** `ok`, `unsupported-format`, `unsupported-version`, `unsupported-entry-size`,
  `unsupported-hash`, `meta-size-mismatch`, `meta-hash-mismatch`, `txt-size-mismatch`, `txt-hash-mismatch`,
  `entry-out-of-range`, `name-hash-mismatch`, `invalid-flags`. A new verdict is a format change: it goes in `FORMAT.md`
  and in the conformance vectors first, then in every implementation.
- **A merge of changes must not require a baseline.** Batches after the recorded generation *are* the changes from it.
  `--baseline` is optional: it exists for rebuilding a full state from an old snapshot (dropping a change that has
  already returned to the known identity), which is a secondary case. The normal shape is: keep the latest state,
  stream each change to listeners, and build the new state from the old one. Do not make a consumer hold a snapshot in
  order to read the change stream, and do not describe the baseline as required.

- **A gap in the batch sequence is an error** (`batch-gap`), never skipped. `batch-too-old` means the consumer's baseline
  predates the oldest retained batch.

## 3. Conformance vectors are the definition

`conformance/fsmeta-vectors-v2.json` is generated **from the engine** by `conformance/gen-vectors-v2.mjs`, and every
implementation must answer it identically. When a port disagrees, the question is which side is wrong; the vector is
edited only when the format itself changes, and then it is regenerated rather than hand-patched.

## 4. Measurement discipline

The bench times a **process**, so a cold run measures loader and JIT as much as the matcher. `--rounds N` (on the CLIs)
repeats the decision loop inside one process and gives steady state; start-up is measured separately, by running the same
command against an empty path list, and subtracted. Run-to-run variance is about 13% at 12 rounds, so **interleave the two

- **A cached build prints no test counts.** `zig build test` against a warm cache reports `37/37 steps succeeded` and
  nothing else, so a count quoted from such a run is stale at best — and this project has had a report that claimed a
  passing total it never ran (`98/100` against a true `300/306`). When a number is going into a report, a commit message
  or a document, run the gate with a fresh `--cache-dir` (`.zig-cache\<something-new>`) and quote what it prints.
configurations in one run** rather than comparing two runs, and do not report a difference smaller than that.

## 5. House rules

- **Scripts are Bun JavaScript** (`#!/usr/bin/env bun`), never `.ps1`, `.cmd`, `.sh`. Java and Zig builds are driven from
  them where a wrapper is needed.
- **Scratch goes in `.tmp/`** (gitignored), never in a tracked directory and never in `zig-out/`.
- **Read and write files with .NET or Bun in PowerShell, not with redirects**: `>` re-encodes to UTF-16 and breaks scripts.
  A relative path passed to `[System.IO.File]` resolves against the *process* directory, not the shell's — use absolute
  paths.
- **Markdown tables** are normalised with `md-fix-tables <file>`; if the tool is missing, say so and carry on.
- **SPDX header** on every source file: `SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause` and
  `Copyright (c) 2026 Davor Hrg`.
- **Zig is 0.17** (`D:\wrk\zig\17\zig.exe` on this machine); `build.zig` refuses other minors on purpose, because 0.17
  moved the `std.Io` surface.
