//! build.zig — offline-first build over the fetched engine artifacts.
//!
//! `fetch.sh` / `fetch.ps1` (run first) download the pinned corvid
//! release, sha256-verify it, and normalize `corvid.h` + the platform
//! cdylib into `deps/current/`. This build consumes `deps/current` ONLY —
//! no engine checkout, no vendored binaries in git, no network at build
//! time.
//!
//!   zig build test        — unit tests (src) + the golden-suite port
//!                           (test/golden.zig over the vendored fixtures)
//!   zig build examples    — build the six-program examples tour
//!   zig build run-<name>  — run one example (quickstart, hybrid, ...)
//!
//! The library is the `corvid` module (src/corvid.zig): an @cImport of
//! deps/current/corvid.h plus the idiomatic wrapper. Linking is set per
//! target: `-lcorvid` with an rpath into deps/current on macOS/Linux; the
//! MSVC import library (or its mingw-named twin) on Windows.

const std = @import("std");

const example_names = [_][]const u8{
    "quickstart", "hybrid", "vector_index", "text_search", "graph", "geo",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    // ASan leg (CI, Linux): instrument the harness/examples. The fetched
    // cdylib is not rebuilt (it is a release artifact) — this catches
    // harness-side memory errors and leaks exactly like corvid-c's
    // sanitizer job over the same shape.
    const sanitize = b.option(bool, "sanitize", "build with AddressSanitizer (ASan)") orelse false;

    // ---- deps/current must exist (fetch.sh / fetch.ps1) ----------------
    const deps_dir = b.path("deps/current");
    if (verifyFetchedArtifacts(b)) {
        // ok — fall through
    } else |e| {
        std.debug.print(
            \\build: missing engine artifacts in deps/current ({s}).
            \\  Run ./fetch.sh (macOS/Linux) or ./fetch.ps1 (Windows) first —
            \\  it downloads the pinned release, sha256-verifies it against
            \\  the release's checksums.txt, and normalizes corvid.h + the
            \\  cdylib into deps/current. It also discards stale pins and
            \\  keeps exactly one.
            \\
        , .{@errorName(e)});
        @panic("engine artifacts not fetched — run ./fetch.sh (or fetch.ps1)");
    }
    // Windows has no rpath: run steps need deps/current on PATH so the
    // loader finds corvid.dll (see also linkCorvid's note — README
    // documents the manual-build case).
    const needs_dll_path = target.result.os.tag == .windows;

    // ---- the corvid module ---------------------------------------------
    const corvid_mod = b.createModule(.{
        .root_source_file = b.path("src/corvid.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkCorvid(corvid_mod, deps_dir, target.result);
    if (sanitize) corvid_mod.sanitize_c = .full;

    // ---- unit tests (src) -----------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = corvid_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (needs_dll_path) run_unit_tests.addPathDir(b.pathFromRoot("deps/current"));

    // ---- the golden-suite port (test/golden.zig) -------------------------
    // Harness contract, exactly like upstream: argv is
    //   golden <workdir> <fixture.txt> [fixture.txt ...]
    // It prints "SMOKE <file> lines=<n> executed=<n>" per fixture and
    // exits non-zero on the first failed expectation.
    const golden_mod = b.createModule(.{
        .root_source_file = b.path("test/golden.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkCorvid(golden_mod, deps_dir, target.result);
    if (sanitize) golden_mod.sanitize_c = .full;
    const golden_exe = b.addExecutable(.{
        .name = "golden",
        .root_module = golden_mod,
    });
    const golden_install = b.addInstallArtifact(golden_exe, .{});
    const golden_run = b.addRunArtifact(golden_exe);
    if (needs_dll_path) golden_run.addPathDir(b.pathFromRoot("deps/current"));
    const workdir = b.pathFromRoot(".zig-cache/golden-workdir");
    golden_run.addArg(workdir);
    for ([_][]const u8{
        "admin", "geo", "graph", "mutations", "persist", "queries",
        "schema", "values",
    }) |stem| {
        golden_run.addArg(b.pathFromRoot(b.fmt("golden/{s}.txt", .{stem})));
    }

    const test_step = b.step("test", "unit tests + the golden-suite port");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&golden_run.step);
    test_step.dependOn(&golden_install.step);

    // ---- the examples tour ------------------------------------------------
    const examples_step = b.step("examples", "build the six-example tour");
    for (example_names) |name| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "corvid", .module = corvid_mod },
            },
        });
        if (sanitize) mod.sanitize_c = .full;
        const exe = b.addExecutable(.{ .name = b.fmt("example_{s}", .{name}), .root_module = mod });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        if (needs_dll_path) run.addPathDir(b.pathFromRoot("deps/current"));
        // File-backed examples (vector_index) work in a scratch dir so
        // parallel runs never collide on the db file.
        const scratch = b.fmt(".zig-cache/example-{s}", .{name});
        std.Io.Dir.cwd().createDirPath(b.graph.io, b.pathFromRoot(scratch)) catch {};
        run.setCwd(b.path(scratch));
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("run the {s} example", .{name}));
        run_step.dependOn(&run.step);
    }
}

/// Wire one module against deps/current: include path, libc, the cdylib,
/// and (macOS/Linux) an rpath so the build-tree binaries load the fetched
/// dylib without DYLD_ help — the same discipline corvid-c bakes in.
fn linkCorvid(mod: *std.Build.Module, deps_dir: std.Build.LazyPath, target: std.Target) void {
    mod.link_libc = true;
    mod.addIncludePath(deps_dir);
    mod.addLibraryPath(deps_dir);
    switch (target.os.tag) {
        .macos, .linux => {
            mod.linkSystemLibrary("corvid", .{});
            mod.addRPath(deps_dir);
        },
        .windows => {
            // lld-link takes the MSVC import lib; the mingw flavor takes
            // its dll.a twin (fetch.ps1 stages both). The DLL itself is
            // found via PATH at load time (CI and run steps add
            // deps/current; README documents it).
            if (target.abi == .msvc) {
                mod.addObjectFile(mod.owner.path("deps/current/corvid.dll.lib"));
            } else {
                mod.addObjectFile(mod.owner.path("deps/current/libcorvid.dll.a"));
            }
        },
        else => {},
    }
}

/// Fail fast, with the fetch hint, when deps/current is absent/incomplete.
/// (0.16's Dir.access grew an `Io` parameter; 0.15's did not.)
fn verifyFetchedArtifacts(b: *std.Build) !void {
    if (comptime @import("builtin").zig_version.minor >= 16) {
        try b.build_root.handle.access(b.graph.io, "deps/current/corvid.h", .{});
    } else {
        try b.build_root.handle.access("deps/current/corvid.h", .{});
    }
}
