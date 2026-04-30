// hilang microbenchmarks: fib (recursion), sum 1..N (whileTrue arith),
// Point alloc, empty whileTrue counter. Run in-process — no daemon, no
// socket roundtrip. Best-of-3 ms per leg.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness");

const TestEnv = harness.TestEnv;

const RUNS = 3;

fn out(comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    _ = std.posix.system.write(1, s.ptr, s.len);
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn timeBest(env: *TestEnv, label: []const u8, json: []const u8) !void {
    var times = [_]u64{0} ** RUNS;
    var last: vm.Oop = vm.oop.NIL;
    var i: u32 = 0;
    while (i < RUNS) : (i += 1) {
        try env.machine.collectGarbage();
        const t0 = nowNs();
        last = try env.evalJson(json);
        times[i] = nowNs() - t0;
    }
    var best: u64 = times[0];
    for (times) |t| best = @min(best, t);

    var print_buf: [64]u8 = undefined;
    const printed = harness.printString(env, last, &print_buf) catch "?";
    try out("  {s}: best {d:>8.3} ms  (runs:", .{ label, @as(f64, @floatFromInt(best)) / 1e6 });
    for (times) |t| try out(" {d:.1}", .{@as(f64, @floatFromInt(t)) / 1e6});
    try out(")  → {s}\n", .{printed});
}

pub fn main() !void {
    var env: TestEnv = undefined;
    try env.initWithHeap(256 * 1024 * 1024);
    defer env.deinit();

    try out("== hilang microbenchmarks ==\n\n", .{});

    // Recursive fibonacci on SmallInteger as an AST method.
    //   fib: ^ self < 2 ifTrue: [self] ifFalse: [(self-1) fib + (self-2) fib]
    try env.installMethod("SmallInteger", "fib", &.{}, &.{},
        \\[
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"<","args":[{"literal":{"int":2}}]}},
        \\          "selector":"ifTrue:ifFalse:","args":[
        \\            {"block":{"params":[],"temps":[],"body":[{"var_ref":"self"}]}},
        \\            {"block":{"params":[],"temps":[],"body":[
        \\              {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":1}}]}},"selector":"fib","args":[]}},
        \\                       "selector":"+","args":[
        \\                         {"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":2}}]}},"selector":"fib","args":[]}}
        \\                       ]}}
        \\            ]}}
        \\          ]}}}
        \\]
    );
    try out("Recursive fibonacci (AST method, full message dispatch each call):\n", .{});
    inline for ([_]i64{ 10, 15, 20, 25, 30 }) |n| {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "fib({d})", .{n});
        var expr_buf: [256]u8 = undefined;
        const expr = try std.fmt.bufPrint(&expr_buf,
            "{{\"send\":{{\"receiver\":{{\"literal\":{{\"int\":{d}}}}},\"selector\":\"fib\",\"args\":[]}}}}", .{n});
        try timeBest(&env, label, expr);
    }
    try out("\n", .{});

    // Sum 1..N: tight integer whileTrue: with two assignments per iter.
    try out("Sum 1..N (whileTrue: with two assignments per iteration):\n", .{});
    inline for ([_]i64{ 1_000, 10_000, 100_000, 1_000_000 }) |n| {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "sum 1..{d}", .{n});
        var expr_buf: [1024]u8 = undefined;
        const expr = try std.fmt.bufPrint(&expr_buf,
            \\{{"seq":[
            \\  {{"assign":{{"name":"i","value":{{"literal":{{"int":0}}}}}}}},
            \\  {{"assign":{{"name":"s","value":{{"literal":{{"int":0}}}}}}}},
            \\  {{"send":{{"receiver":{{"block":{{"params":[],"temps":[],"body":[
            \\    {{"send":{{"receiver":{{"var_ref":"i"}},"selector":"<","args":[{{"literal":{{"int":{d}}}}}]}}}}
            \\  ]}}}},"selector":"whileTrue:","args":[{{"block":{{"params":[],"temps":[],"body":[
            \\    {{"assign":{{"name":"i","value":{{"send":{{"receiver":{{"var_ref":"i"}},"selector":"+","args":[{{"literal":{{"int":1}}}}]}}}}}}}},
            \\    {{"assign":{{"name":"s","value":{{"send":{{"receiver":{{"var_ref":"s"}},"selector":"+","args":[{{"var_ref":"i"}}]}}}}}}}}
            \\  ]}}}}]}}}},
            \\  {{"var_ref":"s"}}
            \\]}}
        , .{n});
        try timeBest(&env, label, expr);
    }
    try out("\n", .{});

    // Object allocation: Point new in a loop.
    _ = try env.defineClass("Point", "Object", &.{ "x", "y" });
    try env.installMethod("SmallInteger", "allocPoints", &.{}, &.{ "i", "p" },
        \\[
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"p","value":{"send":{"receiver":{"var_ref":"Point"},"selector":"new","args":[]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"var_ref":"self"}
        \\]
    );
    try out("Object allocation (Point new in a loop):\n", .{});
    inline for ([_]i64{ 1_000, 10_000, 100_000, 1_000_000 }) |n| {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "alloc {d} Points", .{n});
        var expr_buf: [256]u8 = undefined;
        const expr = try std.fmt.bufPrint(&expr_buf,
            "{{\"send\":{{\"receiver\":{{\"literal\":{{\"int\":{d}}}}},\"selector\":\"allocPoints\",\"args\":[]}}}}", .{n});
        try timeBest(&env, label, expr);
    }
    try out("\n", .{});

    // Empty whileTrue: — pure dispatch + counter.
    try out("Empty whileTrue: (pure dispatch + counter):\n", .{});
    inline for ([_]i64{ 1_000, 10_000, 100_000, 1_000_000 }) |n| {
        var label_buf: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "count to {d}", .{n});
        var expr_buf: [1024]u8 = undefined;
        const expr = try std.fmt.bufPrint(&expr_buf,
            \\{{"seq":[
            \\  {{"assign":{{"name":"i","value":{{"literal":{{"int":0}}}}}}}},
            \\  {{"send":{{"receiver":{{"block":{{"params":[],"temps":[],"body":[
            \\    {{"send":{{"receiver":{{"var_ref":"i"}},"selector":"<","args":[{{"literal":{{"int":{d}}}}}]}}}}
            \\  ]}}}},"selector":"whileTrue:","args":[{{"block":{{"params":[],"temps":[],"body":[
            \\    {{"assign":{{"name":"i","value":{{"send":{{"receiver":{{"var_ref":"i"}},"selector":"+","args":[{{"literal":{{"int":1}}}}]}}}}}}}}
            \\  ]}}}}]}}}},
            \\  {{"var_ref":"i"}}
            \\]}}
        , .{n});
        try timeBest(&env, label, expr);
    }
}
