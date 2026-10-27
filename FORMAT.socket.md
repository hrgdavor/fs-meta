# format for unix socket communication

notes

- define binary handshake but in such way it can not happen first two bytes are start of JSON object `{"`
  - this way we easily recognize when it is JSONRPC 
- binary wire protocol is 8 bytes for message prefix and 
  - when sending changes adds 64 bytes from meta followed by file name without newline
  - those 64 bytes have file name length that makes it easy to know that entry being read is 64+filenameLength and next starts after it 
  - commands are encoded in the 8 bytes somehow
  - START_BATCH
  - END_BATCH
  - CHANGE_ENTRY
  - etc...

## Proposed wire format

The notes above are the origin of this design; what follows makes them precise enough to implement, and deliberately
reuses the format the engine already writes so that **nothing on the wire needs a second parser**.

### Framing

Every message is an 8-byte prefix followed by `length` payload bytes, all integers little-endian:

| Offset | Size | Field    | Meaning                                                                                   |
| ------ | ---- | -------- | ----------------------------------------------------------------------------------------- |
| 0      | 2    | `kind`   | the message kind, a `u16` from the table below                                            |
| 2      | 2    | `flags`  | bit 0 = `MULTIPART` (reserved, unused); bits 1..15 reserved; a reader rejects any set bit |
| 4      | 4    | `length` | payload bytes after the prefix, at most 1 MiB                                             |

`kind` values are all **below `0x7B`**, so the first byte of a binary message can never be `0x7B` (`{`) — which is
what makes the JSON-RPC side of the socket recognisable from its first byte, as the notes ask: a JSON object starts
`{"` = `0x7B 0x22`, and a binary message starts with a small kind byte followed by `0x00`.

**The 1 MiB limit is per frame, not per batch.** A batch is a *chain* of frames — `START_BATCH`, one `CHANGE_ENTRY`
per entry (64 bytes plus a name), `END_BATCH` — so a generation of any size is delivered as many small frames. A server
must therefore not bound a batch by the frame limit when it reads that batch back from disk: `server.zig` keeps a
separate `max_batch_file_bytes` for it, with a test that loads a batch larger than one frame. This was a real defect,
not a hypothetical: a first batch of more than ~16 384 names (64 B per entry) could not be read back, so the consumer
of a large tree received no batch at all and only the daemon's `last_error` said why.

### Messages

| `kind` | Name           | Payload                                                                                |
| ------ | -------------- | -------------------------------------------------------------------------------------- |
| `0x01` | `HELLO`        | the fixed 24-byte greeting of § Handshake — its one definition, not a second size here |
| `0x02` | `START_BATCH`  | `u64 number`, `u64 parent`, `u64 started_ns`                                           |
| `0x03` | `CHANGE_ENTRY` | 64-byte entry (§ 5) + name bytes, no LF                                                |
| `0x04` | `END_BATCH`    | `u64 number`, `u64 added`, `u64 changed`, `u64 deleted`, `u64 changes_hash`            |
| `0x05` | `ERROR`        | `u16 code`, then a UTF-8 message                                                       |
| `0x06` | `SUBSCRIBE`    | `u64 from_batch` — the last batch the client has applied (`0` = nothing)               |
| `0x07` | `PING`         | empty                                                                                  |
| `0x08` | `PONG`         | empty                                                                                  |
| `0x09` | `STATE`        | `u8 state`, `u8 reason`, `u32 idle_timeout_ms`, `u64 head_batch` — see § STATE         |
| `0x0a` | `GIT_EVENT`    | `u8 phase`, `u8 kind`, `u8 source`, `u8 status`, `u64 head_batch`, `u64 at_ms`, then for `kind = worktree` only `u32 path_len` + path — see § GIT_EVENT |

**`HELLO` is defined once**, in § Handshake; the row above is a pointer that keeps the kind numbering in one place,
not a second payload layout.

**`CHANGE_ENTRY` is the trio's entry, unchanged.** Its `nameLength` (offset 40) makes the frame self-delimiting:
`length == 64 + nameLength`, and a client checks that equality rather than trusting `length` alone. The change kind
comes from the entry's change bits (§ 17.2), so there is no third representation of "added / changed / deleted" — the
wire, the batch folder and the in-memory plan all speak the same 64 bytes.

