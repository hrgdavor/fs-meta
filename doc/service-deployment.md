# Running the fs-meta daemon as a non-root service

> **Status (2026-11-01).** The startup refusal (**N2**) is implemented in [`src/security.zig`](../src/security.zig):
> `serve` and `daemon start` refuse uid 0, an elevated Administrator token, LocalSystem/LocalService/NetworkService,
> or an identity whose privilege level cannot be determined. **N3–N6 are implemented** in this checkout:
> `socket_security.zig` makes POSIX sockets owner-only and peer-checked (Windows has a documented gap),
> `server.zig`/`fsmeta.zig` gate the `{{` dialect behind `serve --allow-exec` (default off), `security.zig` hardens
> the process after the gate, and `safe_dir.zig` refuses a symlinked `.fs-meta`. The in-tree N7 **negative tests are
> added** (socket modes, peer mismatch, exec gate, privileged refusal when the runner allows it); the different-uid
> and root/elevated **CI hosts remain open**. The authoritative status is
> [`plans/non-root-daemon.md`](../plans/non-root-daemon.md) § 6.
> The templates in [`packaging/`](../packaging/README.md) are safe defaults regardless of which binary you deploy.

> **The rule.** Run `fsmeta daemon`, `fsmeta serve`, and every other serving or watching process as an ordinary,
> unprivileged user. Never as root, never from an elevated Administrator/SYSTEM prompt, never as LocalSystem. Use a
> dedicated account for a service. The daemon walks project trees, writes `.fs-meta`, and serves a local Unix socket;
> a bug in any of those paths must stay at that user's ordinary privilege.

## 1. What the startup refusal does and does not do

The refusal runs before the daemon opens a socket or starts watching:

- **POSIX:** the effective uid is checked; `0` is refused.
- **Windows:** the process token's `TokenElevation` is checked, and the LocalSystem/LocalService/NetworkService SIDs are
  refused even when the elevation bit is clear. A failed token query is a refusal, not a pass.
- **Both:** there is no `--allow-root` escape hatch. Do not wrap the daemon in `sudo`, `runas`, a root LaunchDaemon, or
  a LocalSystem service.

It is **not** a capability audit. On POSIX it checks the effective uid only; do not give the binary file
capabilities (`setcap`) or start it with ambient capabilities. On Windows it checks elevation and the three service
SIDs only; do not assume it notices every other privileged group or privilege. The unprivileged account remains the
real control.

The refusal covers `serve` and `daemon start`. It does **not** cover commands such as `refresh`, `scan` and `verify`;
those also read project trees and `refresh` writes the trio, so run them as the same ordinary user. Do not treat
"only serving is refused" as permission to run maintenance commands as root.

The `daemon start` refusal exits with code **4**; `serve` reports the refusal and exits non-zero. A service that fails
immediately with either is a service started under the wrong account — read the log before changing anything else.

### 1.1 Quick identity check

For a manual (non-service) run, check the account you are actually using before starting anything:

```sh
id
id -u
id -un
```

```powershell
whoami /user
whoami /groups | Select-String 'S-1-16-12288','S-1-16-16384'
```

On POSIX `id -u` must not be `0`. On Windows, a match for `S-1-16-12288` (High mandatory level) or `S-1-16-16384`
(System) means the shell is elevated; do not run `fsmeta serve` or `fsmeta daemon start` from it. For a service, the
`ps`/`GetOwner` checks in the platform sections are authoritative — the service does not inherit your terminal's
token.

## 2. The socket is a trust boundary — and the `{{` dialect is the reason

The daemon serves one consumer socket per root at `<runtime>/roots/<id>.sock`; `fsmeta serve` serves
`<root>/.fs-meta/socket`. The protocol includes the `{{` **executable dialect**: the server hands the connection to a
child program as its stdin/stdout ([`FORMAT.socket.md`](../FORMAT.socket.md) § The `{{` dialect).

The opt-in gate for that dialect is **`fsmeta serve --allow-exec`**; it is **off by default** and is a process-level
operator decision, never a client request. A refused opener gets `protocol: exec-dialect-disabled` and no child. The
daemon never implements the dialect, and `serve --live` never classifies it, so neither can be loosened by this
switch. Even when enabled, the peer must match the serving uid/gid on a platform that reports it.

N3 (owner-only socket mode and peer credentials) is implemented on Linux/macOS/BSD: the socket is `0600`, the
daemon's runtime directories are `0700`, and a different uid/gid is refused. **Windows has no mode bits or AF_UNIX
peer credentials in this implementation**, so its inherited per-user ACL is the control; an explicit `--base`
outside the profile needs an operator ACL. The templates add that ACL separation independently.

