const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const print_mod = @import("print.zig");
const dict = @import("dict.zig");
const bigint = @import("bigint.zig");
const eval_mod = @import("eval.zig");
const Vm = eval_mod.Vm;
const Oop = oop_mod.Oop;

// Primitives can call back into eval (e.g. BlockClosure>>value), so the
// error set must include every EvalError variant — alias to keep them
// in sync automatically.
pub const PrimError = eval_mod.EvalError;

pub const PrimFn = *const fn (vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop;

// Stable IDs. Methods reference these via their primitive_id slot, so
// these numbers are part of the on-image ABI — append, never reorder.
pub const PRIM_INT_ADD: u32 = 1;
pub const PRIM_INT_SUB: u32 = 2;
pub const PRIM_INT_MUL: u32 = 3;
pub const PRIM_INT_LT: u32 = 4;
pub const PRIM_OBJ_PRINT_NL: u32 = 10;
pub const PRIM_OBJ_CLASS: u32 = 11;
pub const PRIM_OBJ_IDENTITY_EQ: u32 = 12;
pub const PRIM_BLOCK_VALUE: u32 = 20;
pub const PRIM_BLOCK_VALUE_1: u32 = 21;
pub const PRIM_BLOCK_VALUE_2: u32 = 22;
pub const PRIM_BLOCK_VALUE_3: u32 = 23;
pub const PRIM_BLOCK_VALUE_4: u32 = 24;
pub const PRIM_BLOCK_WHILE_TRUE: u32 = 25;
pub const PRIM_BLOCK_WHILE_FALSE: u32 = 26;
pub const PRIM_TRUE_IF_TRUE: u32 = 30;
pub const PRIM_TRUE_IF_FALSE: u32 = 31;
pub const PRIM_TRUE_IF_TRUE_IF_FALSE: u32 = 32;
pub const PRIM_FALSE_IF_TRUE: u32 = 33;
pub const PRIM_FALSE_IF_FALSE: u32 = 34;
pub const PRIM_FALSE_IF_TRUE_IF_FALSE: u32 = 35;
pub const PRIM_CLASS_NEW: u32 = 40;
pub const PRIM_OBJECT_SIZE: u32 = 50;
pub const PRIM_ARRAY_AT: u32 = 51;
pub const PRIM_ARRAY_AT_PUT: u32 = 52;
pub const PRIM_ARRAY_NEW_SIZED: u32 = 53;
pub const PRIM_STRING_CONCAT: u32 = 54;
pub const PRIM_INT_LE: u32 = 55;
pub const PRIM_INT_GT: u32 = 56;
pub const PRIM_INT_GE: u32 = 57;
pub const PRIM_OBJ_BECOME: u32 = 60;
pub const PRIM_OBJ_IS_KIND_OF: u32 = 61;
pub const PRIM_EXC_SIGNAL: u32 = 70;
pub const PRIM_EXC_MESSAGE_TEXT: u32 = 71;
pub const PRIM_BLOCK_ON_DO: u32 = 72;
pub const PRIM_BLOCK_ENSURE: u32 = 73;
pub const PRIM_OBJ_PERFORM: u32 = 74;
pub const PRIM_BEHAVIOR_SELECTORS: u32 = 80;
pub const PRIM_STRING_STARTS_WITH: u32 = 81;
pub const PRIM_INT_DIV_FLOOR: u32 = 90;
pub const PRIM_INT_MOD_FLOOR: u32 = 91;
pub const PRIM_INT_QUO: u32 = 92;
pub const PRIM_INT_REM: u32 = 93;
pub const PRIM_STRING_EQUALS: u32 = 94;
pub const PRIM_INT_AS_STRING: u32 = 95;
pub const PRIM_BEHAVIOR_NAME: u32 = 96;
pub const PRIM_STRING_AT: u32 = 97;
pub const PRIM_STRING_FROM_CHAR_CODE: u32 = 98;
pub const PRIM_STRING_AS_SYMBOL: u32 = 99;
pub const PRIM_SYMBOL_AS_STRING: u32 = 100;
pub const PRIM_FLOAT_ADD: u32 = 110;
pub const PRIM_FLOAT_SUB: u32 = 111;
pub const PRIM_FLOAT_MUL: u32 = 112;
pub const PRIM_FLOAT_DIV: u32 = 113;
pub const PRIM_FLOAT_LT: u32 = 114;
pub const PRIM_FLOAT_LE: u32 = 115;
pub const PRIM_FLOAT_GT: u32 = 116;
pub const PRIM_FLOAT_GE: u32 = 117;
pub const PRIM_FLOAT_EQ: u32 = 118;
pub const PRIM_FLOAT_AS_STRING: u32 = 119;
pub const PRIM_FLOAT_TRUNCATED: u32 = 120;
pub const PRIM_INT_AS_FLOAT: u32 = 121;
pub const PRIM_INT_EQ: u32 = 122;
pub const PRIM_LARGE_ADD: u32 = 130;
pub const PRIM_LARGE_SUB: u32 = 131;
pub const PRIM_LARGE_MUL: u32 = 132;
pub const PRIM_LARGE_LT: u32 = 133;
pub const PRIM_LARGE_LE: u32 = 134;
pub const PRIM_LARGE_GT: u32 = 135;
pub const PRIM_LARGE_GE: u32 = 136;
pub const PRIM_LARGE_EQ: u32 = 137;
pub const PRIM_LARGE_AS_STRING: u32 = 138;
pub const PRIM_LARGE_AS_FLOAT: u32 = 139;
pub const PRIM_FLOAT_SQRT: u32 = 140;
pub const PRIM_FLOAT_SIN: u32 = 141;
pub const PRIM_FLOAT_COS: u32 = 142;
pub const PRIM_FLOAT_LN: u32 = 143;
pub const PRIM_FLOAT_EXP: u32 = 144;

// ---- Concurrency. Surface only — semantics are placeholder-cooperative
// until the context-switch backend lands. fork allocates a Process and
// links it into the scheduler's runnable list; signal/wait operate on
// the count and waiter list synchronously; yield/resume/suspend mark
// state ivars without actually transferring control. The shape mirrors
// classic Smalltalk so once swapcontext-style switching ships in a
// later commit, the public methods don't need to change. ----
pub const PRIM_BLOCK_FORK: u32 = 200;
pub const PRIM_BLOCK_FORK_AT: u32 = 201;
pub const PRIM_SEMAPHORE_WAIT: u32 = 210;
pub const PRIM_SEMAPHORE_SIGNAL: u32 = 211;
pub const PRIM_PROCESS_RESUME: u32 = 220;
pub const PRIM_PROCESS_SUSPEND: u32 = 221;
pub const PRIM_PROCESS_TERMINATE: u32 = 222;
pub const PRIM_PROCESSOR_YIELD: u32 = 230;
pub const PRIM_PROCESSOR_ACTIVE: u32 = 231;
pub const PRIM_TIME_MONO_NANOS: u32 = 240;
pub const PRIM_DELAY_WAIT: u32 = 241;
pub const PRIM_FS_OPEN: u32 = 300;
pub const PRIM_FS_READ: u32 = 301;
pub const PRIM_FS_READ_ALL: u32 = 302;
pub const PRIM_FS_WRITE: u32 = 303;
pub const PRIM_FS_CLOSE: u32 = 304;
pub const PRIM_OBJ_INST_VAR_AT: u32 = 310;
pub const PRIM_OBJ_INST_VAR_AT_PUT: u32 = 311;
pub const PRIM_OBJ_IS_MEMBER_OF: u32 = 312;
pub const PRIM_BEHAVIOR_INST_VAR_NAMES: u32 = 313;
pub const PRIM_BLOCK_IF_CURTAILED: u32 = 320;
pub const PRIM_EXC_PASS: u32 = 321;
pub const PRIM_EXC_RESIGNAL_AS: u32 = 322;
pub const PRIM_SOCK_CONNECT: u32 = 330;
pub const PRIM_SOCK_LISTEN: u32 = 331;
pub const PRIM_SOCK_ACCEPT: u32 = 332;

pub fn dispatch(vm: *Vm, prim_id: u32, receiver: Oop, args: []const Oop) PrimError!Oop {
    return switch (prim_id) {
        PRIM_INT_ADD => primIntAdd(vm, receiver, args),
        PRIM_INT_SUB => primIntSub(vm, receiver, args),
        PRIM_INT_MUL => primIntMul(vm, receiver, args),
        PRIM_INT_LT => primIntLt(vm, receiver, args),
        PRIM_OBJ_PRINT_NL => primObjPrintNl(vm, receiver, args),
        PRIM_OBJ_CLASS => primObjClass(vm, receiver, args),
        PRIM_OBJ_IDENTITY_EQ => primObjIdentityEq(vm, receiver, args),
        PRIM_BLOCK_VALUE,
        PRIM_BLOCK_VALUE_1,
        PRIM_BLOCK_VALUE_2,
        PRIM_BLOCK_VALUE_3,
        PRIM_BLOCK_VALUE_4,
        => eval_mod.invokeBlock(vm, receiver, args),
        PRIM_BLOCK_WHILE_TRUE => primBlockWhileTrue(vm, receiver, args),
        PRIM_BLOCK_WHILE_FALSE => primBlockWhileFalse(vm, receiver, args),
        PRIM_TRUE_IF_TRUE => primTrueIfTrue(vm, receiver, args),
        PRIM_TRUE_IF_FALSE => primTrueIfFalse(vm, receiver, args),
        PRIM_TRUE_IF_TRUE_IF_FALSE => primTrueIfTrueIfFalse(vm, receiver, args),
        PRIM_FALSE_IF_TRUE => primFalseIfTrue(vm, receiver, args),
        PRIM_FALSE_IF_FALSE => primFalseIfFalse(vm, receiver, args),
        PRIM_FALSE_IF_TRUE_IF_FALSE => primFalseIfTrueIfFalse(vm, receiver, args),
        PRIM_CLASS_NEW => primClassNew(vm, receiver, args),
        PRIM_OBJECT_SIZE => primObjectSize(vm, receiver, args),
        PRIM_ARRAY_AT => primArrayAt(vm, receiver, args),
        PRIM_ARRAY_AT_PUT => primArrayAtPut(vm, receiver, args),
        PRIM_ARRAY_NEW_SIZED => primArrayNewSized(vm, receiver, args),
        PRIM_STRING_CONCAT => primStringConcat(vm, receiver, args),
        PRIM_INT_LE => primIntLe(vm, receiver, args),
        PRIM_INT_GT => primIntGt(vm, receiver, args),
        PRIM_INT_GE => primIntGe(vm, receiver, args),
        PRIM_OBJ_BECOME => primObjBecome(vm, receiver, args),
        PRIM_OBJ_IS_KIND_OF => primObjIsKindOf(vm, receiver, args),
        PRIM_EXC_SIGNAL => primExceptionSignal(vm, receiver, args),
        PRIM_EXC_MESSAGE_TEXT => primExceptionMessageText(vm, receiver, args),
        PRIM_BLOCK_ON_DO => primBlockOnDo(vm, receiver, args),
        PRIM_BLOCK_ENSURE => primBlockEnsure(vm, receiver, args),
        PRIM_OBJ_PERFORM => primObjPerform(vm, receiver, args),
        PRIM_BEHAVIOR_SELECTORS => primBehaviorSelectors(vm, receiver, args),
        PRIM_STRING_STARTS_WITH => primStringStartsWith(vm, receiver, args),
        PRIM_INT_DIV_FLOOR => primIntDivFloor(vm, receiver, args),
        PRIM_INT_MOD_FLOOR => primIntModFloor(vm, receiver, args),
        PRIM_INT_QUO => primIntQuo(vm, receiver, args),
        PRIM_INT_REM => primIntRem(vm, receiver, args),
        PRIM_STRING_EQUALS => primStringEquals(vm, receiver, args),
        PRIM_INT_AS_STRING => primIntAsString(vm, receiver, args),
        PRIM_BEHAVIOR_NAME => primBehaviorName(vm, receiver, args),
        PRIM_STRING_AT => primStringAt(vm, receiver, args),
        PRIM_STRING_FROM_CHAR_CODE => primStringFromCharCode(vm, receiver, args),
        PRIM_STRING_AS_SYMBOL => primStringAsSymbol(vm, receiver, args),
        PRIM_SYMBOL_AS_STRING => primSymbolAsString(vm, receiver, args),
        PRIM_FLOAT_ADD => primFloatAdd(vm, receiver, args),
        PRIM_FLOAT_SUB => primFloatSub(vm, receiver, args),
        PRIM_FLOAT_MUL => primFloatMul(vm, receiver, args),
        PRIM_FLOAT_DIV => primFloatDiv(vm, receiver, args),
        PRIM_FLOAT_LT => primFloatLt(vm, receiver, args),
        PRIM_FLOAT_LE => primFloatLe(vm, receiver, args),
        PRIM_FLOAT_GT => primFloatGt(vm, receiver, args),
        PRIM_FLOAT_GE => primFloatGe(vm, receiver, args),
        PRIM_FLOAT_EQ => primFloatEq(vm, receiver, args),
        PRIM_FLOAT_AS_STRING => primFloatAsString(vm, receiver, args),
        PRIM_FLOAT_TRUNCATED => primFloatTruncated(vm, receiver, args),
        PRIM_INT_AS_FLOAT => primIntAsFloat(vm, receiver, args),
        PRIM_INT_EQ => primIntEq(vm, receiver, args),
        PRIM_LARGE_ADD => primLargeAdd(vm, receiver, args),
        PRIM_LARGE_SUB => primLargeSub(vm, receiver, args),
        PRIM_LARGE_MUL => primLargeMul(vm, receiver, args),
        PRIM_LARGE_LT => primLargeCmp(vm, receiver, args, .lt),
        PRIM_LARGE_LE => primLargeCmp(vm, receiver, args, .le),
        PRIM_LARGE_GT => primLargeCmp(vm, receiver, args, .gt),
        PRIM_LARGE_GE => primLargeCmp(vm, receiver, args, .ge),
        PRIM_LARGE_EQ => primLargeCmp(vm, receiver, args, .eq),
        PRIM_LARGE_AS_STRING => primLargeAsString(vm, receiver, args),
        PRIM_LARGE_AS_FLOAT => primLargeAsFloat(vm, receiver, args),
        PRIM_FLOAT_SQRT => primFloatMath(vm, receiver, args, .sqrt),
        PRIM_FLOAT_SIN => primFloatMath(vm, receiver, args, .sin),
        PRIM_FLOAT_COS => primFloatMath(vm, receiver, args, .cos),
        PRIM_FLOAT_LN => primFloatMath(vm, receiver, args, .ln),
        PRIM_FLOAT_EXP => primFloatMath(vm, receiver, args, .exp),
        PRIM_BLOCK_FORK => primBlockFork(vm, receiver, args, null),
        PRIM_BLOCK_FORK_AT => primBlockFork(vm, receiver, args, .from_arg),
        PRIM_SEMAPHORE_WAIT => primSemaphoreWait(vm, receiver, args),
        PRIM_SEMAPHORE_SIGNAL => primSemaphoreSignal(vm, receiver, args),
        PRIM_PROCESS_RESUME => primProcessResume(vm, receiver, args),
        PRIM_PROCESS_SUSPEND => primProcessSuspend(vm, receiver, args),
        PRIM_PROCESS_TERMINATE => primProcessTerminate(vm, receiver, args),
        PRIM_PROCESSOR_YIELD => primProcessorYield(vm, receiver, args),
        PRIM_PROCESSOR_ACTIVE => primProcessorActive(vm, receiver, args),
        PRIM_TIME_MONO_NANOS => primTimeMonoNanos(vm, receiver, args),
        PRIM_DELAY_WAIT => primDelayWait(vm, receiver, args),
        PRIM_FS_OPEN => primFsOpen(vm, receiver, args),
        PRIM_FS_READ => primFsRead(vm, receiver, args),
        PRIM_FS_READ_ALL => primFsReadAll(vm, receiver, args),
        PRIM_FS_WRITE => primFsWrite(vm, receiver, args),
        PRIM_FS_CLOSE => primFsClose(vm, receiver, args),
        PRIM_OBJ_INST_VAR_AT => primObjInstVarAt(vm, receiver, args),
        PRIM_OBJ_INST_VAR_AT_PUT => primObjInstVarAtPut(vm, receiver, args),
        PRIM_OBJ_IS_MEMBER_OF => primObjIsMemberOf(vm, receiver, args),
        PRIM_BEHAVIOR_INST_VAR_NAMES => primBehaviorInstVarNames(vm, receiver, args),
        PRIM_BLOCK_IF_CURTAILED => primBlockIfCurtailed(vm, receiver, args),
        PRIM_EXC_PASS => primExceptionPass(vm, receiver, args),
        PRIM_EXC_RESIGNAL_AS => primExceptionResignalAs(vm, receiver, args),
        PRIM_SOCK_CONNECT => primSockConnect(vm, receiver, args),
        PRIM_SOCK_LISTEN => primSockListen(vm, receiver, args),
        PRIM_SOCK_ACCEPT => primSockAccept(vm, receiver, args),
        else => error.UnknownPrimitive,
    };
}

// Number coercion helper. Returns f64 if the Oop is a tagged Int or
// tagged Float; otherwise null. Used by mixed-type arithmetic so that
// `1 + 2.5` and `2.5 + 1` both promote to Float (Phase A.2).
inline fn asF64(o: Oop) ?f64 {
    if (oop_mod.isInt(o)) return @floatFromInt(oop_mod.toInt(o));
    if (oop_mod.isFloat(o)) return oop_mod.toF64(o);
    return null;
}

// Smalltalk-side double dispatch fallbacks. When an Int primitive is
// called with an arg of a type the primitive doesn't recognize (e.g.
// Fraction), defer to the arg's own implementation. Commutative ops
// just swap; non-commutative ones rewrite via negation or inversion.
//
// Pin every Oop local across each sendSym — including the inline
// args slice's element. A bare `&.{receiver}` is a stack temporary
// not in any GC-walked region, so an inner safe-point GC would leave
// args[0] pointing at moved-from memory.
fn fallbackCommutative(vm: *Vm, receiver: Oop, arg: Oop, sel: []const u8) PrimError!Oop {
    var arg_pin: Oop = arg;
    var sym_pin: Oop = oop_mod.NIL;
    var args_buf: [1]Oop = .{receiver};
    var slot_ptrs: [3]?*Oop = .{ &arg_pin, &sym_pin, &args_buf[0] };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 3 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    sym_pin = try dict.newSymbol(vm.heap, &vm.globals, sel);
    return vm.sendSym(arg_pin, sym_pin, &args_buf);
}

fn fallbackSub(vm: *Vm, receiver: Oop, arg: Oop) PrimError!Oop {
    // a - b  ==  (b negated) + a
    var arg_pin: Oop = arg;
    var neg_sym_pin: Oop = oop_mod.NIL;
    var neg_pin: Oop = oop_mod.NIL;
    var args_buf: [1]Oop = .{receiver};
    var slot_ptrs: [4]?*Oop = .{ &arg_pin, &neg_sym_pin, &neg_pin, &args_buf[0] };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 4 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    neg_sym_pin = try dict.newSymbol(vm.heap, &vm.globals, "negated");
    neg_pin = try vm.sendSym(arg_pin, neg_sym_pin, &.{});
    return vm.sendSym(neg_pin, vm.globals.sym_plus, &args_buf);
}

// a < b  ==  b > a, etc. The inverse map for comparisons.
fn fallbackCmp(vm: *Vm, receiver: Oop, arg: Oop, swapped_sel: Oop) PrimError!Oop {
    var arg_pin: Oop = arg;
    var sel_pin: Oop = swapped_sel;
    var args_buf: [1]Oop = .{receiver};
    var slot_ptrs: [3]?*Oop = .{ &arg_pin, &sel_pin, &args_buf[0] };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 3 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    return vm.sendSym(arg_pin, sel_pin, &args_buf);
}

fn primIntAdd(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) {
        const a = oop_mod.toInt(receiver);
        const b = oop_mod.toInt(args[0]);
        const sum = a +% b;
        if (((a ^ sum) & (b ^ sum)) >= 0 and oop_mod.fitsSmallInt(sum)) return oop_mod.fromInt(sum);
        return bigint.add(vm.heap, &vm.globals, receiver, args[0]);
    }
    if (oop_mod.isFloat(args[0])) return oop_mod.fromF64(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) + oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) return bigint.add(vm.heap, &vm.globals, receiver, args[0]);
    return fallbackCommutative(vm, receiver, args[0], "+");
}