**`START_BATCH` / `END_BATCH` are the boundaries, and `END_BATCH` is the commit.** A client applies nothing until the
batch's `END_BATCH` arrives, exactly as a reader trusts `files.json` last (§ 9): the counts in `END_BATCH` must equal
the entries counted by change bit, or the batch is discarded with `batch-count-mismatch`. That is what makes a dropped
connection mid-batch harmless — the client keeps its `from_batch` and asks again.

### Ordering on the wire

`CHANGE_ENTRY` messages within a batch are sent in **`(nameHash, name)`** order (§ 4 and § 17.2a). A client therefore
does not buffer a batch to sort it: it can insert into its own hash-ordered state as messages arrive, and a batch that
arrives already sorted merges with the previous one in a single walk — the same operation the reconcile API performs
off-line.

### Replay, resume and the two refusals

1. The client sends `SUBSCRIBE {from_batch}`.
2. The server answers with `HELLO`, then for each generation `g` in `from_batch + 1 ..= current`: `START_BATCH{g, g-1}`,
   its `CHANGE_ENTRY` messages, `END_BATCH{g, …}`.
3. If `from_batch` is older than the oldest retained batch, the server answers `ERROR{batch-too-old}` and the client
   falls back to a full pass (read the trio, or ask for a snapshot).
4. A missing batch in the range is `ERROR{batch-gap}` — never silently skipped, because a skipped batch is a quietly
   wrong index.

Live updates are the same messages: when a pass publishes generation `g`, the server sends its `START_BATCH`,
`CHANGE_ENTRY` messages and `END_BATCH` to every subscribed client whose `from_batch` is `g - 1`. A client that was
asleep gets the replay path instead, which is why replay and live streaming are one protocol rather than two.

### STATE

`STATE` (kind `0x09`) exists because a daemon can put a root to sleep, and that creates a question the wire could
not ask before: **is this subscribe slow because the root is waking?** A consumer cannot tell "waking, 400 k files"
from "big tree, first batch is slow" from "server stuck", and the answer costs fourteen bytes.

```
u8   state            0 = off, 1 = asleep, 2 = waking, 3 = watching
u8   reason           0 = none, 1 = a client subscribed, 2 = idle timeout, 3 = control request, 4 = watcher event
u32  idle_timeout_ms  the root's current setting; 0 = it never sleeps
u64  head_batch       the newest batch the server considers published
```

`head_batch` is the whole progress story. A client compares it with its own last applied batch and knows whether a
wake means "one small diff" or "a long catch-up" — and the server estimates nothing. There are deliberately no
progress counters, no percentages and no files-scanned: on the measured workloads thousands of files are
milliseconds, so progress would flicker and then be gone, and it would turn a state notification into a telemetry
channel that has to be kept honest under a deadline. A richer view (passes, bytes, elapsed) belongs to the CLI's
`root status --json`, which no consumer waits on.

**When a server sends it** — always between batches, never inside one (`START_BATCH` … `END_BATCH` is a
transaction, and a `STATE` there would be a protocol violation; the suite asserts it):

1. immediately after `HELLO`, so a fresh client knows what it joined;
2. `state = waking` **before** the wake scan's first `START_BATCH` — the case the frame exists for;
3. on every transition (`waking → watching`, `watching → asleep`, a mode change made through the control socket);
4. a final `STATE` before the connection is closed on shutdown, so a client stops waiting rather than timing out.

A server that does not implement `STATE` never sends kind `0x09`, and a client that does not understand it must
refuse the frame rather than skip it (the framing rule above: an unknown kind closes the connection).

**A pass that changed nothing sends no `STATE`.** The frame announces transitions, not a heartbeat; one every pass
interval would be a telemetry stream, not a state notification.

`FORMAT.daemon.md` documents the state machine these four fields describe.

### GIT_EVENT

`GIT_EVENT` (kind `0x0a`, protocol `0x0102`) is the daemon's second addition: a git operation's **start** or **finish**,
interleaved between batches and never inside one. It exists because a checkout changes two things a consumer cannot
correlate otherwise — the files, which arrive as an ordinary batch, and the fact that a git operation produced them.

