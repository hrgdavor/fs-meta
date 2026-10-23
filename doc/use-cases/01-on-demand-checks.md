# Use case 1 — on-demand checks over a tree

> **Status:** requirements, no implementation. **Scope:** a script that checks some property of files in a tree on
> demand (a linter, a link checker, a "generated file matches its template" verifier) and must avoid re-deciding
> what it already decided.
>
> **Related:** [`../../FORMAT.md`](../../FORMAT.md) § 6 (flags), § 11 (hash on demand), § 16 (socket, engine).

## 1. The situation

A script is asked to check a property of every file of some kind in a tree — say, that every Java source carries a
licence header, or that every Markdown link resolves, or that every generated file still matches its template.
The tree can hold on the order of 10⁵ files; a full pass costs seconds to minutes; a run is triggered by a save, a
commit or a developer pressing a button, so most runs see **nothing changed** since the previous one.

The cost that matters is not the check itself, which is fast per file, but:

- **finding the files** — a walk, and a `stat` per file, which is the cost [`coldstart.zig`](../../src/coldstart.zig)
  exists to avoid;
- **deciding again** what was already decided — re-reading content that has not changed, and re-running a rule
  whose answer cannot have moved.

Getting it wrong in the other direction is worse: skipping a file whose content *did* change means a broken file
is reported as checked. So the cache must be conservative: a false "recheck" costs time, a false "skip" costs
trust.

## 2. Questions the tool must be able to answer

1. For a given path, is there a verdict — and what is it?
2. Is that verdict still valid for the tree as it is *now*?
3. If not, what exactly invalidated it — the file's own content, its type, a rule that changed, or something the
   verdict was reading?
4. Which files does a verdict depend on, so that a change there reaches the verdicts that used it?
5. What can be decided from cheap facts alone (name, kind, size) and what genuinely needs content?

## 3. The tool's own cache

Per candidate file, one row. The first column is the key the tool thinks in, the last is the reason it exists.

| Field         | Value                                                                         | Why it is needed                                                                  |
| ------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `path`        | tree-relative, `/`-separated                                                  | the thing being judged, and the join back to the trio                             |
| `verdict`     | `applicable`, `not-applicable-by-type`, `not-applicable-by-content`, `failed` | the answer; the negative ones are as important as the positive one                |
| `reason`      | rule id (or the message key)                                                  | so a ruleset change can invalidate *only* what that rule decided                  |
| `content_key` | content hash + `hash_lf`, or `none`                                           | the identity a content-dependent verdict was computed under                       |
| `meta_key`    | `mtime_ns` + `size_bytes` + `file_id_lo`/`file_id_hi`                         | the identity a *cheap* verdict was computed under, and the pre-filter for content |
| `deps`        | list of `(path, content_key)`                                                 | what the verdict read besides the file itself                                     |
| `ruleset`     | tool version + rules version                                                  | a rule change is an invalidation source that has nothing to do with the tree      |
| `checked_at`  | the pass's timestamp                                                          | diagnostics, and to notice a cache that is never refreshed                        |
| `generation`  | the trio generation the row was last reconciled against                       | lets a recheck start from "which identities moved", not from "which files exist"  |

Two identities, not one, is deliberate: a verdict that depends only on the file's *kind* must never force a hash,
and a verdict that depends on content must never be trusted on `mtime` alone. The row records which identity it
was actually judged under, so the skip test in § 5 can be exact.

## 4. What the trio gives — and what must not go into it

The trio already carries every fact § 3 needs to compare against: `name`, `flags` (kind), `mtimeNs`, `sizeBytes`,
`contentHash` when a hash was taken, and `fileIdLo`/`fileIdHi`. It also carries, in `files.json`, the `generation`,
the `root` identity and the `hash` convention the hashes were taken under.

**What must not go into the trio:** the verdict, the reason, the rule version, the dependency list. Those are one
tool's opinion; a second tool checking a different property would have to rewrite the same file, the generation
would mix two tools' decisions, and `verify` could no longer tell a tree description from an opinion about it.

The trio therefore gives the tool:

- one **validated** description of the tree (§ 8), so the tool never walks or stats on its own;
- **identities** to key its verdicts by;
- a **generation** number, so two descriptions can be compared as snapshots.

## 5. Skip rules

The heart of the use case. Each row is "given this difference between the cached row and the current trio, may the
verdict be reused?".

| Situation                                                 | May skip?                                                 | Why                                                                           |
| --------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Row absent                                                | no                                                        | nothing was ever decided                                                      |
| Path gone from the trio                                   | row is dropped, not rechecked                             | the file is gone; nothing to judge (§ 11)                                     |
| `file_id` equal, path different                           | **yes**, and the row moves                                | it is the same file under a new name — a rename is not a content change       |
| Kind changed (`file` ↔ `dir` ↔ `symlink`)                 | no                                                        | a verdict about a file says nothing about a directory                         |
| `not-applicable-by-type` and the name suffix is unchanged | **yes**, always, with no hash                             | the decision was about the name's extension and nothing else                  |
| `not-applicable-by-type` but the suffix changed           | no                                                        | the type the rule keys on changed                                             |
| `content_key` present and equal to the trio's hash        | **yes**                                                   | the strongest possible equality; the bytes are provably the same              |
| `content_key` present, trio hash absent, `meta_key` equal | no — ask for the hash                                     | `mtime`+`size` is a pre-filter, not a proof (§ 11)                            |
| `meta_key` equal and the verdict is content-independent   | **yes**                                                   | the verdict never read the content                                            |
| `meta_key` differs                                        | no                                                        | something about the file changed; only a hash can say whether the content did |
| `ruleset` differs                                         | no, for the rows whose `reason` belongs to a changed rule | a rule change invalidates what that rule decided, and nothing else            |
| any `deps` entry differs (identity or presence)           | no                                                        | the verdict read that file; its answer may have depended on it                |

