# Build artifacts and staged builds

**Status:** B1–B11 are implemented (protocol `0x0104`, the barrier, `.fs-meta/build.json`, the `stage` ignore source,
the stage state/trio/batches under `.fs-meta/stages/<NN>/`, streaming stage-batch frames while the walk runs, the
one-shot `fsmeta stage status|scan|diff` CLI, `SUBSCRIBE_V3`/`from_stage_batch` replay, the scp-like publisher
example, `root status` stage counters and a builder timeout, tests and the reference documents).

## 1. The situation

A development project has two kinds of files:

- **sources** — what a person edits, what the main thread of a dev tool watches and indexes;
- **build artifacts** — what a compiler, generator, linker or packager writes. They are usually in
  `.gitignore`, so `fs-meta`'s walk never lists them and their writes never publish a batch.

The main thread must **not** wake for artifact writes: a build that regenerates `build/classes/...` would
otherwise look like a source change and start another build. That is why artifacts are ignored in the first
place, and it is correct.

The problem is the other side of the same boundary. Builds are often **staged**:

```
sources ──stage 0──► generated sources / classes ──stage 1──► resources / bundles ──stage 2──► dist
```

Stage 1 cannot start merely because a source changed — it needs stage 0 to have finished. Today a consumer has
only one signal, the batch, and a batch says nothing about whether another client's build is done. If stage 1
subscribes to the same stream it runs too early; if it does not subscribe it never learns that stage 0 finished,
because stage 0's output is ignored by the walk.

`fs-meta` already owns the change stream and the daemon already has every client connected. The missing piece is
a **stage barrier**: a way for a builder to say "I started" / "I am done", and for the daemon to release the next
stage only when every builder of the previous stage is done.

## 2. Definitions

- **Stage** — a non-negative integer. `0` is the ordinary source stream; a watcher that does not declare a stage
  is stage 0 and behaves exactly as it does today.
- **Listener** — a subscriber that only receives changes (`SUBSCRIBE`).
- **Builder** — a subscriber that declared `builder` in its subscription. A builder is expected to answer every
  batch released to its stage with either `BUILD_STARTED` while it works and `BUILD_DONE` when it finishes, or
  `BUILD_DONE` immediately when it decides the batch needs no build.
- **Round** — one traversal of the stage chain. Stage 0 receives a batch; its builders work; when all of them are
  done, stage 1 receives everything it had not seen, plus a `STAGE_READY`; its builders work; and so on.
- **Artifact** — a path produced by a stage. In the barrier phase an artifact is **not** a root-trio entry: it is
  ignored by the walk (usually through `.gitignore`), and the stage barrier is the signal that it may have changed.
  In the folder phase (§ 7) a stage declares its output folders and gets a **stage state** that lists and hashes
  those artifacts, so the next stage can recheck only what changed.
- **Stage folder** — a workspace-relative output folder declared for one stage in `.fs-meta/build.json`. It is
  excluded from the root walk and scanned only by that stage's state.
- **Stage state** — the stage-local trio/cache and batch archive under `<root>/.fs-meta/stages/<NN>/`. It has the
  same 64-byte entries, hashes, ordering and batch semantics as the root, but its own generation and its own folder
  scope. It is regenerable: deleting it forces a cold stage scan, never a wrong one.

## 3. Why a barrier in the daemon, not in each client

Three clients cannot coordinate a barrier without one of them becoming a coordinator, and the coordinator would
need to know every other client's state. The daemon is the only process that:

- sees every subscriber and its declared stage;
- knows which batches each subscriber has actually received (`from_batch`);
- already serialises writes to every socket under the root lock;
- can count a disconnected builder as finished, instead of hanging the pipeline forever.

It is therefore the natural place for the barrier. The engine is unchanged: the daemon still publishes the
engine's batches, and the stage machinery only decides **when** a batch is written to a socket.

## 4. The protocol change

Protocol `0x0104`. The existing `SUBSCRIBE` (kind `0x06`) is unchanged: it means stage 0, listener. A client that
wants a stage or a builder role sends `SUBSCRIBE_V2` (kind `0x0B`). The old form stays the default, so no
existing client changes behaviour. Stage artifact batches use the separate `0x0F`–`0x11` frame set (§ 7.6); they
are never mixed into a root `START_BATCH … END_BATCH`.

