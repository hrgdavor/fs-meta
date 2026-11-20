# Root discovery — how a client finds the root that serves a path

**Status:** client-side contract, decided 2026-11-19. **fs-meta needs no change for this.** The daemon already
serves one root per project or one root per subproject, nested roots are guarded, and every operation names the
root it acts on. A client resolves the serving root itself — from the daemon's `roots` while it is live, or
from `roots.json` when it is not — and chooses where its own metadata lives. There is deliberately no
`root.which` command and no path-resolving CLI: the rule is a few lines, and a client that can work offline
needs the same rule against `roots.json` anyway.

This document is for client authors (the Java port, the Bun/Node port, `jcodebuddy`, editors and any other
tool). It is not a second registry and it does not change any format.

## Why this exists

A project may be served as **one root** — `fsmeta root add <project>` — or as **several roots**, one per
subproject: `root add <project>/module-a`, `root add <project>/module-b`, and so on. Both layouts are
legitimate, and a project can switch between them.

Nested roots are allowed and guarded (`FORMAT.daemon.md` § 4, [`doc/daemon.md`](daemon.md)): a parent's scan
excludes a child root, so the parent's stream does **not** contain the child's files, and the child's stream
does not contain the parent's. A root that is a plain directory still owns every file under it that is not
inside a nested root.

A client must therefore **never assume**:

- that the directory it was given is itself a root;
- that its project root is the root serving a module;
- that one subscription covers every source root of a project.

It resolves the path to the **serving root** and uses that root's socket, generation and settings.

## 1. Resolution, in order

Given a path `p` — a directory or a file — the serving root is found in this order. A step is skipped only
when the higher one cannot answer.

### 1a. With a live daemon: the `roots` command

The daemon holds the claims, rewrites the socket path on every start and reports roots that are `missing`
(`FORMAT.daemon.md` § 4). Its answer is the authority.

`fsmeta roots list --json` (or the `roots` control command) returns every root object; choose the **deepest**
root whose `root` is `p` or an ancestor of `p`, by the rule in § 2. The socket is the record's `socket`; do not
derive it, and do not use `<root>/.fs-meta/socket` (that is `fsmeta serve`, a different contract).

A path no root serves is reported as such. It is not the nearest unrelated root, and it is not a reason to
attach to a parent with different semantics.

### 1b. Without a live daemon: `roots.json`

Read the durable list (`FORMAT.daemon.md` § 1b: `$FSMETA_CONFIG_HOME/fsmeta/roots.json`,
`%APPDATA%\fsmeta\roots.json`, …) and apply the same deepest rule. This is the daemon's own durable state,
not a filesystem search: the daemon reads the same file on start, and a record that carries a socket path is
a root the daemon serves or served.

A record stays authoritative even when its root is `missing`: resolving it lets the client say "the root is
registered but its path is gone" instead of "no root" — the two need different fixes. A malformed record is
reported and skipped, as the daemon does (§ 3 of `FORMAT.daemon.md`).

### 1c. Optional: a client-side `.fs-meta` walk (offline only)

Only when neither a daemon nor a `roots.json` record answers — a checkout, a CI job, a machine where the
daemon was never configured — a client **may** search the filesystem for a root. It is the client's choice:
this is a **read-only, offline** discovery that yields a root with a trio, but no live event stream and no
socket to subscribe to.

If a client implements it, the walk:

1. Starts at `canonical(p)`; if `p` is a file, at its parent.
2. For each directory `d`, nearest first, up to the volume root: if `d/.fs-meta` is a **directory** holding the
   trio (`files.meta`, `files.txt`, `files.json`), `d` is the candidate root.
3. The **nearest** candidate wins — that is the nested-root rule again.
4. Does not follow a symlinked `.fs-meta` (`safe_dir` refuses one; a reader must not accept what the writer
   would refuse) and does not cross a volume or drive boundary.
5. If the nearest `.fs-meta` is present but not a valid trio, **reports it and stops**; it does not silently
   continue to a parent. The format's writes are atomic, so an invalid `.fs-meta` is either a foreign directory
   or a real problem, and attaching to the parent would hide it.

A `.fs-meta` may be stale (a root that was removed), which is the price of the offline path. A client that
needs live events does not treat the walk as a substitute for the daemon: it gets the trio, and it says so.

### 1d. No root

The client decides, explicitly: a **mutation** refuses; a **generator** runs a full pass; a **viewer** shows
"not served" and does nothing. It never falls back to a parent that was not resolved by this order.

## 2. The deepest-ancestor rule

The rule is one rule, applied identically in § 1a, § 1b and § 1c:

- A root `r` **serves** `p` when `canonical(r) == canonical(p)` or `canonical(r)` is a proper ancestor of
  `canonical(p)`.