fn primIntSub(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) {
        const a = oop_mod.toInt(receiver);
        const b = oop_mod.toInt(args[0]);
        const diff = a -% b;
        if (((a ^ b) & (a ^ diff)) >= 0 and oop_mod.fitsSmallInt(diff)) return oop_mod.fromInt(diff);
        return bigint.sub(vm.heap, &vm.globals, receiver, args[0]);
    }
    if (oop_mod.isFloat(args[0])) return oop_mod.fromF64(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) - oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) return bigint.sub(vm.heap, &vm.globals, receiver, args[0]);
    return fallbackSub(vm, receiver, args[0]);
}

fn primIntMul(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) {
        const a = oop_mod.toInt(receiver);
        const b = oop_mod.toInt(args[0]);
        const m = @mulWithOverflow(a, b);
        if (m[1] == 0 and oop_mod.fitsSmallInt(m[0])) return oop_mod.fromInt(m[0]);
        return bigint.mul(vm.heap, &vm.globals, receiver, args[0]);
    }
    if (oop_mod.isFloat(args[0])) return oop_mod.fromF64(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) * oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) return bigint.mul(vm.heap, &vm.globals, receiver, args[0]);
    return fallbackCommutative(vm, receiver, args[0], "*");
}

fn primIntLt(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) return oop_mod.fromBool(oop_mod.toInt(receiver) < oop_mod.toInt(args[0]));
    if (oop_mod.isFloat(args[0])) return oop_mod.fromBool(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) < oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) {
        const o = bigint.cmp(&vm.globals, receiver, args[0]) orelse return error.TypeError;
        return oop_mod.fromBool(o == .lt);
    }
    return fallbackCmp(vm, receiver, args[0], vm.globals.sym_gt);
}

