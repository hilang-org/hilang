// hilang extended benchmark suite. Mirrors bench/suite.py: covers
// recursion variants, collection pipelines, strings, LargeInteger
// math, GC pressure, polymorphic dispatch, backtracking, exceptions,
// and Float-only loops. Runs in-process (no daemon, no socket).
//
// Each category restarts the VM (fresh heap + bootstrap) so per-leg
// state stays isolated, mirroring the Python driver's per-category
// daemon respawn.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness");

const TestEnv = harness.TestEnv;

const RUNS = 3;
const HEAP_BYTES: usize = 512 * 1024 * 1024;

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
    var failed = false;
    var i: u32 = 0;
    while (i < RUNS) : (i += 1) {
        env.machine.collectGarbage() catch {};
        const t0 = nowNs();
        last = env.evalJson(json) catch |e| {
            try out("  {s}: SKIP ({s})\n", .{ label, @errorName(e) });
            failed = true;
            break;
        };
        times[i] = nowNs() - t0;
    }
    if (failed) return;
    var best: u64 = times[0];
    for (times) |t| best = @min(best, t);

    var print_buf: [128]u8 = undefined;
    const printed = harness.printString(env, last, &print_buf) catch "?";
    try out("  {s}: best {d:>8.3} ms  (runs:", .{ label, @as(f64, @floatFromInt(best)) / 1e6 });
    for (times) |t| try out(" {d:.1}", .{@as(f64, @floatFromInt(t)) / 1e6});
    try out(")  → {s}\n", .{printed});
}

fn freshEnv(env: *TestEnv) !void {
    env.deinit();
    try env.initWithHeap(HEAP_BYTES);
}

