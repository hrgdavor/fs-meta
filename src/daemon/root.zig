// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! One root, served: a consumer socket, its subscribers, its state machine, and the passes that keep it fresh.
//!
//! ## What "watching" means here
//!
//! A pass is `engine.refresh` — the same composition `fsmeta refresh` runs — so the daemon never reimplements
//! discovery, diffing, publishing or rotation; it decides *when* a pass runs and *who* hears about it.
//!
//! **The event source is `nightwatch`.** A `watching` root holds a recursive watch on its tree; nightwatch's own
//! thread calls the handler, which does nothing but raise a sequence number and a timestamp. `tick` — the
//! scheduler's 100 ms step — then decides *when* that becomes a pass: `watch.Scheduler` (the prototype's
//! self-tuning quiet period) turns a burst of events into one pass, and no event means no pass at all. A root
//! that is idle therefore costs one timer check, not a scan.
//!
//! Three details matter and are easy to get wrong:
//!
//! - **The watcher is armed before the wake scan, not after it.** A change that lands while the scan is running
//!   would otherwise fall between the scan and the watch and be invisible until the next change. Armed first,
//!   the pass sees it, and the event raises the dirty flag for a follow-up pass.
//! - **`.fs-meta` and `.git` events are ignored.** The first is our own output, and feeding it back would make
//!   the daemon publish itself forever; the second is not part of what a trio describes (`FORMAT.md` § 16).
//! - **A sleeping root holds no watcher.** Sleeping is the point of the state machine: no thread, no handles.
//!
//! If the platform refuses to arm a watcher (a watch limit, an unsupported filesystem), the root falls back to
//! passes on `fallback_pass_interval_ms` and says so in `last_error` — a degraded mode that is visible, rather
//! than a root that silently stops seeing changes.
//!
//! ## Locking
//!
//! One mutex per root, and a strict rule: **every write to a subscriber's socket happens under it**, and so does
//! every state transition. Reads happen outside it, in the connection's own task. That is what keeps a batch a
//! transaction (`START_BATCH` … `END_BATCH` with no `STATE` inside it) while several clients are connected, and
//! it is why there is no per-connection queue to reason about. The event handler is the one exception: it touches
//! only atomics, so nightwatch's thread never waits for a pass to finish.
//!
//! A pass holds this root's lock for its whole duration, so a slow scan — or a client that stopped reading,
//! which blocks the write into its socket — delays *this* root and nobody else: each root has its own scheduler
//! task, its own timer and its own lock. The suite pins that with a root deliberately stuck mid-write while
//! another root must still publish.
//!
//! The one thing that is *not* independent is the diagnostic path: `roots list` takes every root's lock in turn
//! (a snapshot has to be consistent), so it waits for a stuck root. That is a deliberate shape — the consumer
//! sockets are the real path and they stay up — and `plans/next-steps.md` records the option of a `busy` flag
//! when blocking a listing becomes annoying.

const std = @import("std");
const nightwatch = @import("nightwatch");
const engine = @import("../engine.zig");
const batch_mod = @import("../batch.zig");
const server = @import("../server.zig");
const wire = @import("../wire.zig");
const format = @import("../format.zig");
const watch = @import("../watch.zig");
const gitdir = @import("../gitdir.zig");
const gitwatch = @import("gitwatch.zig");
const hooks = @import("hooks.zig");
const paths = @import("paths.zig");
const registry = @import("registry.zig");
const reaper = @import("reaper.zig");
const state = @import("state.zig");

/// The watcher every root uses: nightwatch's recommended backend for this platform (ReadDirectoryChangesW on
/// Windows, FSEvents/kqueue on macOS, inotify on Linux), all of which deliver from their own thread.
const Watcher = nightwatch.Default;

/// The degraded cadence: how often a `watching` root runs a pass when no watcher could be armed. Slow enough to
/// be cheap, fast enough that a client is not blind, and always accompanied by `last_error` naming the reason.
pub const fallback_pass_interval_ms: i64 = 200;

/// How long a `watching` root may go with no event and no pass before the daemon looks for itself.
///
/// This is the safety net for a watcher that died without telling us. `nightwatch`'s Windows backend ends its
/// thread when `ReadDirectoryChangesW`'s completion fails, and a buffer overflow **is** a failed completion
/// (`ERROR_NOTIFY_ENUM_DIR`) — so an overflow stops the watch silently: no handler call, no error, no future
/// events. There is no overflow callback to count, so the daemon counts *silence* instead: if nothing has happened
/// for a minute while the root is `watching`, one pass runs; if that pass finds changes, the watcher missed them and
/// is re-armed. A pass on a 20 000-name tree is ~70 ms (`doc/benchmark.md`), so the net costs ~0.1% of a core and
/// only while a root is watching.
pub const safety_pass_interval_ms: i64 = 60_000;

/// Whether a watching root is due for a safety pass: `interval_ms` of silence, measured from the later of the last
/// event and the last pass. Pure, so the rule is a unit test rather than a clock argument.
pub fn safetyPassDue(now_ms: i64, last_event_ms: i64, last_pass_ms: i64, interval_ms: i64) bool {
    const since = @max(last_event_ms, last_pass_ms);
    return now_ms - since >= interval_ms;
}

/// Why a pass ran. The wire only knows `STATE.reason`, which has no "timer" value (and gaining one would be a
/// protocol change), so `event` and `safety` both report `.watcher` there and are told apart by the counters —
/// which is the distinction that matters when a root looks stale.
const PassKind = enum {
    /// The wake after a sleep, or `off`'s on-demand scan: the caller's reason is the machine's.
    wake,
    /// A burst of watcher events became due.
    event,
    /// The safety net: silence for `safety_pass_interval_ms` while watching.
    safety,
    /// An `off` root's on-demand scan, which never arms a watcher.
    scan,

    fn reason(self: PassKind, machine_reason: state.Reason) state.Reason {
        return switch (self) {
            .wake => machine_reason,
            .event, .safety => .watcher,
            .scan => .none,
        };
    }
};

/// How often a root's own scheduler wakes to check its idle deadline and its event burst.
///
/// **Each root has its own scheduler task**, not one loop over every root. A batch belongs to one root, and its
/// latency must not depend on what the other roots are doing: with a shared loop, a slow scan (or a stuck socket
/// write) in one root delayed every other root's tick — and so its batches. A task per root costs one sleeping
/// thread each, which is what `Group` is for, and it makes the plan's `RootHost` seam honest: a root is already
/// independent enough to become a child process later.
pub const tick_interval_ms: u64 = 100;

/// What a client sees about a root, without the lock held. Plain data: the daemon formats it as JSON, and a
/// test asserts the fields rather than parsing the wire.
pub const Snapshot = struct {
    id: []const u8,
    root: []const u8,
    mode: state.Mode,
    phase: state.Phase,
    reason: state.Reason,
    clients: u32,
    idle_timeout_ms: u64,
    retention: registry.Retention,
    on_remove: registry.OnRemove,
    /// The root's discovery policy for worktrees of its repository (`plans/worktrees.md` § 5, M6).
    on_worktree: registry.OnWorktree,
    socket: []const u8,
    served_by: []const u8,
    missing: bool,
    head_batch: u64,
    passes: u64,
    wakes: u64,
    /// What the last byte-budget rotation removed. The count rotation is the engine's and is reported by the
    /// archive itself; this is the per-root policy the daemon adds, and the CLI shows it so the trade-off is
    /// visible rather than silent.
    rotated_by_bytes: u64,
    /// How many passes a watcher burst caused, and how many the safety net did. `passes` is their sum plus the
    /// wake scans; these two are the split that tells an idle watcher from a dead one.
    event_passes: u64,
    safety_passes: u64,
    /// **When** the last pass ran: a wall-clock timestamp in milliseconds, not a duration. `last_pass_duration_ms`
    /// beside it is the cost of that pass; one number cannot answer both questions.
    last_pass_ms: i64,
    /// **How long** the last pass took, measured around `engine.refresh` on the wall clock the daemon already
    /// uses. The pair `last_pass_ms` / `last_pass_duration_ms` is deliberately two names, not one overloaded field.
    last_pass_duration_ms: i64,
    /// The number of names the last pass saw (`engine.Outcome.count`): files plus directories.
    last_pass_files: u64,
    /// The number of entries whose content hash the last pass had to take (`engine.Outcome.hashed`). This is the
    /// number a seed is judged by (`plans/worktrees.md` § 5e): a seeded worktree's first diff is small, a cold scan
    /// hashes the whole tree.
    last_pass_hashed: u64,
    /// The bytes the last pass's batch wrote — its `files.meta` + `files.txt` + `files.json` — or `0` when the
    /// pass published no batch (an empty diff does not advance the sequence, and a first generation has no parent).
    last_pass_batch_bytes: u64,
    last_error: []const u8,
    created_at: []const u8,
    /// What git is doing to this root (`plans/worktrees.md` § 5g): the branch (or `detached:<sha8>`), whether HEAD
    /// is detached, and the operation in progress. All empty/none when `gitwatch` is off, because the metadata is
    /// then never read at all — the switch is the promise, not a hint.
    head: gitwatch.Head = .{},
    in_progress: gitwatch.InProgress = .none,
    /// `GIT_EVENT` frames sent to this root's subscribers, and passes a finish waited for (§ 5d counters).
    git_events: u64 = 0,
    git_passes: u64 = 0,
    /// This root's own `gitwatch`, reported so a caller that is not the daemon can ask whether a hook spool for it
    /// would ever be read (`fsmeta daemon hooks install` refuses when it would not: `plans/worktrees.md` § 5c, M5).
    gitwatch: bool = true,
    /// This root's `worktrees` handling switch (§ 5h), copied from the record. The scan rule is not affected by it.
    worktrees: bool = true,
    /// Whether this root is a **linked worktree** and the common dir it shares with the other worktrees of its
    /// repository (`plans/worktrees.md` § 5g, M7). Both come from the resolved `self.git` location; `common_dir` is
    /// empty (and `worktree` false) with `gitwatch` off or when the root is not inside a repository. They are host
    /// state, never trio content.
    worktree: bool = false,
    common_dir: []const u8 = "",
};

/// Eight atomic stamps, one per git event kind: the struct default for `git_tree_stamp`/`git_repo_stamp`.
fn zeroStamps() [8]std.atomic.Value(u64) {
    var stamps: [8]std.atomic.Value(u64) = undefined;
    for (&stamps) |*slot| slot.* = std.atomic.Value(u64).init(0);
    return stamps;
}

/// Forget every kind in one signal queue. A zero stamp means "not pending" (`takeKinds` exchanges it back to zero).
fn clearStamps(stamps: *[8]std.atomic.Value(u64)) void {
    for (stamps) |*slot| slot.store(0, .release);
}

/// `<common>/worktrees/<id>` from an event path (`.../worktrees/<id>`, or a file below it). Event paths are the only
/// place the watcher's thread can name a worktree without allocating, so the id is recovered from the path the event
/// carried; `arena` owns the result.
fn isWorktreesParent(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    return std.mem.eql(u8, std.fs.path.basename(trimmed), "worktrees");
}

fn worktreeMetadataDir(arena: std.mem.Allocator, event_path: []const u8) ?[]const u8 {
    const needle = "worktrees";
    const at = std.mem.indexOf(u8, event_path, needle) orelse return null;
    if (at != 0 and event_path[at - 1] != '/' and event_path[at - 1] != '\\') return null;
    var index = at + needle.len;
    if (index >= event_path.len or (event_path[index] != '/' and event_path[index] != '\\')) return null;
    while (index < event_path.len and (event_path[index] == '/' or event_path[index] == '\\')) index += 1;
    if (index >= event_path.len) return null;
    while (index < event_path.len and event_path[index] != '/' and event_path[index] != '\\') index += 1;
    return arena.dupe(u8, event_path[0..index]) catch null;
}

/// The working tree a metadata directory names: `<metadata>/gitdir` is the absolute path back to the worktree's
/// `.git` file (§ 1), so the worktree is that path without its last segment. `""` when the file is gone (a removal) or
/// unreadable — the frame's `path_len = 0` means exactly "no longer knowable".
fn worktreePathOf(arena: std.mem.Allocator, io: std.Io, metadata_dir: []const u8) []const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, metadata_dir, .{}) catch return "";
    defer dir.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const text = dir.readFile(io, "gitdir", &buffer) catch return "";
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    var end = trimmed.len;
    if (end >= 4 and std.mem.endsWith(u8, trimmed[0..end], ".git")) end -= 4;
    while (end > 0 and (trimmed[end - 1] == '/' or trimmed[end - 1] == '\\')) end -= 1;
    return arena.dupe(u8, trimmed[0..end]) catch "";
}

/// The kinds pending for one flush, in the order they were first seen.
const PendingKinds = struct {
    kinds: [8]u8 = undefined,
    len: u8 = 0,

    fn items(self: *const PendingKinds) []const u8 {
        return self.kinds[0..self.len];
    }
};