**Practical rule:** treat the socket as equivalent to a shell for the service account. If another local user can
reach it, that user can act as the daemon. Check this explicitly in § 5.4, § 6.3 and § 7.4. Do not use `serve` on a
checkout in a shared or world-writable directory: its socket lives inside the repository, unlike the daemon's socket
in the private runtime directory.

## 3. Pick a deployment shape

| Platform            | Template                                                                            | Account                             | Starts without a login? | Notes                                                                |
| ------------------- | ----------------------------------------------------------------------------------- | ----------------------------------- | ----------------------- | -------------------------------------------------------------------- |
| Linux, systemd      | [`packaging/systemd/fsmeta.service`](../packaging/systemd/fsmeta.service)           | `fsmeta` system user                | yes                     | the reference service shape; hardening options are commented there   |
| macOS, LaunchDaemon | [`packaging/launchd/hr.hrg.fsmeta.plist`](../packaging/launchd/hr.hrg.fsmeta.plist) | `_fsmeta` hidden user               | yes                     | `UserName`/`GroupName` are mandatory; without them launchd uses root |
| macOS, LaunchAgent  | described in § 6.4                                                                  | the logged-in user                  | no                      | developer desktop only; no `UserName` key                            |
| Windows, service    | [`packaging/windows/fsmeta-service.xml`](../packaging/windows/fsmeta-service.xml)   | `NT SERVICE\fsmeta` virtual account | yes                     | needs a service wrapper; `fsmeta.exe` has no native service host     |
| Linux container     | [`packaging/container/Dockerfile`](../packaging/container/Dockerfile) + [compose.yaml](../packaging/container/compose.yaml) | numeric uid/gid `10001` | with a restart policy | read-only root filesystem, no capabilities, no network |

A dedicated account per daemon is the safe default. Sharing the account with an interactive login, an editor, or an
unrelated service gives every process in that account the daemon's access to every served root.

## 4. Accounts, directories and the two paths

Create an account that cannot log in and is not an administrator:

- Linux: a system user with `/usr/sbin/nologin`, no supplementary groups unless a served root needs one.
- macOS: a hidden service account with `/usr/bin/false` as its shell.
- Windows: the service's own virtual account `NT SERVICE\fsmeta` (no password, no profile, no interactive login).
- Container: a numeric user in the image; no shell is needed at runtime.

The daemon has exactly two host-state locations besides the served roots ([`FORMAT.daemon.md`](../FORMAT.daemon.md) § 1):

| Variable             | Meaning                                                                              | Default when unset |
| -------------------- | ------------------------------------------------------------------------------------ | ------------------ |
| `FSMETA_RUNTIME_DIR` | used as-is: sockets, claims, pid file, per-root logs                                 | `$XDG_RUNTIME_DIR/fsmeta`, else `~/.cache/fsmeta/run` (POSIX); `%LOCALAPPDATA%\fsmeta\run` (Windows) |
| `FSMETA_CONFIG_HOME` | **a prefix**, not the directory: the list is `$FSMETA_CONFIG_HOME/fsmeta/roots.json` | `$XDG_CONFIG_HOME/fsmeta/roots.json`, else `~/.config/fsmeta/roots.json` (POSIX); `%APPDATA%\fsmeta\roots.json` (Windows) |

Both directories must be private to the service account (`0700` on POSIX, an ACL naming only the account and
Administrators/SYSTEM on Windows). The runtime directory is rebuilt on every start; `roots.json` is durable and is
written only by the daemon.

**Served roots.** The daemon writes the trio and `batches/` inside each root. For a dedicated service account, give
it a dedicated checkout or a tree that is group-writable by that account — not a developer's live working tree. Do
not serve `/`, `/tmp`, a home directory the service account does not own, or a world-writable directory. Prefer a
narrow path such as `/srv/fsmeta/<repo>`, `/usr/local/var/fsmeta/roots/<repo>`, or `C:\srv\fsmeta\<repo>`. A
per-user LaunchAgent (§ 6.4) is the exception: it runs as the logged-in user, so serving that user's own repository
under their home is that user's ordinary privilege, not a shared service. Nested roots are supported and guarded by
the parent's managed ignore block ([`doc/daemon.md`](daemon.md)); they still each need to be reachable and writable
by the same account.

## 5. Linux: systemd

### 5.1 Install

