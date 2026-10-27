# `FORMAT.daemon.md` — the fs-meta daemon

**Status:** implemented; this file is the reference a later session reads instead of the plan
(`plans/archive/daemon.md`), which records the decisions and how they were reached.

**What it is.** One long-lived process, `fsmeta daemon`, that tracks a set of **roots**. Each root gets its own Unix
socket, at a path a consumer can discover, speaking the binary protocol of [`FORMAT.socket.md`](FORMAT.socket.md).
A consumer connects, `SUBSCRIBE`s, and receives batches as the tree changes — the same batches the engine writes,
because the daemon is a *server* of that data and never a second writer.

The daemon exists for two reasons, and both are about cost:

1. **One process can serve many roots.** `fsmeta serve <root>` binds `<root>/.fs-meta/socket` and owns one tree for
   its lifetime. A person working in five repositories would otherwise run five processes, five sockets and five
   copies of the engine.
2. **Watching costs something, and nothing is watching when nothing is looking.** A root nobody subscribes to can go
   **asleep**: no watcher, no open tree handles, only the last published generation kept. Waking it costs one full
   scan — the difference between the tree and the last published generation — published as normal batches.

**The engine is still the only writer** (`AGENTS.md` § 1). A pass is `engine.refresh`: discovery, hashing, the
commit record, the batch and the rotation are the engine's. The daemon decides *when* a pass runs and *who* hears
about it; it never lays a trio out itself.

---

## 1. Two directories, and the difference matters

| directory                        | holds                                                           | lifetime                                              |
| -------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------- |
| **runtime** (host state)         | sockets, the daemon's pid file, claims, per-root logs           | ephemeral: a tmpfs, cleared at logout                 |
| **home** (configuration)         | `roots.json`: the roots this machine serves, and their settings | durable: survives a reboot, a crash, an empty runtime |

Losing the runtime directory is normal. It is rebuilt from `roots.json` on every start. Losing `roots.json` means
the person's list is gone; nothing else can answer "what was I serving?".

### 1a. The runtime directory

| platform                                     | directory                   |
| -------------------------------------------- | --------------------------- |
| `FSMETA_RUNTIME_DIR` set (tests, containers) | `$FSMETA_RUNTIME_DIR`       |
| Linux/macOS, `$XDG_RUNTIME_DIR` set          | `$XDG_RUNTIME_DIR/fsmeta`   |
| macOS/Linux without it                       | `~/.cache/fsmeta/run`       |
| Windows                                      | `%LOCALAPPDATA%\fsmeta\run` |

```
<base>/
  daemon.sock                 the control socket
  daemon.lock                 the daemon's own lock; held for the life of the process
  daemon.json                 pid, started_at, protocol, base — what a CLI reads before it connects
  roots/<id>.pid              the claim on one root: an exclusively locked file, holding the pid for a human
  roots/<id>.sock             the consumer socket for that root
  logs/<id>.log               per-root log; rotated (truncated) on start, removed with the root
```

`--base <dir>` overrides the runtime directory for one daemon, and `FSMETA_RUNTIME_DIR` overrides it for everything
in a process tree. The CLI computes the same base the daemon would, so both sides agree without asking.

### 1b. The durable root list

| platform                                     | file                                    |
| -------------------------------------------- | --------------------------------------- |
| `FSMETA_CONFIG_HOME` set (tests, containers) | `$FSMETA_CONFIG_HOME/fsmeta/roots.json` |
| `$XDG_CONFIG_HOME` set                       | `$XDG_CONFIG_HOME/fsmeta/roots.json`    |
| otherwise (Linux/macOS)                      | `~/.config/fsmeta/roots.json`           |
| Windows                                      | `%APPDATA%\fsmeta\roots.json`           |

`roots.json` is one document (§ 3), written atomically: `<path>.tmp`, then a rename over the original. A reader
therefore sees the whole previous list or the whole next one, never a half-written one.

**The invariant: the daemon never walks the file system to discover roots.** On start it reads this list and
`stat`s each recorded path once. It does not search for `.git` directories and it does not re-scan a home directory
— a search would make every restart unbounded and would find roots nobody asked for. If the list ever grows past a
few hundred roots, per-root files under `~/.config/fsmeta/roots/` are the documented alternative, read by one
`readdir` (still not a search).

### 1c. `<id>` is derived, not random

```
id = hex8( low 32 bits of wyhash(canonical_root_path) )
```

Exactly eight lowercase hex digits: `a1b2c3d4`. The same root therefore gets the same id across restarts and across
daemons, and the socket name is thirteen bytes — `a1b2c3d4.sock` — whatever the root's depth. That length is not
cosmetic: an AF_UNIX path is limited to about 104 bytes on POSIX, and a hashed name is the only way to stay short
for a deeply nested root. The record in `roots.json` carries the root path, which is what makes the short name
resolvable.

**The trio still contains no absolute path** (`FORMAT.md` § 3.1, `AGENTS.md`). The registry, the socket paths and
the pids are host state; they are never interpolated into a stored byte.

### 1d. Claiming a root

`<base>/roots/<id>.pid` is opened and **locked exclusively** for as long as the process serves that root; the kernel
releases the lock when the process ends, whatever the reason. The pid is written into the file because a person
reading `roots/` should see who is serving what — it is a diagnostic, never the authority. A pid answers "is this
number alive", which is a different question and a dangerous one, since pids are reused.

Two daemons therefore cannot serve one root: the second one's lock attempt fails and it reports which root it could
not take.

---

## 2. The state machine

Each root is in exactly one phase. `off`, `asleep` and `watching` are stable; `waking` is transient.

```
            add root                       subscriber arrives / control wake
   (none) ─────────► off ──mode change──► asleep ◄──────────────┐
                       │                    │  wake              │ idle deadline
                       │ mode = always      │  (scan + diff)     │ (auto, no clients)
                       │ or auto + client   ▼                    │
                       └────────────────► waking ──► watching ───┘
```

| phase      | watcher | open tree handles | socket | what it means                                                |
| ---------- | ------- | ----------------- | ------ | ------------------------------------------------------------ |
| `off`      | never   | none              | bound  | configured never to watch; answers a subscribe with one scan |
| `asleep`   | no      | none              | bound  | no reason to watch; keeps its last published generation      |
| `waking`   | arming  | during the scan   | bound  | a full scan is running and its difference will be published  |
| `watching` | yes     | while watching    | bound  | passes run on the scheduler; events reach subscribers        |

**Rules, and why.**

- **A subscriber is the reason to watch, not the reason to exist.** A root with no clients keeps its socket *and*
  its last published generation, so a returning client gets a diff instead of a cold start.
