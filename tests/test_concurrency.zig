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

test "suspended Process survives GC during another's run" {
    // Regression for the gap closed by this commit: a suspended
    // Process's bc_pin chain lives on its mmap'd native stack,
    // outside heap range. Frame slots reachable through
    // PROCESS_SAVED_FRAME are walked already; what's NOT walked
    // (pre-fix) is the OUTER frame's bytecode-interp eval-stack
    // when execution is paused inside a nested send.
    //
    // Shape: define a method `gcProbeYield` on Object that calls
    // `Processor yield` between accessing two heap-pointer
    // arguments, so when the worker invokes
    //
    //   GcLog addLast: (1 gcProbeYield: a with: b)
    //
    // the outer bytecode interp parks with eval-stack
    // [GcLog, 1, a, b] at sp=4 — pre-fix `a` and `b` go stale on
    // a GC; the post-yield SEND opcode hands a stale `GcLog` to
    // `addLast:` and either bus-errors or DNUs.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Global log so we can assert from main after both yields.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"GcLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // Object>>gcProbeYield:with:  Processor yield. ^aOC size + bOC size
    try env.installMethod(
        "Object",
        "gcProbeYield:with:",
        &.{ "aOC", "bOC" },
        &.{},
        \\[
        \\  {"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}},
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"aOC"},"selector":"size","args":[]}},
        \\          "selector":"+","args":[{"send":{"receiver":{"var_ref":"bOC"},"selector":"size","args":[]}}]}}}
        \\]
    );

    // Worker block:
    //   | a b |
    //   a := OC new init. a addLast: 1; addLast: 2; addLast: 3.
    //   b := OC new init. b addLast: 4; addLast: 5.
    //   GcLog addLast: (1 gcProbeYield: a with: b).
    //
    // At the SEND of gcProbeYield:with: the worker's outer block
    // frame's eval stack is [GcLog, 1, a, b]; that's what the
    // chain walker has to pin if the inner method yields.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":["a","b"],"body":[
        \\  {"assign":{"name":"a","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}}},
        \\  {"send":{"receiver":{"var_ref":"a"},"selector":"addLast:","args":[{"literal":{"int":1}}]}},
        \\  {"send":{"receiver":{"var_ref":"a"},"selector":"addLast:","args":[{"literal":{"int":2}}]}},
        \\  {"send":{"receiver":{"var_ref":"a"},"selector":"addLast:","args":[{"literal":{"int":3}}]}},
        \\  {"assign":{"name":"b","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}}},
        \\  {"send":{"receiver":{"var_ref":"b"},"selector":"addLast:","args":[{"literal":{"int":4}}]}},
        \\  {"send":{"receiver":{"var_ref":"b"},"selector":"addLast:","args":[{"literal":{"int":5}}]}},
        \\  {"send":{"receiver":{"var_ref":"GcLog"},"selector":"addLast:","args":[
        \\    {"send":{"receiver":{"literal":{"int":1}},"selector":"gcProbeYield:with:","args":[
        \\      {"var_ref":"a"},{"var_ref":"b"}
        \\    ]}}
        \\  ]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Worker runs up to its `Processor yield` inside
    // gcProbeYield:with:, then control returns here.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );

    // Deterministic GC. Every heap object the suspended worker
    // holds gets relocated; the bytecode-interp eval-stack on
    // the worker's mmap stack must be rewritten by the new
    // chain walker.
    try env.machine.collectGarbage();

    // Resume the worker; gcProbeYield:with: returns 3 + 2 = 5,
    // which addLast:'s into GcLog. Pre-fix the post-yield SEND
    // opcode would dispatch addLast: against a stale GcLog oop.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );

    const got = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"GcLog"},"selector":"first","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 5), vm.oop.toInt(got));
}

test "Mutex serialises critical sections across forks" {
    // Two workers each enter `mutex critical: [log addLast: 'X1'.
    // Processor yield. log addLast: 'X2']`. Without the mutex the
    // yield interleaves the two halves; with it the second worker
    // blocks on the underlying semaphore and runs only after the
    // first releases. Expected log: ['A1','A2','B1','B2'].
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"MutLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"TheMutex"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Mutex"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"TheMutex"},"selector":"critical:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"MutLog"},"selector":"addLast:","args":[{"literal":{"string":"A1"}}]}},
        \\      {"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}},
        \\      {"send":{"receiver":{"var_ref":"MutLog"},"selector":"addLast:","args":[{"literal":{"string":"A2"}}]}}
        \\    ]}}
        \\  ]}}
        \\]}},"selector":"fork","args":[]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"TheMutex"},"selector":"critical:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"MutLog"},"selector":"addLast:","args":[{"literal":{"string":"B1"}}]}},
        \\      {"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}},
        \\      {"send":{"receiver":{"var_ref":"MutLog"},"selector":"addLast:","args":[{"literal":{"string":"B2"}}]}}
        \\    ]}}
        \\  ]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Drive the schedule. 6 yields is comfortably more than enough
    // to drain both workers; surplus yields stay on the same active.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        _ = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
        );
    }

    const size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"MutLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 4), vm.oop.toInt(size));

    // Order: each worker's two halves are adjacent. Pre-mutex the
    // yield would split them — we'd see ABAB or similar.
    const e0 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"MutLog"},"selector":"at:","args":[{"literal":{"int":1}}]}}
    );
    const e1 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"MutLog"},"selector":"at:","args":[{"literal":{"int":2}}]}}
    );
    // First two entries must share a prefix letter (both 'A' or both 'B').
    const c0 = vm.object.bytesOf(e0)[0];
    const c1 = vm.object.bytesOf(e1)[0];
    try std.testing.expectEqual(c0, c1);
}