```sh
# 1. A system account with no login shell and no administrator group.
sudo groupadd --system fsmeta
sudo useradd --system --gid fsmeta --home-dir /var/lib/fsmeta \
     --no-create-home --shell /usr/sbin/nologin fsmeta
# /sbin/nologin is the path on some distributions; use whichever exists.

# 2. A narrow place for served roots, owned by the account. Clone or copy the
#    repositories here as fsmeta; do not point the service at a developer's tree.
sudo install -d -o fsmeta -g fsmeta -m 0750 /srv/fsmeta
sudo -u fsmeta git clone <repository-url> /srv/fsmeta/app

# 3. The engine binary.
sudo install -m 0755 zig-out/bin/fsmeta /usr/local/bin/fsmeta

# 4. The unit. StateDirectory= creates /var/lib/fsmeta as 0700; --no-create-home
#    in step 1 keeps useradd from creating it wider first.
sudo install -m 0644 packaging/systemd/fsmeta.service /etc/systemd/system/fsmeta.service
sudo systemctl daemon-reload
sudo systemctl enable --now fsmeta.service
```

The unit starts with an empty root list, which is valid. Add the root as the service account, with the same two
environment values the unit sets:

```sh
sudo -u fsmeta env FSMETA_RUNTIME_DIR=/run/fsmeta FSMETA_CONFIG_HOME=/var/lib \
  /usr/local/bin/fsmeta root add /srv/fsmeta/app --mode auto
sudo -u fsmeta env FSMETA_RUNTIME_DIR=/run/fsmeta FSMETA_CONFIG_HOME=/var/lib \
  /usr/local/bin/fsmeta roots list
```

`FSMETA_CONFIG_HOME=/var/lib` means the durable list is `/var/lib/fsmeta/roots.json` — the `fsmeta/` component is
added by the code, not by the unit. The runtime sockets are `/run/fsmeta/roots/<id>.sock`.

### 5.2 What the hardening options are for

| Setting                                                 | Why it suits this daemon                                                                          | Caveat                                                                                         |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `User=fsmeta` / `Group=fsmeta`                          | the rule itself; the daemon refuses uid 0 anyway                                                  | the account must own or be able to write each served root                                      |
| `NoNewPrivileges=yes`                                   | no set-uid/file-capability escalation from the daemon or a child it spawns                        | it does **not** disable the `{{` dialect or limit which program a client may ask for           |
| `PrivateTmp=yes`                                        | hooks and clients cannot meet through a shared `/tmp`                                             | a served root under `/tmp` disappears from the service's view — do not serve `/tmp`            |
| `PrivateDevices=yes`                                    | a file watcher needs no physical devices                                                          | hooks that need a device (GPU, serial) must not be used here                                   |
| `ProtectSystem=strict` + `ReadWritePaths=`              | the binary, `/usr` and `/etc` are read-only; only the roots the operator names are writable       | **every** served root needs a `ReadWritePaths=` entry, or publishing the trio fails            |
| `ProtectHome=yes`                                       | repositories under `/home` are hidden, which is the point when roots live under `/srv`            | if a served root is under `/home`, remove this line and list that root in `ReadWritePaths=`    |
| `RestrictAddressFamilies=AF_UNIX`                       | the daemon only listens on a Unix socket; no TCP is needed                                        | git hooks that need the network need `AF_INET AF_INET6`; `fsmeta serve --http` is a different command |
| `RestrictNamespaces=yes`                                | a file watcher needs no new namespaces                                                            | hooks that use `unshare`, `bwrap` or a sandbox need this relaxed                               |
| `CapabilityBoundingSet=` + `AmbientCapabilities=`       | even a misconfigured host cannot hand the process a capability                                    | never add `setcap` to the binary or ambient capabilities to the unit                           |
| `UMask=0077`                                            | files and directories the daemon creates are owner-only, independent of the code's explicit modes | an existing `.fs-meta` keeps its old mode; `safe_dir.zig` refuses a symlink but does not rewrite an existing world-readable tree |
| `RuntimeDirectoryMode=0700` + `StateDirectoryMode=0700` | sockets and `roots.json` are unreachable by other local users as well as by the daemon's own `0700` creation | these modes apply at creation; an older wider directory is narrowed by `ensurePrivateDir` on the daemon's start |
| memory-denying / `SystemCallFilter` options             | deliberately **not** set                                                                          | they would apply to git hooks and the `{{` child too, and break legitimate JIT-based or syscall-heavy tools |

`daemon start --foreground` is the mode a supervisor wants. It is the same branch `daemon start` re-executes when it
daemonizes itself ([`FORMAT.daemon.md`](../FORMAT.daemon.md) § 6), so it is not a test-only binary path.

