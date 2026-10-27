# Next steps — fs-meta

What is still open, and how to read the gate. The completed sections — A–E (gitignore move, pair layout, `reconcile`,
the socket server, ports), H (the `reconcile` defect), I (the two decided output warts), J (the worktrees plan) and the
daemon's implementation record — were moved to [`plans/archive/next-steps-done.md`](archive/next-steps-done.md) on
2026-10-27. Nothing in that file is work to do; the acceptance notes there are the evidence it was done.

Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate:

```text
cd fs-meta
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
```

Today: **50/50 steps, 755/763 tests** (8 skipped — **two** platform guards, each counted in four test binaries; see
§ 3). The Bun gate (`bun test`, which runs `js/` and `test/`) is **130 pass, 5 skip, 0 fail** across 135 tests: three
writer-scope tests, one POSIX-only socket assertion, one Linux-only watch-bound measurement (§ 3), and the daemon,
port and CLI suites.

**Implemented, in one line each:** the trio format and the Zig engine; the daemon (`roots.json`, per-root sockets,
`STATE`, sleep/wake, retention, `on_remove`); and the worktrees plan ([`worktrees.md`](worktrees.md)) — boundary rule,
guarded nesting, ignore sources, git lock latch, metadata watch, `GIT_EVENT` (`0x0102`), hooks, seeding, live
discovery/removal, and the two per-root switches. `FORMAT.md`, `FORMAT.daemon.md`, `FORMAT.socket.md`, `README.md`
and `AGENTS.md` are the references.

## 1. Retention and the WAL (deliberately open)

`FORMAT.md` § 17.6: keep the directory of batch trios or move to one append-only log with rotation, plus the retention
window and the point at which `batch-too-old` becomes reachable. No code depends on the answer: `diff`, `encode`,
`decode` and `collapse` all survive it unchanged, and the consumer API is specified independently of the storage. Until
it is decided, the directory layout is the reference.

The related `reconcile --baseline <root>` adapter is **done** and archived with the rest — see
[`plans/archive/next-steps-done.md`](archive/next-steps-done.md) § C.

## 2. The per-root child daemon (not scheduled)

[`tbd-per-root-daemon.md`](tbd-per-root-daemon.md) — one root per child process, with the parent aggregating state.
Not needed for the daemon to work: the per-root scheduler already removed the latency coupling that motivated it.
It waits for a measured trigger (a cross-root delay beyond a user-visible threshold, a crash/OOM where one root took
the daemon down, or a per-root restart need) and for four decisions the file records (IPC shape, consumer-socket
ownership, supervision, what the parent aggregates).

## 3. Reading the gate (why it prints skips)

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
`bun test` prints them as skips and never counts them as passes; the reason is "writer scope: the Zig engine is the
only writer (AGENTS.md § 1); set FSMETA_PORT_WRITER=1 to run it". With `FSMETA_PORT_WRITER=1 bun test` they run and are
expected to fail until the port learns the two-order layout — that is the writer half of E1, and it is the one gap
this file keeps open on purpose.

**G2. The POSIX-only socket assertion (1) — platform guard, no gap.** `test/socket.test.mjs` runs its four replay
tests on Windows AF_UNIX; only `POSIX: the bound address is a socket node…` is skipped, with the reason "this host
is win32; an S_ISSOCK node on the bound address is POSIX-only". Linux/macOS CI is what covers it.

**G3. The Linux watch-bound measurement (1) — platform guard, no gap.** `test/watch-bound.test.mjs` asserts that
both watcher arms register only what they may watch, using a repository with 120 `objects/` directories, a linked
worktree and a 40-directory nested clone. A per-directory count only exists on inotify/kqueue, so on Windows (one
recursive registration) the test skips with its reason; Linux CI produces the number
([`worktrees.md`](worktrees.md) § 5b).
