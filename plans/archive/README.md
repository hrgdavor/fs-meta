# plans/archive — finished plans, kept for the record

These plans are **done**: their milestones are implemented, their decisions are in the reference documents, and their
open questions are either answered or moved to a live file. They are archived rather than deleted because a decision is
only as good as the reasoning behind it, and because a session that re-reads the code usually wants to know *why* it
looks the way it does.

**Do not edit these files to describe new work.** The live documents are:

| live document                                            | what it holds                                                                                    |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| [`../next-steps.md`](../next-steps.md)                   | what is left, in order, across the whole project                                                 |
| [`../worktrees.md`](../worktrees.md)                     | the worktree plan (next major work), which supersedes the nested-roots rule in `daemon.md` § 16b |
| [`../tbd-per-root-daemon.md`](../tbd-per-root-daemon.md) | the one deliberately unscheduled item (M5)                                                       |
| [`../../FORMAT.md`](../../FORMAT.md)                     | the trio, normative                                                                              |
| [`../../FORMAT.socket.md`](../../FORMAT.socket.md)       | the wire protocol, normative                                                                     |
| [`../../FORMAT.daemon.md`](../../FORMAT.daemon.md)       | the daemon as built: layout, state machine, control API, budgets                                 |

If an archived plan's outcome changes, change the live document and add a line here with the date and the reason.

## The archive

| file                                                         | what it was                                                                                   | outcome |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------- | ------- |
| [`daemon.md`](daemon.md)                                     | the plan for `fsmeta daemon`: M0–M4, the state machine, the per-root model, the nested-roots decision | **implemented through M4**; the design as built is `FORMAT.daemon.md`, and the measurement and parity gates are in `doc/benchmark.md`, `test/daemon.test.mjs` and `test/daemon-parity.test.mjs`. M5 moved to [`../tbd-per-root-daemon.md`](../tbd-per-root-daemon.md). § 16b's nested-roots rule (allow + warn) is superseded by [`../worktrees.md`](../worktrees.md): a nested repository is excluded by the scan rule, a nested root that is not a repository is guarded by the internal ignore or refused, and nothing is merely warned about. |
| [`next-session-pair-layout.md`](next-session-pair-layout.md) | the plan that diagnosed and fixed the pair layout (`files.txt` order vs `files.meta` order, the name-offset pair) | **done**: `publish` lays out through `pair.layout` with the count assertion, emits `roots`, and `FORMAT.md` § 2/§ 5 state the two orders correctly. |
| [`reconcile-baseline.md`](reconcile-baseline.md)             | the plan for `fsmeta reconcile --baseline` — the consumer's "what changed since *my* state"   | **done**: the flag, the identity reconstruction and the tests exist; the defect it later exposed (a deleted batch name corrupted by freeing borrowed cache keys) was fixed with the cache key-ownership change recorded in `../next-steps.md` § H. |
| [`query-glob-changed.md`](query-glob-changed.md)             | the plan for the `match`/`changed` CLI over the trio, and the socket variant of the same idea | **done for the CLI** (`match` with `wildmatch`, `changed`, `--since`, `--json`, exit codes; `test/query-cli.test.mjs`); the socket variant was **superseded** by `FORMAT.socket.md`'s `SUBSCRIBE` + batches, which carry the whole change stream instead of a query. |
