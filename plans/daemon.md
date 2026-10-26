# fs-meta daemon — implementation plan

**Status:** plan for a new session. Nothing in this document is implemented yet.
**Language:** Zig only. Tooling and tests around it stay Bun, per the house rules.
**Purpose:** one long-lived process that tracks a set of active roots, keeps a Unix socket per root for consumers, and
decides when each root is worth watching.

---

## 1. What it is, in one paragraph

`fsmeta daemon` runs in the background. Each **root** it tracks gets its own Unix socket that speaks the existing binary
protocol from [`FORMAT.socket.md`](../FORMAT.socket.md) — a consumer connects, `SUBSCRIBE`s, and receives batches as the
tree changes. Each root has a **watch mode** (`off`, `always`, `auto`) and an **idle timeout**: watching costs a thread and
filesystem handles, so a root that nobody is listening to can go **asleep**, and waking it costs one full scan to work
out what changed while it slept. A small **control socket** plus a CLI let a person list roots, change modes and timeouts,
and force a sleep or a wake. The process model is deliberately shaped so that a root can later be served by its own child
daemon without changing the consumer-facing socket or the control interface.

## 2. Goals and non-goals

**Goals**

1. Track N roots in one process, each with a stable socket path that consumers can discover.
2. Per-root mode: `off` (never watch), `always` (watch regardless of clients), `auto` (watch only while at least one
   client is subscribed).
3. Per-root idle timeout: after this long without a reason to watch, the root sleeps; the next request wakes it with a full
   scan and a diff, publishes that as batches, and resumes watching.
4. A diagnostic CLI that lists roots and their state, and controls mode, timeout, sleep and wake.
5. Seams that allow *per-root daemons* later, with a main daemon aggregating their state.

**Non-goals (for now)**

- No service manager, no login-time autostart, no supervision/restart policy. Those are a later decision.
- No network sockets. Unix domain sockets only.
- No change to the trio format or the batch protocol semantics. A daemon is a *server* of the same data.
- No change to which process writes: the Zig engine remains the only writer.

## 3. Where it sits in the existing code

| existing module                                      | role in the daemon                                                                      |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `src/scan.zig`                                       | the full scan; the wake path reuses it                                                  |
| `src/engine.zig`, `src/batch.zig`, `src/publish.zig` | produce and publish the batch trio; the daemon calls them, it does not reimplement them |
| `src/server.zig`, `src/wire.zig`                     | the per-root socket server and framing; today one root per process, the daemon needs N  |
| `src/watch.zig`, `watch_run.zig`, `watch_tuning.zig` | the nightwatch-backed watcher; the daemon decides *when* it runs, not *how*             |
| `src/coldstart.zig`                                  | the existing "scan then serve" path; the wake path is a second caller of it             |
| `src/query.zig`, `src/fsmeta.zig`                    | the CLI patterns to follow for the new subcommands                                      |

The one structural change to existing code: `server.zig` currently owns *a* root. It becomes a per-root value
(`RootServer`) that the daemon instantiates N times, with no global state added inside it.

## 4. New modules

```
src/daemon/host.zig        the process: owns the event loop, the registry, and N RootRuntimes
src/daemon/registry.zig    durable state: roots, modes, timeouts, socket paths, pids — plain data, no sockets
src/daemon/root.zig        RootRuntime: one root's socket, subscribers, state machine, watcher, idle deadline
src/daemon/state.zig       the state machine alone: asleep/waking/watching/off, pure and clock-injected
src/daemon/control.zig     the control socket: JSON-lines request/response, versioned
src/daemon/cli.zig         `fsmeta daemon …` and `fsmeta root …` subcommands, talking to the control socket
src/daemon/paths.zig       socket and state directory resolution, short socket names
src/daemon/reaper.zig      stale socket/lock/registry cleanup on start and on remove
```

**Why `state.zig` is separate from `root.zig`:** the state machine is the part with the subtle behaviour (idle vs.
subscribers vs. mode), and separating it makes it testable with an injected clock and no sockets at all. The socket
and the watcher are plumbing around it.

**The future-split seam.** `host.zig` talks to roots only through a `RootHost` interface:

```zig
pub const RootHost = struct {
    snapshot: *const fn (self: *anyopaque, alloc: std.mem.Allocator) anyerror!RootSnapshot,
    control:  *const fn (self: *anyopaque, request: ControlRequest) anyerror!ControlReply,
    deinit:   *const fn (self: *anyopaque, alloc: std.mem.Allocator) void,
};
```

