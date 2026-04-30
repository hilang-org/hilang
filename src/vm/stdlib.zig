const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const dict = @import("dict.zig");
const class_mod = @import("class.zig");
const method_mod = @import("method.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

// stdlib lives in the heap like everything else. `loadSUnit` runs once
// at bootstrap end: builds heap-resident AST trees for each class and
// method via the helpers below, then installs them through the same
// class_mod / method_mod APIs the server uses for define_class /
// define_method. The result is identical to a user typing the
// definitions over the protocol — there's no second tier.

const Ctx = struct {
    heap: *Heap,
    g: *const Globals,
};

// ---- AST builders ----
//
// Each returns a heap Oop for the constructed AstNode. The returned
// node is reachable via whatever links the caller wires up; bare
// nodes left dangling get reaped by the next GC.

fn lit(c: Ctx, value: Oop) !Oop {
    const node = try c.heap.allocSlots(c.g.literal_node_class, object.LIT_INST_SIZE);
    object.setSlot(node, object.SLOT_LIT_VALUE, value);
    return node;
}

fn litInt(c: Ctx, n: i64) !Oop {
    return lit(c, oop_mod.fromInt(n));
}

fn litTrue(c: Ctx) !Oop {
    return lit(c, oop_mod.TRUE);
}

fn litFalse(c: Ctx) !Oop {
    return lit(c, oop_mod.FALSE);
}

fn litNil(c: Ctx) !Oop {
    return lit(c, oop_mod.NIL);
}

fn litString(c: Ctx, s: []const u8) !Oop {
    const str = try c.heap.allocBytes(c.g.string_class, @intCast(s.len));
    @memcpy(object.bytesOf(str)[0..s.len], s);
    return lit(c, str);
}

fn varRef(c: Ctx, name: []const u8) !Oop {
    const sym = try dict.newSymbol(c.heap, c.g, name);
    const node = try c.heap.allocSlots(c.g.var_ref_node_class, object.VARREF_INST_SIZE);
    object.setSlot(node, object.SLOT_VARREF_NAME, sym);
    return node;
}

fn assignNode(c: Ctx, name: []const u8, value: Oop) !Oop {
    const sym = try dict.newSymbol(c.heap, c.g, name);
    const node = try c.heap.allocSlots(c.g.assign_node_class, object.ASSIGN_INST_SIZE);
    object.setSlot(node, object.SLOT_ASSIGN_NAME, sym);
    object.setSlot(node, object.SLOT_ASSIGN_VALUE, value);
    return node;
}

fn send(c: Ctx, receiver: Oop, selector: []const u8, args: []const Oop) !Oop {
    const sym = try dict.newSymbol(c.heap, c.g, selector);
    const args_arr = try c.heap.allocSlots(c.g.array_class, @intCast(args.len));
    for (args, 0..) |a, i| object.setSlot(args_arr, @intCast(i), a);
    const node = try c.heap.allocSlots(c.g.send_node_class, object.SEND_INST_SIZE);
    object.setSlot(node, object.SLOT_SEND_RECEIVER, receiver);
    object.setSlot(node, object.SLOT_SEND_SELECTOR, sym);
    object.setSlot(node, object.SLOT_SEND_ARGS, args_arr);
    return node;
}

fn block(c: Ctx, params: []const []const u8, temps: []const []const u8, body: []const Oop) !Oop {
    const params_arr = try buildSymArray(c, params);
    const temps_arr = try buildSymArray(c, temps);
    const body_arr = try c.heap.allocSlots(c.g.array_class, @intCast(body.len));
    for (body, 0..) |stmt, i| object.setSlot(body_arr, @intCast(i), stmt);
    const node = try c.heap.allocSlots(c.g.block_node_class, object.BLOCKNODE_INST_SIZE);
    object.setSlot(node, object.SLOT_BLOCKNODE_PARAMS, params_arr);
    object.setSlot(node, object.SLOT_BLOCKNODE_TEMPS, temps_arr);
    object.setSlot(node, object.SLOT_BLOCKNODE_BODY, body_arr);
    return node;
}

fn ret(c: Ctx, inner: Oop) !Oop {
    const node = try c.heap.allocSlots(c.g.ret_node_class, object.RET_INST_SIZE);
    object.setSlot(node, object.SLOT_RET_INNER, inner);
    return node;
}

fn superSend(c: Ctx, selector: []const u8, args: []const Oop) !Oop {
    const sym = try dict.newSymbol(c.heap, c.g, selector);
    const args_arr = try c.heap.allocSlots(c.g.array_class, @intCast(args.len));
    for (args, 0..) |a, i| object.setSlot(args_arr, @intCast(i), a);
    const node = try c.heap.allocSlots(c.g.super_send_node_class, object.SUPER_INST_SIZE);
    object.setSlot(node, object.SLOT_SUPER_SELECTOR, sym);
    object.setSlot(node, object.SLOT_SUPER_ARGS, args_arr);
    return node;
}

fn buildSymArray(c: Ctx, names: []const []const u8) !Oop {
    const arr = try c.heap.allocSlots(c.g.array_class, @intCast(names.len));
    for (names, 0..) |n, i| {
        const sym = try dict.newSymbol(c.heap, c.g, n);
        object.setSlot(arr, @intCast(i), sym);
    }
    return arr;
}

// Install an AST method on `cls`. Mirrors the protocol's define_method
// path but is callable from Zig directly.
fn defineMethod(
    c: Ctx,
    cls: Oop,
    selector: []const u8,
    params: []const []const u8,
    temps: []const []const u8,
    body: []const Oop,
) !void {
    const params_arr = try buildSymArray(c, params);
    const temps_arr = try buildSymArray(c, temps);
    const body_arr = try c.heap.allocSlots(c.g.array_class, @intCast(body.len));
    for (body, 0..) |stmt, i| object.setSlot(body_arr, @intCast(i), stmt);

    const m = try method_mod.newAst(c.heap, c.g, cls, selector, @intCast(params.len), params_arr, temps_arr, body_arr);
    try method_mod.install(c.heap, c.g, null, cls, selector, m);
}

fn defineClassAndRegister(
    heap: *Heap,
    g: *Globals,
    name: []const u8,
    super: Oop,
    ivars: []const []const u8,
) !Oop {
    const cls = try class_mod.defineClass(heap, g, name, super, ivars);
    const sym = try dict.newSymbol(heap, g, name);
    _ = try dict.atPutSym(heap, g.smalltalk, sym, cls);
    return cls;
}

// Install a minimal SUnit-style testing framework, a handful of core
// Smalltalk methods (Boolean>>not, Array>>do:), and the start of a
// stdlib of collections (OrderedCollection):
//   Boolean>>not, True>>not, False>>not
//   Array>>do:
//   OrderedCollection < Object  ivars=[array tally]
//   TestFailure < Exception
//   TestCase < Object  with assert:, assert:equals:, deny:, should:raise:, fail:
//   TestRunner < Object  with init, passed, failed, runOne:selector:, runAll:
pub fn loadSUnit(heap: *Heap, g: *Globals) !void {
    const c = Ctx{ .heap = heap, .g = g };

    // ---- Message (reified failed send for DNU) ----
    //
    // Defined first so that any subsequent stdlib send that misses
    // its target can dispatch through Object>>doesNotUnderstand:.
    // In practice stdlib loads cleanly, but we want the safety
    // net live before any user code runs.
    const message_class = try defineClassAndRegister(heap, g, "Message", g.object_class, &.{ "selector", "arguments" });
    g.message_class = message_class;
    try defineMethod(c, message_class, "selector", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "selector")),
    });
    try defineMethod(c, message_class, "arguments", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "arguments")),
    });

    // Object>>doesNotUnderstand: aMessage
    //   ^Exception new signal: 'doesNotUnderstand: ', aMessage selector asString
    try defineMethod(c, g.object_class, "doesNotUnderstand:", &.{"aMessage"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "Exception"), "new", &.{}), "signal:", &.{
            try send(c, try litString(c, "doesNotUnderstand: "), ",", &.{
                try send(c, try send(c, try varRef(c, "aMessage"), "selector", &.{}), "asString", &.{}),
            }),
        })),
    });

    // ---- Number hierarchy ----
    //
    // Three abstract classes plus a reparenting of SmallInteger so that
    // the Magnitude/Number/Integer protocol has a place to live.
    // SmallInteger originally inherited directly from Object; this
    // reroutes its superclass slot (and its metaclass's superclass) to
    // Integer < Number < Magnitude < Object. No instance layouts shift
    // because SmallIntegers are tagged values, not heap objects with
    // ivars.
    _ = try defineClassAndRegister(heap, g, "Magnitude", g.object_class, &.{});
    const magnitude_class = dict.lookupBySym(g.smalltalk, try dict.newSymbol(heap, g, "Magnitude"));
    _ = try defineClassAndRegister(heap, g, "Number", magnitude_class, &.{});
    const number_class = dict.lookupBySym(g.smalltalk, try dict.newSymbol(heap, g, "Number"));
    _ = try defineClassAndRegister(heap, g, "Integer", number_class, &.{});
    const integer_class = dict.lookupBySym(g.smalltalk, try dict.newSymbol(heap, g, "Integer"));

    // Reparent SmallInteger: Object → Integer. LargePositiveInteger /
    // LargeNegativeInteger get the same treatment (they're heap
    // objects, but inheriting Integer-protocol methods like gcd:,
    // factorial, even/odd is what users expect).
    const integer_meta = object.headerOf(integer_class).class;
    inline for (.{
        g.smallinteger_class,
        g.large_positive_integer_class,
        g.large_negative_integer_class,
    }) |int_subclass| {
        object.setSlot(int_subclass, object.SLOT_SUPERCLASS, integer_class);
        const meta = object.headerOf(int_subclass).class;
        object.setSlot(meta, object.SLOT_SUPERCLASS, integer_meta);
    }

    // Reparent SmallFloat: Object → Number. Lets SmallFloat inherit
    // Number protocol (negated, abs, isPositive, between:and:, etc.),
    // which user math wrappers (sqrt/sin/cos/...) and Fraction
    // arithmetic expect.
    object.setSlot(g.small_float_class, object.SLOT_SUPERCLASS, number_class);
    const number_meta = object.headerOf(number_class).class;
    const small_float_meta_for_reparent = object.headerOf(g.small_float_class).class;
    object.setSlot(small_float_meta_for_reparent, object.SLOT_SUPERCLASS, number_meta);

    // ---- Interval ----
    //
    // (1 to: 10) is an Interval — a lazy integer range. Phase C.8
    // reparents it under SequenceableCollection so it inherits all
    // the collection iteration combinators. For now it stands alone
    // with `do:`, `at:`, `size`, `setStart:stop:step:` plus class-side
    // factories.
    const interval_class = try defineClassAndRegister(heap, g, "Interval", g.object_class, &.{ "start", "stop", "step" });

    // Interval>>setStart: s stop: e step: i
    //   start := s. stop := e. step := i. ^self
    try defineMethod(c, interval_class, "setStart:stop:step:", &.{ "s", "e", "i" }, &.{}, &.{
        try assignNode(c, "start", try varRef(c, "s")),
        try assignNode(c, "stop", try varRef(c, "e")),
        try assignNode(c, "step", try varRef(c, "i")),
        try ret(c, try varRef(c, "self")),
    });

    // Interval>>at: i  ^start + ((i - 1) * step)
    try defineMethod(c, interval_class, "at:", &.{"i"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "start"), "+", &.{
            try send(c, try send(c, try varRef(c, "i"), "-", &.{try litInt(c, 1)}), "*", &.{try varRef(c, "step")}),
        })),
    });

    // Interval>>size  ^((stop - start) // step) + 1
    try defineMethod(c, interval_class, "size", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try send(c, try varRef(c, "stop"), "-", &.{try varRef(c, "start")}), "//", &.{try varRef(c, "step")}), "+", &.{try litInt(c, 1)})),
    });

    // Interval>>do: aBlock
    //   | i |
    //   i := start.
    //   [i <= stop] whileTrue: [aBlock value: i. i := i + step]
    //   (Assumes step > 0; descending intervals are v2.)
    try defineMethod(c, interval_class, "do:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try varRef(c, "start")),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "stop")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "i")}),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try varRef(c, "step")})),
            }),
        }),
    });

    // Interval class side: from:to:, from:to:by:
    const interval_meta = object.headerOf(interval_class).class;
    try defineMethod(c, interval_meta, "from:to:", &.{ "s", "e" }, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "new", &.{}), "setStart:stop:step:", &.{
            try varRef(c, "s"), try varRef(c, "e"), try litInt(c, 1),
        })),
    });
    try defineMethod(c, interval_meta, "from:to:by:", &.{ "s", "e", "i" }, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "new", &.{}), "setStart:stop:step:", &.{
            try varRef(c, "s"), try varRef(c, "e"), try varRef(c, "i"),
        })),
    });

    // Number>>to:, to:by:, to:do:, to:by:do:
    //   to: e        ^Interval from: self to: e
    //   to: e by: i  ^Interval from: self to: e by: i
    //   to:do: short-circuits the Interval allocation in tight loops.
    try defineMethod(c, number_class, "to:", &.{"e"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "Interval"), "from:to:", &.{ try varRef(c, "self"), try varRef(c, "e") })),
    });
    try defineMethod(c, number_class, "to:by:", &.{ "e", "i" }, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "Interval"), "from:to:by:", &.{ try varRef(c, "self"), try varRef(c, "e"), try varRef(c, "i") })),
    });
    try defineMethod(c, number_class, "to:do:", &.{ "e", "aBlock" }, &.{"i"}, &.{
        try assignNode(c, "i", try varRef(c, "self")),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "e")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "i")}),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // Number>>timesRepeat: aBlock — repeat aBlock value `self` times.
    try defineMethod(c, number_class, "timesRepeat:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "self")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value", &.{}),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // Number>>to: e by: step do: aBlock
    //   | k |
    //   k := self.
    //   step > 0
    //     ifTrue:  [[k <= e] whileTrue: [aBlock value: k. k := k + step]]
    //     ifFalse: [[k >= e] whileTrue: [aBlock value: k. k := k + step]]
    try defineMethod(c, number_class, "to:by:do:", &.{ "e", "step", "aBlock" }, &.{"k"}, &.{
        try assignNode(c, "k", try varRef(c, "self")),
        try send(c, try send(c, try varRef(c, "step"), ">", &.{try litInt(c, 0)}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try block(c, &.{}, &.{}, &.{
                    try send(c, try varRef(c, "k"), "<=", &.{try varRef(c, "e")}),
                }), "whileTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "k")}),
                        try assignNode(c, "k", try send(c, try varRef(c, "k"), "+", &.{try varRef(c, "step")})),
                    }),
                }),
            }),
            try block(c, &.{}, &.{}, &.{
                try send(c, try block(c, &.{}, &.{}, &.{
                    try send(c, try varRef(c, "k"), ">=", &.{try varRef(c, "e")}),
                }), "whileTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "k")}),
                        try assignNode(c, "k", try send(c, try varRef(c, "k"), "+", &.{try varRef(c, "step")})),
                    }),
                }),
            }),
        }),
    });

    // Magnitude>>min:, max:, between:and:
    try defineMethod(c, magnitude_class, "min:", &.{"aMagnitude"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "<=", &.{try varRef(c, "aMagnitude")}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{try varRef(c, "self")}),
            try block(c, &.{}, &.{}, &.{try varRef(c, "aMagnitude")}),
        })),
    });
    try defineMethod(c, magnitude_class, "max:", &.{"aMagnitude"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "<=", &.{try varRef(c, "aMagnitude")}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{try varRef(c, "aMagnitude")}),
            try block(c, &.{}, &.{}, &.{try varRef(c, "self")}),
        })),
    });
    try defineMethod(c, magnitude_class, "between:and:", &.{ "low", "high" }, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "low"), "<=", &.{try varRef(c, "self")}), "and:", &.{
            try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "self"), "<=", &.{try varRef(c, "high")})}),
        })),
    });

    // Number>>abs, negated, sign, isZero, isPositive, isNegative
    try defineMethod(c, number_class, "isZero", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "=", &.{try litInt(c, 0)})),
    });
    try defineMethod(c, number_class, "isPositive", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), ">", &.{try litInt(c, 0)})),
    });
    try defineMethod(c, number_class, "isNegative", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "<", &.{try litInt(c, 0)})),
    });
    try defineMethod(c, number_class, "negated", &.{}, &.{}, &.{
        try ret(c, try send(c, try litInt(c, 0), "-", &.{try varRef(c, "self")})),
    });
    try defineMethod(c, number_class, "abs", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "isNegative", &.{}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "self"), "negated", &.{})}),
            try block(c, &.{}, &.{}, &.{try varRef(c, "self")}),
        })),
    });
    // Integer>>even, odd
    //   even  ^self \\ 2 = 0
    //   odd   ^self even not
    try defineMethod(c, integer_class, "even", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "\\\\", &.{try litInt(c, 2)}), "=", &.{try litInt(c, 0)})),
    });
    try defineMethod(c, integer_class, "odd", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "even", &.{}), "not", &.{})),
    });

    // Integer>>gcd: anInt
    //   ^anInt = 0 ifTrue: [self abs] ifFalse: [anInt gcd: self \\ anInt]
    try defineMethod(c, integer_class, "gcd:", &.{"anInt"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "anInt"), "=", &.{try litInt(c, 0)}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "self"), "abs", &.{})}),
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "anInt"), "gcd:", &.{
                    try send(c, try varRef(c, "self"), "\\\\", &.{try varRef(c, "anInt")}),
                }),
            }),
        })),
    });

    // Integer>>factorial
    //   ^self <= 1 ifTrue: [1] ifFalse: [self * (self - 1) factorial]
    try defineMethod(c, integer_class, "factorial", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "<=", &.{try litInt(c, 1)}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{try litInt(c, 1)}),
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "self"), "*", &.{
                    try send(c, try send(c, try varRef(c, "self"), "-", &.{try litInt(c, 1)}), "factorial", &.{}),
                }),
            }),
        })),
    });

    // Integer>>raisedTo: anInt
    //   anInt = 0 ifTrue: [^1].
    //   ^self * (self raisedTo: anInt - 1)
    try defineMethod(c, integer_class, "raisedTo:", &.{"anInt"}, &.{}, &.{
        try send(c, try send(c, try varRef(c, "anInt"), "=", &.{try litInt(c, 0)}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{try ret(c, try litInt(c, 1))}),
        }),
        try ret(c, try send(c, try varRef(c, "self"), "*", &.{
            try send(c, try varRef(c, "self"), "raisedTo:", &.{
                try send(c, try varRef(c, "anInt"), "-", &.{try litInt(c, 1)}),
            }),
        })),
    });

    try defineMethod(c, number_class, "sign", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "isZero", &.{}), "ifTrue:ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{try litInt(c, 0)}),
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "self"), "isPositive", &.{}), "ifTrue:ifFalse:", &.{
                    try block(c, &.{}, &.{}, &.{try litInt(c, 1)}),
                    try block(c, &.{}, &.{}, &.{try litInt(c, -1)}),
                }),
            }),
        })),
    });

    // ---- Fraction ----
    //
    // Reduced rational numbers. Numerator and denominator are any
    // Integer (SmallInteger or Large*); the canonical form has
    // denominator > 0 and gcd(|n|, |d|) = 1 when both are Small. For
    // Large operands we currently skip reduction (gcd on Large needs
    // Large modulo, deferred to v3) — the result is still
    // mathematically correct, just not in lowest terms. Fraction
    // arithmetic with Float promotes both sides to Float.
    const fraction_class = try defineClassAndRegister(heap, g, "Fraction", number_class, &.{ "numerator", "denominator" });

    // Fraction>>setNum: n den: d   private constructor; ivar setter.
    try defineMethod(c, fraction_class, "setNum:den:", &.{ "n", "d" }, &.{}, &.{
        try assignNode(c, "numerator", try varRef(c, "n")),
        try assignNode(c, "denominator", try varRef(c, "d")),
        try ret(c, try varRef(c, "self")),
    });

    try defineMethod(c, fraction_class, "numerator", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "numerator")),
    });
    try defineMethod(c, fraction_class, "denominator", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "denominator")),
    });

    // Fraction class>>numerator: n denominator: d
    //   d isZero ifTrue: [Exception new signal: 'fraction denominator is zero'].
    //   d < 0 ifTrue: [n := 0 - n. d := 0 - d].
    //   ((n class == SmallInteger) and: [d class == SmallInteger]) ifTrue: [
    //     | g |
    //     g := n abs gcd: d.
    //     n := n // g. d := d // g
    //   ].
    //   d = 1 ifTrue: [^n].
    //   ^self new setNum: n den: d
    const frac_meta = object.headerOf(fraction_class).class;
    try defineMethod(c, frac_meta, "numerator:denominator:", &.{ "n", "d" }, &.{"g_"}, &.{
        try send(c, try send(c, try varRef(c, "d"), "isZero", &.{}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "Exception"), "new", &.{}), "signal:", &.{
                    try litString(c, "fraction denominator is zero"),
                }),
            }),
        }),
        try send(c, try send(c, try varRef(c, "d"), "<", &.{try litInt(c, 0)}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try assignNode(c, "n", try send(c, try litInt(c, 0), "-", &.{try varRef(c, "n")})),
                try assignNode(c, "d", try send(c, try litInt(c, 0), "-", &.{try varRef(c, "d")})),
            }),
        }),
        // Reduce only when both are SmallInteger (gcd needs //).
        try send(c, try send(c,
            try send(c, try send(c, try varRef(c, "n"), "class", &.{}), "==", &.{try varRef(c, "SmallInteger")}),
            "and:", &.{try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "d"), "class", &.{}), "==", &.{try varRef(c, "SmallInteger")}),
            })},
        ), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try assignNode(c, "g_", try send(c,
                    try send(c, try varRef(c, "n"), "abs", &.{}),
                    "gcd:", &.{try varRef(c, "d")},
                )),
                try assignNode(c, "n", try send(c, try varRef(c, "n"), "//", &.{try varRef(c, "g_")})),
                try assignNode(c, "d", try send(c, try varRef(c, "d"), "//", &.{try varRef(c, "g_")})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "d"), "=", &.{try litInt(c, 1)}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try varRef(c, "n")),
            }),
        }),
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "new", &.{}), "setNum:den:", &.{
            try varRef(c, "n"),
            try varRef(c, "d"),
        })),
    });

    // Integer>>/ aNumber
    //   (aNumber class == SmallFloat) ifTrue: [^self asFloat / aNumber].
    //   ^Fraction numerator: self denominator: aNumber
    try defineMethod(c, integer_class, "/", &.{"aNumber"}, &.{}, &.{
        try send(c,
            try send(c, try send(c, try varRef(c, "aNumber"), "class", &.{}), "==", &.{try varRef(c, "SmallFloat")}),
            "ifTrue:",
            &.{try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), "/", &.{try varRef(c, "aNumber")})),
            })},
        ),
        try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
            try varRef(c, "self"),
            try varRef(c, "aNumber"),
        })),
    });

    // Helper: classify aNumber so the four arithmetic methods aren't
    // structural copies. Exposed as `Fraction>>kindOf:` returning
    // #float, #fraction, or #integer.
    try defineMethod(c, fraction_class, "kindOf:", &.{"aNumber"}, &.{}, &.{
        try send(c,
            try send(c, try send(c, try varRef(c, "aNumber"), "class", &.{}), "==", &.{try varRef(c, "SmallFloat")}),
            "ifTrue:",
            &.{try block(c, &.{}, &.{}, &.{
                try ret(c, try lit(c, try dict.newSymbol(c.heap, c.g, "float"))),
            })},
        ),
        try send(c,
            try send(c, try varRef(c, "aNumber"), "isKindOf:", &.{try varRef(c, "Fraction")}),
            "ifTrue:",
            &.{try block(c, &.{}, &.{}, &.{
                try ret(c, try lit(c, try dict.newSymbol(c.heap, c.g, "fraction"))),
            })},
        ),
        try ret(c, try lit(c, try dict.newSymbol(c.heap, c.g, "integer"))),
    });

    // Fraction>>+ aNumber
    //   kind := self kindOf: aNumber.
    //   kind == #float    ifTrue: [^self asFloat + aNumber].
    //   kind == #fraction ifTrue: [
    //     ^Fraction numerator: numerator * aNumber denominator
    //                        + (aNumber numerator * denominator)
    //              denominator: denominator * aNumber denominator
    //   ].
    //   ^Fraction numerator: numerator + (aNumber * denominator)
    //            denominator: denominator
    try defineMethod(c, fraction_class, "+", &.{"aNumber"}, &.{"k"}, &.{
        try assignNode(c, "k", try send(c, try varRef(c, "self"), "kindOf:", &.{try varRef(c, "aNumber")})),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "float"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), "+", &.{try varRef(c, "aNumber")})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "fraction"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
                    try send(c,
                        try send(c, try varRef(c, "numerator"), "*", &.{try send(c, try varRef(c, "aNumber"), "denominator", &.{})}),
                        "+",
                        &.{try send(c, try send(c, try varRef(c, "aNumber"), "numerator", &.{}), "*", &.{try varRef(c, "denominator")})},
                    ),
                    try send(c, try varRef(c, "denominator"), "*", &.{try send(c, try varRef(c, "aNumber"), "denominator", &.{})}),
                })),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
            try send(c, try varRef(c, "numerator"), "+", &.{
                try send(c, try varRef(c, "aNumber"), "*", &.{try varRef(c, "denominator")}),
            }),
            try varRef(c, "denominator"),
        })),
    });

    // Fraction>>- aNumber  ^self + aNumber negated
    // (Using `0 - aNumber` would dispatch to Integer>>- with a Fraction
    // arg — primIntSub doesn't accept Fractions.)
    try defineMethod(c, fraction_class, "-", &.{"aNumber"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "+", &.{
            try send(c, try varRef(c, "aNumber"), "negated", &.{}),
        })),
    });

    // Fraction>>* aNumber
    //   k := self kindOf: aNumber.
    //   k == #float    ifTrue: [^self asFloat * aNumber].
    //   k == #fraction ifTrue: [
    //     ^Fraction numerator: numerator * aNumber numerator
    //              denominator: denominator * aNumber denominator
    //   ].
    //   ^Fraction numerator: numerator * aNumber denominator: denominator
    try defineMethod(c, fraction_class, "*", &.{"aNumber"}, &.{"k"}, &.{
        try assignNode(c, "k", try send(c, try varRef(c, "self"), "kindOf:", &.{try varRef(c, "aNumber")})),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "float"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), "*", &.{try varRef(c, "aNumber")})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "fraction"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
                    try send(c, try varRef(c, "numerator"), "*", &.{try send(c, try varRef(c, "aNumber"), "numerator", &.{})}),
                    try send(c, try varRef(c, "denominator"), "*", &.{try send(c, try varRef(c, "aNumber"), "denominator", &.{})}),
                })),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
            try send(c, try varRef(c, "numerator"), "*", &.{try varRef(c, "aNumber")}),
            try varRef(c, "denominator"),
        })),
    });

    // Fraction>>/ aNumber
    //   k := self kindOf: aNumber.
    //   k == #float    ifTrue: [^self asFloat / aNumber].
    //   k == #fraction ifTrue: [
    //     ^Fraction numerator: numerator * aNumber denominator
    //              denominator: denominator * aNumber numerator
    //   ].
    //   ^Fraction numerator: numerator denominator: denominator * aNumber
    try defineMethod(c, fraction_class, "/", &.{"aNumber"}, &.{"k"}, &.{
        try assignNode(c, "k", try send(c, try varRef(c, "self"), "kindOf:", &.{try varRef(c, "aNumber")})),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "float"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), "/", &.{try varRef(c, "aNumber")})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "fraction"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
                    try send(c, try varRef(c, "numerator"), "*", &.{try send(c, try varRef(c, "aNumber"), "denominator", &.{})}),
                    try send(c, try varRef(c, "denominator"), "*", &.{try send(c, try varRef(c, "aNumber"), "numerator", &.{})}),
                })),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
            try varRef(c, "numerator"),
            try send(c, try varRef(c, "denominator"), "*", &.{try varRef(c, "aNumber")}),
        })),
    });

    // Fraction>>= aNumber
    //   k := self kindOf: aNumber.
    //   k == #float    ifTrue: [^self asFloat = aNumber].
    //   k == #fraction ifTrue: [
    //     ^(numerator * aNumber denominator) = (aNumber numerator * denominator)
    //   ].
    //   ^numerator = (aNumber * denominator)
    try defineMethod(c, fraction_class, "=", &.{"aNumber"}, &.{"k"}, &.{
        try assignNode(c, "k", try send(c, try varRef(c, "self"), "kindOf:", &.{try varRef(c, "aNumber")})),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "float"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), "=", &.{try varRef(c, "aNumber")})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "fraction"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c,
                    try send(c, try varRef(c, "numerator"), "*", &.{try send(c, try varRef(c, "aNumber"), "denominator", &.{})}),
                    "=",
                    &.{try send(c, try send(c, try varRef(c, "aNumber"), "numerator", &.{}), "*", &.{try varRef(c, "denominator")})},
                )),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "numerator"), "=", &.{
            try send(c, try varRef(c, "aNumber"), "*", &.{try varRef(c, "denominator")}),
        })),
    });

    // Fraction>>< aNumber
    //   k := self kindOf: aNumber.
    //   k == #float    ifTrue: [^self asFloat < aNumber].
    //   k == #fraction ifTrue: [
    //     ^(numerator * aNumber denominator) < (aNumber numerator * denominator)
    //   ].
    //   ^numerator < (aNumber * denominator)
    try defineMethod(c, fraction_class, "<", &.{"aNumber"}, &.{"k"}, &.{
        try assignNode(c, "k", try send(c, try varRef(c, "self"), "kindOf:", &.{try varRef(c, "aNumber")})),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "float"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), "<", &.{try varRef(c, "aNumber")})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "k"), "==", &.{try lit(c, try dict.newSymbol(c.heap, c.g, "fraction"))}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try ret(c, try send(c,
                    try send(c, try varRef(c, "numerator"), "*", &.{try send(c, try varRef(c, "aNumber"), "denominator", &.{})}),
                    "<",
                    &.{try send(c, try send(c, try varRef(c, "aNumber"), "numerator", &.{}), "*", &.{try varRef(c, "denominator")})},
                )),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "numerator"), "<", &.{
            try send(c, try varRef(c, "aNumber"), "*", &.{try varRef(c, "denominator")}),
        })),
    });

    // Fraction>>>  aN  ^(self < aN) not and: [(self = aN) not]
    try defineMethod(c, fraction_class, ">", &.{"aN"}, &.{}, &.{
        try ret(c, try send(c,
            try send(c, try send(c, try varRef(c, "self"), "<", &.{try varRef(c, "aN")}), "not", &.{}),
            "and:",
            &.{try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "self"), "=", &.{try varRef(c, "aN")}), "not", &.{}),
            })},
        )),
    });
    // Fraction>><=  aN  ^(self > aN) not
    try defineMethod(c, fraction_class, "<=", &.{"aN"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), ">", &.{try varRef(c, "aN")}), "not", &.{})),
    });
    // Fraction>>>=  aN  ^(self < aN) not
    try defineMethod(c, fraction_class, ">=", &.{"aN"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "<", &.{try varRef(c, "aN")}), "not", &.{})),
    });

    // Fraction>>asFloat  ^numerator asFloat / denominator asFloat
    try defineMethod(c, fraction_class, "asFloat", &.{}, &.{}, &.{
        try ret(c, try send(c,
            try send(c, try varRef(c, "numerator"), "asFloat", &.{}),
            "/",
            &.{try send(c, try varRef(c, "denominator"), "asFloat", &.{})},
        )),
    });

    // Fraction>>printOn: aStream
    //   aStream nextPutAll: numerator printString.
    //   aStream nextPutAll: '/'.
    //   aStream nextPutAll: denominator printString
    try defineMethod(c, fraction_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
            try send(c, try varRef(c, "numerator"), "printString", &.{}),
        }),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "/")}),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
            try send(c, try varRef(c, "denominator"), "printString", &.{}),
        }),
    });

    // Fraction>>negated  ^Fraction numerator: 0 - numerator denominator: denominator
    try defineMethod(c, fraction_class, "negated", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "Fraction"), "numerator:denominator:", &.{
            try send(c, try litInt(c, 0), "-", &.{try varRef(c, "numerator")}),
            try varRef(c, "denominator"),
        })),
    });

    // ---- Collection abstract class ----
    //
    // Iteration combinators that depend only on the abstract `do:`
    // method live here. Subclasses (OrderedCollection, Dictionary,
    // Array, Interval, ...) provide do: + size, then inherit the
    // rest for free. Phase C.8 reparents Array/OC/Interval through
    // SequenceableCollection; for now they go directly under
    // Collection.
    const collection_class = try defineClassAndRegister(heap, g, "Collection", g.object_class, &.{});

    // Collection>>isEmpty  ^self size = 0
    try defineMethod(c, collection_class, "isEmpty", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "size", &.{}), "=", &.{try litInt(c, 0)})),
    });

    // Collection>>collect: aBlock
    //   | r |
    //   r := OrderedCollection new init.
    //   self do: [:x | r add: (aBlock value: x)].
    //   ^r
    try defineMethod(c, collection_class, "collect:", &.{"aBlock"}, &.{"r"}, &.{
        try assignNode(c, "r", try send(c, try send(c, try varRef(c, "OrderedCollection"), "new", &.{}), "init", &.{})),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try varRef(c, "r"), "add:", &.{
                    try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}),
                }),
            }),
        }),
        try ret(c, try varRef(c, "r")),
    });

    try defineMethod(c, collection_class, "select:", &.{"aBlock"}, &.{"r"}, &.{
        try assignNode(c, "r", try send(c, try send(c, try varRef(c, "OrderedCollection"), "new", &.{}), "init", &.{})),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "r"), "add:", &.{try varRef(c, "x")}),
                    }),
                }),
            }),
        }),
        try ret(c, try varRef(c, "r")),
    });

    try defineMethod(c, collection_class, "reject:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "select:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}), "not", &.{}),
            }),
        })),
    });

    try defineMethod(c, collection_class, "inject:into:", &.{ "initial", "aBlock" }, &.{"acc"}, &.{
        try assignNode(c, "acc", try varRef(c, "initial")),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try assignNode(c, "acc", try send(c, try varRef(c, "aBlock"), "value:value:", &.{
                    try varRef(c, "acc"),
                    try varRef(c, "x"),
                })),
            }),
        }),
        try ret(c, try varRef(c, "acc")),
    });

    try defineMethod(c, collection_class, "includes:", &.{"x"}, &.{}, &.{
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"each"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "each"), "=", &.{try varRef(c, "x")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try ret(c, try litTrue(c))}),
                }),
            }),
        }),
        try ret(c, try litFalse(c)),
    });

    try defineMethod(c, collection_class, "count:", &.{"aBlock"}, &.{"n"}, &.{
        try assignNode(c, "n", try litInt(c, 0)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try assignNode(c, "n", try send(c, try varRef(c, "n"), "+", &.{try litInt(c, 1)})),
                    }),
                }),
            }),
        }),
        try ret(c, try varRef(c, "n")),
    });

    // do:separatedBy: aBlock between: separatorBlock
    //   | first |
    //   first := true.
    //   self do: [:x | first ifFalse: [separatorBlock value]. aBlock value: x. first := false]
    try defineMethod(c, collection_class, "do:separatedBy:", &.{ "aBlock", "separatorBlock" }, &.{"first"}, &.{
        try assignNode(c, "first", try litTrue(c)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "first"), "not", &.{}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "separatorBlock"), "value", &.{})}),
                }),
                try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}),
                try assignNode(c, "first", try litFalse(c)),
            }),
        }),
    });

    // detect: aBlock ifNone: noneBlock
    //   self do: [:x | (aBlock value: x) ifTrue: [^x]].
    //   ^noneBlock value
    try defineMethod(c, collection_class, "detect:ifNone:", &.{ "aBlock", "noneBlock" }, &.{}, &.{
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try ret(c, try varRef(c, "x"))}),
                }),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "noneBlock"), "value", &.{})),
    });

    // detect: aBlock  ^self detect: aBlock ifNone: [Exception new signal: 'not found']
    try defineMethod(c, collection_class, "detect:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "detect:ifNone:", &.{
            try varRef(c, "aBlock"),
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "Exception"), "new", &.{}), "signal:", &.{try litString(c, "not found")}),
            }),
        })),
    });

    // anySatisfy: aBlock  ^(self detect: aBlock ifNone: [nil]) isNil not
    // Simpler: walk and return true on first match.
    try defineMethod(c, collection_class, "anySatisfy:", &.{"aBlock"}, &.{}, &.{
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try ret(c, try litTrue(c))}),
                }),
            }),
        }),
        try ret(c, try litFalse(c)),
    });

    try defineMethod(c, collection_class, "allSatisfy:", &.{"aBlock"}, &.{}, &.{
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "x")}), "not", &.{}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try ret(c, try litFalse(c))}),
                }),
            }),
        }),
        try ret(c, try litTrue(c)),
    });

    try defineMethod(c, collection_class, "noneSatisfy:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "anySatisfy:", &.{try varRef(c, "aBlock")}), "not", &.{})),
    });

    // sum  ^self inject: 0 into: [:a :x | a + x]
    try defineMethod(c, collection_class, "sum", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "inject:into:", &.{
            try litInt(c, 0),
            try block(c, &.{ "a", "x" }, &.{}, &.{
                try send(c, try varRef(c, "a"), "+", &.{try varRef(c, "x")}),
            }),
        })),
    });

    // max  ^self inject: self first into: [:a :x | a max: x]
    // (hand-rolled to avoid empty-collection corner case if first is missing)
    try defineMethod(c, collection_class, "max", &.{}, &.{"r"}, &.{
        try assignNode(c, "r", try litNil(c)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "r"), "==", &.{try litNil(c)}), "ifTrue:ifFalse:", &.{
                    try block(c, &.{}, &.{}, &.{try assignNode(c, "r", try varRef(c, "x"))}),
                    try block(c, &.{}, &.{}, &.{
                        try assignNode(c, "r", try send(c, try varRef(c, "r"), "max:", &.{try varRef(c, "x")})),
                    }),
                }),
            }),
        }),
        try ret(c, try varRef(c, "r")),
    });

    try defineMethod(c, collection_class, "min", &.{}, &.{"r"}, &.{
        try assignNode(c, "r", try litNil(c)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "r"), "==", &.{try litNil(c)}), "ifTrue:ifFalse:", &.{
                    try block(c, &.{}, &.{}, &.{try assignNode(c, "r", try varRef(c, "x"))}),
                    try block(c, &.{}, &.{}, &.{
                        try assignNode(c, "r", try send(c, try varRef(c, "r"), "min:", &.{try varRef(c, "x")})),
                    }),
                }),
            }),
        }),
        try ret(c, try varRef(c, "r")),
    });

    // asOrderedCollection  ^self collect: [:x | x]   (slow but works)
    try defineMethod(c, collection_class, "asOrderedCollection", &.{}, &.{"r"}, &.{
        try assignNode(c, "r", try send(c, try send(c, try varRef(c, "OrderedCollection"), "new", &.{}), "init", &.{})),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try varRef(c, "r"), "add:", &.{try varRef(c, "x")}),
            }),
        }),
        try ret(c, try varRef(c, "r")),
    });

    // ---- SequenceableCollection ----
    //
    // Indexed (1-based) collections. Subclasses (OrderedCollection,
    // Array, Interval) provide at:, at:put:, do:, size. They inherit
    // first, last, , (concat), and Collection's iteration combinators.
    const sequenceable_class = try defineClassAndRegister(heap, g, "SequenceableCollection", collection_class, &.{});

    try defineMethod(c, sequenceable_class, "first", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "at:", &.{try litInt(c, 1)})),
    });
    try defineMethod(c, sequenceable_class, "last", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "at:", &.{try send(c, try varRef(c, "self"), "size", &.{})})),
    });

    // , aCollection  ^OC of self followed by aCollection
    try defineMethod(c, sequenceable_class, ",", &.{"aCollection"}, &.{"r"}, &.{
        try assignNode(c, "r", try send(c, try send(c, try varRef(c, "OrderedCollection"), "new", &.{}), "init", &.{})),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try varRef(c, "r"), "add:", &.{try varRef(c, "x")}),
            }),
        }),
        try send(c, try varRef(c, "aCollection"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try varRef(c, "r"), "add:", &.{try varRef(c, "x")}),
            }),
        }),
        try ret(c, try varRef(c, "r")),
    });

    // Reparent Array, Interval to SequenceableCollection.
    object.setSlot(g.array_class, object.SLOT_SUPERCLASS, sequenceable_class);
    object.setSlot(object.headerOf(g.array_class).class, object.SLOT_SUPERCLASS, object.headerOf(sequenceable_class).class);
    object.setSlot(interval_class, object.SLOT_SUPERCLASS, sequenceable_class);
    object.setSlot(object.headerOf(interval_class).class, object.SLOT_SUPERCLASS, object.headerOf(sequenceable_class).class);

    // ---- WriteStream ----
    //
    // A streaming String builder. Holds a single ivar `contents`,
    // grown by repeated String concatenation. Phase B.6 wires
    // printOn: through it; for now exists with the bare protocol.
    const write_stream_class = try defineClassAndRegister(heap, g, "WriteStream", g.object_class, &.{"contents"});

    // WriteStream>>setContents: aString  contents := aString. ^self
    try defineMethod(c, write_stream_class, "setContents:", &.{"aString"}, &.{}, &.{
        try assignNode(c, "contents", try varRef(c, "aString")),
        try ret(c, try varRef(c, "self")),
    });

    // WriteStream class>>new  ^super new setContents: ''
    const ws_meta = object.headerOf(write_stream_class).class;
    try defineMethod(c, ws_meta, "new", &.{}, &.{}, &.{
        try ret(c, try send(c, try superSend(c, "new", &.{}), "setContents:", &.{try litString(c, "")})),
    });

    // WriteStream class>>on: aString  ^self new setContents: aString
    try defineMethod(c, ws_meta, "on:", &.{"aString"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "new", &.{}), "setContents:", &.{try varRef(c, "aString")})),
    });

    // WriteStream>>nextPutAll: aString
    //   contents := contents , aString. ^self
    try defineMethod(c, write_stream_class, "nextPutAll:", &.{"aString"}, &.{}, &.{
        try assignNode(c, "contents", try send(c, try varRef(c, "contents"), ",", &.{try varRef(c, "aString")})),
        try ret(c, try varRef(c, "self")),
    });

    // WriteStream>>nextPut: aChar  (alias to nextPutAll: until we have Character)
    try defineMethod(c, write_stream_class, "nextPut:", &.{"aChar"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "nextPutAll:", &.{try varRef(c, "aChar")})),
    });

    // WriteStream>>contents  ^contents
    try defineMethod(c, write_stream_class, "contents", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "contents")),
    });

    // WriteStream>>nl    nextPutAll: a newline
    // WriteStream>>space nextPutAll: a space
    // WriteStream>>tab   nextPutAll: a tab
    try defineMethod(c, write_stream_class, "nl", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "nextPutAll:", &.{try litString(c, "\n")})),
    });
    try defineMethod(c, write_stream_class, "space", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "nextPutAll:", &.{try litString(c, " ")})),
    });
    try defineMethod(c, write_stream_class, "tab", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "nextPutAll:", &.{try litString(c, "\t")})),
    });

    // Boolean>>not — abstract; concrete versions on True/False below.
    try defineMethod(c, g.true_class, "not", &.{}, &.{}, &.{
        try ret(c, try litFalse(c)),
    });
    try defineMethod(c, g.false_class, "not", &.{}, &.{}, &.{
        try ret(c, try litTrue(c)),
    });

    // Lazy short-circuit boolean operators.
    //   true  and: aBlock  → aBlock value
    //   false and: aBlock  → false
    //   true  or:  aBlock  → true
    //   false or:  aBlock  → aBlock value
    try defineMethod(c, g.true_class, "and:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "aBlock"), "value", &.{})),
    });
    try defineMethod(c, g.false_class, "and:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try litFalse(c)),
    });
    try defineMethod(c, g.true_class, "or:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try litTrue(c)),
    });
    try defineMethod(c, g.false_class, "or:", &.{"aBlock"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "aBlock"), "value", &.{})),
    });

    // ---- String character-level operations ----
    //
    // Built on String>>at:, size, and String class>>fromCharCode:.
    // Pure Smalltalk implementations using WriteStream for output
    // accumulation.

    // String>>do: aBlock — iterate over char codes (SmallIntegers).
    try defineMethod(c, g.string_class, "do:", &.{"aBlock"}, &.{}, &.{
        try send(c, try litInt(c, 1), "to:do:", &.{
            try send(c, try varRef(c, "self"), "size", &.{}),
            try block(c, &.{"i"}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{
                    try send(c, try varRef(c, "self"), "at:", &.{try varRef(c, "i")}),
                }),
            }),
        }),
    });

    // String>>asUppercase — shift lowercase ascii to upper.
    try defineMethod(c, g.string_class, "asUppercase", &.{}, &.{ "ws", "c" }, &.{
        try assignNode(c, "ws", try send(c, try varRef(c, "WriteStream"), "new", &.{})),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"c"}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "c"), ">=", &.{try litInt(c, 97)}), "and:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "c"), "<=", &.{try litInt(c, 122)}),
                    }),
                }), "ifTrue:ifFalse:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "ws"), "nextPutAll:", &.{
                            try send(c, try varRef(c, "String"), "fromCharCode:", &.{
                                try send(c, try varRef(c, "c"), "-", &.{try litInt(c, 32)}),
                            }),
                        }),
                    }),
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "ws"), "nextPutAll:", &.{
                            try send(c, try varRef(c, "String"), "fromCharCode:", &.{try varRef(c, "c")}),
                        }),
                    }),
                }),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "ws"), "contents", &.{})),
    });

    // String>>asLowercase — mirror of asUppercase.
    try defineMethod(c, g.string_class, "asLowercase", &.{}, &.{ "ws", "c" }, &.{
        try assignNode(c, "ws", try send(c, try varRef(c, "WriteStream"), "new", &.{})),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"c"}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "c"), ">=", &.{try litInt(c, 65)}), "and:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "c"), "<=", &.{try litInt(c, 90)}),
                    }),
                }), "ifTrue:ifFalse:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "ws"), "nextPutAll:", &.{
                            try send(c, try varRef(c, "String"), "fromCharCode:", &.{
                                try send(c, try varRef(c, "c"), "+", &.{try litInt(c, 32)}),
                            }),
                        }),
                    }),
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "ws"), "nextPutAll:", &.{
                            try send(c, try varRef(c, "String"), "fromCharCode:", &.{try varRef(c, "c")}),
                        }),
                    }),
                }),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "ws"), "contents", &.{})),
    });

    // String>>indexOf: aCharCode — return 1-based index or 0 if absent.
    try defineMethod(c, g.string_class, "indexOf:", &.{"aChar"}, &.{}, &.{
        try send(c, try litInt(c, 1), "to:do:", &.{
            try send(c, try varRef(c, "self"), "size", &.{}),
            try block(c, &.{"i"}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "self"), "at:", &.{try varRef(c, "i")}), "=", &.{try varRef(c, "aChar")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try ret(c, try varRef(c, "i"))}),
                }),
            }),
        }),
        try ret(c, try litInt(c, 0)),
    });

    // String>>copyFrom: start to: stop — substring (1-based, inclusive).
    try defineMethod(c, g.string_class, "copyFrom:to:", &.{ "start", "stop" }, &.{"ws"}, &.{
        try assignNode(c, "ws", try send(c, try varRef(c, "WriteStream"), "new", &.{})),
        try send(c, try varRef(c, "start"), "to:do:", &.{
            try varRef(c, "stop"),
            try block(c, &.{"i"}, &.{}, &.{
                try send(c, try varRef(c, "ws"), "nextPutAll:", &.{
                    try send(c, try varRef(c, "String"), "fromCharCode:", &.{
                        try send(c, try varRef(c, "self"), "at:", &.{try varRef(c, "i")}),
                    }),
                }),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "ws"), "contents", &.{})),
    });

    // ---- printOn: protocol ----
    //
    // Object>>printString builds a WriteStream and calls self printOn:
    // on it. Object>>printOn: defaults to "a ClassName". Subclasses
    // override printOn: to control their printed form. This replaces
    // the Zig-side print.zig dispatch for Smalltalk-level printing
    // (printNl now sends printString).

    // Object>>printString
    //   | ws |
    //   ws := WriteStream new.
    //   self printOn: ws.
    //   ^ws contents
    try defineMethod(c, g.object_class, "printString", &.{}, &.{"ws"}, &.{
        try assignNode(c, "ws", try send(c, try varRef(c, "WriteStream"), "new", &.{})),
        try send(c, try varRef(c, "self"), "printOn:", &.{try varRef(c, "ws")}),
        try ret(c, try send(c, try varRef(c, "ws"), "contents", &.{})),
    });

    // Object>>printOn: aStream
    //   aStream nextPutAll: 'a '.
    //   aStream nextPutAll: self class name
    try defineMethod(c, g.object_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "a ")}),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
            try send(c, try send(c, try varRef(c, "self"), "class", &.{}), "name", &.{}),
        }),
    });

    // SmallInteger>>printOn: aStream  ^aStream nextPutAll: self asString
    try defineMethod(c, g.smallinteger_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
            try send(c, try varRef(c, "self"), "asString", &.{}),
        }),
    });

    // SmallFloat>>printOn: aStream  ^aStream nextPutAll: self asString
    try defineMethod(c, g.small_float_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
            try send(c, try varRef(c, "self"), "asString", &.{}),
        }),
    });

    // SmallFloat>>asFloat  ^self
    try defineMethod(c, g.small_float_class, "asFloat", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "self")),
    });

    // Math wrappers on Number — delegate to Float primitives via
    // asFloat, so 4 sqrt and (1/2) ln work too.
    inline for (.{ "sqrt", "sin", "cos", "ln", "exp" }) |op| {
        try defineMethod(c, number_class, op, &.{}, &.{}, &.{
            try ret(c, try send(c, try send(c, try varRef(c, "self"), "asFloat", &.{}), op, &.{})),
        });
    }

    // SmallFloat class>>pi  ^3.141592653589793
    // SmallFloat class>>e   ^2.718281828459045
    const small_float_meta = object.headerOf(g.small_float_class).class;
    try defineMethod(c, small_float_meta, "pi", &.{}, &.{}, &.{
        try ret(c, try lit(c, oop_mod.fromF64(3.141592653589793))),
    });
    try defineMethod(c, small_float_meta, "e", &.{}, &.{}, &.{
        try ret(c, try lit(c, oop_mod.fromF64(2.718281828459045))),
    });

    // Large{Positive,Negative}Integer>>printOn: aStream
    inline for (.{ g.large_positive_integer_class, g.large_negative_integer_class }) |large_cls| {
        try defineMethod(c, large_cls, "printOn:", &.{"aStream"}, &.{}, &.{
            try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
                try send(c, try varRef(c, "self"), "asString", &.{}),
            }),
        });
    }

    // String>>printOn: writes with single-quote delimiters (no escape
    // for v1; embedded quotes will look ugly but readable enough).
    try defineMethod(c, g.string_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "'")}),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try varRef(c, "self")}),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "'")}),
    });

    // Symbol>>printOn: writes with leading #.
    try defineMethod(c, g.symbol_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "#")}),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try varRef(c, "self")}),
    });

    // True>>printOn:, False>>printOn:, UndefinedObject>>printOn:
    try defineMethod(c, g.true_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "true")}),
    });
    try defineMethod(c, g.false_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "false")}),
    });
    try defineMethod(c, g.undefined_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "nil")}),
    });

    // Class>>printOn: aStream  aStream nextPutAll: self name
    try defineMethod(c, g.class_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{
            try send(c, try varRef(c, "self"), "name", &.{}),
        }),
    });

    // BlockClosure>>printOn: aStream  aStream nextPutAll: 'a BlockClosure'
    try defineMethod(c, g.block_closure_class, "printOn:", &.{"aStream"}, &.{}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "a BlockClosure")}),
    });

    // Array>>do: aBlock
    //   | i |
    //   i := 1.
    //   [i <= self size] whileTrue: [aBlock value: (self at: i). i := i + 1]
    try defineMethod(c, g.array_class, "do:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try send(c, try varRef(c, "self"), "size", &.{})}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{
                    try send(c, try varRef(c, "self"), "at:", &.{try varRef(c, "i")}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // Array>>printOn: aStream
    //   | first |
    //   aStream nextPutAll: '#('.
    //   first := true.
    //   self do: [:x |
    //     first ifFalse: [aStream space].
    //     x printOn: aStream.
    //     first := false].
    //   aStream nextPutAll: ')'
    try defineMethod(c, g.array_class, "printOn:", &.{"aStream"}, &.{"first"}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "#(")}),
        try assignNode(c, "first", try litTrue(c)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "first"), "not", &.{}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "aStream"), "space", &.{})}),
                }),
                try send(c, try varRef(c, "x"), "printOn:", &.{try varRef(c, "aStream")}),
                try assignNode(c, "first", try litFalse(c)),
            }),
        }),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, ")")}),
    });

    // ---- HashedCollection ----
    //
    // Abstract parent of unordered key-based collections. Currently
    // empty — reserved for hash-aware methods (`removeKey:`, etc.)
    // when we have value-equality + hash. For now Dictionary and Set
    // live here mostly to make the hierarchy match Smalltalk-80.
    const hashed_class = try defineClassAndRegister(heap, g, "HashedCollection", collection_class, &.{});

    // Reparent Dictionary to HashedCollection.
    object.setSlot(g.dictionary_class, object.SLOT_SUPERCLASS, hashed_class);
    object.setSlot(object.headerOf(g.dictionary_class).class, object.SLOT_SUPERCLASS, object.headerOf(hashed_class).class);

    // ---- Dictionary (user-facing) ----
    //
    // The kernel's Dictionary class already exists and is used by
    // Smalltalk + every methodDict. We retrofit ivar names ("keys",
    // "values", "count") and install Smalltalk methods on top, so
    // user-facing dictionary code works on the same class.
    //
    // CAVEAT: kernel dicts (Smalltalk, methodDicts) are managed by
    // dict.zig directly via slot indices. Calling `init` on them
    // would re-initialize and break them. User code creates new
    // dictionaries with `Dictionary new init`.
    //
    // Identity-based key comparison via ==. Matches our existing
    // semantics; works for SmallIntegers and interned Symbols.
    {
        const dict_ivars = try c.heap.allocSlots(c.g.array_class, 3);
        object.setSlot(dict_ivars, 0, try dict.newSymbol(c.heap, c.g, "keys"));
        object.setSlot(dict_ivars, 1, try dict.newSymbol(c.heap, c.g, "values"));
        object.setSlot(dict_ivars, 2, try dict.newSymbol(c.heap, c.g, "count"));
        object.setSlot(c.g.dictionary_class, object.SLOT_CLASS_IVAR_NAMES, dict_ivars);
    }

    const dict_class = c.g.dictionary_class;

    // init
    //   keys := Array new: 8.
    //   values := Array new: 8.
    //   count := 0
    try defineMethod(c, dict_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "keys", try send(c, try varRef(c, "Array"), "new:", &.{try litInt(c, 8)})),
        try assignNode(c, "values", try send(c, try varRef(c, "Array"), "new:", &.{try litInt(c, 8)})),
        try assignNode(c, "count", try litInt(c, 0)),
    });

    // size  ^count
    try defineMethod(c, dict_class, "size", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "count")),
    });

    // isEmpty inherited from Collection (uses self size = 0).

    // includesKey: k
    //   | i |
    //   i := 1.
    //   [i <= count] whileTrue: [
    //     (keys at: i) == k ifTrue: [^true].
    //     i := i + 1
    //   ].
    //   ^false
    try defineMethod(c, dict_class, "includesKey:", &.{"k"}, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "keys"), "at:", &.{try varRef(c, "i")}), "==", &.{try varRef(c, "k")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try ret(c, try litTrue(c))}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
        try ret(c, try litFalse(c)),
    });

    // at: k ifAbsent: aBlock
    //   | i |
    //   i := 1.
    //   [i <= count] whileTrue: [
    //     (keys at: i) == k ifTrue: [^values at: i].
    //     i := i + 1
    //   ].
    //   ^aBlock value
    try defineMethod(c, dict_class, "at:ifAbsent:", &.{ "k", "aBlock" }, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "keys"), "at:", &.{try varRef(c, "i")}), "==", &.{try varRef(c, "k")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try ret(c, try send(c, try varRef(c, "values"), "at:", &.{try varRef(c, "i")})),
                    }),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
        try ret(c, try send(c, try varRef(c, "aBlock"), "value", &.{})),
    });

    // at: k
    //   ^self at: k ifAbsent: [Exception new signal: 'key not found']
    try defineMethod(c, dict_class, "at:", &.{"k"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "at:ifAbsent:", &.{
            try varRef(c, "k"),
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "Exception"), "new", &.{}), "signal:", &.{try litString(c, "key not found")}),
            }),
        })),
    });

    // grow
    //   | newKeys newValues i |
    //   newKeys := Array new: keys size * 2.
    //   newValues := Array new: values size * 2.
    //   i := 1.
    //   [i <= count] whileTrue: [
    //     newKeys at: i put: (keys at: i).
    //     newValues at: i put: (values at: i).
    //     i := i + 1
    //   ].
    //   keys := newKeys. values := newValues
    try defineMethod(c, dict_class, "grow", &.{}, &.{ "newKeys", "newValues", "i" }, &.{
        try assignNode(c, "newKeys", try send(c, try varRef(c, "Array"), "new:", &.{
            try send(c, try send(c, try varRef(c, "keys"), "size", &.{}), "*", &.{try litInt(c, 2)}),
        })),
        try assignNode(c, "newValues", try send(c, try varRef(c, "Array"), "new:", &.{
            try send(c, try send(c, try varRef(c, "values"), "size", &.{}), "*", &.{try litInt(c, 2)}),
        })),
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "newKeys"), "at:put:", &.{
                    try varRef(c, "i"),
                    try send(c, try varRef(c, "keys"), "at:", &.{try varRef(c, "i")}),
                }),
                try send(c, try varRef(c, "newValues"), "at:put:", &.{
                    try varRef(c, "i"),
                    try send(c, try varRef(c, "values"), "at:", &.{try varRef(c, "i")}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
        try assignNode(c, "keys", try varRef(c, "newKeys")),
        try assignNode(c, "values", try varRef(c, "newValues")),
    });

    // at: k put: v
    //   | i |
    //   i := 1.
    //   [i <= count] whileTrue: [
    //     (keys at: i) == k ifTrue: [values at: i put: v. ^v].
    //     i := i + 1
    //   ].
    //   count == keys size ifTrue: [self grow].
    //   count := count + 1.
    //   keys at: count put: k.
    //   values at: count put: v.
    //   ^v
    try defineMethod(c, dict_class, "at:put:", &.{ "k", "v" }, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try send(c, try send(c, try varRef(c, "keys"), "at:", &.{try varRef(c, "i")}), "==", &.{try varRef(c, "k")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "values"), "at:put:", &.{ try varRef(c, "i"), try varRef(c, "v") }),
                        try ret(c, try varRef(c, "v")),
                    }),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
        try send(c, try send(c, try varRef(c, "count"), "==", &.{try send(c, try varRef(c, "keys"), "size", &.{})}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "self"), "grow", &.{}),
            }),
        }),
        try assignNode(c, "count", try send(c, try varRef(c, "count"), "+", &.{try litInt(c, 1)})),
        try send(c, try varRef(c, "keys"), "at:put:", &.{ try varRef(c, "count"), try varRef(c, "k") }),
        try send(c, try varRef(c, "values"), "at:put:", &.{ try varRef(c, "count"), try varRef(c, "v") }),
        try ret(c, try varRef(c, "v")),
    });

    // do: aBlock  iterate over values
    try defineMethod(c, dict_class, "do:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{try send(c, try varRef(c, "values"), "at:", &.{try varRef(c, "i")})}),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // keysDo: aBlock  iterate over keys
    try defineMethod(c, dict_class, "keysDo:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{try send(c, try varRef(c, "keys"), "at:", &.{try varRef(c, "i")})}),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // keysAndValuesDo: aBlock
    try defineMethod(c, dict_class, "keysAndValuesDo:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try litInt(c, 1)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "count")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:value:", &.{
                    try send(c, try varRef(c, "keys"), "at:", &.{try varRef(c, "i")}),
                    try send(c, try varRef(c, "values"), "at:", &.{try varRef(c, "i")}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // Dictionary>>printOn: aStream
    //   | first |
    //   aStream nextPutAll: 'Dict('.
    //   first := true.
    //   self keysAndValuesDo: [:k :v |
    //     first ifFalse: [aStream space].
    //     k printOn: aStream.
    //     aStream nextPutAll: '->'.
    //     v printOn: aStream.
    //     first := false].
    //   aStream nextPutAll: ')'
    try defineMethod(c, dict_class, "printOn:", &.{"aStream"}, &.{"first"}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "Dict(")}),
        try assignNode(c, "first", try litTrue(c)),
        try send(c, try varRef(c, "self"), "keysAndValuesDo:", &.{
            try block(c, &.{ "k", "v" }, &.{}, &.{
                try send(c, try send(c, try varRef(c, "first"), "not", &.{}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "aStream"), "space", &.{})}),
                }),
                try send(c, try varRef(c, "k"), "printOn:", &.{try varRef(c, "aStream")}),
                try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "->")}),
                try send(c, try varRef(c, "v"), "printOn:", &.{try varRef(c, "aStream")}),
                try assignNode(c, "first", try litFalse(c)),
            }),
        }),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, ")")}),
    });

    // ---- Set ----
    //
    // Unordered collection of unique elements. v1 builds on top of
    // Dictionary using identity equality (Set elements compare via
    // ==, since Dictionary keys do). Switch to value equality once
    // Dictionary gains hash + =-based storage.
    const set_class = try defineClassAndRegister(heap, g, "Set", hashed_class, &.{"dict"});

    // Set>>init  dict := Dictionary new init. ^self
    try defineMethod(c, set_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "dict", try send(c, try send(c, try varRef(c, "Dictionary"), "new", &.{}), "init", &.{})),
        try ret(c, try varRef(c, "self")),
    });

    // Set>>add: x  dict at: x put: x. ^x
    try defineMethod(c, set_class, "add:", &.{"x"}, &.{}, &.{
        try send(c, try varRef(c, "dict"), "at:put:", &.{ try varRef(c, "x"), try varRef(c, "x") }),
        try ret(c, try varRef(c, "x")),
    });

    // Set>>includes: x  ^dict includesKey: x
    try defineMethod(c, set_class, "includes:", &.{"x"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "dict"), "includesKey:", &.{try varRef(c, "x")})),
    });

    // Set>>size  ^dict size
    try defineMethod(c, set_class, "size", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "dict"), "size", &.{})),
    });

    // Set>>do: aBlock  dict keysDo: aBlock
    try defineMethod(c, set_class, "do:", &.{"aBlock"}, &.{}, &.{
        try send(c, try varRef(c, "dict"), "keysDo:", &.{try varRef(c, "aBlock")}),
    });

    // Set>>printOn: aStream
    //   aStream nextPutAll: 'Set('. ... ')'.
    try defineMethod(c, set_class, "printOn:", &.{"aStream"}, &.{"first"}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "Set(")}),
        try assignNode(c, "first", try litTrue(c)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "first"), "not", &.{}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "aStream"), "space", &.{})}),
                }),
                try send(c, try varRef(c, "x"), "printOn:", &.{try varRef(c, "aStream")}),
                try assignNode(c, "first", try litFalse(c)),
            }),
        }),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, ")")}),
    });

    // ---- Bag ----
    //
    // Multiset — counts duplicate occurrences. Backed by a Dictionary
    // mapping element → count. add: x increments the count; size is
    // the sum across all entries; do: yields each element count times.
    const bag_class = try defineClassAndRegister(heap, g, "Bag", hashed_class, &.{"counts"});

    // Bag>>init  counts := Dictionary new init. ^self
    try defineMethod(c, bag_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "counts", try send(c, try send(c, try varRef(c, "Dictionary"), "new", &.{}), "init", &.{})),
        try ret(c, try varRef(c, "self")),
    });

    // Bag>>add: x
    //   | n |
    //   n := counts at: x ifAbsent: [0].
    //   counts at: x put: n + 1.
    //   ^x
    try defineMethod(c, bag_class, "add:", &.{"x"}, &.{"n"}, &.{
        try assignNode(c, "n", try send(c, try varRef(c, "counts"), "at:ifAbsent:", &.{
            try varRef(c, "x"),
            try block(c, &.{}, &.{}, &.{try litInt(c, 0)}),
        })),
        try send(c, try varRef(c, "counts"), "at:put:", &.{
            try varRef(c, "x"),
            try send(c, try varRef(c, "n"), "+", &.{try litInt(c, 1)}),
        }),
        try ret(c, try varRef(c, "x")),
    });

    // Bag>>occurrencesOf: x  ^counts at: x ifAbsent: [0]
    try defineMethod(c, bag_class, "occurrencesOf:", &.{"x"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "counts"), "at:ifAbsent:", &.{
            try varRef(c, "x"),
            try block(c, &.{}, &.{}, &.{try litInt(c, 0)}),
        })),
    });

    // Bag>>size  total count = sum of all values
    try defineMethod(c, bag_class, "size", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "counts"), "inject:into:", &.{
            try litInt(c, 0),
            try block(c, &.{ "a", "v" }, &.{}, &.{
                try send(c, try varRef(c, "a"), "+", &.{try varRef(c, "v")}),
            }),
        })),
    });

    // Bag>>do: aBlock — yield each element count-times.
    try defineMethod(c, bag_class, "do:", &.{"aBlock"}, &.{}, &.{
        try send(c, try varRef(c, "counts"), "keysAndValuesDo:", &.{
            try block(c, &.{ "k", "v" }, &.{}, &.{
                try send(c, try varRef(c, "v"), "timesRepeat:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "aBlock"), "value:", &.{try varRef(c, "k")}),
                    }),
                }),
            }),
        }),
    });

    // Bag>>do:withCount: aBlock — invoke per (element, count) pair.
    try defineMethod(c, bag_class, "do:withCount:", &.{"aBlock"}, &.{}, &.{
        try send(c, try varRef(c, "counts"), "keysAndValuesDo:", &.{
            try block(c, &.{ "k", "v" }, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:value:", &.{ try varRef(c, "k"), try varRef(c, "v") }),
            }),
        }),
    });

    // ---- OrderedCollection ----
    //
    // Three-ivar dynamic deque. `array` is the backing Array;
    // `firstIndex` and `lastIndex` mark the active 1-based range
    // (inclusive). Empty when firstIndex > lastIndex. Supports O(1)
    // add/remove at both ends; grows in either direction by doubling
    // and re-centring the live range.
    //
    // Inherits first, last, , from SequenceableCollection plus
    // collect:, select:, etc. from Collection.
    const oc = try defineClassAndRegister(heap, g, "OrderedCollection", sequenceable_class, &.{ "array", "firstIndex", "lastIndex" });

    // init  array := Array new: 8. firstIndex := 1. lastIndex := 0
    try defineMethod(c, oc, "init", &.{}, &.{}, &.{
        try assignNode(c, "array", try send(c, try varRef(c, "Array"), "new:", &.{try litInt(c, 8)})),
        try assignNode(c, "firstIndex", try litInt(c, 1)),
        try assignNode(c, "lastIndex", try litInt(c, 0)),
    });

    // size  ^lastIndex - firstIndex + 1
    try defineMethod(c, oc, "size", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "lastIndex"), "-", &.{try varRef(c, "firstIndex")}), "+", &.{try litInt(c, 1)})),
    });

    // at: i  ^array at: firstIndex + i - 1
    try defineMethod(c, oc, "at:", &.{"i"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "array"), "at:", &.{
            try send(c, try send(c, try varRef(c, "firstIndex"), "+", &.{try varRef(c, "i")}), "-", &.{try litInt(c, 1)}),
        })),
    });

    // growLast — when lastIndex == array size and we want to addLast:
    //   doubles capacity; existing elements stay at their indices.
    try defineMethod(c, oc, "growLast", &.{}, &.{ "newArr", "i" }, &.{
        try assignNode(c, "newArr", try send(c, try varRef(c, "Array"), "new:", &.{
            try send(c, try send(c, try varRef(c, "array"), "size", &.{}), "*", &.{try litInt(c, 2)}),
        })),
        try assignNode(c, "i", try varRef(c, "firstIndex")),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "lastIndex")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "newArr"), "at:put:", &.{
                    try varRef(c, "i"),
                    try send(c, try varRef(c, "array"), "at:", &.{try varRef(c, "i")}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
        try assignNode(c, "array", try varRef(c, "newArr")),
    });

    // growFirst — when firstIndex == 1 and we want to addFirst:
    //   doubles capacity; existing elements shift right by old size,
    //   so firstIndex/lastIndex move to the right portion of the new
    //   array, leaving room for prepends.
    try defineMethod(c, oc, "growFirst", &.{}, &.{ "newArr", "shift", "i" }, &.{
        try assignNode(c, "shift", try send(c, try varRef(c, "array"), "size", &.{})),
        try assignNode(c, "newArr", try send(c, try varRef(c, "Array"), "new:", &.{
            try send(c, try varRef(c, "shift"), "*", &.{try litInt(c, 2)}),
        })),
        try assignNode(c, "i", try varRef(c, "firstIndex")),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "lastIndex")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "newArr"), "at:put:", &.{
                    try send(c, try varRef(c, "i"), "+", &.{try varRef(c, "shift")}),
                    try send(c, try varRef(c, "array"), "at:", &.{try varRef(c, "i")}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
        try assignNode(c, "array", try varRef(c, "newArr")),
        try assignNode(c, "firstIndex", try send(c, try varRef(c, "firstIndex"), "+", &.{try varRef(c, "shift")})),
        try assignNode(c, "lastIndex", try send(c, try varRef(c, "lastIndex"), "+", &.{try varRef(c, "shift")})),
    });

    // addLast: x
    //   lastIndex == array size ifTrue: [self growLast].
    //   lastIndex := lastIndex + 1.
    //   array at: lastIndex put: x.
    //   ^x
    try defineMethod(c, oc, "addLast:", &.{"x"}, &.{}, &.{
        try send(c, try send(c, try varRef(c, "lastIndex"), "==", &.{
            try send(c, try varRef(c, "array"), "size", &.{}),
        }), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "self"), "growLast", &.{})}),
        }),
        try assignNode(c, "lastIndex", try send(c, try varRef(c, "lastIndex"), "+", &.{try litInt(c, 1)})),
        try send(c, try varRef(c, "array"), "at:put:", &.{ try varRef(c, "lastIndex"), try varRef(c, "x") }),
        try ret(c, try varRef(c, "x")),
    });

    // add: x  ^self addLast: x  (Smalltalk-80 alias)
    try defineMethod(c, oc, "add:", &.{"x"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "addLast:", &.{try varRef(c, "x")})),
    });

    // addFirst: x
    //   firstIndex == 1 ifTrue: [self growFirst].
    //   firstIndex := firstIndex - 1.
    //   array at: firstIndex put: x.
    //   ^x
    try defineMethod(c, oc, "addFirst:", &.{"x"}, &.{}, &.{
        try send(c, try send(c, try varRef(c, "firstIndex"), "==", &.{try litInt(c, 1)}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "self"), "growFirst", &.{})}),
        }),
        try assignNode(c, "firstIndex", try send(c, try varRef(c, "firstIndex"), "-", &.{try litInt(c, 1)})),
        try send(c, try varRef(c, "array"), "at:put:", &.{ try varRef(c, "firstIndex"), try varRef(c, "x") }),
        try ret(c, try varRef(c, "x")),
    });

    // removeLast
    //   | x |
    //   x := array at: lastIndex.
    //   lastIndex := lastIndex - 1.
    //   ^x
    try defineMethod(c, oc, "removeLast", &.{}, &.{"x"}, &.{
        try assignNode(c, "x", try send(c, try varRef(c, "array"), "at:", &.{try varRef(c, "lastIndex")})),
        try assignNode(c, "lastIndex", try send(c, try varRef(c, "lastIndex"), "-", &.{try litInt(c, 1)})),
        try ret(c, try varRef(c, "x")),
    });

    // removeFirst
    //   | x |
    //   x := array at: firstIndex.
    //   firstIndex := firstIndex + 1.
    //   ^x
    try defineMethod(c, oc, "removeFirst", &.{}, &.{"x"}, &.{
        try assignNode(c, "x", try send(c, try varRef(c, "array"), "at:", &.{try varRef(c, "firstIndex")})),
        try assignNode(c, "firstIndex", try send(c, try varRef(c, "firstIndex"), "+", &.{try litInt(c, 1)})),
        try ret(c, try varRef(c, "x")),
    });

    // do: aBlock
    //   | i |
    //   i := firstIndex.
    //   [i <= lastIndex] whileTrue: [aBlock value: (array at: i). i := i + 1]
    try defineMethod(c, oc, "do:", &.{"aBlock"}, &.{"i"}, &.{
        try assignNode(c, "i", try varRef(c, "firstIndex")),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "i"), "<=", &.{try varRef(c, "lastIndex")}),
        }), "whileTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "aBlock"), "value:", &.{
                    try send(c, try varRef(c, "array"), "at:", &.{try varRef(c, "i")}),
                }),
                try assignNode(c, "i", try send(c, try varRef(c, "i"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // OrderedCollection>>printOn: aStream
    //   | first |
    //   aStream nextPutAll: 'OC('.
    //   first := true.
    //   self do: [:x |
    //     first ifFalse: [aStream space].
    //     x printOn: aStream.
    //     first := false].
    //   aStream nextPutAll: ')'
    try defineMethod(c, oc, "printOn:", &.{"aStream"}, &.{"first"}, &.{
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, "OC(")}),
        try assignNode(c, "first", try litTrue(c)),
        try send(c, try varRef(c, "self"), "do:", &.{
            try block(c, &.{"x"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "first"), "not", &.{}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{try send(c, try varRef(c, "aStream"), "space", &.{})}),
                }),
                try send(c, try varRef(c, "x"), "printOn:", &.{try varRef(c, "aStream")}),
                try assignNode(c, "first", try litFalse(c)),
            }),
        }),
        try send(c, try varRef(c, "aStream"), "nextPutAll:", &.{try litString(c, ")")}),
    });

    // first, last inherited from SequenceableCollection.

    // collect:, select:, reject:, inject:into:, includes:, count:
    // all inherited from Collection.

    _ = try defineClassAndRegister(heap, g, "TestFailure", g.exception_class, &.{});
    const test_case = try defineClassAndRegister(heap, g, "TestCase", g.object_class, &.{});

    // TestCase>>fail: aString
    //   ^ TestFailure new signal: aString
    try defineMethod(c, test_case, "fail:", &.{"aString"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "TestFailure"), "new", &.{}), "signal:", &.{
            try varRef(c, "aString"),
        })),
    });

    // TestCase>>assert: aBoolean
    //   aBoolean == true ifFalse: [self fail: 'assertion failed']
    try defineMethod(c, test_case, "assert:", &.{"aBoolean"}, &.{}, &.{
        try send(c, try send(c, try varRef(c, "aBoolean"), "==", &.{try litTrue(c)}), "ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "self"), "fail:", &.{try litString(c, "assertion failed")}),
            }),
        }),
    });

    // TestCase>>assert: actual equals: expected
    //   actual == expected ifFalse: [self fail: 'expected equality']
    try defineMethod(c, test_case, "assert:equals:", &.{ "actual", "expected" }, &.{}, &.{
        try send(c, try send(c, try varRef(c, "actual"), "==", &.{try varRef(c, "expected")}), "ifFalse:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "self"), "fail:", &.{try litString(c, "expected equality")}),
            }),
        }),
    });

    // TestCase>>deny: aBoolean
    //   self assert: aBoolean not
    try defineMethod(c, test_case, "deny:", &.{"aBoolean"}, &.{}, &.{
        try send(c, try varRef(c, "self"), "assert:", &.{
            try send(c, try varRef(c, "aBoolean"), "not", &.{}),
        }),
    });

    // TestCase>>should: aBlock raise: aClass
    //   | caught |
    //   caught := false.
    //   [aBlock value] on: aClass do: [:e | caught := true].
    //   caught == false ifTrue: [self fail: 'expected exception not raised']
    try defineMethod(c, test_case, "should:raise:", &.{ "aBlock", "aClass" }, &.{"caught"}, &.{
        try assignNode(c, "caught", try litFalse(c)),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "aBlock"), "value", &.{}),
        }), "on:do:", &.{
            try varRef(c, "aClass"),
            try block(c, &.{"e"}, &.{}, &.{
                try assignNode(c, "caught", try litTrue(c)),
            }),
        }),
        try send(c, try send(c, try varRef(c, "caught"), "==", &.{try litFalse(c)}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "self"), "fail:", &.{try litString(c, "expected exception not raised")}),
            }),
        }),
    });

    const test_runner = try defineClassAndRegister(heap, g, "TestRunner", g.object_class, &.{ "passed", "failed" });

    // TestRunner>>init
    //   passed := 0. failed := 0
    try defineMethod(c, test_runner, "init", &.{}, &.{}, &.{
        try assignNode(c, "passed", try litInt(c, 0)),
        try assignNode(c, "failed", try litInt(c, 0)),
    });

    try defineMethod(c, test_runner, "passed", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "passed")),
    });
    try defineMethod(c, test_runner, "failed", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "failed")),
    });

    // TestRunner>>runOne: aClass selector: aString
    //   | tc |
    //   tc := aClass new.
    //   [tc perform: aString.
    //    ('PASS: ' , aString) printNl.
    //    passed := passed + 1
    //   ] on: Exception do: [:e |
    //    ('FAIL: ' , aString , ': ' , e messageText) printNl.
    //    failed := failed + 1
    //   ]
    try defineMethod(c, test_runner, "runOne:selector:", &.{ "aClass", "aString" }, &.{"tc"}, &.{
        try assignNode(c, "tc", try send(c, try varRef(c, "aClass"), "new", &.{})),
        try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "tc"), "perform:", &.{try varRef(c, "aString")}),
            try send(c, try send(c, try litString(c, "PASS: "), ",", &.{try varRef(c, "aString")}), "printNl", &.{}),
            try assignNode(c, "passed", try send(c, try varRef(c, "passed"), "+", &.{try litInt(c, 1)})),
        }), "on:do:", &.{
            try varRef(c, "Exception"),
            try block(c, &.{"e"}, &.{}, &.{
                try send(c, try send(c, try send(c, try send(c, try litString(c, "FAIL: "), ",", &.{try varRef(c, "aString")}), ",", &.{try litString(c, ": ")}), ",", &.{try send(c, try varRef(c, "e"), "messageText", &.{})}), "printNl", &.{}),
                try assignNode(c, "failed", try send(c, try varRef(c, "failed"), "+", &.{try litInt(c, 1)})),
            }),
        }),
    });

    // TestRunner>>runAll: aClass
    //   aClass selectors do: [:sel |
    //     (sel startsWith: 'test') ifTrue: [self runOne: aClass selector: sel]
    //   ]
    try defineMethod(c, test_runner, "runAll:", &.{"aClass"}, &.{}, &.{
        try send(c, try send(c, try varRef(c, "aClass"), "selectors", &.{}), "do:", &.{
            try block(c, &.{"sel"}, &.{}, &.{
                try send(c, try send(c, try varRef(c, "sel"), "startsWith:", &.{try litString(c, "test")}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try send(c, try varRef(c, "self"), "runOne:selector:", &.{
                            try varRef(c, "aClass"),
                            try varRef(c, "sel"),
                        }),
                    }),
                }),
            }),
        }),
    });
}