```
u8   phase       0 = start, 1 = finish, 2 = aborted
u8   kind        0 = branch, 1 = checkout, 2 = commit, 3 = merge, 4 = rebase, 5 = index, 6 = worktree, 7 = other
u8   source      0 = metadata (the file timeline), 1 = hook (a `post-checkout`/`reference-transaction`, M5)
u8   status      0 = ok, 1 = our pass failed, 2 = timed out
u64  head_batch  the receiving root's head; for a `finish`, the batch the finish waited for
u64  at_ms       epoch milliseconds, the daemon's own clock
```

A payload is **exactly 20 bytes**, except for `kind = worktree`, which appends `u32 path_len` and the UTF-8 path, so its
length is `24 + path_len`. `path_len = 0` is valid and means "the path is no longer knowable" — a `git worktree remove`
deletes the metadata that named it, so a consumer must read an empty path as *a worktree left this repository*, not as a
malformed frame. A reader checks `path_len <= length - 24` before slicing the path, and a non-`worktree` kind with any
length but 20 is a `LengthMismatch`; a value outside a table is refused rather than guessed at. The two tables that
matter for compatibility:

- **`kind = worktree` is the only variable-length event and the only one that names a path.** A branch event is about
  *this root's* working tree, and the connection is the attribution; a worktree appearing or leaving is a fact about the
  repository, which the root's stream cannot name otherwise.
- **`head_batch` is the root's head, not a promise of a fetchable batch.** For a tree-changing operation it is the
  generation the finish waited for. For a **repo-wide** event (`refs/`, `packed-refs`, a worktree) no batch was
  published for that root — its tree did not change — so its `head_batch` is the head the root already had, and a
  consumer must not read it as "a batch you can fetch".

**`source = hook` is the same contract from a precise signal.** When the repository's hooks are installed
(`FORMAT.daemon.md` § 6a), `reference-transaction` reports a ref update's start (`prepared`) and its finish
(`committed` or `aborted`) per transaction, and the specific hooks supply the kind: `post-checkout`'s flag is `branch`
(1) or `checkout` (0), `post-merge` is `merge`, `post-rewrite` is `rebase` (or `other` for an amend), `post-index-change`
is `index` and `post-commit` is `commit`. A `reference-transaction` event without such a companion is `other`: the spool
line records the phase, not the ref names, and a kind is never guessed. A start is written as soon as the hook fires
(so it may precede the batch or follow it — rule 1 is unchanged), a `committed` finish waits for the pass exactly as a
metadata finish does, and an `aborted` finish is written at once (rule 6). With hooks installed **both sources may
report one operation** — a checkout produces hook frames and the timeline's — and `source` is how a consumer tells them
apart; coalescing is per `(kind, phase)` per pass, not per operation.

**The ordering contract**, which is the point of the frame:

1. **Start has no constraint.** It may come before or after the `START_BATCH` of the pass that is running; a consumer
   that queries on start may see a half-written tree, and that is what "start" means. The metadata timeline's starts are
   notices ("the tree is about to be rewritten"), a hook's are precise (`source = hook`).
2. **Finish is written only after the pass that reflects it has been published** — per connection. The pass commits the
   trio, the daemon writes `START_BATCH` … `END_BATCH` (and a `STATE` if the pass emits one), and only then
   `GIT_EVENT(finish)`. A consumer that reacts to "finished" with a query therefore finds the work done and has its
   batch first.
3. **A pass that publishes nothing still precedes its finish.** If a checkout lands on identical content there is no
   batch to precede it; the guarantee is "never before the pass", not "always a batch".
4. **Batched operations finish in order, coalesced by kind.** One pass may cover several metadata changes; at most one
   event per `(kind, phase)` is emitted for it, in the order the kinds were first seen. A `git fetch` that moves many
   refs is one `commit` event for that root's flush, not one per ref.
5. **A failed pass is reported, not hidden:** the finish carries `status = failed` (its `head_batch` is the head the
   root had). Silence would be the one outcome that makes a consumer believe a state it never received.
6. **`aborted` is sent without waiting for a pass**, because nothing was published, and a start whose finish never
   arrives is closed after a bounded time with `status = timed_out`.
7. **Only a root with `gitwatch` on emits.** A root whose flag is off receives no `GIT_EVENT` at all — its flag says it
   asked for no git handling — and a sleeping root sends none because it has no watcher (§ 5h).
