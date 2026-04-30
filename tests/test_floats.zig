// Float arithmetic, comparisons, formatting, and mixed-type coercion.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn evalFloat(env: *TestEnv, json: []const u8) !f64 {
    const o = try env.evalJson(json);
    return vm.oop.toF64(o);
}

fn evalInt(env: *TestEnv, json: []const u8) !i64 {
    const o = try env.evalJson(json);
    return vm.oop.toInt(o);
}

fn expectFloat(env: *TestEnv, want: f64, json: []const u8) !void {
    const got = try evalFloat(env, json);
    try std.testing.expectApproxEqAbs(want, got, 1e-12);
}

fn expectInt(env: *TestEnv, want: i64, json: []const u8) !void {
    const got = try evalInt(env, json);
    try std.testing.expectEqual(want, got);
}

fn expectTrue(env: *TestEnv, json: []const u8) !void {
    const o = try env.evalJson(json);
    try std.testing.expectEqual(vm.oop.TRUE, o);
}

test "Float +" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 3.75,
        \\{"send":{"receiver":{"literal":{"float":1.5}},"selector":"+","args":[{"literal":{"float":2.25}}]}}
    );
}

test "Float -" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 3.5,
        \\{"send":{"receiver":{"literal":{"float":5.0}},"selector":"-","args":[{"literal":{"float":1.5}}]}}
    );
}

test "Float *" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 7.0,
        \\{"send":{"receiver":{"literal":{"float":2.0}},"selector":"*","args":[{"literal":{"float":3.5}}]}}
    );
}

test "Float /" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 2.5,
        \\{"send":{"receiver":{"literal":{"float":10.0}},"selector":"/","args":[{"literal":{"float":4.0}}]}}
    );
}

test "Float <" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"literal":{"float":1.0}},"selector":"<","args":[{"literal":{"float":2.0}}]}}
    );
}

test "Float >=" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"literal":{"float":2.0}},"selector":">=","args":[{"literal":{"float":2.0}}]}}
    );
}

test "Float =" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"literal":{"float":3.14}},"selector":"=","args":[{"literal":{"float":3.14}}]}}
    );
}

test "Float truncated" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 3,
        \\{"send":{"receiver":{"literal":{"float":3.9}},"selector":"truncated","args":[]}}
    );
}

test "Integer asFloat" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 42.0,
        \\{"send":{"receiver":{"literal":{"int":42}},"selector":"asFloat","args":[]}}
    );
}

test "Float class is SmallFloat" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"float":3.14}},"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.small_float_class, cls);
}

test "Float printString = '1.5'" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"float":1.5}},"selector":"printString","args":[]}},
        \\"selector":"=","args":[{"literal":{"string":"1.5"}}]}}
    );
}

test "mix: Int + Float" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 3.5,
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"+","args":[{"literal":{"float":2.5}}]}}
    );
}

test "mix: Float + Int" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 3.5,
        \\{"send":{"receiver":{"literal":{"float":2.5}},"selector":"+","args":[{"literal":{"int":1}}]}}
    );
}

test "mix: Int < Float" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"<","args":[{"literal":{"float":2.5}}]}}
    );
}

test "mix: Int = Float" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectTrue(&env,
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"=","args":[{"literal":{"float":1.0}}]}}
    );
}

test "mix: Float / Int" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectFloat(&env, 2.5,
        \\{"send":{"receiver":{"literal":{"float":10.0}},"selector":"/","args":[{"literal":{"int":4}}]}}
    );
}
