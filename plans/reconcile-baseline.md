# The baseline option for `fsmeta reconcile`

Status: **implemented** (`BaselineStore` in `src/fsmeta.zig`), verified by hand on a change-and-change-back tree: without a baseline `reconcile` reports `changed a.txt`, with the baseline it reports `0 names`. The integration test described at the end is still to be added. Written after implementing `reconcile` (`94e503b`), because the facts below were
established by reading the code and would otherwise have to be rediscovered — and because the last three edits near this
path each broke the build, so the design is worth agreeing before it is written.

## What a baseline is

A consumer reconciles from the generation it recorded. Without a baseline, `reconcile` reports what the batches say: a name
that changed and changed back (a branch flip, a file restored) still appears as `changed`. With a baseline, `changed`
entries whose identity equals what the consumer already has are **dropped**, which is what makes the answer "the state
difference, not the event history".

`reconcile.collapse` already takes one:

```zig
pub const Baseline = struct {
    context: *anyopaque,
    lookup: *const fn (context: *anyopaque, nameHash: u64, name: []const u8) ?Identity,
};
```

So `--baseline` is an adapter, not a change to the collapse.

## The three facts the adapter needs

1. **A recorded state is a trio**, so the baseline is a *directory*: `--baseline <root>` loads `<root>/.fs-meta` through the
   existing `loadCache`. A diff file would be a second format to keep in step; a trio is what this project already reads.
2. **Identity flags must match what the batch events carry.** `batch.toEvents` builds an event's identity as
   `entry.flags_word & ~CHANGE_MASK`, so the adapter must reconstruct the same word:
   - a file is `REGULAR_FILE` or `SYMLINK` from `FileState.kind`, plus `CONTENT_KNOWN` when `content_hash != null` and
     `HASH_LF` when `hash_lf` is set;
   - a directory is `IS_DIR`;
   - no `CHANGE_*` bits. A mismatch here makes every comparison fail and the baseline silently do nothing, which is the
     failure mode to test for.
3. **The baseline's names are root-relative paths**, the same key the batch uses (`a.txt`, `src/b.java`, `src/` — a
   directory's stored name carries the slash). A `StringHashMap` keyed by that name is enough; the `nameHash` argument can
   be ignored, because the map is not hash-ordered and a hash collision is then harmless.

## The shape of the change

```
fsmeta reconcile <root> <from> [to] [--baseline <root>] [--json]
```

- `--baseline` is parsed in the option loop and passed to `runReconcile`.
- `runReconcile` loads the baseline trio once (not per batch), builds a `StringHashMap(Identity)` of files and directories,
  and passes `.{ .context = &store, .lookup = BaselineStore.lookup }` to `collapse`.
- Missing or invalid baseline trio: refuse with a message, never fall back to "no baseline" — a consumer that asked for one
  and silently did not get it would trust a diff of the wrong length.

## The test that proves it

Two trees, one history:

1. publish generation 1 with `a.txt` = "one"; copy `.fs-meta` aside as the baseline root;
2. publish generation 2 with `a.txt` = "two", then generation 3 with `a.txt` = "one" again (change, then a change back);
3. `reconcile <root> 1` reports `changed a.txt` — the batches saw two changes;
4. `reconcile <root> 1 --baseline <copy>` reports **0 names** — the identity equals what the baseline holds.

That difference is the whole reason the option exists, and it is the assertion that would have caught a flags mismatch.