8. **A late subscriber is not replayed a finish.** Git events are a live signal, not a log: a client that subscribes
   after one was flushed learns the state from the batch. The history of git operations is `root status`'s job.

**Git events are a daemon feature.** `fsmeta serve` announces `0x0102` and never emits `0x0a` (or `0x09`): it has no
scheduler and no git handling, so a consumer of `serve` gets batches only — the same asymmetry `STATE` already has.

### What the wire deliberately does not carry

- **File contents.** A client that needs a file's bytes asks the host OS, not the engine; the engine hashes on request
  (§ 12) and reports the hash, not the data.
- **The trio's own bytes.** `SUBSCRIBE` is the incremental path; a client that wants the whole state for the first time
  reads `files.meta` / `files.txt` / `files.json` directly, or asks for a snapshot message that is not specified yet.
- **Ordering by clock.** `START_BATCH.started_ns` exists for diagnostics; ordering is the batch number, never a
  timestamp, because a clock can go backwards and a sequence cannot.

### Why two boundaries: the consumer can work during the batch

`START_BATCH` and `END_BATCH` are not only a framing device — they tell a consumer **which work it may begin now and
which must wait for the whole change set**, and that distinction is where the latency advantage comes from.

Work that is **independent per entry** can start the moment its `CHANGE_ENTRY` arrives, while the rest of the batch is
still being decoded and transferred:

- reading the file's bytes (or opening it for the host tool that will use it) and hashing/parsing them;
- building the consumer's own per-file rows, index entries or parse trees;
- scheduling per-file work on a thread pool, one task per change.

Work that **depends on the complete set** is postponed to `END_BATCH`, and the reason is that it cannot be decided
from a prefix:

- a removed directory removes its subtree, and the set of surviving names is only known at the end;
- renames and "same content, new name" detection need both sides of the window;
- aggregate structures — inverted indexes, dependency graphs, "is any file dirty" flags — need every change before
  they are consistent;
- the durable commit itself: one transaction, one `generation` watermark advance, one "generation g applied" event.

So a consumer that waits for the last byte pays `transfer + independent_work` serially; one that pipelines pays
`max(transfer, independent_work)` and hides the parsing under the network. On a batch of a few thousand entries over a
socket that is a real difference, and on a local socket it is the difference between "the watcher's latency" and "the
watcher's latency plus the indexer's".

The correctness rule is unchanged: **pipelined work is speculative until `END_BATCH`.** A consumer may do it, must not
acknowledge it, and must be able to discard it — if the connection drops or a count mismatches, it keeps its old
`from_batch` and replays from there. Because the independent work is a pure function of (entry, file bytes), replaying
it is safe, which is what makes the pipelining free rather than merely fast.

`START_BATCH` also fails fast: `number` and `parent` are in the first message, so a consumer whose `from_batch` does not
match `parent - 1` learns it immediately instead of after receiving a change set it cannot apply.

### Handshake

A handshake should answer four questions before any change flows — *which protocol, which layout, which hash, which
role* — and it should be impossible to confuse with either JSON-RPC or a stray write to the socket.

**Simultaneous greeting.** Both sides send one `HELLO` immediately on connect, without waiting:

```
kind   = 0x01            (2 bytes, little-endian, always < 0x7B)
flags  = 0               (2 bytes)
length = 24              (4 bytes: a FIXED greeting size)
payload:
  u16  protocol        major << 8 | minor
  u16  entry_size      64
  u8   hash_algorithm  0 = wyhash64
  u8   role            0 = server, 1 = client
  u8   capabilities    bit 0 = snapshot, bit 1 = changes_hash, bits 2..7 reserved
  u8   reserved        0
  u64  generation      the newest batch this side knows (0 = none)
  u64  max_frame       largest payload this side will accept
```

Then each side reads the peer's greeting and checks it, in this order and with these names — the same ones the file
format uses, so a client reports one vocabulary:

| check                                   | failure                  |
| --------------------------------------- | ------------------------ |
| `entry_size == 64`                      | `unsupported-entry-size` |
| `hash_algorithm == 0`                   | `unsupported-hash`       |
| `major` differs from ours               | `unsupported-version`    |
| `length` is not the greeting's fixed 24 | protocol error           |
| unknown **required** capability bits    | `unsupported-capability` |