fn primIntEq(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) return oop_mod.fromBool(receiver == args[0]);
    if (oop_mod.isFloat(args[0])) return oop_mod.fromBool(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) == oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) {
        // A canonical Large is never == a SmallInt, by construction.
        return oop_mod.fromBool(false);
    }
    return fallbackCommutative(vm, receiver, args[0], "=");
}

fn primObjPrintNl(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (vm.output) |sink| {
        // Dispatch through Smalltalk-side printString (defined in stdlib).
        // Falls back to Zig-side rendering if it fails (e.g., before
        // stdlib loads).
        const result = vm.sendSym(receiver, vm.globals.sym_printString, &.{}) catch {
            var arena = std.heap.ArenaAllocator.init(sink.allocator);
            defer arena.deinit();
            const s = print_mod.printString(arena.allocator(), vm, receiver) catch return error.OutOfMemory;
            sink.buffer.appendSlice(sink.allocator, s) catch return error.OutOfMemory;
            sink.buffer.append(sink.allocator, '\n') catch return error.OutOfMemory;
            return receiver;
        };
        if (oop_mod.isHeapPtr(result)) {
            const hdr = object.headerOf(result);
            if ((hdr.flags & object.FLAG_BYTES) != 0) {
                const bytes = object.bytesOf(result)[0..hdr.size];
                sink.buffer.appendSlice(sink.allocator, bytes) catch return error.OutOfMemory;
            }
        }
        sink.buffer.append(sink.allocator, '\n') catch return error.OutOfMemory;
    }
    return receiver;
}

fn primObjClass(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    return vm.classOf(receiver);
}

fn primObjIdentityEq(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return oop_mod.fromBool(receiver == args[0]);
}

// Conditional primitives. Bodies are trivial because the conditional
// logic falls out of method dispatch — True#ifTrue: invokes its block,
// False#ifTrue: just returns nil. Both arms are sent `value`, so any
// object responding to `value` works as a "block" (polymorphism that
// matches Smalltalk-80).
fn primTrueIfTrue(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return vm.sendSym(args[0], vm.globals.sym_value, &.{});
}

fn primTrueIfFalse(_: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return oop_mod.NIL;
}

fn primTrueIfTrueIfFalse(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 2) return error.ArityMismatch;
    return vm.sendSym(args[0], vm.globals.sym_value, &.{});
}

fn primFalseIfTrue(_: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return oop_mod.NIL;
}

fn primFalseIfFalse(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return vm.sendSym(args[0], vm.globals.sym_value, &.{});
}

fn primFalseIfTrueIfFalse(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 2) return error.ArityMismatch;
    return vm.sendSym(args[1], vm.globals.sym_value, &.{});
}

// Loop primitives. Receiver is a block tested each iteration; the body
// is the argument block. Returns nil (Smalltalk convention).
//
// `recv_pin` and `body_pin` are stack-local Oop slots pinned through
// the GC root-pin chain. Without that pinning, a GC fired by either
// `vm.sendSym` call would leave the Zig parameter `receiver` and the
// args-slice contents stale, and the next iteration would dispatch
// against a moved-from address.
fn primBlockWhileTrue(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    var recv_pin: Oop = receiver;
    var body_pin: Oop = args[0];
    var slot_ptrs: [2]?*Oop = .{ &recv_pin, &body_pin };
    var pin = eval_mod.RootPin{
        .parent = vm.root_pin,
        .slots = &slot_ptrs,
        .n = 2,
    };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    while (true) {
        const cond = try vm.sendSym(recv_pin, vm.globals.sym_value, &.{});
        if (cond != oop_mod.TRUE) break;
        _ = try vm.sendSym(body_pin, vm.globals.sym_value, &.{});
    }
    return oop_mod.NIL;
}

// Object>>size: number of slots (or bytes for byte objects). 0 for
// SmallIntegers and sentinels.
fn primObjectSize(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return oop_mod.fromInt(0);
    return oop_mod.fromInt(@intCast(object.headerOf(receiver).size));
}

// Array>>at: 1-based index lookup over slot array. Bounds-checked.
fn primArrayAt(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const i = oop_mod.toInt(args[0]);
    if (i < 1) return error.PrimitiveFailed;
    const idx: u32 = @intCast(i - 1);
    if (idx >= object.headerOf(receiver).size) return error.PrimitiveFailed;
    return object.slot(receiver, idx);
}

// Array>>at:put: 1-based index store. Returns the stored value.
fn primArrayAtPut(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 2) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const i = oop_mod.toInt(args[0]);
    if (i < 1) return error.PrimitiveFailed;
    const idx: u32 = @intCast(i - 1);
    if (idx >= object.headerOf(receiver).size) return error.PrimitiveFailed;
    object.setSlot(receiver, idx, args[1]);
    return args[1];
}

// Array class>>new: allocate a slot-array of `arg` slots, each NIL.
// Receiver is expected to be Array (or any class with array-like
// instances) — this primitive is installed on Array's metaclass only.
fn primArrayNewSized(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const n = oop_mod.toInt(args[0]);
    if (n < 0) return error.PrimitiveFailed;
    return vm.heap.allocSlots(receiver, @intCast(n)) catch error.OutOfMemory;
}

