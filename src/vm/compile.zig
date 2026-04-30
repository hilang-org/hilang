// AST → bytecode compiler. Walks a method's body AST and emits a
// stream of u32 instructions plus a literal pool. Hits an
// unsupported node (BlockNode, SuperSendNode) and returns
// `error.Unsupported`; the caller then keeps using the AST
// interpreter for that method. Phase D will incrementally add
// support for the missing nodes.

const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const globals_mod = @import("globals.zig");
const dict = @import("dict.zig");
const bc = @import("bytecode.zig");

const Heap = heap_mod.Heap;
const Globals = globals_mod.Globals;
const Oop = oop_mod.Oop;

pub const CompileError = error{
    Unsupported,
    OutOfMemory,
    OperandOverflow,
};

const MAX_INSTRS = 4096;
const MAX_LITERALS = 256;

pub fn compileMethod(heap: *Heap, g: *const Globals, method: Oop) CompileError!void {
    const body = object.slot(method, object.SLOT_METHOD_BODY);
    const params_arr = object.slot(method, object.SLOT_METHOD_PARAMS);
    const temps_arr = object.slot(method, object.SLOT_METHOD_TEMPS);

    var ctx = Ctx{
        .heap = heap,
        .g = g,
        .params = params_arr,
        .temps = temps_arr,
        .is_block_scope = false,
        .instrs = undefined,
        .n_instrs = 0,
        .literals = undefined,
        .n_literals = 0,
    };
    @memset(&ctx.literals, oop_mod.NIL);

    // Compile the method body. The result of evaluating it is the
    // implicit return value of a method without explicit `^`. Trailing
    // RETURN_TOP gives that semantics.
    try compileBody(&ctx, body);
    try emit(&ctx, .return_top, 0);

    // Allocate heap storage for bytecode and literals, blit, install.
    const bytes_n: u32 = @intCast(ctx.n_instrs * @sizeOf(bc.Instr));
    const code = heap.allocBytes(g.byte_array_class, bytes_n) catch return error.OutOfMemory;
    const code_bytes = object.bytesOf(code);
    var i: u32 = 0;
    while (i < ctx.n_instrs) : (i += 1) {
        std.mem.writeInt(u32, code_bytes[i * 4 ..][0..4], ctx.instrs[i], .little);
    }

    const lits = heap.allocSlots(g.array_class, ctx.n_literals) catch return error.OutOfMemory;
    var k: u32 = 0;
    while (k < ctx.n_literals) : (k += 1) object.setSlot(lits, k, ctx.literals[k]);

    object.setSlot(method, object.SLOT_METHOD_BYTECODE, code);
    object.setSlot(method, object.SLOT_METHOD_LITERALS, lits);
    object.setSlot(method, object.SLOT_METHOD_KIND, oop_mod.fromInt(object.METHOD_KIND_BYTECODE));
}

const Ctx = struct {
    heap: *Heap,
    g: *const Globals,
    params: Oop,
    temps: Oop,
    // Method frames have `self` at value-slot 0, params start at 1.
    // Block frames have no self in their frame, params start at 0.
    // Both contexts emit PUSH_SELF (reads from home method's frame
    // slot 0) for `self`, but the slot offset for params/temps
    // differs by 1.
    is_block_scope: bool,
    instrs: [MAX_INSTRS]bc.Instr,
    n_instrs: u32,
    literals: [MAX_LITERALS]Oop,
    n_literals: u32,
};

fn emit(ctx: *Ctx, op: bc.Op, operand: u32) CompileError!void {
    if (ctx.n_instrs >= MAX_INSTRS) return error.OperandOverflow;
    if (operand > 0x00FF_FFFF) return error.OperandOverflow;
    ctx.instrs[ctx.n_instrs] = bc.encode(op, operand);
    ctx.n_instrs += 1;
}

fn emitRaw(ctx: *Ctx, instr: bc.Instr) CompileError!void {
    if (ctx.n_instrs >= MAX_INSTRS) return error.OperandOverflow;
    ctx.instrs[ctx.n_instrs] = instr;
    ctx.n_instrs += 1;
}

