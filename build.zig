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


/// The reference implementation of `fs-meta`, plus the watcher prototype it leads.
///
/// `zig build` builds the engine, `zig build test` runs every module, and the watcher — the one artifact with a
/// third-party dependency — is a separate step so a stale prototype can never stop the engine from building.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The matcher and the chain come from the sibling `gitignore` project. They are mounted under their file
    // names, so every `@import("gitignore.zig")` in this tree keeps working: the move is build-level.
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
    const basis_imports = [_]std.Build.Module.Import{
        .{ .name = "gitignore.zig", .module = gitignore_module },
        .{ .name = "ignore.zig", .module = ignore_module },
    };

    // The engine: no third-party dependency.
    const fsmeta = b.addExecutable(.{
        .name = "fsmeta",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fsmeta.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &basis_imports,
        }),
    });
    b.installArtifact(fsmeta);

    const run_step = b.step("run", "Run the engine: zig build run -- verify <root>");
    run_step.dependOn(&b.addRunArtifact(fsmeta).step);

    // Every module, so one command proves the whole reference.
    const test_step = b.step("test", "Run every module's tests");
    const modules = [_][]const u8{
        "format", "json_doc", "validate", "cache", "coldstart", "scan", "lister", "publish", "engine", "watch", "watch_tuning", "watch_run", "reconcile", "batch", "wire", "pair", "query", "server",
    };
    for (modules) |name| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &basis_imports,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The watcher prototype, built against nightwatch. Separate on purpose: it is the one artifact whose
    // dependency comes from upstream, and the engine must not depend on that fetch succeeding.
    const dep = b.dependency("nightwatch", .{ .target = target, .optimize = optimize });
    const watcher = b.addExecutable(.{
        .name = "watcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nightwatch", .module = dep.module("nightwatch") },
            },
        }),
    });
    const watcher_step = b.step("watcher", "Build the nightwatch watcher prototype");
    watcher_step.dependOn(&b.addInstallArtifact(watcher, .{}).step);
}