### 5.3 If `fsmeta serve` is used instead

`serve` is a single-root command with a socket **inside the repository** at `<root>/.fs-meta/socket`. It is not what
the systemd unit runs. If you must supervise `serve`, copy the unit, change `ExecStart=` to
`fsmeta serve <root> --live`, and keep everything else the same; do not add `--http`. Its socket inherits the
repository directory's reachability; do not use it for a shared checkout, and do not add `--http` on an untrusted
network. `safe_dir.zig` and `socket_security.zig` are the code-level fixes for the write/socket surface; the socket is
made `0600` and peers are checked on POSIX, while Windows relies on the repository/ACL reachability.

### 5.4 Verify

```sh
# The unit parses and points at an existing executable.
sudo systemd-analyze verify /etc/systemd/system/fsmeta.service

# The service definition and the process's real identity.
systemctl show -p User -p Group fsmeta.service
MAINPID=$(systemctl show -p MainPID --value fsmeta.service)
ps -o user:20,pid,args -p "$MAINPID"
sudo grep -E '^(Uid|Gid|Groups):' "/proc/$MAINPID/status"
id fsmeta

# The account is not root and not in an administrator group.
id -u fsmeta
id -Gn fsmeta

# Runtime directory and sockets are owned by the service account, and 0700.
sudo stat -c '%A %U:%G %n' /run/fsmeta
sudo find /run/fsmeta -maxdepth 2 -name '*.sock' -exec stat -c '%A %U:%G %n' {} +

# The trio directory is writable by the service account (owner shown must be fsmeta).
sudo stat -c '%A %U:%G %n' /srv/fsmeta/app/.fs-meta /srv/fsmeta/app/.fs-meta/files.meta

# The daemon answers its own CLI as the service user.
sudo -u fsmeta env FSMETA_RUNTIME_DIR=/run/fsmeta FSMETA_CONFIG_HOME=/var/lib \
  /usr/local/bin/fsmeta daemon status
sudo -u fsmeta env FSMETA_RUNTIME_DIR=/run/fsmeta FSMETA_CONFIG_HOME=/var/lib \
  /usr/local/bin/fsmeta roots list

# Another local user must not reach the runtime directory or get an answer.
if sudo -u nobody test -r /run/fsmeta; then echo 'UNSAFE: runtime dir readable by nobody'; fi
sudo -u nobody env FSMETA_RUNTIME_DIR=/run/fsmeta FSMETA_CONFIG_HOME=/var/lib \
  /usr/local/bin/fsmeta roots list || echo 'ok: other user refused'

# A refusal message in the journal means the unit started under the wrong account.
journalctl -u fsmeta.service -b --no-pager | grep -i 'refusing to serve' && echo 'WRONG ACCOUNT'
```

`Uid` in `/proc/<pid>/status` must be a number other than `0`. If `ps` shows `root`, stop the service and fix
`User=` before doing anything else.

## 6. macOS: launchd

### 6.1 LaunchDaemon or LaunchAgent

| Shape            | Runs as                                    | Starts                       | `UserName` key                             | Use it for                                         |
| ---------------- | ------------------------------------------ | ---------------------------- | ------------------------------------------ | -------------------------------------------------- |
| **LaunchDaemon** | the account named by `UserName`            | boot, before any login       | required — **omitting it means root**      | a dedicated `_fsmeta` service account              |
| **LaunchAgent**  | the logged-in user, in that user's session | at login, stops at logout    | not applicable (an agent runs as the user) | a single developer's desktop, never a shared host  |

The included plist is a **LaunchDaemon** with `UserName`/`GroupName` set to `_fsmeta`. A LaunchDaemon is the only
shape that can serve before login, and it is also the only one where omitting `UserName` would silently produce a
root process — the thing this rule forbids.

### 6.2 Install the LaunchDaemon