test "Mutex is reentrant in the same Process" {
    // Without the owner-fast-path, a second `critical:` from the
    // same process would deadlock on its own semaphore — surfaced
    // as PrimitiveFailed (no other runnable to schedule).
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"ReLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"ReMtx"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Mutex"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // ReMtx critical: [
    //   ReLog addLast: 'outer-pre'.
    //   ReMtx critical: [ReLog addLast: 'inner'].
    //   ReLog addLast: 'outer-post']
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ReMtx"},"selector":"critical:","args":[
        \\  {"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"ReLog"},"selector":"addLast:","args":[{"literal":{"string":"outer-pre"}}]}},
        \\    {"send":{"receiver":{"var_ref":"ReMtx"},"selector":"critical:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"ReLog"},"selector":"addLast:","args":[{"literal":{"string":"inner"}}]}}
        \\      ]}}
        \\    ]}},
        \\    {"send":{"receiver":{"var_ref":"ReLog"},"selector":"addLast:","args":[{"literal":{"string":"outer-post"}}]}}
        \\  ]}}
        \\]}}
    );

    const size = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ReLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(size));
}

test "SharedQueue producer/consumer round-trip" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"TheQ"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"SharedQueue"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // Producer: nextPut: 1, 2, 3.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"TheQ"},"selector":"nextPut:","args":[{"literal":{"int":1}}]}},
        \\  {"send":{"receiver":{"var_ref":"TheQ"},"selector":"nextPut:","args":[{"literal":{"int":2}}]}},
        \\  {"send":{"receiver":{"var_ref":"TheQ"},"selector":"nextPut:","args":[{"literal":{"int":3}}]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Yield so the producer runs and fills the queue (and signals
    // `available` 3 times).
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );

    // 1 + 2*10 + 3*100 = 321 — proves FIFO order.
    const result = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"TheQ"},"selector":"next","args":[]}},
        \\  "selector":"+","args":[{"send":{"receiver":{"send":{"receiver":{"var_ref":"TheQ"},"selector":"next","args":[]}},
        \\    "selector":"*","args":[{"literal":{"int":10}}]}}]}},
        \\  "selector":"+","args":[{"send":{"receiver":{"send":{"receiver":{"var_ref":"TheQ"},"selector":"next","args":[]}},
        \\    "selector":"*","args":[{"literal":{"int":100}}]}}]}}
    );
    try std.testing.expectEqual(@as(i64, 321), vm.oop.toInt(result));
}

test "Delay wait blocks at least N nanoseconds" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // 5 ms is short enough not to drag CI; long enough to dwarf
    // any nanosleep granularity (typically <1 ms). Stash t0 in
    // the Smalltalk dict so we can compute the delta after the
    // delay returns.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DelT0"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Time"},"selector":"monotonicNanos","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Delay"},"selector":"forMilliseconds:","args":[{"literal":{"int":5}}]}},
        \\  "selector":"wait","args":[]}}
    );
    const got = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Time"},"selector":"monotonicNanos","args":[]}},
        \\  "selector":"-","args":[{"var_ref":"DelT0"}]}}
    );
    const elapsed = vm.oop.toInt(got);
    try std.testing.expect(elapsed >= 5_000_000);
    // Sanity upper bound — under 1 s would catch a runaway sleep.
    try std.testing.expect(elapsed < 1_000_000_000);
}