// String>>, : byte concatenation. Returns a new String containing the
// receiver's bytes followed by the argument's bytes.
fn primStringConcat(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver) or !oop_mod.isHeapPtr(args[0])) return error.TypeError;
    const ah = object.headerOf(receiver);
    const bh = object.headerOf(args[0]);
    if ((ah.flags & object.FLAG_BYTES) == 0 or (bh.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const total = ah.size + bh.size;
    const result = vm.heap.allocBytes(vm.globals.string_class, total) catch return error.OutOfMemory;
    const dst = object.bytesOf(result);
    @memcpy(dst[0..ah.size], object.bytesOf(receiver)[0..ah.size]);
    @memcpy(dst[ah.size .. ah.size + bh.size], object.bytesOf(args[0])[0..bh.size]);
    return result;
}

fn primIntLe(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) return oop_mod.fromBool(oop_mod.toInt(receiver) <= oop_mod.toInt(args[0]));
    if (oop_mod.isFloat(args[0])) return oop_mod.fromBool(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) <= oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) {
        const o = bigint.cmp(&vm.globals, receiver, args[0]) orelse return error.TypeError;
        return oop_mod.fromBool(o != .gt);
    }
    return fallbackCmp(vm, receiver, args[0], vm.globals.sym_ge);
}

fn primIntGt(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) return oop_mod.fromBool(oop_mod.toInt(receiver) > oop_mod.toInt(args[0]));
    if (oop_mod.isFloat(args[0])) return oop_mod.fromBool(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) > oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) {
        const o = bigint.cmp(&vm.globals, receiver, args[0]) orelse return error.TypeError;
        return oop_mod.fromBool(o == .gt);
    }
    return fallbackCmp(vm, receiver, args[0], vm.globals.sym_lt);
}

fn primIntGe(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    if (oop_mod.isInt(args[0])) return oop_mod.fromBool(oop_mod.toInt(receiver) >= oop_mod.toInt(args[0]));
    if (oop_mod.isFloat(args[0])) return oop_mod.fromBool(@as(f64, @floatFromInt(oop_mod.toInt(receiver))) >= oop_mod.toF64(args[0]));
    if (bigint.isLarge(&vm.globals, args[0])) {
        const o = bigint.cmp(&vm.globals, receiver, args[0]) orelse return error.TypeError;
        return oop_mod.fromBool(o != .lt);
    }
    return fallbackCmp(vm, receiver, args[0], vm.globals.sym_le);
}

// Object>>become: Swap the identities of two objects across the entire
// image. After this call, every reference to `receiver` becomes a
// reference to `other` and vice versa. Walks the heap; O(used).
// Receiver and arg must both be heap pointers.
fn primObjBecome(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    const other = args[0];
    if (!oop_mod.isHeapPtr(receiver) or !oop_mod.isHeapPtr(other)) return error.TypeError;
    if (receiver == other) return receiver;

    const start: u64 = @intFromPtr(vm.heap.activeBase());
    const end: u64 = start + vm.heap.used;
    var addr: u64 = start;
    while (addr < end) {
        const hdr: *object.Header = @ptrFromInt(addr);

        if (hdr.class == receiver) hdr.class = other else if (hdr.class == other) hdr.class = receiver;

        const is_bytes = (hdr.flags & object.FLAG_BYTES) != 0;
        if (!is_bytes) {
            const slots: [*]Oop = @ptrFromInt(addr + @sizeOf(object.Header));
            var i: u32 = 0;
            while (i < hdr.size) : (i += 1) {
                if (slots[i] == receiver) {
                    slots[i] = other;
                } else if (slots[i] == other) {
                    slots[i] = receiver;
                }
            }
        }

        const payload_bytes = if (is_bytes) hdr.size else hdr.size * @sizeOf(Oop);
        const total = @sizeOf(object.Header) + payload_bytes;
        addr += std.mem.alignForward(usize, total, 8);
    }

    // Also swap in the image header anchor + Vm root fields, since
    // those reference heap objects by Oop too.
    const ih = vm.heap.imageHeader();
    if (ih.smalltalk == receiver) ih.smalltalk = other else if (ih.smalltalk == other) ih.smalltalk = receiver;
    swapInPlace(&vm.current_frame, receiver, other);
    swapInPlace(&vm.current_method_frame, receiver, other);
    swapInPlace(&vm.current_method_class, receiver, other);
    swapInPlace(&vm.return_value, receiver, other);
    swapInPlace(&vm.return_target, receiver, other);

    // Globals struct fields too.
    const g = &vm.globals;
    inline for (.{
        &g.object_class,           &g.behavior_class,           &g.class_description_class,
        &g.class_class,            &g.metaclass_class,          &g.undefined_class,
        &g.boolean_class,          &g.true_class,               &g.false_class,
        &g.smallinteger_class,     &g.small_float_class,        &g.byte_array_class,         &g.string_class,
        &g.symbol_class,           &g.array_class,              &g.dictionary_class,
        &g.compiled_method_class,  &g.frame_class,              &g.block_closure_class,
        &g.literal_node_class,     &g.var_ref_node_class,       &g.assign_node_class,
        &g.send_node_class,        &g.super_send_node_class,    &g.block_node_class,
        &g.seq_node_class,         &g.ret_node_class,           &g.exception_class,
        &g.smalltalk,              &g.symbol_table,
        &g.sym_nil,                &g.sym_true,                 &g.sym_false,
        &g.sym_smalltalk,          &g.sym_thisContext,          &g.sym_self,
        &g.sym_value,              &g.sym_value_colon,
        &g.sym_plus,               &g.sym_minus,                &g.sym_times,
        &g.sym_lt,                 &g.sym_le,                   &g.sym_gt,
        &g.sym_ge,                 &g.sym_printString,
    }) |p| swapInPlace(p, receiver, other);

    swapInPlace(&vm.signaled_exception, receiver, other);

    return other;
}

fn swapInPlace(p: *Oop, a: Oop, b: Oop) void {
    if (p.* == a) p.* = b else if (p.* == b) p.* = a;
}

// Object>>isKindOf: walks the receiver's class chain looking for the
// argument class. Returns true if the receiver is an instance of the
// class or any of its subclasses.
fn primObjIsKindOf(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return oop_mod.fromBool(isKindOfImpl(vm, receiver, args[0]));
}

fn isKindOfImpl(vm: *const Vm, instance: Oop, target: Oop) bool {
    var cls = vm.classOf(instance);
    while (oop_mod.isHeapPtr(cls)) {
        if (cls == target) return true;
        cls = object.slot(cls, object.SLOT_SUPERCLASS);
    }
    return false;
}

// Exception>>signal: receiver is an Exception instance; arg is the
// messageText. Stores the message and raises UserSignal carrying the
// receiver in vm.signaled_exception.
fn primExceptionSignal(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    object.setSlot(receiver, object.SLOT_EXCEPTION_MESSAGE, args[0]);
    vm.signaled_exception = receiver;
    return error.UserSignal;
}

fn primExceptionMessageText(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    return object.slot(receiver, object.SLOT_EXCEPTION_MESSAGE);
}

// Block>>ifCurtailed: aBlock — like ensure: but only runs the
// handler when the receiver escapes via an error. The original
// error is rethrown after the handler runs. Use for cleanup
// that should *only* fire on abnormal exit.
fn primBlockIfCurtailed(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    var recv_pin: Oop = receiver;
    var handler_pin: Oop = args[0];
    var slot_ptrs: [2]?*Oop = .{ &recv_pin, &handler_pin };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 2 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    return vm.sendSym(recv_pin, vm.globals.sym_value, &.{}) catch |e| {
        // Best-effort handler — swallow its own error so the
        // original propagates unchanged.
        _ = vm.sendSym(handler_pin, vm.globals.sym_value, &.{}) catch {};
        return e;
    };
}

// Exception>>pass — re-raise the current exception so outer
// on:do: handlers get a chance. The receiver is the same
// exception instance the inner handler received.
fn primExceptionPass(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    vm.signaled_exception = receiver;
    return error.UserSignal;
}

// Exception>>resignalAs: anException — abandon the current
// exception, raise a different one. Useful when wrapping a
// low-level fault into a domain-specific exception class.
fn primExceptionResignalAs(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(args[0])) return error.TypeError;
    vm.signaled_exception = args[0];
    return error.UserSignal;
}

// Block>>on:do: invokes the receiver. If a UserSignal escapes whose
// exception isKindOf args[0], invokes args[1] with the exception as
// argument and returns its result. Otherwise rethrows. Non-signal
// errors propagate unchanged.
fn primBlockOnDo(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 2) return error.ArityMismatch;
    var recv_pin: Oop = receiver;
    var exc_class_pin: Oop = args[0];
    var handler_pin: Oop = args[1];
    var slot_ptrs: [3]?*Oop = .{ &recv_pin, &exc_class_pin, &handler_pin };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 3 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    return vm.sendSym(recv_pin, vm.globals.sym_value, &.{}) catch |e| {
        if (e == error.UserSignal) {
            const exc = vm.signaled_exception;
            if (isKindOfImpl(vm, exc, exc_class_pin)) {
                vm.signaled_exception = oop_mod.NIL;
                // Pin args slice element across the handler send.
                var arg_buf: [1]Oop = .{exc};
                var arg_pin_slots: [1]?*Oop = .{&arg_buf[0]};
                var arg_pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &arg_pin_slots, .n = 1 };
                vm.root_pin = &arg_pin;
                defer vm.root_pin = arg_pin.parent;
                return vm.sendSym(handler_pin, vm.globals.sym_value_colon, &arg_buf);
            }
        }
        return e;
    };
}

