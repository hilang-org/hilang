// SortedCollection / IdentityDictionary / IdentitySet — round
// out the collection cluster with the variants Pharo offers.
// SortedCollection maintains sorted order on add:; the Identity*
// variants compare keys with == instead of =.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "SortedCollection maintains ascending order across mixed adds" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // | sc |
    // sc := SortedCollection new init.
    // #(3 1 4 1 5 9 2 6) do: [:x | sc add: x].
    // ^sc
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"SC"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"SortedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    const inputs = [_]i64{ 3, 1, 4, 1, 5, 9, 2, 6 };
    for (inputs) |x| {
        var buf: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"SC\"}},\"selector\":\"add:\",\"args\":[{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{x},
        );
        _ = try env.evalJson(json);
    }
    // Expected sorted: 1 1 2 3 4 5 6 9.
    const expected = [_]i64{ 1, 1, 2, 3, 4, 5, 6, 9 };
    for (expected, 1..) |want, i| {
        var buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf,
            "{{\"send\":{{\"receiver\":{{\"var_ref\":\"SC\"}},\"selector\":\"at:\",\"args\":[{{\"literal\":{{\"int\":{}}}}}]}}}}",
            .{i},
        );
        const got = try env.evalJson(json);
        try std.testing.expectEqual(want, vm.oop.toInt(got));
    }
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SC"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 8), vm.oop.toInt(sz));
}

test "IdentityDictionary keys compare by identity, not equality" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Build two String keys with the same bytes but different oops.
    // For a regular Dictionary, 'k' = 'k' would conflate them; for
    // IdentityDictionary the second insert is a separate entry.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IDA"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"string":"k"}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IDB"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"string":"k"}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IDD"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"IdentityDictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD"},"selector":"at:put:","args":[{"var_ref":"IDA"},{"literal":{"int":1}}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD"},"selector":"at:put:","args":[{"var_ref":"IDB"},{"literal":{"int":2}}]}}
    );

    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(sz));

    const a = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD"},"selector":"at:","args":[{"var_ref":"IDA"}]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(a));
    const b = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD"},"selector":"at:","args":[{"var_ref":"IDB"}]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(b));
}

test "IdentityDictionary at:put: replaces value when key oop matches" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IDD2"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"IdentityDictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD2"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"key"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":10}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD2"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"key"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":20}}
        \\]}}
    );
    // Symbols are interned so #key == #key — second put overwrites.
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD2"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(sz));
    const got = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IDD2"},"selector":"at:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"key"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    try std.testing.expectEqual(@as(i64, 20), vm.oop.toInt(got));
}

test "IdentityDictionary at:ifAbsent: routes to the absent block" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const got = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"IdentityDictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}},
        \\  "selector":"at:ifAbsent:","args":[
        \\    {"send":{"receiver":{"literal":{"string":"missing"}},"selector":"asSymbol","args":[]}},
        \\    {"block":{"params":[],"temps":[],"body":[{"literal":{"int":99}}]}}
        \\  ]}}
    );
    try std.testing.expectEqual(@as(i64, 99), vm.oop.toInt(got));
}

test "IdentitySet add: is idempotent on identical oops" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"ISS"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"IdentitySet"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    // Same Symbol oop added 3x.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ISS"},"selector":"add:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"a"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ISS"},"selector":"add:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"a"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ISS"},"selector":"add:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"b"}},"selector":"asSymbol","args":[]}}
        \\]}}
    );
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"ISS"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(sz));
}

test "IdentitySet includes: matches by identity" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"K1"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"string":"k"}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"K2"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"string":"k"}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"S2"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"IdentitySet"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"S2"},"selector":"add:","args":[{"var_ref":"K1"}]}}
    );
    const has1 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"S2"},"selector":"includes:","args":[{"var_ref":"K1"}]}}
    );
    try std.testing.expectEqual(vm.oop.TRUE, has1);
    // K2 has the same bytes but is a different oop; identity says no.
    const has2 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"S2"},"selector":"includes:","args":[{"var_ref":"K2"}]}}
    );
    try std.testing.expectEqual(vm.oop.FALSE, has2);
}

test "Dictionary>>keys returns just the live keys, sized correctly" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DK"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Dictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DK"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"a"}},"selector":"asSymbol","args":[]}},{"literal":{"int":1}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DK"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"b"}},"selector":"asSymbol","args":[]}},{"literal":{"int":2}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DK"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"c"}},"selector":"asSymbol","args":[]}},{"literal":{"int":3}}
        \\]}}
    );
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"DK"},"selector":"keys","args":[]}},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(sz));
}

test "Dictionary>>values returns just the live values" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DV"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"Dictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DV"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"a"}},"selector":"asSymbol","args":[]}},{"literal":{"int":10}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DV"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"b"}},"selector":"asSymbol","args":[]}},{"literal":{"int":20}}
        \\]}}
    );
    // values sum = 30.
    const sum = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"DV"},"selector":"values","args":[]}},"selector":"sum","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 30), vm.oop.toInt(sum));
}