Minor versions are negotiated by allowance: a newer minor may append fields after byte 23 and advertise them in
`capabilities`; an older peer reads the fixed 24 bytes and ignores the rest because `length` tells it how much to skip.
**This implementation does not use that allowance yet** — it accepts `length = 24` exactly and refuses a longer
greeting (see § Values this implementation pins). Major versions change the layout and are refused rather than guessed.

After the greeting the client sends `SUBSCRIBE {from_batch}`; the server replies with `HELLO`-derived replay
(`START_BATCH` … `END_BATCH` per generation) or the live stream. There is no "who speaks first" question because both
greet at once, and no state machine whose order can deadlock.

### Values this implementation pins

The layout above is the format. Three of its values are this implementation's choice, and they are pinned here so a
client author reads them instead of inferring them from the server's bytes.

**`protocol` is `0x0102`** — major 1, minor 2. A client must use major 1; a different major is `unsupported-version`.
The minor is negotiated by allowance, as above. Minor 1 is the `STATE` frame (§ STATE) and minor 2 is `GIT_EVENT`
(§ GIT_EVENT); there are no deployed clients, so each bump was made once and every implementation was updated
together — no capability bit gates either, and a `0x0100` or `0x0101` caller is still accepted because the major
matches. A minor-2 client that does not know `0x0a` must refuse it rather than skip it (an unknown kind closes the
connection), which is why the bump is a bump: a reader must be able to say "I do not know this frame".

**`ERROR` codes** are the `u16 code` at offset 0 of the payload (kind `0x05`). The number is the contract: the UTF-8
message that follows begins with the code's word and `: `, then detail for a human, so a client branches on the number
and never on the text.

| code | word            | sent when                                                                                          |
| ---- | --------------- | -------------------------------------------------------------------------------------------------- |
| 1    | `protocol`      | the peer's greeting is not a `HELLO` frame with `length = 24`, its payload does not decode (`role` outside 0/1), or it fails a greeting check (`unsupported-entry-size`, `unsupported-hash`, `unsupported-version`, `unsupported-capability`); `SUBSCRIBE` is not an 8-byte payload, or its `from_batch` is newer than the newest batch; or a frame prefix is refused (`unknown-kind`, `unsupported-flags`, `frame-too-large`) |
| 2    | `batch-too-old` | `from_batch + 1` is below the oldest retained batch, so replay cannot start where the client asked |
| 3    | `batch-gap`     | a generation in `from_batch + 1 ..= newest` has no batch directory                                 |

**`changes_hash` is `0`, and its capability bit is clear.** The server advertises `capabilities = 0`, so bit 1
(`changes_hash`) is off and every `END_BATCH` carries `changes_hash = 0`. What the field would hash is not specified
yet, so **a hash-verifying client must not rely on it**: treat it as absent and use the exact `added` / `changed` /
`deleted` counts, which the document does define, as the batch's integrity check. Bit 0 (`snapshot`) is clear for the
same reason — the snapshot message is not specified yet.

Two consequences of the same "pin it, do not guess" rule. Capability bits outside `0x03` are treated as required by
this server and refused with `unsupported-capability`, so a reserved bit is never silently ignored. And a greeting
longer than 24 bytes is a protocol error, so a newer minor must still greet in the fixed 24 bytes.

### Lessons taken from ZMTP (ZeroMQ's wire protocol)

ZMTP solved several of these problems a decade earlier, and four of its decisions transfer directly:

- **A fixed greeting before any length-prefixed frame.** ZMTP's greeting is 64 fixed bytes; only after it do frames with
  length fields begin. The lesson: bootstrap framing with a size both sides already know, so a wrong length assumption
  cannot corrupt the stream before the first frame is parsed. That is why our `HELLO` payload is fixed at 24 and the
  variable frames come after it.
- **A signature that cannot be another protocol.** ZMTP starts with `0xFF` followed by zeros specifically so an HTTP or
  other text request cannot be mistaken for it, and a peer that sees a non-matching first byte can report "not ZMTP"
  instead of guessing. Ours is the same idea in the other direction: every `kind` is `< 0x7B`, so a binary greeting can
  never begin with `{` and JSON-RPC is identified by `0x7B 0x22`.
