# Packaging and service templates

These files are **examples of running `fsmeta daemon` as a dedicated, unprivileged user**. They are the
documentation/packaging half of **N7** in [`plans/non-root-daemon.md`](../plans/non-root-daemon.md); they add no
enforcement of their own. The startup refusal (N2) is implemented in `src/security.zig`. Socket modes and peer
credentials (N3), the `{{` opt-in (N4), startup hardening (N5) and `.fs-meta` no-follow checks (N6) are separate
steps in that plan; check its § 6 for the status in the build you deploy. The templates do not depend on any
particular N3–N6 step having landed: they use account, directory and ACL separation to keep the daemon unprivileged
either way.

> **The rule: never run the daemon as root, an elevated Administrator, or SYSTEM/LocalSystem.** Use an ordinary
> unprivileged account — a dedicated one for a service. The daemon walks project trees, writes `.fs-meta` and serves
> a local socket that includes an executable dialect; a bug there must not have elevated permissions.

| File                                                         | Platform        | What it is                                                                                     |
| ------------------------------------------------------------ | --------------- | ---------------------------------------------------------------------------------------------- |
| [`systemd/fsmeta.service`](systemd/fsmeta.service)           | Linux (systemd) | unit running as `fsmeta`, with a 0700 runtime/state directory and a file-watcher hardening set |
| [`launchd/hr.hrg.fsmeta.plist`](launchd/hr.hrg.fsmeta.plist) | macOS           | LaunchDaemon running as `_fsmeta`; a LaunchAgent alternative is described in the guide         |
| [`windows/fsmeta-service.xml`](windows/fsmeta-service.xml)   | Windows         | wrapper config (WinSW example) for a service installed with `obj= "NT SERVICE\fsmeta"`; the wrapper is not shipped here |
| [`container/Dockerfile`](container/Dockerfile)               | Linux container | image with a numeric non-root `USER`; compose drops all capabilities and keeps the network off |
| [`container/compose.yaml`](container/compose.yaml)           | Linux container | read-only root filesystem, no networking, private runtime/config volumes, one read-write served root |

**Install and verification steps, including the operator checklist and the honest list of what is not enforced yet,
are in [`doc/service-deployment.md`](../doc/service-deployment.md).** The systemd unit, launchd plist and Windows
wrapper config are examples: adjust the binary path, the served-root paths and any options marked in their comments
before installing. None of them has a root or LocalSystem variant, and none should be given one.

**Releasing the artifacts is separate.** Maven Central, npm and the Zig tag are covered by
[`publishing.md`](../publishing.md); this directory is only about running the daemon, not about publishing it.

## The short version

1. Create a dedicated unprivileged account; give it no shell and no administrator group.
2. Give it private runtime/state directories (0700) and only the served roots it needs.
3. Run `fsmeta daemon start --foreground` under the service manager as that account — never with `sudo` and never
   with SCM's default `LocalSystem`.
4. Verify the process owner, the socket owner and the service's configured account.
5. Treat the socket as equivalent to a shell for that account: the `{{` executable dialect should be opt-in, and N4
   is the step that makes it so. Until you have confirmed the gate in your build, assume a client that can reach
   the socket can ask for a child process as that user.
