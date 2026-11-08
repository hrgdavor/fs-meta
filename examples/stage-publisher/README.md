# Stage publisher — copy artifacts while the stage batch is still arriving

A small scp-like client for the stage stream in [`plans/build-artifacts.md`](../../plans/build-artifacts.md) § 7.7.
It is deliberately **not** a watcher: the Zig daemon scans the declared stage folders and writes the stage state;
this client copies the resulting files and runs one post-batch action.

```sh
bun examples/stage-publisher/publisher.mjs \
  --socket "$FSMETA_RUNTIME/roots/<id>.sock" \
  --root ~/projects/demo \
  --dest /srv/demo-stage0 \
  --stage 1 \
  --include 'build/classes/**' \
  --after-batch 'systemctl reload demo'
```

`--stage 1` subscribes to the consumer of stage 0. Stage 0 must be declared in
`<root>/.fs-meta/build.json`:

```json
{
  "version": 1,
  "stages": [
    { "stage": 0, "folders": ["build/classes"] }
  ]
}
```

## What it does

- Sends `HELLO`, then `SUBSCRIBE_V3` at the current root head, with `from_stage_batch` defaulting to `0`.
- On `STAGE_BATCH_START`, starts a speculative copy set.
- On each `STAGE_CHANGE_ENTRY`, copies a changed file **immediately** (temp file + rename), creates changed
  directories, and queues deletes.
- On `STAGE_BATCH_END`, waits for the in-flight copies, applies deletes, checks the counts, and runs
  `--after-batch` once. A failed copy or count mismatch skips the hook and exits non-zero.
- If the connection drops mid-batch, nothing is committed; rerunning with the last `from_stage_batch` replays the
  archive and copies again.

The daemon never runs the hook. The client does, after the stage state has committed.

## Options

| Option                   | Meaning                                                      |
| ------------------------ | ------------------------------------------------------------ |
| `--socket <path>`        | Unix socket of the daemon root (`<runtime>/roots/<id>.sock`) |
| `--root <path>`          | Project root; names in the frames are workspace-relative     |
| `--dest <path>`          | Copy destination                                             |
| `--stage <n>`            | Consumer stage; defaults to 1 (stage 0's output)             |
| `--from-stage-batch <n>` | Last applied stage generation; defaults to 0                 |
| `--include <pattern>`    | Server-side stage filter; repeatable                         |
| `--exclude <pattern>`    | Server-side stage filter; repeatable                         |
| `--after-batch <script>` | Runs once after a successful `STAGE_BATCH_END`               |
| `--once`                 | Exit after the first stage batch                             |