/// Take every pending kind out of `stamps`, ordered by first sighting. Called with the root's lock held; the
/// exchange is the consume, so a kind that arrives after this belongs to the next flush.
fn takeKinds(stamps: *[8]std.atomic.Value(u64)) PendingKinds {
    var ordered: [8]struct { kind: u8, stamp: u64 } = undefined;
    var pending = PendingKinds{};
    for (stamps, 0..) |*slot, index| {
        const stamp = slot.swap(0, .acq_rel);
        if (stamp == 0) continue;
        var at: usize = pending.len;
        while (at > 0 and ordered[at - 1].stamp > stamp) : (at -= 1) ordered[at] = ordered[at - 1];
        ordered[at] = .{ .kind = @intCast(index), .stamp = stamp };
        pending.len += 1;
    }
    for (0..pending.len) |index| pending.kinds[index] = ordered[index].kind;
    return pending;
}

/// One connected, subscribed consumer. Owned by the root, freed when the connection ends.
const Subscriber = struct {
    stream: std.Io.net.Stream,
    from_batch: u64,
    registered: bool = true,
    alive: bool = true,
};

/// The bridge from nightwatch's thread into the scheduler's atomics.
///
/// It **must not** take the root's mutex: a handler that waited for a pass would stall the watcher, and a pass
/// can take seconds. Raising a sequence number and a timestamp is all this does; `tick` reads them under the
/// lock, which is the only place a pass is decided.
const EventHandler = struct {
    handler: Watcher.Handler,
    root: *RootRuntime,

    const vtable = Watcher.Handler.VTable{ .change = change, .rename = rename, .should_watch = shouldWatch };

    fn change(handler: *Watcher.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *EventHandler = @fieldParentPtr("handler", handler);
        _ = event;
        self.root.noteEvent(path);
    }

    fn rename(handler: *Watcher.Handler, source: []const u8, destination: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        const self: *EventHandler = @fieldParentPtr("handler", handler);
        self.root.noteEvent(source);
        self.root.noteEvent(destination);
    }

    /// The arm-time predicate (`plans/worktrees.md` § 5b, G35). A per-directory backend asks it before registering
    /// a directory and before recursing, so a nested repository is never registered — the balloon the field report
    /// measured. It runs on the watcher's thread, so it allocates only from a fixed stack buffer and never takes the
    /// root's mutex.
    fn shouldWatch(handler: *Watcher.Handler, path: []const u8, object_type: nightwatch.ObjectType) bool {
        const self: *EventHandler = @fieldParentPtr("handler", handler);
        var scratch: [8 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        return gitwatch.shouldWatchTree(fba.allocator(), self.root.io, self.root.root_path, path, object_type);
    }
};

/// The daemon's nested-root guard hook (`plans/worktrees.md` § 5, M2).
///
/// A root cannot know which other roots are served — that is the host's list — so the host installs this callback.
/// It runs under the root's lock, before `engine.refresh`, and may append a managed line to this root's
/// `.fs-meta/ignore`; it must not take the host's roots mutex, or the control task's add path (roots mutex, then a
/// parent's root lock) would deadlock against a pass (root lock, then the callback). The host's callback reads an
/// immutable snapshot and writes files only, which is why one field is enough.
pub const Guard = struct {
    ctx: *anyopaque,
    reconcileFn: *const fn (ctx: *anyopaque, root: []const u8) void,
    /// Whether another root of **this daemon** serves `path`, asked by the hook spool reader (`plans/worktrees.md`
    /// § 5c, M5): a hook that fired in an unserved worktree of this repository is an event for every served root of
    /// it, while one that fired in a served sibling belongs to that sibling alone. The same leaf rule as
    /// `reconcileFn`: an immutable snapshot, never the host's roots mutex.
    servedFn: *const fn (ctx: *anyopaque, path: []const u8) bool,

    pub fn reconcile(self: Guard, root: []const u8) void {
        self.reconcileFn(self.ctx, root);
    }

    pub fn isServed(self: Guard, path: []const u8) bool {
        return self.servedFn(self.ctx, path);
    }
};

/// M6's discovery/removal hook. A worktree event is a repository event, but adopting or marking a root missing is
/// host state: the root queues the signal and returns. The callback must not take the host's roots mutex — the pass
/// holds this root's lock — so the host appends to a queue and a daemon task drains it.
pub const WorktreeObserver = struct {
    ctx: *anyopaque,
    onWorktree: *const fn (ctx: *anyopaque, root: []const u8, phase: wire.GitPhase, path: []const u8, metadata_dir: []const u8) void,

    pub fn notify(self: WorktreeObserver, root: []const u8, phase: wire.GitPhase, path: []const u8, metadata_dir: []const u8) void {
        self.onWorktree(self.ctx, root, phase, path, metadata_dir);
    }
};

/// The metadata watcher's thread, into this root.
///
/// Atomics only — no root lock, no allocation, no log: the arm calls this with its own mutex held while a tick may
/// be running a pass. A tree-changing event raises `git_seq`, which `tick` folds into the ordinary burst so a
/// checkout becomes one pass, and stamps the kind so the pass can report it. A repo-wide event raises nothing: it is
/// an event for every root of the repo and a pass for none (§ 5b), so `tick` flushes it on its own. Everything here
/// is a *signal*; the frames are written by `tick`/`runPassLocked`, under the root's lock.
fn gitNotify(ctx: *anyopaque, change: gitwatch.Change, path: []const u8) void {
    const self: *RootRuntime = @ptrCast(@alignCast(ctx));
    const kind = @intFromEnum(change.kind);
    // A monotonically increasing stamp, so the first sighting of each kind keeps its place among the others.
    const stamp = self.git_kind_seq.fetchAdd(1, .acq_rel) + 1;
    switch (change.scope) {
        .tree, .repo_tree => {
            _ = self.git_tree_stamp[kind].cmpxchgStrong(0, stamp, .acq_rel, .acquire);
            _ = self.git_seq.fetchAdd(1, .release);
        },
        .repo => {
            _ = self.git_repo_stamp[kind].cmpxchgStrong(0, stamp, .acq_rel, .acquire);
            // The one thing a metadata event cannot reconstruct after the fact: which worktree. The path is copied
            // now, under a leaf mutex (`tick` takes the same one after the root lock), never allocated here.
            if (change.kind == .worktree) self.rememberWorktreePath(path);
        },
        .ignored => {},
    }
}

pub const RootRuntime = struct {
    io: std.Io,
    /// The daemon's allocator: for long-lived allocations (the record, the socket path, subscribers).
    allocator: std.mem.Allocator,
    /// Everything with the root's lifetime goes here; nothing is freed individually.
    arena: std.mem.Allocator,
    layout: paths.Layout,
    record: registry.Record,
    /// The root path, immutable for the root's lifetime. Separate from `record.root` because it is read without
    /// the lock when a snapshot is unavailable (`identity`) — the record's mutable fields are not.
    root_path: []const u8,
    machine: state.Machine,
    mutex: std.Io.Mutex = .init,
    /// The consumer listener, when the root exists.
    server: ?std.Io.net.Server = null,
    socket_path: []const u8 = "",
    claim: ?reaper.Claim = null,
    subscribers: std.ArrayListUnmanaged(*Subscriber) = .empty,
    group: std.Io.Group = .init,
    /// The root path is gone: reported, not dropped, and recovered when it comes back.
    missing: bool = false,
    /// The last failure, for `root status --json` and the log. Owned by the arena.
    last_error: []const u8 = "",
    /// When the last pass ran, in wall-clock milliseconds. A timestamp: the duration is `last_pass_duration_ms`.
    last_pass_ms: i64 = 0,
    /// The measured cost of the last pass: how long it took, how many names it saw, and how many bytes its batch
    /// wrote. Exposed in the snapshot so the idle default can be tuned against evidence rather than taste.
    last_pass_duration_ms: i64 = 0,
    last_pass_files: u64 = 0,
    last_pass_hashed: u64 = 0,
    last_pass_batch_bytes: u64 = 0,
    /// How many nested repositories the last pass refused to cross. A boundary that appears *after* the arm is the
    /// one case a per-directory backend cannot prune at registration time — the directory existed before its `.git`
    /// did — so an increase re-arms the tree watcher once (`plans/worktrees.md` § 5b, G35).
    boundaries_seen: u64 = 0,
    /// Set before a root is torn down: the accept loop checks it after its next accept and returns.
    stopping: std.atomic.Value(bool) = .init(false),
    /// What the last byte-budget rotation removed, so `root status` can show the trade-off rather than hide it.
    rotated_by_bytes: u64 = 0,
    /// Passes caused by a watcher burst, and passes caused by the safety net (`safety_pass_interval_ms`). They
    /// share `passes` and both report `STATE.reason = watcher`; these count them apart, which is how a watcher
    /// that is alive but idle is told from one that died — a root whose `safety_passes` keeps finding work has a
    /// watcher problem, not a busy tree.
    event_passes: u64 = 0,
    safety_passes: u64 = 0,
    log_file: ?std.Io.File = null,

    /// The daemon-wide metadata watch (`plans/worktrees.md` § 5b): one arm per common dir, refcounted by the roots
    /// that resolve to it. Every root of the daemon shares this registry.
    git_registry: *gitwatch.Registry,
    /// This root's git directories, resolved **per pass** (§ 5b) or `null` when the root is not inside a working
    /// copy, has no readable `.git`, or has `gitwatch` off.
    git: ?gitdir.Location = null,
    /// The arm this root shares with every other root of the same repository, and its registration in it.
    git_arm: ?*gitwatch.Arm = null,
    git_listener: gitwatch.Listener = undefined,
    /// Raised by the metadata watcher's thread for a tree-changing event (its own `$GIT_DIR`, or the shared ignore).
    /// `tick` folds it into the same burst as a working-tree event, so a checkout is one pass, not one per file.
    git_seq: std.atomic.Value(u64) = .init(0),
    /// The git seq `tick` has already handed to the scheduler, and the two facts about the per-root lock latch: when
    /// it was first seen held, and whether the "deferred" / "still held" lines have been logged (once each, so a
    /// stale lock is diagnosable without a line every tick for the rest of the daemon's life).
    seen_git_seq: u64 = 0,
    git_lock_since_ms: i64 = 0,
    git_defer_logged: bool = false,
    git_lock_stale_logged: bool = false,

    /// The metadata timeline's pending event kinds (`plans/worktrees.md` § 5d). Each slot holds the order in which
    /// that kind was first seen since the last flush — zero means "not pending" — so a pass reports its events in
    /// arrival order rather than table order. Tree kinds wait for a pass; repo-wide kinds are emitted as they are
    /// seen, because nothing this root publishes follows them.
    git_tree_stamp: [8]std.atomic.Value(u64) = zeroStamps(),
    git_repo_stamp: [8]std.atomic.Value(u64) = zeroStamps(),
    git_kind_seq: std.atomic.Value(u64) = .init(0),
    /// The last worktree metadata path a repo-wide event named, copied out of the watcher's thread (a fixed buffer
    /// under a leaf mutex, because the watcher's thread may not allocate).
    git_path_mutex: std.Io.Mutex = .init,
    git_path: [std.fs.max_path_bytes]u8 = undefined,
    git_path_len: usize = 0,
    /// A worktree add is a `start` when its metadata appears and a `finish` when the directory has stopped changing
    /// (§ 5c's metadata heuristic); this is the one pending add, with the mtime seen on the previous tick.
    git_worktree_pending: bool = false,
    git_worktree_mtime: i64 = 0,
    /// The tick at which a `worktree` finish was last written. The parent `worktrees/` removal and its last child's
    /// removal can arrive together; this keeps one operation to one finish (`plans/worktrees.md` § 5d).
    last_worktree_finish_ms: i64 = -1,
    /// The `worktrees/` existence poll that catches the last linked worktree's removal on platforms whose watcher
    /// does not deliver the child when its parent goes too. `-1` means "not sampled yet for this git dir".
    worktrees_check_ms: i64 = -1,
    worktrees_dir_seen: bool = true,
    /// Counters (§ 5d): `GIT_EVENT` frames sent, and passes a finish waited for.
    git_events: u64 = 0,
    git_passes: u64 = 0,

    /// The repository's hook spool, as this root reads it (`plans/worktrees.md` § 5c, M5): `<common>/fsmeta-events.log`.
    /// The offset is **per root**, not per repo, because the tick is per root and so is the delivery; the file is a
    /// mailbox of a few hundred lines, and a root that joins later starts at its current end so nothing is replayed.
    hook_spool: []const u8 = "",
    hook_common: []const u8 = "",
    hook_offset: u64 = 0,
    hook_backlog_logged: bool = false,
    /// Hook signals queued for the wire, one stamp per kind (`takeKinds` order). A burst of ref transactions is one
    /// operation per kind, so the queues are coalesced exactly as the metadata timeline's are (§ 5d rule 4):
    ///
    /// * `start` — written at the next flush, before any pass (§ 5d rule 1);
    /// * `repo` — a finish for an **unserved** worktree, which no pass of this root follows;
    /// * `abort` — an aborted transaction, written without waiting for a pass (§ 5d rule 6);
    /// * `finish` — a `committed` finish for **this** root's tree, which waits for the pass that reflects it.
    hook_start_stamp: [8]std.atomic.Value(u64) = zeroStamps(),
    hook_repo_stamp: [8]std.atomic.Value(u64) = zeroStamps(),
    hook_abort_stamp: [8]std.atomic.Value(u64) = zeroStamps(),
    hook_finish_stamp: [8]std.atomic.Value(u64) = zeroStamps(),
    hook_kind_seq: std.atomic.Value(u64) = .init(0),
    /// When the daemon that serves this root started (epoch milliseconds). A spool line stamped in an earlier second
    /// is a leftover from a hook that fired while no daemon was running, and must not replay as a fresh event.
    daemon_started_at_ms: i64 = 0,
    /// `false` only under the test guard `FSMETA_GIT_ARM=off` (`FORMAT.daemon.md` § 8): the metadata watcher is not
    /// armed, so the hook path can be exercised alone. The git dirs are still resolved and the latch still polls.
    git_arm_enabled: bool = true,

    /// The watcher, present exactly while the root is `waking` or `watching`. `null` when asleep, `off`, or
    /// when this platform refused to arm one (the degraded case `last_error` names).
    watcher: ?Watcher = null,
    /// Stable storage for the handler: nightwatch keeps this pointer for the watcher's lifetime.
    event_handler: EventHandler = undefined,
    /// Raised by nightwatch's thread on every event; read by `tick` to notice a burst.
    event_seq: std.atomic.Value(u64) = .init(0),
    /// When the last event arrived, from nightwatch's thread. Diagnostics and the scheduler's clock.
    last_event_ms: std.atomic.Value(i64) = .init(0),
    /// The sequence number `tick` has already handed to the scheduler.
    seen_seq: u64 = 0,
    /// The prototype's self-tuning quiet period (`watch.zig`): a burst becomes one pass, sized by how long this
    /// machine's passes actually take.
    scheduler: watch.Scheduler = .{},
    /// The host's nested-root guard: before every pass, repair the managed block for the served roots inside this
    /// one. `null` when the runtime was created outside a daemon (the unit tests).
    guard: ?Guard = null,
    /// The host's worktree discovery/removal hook (`plans/worktrees.md` § 5, M6). `null` outside a daemon.
    worktree_observer: ?WorktreeObserver = null,

    /// Create the runtime for a record. The root is not touched yet: `start` binds the socket.
    pub fn create(
        parent_allocator: std.mem.Allocator,
        io: std.Io,
        layout: paths.Layout,
        record: registry.Record,
        arena: std.mem.Allocator,
        git_registry: *gitwatch.Registry,
    ) !*RootRuntime {
        const self = try parent_allocator.create(RootRuntime);
        self.* = .{
            .io = io,
            .allocator = parent_allocator,
            .arena = arena,
            .layout = layout,
            .record = record,
            .root_path = try arena.dupe(u8, record.root),
            .machine = state.Machine.init(record.mode, record.idle_timeout_ms),
            .socket_path = try layout.rootSocket(arena, record.id),
            .git_registry = git_registry,
        };
        self.event_handler = .{ .handler = .{ .vtable = &EventHandler.vtable }, .root = self };
        self.git_listener = .{ .ctx = self, .notify = gitNotify, .git_dir = "" };
        return self;
    }

    /// Bind the socket, take the claim, and start accepting. A root whose path has vanished is marked
    /// `missing` instead: the daemon reports it and reaps nothing, because the record is the user's.
    pub fn start(self: *RootRuntime) !void {
        const io = self.io;
        self.lock();
        defer self.unlock();

        std.Io.Dir.accessAbsolute(io, self.record.root, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.missing = true;
                self.setError("the root directory is missing");
                self.log("missing: {s}", .{self.record.root});
                return;
            },
            else => return err,
        };

        try self.bindLocked();
        self.log("started: serving {s} ({s}, {s})", .{ self.record.root, self.record.mode.name(), self.machine.phase.name() });
    }

    /// Claim the root, bind its socket, read the head from the archive and start accepting. The lock is held.
    fn bindLocked(self: *RootRuntime) !void {
        const io = self.io;
        const pid_text = try std.fmt.allocPrint(self.arena, "{d}", .{reaper.currentPid()});
        self.claim = try reaper.claim(io, self.arena, self.layout, self.record.id, pid_text);

        // A socket file left by a killed process is not a peer: remove it before binding, or `bind` refuses.
        std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        self.server = try address.listen(io, .{});
        self.subscribers.clearRetainingCapacity();

        // The newest batch the archive holds is the head: a returning client gets the diff from it, not a
        // cold start, and a client that is ahead of it is refused rather than silently replayed.
        const window = try server.openBatchWindow(io, self.record.root);
        if (window.dir) |dir| dir.close(io);
        self.machine.head_batch = window.last;

        // `always` means watch regardless of clients, so a root configured that way starts watching at once.
        // `auto` and `off` wait: a client or a control request is what gives them a reason.
        if (self.machine.mode == .always) _ = self.machine.wake(nowMs(io)) catch {};
        // The git dirs are resolved before the arm, so `root status` can answer while the root is still asleep and
        // the first wake already knows which common dir it belongs to.
        self.syncGitLocked();
        self.syncWatcherLocked();

        try self.group.concurrent(io, acceptLoop, .{self});
        // The root's own scheduler: its timer, its idle deadline, its event bursts. See `tick_interval_ms`.
        try self.group.concurrent(io, scheduleLoop, .{self});
    }

    pub fn deinit(self: *RootRuntime) void {
        const io = self.io;
        self.stopping.store(true, .release);

        // The subscribers are told and closed first: a `STATE` before the connection ends is what lets a client
        // stop waiting instead of timing out, and closing the stream is what ends each connection task.
        self.lock();
        self.broadcastState();
        for (self.subscribers.items) |subscriber| {
            subscriber.alive = false;
            subscriber.stream.close(io);
        }
        self.subscribers.clearRetainingCapacity();
        self.machine.clients = 0;
        // The watcher goes before the paths it watches are touched, and before `self` is freed: nightwatch
        // joins its thread here. The metadata arm's reference is handed back in the same step.
        self.disarmWatcherLocked();
        self.unlock();

        // Wake the blocked `accept` with a throwaway connection before touching the listener. **Closing the
        // listener underneath a blocked accept is not safe on Windows**: Zig's `netAccept` maps the resulting
        // cancelled status to `unreachable`, so it aborts the process rather than returning an error.
        wakeAcceptor(io, self.socket_path);

        // Then wait for the tasks to finish. `Group.cancel` is deliberately not used: it cancels an in-flight
        // accept, which is the same abort by another route.
        self.group.await(io) catch {};

        if (self.server) |*listener| listener.deinit(io);
        self.server = null;
        std.Io.Dir.deleteFileAbsolute(io, self.socket_path) catch {};
        if (self.log_file) |file| file.close(io);
        self.log_file = null;

        if (self.claim) |*claim| reaper.release(claim, io);
        reaper.removeRootFiles(io, self.arena, self.layout, self.record.id);
        self.subscribers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ---------------------------------------------------------------- control, from the host

    /// A root that could not be locked within the caller's budget. `FORMAT.daemon.md` § 4b: an expired budget is
    /// reported as "not yet available", never answered with a torn read.
    pub const Busy = error{Busy};

    /// `forcePass` cannot run because the root is gone or its runtime is already stopped. The caller refuses the
    /// operation that needed the pass; it is not a silent success.
    pub const Force = error{ Busy, Unavailable };

    /// Take the root's lock within `budget_ms`, or give up. `0` means "do not wait at all".
    ///
    /// `std.Io.Mutex` has an unbounded `lock` and a `tryLock`, so a bounded wait is a poll; the poll interval is
    /// small because the budgets are (50–250 ms) and a housekeeping call is not a hot path.
    fn lockWithin(self: *RootRuntime, budget_ms: i64) bool {
        if (self.mutex.tryLock()) return true;
        if (budget_ms <= 0) return false;
        const deadline = nowMs(self.io) + budget_ms;
        while (nowMs(self.io) < deadline) {
            self.io.sleep(.fromMilliseconds(2), .real) catch return false;
            if (self.mutex.tryLock()) return true;
        }
        return self.mutex.tryLock();
    }

    /// The root's state as plain data, waiting at most `budget_ms` for the lock.
    ///
    /// The caller chooses the budget, because the right one is a property of the *operation*: a listing over many
    /// roots should give up quickly and say so, a `root status` asked by name can afford to wait, and a mutation
    /// must either happen or be refused. See `control.Budget`.
    pub fn snapshot(self: *RootRuntime, budget_ms: i64) Busy!Snapshot {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        const git_status = self.gitStatus();
        return .{
            .id = self.record.id,
            .root = self.root_path,
            .mode = self.machine.mode,
            .phase = self.machine.phase,
            .reason = self.machine.reason,
            .clients = self.machine.clients,
            .idle_timeout_ms = self.machine.idle_timeout_ms,
            .retention = self.record.retention,
            .on_remove = self.record.on_remove,
            .on_worktree = self.record.on_worktree,
            .socket = self.socket_path,
            .served_by = self.record.served_by,
            .missing = self.missing,
            .head_batch = self.machine.head_batch,
            .passes = self.machine.passes,
            .wakes = self.machine.wakes,
            .rotated_by_bytes = self.rotated_by_bytes,
        .event_passes = self.event_passes,
        .safety_passes = self.safety_passes,
            .last_pass_ms = self.last_pass_ms,
            .last_pass_duration_ms = self.last_pass_duration_ms,
            .last_pass_files = self.last_pass_files,
            .last_pass_hashed = self.last_pass_hashed,
            .last_pass_batch_bytes = self.last_pass_batch_bytes,
            .last_error = self.last_error,
            .created_at = self.record.created_at,
            .head = git_status.head,
            .in_progress = git_status.in_progress,
            .git_events = self.git_events,
            .git_passes = self.git_passes,
            .gitwatch = self.record.gitwatch,
            .worktrees = self.record.worktrees,
            .worktree = if (self.git) |location| location.is_gitfile else false,
            .common_dir = if (self.git) |location| location.common_dir else "",
        };
    }

    /// What git is doing to this root, for `root status`. Read on demand from `$GIT_DIR`, which is small (one
    /// `HEAD` read plus up to four existence checks) and always current — a cached copy would answer for the last
    /// pass rather than for now, and the plan says these fields come from the files the watch keeps warm (§ 5g).
    ///
    /// With `gitwatch` off there is no resolved git dir at all, so the answer is empty by construction rather than
    /// by a second check: the switch means the metadata is never read.
    fn gitStatus(self: *RootRuntime) struct { head: gitwatch.Head, in_progress: gitwatch.InProgress } {
        const location = self.git orelse return .{ .head = .{}, .in_progress = .none };
        return .{
            .head = gitwatch.readHead(self.io, location.git_dir),
            .in_progress = gitwatch.readInProgress(self.io, location.git_dir),
        };
    }

    /// The identity of a root whose snapshot is not available: enough to name it, and nothing that could be a
    /// torn read. The path is immutable for the root's lifetime, which is why it is kept beside the record.
    pub fn identity(self: *const RootRuntime) struct { id: []const u8, root: []const u8 } {
        return .{ .id = self.record.id, .root = self.root_path };
    }

    /// Change the mode. A mutation, so it waits up to `budget_ms` and then reports `error.Busy`: a caller told
    /// "done" when nothing happened would have a worse answer than a caller told "not yet".
    pub fn setMode(self: *RootRuntime, mode: state.Mode, now_ms: i64, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        const previous = self.machine.mode;
        self.record.mode = mode;
        switch (self.machine.setMode(mode, now_ms)) {
            .wake => {
                self.log("mode {s} -> {s}: waking", .{ previous.name(), mode.name() });
                self.syncWatcherLocked();
                self.broadcastState();
            },
            .sleep => {
                self.log("mode {s} -> {s}: watching stops", .{ previous.name(), mode.name() });
                self.syncWatcherLocked();
                self.broadcastState();
            },
            .none => {
                if (previous != mode) {
                    self.log("mode {s} -> {s}", .{ previous.name(), mode.name() });
                    self.syncWatcherLocked();
                    self.broadcastState();
                }
            },
        }
    }

    pub fn setIdleTimeout(self: *RootRuntime, idle_timeout_ms: u64, now_ms: i64, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        self.record.idle_timeout_ms = idle_timeout_ms;
        self.machine.setIdleTimeout(idle_timeout_ms, now_ms);
        self.broadcastState();
    }

    pub fn setRetention(self: *RootRuntime, retention: registry.Retention, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        self.record.retention = retention;
    }

    /// Flip this root's `gitwatch` live (`root set <id> gitwatch on|off`, `plans/worktrees.md` § 5h, M7).
    ///
    /// The switch is the promise, not a hint: **off** releases the shared metadata arm, forgets the resolved git
    /// dirs (so `root status` loses `head`/`detached`/`in_progress` immediately), drops the signals already queued
    /// and swallows a burst the watcher had handed to the scheduler. **On** resolves and arms again from this root's
    /// own path, exactly as a pass would. Neither direction changes a trio byte: git metadata is not scan input.
    pub fn setGitwatch(self: *RootRuntime, enabled: bool, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        const previous = self.record.gitwatch;
        self.record.gitwatch = enabled;
        if (enabled) {
            self.syncGitLocked();
        } else {
            self.releaseGitArmLocked();
            self.git = null;
            // A queued metadata burst belongs to a watch this root no longer holds. Keeping it would produce one
            // extra pass (and, worse, a finish for a git event the root opted out of); the pass's content would not
            // change, so dropping it is what "off" means.
            self.seen_git_seq = self.git_seq.load(.acquire);
            self.git_lock_since_ms = 0;
            self.git_defer_logged = false;
            self.git_lock_stale_logged = false;
            self.clearGitSignalsLocked();
        }
        if (previous != enabled) self.log("control: gitwatch {s}", .{if (enabled) "on (metadata watch resolved again)" else "off (metadata watch released, git status cleared)"});
    }

    /// Flip this root's `worktrees` handling live (`root set <id> worktrees on|off`, `plans/worktrees.md` § 5h, M7).
    ///
    /// **Off** stops what this root *does* about worktrees — adoption, seeding, `worktree` events and the removal
    /// reaction — and drops a worktree add that was already pending a finish. It never hides a boundary: the scan
    /// rule runs in the engine and does not consult this flag (`plans/worktrees.md` § 5, § 5h). **On** does not
    /// retroactively adopt a worktree that appeared while it was off; the next discovery signal does.
    pub fn setWorktrees(self: *RootRuntime, enabled: bool, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        const previous = self.record.worktrees;
        self.record.worktrees = enabled;
        if (!enabled) {
            // A pending start/finish is worktree handling; with the switch off there is nothing to finish.
            self.git_worktree_pending = false;
            self.git_worktree_mtime = 0;
            self.git_path_mutex.lockUncancelable(self.io);
            self.git_path_len = 0;
            self.git_path_mutex.unlock(self.io);
        }
        if (previous != enabled) self.log("control: worktrees {s}", .{if (enabled) "on" else "off (boundary rule unchanged)"});
    }

    /// Drop every pending git signal: the metadata timeline's tree and repo kinds and the four hook queues. Called
    /// with the root's lock held, from `setGitwatch` (off) — a queued event is a fact only while the watch exists.
    fn clearGitSignalsLocked(self: *RootRuntime) void {
        clearStamps(&self.git_tree_stamp);
        clearStamps(&self.git_repo_stamp);
        clearStamps(&self.hook_start_stamp);
        clearStamps(&self.hook_repo_stamp);
        clearStamps(&self.hook_abort_stamp);
        clearStamps(&self.hook_finish_stamp);
        self.git_worktree_pending = false;
        self.git_worktree_mtime = 0;
    }

    /// Force a sleep. Batches and the socket stay; only the watching stops — and with it the watcher, which is
    /// the handle this frees.
    pub fn sleepNow(self: *RootRuntime, now_ms: i64, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        if (self.machine.sleep(now_ms) == .sleep) {
            self.log("control: asleep", .{});
            self.syncWatcherLocked();
            self.broadcastState();
        }
    }

    /// Force a wake, refused on a root whose mode is `off` — a refusal, not a silent no-op.
    pub fn wakeNow(self: *RootRuntime, now_ms: i64, budget_ms: i64) (state.WakeRefused || Busy)!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        if (try self.machine.wake(now_ms) == .wake) {
            self.log("control: waking", .{});
            self.syncWatcherLocked();
            self.broadcastState();
        }
    }

    /// The worktree metadata that names this root is gone (`plans/worktrees.md` § 5f). Mark it `missing` immediately
    /// and tell subscribers; the archive is untouched — `root remove` is the only path that may delete history, and
    /// only with `on_remove = delete`. The configured mode is remembered in `record.mode`, so a directory that comes
    /// back is recovered by the ordinary missing/recover path.
    pub fn markMissing(self: *RootRuntime, budget_ms: i64) Busy!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        if (self.missing) return;
        self.missing = true;
        _ = self.machine.setMode(.off, self.last_pass_ms);
        self.setError("the worktree metadata is gone");
        self.disarmWatcherLocked();
        self.syncWatcherLocked();
        self.broadcastState();
        self.log("missing: the git worktree metadata disappeared", .{});
    }

    /// Run exactly one pass under this root's lock, without changing its mode or phase. `root add` uses it so the
    /// parent's managed line is in the parent's trio **before** the child is served, even when the parent is asleep
    /// or `off` (`plans/worktrees.md` § 5, G39): the pass arms no watcher, so a sleeping parent goes back to sleep.
    ///
    /// A root that is `waking` runs the pass directly as well; its scheduler's wake pass sees the published state and
    /// does not need a second batch. The pass itself may find nothing to publish, which is a success.
    pub fn forcePass(self: *RootRuntime, now_ms: i64, budget_ms: i64) Force!void {
        if (!self.lockWithin(budget_ms)) return error.Busy;
        defer self.unlock();
        if (self.stopping.load(.acquire) or self.missing or self.server == null) return error.Unavailable;
        _ = self.runPassLocked(now_ms, .scan);
    }

    // ---------------------------------------------------------------- the scheduler

    /// One scheduler step for **this** root, driven by this root's own task.
    ///
    /// It holds only this root's lock, so a slow pass (or a client that stopped reading) delays this root's
    /// batches and nobody else's. That independence is the point: a batch belongs to one root.
    pub fn tick(self: *RootRuntime, now_ms: i64) void {
        self.lock();
        defer self.unlock();
        if (self.stopping.load(.acquire)) return;
        if (self.missing) {
            self.recoverLocked(now_ms);
            return;
        }
        if (self.server == null) return; // already stopped

        switch (self.machine.tick(now_ms)) {
            .sleep => {
                self.log("idle: asleep after {d} ms without clients", .{self.machine.idle_timeout_ms});
                self.syncWatcherLocked();
                self.broadcastState();
            },
            .wake => {},
            .none => {},
        }
        self.syncWatcherLocked();

        // The hook spool is the precision source (`plans/worktrees.md` § 5c). It is read before the latch and before
        // any pass, so a `prepared` start goes out while the operation is still in flight, and a `committed` finish is
        // queued before the pass it must wait for — whichever tick the lock clears on.
        self.readHookSpoolLocked(now_ms);
        self.flushHookSignalsLocked(now_ms);

        // Repo-wide git events are flushed before any pass decision: they are an event for every root of the repo and
        // a pass for none, so neither the latch nor the burst may hold them.
        self.flushRepoGitEventsLocked(now_ms);

        // A lock in this root's own git dir means its tree is being rewritten right now: no pass may start, and the
        // deferred burst is not lost — the scheduler is left untouched, so the pass runs on the first tick after the
        // lock is gone. The check is a poll, which is the point (§ 5b): a delete event may never arrive.
        if (self.gitBlockedLocked(now_ms)) return;

        if (self.machine.phase == .waking) {
            // The wake scan. Its cause is whatever put the root in `waking`: a subscribe or a control request.
            _ = self.runPassLocked(now_ms, .wake);
            return;
        }
        if (self.machine.phase != .watching) return;

        // Events, not time: a burst of them becomes one pass, and no event means no pass at all.
        if (self.watcher == null) {
            // Degraded: this platform refused a watcher, so the root is kept current on a timer instead, and
            // `last_error` says why. Better a visible fallback than a root that silently stops seeing changes.
            if (now_ms - self.last_pass_ms >= fallback_pass_interval_ms) _ = self.runPassLocked(now_ms, .safety);
            return;
        }
        if (self.pollEventsLocked(now_ms)) return;

        // Silence for the interval: look for ourselves. This is the only way to notice a watcher that died
        // without telling us — see `safety_pass_interval_ms`. A pass that finds changes proves the watcher missed
        // them, so it is re-armed; a pass that finds none leaves it alone, which is what keeps an idle tree quiet.
        if (!safetyPassDue(now_ms, self.last_event_ms.load(.acquire), self.last_pass_ms, safety_pass_interval_ms)) return;
        const published = self.runPassLocked(now_ms, .safety);
        if (published) {
            self.log("watcher silent for {d} ms and changes were missed; re-arming it", .{safety_pass_interval_ms});
            self.disarmWatcherLocked();
            self.syncWatcherLocked();
        }
    }

    /// Hand the watcher's counter to the scheduler, and run a pass when the burst is over (or has gone on too
    /// long). Called with the lock held, from `tick`. Returns whether a pass ran.
    fn pollEventsLocked(self: *RootRuntime, now_ms: i64) bool {
        const git_seq = self.git_seq.load(.acquire);
        if (git_seq != self.seen_git_seq) {
            self.seen_git_seq = git_seq;
            // A metadata event is a burst like any other: one pass when quiet. `noteEvent` is only given the time,
            // because the scheduler sizes the quiet period from measured pass durations, not from the source.
            self.scheduler.noteEvent(@floatFromInt(now_ms));
        }
        const seq = self.event_seq.load(.acquire);
        if (seq != self.seen_seq) {
            self.seen_seq = seq;
            self.scheduler.noteEvent(@floatFromInt(now_ms));
        }
        switch (self.scheduler.poll(@floatFromInt(now_ms))) {
            .none => return false,
            .quiet, .forced => {},
        }
        const started = nowMs(self.io);
        _ = self.runPassLocked(now_ms, .event);
        // Measure the pass, so the next burst is sized by this machine rather than by a constant.
        self.scheduler.notePass(@floatFromInt(nowMs(self.io) - started));
        self.scheduler.flushed();
        return true;
    }

    /// Keep the watcher in step with the phase: armed while `waking` or `watching`, released otherwise.
    ///
    /// A root that is asleep or `off` holds **no watcher at all** — that is what sleeping is for. Called after
    /// every transition, so the invariant lives in one place instead of at each call site.
    fn syncWatcherLocked(self: *RootRuntime) void {
        switch (self.machine.phase) {
            .waking, .watching => self.armWatcherLocked(),
            .asleep, .off => self.disarmWatcherLocked(),
        }
    }

    /// Arm the recursive watch on the root, once. The handler is `self.event_handler`, which lives in this
    /// struct, so the pointer nightwatch keeps stays valid for as long as the watcher does.
    fn armWatcherLocked(self: *RootRuntime) void {
        if (self.watcher != null) return;
        // The metadata arm follows the same rule as the tree watcher: it is on exactly while the root is waking or
        // watching. Resolving here (not only in the pass) is what makes the first wake see the git dirs it needs.
        self.syncGitLocked();
        self.armGitLocked();
        self.watcher = Watcher.init(self.io, self.allocator, &self.event_handler.handler) catch |err| {
            self.setError(@errorName(err));
            self.log("watcher unavailable ({s}); falling back to a {d} ms pass", .{ @errorName(err), fallback_pass_interval_ms });
            return;
        };
        // `watch` is called through the field, so a failure can be cleaned up by the one function that owns
        // releasing a watcher — and the local never has to be both the receiver and the cleanup target.
        self.watcher.?.watch(self.record.root) catch |err| {
            self.disarmWatcherLocked();
            self.setError(@errorName(err));
            self.log("cannot watch {s} ({s}); falling back to a {d} ms pass", .{ self.record.root, @errorName(err), fallback_pass_interval_ms });
            return;
        };
        // Events from before the watch existed are not events of this watch.
        self.seen_seq = self.event_seq.load(.acquire);
        self.log("watching: {d} registration(s)", .{self.watcher.?.watch_count()});
    }

    fn disarmWatcherLocked(self: *RootRuntime) void {
        // The metadata arm is shared and refcounted; this root's reference goes back first, so the arm survives a
        // sibling that is still watching and is freed (with its watcher) when the last root leaves.
        self.releaseGitArmLocked();
        var armed = self.watcher orelse return;
        self.watcher = null;
        // Drains and joins nightwatch's thread. The handler only touches atomics, so it cannot be waiting on
        // this mutex — which is why this is safe to call with the lock held.
        armed.deinit();
        self.scheduler.flushed();
    }

    // ---------------------------------------------------------------- the git metadata watch

    /// Resolve `$GIT_DIR`/`$GIT_COMMON_DIR` for this root (§ 5b, "Resolve the git dirs per pass, not once").
    ///
    /// The strings the root keeps are arena-owned and only re-duplicated when the answer changes, so a pass on an
    /// ordinary repository allocates nothing. A resolution failure — a broken `gitdir:`, a `commondir` naming a
    /// missing directory, a root that is not a repository — is a state, not an error: the root keeps scanning and has
    /// no git handling until the link is repaired (§ 5b).
    fn syncGitLocked(self: *RootRuntime) void {
        if (!self.record.gitwatch) {
            self.releaseGitArmLocked();
            self.git = null;
            return;
        }
        var pass_arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer pass_arena_state.deinit();
        const arena = pass_arena_state.allocator();
        const resolved = gitdir.resolve(arena, self.io, self.root_path) catch null;
        const location = resolved orelse {
            if (self.git != null) self.log("git: {s} is no longer a working copy", .{self.root_path});
            self.releaseGitArmLocked();
            self.git = null;
            return;
        };
        // A `.git` that does not confirm (`HEAD` + `objects/` for a directory, `HEAD` for a gitfile target) is a stray
        // directory or a broken link, not a repository (§ 4, § 5b): no metadata watch, no git events, ordinary
        // scanning. The same confirmation the boundary rule uses decides it, so "not a repository" means one thing.
        if (!gitwatch.confirms(self.io, location)) {
            if (self.git != null) self.log("git: {s} no longer confirms as a working copy", .{self.root_path});
            self.releaseGitArmLocked();
            self.git = null;
            return;
        }
        if (self.git) |current| {
            if (gitwatch.samePath(current.git_dir, location.git_dir) and
                gitwatch.samePath(current.common_dir, location.common_dir) and
                current.is_gitfile == location.is_gitfile)
            {
                self.armGitLocked(); // unchanged: only make sure the arm is held while the root watches
                return;
            }
            if (!gitwatch.samePath(current.common_dir, location.common_dir)) {
                // A different repository: the arm we held belongs to the old common dir, and is not ours any more.
                self.releaseGitArmLocked();
            } else {
                self.log("git: $GIT_DIR moved to {s}", .{location.git_dir});
            }
        }
        self.git = .{
            .git_dir = self.arena.dupe(u8, location.git_dir) catch return,
            .common_dir = self.arena.dupe(u8, location.common_dir) catch return,
            .is_gitfile = location.is_gitfile,
        };
        self.worktrees_check_ms = -1; // a new git dir: sample `worktrees/` before drawing any conclusion
        self.armGitLocked();
    }

    /// Hold this root's reference to the repo's metadata arm — acquiring it, or re-mapping the prefix when only
    /// `$GIT_DIR` moved (§ 5b: "If a root's resolution changes, only its prefix mapping changes").
    fn armGitLocked(self: *RootRuntime) void {
        if (!self.record.gitwatch) return;
        // The test guard (`FSMETA_GIT_ARM=off`, FORMAT.daemon.md § 8) disarms the metadata watcher so the hook path can
        // be exercised on its own. Nothing else changes: the dirs are resolved, the latch polls, the spool is read.
        if (!self.git_arm_enabled) return;
        switch (self.machine.phase) {
            .waking, .watching => {},
            .asleep, .off => return,
        }
        const location = self.git orelse return;
        if (self.git_arm) |arm| {
            _ = self.git_registry.updateListener(arm, &self.git_listener, location.git_dir);
            return;
        }
        self.git_listener.git_dir = location.git_dir;
        self.git_arm = self.git_registry.acquire(location.common_dir, &self.git_listener) catch |err| {
            // Degraded, not broken: the working-tree watcher still works, so this costs git signals only — and the
            // root's log is where that is visible, rather than `last_error`, which would claim the pass is failing.
            self.log("git: cannot watch {s} ({s}); git events are off for this root", .{ location.common_dir, @errorName(err) });
            return;
        };
        self.log("git: metadata watch for {s} ({d} root(s) of this repository)", .{
            location.common_dir,
            self.git_registry.rootCount(self.git_arm.?),
        });
    }

    fn releaseGitArmLocked(self: *RootRuntime) void {
        const arm = self.git_arm orelse return;
        self.git_arm = null;
        const remaining = self.git_registry.release(arm, &self.git_listener);
        if (remaining == 0) {
            self.log("git: metadata watch released (no root of this repository watches it)", .{});
        } else {
            self.log("git: metadata watch kept for {d} other root(s) of this repository", .{remaining});
        }
    }

    /// Whether a pass must wait: the per-root lock latch (§ 5b, § 5d). Only this root's `$GIT_DIR` locks count, so a
    /// commit in one worktree cannot stall a sibling's pass through a shared `refs/**/*.lock`.
    ///
    /// The latch is cleared by this poll — never by a delete event — because in a linked worktree there is no tree
    /// watcher on git's directory to deliver one, which is the prototype's documented bug (`src/main.zig`).
    fn gitBlockedLocked(self: *RootRuntime, now_ms: i64) bool {
        const location = self.git orelse return false;
        if (!gitwatch.hasTreeLock(self.io, location.git_dir)) {
            if (self.git_lock_since_ms != 0) {
                self.log("git: lock cleared after {d} ms; the deferred pass may run", .{now_ms - self.git_lock_since_ms});
                self.git_lock_since_ms = 0;
                self.git_defer_logged = false;
                self.git_lock_stale_logged = false;
            }
            return false;
        }
        if (self.git_lock_since_ms == 0) self.git_lock_since_ms = now_ms;
        if (!self.git_defer_logged) {
            self.git_defer_logged = true;
            self.log("git: {s} is mid-write; passes deferred until its lock is gone", .{location.git_dir});
        }
        // A stale lock (a git that was killed) would otherwise defer this root for ever, silently. One line after
        // the safety interval says so; the daemon still does not override it, because git would not either.
        if (!self.git_lock_stale_logged and now_ms - self.git_lock_since_ms >= safety_pass_interval_ms) {
            self.git_lock_stale_logged = true;
            self.log("git: the lock under {s} has been held for {d} ms; a killed git leaves one behind", .{ location.git_dir, now_ms - self.git_lock_since_ms });
        }
        return true;
    }

    // ---------------------------------------------------------------- the hook spool (M5)

    /// Where a hook line belongs (`plans/worktrees.md` § 5c, M5).
    const HookTarget = enum {
        /// The worktree git was operating on is this root: the event is this root's tree.
        mine,
        /// No served root of this repository owns that worktree, so the event is repo-wide: every served root of the
        /// repository with `gitwatch` on reports it, because the worktree is a fact about the repository.
        unserved,
        /// A sibling served root owns it: that root reports the event, and this one stays silent. Two roots reporting
        /// one checkout would make a consumer treat a sibling's tree as its own.
        sibling,
    };

    fn hookTargetLocked(self: *RootRuntime, worktree: []const u8) HookTarget {
        if (worktree.len > 0 and gitwatch.samePath(self.root_path, worktree)) return .mine;
        // An empty path is a hook that could not name its worktree (a non-repository context). Attributing it to the
        // repository is the only honest reading: it is not provably this root's tree, and it is not provably nobody's.
        if (worktree.len > 0) {
            if (self.guard) |guard| {
                if (guard.isServed(worktree)) return .sibling;
            }
        }
        return .unserved;
    }

    /// Point this root at the repository's spool (`<common>/fsmeta-events.log`) and start at its current end.
    ///
    /// The offset is per root, not per repository: the tick is per root, and so is the delivery, so a shared offset
    /// would need a lock across roots for a mailbox of a few hundred lines. Starting at the end is what keeps a
    /// restart from replaying history as live events; the per-line age check is the second half of that rule (§ 5c).
    fn syncHookSpoolLocked(self: *RootRuntime, common: []const u8) void {
        self.hook_spool = std.fs.path.join(self.arena, &.{ common, hooks.spool_name }) catch "";
        self.hook_common = self.arena.dupe(u8, common) catch "";
        self.hook_backlog_logged = false;
        const existing: ?u64 = blk: {
            const stat = std.Io.Dir.cwd().statFile(self.io, self.hook_spool, .{}) catch break :blk null;
            break :blk stat.size;
        };
        self.hook_offset = existing orelse 0;
        if (existing) |bytes| {
            if (bytes > 0) {
                self.log("hooks: {s} holds {d} bytes from before this root read it; starting at its end", .{ self.hook_spool, bytes });
            } else {
                self.log("hooks: reading {s}", .{self.hook_spool});
            }
        } else {
            self.log("hooks: no spool yet at {s}; install them with `fsmeta daemon hooks install`", .{self.hook_spool});
        }
    }

    /// Read the lines the hooks appended since the last tick (`plans/worktrees.md` § 5c, M5).
    ///
    /// One `stat` per tick and a read only when the file grew: a repository with no hooks, or hooks that did not
    /// fire, costs one filesystem call per tick. A line is attributed to the root of the worktree it fired in; a line
    /// from a worktree no served root of this repository owns is a repo-wide event for every one of them.
    ///
    /// A **start** is written as the line is read — before any pass, which is what § 5d rule 1 allows and rule 2's
    /// ordering needs — an **aborted** finish at once (§ 5d rule 6: nothing was published), and a **committed** finish
    /// is queued for the pass machinery, so it is written only after the batch that reflects it.
    fn readHookSpoolLocked(self: *RootRuntime, now_ms: i64) void {
        if (!self.record.gitwatch) return;
        switch (self.machine.phase) {
            // A sleeping root has no watcher and emits nothing (§ 5d rule 7). The lines stay in the spool (the hook
            // caps it) and are read on the wake, folded into the wake pass.
            .waking, .watching => {},
            else => return,
        }
        const location = self.git orelse return;
        if (self.hook_common.len == 0 or !gitwatch.samePath(self.hook_common, location.common_dir)) {
            self.syncHookSpoolLocked(location.common_dir);
        }
        if (self.hook_spool.len == 0) return;
        const stat = std.Io.Dir.cwd().statFile(self.io, self.hook_spool, .{}) catch return;
        if (stat.size == self.hook_offset) return; // the common case: nothing was appended
        var scratch_state = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_state.deinit();
        const arena = scratch_state.allocator();
        const read = hooks.readNew(self.io, arena, self.hook_spool, self.hook_offset, hooks.spool_max_lines) catch |err| switch (err) {
            error.SpoolBacklog => {
                // A mailbox nobody read for months. Replaying it would be a storm of stale operations; the batches a
                // consumer missed are still in the archive, so the backlog is dropped and the read resumes at the end.
                if (!self.hook_backlog_logged) {
                    self.hook_backlog_logged = true;
                    self.log("hooks: {s} holds more than {d} lines; the backlog is dropped", .{ self.hook_spool, hooks.spool_max_lines });
                }
                self.hook_offset = stat.size;
                return;
            },
            else => return,
        };
        self.hook_offset = read.offset;
        const start_second: i64 = @divTrunc(self.daemon_started_at_ms, 1000);
        for (read.lines) |text| {
            const line = hooks.parseLine(arena, text) orelse continue;
            // A hook that fired while no daemon was running is not a fresh event (§ 5c): its stamp is older than this
            // daemon's start. A line in the start's own second is kept — second resolution cannot tell, and losing a
            // real event is worse than repeating a sub-second old one.
            if (self.daemon_started_at_ms > 0 and line.at < start_second) continue;
            const signal = hooks.signalOf(line) orelse continue;
            const target = self.hookTargetLocked(line.worktree);
            if (target == .sibling) continue;
            const kind: u8 = @intFromEnum(signal.kind);
            // Three lines of one kind are one event (§ 5d rule 4): a checkout fires several ref transactions, and a
            // frame per line would be the storm the coalescing rule exists for.
            const stamp = self.hook_kind_seq.fetchAdd(1, .acq_rel) + 1;
            switch (signal.phase) {
                .start => _ = self.hook_start_stamp[kind].cmpxchgStrong(0, stamp, .acq_rel, .acquire),
                .aborted => _ = self.hook_abort_stamp[kind].cmpxchgStrong(0, stamp, .acq_rel, .acquire),
                .finish => if (target == .mine) {
                    // A finish waits for the pass that reflects it (§ 5d rule 2), and forces that pass even when no
                    // file moved (§ 5b rule 3): the seq makes `pollEventsLocked` see a burst, and the scheduler note
                    // makes the burst end after the quiet period.
                    _ = self.hook_finish_stamp[kind].cmpxchgStrong(0, stamp, .acq_rel, .acquire);
                    _ = self.git_seq.fetchAdd(1, .release);
                    self.scheduler.noteEvent(@floatFromInt(now_ms));
                } else {
                    // No pass of this root follows an unserved worktree's checkout, so its finish is a repo-wide event
                    // (`head_batch` is the head this root already had, per FORMAT.socket.md § GIT_EVENT).
                    _ = self.hook_repo_stamp[kind].cmpxchgStrong(0, stamp, .acq_rel, .acquire);
                },
            }
        }
    }

    /// Write the queued hook signals that need no pass: the starts (before any pass, § 5d rule 1), the repo-wide
    /// finishes of an unserved worktree, and the aborted transactions (§ 5d rule 6). A `committed` finish for this
    /// root's own tree is deliberately absent from this list: it waits for the pass.
    fn flushHookSignalsLocked(self: *RootRuntime, now_ms: i64) void {
        if (!self.record.gitwatch) return;
        const starts = takeKinds(&self.hook_start_stamp);
        const repo = takeKinds(&self.hook_repo_stamp);
        const aborts = takeKinds(&self.hook_abort_stamp);
        if (starts.len == 0 and repo.len == 0 and aborts.len == 0) return;
        var flush_arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer flush_arena_state.deinit();
        const arena = flush_arena_state.allocator();
        // A start and an aborted finish wait for no pass of this root, and a repo-wide finish has no pass either:
        // writing them here must not move `git_passes`, which counts passes a finish waited for (§ 5d).
        self.sendHookFramesLocked(arena, &starts, .start, now_ms);
        self.sendHookFramesLocked(arena, &repo, .finish, now_ms);
        self.sendHookFramesLocked(arena, &aborts, .aborted, now_ms);
    }

    /// Write one hook-sourced frame per kind, outside the pass machinery and outside every counter: these are the
    /// signals § 5d rules 1 and 6 allow to be written at once.
    fn sendHookFramesLocked(self: *RootRuntime, arena: std.mem.Allocator, pending: *const PendingKinds, phase: wire.GitPhase, now_ms: i64) void {
        if (pending.len == 0) return;
        for (pending.items()) |kind| {
            const event = wire.GitEvent{
                .phase = phase,
                .kind = @enumFromInt(kind),
                .source = .hook,
                .status = .ok,
                // No pass of this root produced a generation for the event, so this is the head it already had —
                // the same meaning `FORMAT.socket.md` § GIT_EVENT gives a repo-wide event's `head_batch`.
                .head_batch = self.machine.head_batch,
                .at_ms = @intCast(@max(now_ms, 0)),
            };
            self.broadcastGitEventLocked(arena, event);
        }
    }

    // ---------------------------------------------------------------- git events on the wire

    /// Copy the worktree metadata path a repo-wide event named. Called from the watcher's thread, so it allocates
    /// nothing: a fixed buffer under a leaf mutex that `tick` takes after the root's.
    fn rememberWorktreePath(self: *RootRuntime, path: []const u8) void {
        self.git_path_mutex.lockUncancelable(self.io);
        defer self.git_path_mutex.unlock(self.io);
        const count = @min(path.len, self.git_path.len);
        @memcpy(self.git_path[0..count], path[0..count]);
        self.git_path_len = count;
    }

    /// The remembered path, copied into the caller's arena (which owns it for the flush).
    fn takeWorktreePath(self: *RootRuntime, arena: std.mem.Allocator) ?[]const u8 {
        self.git_path_mutex.lockUncancelable(self.io);
        defer self.git_path_mutex.unlock(self.io);
        if (self.git_path_len == 0) return null;
        return arena.dupe(u8, self.git_path[0..self.git_path_len]) catch null;
    }

    /// One `stat` per half-second: whether `<common>/worktrees` exists. A disappearance is the last linked worktree's
    /// removal on backends that deliver the parent's deletion instead of the child's (ReadDirectoryChangesW deletes
    /// both at once); the id is gone with it, so the answer is one `finish` with `path_len = 0` (§ 5d). The event path
    /// handles the ordinary case and sets `last_worktree_finish_ms`, so the two routes never double-report one removal.
    fn pollWorktreesDirLocked(self: *RootRuntime, now_ms: i64) void {
        const location = self.git orelse return;
        if (now_ms - self.worktrees_check_ms < 500) return;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}{c}worktrees", .{ location.common_dir, std.fs.path.sep }) catch return;
        const present = if (std.Io.Dir.accessAbsolute(self.io, path, .{})) |_| true else |_| false;
        if (self.worktrees_check_ms == -1) {
            // First sample for this git dir: a repository that simply has no linked worktree is not a removal.
            self.worktrees_check_ms = now_ms;
            self.worktrees_dir_seen = present;
            return;
        }
        const vanished = self.worktrees_dir_seen and !present;
        self.worktrees_check_ms = now_ms;
        self.worktrees_dir_seen = present;
        if (!vanished) return;
        // The event path may already have reported the child in the same burst; one operation, one finish.
        if (now_ms - self.last_worktree_finish_ms <= 1000) return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        self.sendWorktreeEventLocked(arena_state.allocator(), .finish, "", now_ms);
    }

    /// Flush the repo-wide kinds: an event for every root of the repo, and a pass for none.
    ///
    /// These are emitted as they are seen rather than around a pass, because no pass follows them for this root: § 5d
    /// rule 3's guarantee is "never before the pass", not "always a batch". A ref update is reported as a single
    /// `finish` — by the time metadata sees it, it has happened, and a fabricated `start` would be a lie; a worktree
    /// is the exception, because its `start` (the metadata appearing) and its `finish` (the checkout that fills it)
    /// are genuinely apart.
    fn flushRepoGitEventsLocked(self: *RootRuntime, now_ms: i64) void {
        if (!self.record.gitwatch) return;
        // The last linked worktree takes the parent directory with it; poll for that shape before the event path.
        self.pollWorktreesDirLocked(now_ms);
        const pending = takeKinds(&self.git_repo_stamp);
        // A pending worktree add needs *ticks*, not another event: its finish is the heuristic "the directory stopped
        // changing", so it is polled here even when nothing new arrived (that is what makes it a finish at all).
        if (pending.len == 0 and !self.git_worktree_pending) return;
        var flush_arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer flush_arena_state.deinit();
        const arena = flush_arena_state.allocator();
        var worktree_flushed = false;
        for (pending.items()) |kind| {
            if (kind == @intFromEnum(gitwatch.Kind.worktree)) {
                self.flushWorktreeLocked(arena, now_ms);
                worktree_flushed = true;
                continue;
            }
            const event = wire.GitEvent{
                .phase = .finish,
                .kind = @enumFromInt(kind),
                .source = .metadata,
                .status = .ok,
                // A repo-wide event produced no generation for this root, so its `head_batch` is the head it already
                // had — documented in FORMAT.socket.md, because a consumer must not read it as "a batch to fetch".
                .head_batch = self.machine.head_batch,
                .at_ms = @intCast(@max(now_ms, 0)),
            };
            self.broadcastGitEventLocked(arena, event);
        }
        // One worktree flush per tick: a start and a finish in the same tick would report a checkout that has not
        // happened yet as finished.
        if (!worktree_flushed and self.git_worktree_pending) self.flushWorktreeLocked(arena, now_ms);
    }

    /// A worktree appearing or leaving (§ 5c, § 5d), for this root. The `start` is the metadata directory appearing
    /// with the worktree's path (read from its `gitdir`); the `finish` is the metadata heuristic — the directory has
    /// stopped changing between two ticks — and a removal is a single `finish` whose path is no longer knowable, so
    /// `path_len` is 0.
    fn flushWorktreeLocked(self: *RootRuntime, arena: std.mem.Allocator, now_ms: i64) void {
        if (!self.record.worktrees) {
            self.git_worktree_pending = false;
            return;
        }
        if (self.git == null) return;
        const event_path = self.takeWorktreePath(arena) orelse return;
        // The parent `worktrees/` directory itself: on the platforms whose watcher delivers the child's removal,
        // the child path arrives and is handled below. When the *last* worktree goes, both it and the empty parent
        // disappear, and only the parent's deletion is delivered — no id can name the worktree, so the contract's
        // answer is one finish with `path_len = 0` (§ 5d). A creation of the parent says nothing.
        if (isWorktreesParent(event_path)) {
            std.Io.Dir.accessAbsolute(self.io, event_path, .{}) catch {
                // A child removal in the same tick already emitted its finish; do not send a second one.
                if (self.last_worktree_finish_ms == now_ms) return;
                self.sendWorktreeEventLocked(arena, .finish, "", now_ms);
            };
            return;
        }
        const metadata_dir = worktreeMetadataDir(arena, event_path) orelse return;
        const stat = std.Io.Dir.openDirAbsolute(self.io, metadata_dir, .{}) catch {
            // The directory is gone: a worktree left this repository, and the path that named it went with it, so
            // `path_len = 0`. A pending add is closed by the same finish rather than left open (§ 5d, rule 6's
            // "a start with no finish").
            self.git_worktree_pending = false;
            self.sendWorktreeEventLocked(arena, .finish, "", now_ms);
            self.observeWorktree(.finish, "", metadata_dir);
            return;
        };
        defer stat.close(self.io);
        const changed = stat.stat(self.io) catch {
            self.sendWorktreeEventLocked(arena, .finish, "", now_ms);
            self.observeWorktree(.finish, "", metadata_dir);
            return;
        };
        const mtime: i64 = @intCast(@divTrunc(changed.mtime.nanoseconds, 1_000_000));
        if (!self.git_worktree_pending) {
            self.git_worktree_pending = true;
            self.git_worktree_mtime = mtime;
            const path = worktreePathOf(arena, self.io, metadata_dir);
            self.sendWorktreeEventLocked(arena, .start, path, now_ms);
            self.observeWorktree(.start, path, metadata_dir);
            return;
        }
        if (mtime == self.git_worktree_mtime) {
            self.git_worktree_pending = false;
            const path = worktreePathOf(arena, self.io, metadata_dir);
            self.sendWorktreeEventLocked(arena, .finish, path, now_ms);
            self.observeWorktree(.finish, path, metadata_dir);
            return;
        }
        self.git_worktree_mtime = mtime;
    }

    fn observeWorktree(self: *RootRuntime, phase: wire.GitPhase, path: []const u8, metadata_dir: []const u8) void {
        if (!self.record.worktrees) return;
        if (self.worktree_observer) |observer| observer.notify(self.root_path, phase, path, metadata_dir);
    }

    fn sendWorktreeEventLocked(self: *RootRuntime, arena: std.mem.Allocator, phase: wire.GitPhase, path: []const u8, now_ms: i64) void {
        if (!self.record.worktrees) return;
        if (phase == .finish) self.last_worktree_finish_ms = now_ms;
        const event = wire.GitEvent{
            .phase = phase,
            .kind = .worktree,
            .source = .metadata,
            .status = .ok,
            // § 5d: a worktree event is about the repository, not about this root's tree, so `head_batch` is this
            // root's current head, not a generation the event produced.
            .head_batch = self.machine.head_batch,
            .at_ms = @intCast(@max(now_ms, 0)),
            .path = path,
        };
        self.broadcastGitEventLocked(arena, event);
    }

    /// Write one `GIT_EVENT` to every subscriber. Never inside a batch: the caller runs outside
    /// `broadcastBatchLocked`, and the root's lock is what keeps that true.
    fn broadcastGitEventLocked(self: *RootRuntime, arena: std.mem.Allocator, event: wire.GitEvent) void {
        if (self.subscribers.items.len == 0) return;
        const payload_size = event.payloadSize();
        const frame = arena.alloc(u8, wire.prefix_size + payload_size) catch return;
        wire.writePrefix(frame[0..wire.prefix_size], .git_event, 0, payload_size);
        event.write(frame[wire.prefix_size..]);
        for (self.subscribers.items) |subscriber| {
            if (!subscriber.alive) continue;
            writeAll(self.io, subscriber.stream, frame) catch {
                subscriber.alive = false;
            };
        }
        self.dropDeadLocked();
        self.git_events += 1;
    }

    /// Write a `start` or `finish` for every pending tree kind, in arrival order. Called with the root's lock held.
    ///
    /// `source` is part of the frame (`FORMAT.socket.md` § GIT_EVENT): the metadata timeline and a hook report the same
    /// event type, and a consumer tells them apart by that byte rather than by timing.
    fn sendGitEventsLocked(
        self: *RootRuntime,
        arena: std.mem.Allocator,
        pending: *const PendingKinds,
        phase: wire.GitPhase,
        source: wire.GitSource,
        status: wire.GitStatus,
        head_batch: u64,
        now_ms: i64,
    ) void {
        if (pending.len == 0) return;
        for (pending.items()) |kind| {
            const event = wire.GitEvent{
                .phase = phase,
                .kind = @enumFromInt(kind),
                .source = source,
                .status = status,
                .head_batch = head_batch,
                .at_ms = @intCast(@max(now_ms, 0)),
            };
            self.broadcastGitEventLocked(arena, event);
        }
        if (phase == .finish) self.git_passes += 1;
    }

    /// What the watcher's thread calls. Atomics only: no lock, no allocation, no log.
    fn noteEvent(self: *RootRuntime, path: []const u8) void {
        if (self.machine.phase == .off) return;
        // A `.git` entry appearing is the one git path the filter must not hide (`plans/worktrees.md` § 4, G33):
        // it is how a directory becomes a nested repository, and waiting for the 60 s safety pass would let a new
        // worktree stay unscanned for a minute. Events *inside* `.git` are still ignored.
        if (!isGitEntry(path) and isIgnoredPath(path)) return;
        _ = self.event_seq.fetchAdd(1, .release);
        self.last_event_ms.store(nowMs(self.io), .monotonic);
    }

    /// A root whose path came back is usable again: the record was never dropped, so recovery is a `stat` and,
    /// for a root that could not bind at start, one bind. Nothing is searched and nothing is re-added.
    fn recoverLocked(self: *RootRuntime, now_ms: i64) void {
        std.Io.Dir.accessAbsolute(self.io, self.record.root, .{}) catch return;
        self.missing = false;
        self.setError("");
        if (self.server == null) {
            // The root was already gone when the daemon started, so it has no socket and no claim yet.
            self.bindLocked() catch |err| {
                self.missing = true;
                self.setError(@errorName(err));
                return;
            };
        }
        // The pass that found the root missing moved the root to `off`; the configured mode is restored.
        _ = self.machine.setMode(self.record.mode, now_ms);
        self.syncWatcherLocked();
        self.log("recovered: {s} ({s})", .{ self.record.root, self.record.mode.name() });
        self.broadcastState();
    }

    /// One pass, with the lock already held: run the engine, publish the difference, tell the subscribers.
    ///
    /// The engine owns discovery, diffing, the commit and the batch; this function owns only the consequences —
    /// the state transition, the stream, the rotation and the log. Its failure is explicit: a root that
    /// vanished becomes `missing` and its clients are told, rather than being left to time out.
    ///
    /// `kind` decides both what `STATE.reason` says (a client's subscribe, a watcher event and a safety pass are
    /// different answers) and which counter moves, so a root that looks stale can be told apart from one whose
    /// watcher is alive. Returns whether a batch was published.
    fn runPassLocked(self: *RootRuntime, now_ms: i64, kind: PassKind) bool {
        const io = self.io;
        self.last_pass_ms = now_ms;
        // Resolve per pass, before the scan, so the metadata mapping describes the tree this pass is about to read
        // (§ 5b). `.git` is invisible to the working-tree watcher, so this is the only place a root that became a
        // worktree, or whose `gitdir:` moved, is ever noticed.
        self.syncGitLocked();
        // The nested-root guard runs before the engine reads `.fs-meta/ignore`, so a block that was deleted or
        // edited by hand is repaired by *this* pass rather than a later one (`plans/worktrees.md` § 5, G37).
        if (self.guard) |guard| guard.reconcile(self.root_path);
        switch (kind) {
            .event => self.event_passes += 1,
            .safety => self.safety_passes += 1,
            .wake, .scan => {},
        }
        const cause = kind.reason(self.machine.reason);

        // Armed **before** the scan: a change that lands during it must be seen, not fall in the gap between
        // the scan and the watch. `off` never reaches here with a watcher — `syncWatcherLocked` releases it.
        const was_waking = self.machine.phase == .waking;
        if (was_waking) self.armWatcherLocked();

        var pass_arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer pass_arena_state.deinit();
        const arena = pass_arena_state.allocator();

        var stamp_buffer: [32]u8 = undefined;
        const options: engine.Options = .{
            .updated = rfc3339Utc(now_ms, &stamp_buffer),
            .keep_batches = @intCast(@min(self.record.retention.max_batches, std.math.maxInt(usize))),
        };

        // The cost the pass is about to incur, from the same clock the scheduler uses. `last_pass_ms` above is
        // *when* the pass ran; this is how long it took, and the two are never the same field.
        const pass_started = nowMs(io);

        // What the metadata timeline saw, in first-sighting order. `start` goes out **before** the pass: § 5d rule 1
        // puts no ordering constraint on it, and a consumer that reacts to start must expect a half-written tree.
        const tree_kinds = if (self.record.gitwatch) takeKinds(&self.git_tree_stamp) else PendingKinds{};
        if (tree_kinds.len > 0) self.sendGitEventsLocked(arena, &tree_kinds, .start, .metadata, .ok, self.machine.head_batch, now_ms);
        // A hook's `committed` finish takes the same route the metadata one does: it is queued until a pass runs, and
        // written after that pass's batch (§ 5d rule 2). Taken here so a line read during this pass belongs to the
        // next one, not to a finish this pass cannot have reflected.
        const hook_finishes = if (self.record.gitwatch) takeKinds(&self.hook_finish_stamp) else PendingKinds{};

        const outcome = engine.refresh(arena, io, self.record.root, options) catch |err| {
            // A failed pass still cost time. Its file count and batch are unknown, so they are zeroed rather than
            // left describing the previous pass as if it were this one.
            self.last_pass_duration_ms = nowMs(io) - pass_started;
            self.last_pass_files = 0;
            self.last_pass_hashed = 0;
            self.last_pass_batch_bytes = 0;
            // The finish is still written, with `status = failed`: silence would leave a consumer believing a state
            // it never received (§ 5d rule 5). A hook finish that waited for this pass says the same thing, from its
            // own, more precise source.
            self.sendGitEventsLocked(arena, &tree_kinds, .finish, .metadata, .failed, self.machine.head_batch, now_ms);
            self.sendGitEventsLocked(arena, &hook_finishes, .finish, .hook, .failed, self.machine.head_batch, now_ms);
            self.failLocked(err);
            return false;
        };

        // The pass's cost, recorded while the numbers are fresh: the wall clock around the engine, the name count
        // it reported, and the batch it actually wrote. The batch is measured before the broadcast, because the
        // bytes are the archive's, not the wire's.
        self.last_pass_duration_ms = nowMs(io) - pass_started;
        self.last_pass_files = outcome.count;
        self.last_pass_hashed = outcome.hashed;
        self.last_pass_batch_bytes = if (outcome.published) batchBytes(io, self.record.root, outcome.generation) else 0;

        // With `gitwatch` off there is no metadata event, so the pass that saw a new worktree is the only discovery
        // route (§ 5, G43). The boundary rule already keeps it out of this tree; adoption is the opt-in second step.
        if (self.record.worktrees and !self.record.gitwatch) {
            for (outcome.boundary_paths) |boundary| {
                if (boundary.kind != .worktree) continue;
                const full = std.fs.path.join(arena, &.{ self.record.root, boundary.path }) catch continue;
                self.observeWorktree(.finish, full, "");
            }
        }

        if (outcome.published) {
            self.machine.attribute(cause);
            self.machine.published(outcome.generation, now_ms);
            self.setError("");
            self.log("pass: generation {d}, {d} names ({s})", .{ outcome.generation, outcome.count, cause.name() });
            const plan = self.loadBatchLocked(arena, outcome.generation) catch |err| {
                self.setError(@errorName(err));
                self.log("pass: batch {d} cannot be read back ({s})", .{ outcome.generation, @errorName(err) });
                self.sendGitEventsLocked(arena, &tree_kinds, .finish, .metadata, .failed, self.machine.head_batch, now_ms);
                self.sendGitEventsLocked(arena, &hook_finishes, .finish, .hook, .failed, self.machine.head_batch, now_ms);
                self.broadcastState();
                return false;
            };
            self.broadcastBatchLocked(arena, outcome.generation, plan);
            self.rotateLocked(arena);
        } else if (was_waking) {
            // A wake that found nothing to publish still ends: the scan is what the client waited for, and the
            // state says so even though no batch follows.
            self.machine.woke(now_ms);
            self.log("wake: nothing changed at generation {d}", .{outcome.generation});
        }
        self.syncWatcherLocked();

        // A boundary that appeared after the arm is the one shape a per-directory backend cannot prune at
        // registration time: the directory existed before its `.git` did. One disarm/arm applies the predicate to
        // the new tree; a boundary that merely disappeared needs nothing (`plans/worktrees.md` § 5b, G35).
        if (outcome.boundary_paths.len > self.boundaries_seen) {
            self.boundaries_seen = outcome.boundary_paths.len;
            if (self.watcher != null and self.machine.phase == .watching) {
                self.disarmWatcherLocked();
                self.armWatcherLocked();
                self.log("a nested repository appeared; re-armed the tree watcher so it is not registered", .{});
            }
        } else {
            self.boundaries_seen = outcome.boundary_paths.len;
        }

        // `STATE` is for transitions, not for a heartbeat: a pass that changed nothing has nothing to announce,
        // and a client that received one every event would be listening to a telemetry channel.
        if (outcome.published or was_waking) self.broadcastState();

        // The finish comes **last**, after the batch and its STATE have gone to every subscriber (§ 5d rule 2): a
        // client that reacts to "finished" with a query must find the work done. A pass that published nothing still
        // precedes its finish (rule 3), and `head_batch` is then the head it already had. The hook's finishes follow the
        // metadata ones: when both sources saw the same operation, the precise one has the last word.
        self.sendGitEventsLocked(arena, &tree_kinds, .finish, .metadata, .ok, self.machine.head_batch, now_ms);
        self.sendGitEventsLocked(arena, &hook_finishes, .finish, .hook, .ok, self.machine.head_batch, now_ms);
        return outcome.published;
    }

    /// The pass failed. A vanished root moves to `off` and the clients are told why; every other failure is
    /// recorded and retried on the next tick, because a transient read error is not a reason to stop serving.
    fn failLocked(self: *RootRuntime, err: anyerror) void {
        const io = self.io;
        self.setError(@errorName(err));
        self.log("pass failed: {s}", .{@errorName(err)});
        switch (err) {
            error.RootMissing, error.FileNotFound, error.NotDir => {
                self.missing = true;
                _ = self.machine.setMode(.off, self.last_pass_ms);
                self.setError("the root directory is missing");
                self.syncWatcherLocked();
                self.broadcastState();
                for (self.subscribers.items) |subscriber| {
                    server.refuse(io, subscriber.stream, .protocol, "root {s} is missing: {s}", .{ self.record.root, @errorName(err) });
                    subscriber.alive = false;
                }
                self.dropDeadLocked();
            },
            else => self.broadcastState(),
        }
    }

    /// Retention's second ceiling: after every publish, remove the oldest generations until the archive fits
    /// both limits. Oldest-first and one at a time, the order the format already requires.
    fn rotateLocked(self: *RootRuntime, arena: std.mem.Allocator) void {
        const meta_dir = openMetaDir(self.io, self.record.root, arena) catch return;
        defer meta_dir.close(self.io);
        const by_bytes = batch_mod.rotateToBytes(arena, self.io, meta_dir, self.record.retention.max_bytes) catch |err| {
            self.log("rotation failed: {s}", .{@errorName(err)});
            return;
        };
        self.rotated_by_bytes = by_bytes.dropped;
        if (by_bytes.dropped > 0) self.log("rotation: dropped {d} generation(s) over {d} bytes", .{ by_bytes.dropped, self.record.retention.max_bytes });
    }

    fn loadBatchLocked(self: *RootRuntime, arena: std.mem.Allocator, generation: u64) !batch_mod.Plan {
        const window = try server.openBatchWindow(self.io, self.record.root);
        defer if (window.dir) |dir| dir.close(self.io);
        const dir = window.dir orelse return error.BatchGap;
        return server.loadBatch(arena, self.io, dir, generation);
    }

    // ---------------------------------------------------------------- the stream

    /// Send `STATE` to every subscriber: always between batches, never inside one.
    fn broadcastState(self: *RootRuntime) void {
        const io = self.io;
        var bytes: [wire.prefix_size + wire.state_size]u8 = undefined;
        const frame = self.machine.frame();
        frame.write(&bytes);
        for (self.subscribers.items) |subscriber| {
            if (!subscriber.alive) continue;
            writeAll(io, subscriber.stream, &bytes) catch {
                subscriber.alive = false;
            };
        }
        self.dropDeadLocked();
    }

    /// Send one batch as `START_BATCH` … `END_BATCH`. A batch is a transaction: no `STATE` may appear inside.
    fn broadcastBatchLocked(self: *RootRuntime, arena: std.mem.Allocator, generation: u64, plan: batch_mod.Plan) void {
        for (self.subscribers.items) |subscriber| {
            if (!subscriber.alive) continue;
            self.sendBatch(arena, subscriber, generation, plan) catch {
                subscriber.alive = false;
            };
        }
        self.dropDeadLocked();
    }

    fn sendBatch(self: *RootRuntime, arena: std.mem.Allocator, subscriber: *Subscriber, generation: u64, plan: batch_mod.Plan) !void {
        const io = self.io;
        try server.sendStartBatch(io, subscriber.stream, generation, generation - 1);
        for (plan.entries, plan.names) |entry, name| {
            try server.sendChangeEntry(io, arena, subscriber.stream, entry, name);
        }
        try server.sendEndBatch(io, subscriber.stream, generation, server.counts(plan));
        subscriber.from_batch = generation;
    }

    /// Replay the archive from `from_batch` up to the head, to one subscriber.
    fn replayLocked(self: *RootRuntime, arena: std.mem.Allocator, subscriber: *Subscriber, from_batch: u64) !void {
        const io = self.io;
        const window = try server.openBatchWindow(io, self.record.root);
        defer if (window.dir) |dir| dir.close(io);
        const dir = window.dir orelse return;
        var generation = from_batch + 1;
        while (generation <= window.last) : (generation += 1) {
            const plan = server.loadBatch(arena, io, dir, generation) catch |err| switch (err) {
                error.BatchGap => {
                    server.refuse(io, subscriber.stream, .batch_gap, "no batch {d}; the archive ends at {d}", .{ generation, window.last });
                    return error.BatchGap;
                },
                else => return err,
            };
            try self.sendBatch(arena, subscriber, generation, plan);
        }
    }

    /// Forget subscribers whose socket failed. **The connection's own task owns the memory and closes the
    /// stream**; this only takes the subscriber out of the list and stops counting it, so a failed write can
    /// never free a pointer the connection task is still using.
    fn dropDeadLocked(self: *RootRuntime) void {
        var index: usize = 0;
        while (index < self.subscribers.items.len) {
            const subscriber = self.subscribers.items[index];
            if (subscriber.alive) {
                index += 1;
                continue;
            }
            _ = self.subscribers.orderedRemove(index);
            if (subscriber.registered) {
                subscriber.registered = false;
                self.machine.unsubscribe(nowMs(self.io));
            }
        }
    }

    // ---------------------------------------------------------------- connections

    /// The root's scheduler task: sleep, check, repeat. It ends when `stopping` is set, which is what lets
    /// `deinit` wait for it without cancelling a blocked `accept` (see `deinit`).
    fn scheduleLoop(self: *RootRuntime) void {
        const io = self.io;
        while (true) {
            io.sleep(.fromMilliseconds(tick_interval_ms), .real) catch return; // only `Canceled`
            if (self.stopping.load(.acquire)) return;
            self.tick(nowMs(io));
        }
    }

    /// Accept forever. The listener belongs to the root; a connection gets its own task so that one slow
    /// client cannot stop the next one from being greeted.
    fn acceptLoop(self: *RootRuntime) void {
        const io = self.io;
        const listener = if (self.server) |*value| value else return;
        while (true) {
            const stream = listener.accept(io) catch return;
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                return;
            }
            self.group.concurrent(io, connectionTask, .{ self, stream }) catch {
                server.refuse(io, stream, .protocol, "the daemon cannot start a connection task", .{});
                stream.close(io);
            };
        }
    }

    fn connectionTask(self: *RootRuntime, stream: std.Io.net.Stream) void {
        const io = self.io;
        const subscriber = self.allocator.create(Subscriber) catch {
            stream.close(io);
            return;
        };
        subscriber.* = .{ .stream = stream, .from_batch = 0 };
        defer {
            self.unregister(subscriber);
            stream.close(io); // the connection's task owns the stream
            self.allocator.destroy(subscriber);
        }
        self.serveConnection(stream, subscriber) catch {};
    }

    /// Greet, subscribe, replay, and stay: the consumer-facing half of the daemon.
    fn serveConnection(self: *RootRuntime, stream: std.Io.net.Stream, subscriber: *Subscriber) !void {
        const io = self.io;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var read_buffer: [8192]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);

        self.lock();
        var locked = true;
        defer if (locked) self.unlock();

        // Simultaneous greeting: both sides send HELLO without waiting for the other (FORMAT.socket.md).
        const ours = wire.Hello{
            .protocol = wire.protocol,
            .entry_size = @intCast(format.entry_size),
            .hash_algorithm = 0,
            .role = .server,
            .capabilities = 0,
            .generation = self.machine.head_batch,
            .max_frame_bytes = wire.max_frame,
        };
        var hello_bytes: [wire.prefix_size + wire.hello_size]u8 = undefined;
        ours.write(&hello_bytes);
        try writeAll(io, stream, &hello_bytes);

        const hello_prefix = (try readPrefix(io, stream, &reader.interface)) orelse return;
        if (hello_prefix.kind != .hello or hello_prefix.length != wire.hello_size) {
            server.refuse(io, stream, .protocol, "expected a 24-byte HELLO greeting", .{});
            return;
        }
        const theirs = wire.Hello.read(try reader.interface.take(hello_prefix.length)) catch {
            server.refuse(io, stream, .protocol, "malformed HELLO payload", .{});
            return;
        };
        const verdict = wire.checkHello(ours, theirs);
        if (verdict != .ok) {
            server.refuse(io, stream, .protocol, "{s}", .{server.helloVerdictWord(verdict)});
            return;
        }

        const subscribe_prefix = (try readPrefix(io, stream, &reader.interface)) orelse return;
        if (subscribe_prefix.kind != .subscribe or subscribe_prefix.length != 8) {
            server.refuse(io, stream, .protocol, "expected SUBSCRIBE with a u64 from_batch", .{});
            return;
        }
        const from_batch = std.mem.readInt(u64, (try reader.interface.take(subscribe_prefix.length))[0..8], .little);

        const window = try server.openBatchWindow(io, self.record.root);
        defer if (window.dir) |dir| dir.close(io);
        if (from_batch > window.last) {
            server.refuse(io, stream, .protocol, "from_batch {d} is newer than the newest batch {d}", .{ from_batch, window.last });
            return;
        }
        if (window.first) |first| {
            if (from_batch + 1 < first) {
                server.refuse(io, stream, .batch_too_old, "batches start at {d}, so from_batch {d} cannot be replayed", .{ first, from_batch });
                return;
            }
        }

        // `off` means never *watch*, not never *serve*: one scan here, so the replay describes the tree as it
        // is now, and then nothing else runs until a mode change or a subscriber on a watching mode.
        if (self.machine.mode == .off) _ = self.runPassLocked(nowMs(io), .scan);

        subscriber.from_batch = from_batch;
        try self.subscribers.append(self.allocator, subscriber);
        subscriber.registered = true;

        // A client is a reason to watch: this is the transition the `STATE` frame exists to announce.
        _ = self.machine.subscribe(nowMs(io));
        // Armed here as well as in the wake pass, so a change that lands in the few milliseconds between this
        // subscribe and the scan is an event rather than a gap.
        self.syncWatcherLocked();
        self.broadcastState(); // "immediately after HELLO, so a fresh client knows what it joined"
        try self.replayLocked(arena, subscriber, from_batch);
        if (self.machine.phase == .waking) {
            // The wake scan runs on the scheduler, not here: the client has already been told it is coming.
            self.log("subscribed: waking", .{});
        }

        locked = false;
        self.unlock();

        self.readLoop(stream, &reader, subscriber);
    }

    /// Read command frames from a subscriber until it leaves. `PING` is answered; anything else ends the
    /// connection, because a second `SUBSCRIBE` on a live connection is a client bug rather than a command.
    fn readLoop(self: *RootRuntime, stream: std.Io.net.Stream, reader: *std.Io.net.Stream.Reader, subscriber: *Subscriber) void {
        const io = self.io;
        while (true) {
            const prefix = reader.interface.takeArray(wire.prefix_size) catch break;
            const frame = wire.readPrefix(prefix) catch break;
            const payload = reader.interface.take(frame.length) catch break;
            switch (frame.kind) {
                .ping => {
                    if (payload.len != 0) break;
                    self.lock();
                    if (!subscriber.alive) {
                        self.unlock();
                        break;
                    }
                    server.writeFrame(io, stream, .pong, &.{}) catch {
                        subscriber.alive = false;
                        self.dropDeadLocked();
                        self.unlock();
                        break;
                    };
                    self.unlock();
                },
                .pong => {},
                else => break,
            }
        }
    }

    fn unregister(self: *RootRuntime, subscriber: *Subscriber) void {
        self.lock();
        defer self.unlock();
        if (!subscriber.registered) return; // already taken out of the list by a failed write
        subscriber.registered = false;
        subscriber.alive = false;
        for (self.subscribers.items, 0..) |candidate, index| {
            if (candidate == subscriber) {
                _ = self.subscribers.orderedRemove(index);
                break;
            }
        }
        self.machine.unsubscribe(nowMs(self.io));
        if (self.machine.mode == .off) return;
        self.broadcastState();
        self.log("unsubscribed: {d} client(s) left", .{self.machine.clients});
    }

    // ---------------------------------------------------------------- small helpers

    fn lock(self: *RootRuntime) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *RootRuntime) void {
        self.mutex.unlock(self.io);
    }

    fn setError(self: *RootRuntime, message: []const u8) void {
        self.last_error = self.arena.dupe(u8, message) catch self.last_error;
    }

    /// Append one line to `<base>/logs/<id>.log`. Best effort: a log that cannot be written must never be the
    /// reason a root stops being served.
    fn log(self: *RootRuntime, comptime format_text: []const u8, args: anytype) void {
        const file = self.log_file orelse return;
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("[{d}] ", .{nowMs(self.io)}) catch return;
        writer.print(format_text, args) catch return;
        writer.writeAll("\n") catch return;
        file.writeStreamingAll(self.io, writer.buffered()) catch {};
    }
};

