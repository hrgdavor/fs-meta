# fs-meta

The file-system state of one codebase folder, as a **trio of files** a watcher maintains and every other tool
reads — so a tool that kept an index can ask *"is this file still what I indexed last time?"* by reading one
64-byte entry instead of walking the tree and re-reading every file.

**The format is specified in [`FORMAT.md`](FORMAT.md).** That document is the authority; this one is about the
subproject: what is here, how to run it, and where it plugs in.

| In this subproject                | What it is                                                                                   |
| --------------------------------- | -------------------------------------------------------------------------------------------- |
| [`FORMAT.md`](FORMAT.md)          | the normative specification of version 1: the trio, the 64-byte entry, the checks, the publish protocol |
| `src/main.zig` + `build.zig*`     | the **Zig engine** — the reference implementation and the writer: it scans, publishes and serves. In progress: today `src/main.zig` is the watcher prototype (event batching, git-transaction awareness) and does not emit a trio yet |
| `src/main/java/hr/hrg/fsmeta/`    | the **Java reader** — a standalone Maven module, `hr.hrg:fs-meta` (`0.1.0-SNAPSHOT`)         |
| `js/`                             | the **Bun reader** — dependency-free ESM, no build step                                      |
| `conformance/`                    | the shared vector file every reader asserts, and the generator that produces it              |

**Not a `jcodebuddy` artifact.** The module has its own group id, artifact id and version and **no parent** — it
does not inherit `jcodebuddy-parent`, and it names no `jcodebuddy`/`hipster` type. It is listed in the root POM's
`<modules>` so the reactor (and the recorded gate) builds and tests it, which is a build relationship rather than
a namespace. Its one dependency is the hash: the artifact `hr.hrg:wyhash:1.1.0-SNAPSHOT`, from the project's own
repository (installed locally until it is published — DEC-050), so both of this project's ports hash with the same
code rather than with the same algorithm. **`java-watch*` may depend on this project** — the watcher is the writer
of the trio — which is the 2026-10-16 amendment recorded in AGENTS.md § 2.
is the 2026-10-16 amendment recorded in AGENTS.md § 2.

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
zig-out/bin/fsmeta.exe reconcile <root> <from> [to] [--json] [--baseline <root>]

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

Batch directories are named by the generation in lowercase hex, zero-padded to eight digits: `00000001`,
`00000002`, … `0000000f`, `00000010`, …

### As a library

```java
// Java
FsMetaLoad load = FsMetaPair.load(Path.of(".fs-meta"));       // reads and validates the three files
if (load.ok()) {
    FsMetaEntry entry = load.pair().entryOrNull("src/main/App.java");
    if (entry != null && entry.usableFingerprint() && entry.contentHash() == myRecordedHash) {
        // my derived work is still valid: I did not read the file
    }
}
FsMetaWriter.publish(dir, FsMetaScanner.scan(root, FsMetaScanOptions.defaults()), FsMetaHashMode.TEXT,
        "my-tool/1");
```

```js
// Bun / Node
import { loadTrio, scanTree, scanOptions, publish } from './fs-meta/js/fsmeta.mjs';

const load = loadTrio('.fs-meta');
if (load.ok) {
  const entry = load.pair.entryOrNull('src/main/App.java');
  // entry.contentHash / entry.sizeBytes / entry.mtimeMillis (BigInt) against what you recorded
}
publish('.fs-meta', scanTree('.', scanOptions()), { mode: 'text', writer: 'my-tool/1' });
```

A publish takes no root path: a trio contains no absolute path (§ 3.1 of `FORMAT.md`), so where the tree was
scanned is not something it records. Publishing the same tree from an absolute root and from a relative root is
byte-identical, and a copied or renamed workspace still verifies — which is what lets a tool be bound to a
workspace rather than to a location.

Java's `mvn -o -pl fs-meta install` publishes the jar for a driver project under `proto/`, the same way any
other library here is consumed.

## How the ports stay one format

`conformance/fsmeta-vectors.json` is the contract. Its blobs are produced from this project's own definition (§ 15 of `FORMAT.md`) and every *reader* asserts every byte of them — the Java and Bun readers today. The **writer is the Zig engine**, which is the reference: a reader that agrees with the vectors agrees with the reference, not with another implementation of it.

