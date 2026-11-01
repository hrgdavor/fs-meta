# Run the fs-meta daemon as a non-root user — and enforce it

**Status: N1–N6 implemented with documented platform gaps; N7 docs/packaging done, N7 negative/CI tests open
(2026-11-01).** The rule is at the top of [`README.md`](../README.md), [`AGENTS.md`](../AGENTS.md),
[`doc/daemon.md`](../doc/daemon.md) and the operator guide [`doc/service-deployment.md`](../doc/service-deployment.md).
`src/security.zig` refuses `serve`/`daemon start` for uid 0, an elevated Administrator token or service SIDs;
`socket_security.zig` makes POSIX sockets owner-only and peer-checked; `safe_dir.zig` refuses a symlinked `.fs-meta`;
the `{{` dialect is off unless `serve --allow-exec`. The Windows socket DACL/peer gap and the remaining negative tests
are called out below and in § 6.

## 1.1 What N2 implemented

- `security.ensureUnprivileged()` runs before `runServe` and at the start of `daemonStart`, so both the single-root
  `fsmeta serve` and the multi-root `fsmeta daemon start` (foreground and detached) are covered.
- POSIX checks the effective uid; Windows checks `TokenElevation` and rejects the LocalSystem/LocalService/
  NetworkService SIDs explicitly. A failed token query is a refusal, not a pass.
- The refusal message states the deployment rule and points here. There is no `--allow-root` escape hatch.
- `zig build` and the focused `security.zig` test compile; the normal non-elevated daemon integration test still
  passes.

## 1.2 What N3–N6 implemented

- **N3 / sockets:** `src/socket_security.zig` creates the daemon runtime directories `0700` (and narrows existing
  ones), narrows `serve`/daemon sockets to `0600` before accept, and compares peer uid+gid on Linux
  (`SO_PEERCRED`) and macOS/BSD (`getpeereid`). A different peer is refused on the normal `ERROR` path. **Windows has
  no mode bits and no AF_UNIX peer credentials in Zig 0.17**, so the per-user profile ACL is the only control there;
  an explicit `--base` outside the profile is a documented gap. Same uid + different gid is deliberately refused.
- **N4 / `{{`:** `fsmeta serve --allow-exec` is the only way to offer the executable dialect; the default is off and a
  refused opener gets `protocol: exec-dialect-disabled`, no child. The daemon never implemented the dialect, and
  `serve --live` never classified it, so neither can be loosened. No env var or client frame can enable it.
- **N5 / process hardening:** `security.hardenAfterStart()` runs after the non-root gate in `daemonStart` and in the
  `serve` branch. Linux sets and verifies `PR_SET_NO_NEW_PRIVS`, clears the ambient capability set and sets umask
  `077`; macOS/BSD set umask `077` only; Windows applies a best-effort extension-point mitigation. It is defense in
  depth, not a privilege drop.
- **N6 / `.fs-meta`:** `src/safe_dir.zig` classifies the final component with no-follow stat/open and refuses a
  symlink/junction/reparse point (`error.MetaDirSymlink`) or a non-directory (`error.MetaDirNotDirectory`). Fresh
  `.fs-meta` is `0700` / fresh trio files `0600`; existing modes are inherited. Temp files are created exclusively so
  a pre-planted `files.*.tmp` cannot redirect the write.
- **N7 / packaging:** `doc/service-deployment.md` and `packaging/` cover systemd, launchd, Windows service wrapper and
  containers, with non-root service users and verification commands.

**Still open / explicitly not claimed:** the Windows socket DACL and peer check; UID+GID clients started through
`sg`/`newgrp` when the primary gid differs; `batch.zig`'s batch-file writes and `ignores.zig`'s own `.fs-meta` open
still follow symlinks (engine/publish are covered); the `{{` child path on Windows is pre-existing and unverified; and
the N7 negative tests (root/elevated refusal, socket modes, second-user refusal, exec gate) in CI.

## 1. Why this is a hard rule

The daemon is not a passive reader. It:

- walks every served tree, including names, symlinks, `.gitignore`/`info/exclude` files and nested boundaries;
- writes `.fs-meta` (trio and `batches/`) inside the served root;
- binds a local Unix socket and accepts frames from local clients;
- supports the `{{` **executable dialect** (`FORMAT.socket.md` § The `{{` dialect): the server hands the socket to a
  child program as stdin/stdout;
- may run hooks / git helpers and may be asked to adopt or seed worktrees.

