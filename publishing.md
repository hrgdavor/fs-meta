# Publishing

This checkout produces three artifacts, and a release is the same commit for all of them:

| artifact              | coordinate        | where                                         |
| --------------------- | ----------------- | --------------------------------------------- |
| Java client/reader    | `hr.hrg:fs-meta`  | Maven Central, through the Central publisher  |
| JavaScript/Bun client | `@hrg/fs-meta`    | npm                                           |
| Zig engine and daemon | `fsmeta` binaries | GitHub Releases, built from the tagged source |

The version is pinned in three places and must agree: `pom.xml`, `package.json` and `build.zig.zon`. Run
`bun scripts/check-poms.mjs` after editing either POM; it also asserts that the POMs have no SNAPSHOT dependency.

## Before the first release

1. **`hr.hrg:wyhash:1.2.0` is on Maven Central.** fs-meta pins `1.2.0` (the zero-allocation
   `String`/`MemorySegment` implementation and the generated vectors), so no local install or version override is
   needed. Central rejects a release whose POM depends on a SNAPSHOT; the POM names the released version.
2. **`hr.hrg:gitignore:0.3.5`** is already on Maven Central, so the other dependency needs no local install.
3. **JDK 25** (`JAVA_HOME` must point at it).
4. **Real Maven 3.9.x, not `mvnd`.** This machine's `mvn` is `mvnd` and it refuses `-Dmvnd.noDaemon`; the gitignore
   checkout has an unpacked Maven at `..\gitignore\.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd`. Any unpacked Maven
   3.9.x works; the examples below use `<maven-home>\bin\mvn.cmd`.
5. **The Central token** in `~/.m2/settings.xml`, under a server with id **`central`**. The publisher is configured
   with `publishingServerId=central`; a missing server is an authentication failure, not a POM error.
6. **A GPG key and `MAVEN_GPG_PASSPHRASE`.** Signing is off by default (`gpg.skip=true`); a release passes
   `-Dgpg.skip=false`. The profile passes `--pinentry-mode loopback`, so gpg reads `MAVEN_GPG_PASSPHRASE` instead of
   opening a prompt a batch build cannot answer. A passphrase stored in `settings.xml` is not used.
7. **A release version and a tag.** The POM and `package.json` are `0.3.8`; tag that commit before publishing.
   `v0.3.7` points at the previous published commit `90e97a3`, and `v0.3.6` predates the JavaScript daemon client
   and this publishing setup. Tag the released commit for every future release; do not publish an artifact whose
   tag points at different code.

## Publishing the Maven artifact

### Why there are two POMs

`pom.xml` is the normal build. It has no Central publisher, sets `maven.deploy.skip=true`, and a bare `mvn deploy`
therefore uploads nothing. `pom-release.xml` is a **copy** of it plus the `central-publishing-maven-plugin` in the
top-level `<build>`; it keeps `maven.deploy.skip=true`, because that stops `maven-deploy-plugin`, not the publisher (a
separate goal at the same phase). If the publisher extension ever failed to load, the release would do nothing instead
of falling back to a direct upload.

The publisher cannot live in `pom.xml`: Maven reads `<extensions>true</extensions>` only from a top-level `<build>`,
never from a profile. Declared in `pom.xml` it would load for every build and make a bare `mvn deploy` publish. It
cannot be a child of `pom.xml` either: Maven 3.9.9 rejects a jar-packaged POM as a parent, and Maven has no POM
include. So the file is duplicated and [scripts/check-poms.mjs](scripts/check-poms.mjs) keeps the copies in step:

```text
bun scripts/check-poms.mjs
```

The check strips comments, removes the release-only publisher, and fails if anything else differs. Edit `pom.xml`,
copy the change into `pom-release.xml`, then run it.

### The release commands

The first command proves the binary, sources and javadoc jars are built. It does not upload:

```text
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-25'
<maven-home>\bin\mvn.cmd -f pom-release.xml -Ppublish -DskipTests package
```

The second exercises the publisher without uploading: it stages and bundles locally, logs
`Skipping Central Publishing at user's request.`, and stops before the upload. This is the release-path smoke test:

```text
<maven-home>\bin\mvn.cmd -f pom-release.xml -DskipTests -DskipPublishing=true deploy
```

