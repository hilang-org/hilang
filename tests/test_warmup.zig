// Cross-iteration regression tests for warmup-sensitive paths. Both
// shapes broke at v42 and were fixed shortly before the OSS release.
//
//   - `2 raisedTo: 20` returned the wrong value after raisedTo: tier-up
//     to NATIVE: the JIT's post-SEND eval-stack reg recanonicalisation
//     didn't write aliased survivors (e.g. an aliased push_self) into
//     their canonical reg, so the next opcode read stale state.
//
//   - `dictChurn` DNU'd after dictChurn tier-up: a JIT'd caller invoked
//     AST `at:put:` (kept AST due to ivar refs); a safe-point GC inside
//     the callee skipped the JIT'd caller's stack frame, leaving its
//     literal-pool symbols pointing into from-space.
//
// Tests are intentionally cross-iteration: iter 0 runs under bytecode,
// iter 1+ runs under JIT'd code, and both legs must agree.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "2 raisedTo: 20 across 5 iterations" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const expr =
        \\{"send":{"receiver":{"literal":{"int":2}},"selector":"raisedTo:","args":[{"literal":{"int":20}}]}}
    ;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const o = try env.evalJson(expr);
        try std.testing.expectEqual(@as(i64, 1048576), vm.oop.toInt(o));
    }
}

test "5000 dictChurn across 2 iterations" {
    var env: TestEnv = undefined;
    // dictChurn at N=5000 grows past the default 8 MiB half_size; size
    // for ~256 MB total so the safe-point GC the bug feeds on actually
    // fires.
    try env.initWithHeap(256 * 1024 * 1024);
    defer env.deinit();

    // dictChurn body:
    //   d := Dictionary new init.
    //   i := 0.
    //   [i < self] whileTrue: [
    //       d at:put: i (i*2).
    //       i := i + 1].
    //   ^ d size
    try env.installMethod(
        "SmallInteger",
        "_warmupDictChurn",
        &.{},
        &.{ "d", "i" },
        \\[
        \\  {"assign":{"name":"d","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Dictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"d"},"selector":"at:put:","args":[
        \\          {"var_ref":"i"},
        \\          {"send":{"receiver":{"var_ref":"i"},"selector":"*","args":[{"literal":{"int":2}}]}}
        \\      ]}},
        \\      {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"send":{"receiver":{"var_ref":"d"},"selector":"size","args":[]}}}
        \\]
    );

    const expr =
        \\{"send":{"receiver":{"literal":{"int":5000}},"selector":"_warmupDictChurn","args":[]}}
    ;
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        const o = try env.evalJson(expr);
        try std.testing.expectEqual(@as(i64, 5000), vm.oop.toInt(o));
    }
}
