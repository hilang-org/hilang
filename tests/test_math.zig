// sqrt / sin / cos / ln / exp / pi / e

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn evalFloat(env: *TestEnv, json: []const u8) !f64 {
    const o = try env.evalJson(json);
    return vm.oop.toF64(o);
}

fn expectFloat(env: *TestEnv, want: f64, eps: f64, json: []const u8) !void {
    const got = try evalFloat(env, json);
    try std.testing.expectApproxEqAbs(want, got, eps);
}

test "Float 4.0 sqrt = 2.0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 2.0, 1e-9,
        \\{"send":{"receiver":{"literal":{"float":4.0}},"selector":"sqrt","args":[]}}
    );
}

test "Integer 9 sqrt = 3.0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 3.0, 1e-9,
        \\{"send":{"receiver":{"literal":{"int":9}},"selector":"sqrt","args":[]}}
    );
}

test "(1/4) sqrt = 0.5" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 0.5, 1e-9,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"/","args":[{"literal":{"int":4}}]}},
        \\"selector":"sqrt","args":[]}}
    );
}

test "0.0 sin = 0.0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 0.0, 1e-9,
        \\{"send":{"receiver":{"literal":{"float":0.0}},"selector":"sin","args":[]}}
    );
}

test "0.0 cos = 1.0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 1.0, 1e-9,
        \\{"send":{"receiver":{"literal":{"float":0.0}},"selector":"cos","args":[]}}
    );
}

test "(SmallFloat pi) cos = -1" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, -1.0, 1e-9,
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"SmallFloat"},"selector":"pi","args":[]}},
        \\"selector":"cos","args":[]}}
    );
}

test "0.0 exp = 1.0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 1.0, 1e-9,
        \\{"send":{"receiver":{"literal":{"float":0.0}},"selector":"exp","args":[]}}
    );
}

test "1.0 exp = SmallFloat e" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const a = try evalFloat(&env,
        \\{"send":{"receiver":{"literal":{"float":1.0}},"selector":"exp","args":[]}}
    );
    const b = try evalFloat(&env,
        \\{"send":{"receiver":{"var_ref":"SmallFloat"},"selector":"e","args":[]}}
    );
    try std.testing.expectApproxEqAbs(a, b, 1e-9);
}

test "(SmallFloat e) ln = 1.0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 1.0, 1e-12,
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"SmallFloat"},"selector":"e","args":[]}},
        \\"selector":"ln","args":[]}}
    );
}

test "SmallFloat pi has class SmallFloat" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"SmallFloat"},"selector":"pi","args":[]}},
        \\"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.small_float_class, cls);
}
