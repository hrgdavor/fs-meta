# Git moves — correctness and cost of a **warm** start across a checkout

> **Status, 2026-10-19: the figures below are historical.** They were measured before globMatch was rewritten as
> a segment DP, before the engine actually hashed anything, and without a dependency tree in the fixture. The
> current numbers — and the reason the old ones are an order of magnitude slower — are in
> [watch-mode.md](watch-mode.md#current-performance). The method, the trees and the harness in this document are
> still the method; only the numbers moved.
A developer switches commits, and the trio on disk now describes the tree just left. The pass that follows is a
**warm** start — an existing generation is being reconciled with a tree that changed underneath it. That is the
same path a watcher will use on every save, so it is the path worth measuring. The cold start here is only
*setup*: it builds the trio, it is reported for reference, and it is excluded from the measured totals.

## The pairs

| Project     | Newer commit                                                | Older commit                                                         | Changed paths |
| ----------- | ----------------------------------------------------------- | -------------------------------------------------------------------- | ------------: |
| jcodebuddy  | `7bfad9a` *navigation alignment* (`main`, HEAD)             | `32478e7` *docs: the plugin must be REBUILT for Ctrl+click* (HEAD~6) | 99            |
| Apache Fory | `a11d257` *chore: Bump MessagePack from 2.5.301 to 2.5.303* | `7a68b8c` *chore: update release references to 1.7.7* (HEAD~6)       | 28            |

## The harness

[`../bench/git-moves.mjs`](../bench/git-moves.mjs) performs the sequence a person causes:

1. `git checkout <old>` — **bootstrap**: remove any trio, cold start, publishes generation 1. Setup, not measured.
2. `git checkout <new>` — **warm** `refresh` against a trio that describes the old tree: the reconciliation under
   test, and the number that matters.
3. `git checkout <old>` — **warm** `refresh` back: the same reconciliation in the other direction.

Correctness is asserted against an **independent oracle** after every pass: the trio's names from `files.txt`
must be exactly the name set of a full walk (`scan --hash none`), compared as sorted multisets. Every measured move
is also expressed as a fraction of the `bootstrap` of the same tree — so the warm-start benefit, or its absence, is
the headline rather than something to derive from two documents.

```text
bun fs-meta/bench/git-moves.mjs .tmp/head        7bfad9a 32478e7 --label jcodebuddy
bun fs-meta/bench/git-moves.mjs .tmp/bench/fory  a11d257 7a68b8c --label "Apache Fory"
```

## Results

jcodebuddy — 99 changed paths, 1961 names at the newer commit:

| step                                         | refresh  | vs cold | generation | names | added | removed | modified | trio == walk |
| -------------------------------------------- | -------: | ------: | ---------: | ----: | ----: | ------: | -------: | ------------ |
| bootstrap at `7bfad9a` (cold, setup)         | 187.4 ms | —       | 1          | 1961  | 1361  | 0       | 0        | yes (1961)   |
| checkout `32478e7` → refresh (**warm**)      | 194.0 ms | 104%    | 2          | 1953  | 0     | 8       | 91       | yes (1953)   |
| checkout `7bfad9a` → refresh back (**warm**) | 198.6 ms | 106%    | 3          | 1961  | 8     | 0       | 91       | yes (1961)   |

Apache Fory — 28 changed paths, 3881 names at the newer commit:

| step                                         | refresh   | vs cold | generation | names | added | removed | modified | trio == walk |
| -------------------------------------------- | --------: | ------: | ---------: | ----: | ----: | ------: | -------: | ------------ |
| bootstrap at `a11d257` (cold, setup)         | 4750.8 ms | —       | 1          | 3881  | 2887  | 0       | 0        | yes (3881)   |
| checkout `7a68b8c` → refresh (**warm**)      | 4646.1 ms | 98%     | 2          | 3879  | 0     | 2       | 26       | yes (3879)   |
| checkout `a11d257` → refresh back (**warm**) | 4751.3 ms | 100%    | 3          | 3881  | 2     | 0       | 26       | yes (3881)   |

## What the numbers establish

1. **Correctness holds in both directions on both projects.** Six passes, six name sets agreeing with the
   independent walk, and the counters are the git diff exactly: 99 changed paths produce `8 removed + 91 modified`,
   and moving back produces the mirror image `8 added + 91 modified`; Fory's 28 paths produce `2 + 26` and back.
   (The cold `added` count covers files only: `1361 files + 600 directories = 1961`, `2887 + 994 = 3881`.)

2. **The warm start currently buys nothing: 104–106% of the cold start on jcodebuddy, 98–100% on Fory.** These are
   the "existing cold start numbers" the benchmark records ([`benchmark.md`](benchmark.md): 176–192 ms and
   4.8–6.1 s), and a warm pass lands on top of them rather than below. Changing 99 files costs what discovering
   1961 costs; changing 28 costs what discovering 3881 costs. The warm pass re-lists every directory and repeats
   the per-entry work, so it is a cold start with a cache read in front of it.

3. **That is the defect, stated as a test rather than as a wish.** The purpose of this harness is to keep it
   visible: a warm start is supposed to be a fraction of a cold one — the difference being the publish and the
   discovery of names — and today the fraction is ~1.00. The acceptance criterion to adopt with the next engine
   change is written here: **a warm move under 25% of the cold baseline of the same tree**, with correctness still
   agreeing with the walk.

## Next

1. Instrument `refresh` per phase (list, stat, ignore, reconcile, publish) and re-run this harness and the
   benchmark; the per-phase numbers decide which of the four fixes in [`benchmark.md`](benchmark.md) to apply first.
2. Then the watcher, on the same pairs: start it at the older commit, `git checkout` the newer one **while it
   runs**, wait for the flush, and apply this same walk-oracle assertion to the trio the watcher produced. Two
   numbers to watch: flush latency after the checkout settles, and **one** publish per move (a publish per file
   event is the failure mode).
