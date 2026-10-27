const std = @import("std");
const builtin = @import("builtin");

// The reference implementation is developed and verified against exactly this compiler. Refusing other versions
// is deliberate: 0.17 moved the whole I/O surface (`std.Io`), so a different minor version does not build this
// code — and an error that says so, with the path, is worth more than the first thousand mismatched symbols.
const required_zig = "0.17";
const toolchain_hint = "D:\\wrk\\zig\\17\\zig.exe";
comptime {
    const actual = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        builtin.zig_version.major,
        builtin.zig_version.minor,
        builtin.zig_version.patch,
    });
    if (builtin.zig_version.minor != 17 or builtin.zig_version.major != 0) {
        @compileError("fs-meta requires Zig " ++ required_zig ++ " (" ++ toolchain_hint ++ "), got " ++ actual);
    }
}


/// The reference implementation of `fs-meta`, plus the daemon and the watcher prototype it leads.
///
/// `zig build` builds the engine (which contains `fsmeta daemon`), `zig build test` runs every module, and the
/// watcher prototype is a separate step because it is a prototype, not because of its dependency: the daemon
/// watches through `nightwatch` too, so that dependency is part of the engine.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The matcher and the chain come from the pinned `gitignore` dependency (v0.3.5 in build.zig.zon), not from a
    // sibling checkout. They are mounted under their file names, so every `@import("gitignore.zig")` in this tree
    // keeps working: the move is build-level.
    const gitignore_dep = b.dependency("gitignore", .{ .target = target, .optimize = optimize });
    const gitignore_module = b.createModule(.{
        .root_source_file = gitignore_dep.path("src/gitignore.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ignore_module = b.createModule(.{
        .root_source_file = gitignore_dep.path("src/ignore.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gitignore.zig", .module = gitignore_module }},
    });

    // The file-system watcher. `fsmeta daemon` arms one per watching root (`FORMAT.daemon.md` § 2b), so the
    // engine binary imports it: the plan's watcher is event-driven, and a poll behind the same seam would be a
    // different design with different costs.
    const nightwatch_dep = b.dependency("nightwatch", .{ .target = target, .optimize = optimize });
    const nightwatch_module = nightwatch_dep.module("nightwatch");

    const engine_imports = [_]std.Build.Module.Import{
        .{ .name = "gitignore.zig", .module = gitignore_module },
        .{ .name = "ignore.zig", .module = ignore_module },
        .{ .name = "nightwatch", .module = nightwatch_module },
    };

    // The engine, and the daemon with it.
    const fsmeta = b.addExecutable(.{
        .name = "fsmeta",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fsmeta.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &engine_imports,
        }),
    });
    b.installArtifact(fsmeta);

    const run_step = b.step("run", "Run the engine: zig build run -- verify <root>");
    run_step.dependOn(&b.addRunArtifact(fsmeta).step);

    // Every module, so one command proves the whole reference.
    const test_step = b.step("test", "Run every module's tests");
    const modules = [_][]const u8{
        "format", "json_doc", "validate", "cache", "coldstart", "scan", "lister", "boundary", "gitdir", "ignores", "nesting", "seed", "publish", "engine", "watch", "watch_tuning", "watch_run", "reconcile", "batch", "wire", "pair", "query", "server",
        // The daemon's modules are rooted at `src/daemon_tests.zig`, because a Zig module root fixes how far an
        // `@import` may reach: a root inside `src/daemon/` could not import the engine's `../format.zig`.
        "daemon_tests",
    };
    for (modules) |name| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &engine_imports,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The watcher prototype: the same dependency, a separate artifact because it is a prototype. It imports the
    // engine's modules too (`engine.refresh` is what a pass is), so it gets the same import set.
    const watcher = b.addExecutable(.{
        .name = "watcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &engine_imports,
        }),
    });
    const watcher_step = b.step("watcher", "Build the nightwatch watcher prototype");
    watcher_step.dependOn(&b.addInstallArtifact(watcher, .{}).step);
}
