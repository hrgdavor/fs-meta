# Benchmark — the engine against real trees

> **Status, 2026-10-19: the figures below are historical.** They were measured before globMatch was rewritten as
> a segment DP, before the engine actually hashed anything, and without a dependency tree in the fixture. The
> current numbers — and the reason the old ones are an order of magnitude slower — are in
> [watch-mode.md](watch-mode.md#current-performance). The method, the trees and the harness in this document are
> still the method; only the numbers moved.
Numbers, not impressions. The harness is [`../bench/bench.mjs`](../bench/bench.mjs); every figure below is a
median of five runs of the ReleaseFast build (`zig build -Doptimize=ReleaseFast`), on the machine that wrote the
reference, against trees checked out to the same volume as the engine so that no result is a cross-volume artifact.

```text
bun fs-meta/bench/bench.mjs <tree> --label "<name>" --repeat 5
```

Each run measures four consumer operations:

| Operation                | What it is                                                                                      |
| ------------------------ | ----------------------------------------------------------------------------------------------- |
| `refresh — cold`         | the trio is removed before the run: no `.fs-meta`, so the pass discovers the tree and publishes |
| `refresh — warm`         | the trio is exactly what the tree describes: the "nothing changed" pass                         |
| `verify`                 | read the trio and run every § 8 check — the reader's whole cost                                 |
| `scan — no hashing`      | the full walk (`Dir.iterate` + stat + identity per entry), no content read                      |
| `scan — content hashing` | the same walk, plus one wyhash pass over every regular file                                     |

## Trees

| Tree                         | Commit             | Files | Directories | Size    | Trio names | `meta` + `txt` + `json`   |
| ---------------------------- | ------------------ | ----: | ----------: | ------: | ---------: | ------------------------: |
| jcodebuddy (this repository) | `7bfad9a` (`main`) | 1361  | 600         | 17.0 MB | 1961       | 125,504 + 127,669 + 623 B |
| Apache Fory                  | `a11d257`          | 2925  | 1003        | 38.0 MB | 3881       | 248,384 + 210,599 + 630 B |

Both trees were checked out cleanly at a commit — a `git worktree` at HEAD and a shallow clone — so no uncommitted
file and no build output is in either. A second benchmark of the same repository with 2000 synthetic
`node_modules` files confirmed that excluded content costs nothing: the trio still held 1961 names.

## Results

jcodebuddy @ `7bfad9a` — 1361 files, 1961 names:

| operation                         | min   | median | mean  | max   | n   |
| ---------                         | --:   | -----: | ---:  | --:   | -:  |
| refresh — cold (no trio, publish) | 178.0 | 186.4  | 189.4 | 207.4 | 5   |
| refresh — warm (nothing changed)  | 164.1 | 176.2  | 175.3 | 182.8 | 5   |
| verify (validate the trio)        | 9.0   | 9.7    | 10.8  | 15.5  | 5   |
| scan — no hashing (full walk)     | 333.9 | 340.7  | 345.4 | 368.5 | 5   |
| scan — content hashing            | 338.6 | 358.8  | 360.6 | 388.8 | 5   |

Apache Fory @ `a11d257` — 2925 files, 3881 names:

| operation                         | min    | median | mean   | max    | n   |
| ---------                         | --:    | -----: | ---:   | --:    | -:  |
| refresh — cold (no trio, publish) | 5732.5 | 6089.6 | 6087.8 | 6402.3 | 5   |
| refresh — warm (nothing changed)  | 5767.2 | 5858.5 | 5865.2 | 5948.2 | 5   |
| verify (validate the trio)        | 9.9    | 12.2   | 12.6   | 17.1   | 5   |
| scan — no hashing (full walk)     | 6318.1 | 6431.7 | 6778.2 | 8054.4 | 5   |
| scan — content hashing            | 6327.2 | 6469.4 | 6488.7 | 6749.8 | 5   |

Per-file warm cost:

| Tree        | ms per file | files/s | warm / cold |
| ----------- | ----------: | ------: | ----------: |
| jcodebuddy  | 0.129       | 7725    | 95%         |
| Apache Fory | 2.003       | 499     | 96%         |


## Current numbers, 2026-10-19

Re-run after the matcher rewrite (`globMatch` as a segment DP), with hashing enabled and the jcodebuddy tree
prepared by `--prepare` so it carries a real `node_modules` (8,735 files, all ignored). Median of 3.

jcodebuddy @ `7bfad9a` — 1965 names:

| operation                        | median           |
| -------------------------------- | ---------------: |
| refresh — cold (publish)         | 222.9 ms         |
| refresh — warm (nothing changed) | 71.3 ms          |
| refresh — warm, gitignore off    | 101.0 ms         |
| refresh — cold, per-file stat    | 384.2 ms         |
| refresh — warm, per-file stat    | 228.5 ms         |
| verify                           | 9.6 ms           |
| scan — no hashing / hashing      | 309.7 / 330.5 ms |

Apache Fory @ `a11d257` — 3881 names:

| operation                        | median           |
| -------------------------------- | ---------------: |
| refresh — cold (publish)         | 574.5 ms         |
| refresh — warm (nothing changed) | 231.9 ms         |
| refresh — warm, gitignore off    | 78.0 ms          |
| refresh — cold, per-file stat    | 883.6 ms         |
| refresh — warm, per-file stat    | 541.1 ms         |
| verify                           | 10.7 ms          |
| scan — no hashing / hashing      | 707.3 / 752.1 ms |



**Final numbers for this round.** One more change — pruned anchored rules by their literal first segment — brought
Fory to **103-109 ms** warm against a **68.1 ms** no-rule baseline (**1.6×**, inside the 2× budget) and left
jcodebuddy at **57.7 ms** against **228.5 ms** without rules (**0.25×**). The whole arc, and the code for every
optimisation that produced it, is in [gitignore-and-optimisations.md](gitignore-and-optimisations.md).
**Update, later the same day.** Two more changes moved these numbers again, both measured the same way:
`globMatch` became a segment DP, and `**/pattern` is now normalised to the unanchored form it means — which
moved Fory's ~50 such rules out of the general-glob class into the indexed suffix/literal classes. The warm
pass is now **147.6–148.0 ms on Fory** against a **61–65 ms** no-rule baseline (**2.4×**, down from 2.97×), and
**58.9–60.1 ms on jcodebuddy** against **228.5 ms** without rules (**0.26×** — the rules prune 8,735 ignored
files, so keeping them is four times cheaper than listing without them). The remaining ~20% on Fory is the rules
that are still genuinely anchored (`x/**`, `a/**/b`), each of which still walks the ancestor prefixes.
**What changed, and what is still open.** Cold on Fory went from ~5,100 ms to 574 ms, and the warm pass from
~4,600 ms to 232 ms — the `globMatch` rewrite is the reason. But measured against the *same pass with the rules
off* (78 ms), the matcher now costs 154 ms on Fory: **~3× the baseline, not the 2× target**. The earlier "1.8×"
figure compared against a baseline taken in a different run and is not a like-for-like number. On jcodebuddy
the rules *save* time (71.3 ms with, 101.0 ms without) because they prune the 8,735 ignored files.

So the open item is precise: **Fory’s 50 `**` patterns still cost about twice what they should.** The next lever
is not `globMatch` (it is polynomial now) but the per-entry scan of non-literal rules: a suffix list for the
final segment and a wildcard list evaluated once per rule rather than per ancestor.
## Reproducibility check

The Apache Fory figures were measured twice, the second time after the freshly cloned tree had settled (the first
run followed the clone by minutes, so a cold file cache or real-time scanning of newly written files was a
candidate explanation for the high per-file cost). They agree:

| operation              | first run (median) | second run (median) |
| ---------------------- | -----------------: | ------------------: |
| refresh — cold         | 6089.6             | 5905.6              |
| refresh — warm         | 5858.5             | 5847.7              |
| verify                 | 12.2               | 10.1                |
| scan — no hashing      | 6431.7             | 6400.1              |
| scan — content hashing | 6469.4             | 6491.4              |

So the 15.5× per-file difference against jcodebuddy is a property of the code and of the tree shape, not of the
measurement: the same binary, the same volume, and two runs that differ by less than 4%.
## Batched listing versus a syscall per file

The listing is the one place where the engine has a platform-specific fast path: on Windows one
`NtQueryDirectoryFile` per directory returns every child with its mtime, size and `FileId`; the naive
implementation — `readdir` plus a `stat` (and an identity handle) per entry — is also available, forced with
`--per-file`, precisely so the two can be measured against each other. Same trees, same harness, same build.

| Tree                    | cold, batched | cold, per-file | effect   | warm, batched | warm, per-file | effect   |
| ----------------------- | ------------: | -------------: | -------: | ------------: | -------------: | -------: |
| jcodebuddy @ `7bfad9a`  | 191.9 ms      | 320.6 ms       | **−40%** | 177.9 ms      | 313.4 ms       | **−43%** |
| Apache Fory @ `a11d257` | 4792.4 ms     | 5024.4 ms      | −5%      | 4868.1 ms     | 4973.6 ms      | −2%      |

Both modes were also checked to produce **byte-identical** `files.meta` and `files.txt` (sha256 comparison): the
fast path is an optimisation, not a change of semantics. That is why it can be kept and measured, and why the flag
belongs in the engine rather than in a benchmark-only branch.

The two columns say different things, and both matter:

- On a **shallow** tree the batch is the difference between one listing per directory and a stat per entry: it
  removes 129 ms of 321 ms, i.e. 40% of the pass. This is the gain the design paper predicted, visible.
- On a **deep** tree with more `.gitignore` rules it removes only 232 ms of 5,024 ms. The per-file syscall is
  therefore **not** what costs five seconds on Fory — something else runs per entry and dominates it. That is the
  `.gitignore` stack (per entry, per ancestor, with a formatted path each time) and the reconciler's bookkeeping,
  which is exactly where the 15.5× per-file gap between the two trees points.

So the next optimisation is not in the listing. It is in the work the engine does per entry *around* the listing,
and the batched path is already as cheap as the platform allows.
## What the numbers say

1. **Validation is essentially free.** 10–12 ms to check a trio of ~4000 names, i.e. ~3 µs per name, including
   both whole-file hashes. The reader path is not where the time goes, so nothing about `verify` needs attention.

2. **The incremental pass has almost no advantage yet — this is the headline defect.** The warm pass costs 95–96%
   of the cold pass on both trees. A warm pass must be cheaper by the whole cost of publishing and of discovering
   names; it is not, so the current implementation pays the discovery cost on every run even when nothing changed.
   The design paper's target — "1.5 s full walk becomes 200 ms stat-only" — is therefore **not yet met**: the warm
   pass is 176 ms on 1361 files, which is the *same* as the walk minus hashing, not an order of magnitude less.

3. **The cost is per entry, not per byte.** Adding content hashing to the walk costs 5% (340.7 → 358.8 ms on
   jcodebuddy, 6431.7 → 6469.4 ms on Fory), so wyhash over 38 MB is noise. Whatever the per-entry cost is, it is
   syscalls and allocations, not hashing — which is also why "hash on demand" was the right architecture.

4. **Fory is 15.5× more expensive per file than jcodebuddy, on the same volume, with the same code.** That is the
   strongest signal in this document: the same operation, two trees, one order of magnitude apart. Fory is deeper
   (Java package paths), has larger directories, and carries a `.gitignore` with more patterns. Each of those
   multiplies a per-entry cost, which points at the code paths that run *per entry*, not per tree.

5. **The trio is compact**: 248 KB of `files.meta` for 3881 names, and 210 KB of `files.txt`, so a publish is
   cheap in bytes — the cold pass is dominated by discovery, not by writing.

## Where the per-entry cost most likely is

In descending order of expected effect, to be confirmed by measurement rather than by argument:

1. **The `.gitignore` stack walks the ancestor chain and allocates a path per entry per ancestor.** For every
   candidate entry, `ignore.ignored` formats `<relative dir>/<name>` into the arena and then, for each ancestor
   that owns a rule file, formats it again and runs the matcher. On Fory that is depth × entries allocations —
   with 1003 directories and Java-package depth the multiplication is large. The fix is a per-directory prefix
   held once per directory, and no allocation in the per-entry path.
2. **A directory's own identity costs three syscalls** (`lister.stat` opens the parent, stats the child, and opens
   a handle for the `fileId`). The parent's bulk listing already reported that directory's `FileId` and mtime, so
   cold start should take it from the listing and stat only the root.
