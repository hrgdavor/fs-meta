# Worktrees and git-aware watching — support plan

**Status:** plan, not started. It supersedes the nested-roots *rule* decided in `plans/archive/daemon.md` § 16b (see
§ 6 below); the warning that rule produced stays in the code until M2 replaces it.
**Purpose:** make fs-meta safe around `git worktree`, and make the root watcher *git-aware*: a checkout, a branch
switch, a merge or a worktree add must be seen at its **start** and its **finish**, the pass must not run mid-write, and
a consumer must learn that git finished only after it has the batch that shows the result.
Research is § 1, the decisions already taken by the user are § 2, the git signal design is § 5b–§ 5h, the work is § 7.


## 1. What a worktree is, from the source

Facts below are from [`git-worktree(1)`](https://git-scm.com/docs/git-worktree) and
[`gitrepository-layout(5)`](https://git-scm.com/docs/gitrepository-layout), both read on 2026-10-26.

- A repository has one **main worktree** (unless bare) and zero or more **linked worktrees**. `git worktree add <path>`
  creates a working tree at `<path>` and an administrative directory `$GIT_COMMON_DIR/worktrees/<id>`; `<id>` is usually the
  basename of the path, suffixed with a number when taken.
- **Inside a linked worktree, `.git` is a plain text file**, not a directory, containing `gitdir: <path>` that points at
  `$GIT_COMMON_DIR/worktrees/<id>`. `$GIT_COMMON_DIR` then points back at the main `.git`. This "gitfile" mechanism is shared
  with **submodule checkouts**, so "a directory whose `.git` is a file" is not unique to worktrees.
- `$GIT_COMMON_DIR/worktrees/<id>/` holds `gitdir` (a text file with the absolute path back to the worktree's `.git` file,
  used to detect a manually removed worktree), optional `locked` (with a reason; prevents automatic and manual pruning and
  blocks `move`/`remove` without `--force` twice) and optional `config.worktree` (only read when
  `extensions.worktreeConfig` is on).
- **Relative links exist.** `git worktree add --relative-paths` (or `worktree.useRelativePaths=true`) writes a relative
  `gitdir:` and enables `extensions.relativeWorktrees`. A relative `gitdir:` must be resolved **against the worktree
  directory**, and relative `commondir` against `$GIT_DIR`.
- Enumeration is `git worktree list [--porcelain [-z]]`: one record per worktree, `worktree <path>`, `HEAD <sha>`,
  `branch <ref>` or `detached`, and the boolean attributes `bare`, `locked [reason]`, `prunable <reason>`. The porcelain
  format is stable across Git versions by contract.
- Lifecycle: `remove` (refuses an unclean worktree or one with submodules unless `--force`; the main worktree cannot be
  removed), `prune` (drops `$GIT_COMMON_DIR/worktrees/<id>` for missing working trees; also happens lazily under
  `gc.worktreePruneExpire`), `move` (refuses worktrees containing submodules), `lock`/`unlock`, `repair` (reconnect after
  a manual move of either side).
- **Refs are shared** (`refs/`, `packed-refs`, objects, hooks, `config` live in the common dir); `HEAD`, `index`,
  `logs/HEAD` and pseudo-refs are per-worktree; `refs/bisect`, `refs/worktree`, `refs/rewritten` are per-worktree
  exceptions.
- Git's own warning, verbatim: *"Multiple checkout in general is still experimental, and the support for submodules is
  incomplete. It is NOT recommended to make multiple checkouts of a superproject."*

## 1b. Git signals, from the source

Two kinds of signal, and they answer different questions. Facts from [`githooks(5)`](https://git-scm.com/docs/githooks) and
[`gitrepository-layout(5)`](https://git-scm.com/docs/gitrepository-layout).

**What the files say (always available, no cooperation needed):**

| path                                                                                                | tells us                                                                                            |
| --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `$GIT_DIR/HEAD`                                                                                     | branch switch or detached checkout — its content changes from `ref: refs/heads/x` to another ref or a 40-hex id |
| `$GIT_DIR/index`                                                                                    | the index was rewritten (checkout, merge, reset, `git add`)                                         |
| `$GIT_DIR/ORIG_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `REBASE_HEAD`, `BISECT_LOG`  | the **state** git is in: a merge, cherry-pick, revert, rebase or bisect is in progress or just finished |
| `$GIT_DIR/*.lock` (`index.lock`, `HEAD.lock`, `shallow.lock`)                                       | git is **mid-write** in this working tree: a pass now would describe a half-written tree            |
| `$GIT_COMMON_DIR/refs/**/*.lock`, `packed-refs.lock`                                                | a ref update is in flight — an event and a heuristic, **not** a reason to block another root's pass |
| `$GIT_COMMON_DIR/refs/**`, `packed-refs`                                                            | branches and tags changed — the durable record of a commit, merge, rebase, fetch                    |
| `$GIT_DIR/logs/HEAD`, `$GIT_COMMON_DIR/logs/refs/**`                                                | the reflog: what HEAD and each ref moved from and to, in order                                      |
| `$GIT_COMMON_DIR/worktrees/<id>/`                                                                   | a worktree exists; `gitdir` names its path, `locked` marks it as not prunable                       |
| `$GIT_COMMON_DIR/info/exclude`                                                                      | the repo-local ignore; fs-meta does not read it today, and **M1 makes it a source** (§ 5)           |

**What the hooks say (precise, but only if installed):**

| hook                    | arguments                                                                                     | what it gives us                                                               |
| ----------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `reference-transaction` | `<prepared\|committed\|aborted>` on the argument, ref updates on stdin as `<old> <new> <ref>` | **the best start/finish pair**: `prepared` is the start of a ref update and `committed`/`aborted` its finish, per ref and per worktree; **which operations actually fire it is what the M4 spike measures** (a checkout updates HEAD, which is not the same shape as a branch ref update) |
| `post-checkout`         | `<old-head> <new-head> <flag>` (`flag` 1 = branch checkout, 0 = file checkout)                | the finish of a checkout, with both heads — the direct "branch changed" signal |
| `post-merge`            | `<is-squash>`                                                                                 | a merge finished                                                               |
| `post-rewrite`          | `<amend\|rebase>`                                                                             | history was rewritten (amend, rebase)                                          |
| `post-index-change`     | `<lock-updated> <write-changed>`                                                              | the index was written — a readable start/finish heuristic even for `git add`   |
| `post-commit`           | —                                                                                             | a commit finished                                                              |

Hooks live in `$GIT_COMMON_DIR/hooks` — the common dir, shared by every worktree (`git-worktree(1)`), so one installation covers
all of them; `core.hooksPath` moves them elsewhere and, if set, ours would not run. Hooks are user code and a security
surface: installing one is an explicit, reversible act, never a side effect of `root add`.

**The two signals are complementary, not redundant.** The files always work (a root with no hooks, a repo the user will
not let us touch, a bare repo hosting worktrees), but they arrive as a stream of events whose *grouping* is guessed: a
`HEAD` write and an `index` write are one checkout only because they happen together. The hooks are exact — start,
finish, what ref, old and new heads — but they cost an install and a script per git operation. The design is: the files
are the baseline, the hooks are the precision upgrade, and both feed the **same** event type.

## 2. What the user has already decided (leading requirements)

**R1 — a nested repository is never scanned.** A directory that is a nested repository or working copy — a clone, a
submodule checkout, a linked worktree — is a boundary: the parent's walk does not descend into it, so a worktree is
never scanned twice, never lands in two trios, and never gets a `.fs-meta` written by its parent. This is a **scan
rule**, not a switch (§ 5h): it is what a trio *is*, and it holds whether or not fs-meta does anything worktree-aware.

**R2 — nesting is guarded, not warned.** A nested *root* (a path added to the daemon as a root of its own) must be
invisible to its parent's scan. For a repository that is automatic (R1); for a plain subdirectory — a root that is not
a repo, which no scan rule can exclude — the daemon writes the parent's **internal ignore** (`.fs-meta/ignore`), or
refuses the add with a clear error. It never warn-and-continues, because a visible nested root is exactly the collision
the guard exists to prevent.

**R3 — the root handler watches git's own files, and optionally its hooks, so checkouts, branch switches and worktree
adds are seen as they start and as they finish**, batched through the same scheduler as working-tree events (§ 5b,
§ 5c). Consumers receive start/finish events for git operations, and the ordering rule is: **a finish is never sent
before the `END_BATCH` of the pass that reflects it** (§ 5d) — a client that reacts to "finished" with a query must find
the work done, and must have its batch first.

**R4 — a worktree that is adopted as a root is seeded from the base root's trio**, not scanned cold: copy the trio,
publish a genesis from it, then let a normal pass publish the branch differences (§ 5e).

**R5 — the worktree *handling* ships behind switches, the *scan rule* does not.** `worktrees` (worktree recognition,
adoption, seeding, worktree events, the removal reaction) and `gitwatch` (the metadata watch, latch, events, hooks), per
root with daemon defaults, plus `FSMETA_WORKTREES=0` as an emergency override that wins over everything (§ 5h). Off
means no worktree-specific handling; the general rule — *a nested repository, worktree or not, is not scanned* — and the
nested-root guard stay on, because they are what a trio and a collision-free root set are, not features.

R1 and R2 replace the previous nested behaviour (`plans/archive/daemon.md` § 16b: allowed, warned, duplicates measured
at 10/10); R3, R4 and R5 are new. § 6 explains why the replacement is better and what it costs.

## 3. The tools landscape, and the caveats that reach us

**Observed in the field.** A recursive file watcher that had to handle "piled-up agent worktrees (a full repo copy
each)" reported the watch ballooning "to millions of dirs"; the fix was to discover nested repo/worktree roots **by
their `.git` marker** and prune each subtree from the watcher, plus static ignores for the conventions `.worktrees/`,
`.claude/worktrees/` and `.conductor/`, with caps and a 3 s deadline so the discovery cannot block watching
([superset-sh/superset #5693](https://github.com/ParadevAI/Paradev/pull/5693)). That is our problem verbatim, one
application layer up, and its PR is a checklist of what goes wrong: symlink cycles, paths containing glob magic
(a Next.js `app/[id]/` segment), and truncation behaviour when the discovery hits its cap.

**Tools that create worktrees.** `git worktree` itself (the only primitive), and managers on top of it: [`gwq`](https://github.com/d-kuro/gwq)
("Git worktree manager with fuzzy finder… perfect for parallel AI coding workflows"), agent harnesses that keep a
worktree per task under `.claude/worktrees/` or `.conductor/`, and editor integrations that list them. Jujutsu has the
comparable "workspace" concept, so any detection rule we write must be phrased as "a working copy with a marker",
not hard-wired to git's exact layout.

**Caveats that affect our listening and our scans:**

| caveat                                                              | consequence for fs-meta                                                                |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `.git` is a **file** in a linked worktree                           | our `reserved` rule already hides a `.git` *entry of either kind* (`lister.zig` `visible()`), so the marker is invisible to the scan — detection must look at the listing **before** the filter, or walk separately |
| `.git` file is also a submodule marker                              | a boundary rule catches submodules too; decided: the same rule (§ 8.1)                 |
| `gitdir:` may be **relative**                                       | resolve against the worktree dir before trusting it; do not assume absolute            |
| worktree metadata lives **outside** the tree                        | a worktree's own `.fs-meta` is the only thing we may write inside it; the common `.git` is never ours to touch |
| `git worktree remove` deletes the directory                         | the watcher's handle allows deletion (`FILE_SHARE_DELETE`), but `<worktree>/.fs-meta` is untracked and makes git refuse without `--force` or an `info/exclude` line; the daemon reacts to the disappearance (§ 5f) |
| `prune`/`gc.worktreePruneExpire` remove metadata for a missing tree | a served root can vanish without a `remove`: it became `missing`, and the daemon must not resurrect it |
| `move`/`repair` change paths                                        | the same tree gets a new id (the id is the canonical path's hash); the old root becomes `missing`, and § 5f is the policy |
| `locked` prevents pruning                                           | a locked worktree may be on a removable volume: `missing` is expected, not a fault     |
| refs are shared, worktree config is not                             | nothing for the trio (we read the filesystem, not refs), but it explains why two worktrees legitimately differ in content |
| Windows long paths                                                  | the plan adds no new path handling: the `.git`-file read and the hashed socket id are as long-path-safe as the rest of the engine, and M0 records the behaviour near `MAX_PATH` instead of claiming a fix |
| agent tools pile worktrees **inside** the repo                      | the balloon case: the parent's watcher must not descend, and the daemon must not start a watcher per worktree unless asked |
| `.git` contains `objects/` with thousands of directories            | watching it recursively is the inotify watch limit (ENOSPC); the metadata watcher must refuse to descend into `objects/`, `modules/` and `lfs/` (§ 5b) |
| `index.lock` is created and removed inside microseconds             | the lock is a "do not pass now" latch, not an event source; start/finish come from hooks or from the HEAD/ref timeline (§ 5b, § 5c) |
| hooks live in the **common** dir                                    | one install covers every worktree, including ones created later; `core.hooksPath` disables ours silently, so `hooks install` refuses when it is set (§ 5c) |
| a repo can be **bare** and host worktrees                           | there is no `.git` in the working copy; the worktree's `.git` file still points into the bare repo, so `$GIT_DIR`/`$GIT_COMMON_DIR` resolution must not assume `.git` is a directory |
| `git worktree add` runs no worktree-specific hook                   | detection is the `worktrees/` metadata and the new `.git` file; the checkout it performs *does* run `post-checkout`, which is a second route when hooks are installed (§ 5c). Measured in the closure batch (git 2.54): add fires ref transactions in both the parent and the new worktree plus `post-index-change`/`post-checkout`, but no hook carries the *worktree kind*; `remove` leaves at most one incidental `post-index-change "0 0"` line. The `worktree` event is therefore metadata-only in every configuration. |

## 4. How we learn that a worktree showed up

Three routes, in increasing scope. All of them confirm a directory only by reading its `.git` **entry** — a file for a linked worktree or a submodule, a directory for a nested clone:

1. **During a normal pass (the cheap one).** The lister already reads every directory's entries, and it has the `.git`
   entry in hand before filtering. A directory whose `.git` entry confirms (below), and is not the root itself, is a
   **boundary**. No extra I/O, no second walk. Excluding the subtree then costs nothing; the only question is what the
   trio records (§ 5).
2. **From the watcher (live).** A `created` event for a directory is checked the same way — the same two confirmations — because the event names a
   directory, not its contents. This is what
   makes a worktree that appears while a root is `watching` visible within one burst rather than at the next pass.
   **The one case the filter hides:** a `.git` entry created inside an *existing* directory (`git init` there, or
   `git worktree add` into an empty directory), because the working-tree watcher drops `.git` events. `noteEvent`
   therefore special-cases a `.git` creation — a rare, cheap path — and forces a pass, instead of waiting for the safety
   net (up to 60 s) to notice.
A directory carrying a `.git` entry that is *moved* into the tree arrives as a rename, not a creation, so the same
   special case covers `rename` when its destination is a `.git` entry.
3. **From the registry (across roots).** A worktree created *outside* the served root (`git worktree add ../feature`) is
   invisible to that root's scan; it is a new directory somewhere else. Only an explicit `root add` (or a future
   `root discover`) can bring it in. The plan does not pretend otherwise.

Confirmation, without running git: read `<dir>/.git`; it must start with `gitdir: `; resolve the path (against `<dir>` if
relative); the target must exist and be a directory. The **back-pointer** (`<target>/gitdir` naming `<dir>/.git`) is
confirmation *when it matches*, not a requirement: `git worktree repair` exists precisely because a manual move leaves
that back-pointer stale, and refusing such a `.git` would make a worktree fs-meta can otherwise describe invisible. A
mismatch is logged once and the boundary still counts. `git worktree list --porcelain` is the ground truth for **tests**,
not for runtime: the engine does not shell out to git, and a subprocess on the scan path would be a different decision
(it would also make `git` a hard dependency of a filesystem walk).

**A `.git` *directory* is a different confirmation.** A nested clone or a submodule checked out as a directory has a
`.git/` directory, not a file, and there is no `gitdir:` line to read. Confirm it by what makes a directory a
repository: `HEAD` is a file whose first line is `ref: …` or 40 hex characters, and `objects/` is a directory. Reading two
entries is enough; anything else (a directory that merely contains a file named `.git`, a fixture, a backup copy) is
**not** a boundary and is listed normally. False positives are worse than false negatives here: a misdetected boundary
silently removes a subtree from the trio.

**Symlinks are never followed**, as everywhere else in the lister: a symlink to a directory is an entry, not a
descent, so a boundary cannot be reached through one and a cycle cannot form.


## 5. What happens when we find one

**The rule is general, and it is not a worktree feature.** A directory that is a **nested repository or working
copy** — a clone (`.git/` directory), a submodule checkout, a linked worktree (`.git` file) — is a boundary: the walk
does not descend into it, and the trio describes the tree *except* those boundaries. A worktree is one case of the rule,
not the rule itself, which is why **the rule stays on when the worktree handling is switched off** (§ 5h): a trio that
descended into a nested repository would describe another repository's branch as if it were this tree's content, and a
served nested root would then be scanned twice. The same shape git itself uses for submodules (one entry, no contents).

**In the engine (`refresh`/`scan`), a boundary is not descended into, and the trio says so.** Two consequences, both
decided in § 8:

- **Format.** `files.json`'s `scan` block gains a boolean (`nested_repos`, default `true`). It says why a subtree is
  absent without growing: no boundary rule would, and a stored path list would be unbounded. The paths themselves are
  visible through `scan --json` and `fsmeta ignored` (§ 5g), never in the trio. It is a *record* of the rule, not a
  switch: no flag turns the rule off, because a trio that descended into a nested repository would not be describing
  one tree.
- **Compatibility.** A tree that contains a nested clone would publish fewer names than today, and `verify` must not
  call the new trio wrong. That is a format change: `FORMAT.md` § reserved names gets the rule, a conformance vector
  gets a nested repository, and the ports must tolerate the new `scan` key (they already keep unknown keys, per
  `json_doc.zig`). The **migration** is a first pass that deletes the previous trio's entries under a boundary: do not
  let that happen silently — when the previous trio has names under a boundary and the new pass removes them, the CLI
  says so once (`N names under nested repositories are no longer described`) and the daemon logs it, because a batch
  that deletes a subtree is the kind of change a consumer notices.

**In the daemon, a boundary needs no line: the rule already keeps it out.** The internal ignore exists for the other case — a nested *root* that is **not** a repository (a plain subdirectory), which nothing but an ignore rule can exclude. R1 and R2,
as work:

- the parent's **internal ignore** is a file fs-meta owns: `<root>/.fs-meta/ignore`, one root-relative path per line,
  gitignore syntax, read by the engine *in addition to* the user's `.gitignore` chain. It must be parsed by the **same
  `gitignore` reader** as every other pattern source — not a second matcher — so a path with spaces, `[id]`, `!` or a
  trailing slash behaves exactly as it does in `.gitignore` (the one-wildcard invariant in `AGENTS.md` § 2). It lives in
  our own directory, so writing it is not a write into the user's tree, and it survives restarts. A malformed line is a
  logged skip, never a failed pass.
- **Git's own internal exclude is read as a second source.** `<common>/info/exclude` is the repo-local, untracked
  exclude file (`gitignore(5)` notes that `status`/`add`/`rm`/`clean` honour it) and fs-meta does not read it today. It
  joins the same chain, from the same matcher, in the same pass: a user who already ignores a path there sees it
  excluded like any other ignore source, and a `git worktree add` flow the user set up by hand works unchanged.
  This does make the trio's content depend on a file **outside** the working tree (`<common>/info/exclude`), which
  is the same dependency git itself has: it is recorded in `scan.ignore_sources`, and two checkouts of one commit with
  different internal excludes legitimately have different visible sets.
  `core.excludesFile` (the global ignore) is **out of scope**: it is a per-user file that can change under a root and
  would make the trio's content depend on the machine.
- **Precedence and no cross-source negation.** The sources are the root's `.gitignore` chain, `.git/info/exclude`, and
  `.fs-meta/ignore`, in that order. Each is evaluated with git's own rules; a **negative** pattern (`!`) inside one source
  affects only that source. Otherwise a user's `!worktrees/` in `.gitignore` could re-expose a nested root that the internal ignore keeps
  out, which is the collision R2 exists to prevent. `.fs-meta/ignore` may still contain `!` for its own entries.
- **How the managed lines are written.** Root-relative, `/` separators, with gitignore's escapes for a path that
  starts with `!` or `#` or ends in a space; a path containing a **newline** cannot be represented in a line-based
  file, so `root add` refuses such a path (a newline in a workspace root is not a case worth representing). The
  managed block is evaluated **last within its own file** — the daemon parses it as a separate sub-source after the
  user's lines — so a user's `!` in `.fs-meta/ignore` cannot re-include a nested root, while a `!` in the block itself
  still can (our own escape hatch). `fsmeta exclude` appends at the end of `info/exclude` and documents that a *later*
  `!` in that file would override it; the next reconciliation repairs a block that was edited away.
**The block is written atomically** — a temp file beside `.fs-meta/ignore`, then a rename, the same discipline as
`roots.json` — because a control-task write can race a pass that is reading the file under the parent's lock; a
half-written ignore would silently drop every managed line after the tear. `fsmeta exclude` writes its block in one
call for the same reason.
- **`--no-gitignore` does not disable the guard.** The flag disables the user's chain (and `info/exclude`, which is
  git's own); the boundary rule and `.fs-meta/ignore` still apply, because they are what keeps a served nested root out
  of its parent. A flag that silently re-enabled duplicate scanning would make two writers produce two different trios
  from one tree (`fsmeta refresh --no-gitignore` versus the daemon), which is a worse surprise than a listing that
  ignores more than asked. Undoing the guard is done by removing the nested root, not by disabling the rule.
- **Every source is recorded and reported**, so "why is this name absent" is answerable: `files.json`'s `scan` block gains
  `nested_repos` (bool) and `ignore_sources` (the list of sources actually consulted, e.g. `["gitignore","info/exclude","fs-meta/ignore"]`).
  The *current* state is reported by `scan --json` and `fsmeta ignored`, not by `verify` (§ 5g). A source that does not exist (`info/exclude` absent, `.fs-meta/ignore` absent) is omitted: the list says what was
consulted, not what was configured, so a missing file is visible as an absent name rather than a stale entry. Additive keys only — a
  reader that does not know them keeps working (`json_doc.zig` preserves unknown keys).
- `root add <path>` inside a served root: append the path to the parent's `.fs-meta/ignore` (idempotent: an exact entry
  is a no-op), force one parent pass, and only then serve the child; if the append fails, refuse with exit 4 and a
  message that names the file and the parent — **never** warn-and-continue (R2). This is not gated: it is a collision
  invariant, and a root inside another root is exactly the case R1 exists for, worktree feature or not.
  The parent is passed **once**, even if it is `asleep` or `off`, because the ignore must take effect in its trio;
  the pass arms no watcher, so a sleeping parent goes back to sleep. A seed needs nothing from the base's state but
  its trio on disk, so a sleeping base is fine too.
  The visibility check is **single-path**, not a scan: evaluating one relative path through the parent's ignore chain
  means reading the `.gitignore` files along that path (bounded by depth), never walking the tree — otherwise `root add`
  would cost a full pass of the parent just to decide where to put one line.
- worktree discovery (route 1/2) does the same for the boundary, then either leaves it alone (default) or adds it as a
  root (`--on-worktree serve`, opt-in, recorded per root in `roots.json`), because a watcher per agent worktree is exactly
  the balloon the field report describes. Default is **ignore only**; discovery *reporting* and adoption are under
  `worktrees` (§ 5h), the boundary itself is not.
  The policy belongs to the **discovering root** (the parent whose pass found the directory): `--on-worktree serve` is
  set there, not on the child that does not exist yet. With `gitwatch` off, adoption still works at pass time — the
  tree watcher sees the new directory and the next pass judges it — but **no `worktree` event is sent**, because the
  event needs the git signal. The full matrix is in § 5h.
- removal follows the tree: a nested *root* that disappears has its managed line removed at the next reconciliation — on
  `root remove`, at daemon start, or when a pass finds a stale entry (a boundary needs no line: the rule excludes it); a
  served worktree that disappears becomes `missing` (§ 2b of `FORMAT.daemon.md`), and `root remove`/`reap` handles it
  like any vanished root. § 5f is the removal path in detail.
- **The reverse direction is the same rule.** Adding a root that *contains* already-served roots must hide those
  children in the new parent: the daemon writes one managed line per served descendant before the parent's first pass,
  and refuses if it cannot. At start, every served root's managed block is **reconciled** the same way — a pair can
  enter `roots.json` by hand or by an older version — and a block that was deleted or edited is repaired when a pass
  finds a served child visible to its parent, because the invariant is the daemon's, not the file's. `root remove`
  removes the child's line; a stale line for a path that no longer exists is harmless and the next reconciliation drops
  it.

**The ports are readers, but they also carry writer code** (`FsMetaWriter.publish` in Java, the JS write paths), kept
behind the port-writer gate. A port writer that does not implement the boundary rule must not claim it:
`scan.nested_repos` is written `true` **only by the reference engine**, and **absent means "the rule was not applied"**
— a reader may not infer the rule from an old trio. The ports' gated writer tests are where that stays honest (M0).

### 5b. The git watch set: which files, and how they are watched

**The root handler watches git's own state, not just the working tree.** For every served root that is inside a git
working copy, resolve two directories (per pass, not once — see below):

- `$GIT_DIR` — from the `.git` file's `gitdir:` line (linked worktree/submodule) or `.git` itself;
- `$GIT_COMMON_DIR` — `$GIT_DIR` unless a `commondir` file (relative to `$GIT_DIR`) names another.

**One metadata watcher per common dir, not per root.** The common dir is shared by every worktree, so a served main
worktree and three served worktrees of the same repo resolve to the same `$GIT_COMMON_DIR`; arming one watcher per root
would register the same `refs/` tree four times and deliver four copies of every ref event. **The arm is the common dir
alone**, because everything else is inside it: a linked worktree's `$GIT_DIR` is `<common>/worktrees/<id>/`, a
submodule's is `<common>/modules/<name>/`, and the main worktree's is the common dir itself. So `$GIT_DIR` is either equal
to or below `$GIT_COMMON_DIR`, and the daemon keys one watcher by the common dir, then maps each event to roots by path
prefix (a table substitution, not a second watch). If a root's resolution changes, only its prefix mapping changes; the
watcher is re-armed only when the common dir itself changes.
The arm is **refcounted** by the roots that resolve to it: the last root of a repo to go disarms it, or a removed
repo keeps a watcher (and its handles) for the life of the daemon. M3 tests add-two-remove-one (arm stays) and
remove-the-last (arm gone).

Then watch this set, and **nothing else** in git's directory:

| watched                                                       | why                                                                                           |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `$GIT_DIR/HEAD`, `ORIG_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `REBASE_HEAD`, `BISECT_LOG` | branch/checkout change, and "git is in the middle of a merge/rebase/cherry-pick" |
| `$GIT_DIR/index`                                              | the index was rewritten (checkout, merge, reset, `git add`)                                   |
| `$GIT_DIR/*.lock` (`index.lock`, `HEAD.lock`, `shallow.lock`) | git is mid-write in **this** tree: do not pass **this root**                                  |
| `$GIT_COMMON_DIR/refs/**/*.lock`, `packed-refs.lock`          | a ref update is in flight — an event and a heuristic, never a pass blocker for a sibling root |
| `$GIT_COMMON_DIR/refs/`, `packed-refs`, `logs/refs/`          | branch/tag updates (commit, merge, rebase, fetch)                                             |
| `$GIT_COMMON_DIR/worktrees/`                                  | a worktree appeared, moved, was locked or pruned                                              |
| `$GIT_COMMON_DIR/info/exclude`                                | the repo-local ignore file (see § 8.3)                                                        |

**Not watched:** `objects/`, `modules/`, `lfs/`, `hooks/`. They are large, they change on every fetch/commit, and none
of them changes what a trio describes. **Skipping them is guaranteed on the per-directory backends**, including
inotify: `INotify.zig` never calls `should_watch` itself, but nightwatch's generic layer does — `recurse_watch` asks
`backend.handler.should_watch(sub, .dir)` before every `add_watch`/recursion (`nightwatch.zig:362-363`) and the
interceptor asks for a directory created later (`nightwatch.zig:271-272` and `:319-320`);
`filters_watches = !watches_recursively` (`:128`). So on Linux the arm registers the common dir plus the admitted
metadata directories, and `objects/`, `modules/`, `lfs/`, `hooks/` are never registered *or opened*. The earlier claim
that "inotify ignores the predicate" was about the backend file and was wrong: only `KQueue.zig`/`KQueueDir.zig` call
it directly, because they are a shortcut, not the contract. The one-handle backends (ReadDirectoryChangesW, FSEvents)
never consult it — one registration covers the whole subtree — and there the handler filter does the same work.

**How.** `nightwatch`'s public `watch(path)` is recursive-only and takes no ignore set, but its handler exposes a
`should_watch` predicate. The metadata arm passes `gitwatch.shouldWatch`; the consequences are:

- **Windows, macOS**: the subtree is one handle or one FSEvents stream; the handler filters `objects/`, `modules/`,
  `lfs/`, `hooks/` and the cost of registering is negligible.
- **Linux, kqueue**: the generic layer consults the predicate at arm time and for a directory created later, so the
  watch set is bounded by the metadata directories. `test/watch-bound.test.mjs` asserts the count on Linux (the only
  backend where a per-directory count is meaningful) and skips with its reason elsewhere; the number is produced by
  Linux CI, not by this Windows host.

**The tree arm wants the same predicate, and has it.** `gitwatch.shouldWatchTree` admits the served root (which may
itself be a worktree), refuses `.git`/`.fs-meta` and a confirmed boundary, admits a stray `.git` fixture, and reads a
gitfile from a fixed stack buffer on the watcher's thread (no shared allocator, no root mutex). A backend that honours
the predicate therefore never registers a nested repository. A boundary discovered *after* the arm (`git worktree add`
while watching: the directory existed before its `.git`) cannot be pruned at registration time, so the daemon
**re-arms the root's watcher once** when a pass reports a higher boundary count; the predicate then applies to the new
shape. On Windows the single recursive registration is not pruned either way, and the handler filter keeps the cost
flat.

**Batching (this is the part that must not be improvised).** Git metadata events join the **same** scheduler as working
tree events: `scheduler.noteEvent` for the burst, one pass when quiet. Three extra rules:

1. **A pass must not start while *its own tree* is mid-write.** `src/main.zig` (the watcher prototype) already
   implements this latch for a main worktree: a `*.lock` in `.git` sets `in_git_tx`, a flush is refused while a lock
   exists, and the lock is re-checked by polling (`hasGitLock`) so a missed delete cannot strand the latch. That is the
   seed of M3, with two corrections the worktree case forces: the lock set is **per root** (`$GIT_DIR/index.lock`,
   `HEAD.lock`, `shallow.lock`), so a commit in worktree A does not block B's pass through a shared
   `refs/heads/x.lock`; and the dir is resolved from the gitfile, not assumed to be `.git`. Its documented bug is the
   caveat to carry over: *"clearing this from a git-watcher delete event stranded the latch whenever `.git` is a file (a
   git worktree), because then no git watcher exists at all"* — the worktree case is the normal case now, so the latch
   is cleared by the poll, never by a delete event.
**Lifting the latch means retiring the prototype's copy.** `src/main.zig` is a prototype, not the daemon; leaving a
second implementation of the same latch would guarantee drift. M3 moves it into `RootRuntime` and thins the prototype to
the debouncer it still is (or deletes it if nothing else needs it), with "the prototype's `hasGitLock` is gone" as an
acceptance line — the plan already says that, and this is why.
2. **A finished operation is a flush trigger.** Metadata events force the quiet period to end as soon as no lock is
   present (subject to the existing floor), so a checkout is published as one batch, not one per written file.

3. **A git finish forces a pass even with no file events.** `git commit --amend`, a branch switch to identical content,
   or a `git add` that leaves the tree as it was produce a finish and *no* working-tree event: without this rule the
   deferred finish would wait for a burst that never comes. A hook finish (and a metadata-derived one) therefore calls
   `noteEvent` and flags the root for a pass; if the pass publishes nothing it still completes and the finish follows it
   (§ 5d rule 3).

**Resolve the git dirs per pass, not once.** `.git` is invisible to the working-tree watcher (reserved name), so a root
that becomes a worktree, or whose `gitdir:` changes (`git worktree repair`, a moved repo), would never be noticed by a
one-time resolution. The pass already stats the root; statting `<root>/.git`, resolving `git_dir`/`common_dir` and
comparing them with the armed mapping is free: a different common dir re-arms the watcher, a different `git_dir` only
re-maps the prefix. A root with no `.git` at all is fine: no metadata watch, no git events, behaviour unchanged. A root
that *is* a git directory (a bare repo) is out of scope — there is no working tree to describe — and the resolution must
not mistake its `HEAD` for a checkout.
A **broken link** — the `gitdir:` target is gone, or `commondir` names a missing directory — is not a failed pass: the
root keeps scanning, the mismatch is logged once, and it has no git handling until the link is repaired (`git worktree
repair` is the user's tool, and the next pass re-resolves). Showing an error every tick for a state the user can only
fix from outside would be noise, not a diagnosis.

**Tree-changing signals versus repo-wide signals.** The split is by **path**, not by directory identity, because the
main worktree's `$GIT_DIR` *is* the common dir:

- a root's **tree-changing set** is its `$GIT_DIR` files — `HEAD`, `index`, `ORIG_HEAD`, `MERGE_HEAD`,
  `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `REBASE_HEAD`, `BISECT_LOG`, `logs/HEAD` — and a change there is a reason to pass
  **that root**;
- everything else under the common dir (`refs/`, `packed-refs`, `logs/refs/`, `worktrees/`) is **repo-wide**: a commit
  in worktree A moves refs that worktree B also sees, but B's tree did not change. A repo-wide signal is an **event for
  every served root of the repo** and a **pass only for the root whose tree set also moved** (or whose checkout is still
  settling). A pure `git gc`/`packed-refs` rewrite is then an event with no pass, which is exactly right.

**An ignore-file change must reach a pass.** `info/exclude` and `.fs-meta/ignore` decide which names exist, so an edit
must produce a pass that adds or removes the affected entries — otherwise the trio stays wrong until an unrelated file
moves. There is no state to record for this: the engine re-reads both files on **every** pass (it has to, to apply them),
so a pass is all that is missing, and two things provide one. `info/exclude` is in the common dir, so the metadata watch
sees the edit directly. `.fs-meta/ignore` is dropped by both watchers (`.fs-meta` is never an event), so a hand edit is
picked up by the next pass — bounded to `safety_pass_interval_ms` (60 s, § 2b of `FORMAT.daemon.md`) by the safety net (and the metadata arm has the same failure mode as the tree watcher: nightwatch ends its thread on a failed completion,
so the safety pass re-arms **both** arms when it finds a change, not only the tree watcher)
that already exists — while the daemon's own writes force one immediately (M2). No mtime in `scan`, no new trigger.

**Lock files are a latch, not an event source.** `refs/heads/x.lock` lives for microseconds; an event stream may miss
it entirely. That is why start/finish *events* come from hooks when they are available (§ 5c) and from the file
timeline otherwise — the lock's only job is "do not pass now".

### 5c. Hooks, as an option

Hooks are opt-in per repository, installed by an explicit command, never by `root add`:

```
fsmeta daemon hooks install <root> [--force]     # writes the wrapper set into $GIT_COMMON_DIR/hooks
fsmeta daemon hooks uninstall <root>
fsmeta daemon hooks status [--json]
```

- **Which hooks:** `reference-transaction`, `post-checkout`, `post-merge`, `post-rewrite`, `post-index-change` (and
  `post-commit` only if the ref transaction turns out to be too coarse). `reference-transaction` is the backbone: it
  is the start/finish pair the user asked for **where it fires** (per ref, per worktree, with both object ids and the
  `prepared`/`committed`/`aborted` state); **which operations fire it — a checkout updates HEAD, a commit updates a
  branch — is exactly what M4's spike measures before the design depends on it.** It needs git 2.28 and
  `post-index-change` 2.20; on an older git the file simply never runs, which is why the spike records the git version.
- **What they do:** append one JSON line to a **per-repo spool, `<common>/fsmeta-events.log`**, with the hook name, the
  phase, the arguments, the worktree path (so the daemon can attribute the event to a root) and the timestamp, then exit
  0 immediately. No socket from a shell script, no dependency on the `fsmeta` binary being on `PATH`, and nothing that
  can block git. The file is inside git's private state, not the user's tree: it exists for every worktree of the repo
  without creating a `.fs-meta` in a directory fs-meta does not serve, it survives `git worktree remove`, and the daemon
  reads it per common dir (the same key the metadata watcher uses) on its tick. **Each root reads the file for itself**
  — a per-root offset over one per-repo file, because the tick and the delivery are per root and the mailbox is a few
  hundred lines, so no lock across roots is needed; a root that joins later starts at the current end. The script finds the spool directory with one cheap `git rev-parse --git-common-dir` call rather than an embedded path,
  so a moved or repaired repo keeps working (a failure exits 0 silently). The call asks for an **absolute** path —
  `--path-format=absolute` (git ≥ 2.31) or, on older git, prefixing the printed dir with the worktree root — because
  `--git-common-dir` prints `.git` relative to the cwd, and the script does not control its cwd. A repo's spool is read only while at least one
  served root of that repo has `gitwatch` on; otherwise the file sits at
  its cap until someone does, which is exactly what the hook's own truncate is for. The line is JSON with the worktree path **string-escaped**, because the spool is line-based: a path with a newline is
  escaped, not embedded raw (where the managed ignore block must refuse such a path, the spool can escape it). A per-root spool was considered and
  rejected: the hook runs in whichever worktree git is operating on, which may be one fs-meta has never seen.
- **The hook must never fail git.** This is not a style preference: a non-zero `reference-transaction` hook **aborts the
  ref update**, turning a broken spool write into a failed `git commit`. Every generated hook therefore ends with
  `exit 0` on every path (including a missing spool directory), uses `printf >> ... 2>/dev/null || true`, and must not
  call anything that can block (no lock acquisition, no `fsmeta` spawn). The wrapper also sets a trap so an unexpected
  shell error still exits 0.
- **Windows needs POSIX sh and LF.** Git on Windows runs hooks through its bundled `sh`, so the generated script is
  `/bin/sh` with **LF** line endings (CRLF makes sh fail with `\r: not found`), and on POSIX it gets the executable bit.
  The tests must assert the bytes, not just the content, because a checkout with `core.autocrlf` would otherwise rewrite
  them.
- **The spool is bounded and dated.** Lines carry a timestamp; the daemon discards lines older than its own start (a hook
  that fired while no daemon was running must not replay as a fresh event) and rotates the file when it exceeds a cap (a
  few hundred lines) before reading. A spool is not a log to keep: it is a mailbox. **The hook also caps it** — a size
  check and a truncate before appending, both `|| true` — because a repo can go without a daemon for months, and an
  unbounded file inside `.git` is not acceptable.
- **Safety:** a hook that exists and is not ours is never overwritten — `install` refuses, `--force` renames it to
  `<name>.fsmeta-orig` and writes a chaining wrapper that calls the original with `"$@"` (so a user's existing
  `post-checkout` keeps working). `uninstall` restores the original. Every generated hook carries a `# fsmeta-managed`
  marker and refuses to run if the marker is missing (a user edit).
- **Shared by worktrees:** hooks live in the common dir, so one install covers every linked worktree of the repo —
  including a worktree created later, which is why a new worktree's checkout is seen even before its root exists.
- **Install is a local file operation, not a control request.** It resolves the git dirs from the path it is given, so
  it works with no daemon running, and `hooks status` reads the hook files and the spool size. The spool line carries an
  **epoch-seconds timestamp from POSIX `date +%s`** (portable to the sh git bundles; `%3N` is not), and `install` checks
  that `<common>` is writable before it writes anything — a read-only `.git` means no hook reporting, and saying so at
  install time beats a hook that silently never writes.
- **What each event means, and what it does not.** A `refs/heads/*` update maps to `commit`; a `HEAD` symref update to
  `branch`; `refs/stash`, `refs/notes` and `refs/remotes` to `other`; `post-checkout`'s flag picks `branch` (1) or
  `checkout` (0). `post-index-change` fires whenever the index is **written**, which a plain `git status` can do while
  refreshing racy stat data — so an `index` event says "the index was written", not "content changed". The per-pass
  coalescing keeps such noise to one event, and the docs say so rather than implying a change.
- **If `core.hooksPath` is set**, ours would not run; `install` detects it and refuses with the path in the message,
  rather than installing hooks that never fire.

### 5d. Git events on the wire, and the ordering contract

Consumers get a new frame, interleaved between batches and never inside one:

| kind   | name        | payload | notes                                       |
| ------ | ----------- | ------- | ------------------------------------------- |
| `0x0A` | `GIT_EVENT` | `u8 phase` (0 = start, 1 = finish, 2 = aborted), `u8 kind` (0 = branch, 1 = checkout, 2 = commit, 3 = merge, 4 = rebase, 5 = index, 6 = worktree, 7 = other), `u8 source` (0 = metadata, 1 = hook), `u8 status` (0 = ok, 1 = our pass failed, 2 = timed out), `u64 head_batch` (0 for a start), then **only for `kind = worktree`** a `u32 path_len` and the UTF-8 path of the worktree | 20 bytes, or 24 + path for a worktree event |

**`branch` and `checkout` are the two `post-checkout` cases**, so the mapping is not a guess: `flag = 1` (a branch
switch) is `branch`, `flag = 0` (files checked out) is `checkout`. When the signal comes from the metadata timeline
instead, a `HEAD` whose content changed from one ref to another is `branch`, and an `index`-only change with the same
`HEAD` is `checkout`.

**Only `worktree` events carry a path.** A branch event is about *this root's working tree*, and the root is the
connection; a worktree appearing or disappearing is a fact about the repository, which the root's stream cannot name
otherwise. So the frame is variable-length exactly there, and the length check is part of the parse (`kind = worktree`
⇒ at least 24 bytes; every other kind ⇒ exactly 20). The reader also checks `path_len ≤ length − 24` before slicing the path, because a frame is a length, not a promise. **`path_len` may be 0 when the path is no longer knowable** — a
`git worktree remove` deletes the metadata that held it, and a `prune` is noticed after the fact — so the consumer must
treat an empty path as "a worktree left this repo", not as a malformed frame. Worktree events go to **every served root
of that repo**, because the worktree belongs to the repo, not to one root; the root-specific events never do. `roots
list` still shows whether the worktree is served — the event says it exists, the registry says what we do about it. The phases are defined: **start** when `<common>/worktrees/<id>` appears, **finish** on the new worktree's
`post-checkout` (hook source) or, without hooks, when a pass finds the directory confirmed and its mtime stable
(metadata source) — a heuristic, and labelled as one by `source = metadata`; a **removal** is a single finish with
`path_len = 0` when the path is no longer knowable.
**Scoping, and what `head_batch` means for these.** Worktree events go to every served root of that repo **that has
`gitwatch` on** — a root with the flag off receives no `GIT_EVENT` at all, because its flag says no git handling — and
nothing was published for the receiving root by a repo-wide event, so its `head_batch` is **that root's current head**,
not a generation the event produced. A consumer must not read it as "a batch you can fetch".

Adding a frame is a protocol change: `protocol` moves to `0x0102` when this lands, `FORMAT.socket.md` gets the kind and
the tables, and the daemon's `STATE`/consumer tests start asserting the new pin. (The alternative — treating it as "still
0x0101, no deployed clients" — was the argument for `STATE`; it does not stretch to a second addition, because a reader
that meets `0x0A` must be able to say "I do not know this frame".) `serve` bumps with it: `wire.protocol` is shared, so `fsmeta serve` announces `0x0102` and simply never emits
`0x0A` or `0x09` — the same asymmetry `STATE` already has, stated in one line in `FORMAT.socket.md`.

**The ordering contract, which is the point of the design:**

1. **Start has no constraint.** `GIT_EVENT(start)` may be written before or after the `START_BATCH` of the pass that is
   running. A consumer that queries on start may see a half-written tree; that is what "start" means.
2. **Finish is written only after the pass that reflects it has been published.** Concretely: the pass commits the trio
   (`engine.refresh`), the daemon broadcasts `START_BATCH`/`CHANGE_ENTRY`*/`END_BATCH` to every subscriber, and only then
   writes `GIT_EVENT(finish)` to each of them. Per connection the frames are ordered, so the sequence is
   `START_BATCH … END_BATCH`, then `STATE` if that pass emits one, then `GIT_EVENT(finish)` — **every client receives its
   own `END_BATCH` before the finish**; and because the trio is committed before the batch, a query that happens after
   the finish (a CLI reading the trio, a consumer asking for a path) sees the finished state. That is the user's
   requirement exactly: *a hook-triggered consumer query must find the work done, and no client may hear "finished"
   before it can see the result.* The guarantee is about those frames; `PING`/`PONG` and anything else may interleave.
3. **A pass that publishes nothing still precedes its finish.** If a checkout lands on identical content, the finish is
   emitted after the pass completed (no batch to precede it); the guarantee is "never before the pass", not "always a
   batch".
4. **Batched operations finish in order.** One pass may cover a checkout followed by a commit: both finishes are written
   after that pass, in the order their signals arrived, each carrying the same `head_batch`.
   **Coalesce per kind within a pass.** A `git fetch`, a `push`, a `gc` or a scripted loop of commits can fire
   hundreds of ref transactions in one burst; one finish per ref would be a frame storm for a consumer whose useful
   signal is "history moved". At most one event per `(kind, phase)` is emitted per pass, and the batch already says
   what changed. Per-operation granularity, if ever needed, is a payload field (a count or the ref), not a reason to
   flood the socket.
5. **A failed pass is reported, not hidden.** If the pass fails, the finish carries `status = failed` — the only signal a
   consumer gets, because `last_error` is control-plane state that never travels on this socket; the consumer must treat
   its view as stale and ask (`root status`). Silence would be the one outcome that makes a consumer believe a state it
   never received.
6. **An aborted operation is reported as aborted.** Git aborts ref transactions (`reference-transaction aborted`) and a
   checkout can fail on a dirty tree. The aborted phase is emitted without waiting for a pass, with the same
   `head_batch` as the current head (nothing was published), because there is no result to show. A start with no finish
   at all is closed after a bounded time (`status = timed out`, e.g. a hook that could not run) rather than left open
   forever — an open start would tell a consumer a write is in progress when it is not.
7. **Only `watching` roots emit.** A sleeping root has no watcher; hooks that fire while it sleeps are folded into the
   next wake pass, and the wake's finish (if any) follows that batch. A root whose mode is `off` emits nothing.
8. **A late subscriber is not replayed a finish.** A client that subscribes after a finish was flushed learns the state
   from the batch (`head_batch` plus the replay) and gets no historical `GIT_EVENT`; git events are a live signal, not a
   log. A consumer that needs the history of git operations asks the daemon (`root status`), not the stream.

Implementation shape: pending signals are queued per root (`git_pending`), `runPassLocked` already ends with the batch
broadcast under the root lock, so the flush is a loop right after it — same lock, same order, no second task. The
counters gain `git_events` (sent) and `git_passes` (passes a finish waited for), and `root status` prints them.

**One caveat the ordering inherits from § 4b:** the broadcast is sequential, so a subscriber that stopped reading delays
the frames written after it — including the finish of the client queued behind it. The guarantee is per connection and
per frame order, not "everyone hears at the same instant"; a stuck client is a known root-level cost (§ 4b), not a
second failure mode of this frame.

**How the ordering is tested, deterministically.** A test that writes a file and waits can only observe the order
*usually*. Two mechanisms make it a fact:

- a **unit test of the queue**: a fake writer records the frame log; the flush function is called with a pending finish
  and a batch in flight, and the log must read `START_BATCH, CHANGE_ENTRY…, END_BATCH, STATE?, GIT_EVENT(finish)` in
  that order for every subscriber — no socket, no timing;
- an **integration test with an injected slow pass** (`FSMETA_TEST_PASS_DELAY_MS`, read only under the test build or an
  explicit env guard), which proves a client cannot receive the finish while the pass is still publishing — the one case
  the unit test cannot show.

### 5e. Seeding a worktree from the base trio

A new worktree starts as (almost) the same content as the base worktree, on a different branch. A cold scan would hash
every file to discover that most are unchanged. Instead, when a root is **added as a worktree of a repo that is already
served**:

1. Verify the link: the worktree's `.git` file points at `<common>/worktrees/<id>/`, and that `gitdir` names the
   worktree — the same confirmation as § 4.
2. Copy the base root's `files.meta` and `files.txt` into the new root's `.fs-meta/`, and **rewrite** `files.json` for
   the new archive: `generation = 1`, `created` = now, the same `scan` block, the root-relative counts from the copied
   entries. Copying the base's document verbatim would carry its generation number and its creation instant into an
   archive that has neither, which every later diff would build on.
3. Write a **genesis batch from the copied state** (generation 1, full state, no scan) so the new archive has a complete
   first generation a consumer can start from.
4. Run a normal pass: it loads the copied trio as the previous state, walks the tree, and — because mtime/size match for
   unchanged files — re-hashes only the branch differences, publishing generation 2 as a *diff*. `outcome.hashed` tells
   the truth about what the seed saved.
5. If the pass fails or the copy is half-written, remove the seeded trio and the genesis batch rather than leave a
   plausible-looking archive that describes nothing: a failed seed must degrade to a cold scan, not to a wrong trio.

The result: a worktree root that is available in one small batch plus a diff, instead of a full genesis scan of content
the base already had.

**Seed validity, decided.** Seed only when all of these hold, and fall back to a cold scan otherwise: the worktree's
`gitdir` and the base's resolve to the **same common dir**; the base's last pass completed (its snapshot has no
`last_error` and no pass is in flight, so `head_batch` is the state the trio describes); the two trios' `scan` blocks
match (a different `hash_mode` makes the copied content hashes unusable, a different `ignore_sources` list makes the copy
describe a different tree, and the two `.fs-meta/ignore` files must be **byte-identical** — the source list does not
capture their contents, and a seed that disagreed would publish an excluded name in its genesis batch and delete it in
the next); and the base's trio is readable and validates. The diff pass corrects content anyway,
but a seed from a base that was itself mid-update would publish an intermediate generation as if it were real.

### 5f. Removal, pruning, and the `missing` state

**`git worktree remove` is not blocked by our watcher.** `nightwatch`'s Windows backend opens the watched directory with
`FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE` (`backend/Windows.zig`), so a watched tree can be deleted
underneath it — the earlier worry that our handles would make the removal fail is unfounded, and this plan needs no
`root release` command for it.

**What *does* block it is our own data.** `git worktree remove` refuses a worktree with untracked files, and
`<worktree>/.fs-meta` is untracked; a served worktree therefore needs `--force`, or one line in
`<common>/info/exclude`. Because § 5 reads `info/exclude`, the clean answer is a documented one-liner (plus an opt-in
`fsmeta exclude <root>` that appends a **marked, idempotent** block (`# fsmeta: our own directory` + `.fs-meta/`, skipped
if already present, **LF endings**) to that file for a user who asks — never automatic, it is git's file).
The caveat goes in `README.md`, `FORMAT.daemon.md` § 6 (the CLI, where `root remove` is recommended) and § 8 (platform
notes); `root remove` is the recommended way to stop serving before the directory goes away.

**The reaction path, in order:**

1. The metadata watch sees `<common>/worktrees/<id>` disappear (or its `gitdir` file vanish) — the same event
   `git worktree prune` produces — or the root's own directory is gone at the next pass.
2. The daemon **disarms that root's metadata mapping and working-tree watcher immediately**, before the next pass, so no
   further events are attributed to a tree that is going away.
3. The root becomes `missing` (§ 2b of `FORMAT.daemon.md`): subscribers get the state, `roots list` reports it, and the
   record stays, so a re-created path is picked up by the next add/start rather than silently dropped.
4. **`on_remove` is not applied.** It is a policy for an explicit `root remove`, not for a disappearance: a worktree on a
   volume that is briefly unmounted (the `locked` case) must not lose its batch history because it was `missing` for a
   minute. Only `root remove` deletes history, and only when the record says `delete`.
5. A pass that races the removal (a trio file vanishing mid-scan) must **degrade to `missing`**, not retry forever: a
   failed read of a trio file whose root no longer exists is the `missing` transition, not `last_error` + retry.
6. `git worktree move` and `repair` change `gitdir`: the old path becomes `missing` (step 3); a new path inside a served
   root is a boundary to ignore, one outside it is added by the user. A `locked` worktree is never pruned, so a
   `missing` locked root is expected and must not be reaped.

**With `worktrees` off there is no step 1.** The removal reaction is worktree handling, so the metadata signal is not
wired: the disappearance is noticed by the root's next pass — or by the safety net's, at most 60 s later — and becomes
`missing` the same way. The reaction is a latency optimisation plus the `locked`-volume care, not the only way a root
notices it is gone.

**A blocked removal leaves everything as it was.** If git refuses because of the untracked `.fs-meta`, it changes no
metadata and deletes nothing, so there is nothing for the daemon to react to: the root keeps serving. The user either
adds the `info/exclude` line (if they run fs-meta's M1) or passes `--force`; neither requires stopping the daemon
first.

### 5g. What the CLI, `scan` and `verify` report

Three questions a person will ask, and where each is answered (all additive to the existing JSON):

| question                               | answered by |
| -------------------------------------- | ----------- |
| "Why is this subtree not in the trio?" | `scan --json` gains `boundaries: [{ path, kind: "worktree"\|"repo" }]` and `ignored_sources: [...]`; text mode prints a `boundary:` line, and the footer says how many boundaries were skipped |
| "Which source ignored this name?"      | a new `fsmeta ignored <root> [--json]` lists every **pruned directory boundary** (not just top-level) with the source that decided it (`gitignore`, `info/exclude`, `fs-meta/ignore`, `boundary`, `reserved`), the number it removed, and a cap with a count when the list is truncated — a diagnostic; it never writes |
| "What is git doing to this root?"      | `root status` gains `head` (the branch name, or `detached:<sha8>`), `detached`, `in_progress` (`null`/`merge`/`rebase`/`cherry-pick`/`revert`/`bisect`) and `last_git_event` (`kind`, `phase`, `at`), read from the metadata files the watch already keeps warm; `roots list` gains a `worktree` column and groups roots that share a common dir; both carry `git_common` (the resolved common dir, host state like `root`, empty when `gitwatch` is off) |

`verify` keeps its job (validate the trio as written) and gains no rescan: it reports the trio's recorded
`scan.nested_repos` and `scan.ignore_sources`, so a reader can see *how* the state was produced. The current-state
questions belong to `ignored` and `scan`.

### 5h. The gate: two switches, one invariant, and an emergency override

The plan mixes two kinds of rule, and the gate must not confuse them:

- **An invariant — nested repositories are not scanned.** It applies whether or not worktrees are handled specially, and
  it is **not gated**: § 5 describes why a trio that descended into another repository would not be describing one tree.
  The same goes for the nested-root guard (R2): a root inside a served root is always ignored by its parent or refused,
  worktree feature or not, because that is the collision the guard exists to prevent, not a worktree feature.
- **Worktree-specific handling**, which is complex and can misbehave, and is gated. Two flags, resolved per root at add
  time from the daemon's defaults, overridable at runtime:

| flag        | default | what it controls                                                                              | off means |
| ----------- | ------- | --------------------------------------------------------------------------------------------- | --------- |
| `worktrees` | on      | recognising a boundary as a **worktree of a served repo** (`gitdir` → common dir), adopting one (`--on-worktree serve`), seeding it from the base trio, the `worktree` event, the `roots list` worktree grouping, the `worktrees/<id>` removal reaction, `hooks`/`exclude` | a boundary is **still a boundary and still not scanned**, but nothing else happens: no adoption, no seed, no `worktree` event, no worktree grouping, no removal reaction; an explicit `root add <worktree>` serves it as an ordinary root, scanned as its own tree |
| `gitwatch`  | on      | the metadata watch, the per-root lock latch, `GIT_EVENT`, hooks, the `root status` git fields | no `.git` watch, no git events, no hook spool read; the working-tree watcher is exactly what it is today |

- **What the switches never turn off:** the boundary rule of § 5, the `scan.nested_repos` record, `info/exclude` reading,
  and R2's nested-root guard. The first two are what a trio *is*; the third is a `.gitignore`-compatibility fix; the
  fourth is a collision invariant. A gate that changed what a trio describes would be a second format, not a switch.
- **Where they live.** `roots.json`'s `defaults` gains both, and each record copies them at add time (like every other
  default). The daemon resolves the effective value per root at start and on every `root set`; the CLI passes
  `--worktrees on|off` / `--gitwatch on|off` at add, and `root set <id> worktrees off` flips it live.
  A record written before the flags existed resolves them from `defaults` — or `on` when the default itself is absent —
  so an upgrade neither silently turns handling off for old roots nor on for ones whose operator had said off.
- **The emergency override wins over everything:** `FSMETA_WORKTREES=0` (or `off`) at `daemon start` disables **both**
  flags for every root of that daemon, and `=1` (or `on`) forces both on over a config that says off; either way it logs
  one line at start and is reported by `daemon status` (`"worktrees": "off (environment)"`). The override exists for a
  daemon that misbehaves with the feature on, because it needs no working control socket and no config edit.
  `FSMETA_GITWATCH=0` is the finer knob. Neither touches the scan rule.
- **Flipping a switch is not a scan-rule change.** `worktrees` off does not add or remove names (the boundary rule still
  decides that), so the flip forces a pass only to re-resolve the root's git dirs and drop its pending worktree signals;
  `git_events`/`git_passes` stop moving. The trio is byte-identical before and after — which is the property that makes
  the switch safe to reach for.
- **`gitwatch` off is independent of `worktrees` off.** A root with no worktrees still benefits from checkout batching and
  events, and a worktree-handling problem does not have to cost the events. The emergency env override turns both off,
  because the operator answering "is it the new stuff?" should not have to guess which half misbehaved.
- **The gate is built first.** M0 ships the flag plumbing with the boundary rule, M3/M4 ship under `gitwatch`, M5 refuses
  to install hooks when its flag is off, M6 skips seeding/adoption. Each milestone's tests run at least one case with its
  flag off, so "it can be turned off" is a tested property, not a fallback nobody exercises.



## 6. Relationship to the daemon's nested-roots decision

`plans/archive/daemon.md` § 16b measured the cost of nesting *without* a guard: 10 of 10 edits produced a pass in both
roots, the pair scanned 904 names where one root covered the change with 604, and the inner history duplicated the
overlapping batch bytes (+48.8%). It chose "allowed, with a warning" and rejected option D (pruning the child from the
parent's scan) because "a generation that skips part of its tree is not a state description".

**R1/R2 make option D the rule, and the objection is answered by naming the boundary.** A generation describes the
tree *minus nested repositories and working copies* — a rule that is stated in `FORMAT.md`, recorded in `files.json`'s `scan` block, and
verifiable. That is a description with a defined edge, not a hole; git itself does the same for submodules. With the
rule in place the measured duplicate cost disappears by construction (the parent no longer watches the child), which is
why the warning path is superseded rather than kept: the code that prints it is removed in M2, and the archive note
points here.

## 7. Milestones

| #      | what | done when |
| -      | ---- | --------- |
| **M0** | **The rule (not gated) and the gate plumbing.** The boundary rule: a directory whose `.git` entry **confirms** (§ 4) is a boundary, never descended — a *file* marker by its `gitdir:` target (back-pointer only as confirmation, so a manually moved worktree still counts), a *directory* marker by `HEAD` + `objects/`; a clone, a submodule and a worktree are all covered because the rule is about nested repositories. `files.json` `scan.nested_repos` (a record, always `true`) + `FORMAT.md` + a conformance vector with a nested repository; ports tolerate the key; the **migration** case prints its one-line notice. `scan`/`scan --json` shows boundaries, and a `.git` entry created inside an existing directory forces a pass (the one case the watcher filter hides, § 4). In the same milestone, the `roots.json` `defaults` gain `worktrees` and `gitwatch` (both on) and `daemon status` reports them, so every later milestone can be gated. | a nested clone's, submodule's and linked worktree's files are absent from the trio and present in `scan --json`'s `boundaries`; the rule holds with **both flags off** (it is not a worktree feature); a stray `.git` directory is **not** a boundary; a stale back-pointer still is; `git init` inside a watched directory is picked up within one tick, not at the safety pass; a root near `MAX_PATH` has its behaviour recorded (not fixed); on kqueue/Windows a boundary is never registered by the watcher, and a worktree added while watching does not grow the watch set; on Linux either the nightwatch change lands (then the same holds) or the limitation is recorded and only the scan-level exclusion is asserted; on Linux `watch_count` stays bounded (the nightwatch predicate or the documented fallback), measured rather than assumed; `verify` says `ok`; `daemon status` shows the flags; `FSMETA_WORKTREES=0` flips them for a daemon. |
| **M1** | The ignore sources: `<root>/.fs-meta/ignore` (ours) **and** `<common>/info/exclude` (git's, currently unread), both through the existing `gitignore` reader, with the source precedence and no-cross-source-negation rule of § 5; `files.json` `scan.ignore_sources` (no mtime — the engine re-reads both files every pass, § 5b); a new `fsmeta ignored <root> [--json]` naming the deciding source per pruned directory; `refresh` and the daemon agree; idempotent append helper with tests (relative path, already present, parent deleted, path with spaces, `[id]`, `!`). | a root with `.fs-meta/ignore` containing `worktrees/w1/` publishes without that subtree, from `refresh` **and** from the daemon; editing that file by hand removes the subtree on the next pass (the 60 s safety net bounds it); an `info/exclude` line does the same without fs-meta writing anything; deleting either line brings the subtree back; `ignored` names the source for each. |
| **M2** | Guarded nesting in `root add` (R2), **not gated**: auto-append to the parent's internal ignore (in a `# fsmeta-managed` block), force a parent pass, refuse (exit 4) when it cannot be arranged; **remove** the § 16b warning path and its test; re-run the § 16b measurement (expected: a write inside the child produces a pass only in the child). | the parent's `last_pass_files` is unchanged by a child edit, the child's advances, and the parent never writes the child's `.fs-meta`; the guard also applies with both flags off; a user's own `.fs-meta/ignore` lines survive a rewrite of the managed block; a parent added after its children hides each of them (one managed line), a hand-edited `roots.json` is reconciled at start, and a deleted managed block is repaired by the parent's next pass; the old warning test is gone; `FORMAT.daemon.md` § 4 documents the rule. |
| **M3** | **The git lock latch and the metadata watch, lifted from the prototype into `RootRuntime`**, under the `gitwatch` flag: resolve `$GIT_DIR`/`$GIT_COMMON_DIR` per pass (gitfile + `commondir`), **one metadata watcher per common dir** with per-root prefix mapping, a `should_watch` predicate that refuses `objects/`/`modules/`/`lfs/`/`hooks/`, the metadata path set, the **path-based** tree-changing-versus-repo-wide split, a **per-root** lock latch (`$GIT_DIR/*.lock` only), clear the latch by polling; `root status` gains `head`, `detached`, `in_progress`. | with `gitwatch = off` the metadata watcher is never armed and a checkout produces no extra pass or event (only the ordinary working-tree burst); with it on: a checkout mid-write produces no pass, one checkout one batch, a commit in one worktree does **not** pass its sibling's root, a shared `refs/**/*.lock` does **not** block a sibling's pass, a worktree root does not strand the latch, and the main worktree's HEAD/index change is still tree-changing; `root status` shows the git state (empty when off); `hasGitLock` is gone from `main.zig`. The arm is refcounted: adding two roots of one repo arms it once, removing one leaves it, removing the last disarms it; on Linux the arm's `watch_count` is bounded by the small-dir set plus the polled files, not by `objects/`. |
| **M4** | **Git events (R3)**, under `gitwatch`: `GIT_EVENT` (kind `0x0A`), `protocol = 0x0102`, the metadata-derived timeline (HEAD/refs/pseudo-refs) folded into start/finish, `branch` vs `checkout` from the `post-checkout` flag, the deferred-finish queue flushed **after** `broadcastBatchLocked`, the variable-length `worktree` event (path) sent to every served root of the repo, `git_events`/`git_passes` counters, `root status` display, `FORMAT.socket.md` + `FORMAT.daemon.md`. **Before any of it, a spike:** log which hooks fire for `git switch`, `git checkout -- .`, commit, amend, merge, rebase, reset, stash, `worktree add/remove/move`, fetch — the result is a small coverage table appended to this plan. | a consumer sees `START_BATCH … END_BATCH` then `GIT_EVENT(finish)` for a checkout; a checkout that changes nothing still emits finish after its pass; a failed pass emits `status = failed`; `worktree add` produces a `worktree` event with the path on every served root, and a removal with `path_len = 0` is accepted as "a worktree left"; a `git fetch` that moves many refs produces at most one event per kind for the pass, not one per ref; with `gitwatch = off` **no** `GIT_EVENT` is ever sent and the client sees batches only; the hook-coverage table exists. |
| **M5** | **Hooks (R3, optional)**, under `gitwatch`: `daemon hooks install/uninstall/status`, the wrapper set, the `# fsmeta-managed` marker, chaining with `--force`, refusal when `core.hooksPath` is set, a **per-repo spool `<common>/fsmeta-events.log`** read on the tick, the hook's own size cap, the stale-line discard; `install` refuses while `gitwatch` is off (a hook that writes a spool nobody reads is a trap). | with hooks installed and the metadata watcher **disabled**, a checkout still produces start/finish in the right order; a hook fired for an *unserved* worktree writes to the common spool and creates no `.fs-meta` there; install works with no daemon running, and refuses a read-only `<common>` with the path in the message; an existing `post-checkout` still runs; `uninstall` restores it byte-for-byte; a spool left for a week is still bounded; `install` with `gitwatch = off` refuses and says why. |
| **M6** | **Seeding (R4) + live discovery + removal (§ 5f)**, under `worktrees` (and `gitwatch` where the signal comes from a hook): a worktree adopted as a root copies the base trio (with the validity conjunction of § 5e), publishes a genesis from it, then a diff; a `created` directory that confirms as a boundary is reported (the parent's scan excludes it by rule either way) and, |  |
opt-in, adopted as a root; `worktrees/<id>` disappearing disarms that root and marks it `missing` immediately, **without touching its history**; `move`/`repair`/`prune` handled as vanished or renamed paths; caps and a deadline on the confirmation I/O. | a worktree root appears with `genesis + diff` and `outcome.hashed` far below a cold scan; a worktree added while watching is pruned from the parent within one burst; removal leaves `missing`, not a stuck root, with its `batches/` intact; a locked worktree reported `missing` is not reaped; with `worktrees = off` there is **no adoption, no seed, no worktree event and no removal reaction**, while the boundary rule still keeps the worktree out of the parent's trio and an explicit `root add` of it works as an ordinary root. |
| **M7** | CLI and docs: `roots list` marks a root as a worktree and groups by common dir; `root add --worktree`/`--nested`/`--on-worktree`, `--worktrees`/`--gitwatch`, `root set <id> worktrees off` / `gitwatch off`, and `FSMETA_WORKTREES`/`FSMETA_GITWATCH` documented; `daemon status` reports both effective flags and whether the env override is active; `hooks` and `exclude` commands in `FORMAT.daemon.md` § 6; `FORMAT.socket.md` records that git events are a daemon feature (`serve` does not emit them); `FORMAT.md` (boundary rule, `scan.nested_repos`, `scan.ignore_sources`); `README.md` gets the two-switch paragraph, the emergency command and the sentence *the scan rule is not one of the switches*; `AGENTS.md` (one invariant each: *a boundary is ignored, not scanned twice*; *finish never precedes its batch*; *every worktree/git feature is behind a switch tested in both states, and the boundary rule is not a feature*). | the documents name the rules once and say how to disable the handling without changing what a trio describes; a person reading only `FORMAT.daemon.md` + `README.md` can explain the event order, the `serve` asymmetry, why a worktree is absent from the parent's trio with every flag off, and how to turn the handling off in one command. |

**M0 status (2026-10-27): done.** Evidence, criterion by criterion:

- **Boundary detection** lives in `src/boundary.zig` and runs on the *unfiltered* listing in `src/scan.zig` and
  `src/lister.zig`: the boundary is neither listed nor entered, so a clone's, a submodule's and a worktree's files are
  absent from the trio. Seven unit tests cover the ordinary directory, the stray `.git` directory (not a boundary), the
  clone, detached `HEAD`, the gitfile, a missing target (not a boundary) and a missing `gitdir:` prefix.
- **`scan --json`** reports `{"names":[…],"count":N,"boundaries":[{"path":"clone","kind":"repo"}]}`; verified by hand for
  a clone (`repo`) and a linked worktree (`worktree`).
- **`scan.nestedRepos`**: the engine writes `true` always; `FORMAT.md` § 7 and § 16 document the key and that absent
  means the rule was not applied. `conformance/fsmeta-vectors-v2.json` has the generated `ok-nested-repository` case and
  asserts in the generator that the clone's name is absent from `files.txt` (15 cases, all verified by the engine).
- **Migration notice**: a pass that removes names under a boundary prints
  `2 names under nested repositories are no longer described` (verified on a trio published before the markers existed).
- **The rule is not gated**: a daemon root added with `--worktrees off` publishes the same exclusion and the same
  `nestedRepos` record (verified live).
- **Gate plumbing**: `roots.json` defaults and records carry `worktrees`/`gitwatch`; `root add --worktrees off --gitwatch
  on` persists them; `daemon status` prints `worktrees on, gitwatch on`, and with `FSMETA_WORKTREES=0` prints both `off`
  plus `note: FSMETA_WORKTREES=off is active`.
- **`.git` appearing forces a pass** (G33): creating `.git` under a watching root moves `event_passes` within one tick,
  and the published-pass count does not move because nothing in the trio changed (`test/daemon.test.mjs`).
- **Watchers**: on Windows nightwatch arms one recursive registration per root, so a boundary cannot be registered and
  cannot grow the watch set. On Linux the tree arm's per-directory registration remains the limitation recorded in § 5b
  and G49; M0 asserts the scan-level exclusion there and M3 owns the arming.
- **`MAX_PATH`**: not exercised on this host; no new path handling was added, as § 3 says, and the case stays open.
- **Gates**: `zig build test` with a fresh cache — 40/40 steps, **468/474 tests passed (6 skipped), 0 failed**;
  `bun test js test` — 99 passed, 4 skipped, 0 failed.

**M1 status (2026-10-27): done.** Evidence, criterion by criterion:

- **Two sources, one reader.** `src/ignores.zig` loads `<root>/.fs-meta/ignore` and `<common>/info/exclude` (resolved
  by `gitdir.resolve`; a root that is not a repository has no second source) and parses both with the existing
  `gitignore.Rules`. `.fs-meta/ignore`'s `# fsmeta-managed` block is split out and evaluated after the user's lines, so
  a user's `!` cannot re-open a managed entry while the block's own `!` can.
- **Precedence and no cross-source negation** live in `Sources.decide`: chain, then `info/exclude`, then
  `.fs-meta/ignore`; the first exclusion wins, so a later `!` is never consulted. Tests cover chain-vs-internal,
  info-vs-internal, per-source negation, and the managed block's escape hatch.
- **No cache, no mtime.** `engine.refresh` calls `Sources.load` on every pass and `scanDetailed` does the same on every
  walk; a hand-edit test publishes the new tree on the next pass, and the daemon's 60 s safety net bounds the wait
  because `.fs-meta` is not a watcher event.
- **`scan.ignoreSources`**: `files.json`'s scan block records the sources in precedence order, omitting a source whose
  file is absent (`gitignore` is listed whenever the flag allowed the chain). `FORMAT.md` § 7 and § 16 document it;
  `json_doc` pins the emitted bytes; a reader that does not know the key keeps working.
- **`fsmeta ignored`** is a read-only walk: JSON is `[{path, source}]`, text is one `<source> <path>` line, and the
  source vocabulary is `gitignore`, `info/exclude`, `fs-meta/ignore`, `boundary`, `reserved` (documented in the usage
  text). It never writes.
- **`refresh` and the daemon agree**: `RootRuntime.runPassLocked` calls `engine.refresh`, so there is one
  implementation, and the CLI walk and the cold-start lister apply the same `Sources` object.
- **Linked worktree**: a `gitdir`-backed test reads `info/exclude` from `<common>` (not the worktree's own git dir),
  both through `Sources.load` and through `scanDetailed`.
- **Append helper**: `appendManaged` writes a directory-shaped `path/` under `# fsmeta-managed`, preserves the user's
  lines, is idempotent, recreates a deleted `.fs-meta`, escapes spaces / a leading `!` / `[id]`, and refuses a newline
  or an absolute path. Each case has a test.
- **Gates**: fresh-cache `zig build test` — 46/46 steps, **563/569 tests passed (6 skipped), 0 failed**;
  `bun test js test` — **102 passed, 4 skipped, 0 failed**.
- **Left open**: no daemon-specific M1 test was added; the daemon path is `engine.refresh`, and the engine-level test
  pins the source set and the exclusions. A hand edit of `.fs-meta/ignore` waits for the next daemon pass (60 s
  safety net), as § 5b and decision 11 say.

**M2 status (2026-10-27): done.** Evidence, criterion by criterion:

- **Guard, not warning.** `Host.addRoot` finds served ancestors and descendants with `paths.isInside`, appends each
  relative child to the parent's managed block with `ignores.appendManaged`, and calls `RootRuntime.forcePass` once per
  parent — the pass arms no watcher, so an `asleep` or `off` parent stays that way. Only then is the child recorded and
  served. A parent added after its children gets one managed line per served descendant before its first pass.
- **Refusal is exit 4**, with a message naming `<parent>/.fs-meta/ignore` and the parent, when the append or the pass
  cannot be arranged; the child is not recorded or served. The `warning` field, `nestingWarningLocked`, the CLI note and
  the § 16b wording are gone; `README.md` and `FORMAT.daemon.md` § 4 state the guard instead.
- **Lifecycle.** `startRoots` rewrites every parent's block from `roots.json` before any root starts; each pass's
  `Guard` callback appends missing lines before `engine.refresh`, so a deleted block is repaired by the parent's next
  pass; `root remove` rewrites its parents and drops the line. `ignores.rewriteManaged` keeps the user's bytes above the
  marker and replaces only the managed block.
- **Not gated**: a daemon with `FSMETA_WORKTREES=0`, and a child added with `--worktrees off --gitwatch off`, are both
  hidden from the parent.
- **Measurement** (`test/daemon.test.mjs`): a child edit advances the child's `passes`/`last_pass_files` and does not
  move the parent's published pass count or name count; a parent edit leaves the child's `files.json` generation
  untouched, so the parent never writes the child's `.fs-meta`; the parent's trio omits the child's names.
- **Tests**: `src/nesting.zig` (relative paths, append/reconcile, user-line survival), `src/ignores.zig` (managed-block
  rewrite), and the daemon cases `a nested root is guarded by its parent, not warned about`, `a deleted guard block is
  repaired by the parent pass and at startup`, `the guard holds with both switches off`, and `root add refuses when it
  cannot arrange the guard`. The old warning test is gone.
- **Gates**: fresh-cache `zig build test` — 48/48 steps, **609/615 tests passed (6 skipped), 0 failed**; `zig build`
  (executable, which analyses the host paths `zig build test` leaves lazy) — 4/4 steps; `bun test js test` — **111
  passed, 4 skipped, 0 failed**.
- **Left open**: the refusal test uses a directory named `.fs-meta/ignore` (portable on this host) rather than a
  read-only ACL; a failure after an earlier ancestor append can leave a harmless stale line, which the next
  reconciliation drops; the § 16b benchmark was replaced by the daemon test's per-root counters rather than re-run as a
  timing benchmark.

**M3 status (2026-10-27): done; the Linux watch bound is proven by the dependency's code path, with the empirical
count left to Linux CI.** Evidence, criterion by criterion:

- **Git dirs are resolved per pass.** `RootRuntime.syncGitLocked` calls `gitdir.resolve` from `runPassLocked` and from
  the wake/arm path, so a root that became a worktree, or whose `gitdir:` moved, is re-mapped; the location strings
  are duplicated into the root's arena only when the answer changes, so an ordinary pass allocates nothing. A resolved
  location must also **confirm** (`HEAD` + `objects/` for a `.git` directory, `HEAD` for a gitfile's target), which is
  § 4's vocabulary applied to the root: a stray `.git` directory is not a repository and gets no metadata watch. The
  existing suite found this — a fixture's `.git/HEAD` write became a git event pass — and the confirmation fixed it
  rather than weakening the test.
- **One metadata watcher per common dir, refcounted.** `src/daemon/gitwatch.zig`'s `Registry` keys arms by common dir
  (`samePath` is separator- and case-tolerant, so two spellings of one repo do not arm twice) and counts the roots
  that hold it; `RootRuntime` acquires on arm, re-maps only the prefix when `$GIT_DIR` moves, and releases on
  disarm/deinit. Unit test: add two roots of one repo → one arm (`refs` 1→2), remove one → the arm stays, remove the
  last → it is gone; a second repo is a second arm. Integration: the daemon prints the arm once, the per-root logs read
  `(1 root(s) of this repository)` then `(2 root(s) …)`, `root remove` of one keeps it (no `released` line) and
  removing the last prints `released` exactly once.
- **Per-root prefix mapping.** The arm is on the common dir alone — a root's working tree is never in it — and each
  listener carries its own `$GIT_DIR`, so the same path is classified per root. Unit test: `<common>/worktrees/wt/HEAD`
  is `.tree` for the worktree root and `.repo` for the main root; the main worktree's `<common>/HEAD` is `.tree` for
  the main root and `.ignored` for the worktree root, so a sibling cannot be passed by it.
- **`should_watch` prunes the balloon, including on inotify.** Directories named `objects`, `modules`, `lfs` or
  `hooks` are refused at any depth, and nothing outside the metadata set is admitted (unit test). The predicate is in
  the handler vtable, and nightwatch's generic layer consults it on every per-directory backend: `recurse_watch`
  before each `add_watch`/recursion and the interceptor for a directory created later. The earlier "not met on Linux
  because `INotify.zig` never calls it" was a misreading of where the contract lives; the closure batch confirmed it
  against the pinned dependency (`nightwatch.zig:128/194-197/362-363/271-272/319-320`) and pinned both the vtable path
  and `filters_watches` per platform in tests. **On this host (Windows)** ReadDirectoryChangesW covers the subtree
  with **one** registration and never consults the predicate, so it is a handler filter; the arm logs
  `(1 registration(s), should_watch filtered in the handler (one recursive registration))`. An empirical `watch_count`
  on Linux remains a Linux-CI measurement, not an open design question.
- **The metadata path set.** Tree-changing: `HEAD`, `index`, `ORIG_HEAD`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`,
  `REVERT_HEAD`, `REBASE_HEAD`, `BISECT_LOG`, `logs/HEAD`, and `$GIT_DIR/*.lock`. Repo-wide: `refs/`, `packed-refs`
  (+`.lock`), `logs/refs/`, `worktrees/`. Shared and tree-changing for every root: `info/exclude`. Refused:
  `objects/`, `modules/`, `lfs/`, `hooks/` — hooks are deliberately not a file event (§ 5b excludes them; M5's spool is
  the hook signal). A ref lock is watched as an event but is not a latch.
- **The path-based split holds.** Unit test: the same `refs/heads/x` is `.repo` for every root while a worktree's own
  `HEAD`/`index`/`logs/HEAD` are `.tree` only for it. Integration: an empty commit in a linked worktree moves that
  root's `event_passes` and leaves its sibling's untouched (and its `head_batch` unchanged); a `git update-ref` — the
  lock-and-rename shape of a fetch — moves neither root.
- **A per-root lock latch, cleared by polling.** `hasTreeLock` stats only `$GIT_DIR/index.lock`, `HEAD.lock` and
  `shallow.lock`; a `refs/**/*.lock` or `packed-refs.lock` is not a latch, so a commit in one worktree cannot stall a
  sibling. `tick` consults it before any pass (wake, event or safety), leaves the scheduler's burst pending while it
  is held, and resumes on the first tick after it is gone; a lock held past the safety interval is logged once, and
  cleared only by the poll. Unit test: each of the three latches and no ref lock; integration: a lock created in a
  *linked worktree's* git dir (a directory no tree watcher covers) defers a pass across ten ticks and the deferred
  pass runs after the lock is deleted, while a shared `refs/heads/*.lock` does not block a pass.
- **One checkout, one batch, no mid-write pass.** Integration, with real git: a `git checkout` between branches that
  differ by one file produces exactly one batch whose entry is that file (added one way, deleted the other), no second
  batch, and the next pass's `head` is the branch it landed on. The mid-write half is the latch case above: a lock
  that exists while a file changes produces no pass at all, and exactly one pass when it is removed.
- **`root status` shows the git state.** `head` (branch name, or `detached:<sha8>`), `detached` and `in_progress`
  (`merge`/`rebase`/`cherry-pick`/`revert`/`bisect`) are read on demand from `$GIT_DIR`; text output and `--json`
  carry them, and all three are empty/false when `gitwatch` is off. Unit tests cover the `HEAD` forms and each
  in-progress marker in precedence order; integration covers a branch, `git checkout --detach`, a conflicting merge
  and the cleared state after `merge --abort`.
- **`gitwatch = off` really is off.** `syncGitLocked` returns before resolving anything, so no `.git` is read, no arm
  is acquired and no latch is polled. Integration: the root's log contains no `git:` line, `root status` has no head,
  a HEAD-only checkout (identical content) produces no pass and no batch, and a content checkout produces exactly one
  ordinary working-tree burst.
- **The prototype's latch is retired.** `src/main.zig` no longer has `hasGitLock`, `in_git_tx` or the git watcher: it
  is the debouncer it always was, with a comment saying where the latch went and why a second copy would drift. It is
  not on `zig build`'s path (only `zig build watcher`), and that build still succeeds.
- **No wire change.** M4 owns `GIT_EVENT`, so M3 adds no frame, no protocol bump and no `git_events`/`git_passes`
  counters; the split is proven by `event_passes`, which is already on the wire.
- **Gates**: `zig build test` with a fresh cache (`--cache-dir .zig-cache/m3-fresh2`) — 48/48 steps, **609/615 tests
  passed (6 skipped), 0 failed**; `zig build` and `zig build watcher` — 4/4 steps each (evidence for the lazily
  analysed executable path); `bun test js test` — 110 passed, 4 skipped, 0 failed (823 assertions).

**M4 hook-coverage spike (2026-10-27, git 2.54.0.windows.1).** Run before building anything on the hooks, as the
milestone requires: every hook git calls was asked to append one line to a spool, and one operation at a time was run
against a real repository (`.tmp/` scratch, discarded). The third column is what `reference-transaction` actually saw
on stdin — the load-bearing discovery, because it means a **branch switch is a ref transaction after all**: `HEAD`
arrives as `ref: refs/heads/<branch>`.

| operation                            | hooks that fired                                                                                  | ref names seen by `reference-transaction`                                                         |
| ------------------------------------ | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `switch -c <branch>`                 | `post-checkout`, `reference-transaction`                                                          | `refs/heads/<new>` (create) and **`HEAD`** (`0000…` → `ref:refs/heads/<new>`)                     |
| `switch <branch>` (branch switch)    | `post-checkout`, `post-index-change`, `reference-transaction`                                     | **`HEAD`** (`0000…` → `ref:refs/heads/<branch>`)                                                  |
| `checkout -- .` (file checkout)      | `post-checkout`, `post-index-change`                                                              | —                                                                                                 |
| `checkout <branch>` (legacy command) | `post-checkout`, `post-index-change`, `reference-transaction`                                     | **`HEAD`** (`0000…` → `ref:refs/heads/<branch>`)                                                  |
| `commit`                             | `post-commit`, `post-index-change`, `reference-transaction`                                       | `HEAD` and `refs/heads/<branch>`, old→new sha                                                     |
| `commit --allow-empty`               | `post-commit`, `post-index-change`, `reference-transaction`                                       | same shape as `commit`                                                                            |
| `commit --amend`                     | `post-commit`, `post-index-change`, **`post-rewrite`**, `reference-transaction`                   | same shape as `commit`                                                                            |
| `merge` (fast-forward)               | `post-checkout`, `reference-transaction`                                                          | `refs/heads/<branch>`, old→new                                                                    |
| `merge` (conflict)                   | `post-checkout`, `post-index-change`, `reference-transaction`                                     | `HEAD`, `refs/heads/<branch>`; `merge --abort` fires `post-index-change`, `reference-transaction` |
| `rebase` (conflict)                  | `post-checkout`, `post-index-change`, `reference-transaction`                                     | `HEAD`; `rebase --abort` fires `post-index-change`, `reference-transaction`                       |
| `reset --hard`                       | `post-checkout`, `post-index-change`, `reference-transaction`                                     | `HEAD`, `refs/heads/<branch>`                                                                     |
| `stash` / `stash pop`                | `post-index-change`, `reference-transaction`                                                      | `refs/stash` (create/delete)                                                                      |
| `worktree add`                       | `post-checkout`, `post-index-change`, `reference-transaction` (in the **new** worktree's context) | `refs/heads/<new>`, the new worktree's `HEAD`                                                     |
| `worktree move`                      | **none**                                                                                          | —                                                                                                 |
| `worktree remove`                    | **none**                                                                                          | —                                                                                                 |
| `fetch` (moves a ref)                | `reference-transaction`                                                                           | the fetched ref(s)                                                                                |
| `gc` (packed-refs rewrite)           | `reference-transaction`                                                                           | —                                                                                                 |

What the table decides:

- **`reference-transaction` is the backbone it was hoped to be, and better:** it reports `HEAD` for a switch, so a
  start/finish pair per worktree is available from git itself, with both object ids on stdin. `AUTO_MERGE` also appears
  in its stream (a pseudo-ref git writes while merging); a hook-driven reader must ignore refs it does not know rather
  than refuse them.
- **`post-checkout`'s flag is the `branch`/`checkout` split** the frame's two kinds encode, exactly as § 5d assumed.
- **`worktree move` and `worktree remove` fire nothing at all.** No hook can report them, so the `worktree` event is the
  metadata timeline's job in every configuration — the `worktrees/<id>` directory appearing or vanishing — which is what
  M4 implements. `worktree add` does fire hooks, but only in the new worktree's context, which may not be a served root:
  the second reason the metadata path is not optional.
- **A `fetch` and a `gc` are ref transactions only** — repo-wide events with no tree change, which is why a repo-wide
  signal must not pass a root.
- **The fallback is real, not hypothetical:** this environment has no hooks installed (M5 installs them, so nothing can
  yet), so every M4 integration case runs on the metadata timeline. The table is M5's design input, and the `source`
  byte is how a consumer tells the two apart.

**M4 status (2026-10-27): done, metadata-sourced.** Evidence, criterion by criterion:

- **`GIT_EVENT` (kind `0x0A`) is on the wire** at `protocol = 0x0102`: 20 bytes (`u8 phase`, `u8 kind`, `u8 source`,
  `u8 status`, `u64 head_batch`, `u64 at_ms`), and `24 + path` for the one variable kind, `worktree`. `wire.GitEvent`
  round-trips both shapes; a non-`worktree` kind of any other length, a `worktree` kind without its `u32 path_len`, a
  `path_len` past the frame, and any value outside the four tables are refused with `LengthMismatch`/`InvalidGitEvent`
  rather than guessed (`src/wire.zig` test). The `HELLO` pin moved to `0x0102` in both suites, and `fsmeta serve`
  announces it and never emits `0x0A` (no scheduler, no git handling) — the asymmetry `STATE` already had.
- **The finish ordering is the tested contract.** Integration asserts the interleaving on a real socket: for a
  `git checkout`, exactly one batch is published, its `END_BATCH` precedes `GIT_EVENT(finish)`, the finish's
  `head_batch` is that generation, and no batch follows. A HEAD-only checkout to identical content emits a finish with
  **no batch at all** (§ 5d rule 3). A burst of five ref updates in one `git update-ref --stdin` is **one** `commit`
  event, not five (coalescing per kind), and a ref-only update has no pass to wait for, so its `head_batch` is the head
  the root already had — documented as "not a batch you can fetch".
- **Kinds are decided from the path, in the watcher's thread** (`gitwatch.changeOf`, unit-tested): `HEAD` → `branch`,
  `index` → `index`, `MERGE_HEAD` → `merge`, `REBASE_HEAD`/`rebase-merge/**`/`rebase-apply/**` → `rebase`,
  `refs/heads/*` → `commit`, `worktrees/*` → `worktree`, everything else shared → `other`. A lock is **never** an event
  (§ 5b, "Lock files are a latch, not an event source"), tree lock and ref lock alike: the durable rename after it is
  the record, and dropping the pair is what keeps "one operation, one event" true.
- **Worktree events go to every served root of the repo with `gitwatch` on**, with the path read from
  `worktrees/<id>/gitdir`, and `head_batch` is that root's current head. Integration: two served roots of one repo,
  `git worktree add` → both receive the path; `git worktree remove` → both receive a finish with `path_len = 0`. The add
  is a `start` when the metadata appears and a `finish` when the directory has stopped changing between two ticks — the
  heuristic § 5c describes, labelled `source = metadata`. **The last linked worktree needs a second detector:** its
  removal deletes the empty `worktrees/` directory too, and ReadDirectoryChangesW then delivers the parent's deletion
  instead of the child's, which carries no id. A half-second existence poll of `<common>/worktrees` (one `stat`, no
  allocation unless the answer changes) emits the same single `finish(path_len = 0)`, deduplicated against the event
  path by `last_worktree_finish_ms`, so a removal is never reported twice. Integration: with no sibling worktree,
  `git worktree remove` still produces the empty-path finish.
- **`gitwatch = off` sends no `GIT_EVENT` at all.** Integration: a HEAD-only checkout produces no pass, no batch and no
  event; a content checkout produces exactly one ordinary batch with no event frames before or after it, and
  `git_events`/`git_passes` stay 0.
- **Counters and display:** `git_events` (frames sent) and `git_passes` (passes a finish waited for) are in the root
  snapshot, `root status` prints them, and `FORMAT.daemon.md` § 4 documents them with the git fields. `FORMAT.socket.md`
  has the § GIT_EVENT contract: the layout, the variable `worktree` shape, `head_batch`'s two meanings, and the eight
  ordering rules.
- **A failed pass is reported, not hidden:** a finish that waited for a failed pass carries `status = failed` (and the
  batch-read-back failure path does the same). The closure batch added the fixture: with a HEAD-only checkout pending,
  the engine is made to fail from outside (the trio's `files.meta` replaced by a directory → `IsDir`); every pending
  kind gets `start(ok)` then `finish(status = failed, source = metadata)`, no `START_BATCH` is written, the root
  records `last_error = "IsDir"` and stays `watching`, and the next pass after the trio is restored clears it and
  publishes. A `NotDir` failure (root marked `missing`) is the other arm and remains covered by the M6 removal tests.
- **`aborted` and timed-out starts are not implemented from metadata, and M4 does not claim them.** The metadata
  timeline sees an operation *after* it happened, so it has no open start to abort or time out; that pair belongs to the
  hook source (M5), and the frame's phase/status table already reserves it.
- **Gates**: `zig build test` with a fresh cache — **613/619 tests passed (6 skipped), 0 failed**, 48/48 steps;
  `zig build` and `zig build watcher` — 4/4 steps each; `bun test test/daemon.test.mjs` — 28/28,
  `bun test js test` — 116 passed, 4 skipped, 0 failed.

**M5 status (2026-10-27): done.** Evidence, criterion by criterion. The file half is the previous pass's `hooks.zig`
(kept, one body fix below); the command, the refusals, the daemon-side spool reader and the integration cases are this
pass's work.

- **The file half.** `src/daemon/hooks.zig`: the six generated hooks as bytes — POSIX `sh`, **LF only** (a CRLF script
  fails under git's bundled `sh`), `# fsmeta-managed`, `trap 'exit 0'` and `|| true` on every write, the spool found
  with `git rev-parse` rather than an embedded path, the 64 KiB truncate before appending, one JSON line with an
  epoch-seconds `date +%s` stamp, and escaping; `install` writes atomically, refuses a foreign hook without `--force`
  and chains it as `<name>.fsmeta-orig` with it; `uninstall` restores the original byte for byte; `status` reports
  ours/foreign/chained + the spool size. Four unit tests, plus three added here: the line→`(kind, phase)` mapping, the
  `core.hooksPath` reader (config-file fallback) and the write probe.
- **The CLI is real and local.** `fsmeta daemon hooks install <root> [--force]`, `uninstall <root>`,
  `status [<root>] [--json]` are wired into the `daemon` dispatch and the usage text. They resolve the git dirs from the
  path they are given (`gitdir.resolve`) and read/write `<common>/hooks` directly; nothing goes through the control
  socket. `status` with no root groups every served root by common dir and reports each hook's state and the spool
  size, as text or as `{"repositories":[…]}` JSON; **`hooks status --json` reports ours/foreign/chained + the spool
  size** (integration case 3).
- **The refusals, each with its path.** `install` refuses a set `core.hooksPath` (naming it; git itself is asked, with a
  repository-config fallback when git is not on `PATH`), a root whose `gitwatch` is off (naming the switch; the answer
  comes from the running daemon's `roots` reply or from the durable `roots.json`, and when neither knows the root the
  refusal says so — never an install that writes a mailbox nobody reads), an unwritable `<common>/hooks` (a real write
  probe, path in the message) and a foreign hook without `--force` (naming the file). All exit 4. Integration case 5
  covers the first three.
- **The spool reader is on the tick.** `RootRuntime.readHookSpoolLocked` runs before the latch and before any pass:
  one `stat` per tick, a read only when the file grew, the **offset per root** (the tick and the delivery are per root;
  a root that joins starts at the spool's current end, so a restart replays nothing), lines from an earlier second than
  the daemon's start discarded, a backlog over 512 lines dropped with one log line, and the shrink path exercised when
  the hook truncates the file. A line is attributed by its worktree: **this root** (a tree event), **a served sibling**
  (dropped), or **unserved** (a repo-wide finish for every served root of the repository, `head_batch` = that root's
  current head) — the `Guard.isServed` snapshot answers the sibling question without taking the host's roots mutex.
  `prepared` is a start written as the line is read, `committed` is a finish **queued for `runPassLocked`'s tail** (the
  same place the metadata finish is written, after the batch and its `STATE`), `aborted` is written at once. Kinds come
  from `hooks.signalOf`: `post-checkout`'s flag → `branch`/`checkout`, `post-merge` → `merge`, `post-rewrite` →
  `rebase`/`other`, `post-index-change` → `index`, `post-commit` → `commit`; `reference-transaction` alone is `other`,
  because the spool line records the phase and not the ref names (consuming stdin is the one thing that can block a
  hook). `source = hook` on every one of them, and `git_events`/`git_passes` move for them exactly as for the timeline
  (integration case 1 asserts both counters).
- **The hook's body was tightened (the one change to the previous pass's module).** A hook is a process per git
  operation and git fires `reference-transaction` per phase per transaction; on this host each spawn of git's bundled
  `sh` or an msys utility costs 25–50 ms, and the first body made a one-file checkout take **3.3 s instead of 33 ms**.
  It now exits before any work on `preparing` (a notification phase this daemon does not read), asks git for the common
  dir *and* the worktree in **one** `rev-parse` (split with `IFS`, no second process; the two-call form remains the
  fallback for git < 2.31), runs `sed` only when a path actually contains `"` or `\`, and runs a chained original first
  with `"$@"` untouched. Measured after: **1.1–1.35 s** for the same checkout. The line format, the marker, the cap and
  the API are unchanged; the cost is recorded in `FORMAT.daemon.md` § 6a and § 8 rather than left as a surprise.
- **Integration cases** (`test/daemon.test.mjs`, appended; a real `git` in `.tmp/`): (1) with the metadata watch
  **disarmed** (`FSMETA_GIT_ARM=off`, a test-only guard documented in `FORMAT.daemon.md` § 8) a real checkout still
  produces a start before the finish, the finish after that client's `END_BATCH`, `head_batch` = that generation, every
  frame `source = hook`, and the counters move; (2) a hook fired in an **unserved** worktree reaches the served root
  through the common spool, creates no `.fs-meta` there, and publishes no batch in the served tree; (3) **install works
  with no daemon** (the answer comes from `roots.json`), refuses a foreign `post-checkout` without `--force`, chains it
  with `--force`, `status --json` reports `ours`/`chained` + the spool size, a real checkout still runs the user's hook,
  and **uninstall restores it byte for byte**; (4) a line older than the daemon's start is ignored and a spool past the
  cap is truncated by the hook (with the next real checkout still read — the shrink path) rather than replayed;
  (5) `install` refuses `gitwatch off` (and `core.hooksPath`, and an unwritable hooks path) with the reason in the
  message.
- **Docs.** `FORMAT.daemon.md` § 2b has the third event source (attribution, phases, ordering, age/bounds, the
  `other` kind, both sources reporting one operation, sleeping/`gitwatch` behaviour); § 4 documents the per-root
  `gitwatch` field; § 6 lists the three commands and § 6a is the hook contract, refusals, spool and the measured cost;
  § 8 records the test guard and the Windows spawn cost. `FORMAT.socket.md` § GIT_EVENT says what `source = hook`
  means (kinds, phases, ordering, both sources, per-pass coalescing). `plans/worktrees.md` § 7's M5 row needed no edit;
  this paragraph is the evidence.
- **Gates.** `zig build test` with a fresh cache (`--cache-dir .zig-cache/m5b-fresh2`) — **726/734 tests passed
  (8 skipped), 0 failed**, 50/50 steps; `zig build` and `zig build watcher` — 4/4 steps each (the executable path,
  which `zig build test` leaves lazy); `bun test test/daemon.test.mjs` — **36/36**; `bun test js test` — **124 passed,
  4 skipped, 0 failed**.
- **Not met, or worth knowing.** The read-only-`<common>` case is exercised with a **file where the `hooks` directory
  belongs** (the portable way to make the write fail on this host); Windows has no read-only directory attribute that
  blocks creation, so a real ACL was not used. A hook line's `reference-transaction` kind is `other` (no ref names in the
  line, by design). A checkout fires several ref transactions on this git (three committed, two aborted), so it
  produces a start/finish pair per transaction and one pass per finish that lands after the previous quiet period —
  coalescing is per `(kind, phase)` per pass, and the frame count is git's behaviour, not the daemon's. `install` cannot
  see a **global** `core.hooksPath` when git is not on `PATH` (documented). The metadata-arm test guard is a test-only
  environment variable; it is not a user switch and changes nothing but whether the watcher is armed.




**M6 status (2026-10-27): done, with the hook route deferred to M5.** Evidence, criterion by criterion:

- **Seed (`src/seed.zig`, `Host.addRoot`).** The § 5e conjunction is checked: same common dir, base last pass settled
  (`snapshot` succeeds with no `last_error`), matching `scan` blocks (`hashMode`/names/respect/nested/`ignoreSources`),
  byte-identical `.fs-meta/ignore`, base trio readable and valid. The seed publishes a generation-1 trio (own
  `created`/`updated`/root identity, same `scan` block) and genesis batch 1; the next pass publishes the diff. The
  copied metadata is refreshed from the new checkout, and every copied hash is verified once against the checkout
  (a same-size branch edit and `core.autocrlf`'s `\n`→`\r\n` are both detected); a mismatch drops that hash so the
  diff pass hashes exactly that file. `last_pass_hashed` is the measurement. A failure after the copy removes the
  seeded files and batch and falls back cold; an existing archive is never overwritten. The seed runs **before** the
  nested-root guard, so a worktree adopted inside its base still sees the base's pre-guard ignore bytes.
- **Live discovery.** `on_worktree` is a per-root record (`ignore` default, `serve`) copied from `defaults`, with
  `root add --on-worktree`. A worktree metadata event (gitwatch on) or the pass that confirmed the boundary (gitwatch
  off) queues a signal; the daemon's bounded task (32 signals / 3 s per drain) confirms and adopts through the same
  `root.add` path (seed included). The default reports and adds nothing; the parent's trio already excludes it.
- **Removal.** `<common>/worktrees/<id>` disappearing marks the matching root `missing` immediately (watches disarmed,
  archive untouched); a changed `gitdir` back-pointer (`move`/`repair`) marks the old path missing; `prune` is the same
  disappearance. `locked` missing roots are never reaped, and history is deleted only by an explicit `root remove`
  with `on_remove = delete` (the existing test still covers that). The removal reaction is gated by the affected
  root's `worktrees`; with it off there is no reaction.
- **`worktrees = off`** gates seed, adoption, `worktree` events and the removal reaction; the boundary rule still
  keeps the worktree out of the parent's trio, and an explicit `root add` serves it as an ordinary cold root.
- **Tests.** `src/seed.zig` unit cases (copy/genesis/diff hashed=2 including a same-size edit, refusal on differing
  ignore/scan/existing archive); `test/daemon.test.mjs` appends `a worktree added to a served repository is seeded, and
  worktrees=off falls back to a cold scan`, `a worktree discovered live is adopted when on-worktree serve is set, and
  ignored by default` (including pass-time discovery with `gitwatch` off and the `worktrees=off` negative), and `a
  vanished worktree root becomes missing immediately and keeps its archive`.
- **Gates**: fresh-cache `zig build test` — 50/50 steps, **726/734 tests passed (8 skipped), 0 failed**; `zig build`
  — 4/4 steps; `zig build watcher` — 4/4 steps; `bun test js test` — **124 passed, 4 skipped, 0 failed**.
- **Left open**: the hook-source route for worktree events is not exercised (M5's spool reader is now in, but M6's
  discovery uses the metadata/pass routes; a hook line reaching `worktree` would be the same queue); the seed verifies
  copied hashes rather than trusting the plan's mtime/size premise, so the first *pass* is small but the seed itself
  reads the checkout; `on_worktree` has a record field and an early CLI flag, with the full M7 documentation to come.




**M7 status (2026-10-27): done.** The CLI and the documents now say the same things. Evidence, criterion by criterion:

- **`root set <id> worktrees off|on` and `gitwatch off|on`.** Both are two-word settings like `mode`/`idle`, parsed by
  `daemon/cli.zig`, carried by `control.Request`'s existing `worktrees`/`gitwatch` booleans, persisted to `roots.json`
  and applied live by `RootRuntime.setWorktrees`/`setGitwatch`; the reply carries the root object, so the new values are
  reported. `gitwatch = off` releases the shared metadata arm, forgets `$GIT_DIR`/`$GIT_COMMON_DIR` (so `head`,
  `detached`, `in_progress`, `worktree` and `common_dir` are empty at once), drops the queued timeline/hook signals and
  swallows a burst the watcher had already handed to the scheduler; `on` resolves and arms again. `worktrees = off`
  drops a pending worktree start/finish and stops adoption, seed, `worktree` events and the removal reaction (the
  runtime gates them on the same field), and **never** hides a boundary: the engine's rule does not consult it. The
  **effective** value is applied, so `FSMETA_WORKTREES=0`/`FSMETA_GITWATCH=0` still wins; a live flip they mask says so.
- **`roots list` marks and groups.** The root snapshot gains `worktree: bool` and `common_dir: string`, filled from the
  M3 `self.git` location (`is_gitfile`, `common_dir`) and empty/false with `gitwatch` off or outside a repository;
  `--json` remains the flat array with both fields. Text output uses **sorted adjacency**: roots of one repository are
  contiguous, sorted by common dir, under a `repo <common dir>` header, with a `worktree` marker on a linked-worktree
  line and roots without a repository last. The marker and grouping are host state (they describe where a root sits)
  and are not gated by `worktrees`; that is the one place this milestone follows M7's explicit field rule rather than
  § 5h's summary list, and `FORMAT.daemon.md` § 4/§ 6 state the result.
- **`fsmeta exclude <root>`** is a top-level engine command, not a daemon one (`src/fsmeta.zig` +
  `ignores.appendExclude`). It resolves the root by opening it, confirms the `.git` entry with the boundary rule, and
  appends the marked block `# fsmeta: our own directory` + `.fs-meta/` to `<common>/info/exclude` — LF bytes, atomic
  temp+rename, `info/` and the file created when missing, skipped when the block is already present. A path that is not
  a repository is refused with exit 1 and the path in the message. Tests cover idempotence, preserved user lines, LF
  bytes and the refusal; a later `!` line overriding the entry is documented (`FORMAT.daemon.md` § 6b, `README.md`).
- **`root add --worktree` and `--nested`.** The plan defines only the row, so the minimal defensible semantics are
  these, and they are documented in `FORMAT.daemon.md` § 4 and the CLI usage: `--worktree` **asserts** a linked
  worktree (`.git` is a gitfile whose target is an existing directory; checked by `gitdir.linkedWorktree`), refuses a
  plain directory, a nested clone or a broken gitfile with exit 4 and the path, takes the adoption/seed path for that
  explicit add (it forces `worktrees` on for the new record unless an env override wins), and rejects the contradictory
  `--worktrees off` combination. `--nested` is an **acknowledgement only**: the M2 guard still writes the parent's
  managed line and still refuses when it cannot; the flag weakens nothing, is not persisted, and is echoed as
  `"nested":"acknowledged"` in the reply.
- **`daemon status`** already reported both effective flags and both `*_override` fields from M0; the CLI and the docs
  now point at the same names (`worktrees`, `gitwatch`, `worktrees_override`, `gitwatch_override`), and `root add`/
  `root set` resolve the effective value the same way at add time and on every flip.
- **Documents.** `README.md` has the two-switch table, the `FSMETA_WORKTREES=0` / `FSMETA_GITWATCH=0` emergency
  command, the *the scan rule is not one of the switches* paragraph and the `git worktree remove`/`exclude` caveat.
  `AGENTS.md` § 2 gained the three invariants (*a boundary is ignored, not scanned twice*; *finish never precedes its
  batch*; *every worktree/git feature is behind a switch tested in both states, and the boundary rule is not a
  feature*). `FORMAT.daemon.md` § 3/§ 4 carry the two switches in `roots.json` and the root object, § 4 has the live-flip
  and add-flag semantics, § 6 adds `exclude` and the two `root set` forms, and § 6b is the file/refusal contract.
  `FORMAT.socket.md` § GIT_EVENT now opens with *git events are a daemon feature* and keeps the `serve` asymmetry.
  `FORMAT.md` § 7/§ 16 were checked against the implementation and needed no change (`nestedRepos`, `ignoreSources`,
  source precedence and the "no switch turns the rule off" sentence already match `engine.zig`, `json_doc.zig`,
  `ignores.zig` and `boundary.zig`).
- **Tests.** `test/daemon.test.mjs` appends a `the M7 CLI` block: `roots list` grouping/marker and `--json` fields;
  `root set gitwatch off` clearing the git fields and releasing the arm, `on` restoring them; `worktrees off` producing
  no `worktree` event for an add, `on` producing one, and the boundary still absent from the trio with the handling off;
  `--worktree` refusal and acceptance; `--nested` acknowledgement with the parent's managed line still written;
  `exclude` idempotence/preservation/LF and the non-repository refusal. `src/gitdir.zig` gained
  `linkedWorktree` with a unit test, and `src/ignores.zig` the `appendExclude` cases.
- **Gates.** `zig build test` with a fresh cache (`--cache-dir .zig-cache/m7`) — 50/50 steps, **746/754 tests
  passed (8 skipped), 0 failed**; `zig build` — 4/4 steps; `zig build watcher` — 4/4 steps; `bun test js test` — **127
  passed, 4 skipped, 0 failed**; `bun test test/daemon.test.mjs` — **39/39**.
- **Left open.** The M7 row says "CLI and docs"; the two flags' behaviour inside a *worktree* root remains what M6
  built (its own `worktrees` gates the removal reaction), and the product choices recorded in § 8 (gate defaults and
  the migration default) are untouched. `--nested` does not detect whether the path really is nested: it is an
  acknowledgement, and the guard is the enforcement; a caller that passes it on a non-nested path only records an
  inaccurate intent.

### Gap closure batch (2026-10-27, after M7)

Three items M0–M7 had recorded as open, plus the two defects the work uncovered:

- **The Linux watch bound was misrecorded.** `INotify.zig` never calls `should_watch`, but nightwatch's generic layer
  does (`nightwatch.zig:362-363` at arm time, `:271-272`/`:319-320` for a directory created later;
  `filters_watches = !watches_recursively`, `:128`), so the predicate was already honoured on inotify. The closure
  batch pinned the vtable path and the per-platform `filters_watches` contract in `gitwatch.zig` tests, corrected
  § 5b and the M3 status, and added `test/watch-bound.test.mjs`: on Linux it builds a repository with 120 `objects/`
  directories, a linked worktree and a 40-directory nested clone, then asserts both the metadata arm's registration
  count and the tree arm's stay bounded and that the log says the predicate is honoured. It skips, with its reason, on
  every host without per-directory registration (this Windows one), so Linux CI owns the number.
- **The tree arm had no predicate at all** (G35's real remainder): `EventHandler` was change/rename only, so on
  kqueue/inotify the working-tree arm registered every boundary and `.git/objects`. `gitwatch.shouldWatchTree` now
  admits the served root, refuses `.git`/`.fs-meta` and a confirmed boundary, and reads a gitfile from a fixed stack
  buffer on the watcher thread; a pass whose boundary count increased re-arms the watcher once so a worktree added
  after the arm is not registered either. Unit test: root-as-worktree, internal names, ordinary dir, clone, stray
  `.git`, gitfile, file events.
- **A failed finish is now an integration case** (M4), and **a hook cannot carry the worktree kind** is pinned with
  the measured spool facts (add fires ref transactions/`post-checkout` in the new worktree; remove leaves at most one
  `post-index-change "0 0"`), so every `worktree` frame is `source = metadata`.
- **The last worktree's removal** used to emit no finish: deleting the empty `<common>/worktrees/` makes
  ReadDirectoryChangesW deliver the parent, which carries no id. `<common>/worktrees` is now sampled once per
  half-second (one `stat`), and a present→absent transition emits the single `finish(path_len = 0)`, deduplicated
  against the event path. Integration: with no sibling worktree, `git worktree remove` produces it.
- **Gates for the batch**: fresh cache (`--cache-dir .zig-cache/final2`) — **50/50 steps, 755/763 Zig tests
  (8 skipped), 0 failed**, exit 0; `zig build` and `zig build watcher` — 4/4 each; `bun test js test` — **130 passed,
  4 skipped, 0 failed** (134 tests); `bun test test/daemon.test.mjs` — **42/42** (39 M0–M7 + failed finish + hook
  worktree facts + last-worktree removal).

## 8. Decisions taken (2026-10-27)

Each was an open question in the first draft; each is now a decision, with the reason, and the milestone that implements
it. Anything that is still a choice is marked as such — there are two, both product calls.

1. **Submodules follow the same boundary rule.** A submodule checkout has the same `.git`-file marker (or a `.git`
   directory, § 4), and the alternative — detecting only gitdirs under `worktrees/` — is a weaker test that fails for
   relative links. The rule is **general** (a nested repository, of which a worktree is one case), so there is no
   per-kind opt-out and it is not one of the switches; git's own choice to describe a submodule as one entry supports
   it. **M0.**
2. **Format: additive, no version bump.** `scan.nested_repos` and `scan.ignore_sources` are new keys in the existing
   `scan` block; the ports already preserve unknown keys (`json_doc.zig`), a conformance vector pins the behaviour, and
   `FORMAT.md` § 5/§ 9 records both. A reader that predates them still validates the trio. **M0/M1.**
`scan.nested_repos` is **optional**, and absent means *the writer did not apply the rule* (not "the tree has no
   nested repositories"): only the reference engine writes `true`, and a port writer that does not implement the rule
   omits the key rather than claiming it. A reader therefore never infers the rule from absence.
3. **The internal ignore is `.fs-meta/ignore`, and `info/exclude` joins the chain.** Writing our own file avoids
   touching the user's tree; reading git's repo-local exclude closes a real `.gitignore`-compatibility gap (it was
   never read) and gives a user a place to exclude a path without fs-meta's help. The global `core.excludesFile`
   stays out: it would make the trio depend on the machine. Precedence: chain → `info/exclude` → `.fs-meta/ignore`, no
   cross-source negation (§ 5). **M1.**
4. **A discovered worktree is excluded by the rule, never served automatically.** The scan rule already keeps it out of
   the parent (R1); serving it is a second decision, and a watcher per agent worktree is precisely the balloon the field
   report describes. Opt-in only: `--on-worktree serve` on `root add`, recorded per root in `roots.json`; the default is
   report-only. **M6.**
5. **The parent never writes the child's `.fs-meta`.** Guaranteed by the boundary rule and by R2's refusal, and pinned
   by a test anyway — it is the collision the guard exists to prevent. **M2.**
6. **One metadata watcher per common dir.** A linked worktree's `$GIT_DIR` is `<common>/worktrees/<id>/` and a
   submodule's is `<common>/modules/<name>/`, so the common dir is the single tree that covers every root of a repo; the
   arm is on it, and events reach roots by path prefix. One `refs/` tree watched once, not once per worktree. **M3.**
7. **Hooks are installed per repository, never automatically.** `hooks install <root>` / `--all`, `hooks status` reports
   coverage, `root add` prints the command when hooks would improve precision. Their spool is `<common>/fsmeta-events.log`
   — per repo, not per root, because the hook runs in whichever worktree git is operating on (possibly one fs-meta does
   not serve), and a per-root spool would create `.fs-meta` there. `daemon stop` touches nothing: hooks keep working
   without a daemon, the spool is capped by the hook itself, and removing the hooks is a separate `hooks uninstall`.
   **M5.**
8. **Seed validity is a conjunction, not a heuristic** (§ 5e): same common dir, the base's last pass completed, matching
   `scan` blocks, byte-identical `.fs-meta/ignore`, base trio readable and valid. Anything else falls back to a cold scan. **M6.**
9. **Git events stay on the consumer socket; the control plane only summarises.** A stream on the control socket would
   be a second protocol for no consumer, so `root status` reports `last_git_event` and the stream is the root socket's.
   **M4.**
10. **A worktree appearing or disappearing is a repo-wide event with a path.** The one fact a root's stream cannot name
    locally is *which* worktree; so `GIT_EVENT` is variable-length exactly for `kind = worktree` (a `u32 path_len` plus
    the path) and is sent to every served root of that repo, while root-specific events stay 20 bytes and carry no path.
    **M4.**
11. **An ignore-file change must reach a pass.** `info/exclude` arrives through the metadata watch; `.fs-meta/ignore` is
    dropped by both watchers, so a hand edit takes effect on the next pass — bounded to 60 s by the safety net that
    already exists — while the daemon's own writes force one immediately. The engine re-reads both files every pass, so
    no extra state (no mtime) is needed. **M1.**
12. **The handling is gated; the scan rule and the nested-root guard are not** (§ 5h). `worktrees` gates worktree
    *recognition, adoption, seeding, worktree events and the removal reaction*; `gitwatch` gates the metadata watch,
    latch, events and hooks. Both are per root with daemon defaults, plus `FSMETA_WORKTREES=0` as an override that wins
    over everything and needs no working control socket. What neither switch touches: the boundary rule (a nested
    repository is never scanned, worktree or not), `scan.nested_repos` as its record, `info/exclude` reading, and R2's
    nested-root guard. A gate that changed what a trio describes would be a second format, not a switch; a gate that
    re-enabled duplicate scanning would be worse than the bug it works around. **M0 (flag plumbing + rule), M2 (guard),
    M3/M4/M5 (`gitwatch`), M6 (`worktrees` handling), M7 (docs).**

**Still genuinely open, and deliberately small:**

- **The gate defaults.** `worktrees` and `gitwatch` are proposed **on**, with the kill switch available from the first
  release (§ 5h). Whether the first release should instead ship them **off** until a few weeks of use have passed is a
  product call, not a design one: the code paths are identical, only the default differs, and `FSMETA_WORKTREES=1`
  exists for the early adopter either way.
- **The migration default.** The rule publishes a deletion batch for existing trios that contain boundary names, with a
  one-line notice. Whether `nested_repos` should default to `false` for trios written before the key existed (a quiet
  upgrade) or to `true` (the rule, applied at once) is a product call; the plan implements `true` with the notice and
  leaves the default controllable per root. **Decide before M0 ships, not before M0 starts.**
- **A shared watcher arm** was the second open question and is now answered by the common-dir arm (§ 10): the metadata
  arm is usually outside every served root, so there is nothing of the root's to share, and one arm per common dir is
  the design.

## 9. Why this order

M0 is the cheap half: detection during a listing we already do, the format sentence that makes the behaviour
defensible, **and the gate plumbing (§ 5h) — first, so every milestone after it can be turned off without a rebuild; the
gate covers the handling, never the rule.** M1 makes the exclusion durable and consistent across writers, which R2 needs.
M2 is the rule change the user asked for, and it deletes code (the warning) rather than adding a mode. **M3 comes before
the events on purpose:** a pass that runs mid-checkout publishes a half-written tree, and no event ordering can repair a
wrong batch — the latch is what makes the later finish-before/after guarantee meaningful. M4 is the consumer contract.
M5 adds precision without a second contract (hooks feed M4's pipeline). M6 is the adoption path, where
`remove`/`move`/`prune` policy and the seed are decided. M7 is the documentation debt that keeps the rules — and the
switches — from being rediscovered.

**Implementation surface, so nobody rediscovers it:** `scan.zig` (its own `IgnoreFrame` stack over `gitignore.Rules`,
which is where the two root-level sources plug in — the library already parses a byte string into `Rules`, so no upstream
change is needed); `lister.zig` (`visible()` plus the boundary detection, which must run on the unfiltered listing);
`engine.zig` (`Options`, the scan block); `json_doc.zig` and `publish.zig` (the two `scan`-block writers); `cache.zig`
(if the ignore sources travel with it); `daemon/root.zig` (the watcher predicate, latch, git events); `daemon/host.zig`
(the managed block, reconciliation, flags); `daemon/registry.zig` (defaults and records); `daemon/control.zig` and
`daemon/cli.zig` (flags, `hooks`); `fsmeta.zig` (the top-level `scan --json`, `ignored`, `exclude`); a new
`daemon/hooks.zig` (generate, install, uninstall, status); `wire.zig` and `server.zig` (`GIT_EVENT`);
`conformance/gen-vectors-v2.mjs` (the nested-repository vector); `FORMAT.md`, `FORMAT.socket.md`, `FORMAT.daemon.md`.

## 10. Reviews: what was missing, and what it changed

Ten reviews so far, all checked against the code (`lister.zig`, `scan.zig`, `cache.zig`, `coldstart.zig`,
`src/main.zig`, `wire.zig`, `json_doc.zig`, `daemon/root.zig`, the ports' writer code, `nightwatch`'s backends) and
against `git-worktree(1)`/`gitrepository-layout(5)`. The first (G1–G17) found the hook, ordering and scoping defects;
the second (G18–G28) found contradictions the first review's edits had introduced, one design simplification and one
correctness problem with manual moves; the third (G31–G34) found a superseded entry (G5 vs G24), three wrong paths
(`worktrees/` under `$GIT_DIR`, `logs/HEAD` under the common dir, hooks under the wrong dir) and one detection gap (a
`.git` entry appearing inside an existing directory); **the fourth (G35–G40) went to the code the plan will change** and
found that the boundary rule never reached the watcher, that a parent added after its children was unguarded, that the
managed block had no lifecycle, that the ports carry writer code that could claim the rule, that the add path never said
what an asleep parent does, and that the hook install was described as needing a daemon; **the fifth (G41–G45) found the per-repo watcher arm was never refcounted, that a `git fetch` would storm the socket with one event per ref, that the adoption policy and the spool read had no owner, that grouping by common dir had no field to group by, and that the implementation surface named the wrong file for the top-level `scan`/`ignored`/`exclude` commands; **the sixth (G46–G48) found the pruning mechanism missing on the one platform where the balloon happens (`INotify.zig` never calls `should_watch`), that `--no-gitignore` could disable the guard and fork the two writers, and that a protocol bump would have made `serve` and the daemon disagree; **the seventh (G49–G52) found the tree arm's pruning claim unachievable on Linux (the fallback covers only the metadata arm), that a hook had no way to find the spool after a repo move, that the event meanings were under-specified, and that `fsmeta exclude` was neither marked nor idempotent.** **the eighth (G53–G56) found the managed ignore block had no writing or ordering rules, that repo-wide events went to roots that opted out of git handling, that the worktree event phases were undefined, and that the metadata arm could die silently because only the tree watcher was re-armed.** **the ninth (G57–G59) found a broken git link treated as an error instead of a state, that existing `roots.json` records predate the flags with no rule for what they resolve to, and that a newline in a path could break the line-based hook spool.** **the tenth (G60–G63) found the prototype would keep a second copy of the latch, that the parent-visibility check read like a full scan, that the managed block had no write discipline against a concurrent pass, and that `--git-common-dir` can be relative while a hook does not control its cwd.** **Every gap is now folded into
the plan or decided in § 8**; two product-level choices remain open there (the gate defaults and the migration default),
and the watcher-sharing question is answered by the common-dir arm.

| id  | gap                                                                                                 | severity                                                              | state                                                                                               |
| --  | ---                                                                                                 | --------                                                              | -----                                                                                               |
| G1  | **A failing hook aborts the user's git operation.** A non-zero `reference-transaction` terminates the ref transaction, so a full disk or a missing spool directory would break `git commit`. | would break the user's repo | **folded**: § 5c now requires `exit 0` on every path, no blocking calls, and `printf … 2>/dev/null \|\| true`. |
| G2  | **A git finish with no file event would wait for a burst that never comes** (`git commit --amend`, a checkout to identical content). | the event never fires                | **folded**: § 5b rule 3 — a finish forces a pass; § 5d rule 3 — the finish follows a pass that published nothing. |
| G3  | **A repo-wide signal (a commit's ref update) would make every root of the repo pass**, including worktrees whose trees did not change. | N passes per commit                | **folded**: § 5b "tree-changing versus repo-wide" — `$GIT_DIR` change passes its root, `$GIT_COMMON_DIR` change is an event for all roots. |
| G4  | **`.git` is invisible to the working-tree watcher**, so a root that becomes a worktree (or is repaired/moved) never re-arms the metadata watch. | stale watch               | **folded**: § 5b "resolve the git dirs per pass".                                                   |
| G5  | **The `worktree` event kind could not identify its worktree** in a 20-byte frame.                   | unusable event                                                        | **superseded by G24**: the kind was dropped, then re-added as a variable-length frame carrying the path; discovery is a repo-wide `worktree` event and `roots list` still says what is served. |
| G6  | **A hook written with CRLF does not run under `sh`**; a hook without the exec bit does not run on POSIX. | hooks silently never fire                                        | **folded**: § 5c — POSIX sh, LF bytes, exec bit, and a byte-level test.                             |
| G7  | **Start without finish** (hook failed, daemon died) would tell a consumer a write is in progress forever. | consumer stuck in "in progress"                                 | **folded**: § 5d rule 6 — `aborted` and `status = timed out` after a bound.                         |
| G8  | **A stale spool replays old git operations as fresh events** after a daemon restart.                | wrong events                                                          | **folded**: § 5c — dated lines, discard older than start, rotate at a cap.                          |
| G9  | **Seeding copied `files.json` verbatim** would carry the base's generation and `created` into a new archive. | wrong generation lineage                                     | **folded**: § 5e — rewrite the document for generation 1, and remove the seed if the pass fails.    |
| G10 | **The migration is a deletion batch.** Every existing trio that contains submodule/worktree content loses those names on the first pass after the rule lands. | surprising and visible | **folded into M0**: one-line notice on both the CLI and the daemon log; the batch still publishes (the rule is the truth). `nested_repos` records the rule as `true`; it is not a switch, and the one remaining product call (the migration default) is recorded in § 8. |
| G11 | **`git worktree remove` of a served worktree** was feared to fail on Windows because of our handles. | removal fails halfway                                                | **corrected and folded**: `nightwatch` opens with `FILE_SHARE_DELETE`, so the watcher does not block the delete — what *does* block it is `<worktree>/.fs-meta` being untracked, hence `--force` or an `info/exclude` line; the daemon reacts to `worktrees/<id>` disappearing by disarming and marking `missing` (§ 5f). |
| G12 | **Not every directory with a `.git` is a repository** (a stray `.git` directory, a fixture).        | false boundary                                                        | **folded**: § 4 — a *file* marker is confirmed by the `gitdir:` pair, a *directory* marker by `HEAD` (a `ref: …` line or 40 hex) plus `objects/`; anything else is listed normally. |
| G13 | **The internal ignore must use the existing pattern engine.** A bespoke path matcher would diverge on spaces, `[id]`, `!`, trailing slashes — and `AGENTS.md` § 2 forbids a second wildcard implementation. | future inconsistency | **folded**: § 5 "same `gitignore` reader", plus the source precedence and the no-cross-source-negation rule. |
| G14 | **`serve` (non-daemon) has no scheduler**, so a consumer of `fsmeta serve` gets no git events.      | feature asymmetry                                                     | **decided**: § 5g and `FORMAT.socket.md` state that git events are a daemon feature; `serve` remains the simple path. |
| G15 | **The ordering contract needs a deterministic test**, not a race.                                   | unverifiable promise                                                  | **folded**: § 5d — a unit test of the flush order with a recording writer, plus an injected slow pass for the integration case. |
| G16 | **A consumer cannot see *why* a subtree is absent** (boundary vs `.gitignore` vs internal ignore).  | debuggability                                                         | **folded into M0/M1**: `scan --json` carries `boundaries` and `ignored_sources`; `fsmeta ignored` names the deciding source per path (§ 5g). |
| G17 | **The git state itself is not visible.**                                                            | diagnostics                                                           | **folded into M3/M7**: `root status` gains `head`, `detached`, `in_progress` and `last_git_event`; `roots list` gains a `worktree` column (§ 5g). |
| G18 | **§ 3's caveat table still claimed the watcher blocks `git worktree remove`**, contradicting § 5f.  | an internal contradiction                                             | **fixed**: the row now says the handle allows deletion and the blocker is the untracked `.fs-meta`. |
| G19 | **A stale `gitdir` back-pointer** (a manual move, which is what `git worktree repair` exists for) made the § 4 test reject a worktree fs-meta can describe. | a real worktree becomes invisible | **fixed**: the target's existence is required, the back-pointer only confirms; M0 tests the stale case. |
| G20 | **The main worktree's `$GIT_DIR` *is* the common dir**, so the directory-based "tree-changing vs repo-wide" split would have classified its `HEAD` change as repo-wide and never passed its root. | missed passes on the main worktree | **fixed**: the split is by **path** (`$GIT_DIR` file set vs everything else), with the main-worktree case as an M3 acceptance. |
| G21 | **A shared `refs/**/*.lock` would have blocked every root of the repo's passes** ("refuse a pass while any lock exists"). | a commit in one worktree stalls the others      | **fixed**: the latch is per root and only `$GIT_DIR/*.lock`; a shared ref lock is an event, not a pass blocker. |
| G22 | **The per-root hook spool would have created `.fs-meta` in worktrees fs-meta does not serve**, and missed events for a worktree whose root did not exist yet. | foreign writes, lost events | **fixed**: the spool is per repo at `<common>/fsmeta-events.log`, capped by the hook itself; M5 tests an unserved worktree. |
| G23 | **`on_remove` applied to a `missing` root** would delete the history of a worktree that was merely unmounted (the `locked` case). | data loss                               | **fixed**: `on_remove` applies only to an explicit `root remove`; a `missing` root keeps its batches. M6 tests it. |
| G24 | **Worktree events had been dropped from the wire** although the requirement named "adding worktrees" as something to detect. | a missing event type                         | **fixed**: `GIT_EVENT(kind = worktree)` is variable-length (path) and repo-wide; every other kind stays 20 bytes (§ 5d). |
| G25 | **`reference-transaction` was called "the backbone" without evidence** of which hooks fire per operation. | an unvalidated dependency                                       | **fixed**: M4 opens with a coverage spike (switch, checkout, commit, amend, merge, rebase, reset, stash, worktree add/remove/move, fetch) whose table is appended to this plan. |
| G26 | **A hand edit of `.fs-meta/ignore` never reached a pass** (`.fs-meta` is dropped by both watchers). | ignore changes take effect "some day"                                 | **fixed**: no state is needed — the engine re-reads both ignore files every pass, `info/exclude` is seen by the metadata watch, and a hand edit of `.fs-meta/ignore` waits at most the 60 s safety-net interval (§ 5b, M1). |
| G27 | **`verify --verbose` was promised to recompute ignore verdicts**, which § 5g forbids (verify does not rescan). | a contradictory promise                                    | **fixed**: verify reports the recorded `scan` keys; the current state is `scan`/`ignored`.          |
| G28 | **`status = failed` claimed the consumer "already has `last_error`"** — it does not; `last_error` is control-plane only. | a false guarantee                                | **fixed**: § 5d rule 5 says the status is the consumer's only signal and points it at `root status`. |
| G29 | **The whole feature had no off switch**, although it changes what a trio describes, watches `.git`, installs hooks and can publish large deletion batches. | a misbehaving feature that cannot be stood down | **added on request**: § 5h — `worktrees` and `gitwatch` per root with daemon defaults, `FSMETA_WORKTREES=0` as an emergency override that needs no control socket, and every milestone tested with its flag off. **The ignore rule is not one of the switches** (recorded as G30): off stops the worktree handling, never the boundary rule, because a trio that descended into another repository would not be describing one tree. |
| G30 | **The boundary rule was gated as part of "the worktree feature"**, so disabling worktrees would have re-scanned nested working copies — the very duplication and collision the rule exists to prevent. | the switch would re-create the bug it works around | **fixed on request**: the rule is general (a nested repository, worktree or not: clone, submodule, linked worktree) and always on; `scan.nested_repos` records it, no flag flips it, and `worktrees=off` only stops the handling (adoption, seed, worktree events, removal reaction) — § 5, § 5h, M0/M2/M6. |
| G31 | **`.git` was written in the wrong place** in three places: the administrative directory and `prune` under `$GIT_DIR`, and `logs/HEAD` under the common dir although it is per-worktree. | a reader following the plan would watch the wrong paths | **fixed**: `$GIT_COMMON_DIR/worktrees/<id>`, `$GIT_DIR/logs/HEAD`, `$GIT_COMMON_DIR/logs/refs/**`, and hooks under `$GIT_COMMON_DIR/hooks`. |
| G32 | **G5 still said the `worktree` event kind was dropped**, while G24 had re-added it — two entries contradicting each other. | a stale changelog                              | **fixed**: G5 is marked superseded by G24.                                                          |
| G33 | **A `.git` entry appearing inside an existing directory was invisible to both watchers** (the working-tree filter drops `.git`), so a new worktree could stay unscanned for up to the 60 s safety interval. | a slow detection on a common flow | **fixed**: § 4 — `noteEvent` special-cases a `.git` creation and forces a pass; M0 tests it. |
| G34 | **The seed validity check compared `scan.ignore_sources` (the list of sources) rather than the ignore files' contents**, so two roots with different `.fs-meta/ignore` files could still seed — publishing an excluded name in the genesis batch. | a transient wrong batch | **fixed**: § 5e requires byte-identical `.fs-meta/ignore`; § 8.8 matches. |
| G35 | **The boundary rule reached the scan but not the watcher.** On Linux the recursive arm registers a watch per directory, so a worktree inside a root would still balloon the watcher — the field report's exact failure — while the trio looked correct. | the resource bug survives the fix | **fixed (closure batch)**: § 5b — `gitwatch.shouldWatchTree` is in the tree arm's `EventHandler` vtable, refusing `.git`/`.fs-meta` and a confirmed boundary and admitting the served root; the daemon re-arms once when a pass sees a new boundary, which covers a directory that existed before its `.git`. Unit test covers root-as-worktree, clone, stray `.git` and gitfile. |
| G36 | **A parent added *after* its children was never guarded.** Only "add a child inside a served parent" was described; adding the parent later left every served descendant visible to it. | duplicate scanning on a legal workflow | **fixed**: § 5 — one managed line per served descendant before the parent's first pass, refused when it cannot be arranged, plus startup reconciliation. |
| G37 | **The managed block had no lifecycle**: nothing said who removes a child's line, what a stale line does, or what happens if a person deletes the file. | a guard that silently stops guarding | **fixed**: § 5 — `root remove` removes the line, a stale line is harmless, and a pass that finds a served child visible to its parent repairs the block. |
| G38 | **Ports carry writer code** (`FsMetaWriter.publish`), so `scan.nested_repos=true` could be claimed by a writer that never applied the rule. | a false format claim          | **fixed**: § 5/§ 8.2 — the key is optional, only the engine writes `true`, absent means "not applied", and the port-writer gate keeps it honest. |
| G39 | **Add-root assumed the parent could be passed**, without saying what an `asleep` or `off` parent does. | an ambiguous step in the common path                               | **fixed**: § 5 — exactly one pass, no watcher armed, the parent returns to sleep; a seed reads the base's trio from disk. |
| G40 | **Hooks were described as if a daemon had to be running**, and the spool timestamp format was unspecified (`%3N` is not portable to git's sh). | an install that cannot work, a timestamp that cannot be parsed | **fixed**: § 5c — install is a local file operation, the timestamp is POSIX `date +%s` epoch seconds, and install checks `<common>` is writable. |
| G41 | **The per-common-dir metadata arm was never refcounted.** Removing the last root of a repo would leave its watcher (and handles) armed for the life of the daemon. | a resource leak with a plausible trigger (agents come and go) | **fixed**: § 5b — the arm is refcounted by the roots that resolve to it; the last removal disarms it; M3 tests add-two/remove-one and remove-the-last. |
| G42 | **A ref-heavy operation would storm the socket**: `git fetch`, `push` or `gc` fires a ref transaction per ref, and one finish per op after one pass is hundreds of frames for a consumer whose signal is "history moved". | a burst that makes the event stream useless precisely when it matters | **fixed**: § 5d rule 4 — coalesce per `(kind, phase)` within a pass; per-op granularity, if ever needed, is a payload field, not a flood; M4 tests a many-ref fetch. |
| G43 | **Adoption policy and spool reading had no owner**: whose `--on-worktree` applies for a worktree found inside a parent, and which daemon reads a repo's spool when no root of it watches git. | an ambiguous, silently inert feature | **fixed**: § 5/§ 5c — the policy is the discovering root's, and a spool is read only while some served root of that repo has `gitwatch` on. The flag matrix is spelled out: the `worktree` event needs `gitwatch` for the signal; adoption at pass time works with `gitwatch` off. |
| G44 | **`roots list` was told to group by common dir, but nothing carried it.** The snapshot had no `git_common`, so the grouping had no data. | a feature with no input          | **fixed**: § 5g — `root status` and `roots list` carry `git_common` (host state like `root`, empty when `gitwatch` is off). |
| G45 | **The implementation surface named the wrong file for `scan --json`/`ignored`/`exclude`** (they are top-level `fsmeta` subcommands, not daemon CLI), the hook module was unnamed, `ignore_sources` did not say whether absent files are listed, the `.git` special case missed renames, and `path_len` had no upper bound. | five small gaps in one place | **fixed**: § 7 surface (adds `fsmeta.zig` and a new `daemon/hooks.zig`), § 5 (`ignore_sources` = consulted only), § 4 (rename), § 5d (`path_len ≤ length − 24`). |
| G46 | **The pruning mechanism was misattributed to the backend file.** `INotify.zig` never calls `should_watch` (kqueue does), and the plan concluded the predicate was unavailable on Linux — but nightwatch's generic `recurse_watch` and interceptor consult it for every non-recursive backend (`nightwatch.zig:362-363`, `:271-272`, `:319-320`). | a fix described as missing that was already in the dependency | **corrected (closure batch)**: § 5b and M3 status state the generic-layer mechanism with file/line evidence; `gitwatch.zig` pins the vtable path and `filters_watches` per platform. The Linux count is asserted by `test/watch-bound.test.mjs`, which skips (with its reason) on hosts where per-directory registration does not exist. |
| G47 | **`--no-gitignore` could disable the guard and fork the two writers**: `refresh --no-gitignore` would publish a nested root's content that the daemon's trio excludes. | two writers, two trios, one tree | **fixed**: § 5 — the flag disables the user's chain and `info/exclude`; the boundary rule and `.fs-meta/ignore` always apply; undoing the guard means removing the nested root. |
| G48 | **A protocol bump would have made `serve` and the daemon disagree.** `wire.protocol` is shared, so bumping for `GIT_EVENT` changes what `serve` announces too, and the plan said nothing about it. | a client that cannot talk to one of the two servers | **fixed**: § 5d — `serve` announces `0x0102` and never emits `0x0A`/`0x09`, documented as the same asymmetry `STATE` already has. |
| G49 | **The "fallback" covered only half the problem, and the premise was wrong.** The plan assumed a recursive inotify arm could not be stopped from registering a subtree; in fact the generic layer consults the predicate for the tree arm too, once the arm supplies one. | an acceptance criterion nobody could meet on the target platform | **fixed (closure batch)**: the tree arm now supplies `shouldWatchTree`, § 5b is rewritten, and the per-platform contract is a compile-time test. The Linux empirical count remains CI work, not an open design question. |
| G50 | **The hook script had no way to find the spool** once a repo moves: an embedded `<common>` path goes stale, and `worktree repair`/a moved clone is a documented case. | hooks that silently stop reporting | **fixed**: § 5c — the script asks `git rev-parse --git-common-dir` (one cheap call) and exits 0 silently on failure. |
| G51 | **Event meanings were under-specified**: which refs map to which `kind`, and that `post-index-change` also fires when `git status` refreshes the index — so an `index` event is not a content change. | a consumer reading more into an event than it means | **fixed**: § 5c — `refs/heads/*` → `commit`, `HEAD` symref → `branch`, `refs/stash`/`refs/notes`/`refs/remotes` → `other`; an `index` event says "the index was written"; coalescing keeps the noise to one per pass. |
| G52 | **`fsmeta exclude` had no idempotence or marker**, so running it twice would duplicate the line and leave no way to recognise our own edit in git's file. | a small command that slowly corrupts a user file | **fixed**: § 5f — a marked, idempotent block (`# fsmeta: our own directory` + `.fs-meta/`), skipped when present. |
| G53 | **The managed ignore block had no writing rules**: no escaping for a path starting with `!`/`#` or ending in a space, no answer for a path containing a newline, and no ordering rule — so a user's `!` line in the same file could re-include a nested root. | a guard defeated by a legal-looking edit | **fixed**: § 5 — escapes, newline refusal at `root add`, and the managed block evaluated **last as its own sub-source**; `fsmeta exclude` documents that a later `!` in `info/exclude` overrides it. |
| G54 | **Repo-wide events were sent to every served root of the repo**, including roots with `gitwatch` off (which asked for no git handling), and `head_batch` on such an event was ambiguous — nothing was published for that root. | an event a root opted out of, with a field that looks fetchable | **fixed**: § 5d — only roots with `gitwatch` on receive them, and `head_batch` is stated to be the receiving root's current head, not a new generation. |
| G55 | **Worktree event phases were undefined**: "start/finish" for an appearing worktree, where the metadata route has no natural finish, and how a removal is reported. | an event consumers cannot interpret | **fixed**: § 5d — start on `worktrees/<id>` appearing, finish from the new worktree's `post-checkout` or a stable confirmation labelled `source = metadata`, removal as one finish with `path_len = 0`. |
| G56 | **The metadata arm can die silently too.** nightwatch ends its thread on a failed completion, and the safety pass only re-armed the *tree* watcher — so a dead metadata arm would stop git events until a restart. | git events silently stop | **fixed**: § 5b — the safety pass re-arms **both** arms when it finds a change. |
| G57 | **A broken git link was treated as an error rather than a state.** A worktree whose `gitdir:` target is gone (or whose `commondir` points nowhere) would have failed or logged every tick, although only `git worktree repair` can fix it. | noise for a user-fixable state | **fixed**: § 5b — the root keeps scanning, the mismatch is logged once, and it has no git handling until the next pass re-resolves a repaired link. |
| G58 | **Existing `roots.json` records predate the flags.** Nothing said what a record without `worktrees`/`gitwatch` resolves to, so an upgrade could silently flip handling off (or on). | an upgrade that changes behaviour without a trace | **fixed**: § 5h — a missing flag resolves from `defaults`, or `on` when the default is absent. |
| G59 | **The spool line could be broken by a path with a newline**, since the spool is line-based — the same class as the managed ignore block, but escapable where that one is not. | a malformed line that loses one event | **fixed**: § 5c — the path is JSON string-escaped; `fsmeta exclude` writes LF endings. |
| G60 | **The prototype (`src/main.zig`) keeps its own copy of the latch.** Lifting the latch into `RootRuntime` while leaving the prototype as-is guarantees drift between two implementations of the same rule. | two sources of truth for batching | **fixed**: § 5b — the prototype is thinned to a debouncer (or deleted), and M3's acceptance already says its `hasGitLock` path is gone; this records why. |
| G61 | **The parent-visibility check looked like a scan.** "Compute the parent's effective scan" would have meant a full walk to decide where to put one line. | `root add` as expensive as a pass | **fixed**: § 5 — a **single-path** evaluation through the ignore chain (depth-bounded file reads), never a tree walk. |
| G62 | **The managed block had no write discipline**: a control-task write could race a pass reading the file, and a tear would silently drop every managed line after it. | a guard that disappears mid-write | **fixed**: § 5 — atomic write (temp + rename, like `roots.json`); `fsmeta exclude` writes its block in one call. |
| G63 | **`git rev-parse --git-common-dir` can print a relative path** (`.git`), and the hook does not control its cwd — so "one cheap call" was not enough. | hooks writing to the wrong place | **fixed**: § 5c — `--path-format=absolute` (git ≥ 2.31) with a resolve-against-the-worktree-root fallback for older git. |

**Two things the review confirmed rather than changed**, so nobody hunts for them:

- `lister.zig`'s `visible()` already hides a `.git` entry **of either kind** (`reserved` is checked before `is_dir`), so
  a worktree's `.git` file cannot leak into a trio today. The detection in M0 is an addition to the listing, not a bug
  fix.
- `nightwatch`'s `Handler.VTable.should_watch` exists and is honoured by the per-directory backends; the plan's "filtered
  watch" is buildable without forking the dependency or writing a second watcher.

**The watcher-sharing question is settled by the common-dir arm:** the metadata arm is a directory that is usually
*outside* every served root (a linked worktree's gitdir lives in the base repo), so it cannot be the root's own arm. It is
shared *across roots of one repo*, which is the sharing that matters.