- **The deepest such root wins** (most path segments). An exact root is its own ancestor.
- Ancestry is compared **segment by segment**, not as a string prefix: `/a/bc` is not inside `/a/b`.
- On Windows the comparison is case-insensitive per segment and includes the drive or UNC root; on POSIX it
  is exact. Canonicalize with the real path when it exists and with absolute-normalize otherwise, so a
  symlinked root and its target are one root.
- **A tie** — two records naming the same canonical path — is the same root. Select one deterministically
  (the daemon's own order, then the id) and report the duplicate rather than picking by iteration order.
- The returned value is the **root**, never the locator. The consumer narrows the stream to its own
  subfolder with the protocol filter; it does not create a second root for a subdirectory.

A worked example:

```text
roots: /p (id p), /p/module-a (id ma)
path:  /p/module-a/src/main/java
→ ma, because /p/module-a is deeper than /p
path:  /p/other/src
→ p
path:  /p/module-ab/src
→ p, because /p/module-a is not an ancestor of /p/module-ab
```

## 3. Multi-root clients

A client that serves a project maps every directory it watches — a source root, a content root, a
subproject — to its serving root, and attaches **once per serving root**:

- **Subscriptions are per root.** Batch and generation numbers are per root (`FORMAT.daemon.md` § 3,
  `FORMAT.socket.md`); a generation from one root says nothing about another. Never compare, sort or merge
  generation numbers across roots.
- **Filters are relative to each root.** A source root under `module-a/src/main/java` is filtered as
  `module-a/src/main/java/**` against the `module-a` root, and `src/main/java/**` against a root that *is*
  `module-a`. The same file is relative to only one serving root.
- **A nested root is not in its parent's stream.** A client that expects the parent's batch to mention a nested
  root's files will silently miss them. Subscribe to the child (and to the parent for the rest) or choose one
  granularity for the whole project.
- **State is per root.** An applied-generation marker is meaningful only with the root it belongs to; a cache
  that stores one number for a multi-root project is wrong. Store `(root, generation)` pairs.
- **A queue per root.** One slow or stuck root must not delay another's batches (the daemon's own rule,
  `FORMAT.daemon.md` § 2c, applies to a client too).

A project that registers **only** module roots has no serving root for the project directory itself. A client
given the project directory must not invent one: it enumerates the roots (from `roots`/`roots.json`) and
attaches to each, or it reports that the project root is not served and asks for one. A project that registers
a **project root** gets one subscription for everything outside its nested roots.

## 4. What fs-meta does not do

- **No `root.which`, no `--root auto`, no path-resolving operations.** Every operation takes the root it acts
  on (`changed`, `reconcile`, `merge`, `find`, `match`, `stage`, `refresh`, `serve`). A client with a path
  inside a root resolves the root first, per this document, and then calls the operation with it.
- **No filesystem search for roots by the daemon** (`FORMAT.daemon.md` § 1b). The walk in § 1c is a
  client-side, offline choice, never a daemon feature.
- **No metadata location.** Where a tool keeps its own metadata (JCodeBuddy's `.jcodebuddy/`, an index, a
  cache) is the tool's decision; fs-meta's trio is per root and nothing else. A tool that wants a metadata
  directory outside its root chooses that itself.
- **No watcher in a client.** A client subscribes to the Zig daemon or reads the trio; it never starts a
  watcher, a scheduler or a second `serve` (`AGENTS.md` § 1).

## 5. Sockets and paths a client must not guess

- The **consumer socket** is the one in the daemon's record (`socket` in `roots.json` / `roots`). It is
  rewritten on every daemon start, and a `--base` daemon may put it anywhere. Never reconstruct
  `<runtime>/roots/<id>.sock` without the record (the record names it for a reason), and never use
  `<root>/.fs-meta/socket` (that is `serve`).
- The **root identity** is its canonical path; the id is derived from it (`FORMAT.daemon.md` § 1c) but is not
  a location. A client that has only an id asks the daemon; it never hashes a candidate path to compare.

## 6. Client checklist

A client that follows this contract can answer these without fs-meta changes:

1. Given a directory, find the deepest serving root from a live daemon (`roots`) and from `roots.json`
   (offline), with the segment/case/canonical rules of § 2.
2. If the client watches several directories, attach once per serving root, filter relative to each, and keep
   `(root, generation)` state per root.
3. Treat a nested root as absent from its parent's stream, and report a project directory that is not itself a
   root instead of attaching to an unrelated parent.
4. Fall back to the trio (optionally via the § 1c walk) only for read-only/offline work, and say that there is
   no live stream.
5. Report a `missing` root as registered-but-gone, not as "no root".
6. Never fabricate a socket path or start a watcher.