// Concurrency surface: Process, Semaphore, ProcessorScheduler, plus
// the Processor singleton bound in the Smalltalk dictionary. Methods
// that need raw VM state (fork, wait, signal, yield, ...) are
// installed as primitives by the bootstrap; the rest are AST methods
// here. Semantics today are placeholder-cooperative — no real
// stack switching yet — but the public protocol matches classic
// Smalltalk so the eventual scheduler doesn't change the surface.
pub fn loadConcurrency(heap: *Heap, g: *Globals) !void {
    const c = Ctx{ .heap = heap, .g = g };

    // Pre-intern state symbols. The fork/wait/signal primitives store
    // these directly into Process.state and read them back, so caching
    // a single canonical Oop per state keeps the dispatch path off
    // newSymbol on the hot path.
    g.sym_runnable = try dict.newSymbol(heap, g, "runnable");
    g.sym_suspended = try dict.newSymbol(heap, g, "suspended");
    g.sym_waiting = try dict.newSymbol(heap, g, "waiting");
    g.sym_terminated = try dict.newSymbol(heap, g, "terminated");

    // ---- Process ----
    const process_class = try defineClassAndRegister(
        heap,
        g,
        "Process",
        g.object_class,
        &.{
            "priority", "state",     "block",      "name",
            "nextLink", "result",    "suspendedContext",
            "savedFrame", "savedMethodFrame", "savedMethodClass",
            "deadline",
        },
    );
    g.process_class = process_class;

    try defineMethod(c, process_class, "priority", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "priority")),
    });
    try defineMethod(c, process_class, "state", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "state")),
    });
    try defineMethod(c, process_class, "name", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "name")),
    });
    try defineMethod(c, process_class, "name:", &.{"aName"}, &.{}, &.{
        try assignNode(c, "name", try varRef(c, "aName")),
        try ret(c, try varRef(c, "self")),
    });
    try defineMethod(c, process_class, "isTerminated", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "state"), "==", &.{try lit(c, g.sym_terminated)})),
    });

    // ---- Semaphore ----
    const semaphore_class = try defineClassAndRegister(
        heap,
        g,
        "Semaphore",
        g.object_class,
        &.{ "count", "waitersHead", "waitersTail" },
    );
    g.semaphore_class = semaphore_class;

    // Semaphore>>init  count := 0. waitersHead := nil. waitersTail := nil. ^self
    try defineMethod(c, semaphore_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "count", try litInt(c, 0)),
        try assignNode(c, "waitersHead", try litNil(c)),
        try assignNode(c, "waitersTail", try litNil(c)),
        try ret(c, try varRef(c, "self")),
    });

    // Semaphore class>>forMutualExclusion  ^self new init signal
    const sema_meta = object.headerOf(semaphore_class).class;
    try defineMethod(c, sema_meta, "forMutualExclusion", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try send(c, try varRef(c, "self"), "new", &.{}), "init", &.{}), "signal", &.{})),
    });

    // Semaphore>>critical: aBlock
    //   self wait. ^[aBlock value] ensure: [self signal]
    try defineMethod(c, semaphore_class, "critical:", &.{"aBlock"}, &.{}, &.{
        try send(c, try varRef(c, "self"), "wait", &.{}),
        try ret(c, try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "aBlock"), "value", &.{}),
        }), "ensure:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "self"), "signal", &.{}),
            }),
        })),
    });

    try defineMethod(c, semaphore_class, "count", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "count")),
    });

    // ---- ProcessorScheduler ----
    const scheduler_class = try defineClassAndRegister(
        heap,
        g,
        "ProcessorScheduler",
        g.object_class,
        &.{ "quiescentLists", "activeProcess", "delayHead" },
    );
    g.scheduler_class = scheduler_class;

    // ProcessorScheduler>>init  quiescentLists := Array new: 7. activeProcess := nil. ^self
    try defineMethod(c, scheduler_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "quiescentLists", try send(c, try varRef(c, "Array"), "new:", &.{
            try litInt(c, @intCast(object.MAX_PRIORITY)),
        })),
        try assignNode(c, "activeProcess", try litNil(c)),
        try ret(c, try varRef(c, "self")),
    });

    // ProcessorScheduler>>quiescentLists / activeProcess accessors —
    // mostly for inspection from tests and printers.
    try defineMethod(c, scheduler_class, "quiescentLists", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "quiescentLists")),
    });

    // Build the Processor singleton instance and bind it in Smalltalk.
    const processor = try heap.allocSlots(scheduler_class, object.SCHEDULER_INST_SIZE);
    const qlists = try heap.allocSlots(g.array_class, object.MAX_PRIORITY);
    var i: u32 = 0;
    while (i < object.MAX_PRIORITY) : (i += 1) {
        object.setSlot(qlists, i, oop_mod.NIL);
    }
    object.setSlot(processor, object.SLOT_SCHEDULER_QLISTS, qlists);
    object.setSlot(processor, object.SLOT_SCHEDULER_ACTIVE, oop_mod.NIL);
    object.setSlot(processor, object.SLOT_SCHEDULER_DELAY_HEAD, oop_mod.NIL);
    g.processor = processor;
    _ = try dict.atPut(heap, g.smalltalk, g, "Processor", processor);

    // Priority constants in the Smalltalk dict.
    _ = try dict.atPut(heap, g.smalltalk, g, "PriorityUserBackground", oop_mod.fromInt(object.PRIORITY_USER_BACKGROUND));
    _ = try dict.atPut(heap, g.smalltalk, g, "PriorityUserScheduling", oop_mod.fromInt(object.PRIORITY_USER_SCHEDULING));
    _ = try dict.atPut(heap, g.smalltalk, g, "PriorityUserInterrupt", oop_mod.fromInt(object.PRIORITY_USER_INTERRUPT));
    _ = try dict.atPut(heap, g.smalltalk, g, "PriorityLowIO", oop_mod.fromInt(object.PRIORITY_LOW_IO));
    _ = try dict.atPut(heap, g.smalltalk, g, "PriorityHighIO", oop_mod.fromInt(object.PRIORITY_HIGH_IO));
    _ = try dict.atPut(heap, g.smalltalk, g, "PriorityTiming", oop_mod.fromInt(object.PRIORITY_TIMING));

    // ---- Mutex ----
    //
    // Reentrant mutual exclusion built atop a binary Semaphore. Owner
    // tracking lets the same Process re-enter `critical:` without
    // deadlocking; a counter tracks nesting depth so only the
    // outermost release signals the semaphore.
    const mutex_class = try defineClassAndRegister(
        heap,
        g,
        "Mutex",
        g.object_class,
        &.{ "semaphore", "owner", "count" },
    );

    // Mutex>>init  semaphore := Semaphore new init signal. owner := nil. count := 0. ^self
    try defineMethod(c, mutex_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "semaphore", try send(c, try send(c, try send(c, try varRef(c, "Semaphore"), "new", &.{}), "init", &.{}), "signal", &.{})),
        try assignNode(c, "owner", try litNil(c)),
        try assignNode(c, "count", try litInt(c, 0)),
        try ret(c, try varRef(c, "self")),
    });

    // Mutex>>critical: aBlock
    //   | active |
    //   active := Processor activeProcess.
    //   owner == active ifTrue: [
    //     count := count + 1.
    //     ^[aBlock value] ensure: [count := count - 1]].
    //   semaphore wait.
    //   owner := active. count := 1.
    //   ^[aBlock value] ensure: [
    //     count := count - 1.
    //     count = 0 ifTrue: [owner := nil. semaphore signal]]
    try defineMethod(c, mutex_class, "critical:", &.{"aBlock"}, &.{"active"}, &.{
        try assignNode(c, "active", try send(c, try varRef(c, "Processor"), "activeProcess", &.{})),
        try send(c, try send(c, try varRef(c, "owner"), "==", &.{try varRef(c, "active")}), "ifTrue:", &.{
            try block(c, &.{}, &.{}, &.{
                try assignNode(c, "count", try send(c, try varRef(c, "count"), "+", &.{try litInt(c, 1)})),
                try ret(c, try send(c, try block(c, &.{}, &.{}, &.{
                    try send(c, try varRef(c, "aBlock"), "value", &.{}),
                }), "ensure:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try assignNode(c, "count", try send(c, try varRef(c, "count"), "-", &.{try litInt(c, 1)})),
                    }),
                })),
            }),
        }),
        try send(c, try varRef(c, "semaphore"), "wait", &.{}),
        try assignNode(c, "owner", try varRef(c, "active")),
        try assignNode(c, "count", try litInt(c, 1)),
        try ret(c, try send(c, try block(c, &.{}, &.{}, &.{
            try send(c, try varRef(c, "aBlock"), "value", &.{}),
        }), "ensure:", &.{
            try block(c, &.{}, &.{}, &.{
                try assignNode(c, "count", try send(c, try varRef(c, "count"), "-", &.{try litInt(c, 1)})),
                try send(c, try send(c, try varRef(c, "count"), "=", &.{try litInt(c, 0)}), "ifTrue:", &.{
                    try block(c, &.{}, &.{}, &.{
                        try assignNode(c, "owner", try litNil(c)),
                        try send(c, try varRef(c, "semaphore"), "signal", &.{}),
                    }),
                }),
            }),
        })),
    });

    try defineMethod(c, mutex_class, "owner", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "owner")),
    });
    try defineMethod(c, mutex_class, "count", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "count")),
    });

    // ---- SharedQueue ----
    //
    // Producer/consumer queue. `available` is the count of buffered
    // items; `mutex` serialises mutations of the underlying
    // OrderedCollection.
    const shared_queue_class = try defineClassAndRegister(
        heap,
        g,
        "SharedQueue",
        g.object_class,
        &.{ "items", "mutex", "available" },
    );

    // SharedQueue>>init
    //   items := OrderedCollection new init.
    //   mutex := Mutex new init.
    //   available := Semaphore new init.   "count = 0"
    //   ^self
    try defineMethod(c, shared_queue_class, "init", &.{}, &.{}, &.{
        try assignNode(c, "items", try send(c, try send(c, try varRef(c, "OrderedCollection"), "new", &.{}), "init", &.{})),
        try assignNode(c, "mutex", try send(c, try send(c, try varRef(c, "Mutex"), "new", &.{}), "init", &.{})),
        try assignNode(c, "available", try send(c, try send(c, try varRef(c, "Semaphore"), "new", &.{}), "init", &.{})),
        try ret(c, try varRef(c, "self")),
    });

    // SharedQueue>>nextPut: anObject
    //   mutex critical: [items addLast: anObject].
    //   available signal. ^anObject
    try defineMethod(c, shared_queue_class, "nextPut:", &.{"anObject"}, &.{}, &.{
        try send(c, try varRef(c, "mutex"), "critical:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "items"), "addLast:", &.{try varRef(c, "anObject")}),
            }),
        }),
        try send(c, try varRef(c, "available"), "signal", &.{}),
        try ret(c, try varRef(c, "anObject")),
    });

    // SharedQueue>>next
    //   available wait.
    //   ^mutex critical: [items removeFirst]
    try defineMethod(c, shared_queue_class, "next", &.{}, &.{}, &.{
        try send(c, try varRef(c, "available"), "wait", &.{}),
        try ret(c, try send(c, try varRef(c, "mutex"), "critical:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "items"), "removeFirst", &.{}),
            }),
        })),
    });

    // SharedQueue>>size  ^mutex critical: [items size]
    try defineMethod(c, shared_queue_class, "size", &.{}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "mutex"), "critical:", &.{
            try block(c, &.{}, &.{}, &.{
                try send(c, try varRef(c, "items"), "size", &.{}),
            }),
        })),
    });

    // SharedQueue>>isEmpty  ^self size = 0
    try defineMethod(c, shared_queue_class, "isEmpty", &.{}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "size", &.{}), "=", &.{try litInt(c, 0)})),
    });

    // ---- Time ----
    //
    // Tiny utility class. Class-side `monotonicNanos` is wired as a
    // primitive in bootstrap.zig (no metaclass plumbing in stdlib).
    const time_class = try defineClassAndRegister(heap, g, "Time", g.object_class, &.{});
    _ = time_class;

    // ---- Delay ----
    //
    // Cooperative timed wait. `wait` is a primitive that parks the
    // active Process on the scheduler's sorted delay queue using
    // the receiver's deadlineNanos ivar (slot 0); the scheduler's
    // expireSleepers walks it on every yield/wait/signal point.
    const delay_class = try defineClassAndRegister(
        heap,
        g,
        "Delay",
        g.object_class,
        &.{"deadlineNanos"},
    );

    try defineMethod(c, delay_class, "setDeadlineNanos:", &.{"n"}, &.{}, &.{
        try assignNode(c, "deadlineNanos", try varRef(c, "n")),
        try ret(c, try varRef(c, "self")),
    });
    try defineMethod(c, delay_class, "deadlineNanos", &.{}, &.{}, &.{
        try ret(c, try varRef(c, "deadlineNanos")),
    });

    // Delay class>>forMilliseconds: ms  ^self new setDeadlineNanos: Time monotonicNanos + (ms * 1000000)
    const delay_meta = object.headerOf(delay_class).class;
    try defineMethod(c, delay_meta, "forMilliseconds:", &.{"ms"}, &.{}, &.{
        try ret(c, try send(c, try send(c, try varRef(c, "self"), "new", &.{}), "setDeadlineNanos:", &.{
            try send(c, try send(c, try varRef(c, "Time"), "monotonicNanos", &.{}), "+", &.{
                try send(c, try varRef(c, "ms"), "*", &.{try litInt(c, 1_000_000)}),
            }),
        })),
    });
    // Delay class>>forSeconds: s  ^self forMilliseconds: s * 1000
    try defineMethod(c, delay_meta, "forSeconds:", &.{"s"}, &.{}, &.{
        try ret(c, try send(c, try varRef(c, "self"), "forMilliseconds:", &.{
            try send(c, try varRef(c, "s"), "*", &.{try litInt(c, 1_000)}),
        })),
    });
}