// ──────────────────────────────────────────────────────────────────────
// A. Recursion shapes
// ──────────────────────────────────────────────────────────────────────
fn categoryRecursion(env: *TestEnv) !void {
    try out("Recursion shapes:\n", .{});

    // ackermann(m, n)
    try env.installMethod("SmallInteger", "ackermann:", &.{"n"}, &.{},
        \\[
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"=","args":[{"literal":{"int":0}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\    ]}},
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"n"},"selector":"=","args":[{"literal":{"int":0}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\        {"block":{"params":[],"temps":[],"body":[
        \\          {"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":1}}]}},"selector":"ackermann:","args":[{"literal":{"int":1}}]}}
        \\        ]}},
        \\        {"block":{"params":[],"temps":[],"body":[
        \\          {"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":1}}]}},"selector":"ackermann:","args":[
        \\            {"send":{"receiver":{"var_ref":"self"},"selector":"ackermann:","args":[
        \\              {"send":{"receiver":{"var_ref":"n"},"selector":"-","args":[{"literal":{"int":1}}]}}
        \\            ]}}
        \\          ]}}
        \\        ]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}}
        \\]
    );
    try timeBest(env, "ackermann(3, 6)         ",
        \\{"send":{"receiver":{"literal":{"int":3}},"selector":"ackermann:","args":[{"literal":{"int":6}}]}}
    );

    // Mutual recursion via isEvenSlow / isOddSlow
    try env.installMethod("SmallInteger", "isEvenSlow", &.{}, &.{},
        \\[
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"=","args":[{"literal":{"int":0}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[{"literal":{"true":true}}]}},
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":1}}]}},"selector":"isOddSlow","args":[]}}
        \\    ]}}
        \\  ]}}}
        \\]
    );
    try env.installMethod("SmallInteger", "isOddSlow", &.{}, &.{},
        \\[
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"=","args":[{"literal":{"int":0}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[{"literal":{"false":true}}]}},
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":1}}]}},"selector":"isEvenSlow","args":[]}}
        \\    ]}}
        \\  ]}}}
        \\]
    );
    try timeBest(env, "isEven/isOdd 1000       ",
        \\{"send":{"receiver":{"literal":{"int":1000}},"selector":"isEvenSlow","args":[]}}
    );

    // Tree-sum: balanced binary tree depth=15.
    _ = try env.defineClass("Node", "Object", &.{ "v", "left", "right" });
    try env.installMethod("Node", "setV:left:right:", &.{ "aV", "aL", "aR" }, &.{},
        \\[
        \\  {"assign":{"name":"v","value":{"var_ref":"aV"}}},
        \\  {"assign":{"name":"left","value":{"var_ref":"aL"}}},
        \\  {"assign":{"name":"right","value":{"var_ref":"aR"}}},
        \\  {"ret":{"var_ref":"self"}}
        \\]
    );
    try env.installMethod("Node", "isLeaf", &.{}, &.{},
        \\[{"ret":{"send":{"receiver":{"var_ref":"left"},"selector":"isNil","args":[]}}}]
    );
    try env.installMethod("Node", "sum", &.{}, &.{},
        \\[
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"isLeaf","args":[]}},"selector":"ifTrue:ifFalse:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[{"var_ref":"v"}]}},
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"left"},"selector":"sum","args":[]}},"selector":"+","args":[
        \\        {"send":{"receiver":{"var_ref":"right"},"selector":"sum","args":[]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}}
        \\]
    );
    try env.installMethod("SmallInteger", "buildTree", &.{}, &.{"n"},
        \\[
        \\  {"ret":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"=","args":[{"literal":{"int":0}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"Node"},"selector":"new","args":[]}},"selector":"setV:left:right:","args":[
        \\        {"literal":{"int":1}},{"literal":{"nil":true}},{"literal":{"nil":true}}
        \\      ]}}
        \\    ]}},
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"self"},"selector":"-","args":[{"literal":{"int":1}}]}}}},
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"Node"},"selector":"new","args":[]}},"selector":"setV:left:right:","args":[
        \\        {"literal":{"int":0}},
        \\        {"send":{"receiver":{"var_ref":"n"},"selector":"buildTree","args":[]}},
        \\        {"send":{"receiver":{"var_ref":"n"},"selector":"buildTree","args":[]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}}
        \\]
    );
    try env.installMethod("Object", "isNil", &.{}, &.{}, "[{\"ret\":{\"literal\":{\"false\":true}}}]");
    try env.installMethod("UndefinedObject", "isNil", &.{}, &.{}, "[{\"ret\":{\"literal\":{\"true\":true}}}]");
    try timeBest(env, "tree-sum depth=15       ",
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":15}},"selector":"buildTree","args":[]}},"selector":"sum","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// B. Collection pipelines
// ──────────────────────────────────────────────────────────────────────
fn categoryCollections(env: *TestEnv) !void {
    try out("\nCollection pipelines:\n", .{});

    try timeBest(env, "Interval inject 100k    ",
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"to:","args":[{"literal":{"int":100000}}]}},"selector":"inject:into:","args":[
        \\  {"literal":{"int":0}},
        \\  {"block":{"params":["acc","n"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"acc"},"selector":"+","args":[{"var_ref":"n"}]}}
        \\  ]}}
        \\]}},"selector":"+","args":[{"literal":{"int":0}}]}}
    );

    try timeBest(env, "collect/select/inject   ",
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"to:","args":[{"literal":{"int":10000}}]}},"selector":"collect:","args":[
        \\  {"block":{"params":["n"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"n"},"selector":"*","args":[{"var_ref":"n"}]}}
        \\  ]}}
        \\]}},"selector":"select:","args":[
        \\  {"block":{"params":["n"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"n"},"selector":"even","args":[]}}
        \\  ]}}
        \\]}},"selector":"inject:into:","args":[
        \\  {"literal":{"int":0}},
        \\  {"block":{"params":["acc","n"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"acc"},"selector":"+","args":[{"var_ref":"n"}]}}
        \\  ]}}
        \\]}}
    );

    try env.installMethod("SmallInteger", "ocChurn", &.{}, &.{ "oc", "i" },
        \\[
        \\  {"assign":{"name":"oc","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"oc"},"selector":"addLast:","args":[{"var_ref":"i"}]}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"oc"},"selector":"removeFirst","args":[]}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"send":{"receiver":{"var_ref":"oc"},"selector":"size","args":[]}}}
        \\]
    );
    try timeBest(env, "OC add/removeFirst 10k  ",
        \\{"send":{"receiver":{"literal":{"int":10000}},"selector":"ocChurn","args":[]}}
    );

    try env.installMethod("SmallInteger", "dictChurn", &.{}, &.{ "d", "i" },
        \\[
        \\  {"assign":{"name":"d","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Dictionary"},"selector":"new","args":[]}},"selector":"init","args":[]}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"d"},"selector":"at:put:","args":[
        \\      {"var_ref":"i"},
        \\      {"send":{"receiver":{"var_ref":"i"},"selector":"*","args":[{"literal":{"int":2}}]}}
        \\    ]}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"d"},"selector":"at:","args":[{"var_ref":"i"}]}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"send":{"receiver":{"var_ref":"d"},"selector":"size","args":[]}}}
        \\]
    );
    try timeBest(env, "Dict 5k put + 5k get    ",
        \\{"send":{"receiver":{"literal":{"int":5000}},"selector":"dictChurn","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// C. String workloads
// ──────────────────────────────────────────────────────────────────────
fn categoryStrings(env: *TestEnv) !void {
    try out("\nString workloads:\n", .{});

    // Quadratic concat: 500 iterations of s := s , 'abc'.
    try env.installMethod("SmallInteger", "concatLoop", &.{}, &.{ "s", "i" },
        \\[
        \\  {"assign":{"name":"s","value":{"literal":{"string":""}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"s","value":{"send":{"receiver":{"var_ref":"s"},"selector":",","args":[{"literal":{"string":"abc"}}]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"send":{"receiver":{"var_ref":"s"},"selector":"size","args":[]}}}
        \\]
    );
    try timeBest(env, "concat 500 x 'abc'      ",
        \\{"send":{"receiver":{"literal":{"int":500}},"selector":"concatLoop","args":[]}}
    );

    try env.installMethod("SmallInteger", "buildBigString", &.{}, &.{ "s", "i" },
        \\[
        \\  {"assign":{"name":"s","value":{"literal":{"string":""}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"s","value":{"send":{"receiver":{"var_ref":"s"},"selector":",","args":[{"literal":{"string":"abcde"}}]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"s"}}
        \\]
    );
    try env.installMethod("Object", "scanString:", &.{"s"}, &.{"n"},
        \\[
        \\  {"assign":{"name":"n","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"var_ref":"s"},"selector":"do:","args":[{"block":{"params":["c"],"temps":[],"body":[
        \\    {"assign":{"name":"n","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"c"},"selector":">","args":[{"literal":{"int":0}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\      ]}},
        \\      {"block":{"params":[],"temps":[],"body":[{"var_ref":"n"}]}}
        \\    ]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );
    try timeBest(env, "String do: 5000 chars   ",
        \\{"send":{"receiver":{"literal":{"int":0}},"selector":"scanString:","args":[
        \\  {"send":{"receiver":{"literal":{"int":1000}},"selector":"buildBigString","args":[]}}
        \\]}}
    );

    try timeBest(env, "asUppercase 1000 chars  ",
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"int":200}},"selector":"buildBigString","args":[]}},"selector":"asUppercase","args":[]}},"selector":"size","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// D. LargeInteger arithmetic
// ──────────────────────────────────────────────────────────────────────
fn categoryLargeInt(env: *TestEnv) !void {
    try out("\nLargeInteger math:\n", .{});

    try timeBest(env, "factorial 30            ",
        \\{"send":{"receiver":{"literal":{"int":30}},"selector":"factorial","args":[]}}
    );
    try timeBest(env, "factorial 40            ",
        \\{"send":{"receiver":{"literal":{"int":40}},"selector":"factorial","args":[]}}
    );
    try timeBest(env, "gcd: factorial(20,15)   ",
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":20}},"selector":"factorial","args":[]}},"selector":"gcd:","args":[
        \\  {"send":{"receiver":{"literal":{"int":15}},"selector":"factorial","args":[]}}
        \\]}}
    );
    try timeBest(env, "2 raisedTo: 20          ",
        \\{"send":{"receiver":{"literal":{"int":2}},"selector":"raisedTo:","args":[{"literal":{"int":20}}]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// E. GC pressure
// ──────────────────────────────────────────────────────────────────────
fn categoryGc(env: *TestEnv) !void {
    try out("\nGC pressure:\n", .{});

    _ = try env.defineClass("Point", "Object", &.{ "x", "y" });

    try env.installMethod("SmallInteger", "allocTransient", &.{}, &.{ "i", "p" },
        \\[
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"p","value":{"send":{"receiver":{"var_ref":"Point"},"selector":"new","args":[]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"self"}}
        \\]
    );
    try timeBest(env, "alloc 100k transient    ",
        \\{"send":{"receiver":{"literal":{"int":100000}},"selector":"allocTransient","args":[]}}
    );

    try env.installMethod("SmallInteger", "allocRetained", &.{}, &.{ "i", "oc" },
        \\[
        \\  {"assign":{"name":"oc","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"oc"},"selector":"addLast:","args":[
        \\      {"send":{"receiver":{"var_ref":"Point"},"selector":"new","args":[]}}
        \\    ]}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"send":{"receiver":{"var_ref":"oc"},"selector":"size","args":[]}}}
        \\]
    );
    try timeBest(env, "alloc 50k retained      ",
        \\{"send":{"receiver":{"literal":{"int":50000}},"selector":"allocRetained","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// F. Polymorphic dispatch
// ──────────────────────────────────────────────────────────────────────
fn categoryPolymorphism(env: *TestEnv) !void {
    try out("\nPolymorphic dispatch:\n", .{});

    // Cycle through 4 receiver types per iter so the printString IC
    // sees each class.
    try env.installMethod("SmallInteger", "polymorphPrint", &.{}, &.{ "i", "n" },
        \\[
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"assign":{"name":"n","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[
        \\      {"send":{"receiver":{"send":{"receiver":{"literal":{"int":42}},"selector":"printString","args":[]}},"selector":"size","args":[]}}
        \\    ]}}}},
        \\    {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[
        \\      {"send":{"receiver":{"send":{"receiver":{"literal":{"string":"hi"}},"selector":"printString","args":[]}},"selector":"size","args":[]}}
        \\    ]}}}},
        \\    {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[
        \\      {"send":{"receiver":{"send":{"receiver":{"literal":{"float":3.14}},"selector":"printString","args":[]}},"selector":"size","args":[]}}
        \\    ]}}}},
        \\    {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[
        \\      {"send":{"receiver":{"send":{"receiver":{"literal":{"true":true}},"selector":"printString","args":[]}},"selector":"size","args":[]}}
        \\    ]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );
    try timeBest(env, "printString x4 megamorphic 2500",
        \\{"send":{"receiver":{"literal":{"int":2500}},"selector":"polymorphPrint","args":[]}}
    );

    // Deep super-send chain: A → B → C → D → E with f = super f + 1.
    _ = try env.defineClass("BenchA", "Object", &.{});
    _ = try env.defineClass("BenchB", "BenchA", &.{});
    _ = try env.defineClass("BenchC", "BenchB", &.{});
    _ = try env.defineClass("BenchD", "BenchC", &.{});
    _ = try env.defineClass("BenchE", "BenchD", &.{});
    try env.installMethod("BenchA", "f", &.{}, &.{}, "[{\"ret\":{\"literal\":{\"int\":1}}}]");
    const super_plus_one =
        \\[{"ret":{"send":{"receiver":{"super_send":{"selector":"f","args":[]}},"selector":"+","args":[{"literal":{"int":1}}]}}}]
    ;
    try env.installMethod("BenchB", "f", &.{}, &.{}, super_plus_one);
    try env.installMethod("BenchC", "f", &.{}, &.{}, super_plus_one);
    try env.installMethod("BenchD", "f", &.{}, &.{}, super_plus_one);
    try env.installMethod("BenchE", "f", &.{}, &.{}, super_plus_one);

    try env.installMethod("SmallInteger", "deepSuperLoop", &.{}, &.{ "i", "e", "n" },
        \\[
        \\  {"assign":{"name":"e","value":{"send":{"receiver":{"var_ref":"BenchE"},"selector":"new","args":[]}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"assign":{"name":"n","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[
        \\      {"send":{"receiver":{"var_ref":"e"},"selector":"f","args":[]}}
        \\    ]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );
    try timeBest(env, "super-send 5-deep 10k   ",
        \\{"send":{"receiver":{"literal":{"int":10000}},"selector":"deepSuperLoop","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// G. Backtracking — N-Queens
// ──────────────────────────────────────────────────────────────────────
fn categoryBacktracking(env: *TestEnv) !void {
    try out("\nBacktracking:\n", .{});

    _ = try env.defineClass("Queens", "Object", &.{ "n", "cols", "diag1", "diag2" });
    try env.installMethod("Queens", "init:", &.{"sz"}, &.{"i"},
        \\[
        \\  {"assign":{"name":"n","value":{"var_ref":"sz"}}},
        \\  {"assign":{"name":"cols","value":{"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[{"var_ref":"sz"}]}}}},
        \\  {"assign":{"name":"diag1","value":{"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[
        \\    {"send":{"receiver":{"send":{"receiver":{"literal":{"int":2}},"selector":"*","args":[{"var_ref":"sz"}]}},"selector":"-","args":[{"literal":{"int":1}}]}}
        \\  ]}}}},
        \\  {"assign":{"name":"diag2","value":{"send":{"receiver":{"var_ref":"Array"},"selector":"new:","args":[
        \\    {"send":{"receiver":{"send":{"receiver":{"literal":{"int":2}},"selector":"*","args":[{"var_ref":"sz"}]}},"selector":"-","args":[{"literal":{"int":1}}]}}
        \\  ]}}}},
        \\  {"ret":{"var_ref":"self"}}
        \\]
    );
    try env.installMethod("Queens", "solveFrom:", &.{"row"}, &.{ "count", "col", "d1", "d2" },
        \\[
        \\  {"assign":{"name":"count","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"row"},"selector":"=","args":[{"var_ref":"n"}]}},"selector":"ifTrue:ifFalse:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"assign":{"name":"count","value":{"literal":{"int":1}}}}
        \\    ]}},
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"assign":{"name":"col","value":{"literal":{"int":0}}}},
        \\      {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"col"},"selector":"<","args":[{"var_ref":"n"}]}}
        \\      ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\        {"assign":{"name":"d1","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"row"},"selector":"+","args":[{"var_ref":"col"}]}},"selector":"+","args":[{"literal":{"int":1}}]}}}},
        \\        {"assign":{"name":"d2","value":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"row"},"selector":"-","args":[{"var_ref":"col"}]}},"selector":"+","args":[{"var_ref":"n"}]}},"selector":"+","args":[{"literal":{"int":0}}]}}}},
        \\        {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"cols"},"selector":"at:","args":[{"send":{"receiver":{"var_ref":"col"},"selector":"+","args":[{"literal":{"int":1}}]}}]}},"selector":"==","args":[{"literal":{"nil":true}}]}},"selector":"and:","args":[{"block":{"params":[],"temps":[],"body":[
        \\          {"send":{"receiver":{"send":{"receiver":{"var_ref":"diag1"},"selector":"at:","args":[{"var_ref":"d1"}]}},"selector":"==","args":[{"literal":{"nil":true}}]}}
        \\        ]}}]}},"selector":"and:","args":[{"block":{"params":[],"temps":[],"body":[
        \\          {"send":{"receiver":{"send":{"receiver":{"var_ref":"diag2"},"selector":"at:","args":[{"var_ref":"d2"}]}},"selector":"==","args":[{"literal":{"nil":true}}]}}
        \\        ]}}]}},"selector":"ifTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\          {"send":{"receiver":{"var_ref":"cols"},"selector":"at:put:","args":[
        \\            {"send":{"receiver":{"var_ref":"col"},"selector":"+","args":[{"literal":{"int":1}}]}},
        \\            {"literal":{"true":true}}
        \\          ]}},
        \\          {"send":{"receiver":{"var_ref":"diag1"},"selector":"at:put:","args":[{"var_ref":"d1"},{"literal":{"true":true}}]}},
        \\          {"send":{"receiver":{"var_ref":"diag2"},"selector":"at:put:","args":[{"var_ref":"d2"},{"literal":{"true":true}}]}},
        \\          {"assign":{"name":"count","value":{"send":{"receiver":{"var_ref":"count"},"selector":"+","args":[
        \\            {"send":{"receiver":{"var_ref":"self"},"selector":"solveFrom:","args":[
        \\              {"send":{"receiver":{"var_ref":"row"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\            ]}}
        \\          ]}}}},
        \\          {"send":{"receiver":{"var_ref":"cols"},"selector":"at:put:","args":[
        \\            {"send":{"receiver":{"var_ref":"col"},"selector":"+","args":[{"literal":{"int":1}}]}},
        \\            {"literal":{"nil":true}}
        \\          ]}},
        \\          {"send":{"receiver":{"var_ref":"diag1"},"selector":"at:put:","args":[{"var_ref":"d1"},{"literal":{"nil":true}}]}},
        \\          {"send":{"receiver":{"var_ref":"diag2"},"selector":"at:put:","args":[{"var_ref":"d2"},{"literal":{"nil":true}}]}}
        \\        ]}}]}},
        \\        {"assign":{"name":"col","value":{"send":{"receiver":{"var_ref":"col"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\      ]}}]}}
        \\    ]}}
        \\  ]}},
        \\  {"ret":{"var_ref":"count"}}
        \\]
    );
    try env.installMethod("SmallInteger", "queens", &.{}, &.{"q"},
        \\[
        \\  {"assign":{"name":"q","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"Queens"},"selector":"new","args":[]}},"selector":"init:","args":[{"var_ref":"self"}]}}}},
        \\  {"ret":{"send":{"receiver":{"var_ref":"q"},"selector":"solveFrom:","args":[{"literal":{"int":0}}]}}}
        \\]
    );
    try timeBest(env, "N-Queens n=8 (92 sols)  ",
        \\{"send":{"receiver":{"literal":{"int":8}},"selector":"queens","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// H. Exception control flow
// ──────────────────────────────────────────────────────────────────────
fn categoryExceptions(env: *TestEnv) !void {
    try out("\nException control flow:\n", .{});

    try env.installMethod("SmallInteger", "exceptLoop", &.{}, &.{ "i", "n" },
        \\[
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"assign":{"name":"n","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"Exception"},"selector":"new","args":[]}},"selector":"signal:","args":[{"literal":{"string":"oops"}}]}}
        \\    ]}},"selector":"on:do:","args":[
        \\      {"var_ref":"Exception"},
        \\      {"block":{"params":["e"],"temps":[],"body":[
        \\        {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\      ]}}
        \\    ]}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );
    try timeBest(env, "signal+catch x 1000     ",
        \\{"send":{"receiver":{"literal":{"int":1000}},"selector":"exceptLoop","args":[]}}
    );
}

// ──────────────────────────────────────────────────────────────────────
// I. Float math
// ──────────────────────────────────────────────────────────────────────
fn categoryFloat(env: *TestEnv) !void {
    try out("\nFloat math:\n", .{});

    try env.installMethod("SmallInteger", "sinSum", &.{}, &.{ "i", "acc" },
        \\[
        \\  {"assign":{"name":"acc","value":{"literal":{"float":0.0}}}},
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"var_ref":"self"}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"acc","value":{"send":{"receiver":{"var_ref":"acc"},"selector":"+","args":[
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"i"},"selector":"asFloat","args":[]}},"selector":"sin","args":[]}}
        \\    ]}}}},
        \\    {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"acc"}}
        \\]
    );
    try timeBest(env, "sum sin(i) 0..10000     ",
        \\{"send":{"receiver":{"literal":{"int":10000}},"selector":"sinSum","args":[]}}
    );

    // Mandelbrot 40x40, max 50 iters.
    try env.installMethod("SmallInteger", "mandelEscapeAt:y:maxIter:", &.{ "py", "max" }, &.{ "x", "y", "x2", "y2", "cx", "cy", "iter" },
        \\[
        \\  {"assign":{"name":"cx","value":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"self"},"selector":"asFloat","args":[]}},"selector":"/","args":[{"literal":{"float":40.0}}]}},"selector":"*","args":[{"literal":{"float":3.0}}]}}}},
        \\  {"assign":{"name":"cx","value":{"send":{"receiver":{"var_ref":"cx"},"selector":"-","args":[{"literal":{"float":2.0}}]}}}},
        \\  {"assign":{"name":"cy","value":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"py"},"selector":"asFloat","args":[]}},"selector":"/","args":[{"literal":{"float":40.0}}]}},"selector":"*","args":[{"literal":{"float":3.0}}]}}}},
        \\  {"assign":{"name":"cy","value":{"send":{"receiver":{"var_ref":"cy"},"selector":"-","args":[{"literal":{"float":1.5}}]}}}},
        \\  {"assign":{"name":"x","value":{"literal":{"float":0.0}}}},
        \\  {"assign":{"name":"y","value":{"literal":{"float":0.0}}}},
        \\  {"assign":{"name":"iter","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"iter"},"selector":"<","args":[{"var_ref":"max"}]}},"selector":"and:","args":[{"block":{"params":[],"temps":[],"body":[
        \\      {"assign":{"name":"x2","value":{"send":{"receiver":{"var_ref":"x"},"selector":"*","args":[{"var_ref":"x"}]}}}},
        \\      {"assign":{"name":"y2","value":{"send":{"receiver":{"var_ref":"y"},"selector":"*","args":[{"var_ref":"y"}]}}}},
        \\      {"send":{"receiver":{"send":{"receiver":{"var_ref":"x2"},"selector":"+","args":[{"var_ref":"y2"}]}},"selector":"<","args":[{"literal":{"float":4.0}}]}}
        \\    ]}}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"y","value":{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"literal":{"float":2.0}},"selector":"*","args":[{"var_ref":"x"}]}},"selector":"*","args":[{"var_ref":"y"}]}},"selector":"+","args":[{"var_ref":"cy"}]}}}},
        \\    {"assign":{"name":"x","value":{"send":{"receiver":{"send":{"receiver":{"var_ref":"x2"},"selector":"-","args":[{"var_ref":"y2"}]}},"selector":"+","args":[{"var_ref":"cx"}]}}}},
        \\    {"assign":{"name":"iter","value":{"send":{"receiver":{"var_ref":"iter"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"iter"}}
        \\]
    );
    try env.installMethod("SmallInteger", "mandelbrot", &.{}, &.{ "x", "y", "n" },
        \\[
        \\  {"assign":{"name":"n","value":{"literal":{"int":0}}}},
        \\  {"assign":{"name":"y","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"y"},"selector":"<","args":[{"literal":{"int":40}}]}}
        \\  ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\    {"assign":{"name":"x","value":{"literal":{"int":0}}}},
        \\    {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\      {"send":{"receiver":{"var_ref":"x"},"selector":"<","args":[{"literal":{"int":40}}]}}
        \\    ]}},"selector":"whileTrue:","args":[{"block":{"params":[],"temps":[],"body":[
        \\      {"assign":{"name":"n","value":{"send":{"receiver":{"var_ref":"n"},"selector":"+","args":[
        \\        {"send":{"receiver":{"var_ref":"x"},"selector":"mandelEscapeAt:y:maxIter:","args":[{"var_ref":"y"},{"var_ref":"self"}]}}
        \\      ]}}}},
        \\      {"assign":{"name":"x","value":{"send":{"receiver":{"var_ref":"x"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\    ]}}]}},
        \\    {"assign":{"name":"y","value":{"send":{"receiver":{"var_ref":"y"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\  ]}}]}},
        \\  {"ret":{"var_ref":"n"}}
        \\]
    );
    try timeBest(env, "mandelbrot 40x40 max50  ",
        \\{"send":{"receiver":{"literal":{"int":50}},"selector":"mandelbrot","args":[]}}
    );
}

pub fn main() !void {
    try out("== hilang extended benchmarks ==\n\n", .{});

    var env: TestEnv = undefined;
    try env.initWithHeap(HEAP_BYTES);
    defer env.deinit();

    try categoryRecursion(&env);
    try freshEnv(&env);
    try categoryCollections(&env);
    try freshEnv(&env);
    try categoryStrings(&env);
    try freshEnv(&env);
    try categoryLargeInt(&env);
    try freshEnv(&env);
    try categoryGc(&env);
    try freshEnv(&env);
    try categoryPolymorphism(&env);
    try freshEnv(&env);
    try categoryBacktracking(&env);
    try freshEnv(&env);
    try categoryExceptions(&env);
    try freshEnv(&env);
    try categoryFloat(&env);
}
