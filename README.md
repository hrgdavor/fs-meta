# fs-meta

> **Security rule: run the daemon as a non-root, unprivileged user. Never run it as root or as an elevated
> Administrator.** The daemon walks project trees, writes `.fs-meta` and serves a local Unix socket — including an
> executable dialect that hands the connection to a child program. Any exploit in that attack surface would
> otherwise run with **elevated permissions**. This is a hard deployment rule, not a recommendation. The startup
> refusal is implemented; socket permissions, peer checks, privilege dropping, packaging and the remaining tests are
> planned in [`plans/non-root-daemon.md`](plans/non-root-daemon.md).

The file-system state of one codebase folder, as a **trio of files** a watcher maintains and every other tool
reads — so a tool that kept an index can ask *"is this file still what I indexed last time?"* by reading one
64-byte entry instead of walking the tree and re-reading every file.

**The format is specified in [`FORMAT.md`](FORMAT.md).** That document is the authority; this one is about the
subproject: what is here, how to run it, and where it plugs in.

| In this subproject                | What it is                                                                                   |
| --------------------------------- | -------------------------------------------------------------------------------------------- |
| [`FORMAT.md`](FORMAT.md)          | the normative specification of version 1: the trio, the 64-byte entry, the checks, the publish protocol |
| `src/main.zig` + `build.zig*`     | the **Zig engine** — the reference implementation, the writer and the watcher: it scans, hashes, publishes, runs the daemon and serves one Unix socket per watched root |
| `src/main/java/hr/hrg/fsmeta/`    | the **Java client/reader** — a standalone Maven module, `hr.hrg:fs-meta` (`0.3.6`); it validates, decodes and loads the trio and connects to the daemon; it is not a watcher |
| `js/`                             | the **Bun client/reader** — dependency-free ESM, no build step                               |
| `conformance/`                    | the shared vector file every reader asserts, and the generator that produces it              |

**Not a `jcodebuddy` artifact.** The module has its own group id, artifact id and version and **no parent** — it
does not inherit `jcodebuddy-parent`, and it names no `jcodebuddy`/`hipster` type. It is listed in the root POM's
`<modules>` so the reactor (and the recorded gate) builds and tests it, which is a build relationship rather than
a namespace. Its one dependency is the hash: the artifact `hr.hrg:wyhash:1.1.0-SNAPSHOT`, from the project's own
repository (installed locally until it is published — DEC-050), so both of this project's ports hash with the same
code rather than with the same algorithm. **`java-watch*` may depend on this project** — the watcher is the writer
of the trio — which is the 2026-10-16 amendment recorded in AGENTS.md § 2.

## The watcher is the Zig engine; tools connect over a Unix socket

This is the intended deployment, not an implementation detail:

- **One Zig daemon watches the roots.** A single long-lived process tracks the served roots, and each root gets
  its own Unix socket (`<id>.sock`) and its own trio. The daemon owns the event source, the grace/debounce window,
  the git-transaction latch, the batch archive and retention.
- **Every other tool is a client over that socket.** A tool asks the engine for the live change stream
  (`SUBSCRIBE` / `CHANGE_ENTRY` frames in `FORMAT.socket.md`) instead of running its own watcher and hashing the
  tree. A tool that starts while no daemon is running falls back to reading the trio; that is the durable path.
- **Multiple tools are expected to be active at once.** One native watcher shares one scan, one hash and one batch
  stream across all of them. That is why the Zig variant is the intended one: it is the most lightweight and
  fastest option when several Java, Bun, editor and codegen processes are open, and it avoids each of them
  carrying its own event loop, debounce and hashing.
- **The Java and Bun ports are clients/readers, not watchers.** They validate and decode the trio and can speak
  the socket protocol. They do not run a second watch loop in-process; that would duplicate the engine and defeat
  the point. The Java port's writer exists for repair/tests, not as a production watcher.


## The trio, in one paragraph

`files.meta` is a dense array of 64-byte entries, one per file, little-endian, no header — one entry per cache
line, and the count is `size / 64`. Each entry carries the file's mtime, its name's hash, its content hash, its
size, and where its name sits in `files.txt`. `files.txt` is the same names, LF-delimited and sorted by UTF-8
bytes, so a human can read it and a diff can be a merge join. `files.json` is the sidekick that makes the binary
file self-describing: version, counts, sizes, the hash algorithm — and it is written **last**, so a crash leaves
a state a reader can *detect* rather than trust. `FORMAT.md` § 5 has the field table and § 13 a worked example
in hex.

Two rules from § 1 are worth repeating because they are the reason this is safe to build on: **the trio is a
cache, never a correctness input** — a missing, stale or corrupt trio makes a tool slower, never wrong — and
**mtime equality is never proof of content equality**, so a decision that depends on bytes reads the bytes.