// Add `value` to the literal pool (deduplicated by identity) and
// return its index.
fn addLiteral(ctx: *Ctx, value: Oop) CompileError!u32 {
    var i: u32 = 0;
    while (i < ctx.n_literals) : (i += 1) {
        if (ctx.literals[i] == value) return i;
    }
    if (ctx.n_literals >= MAX_LITERALS) return error.OperandOverflow;
    const idx = ctx.n_literals;
    ctx.literals[idx] = value;
    ctx.n_literals += 1;
    return idx;
}

// Resolve a name symbol against this context's params/temps. Returns
// the value-array offset to use as the operand of PUSH_LOCAL /
// STORE_LOCAL. Caller handles `self` separately (always PUSH_SELF).
// Returns null if the name is neither a param nor a temp here.
fn resolveLocal(ctx: *Ctx, name_sym: Oop) ?u32 {
    const base: u32 = if (ctx.is_block_scope) 0 else 1;
    const params_n = if (oop_mod.isHeapPtr(ctx.params)) object.headerOf(ctx.params).size else 0;
    var i: u32 = 0;
    while (i < params_n) : (i += 1) {
        if (object.slot(ctx.params, i) == name_sym) return base + i;
    }
    const temps_n = if (oop_mod.isHeapPtr(ctx.temps)) object.headerOf(ctx.temps).size else 0;
    var j: u32 = 0;
    while (j < temps_n) : (j += 1) {
        if (object.slot(ctx.temps, j) == name_sym) return base + params_n + j;
    }
    return null;
}

fn compileBody(ctx: *Ctx, body: Oop) CompileError!void {
    if (oop_mod.isNil(body)) {
        try emit(ctx, .push_nil, 0);
        return;
    }
    if (!oop_mod.isHeapPtr(body)) {
        // Bare tagged-int / bool literal in the body slot — treat it
        // as a single expression.
        try compileExpr(ctx, body);
        return;
    }
    const cls = object.headerOf(body).class;

    // Method body is conventionally an Array of statements.
    if (cls == ctx.g.array_class) {
        const n = object.headerOf(body).size;
        if (n == 0) {
            try emit(ctx, .push_nil, 0);
            return;
        }
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try compileExpr(ctx, object.slot(body, i));
            if (i + 1 < n) try emit(ctx, .pop, 0);
        }
        return;
    }
    try compileExpr(ctx, body);
}

