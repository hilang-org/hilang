// String API expansion: indexOf:, subStrings:, asUppercase,
// asLowercase, replaceAll:with:, trimmed, endsWith:. The pieces
// every text-handling LLM-authored program reaches for.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn evalString(env: *TestEnv, json: []const u8) !vm.Oop {
    return env.evalJson(json);
}

fn expectStr(o: vm.Oop, want: []const u8) !void {
    try std.testing.expect(vm.oop.isHeapPtr(o));
    try std.testing.expectEqualStrings(want, vm.object.bytesOf(o)[0..vm.object.headerOf(o).size]);
}

test "findString: returns 1-based position or 0" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const a = try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"hello world"}},"selector":"findString:","args":[{"literal":{"string":"world"}}]}}
    );
    try std.testing.expectEqual(@as(i64, 7), vm.oop.toInt(a));

    const b = try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"hello"}},"selector":"findString:","args":[{"literal":{"string":"xyz"}}]}}
    );
    try std.testing.expectEqual(@as(i64, 0), vm.oop.toInt(b));

    // Empty needle → 1.
    const c = try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"abc"}},"selector":"findString:","args":[{"literal":{"string":""}}]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(c));
}

test "asUppercase / asLowercase ASCII case map" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"Hello World!"}},"selector":"asUppercase","args":[]}}
    ), "HELLO WORLD!");
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"Hello World!"}},"selector":"asLowercase","args":[]}}
    ), "hello world!");
}

test "trimmed strips leading and trailing whitespace" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"  \t hello \n  "}},"selector":"trimmed","args":[]}}
    ), "hello");
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"no-trim"}},"selector":"trimmed","args":[]}}
    ), "no-trim");
}

test "replaceAll:with: substitutes every occurrence" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"foo bar foo baz foo"}},"selector":"replaceAll:with:","args":[
        \\  {"literal":{"string":"foo"}},{"literal":{"string":"<X>"}}
        \\]}}
    ), "<X> bar <X> baz <X>");
    // Replace with longer / shorter string.
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"aaaa"}},"selector":"replaceAll:with:","args":[
        \\  {"literal":{"string":"a"}},{"literal":{"string":"--"}}
        \\]}}
    ), "--------");
    // Empty old returns receiver unchanged.
    try expectStr(try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"abc"}},"selector":"replaceAll:with:","args":[
        \\  {"literal":{"string":""}},{"literal":{"string":"X"}}
        \\]}}
    ), "abc");
}

test "subStrings: splits on any delimiter character" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // 'a,b,,c' subStrings: ',' → ['a', 'b', 'c'] (empty dropped).
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"SS"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"literal":{"string":"a,b,,c"}},"selector":"subStrings:","args":[{"literal":{"string":","}}]}}
        \\]}}
    );
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SS"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(sz));
    try expectStr(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SS"},"selector":"at:","args":[{"literal":{"int":1}}]}}
    ), "a");
    try expectStr(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SS"},"selector":"at:","args":[{"literal":{"int":3}}]}}
    ), "c");

    // Multi-char delimiter: each char is a separator.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"WS"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"literal":{"string":"one two\tthree"}},"selector":"subStrings:","args":[{"literal":{"string":" \t"}}]}}
        \\]}}
    );
    const wsz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"WS"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(wsz));
}

test "endsWith: mirrors startsWith:" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    try std.testing.expectEqual(vm.oop.TRUE, try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"foobar"}},"selector":"endsWith:","args":[{"literal":{"string":"bar"}}]}}
    ));
    try std.testing.expectEqual(vm.oop.FALSE, try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"foobar"}},"selector":"endsWith:","args":[{"literal":{"string":"baz"}}]}}
    ));
    // Pattern longer than receiver — false, doesn't crash.
    try std.testing.expectEqual(vm.oop.FALSE, try evalString(&env,
        \\{"send":{"receiver":{"literal":{"string":"hi"}},"selector":"endsWith:","args":[{"literal":{"string":"hello"}}]}}
    ));
}
