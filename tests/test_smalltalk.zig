const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");

test "Smalltalk source top-level round trips through JSON AST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\a := 1.
        \\a + 2
    ;

    const json = try vm.smalltalk.parseTopLevelToJson(arena.allocator(), source);
    const rendered = try vm.smalltalk.renderTopLevelSourceFromJson(arena.allocator(), json);
    try std.testing.expectEqualStrings(source, rendered);
}

test "Smalltalk source method round trips with symbol literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\statusKey
        \\    ^#statusCode
    ;

    const json = try vm.smalltalk.parseMethodToJson(arena.allocator(), source);
    const rendered = try vm.smalltalk.renderMethodSourceFromJson(arena.allocator(), json);
    try std.testing.expectEqualStrings(source, rendered);
}

test "evalSource matches JSON AST eval semantics" {
    var env: harness.TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const result = try env.evalSource(
        \\a := 1.
        \\a + 2
    );

    var buf: [64]u8 = undefined;
    const printed = try harness.printString(&env, result, &buf);
    try std.testing.expectEqualStrings("3", printed);
}

test "installMethodSource executes and renders canonically" {
    var env: harness.TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const source =
        \\triplePlus: anInt
        \\    | twice |
        \\    twice := self + self.
        \\    ^twice + anInt
    ;

    try env.installMethodSource("SmallInteger", source);

    const result = try env.evalSource("3 triplePlus: 4");
    var buf: [64]u8 = undefined;
    const printed = try harness.printString(&env, result, &buf);
    try std.testing.expectEqualStrings("10", printed);

    const cls = vm.dict.lookup(env.machine.globals.smalltalk, "SmallInteger");
    const sym = try vm.dict.newSymbol(&env.heap, &env.machine.globals, "triplePlus:");
    const method = vm.method.lookupBySym(cls, sym);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try vm.smalltalk.renderMethodSourceFromHeap(arena.allocator(), &env.machine.globals, method);
    try std.testing.expectEqualStrings(source, rendered);
}