fn compileExpr(ctx: *Ctx, node: Oop) CompileError!void {
    if (oop_mod.isNil(node)) {
        try emit(ctx, .push_nil, 0);
        return;
    }
    if (!oop_mod.isHeapPtr(node)) {
        // Bare tagged value used as a literal.
        const idx = try addLiteral(ctx, node);
        try emit(ctx, .push_lit, idx);
        return;
    }
    const cls = object.headerOf(node).class;
    const g = ctx.g;

    if (cls == g.literal_node_class) {
        const v = object.slot(node, object.SLOT_LIT_VALUE);
        if (v == oop_mod.NIL) return emit(ctx, .push_nil, 0);
        if (v == oop_mod.TRUE) return emit(ctx, .push_true, 0);
        if (v == oop_mod.FALSE) return emit(ctx, .push_false, 0);
        const idx = try addLiteral(ctx, v);
        return emit(ctx, .push_lit, idx);
    }

    if (cls == g.var_ref_node_class) {
        const name = object.slot(node, object.SLOT_VARREF_NAME);
        // `self` always uses PUSH_SELF; for blocks it reads through
        // the home method's frame, for methods through the current
        // frame's value slot 0.
        if (name == g.sym_self) return emit(ctx, .push_self, 0);
        if (resolveLocal(ctx, name)) |slot_idx| {
            return emit(ctx, .push_local, slot_idx);
        }
        // Pseudo-variables that aren't `self`.
        if (name == g.sym_nil) return emit(ctx, .push_nil, 0);
        if (name == g.sym_true) return emit(ctx, .push_true, 0);
        if (name == g.sym_false) return emit(ctx, .push_false, 0);
        // Compile-time global resolution: only emit push_global if
        // the symbol is currently in the Smalltalk dict. Other
        // var refs (ivars, thisContext, smalltalk pseudo-var) need
        // semantics the bytecode compiler doesn't yet model — fall
        // back to AST evaluation for those.
        if (dict.hasSym(g.smalltalk, name)) {
            const idx = try addLiteral(ctx, name);
            return emit(ctx, .push_global, idx);
        }
        return error.Unsupported;
    }

    if (cls == g.assign_node_class) {
        const name = object.slot(node, object.SLOT_ASSIGN_NAME);
        const value = object.slot(node, object.SLOT_ASSIGN_VALUE);
        // Assignment to `self` is illegal in Smalltalk; let AST
        // handle the diagnostic.
        if (name == g.sym_self) return error.Unsupported;
        const slot_idx = resolveLocal(ctx, name) orelse return error.Unsupported;
        try compileExpr(ctx, value);
        return emit(ctx, .store_local, slot_idx);
    }

    if (cls == g.send_node_class) {
        const recv_node = object.slot(node, object.SLOT_SEND_RECEIVER);
        const sel = object.slot(node, object.SLOT_SEND_SELECTOR);
        const args_arr = object.slot(node, object.SLOT_SEND_ARGS);
        const arity: u32 = if (oop_mod.isHeapPtr(args_arr)) object.headerOf(args_arr).size else 0;
        if (arity > 255) return error.OperandOverflow;

        // Special-case inlining for the four common control-flow
        // selectors. We pattern-match on the selector + arg shape and
        // emit jumps; the blocks become inline code with no separate
        // BlockClosure allocation. Blocks with params or temps fall
        // through to the generic SEND path.
        if (try tryInlineControlFlow(ctx, sel, recv_node, args_arr, arity)) return;

        try compileExpr(ctx, recv_node);
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            try compileExpr(ctx, object.slot(args_arr, i));
        }
        const sel_idx = try addLiteral(ctx, sel);
        if (sel_idx > 0xffff) return error.OperandOverflow;
        try emitRaw(ctx, bc.encodeSend(@intCast(arity), @intCast(sel_idx)));
        return;
    }

    if (cls == g.ret_node_class) {
        const inner = object.slot(node, object.SLOT_RET_INNER);
        try compileExpr(ctx, inner);
        return emit(ctx, .return_top, 0);
    }

    if (cls == g.seq_node_class) {
        const stmts = object.slot(node, object.SLOT_SEQ_BODY);
        if (!oop_mod.isHeapPtr(stmts)) return emit(ctx, .push_nil, 0);
        const n = object.headerOf(stmts).size;
        if (n == 0) return emit(ctx, .push_nil, 0);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try compileExpr(ctx, object.slot(stmts, i));
            if (i + 1 < n) try emit(ctx, .pop, 0);
        }
        return;
    }

    if (cls == g.block_node_class) {
        // Recursively compile the block body to a separate bytecode +
        // literal pair. Wrap the result in a 4-slot template Array
        // [params, temps, bytecode, literals] and store it as a
        // literal in the parent's pool. PUSH_BLOCK_AST emits an
        // instruction that materializes a BlockClosure from this
        // template at run time.
        const params = object.slot(node, object.SLOT_BLOCKNODE_PARAMS);
        const temps = object.slot(node, object.SLOT_BLOCKNODE_TEMPS);
        const body = object.slot(node, object.SLOT_BLOCKNODE_BODY);

        var sub = Ctx{
            .heap = ctx.heap,
            .g = g,
            .params = params,
            .temps = temps,
            .is_block_scope = true,
            .instrs = undefined,
            .n_instrs = 0,
            .literals = undefined,
            .n_literals = 0,
        };
        @memset(&sub.literals, oop_mod.NIL);

        // The block body is an Array of statements. Emit them in
        // sequence; the last one is the value of the block.
        if (oop_mod.isHeapPtr(body)) {
            const n = object.headerOf(body).size;
            if (n == 0) {
                try emit(&sub, .push_nil, 0);
            } else {
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try compileExpr(&sub, object.slot(body, i));
                    if (i + 1 < n) try emit(&sub, .pop, 0);
                }
            }
        } else {
            try emit(&sub, .push_nil, 0);
        }
        try emit(&sub, .return_top, 0);

        // Allocate the sub-bytecode and sub-literals.
        const sub_bytes_n: u32 = @intCast(sub.n_instrs * @sizeOf(bc.Instr));
        const sub_code = ctx.heap.allocBytes(g.byte_array_class, sub_bytes_n) catch return error.OutOfMemory;
        const sub_code_bytes = object.bytesOf(sub_code);
        var k: u32 = 0;
        while (k < sub.n_instrs) : (k += 1) {
            std.mem.writeInt(u32, sub_code_bytes[k * 4 ..][0..4], sub.instrs[k], .little);
        }
        const sub_lits = ctx.heap.allocSlots(g.array_class, sub.n_literals) catch return error.OutOfMemory;
        var m: u32 = 0;
        while (m < sub.n_literals) : (m += 1) object.setSlot(sub_lits, m, sub.literals[m]);

        const tmpl = ctx.heap.allocSlots(g.array_class, 4) catch return error.OutOfMemory;
        object.setSlot(tmpl, 0, params);
        object.setSlot(tmpl, 1, temps);
        object.setSlot(tmpl, 2, sub_code);
        object.setSlot(tmpl, 3, sub_lits);

        const idx = try addLiteral(ctx, tmpl);
        return emit(ctx, .push_block_ast, idx);
    }

    // SuperSendNode and anything else → fall back to AST.
    return error.Unsupported;
}

