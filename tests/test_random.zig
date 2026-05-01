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

test "Array shuffle: with deterministic Random produces a permutation" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Build [1, 2, 3, 4, 5] in an Array, shuffle deterministically,
    // verify that every element 1..5 still appears exactly once.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Sa"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"literal":{"int":5}}]}}
        \\]}}
    );
    const fill_indices = [_]i64{ 1, 2, 3, 4, 5 };
    for (fill_indices, 1..) |v, i| {
        var buf: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"Sa\"}},\"selector\":\"at:put:\",\"args\":[{{\"literal\":{{\"int\":{}}}}},{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{ i, v },
        );
        _ = try env.evalJson(json);
    }
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Sa"},"selector":"shuffle:","args":[
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":42}}]}}
        \\]}}
    );

    // Sum after shuffle is still 15 (1+2+3+4+5).
    const sum = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Sa"},"selector":"sum","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 15), vm.oop.toInt(sum));
    // Size unchanged.
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Sa"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 5), vm.oop.toInt(sz));
    // All five values still present (unique).
    var seen: [6]bool = .{false} ** 6;
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        var buf: [192]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"Sa\"}},\"selector\":\"at:\",\"args\":[{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{i},
        );
        const v = vm.oop.toInt(try env.evalJson(json));
        try std.testing.expect(v >= 1 and v <= 5 and !seen[@intCast(v)]);
        seen[@intCast(v)] = true;
    }
}

test "shuffle: with same seed is deterministic" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Two arrays seeded identically must end up identical post-shuffle.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Sb"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"literal":{"int":4}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Sc"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"literal":{"int":4}}]}}
        \\]}}
    );
    var k: i64 = 1;
    while (k <= 4) : (k += 1) {
        var buf1: [192]u8 = undefined;
        var buf2: [192]u8 = undefined;
        _ = try env.evalJson(try std.fmt.bufPrint(&buf1,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"Sb\"}},\"selector\":\"at:put:\",\"args\":[{{\"literal\":{{\"int\":{}}}}},{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{ k, k * 10 },
        ));
        _ = try env.evalJson(try std.fmt.bufPrint(&buf2,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"Sc\"}},\"selector\":\"at:put:\",\"args\":[{{\"literal\":{{\"int\":{}}}}},{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{ k, k * 10 },
        ));
    }
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Sb"},"selector":"shuffle:","args":[
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":1}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Sc"},"selector":"shuffle:","args":[
        \\  {"send":{"receiver":{"var_ref":"Random"},"selector":"seed:","args":[{"literal":{"int":1}}]}}
        \\]}}
    );
    var i: i64 = 1;
    while (i <= 4) : (i += 1) {
        var bufA: [192]u8 = undefined;
        var bufB: [192]u8 = undefined;
        const a = try env.evalJson(try std.fmt.bufPrint(&bufA,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"Sb\"}},\"selector\":\"at:\",\"args\":[{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{i},
        ));
        const b = try env.evalJson(try std.fmt.bufPrint(&bufB,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"Sc\"}},\"selector\":\"at:\",\"args\":[{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{i},
        ));
        try std.testing.expectEqual(vm.oop.toInt(a), vm.oop.toInt(b));
    }
}

test "sample: returns an element from the receiver" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Sd"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"literal":{"int":3}}]}}
        \\]}}
    );
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Sd\"},\"selector\":\"at:put:\",\"args\":[{\"literal\":{\"int\":1}},{\"literal\":{\"int\":10}}]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Sd\"},\"selector\":\"at:put:\",\"args\":[{\"literal\":{\"int\":2}},{\"literal\":{\"int\":20}}]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Sd\"},\"selector\":\"at:put:\",\"args\":[{\"literal\":{\"int\":3}},{\"literal\":{\"int\":30}}]}}");
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        const v = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"Sd"},"selector":"sample","args":[]}}
        );
        const n = vm.oop.toInt(v);
        try std.testing.expect(n == 10 or n == 20 or n == 30);
    }
}

test "sample on empty signals an Exception" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const got = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}},"selector":"sample","args":[]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"e"},"selector":"messageText","args":[]}}
        \\  ]}}
        \\]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    try std.testing.expectEqualStrings(
        "sample: empty collection",
        vm.object.bytesOf(got)[0..vm.object.headerOf(got).size],
    );
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
