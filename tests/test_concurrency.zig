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

test "Semaphore wait on count=0 with no other process deadlocks" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // The active Process is now blocked on the semaphore's waiters
    // queue and there's no other runnable to swap to. The
    // scheduler surfaces this as a recoverable PrimitiveFailed
    // rather than spinning silently.
    const result = env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}},
        \\"selector":"wait","args":[]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}

test "fork actually runs the block once we yield" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // The block bumps a Smalltalk class-side counter on
    // SmallInteger so we can read it back after the yield. We
    // install a stash slot via `Smalltalk at:put:` of an
    // OrderedCollection.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[{"send":{"receiver":{"literal":{"string":"ConcurrencyLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}]}}
    );

    // [ConcurrencyLog addLast: 'forked'] fork.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"ConcurrencyLog"},"selector":"addLast:","args":[{"literal":{"string":"forked"}}]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Forked block hasn't run yet — main is still active and the
    // forked process is parked on the runnable list.
    var size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ConcurrencyLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 0), vm.oop.toInt(size));

    // Yielding hands control to the forked process; when it
    // terminates, scheduleNext brings us back here.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ConcurrencyLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(size));
}

test "Semaphore signal wakes a waiting Process" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Pattern: main forks a worker that waits on the semaphore;
    // main yields so the worker actually starts and parks itself
    // on the waiters list; main then signals, which marks the
    // worker runnable; main yields again, the worker resumes past
    // its wait and finishes its block.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[{"send":{"receiver":{"literal":{"string":"SyncSem"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[{"send":{"receiver":{"literal":{"string":"SyncLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}]}}
    );

    // Worker block: SyncSem wait. SyncLog addLast: 'after-wait'.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"SyncSem"},"selector":"wait","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"SyncLog"},"selector":"addLast:","args":[{"literal":{"string":"after-wait"}}]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Yield → worker runs up to its `wait`, which parks it on
    // SyncSem's waiters and swaps back here.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    var size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SyncLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 0), vm.oop.toInt(size));

    // Signal → worker becomes runnable. We yield again so it can
    // pick up where wait left off.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SyncSem"},"selector":"signal","args":[]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SyncLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(size));
}

test "two forked workers alternate via yield" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[{"send":{"receiver":{"literal":{"string":"AlternateLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}]}}
    );
    // Two workers each log 'A' or 'B' twice with a yield between.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"AlternateLog"},"selector":"addLast:","args":[{"literal":{"string":"A1"}}]}},
        \\  {"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"AlternateLog"},"selector":"addLast:","args":[{"literal":{"string":"A2"}}]}}
        \\]}},"selector":"fork","args":[]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"AlternateLog"},"selector":"addLast:","args":[{"literal":{"string":"B1"}}]}},
        \\  {"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"AlternateLog"},"selector":"addLast:","args":[{"literal":{"string":"B2"}}]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Drive the schedule until both workers terminate.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );

    const size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"AlternateLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 4), vm.oop.toInt(size));
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