// Inline a BlockNode body directly into the surrounding bytecode
// stream (no BlockClosure allocation, no separate frame). Only safe
// when the block has zero params and zero temps — those would need
// fresh frame slots in the parent. Returns false if the block is
// unfit; the caller emits a generic push_block_ast in that case.
fn isInlinableBlock(g: *const Globals, node: Oop) bool {
    if (!oop_mod.isHeapPtr(node)) return false;
    if (object.headerOf(node).class != g.block_node_class) return false;
    const params = object.slot(node, object.SLOT_BLOCKNODE_PARAMS);
    const temps = object.slot(node, object.SLOT_BLOCKNODE_TEMPS);
    const np = if (oop_mod.isHeapPtr(params)) object.headerOf(params).size else 0;
    const nt = if (oop_mod.isHeapPtr(temps)) object.headerOf(temps).size else 0;
    return np == 0 and nt == 0;
}

fn compileInlineBlock(ctx: *Ctx, block_node: Oop) CompileError!void {
    const body = object.slot(block_node, object.SLOT_BLOCKNODE_BODY);
    if (!oop_mod.isHeapPtr(body)) {
        try emit(ctx, .push_nil, 0);
        return;
    }
    const n = object.headerOf(body).size;
    if (n == 0) {
        try emit(ctx, .push_nil, 0);
        return;
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try compileExpr(ctx, object.slot(body, i));
        if (i + 1 < n) try emit(ctx, .pop, 0);
    }
}

// Patch a previously-emitted jump at instruction index `jump_idx`
// to land at `target_idx`. The signed 24-bit operand is the
// displacement from the instruction *after* the jump (since pc was
// already advanced when the jump executes).
fn patchJump(ctx: *Ctx, jump_idx: u32, target_idx: u32) CompileError!void {
    const after = jump_idx + 1;
    const off: i64 = @as(i64, target_idx) - @as(i64, after);
    if (off < -0x80_0000 or off > 0x7F_FFFF) return error.OperandOverflow;
    const op = @as(bc.Op, @enumFromInt(@as(u8, @truncate(ctx.instrs[jump_idx] & 0xff))));
    const operand_u: u32 = @bitCast(@as(i32, @intCast(off & 0xFF_FFFF)));
    ctx.instrs[jump_idx] = bc.encode(op, operand_u);
}

