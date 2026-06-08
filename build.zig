const builtin = @import("builtin");
const std = @import("std");

fn configureCompileStep(
    step: *std.Build.Step.Compile,
    build_options: *std.Build.Step.Options,
    tree_sitter_enabled: bool,
) void {
    step.root_module.addOptions("build_options", build_options);
    if (tree_sitter_enabled) addTreeSitterSources(step.root_module);
}

fn addTreeSitterSources(module: *std.Build.Module) void {
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter/lib/include"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter/lib/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-hcl/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-c/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-cpp/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-rust/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-typescript/typescript/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-typescript/tsx/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-python/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-go/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-dart/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-php/php/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-r/src"));
    module.addIncludePath(module.owner.path("zig-pkg/tree-sitter-ruby/src"));
    module.link_libcpp = true;
    module.addCSourceFiles(.{
        .files = &.{
            "zig-pkg/tree-sitter/lib/src/lib.c",
            "zig-pkg/tree-sitter-c/src/parser.c",
            "zig-pkg/tree-sitter-cpp/src/parser.c",
            "zig-pkg/tree-sitter-cpp/src/scanner.c",
            "zig-pkg/tree-sitter-rust/src/rust-parser.c",
            "zig-pkg/tree-sitter-rust/src/rust-scanner.c",
            "zig-pkg/tree-sitter-typescript/typescript/src/parser.c",
            "zig-pkg/tree-sitter-typescript/typescript/src/scanner.c",
            "zig-pkg/tree-sitter-typescript/tsx/src/parser.c",
            "zig-pkg/tree-sitter-typescript/tsx/src/scanner.c",
            "zig-pkg/tree-sitter-python/src/parser.c",
            "zig-pkg/tree-sitter-python/src/scanner.c",
            "zig-pkg/tree-sitter-go/src/parser.c",
            "zig-pkg/tree-sitter-dart/src/parser.c",
            "zig-pkg/tree-sitter-dart/src/scanner.c",
            "zig-pkg/tree-sitter-php/php/src/parser.c",
            "zig-pkg/tree-sitter-php/php/src/scanner.c",
            "zig-pkg/tree-sitter-hcl/src/parser.c",
            "zig-pkg/tree-sitter-r/src/parser.c",
            "zig-pkg/tree-sitter-r/src/scanner.c",
            "zig-pkg/tree-sitter-ruby/src/parser.c",
            "zig-pkg/tree-sitter-ruby/src/scanner.c",
        },
        .flags = &.{
            "-std=c11",
            "-D_POSIX_C_SOURCE=200809L",
        },
    });
    module.addCSourceFiles(.{
        .files = &.{
            "zig-pkg/tree-sitter-hcl/src/scanner.cc",
        },
        .flags = &.{
            "-std=c++17",
        },
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tree_sitter_enabled = b.option(bool, "tree-sitter", "Enable vendored tree-sitter parser support") orelse true;
    const codesign_identity = b.option(
        []const u8,
        "codesign-identity",
        "macOS codesign identity. Disabled by default and skipped for x86_64-macos.",
    );

    // ── Exposed module: importable as @import("codedb") ──
    const codedb_mod = b.addModule("codedb", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── CLI executable ──
    // In ReleaseFast/Small, strip debug info to shrink the binary (~10%)
    // and the RSS at runtime (smaller __TEXT footprint = fewer pages
    // resident under load). Debug/ReleaseSafe keep symbols for stack traces.
    const strip_debug = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const build_options = b.addOptions();
    build_options.addOption(bool, "tree_sitter", tree_sitter_enabled);
    const wasm_build_options = b.addOptions();
    wasm_build_options.addOption(bool, "tree_sitter", false);
    const exe = b.addExecutable(.{
        .name = "codedb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_debug,
        }),
    });

    // ── mcp-zig dependency ──
    const mcp_dep = b.dependency("mcp_zig", .{});
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));

    // ── nanoregex dependency ──
    const nanoregex_dep = b.dependency("nanoregex", .{});
    exe.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    configureCompileStep(exe, build_options, tree_sitter_enabled);
    codedb_mod.addOptions("build_options", build_options);

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // Zig 0.16 x86_64-macos binaries can segfault on macOS 26 after codesign
    // (issue #504), including under Rosetta. Keep that release slice unsigned.
    if (codesign_identity) |identity| {
        const target_os = target.query.os_tag orelse target.result.os.tag;
        const target_arch = target.query.cpu_arch orelse target.result.cpu.arch;
        if (target_os == .macos and target_arch != .x86_64 and builtin.os.tag == .macos) {
            const codesign = b.addSystemCommand(&.{
                "codesign",
                "-f",
                "--options",
                "runtime",
                "--timestamp",
                "-s",
                identity,
                b.getInstallPath(.bin, "codedb"),
            });
            codesign.step.dependOn(&install_exe.step);
            b.getInstallStep().dependOn(&codesign.step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run codedb daemon");
    run_step.dependOn(&run_cmd.step);

    // ── Tests (split into independent binaries for faster compilation) ──
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const test_step = b.step("test", "Run all tests");

    const test_files = [_]struct { name: []const u8, path: []const u8, needs_mcp: bool, needs_nanoregex: bool }{
        .{ .name = "test-core", .path = "src/test_core.zig", .needs_mcp = false, .needs_nanoregex = false },
        .{ .name = "test-explore", .path = "src/test_explore.zig", .needs_mcp = false, .needs_nanoregex = true },
        .{ .name = "test-index", .path = "src/test_index.zig", .needs_mcp = true, .needs_nanoregex = true },
        .{ .name = "test-parser", .path = "src/test_parser.zig", .needs_mcp = false, .needs_nanoregex = true },
        .{ .name = "test-search", .path = "src/test_search.zig", .needs_mcp = true, .needs_nanoregex = true },
        .{ .name = "test-snapshot", .path = "src/test_snapshot.zig", .needs_mcp = false, .needs_nanoregex = true },
        .{ .name = "test-mcp", .path = "src/test_mcp.zig", .needs_mcp = true, .needs_nanoregex = true },
        .{ .name = "test-compass", .path = "src/test_compass.zig", .needs_mcp = true, .needs_nanoregex = true },
        .{ .name = "test-query", .path = "src/test_query.zig", .needs_mcp = true, .needs_nanoregex = true },
        .{ .name = "test-bench", .path = "src/test_bench.zig", .needs_mcp = false, .needs_nanoregex = true },
    };

    for (test_files) |tf| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tf.path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        if (tf.needs_mcp) t.root_module.addImport("mcp", mcp_dep.module("mcp"));
        if (tf.needs_nanoregex) t.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
        configureCompileStep(t, build_options, tree_sitter_enabled);
        if (test_filter) |f| {
            const filters = b.allocator.alloc([]const u8, 1) catch @panic("oom");
            filters[0] = f;
            t.filters = filters;
        }
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);

        const individual_step = b.step(tf.name, b.fmt("Run {s}", .{tf.name}));
        individual_step.dependOn(&run.step);
    }

    // ── Library tests (verify the module root compiles) ──
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureCompileStep(lib_tests, build_options, tree_sitter_enabled);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // ── Adversarial tests ──
    const adversarial_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adversarial_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    adversarial_tests.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    configureCompileStep(adversarial_tests, build_options, tree_sitter_enabled);
    test_step.dependOn(&b.addRunArtifact(adversarial_tests).step);

    // ── Benchmarks ──
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench.root_module.addImport("mcp", mcp_dep.module("mcp"));
    bench.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    configureCompileStep(bench, build_options, tree_sitter_enabled);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);

    // ── Benchmark (repo benchmark — indexing speed, query latency, recall) ──
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    benchmark.root_module.addImport("mcp", mcp_dep.module("mcp"));
    benchmark.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    configureCompileStep(benchmark, build_options, tree_sitter_enabled);
    const benchmark_run = b.addRunArtifact(benchmark);
    if (b.args) |args| benchmark_run.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run repo benchmark (use -- --root /path/to/repo)");
    benchmark_step.dependOn(&benchmark_run.step);

    // Make module available so dependents don't need to wire it up manually

    // ── Tree-sitter smoke test ──
    const ts_smoke = b.addExecutable(.{
        .name = "tree-sitter-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tree_sitter_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_debug,
        }),
    });
    configureCompileStep(ts_smoke, build_options, tree_sitter_enabled);
    const ts_smoke_run = b.addRunArtifact(ts_smoke);
    const ts_smoke_step = b.step("ts-smoke", "Run tree-sitter Rust smoke parser");
    ts_smoke_step.dependOn(&ts_smoke_run.step);

    // ── WASM build (for Cloudflare Workers) ──
    const wasm = b.addExecutable(.{
        .name = "codedb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    wasm.root_module.addOptions("build_options", wasm_build_options);
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    const wasm_step = b.step("wasm", "Build WASM module for Cloudflare Workers");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../wasm" } },
    }).step);
}