The ordering matters and is the first optimisation: **name and kind → size/mtime/fileId → content hash**, cheapest
first, so a tree that has not changed costs one comparison per row and no I/O at all.

## 6. Dependencies

A verdict may depend on more than its own file:

- **tree files** — an include, a template, a schema, a config inside the tree; identity is the trio's content or
  meta key for that path;
- **outside the tree** — a template shipped with the tool, an environment flag; identity is a version or a mtime
  the tool records itself, because the trio cannot describe what it does not contain;
- **the tool itself** — its version and the ruleset, which is the `ruleset` field.

Invalidation is **transitive**: if a template changes, every verdict that listed it as a dependency is invalid,
and a verdict may itself be a dependency of another (a "generated from" chain). The cache needs both directions —
`deps` on each row and a reverse index — or invalidation is a scan of every row.

## 7. Optimisations

1. **Generation diff.** Reconcile against the new trio by identity, not by path: iterate the trio once, look up
   each row's identity, and only the rows whose identity moved are candidates. Cost is O(entries), not O(files)
   with I/O.
2. **Cheapest-first ordering.** Type verdicts are decided from the name; size-only verdicts from the trio alone;
   only the residue needs a hash. In a typical tree the residue is a handful of files per run.
3. **Negative caching with the same discipline.** `not-applicable` is a verdict like any other, invalidated by the
   same identities. Without it, a tree of 10⁵ files where 10⁴ are applicable costs 10⁵ decisions forever.
4. **Bulk hash request.** Ask the engine for the hashes of just the residue — one request, one pass over the file
   set, no per-file round trip (this is the socket's first real customer).
5. **Reverse dependency index.** Invalidation of dependents is a lookup, not a scan.
6. **Rule-keyed invalidation.** A ruleset bump that only adds one rule invalidates the rows that rule could have
   decided, not the whole cache.
7. **Tombstones.** A file that disappears and reappears with the same identity keeps its verdict; a file that
   reappears with a different one is new. Cheap, and it makes a checkout-switch cheaper than a full recheck.
8. **Reject a foreign cache.** A tool cache is valid only for the same `root` identity (`dev`/`ino` of
   `files.json`); applied to another checkout it must be discarded, because the paths mean a different tree.

## 8. Questions for the format

1. **Where does the tool cache live?** Proposal: `.fs-meta/checks/<tool-id>.cache` — inside the trio's directory,
   which the walker already never lists, so a tool cache can never appear in the tree it describes. It is a
   *convention* on top of the format, not a format change; confirm before any tool writes there.
2. **Is `generation` enough to compare snapshots?** The tool stores the generation *and* the identities it judged,
   so it can diff two snapshots itself. No history is needed in the trio — a decision worth recording, because
   "keep the last N generations" would change the format and grow every publish.
3. **Does a hash have to be present for a content verdict to be skippable?** Under this document: yes — `mtime`
   and `size` are a pre-filter (§ 11), so a content verdict whose hash is unknown is a recheck that asks for the
   hash rather than a skip. The alternative (trust `mtime`+`size`) needs a flag in the cache and is a per-tool
   choice, not a format one.
4. **Should the trio expose a per-directory rollup** (a hash over a directory's child identities) so a large tree
   can be diffed subtree by subtree? It would cost one field in the entry and one publish-size increase; nobody
   needs it until a tree is big enough for O(entries) to hurt. No decision now.
5. **Is `hash_lf` (or the `normalize` convention) part of the cache key?** It must be: the same file hashed under
   `none` and under `lf` is two different hashes. The trio records the writer's convention; a tool cache must
   record the one its rows were computed under, and treat a convention change as a ruleset change.

## 9. Acceptance tests

These are the tests that would prove the use case; they are written before any implementation.

1. A tree checked twice, unchanged, results in **zero** checks on the second pass, and no hash request.
2. Touching a file without changing its content (`mtime` moves, `size` same) causes a **hash request**, and if the
   hash matches the verdict is reused: zero rechecks, one hash.
3. Changing a file's content rechecks **that file only**, plus its dependents.
4. Adding a file to a `not-applicable-by-type` extension rechecks nothing but that file.
5. A ruleset bump rechecks exactly the rows whose `reason` belongs to the changed rule.
6. A dependency change invalidates the dependents **transitively**, and nothing else.
7. Renaming a file keeps its verdict (same `fileId`), including a rename into another directory of the same tree.
8. Deleting a file drops its row; recreating it with the same content does not recheck it.
9. Applying the cache to a different checkout (different `root.dev`/`ino`) discards it.
10. A torn or absent trio falls back to a full check — the tool never trusts a cache it cannot reconcile with a
    valid generation.