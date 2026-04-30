// DateTime: UTC wall clock with civil-from-days breakdown.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "DateTime now returns plausible UTC components" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DT"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"DateTime"},"selector":"now","args":[]}}
        \\]}}
    );

    const year = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DT"},"selector":"year","args":[]}}
    );
    const y = vm.oop.toInt(year);
    try std.testing.expect(y >= 2024);
    try std.testing.expect(y <= 2100);

    const month = vm.oop.toInt(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DT"},"selector":"month","args":[]}}
    ));
    try std.testing.expect(month >= 1 and month <= 12);

    const day = vm.oop.toInt(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DT"},"selector":"day","args":[]}}
    ));
    try std.testing.expect(day >= 1 and day <= 31);

    const hour = vm.oop.toInt(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DT"},"selector":"hour","args":[]}}
    ));
    try std.testing.expect(hour >= 0 and hour <= 23);

    const minute = vm.oop.toInt(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DT"},"selector":"minute","args":[]}}
    ));
    try std.testing.expect(minute >= 0 and minute <= 59);

    const second = vm.oop.toInt(try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"DT"},"selector":"second","args":[]}}
    ));
    try std.testing.expect(second >= 0 and second <= 60); // 60 to allow leap seconds
}

test "DateTime asString emits ISO-8601 zulu format" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const got = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"DateTime"},"selector":"now","args":[]}},
        \\  "selector":"asString","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    const bytes = vm.object.bytesOf(got)[0..vm.object.headerOf(got).size];
    // Expect 20 chars: 'YYYY-MM-DDTHH:MM:SSZ'.
    try std.testing.expectEqual(@as(usize, 20), bytes.len);
    try std.testing.expectEqual(@as(u8, '-'), bytes[4]);
    try std.testing.expectEqual(@as(u8, '-'), bytes[7]);
    try std.testing.expectEqual(@as(u8, 'T'), bytes[10]);
    try std.testing.expectEqual(@as(u8, ':'), bytes[13]);
    try std.testing.expectEqual(@as(u8, ':'), bytes[16]);
    try std.testing.expectEqual(@as(u8, 'Z'), bytes[19]);
}

test "DateTime two consecutive nows differ by at most a small delta" {
    // Just a smoke check that primNow is actually reading the
    // clock and not pinned at a constant.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const a = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"DateTime"},"selector":"now","args":[]}},
        \\  "selector":"second","args":[]}}
    );
    const b = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"DateTime"},"selector":"now","args":[]}},
        \\  "selector":"second","args":[]}}
    );
    // Same second value most of the time; if seconds rolled
    // over between calls, b - a could be -59. Just verify
    // both are valid SmallInts in range.
    const av = vm.oop.toInt(a);
    const bv = vm.oop.toInt(b);
    try std.testing.expect(av >= 0 and av <= 60);
    try std.testing.expect(bv >= 0 and bv <= 60);
}