### 4.1 `SUBSCRIBE_V2` (client → server, `0x0B`)

```text
u64  from_batch
u16  stage             0 = ordinary source stream
u16  flags             bit 0 = builder; bits 1..15 reserved and refused when set
u16  include_count     then include_count × (u16 length + pattern bytes)
u16  exclude_count     then exclude_count × (u16 length + pattern bytes)
```

The filter layout and semantics are the existing ones (`FORMAT.socket.md` § SUBSCRIBE filter patterns). The
`stage` and `flags` header is the only addition. Decoding is exact: a payload shorter than the 12-byte header,
a set reserved bit, a stage above 64 (the pump walks stages in order), or a filter section that does not end
exactly at the payload's end is `ERROR{protocol}`.

### 4.2 `BUILD_STARTED` (client → server, `0x0C`)

```text
u64  generation        the newest batch this builder is working from
```

The builder says it has begun work for `generation`. The frame is informational for diagnostics and for a future
timeout; it does **not** advance the barrier. A builder that starts and never finishes still blocks its successor,
which is why a disconnect and a `BUILD_DONE` with `status = failed` both release it.

### 4.3 `BUILD_DONE` (client → server, `0x0D`)

```text
u64  generation        the newest batch this builder has fully handled
u8   status            0 = ok, 1 = failed, 2 = cancelled
```

This is the acknowledgement that advances the barrier. A builder may batch several generations into one done
(the highest number wins). A generation above the builder's own stage release is refused: a builder cannot
acknowledge work its stage has not been given. A failed or cancelled build still advances: a permanently broken
stage must not stop every later stage forever; the status is recorded in the daemon's log and `root status`.

### 4.4 `STAGE_READY` (server → client, `0x0E`)

```text
u16  stage             the stage that may now work
u64  head_batch        the newest batch the root has published
u64  released_through  the newest batch now released to this stage
```

Sent to every subscriber of stage `S > 0` when the barrier for `S - 1` opens. It comes **after** the batches that
became available, never inside a root `START_BATCH … END_BATCH` or a stage `STAGE_BATCH_START … STAGE_BATCH_END`. It
exists because a stage may need to run even when the previous stage produced **no tracked change** (the common
case: the artifact is gitignored, so the root batch is empty). The root batch carries what the root tracks; the
stage batch carries what the stage produced; `STAGE_READY` carries the fact that the build round reached this
stage. It is sent once per release advance, with `released_through` as the new ceiling.

### 4.5 What the client sees

- Stage 0, listener: unchanged. `SUBSCRIBE`, replay, live batches; no new frames.
- Stage 0, builder: batches as before, and it sends `BUILD_STARTED` / `BUILD_DONE`.
- Stage `S > 0`: no batch is sent before every builder of stage `S - 1` has acknowledged it. On release it
  receives the held batches in order, then `STAGE_READY`.
- A stage with **no builders** does not block: its successor is released as soon as the predecessor is done. A
  listener never blocks; only a declared builder does.

### 4.6 The barrier rule

For one root, and one subscriber `b`:

```text
acked(stage)    = head_batch                    if no builder subscriber declares that stage
                = min(done_through of every builder subscriber at that stage)
released(stage) = head_batch                    if stage == 0
                = min(head_batch, acked(stage - 1))
```

A subscriber at stage `S` may receive batches up to `released(S)`. The daemon sends the missing batches, in
generation order, whenever `released` moves; after the send it emits `STAGE_READY`. Because `released` is
monotonic, a late subscriber replays only what is already released to its stage and then joins the same barrier.

## 5. Failure, disconnect and restart

- **A builder disconnects while it is the last one unfinished at its stage.** The daemon releases the barrier,
  logs the disconnect, and logs that the stage advanced without an acknowledgement. A client crash is not a
  reason to stop every downstream build.
- **A builder declares a stage and never starts a build.** It is a builder, so it is expected to acknowledge; a
  listener must not declare the builder flag. `root status` and the log name the stage and the generation it is
  holding.