`inproc` implements it over a `RootRuntime` in this process. A later `child` implements it over a spawned
`fsmeta root-daemon --id <id>` and a pipe or a second socket. Nothing above `RootHost` — not the control protocol, not the
CLI, not the consumer-facing sockets — changes when that swap happens. The registry records `served_by = inproc | child:<pid>`
so an aggregated view can say which roots live where.

## 5. Runtime state machine (per root)

```
            add root                       subscriber arrives / control wake
   (none) ─────────► off ──mode change──► asleep ◄──────────────┐
                       │                    │  wake              │ idle deadline
                       │ mode = always      │  (scan + diff)     │ (auto, no clients)
                       │ or auto + client   ▼                    │
                       └────────────────► waking ──► watching ───┘
                                            (batches published)   idle deadline
                                                                  (always: only if mode changes)
```

- **off** — socket is still bound and answers from a scan; the watcher never runs. A control `wake` is refused with
  `mode=off` rather than silently ignored.
- **asleep** — socket bound, no watcher, no open tree handles. A `SUBSCRIBE` or a control `wake` starts **waking**.
- **waking** — a full scan runs, the new state is compared with the last published generation, and the difference is
  published as normal batches. This is the "slower response after sleep" the user asked for: one scan, then the diff, then
  normal watching. If the gap exceeds the retention window, the existing `batch-gap` / `batch-too-old` refusals apply
  unchanged — the daemon does not pretend a slept gap was never there.
- **watching** — the watcher is running and events flow.
- **Idle rule** — a root with no subscribers and `mode = auto` moves to `asleep` once `idle_timeout_ms` has passed since the
  last activity. `mode = always` ignores subscribers and never sleeps (a control `sleep` still forces it, and it wakes on
  the next event or wake). `mode = off` never watches.
- **Clients are the reason to watch, not the reason to exist** — a root with zero clients keeps its socket and its last
  published generation, so a returning client gets the diff, not a cold start.

## 6. Paths and naming

**Two directories, and the difference matters.** The **runtime** directory holds sockets and pids: it is ephemeral (a
tmpfs at `$XDG_RUNTIME_DIR`, cleared at logout) and losing it is normal. The **home** directory holds the list of known
roots and their configuration: it is durable, it is what makes a restart cheap, and it is the only thing that answers
"what was I serving?" — see § 6a.

**Runtime base directory** (host state, never in the trio):

| platform                            | directory                   |
| ----------------------------------- | --------------------------- |
| Linux/macOS, `$XDG_RUNTIME_DIR` set | `$XDG_RUNTIME_DIR/fsmeta`   |
| macOS/Linux without it              | `~/.cache/fsmeta/run`       |
| Windows                             | `%LOCALAPPDATA%\fsmeta\run` |

Layout:

```
<base>/
  daemon.sock                 the control socket
  daemon.json                 pid, started_at, protocol major, base dir — what a CLI reads before connecting
  roots/<id>.json             one record per root: root path, mode, idle_timeout_ms, retention, socket, served_by, pid
  roots/<id>.sock             the consumer socket for that root
  logs/<id>.log               per-root log; rotated on start, removed with the root
```

**`<id>` is derived, not random**: `hex8(wyhash(canonical_root_path))`, so the same root gets the same id across restarts
and a second daemon can detect a live claim. The socket name is `<id>.sock` — 13 characters — because AF_UNIX paths are
limited to ~104–108 bytes and a hash is the only way to stay short for deep roots. The `roots/<id>.json` record carries the
*root path*, which is what makes the short name resolvable; this is host state, and the trio itself still never contains an
absolute path.

### 6a. The root list lives in the user home, and a restart never searches

**The invariant:** *the daemon never walks the filesystem to discover roots.* On start it reads the list, and the work is
proportional to the number of recorded roots — one `stat` each to notice a disappeared root, nothing more. A daemon that
searched for `.git` directories, or re-scanned `$HOME`, would make every restart unbounded and would find roots the user
never asked for.