/// The bytes one published generation's batch wrote: its `files.meta`, `files.txt` and `files.json`.
///
/// `0` when the pass wrote no batch (an empty diff does not advance the sequence) and on any stat failure: a
/// measurement must never turn a successful pass into a failed one, so a batch that cannot be measured is
/// reported as unmeasured rather than guessed.
fn batchBytes(io: std.Io, root: []const u8, generation: u64) u64 {
    var meta_dir = openMetaDir(io, root, std.heap.page_allocator) catch return 0;
    defer meta_dir.close(io);
    var batches = meta_dir.openDir(io, "batches", .{}) catch return 0;
    defer batches.close(io);
    var name_buffer: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "{x:0>8}", .{generation}) catch return 0;
    var dir = batches.openDir(io, name, .{}) catch return 0;
    defer dir.close(io);
    var total: u64 = 0;
    for ([_][]const u8{ format.meta_file, format.txt_file, format.json_file }) |file_name| {
        const stat = dir.statFile(io, file_name, .{}) catch continue;
        total += stat.size;
    }
    return total;
}

/// Open `<root>/.fs-meta` for rotation. A root with no trio yet is not an error here: there is nothing to
/// rotate, and the next pass creates it.
fn openMetaDir(io: std.Io, root: []const u8, allocator: std.mem.Allocator) !std.Io.Dir {
    _ = allocator;
    var root_dir = if (std.fs.path.isAbsolute(root))
        try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    return root_dir.openDir(io, format.directory_name, .{ .iterate = true });
}

