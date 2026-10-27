// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! Test aggregator for `src/daemon/`.
//!
//! A Zig module's root file fixes the directory that its `@import`s may reach, so a root at `src/daemon/x.zig`
//! could not import the engine's `../format.zig`. This file is the module root at `src/`, and it pulls in every
//! daemon module: `zig build test` then compiles the daemon exactly as `zig build` does, and runs every test
//! the daemon's files declare.
//!
//! It deliberately contains nothing but imports. Anything with behaviour belongs in one of the modules below.

test {
    _ = @import("daemon/paths.zig");
    _ = @import("daemon/registry.zig");
    _ = @import("daemon/state.zig");
    _ = @import("daemon/gitwatch.zig");
    _ = @import("daemon/hooks.zig");
    _ = @import("daemon/reaper.zig");
    _ = @import("daemon/control.zig");
    _ = @import("daemon/root.zig");
    _ = @import("daemon/host.zig");
    _ = @import("daemon/cli.zig");
}
