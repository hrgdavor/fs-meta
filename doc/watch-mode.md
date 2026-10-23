# Watch mode — self-tuning batching

The watcher maintains a trio while a developer works. The only scheduling question it must answer is **when a
burst of file events becomes one engine pass**, and the answer is not a constant: a machine that passes in 20 ms
should feel immediate, and one that passes in 900 ms must not queue work it cannot finish. So there is no configured
delay — each project's delay is **measured**, persisted, and reported.

## The shape

```text
nightwatch (background thread)          poll thread
  event ──► Batcher (atomics) ──► take ──► Runner.event ──► one engine.refresh per due batch
                   ▲                          │
        git lock / grace window               └─► measured duration ──► watch.json, per project
```

| file                                                 | what it holds                                                     | tested              |
| ---------------------------------------------------- | ----------------------------------------------------------------- | ------------------- |
| [`../src/watch.zig`](../src/watch.zig)               | the policy: EWMA of pass durations, quiet period, forced deadline | 5 tests             |
| [`../src/watch_tuning.zig`](../src/watch_tuning.zig) | per-project state, `watch.json`, the suggested delay              | 2 tests             |
| [`../src/watch_run.zig`](../src/watch_run.zig)       | the loop: bootstrap, event, service, learn, persist               | 3 tests             |
| [`../src/main.zig`](../src/main.zig)                 | the adapter: nightwatch, the git transaction guard, the poll loop | the live test below |

The engine pass is injected into the loop as a function that returns its own measured duration, which is why the
policy is fully tested without a file system and the adapter has no policy in it at all.

## The rule

```text
quiet = clamp(factor × pass_ewma, min_delay, max_delay)      factor 1.5, 25 ms … 2000 ms
```

- **A burst is flushed after `quiet`** of no events.
- **`max_wait_ms` (5 s) forces a flush** even while events keep arriving, so a permanently busy tree is serviced at a
  bounded interval instead of being starved — the failure mode a plain debounce has.
- **Before the first pass is measured**, the floor (25 ms) is used: the first flush never waits on a guess.
- **The estimate is an EWMA (weight 0.3)**, so a machine that is briefly busy does not pin the delay forever: five
  slow passes raise it, ten fast ones bring it back down (asserted by a test).

## The per-project contract

`<project>/.fs-meta/watch.json` — a directory the walker never lists, so the state cannot appear in the tree it
describes:

```json
{ "version": 1, "passes": 42, "ewmaMs": 18.234, "lastMs": 17.900, "maxMs": 61.200, "suggestedDelayMs": 27.351 }
```

- **A restart resumes tuned.** The next session starts with the delay this project actually needs.
- **`suggestedDelayMs` is what a fixed-delay configuration should use**, rounded up to whole milliseconds — derived
  from this tree's measurements rather than from a table of guesses. The watcher prints it at startup:
  `watch tuning for this project: 42 passes, ewma 18.2 ms, last 17.9 ms, max 61.2 ms → suggested delay 28 ms`.
- **It is derived state.** A corrupt or absent file returns defaults rather than an error, costing one burst of
  re-learning; it is written atomically (temporary file, then rename), and saved every 20 passes as well as on
  shutdown.

## Two invariants, and the test that proves them

The live test — [`../bench/watch-test.mjs`](../bench/watch-test.mjs) — starts the watcher on a tree, moves the tree
between two commits **underneath it**, and checks three things:

```text
bun fs-meta/bench/watch-test.mjs .tmp/head 7bfad9a 32478e7
```

| phase              | passes | publishes | names | trio == walk |
| ------------------ | -----: | --------: | ----: | ------------ |
| bootstrap          | 3      | **1**     | 1965  | yes          |
| checkout `32478e7` | 3      | **1**     | 1957  | yes          |
| checkout `7bfad9a` | 3      | **1**     | 1965  | yes          |

1. **The watcher bootstraps** and publishes before any event is trusted.
2. **One batch, one publish per move** — a checkout touching 99 files yields one generation, not one per event. A
   trailing batch that finds nothing publishes nothing.
3. **The trio agrees with an independent oracle** after every phase: the names in `files.txt` equal the name set of
   a full walk (`scan --hash none`).

The same run shows the tuning working: `grace 1677 ms` after a 1118 ms bootstrap, then passes of 407 ms and 262 ms
once warm.

## Two guards that are not optional

- **Events during a git transaction are held.** A `*.lock` in `.git` means the tree is being rewritten, and a pass
  then would describe a half-written tree. The lock **poll** is authoritative: no lock present means the transaction
  is over. Clearing the latch only from a git-watcher delete event stranded it whenever `.git` is a *file* — which is
  every `git worktree`, including the benchmark trees.
- **A grace window after the last event** (2× the current quiet period) so a burst that is still arriving is not
  split. This is what keeps a long checkout to one publish.

## Current performance

Measured with [`../bench/bench.mjs`](../bench/bench.mjs) on the trees in [`benchmark.md`](benchmark.md), with the
matcher fixed (`globMatch` as a segment DP) and hashing enabled:

| tree                                           | warm pass      | cold pass | matcher off (same pass) |
| ---------------------------------------------- | -------------: | --------: | ----------------------: |
| Apache Fory (3881 entries, 50 `**` patterns)   | 103-109 ms     | 574.5 ms  | 68.1 ms (**1.6×**)      |
| jcodebuddy (1965 entries, 8,735 ignored files) | 57.7 ms        | 222.9 ms  | 228.5 ms (**0.25×**)    |


**Both trees are inside the 2× budget.** Fory: 103-109 ms warm against a 68.1 ms no-rule baseline
rules *save* time, because they prune a dependency tree (71.3 ms with, 101.0 ms without). The full tables and the
Full tables and the remaining items are in [benchmark.md](benchmark.md#current-numbers-2026-10-19).
The warm pass is 32% of the cold pass on jcodebuddy (71.3 of 222.9 ms) — the property an incremental
matcher is inside the 2× budget on a tree whose `.gitignore` is deliberately hostile.

## The two failures this design already paid for

Both were found by the live test, not by the unit tests, and both are recorded because they are the kind that
returns:

1. **Servicing only when a batch was taken.** `take()` clears the dirty flag, and the event it reports starts a
   *new* quiet period — so the pass becomes due on a later tick, when no event has arrived. Every batch after the
   bootstrap waited forever. The loop now services on every tick.
2. **A latched git transaction.** See above: the poll must be able to clear the latch, or a single checkout stops the
   watcher permanently.