- **A builder sends `BUILD_STARTED` / `BUILD_DONE` for a generation above `head_batch`.** `ERROR{protocol}` and the
  connection ends. A frame below its own `from_batch` is accepted but cannot move `done_through` backwards.
- **Daemon restart.** The barrier is in-memory. A builder reconnects with its `from_batch` and `SUBSCRIBE_V2`; the
  replay path uses `released(stage)`, so it cannot jump over a stage that has not run. A round interrupted by the
  restart is retried from the batches the client has not acknowledged.
- **A stage 0 root with no builder.** Its stage-1 subscribers are released as soon as a batch exists, which is
  the old behaviour plus the explicit `STAGE_READY`; a pipeline that never declared a builder is not silently
  stalled by this feature.

## 6. What the daemon records

Enough to answer "why is stage 2 waiting?" without a second state file:

- each subscriber's `stage`, `builder` flag, `from_batch`, and `done_through`;
- per root: the head, the last released generation per stage, and a counter per stage of released rounds.

`root status --json` gains those numbers in a later step; the log line is the first diagnostic and is written
when a barrier opens or a builder disconnects.

## 7. Artifact folders and stage-local state (next phase)

The barrier is useful without artifact identities, but it is not enough for incremental builds. A stage needs to
know **which files it produced**, so the next stage can recheck only what changed. That requires the stage to
declare its output folders, and it requires a state for those folders that has the same properties as the root
trio: names, content hashes, generations and a batch history.

This is still **not** the root trio. The root trio describes sources; a stage state describes the artifacts of one
stage. They are separate files with separate generations, and the root walk never lists the stage folders.

### 7.1 Why the root trio stays unchanged

1. A build artifact is usually excluded by `.gitignore`; adding it back would make the root trio describe files the
   project has said are not source. It would also change every root generation, every root batch and every
   conformance vector for a feature one tool wants.
2. The root generation is the source revision a pipeline is triggered from. If a stage wrote into the same
   generation, a stage output would look like a source change and the main thread would wake on its own output —
   the loop this feature exists to avoid.
3. A stage state is a **cache**: deleting `.fs-meta/stages/` costs a full stage scan and is never a correctness
   problem. The root trio is the durable description; the stage state is derived from it and from the artifacts.

### 7.2 Declaring the folders

Each stage declares one or more **root-relative output folders**, and optionally its hash mode, in
`<root>/.fs-meta/build.json`:

```json
{
  "version": 1,
  "stages": [
    { "stage": 0, "folders": ["build/classes/", "build/generated/"], "hash": "text" },
    { "stage": 1, "folders": ["build/libs/"] },
    { "stage": 2, "folders": ["dist/"] }
  ]
}
```

Rules:

