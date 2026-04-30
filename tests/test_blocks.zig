// Block param/temp slot indexing — the canonical cases for the
// off-by-one that bit phase v2.D.2.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn expectInt(env: *TestEnv, want: i64, json: []const u8) !void {
    const o = try env.evalJson(json);
    try std.testing.expectEqual(want, vm.oop.toInt(o));
}

test "(1 to: 5) inject: 0 into: [:a :x | a + x] = 15" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 15,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"to:","args":[{"literal":{"int":5}}]}},
        \\"selector":"inject:into:","args":[
        \\  {"literal":{"int":0}},
        \\  {"block":{"params":["a","x"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"a"},"selector":"+","args":[{"var_ref":"x"}]}}
        \\  ]}}
        \\]}}
    );
}

test "((1 to: 4) collect: [:x | x*x]) sum = 30" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 30,
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"to:","args":[{"literal":{"int":4}}]}},
        \\"selector":"collect:","args":[
        \\  {"block":{"params":["x"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"x"},"selector":"*","args":[{"var_ref":"x"}]}}
        \\  ]}}
        \\]}},"selector":"sum","args":[]}}
    );
}

test "2-arg block with temp: t := x*x; a + t = 30" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 30,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"to:","args":[{"literal":{"int":4}}]}},
        \\"selector":"inject:into:","args":[
        \\  {"literal":{"int":0}},
        \\  {"block":{"params":["a","x"],"temps":["t"],"body":[
        \\    {"seq":[
        \\      {"assign":{"name":"t","value":{"send":{"receiver":{"var_ref":"x"},"selector":"*","args":[{"var_ref":"x"}]}}}},
        \\      {"send":{"receiver":{"var_ref":"a"},"selector":"+","args":[{"var_ref":"t"}]}}
        \\    ]}
        \\  ]}}
        \\]}}
    );
}

test "[:x | x + 1] value: 41 = 42" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 42,
        \\{"send":{"receiver":{"block":{"params":["x"],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"x"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\]}},"selector":"value:","args":[{"literal":{"int":41}}]}}
    );
}

test "[:a :b :c | a + b + c] value:value:value: = 6" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 6,
        \\{"send":{"receiver":{"block":{"params":["a","b","c"],"temps":[],"body":[
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"a"},"selector":"+","args":[{"var_ref":"b"}]}},
        \\           "selector":"+","args":[{"var_ref":"c"}]}}
        \\]}},"selector":"value:value:value:","args":[{"literal":{"int":1}},{"literal":{"int":2}},{"literal":{"int":3}}]}}
    );
}

test "(1 to: 10) inject: 0 into: [:a :x | a + x] = 55 (top-level)" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectInt(&env, 55,
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"to:","args":[{"literal":{"int":10}}]}},
        \\"selector":"inject:into:","args":[
        \\  {"literal":{"int":0}},
        \\  {"block":{"params":["a","x"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"a"},"selector":"+","args":[{"var_ref":"x"}]}}
        \\  ]}}
        \\]}}
    );
}
