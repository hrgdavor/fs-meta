# fs-meta daemon — implementation plan

**Status:** implemented through M4. The only unfinished item, M5 (the per-root child daemon), lives in
[`tbd-per-root-daemon.md`](../tbd-per-root-daemon.md); § 18 is the status table — what exists, what was built
differently, and what is open. The design as built is [`FORMAT.daemon.md`](../../FORMAT.daemon.md).
**Language:** Zig only. Tooling and tests around it stay Bun, per the house rules.
**Purpose:** one long-lived process that tracks a set of active roots, keeps a Unix socket per root for consumers, and
decides when each root is worth watching.

---

## 1. What it is, in one paragraph

`fsmeta daemon` runs in the background. Each **root** it tracks gets its own Unix socket that speaks the existing binary
protocol from [`FORMAT.socket.md`](../../FORMAT.socket.md) — a consumer connects, `SUBSCRIBE`s, and receives batches as the
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

## 7. Consumer socket: one new frame, and the protocol moves to 0x0101

Consumers keep using [`FORMAT.socket.md`](../../FORMAT.socket.md): `HELLO`, `SUBSCRIBE`, `START_BATCH`/`CHANGE_ENTRY`/`END_BATCH`,
`PING`/`PONG`, and the two refusals. **The daemon adds no semantics to those frames.** The sleep feature adds exactly one,
because it creates a question the wire could not ask before: *is this subscribe slow because the root is waking?*

**There are no deployed clients**, so the protocol is bumped once — `protocol = 0x0101` — and every implementation is updated
together. No capability bit, no dual-version branch, no "old client sees the same bytes" test: compatibility machinery for a
client population of zero is complexity that would outlive its reason.

| kind   | name    | payload                                                                                          | why |
| ------ | ------- | ------------------------------------------------------------------------------------------------ | --- |
| `0x09` | `STATE` | `u8 state`, `u8 reason`, `u32 idle_timeout_ms`, `u64 head_batch`                                 | the client learns a wake is running, who caused it, when the root will sleep, and how far behind it will be |

`state`: `0` = off, `1` = asleep, `2` = waking, `3` = watching.
`reason`: `0` = none, `1` = a client subscribed, `2` = idle timeout, `3` = control request, `4` = watcher event.
`idle_timeout_ms`: the root's current setting, so a client can tell when it will next stop receiving events (`0` = never
sleeps). `head_batch`: the newest batch the server considers published — a client comparing it with its own last applied batch
knows whether a wake means "one small diff" or "a long catch-up", without the server estimating anything.

**That is the whole frame.** No progress counters, no percentages, no files-scanned: on the measured workloads thousands of
files are milliseconds (`doc/measurement.md`), so progress would flicker and then be gone, and it would turn a state
notification into a telemetry channel that has to be kept honest. Generation numbers are enough to set expectations.

**When it is sent**, always between batches and never inside one (`START_BATCH` … `END_BATCH` is a transaction):

1. immediately after `HELLO`, so a fresh client knows what it joined;
2. `state = waking` **before** the wake scan's first `START_BATCH` — the case the frame exists for;
3. on every transition (`waking → watching`, `watching → asleep`, mode changes made through the control socket);
4. a final `STATE` before the connection is closed on shutdown, so a client stops waiting rather than timing out.

**Why not just let latency speak:** a consumer cannot distinguish "waking, 400 k files" from "big tree, first batch is slow"
from "server stuck". The frame costs 14 bytes and answers exactly that, once.

