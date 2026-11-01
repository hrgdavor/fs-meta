# Next

- **Non-root service deployment (N7).** [`doc/service-deployment.md`](doc/service-deployment.md) and
  [`packaging/`](packaging/README.md) provide systemd, launchd, Windows virtual-service-account and container
  templates, with per-platform verification commands and an operator checklist. The startup refusal (N2), POSIX
  socket modes/peer checks (N3), `serve --allow-exec` (N4), startup hardening (N5) and no-follow `.fs-meta` writes (N6)
  are implemented with the platform gaps recorded in [`plans/non-root-daemon.md`](plans/non-root-daemon.md) § 6. The
  in-tree negative tests are added; the root/elevated subset runs in CI, while the different-uid CI job remains.
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
