// Exception-handling polish: ifCurtailed:, Exception>>pass,
// Exception>>resignalAs:. The on:do: / signal: / ensure: trio
// already shipped; this commit rounds out the rest of the
// Pharo-style protocol that LLM-authored programs reach for.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "ifCurtailed: runs handler on error and re-raises" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"CurtLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // [[Exception new signal: 'boom'] ifCurtailed: [CurtLog addLast: 'cleanup']]
    //   on: Exception do: [:e | CurtLog addLast: 'caught']
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"boom"}}]}}
        \\  ]}},"selector":"ifCurtailed:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"CurtLog"},"selector":"addLast:","args":[{"literal":{"string":"cleanup"}}]}}
        \\  ]}}]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"CurtLog"},"selector":"addLast:","args":[{"literal":{"string":"caught"}}]}}
        \\  ]}}
        \\]}}
    );

    // Cleanup ran first, then the outer handler.
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CurtLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(sz));
    const e0 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CurtLog"},"selector":"at:","args":[{"literal":{"int":1}}]}}
    );
    try std.testing.expectEqualStrings(
        "cleanup",
        vm.object.bytesOf(e0)[0..vm.object.headerOf(e0).size],
    );
    const e1 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CurtLog"},"selector":"at:","args":[{"literal":{"int":2}}]}}
    );
    try std.testing.expectEqualStrings(
        "caught",
        vm.object.bytesOf(e1)[0..vm.object.headerOf(e1).size],
    );
}

test "ifCurtailed: does NOT run handler on normal return" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"CurtLog2"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // [42] ifCurtailed: [CurtLog2 addLast: 'cleanup']
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[{"literal":{"int":42}}]}},
        \\  "selector":"ifCurtailed:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"CurtLog2"},"selector":"addLast:","args":[{"literal":{"string":"cleanup"}}]}}
        \\  ]}}]}}
    );

    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"CurtLog2"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 0), vm.oop.toInt(sz));
}

test "Exception>>pass propagates to outer handler" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"PassLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );

    // [
    //   [Exception new signal: 'inner']
    //     on: Exception do: [:e | PassLog addLast: 'inner-saw'. e pass]
    // ] on: Exception do: [:e | PassLog addLast: 'outer-saw']
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"inner"}}]}}
        \\  ]}},"selector":"on:do:","args":[
        \\    {"var_ref":"Exception"},
        \\    {"block":{"params":["e"],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"PassLog"},"selector":"addLast:","args":[{"literal":{"string":"inner-saw"}}]}},
        \\      {"send":{"receiver":{"var_ref":"e"},"selector":"pass","args":[]}}
        \\    ]}}
        \\  ]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"PassLog"},"selector":"addLast:","args":[{"literal":{"string":"outer-saw"}}]}}
        \\  ]}}
        \\]}}
    );

    // Both handlers fired, in order.
    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"PassLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(sz));
}

test "Exception>>retry re-runs the protected block" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Counter starts at 0; protected block increments and
    // raises when counter < 3, succeeds otherwise. Handler
    // calls retry. We expect the protected block to re-run
    // until counter reaches 3, at which point it returns.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"RC"}},"selector":"asSymbol","args":[]}},
        \\  {"literal":{"int":0}}
        \\]}}
    );
    const got = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\    {"send":{"receiver":{"literal":{"string":"RC"}},"selector":"asSymbol","args":[]}},
        \\    {"send":{"receiver":{"var_ref":"RC"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\  ]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"RC"},"selector":"<","args":[{"literal":{"int":3}}]}},"selector":"ifTrue:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"again"}}]}}
        \\    ]}}
        \\  ]}},
        \\  {"var_ref":"RC"}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"e"},"selector":"retry","args":[]}}
        \\  ]}}
        \\]}}
    );
    try std.testing.expectEqual(@as(i64, 3), vm.oop.toInt(got));
}

test "Exception>>resignalAs: replaces the in-flight exception" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // A custom Exception subclass so the outer handler can verify
    // resignalAs: replaced (not just augmented) the current exception.
    _ = try env.defineClass("WrappedExc", "Exception", &.{});

    // [
    //   [Exception new signal: 'lo']
    //     on: Exception do: [:e | e resignalAs: (WrappedExc new)]
    // ] on: Exception do: [:e | e isMemberOf: WrappedExc]
    const got = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"lo"}}]}}
        \\  ]}},"selector":"on:do:","args":[
        \\    {"var_ref":"Exception"},
        \\    {"block":{"params":["e"],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"e"},"selector":"resignalAs:","args":[
        \\        {"send":{"receiver":{"var_ref":"WrappedExc"},"selector":"new","args":[]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"e"},"selector":"isMemberOf:","args":[{"var_ref":"WrappedExc"}]}}
        \\  ]}}
        \\]}}
    );
    try std.testing.expectEqual(vm.oop.TRUE, got);
}