**What stays out of it:** the CLI's richer view (files scanned, elapsed, bytes) comes from `root status --json` over the
control socket. The consumer frame carries state and generation, nothing the server would have to measure under a deadline.

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
fsmeta root add <path> [--mode off|always|auto] [--idle 5m] [--keep-batches 32] [--max-bytes 64M]
                     [--on-remove keep|delete]
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
  "idle_timeout_ms": 300000,
  "retention": { "max_batches": 32, "max_bytes": 67108864 },
  "on_remove": "keep",
  "socket": "/run/user/1000/fsmeta/roots/a1b2c3d4.sock",
  "served_by": "inproc",
  "created_at": "2026-10-26T06:50:00Z"
}
```

Defaults: `mode = auto`, `idle_timeout_ms = 300000` (five minutes — long enough that a working session never wakes, short enough
that an abandoned root stops costing a watcher), `retention = { max_batches: 32, max_bytes: 64 MiB }`, `on_remove = keep`.
Every one of those is a global default in the daemon's own config, overridable per root. The daemon reads
the files on start; a malformed record is reported and skipped, not fatal to the other roots.

### 9a. Retention and removal are per-root policy

A root's batches are bounded by **two** limits, not one, because either alone is a poor ceiling:

| limit                   | what it prevents                                            | default |
| ----------------------- | ----------------------------------------------------------- | ------- |
| `retention.max_batches` | unbounded generation count (the format's own default is 32) | 32      |
| `retention.max_bytes`   | 32 generations of a huge tree filling the disk              | 64 MiB  |

After every publish the daemon rotates oldest-first until **both** hold — the same order the format already requires (rename to
`.trash-<id>`, then delete), so a reader never sees a half-removed generation. A batch that alone exceeds `max_bytes` is
kept anyway: refusing to write it would break the commit that just happened, and one oversized generation is better than a
missing one. The CLI reports both current values and what rotation removed, so the trade-off is visible rather than silent.

**Removal is its own choice**, because "stop serving" and "delete my history" are different intents:

- `on_remove = keep` (default) — the socket, record and log go; the batches stay, so a later `root add` resumes from history.
- `on_remove = delete` — the daemon also removes the generations, honouring the same two limits as a final rotation.

Global defaults live in the daemon's config (`{ "defaults": { "idle_timeout_ms": …, "mode": …, "retention": {…}, "on_remove": … } }`)
and are copied into a root's record when it is added, so changing a global default never silently changes an existing root.

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
| **M2** | the state machine wired: `off`/`always`/`auto`, idle timeout, sleep, wake with scan+diff; the `STATE` frame in `FORMAT.socket.md`, `protocol` pinned to `0x0101` in all three implementations | the sleep/wake integration tests; a client sees `STATE(waking, reason=client, head_batch)` before the wake batch, `watching` after it, and `asleep` when the idle timeout fires; `wake` refused on `off` |
| **M3** | multi-root: N sockets, N watchers, add/remove at runtime, reaping; retention enforcement by count **and** bytes with per-root overrides of the global defaults | two roots, isolated batches; remove leaves no socket; a small `max_bytes` rotates early and the reported numbers match; `on_remove=delete` removes generations, `keep` leaves them |
| **M4** | diagnostics: `root status --json`, scan counters, per-root log, `FORMAT.daemon.md` documenting control protocol, registry schema, naming, exit codes | docs reviewed; CLI JSON asserted in tests |
| **M5** | the split seam exercised: a `child` `RootHost` behind a flag, one root served by a child, the main daemon aggregating | same consumer socket path; `roots list` shows `served_by`; killing the child is reported, not fatal |

**Before M5: brainstorm nested roots in § 16a.** It is the one area the plan allows but does not settle, and the discussion needs
M4's diagnostics to be worth having.

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

## 16. Decisions taken before implementation

Answered on 2026-10-26; a new session implements these rather than re-opening them.

| #   | question                    | decision                                                                            |
| --- | --------------------------- | ----------------------------------------------------------------------------------- |
| 1   | `STATE` frame?              | **Yes** — `0x09`, `protocol = 0x0101`, no capability gating (no deployed clients), state + reason + idle timeout + head batch, no progress counters (§ 7) |
| 2   | default idle timeout        | **5 minutes** (`300000`), per-root overridable; `0` = never sleep                   |
| 3   | does `off` bind a socket?   | **Yes** — `off` means never *watch*, not never *serve*; the socket answers from a scan and reports `state=off` |
| 4   | `root remove` and batches   | **Per-root policy** (`on_remove`): `keep` by default, `delete` on request; retention is bounded by **both** `max_batches` and `max_bytes`, per root, defaulted globally (§ 9a) |
| 5   | durable root list           | **One `roots.json`** in the user home, written atomically (§ 6a)                    |
| 6   | vanished root               | **`state = missing`**, reported, removed only by explicit `remove`/`--prune`        |
| 7   | Windows detaching           | **Spawn itself detached** (`DETACHED_PROCESS`, no console) with a pid file; `--foreground` for tests |
| 8   | unknown root on `SUBSCRIBE` | **Refuse** with `ERROR` naming `fsmeta root add`; no implicit registration          |
| 9   | two writers for one root    | **The daemon owns it**; a CLI publish refuses with a message pointing at the daemon |
| 10  | wake diff of 80 000 entries | **Normal batching** — a chain of hex-numbered batches, no special case              |

**Two things this plan still leaves to the implementer, deliberately:**

- **Nested roots** are **allowed for now** (a monorepo and one of its packages are a legitimate pair, and the cost of two
  watchers is the user's to pay) and **deferred as a topic**: they are brainstormed at the end of the milestone work, in § 16a,
  before the split and before anyone treats the current behaviour as a contract.
- **Root-level config vs daemon config** is settled by § 9a: a global `defaults` block plus per-root records, and adding a root
  copies the current defaults, so a later change to a default never silently mutates an existing root.

### 16a. Nested roots — settled in § 16b

Allowed and settled. This section is kept as the record of what the decision had to answer — it is the checklist a
future "should these two roots be one?" question starts from — and § 16b has the measurements, the choice and the code.

**Why it is not obvious.** Two roots, one inside the other, mean two watchers over overlapping trees. Everything that is
cheap and correct for one root becomes a question for two:

| question                    | today's behaviour                                                      | what needs deciding                                                               |
| --------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| duplicate events            | the parent's watcher and the child's both fire for a file in the child | share a watcher and fan out, or accept duplicates and document it?                |
| wake cost                   | each root scans its own tree, so the child's files are scanned twice   | skip a parent's subtree that is itself a root, or scan everything for simplicity? |
| retention                   | two independent generation histories over overlapping content          | leave them independent (current), or let a child inherit/alias the parent's?      |
| ignoring                    | the parent's `.gitignore` chain and the child's differ legitimately    | a child is its own chain — confirm rather than assume                             |
| socket identity             | two sockets, two ids, both derived from their own paths                | does a consumer that knows both need a way to say "same tree"?                    |
| per-root daemon split (§ 4) | two roots could be served by two children                              | is a nested pair a good first candidate for the split, or the worst?              |

**What to bring to the brainstorm**, so it is not a matter of taste:

1. the measured wake-scan cost of a root and of a nested pair (M4 exposes files/bytes/ms per root);
2. whether duplicate events actually arrive in practice — a small experiment with a parent and child watcher on one tree,
   counting duplicates per edit — before designing dedup;
3. the retention numbers from § 9a: what a nested pair costs on disk versus a single root;
4. one real example of the user's own usage (a monorepo plus a package is the motivating case).

**Options to weigh, not to pick now:**

- **A. Keep it simple:** allow nesting, document duplicate events, no dedup, no scan skipping. Everything works; some work is
  duplicated.
- **B. Detect and warn at add time:** `root add` notices the path is inside an existing root (or contains one) and prints what
  the cost will be, then proceeds. Cheap, no semantics change, and it teaches the user the trade-off.
- **C. Share a watcher:** one watcher on the outermost root, events filtered per root by path prefix. Efficient, but couples the
  roots' lifetimes — the parent cannot sleep while the child is watching, which contradicts the per-root idle model.
- **D. Prune child subtrees from the parent's scan:** less duplicate scanning, but the parent's generation then no longer
  describes its whole tree, which breaks the trio's meaning.

My expectation, to be tested rather than assumed: **B now, A as the semantics**, with C only if duplicate events prove
expensive — and D rejected, because a generation that skips part of its tree is not a state description.

**Output of the brainstorm:** a short decision note appended here (chosen option, the measurements behind it, and what the code
already guarantees), and — if B is chosen — one paragraph in `README.md` under the daemon section. Then M5.

### 16b. Decision: allowed, with the cost stated at add time (2026-10-26)

> **Superseded (2026-10-27)** by [`../worktrees.md`](../worktrees.md) § 5–§ 6: the rule is now that a nested root is
> *guarded* — a nested **repository** is excluded by the scan rule (a trio describes the tree minus nested
> repositories), and a nested root that is **not** a repository is excluded by the parent's internal ignore
> (`.fs-meta/ignore`), with `root add` refusing when that cannot be arranged — not merely warned about. A generation
> then has a defined edge, which answers the objection that option D left a hole; the duplicate cost measured below
> disappears by construction. The warning this section decided is removed in that plan's M2.


Measured on this host (§ 16a of this plan asked for exactly this), with a parent root over a tree of **601 files** and a
child root at `packages/a` (**300** of them), both `--mode always --idle 0`, daemon in a scratch runtime:

| what                                                    | parent              | child               | reading                                                          |
| ------------------------------------------------------- | ------------------: | ------------------: | ---------------------------------------------------------------- |
| genesis pass (names / ms / batch)                       | 604 / 49 / 51 266 B | 300 / 28 / 22 467 B | both scan their own tree                                         |
| ten edits inside the child                              | **10 passes**       | **10 passes**       | duplicate events are real: **10/10**, no coalescing across roots |
| wake scan (100 changed inside the child, 100 elsewhere) | 604 names / 32 ms   | 300 names / 18 ms   | the parent alone covers every change at 32 ms; the pair scans **904 names / 50 ms** for the same 200 files |
| 12 generations of batch history                         | 75 061 B            | 36 640 B            | the child's overlapping history is **+48.8%** — the same 300 files stored twice, as `packages/a/…` and as `f…` |

**Decision: A as the semantics, with B implemented.** Nesting is allowed; there is no dedup and no scan skipping; and
`root add` now says what the overlap costs, naming the root it overlaps, in both directions (a new root inside a served one,
and a new root that contains one). It is a `note:` on a successful add, and the control reply carries it as `warning` so a
script does not parse prose. The test is `a nested root is allowed, and adding one says what the overlap costs`.

**Why not the others, with the numbers:**

- **C (share a watcher, fan out by prefix)** would remove the duplicated pass and the second scan, which are ~18 ms and one
  extra pass here — but it couples the roots' lifetimes: the parent could not sleep while the child watches, which is the
  invariant § 2/§ 5 rest the whole idle model on. Buying 18 ms with that is a bad trade at this size.
- **D (prune a child subtree from the parent's scan)** is still rejected: the parent's generation would stop describing its
  whole tree, which is what a generation *is* (`FORMAT.md` § 17). A state description with a hole in it is worse than a
  duplicate pass.

**What the code already guarantees, so a nested pair is a cost and not a hazard:** independent ids (`hex8(wyhash(path))`),
independent sockets, independent archives, independent state machines and idle deadlines; a removed parent does not touch a
child's history (`on_remove` is per root); and the *consumer* never sees a merged stream — a client of the child gets the
child's names. That last point is the legitimate reason to nest at all: a consumer that wants `one.txt` rather than
`packages/a/one.txt`, and a smaller stream, cannot have it any other way.

## 17. Documentation to write as part of the work

- `FORMAT.socket.md` — the `STATE` frame (§ 7): kind `0x09`, the payload fields and their meaning, when it is sent, and the
  `protocol = 0x0101` pin. This is a consumer-facing change and belongs in the consumer-facing document, not in the daemon
  one.
- `FORMAT.daemon.md` — control protocol (JSON lines, versioned), registry record schema, socket naming and base-dir rules,
  exit codes, and the state machine diagram from §5. This is the file a future session reads instead of this plan.
- `README.md` — a "Daemon" section: what it does, the three modes, the sleep/wake trade-off stated in one paragraph.
- `FORMAT.daemon.md` must document the durable home list alongside the runtime layout: which file is configuration,
  which is host state, and the startup sequence that reads the former to rebuild the latter.
- `AGENTS.md` — one line under the invariants: **the registry, socket paths and pids are host state, never trio content**;
  the trio still contains no absolute path.
- `doc/performance.md` or a note in `plans/next-steps.md` — the wake-scan cost, once measured, so the idle default has
  evidence rather than taste.

## 18. Status after implementation

What exists is documented in [`FORMAT.daemon.md`](../../FORMAT.daemon.md) and pinned by `zig build test` and
`test/daemon.test.mjs`. This table exists so the next session does not re-read the plan to work out what happened.

| milestone                                                                                        | state                                                                                        |
| ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| **M0** paths, registry, state machine, durable home list, control socket, `daemon start/stop/status`, `roots list` | done (§ 1, § 3, § 4b of `FORMAT.daemon.md`)                                |
| **M1** one root served: `RootRuntime` owns a socket, `HELLO`/`SUBSCRIBE`, cold scan, first batch | done, with one deviation: `server.zig` was **not** refactored into a `RootServer`. It owns no global state to begin with, so only its frame helpers became public and `RootRuntime` is the per-root value. The M1 gate "parity with `fsmeta serve` on the same tree" is now `test/daemon-parity.test.mjs`: one archive, both servers, same generation, batch numbers, entries and counts. |
| **M2** state machine, idle timeout, sleep, wake with scan+diff, `STATE` frame, protocol `0x0101` | done, and the protocol pin is in `FORMAT.socket.md`                                          |
| **M3** multi-root, add/remove at runtime, reaping, retention by count **and** bytes              | done                                                                                         |
| **M4** diagnostics, `root status --json`, per-root log, `FORMAT.daemon.md`                       | done: `passes`, `wakes`, `head_batch`, `rotated_by_bytes`, and the per-pass cost `last_pass_duration_ms` / `last_pass_files` / `last_pass_batch_bytes` (`FORMAT.daemon.md` § 4, printed by `root status`). The measurement they exist for is in `doc/benchmark.md` § The wake scan: 20 101 names, cold scan 840–1 050 ms, wake scan 72–76 ms for 500 changed files |
| **M5** the split seam exercised with a `child` `RootHost`                                        | **moved out** to [`tbd-per-root-daemon.md`](../tbd-per-root-daemon.md) — nothing is needed for the daemon to work, and the latency argument that motivated it was removed by the per-root scheduler (see that file for the trigger, the open decisions and the definition of done). The `RootHost` vtable in § 4 above is a sketch, not code: nothing calls it |
| **§ 16a** nested roots brainstorm                                                                | **settled** — § 16b: allowed, with a measured-cost warning at add time (option A as the semantics, B implemented, C and D rejected with numbers). The code is `paths.isInside`, `Host.nestingWarningLocked`, the `warning` field of `root.add` and a `note:` line in the CLI |

**Two design changes made while implementing, both recorded in `FORMAT.daemon.md`:**

- **The watcher is `nightwatch`** (§ 3, § 12 of this plan), linked into the engine: `zig build` now has that dependency
  because the daemon is part of `fsmeta`. The § 12 "single event loop, no thread per root" was replaced by **one
  scheduler task per root** — a batch belongs to one root, and its latency must not depend on another root's scan or on
  a client that stopped reading. `FORMAT.daemon.md` § 2c and the suite pin it.
- **Housekeeping APIs over many roots follow a bounded-wait rule** (`FORMAT.daemon.md` § 4b): a per-operation budget, a
  truthful `available: false` / `partial: true` instead of blocking, and unbounded waits only for lifecycle work. The
  plan asked for the first half of that (§ 4b's `RootSnapshot`) without settling the waiting behaviour.

**A cross-cutting bug the measurement found, and fixed:** at 20 101 names the genesis batch's `files.meta` is
1 286 464 bytes, and `server.loadBatch` read every batch file through `wire.max_frame` (1 MiB) — so the first batch of
a large tree could not be read back at all: the root published its generation, the subscriber got
`STATE(waking)` → `STATE(watching)` with no batch, and only `last_error: "StreamTooLong"` said why. `fsmeta serve` had
the same limit. A batch is a *chain* of small frames on the wire, so the frame limit was never the file limit:
`server.max_batch_file_bytes` (256 MiB) is now separate, with a test that loads a 16 500-name batch (over the old
limit). See `doc/benchmark.md` § The wake scan for the numbers that exposed it.

**Two cleanups the work left behind, both now done:** `coldstart` freed cache keys it did not own — a cache loaded
from a trio borrowed them from `files.txt`, so `Allocator.free`'s debug poisoning landed in the trio's own bytes
(the § H defect, now fixed at the source: `Cache.load` and `coldstart` both own their keys, `deinit` frees them, and
`owns_keys` says which kind of cache it is). And a watcher that dies without telling us (a buffer overflow is a
failed `ReadDirectoryChangesW` completion, which ends nightwatch's thread) is now caught by a **safety pass** after
60 s of silence, which re-arms the watcher when it finds a change the watcher missed; `event_passes` and
`safety_passes` in `root status` say whether it ever earned its keep. Both are in `FORMAT.daemon.md` § 2b/§ 4.

**Still open:** nothing in this plan. The per-root child daemon (M5) lives in
[`tbd-per-root-daemon.md`](../tbd-per-root-daemon.md).