- `stage` is `0..64` (the protocol's limit), unique in the document.
- `folders` are workspace-relative, `/`-separated and end at a directory boundary; absolute paths, `..`, `.git`
  and `.fs-meta` are refused.
- A folder belongs to **one** stage. Overlapping folders across stages are refused rather than resolved by a
  "most specific wins" rule; an artifact with two producers has an ambiguous invalidation rule.
- `hash` is `text` (default), `lf` or `none`, exactly the root engine's hash modes.
- The file is read on daemon start and re-read per root pass. A change to it also forces one parent pass, because
  the root walk's exclusions changed. It is not a watcher event (`.fs-meta` is never one).

**The declared folders are excluded from the root walk.** A stage output that is not in `.gitignore` must not be
seen by the root scan either, or the main thread would wake on the build. The plan is a new ignore source named
`stage`, evaluated after `.gitignore`, `info/exclude` and `.fs-meta/ignore`; `fsmeta ignored` names `stage` as the
deciding source. This is a vocabulary addition to `scan.ignoreSources` (`stage`), so it goes into `FORMAT.md` and
the conformance discussion rather than being a quiet daemon rule. It deliberately does **not** write the folders
into the user's `.fs-meta/ignore`: declaring a stage must not edit a file a person owns.

### 7.3 The stage state

Each declared stage gets one state directory:

```text
<root>/.fs-meta/stages/<NN>/
  files.meta          the stage's entries, the normal 64-byte layout
  files.txt           workspace-relative names, as the root trio stores them
  files.json          the normal header plus an additive "stage" object
  batches/            the stage's own generation history
```

`<NN>` is the decimal stage number, zero-padded (`00` … `64`). The entries use the same 64-byte format and the
same content hash as the root, so a stage batch can later be streamed with the root's `CHANGE_ENTRY` payload parser
rather than a second one. The **state files** (`files.meta`/`files.txt`) are sorted like the root's; the **wire
batch** is observation-ordered (§ 7.6). Names are **workspace-relative**, not folder-relative, so a name means the
same thing in the root trio and in every stage state.

The additive `stage` object in `files.json` records at least:

```json
"stage": {
  "stage": 0,
  "folders": ["build/classes/", "build/generated/"],
  "hash": "text",
  "configHash": "…"
}
```

`configHash` is a hash of the normalised folder list + hash mode. A stage state whose `configHash` differs from the
current declaration is discarded and rebuilt with a full scan; a folder added to a stage invalidates the stage
state, not the root trio. Unknown keys are preserved, as `FORMAT.md` already requires. The stage state's `root`
identity is written as `0, 0` for now (the writer does not yet take a directory identity without an extra handle);
`configHash` is the invalidation key, and recording `dev`/`ino` is an open detail.

**The stage state is regenerable.** A missing, torn or foreign stage state falls back to a cold stage scan. It
contains no absolute path; it is host-local cache under the directory the walker already skips.

### 7.4 The incremental check after a batch

The per-root barrier says *when*; the stage state says *what*:

1. Stage `N` builders finish and send `BUILD_DONE`.
2. The daemon runs the **same engine pass** over stage `N`'s declared folders, with `.gitignore` off (artifacts
   are usually ignored) and `.git`/`.fs-meta`/other stage folders skipped. The baseline is the stage state's last
   generation.
3. If the pass publishes, the stage batch carries added/changed/deleted entries, content hashes and a new stage
   generation. If nothing changed, no stage batch is written.
4. The stage batch **streams while the scan runs**: `STAGE_BATCH_START`, then `STAGE_CHANGE_ENTRY` as files settle
   (observation order, § 7.6), then `STAGE_BATCH_END` as the commit. Stage `N+1` receives it on release along with
   the root batches it had not seen and a ready that names the stage generation. The consumer can ask "which
   artifacts changed?" without rehashing the folder itself, and a copier can start before `STAGE_BATCH_END`.

The scan is scoped to the declared folders, so its cost is proportional to the stage's outputs, not to the root.
The `BUILD_DONE` path already holds the root lock; the first implementation runs the stage pass there (the same
choice the root pass makes) and the plan allows a later move to a stage task if a measured pass is too long.

A stage with **no builders** still gets a scan when its barrier would open: a script may have written the folder
without a subscribed builder. A stage with no declared folders has no stage state and behaves exactly like the
current ready-only barrier.

### 7.5 Incremental builds, not only watch mode

The same stage state serves a one-shot build. The CLI surface (names illustrative until the command table is
fixed):

```text
fsmeta stage status <root> [--stage N] [--json]
fsmeta stage scan   <root> --stage N [--json]        # scan and publish; prints the changes
fsmeta stage diff   <root> --stage N [--json]        # compare without publishing
```

A build script runs `stage diff` for stage 0, compiles what it reports, runs `stage scan` to record the result,
then does the same for stage 1. No watcher is involved. The daemon uses the same pass, so watch mode and one-shot
mode cannot drift.

The skip rules are the root engine's, applied to the stage state:

- unchanged content hash ⇒ no change, even if `mtime` moved (a touch is `TOUCHED`, not an edit);
- a deleted folder or file ⇒ deletes for the stage batch;
- a new folder or file ⇒ adds;
- a stage state from another `configHash`, or no state at all ⇒ every current name is an add (cold scan);
- a stage state that cannot be validated ⇒ a cold scan; the current writer records root identity as `0, 0`, so the
  `configHash` is what actually distinguishes declarations until the identity check is added.

This is where a stage batch "has its own cache and batches with hashes": it is the root's format and diff
semantics, scoped to one stage's folders.

### 7.6 Stage batches stream in observation order, not hash order