// Behavior>>selectors returns an Array of the receiver's own method
// selectors (not inherited). Walks the receiver's methodDict; returns
// an empty Array when the dict is nil. Installed on Class so any class
// receiver (instance of a Metaclass that inherits Class) responds.
fn primBehaviorSelectors(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const md = object.slot(receiver, object.SLOT_METHOD_DICT);
    if (oop_mod.isNil(md)) {
        return vm.heap.allocSlots(vm.globals.array_class, 0) catch error.OutOfMemory;
    }
    const keys = object.slot(md, object.SLOT_DICT_KEYS);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(md, object.SLOT_DICT_COUNT)));
    const result = vm.heap.allocSlots(vm.globals.array_class, count) catch return error.OutOfMemory;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        object.setSlot(result, i, object.slot(keys, i));
    }
    return result;
}

// String>>startsWith: returns true if the receiver's bytes begin with
// the argument's bytes. Symbols qualify since they share the byte
// layout (FLAG_BYTES).
// Integer>>// floor division (Smalltalk semantics: rounds toward
// negative infinity). Division by zero is a primitive failure.
fn primIntDivFloor(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver) or !oop_mod.isInt(args[0])) return error.TypeError;
    const b = oop_mod.toInt(args[0]);
    if (b == 0) return error.PrimitiveFailed;
    return oop_mod.fromInt(@divFloor(oop_mod.toInt(receiver), b));
}

// Integer>>\\ floor modulo. Always returns same sign as divisor.
fn primIntModFloor(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver) or !oop_mod.isInt(args[0])) return error.TypeError;
    const b = oop_mod.toInt(args[0]);
    if (b == 0) return error.PrimitiveFailed;
    return oop_mod.fromInt(@mod(oop_mod.toInt(receiver), b));
}

// Integer>>quo: truncated division (rounds toward zero).
fn primIntQuo(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver) or !oop_mod.isInt(args[0])) return error.TypeError;
    const b = oop_mod.toInt(args[0]);
    if (b == 0) return error.PrimitiveFailed;
    return oop_mod.fromInt(@divTrunc(oop_mod.toInt(receiver), b));
}

// Integer>>rem: truncated remainder. Same sign as receiver.
fn primIntRem(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver) or !oop_mod.isInt(args[0])) return error.TypeError;
    const b = oop_mod.toInt(args[0]);
    if (b == 0) return error.PrimitiveFailed;
    return oop_mod.fromInt(@rem(oop_mod.toInt(receiver), b));
}

// SmallFloat arithmetic. Receiver must be a tagged float; the arg may
// be a tagged int (coerced to float) or another tagged float (Phase A.2).
fn primFloatAdd(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromF64(oop_mod.toF64(receiver) + b);
}

fn primFloatSub(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromF64(oop_mod.toF64(receiver) - b);
}

fn primFloatMul(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromF64(oop_mod.toF64(receiver) * b);
}

fn primFloatDiv(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    if (b == 0.0) return error.PrimitiveFailed;
    return oop_mod.fromF64(oop_mod.toF64(receiver) / b);
}

fn primFloatLt(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromBool(oop_mod.toF64(receiver) < b);
}

fn primFloatLe(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromBool(oop_mod.toF64(receiver) <= b);
}

fn primFloatGt(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromBool(oop_mod.toF64(receiver) > b);
}

fn primFloatGe(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return error.TypeError;
    return oop_mod.fromBool(oop_mod.toF64(receiver) >= b);
}

fn primFloatEq(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const b = asF64(args[0]) orelse return oop_mod.fromBool(false);
    return oop_mod.fromBool(oop_mod.toF64(receiver) == b);
}

// SmallFloat>>asString — produce a fresh String like "3.14" or "1.0e10".
fn primFloatAsString(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    var buf: [64]u8 = undefined;
    const f = oop_mod.toF64(receiver);
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return error.PrimitiveFailed;
    const result = vm.heap.allocBytes(vm.globals.string_class, @intCast(s.len)) catch return error.OutOfMemory;
    @memcpy(object.bytesOf(result)[0..s.len], s);
    return result;
}

// SmallFloat>>truncated — round toward zero to a SmallInteger.
fn primFloatTruncated(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const f = oop_mod.toF64(receiver);
    const min_i63: f64 = -4611686018427387904.0; // -(2^62)
    const max_i63: f64 = 4611686018427387903.0; // 2^62 - 1
    if (f < min_i63 or f > max_i63) return error.PrimitiveFailed;
    return oop_mod.fromInt(@intFromFloat(@trunc(f)));
}

// SmallInteger>>asFloat — convert to tagged SmallFloat.
fn primIntAsFloat(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    const i = oop_mod.toInt(receiver);
    return oop_mod.fromF64(@floatFromInt(i));
}

// String>>at: i — return the SmallInteger char code at 1-based index.
fn primStringAt(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const r_hdr = object.headerOf(receiver);
    if ((r_hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const i = oop_mod.toInt(args[0]);
    if (i < 1) return error.PrimitiveFailed;
    const idx: u32 = @intCast(i - 1);
    if (idx >= r_hdr.size) return error.PrimitiveFailed;
    return oop_mod.fromInt(@intCast(object.bytesOf(receiver)[idx]));
}

// String class>>fromCharCode: code — produce a 1-byte String with the
// given char code. Char-style operations build up via WriteStream +
// nextPutAll: with a fromCharCode: result.
fn primStringFromCharCode(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const code = oop_mod.toInt(args[0]);
    if (code < 0 or code > 255) return error.PrimitiveFailed;
    const result = vm.heap.allocBytes(vm.globals.string_class, 1) catch return error.OutOfMemory;
    object.bytesOf(result)[0] = @intCast(code);
    return result;
}

// String>>asSymbol — return the interned Symbol for these bytes.
fn primStringAsSymbol(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const hdr = object.headerOf(receiver);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const bytes = object.bytesOf(receiver)[0..hdr.size];
    return dict.newSymbol(vm.heap, &vm.globals, bytes) catch error.OutOfMemory;
}

// Symbol>>asString — allocate a fresh String with the same bytes.
// Each call returns a new object — Symbols are unique, Strings aren't.
fn primSymbolAsString(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const hdr = object.headerOf(receiver);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const result = vm.heap.allocBytes(vm.globals.string_class, hdr.size) catch return error.OutOfMemory;
    @memcpy(object.bytesOf(result)[0..hdr.size], object.bytesOf(receiver)[0..hdr.size]);
    return result;
}

// SmallInteger>>asString — decimal digit conversion. The Smalltalk-side
// printOn: protocol calls this and writes the bytes through.
fn primIntAsString(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isInt(receiver)) return error.TypeError;
    var buf: [32]u8 = undefined;
    const n = oop_mod.toInt(receiver);
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.PrimitiveFailed;
    const result = vm.heap.allocBytes(vm.globals.string_class, @intCast(s.len)) catch return error.OutOfMemory;
    @memcpy(object.bytesOf(result)[0..s.len], s);
    return result;
}

// Behavior>>name — returns the name slot of a class (a Symbol). For
// metaclass-instance receivers the slot holds thisClass instead, so
// the result is the regular class — caller's responsibility to know
// which.
fn primBehaviorName(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (object.headerOf(receiver).size <= object.SLOT_NAME) return oop_mod.NIL;
    return object.slot(receiver, object.SLOT_NAME);
}

// String>>= byte-equality. Override of Object>>= (identity) for value
// semantics on Strings and Symbols. NIL/non-byte arg → false.
fn primStringEquals(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isHeapPtr(args[0])) return oop_mod.FALSE;
    const r_hdr = object.headerOf(receiver);
    const a_hdr = object.headerOf(args[0]);
    if ((r_hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    if ((a_hdr.flags & object.FLAG_BYTES) == 0) return oop_mod.FALSE;
    if (r_hdr.size != a_hdr.size) return oop_mod.FALSE;
    const r_bytes = object.bytesOf(receiver)[0..r_hdr.size];
    const a_bytes = object.bytesOf(args[0])[0..a_hdr.size];
    return oop_mod.fromBool(std.mem.eql(u8, r_bytes, a_bytes));
}

fn primStringStartsWith(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver) or !oop_mod.isHeapPtr(args[0])) return error.TypeError;
    const r_hdr = object.headerOf(receiver);
    const p_hdr = object.headerOf(args[0]);
    if ((r_hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    if ((p_hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    if (p_hdr.size > r_hdr.size) return oop_mod.FALSE;
    const r_bytes = object.bytesOf(receiver)[0..r_hdr.size];
    const p_bytes = object.bytesOf(args[0])[0..p_hdr.size];
    return oop_mod.fromBool(std.mem.startsWith(u8, r_bytes, p_bytes));
}

// Object>>perform: invokes selector (a Symbol or String) on the
// receiver with no arguments. Used by reflective callers like the
// SUnit test runner to dispatch a test method by name.
fn primObjPerform(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    var recv_pin: Oop = receiver;
    var a_pin: Oop = args[0];
    var sel_sym_pin: Oop = oop_mod.NIL;
    var slot_ptrs: [3]?*Oop = .{ &recv_pin, &a_pin, &sel_sym_pin };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 3 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    if (!oop_mod.isHeapPtr(a_pin)) return error.TypeError;
    const hdr = object.headerOf(a_pin);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const bytes = object.bytesOf(a_pin)[0..hdr.size];
    sel_sym_pin = dict.newSymbol(vm.heap, &vm.globals, bytes) catch return error.OutOfMemory;
    return vm.sendSym(recv_pin, sel_sym_pin, &.{});
}

// Block>>ensure: runs the ensure block in both the normal and the
// exceptional path. If the receiver throws, the ensure block runs and
// the original error is rethrown.
fn primBlockEnsure(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    var recv_pin: Oop = receiver;
    var ensure_pin: Oop = args[0];
    var result_pin: Oop = oop_mod.NIL;
    var slot_ptrs: [3]?*Oop = .{ &recv_pin, &ensure_pin, &result_pin };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 3 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    result_pin = vm.sendSym(recv_pin, vm.globals.sym_value, &.{}) catch |e| {
        // Best-effort run of the ensure block; swallow its own error
        // so the original propagates.
        _ = vm.sendSym(ensure_pin, vm.globals.sym_value, &.{}) catch {};
        return e;
    };
    _ = try vm.sendSym(ensure_pin, vm.globals.sym_value, &.{});
    return result_pin;
}

// Class>>new: allocate a fresh instance of `receiver` (a class), with
// slot count equal to the class's total ivar count up the chain. All
// slots are NIL. This is the canonical Smalltalk constructor.
fn primClassNew(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const class_mod = @import("class.zig");
    const n = class_mod.countIvars(receiver);
    return vm.heap.allocSlots(receiver, n) catch error.OutOfMemory;
}

fn primBlockWhileFalse(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    var recv_pin: Oop = receiver;
    var body_pin: Oop = args[0];
    var slot_ptrs: [2]?*Oop = .{ &recv_pin, &body_pin };
    var pin = eval_mod.RootPin{
        .parent = vm.root_pin,
        .slots = &slot_ptrs,
        .n = 2,
    };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;
    while (true) {
        const cond = try vm.sendSym(recv_pin, vm.globals.sym_value, &.{});
        if (cond != oop_mod.FALSE) break;
        _ = try vm.sendSym(body_pin, vm.globals.sym_value, &.{});
    }
    return oop_mod.NIL;
}

// Large* arithmetic primitives. Receiver is always a Large; arg may
// be Small, Large, or Float. Float ops return Float.
const CmpKind = enum { lt, le, gt, ge, eq };

fn largeArgIsNumeric(vm: *Vm, o: Oop) bool {
    return oop_mod.isInt(o) or oop_mod.isFloat(o) or bigint.isLarge(&vm.globals, o);
}

fn primLargeAdd(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!bigint.isLarge(&vm.globals, receiver)) return error.TypeError;
    if (oop_mod.isFloat(args[0])) {
        const a = bigint.toF64(&vm.globals, receiver) orelse return error.TypeError;
        return oop_mod.fromF64(a + oop_mod.toF64(args[0]));
    }
    if (!largeArgIsNumeric(vm, args[0])) return error.TypeError;
    return bigint.add(vm.heap, &vm.globals, receiver, args[0]);
}

fn primLargeSub(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!bigint.isLarge(&vm.globals, receiver)) return error.TypeError;
    if (oop_mod.isFloat(args[0])) {
        const a = bigint.toF64(&vm.globals, receiver) orelse return error.TypeError;
        return oop_mod.fromF64(a - oop_mod.toF64(args[0]));
    }
    if (!largeArgIsNumeric(vm, args[0])) return error.TypeError;
    return bigint.sub(vm.heap, &vm.globals, receiver, args[0]);
}

fn primLargeMul(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!bigint.isLarge(&vm.globals, receiver)) return error.TypeError;
    if (oop_mod.isFloat(args[0])) {
        const a = bigint.toF64(&vm.globals, receiver) orelse return error.TypeError;
        return oop_mod.fromF64(a * oop_mod.toF64(args[0]));
    }
    if (!largeArgIsNumeric(vm, args[0])) return error.TypeError;
    return bigint.mul(vm.heap, &vm.globals, receiver, args[0]);
}

fn primLargeCmp(vm: *Vm, receiver: Oop, args: []const Oop, kind: CmpKind) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!bigint.isLarge(&vm.globals, receiver)) return error.TypeError;
    if (oop_mod.isFloat(args[0])) {
        const a = bigint.toF64(&vm.globals, receiver) orelse return error.TypeError;
        const b = oop_mod.toF64(args[0]);
        return oop_mod.fromBool(switch (kind) {
            .lt => a < b,
            .le => a <= b,
            .gt => a > b,
            .ge => a >= b,
            .eq => a == b,
        });
    }
    if (!(oop_mod.isInt(args[0]) or bigint.isLarge(&vm.globals, args[0]))) {
        return if (kind == .eq) oop_mod.fromBool(false) else error.TypeError;
    }
    const o = bigint.cmp(&vm.globals, receiver, args[0]) orelse return error.TypeError;
    return oop_mod.fromBool(switch (kind) {
        .lt => o == .lt,
        .le => o != .gt,
        .gt => o == .gt,
        .ge => o != .lt,
        .eq => o == .eq,
    });
}

