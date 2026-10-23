# Next steps — fs-meta

Runnable plan, in order, **after** the `gitignore` extraction. The first section is what the move changed and how to
keep it in sync; the second is the work that was already planned and is unaffected; the third is the ports.

Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate:

```text
cd fs-meta
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
```

Today: **37/37 steps, 298/304 tests** (6 platform skips). Before the move it was 41 steps: the four file-modules for
the matcher and the chain left with their 27 tests.

## A. Sync with the gitignore move

**A1. Keep the dependency sane until it is published.**

- `fs-meta/build.zig.zon` has `.gitignore = .{ .path = "../gitignore" }` — a **path dependency**, so the two projects
  must stay in the same checkout until the matcher is tagged.
- `fs-meta/build.zig` mounts the dependency's files as modules **under their file names**
  (`gitignore.zig`, `ignore.zig`) via `basis_imports`, which is why no `@import` in `fs-meta` changed. If the
  dependency is ever restructured, this is the one place to edit.
- When `gitignore` publishes: replace the path with a version range, delete `../gitignore` from the build's reach, and
  re-run the gate. Acceptance: same test count, no path reference left (`grep -r "\.\./gitignore" fs-meta`).

**A2. Do not re-add the moved files.** `.gitignore` parsing, the chain and `globMatch` live in
[`../gitignore/`](../gitignore/README.md); a change to matching behaviour belongs there, with a vector and a bench row,
not in `fs-meta`. The practical test: if a change needs `src/gitignore.zig`, it is a change to the other project.

**A3. Measure through the other project from now on.** `fs-meta`'s own numbers (`doc/benchmark.md`,
`doc/gitignore-and-optimisations.md`) now describe a matcher it does not own; when the matcher changes, the numbers are
re-measured in `gitignore/bench` and `fs-meta`'s documents link there instead of restating them.

## B. The pair layout (the open defect)

Full detail, with the code, is in [`plans/next-session-pair-layout.md`](next-session-pair-layout.md). Summary:

- **B1.** Add the count assertion in `publish` before `pair.layout`:
  `items.items.len == cache.files.count() + cache.dirs.count() - 1`. It either fires (the item loop) or holds (a real
  cache entry the walker prunes), and that answer is the next step.
- **B2.** Convert `publish` to `pair.layout` (the fragment is written in the plan), pass `laid.roots` into `json_doc`
  (§ 18), and stop freeing meta/txt in a `defer` because `Outcome` returns them.
- **B3.** Two tests move with it: `publish`'s literal becomes `"a.txt\nsrc/\nsrc/b.java\n"`, and `engine`'s
  `expectNameSets` compares membership with `trimSlash` (and its diagnostic `for (a, b, 0..)` must go, it panics on
  unequal lengths).
- **B4.** Acceptance: gate green, and on a scratch tree `files.txt` is name-ordered with slashed directories and
  `files.json` carries `roots`.

## C. The batches' consumer entry point

- **C1.** `fsmeta reconcile <dir> --from N [--to M] [--format json|lines] [--baseline <file>]`:
  read the main trio's `generation`, `batch.decode` each `batches/<g>` for `g` in `N+1..=M`, `batch.toEvents`,
  `reconcile.collapse` with the optional baseline, print `+`/`~`/`-` lines or the JSON.
- **C2.** The two refusals: `batch-gap` (a missing generation in the range) and `batch-too-old` (`--from` below the
  oldest retained batch). Both are named in `FORMAT.md` § 17.5 and neither may fall back to a partial reconcile.
- **C3.** Acceptance: a two-change scratch tree, `reconcile --from 1` returns exactly the added file; `--from 0` returns
  the whole tree as added (a first sync), and the same window with a baseline returns no changes.

## D. The socket server

`FORMAT.socket.md` and `src/wire.zig` define the bytes; the missing piece is the transport.

- **D1.** Accept on a unix socket, exchange `HELLO` both directions at once, check it with `wire.checkHello`.
- **D2.** `SUBSCRIBE{from}` → for each generation, `batch.decode` + `writeChangeEntry` per entry + `END_BATCH`; the
  two `ERROR`s are `batch-too-old` and `batch-gap`.
- **D3.** The live path: a pass that publishes generation `g` sends the same three message kinds to subscribers sitting
  at `g-1`.
- **D4.** Acceptance: a client written in Bun (or curl-like) receives a replay identical to reading the batch folder.

## E. Ports

- **E1. Bun reader** — `fs-meta/js` still speaks the old 64-byte layout: `nameHash`/`sizeBytes` transposed, no
  directories, no `roots`. Owner: the port, against `conformance` vectors.
- **E2. Java reader** — [`doc/java-port.md`](doc/java-port.md) is the ordered plan; nothing implemented.
- **E3. Both ports' matchers** should consume `gitignore`'s vectors and bench rather than re-deriving them.

## F. Retention and the WAL (deliberately open)

`FORMAT.md` § 17.6: a per-generation file or one append-only log, a retention window, and the point at which
`batch-too-old` becomes reachable. No code depends on the answer: `diff`, `encode`, `decode` and `collapse` all survive
it unchanged.

- `reconcile --baseline <root>`: specified in [`reconcile-baseline.md`](reconcile-baseline.md); the adapter, the flags it must reconstruct, and the test that proves it.