**Root batches stay `(nameHash, name)` ordered.** That is what lets a root consumer insert entries into its state as
they arrive. A stage batch must **not** copy that rule: a stage scan that sorted before sending its first entry
would have to finish the whole scan first, and then "copy files as they show up" would be false. The two batch
types have different jobs and therefore different ordering contracts.

A stage batch is a **streaming batch**:

| frame                      | payload                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------- |
| `STAGE_BATCH_START`        | `u16 stage`, `u64 generation`, `u64 parent`, `u64 started_ns`                               |
| `STAGE_CHANGE_ENTRY`       | the same 64-byte entry + name bytes as `CHANGE_ENTRY`, self-delimiting by `nameLength`      |
| `STAGE_BATCH_END`          | `u16 stage`, `u64 generation`, `u64 added`, `u64 changed`, `u64 deleted`, `u64 changes_hash`, `u8 status` |

**Ordering is observation order.** The scan emits a `STAGE_CHANGE_ENTRY` as soon as a file is settled and its hash is
known, in the order the scan reaches it. It is not sorted by `nameHash`, and it is not the build's write order
either. A consumer that needs a sorted state buffers or sorts, or reads the stage state after `END`; a publisher
that copies per file does not need either. The stage state's `files.meta`/`files.txt` remain sorted in their normal
order — only the wire stream is allowed to be unsorted.

**Adds and changes stream early; deletes can arrive late.** A file's add/change is decidable when the scan reaches
it. A deleted directory's subtree is only known once the scan has seen everything, so queued deletes are emitted
before `STAGE_BATCH_END` (or carried in the end frame when a future version defines that shape). `STAGE_BATCH_END`
is the **commit**: its counts are exact, a mismatch discards the batch, and a consumer must not acknowledge the
stream as complete before it.

**This is what makes copying during the batch real.** `STAGE_BATCH_START` arrives when the stage scan starts, not
after it finishes; the first `STAGE_CHANGE_ENTRY` arrives as soon as one file is settled. A publisher can copy that
file while the scanner is still walking the rest of the folder. `STAGE_BATCH_END` is the boundary for side effects
that need the complete set (subtree deletes, a reload/restart hook).

The stage batch archive stores the plan and can be replayed: `SUBSCRIBE_V3`'s `from_stage_batch` replays archived
stage batches before the live stream, while a `SUBSCRIBE_V2` client has no cursor and starts at the stage head. The
archived form is hash-ordered; the live stream is observation-ordered; both are a set, not a write-order log. The
stage state is the sorted, durable form. `STAGE_READY` remains the barrier signal and may name the stage generation;
it is not the artifact payload.
The root's `(nameHash, name)` rule in § Ordering on the wire is unchanged and still applies only to root batches.

**History (2026-11-08).** The first daemon implementation scanned the whole stage, computed the plan, and only then
wrote `STAGE_BATCH_START` and the entries. That was a real gap: the wire ordering was observation-ordered but the
observation had already finished, so the scp-like publisher got the batch after the scan rather than during it.
The fix moved settling, hashing, classification and emission into `scan.Options.on_fact`, and made
`STAGE_BATCH_START` lazy (it is sent before the first change, not for an empty scan). `on_finish` is emitted after
the stage state is committed; deletes still come after the walk because the surviving set is only knowable then.
This note stays here so a future reader knows why `stage.refresh` has a callback API and why the start frame is
conditional.

### 7.7 Example: an scp-like publisher that copies during the batch

A deploy tool (`fsmeta-publish`) copies stage `N`'s output to a test host and, after the batch, reloads or restarts
the tested application. It is the case the two batch boundaries were designed for: **copy as the entries arrive,
commit side effects only after `STAGE_BATCH_END`.**

