// Stack-based bytecode for hilang. Each instruction is a u32: 8-bit
// opcode in the low byte, 24-bit operand in the high three bytes.
// Bytecode is stored as a heap ByteArray (FLAG_BYTES); GC ignores
// the contents because they're integers, not Oops. Literals (Oops
// referenced by PUSH_LIT) live in a sibling Array on the method.
//
// Frame layout from the AST interpreter is reused unchanged:
//   names[0]  = #self,   values[0]  = receiver
//   names[1..]= params/temps, values[1..] = bound values
// PUSH_LOCAL/STORE_LOCAL index directly into that frame.

const std = @import("std");

pub const Op = enum(u8) {
    // 0x00–0x0F: stack manipulation and locals.
    push_lit = 0x00,
    push_self = 0x01,
    push_local = 0x02,
    store_local = 0x03,
    pop = 0x04,
    push_nil = 0x05,
    push_true = 0x06,
    push_false = 0x07,
    // PUSH_GLOBAL: operand is a literal index pointing at the symbol
    // for the global's name. Resolved at runtime via vm.lookupGlobal.
    // Lets methods that reference top-level names like `Point`
    // compile to bytecode (and hence JIT-tier-up) instead of bailing
    // back to the AST evaluator.
    push_global = 0x08,

    // 0x10–0x1F: sends. SEND operand encodes (arity << 16) | sel_idx.
    send = 0x10,
    super_send = 0x11,

    // 0x20–0x2F: returns and jumps. JUMP operand is signed 24-bit
    // displacement from the instruction *after* the jump.
    return_top = 0x20,
    jump = 0x21,
    jump_if_false = 0x22,
    jump_if_true = 0x23,

    // 0x30+: blocks. PUSH_BLOCK_AST creates a closure pointing at an
    // AST BlockNode literal (blocks haven't been compiled yet in v2).
    push_block_ast = 0x30,
};

pub const Instr = u32;

pub inline fn encode(op: Op, operand: u32) Instr {
    std.debug.assert(operand <= 0x00FF_FFFF);
    return (@as(u32, operand) << 8) | @intFromEnum(op);
}

pub inline fn encodeSend(arity: u8, sel_idx: u16) Instr {
    return encode(.send, (@as(u32, arity) << 16) | sel_idx);
}

pub inline fn opOf(i: Instr) Op {
    return @enumFromInt(@as(u8, @truncate(i & 0xff)));
}

pub inline fn operandOf(i: Instr) u32 {
    return i >> 8;
}

pub inline fn signedOperandOf(i: Instr) i32 {
    // Sign-extend the 24-bit operand.
    const u: u32 = i >> 8;
    if ((u & 0x0080_0000) != 0) return @bitCast(u | 0xFF00_0000);
    return @bitCast(u);
}

pub inline fn sendArityOf(i: Instr) u8 {
    return @truncate((operandOf(i) >> 16) & 0xff);
}

pub inline fn sendSelOf(i: Instr) u16 {
    return @truncate(operandOf(i) & 0xffff);
}