```sh
# 1. An unprivileged hidden account with no login shell and no admin group.
#    The exact account tooling varies by macOS release; sysadminctl is the modern one.
sudo sysadminctl -addUser _fsmeta -fullName "fs-meta service" \
     -shell /usr/bin/false -home /var/empty
# If sysadminctl already created the matching group, skip this line.
sudo dseditgroup -o create _fsmeta
sudo dscl . -create /Users/_fsmeta PrimaryGroupID \
     "$(dscl . -read /Groups/_fsmeta PrimaryGroupID | awk '{print $2}')"
id _fsmeta
# _fsmeta must not appear in: dscl . -read /Groups/admin GroupMembership
# _fsmeta must not have a usable login shell: dscl . -read /Users/_fsmeta UserShell

# 2. Private host state. FSMETA_CONFIG_HOME is a prefix, so roots.json is
#    /Library/Application Support/fsmeta/roots.json. The runtime lives under
#    /Library/Caches so the directory survives a reboot.
sudo install -d -o _fsmeta -g _fsmeta -m 0700 \
     "/Library/Application Support/fsmeta" /Library/Caches/fsmeta \
     /Library/Caches/fsmeta/run /Library/Logs/fsmeta

# 3. A narrow served root the account can write.
sudo install -d -o _fsmeta -g _fsmeta -m 0750 /usr/local/var/fsmeta/roots
sudo -u _fsmeta git clone <repository-url> /usr/local/var/fsmeta/roots/app

# 4. The engine and the daemon.
sudo install -m 0755 zig-out/bin/fsmeta /usr/local/bin/fsmeta
sudo install -m 0644 -o root -g wheel packaging/launchd/hr.hrg.fsmeta.plist \
     /Library/LaunchDaemons/hr.hrg.fsmeta.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/hr.hrg.fsmeta.plist
sudo launchctl enable system/hr.hrg.fsmeta
```

Add the root as `_fsmeta`, with the same environment values the plist sets:

```sh
sudo -u _fsmeta env FSMETA_RUNTIME_DIR=/Library/Caches/fsmeta/run \
  FSMETA_CONFIG_HOME="/Library/Application Support" \
  /usr/local/bin/fsmeta root add /usr/local/var/fsmeta/roots/app --mode auto
```

On older macOS releases, `launchctl load -w /Library/LaunchDaemons/hr.hrg.fsmeta.plist` replaces `bootstrap`.

### 6.3 Verify

```sh
plutil -lint /Library/LaunchDaemons/hr.hrg.fsmeta.plist
sudo launchctl print system/hr.hrg.fsmeta | grep -E 'state|pid|program|path'
PID=$(sudo launchctl print system/hr.hrg.fsmeta | awk '/pid =/ {print $3; exit}')
ps -o user:20,pid,command -p "$PID"
id _fsmeta

sudo stat -f '%Sp %Su:%Sg %N' \
  "/Library/Application Support/fsmeta" \
  /Library/Caches/fsmeta/run \
  /Library/Caches/fsmeta/run/roots/*.sock \
  /usr/local/var/fsmeta/roots/app/.fs-meta

sudo -u _fsmeta env FSMETA_RUNTIME_DIR=/Library/Caches/fsmeta/run \
  FSMETA_CONFIG_HOME="/Library/Application Support" \
  /usr/local/bin/fsmeta roots list

# Another user must not read the runtime directory.
if sudo -u nobody test -r /Library/Caches/fsmeta/run; then echo 'UNSAFE: runtime dir readable by nobody'; fi
```

`ps` must print `_fsmeta` (or the account you chose), never `root`. `launchctl print` alone can be misleading about
the effective user after a failed start; `ps -o user` is the authoritative check.

### 6.4 LaunchAgent alternative for a desktop

A LaunchAgent runs as the logged-in user and cannot run before login. It has no `UserName` key — it is already in
that user's session — and it must never be loaded with `sudo` or into the `system` domain. For a single developer,
create `~/Library/LaunchAgents/hr.hrg.fsmeta.agent.plist` with these keys:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>hr.hrg.fsmeta.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/fsmeta</string>
        <string>daemon</string>
        <string>start</string>
        <string>--foreground</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