// Returns true if the send was specialised; false to fall through to
// the generic SEND opcode.
fn tryInlineControlFlow(ctx: *Ctx, sel: Oop, recv_node: Oop, args_arr: Oop, arity: u32) CompileError!bool {
    const g = ctx.g;
    const sym_ifTrue = dict.newSymbol(ctx.heap, g, "ifTrue:") catch return error.OutOfMemory;
    const sym_ifFalse = dict.newSymbol(ctx.heap, g, "ifFalse:") catch return error.OutOfMemory;
    const sym_ifTrueIfFalse = dict.newSymbol(ctx.heap, g, "ifTrue:ifFalse:") catch return error.OutOfMemory;
    const sym_ifFalseIfTrue = dict.newSymbol(ctx.heap, g, "ifFalse:ifTrue:") catch return error.OutOfMemory;
    const sym_whileTrue = dict.newSymbol(ctx.heap, g, "whileTrue:") catch return error.OutOfMemory;
    const sym_whileFalse = dict.newSymbol(ctx.heap, g, "whileFalse:") catch return error.OutOfMemory;

    if ((sel == sym_ifTrue or sel == sym_ifFalse) and arity == 1) {
        const arg = object.slot(args_arr, 0);
        if (!isInlinableBlock(g, arg)) return false;
        // <recv>
        // JUMP_IF_FALSE skip   (or JUMP_IF_TRUE for ifFalse:)
        // <inline arg body>
        // JUMP done
        // skip:
        // PUSH_NIL
        // done:
        try compileExpr(ctx, recv_node);
        const jump_skip_idx = ctx.n_instrs;
        const skip_op: bc.Op = if (sel == sym_ifTrue) .jump_if_false else .jump_if_true;
        try emit(ctx, skip_op, 0); // patched
        try compileInlineBlock(ctx, arg);
        const jump_done_idx = ctx.n_instrs;
        try emit(ctx, .jump, 0); // patched
        const skip_target = ctx.n_instrs;
        try emit(ctx, .push_nil, 0);
        const done_target = ctx.n_instrs;
        try patchJump(ctx, jump_skip_idx, skip_target);
        try patchJump(ctx, jump_done_idx, done_target);
        return true;
    }

    if ((sel == sym_ifTrueIfFalse or sel == sym_ifFalseIfTrue) and arity == 2) {
        const arg0 = object.slot(args_arr, 0);
        const arg1 = object.slot(args_arr, 1);
        if (!isInlinableBlock(g, arg0) or !isInlinableBlock(g, arg1)) return false;
        // For ifTrue:ifFalse:, true→arg0, false→arg1.
        // For ifFalse:ifTrue:, true→arg1, false→arg0.
        const true_branch = if (sel == sym_ifTrueIfFalse) arg0 else arg1;
        const false_branch = if (sel == sym_ifTrueIfFalse) arg1 else arg0;
        // <recv>
        // JUMP_IF_FALSE else
        // <true_branch body>
        // JUMP done
        // else: <false_branch body>
        // done:
        try compileExpr(ctx, recv_node);
        const jump_else_idx = ctx.n_instrs;
        try emit(ctx, .jump_if_false, 0);
        try compileInlineBlock(ctx, true_branch);
        const jump_done_idx = ctx.n_instrs;
        try emit(ctx, .jump, 0);
        const else_target = ctx.n_instrs;
        try compileInlineBlock(ctx, false_branch);
        const done_target = ctx.n_instrs;
        try patchJump(ctx, jump_else_idx, else_target);
        try patchJump(ctx, jump_done_idx, done_target);
        return true;
    }

    if ((sel == sym_whileTrue or sel == sym_whileFalse) and arity == 1) {
        const cond_block = recv_node;
        const body_block = object.slot(args_arr, 0);
        if (!isInlinableBlock(g, cond_block)) return false;
        if (!isInlinableBlock(g, body_block)) return false;
        // loop:
        //   <cond body>
        //   JUMP_IF_FALSE end   (or JUMP_IF_TRUE for whileFalse:)
        //   <body body>
        //   POP                  (drop body's value — whileTrue: returns nil)
        //   JUMP loop
        // end:
        //   PUSH_NIL
        const loop_target = ctx.n_instrs;
        try compileInlineBlock(ctx, cond_block);
        const jump_end_idx = ctx.n_instrs;
        const end_op: bc.Op = if (sel == sym_whileTrue) .jump_if_false else .jump_if_true;
        try emit(ctx, end_op, 0);
        try compileInlineBlock(ctx, body_block);
        try emit(ctx, .pop, 0);
        const jump_loop_idx = ctx.n_instrs;
        try emit(ctx, .jump, 0);
        const end_target = ctx.n_instrs;
        try emit(ctx, .push_nil, 0);
        try patchJump(ctx, jump_end_idx, end_target);
        try patchJump(ctx, jump_loop_idx, loop_target);
        return true;
    }

    return false;
}
