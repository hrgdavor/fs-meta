# The daemon — one process, many roots

> **Security rule: run the daemon as a non-root, unprivileged user. Never as root or an elevated Administrator.**
> It watches trees, writes `.fs-meta` and serves a local socket, including an executable dialect; an exploit would
> otherwise run with **elevated permissions**. The startup refusal, POSIX owner-only sockets/peer checks, `--allow-exec`
> gate, startup hardening and no-follow `.fs-meta` writes are implemented; the remaining gaps are in
> [`plans/non-root-daemon.md`](../plans/non-root-daemon.md), and deployment is covered by
> [`service-deployment.md`](service-deployment.md).

**Only the Zig engine implements this daemon.** The Java and Bun/Node ports are **clients**: they read the trio and
speak the socket protocol, and they must not implement a watcher, scheduler, scan-on-change loop, socket server,
control plane or a second daemon. `js/daemon.mjs` is a client for this daemon, not a daemon.

`fsmeta serve <root>` owns one tree for its lifetime; its optional `--http` flag also serves a browser UI (socutil)
over the same unix socket the binary protocol uses ([`FORMAT.socket.md`](../FORMAT.socket.md)). Bare `--http` binds
port 8765, `--http=<port>` the port you name, and `--http=0` asks the operating system for any free port; the bound
port is then announced on stdout as `socutil listening on http://127.0.0.1:<port>/`. The flag belongs to `serve` alone:
any other command given it fails with `fsmeta: --http is only valid for the serve command`. `fsmeta daemon` is the
other shape: **one long-lived process that tracks several roots**, each with its own socket at
`<runtime>/roots/<id>.sock`, speaking the same binary protocol. A consumer connects, `SUBSCRIBE`s, and receives
batches as the tree changes — the same batches the engine writes. A build pipeline can also stage its subscribers:
`SUBSCRIBE_V2` declares a stage and a builder role, `BUILD_STARTED`/`BUILD_DONE` are the builder's
acknowledgement, and `STAGE_READY` releases the next stage once every builder of the previous one is done
([`FORMAT.socket.md`](../FORMAT.socket.md) § BUILD_STAGES). `FORMAT.daemon.md` is the reference; this is the
working view.

```sh
zig-out/bin/fsmeta.exe daemon start                      # background; --foreground for tests
zig-out/bin/fsmeta.exe root add ~/projects/app --idle 5m  # serve a root, in auto mode
zig-out/bin/fsmeta.exe roots list                         # what is served, and in which state
zig-out/bin/fsmeta.exe root status a1b2c3d4 --json        # one root, in detail
zig-out/bin/fsmeta.exe daemon stop
```

**Three modes, and one trade-off.** `off` never watches: the socket still answers a subscribe with one scan, but
nothing is observed. `always` watches whether or not anybody is listening. `auto` — the default — watches only
while at least one client is subscribed, and goes **asleep** after `idle_timeout_ms` (five minutes by default) with
no clients: no watcher thread, no open tree handles, only the last published generation kept.

Watching is event-driven: a watching root holds a `nightwatch` watch on its tree, and a burst of events becomes one
engine pass (the quiet period is tuned by how long this machine's passes take). Nothing changing means nothing
running, and each root schedules itself — one root's scan (or a client that stopped reading) never delays another
root's batches.

**Each root has its own tick.** A root's scheduler wakes every `tick_ms` to check its idle deadline, its event burst
and its git/hook timers: **default 50 ms**, valid **5–1000 ms**, recorded per root in `roots.json` and set with
`root add <path> --tick <ms>` or `root set <id> tick <ms>`. The default is less conservative than the 100 ms the
daemon used to hard-code, because on a fast SSD and a small tree a pass is a few milliseconds and the wait for the
next tick was often the largest part of a save's latency. The burst scheduler's own 25 ms quiet floor still applies,
so a tick below 25 ms checks more often without publishing sooner; a larger tick trades batch latency for fewer
wakeups. `root status --json` (and `roots list --json`) reports the effective `tick_ms`, and `root status` prints it
on the `idle …, tick … ms, head batch …` line, so the setting in force never has to be guessed from the file.

**The tick should be chosen per editor/SSD rather than globally.** 50 ms is the new default; 10–25 ms is reasonable
for a fast local editor, while 50–100 ms is safer for many roots or slower storage.

Sleeping is the whole point, and waking is what it costs. A returning client triggers **one full scan**, compared
with the last published generation, published as normal batches — so the client sees the diff of everything that
happened while the root slept, and the daemon is then watching again. A root nobody uses therefore costs nothing
(a socket and a record), and a root that becomes busy again pays one scan once. `idle 0` disables sleeping for a
root that must never pay it.

The durable list of roots is `roots.json` in the user's config directory (`%APPDATA%\fsmeta\roots.json` on
Windows), written atomically by the daemon; sockets, pids and logs live in the runtime directory
(`%LOCALAPPDATA%\fsmeta\run`) and are rebuilt from it on every start. The daemon never searches the file system for
roots: it reads the list and `stat`s each entry once.