3. **`containsName` is a linear scan** of the listing for each child, once per child — O(n²) inside a directory
   with many entries. A per-directory set would make it linear.
4. **`std.fmt.allocPrint` per entry** in `coldstart.childPath` and in the drop/rename bookkeeping.

## How to reproduce

```text
git -C <repo> worktree add --detach .tmp/head <commit>          # a clean tree at a commit
git clone --depth 1 https://github.com/apache/fory.git .tmp/bench/fory
bun fs-meta/bench/bench.mjs .tmp/head --label "jcodebuddy @ <sha>" --repeat 5
bun fs-meta/bench/bench.mjs .tmp/bench/fory --label "Apache Fory @ <sha>" --repeat 5
```

The harness prints a Markdown table ready for this document, and its last line reports what it measured. Re-run it
after a change; a warm pass that does not improve is a change that did not address the defect.

## Next

1. Fix items 1–4 above, then re-run both trees with `--repeat 9` and record the table here again.
2. Add a `--profile` mode to the harness that reports per-phase counters from the engine (directories listed,
   identities taken, entries filtered, hashes requested) so the next bottleneck is measured, not guessed.
3. Only then revisit the format questions in [`use-cases/01-on-demand-checks.md`](use-cases/01-on-demand-checks.md):
   a per-directory rollup, for instance, is worth discussing only once a warm pass is O(directories) rather than
   O(entries).