A memory-safety bug, a path-traversal bug, a filter bug or a socket-authorization bug is therefore not a “watcher
crashed” bug when the daemon is root: it is **arbitrary code execution with root/Administrator privileges** on a host
that also holds every served repository. Running unprivileged is the difference between a contained bug and a host
compromise. The executable dialect makes this explicit: a local client that can reach the socket can ask the server to
run a child, so socket access must never imply elevated execution.

## 2. Policy

1. `fsmeta daemon`, `fsmeta serve` and any other serving/watching mode **must run as an ordinary unprivileged user**.
2. **Never as uid 0 / euid 0.** On Windows, never with an elevated Administrator token, and never as `SYSTEM` or a
   service account with broad privileges.
3. **No production “run as root” flag.** Root execution is a deployment error, not a supported mode.
4. Tools that only read a trio may run as any user that can read it; the rule is about the process that watches,
   writes and serves.
5. A socket client is not trusted merely because it can connect: the socket must be owner-only and/or peer-checked.

## 3. What is exposed today

| Area              | Current state                                                                                      | Risk if daemon is root                                         |
| ----------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Startup identity  | N2 refuses uid 0, elevated Administrator and service SIDs; fail-closed query                       | any `sudo fsmeta daemon` is refused                            |
| Unix socket       | N3: `0700` dirs / `0600` sockets and uid+gid peer checks on Linux/macOS/BSD; Windows DACL/peer gap | an elevated daemon would hand a local client root-level access |
| `{{` exec dialect | N4: off by default; only `serve --allow-exec`; daemon/live never had it                            | a local client could run a child as the daemon user            |
| Peer identity     | N3: `.other_user` refused on POSIX; Windows gap documented                                         | any local user with socket access would be a client            |
| `.fs-meta` writes | N6: engine/publish no-follow and exclusive temp creation; batch/ignores gaps remain                | a crafted layout could redirect root writes                    |
| Packaging         | N7: non-root service/container templates and operator guide done; negative/CI tests open           | an operator could install a root service without noticing      |
| Windows           | N2 token/SID refusal done; no POSIX modes, no AF_UNIX peer credentials/DACL in Zig 0.17            | socket access relies on the inherited profile ACL              |

The existing `serve` socket is `<root>/.fs-meta/socket`; the multi-root daemon's socket is
`<runtime>/roots/<id>.sock`. Both are filesystem objects, so ownership and mode are the first control, not the last.

## 4. Enforcement options to explore

### A. Refuse to start when privileged (first line of defence)

- **POSIX:** check `geteuid() == 0` before opening anything; also reject `getegid() == 0` and, on Linux, a process
  carrying `CAP_DAC_OVERRIDE`/`CAP_DAC_READ_SEARCH` if we want to catch capability-only privilege. Error text names
  the fix (“run as your normal user; do not use sudo”).
- **Windows:** query the process token with `GetTokenInformation(TokenElevation)` and refuse when elevated; separately
  refuse `SYSTEM`/`LocalSystem` SIDs. Checking the username is not enough: an Administrator in a filtered
  (non-elevated) token is still a normal user for this rule, while an elevated token is not.
- **Containers:** uid 0 inside a user namespace is not necessarily host root. Decide explicitly: check the effective
  host privilege, not just the numeric uid; rootless user namespaces are allowed only when they cannot write host
  paths outside the served roots.
- **macOS:** euid plus launchd `UserName`; the daemon should not be a LaunchDaemon running as root.

### B. Drop privileges when started by a privileged parent

- If a service manager must start the daemon as root to bind something, drop to a configured uid/gid immediately,
  before scanning: `setgroups`/`setgid`/`setuid`, clear supplementary groups, `PR_SET_NO_NEW_PRIVS`, drop
  capabilities; on Windows use a restricted token/job object and do not inherit an elevated token.
- Prefer **starting already unprivileged** over dropping. A drop that happens after parsing arguments or opening the
  socket leaves a window and is easy to get wrong.
- Any drop must be verified: re-read euid and refuse if it did not take effect.

### C. Make the socket owner-only and peer-checked

- Create the socket directory `0700` and the socket `0600`; set `umask(077)` before creation.
- On Linux, read `SO_PEERCRED` and reject a peer whose uid differs; on BSD/macOS use `getpeereid`; if a platform
  exposes no peer credentials, rely on filesystem ownership and document the gap.
- On Windows, set a restrictive DACL on the socket/containing directory (current user + SYSTEM only) and consider a
  named-pipe ACL if AF_UNIX cannot expose the peer SID.