## Running it

The two ports take the same commands, print the same output and return the same exit codes (0 answered, 1 the
subject failed, 2 usage), so a pipeline does not care which one answers.

```sh
# the Zig engine (reference implementation; `zig build` then run)
zig-out/bin/fsmeta.exe scan <root>                    # walk the tree, write .fs-meta/
zig-out/bin/fsmeta.exe verify <root>                   # is the trio usable?
zig-out/bin/fsmeta.exe refresh <root>                  # rescan and publish a new generation
zig-out/bin/fsmeta.exe glob <root> <pattern> [--since <ts>] [--json]   # git wildmatch; no '/' = basename at any depth
zig-out/bin/fsmeta.exe changed <root> <since> [--json]
zig-out/bin/fsmeta.exe reconcile <root> <from> [to] [--json] [--baseline <root>] [--include <pat>] [--exclude <pat>]

# the Bun port (no build step)
bun fs-meta/js/fsmeta-cli.mjs scan --root .          # walk the tree, write .fs-meta/
bun fs-meta/js/fsmeta-cli.mjs verify                 # is the trio usable?
bun fs-meta/js/fsmeta-cli.mjs names                  # the files it knows, in format order
bun fs-meta/js/fsmeta-cli.mjs query src/main/App.java # one entry's fingerprint
bun fs-meta/js/fsmeta-cli.mjs diff A B               # added / removed / modified / touched / unknown
bun fs-meta/js/fsmeta-cli.mjs repair                 # re-pair entries and names by their hashes

# the Java port (same commands; needs the module built and JDK 25)
bun scripts/mvn-fast.js -pl :fs-meta package
java -cp fs-meta/target/fs-meta-1.0-SNAPSHOT.jar:... hr.hrg.fsmeta.FsMetaCli verify --dir .fs-meta

# both implementations' tests
bun test fs-meta/js                                  # 26 tests: vectors, round trip, CLI
bun scripts/mvn-fast.js -pl :fs-meta package          # 63 JUnit tests

# do the ports really produce one format? one tree, scanned by both, compared byte for byte
bun fs-meta/check-ports.mjs                          # needs the module built (above) and JDK 25
```

`scan` honours `.gitignore` files in the tree unless `--no-gitignore` is given; `--normalize none|lf|text`
chooses the content-hash mode (`text` is the default, which makes a CRLF and an LF checkout agree), and
`--ignore NAME` adds a directory name to skip. The walk's ignore rules are `FORMAT.md` § 16.

### `reconcile` — combined change set for a batch range

`fsmeta reconcile <root> <from> [to] [--json] [--baseline <root>]` gives the **combined set of changes**
after generation `from`, through `to` (inclusive; omitted means the latest batch). A single batch is trivial
(its own entries); the command is useful when several batches are combined into one change set — the input a
parser or checker tool needs to re-run over the names that actually moved.

- `from` is the **baseline** generation (not included in the range). It is the generation the consumer last
  synced at.
- The window is batches `from + 1` through `to`, collapsed per the matrix in `FORMAT.md` § 17.4:
  a name added and then deleted in the window cancels out; a name changed twice is one change carrying the
  final entry.
- Each change is printed as `added <name>`, `changed <name>` or `deleted <name>`, followed by an
  `<n> names` count; `--json` emits one `{"name", "kind"}` object per change.
- A range that predates the retained batches fails with `batch-too-old`, and one that reaches a missing batch
  fails with `batch-gap`, both with exit code 1. The range is never silently shortened.
- `--baseline <root>` supplies the consumer's recorded trio. Without it the answer is a superset: correct,
  idempotent, and occasionally a no-op the consumer did not need. That is the documented trade-off in § 17.4.

`fsmeta merge <root> <start> [end] [--json]` is a **deprecated alias** of `reconcile`, kept so existing
scripts keep working; the batch history has exactly one reader.

**`--include` / `--exclude`** filter the change set by name, so a consumer asks for only what it cares about:

```sh
fsmeta reconcile <root> <from> --include '*.md'          # only markdown changes
fsmeta reconcile <root> <from> --include 'src/**' --exclude '*.test.*'
```

Patterns use git's `wildmatch` (the same matcher as `glob` and `.gitignore`): `*` matches any sequence, `?`
one character, `[abc]` one of the listed. A pattern without `/` matches the basename at any depth; a pattern
with `/` matches the whole workspace-relative path. Include patterns select; exclude patterns suppress and win
over include. Both empty (or omitted) means pass-all. The filter is applied after the collapse, so the counts
reflect the filtered set. The same patterns are available on the socket protocol: a `SUBSCRIBE` payload longer
than 8 bytes carries them, and the server sends only matching `CHANGE_ENTRY` frames (see `FORMAT.socket.md`
§ SUBSCRIBE filter patterns).