test "Process>>onCrash: receives the uncaught exception from the forked block" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Stash a log so the handler can record what it saw; the
    // worker block raises 'boom' which the onCrash handler
    // catches and appends the messageText to the log.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"CrashLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // p := [Exception new signal: 'boom'] fork.
    // p onCrash: [:e | CrashLog addLast: e messageText].
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"CrashP"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"boom"}}]}}
        \\  ]}},"selector":"fork","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CrashP"},"selector":"onCrash:","args":[
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"CrashLog"},"selector":"addLast:","args":[
        \\      {"send":{"receiver":{"var_ref":"e"},"selector":"messageText","args":[]}}
        \\    ]}}
        \\  ]}}
        \\]}}
    );

    // Drive the schedule. Two yields are enough to start the
    // worker, let it raise, and trigger the handler before
    // termination.
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Processor\"},\"selector\":\"yield\",\"args\":[]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Processor\"},\"selector\":\"yield\",\"args\":[]}}");

    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CrashLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(sz));
    const msg = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CrashLog"},"selector":"first","args":[]}}
    );
    try std.testing.expectEqualStrings(
        "boom",
        vm.object.bytesOf(msg)[0..vm.object.headerOf(msg).size],
    );
}

test "Process without onCrash: silently swallows the exception" {
    // Pre-existing behaviour preserved when no handler is set:
    // the worker terminates cleanly, main keeps running, no
    // error escapes to the host. We assert by observing main's
    // own state across the worker's crash.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"AfterCrash"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":0}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"silent"}}]}}
        \\]}},"selector":"fork","args":[]}}
    );
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Processor\"},\"selector\":\"yield\",\"args\":[]}}");
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"AfterCrash"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":42}}
        \\]}}
    );
    const got = try env.evalJson("{\"var_ref\":\"AfterCrash\"}");
    try std.testing.expectEqual(@as(i64, 42), vm.oop.toInt(got));
}

test "Terminated processes are reaped from the Vm's process list" {
    // Without the reaper, every fork leaves a dangling Process oop
    // on Vm.all_processes (and a 2 MiB mmap'd stack on
    // Vm.process_stacks) for the lifetime of the Vm.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Lazy-create the main process so we have a stable baseline of 1.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
    );
    const before = env.machine.all_processes.items.len;
    const stacks_before = env.machine.process_stacks.items.len;

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        _ = try env.evalJson(
            \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":1}}]}},
            \\"selector":"fork","args":[]}}
        );
    }
    // Drain — each yield ends a worker; reapTerminated runs at
    // dequeueHighestRunnable, which fires every yield.
    var j: u32 = 0;
    while (j < 8) : (j += 1) {
        _ = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
        );
    }

    try std.testing.expectEqual(before, env.machine.all_processes.items.len);
    try std.testing.expectEqual(stacks_before, env.machine.process_stacks.items.len);
}

test "Delay does not block the whole VM" {
    // A worker waits on a Delay. Main waits on a semaphore that
    // the worker signals after the delay returns. The fact that
    // the test completes proves expireSleepers re-queued the
    // worker — without that, main blocks forever on the
    // semaphore (its scheduleNext sees an empty run queue and an
    // unattended delay queue → nanosleep → expire → wake worker
    // → worker signals → main resumes). 5 ms keeps the wall
    // clock cheap.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DoneSem"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Semaphore"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Delay"},"selector":"forMilliseconds:","args":[{"literal":{"int":5}}]}},"selector":"wait","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"DoneSem"},"selector":"signal","args":[]}}
        \\]}},"selector":"fork","args":[]}}
    );

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DelT0b"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Time"},"selector":"monotonicNanos","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DoneSem"},"selector":"wait","args":[]}}
    );
    const got = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Time"},"selector":"monotonicNanos","args":[]}},
        \\  "selector":"-","args":[{"var_ref":"DelT0b"}]}}
    );
    const elapsed = vm.oop.toInt(got);
    try std.testing.expect(elapsed >= 5_000_000);
    try std.testing.expect(elapsed < 1_000_000_000);
}