There is deliberately no `UserName` and no root-owned directory in that shape. No environment overrides are needed:
with no `FSMETA_*` set, the runtime directory is `~/.cache/fsmeta/run` and the root list is
`~/.config/fsmeta/roots.json`. Load it with
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/hr.hrg.fsmeta.agent.plist` and verify with
`launchctl print gui/$(id -u)/hr.hrg.fsmeta.agent`. This shape does not need root anywhere, and it stops when the
user logs out.

## 7. Windows: a service with a virtual account

### 7.1 There is no native Windows service host

`fsmeta.exe` is a console program: it does not call `StartServiceCtrlDispatcher`. A service created with
`sc.exe create ... binPath= "...\fsmeta.exe ..."` directly will fail with error 1053 ("did not respond in a timely
manner"). Use a wrapper that can host a console process — the example here is
[WinSW](https://github.com/winsw/winsw), which is **not** shipped in this repository and is not tested here — and
install the service under the low-privilege virtual account:

```text
NT SERVICE\fsmeta
```

The virtual account is created by the Service Control Manager when the service is created, has no password and no
interactive login, and can be granted access to exactly the directories the daemon needs. Never use LocalSystem,
LocalService or NetworkService: N2 refuses those tokens at startup, and the default for a Windows service is
LocalSystem. A virtual service account is a separate, low-privilege service SID — it is not one of the three rejected
accounts — and it is accepted by the startup check precisely because it is not an elevated or SYSTEM-class token.

The wrapper configuration is [`packaging/windows/fsmeta-service.xml`](../packaging/windows/fsmeta-service.xml). Rename
the wrapper executable to `fsmeta-service.exe` and keep the XML beside it as `fsmeta-service.xml`; the wrapper launches
`fsmeta.exe daemon start --foreground` and the child inherits the wrapper's virtual-account token.

### 7.2 Install

Run these in an **Administrator** PowerShell. Being elevated is fine for the installer and for the CLI: the no-root
rule is about the serving process.

```powershell
$prefix = 'C:\Program Files\fs-meta'
New-Item -ItemType Directory -Force $prefix,
    'C:\ProgramData\fsmeta', 'C:\ProgramData\fsmeta\run',
    'C:\ProgramData\fsmeta\logs', 'C:\srv\fsmeta', 'C:\srv\fsmeta\app' | Out-Null

Copy-Item .\zig-out\bin\fsmeta.exe "$prefix\fsmeta.exe" -Force
Copy-Item .\packaging\windows\fsmeta-service.xml "$prefix\fsmeta-service.xml" -Force
# Put the wrapper executable at "$prefix\fsmeta-service.exe" (not shipped here).

# Create the service with the virtual account, NOT the SCM default LocalSystem.
# start= demand keeps a reboot in the middle of this procedure from starting a
# half-configured service; it is switched to auto after the ACLs and environment.
sc.exe create fsmeta binPath= '"C:\Program Files\fs-meta\fsmeta-service.exe"' `
    obj= "NT SERVICE\fsmeta" start= demand
sc.exe description fsmeta "fs-meta daemon (non-root file watcher)"
sc.exe failure fsmeta reset= 86400 actions= restart/5000/restart/10000/restart/30000

# Verify before starting. SERVICE_START_NAME must be NT SERVICE\fsmeta.
sc.exe qc fsmeta
```

If `sc.exe` reports `SERVICE_START_NAME : LocalSystem`, stop: delete the service and set `obj=` again. Do not
"work around" it by granting LocalSystem access — that is the configuration this rule forbids. If `sc.exe` rejects
the virtual account on your Windows build, use a dedicated local user account (or a gMSA) with `obj=` and
`password=` and the same ACLs; never fall back to LocalSystem.

ACLs (the service SID exists only after the service is created):

```powershell
# Config and runtime: only SYSTEM, Administrators and the service account.
icacls 'C:\ProgramData\fsmeta' /inheritance:r /grant:r `
    'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' 'NT SERVICE\fsmeta:(OI)(CI)M'

# Served root: add modify for the service account; do not strip the repository's own ACLs.
icacls 'C:\srv\fsmeta\app' /grant 'NT SERVICE\fsmeta:(OI)(CI)M'
```

The daemon's environment is a service registry value (the SCM does not read your PowerShell environment):

```powershell
$svc = 'HKLM:\SYSTEM\CurrentControlSet\Services\fsmeta'
New-ItemProperty -Path $svc -Name Environment -PropertyType MultiString -Force -Value @(
    'FSMETA_RUNTIME_DIR=C:\ProgramData\fsmeta\run',
    'FSMETA_CONFIG_HOME=C:\ProgramData'
)
```

`FSMETA_CONFIG_HOME=C:\ProgramData` means the durable list is `C:\ProgramData\fsmeta\roots.json`; the runtime
sockets are `C:\ProgramData\fsmeta\run\roots\<id>.sock`. Start the service and add a root:

```powershell
sc.exe config fsmeta start= auto
sc.exe start fsmeta

