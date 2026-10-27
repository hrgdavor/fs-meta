# Next steps — fs-meta

Status and remaining plan for `fs-meta`, in the order the work happened. The sections below are kept as the record:
A–E and J are **done** (with their acceptance evidence), § F is the one deliberate open decision, and § K names what is
actually left. G counts the platform skips, H is a fixed defect's history, and I records two decisions about output.

Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate:

```text
cd fs-meta
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
```

Today: **50/50 steps, 755/763 tests** (8 skipped — **two** platform guards, each counted in four test binaries; see
§ G). The growth from the 40 steps / 431 tests this file used to record is the daemon and the worktrees plan
([`worktrees.md`](worktrees.md)): the latter added `boundary`, `gitdir`, `ignores`, `nesting` and `seed` as modules,
the daemon's `gitwatch`/`hooks`, and their tests.

The Bun gate (`bun test`, which runs `js/` and `test/`) is **130 pass, 5 skip, 0 fail** across 135 tests: three
writer-scope tests (§ G1), one POSIX-only socket assertion (§ G2), one Linux-only watch-bound measurement (§ G3, new
with the worktrees plan), and the suites the daemon and worktrees work added
(`test/daemon.test.mjs`, `test/daemon-parity.test.mjs`, `test/query-cli.test.mjs`, `test/ignored-cli.test.mjs`).