The release itself:

```text
$env:MAVEN_GPG_PASSPHRASE = '<your passphrase>'
<maven-home>\bin\mvn.cmd -f pom-release.xml -Ppublish -Dgpg.skip=false -DskipTests deploy
```

`-Ppublish` adds `maven-source-plugin`, `maven-javadoc-plugin` and `maven-gpg-plugin`; the profile is in both POMs.
The Central publisher takes over `deploy`, uses the `central` server for credentials, and publishes automatically
(`autoPublish=true`). The `distributionManagement` URLs in both POMs are the Central release/snapshot endpoints; the
publisher does not use `altDeploymentRepository`.

### After the release

- Check the artifact under `https://repo1.maven.org/maven2/hr/hrg/fs-meta/<version>/`.
- Consumers should depend on `hr.hrg:fs-meta:<version>` from Central, not on a local `mvn install`.
- `md-fix-tables` depends on `@hrg/fs-meta` and `@hrg/wyhash` 1.2.0; bump both pins after a new release. Its walk
  fallback stays useful when no daemon answers.

### Common failures

| symptom                                                           | cause                                                                                     |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `Could not resolve dependencies ... hr.hrg:wyhash:1.2.0`          | the wyhash release is not on Central (and is not installed locally)                       |
| `401` / `Unauthorized` from the publisher                         | missing or expired token under the `central` server id                                    |
| `gpg: signing failed: Bad passphrase`                             | `MAVEN_GPG_PASSPHRASE` is wrong; if it is unset, the agent reports `Operation cancelled`  |
| Central validation: `SNAPSHOT` dependency                         | a POM still points at a SNAPSHOT; use the released `1.2.0`                                |
| `Invalid packaging for parent POM ... must be 'pom' but is 'jar'` | `pom-release.xml` was made a child of `pom.xml`; it must be a copy                        |
| `deploy` uploaded nothing                                         | that was `pom.xml` (guard) or `-DskipPublishing=true`; the release uses `pom-release.xml` |

## Publishing the npm package

`package.json` is non-private (`private: false`) and declares `publishConfig.access: public`.

**0.3.8 is this checkout** (the staged-build client API and the scoped `@hrg/wyhash` import); **0.3.7 is the
previous published version**. `@hrg/wyhash` 1.2.0 is on npm. For a release, bump `pom.xml`, `pom-release.xml`,
`package.json` and `build.zig.zon` together, tag the commit, then:

```text
bun test js
bun pm pack --dry-run
npm publish
```

A live token that can publish to the `@hrg` scope is required; npm reports a `404` when a token cannot publish to a
scope, which is a token problem rather than a missing package.

The wyhash JavaScript port is published as the scoped **`@hrg/wyhash`** package; the bare `wyhash` name on npm is an
unrelated package by lemon-mint. `js/layout.mjs` imports `@hrg/wyhash`, and `package.json` declares it as an optional
peer (`>=1.2.0`), so publishing it before fs-meta is what makes the Node trio reader work without a checkout link.
Bun's native hash is unaffected. See the wyhash project's `publishing.md` for that release.

## Publishing the Zig engine

The Zig engine is also published as **GitHub Release binaries**. Pushing a `v*` tag runs
[`.github/workflows/release.yml`](.github/workflows/release.yml), which cross-compiles and attaches:

- `fsmeta-<version>-x86_64-linux-musl.tar.gz`
- `fsmeta-<version>-aarch64-linux-musl.tar.gz`
- `fsmeta-<version>-x86_64-macos.tar.gz`
- `fsmeta-<version>-aarch64-macos.tar.gz`
- `fsmeta-<version>-x86_64-windows.zip`

Each archive contains the `fsmeta` binary plus `README.md`, `FORMAT.md`, `FORMAT.socket.md` and `FORMAT.daemon.md`.
The workflow checks out `hrgdavor/socutil` as a sibling because `build.zig.zon` uses the `../socutil` path dependency;
`workflow_dispatch` takes a tag and a `socutil_ref` input. Tag the same commit as the Maven/npm release so the daemon,
the Java client and the JavaScript client describe one version.

Source consumers still build with Zig 0.17.0 (`zig build`) or fetch the tagged source.