- **`off` means never *watch*, not never *serve*.** The socket stays bound and answers a `SUBSCRIBE` with one scan,
  so a client sees the tree as it is now. A control `wake` is refused (`code = 4`, "mode is off") rather than
  silently ignored.
- **Idle sleeps only `auto`, and only with no clients.** `mode = always` ignores subscribers: it watches whether or
  not anybody is listening. `idle_timeout_ms = 0` means "never sleep" and is a setting, not a missing value.
- **A forced sleep affects `always` too.** `fsmeta root sleep` drops the watcher whatever the mode; the root then
  waits for a control `wake` or a subscriber. A forced sleep is a hard stop, not a hint.
- **A mode change does what its name says.** `→ always` starts watching at once (no client needed); `→ off` stops
  watching at once; `→ auto` from `off` goes to `asleep` and waits.
- **A vanished root is `missing`.** It is reported, not dropped and not reaped: `fsmeta roots list` shows
  `"missing": true`, and the record stays until `fsmeta root remove`. If the path comes back, the root recovers on
  the next tick.

### 2a. The wake path, precisely

1. A `SUBSCRIBE` arrives on a sleeping root's socket. The server greets (`HELLO`), registers the subscriber, and
   sends `STATE(waking, reason=client, head_batch = the last published generation)` — the client now knows a scan is
   coming and how far behind it will be. It is **not** answered with a batch yet.
2. The scheduler runs the full scan — the same `engine.refresh` pass `fsmeta refresh` runs — and compares the tree
   with the last published generation.
3. The difference is published as one generation and one batch (or a chain of batches if it crosses the batch limit),
   streamed as `START_BATCH` … `END_BATCH` to every subscriber.
4. `STATE(watching)` follows the batch, the idle deadline is cleared while clients are subscribed, and the root is
   watching.
5. A second client subscribing during `waking` is queued and served by the same scan: no second pass.

**A gap a sleep created is not hidden.** If the wake diff needs a generation the archive no longer retains, the
ordinary `batch-too-old` refusal applies (§ `FORMAT.socket.md`), and the client falls back to a full read. The
daemon does not pretend a slept gap was never there.

**Failure is explicit.** If the root disappeared, the scan fails, the root becomes `missing` and moves to `off`, and
the subscribers receive `ERROR (code 1, protocol)` naming the root — not a hang and not a timeout.

### 2b. The event source: `nightwatch`

A `watching` root holds a **recursive watch on its tree**, through `nightwatch` — the same dependency the watcher
prototype uses, and the reason `build.zig` links it into the engine now that `fsmeta daemon` is part of that binary.
nightwatch delivers from its own thread (ReadDirectoryChangesW on Windows, FSEvents/kqueue on macOS, inotify on
Linux), and the handler does **one** thing: raise a sequence number and a timestamp. It never takes the root's
mutex, because a handler that waited for a pass would stall the watcher.

The scheduler's 100 ms step then decides *when* a burst becomes a pass, using `watch.Scheduler` — the prototype's
self-tuning quiet period, derived from how long this machine's passes actually take. No event means **no pass at
all**: a root that is watching but idle costs one timer check per tick, not a scan. `STATE.reason = watcher` tells a
client that an event, not its own subscribe, produced the batch.

Four rules, and each of them is a bug if it is not followed:

1. **Arm the watcher before the wake scan, not after it.** A change that lands during the scan would otherwise fall
   between the scan and the watch and be invisible until the *next* change.
2. **Ignore `.fs-meta` and `.git` events** (matched per path segment). `.fs-meta` is the pass's own output: a
   watcher that reacted to it would publish itself forever. `.git` is not part of what a trio describes
   (`FORMAT.md` § 16), so a ref update is not a reason to scan.
3. **A sleeping or `off` root holds no watcher at all** — that is the resource sleeping is meant to release.
   `syncWatcherLocked` is the one place that keeps the watcher in step with the phase.
4. **A failed arm is visible, not silent.** If the platform refuses a watch (a limit, an unsupported filesystem),
   the root stays `watching` and falls back to a pass every `fallback_pass_interval_ms` (200 ms), with `last_error`
   naming the reason. A root that quietly stopped seeing changes would be worse than a slow one.

5. **Silence is checked, because a watcher can die without saying so.** `nightwatch`'s Windows backend ends its
   thread when a `ReadDirectoryChangesW` completion fails, and a **buffer overflow is a failed completion**
   (`ERROR_NOTIFY_ENUM_DIR`) — the handler is never called, no error reaches the daemon, and the watch simply stops.
   There is no overflow callback to count, so the daemon counts *silence*: while a root is `watching`, if nothing has
   happened for `safety_pass_interval_ms` (60 s) it runs one pass, and if that pass finds changes it **re-arms the
   watcher** — a change it found is a change the watcher missed. A pass on a 20 000-name tree is ~70 ms
   (`doc/benchmark.md`), so the net costs ~0.1% of a core, and only while a root is watching. The counters in § 4
   (`safety_passes` vs `event_passes`) say whether it has ever earned that.