- **Version and mechanism advertised in the greeting, not discovered later.** ZMTP puts `major`, `minor`, a 20-byte
  mechanism name and an `as-server` bit in the greeting, and negotiates security *after* the transport is framed. We
  copy the shape — `protocol`, `capabilities`, `role` — and deliberately leave the mechanism slot empty: a loopback
  unix socket has no authentication story today, but reserving the byte means adding one later does not need a major
  version. ZMTP's own rule applies: an unknown mechanism is an error, never a silent downgrade — the same reason an
  unknown capability bit is `unsupported-capability` rather than ignored when the sender called it required.
- **Command frames, separate from data frames, so the protocol can grow.** ZMTP 3.1 added `PING`, `PONG` and `ERROR` as
  command frames without a version bump, precisely because a command is a frame with a different flag rather than a new
  envelope. Our kind table is that idea taken to its end: everything, including `CHANGE_ENTRY`, is a kind, so a new
  message is a new number and an old peer refuses it cleanly instead of misparsing it.

Two ZMTP choices we deliberately do **not** copy:

- **Short and long length encodings.** ZMTP uses a one-byte length below 256 and eight bytes above; at 64 bytes per
  entry our frames are always over the threshold, so the shorter form would only add a branch. A 4-byte `length` in
  the prefix is simpler and measurable: it costs 8 bytes per entry on the wire, and a replay of 3,900 entries is
  ~31 KB, which is not a reason to complicate the decoder.
- **Skipping an unknown frame by its length.** A ZMTP peer may skip a frame it does not understand. Here that is the
  one unrecoverable mistake: a skipped `CHANGE_ENTRY` is a silently wrong index, so an unknown `kind` is an error and
  the connection is closed, and the client resumes from its own `from_batch`.

One ZMTP idea worth adopting later is **multipart (`MORE`)**: one frame carrying several entries would amortise the
8-byte prefix over a whole batch. It trades away the per-entry self-delimiting property — a client could no longer
validate `length == 64 + nameLength` per message and would have to walk a frame's interior — so it belongs after a
measurement shows the prefix is the cost, not before.

### Multipart: reserved, not specified

`flags` bit 0 is **`MULTIPART`**. It is *defined* and *unused*: every message today carries it clear, and a receiver that
sees it set answers `unsupported-flags` and closes the connection rather than guessing what follows. "Reserved" must
never be read as "supported", or a future sender would be silently ignored by today's reader.

What it will mean when it is specified:

- one frame carrying **several `CHANGE_ENTRY` payloads back to back**, each still self-delimiting by `64 + nameLength`;
- the 8-byte prefix is paid once per frame instead of once per entry — on a full replay of 3,900 entries that is
  ~31 KB of prefix, the largest single overhead the protocol has today;
- the cost is the property this document relies on elsewhere: a receiver could no longer check one message against one
  `length` field, and a truncated interior would be harder to diagnose than a truncated frame.

Why it is reserved rather than specified: **nothing needs it yet**, and reserving costs one bit. That bit is also what
keeps the door open — without it, a later batched framing would have to overload `kind` or bump the major version,
both of which break peers for a change that is purely an optimisation.

The rules for today, so the reservation is enforceable rather than decorative:

| today      | rule                                                                |
| ---------- | ------------------------------------------------------------------- |
| senders    | write `flags` as `0`                                                |
| receivers  | `flags != 0` → `unsupported-flags`, close, resume from `from_batch` |
| bits 1..15 | reserved on the same terms as bit 0                                 |

### Optional HTTP endpoint

`fsmeta serve <root> --http` also exposes the socket through an HTTP endpoint via the
[socutil](../socutil/) library. The port is the only thing the flag chooses: bare `--http` binds 8765, as before,
`--http=<port>` the port you name, and `--http=0` any free port the operating system hands out, which is then
announced on stdout as `socutil listening on http://127.0.0.1:<port>/`. The flag is valid only for `serve`; any
other command given it fails with `fsmeta: --http is only valid for the serve command`. The HTTP endpoint is a
front for the same Unix socket: the socutil UI lists the socket by name (`fs-meta.socket`) and relays it over a
WebSocket byte tunnel or an SSE tail. The binary protocol on the Unix socket is unchanged; the endpoint is an
optional convenience for browsers and tools that cannot open a Unix socket directly.