| Part of the file          | What it pins                                                                                    |
| ------------------------- | ----------------------------------------------------------------------------------------------- |
| `hashCases` (24)          | `wyhash64` at the lengths that walk its branches, against values produced by the library (and cross-checked against Zig's `std.hash.Wyhash`) |
| `cases` (15)              | complete `files.meta`/`files.txt`/`files.json` triples — the valid pair byte for byte, and every invalid one with the verdict a validator must reach, in the order § 8 checks them |
| `gitignoreCases` (16)     | trees to materialise and the file list a walk must produce, so the two walks are the same walk  |
| `repairCase`              | a pair whose offsets point at the wrong lines, and the entry-to-name pairing the hashes recover |

The vectors are **generated, not hand-written** — `bun fs-meta/conformance/gen-vectors.mjs` — and the generator
refuses to emit anything unless the JS `wyhash64` first reproduces the seven library-produced golden vectors
(the same ones `ContentHashTest` in `hipster-entity-tooling` pins its vendored copy to). The byte layout is
assembled in the generator straight from `FORMAT.md`'s field table, so an implementation that agrees with the
vectors agrees with the published specification rather than with the other implementation of it.

That is not a formality: the ignore vectors caught a real difference between the ports on their first run —
Java's `Matcher.matches()` anchors a pattern while JavaScript's `RegExp.test` searches, so an anchored
`.gitignore` pattern matched a path *suffix* in the Bun walk until it grew an explicit `^`.

`bun fs-meta/check-ports.mjs` closes the loop end to end, past the vectors: it scans one real tree (nested
directories, a CRLF file, a binary file, a name with non-ASCII characters, `.gitignore` rules with a negation
and an excluded directory) with both CLIs and compares what they wrote. `files.meta` and `files.txt` must be
byte-identical, `names` must be the same list, and the two `files.json` documents must agree on everything but
the fields that belong to a publish (`generation`, `created`, `updated`, `writer`) or to this machine (`root`).
It is how the Java port's missing UTF-8 output wrapper was found: the Bun port wrote
`docs/héllo — ünïcode.md`, and the Java one, on the Windows console code page, wrote
`docs/h?llo ? ?n?code.md`.

## Where this plugs in, and the one boundary to know

More than one tool maintains an index over the same files, and each of them used to answer "has this changed?"
by walking and re-reading — or by trusting an mtime, which is a guess. `fs-meta` is the shared starting point:
**the watcher writes the trio once, and every other tool reads 64 bytes per file.** No watcher is wired into
this module yet; what a watcher needs from it is `FsMetaScanner.scanFile` (one path, what an event named) and
`FsMetaWriter.publish` (a generation), both of which exist and are tested.

**The boundary is now on this project's side, and it is permissive here.** `java-watch*` must not know about
Jackson, OpenRewrite or this workspace's `jcodebuddy-*` / `hipster-*` families (AGENTS.md § 2,
`bun scripts/check-watch-standalone.js`) — and a **standalone package that happens to live in this checkout is
not "this workspace"** in that sense: `hr.hrg:fs-meta` has its own coordinates, its own version, no parent and
no workspace dependency of its own, so a `watch/*` module **may** depend on it. That amendment (2026-10-16) is
recorded in AGENTS.md § 2 and in the check's own header, and it is what lets the watcher be the writer of the
trio this project defines instead of growing a copy of it.

## Next

- **The Zig engine is the reference** (Zig 0.17; `scripts/lib/toolchain.js`'s `resolveZig` is the toolchain
  resolution). It is where the writer half lives: scan, hash, publish, serve. `src/main.zig` today is the
  watcher prototype, with event batching and git-transaction awareness but no trio output and no `.gitignore`
  walk yet. When it can publish, the vectors are generated from it and the Java and Bun readers are updated
  against it — the format has no second writer to keep in step.
- **The engine's socket.** A tool with the engine running should ask it for the live state over a local socket
  (Unix domain socket; `AF_UNIX` is supported by Windows 10 1803+, and by Java 16+/Bun/Zig) instead of
  re-reading the tree. The protocol is its own document; `FORMAT.md` stays the durable path.
- **The watcher wiring.** The Java half is ready for it (`FsMetaScanner.scanFile` for one event's path,
  `FsMetaWriter.publish` for a generation), and `java-watch-core` may now depend on this module directly.
- **The hash dependency is in its own project** (DEC-050): both ports hash with the same code — the Java half
  through the `hr.hrg:wyhash` artifact, the Bun half through the package link the root `package.json` declares.
- **The append-only publish path.** `FORMAT.md` § 9 defines it — appending names that sort last never moves an
  existing offset, so the two data files can grow independently — and v1 writes both files whole, which is
  correct but does not yet take that optimisation. It matters when a watcher applies a small batch to a large
  tree; it is a writer-side change with no effect on the bytes a reader sees.
## The engine writes; ports read

`fsmeta` (the Zig engine) is the only writer of a trio. A port validates, decodes and loads what the engine published,
and never has to lay one out — which is why the Bun port's suite is a **reader** suite and its three writer-dependent
tests are gated behind `FSMETA_PORT_WRITER=1`:

```text
bun test js                            # the reader suite, 25 tests, all green
FSMETA_PORT_WRITER=1 bun test js       # also the writer tests, which fail until a writer port learns
                                       # the two-order layout (meta by name hash, text by name, `dir/` names)
```

They are kept rather than deleted so that porting the writing side stays an option; the engine's own tests are what
define the writer today. Extracting them into `js/writer.test.mjs` is worthwhile once a writer port is actually
planned, because they share the reader suite's helpers.
## Dependencies

`gitignore` is consumed as a published artifact in every language it is available in:

| language   | coordinate               | resolved from                               |
| ---------- | ------------------------ | ------------------------------------------- |
| Zig        | `gitignore` v0.3.3       | `build.zig.zon`, the tagged tarball         |
| Java       | `hr.hrg:gitignore:0.3.3` | **Maven Central** — no local install needed |
| JavaScript | `@hrg/gitignore@0.3.3`   | **npm**                                     |

The Java artifact was verified the way a fresh machine would use it: the local copy was deleted and
`mvn dependency:get -Dartifact=hr.hrg:gitignore:0.3.3` repopulated it from Central, then the test suite ran against that
copy. Nothing here needs a checkout of the `gitignore` repository.