Housekeeping commands wait briefly per root and then tell the truth: `roots list` answers even while one root is
busy (`not available yet` in the text, `"available": false` and `"partial": true` in `--json`), and a single-root
command that cannot read its root refuses with exit code `4` instead of inventing an answer. The rule, its budgets
and their reasons are in `FORMAT.daemon.md` § 4b.

**Nested roots are allowed and guarded.** Serving a directory inside another served root (a package inside a monorepo)
works — each root has its own socket, archive and state, and a consumer of the inner root gets names relative to it,
which nothing else can give it. The parent no longer scans the overlap: `root add` writes the child's relative path
into the parent's `.fs-meta/ignore` under a `# fsmeta-managed` block, passes the parent once (even when it is asleep or
`off`), and only then serves the child. The reverse direction is the same rule — a parent added after its children hides
each of them before its first pass — and if the write cannot be arranged the add is refused with exit code `4`, never
warned through. The block is repaired by the parent's next pass, and the guard is not one of the `worktrees`/`gitwatch`
switches. `plans/worktrees.md` § 5 is the rule; `FORMAT.daemon.md` § 4 has the lifecycle. `root add --nested` is only
an acknowledgement: the parent's managed line is still written, and the reply says the intent was recorded.

**The scan rule is not one of the switches.** A directory whose `.git` entry confirms is another repository — a clone,
a submodule checkout or a **linked worktree** — and it is a **boundary**: the walk neither lists nor enters it, so a
worktree is never scanned twice and never appears in two trios. That is what a trio *is* (`FORMAT.md` § 16 records it
as `scan.nestedRepos`), so it holds with **every flag off**. The only worktree-specific thing to turn off is the
handling:

| switch      | default | what it controls                                                                                  | off means |
| ----------- | ------- | ------------------------------------------------------------------------------------------------- | --------- |
| `worktrees` | on      | recognising a worktree of a served repository, adopting it (`--on-worktree serve`), seeding it from the base trio, the `worktree` event, the removal reaction | a boundary is still a boundary and is still not scanned, but nothing is adopted, seeded, announced or reacted to; an explicit `root add` of it serves it as an ordinary root |
| `gitwatch`  | on      | the git metadata watch, the per-root lock latch, `GIT_EVENT`, hooks, the `root status` git fields | no `.git` is read or watched, no git events, no hook spool read; the working-tree watcher is exactly what it always was |

Per root: `root add <path> --worktrees off --gitwatch off` records the values (copied from the daemon's defaults at add
time), `root set <id> worktrees off` and `root set <id> gitwatch off` flip them live, and `daemon status` prints the
effective pair. Flipping one never changes the trio: git metadata is not scan input, so the bytes before and after are
the same — the reason the switch is safe to reach for. **For a daemon that misbehaves with the feature on, start it with
`FSMETA_WORKTREES=0`** (disables both, and needs neither a working control socket nor a config edit); `FSMETA_GITWATCH=0`
is the finer knob. The override wins over every record, logs one line at start, and `daemon status` reports both values
plus `note: FSMETA_WORKTREES=off is active`. Neither variable touches the scan rule.

**Worktrees, when the handling is on.** A linked worktree added as a root is seeded from a served base of the same
repository (a generation-1 trio plus a genesis batch, then one diff — `last_pass_hashed` shows how small), so adoption
costs a diff rather than a cold hash of the whole checkout. `root add --worktree` asserts that the path really is a
linked worktree (`.git` is a gitfile naming an existing directory) and forces the worktree handling on for that add;
it refuses a plain directory or a nested clone. A worktree that appears while a root watches is *reported* by default
and adopted only with `--on-worktree serve` on the discovering root, because a watcher per agent worktree is the
balloon this avoids. `roots list` shows which root is a worktree and groups roots that share a git common dir, and a
worktree whose metadata disappears is reported `missing` with its batch history intact.

**Removing a served worktree.** `git worktree remove` refuses a worktree containing untracked files, and
`<worktree>/.fs-meta` is untracked. Stop serving it first with `fsmeta root remove <id>` (the recommended order), or
pass `--force`, or run `fsmeta exclude <root>` once: it appends a marked, idempotent block (`# fsmeta: our own
directory` + `.fs-meta/`, LF, atomic write) to `<common>/info/exclude`. That is git's own file, so the command is never
automatic; a **later** `!` line in that file overrides the block, as git's last-match-wins rule says.

### A client in JavaScript

`js/daemon.mjs` is the consumer side of this document. `namesForRoot(directory)` resolves the served root from
`roots.json`, reads its trio as a baseline at generation `g`, subscribes from `g`, and applies only the batches after
it — so the answer survives batch retention and an `auto` root that was asleep (the wake scan is the next batch). It
returns `null` rather than a partial list when no daemon answers or the window cannot be reconstructed. The module
imports only Node builtins and `@hrg/gitignore`, so it runs under Node; the trio baseline additionally needs
`@hrg/wyhash` (or Bun's native hash), and is skipped when that reader cannot load.
