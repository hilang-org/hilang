const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("vm", vm_mod);

    const server_exe = b.addExecutable(.{
        .name = "hilang-vm",
        .root_module = server_mod,
    });
    b.installArtifact(server_exe);

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client_exe = b.addExecutable(.{
        .name = "hilang",
        .root_module = client_mod,
    });
    b.installArtifact(client_exe);

    const run_vm = b.addRunArtifact(server_exe);
    if (b.args) |args| run_vm.addArgs(args);
    const run_vm_step = b.step("run-vm", "Run the VM daemon");
    run_vm_step.dependOn(&run_vm.step);

    const run_client = b.addRunArtifact(client_exe);
    if (b.args) |args| run_client.addArgs(args);
    const run_client_step = b.step("run", "Run the client");
    run_client_step.dependOn(&run_client.step);

    const vm_tests = b.addTest(.{ .root_module = vm_mod });
    const run_vm_tests = b.addRunArtifact(vm_tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_vm_tests.step);

    // End-to-end protocol tests: in-process tests/*.zig files that
    // exercise full features (Float arithmetic, Fraction reduction,
    // Block param/temp slots, warmup-sensitive cross-iter dispatch).
    // They use the harness in tests/harness.zig to stand up a fresh
    // VM per test and feed it JSON ASTs.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("vm", vm_mod);
    const protocol_tests = b.addTest(.{ .root_module = tests_mod });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);

    // Bench harness module — same TestEnv as the test suite, exposed
    // by name so bench executables can `@import("harness")`.
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_mod.addImport("vm", vm_mod);

    // bench/micros.zig — the four classic legs (fib, sum, alloc, count).
    const micros_mod = b.createModule(.{
        .root_source_file = b.path("bench/micros.zig"),
        .target = target,
        .optimize = optimize,
    });
    micros_mod.addImport("vm", vm_mod);
    micros_mod.addImport("harness", harness_mod);
    const micros_exe = b.addExecutable(.{ .name = "bench-micros", .root_module = micros_mod });
    b.installArtifact(micros_exe);
    const run_micros = b.addRunArtifact(micros_exe);
    const bench_micros_step = b.step("bench-micros", "Run microbenchmarks");
    bench_micros_step.dependOn(&run_micros.step);

    // bench/suite.zig — extended workload coverage across recursion,
    // collections, strings, large-int math, GC pressure, polymorphic
    // dispatch, backtracking, exceptions, and Float math.
    const suite_mod = b.createModule(.{
        .root_source_file = b.path("bench/suite.zig"),
        .target = target,
        .optimize = optimize,
    });
    suite_mod.addImport("vm", vm_mod);
    suite_mod.addImport("harness", harness_mod);
    const suite_exe = b.addExecutable(.{ .name = "bench-suite", .root_module = suite_mod });
    // Some legs (mutual recursion `isEven/isOdd 1000`, deep
    // backtracking) need more stack than the macOS default 8 MiB.
    suite_exe.stack_size = 64 * 1024 * 1024;
    b.installArtifact(suite_exe);
    const run_suite = b.addRunArtifact(suite_exe);
    const bench_suite_step = b.step("bench-suite", "Run extended benchmark suite");
    bench_suite_step.dependOn(&run_suite.step);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&run_micros.step);
    bench_step.dependOn(&run_suite.step);
}