$env:FSMETA_RUNTIME_DIR = 'C:\ProgramData\fsmeta\run'
$env:FSMETA_CONFIG_HOME = 'C:\ProgramData'
& 'C:\Program Files\fs-meta\fsmeta.exe' root add 'C:\srv\fsmeta\app' --mode auto
& 'C:\Program Files\fs-meta\fsmeta.exe' roots list
```

The CLI is a client, not a serving process, so running it from this elevated shell is allowed. Windows has no
peer-credential check on the socket (the plan's § 4C records that platform gap); the runtime directory's ACL is what
controls access. The control socket is narrowed to `0600` on POSIX but Windows has no mode bits to set, so do not
loosen the ACL; run management commands as the service account with the host's supported mechanism.

### 7.3 Root path and ACL considerations

- Serve a **narrow, dedicated** directory on a local fixed disk. Not `C:\`, `C:\Windows`, `C:\Program Files`, a whole
  user profile, or a mapped network drive (services do not see per-user drive mappings).
- The service account needs `Modify` on the root and its subdirectories because the daemon writes `.fs-meta/` and
  `batches/` there. Grant it on the narrow root, not on a volume.
- If `.fs-meta` already exists from a developer's run under another account, the service cannot publish into it.
  Stop the service, remove or re-ACL that `.fs-meta`, and let the daemon create it.
- Grant `Read`/`Execute` on every parent directory in the path, or the service cannot traverse to the root.
- Do not grant `Everyone` or `Users` write access to the root or to `C:\ProgramData\fsmeta`; a local user who can
  write there can feed the watcher and reach its state.
- `AF_UNIX` sockets require Windows 10 1803 or later. Check the target before promising a Windows deployment.
- A UNC root may be reachable through the computer account (`DOMAIN\COMPUTER$`), not the interactive user. Test it;
  do not assume the service sees the same shares you do.

### 7.4 Verify

```powershell
# The configured service account and the running process owner.
sc.exe qc fsmeta
Get-CimInstance Win32_Service -Filter "Name='fsmeta'" |
    Format-List Name,StartName,State,ProcessId

$p = Get-CimInstance Win32_Process -Filter "Name='fsmeta.exe'"
$p | Invoke-CimMethod -MethodName GetOwner | Format-List Domain,User
$p | Select-Object ProcessId,ExecutablePath

# Runtime directory and socket ACLs: the service SID, SYSTEM and Administrators only.
Get-Acl 'C:\ProgramData\fsmeta\run' | Format-List
Get-ChildItem 'C:\ProgramData\fsmeta\run\roots' -Filter *.sock |
    ForEach-Object { Get-Acl $_.FullName } | Format-List

# The CLI answers as the service's environment.
$env:FSMETA_RUNTIME_DIR = 'C:\ProgramData\fsmeta\run'
$env:FSMETA_CONFIG_HOME = 'C:\ProgramData'
& 'C:\Program Files\fs-meta\fsmeta.exe' daemon status
& 'C:\Program Files\fs-meta\fsmeta.exe' roots list

# In the operator's own shell: what token is this? High/System mandatory level means elevated.
whoami /user
whoami /groups | Select-String 'S-1-16-12288','S-1-16-16384'
```

The `GetOwner` result must be `NT SERVICE\fsmeta`, not `SYSTEM`, `LOCAL SERVICE` or an administrator. If `sc.exe qc`
and `GetOwner` disagree, trust `GetOwner` for the running process and fix the service configuration. A refusal in
the wrapper log (`refusing to serve as a privileged user`) means the configured account is elevated or a service
SID; do not edit the refusal away.

## 8. Containers: non-root by construction

### 8.1 Build and run

The image runs as uid/gid 10001 and listens only on AF_UNIX. The compose example adds a read-only root filesystem,
a private runtime volume, a config volume, all Linux capabilities dropped, and one bind-mounted served root:

```sh
# Build the Linux engine first (a Windows fsmeta.exe is not usable in this image).
zig build
docker compose -f packaging/container/compose.yaml up -d --build

# The host root must be writable by the container uid; make the dedicated
# checkout owned by that uid, or match the image to the host owner:
# FSMETA_UID=$(id -u) FSMETA_GID=$(id -g) docker compose ... up -d --build.
docker compose -f packaging/container/compose.yaml exec \
  -u "${FSMETA_UID:-10001}:${FSMETA_GID:-10001}" fsmeta \
  fsmeta root add /srv/fsmeta/app --mode auto
```

The container is deliberately not given `privileged`, `CAP_SYS_ADMIN`, a host user namespace, a Docker socket, or a
network. Removing `network_mode: none` is only for hooks or tooling that genuinely need the network; the daemon
itself does not.

### 8.2 Rootless user namespaces: the caveat

A rootless engine maps container uid 0 to your unprivileged host uid. That does **not** make uid 0 inside the
container acceptable:

- The daemon sees `geteuid() == 0` and the **N2 refusal rejects it**, exactly as it would on a root host.
- A bind mount's ownership is seen through the mapping; uid 10001 in the container is usually a subordinate host
  uid, not your uid. Files you own on the host may be read-only or inaccessible to it.
- Do not "fix" either problem with `user: "0:0"`, `--privileged`, `--userns=host` (as root), or added capabilities.
  Match the container uid to the host owner (build args, or `podman unshare chown` for a volume), or use
  `--userns=keep-id` with an image built for your uid.

The goal is the same as on a host: an ordinary account, a private runtime directory, and only the roots it serves.
A rootless container does not need root anywhere in its definition, and the templates contain none.

### 8.3 Verify

```sh
docker compose -f packaging/container/compose.yaml config --quiet
docker compose -f packaging/container/compose.yaml exec fsmeta id
docker compose -f packaging/container/compose.yaml exec fsmeta \
  sh -c 'stat -c "%A %u:%g %n" /run/fsmeta /srv/fsmeta/app/.fs-meta'