fn primLargeAsString(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!bigint.isLarge(&vm.globals, receiver)) return error.TypeError;
    return bigint.asString(vm.heap, &vm.globals, receiver);
}

fn primLargeAsFloat(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    const f = bigint.toF64(&vm.globals, receiver) orelse return error.TypeError;
    return oop_mod.fromF64(f);
}

const FloatMathOp = enum { sqrt, sin, cos, ln, exp };

fn primFloatMath(_: *Vm, receiver: Oop, args: []const Oop, op: FloatMathOp) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isFloat(receiver)) return error.TypeError;
    const x = oop_mod.toF64(receiver);
    const y: f64 = switch (op) {
        .sqrt => if (x < 0) return error.PrimitiveFailed else @sqrt(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .ln => if (x <= 0) return error.PrimitiveFailed else @log(x),
        .exp => @exp(x),
    };
    return oop_mod.fromF64(y);
}

// ─────────────────────────────────────────────────────────────────────
// Concurrency primitives. The semantics here are deliberately
// placeholder-cooperative: there is no preemption yet, no native
// stack switching, and `wait` cannot actually block. Each prim
// performs the *bookkeeping* that the real scheduler will hook into
// once it lands. Once context switching ships, fork/wait/yield will
// transfer control without changing their public contract.
// ─────────────────────────────────────────────────────────────────────

fn newProcess(vm: *Vm, block: Oop, priority: i64) PrimError!Oop {
    if (oop_mod.isNil(vm.globals.process_class)) return error.NotImplemented;
    const p = try vm.heap.allocSlots(vm.globals.process_class, object.PROCESS_INST_SIZE);
    object.setSlot(p, object.SLOT_PROCESS_PRIORITY, oop_mod.fromInt(priority));
    object.setSlot(p, object.SLOT_PROCESS_STATE, vm.globals.sym_runnable);
    object.setSlot(p, object.SLOT_PROCESS_BLOCK, block);
    object.setSlot(p, object.SLOT_PROCESS_NAME, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_RESULT, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_SUSPENDED_CONTEXT, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_SAVED_FRAME, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_SAVED_METHOD_FRAME, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_SAVED_METHOD_CLASS, oop_mod.NIL);
    object.setSlot(p, object.SLOT_PROCESS_DEADLINE, oop_mod.fromInt(0));
    return p;
}

// Append a Process onto the scheduler's runnable list for its priority.
// Without preemption we never *pop* from these lists — the bookkeeping
// is here so a future scheduler can find every forked process.
fn schedulerEnqueue(vm: *Vm, process: Oop) void {
    const sched = vm.globals.processor;
    if (!oop_mod.isHeapPtr(sched)) return;
    const lists = object.slot(sched, object.SLOT_SCHEDULER_QLISTS);
    if (!oop_mod.isHeapPtr(lists)) return;
    const pri_oop = object.slot(process, object.SLOT_PROCESS_PRIORITY);
    if (!oop_mod.isInt(pri_oop)) return;
    const pri: usize = @intCast(@max(@as(i64, 1), @min(@as(i64, object.MAX_PRIORITY), oop_mod.toInt(pri_oop))));
    if (pri >= object.headerOf(lists).size) return;
    // Insert at tail by walking. Lists are short in practice (one per
    // priority) so a linear walk is fine; a doubly-linked list with a
    // tail pointer can come later if profiling demands it.
    object.setSlot(process, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
    const head = object.slot(lists, @intCast(pri));
    if (oop_mod.isNil(head)) {
        object.setSlot(lists, @intCast(pri), process);
        return;
    }
    var cur = head;
    while (true) {
        const nxt = object.slot(cur, object.SLOT_PROCESS_NEXT_LINK);
        if (oop_mod.isNil(nxt)) break;
        cur = nxt;
    }
    object.setSlot(cur, object.SLOT_PROCESS_NEXT_LINK, process);
}

const ForkPriorityMode = enum { from_arg };

// BlockClosure>>fork  →  allocate a Process at the default priority,
// allocate it a stack + saved-Context, prepare its first-swap
// trampoline to run the block, link it onto the scheduler's
// runnable list, and return the Process oop. The block does *not*
// run synchronously; it runs the next time the scheduler picks
// this Process (e.g. on yield / wait / termination of the active).
//
// BlockClosure>>forkAt: aPriority  →  same with caller-supplied priority.
fn primBlockFork(vm: *Vm, receiver: Oop, args: []const Oop, mode: ?ForkPriorityMode) PrimError!Oop {
    var recv_pin: Oop = receiver;
    var arg_pin: Oop = if (args.len > 0) args[0] else oop_mod.NIL;
    var slots: [2]?*Oop = .{ &recv_pin, &arg_pin };
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slots, .n = 2 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;

    if (!oop_mod.isHeapPtr(recv_pin)) return error.TypeError;
    if (object.headerOf(recv_pin).class != vm.globals.block_closure_class) return error.TypeError;

    var priority: i64 = object.PRIORITY_USER_SCHEDULING;
    if (mode) |_| {
        if (args.len != 1) return error.ArityMismatch;
        if (!oop_mod.isInt(arg_pin)) return error.TypeError;
        priority = oop_mod.toInt(arg_pin);
        if (priority < 1 or priority > object.MAX_PRIORITY) return error.PrimitiveFailed;
    } else {
        if (args.len != 0) return error.ArityMismatch;
    }

    // Make sure the host thread has a Process oop too — the new
    // process needs *somewhere* to schedule back to once it's done.
    try vm.ensureMainProcess();

    const p = try newProcess(vm, recv_pin, priority);
    var p_pin: Oop = p;
    var p_slots: [1]?*Oop = .{&p_pin};
    var p_pin_root = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &p_slots, .n = 1 };
    vm.root_pin = &p_pin_root;
    defer vm.root_pin = p_pin_root.parent;

    try vm.primeProcess(p_pin);
    schedulerEnqueue(vm, p_pin);
    return p_pin;
}