/// Whether an event's path is one the daemon must not react to.
///
/// `.fs-meta` is our own output: feeding a pass's writes back into the watcher would make the daemon publish
/// itself forever. `.git` is not part of what a trio describes (`FORMAT.md` § 16), so a ref update is not a
/// reason to scan. The check is per path *segment*, because nightwatch delivers absolute paths and a directory
/// named `a.git` is a directory like any other.
fn isIgnoredPath(path: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, path, "/\\");
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, format.directory_name)) return true;
        if (std.mem.eql(u8, segment, ".git")) return true;
    }
    return false;
}

/// Whether the event's last path segment is `.git` itself. Such an event is a directory (or gitfile) appearing,
/// which can make the directory a boundary; an event one level deeper is git's own state and stays ignored.
fn isGitEntry(path: []const u8) bool {
    var segments = std.mem.tokenizeAny(u8, std.mem.trimEnd(u8, path, "/\\"), "/\\");
    var last: []const u8 = "";
    while (segments.next()) |segment| last = segment;
    return std.mem.eql(u8, last, ".git");
}

/// Wake a task blocked in `accept` by connecting to the root's own socket once.
///
/// This exists because closing a listening socket under a blocked `accept` is not a portable way to stop an
/// accept loop: on Windows Zig's `netAccept` treats the resulting cancelled status as `unreachable`, and the
/// process aborts. A throwaway connection completes the accept normally, the loop sees `stopping` and returns,
/// and only then is the listener closed. A connect that fails is harmless: the loop is then already gone.
fn wakeAcceptor(io: std.Io, socket_path: []const u8) void {
    const address = std.Io.net.UnixAddress.init(socket_path) catch return;
    const stream = address.connect(io) catch return;
    stream.close(io);
}