Batch directories are named by the generation in lowercase hex, zero-padded to eight digits: `00000001`,
`00000002`, … `0000000f`, `00000010`, …

### The daemon — one process, many roots

`fsmeta daemon` is a long-lived process that tracks several roots, each with its own socket, speaking the same binary
protocol. Three modes (`off`, `always`, `auto`), nested-root guarding, worktree handling, and `FSMETA_*` overrides.
Full reference: [doc/daemon.md](doc/daemon.md).

### As a library

```java
// Java — a client/reader; the daemon is the watcher and writer
FsMetaLoad load = FsMetaPair.load(Path.of(".fs-meta"));       // reads and validates the three files
if (load.ok()) {
    FsMetaEntry entry = load.pair().entryOrNull("src/main/App.java");
    if (entry != null && entry.usableFingerprint() && entry.contentHash() == myRecordedHash) {
        // my derived work is still valid: I did not read the file
    }
}
```

```js
// Bun / Node — a client/reader; the daemon is the watcher and writer
import { loadTrio } from './fs-meta/js/fsmeta.mjs';

const load = loadTrio('.fs-meta');
if (load.ok) {
  const entry = load.pair.entryOrNull('src/main/App.java');
  // entry.contentHash / entry.sizeBytes / entry.mtimeMillis (BigInt) against what you recorded
}
```

A client does not publish. The engine owns the publish, and a tool that needs the live path asks the daemon over
its Unix socket; a tool without a daemon reads the trio. The Java port's writer exists for repair and tests, not as
the production path.

Java's `mvn -o -pl fs-meta install` publishes the jar for a driver project under `proto/`, the same way any
other library here is consumed.

## How the ports stay one format

`conformance/fsmeta-vectors.json` is the contract: every reader asserts every byte of it, and the writer is the
Zig engine. The vectors are generated, not hand-written. Full detail: [doc/conformance.md](doc/conformance.md).

## Where this plugs in, and the one boundary to know

More than one tool maintains an index over the same files, and each of them used to answer "has this changed?"
by walking and re-reading — or by trusting an mtime, which is a guess. `fs-meta` is the shared starting point:
**one Zig watcher maintains the trio and serves the live socket; every other tool reads the trio or subscribes.**
That is the intended shape because several tools are normally active at once: one native watcher performs one scan
and one hash, and all of them share the result. A Java or Bun process that started its own watch loop would repeat
that work and be heavier for it.

**The boundary is now on this project's side, and it is permissive here.** `java-watch*` must not know about
Jackson, OpenRewrite or this workspace's `jcodebuddy-*` / `hipster-*` families (AGENTS.md § 2,
`bun scripts/check-watch-standalone.js`) — and a **standalone package that happens to live in this checkout is
not "this workspace"** in that sense: `hr.hrg:fs-meta` has its own coordinates, its own version, no parent and
no workspace dependency of its own, so a `watch/*` module **may** depend on it. That amendment (2026-10-16) is
recorded in AGENTS.md § 2 and in the check's own header, and it is what lets the watcher be the writer of the
trio this project defines instead of growing a copy of it.

## Next

See [ROADMAP.md](ROADMAP.md) for the remaining daemon/socket hardening and worktree work. The watcher itself is
the Zig engine and the socket is its live transport; neither is waiting on the Java or Bun ports.

## The engine writes; ports read

The Zig engine is the only writer of a trio; ports validate, decode and load, or connect to the daemon. See
[AGENTS.md § 1](AGENTS.md#1-the-engine-writes-ports-read).

```text
bun test js                            # the reader suite, 25 tests, all green
FSMETA_PORT_WRITER=1 bun test js       # also the writer tests (gated)
```
## Dependencies

`gitignore` is consumed as a published artifact in every language it is available in:

| language   | coordinate               | resolved from                               |
| ---------- | ------------------------ | ------------------------------------------- |
| Zig        | `gitignore` v0.3.5       | `build.zig.zon`, the tagged tarball         |
| Java       | `hr.hrg:gitignore:0.3.5` | **Maven Central** — no local install needed |
| JavaScript | `@hrg/gitignore@0.3.5`   | **npm**                                     |

The Java artifact was verified the way a fresh machine would use it: the local copy was deleted and
`mvn dependency:get -Dartifact=hr.hrg:gitignore:0.3.5` repopulated it from Central, then the test suite ran against that
copy. Nothing here needs a checkout of the `gitignore` repository.