// Semaphore>>wait — decrement count when positive; otherwise
// suspend the active Process onto the semaphore's waiters queue
// and hand control to the next runnable. When the wait returns,
// it means another Process called signal and rescheduled us.
fn primSemaphoreWait(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    var recv_pin: Oop = receiver;
    var slots: [1]?*Oop = .{&recv_pin};
    var pin = eval_mod.RootPin{ .parent = vm.root_pin, .slots = &slots, .n = 1 };
    vm.root_pin = &pin;
    defer vm.root_pin = pin.parent;

    const cnt_oop = object.slot(recv_pin, object.SLOT_SEMA_COUNT);
    if (!oop_mod.isInt(cnt_oop)) return error.TypeError;
    const cnt = oop_mod.toInt(cnt_oop);
    if (cnt > 0) {
        object.setSlot(recv_pin, object.SLOT_SEMA_COUNT, oop_mod.fromInt(cnt - 1));
        return recv_pin;
    }
    // Block the active Process on this Semaphore. Caller must have
    // an active Process — ensureMainProcess guarantees one.
    try vm.ensureMainProcess();
    const active = vm.current_process;
    object.setSlot(active, object.SLOT_PROCESS_STATE, vm.globals.sym_waiting);
    object.setSlot(active, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
    const tail = object.slot(recv_pin, object.SLOT_SEMA_WAITERS_TAIL);
    if (oop_mod.isHeapPtr(tail)) {
        object.setSlot(tail, object.SLOT_PROCESS_NEXT_LINK, active);
    } else {
        object.setSlot(recv_pin, object.SLOT_SEMA_WAITERS_HEAD, active);
    }
    object.setSlot(recv_pin, object.SLOT_SEMA_WAITERS_TAIL, active);

    // Hand control off. When scheduleNext eventually swaps back
    // here, our state has been flipped to runnable by `signal`.
    try vm.scheduleNext();
    return recv_pin;
}

// Semaphore>>signal — increment count. If a Process is already on the
// waiters list, mark it runnable and unlink; the actual transfer of
// control happens when the scheduler runs.
fn primSemaphoreSignal(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const cnt_oop = object.slot(receiver, object.SLOT_SEMA_COUNT);
    if (!oop_mod.isInt(cnt_oop)) return error.TypeError;

    const head = object.slot(receiver, object.SLOT_SEMA_WAITERS_HEAD);
    if (oop_mod.isHeapPtr(head)) {
        const next = object.slot(head, object.SLOT_PROCESS_NEXT_LINK);
        object.setSlot(receiver, object.SLOT_SEMA_WAITERS_HEAD, next);
        if (oop_mod.isNil(next)) {
            object.setSlot(receiver, object.SLOT_SEMA_WAITERS_TAIL, oop_mod.NIL);
        }
        object.setSlot(head, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
        object.setSlot(head, object.SLOT_PROCESS_STATE, vm.globals.sym_runnable);
        schedulerEnqueue(vm, head);
        return receiver;
    }
    object.setSlot(receiver, object.SLOT_SEMA_COUNT, oop_mod.fromInt(oop_mod.toInt(cnt_oop) + 1));
    return receiver;
}

fn primProcessResume(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    object.setSlot(receiver, object.SLOT_PROCESS_STATE, vm.globals.sym_runnable);
    schedulerEnqueue(vm, receiver);
    return receiver;
}

fn primProcessSuspend(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    object.setSlot(receiver, object.SLOT_PROCESS_STATE, vm.globals.sym_suspended);
    return receiver;
}

fn primProcessTerminate(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    object.setSlot(receiver, object.SLOT_PROCESS_STATE, vm.globals.sym_terminated);
    return receiver;
}

// Processor>>yield — push the active Process to the back of its
// priority's runnable list and pick the next runnable. If nothing
// else is runnable we stay where we are, matching classic
// Smalltalk semantics ("yield is a hint, not a contract").
fn primProcessorYield(vm: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    try vm.scheduleNext();
    return oop_mod.NIL;
}

// Processor>>activeProcess — returns the scheduler's recorded active
// Process slot. NIL when no fork has happened yet.
fn primProcessorActive(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    return object.slot(receiver, object.SLOT_SCHEDULER_ACTIVE);
}

// Time monotonicNanos — current CLOCK_MONOTONIC value as a SmallInt.
// Receiver irrelevant; this is a class-side / static-style primitive.
fn primTimeMonoNanos(_: *Vm, _: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    const nanos = eval_mod.monotonicNanos();
    if (!oop_mod.fitsSmallInt(nanos)) return error.PrimitiveFailed;
    return oop_mod.fromInt(nanos);
}

// IPv4 socket primitives. Receiver is a Socket whose first ivar
// (slot 0) holds the underlying fd — same convention as
// FileStream so the read:/readAll/nextPutAll:/primClose prims
// installed on Socket below operate on the fd. Hostnames must
// be dotted IPv4 literals; DNS resolution is out of scope for
// this commit.

fn parseIp4(s: []const u8) ?u32 {
    var parts: [4]u32 = undefined;
    var idx: u32 = 0;
    var cur: u32 = 0;
    var saw: bool = false;
    var p: usize = 0;
    while (p < s.len) : (p += 1) {
        const ch = s[p];
        if (ch >= '0' and ch <= '9') {
            cur = cur * 10 + (ch - '0');
            if (cur > 255) return null;
            saw = true;
        } else if (ch == '.') {
            if (!saw or idx >= 3) return null;
            parts[idx] = cur;
            idx += 1;
            cur = 0;
            saw = false;
        } else return null;
    }
    if (!saw or idx != 3) return null;
    parts[3] = cur;
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

fn buildSockaddrIn(ip_be: u32, port: u16) std.posix.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, ip_be),
    };
}

// Socket>>primConnect: aHost port: aPort
//   aHost must be a dotted IPv4 string (DNS not yet supported).
//   Stores the connected fd into the receiver's slot 0 and
//   returns the receiver so chains compose.
fn primSockConnect(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 2) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isHeapPtr(args[0])) return error.TypeError;
    if (!oop_mod.isInt(args[1])) return error.TypeError;
    const host_hdr = object.headerOf(args[0]);
    if ((host_hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const host_bytes = object.bytesOf(args[0])[0..host_hdr.size];
    const ip = parseIp4(host_bytes) orelse return error.PrimitiveFailed;
    const port_int = oop_mod.toInt(args[1]);
    if (port_int < 0 or port_int > 65535) return error.PrimitiveFailed;

    const fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.PrimitiveFailed;
    const sa = buildSockaddrIn(ip, @intCast(port_int));
    const sa_ptr: *const std.posix.sockaddr = @ptrCast(&sa);
    if (std.posix.system.connect(fd, sa_ptr, @sizeOf(@TypeOf(sa))) != 0) {
        _ = std.posix.system.close(fd);
        return error.PrimitiveFailed;
    }
    object.setSlot(receiver, FS_FD_SLOT, oop_mod.fromInt(@intCast(fd)));
    return receiver;
}

// Socket>>primListen: aPort  — bind to 0.0.0.0:aPort with
// SO_REUSEADDR, then listen with backlog 16. Stores the
// listening fd into the receiver's slot 0.
fn primSockListen(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const port_int = oop_mod.toInt(args[0]);
    if (port_int < 0 or port_int > 65535) return error.PrimitiveFailed;

    const fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.PrimitiveFailed;
    const reuse: c_int = 1;
    _ = std.posix.system.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &reuse, @sizeOf(c_int));
    const sa = buildSockaddrIn(0, @intCast(port_int));
    const sa_ptr: *const std.posix.sockaddr = @ptrCast(&sa);
    if (std.posix.system.bind(fd, sa_ptr, @sizeOf(@TypeOf(sa))) != 0) {
        _ = std.posix.system.close(fd);
        return error.PrimitiveFailed;
    }
    if (std.posix.system.listen(fd, 16) != 0) {
        _ = std.posix.system.close(fd);
        return error.PrimitiveFailed;
    }
    object.setSlot(receiver, FS_FD_SLOT, oop_mod.fromInt(@intCast(fd)));
    return receiver;
}