**Status of the sections below, verified against the code:** A (the gitignore move) is done — the dependency is a
pinned URL, not a path; B (pair layout) is done — `publish` lays out through `pair.layout` with the count assertion
and emits `roots`; C (the batches' consumer entry point) is done — `fsmeta reconcile`, both refusals, the baseline;
D (the socket server, live included) is done — `fsmeta serve`, `test/socket.test.mjs`; E1–E3 (both ports and their
matchers on the vendored vectors) are done; **J (the worktrees plan) is done** — M0–M7 plus the gap-closure batch.
**F remains deliberately open**, § H was a real defect and is fixed, and § I records two small warts.

## A. Sync with the gitignore move (done)

**A1. The dependency is published and pinned (done).**

- `fs-meta/build.zig.zon` pins `.gitignore` to `github.com/hrgdavor/gitignore` tag **v0.3.5** by URL and hash, and
  `nightwatch` the same way; there is no `../gitignore` path left, so the two projects no longer have to share a
  checkout.
- `fs-meta/build.zig` mounts the dependency's files as modules **under their file names**
  (`gitignore.zig`, `ignore.zig`), which is why no `@import` in `fs-meta` changed. If the dependency is ever
  restructured, this is the one place to edit.
- A version bump means editing the URL and hash in `build.zig.zon`, then re-running the gate: same test count, no path
  reference left (`grep -r "\.\./gitignore" fs-meta`).

**A2. Do not re-add the moved files.** `.gitignore` parsing, the chain and `globMatch` live in the
[`gitignore` project](https://github.com/hrgdavor/gitignore) (pinned as an artifact, v0.3.5); a change to matching
behaviour belongs there, with a vector and a bench row, not in `fs-meta`. The practical test: if a change needs
`src/gitignore.zig`, it is a change to the other project.

**A3. Measure through the other project from now on.** `fs-meta`'s own numbers (`doc/benchmark.md`,
`doc/gitignore-and-optimisations.md`) now describe a matcher it does not own; when the matcher changes, the numbers are
re-measured in `gitignore/bench` and `fs-meta`'s documents link there instead of restating them.

## B. The pair layout (done)

**Done, and kept for the record:** the plan that diagnosed the defect and the code that closed it is
[`plans/archive/next-session-pair-layout.md`](archive/next-session-pair-layout.md) (the file it was written as,
`plans/next-session-pair-layout.md`, moved into `plans/archive/` when the archive was created — the link above is the
live path). Summary of what landed:

- **B1 (done).** The count assertion is in `publish` before `pair.layout`:
  `items.items.len == cache.files.count() + cache.dirs.count() - 1` — the loader and the walker both depend on it.
- **B2 (done).** `publish` lays its pair out through `pair.layout`, passes `laid.roots` into `json_doc` (§ 18), and
  does not free meta/txt in a `defer` because `Outcome` returns them.
- **B3 (done).** `publish`'s literal is `"a.txt\nsrc/\nsrc/b.java\n"`, and `engine`'s `expectNameSets` compares
  membership with `trimSlash` (the panicking positional diagnostic is gone).
- **B4 (done).** Gate green, and on a scratch tree `files.txt` is name-ordered with slashed directories while
  `files.json` carries `roots`.

## C. The batches' consumer entry point (done)

- **C1 (done).** `fsmeta reconcile <root> <from> [to] [--json] [--baseline <root>]` reads the main trio's
  `generation`, `batch.decode`s each `batches/<g>` for `g` in `from+1..=to`, calls `batch.toEvents`, collapses with
  the optional baseline, and prints `+`/`~`/`-` lines or the JSON. (`merge` is the deprecated alias; there is no
  `--from`/`--to`/`--format` — those were the design sketch, the CLI settled on positional bounds plus `--json`.)
- **C2 (done).** The two refusals are implemented: `batch-gap` (a missing generation in the range) and `batch-too-old`
  (`from` below the oldest retained batch). Both are named in `FORMAT.md` § 17.5 and neither falls back to a partial
  reconcile.
- **C3 (done).** Covered by `test/reconcile.test.mjs`: a two-change scratch tree, `reconcile 1` returns exactly the
  added file; `0` returns the whole tree as added (a first sync), and the same window with a baseline returns no
  changes.

## D. The socket server (done)

`FORMAT.socket.md` and `src/wire.zig` define the bytes; `src/server.zig` is the transport, and `fsmeta serve` is the
command. What exists:

- **D1 (done).** Accepts on a Unix socket and exchanges `HELLO` both directions at once, checked with
  `wire.checkHello`.
- **D2 (done).** `SUBSCRIBE{from}` replays each generation as `START_BATCH` + `CHANGE_ENTRY`* + `END_BATCH`; the two
  `ERROR`s are `batch-too-old` and `batch-gap`.
- **D3 (done).** The live path sends the same three message kinds to subscribers at `g-1`; the daemon adds `STATE` and
  (under `gitwatch`) `GIT_EVENT` between batches.
- **D4 (done).** `test/socket.test.mjs` asserts a Bun client's replay is identical to reading the batch folder; the
  daemon's consumer path is covered by `test/daemon.test.mjs`.

## E. Ports — done

All three E items are implemented and gated; the ordered plan for the Java reader is kept for the record in
[`../doc/java-port.md`](../doc/java-port.md).

- **E1. Bun reader** — `js/` speaks the current layout (directories, `roots`, batches) and answers the conformance
  vectors; `test/portability.test.mjs` is its reader gate.
- **E2. Java reader** — `src/main/java/hr/hrg/fsmeta/` is implemented and passes its Maven suite (62 tests, 1 skipped,
  0 failures on 2026-10-26); `doc/java-port.md` records the order it was built in.
- **E3. Both ports' matchers** consume `gitignore`'s vectors and bench rather than re-deriving them.

## F. Retention and the WAL (deliberately open)

`FORMAT.md` § 17.6: a per-generation file or one append-only log, a retention window, and the point at which
`batch-too-old` becomes reachable. No code depends on the answer: `diff`, `encode`, `decode` and `collapse` all survive
it unchanged.

- `reconcile --baseline <root>`: specified in [`reconcile-baseline.md`](archive/reconcile-baseline.md); the adapter, the flags it must reconstruct, and the test that proves it.

## G. The skips, and why each one is deliberate

A fresh-cache gate prints `755/763 tests passed (8 skipped)`. That is **two** Zig tests counted in four test
binaries — `scan`, `lister` and `engine` all import `scan.zig`, and the daemon's `daemon_tests` imports the engine —
so the eight are not eight separate gaps. Both skip sites print their platform and condition before returning
`error.SkipZigTest`; `zig build test` echoes them once per test binary (the four that import `scan.zig`),
preceded by the builder's `+- run test` / `failed command:` context header. That header is the builder showing a
step's stderr, not a failed step: the summary still ends `50/50 steps succeeded`. A direct run of the binary shows
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

**G3. The Linux watch-bound measurement (1) — platform guard, no gap.** `test/watch-bound.test.mjs` asserts that
both watcher arms register only what they may watch, using a repository with 120 `objects/` directories, a linked
worktree and a 40-directory nested clone. A per-directory count only exists on inotify/kqueue, so on Windows (one
recursive registration) the test skips with its reason; Linux CI produces the number
([`worktrees.md`](worktrees.md) § 5b).

## The daemon

A long-lived process that tracks several roots, keeps a Unix socket per root for consumers, and decides when each root is worth watching (`off` / `always` / `auto` with a per-root idle timeout, so a slept root wakes with one full scan and a diff). Planned in [daemon.md](archive/daemon.md); Zig only, and shaped so a root can later be served by its own child daemon without changing the consumer socket.

**Implemented:** M0–M4 — the runtime/home split, `roots.json`, the state machine, the per-root sockets, the `STATE`
frame and the `GIT_EVENT` frame (`FORMAT.socket.md`, protocol `0x0102`), sleep and wake with a scan and a diff,
per-root retention by count and bytes with `on_remove`, the control socket and the `daemon`/`root`/`roots` CLI, the
worktrees extension (boundary rule, seeded worktree roots, git-aware watching, hooks, the two switches). Watching is
event-driven (`nightwatch`) and each root schedules itself, so a batch never waits on another root's pass. Housekeeping calls
over many roots follow the bounded-wait rule in `FORMAT.daemon.md` § 4b: they name a root they could not read
(`available: false`, `partial: true`) instead of blocking or guessing. `FORMAT.daemon.md` is the reference;
`test/daemon.test.mjs` is the suite.

**Still open, in the order that matters:**

1. **The per-root child daemon (M5)** has moved out of the daemon plan, to
   [`tbd-per-root-daemon.md`](tbd-per-root-daemon.md) — it is not needed for the daemon to work, and the latency
   argument that motivated it was removed by the per-root scheduler. What is left is failure and memory isolation,
   and that file says what would trigger it and what has to be decided first.

**Done since this list was written, besides the nested-roots decision below:** the watcher-overflow gap is closed by a
safety net, not a counter — `nightwatch` cannot report an overflow (a failed `ReadDirectoryChangesW` completion ends
its thread), so a `watching` root runs one pass after 60 s of silence and re-arms the watcher if that pass finds a
change the watcher missed; `event_passes` / `safety_passes` in `root status` are the split (`FORMAT.daemon.md` § 2b).
The `coldstart` key-ownership cleanup in § H is also done.

**Settled since this list was written — and now implemented:** nested roots. § 16b of
[daemon.md](archive/daemon.md) measured the overlap (10 of 10 edits produce a pass in both roots; a nested pair scans 904
names where one root covers the changes with 604; the inner history duplicates the overlapping batch bytes, +48.8%) and
chose option A as the semantics with B implemented: `root add` warned with those numbers and refused nothing. **The
worktree plan replaced that rule with a guard** ([`worktrees.md`](worktrees.md) § 5–§ 6, M2): the parent's internal ignore
excludes a nested root, `root add` passes the parent once and refuses when it cannot arrange the line, and the startup
pass repairs a block that was deleted or edited. The warning code is gone.

**Measured, no longer open:** the wake scan. `doc/benchmark.md` § The wake scan records 20 101 names, a cold scan of
840–1 050 ms and a wake scan of 72–76 ms for 500 changed files on this host, taken from the new
`last_pass_duration_ms` / `last_pass_files` / `last_pass_batch_bytes` fields. That same measurement found a real bug
outside the daemon — a genesis batch over 1 MiB could not be read back by `server.loadBatch`, so a large tree's first
batch was undeliverable from both `fsmeta serve` and the daemon; `server.max_batch_file_bytes` now separates the file
limit from the 1 MiB frame limit, with a test.

## H. The two failing `reconcile` tests — fixed

`bun test test/reconcile.test.mjs` failed two cases — `a range reports added, changed and deleted, and honours the end
it is given` and `merge is an alias…` — with a **deleted** entry printed under a corrupted name (`deleted <mojibake>`
where the tree had `src/b.java`), while `changed` and `added` in the same range printed correctly. It was pre-existing
and unrelated to the daemon.

**Root cause (not offsets, and not in `batch.zig`).** `engine.refresh` built its `previous` snapshot from the cache's
keys, and for a cache loaded from a trio those keys are **interior slices of that trio's `files.txt`**. Discovery then
mutates the cache in place: `coldstart` frees the name of every entry it removes
(`src/coldstart.zig:131`), and Zig 0.17's `Allocator.free` writes `undefined` over the slice before the raw free —
`0xAA` in a debug build, harmlessly a no-op in release because an arena can only rewind its last allocation. So the
deleted entry's bytes were dead *before* `diff` ran; the batch copied them faithfully, and `decode`'s LF check still
passed because the churn ended at the right newline. The meta entry's `nameOffset`/`nameLength` were correct all along
(`off=17 len=10` over `"a.txt\nsrc/c.java\nªªªªªªªªªª\n"`).

**Fix:** the snapshot owns its names (`try arena.dupe(u8, name)` per file and directory in `src/engine.zig`), with the
invariant stated at the site. Regression tests: `a deleted name survives into the batch that records it`
(`engine.zig` — verified to fail with the dupe removed) and `a deleted entry's name survives diff, encode and decode`
(`batch.zig`; the round-trip alone cannot catch this, which is why both exist).

**Follow-up, done:** the ownership itself is now uniform. `Cache.load` duplicates every key it takes from the trio,
`coldstart` already duplicated its own, and `Cache.deinit` frees the keys when `owns_keys` is set — a flag both real
producers set and a hand-built fixture does not, so a cache the tests assemble from literals is never freed through
the allocator. `coldstart`'s removals are therefore freeing memory it owns, and the poisoning that caused this defect
cannot reach `files.txt` at all. The engine's snapshot fix stays: the snapshot must own its names regardless, because
removal legitimately frees the cache's copies.

The change had one consequence worth recording, because the suite caught it: **`BaselineStore` borrowed the cache's
keys** and outlived the cache, so once `deinit` freed them the baseline matched nothing (`changed a.txt` where `0
names` was right — `test/reconcile.test.mjs` is the test that noticed). It now copies each key, which is the rule for
any store that outlives the cache it was built from.

## I. Two smaller warts the query CLI tests found (decided, not pending)

- **A name containing a space makes a query line ambiguous.** `match` prints `name mtimeNs sizeBytes contentHash`,
  space-separated, and the name is the only variable-width field — so a file called `my notes.txt` cannot be parsed
  back unambiguously. **Decision: keep the shape, point at `--json`.** The text form is a human/debug view that
  scripts already parse; changing it (quoting, a tab, name last) would break every reader for a case `--json`
  already answers exactly, and `--json` is the documented machine path. Revisit only if a port or a test needs the
  text form programmatically.
- **The footer is always `<n> names`**, including `1 names`. **Decision: keep it.** All the commands print the same
  footer and tests pin it; a pluralisation rule is a change to every command for no information.


## J. Worktrees — done (2026-10-27)

[`worktrees.md`](worktrees.md) is implemented: M0–M7 plus the gap-closure batch, committed as `f2b3a72`. In one line
each:

- **worktrees as roots** — a nested repository is never scanned (the boundary rule), nesting is guarded by the
  parent's managed ignore block and refused when it cannot be, and an adopted worktree seeds from the base trio
  instead of scanning cold;
- **git-aware watching** — a refcounted metadata watch per common dir with `should_watch` pruning on both arms, a
  per-root lock latch, optional hooks, and `GIT_EVENT` (0x0A, protocol 0x0102) with the finish-after-batch guarantee;
- **the gate** — `worktrees` and `gitwatch` per root (defaults, `root add`/`root set`, live flip,
  `FSMETA_WORKTREES`/`FSMETA_GITWATCH`) around a rule that is **never** gated.

The open items are recorded in that plan rather than here: `test/watch-bound.test.mjs` asserts the Linux watch bound
and skips (with its reason) on hosts without per-directory registration, so the count is a Linux-CI result; the
Windows-only read-only-`<common>` stand-in and hook spawn cost remain; and `--nested` is intent-only.

## K. What is next (still open)

1. **§ F — retention and the WAL.** A product/format decision: keep the directory of batch trios or move to one
   append-only log with rotation, without changing the consumer API (§ 17.6). Until it is decided, the directory
   layout is the reference.
2. **[`tbd-per-root-daemon.md`](tbd-per-root-daemon.md)** — one root per child process. Not scheduled; it waits for
   a measured trigger (cross-root delay, a crash/OOM, or a per-root restart need) and for four decisions (IPC shape,
   socket ownership, supervision, aggregated state).
3. The two small § I warts stay decided, not pending.
