// Random — xorshift64* PRNG with auto-seeded `new` and
// deterministic `seed:`. Tests verify range, determinism
// across same-seed instances, and divergence across
// different seeds.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "Random seed: produces identical streams" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"R1"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":42}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"R2"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":42}}]}}
        \\]}}
    );

    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const a = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"R1"},"selector":"nextRawInt","args":[]}}
        );
        const b = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"R2"},"selector":"nextRawInt","args":[]}}
        );
        try std.testing.expectEqual(vm.oop.toInt(a), vm.oop.toInt(b));
    }
}

test "Random different seeds diverge" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const a = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":1}}]}},"selector":"nextRawInt","args":[]}}
    );
    const b = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":2}}]}},"selector":"nextRawInt","args":[]}}
    );
    try std.testing.expect(vm.oop.toInt(a) != vm.oop.toInt(b));
}

test "Random>>next returns Float in [0, 1)" {
    // 100 iterations inside a single Smalltalk method so the JIT
    // sees one compilation, not 100. Failures stash a marker in
    // the Smalltalk dict; the assertion checks it never fires.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Rn"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":99}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":100}},"selector":"timesRepeat:","args":[
        \\  {"block":{"params":[],"temps":["v"],"body":[
        \\    {"assign":{"name":"v","value":{"send":{"receiver":{"var_ref":"Rn"},"selector":"next","args":[]}}}},
        \\    {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"v"},"selector":">=","args":[{"literal":{"float":0.0}}]}},"selector":"and:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[{"send":{"receiver":{"var_ref":"v"},"selector":"<","args":[{"literal":{"float":1.0}}]}}]}}
        \\    ]}},"selector":"ifFalse:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\          {"send":{"receiver":{"literal":{"string":"RnBad"}},"selector":"asSymbol","args":[]}},{"literal":{"int":1}}
        \\        ]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}
        \\]}}
    );
    const bad = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:ifAbsent:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"RnBad"}},"selector":"asSymbol","args":[]}},
        \\  {"block":{"params":[],"temps":[],"body":[{"literal":{"int":0}}]}}
        \\]}}
    );
    try std.testing.expectEqual(@as(i64, 0), vm.oop.toInt(bad));
}

test "Random>>nextInteger: bounds the result to 0..bound-1" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Rb"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":17}}]}}
        \\]}}
    );
    // Loop in Smalltalk so there's one JIT compile, not 200.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":200}},"selector":"timesRepeat:","args":[
        \\  {"block":{"params":[],"temps":["v"],"body":[
        \\    {"assign":{"name":"v","value":{"send":{"receiver":{"var_ref":"Rb"},"selector":"nextInteger:","args":[{"literal":{"int":10}}]}}}},
        \\    {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"v"},"selector":">=","args":[{"literal":{"int":0}}]}},"selector":"and:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[{"send":{"receiver":{"var_ref":"v"},"selector":"<","args":[{"literal":{"int":10}}]}}]}}
        \\    ]}},"selector":"ifFalse:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\          {"send":{"receiver":{"literal":{"string":"RbBad"}},"selector":"asSymbol","args":[]}},{"literal":{"int":1}}
        \\        ]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}
        \\]}}
    );
    const bad = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:ifAbsent:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"RbBad"}},"selector":"asSymbol","args":[]}},
        \\  {"block":{"params":[],"temps":[],"body":[{"literal":{"int":0}}]}}
        \\]}}
    );
    try std.testing.expectEqual(@as(i64, 0), vm.oop.toInt(bad));
}

test "Random>>nextBoolean produces a fair-ish mix" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Rb2"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":7}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"BoolT"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":0}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"BoolF"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":0}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":200}},"selector":"timesRepeat:","args":[
        \\  {"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"Rb2"},"selector":"nextBoolean","args":[]}},"selector":"ifTrue:ifFalse:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\          {"send":{"receiver":{"literal":{"string":"BoolT"}},"selector":"asSymbol","args":[]}},
        \\          {"send":{"receiver":{"var_ref":"BoolT"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\        ]}}
        \\      ]}},
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\          {"send":{"receiver":{"literal":{"string":"BoolF"}},"selector":"asSymbol","args":[]}},
        \\          {"send":{"receiver":{"var_ref":"BoolF"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\        ]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}
        \\]}}
    );
    const t = try env.evalJson("{\"var_ref\":\"BoolT\"}");
    const f = try env.evalJson("{\"var_ref\":\"BoolF\"}");
    try std.testing.expect(vm.oop.toInt(t) > 50);
    try std.testing.expect(vm.oop.toInt(f) > 50);
}

test "Random new auto-seeds from clock and produces Floats in range" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const f = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Random"},"selector":"new","args":[]}},"selector":"next","args":[]}}
    );
    try std.testing.expect(vm.oop.isFloat(f));
    const v = vm.oop.toF64(f);
    try std.testing.expect(v >= 0.0 and v < 1.0);
}
