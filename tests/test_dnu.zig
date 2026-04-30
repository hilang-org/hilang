// doesNotUnderstand: dispatch tests. Pre-fix, sending an unknown
// selector raised a Zig EvalError and unwound out of the
// interpreter. Post-fix, the slow-path lookup reifies a Message
// and dispatches `doesNotUnderstand:` against the receiver,
// letting Smalltalk code recover, proxy, or override.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "default doesNotUnderstand: signals a catchable Exception" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // [1 wibble: 2] on: Exception do: [:e | e messageText]
    // The default Object>>doesNotUnderstand: signals an Exception
    // whose text starts with 'doesNotUnderstand: '.
    const got = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"literal":{"int":1}},"selector":"wibble:","args":[{"literal":{"int":2}}]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"e"},"selector":"messageText","args":[]}}
        \\  ]}}
        \\]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    const bytes = vm.object.bytesOf(got)[0..vm.object.headerOf(got).size];
    const expected = "doesNotUnderstand: wibble:";
    try std.testing.expect(std.mem.startsWith(u8, bytes, expected));
}

test "doesNotUnderstand: receives the failed selector and arguments" {
    // Override doesNotUnderstand: on a fresh subclass to stash the
    // Message into a global so the test can inspect both fields.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // class DnuProbe ivars=()  (extends Object).
    _ = try env.defineClass("DnuProbe", "Object", &.{});

    // DnuProbe>>doesNotUnderstand: m  Smalltalk at: #LastDnu put: m. ^nil
    try env.installMethod(
        "DnuProbe",
        "doesNotUnderstand:",
        &.{"m"},
        &.{},
        \\[
        \\  {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\    {"send":{"receiver":{"literal":{"string":"LastDnu"}},"selector":"asSymbol","args":[]}},
        \\    {"var_ref":"m"}
        \\  ]}},
        \\  {"ret":{"literal":{"nil":true}}}
        \\]
    );

    // (DnuProbe new) frob: 7 baz: 'q'
    _ = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"DnuProbe"},"selector":"new","args":[]}},
        \\"selector":"frob:baz:","args":[{"literal":{"int":7}},{"literal":{"string":"q"}}]}}
    );

    // LastDnu selector → #frob:baz:
    const sel = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"LastDnu"},"selector":"selector","args":[]}},
        \\  "selector":"asString","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(sel));
    const sel_bytes = vm.object.bytesOf(sel)[0..vm.object.headerOf(sel).size];
    try std.testing.expectEqualStrings("frob:baz:", sel_bytes);

    // LastDnu arguments size = 2
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"LastDnu"},"selector":"arguments","args":[]}},
        \\  "selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(sz));

    // LastDnu arguments at: 1 = 7
    const a0 = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"LastDnu"},"selector":"arguments","args":[]}},
        \\  "selector":"at:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqual(@as(i64, 7), vm.oop.toInt(a0));

    // LastDnu arguments at: 2 = 'q'
    const a1 = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"LastDnu"},"selector":"arguments","args":[]}},
        \\  "selector":"at:","args":[{"literal":{"int":2}}]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(a1));
    try std.testing.expectEqualStrings("q", vm.object.bytesOf(a1)[0..vm.object.headerOf(a1).size]);
}

test "Subclass override of doesNotUnderstand: changes dispatch behaviour" {
    // A Counter that catches every unknown send and increments
    // an internal tally — a stand-in for any DNU-driven dispatch
    // table. Demonstrates that the override actually replaces the
    // default Object>>doesNotUnderstand: rather than running both.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.defineClass("DnuCounter", "Object", &.{"n"});

    try env.installMethod("DnuCounter", "init", &.{}, &.{},
        \\[
        \\  {"assign":{"name":"n","value":{"literal":{"int":0}}}},
        \\  {"ret":{"var_ref":"self"}}
        \\]
    );
    try env.installMethod("DnuCounter", "count", &.{}, &.{},
        \\[
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );

    // DnuCounter>>doesNotUnderstand: m  n := n + 1. ^n
    try env.installMethod("DnuCounter", "doesNotUnderstand:", &.{"m"}, &.{},
        \\[
        \\  {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[{"literal":{"int":1}}]}}}},
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );

    // Stash a fresh DnuCounter so the same instance receives all four sends.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DC"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"DnuCounter"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"DC\"},\"selector\":\"foo\",\"args\":[]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"DC\"},\"selector\":\"bar\",\"args\":[]}}");
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DC"},"selector":"baz:","args":[{"literal":{"int":99}}]}}
    );

    const got = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DC"},"selector":"count","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(got));
}
