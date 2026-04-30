// Surface tests for the Process / Semaphore / ProcessorScheduler
// scaffolding. The eventual cooperative scheduler will exercise the
// blocking semantics; for now we verify the classes exist, the
// primitives are wired, and the shapes are right.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn expectClass(env: *TestEnv, want: vm.Oop, json: []const u8) !void {
    const got = try env.evalJson(json);
    try std.testing.expectEqual(want, got);
}

fn expectInt(env: *TestEnv, want: i64, json: []const u8) !void {
    const got = try env.evalJson(json);
    try std.testing.expectEqual(want, vm.oop.toInt(got));
}

fn expectTrue(env: *TestEnv, json: []const u8) !void {
    const got = try env.evalJson(json);
    try std.testing.expectEqual(vm.oop.TRUE, got);
}

test "Process, Semaphore, ProcessorScheduler classes exist" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    try expectClass(&env, env.machine.globals.process_class,
        \\{"var_ref":"Process"}
    );
    try expectClass(&env, env.machine.globals.semaphore_class,
        \\{"var_ref":"Semaphore"}
    );
    try expectClass(&env, env.machine.globals.scheduler_class,
        \\{"var_ref":"ProcessorScheduler"}
    );
}

test "Processor singleton is bound and is a ProcessorScheduler" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const processor = try env.evalJson(
        \\{"var_ref":"Processor"}
    );
    try std.testing.expect(vm.oop.isHeapPtr(processor));
    try std.testing.expectEqual(env.machine.globals.processor, processor);

    const cls = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.scheduler_class, cls);
}

test "Semaphore new init has count 0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 0,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}},
        \\"selector":"count","args":[]}}
    );
}

test "Semaphore signal then wait round-trips" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // (Semaphore new init signal) wait — 1 → 0, returns the Semaphore.
    const result = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}},"selector":"signal","args":[]}},
        \\"selector":"wait","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(result));
    // Count should be back at 0.
    try expectInt(&env, 0,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}},"selector":"signal","args":[]}},"selector":"wait","args":[]}},
        \\"selector":"count","args":[]}}
    );
}

test "Semaphore wait on count=0 is a primitive failure (no scheduler yet)" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Once the cooperative scheduler lands this becomes a *block*
    // until another process signals; for now the contract is "you
    // must not silently get past a zero-count wait".
    const result = env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}},
        \\"selector":"wait","args":[]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}

test "Block fork returns a runnable Process at default priority 3" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const p = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":42}}]}},
        \\"selector":"fork","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(p));
    try std.testing.expectEqual(env.machine.globals.process_class, vm.object.headerOf(p).class);

    const pri = vm.object.slot(p, vm.object.SLOT_PROCESS_PRIORITY);
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(pri));

    const state = vm.object.slot(p, vm.object.SLOT_PROCESS_STATE);
    try std.testing.expectEqual(env.machine.globals.sym_runnable, state);
}

test "Block forkAt: clamps priority into 1..7" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const p = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":1}}]}},
        \\"selector":"forkAt:","args":[{"literal":{"int":5}}]}}
    );
    const pri = vm.object.slot(p, vm.object.SLOT_PROCESS_PRIORITY);
    try std.testing.expectEqual(@as(i64, 5), vm.oop.toInt(pri));

    // Out-of-band priority is rejected.
    const bad = env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":1}}]}},
        \\"selector":"forkAt:","args":[{"literal":{"int":99}}]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, bad);
}

test "Forked Process appears in the scheduler's runnable list" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const p = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":1}}]}},
        \\"selector":"fork","args":[]}}
    );
    const lists = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"quiescentLists","args":[]}}
    );
    // Priority 3 (default) → index 3 in the 1-based runnable list array.
    const head = vm.object.slot(lists, 3);
    try std.testing.expectEqual(p, head);
}

test "Process>>terminate flips state to #terminated" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const p = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":1}}]}},
        \\"selector":"fork","args":[]}}
    );
    _ = try env.machine.send(p, "terminate", &.{});
    const state = vm.object.slot(p, vm.object.SLOT_PROCESS_STATE);
    try std.testing.expectEqual(env.machine.globals.sym_terminated, state);
}

test "Processor>>activeProcess starts as nil" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"activeProcess","args":[]}}
    );
    try std.testing.expectEqual(vm.oop.NIL, result);
}

test "Processor>>yield is a no-op for now" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    try std.testing.expectEqual(vm.oop.NIL, result);
}

test "Priority constants are bound in Smalltalk" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 3, "{\"var_ref\":\"PriorityUserScheduling\"}");
    try expectInt(&env, 7, "{\"var_ref\":\"PriorityTiming\"}");
}