The tool subscribes to the **consumer** stage (`N+1` for stage `N`'s output) as a listener — no builder flag, so it
never holds the barrier:

```text
SUBSCRIBE_V2 { from_batch: last, stage: N+1, flags: 0,
               include: ["build/classes/**"], exclude: [] }
```

The stage batch starts when the stage scan starts and streams entries as files settle. The tool handles it like
this:

| frame                 | what the publisher does                                                                             |
| --------------------- | --------------------------------------------------------------------------------------------------- |
| `STAGE_BATCH_START`   | remember `stage`/`generation`/`parent`; start a per-batch copy set; do **not** wait for the batch to finish |
| `STAGE_CHANGE_ENTRY`  | for an add/change, start copying that file immediately in a worker: verify the entry's hash, write a temporary target, then rename it; for a delete, queue it |
| `STAGE_BATCH_END`     | wait for in-flight copies; apply the queued directory/subtree deletes; verify the counts; then run the post-batch hook once |
| `STAGE_READY`         | stage boundary; the same place to trigger a reload/restart when the tool wants the stage transition rather than the batch |

**The copy starts during the batch.** A file watcher can react to an event before a writer closes the file; the
stage batch does not have that problem because the stage scan only reports files it has hashed. But the publisher
also does not wait for `STAGE_BATCH_END`: the stage batch streams a `STAGE_CHANGE_ENTRY` as soon as each file is
settled, and independent per-file work is exactly what those frames allow
([`FORMAT.socket.md`](FORMAT.socket.md) § "Why two boundaries"). A 10 000-class batch can therefore be copied while
the scanner is still walking the rest of the folder and the remaining entries are still being emitted; its wall
time is `max(copy, transfer, scan)` rather than their sum. The entries arrive in **observation order**, not
`(nameHash, name)` order and not the build's write order; the publisher treats them as independent files and does
not assume one class was settled before another.

**There is no quiet-period wait.** The 25 ms root debounce exists to coalesce a burst of source events into one
source batch. A stage pass is triggered by `BUILD_DONE`, not by the root watcher's quiet period, so the publisher
starts with the first stage entry instead of waiting for a timer to expire. The daemon still batches the stage
scan — a batch is what makes `STAGE_BATCH_END`, counts and replay well-defined — but the batching happens while the
scan runs, not after an extra idle delay.

**The batch is speculative until `STAGE_BATCH_END`.** Copies started during the stream are not committed state. If
the connection drops, a count or hash mismatches, or the stage generation does not advance as expected, the
publisher discards its temporary targets and reconnects from its last committed `from_stage_batch`; the replay
copies again. Copy side effects are therefore idempotent: content-addressed temporary names, then rename.

**The post-batch hook is the client's job, never the daemon's.** The daemon does not run scripts. After
`STAGE_BATCH_END` (and only after every copy succeeded) the publisher runs the user's action: a framework reload, a cache flush,
`systemctl reload`, a restart of the tested application. If no batch was published, no hook runs. If a copy failed,
the hook is skipped and the failure is reported: restarting an application with half the classes is worse than not
restarting it. Each subscriber owns its own hook; the barrier coordinates builds, not side effects.

A minimal loop:

```text
on STAGE_BATCH_START(stage, g): pending = {}; generation = g
on STAGE_CHANGE_ENTRY(e):       if e.change is remove -> pending.deletes.add(e.name)
                                else -> schedule copy(e.name, e.content_hash)  # do not await END
on STAGE_BATCH_END(g):          await all copies; apply pending.deletes; verify counts
                                if all copies verified -> run_reload_or_restart_script()
on STAGE_READY(stage):          optional: same hook at the stage boundary
```

**A file that is still being written is not emitted.** The stage scan hashes a file before it becomes an entry, so a
publisher cannot copy a half-written class under the name the writer will later use. That is the stability rule a
future live stage tail would have to preserve too; a raw watch event does not have it.

### 7.8 Edge cases pinned by the plan

- **Folder deleted** ⇒ all its names are deletes in the next stage batch, not an error.
- **Folder appears after declaration** ⇒ cold scan of that folder; the state's `configHash` already covers it.
- **Overlapping stages** ⇒ refused by config validation.
- **Nested `.git`/`.fs-meta`** ⇒ skipped; a stage state never enters itself.
- **Symlinks** ⇒ listed as symlinks and never followed, exactly as the root walk does.
- **A stage scan fails** ⇒ the stage keeps its previous generation, the ready frame for the next stage reports the
  failure (future status field), and the next pass retries. It must not silently advance.
- **Root and stage write the same directory** ⇒ config validation refuses a stage folder that is the root itself,
  and the root's other sources still apply. A declared stage folder is hidden from the root, so this is a config
  error rather than a loop.

## 8. Acceptance tests

These are the tests that make the barrier a fact rather than a diagram:

1. A plain `SUBSCRIBE` still decodes to stage 0, listener, pass-all; replay and live delivery are byte-identical
   to the previous release.
2. A stage-1 listener receives nothing while a stage-0 builder is active, receives the held batch when the
   builder sends `BUILD_DONE`, and then receives `STAGE_READY{stage:1}`.
3. Two stage-0 builders: stage 1 waits for both; the second `BUILD_DONE` opens the barrier.
4. A stage with no builder does not block: stage 2 is released without a stage-1 builder.
5. A builder that disconnects releases the barrier (the later stage is not stranded).
6. A stage-1 builder's `BUILD_DONE` releases stage 2, and a failed status still releases it.
7. Batches arriving while a builder works are held and delivered in order when it finishes; `END_BATCH` counts
   are the filtered set's, as before.
8. A `SUBSCRIBE_V2` with a reserved flag, a malformed filter section, or a `BUILD_DONE` above the head is refused
   with `ERROR{protocol}` and the connection closes.
9. A replay from `from_batch` stops at `released(stage)`, not at the root head: a stage-1 subscriber cannot skip
   its predecessor by reconnecting.

The folder-scoped stage state (§ 7) adds the next group. These are written before its code, as the use-case
documents require:

10. `build.json` accepts the example; it refuses an absolute folder, `..`, `.git`, `.fs-meta`, a duplicate stage,
    an overlapping folder across stages, and a stage above 64.
11. A declared folder is absent from the root trio and from the root change stream, and `fsmeta ignored` names
    `stage` as the deciding source; a folder removed from the declaration comes back to the root walk.
12. A stage state is written under `.fs-meta/stages/<NN>/` with workspace-relative names, 64-byte entries and
    content hashes; `files.json` carries the additive `stage` object and no absolute path.
13. With `gitignore` excluding `build/`, the stage scan still lists `build/classes/A.class`; `.git` and `.fs-meta`
    are never listed.
14. A stage-0 builder's `BUILD_DONE` triggers the stage-0 scan and publishes a stage batch; stage 1 receives the
    root batch plus the stage-0 batch/ready, and can name the changed artifact from the batch.
15. A second stage scan with no changes publishes no stage batch and the stage generation does not move.
16. Touching an artifact without changing its content is not a change; changing one byte marks that file only.
17. Deleting a stage folder yields deletes for every name in it, and recreating it yields adds.
18. Changing a stage's folders or hash mode changes `configHash`, causes a cold scan of that stage, and leaves the
    root generation and the root trio byte-identical.
19. `fsmeta stage diff` and `fsmeta stage scan` run the same pass without a daemon: two runs over an unchanged tree,
    the second reports no changes; editing one artifact reports only it.
20. Deleting `.fs-meta/stages/` makes the next stage scan a cold scan; it never trusts a missing state, and it never
    writes outside `.fs-meta/stages/`.
21. A stage batch's entries hash exactly like a root batch's entries; a stage state with a different `configHash`
    is discarded and cold-scanned. (Root-identity invalidation is still open: the writer records `0, 0`.)

The scp-like publisher example (§ 7.7) adds the streaming and side-effect tests:

22. A publisher copies an artifact after its `STAGE_CHANGE_ENTRY` and **before** the batch's `STAGE_BATCH_END`;
    the test holds the stream open with more entries after it and asserts the copy already exists.
23. A dropped connection or a count mismatch mid-batch leaves no committed copy set; reconnecting from the last
    committed `from_stage_batch` replays and copies again (idempotent temporary+rename).
24. The post-batch hook runs exactly once, after `STAGE_BATCH_END`, and not on `STAGE_BATCH_START`; an empty batch
    or a failed copy runs no hook, and the failure is reported.
25. A file that is still being written is not emitted as a `STAGE_CHANGE_ENTRY`; once settled, its entry's content
    hash matches the copied bytes.
26. A stage pass triggered by `BUILD_DONE` is not delayed by the root watcher's quiet period: the first
    `STAGE_CHANGE_ENTRY` is available as soon as the scan settles a file, with no extra 25 ms coalescing step.
27. Stage entries arrive in observation order, not `(nameHash, name)` order; a consumer that needs sorted state
    gets it from `files.meta` after `STAGE_BATCH_END`, while a per-file copier does not buffer.

The status and trigger work (B5/B13) adds:

28. Two stage-0 builders: the first `BUILD_DONE` does not scan; the second does.
29. A stage with no builders is scanned once per release, not once per tick.
30. A builder with unacknowledged work times out at `stage_timeout_ms` whether or not it sent `BUILD_STARTED`,
    releases its successor, and increments `stage_timeouts`.
31. A changed `.fs-meta/build.json` is detected on the tick and runs a pass even though `.fs-meta` is not watched.
32. `root status --json` reports `stage_blocked` (or `-1`), its generation, builders, batches, failures, timeouts,
    and the last scan's timestamp/duration/error.

## 9. Steps

| #   | Step                                                                                 | Gate                                                                                               |
| -   | ----                                                                                 | ----                                                                                               |
| B1  | **done** — `wire.zig`: barrier and stage-batch kinds, payload structs, protocol `0x0104`, unit tests | `zig build test` for the wire tests                                                |
| B2  | **done** — `filter.zig`: `SUBSCRIBE_V2` decoder, stage/builder defaults, tests       | the old 8-byte and extended forms still decode                                                     |
| B3  | **done** — `daemon/root.zig`: subscriber stage/builder/ack, `released`/`acked`, gated replay and live delivery, `BUILD_*` handling in `readLoop`, `STAGE_READY` | the socket tests in § 8 |
| B4  | **done** — `FORMAT.socket.md` § BUILD_STAGES, `FORMAT.daemon.md` § 8b, README/AGENTS | the document describes exactly the implemented bytes                                               |
| B5  | **done** — `root status` stage counters (`stage_blocked`, generation, builders, batches, failures, timeouts, last scan), a 60 s timeout for any builder with unacknowledged work, and a content-hash poll of `build.json` that triggers a pass | a status reply names the blocked stage and an unacknowledged builder releases it; tests cover both |
| B6  | **done** — `.fs-meta/build.json`: parser, validation, `configHash`, tests            | § 8 test 10                                                                                        |
| B7  | **done** — declared folders as the `stage` ignore source; `fsmeta ignored` names it; `scan.ignoreSources` documentation | § 8 test 11                                                     |
| B8  | **done** — stage state under `.fs-meta/stages/<NN>/`: scoped scan, workspace-relative names, `files.json` `stage` object, batch archive, cold-state fallback | § 8 tests 12, 16, 17, 20   |
| B9  | **done** — daemon: after a stage's builders are done, scan the stage and stream `STAGE_BATCH_START`/entries while the walk runs, end after the commit | § 8 tests 13–15, 26               |
| B10 | **done** — `fsmeta stage status/scan/diff`; CLI and daemon share `stage.refresh`     | § 8 test 19                                                                                        |
| B11 | **done** — `STAGE_BATCH_START`/`STAGE_CHANGE_ENTRY`/`STAGE_BATCH_END`, observation order, `SUBSCRIBE_V3` and `from_stage_batch` replay; root batches still hash-ordered | a stage-1 client can distinguish, consume and replay a stage batch; § 8 test 27 |
| B12 | **done** — [`examples/stage-publisher/`](../examples/stage-publisher/) implements the § 7.7 publisher: copy while streaming, commit at `STAGE_BATCH_END`, hook once; [`test/stage-publisher.test.mjs`](../test/stage-publisher.test.mjs) proves the copy is visible before the end | [`test/stage-publisher.test.mjs`](../test/stage-publisher.test.mjs) |

B1–B12 are implemented; B9's first version (scan first, then stream) is recorded in § 7.6 as history and was
replaced by emission from `scan.Options.on_fact` while the walk runs. B11 includes the `SUBSCRIBE_V3` cursor and
archive replay, B12 is the runnable publisher example, and B5 adds the status view, timeout, config polling, and
the multi-builder/no-builder scan gates. There are no open steps in this plan.
