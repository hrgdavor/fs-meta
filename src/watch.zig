// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Watch mode: when to flush a batch of file-system events.
//!
//! The engine pass is `engine.refresh` — a warm start (§ 11). The only scheduling question is *when* to run it: a
//! pass costs something, and events arrive in bursts, so running one per event wastes work on a slow machine and
//! running too rarely makes a fast machine feel laggy.
//!
//! ## Self-tuning
//!
//! There is no configured delay. Each pass is **measured**, and the quiet period that ends a burst is derived from
//! the recent pass durations:
//!
//! ```text
//! quiet = clamp(factor × pass_ewma, min_delay, max_delay)
//! ```
//!
//! A machine that passes in 20 ms settles at a ~30 ms delay and feels immediate; a machine that passes in 900 ms
//! settles at a ~1.35 s delay and never queues passes it cannot finish. The estimate is an exponentially weighted
//! moving average, so it follows a machine that is busy for a while without pinning the delay there forever.
//!
//! Two bounds keep it reliable rather than merely adaptive:
//!
//! - **`idle_quiet_ms`** is a floor under the derived delay, so a burst is never split by a pause shorter than that;
//! - **`max_wait_ms`** forces a flush even if events never stop arriving, so a continuously busy tree is still
//!   updated at a bounded interval instead of being starved.
//!
//! This file is deliberately free of I/O and of a clock: it takes `now_ms` from the caller, which makes every rule
//! in it a unit test, and leaves the watch loop to be a thin adapter over the engine.

const std = @import("std");

pub const Tuning = struct {
    /// The delay is this multiple of the recent pass duration: enough to let a burst finish, small enough that the
    /// tree is not visibly stale after one.
    factor: f64 = 1.5,
    /// Lower bound: nothing is flushed sooner than this after the last event, however fast the machine is.
    min_delay_ms: f64 = 25,
    /// Upper bound on the derived quiet period, so a pathologically slow pass cannot make the watcher unresponsive.
    max_delay_ms: f64 = 2000,
    /// A flush is forced this long after the first unflushed event, whether or not the tree is still busy.
    max_wait_ms: f64 = 5000,
    /// Floor under the quiet period itself (the derived value is clamped up to it).
    idle_quiet_ms: f64 = 10,
};

pub const Scheduler = struct {
    tuning: Tuning = .{},
    /// Exponentially weighted moving average of a pass duration, in milliseconds. Starts optimistic: the first
    /// pass measures, and no delay is assumed before there is one.
    pass_ewma_ms: f64 = 0,
    pass_samples: u32 = 0,
    /// The exponential weight; 0.3 converges in a handful of passes, which is the scale of "this machine changed".
    weight: f64 = 0.3,

    /// The first unflushed event, and the most recent one.
    burst_started_at: f64 = 0,
    last_event_at: f64 = 0,
    pending: bool = false,

    /// Record an event at `now_ms`.
    pub fn noteEvent(self: *Scheduler, now_ms: f64) void {
        if (!self.pending) {
            self.pending = true;
            self.burst_started_at = now_ms;
        }
        self.last_event_at = now_ms;
    }

    /// Record a completed pass: its duration feeds the delay for the next burst.
    pub fn notePass(self: *Scheduler, duration_ms: f64) void {
        self.pass_samples += 1;
        if (self.pass_samples == 1) {
            self.pass_ewma_ms = duration_ms;
        } else {
            self.pass_ewma_ms = self.pass_ewma_ms * (1 - self.weight) + duration_ms * self.weight;
        }
    }

    /// The quiet period that ends a burst: derived from the machine's measured speed, clamped.
    pub fn quietPeriodMs(self: *const Scheduler) f64 {
        // Before any pass has been measured, use the floor: a first flush should not wait on a guess.
        const estimate = self.tuning.factor * self.pass_ewma_ms;
        const bounded = std.math.clamp(estimate, self.tuning.min_delay_ms, self.tuning.max_delay_ms);
        return @max(bounded, self.tuning.idle_quiet_ms);
    }

    /// The instant this batch will be flushed if no further event arrives.
    pub fn quietDeadlineMs(self: *const Scheduler) f64 {
        return self.last_event_at + self.quietPeriodMs();
    }

    /// The instant a flush is forced regardless of further events.
    pub fn maxWaitDeadlineMs(self: *const Scheduler) f64 {
        return self.burst_started_at + self.tuning.max_wait_ms;
    }

    /// Whether a flush is due at `now_ms`, and if so why.
    pub const Flush = enum { none, quiet, forced };

    pub fn poll(self: *const Scheduler, now_ms: f64) Flush {
        if (!self.pending) return .none;
        if (now_ms >= self.maxWaitDeadlineMs()) return .forced;
        if (now_ms >= self.quietDeadlineMs()) return .quiet;
        return .none;
    }

    /// Mark the batch as flushed; the next event starts a new burst.
    pub fn flushed(self: *Scheduler) void {
        self.pending = false;
        self.burst_started_at = 0;
        self.last_event_at = 0;
    }
};

