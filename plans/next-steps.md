# Next steps — fs-meta

Runnable plan, in order, **after** the `gitignore` extraction. The first section is what the move changed and how to
keep it in sync; the second is the work that was already planned and is unaffected; the third is the ports.

Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate:

```text
cd fs-meta
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
```

Today: **37/37 steps, 321/327 tests** (6 skipped — **two** platform guards, each counted in three test binaries;
see § G). Before the move it was 41 steps: the four file-modules for the matcher and the chain left with their 27
tests.

The Bun gate (`bun test`, which runs `js/` and `test/`) is **71 pass, 4 skip, 0 fail** across 75 tests: three
writer-scope tests (§ G1) and one POSIX-only socket assertion (§ G2).

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

## G. The skips, and why each one is deliberate

A fresh-cache gate prints `321/327 tests passed (6 skipped)`. That is **two** Zig tests counted in three test
binaries — `scan`, `lister` and `engine` all import `scan.zig`, and a test binary runs its imports' tests too — so
the six are not six separate gaps. Both skip sites print their platform and condition before returning
`error.SkipZigTest`; `zig build test` echoes them once per test binary (the three that import `scan.zig`),
preceded by the builder's `+- run test` / `failed command:` context header. That header is the builder showing a
step's stderr, not a failed step: the summary still ends `37/37 steps succeeded`. A direct run of the binary shows
the same reason next to its `SKIP` line.

| Test (`src/scan.zig`)                                   | Why it skips | What would close it                                                                     |
| ------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------- |
| `a symlink is listed as a symlink and never followed`   | Creating a symbolic link needs `SeCreateSymbolicLinkPrivilege` or Windows Developer Mode. This host has neither: the call returns `AccessDenied` (probed directly too), so the walk's symlink case cannot be constructed. The kind mapping is still covered by `the kind mapping covers all three listed kinds`. | Run the gate on a host or account that grants the privilege, or with Developer Mode on. |
| `a name the format cannot store is skipped and counted` | Win32/NTFS cannot construct any name § 3 forbids: `\` is the path separator, the control characters (LF/CR/NUL) are rejected (`BadPathName` when probed), and an invalid-UTF-16 name cannot be passed through Zig's path conversion. | POSIX CI runs it. A Windows fixture would need a native `NtCreateFile` with an unpaired surrogate; the engine has no reason to grow one. |

**G1. The Bun writer tests (3) — feature missing, not a host limitation.** `js/fsmeta.test.mjs` keeps the port's
writing-side cases (`the worked example is byte-exact in both directions`, `every pair case reaches the verdict it
records`, `the repair case recovers the pairing from the hashes`) because porting the writing side stays possible.
They are declared through a `writerTest` helper that calls `test.skip` with the reason in the reported name, so
`bun test` prints `4 skip` and never counts them as passes; the reason is "writer scope: the Zig engine is the only
writer (AGENTS.md § 1); set FSMETA_PORT_WRITER=1 to run it". With `FSMETA_PORT_WRITER=1 bun test` they run and are
expected to fail until the port learns the two-order layout — that is the writer half of E1, and it is the one gap
this plan keeps open on purpose.

**G2. The POSIX-only socket assertion (1) — platform guard, no gap.** `test/socket.test.mjs` runs its four replay
tests on Windows AF_UNIX; only `POSIX: the bound address is a socket node…` is skipped, with the reason "this host
is win32; an S_ISSOCK node on the bound address is POSIX-only". Linux/macOS CI is what covers it.

## The daemon

A long-lived process that tracks several roots, keeps a Unix socket per root for consumers, and decides when each root is worth watching (`off` / `always` / `auto` with a per-root idle timeout, so a slept root wakes with one full scan and a diff). Planned in [daemon.md](daemon.md); Zig only, and shaped so a root can later be served by its own child daemon without changing the consumer socket.
