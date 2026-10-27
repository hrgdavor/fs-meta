# TBD: the per-root child daemon (M5 of the daemon plan)

**Status:** not scheduled. This is the *only* item the daemon plan deliberately left undone, and it was moved out of
[`daemon.md`](archive/daemon.md) on 2026-10-26 so that plan can close: everything else in it is implemented, measured or
decided. Nothing here is needed for the daemon to work; this file exists so the idea keeps its design, its constraints
and the facts that would make it worth doing — and so nobody re-derives them.

**What it is.** Today one process serves every root: `Host` owns N `RootRuntime`s, each with its own socket, scheduler
task, lock and watcher, all in one address space (`FORMAT.daemon.md` § 2c). M5 would let a root be served by its **own
child process**, with the parent daemon aggregating state — the same consumer sockets, the same control protocol, the
same CLI. The interface between them was designed before the daemon existed (§ 4 of `daemon.md`):

```zig
pub const RootHost = struct {
    snapshot: *const fn (self: *anyopaque, alloc: std.mem.Allocator) anyerror!RootSnapshot,
    control:  *const fn (self: *anyopaque, request: ControlRequest) anyerror!ControlReply,
    deinit:   *const fn (self: *anyopaque, alloc: std.mem.Allocator) void,
};
```

`inproc` implements it over a `RootRuntime`; a `child` would implement it over a spawned `fsmeta root-daemon --id <id>`
plus a pipe or a second socket. The registry already carries `served_by = inproc | child:<pid>`, and the CLI prints it
(`root status` → `served_by`), so an aggregated view can say which roots live where.

## Why it is not done

It is not about latency any more. When the plan was written, the expectation was that a slow scan in one root would
delay the others, and that was the reason to split. **That coupling was removed** (§ 2c of `FORMAT.daemon.md`): each
root has its own scheduler task and its own lock, and `test/daemon.test.mjs` pins it with a root deliberately blocked
mid-write while another root must still publish in under 3 s. Measured: the unblocked root published in ~150 ms.

What is left is **isolation of failure and memory**, which is real but has no evidence behind it yet:

- a panic in one root's task takes the whole process (a Zig panic is process-wide, not per task);
- a root with a huge tree keeps its cache in the shared address space, so one big root can push the daemon into the
  allocator's slow path or an OOM that kills the others;
- a `root remove` of a stuck root blocks the control plane (§ 4b of `FORMAT.daemon.md` records the bounded-wait rule
  that keeps this from being unbounded, not a promise that it is fast).

## What would make it worth doing (the trigger, not a guess)

1. **A measured case** where one root's scan delays another root's *batch* beyond a user-visible threshold — the
   per-root scheduler means this needs a pathological root (very large tree, slow volume) rather than the normal case;
2. or a **crash/OOM report** where one root took the daemon down;
3. or a need to **restart one root** (a new mode, a new retention) without dropping the others' subscribers.

Until one of those exists, the split buys isolation at the cost of a second process, an IPC protocol, supervision
(who restarts a dead child? the plan's non-goals exclude a service manager), and a new failure mode: the parent must
tell "child busy" from "child dead". That is why it is here and not in the daemon plan.

## What has to be decided first

- **The IPC shape.** `RootHost` over a socket (JSON lines, like the control plane) or a pipe with the binary frames?
  A socket is reusing two things that exist (`control.zig`'s schema, `wire.zig`'s frames); a pipe is smaller but new.
- **Ownership of the consumer socket.** The child binds `<base>/roots/<id>.sock` (it must: the socket is the root), so
  the parent must not claim it, and `reaper.zig` must learn which process holds which claim. `roots/<id>.pid` already
  encodes this as an OS file lock, which is the mechanism to keep.
- **Supervision.** Parent exits → children? Child exits → restart, report, or leave the root `off`? The plan's
  non-goals say no supervision policy, so the first answer must be "no restart, reported as `missing`", not a policy.
- **The state the parent aggregates.** `roots list` would have to mark a child as `available: false` when the child
  cannot answer — the § 4b budget rule already has the vocabulary; a child is simply another thing that can time out.
- **Spawn cost and the socket race.** `root add` must not return before the child's socket answers (the CLI's `start`
  already models "up" as "the control socket answers", so the same shape applies one level down).

## Definition of done (for whoever picks it up)

- `fsmeta root-daemon --id <id>` (hidden or explicit) serves exactly one root: binds its socket, claims it, runs the
  same `RootRuntime` code, and speaks `RootHost` to its parent.
- The parent serves every root through one interface, so a mixed `inproc`/`child` set works; `served_by` reports which.
- Killing a child leaves the parent up, the other roots serving, and that root reported (`available: false`, or
  `missing` — pick one and document it); the next `root add`/restart can adopt it.
- `tests/daemon.test.mjs` gains a case that runs one root as a child and asserts the same consumer contract
  (`test/daemon-parity.test.mjs` is the model: same batches over the same archive from both servers).
- `FORMAT.daemon.md` § 7 stops describing the seam and documents the split: the IPC, `served_by`, and the refusal a
  client sees when a child is not answering.

## What exists today, so a start does not begin from zero

| piece                                                                             | where                                                  |
| --------------------------------------------------------------------------------- | ------------------------------------------------------ |
| one root's whole lifecycle as a value                                             | `RootRuntime` (`src/daemon/root.zig`) — socket, subscribers, scheduler task, lock, watcher, state machine |
| the per-root state machine, clock-injected and socket-free                        | `src/daemon/state.zig`                                 |
| the control protocol and the § 4b budget rule a child would answer under          | `src/daemon/control.zig`, `FORMAT.daemon.md` § 4       |
| claims as OS file locks, so "who serves this root" is answerable across processes | `src/daemon/reaper.zig`                                |
| `served_by` in the record and in every reply                                      | `src/daemon/registry.zig`, `FORMAT.daemon.md` § 3/§ 4  |
| the seam as a documented fact (not yet a vtable: nothing calls it)                | `plans/archive/daemon.md` § 18, `FORMAT.daemon.md` § 7 |
