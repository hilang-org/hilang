// Reflection primitives: instVarAt:, instVarAt:put:, isMemberOf:,
// Behavior>>instVarNames. The combination is enough to write a
// generic serializer / deep-copy / structural equality.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "instVarAt: reads slots in declaration order (1-based)" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.defineClass("Point", "Object", &.{ "x", "y" });
    try env.installMethod("Point", "x:y:", &.{ "ax", "ay" }, &.{},
        \\[
        \\  {"assign":{"name":"x","value":{"var_ref":"ax"}}},
        \\  {"assign":{"name":"y","value":{"var_ref":"ay"}}},
        \\  {"ret":{"var_ref":"self"}}
        \\]
    );

    // (Point new x: 7 y: 11) instVarAt: 1  → 7
    const x = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Point"},"selector":"new","args":[]}},
        \\  "selector":"x:y:","args":[{"literal":{"int":7}},{"literal":{"int":11}}]}},
        \\  "selector":"instVarAt:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqual(@as(i64, 7), vm.oop.toInt(x));

    const y = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Point"},"selector":"new","args":[]}},
        \\  "selector":"x:y:","args":[{"literal":{"int":7}},{"literal":{"int":11}}]}},
        \\  "selector":"instVarAt:","args":[{"literal":{"int":2}}]}}
    );
    try std.testing.expectEqual(@as(i64, 11), vm.oop.toInt(y));
}

test "instVarAt:put: writes a slot and returns the new value" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.defineClass("Holder", "Object", &.{"v"});

    // Stash a fresh Holder, then mutate its first ivar.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"H"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Holder"},"selector":"new","args":[]}}
        \\]}}
    );
    const stored = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"H"},"selector":"instVarAt:put:","args":[
        \\  {"literal":{"int":1}},{"literal":{"int":42}}
        \\]}}
    );
    try std.testing.expectEqual(@as(i64, 42), vm.oop.toInt(stored));
    const back = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"H"},"selector":"instVarAt:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqual(@as(i64, 42), vm.oop.toInt(back));
}

test "instVarAt: on byte-objects yields integer bytes" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // 'AB' instVarAt: 1  →  65 (ASCII 'A')
    const got = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"AB"}},"selector":"instVarAt:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqual(@as(i64, 65), vm.oop.toInt(got));
    const got2 = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"AB"}},"selector":"instVarAt:","args":[{"literal":{"int":2}}]}}
    );
    try std.testing.expectEqual(@as(i64, 66), vm.oop.toInt(got2));
}

test "instVarAt: out of range raises PrimitiveFailed" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.defineClass("OneSlot", "Object", &.{"v"});
    const result = env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"OneSlot"},"selector":"new","args":[]}},
        \\  "selector":"instVarAt:","args":[{"literal":{"int":5}}]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}

test "isMemberOf: requires exact class (unlike isKindOf:)" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.defineClass("Animal", "Object", &.{});
    _ = try env.defineClass("Dog", "Animal", &.{});

    // (Dog new) isKindOf: Animal  → true
    const k = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Dog"},"selector":"new","args":[]}},
        \\  "selector":"isKindOf:","args":[{"var_ref":"Animal"}]}}
    );
    try std.testing.expectEqual(vm.oop.TRUE, k);

    // (Dog new) isMemberOf: Animal  → false (subclass, not exact)
    const m = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Dog"},"selector":"new","args":[]}},
        \\  "selector":"isMemberOf:","args":[{"var_ref":"Animal"}]}}
    );
    try std.testing.expectEqual(vm.oop.FALSE, m);

    // (Dog new) isMemberOf: Dog  → true
    const m2 = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Dog"},"selector":"new","args":[]}},
        \\  "selector":"isMemberOf:","args":[{"var_ref":"Dog"}]}}
    );
    try std.testing.expectEqual(vm.oop.TRUE, m2);
}

test "Behavior>>instVarNames returns symbols in declaration order" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.defineClass("Triplet", "Object", &.{ "a", "b", "c" });

    const sz = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Triplet"},"selector":"instVarNames","args":[]}},
        \\  "selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(sz));

    // First name is #a
    const first = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Triplet"},"selector":"instVarNames","args":[]}},
        \\  "selector":"at:","args":[{"literal":{"int":1}}]}},"selector":"asString","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(first));
    try std.testing.expectEqualStrings(
        "a",
        vm.object.bytesOf(first)[0..vm.object.headerOf(first).size],
    );
}

test "instVarAt: + instVarNames are sufficient for a generic copier" {
    // Use the reflection surface to build a deep-ish copier
    // entirely from Smalltalk: walk instVarNames, copy each
    // slot via instVarAt:/put:. Demonstrates the practical
    // payoff of this commit.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.defineClass("Pair", "Object", &.{ "fst", "snd" });
    try env.installMethod("Pair", "fst:snd:", &.{ "f", "s" }, &.{},
        \\[
        \\  {"assign":{"name":"fst","value":{"var_ref":"f"}}},
        \\  {"assign":{"name":"snd","value":{"var_ref":"s"}}},
        \\  {"ret":{"var_ref":"self"}}
        \\]
    );

    // Object>>shallowCopy
    //   | c |
    //   c := self class new.
    //   1 to: self class instVarNames size do:
    //     [:i | c instVarAt: i put: (self instVarAt: i)].
    //   ^c
    try env.installMethod("Object", "shallowCopy", &.{}, &.{"c"},
        \\[
        \\  {"assign":{"name":"c","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"class","args":[]}},"selector":"new","args":[]}}}},
        \\  {"send":{"receiver":{"literal":{"int":1}},"selector":"to:do:","args":[
        \\    {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"class","args":[]}},"selector":"instVarNames","args":[]}},"selector":"size","args":[]}},
        \\    {"block":{"params":["i"],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"c"},"selector":"instVarAt:put:","args":[
        \\        {"var_ref":"i"},
        \\        {"send":{"receiver":{"var_ref":"self"},"selector":"instVarAt:","args":[{"var_ref":"i"}]}}
        \\      ]}}
        \\    ]}}
        \\  ]}},
        \\  {"ret":{"var_ref":"c"}}
        \\]
    );

    // Stash a copy and inspect its slots.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Q"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Pair"},"selector":"new","args":[]}},
        \\    "selector":"fst:snd:","args":[{"literal":{"int":7}},{"literal":{"string":"hi"}}]}},"selector":"shallowCopy","args":[]}}
        \\]}}
    );

    const a = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Q"},"selector":"instVarAt:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqual(@as(i64, 7), vm.oop.toInt(a));

    const b = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Q"},"selector":"instVarAt:","args":[{"literal":{"int":2}}]}},
        \\  "selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(b));
}
