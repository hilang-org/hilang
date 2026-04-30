// JSON parse/stringify primitives. The std.json parser produces
// a Value tree that maps onto: nil/true/false → sentinels,
// numbers → SmallInt/Float, strings → String, arrays → Array,
// objects → Dictionary. asJson is the inverse: a recursive emit
// for any heap-or-tagged oop the VM understands.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "asJsonValue parses scalars" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const i = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"42"}},"selector":"asJsonValue","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 42), vm.oop.toInt(i));

    const t = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"true"}},"selector":"asJsonValue","args":[]}}
    );
    try std.testing.expectEqual(vm.oop.TRUE, t);

    const n = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"null"}},"selector":"asJsonValue","args":[]}}
    );
    try std.testing.expectEqual(vm.oop.NIL, n);

    const s = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"\"hello\""}},"selector":"asJsonValue","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(s));
    try std.testing.expectEqualStrings("hello", vm.object.bytesOf(s)[0..vm.object.headerOf(s).size]);
}

test "asJsonValue parses arrays into Array oops" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // '[1, 2, 3]' asJsonValue → an Array of three SmallInts.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"JArr"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"literal":{"string":"[1, 2, 3]"}},"selector":"asJsonValue","args":[]}}
        \\]}}
    );
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JArr"},"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.array_class, cls);
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JArr"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(sz));
    const e1 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JArr"},"selector":"at:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(e1));
    const e3 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JArr"},"selector":"at:","args":[{"literal":{"int":3}}]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(e3));
}

test "asJsonValue parses objects into Dictionary oops" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"JObj"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"literal":{"string":"{\"name\":\"Ada\",\"age\":42}"}},"selector":"asJsonValue","args":[]}}
        \\]}}
    );
    const cls = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JObj"},"selector":"class","args":[]}}
    );
    try std.testing.expectEqual(env.machine.globals.dictionary_class, cls);
    const name = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JObj"},"selector":"at:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"name"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    try std.testing.expectEqualStrings("Ada", vm.object.bytesOf(name)[0..vm.object.headerOf(name).size]);
    const age = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"JObj"},"selector":"at:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"age"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    try std.testing.expectEqual(@as(i64, 42), vm.oop.toInt(age));
}

test "malformed JSON raises PrimitiveFailed" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"{not valid"}},"selector":"asJsonValue","args":[]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}

test "asJson stringifies scalars" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const i = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":42}},"selector":"asJson","args":[]}}
    );
    try std.testing.expectEqualStrings("42", vm.object.bytesOf(i)[0..vm.object.headerOf(i).size]);

    const t = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"true":true}},"selector":"asJson","args":[]}}
    );
    try std.testing.expectEqualStrings("true", vm.object.bytesOf(t)[0..vm.object.headerOf(t).size]);

    const n = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"nil":true}},"selector":"asJson","args":[]}}
    );
    try std.testing.expectEqualStrings("null", vm.object.bytesOf(n)[0..vm.object.headerOf(n).size]);

    const s = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"hi"}},"selector":"asJson","args":[]}}
    );
    try std.testing.expectEqualStrings("\"hi\"", vm.object.bytesOf(s)[0..vm.object.headerOf(s).size]);
}

test "asJson escapes embedded quotes and backslashes" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Literal string `a"b\c` (3 chars: a, quote, b, backslash, c).
    // After asJson it should become `"a\"b\\c"` — 9 chars total.
    const got = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"string":"a\"b\\c"}},"selector":"asJson","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    try std.testing.expectEqualStrings(
        "\"a\\\"b\\\\c\"",
        vm.object.bytesOf(got)[0..vm.object.headerOf(got).size],
    );
}

test "JSON roundtrip via asJson + asJsonValue" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Build {x: [1, 2, [3, "four"]], y: nil}, stringify, parse, verify.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Orig"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Dictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    // Inner array: build via Array new: 4 + at:put:.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Inner"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"literal":{"int":2}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Inner"},"selector":"at:put:","args":[{"literal":{"int":1}},{"literal":{"int":3}}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Inner"},"selector":"at:put:","args":[{"literal":{"int":2}},{"literal":{"string":"four"}}]}}
    );
    // Outer: [1, 2, Inner].
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Outer"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"literal":{"int":3}}]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Outer"},"selector":"at:put:","args":[{"literal":{"int":1}},{"literal":{"int":1}}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Outer"},"selector":"at:put:","args":[{"literal":{"int":2}},{"literal":{"int":2}}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Outer"},"selector":"at:put:","args":[{"literal":{"int":3}},{"var_ref":"Inner"}]}}
    );
    // Orig at: 'x' put: Outer.  Orig at: 'y' put: nil.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Orig"},"selector":"at:put:","args":[{"literal":{"string":"x"}},{"var_ref":"Outer"}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Orig"},"selector":"at:put:","args":[{"literal":{"string":"y"}},{"literal":{"nil":true}}]}}
    );

    // Stringify, parse back, verify reachable values.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Round"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Orig"},"selector":"asJson","args":[]}},"selector":"asJsonValue","args":[]}}
        \\]}}
    );

    // Round at: 'x' at: 3 at: 2 = 'four'.
    const four = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Round"},"selector":"at:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"x"}},"selector":"asSymbol","args":[]}}
        \\]}},"selector":"at:","args":[{"literal":{"int":3}}]}},"selector":"at:","args":[{"literal":{"int":2}}]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(four));
    try std.testing.expectEqualStrings("four", vm.object.bytesOf(four)[0..vm.object.headerOf(four).size]);

    // Round at: 'y' = nil.
    const y = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Round"},"selector":"at:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"y"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    try std.testing.expectEqual(vm.oop.NIL, y);
}