// --------------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "a burst is flushed after a quiet period sized by the measured pass" {
    var scheduler: Scheduler = .{};
    scheduler.notePass(20); // a fast machine: 20 ms per pass
    try testing.expectEqual(@as(f64, 30), scheduler.quietPeriodMs()); // 1.5 × 20

    scheduler.noteEvent(1000);
    try testing.expectEqual(Scheduler.Flush.none, scheduler.poll(1010)); // inside the quiet period
    try testing.expectEqual(Scheduler.Flush.quiet, scheduler.poll(1030));
    scheduler.flushed();
    try testing.expectEqual(Scheduler.Flush.none, scheduler.poll(2000));
}

test "a slow machine gets a longer quiet period, bounded" {
    var scheduler: Scheduler = .{};
    scheduler.notePass(900);
    try testing.expectEqual(@as(f64, 1350), scheduler.quietPeriodMs()); // 1.5 × 900

    scheduler.noteEvent(0);
    try testing.expectEqual(Scheduler.Flush.none, scheduler.poll(1000));
    try testing.expectEqual(Scheduler.Flush.quiet, scheduler.poll(1350));

    // A pathologically slow pass is capped, so the watcher stays responsive.
    var slow: Scheduler = .{};
    slow.notePass(60_000);
    try testing.expectEqual(@as(f64, 2000), slow.quietPeriodMs());
}

test "a continuous burst is flushed by the forced deadline, not starved" {
    var busy: Scheduler = .{};
    busy.notePass(20); // a 30 ms quiet period, so the quiet deadline keeps moving under a steady stream
    busy.noteEvent(0);
    var now: f64 = 0;
    while (now < 6000) : (now += 10) {
        busy.noteEvent(now);
        if (busy.poll(now) == .forced) break;
    }
    // Forced exactly max_wait after the burst began, although no 30 ms gap ever opened.
    try testing.expectEqual(@as(f64, 5000), now);
    busy.flushed();
    try testing.expectEqual(Scheduler.Flush.none, busy.poll(6000));
}

test "the delay follows the machine: it grows when passes slow down and shrinks again" {
    var scheduler: Scheduler = .{};
    scheduler.notePass(20);
    const fast = scheduler.quietPeriodMs();

    for (0..5) |_| scheduler.notePass(400);
    const slow = scheduler.quietPeriodMs();
    try testing.expect(slow > fast);

    for (0..10) |_| scheduler.notePass(20);
    const recovered = scheduler.quietPeriodMs();
    try testing.expect(recovered < slow);
    try testing.expect(recovered >= scheduler.tuning.min_delay_ms);
}

test "an unmeasured machine flushes on the minimum delay rather than guessing" {
    var scheduler: Scheduler = .{};
    try testing.expectEqual(scheduler.tuning.min_delay_ms, scheduler.quietPeriodMs());
    scheduler.noteEvent(0);
    try testing.expectEqual(Scheduler.Flush.none, scheduler.poll(10));
    try testing.expectEqual(Scheduler.Flush.quiet, scheduler.poll(25));
}