// Socket>>accept  — block on the listener's accept(), then
// allocate a fresh Socket whose fd is the new connected fd.
// Returns the new Socket; the receiver remains the listener.
fn primSockAccept(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const listen_fd = try fsFdOf(receiver);
    const cli_fd = std.posix.system.accept(listen_fd, null, null);
    if (cli_fd < 0) return error.PrimitiveFailed;
    if (!oop_mod.isHeapPtr(vm.globals.socket_class)) {
        _ = std.posix.system.close(cli_fd);
        return error.PrimitiveFailed;
    }
    const sock = vm.heap.allocSlots(vm.globals.socket_class, 1) catch {
        _ = std.posix.system.close(cli_fd);
        return error.OutOfMemory;
    };
    object.setSlot(sock, FS_FD_SLOT, oop_mod.fromInt(@intCast(cli_fd)));
    return sock;
}

// Object>>instVarAt: i  — 1-based slot read. For byte-objects
// (String, ByteArray, Symbol) returns the byte as a SmallInt to
// mirror Pharo. SmallIntegers / sentinels have no slots and
// raise PrimitiveFailed.
fn primObjInstVarAt(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.PrimitiveFailed;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const i = oop_mod.toInt(args[0]);
    if (i < 1) return error.PrimitiveFailed;
    const idx: u32 = @intCast(i - 1);
    const hdr = object.headerOf(receiver);
    if (idx >= hdr.size) return error.PrimitiveFailed;
    if ((hdr.flags & object.FLAG_BYTES) != 0) {
        return oop_mod.fromInt(@intCast(object.bytesOf(receiver)[idx]));
    }
    return object.slot(receiver, idx);
}

// Object>>instVarAt: i put: anObject  — 1-based slot store.
// For byte-objects, anObject must be a SmallInt 0..255. Returns
// the stored value (consistent with at:put: convention).
fn primObjInstVarAtPut(_: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 2) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.PrimitiveFailed;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const i = oop_mod.toInt(args[0]);
    if (i < 1) return error.PrimitiveFailed;
    const idx: u32 = @intCast(i - 1);
    const hdr = object.headerOf(receiver);
    if (idx >= hdr.size) return error.PrimitiveFailed;
    if ((hdr.flags & object.FLAG_BYTES) != 0) {
        if (!oop_mod.isInt(args[1])) return error.TypeError;
        const b = oop_mod.toInt(args[1]);
        if (b < 0 or b > 255) return error.PrimitiveFailed;
        object.bytesOf(receiver)[idx] = @intCast(b);
        return args[1];
    }
    object.setSlot(receiver, idx, args[1]);
    return args[1];
}

// Object>>isMemberOf: aClass  — exact class match (unlike
// isKindOf: which walks the superclass chain).
fn primObjIsMemberOf(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    return oop_mod.fromBool(vm.classOf(receiver) == args[0]);
}

// Behavior>>instVarNames  — Array of Symbols naming each
// non-byte instance variable, in slot order. Returns an empty
// Array when the class has none. Receiver must be a class.
fn primBehaviorInstVarNames(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const names = object.slot(receiver, object.SLOT_CLASS_IVAR_NAMES);
    if (oop_mod.isHeapPtr(names)) return names;
    // Class predates ivar-names tracking; return an empty Array
    // rather than NIL so callers can iterate uniformly.
    return vm.heap.allocSlots(vm.globals.array_class, 0) catch error.OutOfMemory;
}

// File-stream primitives. Receiver is a FileStream instance whose
// first ivar slot (index 0, "fd") holds the underlying SmallInt fd
// — these prims read it directly and avoid an arg shuffle. Path
// strings are copied through a 4 KiB stack buffer so we can hand
// a null-terminated `[*:0]const u8` to `openatZ`; longer paths
// fail with PrimitiveFailed (good enough for an LLM-driven VM).
const FS_PATH_MAX: usize = 4096;
const FS_FD_SLOT: u32 = 0;

fn fsCopyPathZ(buf: *[FS_PATH_MAX]u8, path_oop: Oop) PrimError![*:0]const u8 {
    if (!oop_mod.isHeapPtr(path_oop)) return error.TypeError;
    const hdr = object.headerOf(path_oop);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    if (hdr.size + 1 > FS_PATH_MAX) return error.PrimitiveFailed;
    const src = object.bytesOf(path_oop)[0..hdr.size];
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return @ptrCast(buf);
}

fn fsFdOf(receiver: Oop) PrimError!std.posix.fd_t {
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const fd_oop = object.slot(receiver, FS_FD_SLOT);
    if (!oop_mod.isInt(fd_oop)) return error.TypeError;
    const fd = oop_mod.toInt(fd_oop);
    if (fd < 0) return error.PrimitiveFailed;
    return @intCast(fd);
}

// FileStream>>primOpenPath: aPath mode: aMode
//   modes: 0 = read-only; 1 = write+truncate; 2 = write+append.
//   Stores the fd into the receiver's `fd` ivar and returns receiver.
fn primFsOpen(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    if (!oop_mod.isInt(args[1])) return error.TypeError;
    var path_buf: [FS_PATH_MAX]u8 = undefined;
    const path_z = try fsCopyPathZ(&path_buf, args[0]);

    var flags: std.posix.O = .{};
    var perm: std.posix.mode_t = 0;
    switch (oop_mod.toInt(args[1])) {
        0 => flags.ACCMODE = .RDONLY,
        1 => {
            flags.ACCMODE = .WRONLY;
            flags.CREAT = true;
            flags.TRUNC = true;
            perm = 0o644;
        },
        2 => {
            flags.ACCMODE = .WRONLY;
            flags.CREAT = true;
            flags.APPEND = true;
            perm = 0o644;
        },
        else => return error.PrimitiveFailed,
    }
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path_z, flags, perm) catch return error.PrimitiveFailed;
    object.setSlot(receiver, FS_FD_SLOT, oop_mod.fromInt(@intCast(fd)));
    return receiver;
}

// FileStream>>read: aMaxBytes  → String of up to aMaxBytes from fd.
// Empty String on EOF. Capped at 1 GiB to keep allocation sane.
fn primFsRead(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 1) return error.ArityMismatch;
    if (!oop_mod.isInt(args[0])) return error.TypeError;
    const fd = try fsFdOf(receiver);
    const max_int = oop_mod.toInt(args[0]);
    if (max_int < 0 or max_int > 1 << 30) return error.PrimitiveFailed;
    const max: usize = @intCast(max_int);

    const tmp = std.heap.page_allocator.alloc(u8, max) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(tmp);
    const n = std.posix.read(fd, tmp) catch return error.PrimitiveFailed;
    const result = try vm.heap.allocBytes(vm.globals.string_class, @intCast(n));
    if (n > 0) @memcpy(object.bytesOf(result)[0..n], tmp[0..n]);
    return result;
}

// FileStream>>readAll  → String of all remaining bytes from fd.
// Streams in 4 KiB chunks into a Zig ArrayList so we don't need
// fstat. Returns an empty String on an already-EOF fd.
fn primFsReadAll(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    const fd = try fsFdOf(receiver);

    const alloc = std.heap.page_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &chunk) catch return error.PrimitiveFailed;
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch return error.OutOfMemory;
    }
    const result = try vm.heap.allocBytes(vm.globals.string_class, @intCast(buf.items.len));
    if (buf.items.len > 0) @memcpy(object.bytesOf(result)[0..buf.items.len], buf.items);
    return result;
}

// FileStream>>nextPutAll: aString  — write the byte payload to fd
// in a loop until it's all out. Returns receiver so chains compose.
fn primFsWrite(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const fd = try fsFdOf(receiver);
    if (!oop_mod.isHeapPtr(args[0])) return error.TypeError;
    const hdr = object.headerOf(args[0]);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.TypeError;
    const bytes = object.bytesOf(args[0])[0..hdr.size];

    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.posix.system.write(fd, bytes.ptr + written, bytes.len - written);
        if (rc < 0) return error.PrimitiveFailed;
        if (rc == 0) break;
        written += @intCast(rc);
    }
    return receiver;
}

// FileStream>>primClose  — close the fd and set the slot to -1 so
// subsequent ops fail predictably. Idempotent on an already-closed
// FileStream (fd == -1).
fn primFsClose(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    _ = vm;
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const fd_oop = object.slot(receiver, FS_FD_SLOT);
    if (oop_mod.isInt(fd_oop)) {
        const fd = oop_mod.toInt(fd_oop);
        if (fd >= 0) {
            _ = std.posix.system.close(@intCast(fd));
        }
    }
    object.setSlot(receiver, FS_FD_SLOT, oop_mod.fromInt(-1));
    return receiver;
}

// Delay>>wait — park the active Process on the scheduler's sorted
// delay list using the receiver's deadlineNanos ivar (slot 0), then
// hand control to the next runnable. When this returns we've been
// re-enqueued by the scheduler's expireSleepers walk.
fn primDelayWait(vm: *Vm, receiver: Oop, args: []const Oop) PrimError!Oop {
    if (args.len != 0) return error.ArityMismatch;
    if (!oop_mod.isHeapPtr(receiver)) return error.TypeError;
    const dl_oop = object.slot(receiver, 0);
    if (!oop_mod.isInt(dl_oop)) return error.TypeError;

    try vm.ensureMainProcess();
    const active = vm.current_process;
    object.setSlot(active, object.SLOT_PROCESS_DEADLINE, dl_oop);
    object.setSlot(active, object.SLOT_PROCESS_STATE, vm.globals.sym_waiting);
    vm.delayEnqueue(active);

    // Hand off; when scheduleNext eventually returns to us our
    // deadline has already passed and expireSleepers re-queued us.
    try vm.scheduleNext();
    return oop_mod.NIL;
}