CID=$(docker compose -f packaging/container/compose.yaml ps -q fsmeta)
docker inspect -f 'user={{.Config.User}} privileged={{.HostConfig.Privileged}} readonly={{.HostConfig.ReadonlyRootfs}}' "$CID"
```

`id -u` must not be `0`, `privileged` must be `false`, and the runtime directory must be owned by the container
user. If the served root is not writable, fix the host ownership or the build args; do not add privileges.

## 9. Operator checklist

- [ ] The service account is unprivileged, has no login shell, and is not in an administrator/root group.
- [ ] The service definition names that account (`User=`, `UserName`, `obj=`, or image `USER`); no LocalSystem, no
      root, no `sudo` wrapper.
- [ ] `ps -o user` / `GetOwner` shows that account for the running process, not just the configuration file.
- [ ] The runtime directory is `0700` (or an ACL naming only the service account, SYSTEM and Administrators) and is
      on a local filesystem.
- [ ] `roots.json` and its directory are owned by the service account and are not readable by other local users.
- [ ] Every served root is owned or group-writable by the service account; `.fs-meta/` is writable and owned by it.
- [ ] No served root is `/`, `/tmp`, `C:\`, `C:\Windows`, or a world-writable directory; a dedicated service account
      does not serve a home directory it does not own.
- [ ] No `setcap`, ambient capabilities, or elevated token is attached to the binary or service.
- [ ] Another local user cannot reach the runtime directory or get an answer from the socket.
- [ ] The `{{` dialect is treated as shell access for the service account; the socket is not shared and `serve` is
      not used on a shared checkout.
- [ ] `roots list` and `daemon status` answer as the service account; the service starts after reboot/login.
- [ ] Logs contain no `refusing to serve` line; if they do, the process is running under the wrong account.
- [ ] After an upgrade, `roots.json` was preserved and the runtime directory was rebuilt; no root flag was added.

## 10. What this document deliberately does not claim

- That every N3–N6 behaviour is identical on every platform. POSIX has owner-only sockets/peer checks, no-follow
  `.fs-meta` and `no_new_privs` (Linux); Windows has neither POSIX modes nor AF_UNIX peer credentials, and macOS/BSD
  have no `no_new_privs`. [`plans/non-root-daemon.md`](../plans/non-root-daemon.md) § 6 and the code named there are
  authoritative. The templates are safe defaults regardless.
- That the `{{` dialect is enabled anywhere by default. `fsmeta serve --allow-exec` is the explicit opt-in; the
  daemon never had the dialect. The default build refuses the opener with `exec-dialect-disabled`.
- That peer credentials are checked on Windows. The plan's § 4C records the platform surface; use the runtime
  directory ACL and a dedicated virtual account regardless.
- That the POSIX refusal checks capabilities, or that the Windows refusal enumerates every privilege. Neither is
  claimed by `src/security.zig`; the account choice remains the real control.
- That these templates are an installer. They are examples with comments; the commands in this guide are the
  procedure, and the second-uid/root CI execution is still open. Verify the checklist on the target host before trusting a
  deployment.
- That a third-party service wrapper (WinSW) is supported or shipped. It is an example of the only practical shape
  for a Windows service in this checkout; pin and review the wrapper you install.

## 11. Related documents

- [`plans/non-root-daemon.md`](../plans/non-root-daemon.md) — the policy and the N1–N7 status.
- [`doc/daemon.md`](daemon.md) — the daemon's modes, roots, paths and switches.
- [`FORMAT.daemon.md`](../FORMAT.daemon.md) — the normative daemon reference, including the runtime/config rules.
- [`FORMAT.socket.md`](../FORMAT.socket.md) — the protocol and the `{{` dialect.
- [`packaging/README.md`](../packaging/README.md) — the template index.
- [`AGENTS.md`](../AGENTS.md) § 0 — the repository rule this guide operationalises.
