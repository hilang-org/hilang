// Fraction reduction, arithmetic, comparisons, and Float promotion.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn expectTrue(env: *TestEnv, json: []const u8) !void {
    const o = try env.evalJson(json);
    try std.testing.expectEqual(vm.oop.TRUE, o);
}

fn expectInt(env: *TestEnv, want: i64, json: []const u8) !void {
    const o = try env.evalJson(json);
    try std.testing.expectEqual(want, vm.oop.toInt(o));
}

test "2/4 prints '1/2'" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":2}},"selector":"/","args":[{"literal":{"int":4}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"1/2"}}]}}
    );
}

test "6/-3 reduces to -2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, -2,
        \\{"send":{"receiver":{"literal":{"int":6}},"selector":"/","args":[{"literal":{"int":-3}}]}}
    );
}

test "4/2 has class SmallInteger" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":4}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.smallinteger_class, cls);
}

test "1/2 has class Fraction" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":"class","args":[]}}
    );
    const fraction_class = vm.dict.lookup(env.machine.globals.smalltalk, "Fraction");
    try std.testing.expectEqual(fraction_class, cls);
}

test "1/2 + 1/3 = 5/6" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},"selector":"+","args":[{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":3}}]}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"5/6"}}]}}
    );
}

test "1/2 + 1 = 3/2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},"selector":"+","args":[{"literal":{"int":1}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"3/2"}}]}}
    );
}

test "1 + 1/2 = 3/2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"+","args":[{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"3/2"}}]}}
    );
}

test "1/2 - 1/3 = 1/6" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},"selector":"-","args":[{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":3}}]}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"1/6"}}]}}
    );
}

test "1 - 1/2 = 1/2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"-","args":[{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"1/2"}}]}}
    );
}

test "(2/3) * (3/4) = 1/2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":2}},"selector":"/","args":[{"literal":{"int":3}}]}},"selector":"*","args":[{"send":{"receiver":{"literal":{"int":3}},"selector":"/","args":[{"literal":{"int":4}}]}}]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"1/2"}}]}}
    );
}

test "(1/2) / (1/4) = 2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 2,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":"/","args":[{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":4}}]}}]}}
    );
}

test "1/2 = 2/4" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":"=","args":[{"send":{"receiver":{"literal":{"int":2}},"selector":"/","args":[{"literal":{"int":4}}]}}]}}
    );
}

test "1/2 < 2/3" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":"<","args":[{"send":{"receiver":{"literal":{"int":2}},"selector":"/","args":[{"literal":{"int":3}}]}}]}}
    );
}

test "1 < 3/2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"<","args":[
        \\{"send":{"receiver":{"literal":{"int":3}},"selector":"/","args":[{"literal":{"int":2}}]}}
        \\]}}
    );
}

test "3/2 > 1" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":3}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":">","args":[{"literal":{"int":1}}]}}
    );
}

test "1/2 >= 1/2" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":">=","args":[{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}}]}}
    );
}

test "1/2 + 0.5 promotes to SmallFloat" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},
        \\"selector":"+","args":[{"literal":{"float":0.5}}]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.small_float_class, cls);
}

test "1 / 2.0 is SmallFloat" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"float":2.0}}]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.small_float_class, cls);
}

test "(1/2) asFloat = 0.5" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},"selector":"asFloat","args":[]}},
        \\"selector":"=","args":[{"literal":{"float":0.5}}]}}
    );
}

test "(1/2) negated prints '-1/2'" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":2}}]}},"selector":"negated","args":[]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"-1/2"}}]}}
    );
}

test "1/0 raises" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":0}}]}}
    );
    // The kernel should signal something — UserSignal at minimum.
    try std.testing.expect(std.meta.isError(result));
}
