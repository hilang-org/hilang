// LargeInteger overflow, arithmetic, and class transitions.

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

test "25! is a LargePositiveInteger" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.large_positive_integer_class, cls);
}

test "25! prints exactly" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"15511210043330985984000000"}}]}}
    );
}

test "25! - (25! - 1) = 1" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 1,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},
        \\"selector":"-","args":[
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},
        \\"selector":"-","args":[{"literal":{"int":1}}]}}
        \\]}}
    );
}

test "20! < 25!" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":20}},"selector":"factorial","args":[]}},
        \\"selector":"<","args":[
        \\{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}}
        \\]}}
    );
}

test "25! = 25!" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},
        \\"selector":"=","args":[
        \\{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}}
        \\]}}
    );
}

test "25! * 2 = 25! + 25!" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},"selector":"*","args":[{"literal":{"int":2}}]}},
        \\"selector":"=","args":[
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},"selector":"+","args":[{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}}]}}
        \\]}}
    );
}

test "0 - 25! is LargeNegativeInteger" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":0}},"selector":"-","args":[
        \\{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}}
        \\]}},"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.large_negative_integer_class, cls);
}

test "25! - 25! collapses to SmallInteger" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},
        \\"selector":"-","args":[{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}}]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.smallinteger_class, cls);
}

test "2^31 * 2^32 promotes to Large" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"*","args":[{"literal":{"int":2147483648}}]}},"selector":"*","args":[{"literal":{"int":4294967296}}]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.large_positive_integer_class, cls);
}

test "25! + 0.0 promotes to SmallFloat" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},
        \\"selector":"+","args":[{"literal":{"float":0.0}}]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.small_float_class, cls);
}

test "25! asFloat > 1e24" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":25}},"selector":"factorial","args":[]}},"selector":"asFloat","args":[]}},
        \\"selector":">","args":[{"literal":{"float":1.0e24}}]}}
    );
}

test "SmallInteger printing path unaffected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":42}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"42"}}]}}
    );
}