| platform                | durable list (home)                  | ephemeral (runtime)          |
| ----------------------- | ------------------------------------ | ---------------------------- |
| `$XDG_CONFIG_HOME` set  | `$XDG_CONFIG_HOME/fsmeta/roots.json` | `$XDG_RUNTIME_DIR/fsmeta/`   |
| otherwise (Linux/macOS) | `~/.config/fsmeta/roots.json`        | `~/.cache/fsmeta/run/`       |
| Windows                 | `%APPDATA%\fsmeta\roots.json`        | `%LOCALAPPDATA%\fsmeta\run\` |

`roots.json` is one document, written atomically (tmp + rename), holding every root's record from § 9. It is
*configuration*: a choice about this machine, committed by a person through `fsmeta root add`, and it survives a reboot,
a crashed daemon and an empty runtime directory. The runtime directory is rebuilt from it on every start.

**Startup sequence, in order:**

1. Read `roots.json`. A missing file is a valid state: no roots, no error.
2. For each record: `stat` the root path. Present → create its runtime entry and bind its socket. Missing → the root
   becomes `state = missing`, is reported by `roots list`, and is **not** silently dropped; `--prune` removes it.
3. Only then bind the control socket and answer `status`, so a CLI never sees a half-loaded daemon.

**Why a single file, not a directory of files:** the list is small (tens of roots), read once at start, written on every
mutation; one atomic rename is easier to reason about than N files plus a directory scan — and a directory scan on a
network home can be slow. If it ever grows past a few hundred roots, per-root files in `~/.config/fsmeta/roots/` are the
documented alternative, read by `readdir` once (still not a filesystem search).

**What is *not* in the user home:** sockets, pids, runtime state, per-root logs. Those are facts about a running process on
one machine, and they belong in the runtime directory — the same distinction the jcodebuddy webview rules draw between
configuration and host state.

**Claiming**: `<runtime>/roots/<id>.json` is created with `O_EXCL`, then the pid is written. A record whose pid is not alive
is stale and reaped. This is what stops two daemons from serving one root.

## 7. Consumer socket: unchanged protocol, one addition

Consumers keep using [`FORMAT.socket.md`](../FORMAT.socket.md): `HELLO`, `SUBSCRIBE`, `START_BATCH`/`CHANGE_ENTRY`/`END_BATCH`,
`PING`/`PONG`, and the two refusals. **The daemon adds no semantics to those frames.**

One additive frame is proposed, and it is the only protocol change:

| kind   | name    | payload                                                                           | why |
| ------ | ------- | --------------------------------------------------------------------------------- | --- |
| `0x09` | `STATE` | `u8 state` (`0`=off, `1`=asleep, `2`=waking, `3`=watching), `u32 idle_timeout_ms` | a client can tell "slow because waking" from "slow because big"; also what the CLI's diagnostics show |

It rides the existing `protocol` handshake: bump the minor to `0x0101` and gate `STATE` behind a capability bit, so a
client pinned to `0x0100` still works and simply never receives it. **Decide before implementing**: the alternative is to
send nothing and let the first batch's latency speak for itself. My recommendation is the frame, because "why is this
subscribe slow" is the exact question the sleep feature creates.

## 8. Control socket and CLI

**Control protocol:** JSON lines over `<base>/daemon.sock` — one request object, one reply object, connection closed.
Deliberately *not* the binary batch protocol: it is a management interface, humans and scripts are its callers, and JSON is
diffable in a log. Version field first: `{"v":1,"cmd":...}`.

Requests: `status`, `roots`, `root.add`, `root.remove`, `root.set` (`mode`, `idle_timeout_ms`, `retention`), `root.sleep`,
`root.wake`, `daemon.shutdown`.

**CLI surface** (`fsmeta` keeps its existing top-level commands; these are new):

```
fsmeta daemon start [--base <dir>] [--foreground]     # daemonize by default; --foreground for tests
fsmeta daemon stop                                    # asks politely, then reports
fsmeta daemon status [--json]                         # pid, base dir, roots count, uptime
fsmeta roots list [--json] [--state watching,asleep]  # per root: id, path, mode, state, clients, idle timeout
fsmeta root add <path> [--mode off|always|auto] [--idle 30s] [--retention 32]
fsmeta root remove <id|path> [--force]
fsmeta root set <id> mode off|always|auto
fsmeta root set <id> idle <duration>                  # 0 = never sleep
fsmeta root sleep <id>                                # force a sleep now (always mode too)
fsmeta root wake <id>                                 # force a wake; refused when mode = off
fsmeta root status <id> [--json]
```

Durations accept `500ms`, `30s`, `10m`, `0`.

**Exit codes** (stable, documented, tested):

| code | meaning                                         |
| ---- | ----------------------------------------------- |
| `0`  | ok                                              |
| `2`  | no such root                                    |
| `3`  | daemon not running                              |
| `4`  | refused by policy (e.g. `wake` on a root whose mode is `off`, `remove` with live clients without `--force`) |
| `5`  | protocol mismatch (CLI newer/older than daemon) |

## 9. Configuration

Per-root config lives **in the durable list in the user home** (§ 6a), not in the trio and not in a project's
`.jcodebuddy`-style directory: it is a
choice about this machine's daemon, not about the tree's contents. The record is the source of truth; CLI commands mutate
it and the daemon writes it back atomically (write `<id>.json.tmp`, rename).

```json
{
  "id": "a1b2c3d4",
  "root": "/home/u/projects/app",
  "mode": "auto",
  "idle_timeout_ms": 30000,
  "retention": 32,
  "socket": "/run/user/1000/fsmeta/roots/a1b2c3d4.sock",
  "served_by": "inproc",
  "created_at": "2026-10-26T06:50:00Z"
}
```

Defaults: `mode = auto`, `idle_timeout_ms = 30000`, `retention = 32` (the format's documented default). The daemon reads
the files on start; a malformed record is reported and skipped, not fatal to the other roots.

## 10. The wake path, precisely

This is the part users feel, so it gets its own contract:

1. A `SUBSCRIBE` arrives on a sleeping root's socket → state becomes `waking`, and the client is **not** answered yet (or is
   sent `STATE` if the frame is adopted).
2. The daemon runs the full scan (the same one `coldstart` runs) and compares it with the last published generation.
3. The difference is published as one batch (or a small chain if the diff crosses the batch limit), then `END_BATCH`.
4. State becomes `watching`; the watcher is armed; idle deadline is cleared while clients are subscribed.
5. If a second client subscribes during `waking`, it is queued and served by the same batch — no second scan.

**Failure is explicit**: if the root disappeared, the scan fails and the client gets an `ERROR` (`code=1`, protocol) with a
message naming the root instead of a hang; the root moves to `off` and the CLI shows why.

## 11. Lifecycle, crash safety and reaping

- **Start**: read `roots.json` from the home directory (§ 6a) and the runtime `daemon.json`; if a live daemon holds the
  runtime, refuse and say so. Reap stale `roots/*.json`
  (pid dead) and `*.sock` files with no live listener. Bind `daemon.sock` after unlinking a stale one.
- **Stop**: publish a final `END_BATCH` to subscribers, close watchers, unlink sockets, remove `daemon.json`, exit `0`.
  `SIGTERM` and `SIGINT` take the same path; a `--force` second signal exits immediately.
- **Crash**: the next `start` reaps what the dead process left. Nothing in the trio is left half-written, because the trio's
  writes are already atomic (established by the format).
- **Root removed**: socket unlinked, watcher stopped, record deleted, log removed. Batches stay on disk — the data is not the
  daemon's to delete.

## 12. Concurrency model in Zig 0.17

Single event loop in `host.zig`, no thread per root:

- one poll/timed-wait over: the control socket, every root's listener, every connected client, and the watcher's event
  source;
- the timeout is `min(next idle deadline, 1s)` so idle checks are never later than a second;
- `nightwatch` already delivers events from a background thread; the daemon drains a queue per root on the loop, which keeps
  all state owned by one thread and needs no mutex;
- publish/scan are synchronous inside the loop. If a scan of a huge root blocks others, that is the signal for the
  future split — record it, do not pre-emptively thread it.

## 13. Testing strategy

**Unit (Zig)**

- `state.zig` against an injected clock: every transition, the idle rule for each mode, sleep/wake with and without
  clients, `off` refusing a wake.
- `paths.zig`: id stability for the same path, different ids for different paths, socket name length bounds for a 4 000-byte
  root, base-dir resolution per platform.
- `registry.zig`: record round-trip, malformed record skipped and reported, atomic replace.

**Integration (Bun, driving the real binary)** — the house pattern already used by `test/socket.test.mjs`,
`test/serve-stream.test.mjs`:

- start `--foreground` on a scratch base dir, add two roots, assert both sockets exist and answer `HELLO`/`SUBSCRIBE`;
- write a file, assert a `CHANGE_ENTRY` arrives on the subscribed root and **not** on the other;
- set `idle 200ms`, subscribe, disconnect, wait, assert `roots list --json` says `asleep`;
- subscribe again, assert one scan-then-batch (count scans via a debug counter in `--json`), and that state returns to
  `watching`;
- modes: `off` never watches (touch a file, assert no batch), `always` watches with zero clients;
- two daemons on one base dir → the second refuses; kill -9 the first, start again → stale files reaped;
- CLI contract: exit codes `0/2/3/4/5` for the documented situations.

Sockets are AF_UNIX, which this Windows host supports (established in `test/socket.test.mjs`); skip those tests where the
filesystem refuses, with the reason printed — never silently.

## 14. Milestones

Each milestone ends green on the gates that already exist for this repo: `zig build test --summary all`, the Bun suite,
and `mvn -q test` for the Java port (which must keep building against the published matcher).

| #      | deliverable                                                       | gate                                                                                                |
| ------ | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **M0** | `paths.zig`, `registry.zig`, `state.zig` + the durable home list + control socket + `daemon start/stop/status` and `roots list`; no watching yet, roots are records only | unit tests; a root added, the daemon stopped and restarted, and the root still listed **without any filesystem search**; a deleted root path shows `missing`; second daemon refuses |
| **M1** | one root served: `RootRuntime` owns a socket, answers `HELLO`, `SUBSCRIBE`, cold scan and a first batch; `server.zig` refactored into a per-root value | a real client gets a batch; parity with `fsmeta serve` on the same tree |
| **M2** | the state machine wired: `off`/`always`/`auto`, idle timeout, sleep, wake with scan+diff; `STATE` frame if adopted | the sleep/wake integration tests; `wake` refused on `off` |
| **M3** | multi-root: N sockets, N watchers, add/remove at runtime, reaping | two roots, isolated batches; remove leaves no socket                                                |
| **M4** | diagnostics: `root status --json`, scan counters, per-root log, `FORMAT.daemon.md` documenting control protocol, registry schema, naming, exit codes | docs reviewed; CLI JSON asserted in tests |
| **M5** | the split seam exercised: a `child` `RootHost` behind a flag, one root served by a child, the main daemon aggregating | same consumer socket path; `roots list` shows `served_by`; killing the child is reported, not fatal |

M5 is deliberately last and optional: the point of M0–M4 is that it is *possible*, and the interface in §4 is what makes it
possible. If M5 is dropped, nothing in the design is wasted.

## 15. Risks and their mitigations

| risk                                        | mitigation                                                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| runtime dir cleared at logout/reboot        | the root list is in the user home (§ 6a); start rebuilds sockets from it, and a missing runtime directory is a normal first start |
| AF_UNIX path limit on deep roots            | hashed `<id>.sock` (13 chars) under a short base dir; asserted in a path test                     |
| a sleeping root's wake scan is expensive    | it is *one* scan, and it is what the user asked for; expose the cost in `--json` (files, bytes, ms) so it can be tuned via `idle` |
| two daemons serving one root                | `O_EXCL` claim file + pid liveness; test it                                                       |
| daemon holds the tree open and blocks tools | watcher handles only while `watching`; sleeping roots hold nothing                                |
| Zig 0.17 API drift for sockets/watch        | all socket code stays behind `wire.zig`/`server.zig`; the daemon never calls `std.posix` directly |
| `STATE` frame breaks an old client          | capability bit + minor bump; a `0x0100` client never sees it                                      |

## 16. Decisions to take in session 1, before coding

1. **`STATE` frame: add it or not?** Recommendation: add (`0x09`, capability-gated). Without it, a slow subscribe is
   indistinguishable from a slow tree.
2. **Default idle timeout**: 30 s proposed. Rationale: long enough that a developer's edit-run loop keeps the watcher warm,
   short enough that an abandoned root stops costing a thread.
3. **`off` roots: bind a socket at all?** Recommendation: yes — `off` means "never watch", not "not served"; a consumer then
   gets a scan-based answer and the CLI reports `state=off`, which is more useful than `ENOENT`.
4. **Where the base dir lives on Windows**: `%LOCALAPPDATA%\fsmeta\run` proposed; the format's own docs stay platform-neutral.
5. **Does `root remove` delete the root's published batches?** Recommendation: no. They are the tree's data, not the
   daemon's.
6. **One `roots.json` or per-root files in the home?** Recommendation: one file (§ 6a) until a few hundred roots, then
   `roots/` read once by `readdir` — either way, never a filesystem search.
7. **What happens to a root whose path disappears?** Recommendation: `state = missing` in `roots list`, no socket, no
   scan, removed only by an explicit `remove` or `--prune` — never silently forgotten.

## 17. Documentation to write as part of the work

- `FORMAT.daemon.md` — control protocol (JSON lines, versioned), registry record schema, socket naming and base-dir rules,
  exit codes, and the state machine diagram from §5. This is the file a future session reads instead of this plan.
- `README.md` — a "Daemon" section: what it does, the three modes, the sleep/wake trade-off stated in one paragraph.
- `FORMAT.daemon.md` must document the durable home list alongside the runtime layout: which file is configuration,
  which is host state, and the startup sequence that reads the former to rebuild the latter.
- `AGENTS.md` — one line under the invariants: **the registry, socket paths and pids are host state, never trio content**;
  the trio still contains no absolute path.
- `doc/performance.md` or a note in `plans/next-steps.md` — the wake-scan cost, once measured, so the idle default has
  evidence rather than taste.