/// Write bytes to a stream and flush. Each call owns its writer buffer, the same shape `server.zig` uses, so a
/// frame is flushed before the next task can touch the socket.
pub fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(stream, io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// Read a frame prefix, or `null` when the peer closed cleanly before starting one.
fn readPrefix(io: std.Io, stream: std.Io.net.Stream, reader: *std.Io.Reader) !?wire.Frame {
    const prefix = reader.takeArray(wire.prefix_size) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    return wire.readPrefix(prefix) catch |err| {
        server.refuse(io, stream, .protocol, "{s}", .{@errorName(err)});
        return null;
    };
}

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, 1_000_000));
}

/// The pass timestamp as RFC3339 UTC, from the scheduler's clock rather than a fresh read, so the batch and
/// the log agree about when the pass ran.
pub fn rfc3339Utc(now_ms: i64, buffer: *[32]u8) []const u8 {
    const seconds: u64 = if (now_ms < 0) 0 else @intCast(@divTrunc(now_ms, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "the safety net waits for silence, measured from the later of the last event and the last pass" {
    // Nothing has ever happened: the net is due only after a full interval.
    try testing.expect(!safetyPassDue(1_000, 0, 0, 60_000));
    try testing.expect(safetyPassDue(60_000, 0, 0, 60_000));

    // An event resets the clock: a root receiving events never gets a safety pass, however long it has been up.
    try testing.expect(!safetyPassDue(120_000, 119_000, 5_000, 60_000));
    // A pass resets it too, so the net cannot double up on a root that is already being scanned.
    try testing.expect(!safetyPassDue(120_000, 1_000, 119_000, 60_000));
    // Exactly at the interval counts as due: the rule is `>=`, so a root is never left indefinitely.
    try testing.expect(safetyPassDue(180_000, 120_000, 120_000, 60_000));
    // A zero interval would make it due every tick; nothing configures that, and the test says what the formula
    // would do rather than hiding it.
    try testing.expect(safetyPassDue(10, 0, 0, 0));
}

test "a pass kind maps to the wire's reason table without inventing a value" {
    // `FORMAT.socket.md` defines reasons 0..4. A safety pass is not an event, but it is the watcher's own failure
    // path, so it reports `watcher` and is told apart by the counter instead of by a new number a consumer would
    // have to learn.
    try testing.expectEqual(state.Reason.watcher, PassKind.event.reason(.none));
    try testing.expectEqual(state.Reason.watcher, PassKind.safety.reason(.client));
    try testing.expectEqual(state.Reason.client, PassKind.wake.reason(.client));
    try testing.expectEqual(state.Reason.none, PassKind.scan.reason(.control));
}