- Never create the socket in a world-writable directory without an owner-only subdirectory.
- For `serve`, the socket lives under the served root; a repository checked out in a shared/world-writable location
  must be refused or the socket moved to the user's runtime directory.

### D. Gate the executable dialect

- `{{` should be **off by default** and require an explicit opt-in, or be restricted to an allow-listed command set.
- It must never be reachable by a peer that is not the same uid; root execution is forbidden regardless.
- Document that a local unprivileged user who can connect can invoke the child only with that user's privileges, which
  is why non-root is non-negotiable.

### E. Harden filesystem writes

- Open `.fs-meta` with no-follow semantics; refuse a `.fs-meta` that is a symlink; create it `0700` and its files
  `0600` (subject to the reader contract).
- Resolve `serve`'s root once to a handle (as the engine already intends), never interpolate client-supplied paths.
- Refuse a root that is world-writable or owned by another user unless explicitly acknowledged? At minimum, the
  socket/trio permissions must not inherit a hostile directory's openness.

### F. Packaging and service templates

- POSIX service examples use `User=fsmeta` (systemd) or a per-user launchd agent, never a root unit.
- Windows service examples use a low-privilege virtual service account, not LocalSystem, and document the DACL.
- Container examples run as a non-root `USER`; rootless only where the host mapping is clearly unprivileged.
- Installation docs repeat the rule and show how to verify (`id`, `whoami /groups`, token elevation).

### G. Tests and checks

- Unit/startup test: a simulated privileged identity is refused before any socket/tree access.
- Integration test: daemon started normally reports its effective uid/token; socket and directory modes are `0700` /
  `0600`; a second user cannot connect.
- Exec-dialect test: disabled without opt-in; a disallowed peer is refused even when the dialect is enabled.
- Windows CI check for an elevated token; Linux container check for uid 0 refusal.
- A packaging check that no service template runs as root/LocalSystem.
- Make these tests part of `zig build test` / the contributing gate where the platform allows; skip with an explicit
  reason where the test cannot create a second user.

## 5. Decisions still to make

- **Hard refusal vs. override:** recommend hard refusal for all serving commands; if tests need root in a container,
  use a test-only compile-time or explicitly named `--unsafe-root-for-tests` flag, never an environment variable that
  silently ships.
- **Scope:** the rule applies to `daemon` and `serve`; should `refresh`/`scan`/`verify` also refuse root? They write
  the trio (refresh) and parse the same trees, so at least `refresh` should follow the daemon rule; read-only tools may
  be allowed.
- **Rootless containers:** define “unprivileged” by effective host access, not numeric uid alone.
- **Socket placement:** move `serve`'s socket out of the repository for shared checkouts, or make the local mode's
  permissions the documented exception.
- **Exec dialect:** remove it, opt-in it, or authenticate peers; this is the highest-risk feature and should be decided
  before any root-adjacent deployment.

## 6. Suggested order

1. **N1 (docs):** the rule at the top of README/AGENTS/daemon docs. **Done.**
2. **N2:** POSIX/Windows startup refusal, with a precise error and tests. **Done.**
3. **N3:** socket directory/mode + peer credentials; Windows DACL. **Done on POSIX; Windows gap.**
4. **N4:** exec dialect off/opt-in and peer-gated. **Done for `serve`; daemon/live never had it.**
5. **N5:** privilege-drop path for service managers; `no_new_privs`/capability clearing. **Done as hardening, not a drop.**
6. **N6:** filesystem no-follow/handle checks. **Done for engine/publish; batch/ignores gaps.**
7. **N7:** packaging templates and the negative tests above; run them in CI. **Docs/templates done; tests open.**

## 7. Acceptance

- The daemon refuses to serve when running as root, elevated Administrator, or SYSTEM. **Done (N2).**
- A normal unprivileged daemon creates an owner-only socket and rejects a different uid. **Done on Linux/macOS/BSD;
  Windows has no peer credentials/DACL in this implementation.**
- The exec dialect is not reachable without the explicit opt-in and same-user peer check. **Done for `serve`; the
  daemon never had the dialect.**
- `.fs-meta` creation refuses a symlink and uses owner-only modes. **Done for engine/publish; batch and ignores
  remain, and Windows has no POSIX modes.**
- Service templates and docs never suggest root/LocalSystem. **Done in `packaging/` and
  `doc/service-deployment.md`.**
- Tests cover refusal, permissions, peer rejection and the exec gate; the rule is in the top-level README, AGENTS.md
  and daemon guide. **Partial: module-level tests exist; the true root/elevated and second-user CI tests remain open.**