The wake-scan cost (a full pass after a sleep) is measured in
[`doc/benchmark.md`](doc/benchmark.md#the-wake-scan): on one host, with 20 001 files in 100 directories, a cold
first scan took 840–1 050 ms and the wake scan 72–76 ms for 500 changed files — the wake is a full discovery pass,
not a replay of the changes. That is one tree, not every tree, which is why every root also reports its own last
pass in `root status` (§ 4: `last_pass_duration_ms`, `last_pass_files`, `last_pass_batch_bytes`); that is what an
operator tunes `idle` against.

**The second event source: git's own metadata (M3/M4).** A root whose `gitwatch` is on resolves `$GIT_DIR` and
`$GIT_COMMON_DIR` per pass and holds a second arm on the common dir — one watcher per repository, shared and
refcounted by the roots that resolve to it, never on a working tree. It watches the metadata set only (`HEAD`,
`index`, the pseudo-refs, `logs/HEAD`, `refs/`, `packed-refs`, `logs/refs/`, `worktrees/`, `info/exclude`), refuses
`objects/`, `modules/`, `lfs/` and `hooks/` at any depth, and classifies each path by **path** into a tree-changing
signal (this root's `$GIT_DIR`, which may force a pass) or a repo-wide one (`refs/`, which never passes an unrelated
root). Two consequences are part of the contract rather than an optimisation:

- **A pass is deferred while this root's own tree is mid-write.** The latch polls `$GIT_DIR/index.lock`, `HEAD.lock`
  and `shallow.lock` on the tick; it is cleared by polling, never by an event, because a linked worktree has no
  watcher on `.git` to deliver one. A shared `refs/**/*.lock` is not a latch, so one worktree's commit cannot stall
  another's pass.
- **`GIT_EVENT` frames** (§ `FORMAT.socket.md` § GIT_EVENT) report the start and finish of what the metadata implies,
  with the finish written after that client's `END_BATCH`. The metadata source is a heuristic (`source = metadata`);
  the hooks, when they are installed (§ 6a), are the precise upgrade, and they are the third source below.

`gitwatch = off` means exactly that: no `.git` is resolved or read, no arm is held, no latch is polled, and no
`GIT_EVENT` is ever sent for that root.

**The third event source: git's hooks (M5).** The generated hooks (§ 6) append one JSON line per git operation to
`<common>/fsmeta-events.log`, a mailbox inside git's own state, and each root that has `gitwatch` on reads the lines its
repository appended on its next tick. Nothing about the file is asserted, watched or polled by a second thread: the
read is one `stat` per tick and a read only when the file grew, so a repository without hooks costs one filesystem call
per tick.

What the reader does with a line is the whole contract, and it is deliberately the same one the metadata timeline uses:

- **Attribution.** A line names the worktree git was operating on. It belongs to the served root of that worktree; if
  the worktree is not served by any root of the daemon, it is a **repo-wide** event for every served root of that
  repository (with `gitwatch` on), which is how a `git worktree add` checkout is seen before the new root exists. A
  line from a *served sibling* is dropped by the other roots: a sibling's checkout is not their tree.
- **Phases.** `reference-transaction prepared` is a **start**, written as soon as it is read — before any pass, which
  § 5d rule 1 allows and the ordering needs. `committed` is a **finish** and `aborted` is an **aborted** finish. Every
  other generated hook fires at the end of its operation, so it is always a finish. A start is coalesced per kind per
  flush, as § 5d rule 4 requires; a checkout fires several ref transactions, so it legitimately produces a start/finish
  pair per transaction.
- **The finish follows the pass.** A `committed` finish for this root's own tree is queued and written only after the
  pass that reflects it — the same `runPassLocked` tail the metadata finish uses, so the ordering guarantee is one
  implementation, not two. A finish for an unserved worktree has no pass to wait for and is written with the receiving
  root's current `head_batch`, like a metadata repo-wide event.
- **Age and bounds.** A line stamped in a second earlier than the daemon's start is discarded: a hook that fired while
  no daemon was running must not replay as a fresh event. A root starts reading a spool at its current end, so a
  restart does not replay one either. The hook caps the file at 64 KiB (§ 6); a reader that still finds more than 512
  lines drops the backlog and resumes at the end rather than turning a stale mailbox into a storm of events.
- **What a hook line cannot say.** The line records the phase, not the ref names (`reference-transaction`'s stdin is
  deliberately not consumed: reading it is the one thing that can block a hook), so its kind is `other`. The specific
  hooks supply the kind: `post-checkout`'s flag is `branch` (1) or `checkout` (0), `post-merge` is `merge`,
  `post-rewrite` is `rebase` (or `other` for an amend), `post-index-change` is `index` and `post-commit` is `commit`.
  An `index` event says the index was written — a plain `git status` can do that — not that content changed.
- **Both sources may report one operation.** With hooks installed, a checkout produces hook frames *and* the metadata
  timeline's frames for the same pass; `source` is how a consumer tells them apart. The alternative — suppressing one
  source — would make `source` a lie about which signal the daemon actually saw.

A sleeping root reads nothing (it has no watcher and emits nothing, § 5d rule 7): the lines wait in the spool and are
folded into the next wake pass. `gitwatch = off` reads nothing either — no spool is opened, and `install` refuses for
such a root (§ 6), because a hook that writes a mailbox nobody reads is a trap.

### 2c. Each root schedules itself

**There is no daemon-wide scheduler.** Every root owns a task that wakes every `tick_interval_ms` (100 ms) and
checks *that* root: its idle deadline, its event burst, its wake. A batch belongs to one root, so its latency must
not depend on the other roots: with one loop over every root, a slow pass — or worse, a client that stopped reading,
which blocks the write into its socket — would put every other root's tick behind it, and therefore its batches.
A pass holds only its own root's mutex, and a blocked write blocks only its own root.

The cost is one sleeping task per root (a `Group` task, not a thread per connection), which is the price of that
independence and is what makes the plan's `RootHost` seam honest: a root is already independent enough to become a
child process later (§ 7).

**The one exception is the diagnostic path.** `roots list` and `root status` take each root's lock to produce a
consistent snapshot, so a root stuck in a write delays a listing of *itself* (and, because the listing walks every
root, the listing as a whole). The consumer sockets are unaffected; `plans/next-steps.md` records the option of a
`busy` flag reported instead of waiting.

---

## 3. The durable list: `roots.json`

One document. `version`, an optional `defaults` block, and one record per root.

```json
{
  "version": 1,
  "defaults": {
    "mode": "auto",
    "idle_timeout_ms": 300000,
    "retention": { "max_batches": 32, "max_bytes": 67108864 },
    "on_remove": "keep",
    "worktrees": true,
    "gitwatch": true,
    "on_worktree": "ignore"
  },
  "roots": [
    {
      "id": "a1b2c3d4",
      "root": "/home/u/projects/app",
      "mode": "auto",
      "idle_timeout_ms": 300000,
      "retention": { "max_batches": 32, "max_bytes": 67108864 },
      "on_remove": "keep",
      "worktrees": true,
      "gitwatch": true,
      "on_worktree": "ignore",
      "socket": "/run/user/1000/fsmeta/roots/a1b2c3d4.sock",
      "served_by": "inproc",
      "created_at": "2026-10-26T06:50:00Z"
    }
  ]
}
```

| field             | meaning                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------- |
| `id`              | `hex8(wyhash(canonical root path))`; eight lowercase hex digits (§ 1c)                          |
| `root`            | the canonical root path. Host state, never trio content                                         |
| `mode`            | `off`, `always` or `auto` (§ 2)                                                                 |
| `idle_timeout_ms` | how long an `auto` root with no clients keeps watching; `0` = never sleep                       |
| `retention`       | `max_batches` and `max_bytes`, both enforced (§ 3a)                                             |
| `on_remove`       | `keep` (default) or `delete`: what `root remove` does with the batch history (§ 3a)             |
| `worktrees`       | the worktree handling switch (§ 5h); copied from `defaults` at add time                         |
| `gitwatch`        | the git metadata switch (§ 5h); copied from `defaults` at add time                              |
| `on_worktree`     | `ignore` (default) or `serve`: what a worktree discovered under this root becomes (§ 4)         |
| `socket`          | the runtime socket path; rewritten on every start, because the runtime directory may have moved |
| `served_by`       | `inproc` today; `child:<pid>` is reserved for the per-root split (§ 7)                          |
| `created_at`      | when the record was created, RFC3339 UTC                                                        |

**Defaults are copied, not inherited.** `root add` writes the current `defaults` values into the new record, including
the two switches and `on_worktree`. A later change to a default therefore never silently mutates an existing root. A
record written before a field existed resolves it from `defaults`, or from the built-in default (`on` for the switches,
`ignore` for `on_worktree`) when the default itself is absent.

**A malformed record is reported and skipped**, never fatal to the other roots: the daemon prints the reason, keeps
serving what it can, and `fsmeta daemon status` lists the notes it collected.

### 3a. Retention and removal are per-root policy

A root's batch archive is bounded by **two** limits, because either alone is a poor ceiling:

| limit                   | what it prevents                                             | default |
| ----------------------- | ------------------------------------------------------------ | ------- |
| `retention.max_batches` | an unbounded generation count (the format's default is 32)   | 32      |
| `retention.max_bytes`   | 32 generations of a huge tree filling the disk               | 64 MiB  |

After every publish the daemon rotates the archive oldest-first until **both** hold, in the order the format already
requires (rename to `.trash-<id>`, then delete), so a reader never sees a half-removed generation. **A generation that
alone exceeds `max_bytes` is kept**: refusing to keep it would break the commit that just happened, and one oversized
generation is better than a missing one.

**Removal is its own choice**, because "stop serving" and "delete my history" are different intents:

- `on_remove = keep` (the default) — the socket, the claim and the log go; the batches stay, so a later `root add`
  resumes from history.
- `on_remove = delete` — the daemon also removes `batches/` under `<root>/.fs-meta`.

Nothing else in the tree is the daemon's to delete.

---

## 4. The control protocol

JSON lines over `<base>/daemon.sock`: one request object, one reply object, connection closed. Deliberately **not**
the binary batch protocol — its callers are people and scripts, JSON is readable in a log, and diffable. Version
first: `{"v":1,"cmd":…}`.

A reply is one line: `{"v":1,"ok":true,…}` or `{"v":1,"ok":false,"code":N,"message":"…"}`. The `code` is the number
the CLI exits with (§ 6), so the two halves of one contract are one table.

| `cmd`              | fields                                                                                        | reply payload                                                            |
| ------------------ | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `status`           | —                                                                                             | `pid`, `base`, `config`, `protocol`, `uptime_ms`, `roots`, `diagnostics` |
| `roots`            | —                                                                                             | `roots`: an array of root objects                                        |
| `root.add`         | `path`; optional `mode`, `idle_timeout_ms`, `retention`, `on_remove`, `worktrees`, `gitwatch`, `on_worktree`, `worktree`, `nested` | `root`: the new root object         |
| `root.remove`      | `root`; optional `force`                                                                      | `removed`, `root`, `history`                                             |
| `root.set`         | `root`; at least one of `mode`, `idle_timeout_ms`, `retention`, `worktrees`, `gitwatch`       | `root`                                                                   |
| `root.sleep`       | `root`                                                                                        | `root`                                                                   |
| `root.wake`        | `root`                                                                                        | `root`                                                                   |
| `root.status`      | `root`                                                                                        | `root`                                                                   |
| `daemon.shutdown`  | —                                                                                             | `message`                                                                |

`root` is an id or a root path; both are accepted because a person types whichever they have.

**Nested roots are guarded, not warned about** (`plans/worktrees.md` § 5, R2). A nested *root* — a path added to the
daemon as a root of its own — must be invisible to every served parent's scan. A nested *repository* is already excluded
by the boundary rule; a nested root that is a plain directory is excluded by the parent's internal ignore, and `root.add`
arranges that before it serves anything:

1. **A child added inside served parent(s):** for each parent, the child's path relative to that parent is appended
   to `<parent>/.fs-meta/ignore` under the `# fsmeta-managed` block (idempotent; the M1 escaping and its atomic
   temp+rename write are used). The parent is then passed **exactly once**, even when it is `asleep` or `off`: the
   forced pass arms no watcher, so a sleeping parent goes back to sleep, and the line is already in its trio before
   the child's first pass can duplicate it. Only then is the child served.
2. **A parent added after its children:** one managed line is written per already-served descendant **before** the
   new parent's first pass, so the parent never publishes the child's names even once.
3. **Failure is a refusal, exit code 4.** If the append or the parent pass cannot be arranged, `root.add` refuses and
   the message names the file and the parent. It never warns and continues: a visible nested root is the collision
   the guard exists to prevent. The path test is the segment rule (`/a/bc` is not inside `/a/b`), case-insensitive on
   Windows, in both directions.

**The guard is not one of the switches.** `worktrees = off` and `gitwatch = off` stop the worktree handling and git
signals; a nested root is still hidden from its parent with both off. `--no-gitignore` on a pass does not disable
`.fs-meta/ignore` either (`plans/worktrees.md` § 5, G47).

**The two switches, live, and the two add flags.** `worktrees` and `gitwatch` (§ 5h) are copied from `defaults` at add
time and can be changed without a restart:

- `root add <path> --worktrees off|on --gitwatch off|on` writes the record; `root set <id> worktrees off|on` and
  `root set <id> gitwatch off|on` apply the change at once. The **effective** value is what runs: `FSMETA_WORKTREES=0`
  and `FSMETA_GITWATCH=0` at daemon start win over the record, so the reply reports what is in force (a live flip that
  an override masks says so).
- `gitwatch = off` releases this root's reference to the shared metadata arm, forgets the resolved `$GIT_DIR`/
  `$GIT_COMMON_DIR` (so `head`, `detached`, `in_progress` and `common_dir` are empty immediately) and discards the
  signals already queued. `gitwatch = on` resolves and arms again from the root's path. `worktrees = off` drops a
  pending worktree start/finish and stops seed, adoption, `worktree` events and the removal reaction; **it never hides
  a boundary**, because the scan rule lives in the engine and does not consult this flag. A worktree that appeared
  while it was off is not retroactively adopted. Neither flip changes a trio byte.
- `root add --worktree` **asserts** that the path is a linked worktree: `.git` must be a gitfile whose target is an
  existing directory. A plain directory, a nested clone and a broken gitfile are refused with exit code `4` and the
  path in the message. A valid one takes the adoption/seed path for that explicit add and forces `worktrees` on for the
  new record (an environment override still wins). It is the explicit counterpart of `--on-worktree serve`, which is a
  policy for worktrees *discovered under* a served root; it does not change that record's policy.
- `root add --nested` **acknowledges intent only**. The M2 guard still writes the parent's managed line and still
  refuses when it cannot; the flag weakens nothing, is not persisted, and is echoed as `"nested":"acknowledged"` in the
  reply so a script can tell an explicit nested add from a silent one.
- Neither switch affects the `roots list` worktree marker or its common-dir grouping: those describe where the root
  sits (resolved from `.git` under `gitwatch`) rather than what fs-meta does about it.

**Lifecycle of the block.** At daemon start, before any root starts, every served parent's managed block is rewritten
to exactly the served roots inside it — a pair that entered `roots.json` by hand (or was written by an older version)
is guarded before the first pass. `root remove` rewrites its parents' blocks and drops the removed child's line; a
stale line is harmless and the next reconciliation removes it. Every pass appends any missing line for a served
descendant **before** `engine.refresh`, so a block that a person deleted or edited is repaired by the parent's next
pass (`.fs-meta` is not a watcher event, so the 60 s safety net bounds the delay). The user's own lines above the
marker are preserved byte-for-byte; the managed block is its own sub-source, evaluated after them. The parent never
writes the child's `.fs-meta`: the child's trio is written only by passes of the child's own runtime.

A missing parent is skipped at startup: it cannot be scanned, so it cannot duplicate anything, and its record stays
for recovery. A root that is served but whose parent cannot be guarded (a hand-edited registry under a live daemon)
is not repaired in place; the next `root add`/start reconciliation reports the file and path.

**Worktrees are seeded, discovered and removed** (`plans/worktrees.md` § 5e/§ 5f, M6), under `worktrees`:

- **Seeding.** `root.add` of a linked worktree whose repository already has a served root copies the base generation
  when § 5e's conjunction holds: same common dir, base's last pass settled, matching `scan` blocks, byte-identical
  `.fs-meta/ignore`, base trio readable and valid. It writes a **generation-1** trio and a genesis batch 1; the first
  normal pass then publishes generation 2 as a diff, and `last_pass_hashed` says how small it was. A checkout can
  change a file's byte size while its text is identical (`core.autocrlf`); that case keeps the base hash when the
  text hash still matches. A failed copy removes the seeded files and batch and falls back to a cold scan; an
  existing archive is never overwritten.
- **Discovery.** With `on_worktree = serve` on the **discovering** root, a worktree appearing through the metadata
  watch (or, with `gitwatch` off, through the pass that confirmed its boundary) is adopted as a root. The default
  `ignore` reports it and adds nothing; the parent's trio already excludes it by the boundary rule. One drain is
  capped at 32 signals and 3 s so a burst cannot block the daemon.
- **Removal.** `<common>/worktrees/<id>` disappearing marks the corresponding worktree root `missing` immediately
  and disarms its watches; the archive is untouched. `move`/`repair`/`prune` are the same vanished/renamed path
  handling, a `locked` missing root is not reaped, and history is deleted only by an explicit `root remove` with
  `on_remove = delete`. The consumer event is one `GIT_EVENT` `worktree` finish with `path_len = 0`. When the
  **last** linked worktree goes, git also removes the empty `worktrees/` directory, and a recursive-delete backend
  (ReadDirectoryChangesW) reports the parent's deletion rather than the child's; the daemon therefore samples
  `<common>/worktrees` once per half-second (one `stat`) and turns a present→absent transition into that same single
  finish, deduplicated against the event path so one removal never produces two frames. A served worktree root is
  independently marked `missing` by its own tree watcher.
- **`worktrees = off`** stops all of it: no seed, no adoption, no `worktree` event, no removal reaction. The boundary
  rule still keeps a nested repository out of the parent's trio, and an explicit `root add` of the worktree serves it
  as an ordinary root (cold).

**A root object** is what the CLI prints and what a test asserts:

```json
{
  "id": "a1b2c3d4",
  "root": "/home/u/projects/app",
  "mode": "auto",
  "state": "asleep",
  "reason": "idle",
  "clients": 0,
  "idle_timeout_ms": 300000,
  "retention": { "max_batches": 32, "max_bytes": 67108864 },
  "on_remove": "keep",
  "socket": "/run/user/1000/fsmeta/roots/a1b2c3d4.sock",
  "served_by": "inproc",
  "missing": false,
  "head_batch": 12,
  "passes": 7,
  "wakes": 2,
  "last_pass_ms": 1793000000000,
  "last_pass_duration_ms": 12,
  "last_pass_files": 4000,
  "last_pass_hashed": 7,
  "last_pass_batch_bytes": 524288,
  "on_worktree": "ignore",
  "event_passes": 7,
  "safety_passes": 0,
  "head": "main",
  "detached": false,
  "in_progress": "",
  "last_git_kind": "checkout",
  "last_git_phase": "finish",
  "last_git_at_ms": 1793000001234,
  "git_events": 4,
  "git_passes": 3,
  "gitwatch": true,
  "worktrees": true,
  "worktree": false,
  "common_dir": "/home/u/projects/app/.git",
  "last_error": "",
  "created_at": "2026-10-26T06:50:00Z"
}
```

`state` and `reason` are the `STATE` frame's tables (`FORMAT.socket.md` § STATE); `head_batch` is the newest batch
the root considers published; `passes`, `wakes`, `event_passes` and `safety_passes` are diagnostics, not protocol.
`on_worktree` is the root's recorded discovery policy (`ignore` by default, `serve` to adopt); it is copied from
`defaults` at add time like the two switches. `worktrees` and `gitwatch` are the root's effective switches.

**`worktree` and `common_dir` are host state from the resolved git location.** `worktree` says the root is a linked
worktree (`.git` is a gitfile) and `common_dir` is the `$GIT_COMMON_DIR` it shares with the other worktrees of its
repository; both are filled on the pass that resolved them, and both are empty/false when `gitwatch` is off or the root
is not inside a working copy. `roots list --json` carries them in the same flat array; text output prints a `worktree`
marker on the root and puts roots that share a common dir adjacent under a `repo <common dir>` header (sorted
adjacency), with a root that has no common dir last.

`last_pass_ms` is **when** the last pass ran — a wall-clock timestamp in epoch milliseconds — and
`last_pass_duration_ms` is **how long** it took, measured around `engine.refresh` on the same clock. The two are
separate fields on purpose: a timestamp and a duration are different questions, and one field cannot answer both.
`last_pass_files` is the number of names that pass saw (files plus directories), `last_pass_hashed` is how many
entries it had to hash, and `last_pass_batch_bytes` is the size of the batch it wrote — its `files.meta` +
`files.txt` + `files.json` — or `0` when it published no batch (an empty diff does not advance the sequence, and a
first generation has no parent to diff against). These are the per-root wake-scan cost: `fsmeta root status` prints
them as one line (`last pass: 12 ms, 4000 file(s), 512.0 KiB batch`), so an operator can tune `idle` against their own
tree rather than against a guess. `last_pass_hashed` is also the seed evidence: a seeded worktree's first diff hashes
only the files its branch changed. A root that has never scanned reports `last_pass_ms = 0` and the CLI says "none
yet".

**`event_passes` and `safety_passes` split `passes` by cause**, and they are the diagnostics that tell an idle
watcher from a dead one. `event_passes` counts passes a watcher burst caused; `safety_passes` counts the net
described in § 2b — a pass run because nothing had happened for `safety_pass_interval_ms` (60 s) while the root was
`watching`. Both report `STATE.reason = watcher`, because the wire's reason table has no "timer" value and adding one
would be a protocol change for a number no consumer acts on. A root whose `safety_passes` keeps *finding* work has a
watcher problem, not a busy tree; a root whose `safety_passes` finds nothing is simply quiet. The rest of `passes`
are wake scans and `off`'s on-demand scans, which are neither.

**The git fields are host state, and empty with `gitwatch` off.** `head` is the branch name (`main`) or
`detached:<sha8>`; `detached` says which of those it is; `in_progress` is `""`, `merge`, `rebase`, `cherry-pick`,
`revert` or `bisect`, read from the same `$GIT_DIR` files the metadata watch keeps warm
(`plans/worktrees.md` § 5g). A root whose `gitwatch` is off has **no resolved git dir at all**, so all three are
empty/false — not because the root is not a repository, but because the switch means the metadata is never read.
`git_events` counts `GIT_EVENT` frames sent to this root's subscribers, and `git_passes` counts passes a finish waited
for (§ 5d); both stay 0 with `gitwatch` off. `last_git_kind`, `last_git_phase` and `last_git_at_ms` are the **last**
signal the root saw (`branch`/`checkout`/`commit`/`merge`/`rebase`/`index`/`worktree`/`other`, the phase by name, and
the wall-clock epoch millisecond) — recorded before the subscriber check, so a root with no clients still reports what
its watcher observed; all three are empty/`0` before the first event and with `gitwatch` off. `fsmeta root status`
prints them as `git events: 4 sent, 3 pass(es) a finish waited for` and `last git event: checkout finish`, and omits
the lines when there is nothing to say. `gitwatch` repeats this root's effective switch, so a
caller that is not the daemon can ask whether a hook spool for this root would ever be read — which is exactly what
`fsmeta daemon hooks install` does before it writes anything (§ 6).

### 4b. Housekeeping APIs that cover more than one root

A *housekeeping* API is any control request that reports on or changes the machine rather than one root's data:
`roots`, `status`, and every future `roots …` verb. None of them is on the consumer path — a client's batches
never go through them — so they are allowed to wait, but they must not become a hostage of one slow or stuck root
(a pass, or a write to a client that stopped reading, holds that root's lock — § 2c).

**The rule, which applies to every housekeeping API added later:**

1. **Every wait has a budget chosen by the operation**, not by the root. The budget is a property of what was
   asked: a listing over many roots must answer quickly, a root named on the command line can be waited for a
   little, and a mutation must either happen or be refused.
2. **One root lock at a time, never two.** A multi-root call walks the roots in order, takes one lock, writes that
   root's object, releases it, and moves on. No housekeeping call nests root locks, so no two can deadlock, and the
   whole call is bounded by `roots × budget`.
3. **An expired budget is "not yet available", never a guess.** The root's object becomes
   `{"available": false, "id": "…", "root": "…", "reason": "busy"}` — no state, no counters, no field read without
   the lock — and the reply carries `"partial": true` next to `"roots"`. The call is still `ok`, because "I could
   not read this root yet" is a truthful answer to a listing.
4. **A single-root call that expires is a refusal.** `root.status` on a busy root answers `code = 4` with a
   message naming the root, because there is no `partial` field to carry the gap: a caller that gets a success must
   be able to trust every field in it.
5. **Lifecycle calls wait without a budget.** `root.remove` (with `--force`) and `daemon.shutdown` must actually
   finish what they were asked to do; a caller that wants a root or a daemon gone is already committed to waiting.
   They are the only calls allowed to block indefinitely.
6. **`available` is always present** — `true` on a full object — so no caller infers availability from the absence
   of a field, and adding a field later cannot change what "available" means.

| operation                                | budget per root | why                                                                   |
| ---------------------------------------- | --------------- | --------------------------------------------------------------------- |
| `status`                                 | none            | it reads the pid, base and counts only, never a root lock             |
| `roots`                                  | 50 ms           | a listing is a picture of a machine, not a place to wait              |
| `root.status`                            | 250 ms          | one root, asked for by name; a short wait is welcome                  |
| `root.set`, `root.sleep`, `root.wake`    | 2 s             | a mutation is "done" or "not yet", never a silent no-op               |
| `root.remove --force`, `daemon.shutdown` | unbounded       | the caller asked for the work to be finished                          |
| `root.add`                               | 2 s per parent  | the parent pass that must land before the child is served (the guard) |

The numbers are choices; the shape is the rule: **a bounded wait, a truthful "not yet", and a refusal rather than a
fabricated answer.** `tests` pin it by making one root sit in a blocked write and asserting that `roots list`
answers with `available: false` for it while the other root is a complete object.

### 4c. `daemon.json`

```json
{ "v": 1, "pid": 42348, "started_at": "2026-10-26T06:50:00Z", "protocol": 257, "base": "/run/user/1000/fsmeta" }
```

It is *not* the authority on whether a daemon is live — the lock is, and the control socket is what a CLI talks to.
It is the cheap answer to "is there a daemon, and where is its base?" without opening a socket.

**A CLI checks `daemon.lock` before connecting.** On Windows a refused AF_UNIX connect is not a clean error — Zig
reports an unmapped `NTSTATUS` and aborts the process — so "connect and see" is not a safe way to probe a socket a
dead daemon left behind.

---

## 5. Lifecycle, crash safety and reaping

**Start**, in this order:

1. Take `<base>/daemon.lock` exclusively. A live lock means a live daemon: refuse and say so (`exit 4`).
2. Read `roots.json`. A missing file is a valid state — no roots, no error.
3. For each record: one `stat` of the root path. Present → claim it, bind `<id>.sock`, start accepting. Missing →
   the root is `missing`: reported, not dropped.
4. Reap what a dead process left in the runtime directory: claims nobody holds (and the sockets they name), and
   sockets whose claim is gone. A claim that a live process holds is never touched.
5. Only then bind `daemon.sock` and write `daemon.json`, so a CLI never sees a half-loaded daemon.

**Stop** (`daemon stop`, `daemon.shutdown`): send a final `STATE` to every subscriber and close their connections,
close the watchers, unlink the sockets, release the claims, remove `daemon.json`, exit `0`.

**Crash**: the next start reaps what the dead process left; the lock is released by the kernel, so a stale claim is
exactly a claim nobody holds. Nothing in a trio is left half-written, because the trio's writes are already atomic
(`FORMAT.md` § 9).

**Root removed**: the socket, the claim and the log go; the record goes; the batches stay unless
`on_remove = delete` (§ 3a).

**Signals.** `daemon stop` is the graceful path everywhere. On POSIX, `SIGTERM`/`SIGINT` end the process without the
graceful path, and the next start reaps — that is the crash path, and it is safe by construction. On Windows a
console signal is the same crash path.

---

## 6. The CLI and its exit codes

```
fsmeta daemon start [--base <dir>] [--foreground]   # daemonize by default; --foreground for tests
fsmeta daemon stop                                  # asks politely, then waits for the socket to go
fsmeta daemon status [--json]                       # pid, base, roots, uptime, both switches, overrides, notes
fsmeta roots list [--json] [--state watching,asleep]
fsmeta root add <path> [--mode off|always|auto] [--idle 5m] [--keep-batches 32] [--max-bytes 64M]
                       [--on-remove keep|delete] [--worktrees on|off] [--gitwatch on|off]
                       [--on-worktree ignore|serve] [--worktree] [--nested]
fsmeta root remove <id|path> [--force]
fsmeta root set <id> mode off|always|auto
fsmeta root set <id> idle <duration>                # 0 = never sleep
fsmeta root set <id> keep-batches <n>
fsmeta root set <id> worktrees on|off               # live: adoption/seed/events/removal; never the boundary rule
fsmeta root set <id> gitwatch on|off                # live: releases/arms the metadata watch; clears the git fields
fsmeta root sleep <id>                              # force a sleep now, always mode too
fsmeta root wake <id>                               # force a wake; refused when mode = off
fsmeta root status <id> [--json]
fsmeta daemon hooks install <root> [--force]        # write the git hooks; local file operation, no daemon needed
fsmeta daemon hooks uninstall <root>                # remove them, restoring a chained original byte for byte
fsmeta daemon hooks status [<root>] [--json]        # ours/foreign/chained per hook, and the spool size
fsmeta exclude <root>                               # append the marked .fs-meta/ block to <common>/info/exclude (§ 6b)
```

`daemon status` prints `worktrees on, gitwatch on` (the effective values) and adds `note: FSMETA_WORKTREES=off is
active` / `FSMETA_GITWATCH=… is active` when an environment override is in force; `--json` carries the same as
`worktrees`, `gitwatch`, `worktrees_override` and `gitwatch_override` (empty when no override). `roots list` groups
roots that share a git common dir and marks a linked worktree: `worktree` is appended to its line, and the group sits
under `repo <common dir>` (sorted adjacency; roots without a repository come last). `--json` stays the flat array and
carries `worktree` and `common_dir` per root.

Durations: `500ms`, `30s`, `10m`, `2h`, or a bare number of milliseconds; `0` means "never". Byte budgets:
`1024`, `64K`, `64M`, `2G`.

### 6a. Hooks: what the commands write, and what they refuse

The hooks are the precise git signal (`plans/worktrees.md` § 5c, M5). They are **opt-in per repository**, installed by
an explicit command and never by `root add`, because a hook is user code and a security surface. One install covers
every worktree of the repository, including ones created later: the files live in `$GIT_COMMON_DIR/hooks`, which git
shares across worktrees.

`install` writes six files — `reference-transaction`, `post-checkout`, `post-merge`, `post-rewrite`,
`post-index-change`, `post-commit` — each a POSIX `sh` script with **LF** line endings (a CRLF hook fails under git's
bundled `sh` with `\r: not found`; on POSIX it also gets the executable bit), the `# fsmeta-managed` marker on its
first content line, `trap 'exit 0'` and `|| true` on every write. The script appends one JSON line to
`<common>/fsmeta-events.log` with the hook, the phase, the worktree, the arguments and an epoch-seconds timestamp, and
exits 0 on every path: a non-zero `reference-transaction` hook would **abort the user's ref update**, so a full disk
must cost an event, never a failed `git commit`.

The spool is `git`'s private state, not the user's tree: per repository, so it exists for every worktree without
creating a `.fsmeta` in a tree fs-meta does not serve, and it survives `git worktree remove`. The script finds the
common dir and its own worktree with **one** `git rev-parse --path-format=absolute --git-common-dir --show-toplevel`
call rather than an embedded path, so a moved or repaired repository keeps working (a git older than 2.31, which has no
`--path-format`, falls back to the two-call form and resolves the relative common dir itself). It truncates the spool
at 64 KiB before appending: a repository can go months without a daemon, and an unbounded file inside `.git` is not
acceptable.

`install` refuses, with exit code `4` and a message that names the reason, when:

| refusal                            | why |
| ---------------------------------- | --- |
| `core.hooksPath` is set            | git would never look in `<common>/hooks`, so the hooks would silently never run. The message names the configured path. Git itself is asked (so `include.path`, the global and system files are honoured); without git on `PATH` the repository's own `config` is read, which misses a *global* setting — stated here rather than guessed at |
| the root's `gitwatch` is off       | the daemon would never read the spool. The answer comes from the running daemon's `roots` reply, or from the durable `roots.json` when no daemon runs (this is what makes `install` work before the first start). If neither knows the root, `install` refuses and says so rather than installing a trap |
| `<common>/hooks` cannot be written | a read-only repository cannot report git events. The check is a real write (a probe file created and removed), and the message names the path |
| a hook exists and is not fsmeta's  | a user hook is never overwritten silently. `--force` keeps it as `<name>.fsmeta-orig` and writes a wrapper that runs it **first**, with the arguments git gave it, then appends our line (` |  | true`, so a failing user hook cannot abort a git operation) |

`uninstall` removes our wrappers, restores a chained original over its wrapper byte for byte, and leaves a foreign
hook alone. `status` reports, per repository, each hook's state (`ours`, `foreign`, `chained`, `absent`) and the spool's
size; `--json` is one object per repository under `repositories`. `status` with no root groups every served root by
common dir, because several served worktrees share one hook set.

**The cost, measured.** A hook is a process per git operation, and git runs the `reference-transaction` hook once per
phase per transaction: on this Windows host, where each spawn of git's bundled `sh` or of an msys utility costs
25–50 ms, a one-file `git checkout` went from ~33 ms to ~3.3 s with the first version of the script and ~1.1–1.35 s
after the body was tightened (an early exit on `preparing`, one `rev-parse` instead of two, `sed` only when a path
actually needs escaping). The remaining cost is interpreted-shell spawning, not the spool write, and it is why the
hooks are opt-in per repository. A checkout also produces a start/finish pair per ref transaction (three or more on
this git), because coalescing is per `(kind, phase)` **per pass** and the hook processes are spread across ticks.

| code | meaning                                                                              |
| ---- | ------------------------------------------------------------------------------------ |
| `0`  | ok                                                                                   |
| `1`  | a usage error, a failure the daemon reported without a table entry, or `exclude` on a path that is not a repository |
| `2`  | no such root — or `root add` of a directory that does not exist                      |
| `3`  | the daemon is not running (no `daemon.json`, no live lock, or nothing answering)     |
| `4`  | refused by policy: `wake` on `off`, `remove` with live subscribers, a duplicate `add`, a second daemon on one base, `--worktree` on a path that is not one, and every `hooks install` refusal of § 6a |
| `5`  | the CLI and the daemon do not share a control protocol version (`"v"`)               |

### 6b. `exclude`: what the command writes

`fsmeta exclude <root>` is a **top-level engine command, not a daemon one**: it is a local file operation, needs no
daemon, and writes nothing inside the working tree. It appends exactly two lines to git's repo-local exclude file,
`<common>/info/exclude`:

```
# fsmeta: our own directory
.fs-meta/
```

The marker names the edit so a person can find it; `.fs-meta/` hides fs-meta's own directory from git's "untracked
files" test, which is what makes `git worktree remove` of a served worktree work without `--force` (§ 5f of
`plans/worktrees.md`). The block is appended at end of file, after a newline if the existing file did not end with one,
and its own bytes are **LF only**. The write is atomic (a temporary beside the file, then a rename), and `info/` and the
file are created when missing. It is **idempotent**: when the marker and the entry are already present, nothing is
written and the command says so.

It refuses, with exit code `1` and the path in the message, when `<root>` is not a git working copy (no confirmed
`.git` entry — the same confirmation the boundary rule uses), because there is no `<common>` to write. It never edits a
line a person wrote, and it is never automatic: `info/exclude` is git's file. **A later `!` line in the same file
overrides the entry** (git's last-match-wins rule), and the command says so in its output. The recommended way to stop
serving a worktree before `git worktree remove` is still `fsmeta root remove <id>`; `exclude` is the one-line opt-in
for a user who wants git to permit the removal without `--force`.

**What each file-writing command owns:** `hooks install` writes `$GIT_COMMON_DIR/hooks/<name>` (§ 6a); `exclude` writes
`$GIT_COMMON_DIR/info/exclude` (§ 6b); `root add` writes the *parent's* `<root>/.fs-meta/ignore` managed block (§ 4).
None of them writes the served root's trio, and none touches a file inside a tree fs-meta does not serve.

`daemon start` without `--foreground` spawns this same executable with `--foreground`, detached, with no console and
no inherited streams, and then waits for the control socket to answer: `start` means "it is up", not "a process was
spawned".

---

## 7. The seam for per-root daemons

`host.zig` reaches a root only through a small surface: `snapshot`, the control operations and the root's own
scheduler. That is the line where a root could be served by its own child process (`fsmeta root-daemon --id <id>`)
with nothing above it changing — not the control protocol, not the CLI, and not the consumer sockets. The registry
records `served_by`, and every reply prints it, so an aggregated view could say which roots live where.

Nothing is split today, and **the reason is no longer latency**: each root has its own scheduler task and its own lock
(§ 2c), so one root's scan does not delay another's batches. What a split would still buy is failure and memory
isolation. That work is not part of this document or the daemon plan; it is specified, with its open decisions and a
definition of done, in [`plans/tbd-per-root-daemon.md`](plans/tbd-per-root-daemon.md).

---

## 8. Platform notes (Windows, Zig 0.17)

Three things about this host cost a debugging session each; they are written down so they cost nothing twice.

- **A blocked `accept` cannot be cancelled or closed underneath.** Zig's `netAccept` on Windows maps the resulting
  cancelled status to `unreachable`, so both `Group.cancel` and `listener.deinit` abort the process instead of
  returning an error. The daemon sets a `stopping` flag and **connects to its own socket once** to let the accept
  complete, then waits for the tasks, then closes the listener (`RootRuntime.deinit`).
- **Connecting to a stale AF_UNIX address aborts the process** for the same reason (`CONNECTION_REFUSED` is an
  unmapped `NTSTATUS`). Nothing probes a socket by connecting to it: a claim (a lock) is the authority, and the CLI
  checks `daemon.lock` before it connects at all.
- **A file that still has an open handle cannot be deleted.** A claim is released before its file is removed, and
  `isFree` *opens* a claim rather than creating it — an earlier version's `createFile` re-created the very file the
  reaper had just deleted.

**A test guard, not a feature: `FSMETA_GIT_ARM=off`.** It disarms the metadata watcher (§ 2b) while leaving everything
else — the git dirs are resolved, the latch polls, the hook spool is read — so the hook path can be proved on its own
in an integration test. It is the only way to take the metadata timeline out of the picture without a second build. A
typo or an empty value is no guard; a daemon started with it prints one line saying so.

**The hook cost is a Windows fact.** Git's bundled `sh` and msys utilities cost 25–50 ms per spawn here, so a hook is
~150 ms of process time; § 6a records the measured effect on a checkout. Nothing in the design can remove the spawn —
it is what running a hook means — which is why the hooks are opt-in and the body does as little as possible.

## 9. What is not implemented

- **A per-root child daemon** (§ 7). The interface and the `served_by` field are there; no child process is.
  Specified, with its open decisions and a definition of done, in
  [`plans/tbd-per-root-daemon.md`](plans/tbd-per-root-daemon.md).
- **A signal handler that takes the graceful path.** A signal is a crash, and the next start reaps it (§ 5).
