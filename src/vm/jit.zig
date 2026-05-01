// ARM64 JIT codegen for hilang. macOS Apple Silicon only for now.
//
// macOS enforces W^X on JIT pages: a page can be writable XOR executable
// at any moment, toggled per-thread via pthread_jit_write_protect_np.
// We allocate pages with MAP_JIT (0x800), then alternate between RW and
// RX while emitting code. After writes we call sys_icache_invalidate so
// the CPU's instruction cache picks up the new bytes.
//
// Phase J.1 covers: page allocation, W^X dance, a tiny instruction
// encoder (movz / movk / ret), and a smoke test that JIT-builds a
// function returning 42 and calls it.

const std = @import("std");
const builtin = @import("builtin");
const object = @import("object.zig");
const oop_mod = @import("oop.zig");
const bc = @import("bytecode.zig");
const Oop = oop_mod.Oop;

// Bare-libc declarations for the small set of POSIX calls we
// touch directly. We bypass std.posix here because:
//  - macOS needs MAP_JIT (0x800) which std.posix doesn't expose,
//  - pthread_jit_write_protect_np / sys_icache_invalidate are
//    darwin-only and not part of std.
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn mprotect(addr: *anyopaque, len: usize, prot: c_int) c_int;

// Darwin-only JIT helpers. Stubbed out as no-ops on Linux (no
// W^X enforcement at this layer; AArch64 i-cache flush is
// inlined as `dc cvau` + `ic ivau` + `dsb ish` + `isb` in
// markExecutable on Linux).
extern "c" fn pthread_jit_write_protect_np(executable: c_int) void;
extern "c" fn pthread_jit_write_protect_supported_np() c_int;
extern "c" fn sys_icache_invalidate(start: ?*const anyopaque, len: usize) void;
comptime {
    if (builtin.os.tag == .linux) {
        // Provide weak stubs so the macOS-only externs link
        // cleanly on ELF. Each is a no-op; the real cache flush
        // is the inline asm in markExecutable.
        asm (
            \\ .weak pthread_jit_write_protect_np
            \\ .weak pthread_jit_write_protect_supported_np
            \\ .weak sys_icache_invalidate
            \\ pthread_jit_write_protect_np:
            \\     ret
            \\ pthread_jit_write_protect_supported_np:
            \\     mov w0, #0
            \\     ret
            \\ sys_icache_invalidate:
            \\     ret
        );
    }
}

const PROT_READ: c_int = 0x01;
const PROT_WRITE: c_int = 0x02;
const PROT_EXEC: c_int = 0x04;

const MAP_PRIVATE: c_int = 0x0002;
// MAP_ANON differs by OS: 0x1000 on darwin, 0x20 on Linux.
const MAP_ANON: c_int = if (builtin.os.tag == .linux) 0x20 else 0x1000;
const MAP_JIT: c_int = if (builtin.os.tag == .linux) 0 else 0x0800;

const MAP_FAILED: usize = std.math.maxInt(usize); // (void*)-1

pub const JitError = error{
    AllocFailed,
    NotImplementedOnPlatform,
};

// A live JIT code page. Owns the mmap mapping for its lifetime; the
// `bytes` slice is the writable / executable buffer (toggled via
// markWritable / markExecutable). `pos` is the next byte the encoder
// will write to.
pub const JitBuf = struct {
    bytes: []u8,
    pos: usize,
    capacity: usize,

    pub fn deinit(self: *JitBuf) void {
        _ = munmap(@ptrCast(self.bytes.ptr), self.capacity);
        self.* = undefined;
    }

    // Reserve `capacity` bytes of executable memory. macOS requires
    // PROT_READ|PROT_WRITE|PROT_EXEC at mmap time on Apple Silicon
    // when MAP_JIT is set; pthread_jit_write_protect_np then gates
    // write vs execute per thread.
    pub fn alloc(capacity: usize) !JitBuf {
        switch (builtin.os.tag) {
            .macos, .linux => {},
            else => return error.NotImplementedOnPlatform,
        }
        const page = std.heap.page_size_min;
        const rounded = std.mem.alignForward(usize, capacity, page);
        const addr = mmap(
            null,
            rounded,
            PROT_READ | PROT_WRITE | PROT_EXEC,
            MAP_PRIVATE | MAP_ANON | MAP_JIT,
            -1,
            0,
        );
        if (addr == null or @intFromPtr(addr.?) == MAP_FAILED) return error.AllocFailed;
        const ptr: [*]u8 = @ptrCast(@alignCast(addr.?));
        return .{
            .bytes = ptr[0..rounded],
            .pos = 0,
            .capacity = rounded,
        };
    }

    // Switch the calling thread's view of MAP_JIT pages to writable.
    // Must be paired with markExecutable before the code is run.
    pub fn markWritable(_: *JitBuf) void {
        if (pthread_jit_write_protect_supported_np() != 0) {
            pthread_jit_write_protect_np(0);
        }
    }

    // Flip back to executable and flush the i-cache so the CPU sees
    // the freshly-written instructions.
    pub fn markExecutable(self: *JitBuf) void {
        switch (builtin.os.tag) {
            .macos, .ios, .watchos, .tvos => {
                if (pthread_jit_write_protect_supported_np() != 0) {
                    pthread_jit_write_protect_np(1);
                }
                sys_icache_invalidate(@ptrCast(self.bytes.ptr), self.pos);
            },
            .linux => {
                // AArch64 i-cache flush: walk the byte range and
                // emit `dc cvau` / `ic ivau` per cache line, then
                // a barrier pair. CTR_EL0 reports the line size;
                // for simplicity we use 64 bytes which is
                // standard on all current AArch64 cores.
                const start: usize = @intFromPtr(self.bytes.ptr);
                const end: usize = start + self.pos;
                var p: usize = start & ~@as(usize, 63);
                while (p < end) : (p += 64) {
                    asm volatile ("dc cvau, %[p]"
                        :
                        : [p] "r" (p),
                        : .{ .memory = true });
                }
                asm volatile ("dsb ish" ::: .{ .memory = true });
                p = start & ~@as(usize, 63);
                while (p < end) : (p += 64) {
                    asm volatile ("ic ivau, %[p]"
                        :
                        : [p] "r" (p),
                        : .{ .memory = true });
                }
                asm volatile ("dsb ish" ::: .{ .memory = true });
                asm volatile ("isb" ::: .{ .memory = true });
            },
            else => {},
        }
    }

    // Append one ARM64 instruction (4 bytes, little-endian).
    pub fn emit(self: *JitBuf, instr: u32) void {
        std.debug.assert(self.pos + 4 <= self.capacity);
        std.mem.writeInt(u32, self.bytes[self.pos..][0..4], instr, .little);
        self.pos += 4;
    }

    // Pointer to the start of emitted code. Caller is responsible for
    // calling markExecutable before invoking.
    pub fn entry(self: *const JitBuf) [*]const u8 {
        return self.bytes.ptr;
    }
};

// ---- ARM64 instruction encoders ----
//
// Only the encodings J.1 needs. Future phases will grow this.

// MOVZ Xd, #imm16, LSL #shift  (shift in {0,16,32,48})
//   bits: 1 sf=1 1 10 0101 hw imm16 Rd
//   sf=1 → 64-bit; opc=10 (MOVZ); top byte = 0xD2.
pub fn movz(rd: u5, imm16: u16, shift_lsl: u8) u32 {
    std.debug.assert(shift_lsl == 0 or shift_lsl == 16 or shift_lsl == 32 or shift_lsl == 48);
    const hw: u32 = @intCast(shift_lsl / 16);
    return 0xD2800000 | (hw << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
}

// MOVK Xd, #imm16, LSL #shift  (keeps other bits)
pub fn movk(rd: u5, imm16: u16, shift_lsl: u8) u32 {
    std.debug.assert(shift_lsl == 0 or shift_lsl == 16 or shift_lsl == 32 or shift_lsl == 48);
    const hw: u32 = @intCast(shift_lsl / 16);
    return 0xF2800000 | (hw << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
}

// RET — return to address in x30 (LR).
pub fn ret() u32 {
    return 0xD65F03C0;
}

// MOV Xd, Xm  (alias of ORR Xd, XZR, Xm).
//   bits 31-21: 1010_1010_000  (0xAA0)
//   bits 20-16: rm
//   bits 15-10: shift = 0
//   bits  9-5 : rn = 31 (XZR)
//   bits  4-0 : rd
pub fn movReg(rd: u5, rm: u5) u32 {
    return 0xAA000000 | (@as(u32, rm) << 16) | (31 << 5) | @as(u32, rd);
}

// LDR Xt, [Xn, #imm]   immediate, unsigned-offset, 64-bit.
//   imm12 is the byte offset / 8 (range 0..32760).
pub fn ldrImm(rt: u5, rn: u5, byte_offset: u32) u32 {
    std.debug.assert(byte_offset % 8 == 0);
    const imm12: u32 = byte_offset / 8;
    std.debug.assert(imm12 <= 0xFFF);
    return 0xF9400000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

// STR Xt, [Xn, #imm]   immediate, unsigned-offset, 64-bit.
pub fn strImm(rt: u5, rn: u5, byte_offset: u32) u32 {
    std.debug.assert(byte_offset % 8 == 0);
    const imm12: u32 = byte_offset / 8;
    std.debug.assert(imm12 <= 0xFFF);
    return 0xF9000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

// STP Xt, Xt2, [Xn, #imm]!  pre-indexed, 64-bit, store.
pub fn stpPre(rt: u5, rt2: u5, rn: u5, byte_imm: i32) u32 {
    std.debug.assert(@mod(byte_imm, 8) == 0);
    const imm7: u32 = @as(u32, @bitCast(@divExact(byte_imm, 8))) & 0x7F;
    return 0xA9800000 | (imm7 << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

// LDP Xt, Xt2, [Xn], #imm   post-indexed, 64-bit, load.
pub fn ldpPost(rt: u5, rt2: u5, rn: u5, byte_imm: i32) u32 {
    std.debug.assert(@mod(byte_imm, 8) == 0);
    const imm7: u32 = @as(u32, @bitCast(@divExact(byte_imm, 8))) & 0x7F;
    return 0xA8C00000 | (imm7 << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

// SUB SP, SP, #imm12   (positive byte offset, 0..4095).
pub fn subSpImm(byte_imm: u32) u32 {
    std.debug.assert(byte_imm <= 0xFFF);
    return 0xD10003FF | (byte_imm << 10);
}

// ADD SP, SP, #imm12
pub fn addSpImm(byte_imm: u32) u32 {
    std.debug.assert(byte_imm <= 0xFFF);
    return 0x910003FF | (byte_imm << 10);
}

// ADD Xd, SP, #imm12
pub fn addSpToReg(rd: u5, byte_imm: u32) u32 {
    std.debug.assert(byte_imm <= 0xFFF);
    return 0x91000000 | (byte_imm << 10) | (31 << 5) | @as(u32, rd);
}

// BLR Xn  — branch with link via register (absolute call).
// BR Xn — branch to register, no link. Used by tail-call sites that
// need to jump to an arbitrary address held in a register (e.g. the
// alloc stub's slow-path tail-jump to vm_jit_alloc_slow).
pub fn br(rn: u5) u32 {
    return 0xD61F0000 | (@as(u32, rn) << 5);
}

pub fn blr(rn: u5) u32 {
    return 0xD63F0000 | (@as(u32, rn) << 5);
}

// ---- arithmetic / logic, register form (64-bit, no shift) ----

pub fn addsReg(rd: u5, rn: u5, rm: u5) u32 {
    return 0xAB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn subsReg(rd: u5, rn: u5, rm: u5) u32 {
    return 0xEB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn cmpReg(rn: u5, rm: u5) u32 {
    // CMP = SUBS XZR, Rn, Rm
    return 0xEB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | 31;
}

pub fn andReg(rd: u5, rn: u5, rm: u5) u32 {
    return 0x8A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn subImm(rd: u5, rn: u5, imm12: u32) u32 {
    std.debug.assert(imm12 <= 0xFFF);
    return 0xD1000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// CMP Xn, #imm12   alias of SUBS XZR, Xn, #imm12.
pub fn cmpImm(rn: u5, imm12: u32) u32 {
    std.debug.assert(imm12 <= 0xFFF);
    return 0xF100001F | (imm12 << 10) | (@as(u32, rn) << 5);
}

// MUL Xd, Xn, Xm   alias of MADD Xd, Xn, Xm, XZR.
pub fn mulReg(rd: u5, rn: u5, rm: u5) u32 {
    return 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// SMULH Xd, Xn, Xm   signed multiply, upper 64 bits.
pub fn smulhReg(rd: u5, rn: u5, rm: u5) u32 {
    return 0x9B407C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// CMP Xn, Xm, ASR #imm6   alias of SUBS XZR, Xn, Xm, ASR #imm6.
pub fn cmpRegAsr(rn: u5, rm: u5, shift: u6) u32 {
    std.debug.assert(shift < 64);
    return 0xEB80001F | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5);
}

pub fn addImm(rd: u5, rn: u5, imm12: u32) u32 {
    std.debug.assert(imm12 <= 0xFFF);
    return 0x91000000 | (imm12 << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// LSL Xd, Xn, #shift  (1 ≤ shift ≤ 63) — alias of UBFM.
pub fn lslImm(rd: u5, rn: u5, shift: u6) u32 {
    std.debug.assert(shift > 0 and shift < 64);
    const immr: u32 = (64 - @as(u32, shift)) & 0x3F;
    const imms: u32 = 63 - @as(u32, shift);
    return 0xD3400000 | (immr << 16) | (imms << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ASR Xd, Xn, #shift — alias of SBFM.
pub fn asrImm(rd: u5, rn: u5, shift: u6) u32 {
    std.debug.assert(shift > 0 and shift < 64);
    return 0x93400000 | (@as(u32, shift) << 16) | (63 << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// CSET Xd, cond  — set Xd to 1 if cond is true, else 0.
// Alias of CSINC Xd, XZR, XZR, invert(cond).
pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    vs = 6,
    hi = 8,
    ls = 9,
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,
};

pub fn cset(rd: u5, cond: Cond) u32 {
    // CSET Xd, cond  = CSINC Xd, XZR, XZR, invert(cond).
    // CSINC encoding: 1 00 11010100 Rm cond 01 Rn Rd, with Rm=Rn=31.
    // Base bits (with Rm=Rn=31, op2=01):
    //   0x9A800400 | (31<<16) | (31<<5) = 0x9A9F07E0.
    // Earlier encoding was 0x9A9F03E0 (op2=00 — that's CSEL, which
    // always returned XZR=0). Add the 0x400 for the CSINC op2.
    const inv: u32 = @intFromEnum(cond) ^ 1;
    return 0x9A9F07E0 | (inv << 12) | @as(u32, rd);
}

// ---- branches ----

// B <imm>  — unconditional, signed 26-bit (×4 byte) offset relative to
// the address of the instruction. The caller passes a byte offset.
pub fn bUncond(byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x03FFFFFF;
    return 0x14000000 | bits;
}

// BL <imm>  — link-register branch, same imm26 layout as B with the
// link bit (bit 31) set. Used by v4.B's direct-call IC.
pub fn bl(byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x03FFFFFF;
    return 0x94000000 | bits;
}

// B.cond <imm>  — conditional, signed 19-bit (×4 byte) offset.
pub fn bCond(cond: Cond, byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x7FFFF;
    return 0x54000000 | (bits << 5) | @intFromEnum(cond);
}

// TBZ Xt, #bit, <imm>  — test bit and branch if zero. signed 14-bit
// (×4) offset; bit position 0..63.
pub fn tbz(rt: u5, bit: u6, byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x3FFF;
    const b5: u32 = (@as(u32, bit) >> 5) & 1;
    const b40: u32 = @as(u32, bit) & 0x1F;
    return 0x36000000 | (b5 << 31) | (b40 << 19) | (bits << 5) | @as(u32, rt);
}

// CBNZ Xt, <imm>  — compare and branch if non-zero. signed 19-bit (×4) offset.
pub fn cbnz(rt: u5, byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x7FFFF;
    return 0xB5000000 | (bits << 5) | @as(u32, rt);
}

// CBZ Xt, <imm>  — compare and branch if zero. signed 19-bit (×4) offset.
pub fn cbz(rt: u5, byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x7FFFF;
    return 0xB4000000 | (bits << 5) | @as(u32, rt);
}

// ADR Xd, <imm21>  — load PC-relative address. signed 21-bit byte
// offset (NOT scaled). Range ±1 MiB.
pub fn adr(rd: u5, byte_offset: i32) u32 {
    const off: u32 = @as(u32, @bitCast(byte_offset)) & 0x1FFFFF;
    const immlo = off & 0x3;
    const immhi = (off >> 2) & 0x7FFFF;
    return 0x10000000 | (immlo << 29) | (immhi << 5) | @as(u32, rd);
}

// TBNZ Xt, #bit, <imm>  — test bit and branch if non-zero. Same
// encoding shape as TBZ but bit 24 set (0x37000000 base).
pub fn tbnz(rt: u5, bit: u6, byte_offset: i32) u32 {
    std.debug.assert(@mod(byte_offset, 4) == 0);
    const word_off: i32 = @divExact(byte_offset, 4);
    const bits: u32 = @as(u32, @bitCast(word_off)) & 0x3FFF;
    const b5: u32 = (@as(u32, bit) >> 5) & 1;
    const b40: u32 = @as(u32, bit) & 0x1F;
    return 0x37000000 | (b5 << 31) | (b40 << 19) | (bits << 5) | @as(u32, rt);
}

// ---- patching ----
//
// Forward branches are emitted with a placeholder offset of 0
// (jumping to themselves). Once we know the target, we rewrite the
// 14-/19-/26-bit immediate field in place.

pub fn patchBranch14(buf: *JitBuf, instr_off: u32, target_off: u32) void {
    const word_off: i32 = (@as(i32, @intCast(target_off)) - @as(i32, @intCast(instr_off))) >> 2;
    var instr = std.mem.readInt(u32, buf.bytes[instr_off..][0..4], .little);
    instr = (instr & ~(@as(u32, 0x3FFF) << 5)) | ((@as(u32, @bitCast(word_off)) & 0x3FFF) << 5);
    std.mem.writeInt(u32, buf.bytes[instr_off..][0..4], instr, .little);
}

pub fn patchBranch19(buf: *JitBuf, instr_off: u32, target_off: u32) void {
    const word_off: i32 = (@as(i32, @intCast(target_off)) - @as(i32, @intCast(instr_off))) >> 2;
    var instr = std.mem.readInt(u32, buf.bytes[instr_off..][0..4], .little);
    instr = (instr & ~(@as(u32, 0x7FFFF) << 5)) | ((@as(u32, @bitCast(word_off)) & 0x7FFFF) << 5);
    std.mem.writeInt(u32, buf.bytes[instr_off..][0..4], instr, .little);
}

pub fn patchBranch26(buf: *JitBuf, instr_off: u32, target_off: u32) void {
    const word_off: i32 = (@as(i32, @intCast(target_off)) - @as(i32, @intCast(instr_off))) >> 2;
    var instr = std.mem.readInt(u32, buf.bytes[instr_off..][0..4], .little);
    instr = (instr & ~@as(u32, 0x03FFFFFF)) | (@as(u32, @bitCast(word_off)) & 0x03FFFFFF);
    std.mem.writeInt(u32, buf.bytes[instr_off..][0..4], instr, .little);
}

// Load a 64-bit immediate into Xd using up to four MOVZ/MOVK. Skips
// 16-bit chunks that are zero (after the first MOVZ).
pub fn movImm64(buf: *JitBuf, rd: u5, imm: u64) void {
    var emitted: bool = false;
    var shift: u8 = 0;
    while (shift < 64) : (shift += 16) {
        const chunk: u16 = @truncate((imm >> @intCast(shift)) & 0xffff);
        if (chunk == 0 and emitted) continue;
        if (!emitted) {
            buf.emit(movz(rd, chunk, shift));
            emitted = true;
        } else {
            buf.emit(movk(rd, chunk, shift));
        }
    }
    if (!emitted) buf.emit(movz(rd, 0, 0)); // imm == 0
}

// Native method ABI. Called from invokeMethod with the same logical
// arguments the bytecode invokeBytecodeMethod sees:
//   x0 = vm pointer        (Vm-internal callouts; trivial methods ignore)
//   x1 = receiver Oop      (PUSH_SELF / `^self` returns this directly)
//   x2 = args base pointer (Oops; null when arity = 0)
//   x3 = arity (u32 in low half of x3 — currently unused by trivial fns)
// Return Oop in x0.

// JIT entrypoint. Tries the trivial fast path (no frame, no stack)
// first; on miss, attempts the with-frame compile that handles
// PUSH_LIT/PUSH_SELF/PUSH_LOCAL/STORE_LOCAL/POP/RETURN_TOP. Returns
// the byte offset of the entry point on success or null if neither
// path can handle the method's bytecode shape.
//
// CompileResult.depth is the eval-stack depth the with-frame fn
// needs; the runtime stuffs it into SLOT_METHOD_HOT_COUNT so the
// vm_jit_method_enter helper can size the frame correctly.
pub const CompileResult = struct {
    offset: u32,
    max_depth: u32,
};

pub fn compileMethod(vm_ptr: *anyopaque, method: Oop, buf: *JitBuf) ?CompileResult {
    if (compileTrivial(method, buf)) |off| return .{ .offset = off, .max_depth = 0 };
    return compileWithFrame(vm_ptr, method, buf);
}

// Try to JIT a method whose bytecode body is one of the trivial
// patterns we recognise. On success, append code to `buf`, mark it
// executable, and return the byte offset of the entry point. On
// unsupported shape return null — the caller leaves the method as
// kind=BYTECODE and arranges not to retry.
pub fn compileTrivial(method: Oop, buf: *JitBuf) ?u32 {
    const code_oop = object.slot(method, object.SLOT_METHOD_BYTECODE);
    if (!oop_mod.isHeapPtr(code_oop)) return null;
    const code_hdr = object.headerOf(code_oop);
    if (code_hdr.size != 8) return null; // exactly 2 instructions
    const code_bytes = object.bytesOf(code_oop)[0..code_hdr.size];
    const ins0: u32 = std.mem.readInt(u32, code_bytes[0..4], .little);
    const ins1: u32 = std.mem.readInt(u32, code_bytes[4..8], .little);
    if (bc.opOf(ins1) != .return_top) return null;

    const offset: u32 = @intCast(buf.pos);
    buf.markWritable();
    switch (bc.opOf(ins0)) {
        .push_self => {
            // ABI: x0=vm, x1=method, x2=receiver, x3=args, x4=arity.
            // Return receiver: mov x0, x2; ret
            buf.emit(movReg(0, 2));
            buf.emit(ret());
        },
        .push_nil => {
            buf.emit(movz(0, oop_mod.NIL, 0));
            buf.emit(ret());
        },
        .push_true => {
            buf.emit(movz(0, oop_mod.TRUE, 0));
            buf.emit(ret());
        },
        .push_false => {
            buf.emit(movz(0, oop_mod.FALSE, 0));
            buf.emit(ret());
        },
        .push_lit => {
            const lits = object.slot(method, object.SLOT_METHOD_LITERALS);
            if (!oop_mod.isHeapPtr(lits)) {
                buf.markExecutable();
                return null;
            }
            const idx = bc.operandOf(ins0);
            const lit_val = object.slot(lits, idx);
            // Tagged ints / floats / bool / nil have stable bit
            // patterns regardless of heap layout, so embedding them
            // as immediates is safe across GC. Heap-pointer literals
            // (Strings, Symbols, etc.) move; for those we load
            // through method.literals at runtime.
            const stable = oop_mod.isInt(lit_val) or oop_mod.isFloat(lit_val) or
                oop_mod.isNil(lit_val) or oop_mod.isBool(lit_val);
            if (stable) {
                movImm64(buf, 0, lit_val);
                buf.emit(ret());
            } else {
                // ldr x0, [x1, #LITERALS_OFFSET]   ; method.literals
                // ldr x0, [x0, #(2+idx)*8]         ; literals[idx]
                // ret
                buf.emit(ldrImm(0, 1, slotByteOffset(object.SLOT_METHOD_LITERALS)));
                buf.emit(ldrImm(0, 0, slotByteOffset(idx)));
                buf.emit(ret());
            }
        },
        else => {
            buf.markExecutable();
            return null;
        },
    }
    buf.markExecutable();
    return offset;
}

// Register conventions inside JIT'd with-frame methods:
//   x19 = vm pointer            (callee-saved, set in prologue)
//   x20 = frame pointer         (callee-saved, set after enter helper)
//   x21 = result holder         (callee-saved, used by RETURN_TOP)
//   x9  = scratch
// Stack layout (sp grows downward):
//   [pin storage  : 64 bytes ]   <- top, sp + 0
//   [x21, x22 save: 16 bytes]
//   [x19, x20 save: 16 bytes]
//   [fp, lr save  : 16 bytes]
const PIN_STORAGE_BYTES: u32 = 64;

// Eval-stack absolute byte offset from the frame's address (header
// sits at frame, so first slot is at offset 16).
inline fn slotByteOffset(slot_idx: u32) u32 {
    return 16 + slot_idx * 8;
}

// v4.D — method inlining at IC sites. Recognise common bytecode
// shapes and emit a tiny ARM64 stub that performs the leaf path
// in-line at the call site, falling back to the full method only
// when the early-exit predicate doesn't fire. Currently we
// recognise the shape:
//
//   ^self <op> <smallint-literal>
//     ifTrue:  [self]
//     ifFalse: [<arbitrary recursive case>]
//
// After the front-end's ifTrue:ifFalse: inlining, that's the
// bytecode sequence:
//
//   0  push_self
//   1  push_lit  <smallint>
//   2  send      <comparator>           (arity 1)
//   3  jump_if_false  to else_branch
//   4  push_self
//   5  jump      to end
//   6+ <else branch — anything>
//   N  return_top
//
// fib and factorial both compile to exactly this. The stub turns
// the leaf path into a 4-instruction `cmp; b.cond; mov x0,x2; ret`
// and falls back to the full method's prologue only when the
// comparator is false.
//
// The stub uses the caller's "args in regs" ABI directly: vm in x0,
// method in x1, recv in x2, a0..a3 in x3..x6. The leaf path runs
// in 4 instructions (cmp + b.cond + mov x0, x2 + ret), 5× shorter
// than the equivalent full prologue+leaf-body+epilogue.
//
// The fallback path saves the caller's link register on the stack
// (so the inner BL doesn't clobber it) and tail-calls the full
// method's entry with the same regs. After return, restore x30 and
// ret.
//
// Returns the stub's byte offset within `buf`, or null if the
// method's bytecode doesn't match the recognised shape (in which
// case the caller should patch the BL to the full method's entry
// instead).
// Right-hand side of the leaf-check comparison shared between
// the simple and deep stubs: either a SmallInt-tagged immediate
// that fits in cmp's imm12 field, or a register holding a param.
const StubCmpRhs = union(enum) { imm12: u32, arg_reg: u5 };

// Deep-recursive inline stub for fib-shaped methods. The simple
// stub (4 inst leaf + tail-jump to full) skips the prologue only
// on leaf calls; the deep stub keeps the recursive descent inside
// the stub itself, never re-entering the full method's prologue
// until the slow-path bail (overflow or non-SmallInt result).
//
// Layout:
//   .stub:
//     cmp x2, <leaf-cutoff>           ; cmp self vs leaf threshold
//     b.<inv_cond> .recurse
//     mov x0, x2                       ; leaf path returns self
//     ret
//   .recurse:
//     stp x29, x30, [sp, #-32]!        ; save lr + reserve callee slots
//     stp x19, x20, [sp, #16]
//     mov x19, x2                      ; x19 = self (preserved across bls)
//     sub x2, x19, #sub1_imm           ; tagged sub: self - lit1
//     bl .stub                         ; recursive
//     tbz x0, #0, .bail                ; result must be SmallInt
//     mov x20, x0                      ; x20 = first result
//     sub x2, x19, #sub2_imm
//     bl .stub
//     tbz x0, #0, .bail
//     adds x0, x0, x20                 ; tagged add
//     b.vs .bail                       ; on i63 overflow, slow path
//     sub x0, x0, #1                   ; tag fixup for tagged + tagged
//     ldp x19, x20, [sp, #16]
//     ldp x29, x30, [sp], #32
//     ret
//   .bail:
//     mov x2, x19                      ; restore self
//     ldp x19, x20, [sp, #16]
//     ldp x29, x30, [sp], #32
//     b <full_entry>                   ; tail-jump, x30 still caller's
//
// GC safety: the stub never holds a non-SmallInt Oop in a
// callee-saved register. x19 = self is SmallInt (gated on
// SmallIntegerClass). x20 is only assigned after a tag-check that
// the recursive result is SmallInt; on tag failure we bail before
// it's saved. SmallInts don't move under GC, so the absence of a
// frame for the stub is safe — there are no heap roots to walk.
fn emitDeepRecursiveStub(
    buf: *JitBuf,
    fallback_cond: Cond,
    cmp_rhs: StubCmpRhs,
    sub1_imm: u32,
    sub2_imm: u32,
    full_entry_offset: u32,
    ic_entry_addr: u64,
) ?u32 {
    const stub_off: u32 = @intCast(buf.pos);
    if (stub_off + 192 > buf.bytes.len) return null;

    // ---- Leaf check ----
    switch (cmp_rhs) {
        .imm12 => |imm| buf.emit(cmpImm(2, imm)),
        .arg_reg => |r| buf.emit(cmpReg(2, r)),
    }
    const bcond_to_recurse_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(fallback_cond, 0));
    buf.emit(movReg(0, 2));
    buf.emit(ret());

    // ---- Recursive case ----
    const recurse_off: u32 = @intCast(buf.pos);
    patchBranch19(buf, bcond_to_recurse_off, recurse_off);

    // 48-byte stack frame:
    //   sp+0   x29 (saved fp)
    //   sp+8   x30 (saved lr)
    //   sp+16  x19 (saved caller-x19)
    //   sp+24  x20 (saved caller-x20)
    //   sp+32  vm  (saved x0; host pointer, GC-irrelevant)
    buf.emit(stpPre(29, 30, 31, -48));
    buf.emit(0xA9000000 | (@as(u32, 2) << 15) | (@as(u32, 20) << 10) | (@as(u32, 31) << 5) | 19);
    buf.emit(strImm(0, 31, 32));        // str x0, [sp, #32]  — save vm
    buf.emit(movReg(19, 2));

    // First recursive call: x2 = self - sub1_imm (tagged sub)
    buf.emit(subImm(2, 19, sub1_imm));
    const bl1_off: u32 = @intCast(buf.pos);
    const bl1_target: i64 = @as(i64, @intCast(stub_off)) - @as(i64, @intCast(bl1_off));
    if (bl1_target < -(@as(i64, 1) << 27) or bl1_target >= (@as(i64, 1) << 27)) return null;
    buf.emit(bl(@intCast(bl1_target)));
    const tbz1_off: u32 = @intCast(buf.pos);
    buf.emit(tbz(0, 0, 0));
    buf.emit(movReg(20, 0));

    // Second recursive call: x2 = self - sub2_imm
    buf.emit(subImm(2, 19, sub2_imm));
    const bl2_off: u32 = @intCast(buf.pos);
    const bl2_target: i64 = @as(i64, @intCast(stub_off)) - @as(i64, @intCast(bl2_off));
    buf.emit(bl(@intCast(bl2_target)));
    const tbz2_off: u32 = @intCast(buf.pos);
    buf.emit(tbz(0, 0, 0));

    // Tagged add with i63-overflow check.
    buf.emit(addsReg(0, 0, 20));
    const bvs_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(.vs, 0));
    buf.emit(subImm(0, 0, 1));

    // Restore and return.
    buf.emit(0xA9400000 | (@as(u32, 2) << 15) | (@as(u32, 20) << 10) | (@as(u32, 31) << 5) | 19);
    buf.emit(ldpPost(29, 30, 31, 48));
    buf.emit(ret());

    // ---- Bail path ----
    const bail_off: u32 = @intCast(buf.pos);
    patchBranch14(buf, tbz1_off, bail_off);
    patchBranch14(buf, tbz2_off, bail_off);
    patchBranch19(buf, bvs_off, bail_off);

    // Restore vm from saved slot (host ptr; GC-irrelevant).
    buf.emit(ldrImm(0, 31, 32));        // ldr x0, [sp, #32]
    // Re-load cached_method from the IC entry that pointed at this
    // stub. The IC entry is a runtime root walked by the GC, so the
    // cached_method slot is always GC-current — unlike a stack-saved
    // copy, which would go stale after a maybe-GC inside full_entry.
    movImm64(buf, 12, ic_entry_addr);
    buf.emit(ldrImm(1, 12, 8));          // x1 = cached_method
    buf.emit(movReg(2, 19));             // x2 = self
    buf.emit(0xA9400000 | (@as(u32, 2) << 15) | (@as(u32, 20) << 10) | (@as(u32, 31) << 5) | 19);
    buf.emit(ldpPost(29, 30, 31, 48));
    const tail_off: u32 = @intCast(buf.pos);
    const tail_target: i64 = @as(i64, @intCast(full_entry_offset)) - @as(i64, @intCast(tail_off));
    if (tail_target < -(@as(i64, 1) << 27) or tail_target >= (@as(i64, 1) << 27)) return null;
    buf.emit(bUncond(@intCast(tail_target)));

    return stub_off;
}

// Deep stub for factorial-shape methods:
//   ^self <op> N ifTrue: [<lit>] ifFalse: [self * (self - K) <self>]
//
// Single-recursion shape with tagged multiply and i63 overflow
// check. Like the binary-recursive variant, recursive bls go to
// the stub itself; a non-SmallInt result OR an overflowing tagged
// multiply tail-jumps to the full method.
fn emitFactorialStub(
    buf: *JitBuf,
    fallback_cond: Cond,
    cmp_rhs: StubCmpRhs,
    leaf_lit: u16,
    sub_imm: u32,
    full_entry_offset: u32,
    ic_entry_addr: u64,
) ?u32 {
    const stub_off: u32 = @intCast(buf.pos);
    if (stub_off + 192 > buf.bytes.len) return null;

    // ---- Leaf check ----
    switch (cmp_rhs) {
        .imm12 => |imm| buf.emit(cmpImm(2, imm)),
        .arg_reg => |r| buf.emit(cmpReg(2, r)),
    }
    const bcond_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(fallback_cond, 0));
    buf.emit(movz(0, leaf_lit, 0));
    buf.emit(ret());

    // ---- Recursive case ----
    const recurse_off: u32 = @intCast(buf.pos);
    patchBranch19(buf, bcond_off, recurse_off);

    // 48-byte frame: x29/x30 + x19/x20 + saved vm.
    buf.emit(stpPre(29, 30, 31, -48));
    buf.emit(0xA9000000 | (@as(u32, 2) << 15) | (@as(u32, 20) << 10) | (@as(u32, 31) << 5) | 19);
    buf.emit(strImm(0, 31, 32));        // save vm to [sp, #32]
    buf.emit(movReg(19, 2));            // x19 = self

    // Recursive call: x2 = self - sub_imm (tagged sub).
    buf.emit(subImm(2, 19, sub_imm));
    const bl_off: u32 = @intCast(buf.pos);
    const bl_target: i64 = @as(i64, @intCast(stub_off)) - @as(i64, @intCast(bl_off));
    if (bl_target < -(@as(i64, 1) << 27) or bl_target >= (@as(i64, 1) << 27)) return null;
    buf.emit(bl(@intCast(bl_target)));
    const tbz_off: u32 = @intCast(buf.pos);
    buf.emit(tbz(0, 0, 0));

    // Tagged multiply with i64 + i63 overflow check.
    buf.emit(subImm(9, 19, 1));
    buf.emit(asrImm(9, 9, 1));
    buf.emit(subImm(10, 0, 1));
    buf.emit(asrImm(10, 10, 1));
    buf.emit(mulReg(11, 9, 10));
    buf.emit(smulhReg(12, 9, 10));
    buf.emit(cmpRegAsr(12, 11, 63));
    const bne_overflow_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(.ne, 0));
    buf.emit(addsReg(11, 11, 11));
    const bvs_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(.vs, 0));
    buf.emit(addImm(0, 11, 1));

    // Restore and return.
    buf.emit(0xA9400000 | (@as(u32, 2) << 15) | (@as(u32, 20) << 10) | (@as(u32, 31) << 5) | 19);
    buf.emit(ldpPost(29, 30, 31, 48));
    buf.emit(ret());

    // ---- Bail path ----
    const bail_off: u32 = @intCast(buf.pos);
    patchBranch14(buf, tbz_off, bail_off);
    patchBranch19(buf, bne_overflow_off, bail_off);
    patchBranch19(buf, bvs_off, bail_off);

    buf.emit(ldrImm(0, 31, 32));        // ldr x0, [sp, #32] — restore vm
    movImm64(buf, 12, ic_entry_addr);
    buf.emit(ldrImm(1, 12, 8));          // x1 = cached_method (GC-current)
    buf.emit(movReg(2, 19));             // x2 = self
    buf.emit(0xA9400000 | (@as(u32, 2) << 15) | (@as(u32, 20) << 10) | (@as(u32, 31) << 5) | 19);
    buf.emit(ldpPost(29, 30, 31, 48));
    const tail_off: u32 = @intCast(buf.pos);
    const tail_target: i64 = @as(i64, @intCast(full_entry_offset)) - @as(i64, @intCast(tail_off));
    if (tail_target < -(@as(i64, 1) << 27) or tail_target >= (@as(i64, 1) << 27)) return null;
    buf.emit(bUncond(@intCast(tail_target)));

    return stub_off;
}

// Generate an inline-alloc stub for a Class>>new primitive method.
// Receiver at runtime is the class oop; the stub bakes the ivar
// count (computed via class.countIvars at IC fill time) and inlines
// the heap bump-pointer plus header init plus slot zeroing. On
// overflow vs gc_threshold the stub tail-jumps to vm_jit_alloc_slow
// which fires GC and retries.
//
// Layout (for ivar_count = N):
//
//   ldr  x9,  [x19, VM_HEAP]
//   ldr  x10, [x9,  HEAP_USED]
//   ldr  x11, [x9,  HEAP_GC_THRESHOLD]
//   add  x12, x10, #(16 + N*8)        ; or movz+add for big N
//   cmp  x12, x11
//   b.hi .slow
//   str  x12, [x9, HEAP_USED]
//   ldr  x13, [x9, HEAP_ACTIVE_BASE_ADDR]
//   add  x0,  x13, x10                 ; new object addr
//   str  x2,  [x0]                     ; header.class = class
//   movz x14, #N
//   str  x14, [x0, #8]                 ; size + flags=0
//   str  xzr, [x0, #16]                ; slots[0..N-1] = NIL
//   ... (N strs)
//   ret
//
//  .slow:
//   mov  x1, x2                        ; class
//   movz x2, #N                        ; n_slots
//   movImm64 x9, &vm_jit_alloc_slow
//   br   x9
pub fn emitAllocStubExt(buf: *JitBuf, ivar_count: u32, alloc_slow_addr: u64) ?u32 {
    const eval_mod = @import("eval.zig");
    const stub_off: u32 = @intCast(buf.pos);
    if (stub_off + 256 + ivar_count * 4 > buf.bytes.len) return null;
    if (ivar_count > 256) return null;

    const total_bytes: u32 = 16 + ivar_count * 8;
    if (total_bytes > 0xFFF) return null;

    buf.emit(ldrImm(9, 19, eval_mod.Vm.VM_HEAP_OFFSET));
    buf.emit(ldrImm(10, 9, eval_mod.Vm.HEAP_USED_OFFSET));
    buf.emit(ldrImm(11, 9, eval_mod.Vm.HEAP_GC_THRESHOLD_OFFSET));
    buf.emit(addImm(12, 10, total_bytes));
    buf.emit(cmpReg(12, 11));
    const bhi_slow_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(.hi, 0));

    buf.emit(strImm(12, 9, eval_mod.Vm.HEAP_USED_OFFSET));
    buf.emit(ldrImm(13, 9, eval_mod.Vm.HEAP_ACTIVE_BASE_ADDR_OFFSET));
    buf.emit(addsReg(0, 13, 10));
    buf.emit(strImm(2, 0, 0));            // header.class = recv (= class)
    buf.emit(movz(14, @intCast(ivar_count), 0));
    buf.emit(strImm(14, 0, 8));           // size (low 32) + flags=0 (high 32)

    var z: u32 = 0;
    while (z < ivar_count) : (z += 1) {
        buf.emit(strImm(31, 0, 16 + z * 8)); // str xzr, [x0, #...]
    }
    buf.emit(ret());

    // ---- .slow ----
    const slow_off: u32 = @intCast(buf.pos);
    patchBranch19(buf, bhi_slow_off, slow_off);

    buf.emit(movReg(1, 2));               // x1 = class (was x2 = recv)
    buf.emit(movz(2, @intCast(ivar_count), 0));
    movImm64(buf, 9, alloc_slow_addr);
    buf.emit(br(9));                      // tail-jump to helper

    return stub_off;
}

pub fn tryGenerateInlineStub(
    buf: *JitBuf,
    method: Oop,
    full_entry_offset: u32,
    receiver_class: Oop,
    ic_entry_addr: u64,
    globals: anytype,
) ?u32 {
    // The stub uses a raw integer compare (cmp x2, #imm12 / cmpReg)
    // and assumes a SmallInt-tagged receiver. Calling this stub with
    // a Float or heap receiver would compare bit patterns rather
    // than dispatch through a class-specific comparator, producing
    // semantically wrong results. The IC site only invokes the stub
    // when cached_class matches, so requiring that cached_class be
    // SmallInteger keeps the stub correct.
    if (receiver_class != globals.smallinteger_class) return null;
    const code_oop = object.slot(method, object.SLOT_METHOD_BYTECODE);
    if (!oop_mod.isHeapPtr(code_oop)) return null;
    const code_hdr = object.headerOf(code_oop);
    const code_bytes = object.bytesOf(code_oop)[0..code_hdr.size];
    const lits = object.slot(method, object.SLOT_METHOD_LITERALS);
    if (!oop_mod.isHeapPtr(lits)) return null;
    const n: u32 = @intCast(code_bytes.len / 4);
    if (n < 6) return null;

    const ins0 = std.mem.readInt(u32, code_bytes[0..4], .little);
    if (bc.opOf(ins0) != .push_self) return null;

    // The comparison's right-hand side is either a SmallInt literal
    // (fib / factorial style) or a method param read via push_local
    // (min:, max:, and any other 1-arg method that compares self to
    // its argument).
    const ins1 = std.mem.readInt(u32, code_bytes[4..8], .little);
    const cmp_rhs: StubCmpRhs = blk: {
        switch (bc.opOf(ins1)) {
            .push_lit => {
                const li = bc.operandOf(ins1);
                const lv = object.slot(lits, li);
                if (!oop_mod.isInt(lv)) return null;
                if (lv > 0xFFF) return null;
                break :blk .{ .imm12 = @intCast(lv) };
            },
            .push_local => {
                // local idx 0 is self; 1.. are the params (a0..a3).
                // Map idx i (>= 1) to ARM reg x(3 + i - 1) = x(2+i).
                const li = bc.operandOf(ins1);
                if (li == 0 or li > 4) return null;
                break :blk .{ .arg_reg = @intCast(2 + li) };
            },
            else => return null,
        }
    };

    const ins2 = std.mem.readInt(u32, code_bytes[8..12], .little);
    if (bc.opOf(ins2) != .send) return null;
    if (bc.sendArityOf(ins2) != 1) return null;
    const sel_idx = bc.sendSelOf(ins2);
    const sel = object.slot(lits, sel_idx);
    // The leaf path runs when the SEND comparison is TRUE
    // (jump_if_false fall-through). Stub takes the fallback when
    // SEND would have been FALSE — i.e. the inverted condition.
    const fallback_cond: ?Cond = blk: {
        if (sel == globals.sym_lt) break :blk .ge;
        if (sel == globals.sym_le) break :blk .gt;
        if (sel == globals.sym_gt) break :blk .le;
        if (sel == globals.sym_ge) break :blk .lt;
        break :blk null;
    };
    if (fallback_cond == null) return null;

    const ins3 = std.mem.readInt(u32, code_bytes[12..16], .little);
    if (bc.opOf(ins3) != .jump_if_false) return null;

    // The leaf-path body either pushes self (fib's `[self]` form)
    // or a SmallInt literal (factorial's `[1]` form) and then
    // returns / jumps-past-else. Track which so the stub knows
    // what to mov into x0.
    const ins4 = std.mem.readInt(u32, code_bytes[16..20], .little);
    const leaf_kind: union(enum) {
        self_,
        lit: u32, // u16 imm fits movz; up to 0xFFFF
        arg_reg: u5, // x3..x6 for params 0..3
    } = blk: {
        switch (bc.opOf(ins4)) {
            .push_self => break :blk .self_,
            .push_lit => {
                const li = bc.operandOf(ins4);
                const lv = object.slot(lits, li);
                if (!oop_mod.isInt(lv)) return null;
                if (lv > 0xFFFF) return null;
                break :blk .{ .lit = @intCast(lv) };
            },
            .push_local => {
                const li = bc.operandOf(ins4);
                if (li == 0 or li > 4) return null;
                break :blk .{ .arg_reg = @intCast(2 + li) };
            },
            else => return null,
        }
    };

    const ins5 = std.mem.readInt(u32, code_bytes[20..24], .little);
    const op5 = bc.opOf(ins5);
    if (op5 != .return_top and op5 != .jump) return null;

    // Try to match the full fib-shape recursive body so we can
    // generate a deep-inline stub that recurses into ITSELF rather
    // than tail-jumping to the full method on every internal node.
    //
    // After the leaf check (ins0..5) the bytecode for fib's
    // ifFalse-branch is:
    //
    //   ins6  push_self            ; recv of first `-`
    //   ins7  push_lit  N1         ; arg of first `-`
    //   ins8  send -    arity 1    ; (self - N1) on top
    //   ins9  send <self_sel> arity 0   ; recursive call
    //   ins10 push_self
    //   ins11 push_lit  N2
    //   ins12 send -    arity 1
    //   ins13 send <self_sel> arity 0
    //   ins14 send +    arity 1
    //   ins15 return_top
    //
    // The two recursive sends must dispatch to the SAME selector as
    // the method we're inlining (slot SLOT_METHOD_SELECTOR). The
    // ifTrue body (ins4) must be `push_self` so the leaf returns
    // self; otherwise we can't combine results meaningfully.
    const deep: ?struct { sub1_imm: u32, sub2_imm: u32 } = blk: {
        if (n < 16) break :blk null;
        if (op5 != .jump) break :blk null;
        if (bc.opOf(ins0) != .push_self) break :blk null;
        // ins4 is leaf body; must return self for the deep shape.
        switch (leaf_kind) {
            .self_ => {},
            else => break :blk null,
        }
        // ins1 (lit) must be an imm12-fitting SmallInt — already
        // checked. fallback_cond is set.
        const method_sel = object.slot(method, object.SLOT_METHOD_SELECTOR);

        const ins6 = std.mem.readInt(u32, code_bytes[24..28], .little);
        if (bc.opOf(ins6) != .push_self) break :blk null;
        const ins7 = std.mem.readInt(u32, code_bytes[28..32], .little);
        if (bc.opOf(ins7) != .push_lit) break :blk null;
        const li7 = bc.operandOf(ins7);
        const lv7 = object.slot(lits, li7);
        if (!oop_mod.isInt(lv7)) break :blk null;
        if (lv7 < 1 or lv7 > 0xFFF + 1) break :blk null;
        const sub1_imm: u32 = @intCast(lv7 - 1);

        const ins8 = std.mem.readInt(u32, code_bytes[32..36], .little);
        if (bc.opOf(ins8) != .send) break :blk null;
        if (bc.sendArityOf(ins8) != 1) break :blk null;
        const sel8 = object.slot(lits, bc.sendSelOf(ins8));
        if (sel8 != globals.sym_minus) break :blk null;

        const ins9 = std.mem.readInt(u32, code_bytes[36..40], .little);
        if (bc.opOf(ins9) != .send) break :blk null;
        if (bc.sendArityOf(ins9) != 0) break :blk null;
        const sel9 = object.slot(lits, bc.sendSelOf(ins9));
        if (sel9 != method_sel) break :blk null;

        const ins10 = std.mem.readInt(u32, code_bytes[40..44], .little);
        if (bc.opOf(ins10) != .push_self) break :blk null;
        const ins11 = std.mem.readInt(u32, code_bytes[44..48], .little);
        if (bc.opOf(ins11) != .push_lit) break :blk null;
        const li11 = bc.operandOf(ins11);
        const lv11 = object.slot(lits, li11);
        if (!oop_mod.isInt(lv11)) break :blk null;
        if (lv11 < 1 or lv11 > 0xFFF + 1) break :blk null;
        const sub2_imm: u32 = @intCast(lv11 - 1);

        const ins12 = std.mem.readInt(u32, code_bytes[48..52], .little);
        if (bc.opOf(ins12) != .send) break :blk null;
        if (bc.sendArityOf(ins12) != 1) break :blk null;
        if (object.slot(lits, bc.sendSelOf(ins12)) != globals.sym_minus) break :blk null;

        const ins13 = std.mem.readInt(u32, code_bytes[52..56], .little);
        if (bc.opOf(ins13) != .send) break :blk null;
        if (bc.sendArityOf(ins13) != 0) break :blk null;
        if (object.slot(lits, bc.sendSelOf(ins13)) != method_sel) break :blk null;

        const ins14 = std.mem.readInt(u32, code_bytes[56..60], .little);
        if (bc.opOf(ins14) != .send) break :blk null;
        if (bc.sendArityOf(ins14) != 1) break :blk null;
        if (object.slot(lits, bc.sendSelOf(ins14)) != globals.sym_plus) break :blk null;

        const ins15 = std.mem.readInt(u32, code_bytes[60..64], .little);
        if (bc.opOf(ins15) != .return_top) break :blk null;

        break :blk .{ .sub1_imm = sub1_imm, .sub2_imm = sub2_imm };
    };

    if (deep) |d| {
        return emitDeepRecursiveStub(buf, fallback_cond.?, cmp_rhs, d.sub1_imm, d.sub2_imm, full_entry_offset, ic_entry_addr);
    }

    // Try factorial shape: leaf body is a SmallInt literal, else
    // branch is `self * (self - K) <self_sel>`.
    //
    //   ins0  push_self
    //   ins1  push_lit  N         (leaf cutoff)
    //   ins2  send <comparator>
    //   ins3  jump_if_false else
    //   ins4  push_lit  R         (leaf result)
    //   ins5  jump end
    //   ins6  push_self            ; recv of *
    //   ins7  push_self            ; recv of -
    //   ins8  push_lit  K          ; arg of -
    //   ins9  send -    arity 1
    //   ins10 send <self_sel> arity 0
    //   ins11 send *    arity 1
    //   ins12 return_top
    const fact: ?struct { leaf_lit: u16, sub_imm: u32 } = blk: {
        if (n < 13) break :blk null;
        if (op5 != .jump) break :blk null;
        // ins4 must be the lit-leaf form for factorial.
        const leaf_lit_val: u16 = switch (leaf_kind) {
            .lit => |v| if (v <= 0xFFFF) @intCast(v) else break :blk null,
            else => break :blk null,
        };
        const method_sel = object.slot(method, object.SLOT_METHOD_SELECTOR);

        const ins6 = std.mem.readInt(u32, code_bytes[24..28], .little);
        if (bc.opOf(ins6) != .push_self) break :blk null;
        const ins7 = std.mem.readInt(u32, code_bytes[28..32], .little);
        if (bc.opOf(ins7) != .push_self) break :blk null;
        const ins8 = std.mem.readInt(u32, code_bytes[32..36], .little);
        if (bc.opOf(ins8) != .push_lit) break :blk null;
        const li8 = bc.operandOf(ins8);
        const lv8 = object.slot(lits, li8);
        if (!oop_mod.isInt(lv8)) break :blk null;
        if (lv8 < 1 or lv8 > 0xFFF + 1) break :blk null;
        const sub_imm: u32 = @intCast(lv8 - 1);

        const ins9 = std.mem.readInt(u32, code_bytes[36..40], .little);
        if (bc.opOf(ins9) != .send) break :blk null;
        if (bc.sendArityOf(ins9) != 1) break :blk null;
        if (object.slot(lits, bc.sendSelOf(ins9)) != globals.sym_minus) break :blk null;

        const ins10 = std.mem.readInt(u32, code_bytes[40..44], .little);
        if (bc.opOf(ins10) != .send) break :blk null;
        if (bc.sendArityOf(ins10) != 0) break :blk null;
        if (object.slot(lits, bc.sendSelOf(ins10)) != method_sel) break :blk null;

        const ins11 = std.mem.readInt(u32, code_bytes[44..48], .little);
        if (bc.opOf(ins11) != .send) break :blk null;
        if (bc.sendArityOf(ins11) != 1) break :blk null;
        if (object.slot(lits, bc.sendSelOf(ins11)) != globals.sym_times) break :blk null;

        const ins12 = std.mem.readInt(u32, code_bytes[48..52], .little);
        if (bc.opOf(ins12) != .return_top) break :blk null;

        break :blk .{ .leaf_lit = leaf_lit_val, .sub_imm = sub_imm };
    };

    if (fact) |f| {
        // The factorial inline stub is currently disabled: when the
        // tagged multiplication overflows i63 it tail-jumps to the
        // full bytecode entry, which itself dispatches `factorial`
        // through the IC (which still points at this stub), causing
        // the stub to re-run and bail again. Each bail re-computes
        // the entire sub-recursion from scratch — exponential
        // explosion (factorial 50 fires ~2^29 stub invocations and
        // never terminates under repeated GC pressure). Re-enable
        // only when the bail path can multiply self * heap_result
        // without re-entering the stub.
        _ = f;
    }

    // Stub layout — see the function-level comment.
    const stub_off: u32 = @intCast(buf.pos);
    if (stub_off + 32 > buf.bytes.len) return null; // out of JIT page

    switch (cmp_rhs) {
        .imm12 => |imm| buf.emit(cmpImm(2, imm)),
        .arg_reg => |r| buf.emit(cmpReg(2, r)),
    }
    const bcond_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(fallback_cond.?, 0));
    switch (leaf_kind) {
        .self_ => buf.emit(movReg(0, 2)),
        .lit => |v| buf.emit(movz(0, @intCast(v), 0)),
        .arg_reg => |r| buf.emit(movReg(0, r)),
    }
    buf.emit(ret());

    const fallback_off: u32 = @intCast(buf.pos);
    patchBranch19(buf, bcond_off, fallback_off);

    // Tail-jump to the full method's entry. x30 still holds the
    // outer caller's continuation (we never wrote to it on the
    // leaf path either), so when the full method returns it
    // returns straight to the caller — no stp/bl/ldp/ret roundtrip
    // through the stub. Saves 3 instructions on the recursive path.
    const b_off: u32 = @intCast(buf.pos);
    const target_byte: i64 = @as(i64, @intCast(full_entry_offset)) - @as(i64, @intCast(b_off));
    if (target_byte < -(@as(i64, 1) << 27) or target_byte >= (@as(i64, 1) << 27)) return null;
    buf.emit(bUncond(@intCast(target_byte)));

    return stub_off;
}

fn nValuesForMethod(method: Oop) u32 {
    const params = object.slot(method, object.SLOT_METHOD_PARAMS);
    const temps = object.slot(method, object.SLOT_METHOD_TEMPS);
    const np: u32 = if (oop_mod.isHeapPtr(params)) object.headerOf(params).size else 0;
    const nt: u32 = if (oop_mod.isHeapPtr(temps)) object.headerOf(temps).size else 0;
    return 1 + np + nt;
}

const MAX_BYTECODE_INSTRS: u32 = 4096;

// Walk the bytecode, propagate depth across jumps, and verify every
// opcode is supported. Fills `depth_at[i]` with the eval-stack depth
// at the start of instruction `i` (-1 = unreachable, never reached
// in a well-formed program). Returns the max depth observed, or
// null on unsupported / malformed input.
fn analyseSupportedAndDepth(code_bytes: []const u8, depth_at: *[MAX_BYTECODE_INSTRS]i32) ?u32 {
    const n: u32 = @intCast(code_bytes.len / 4);
    if (n > MAX_BYTECODE_INSTRS) return null;
    var i: u32 = 0;
    while (i < n) : (i += 1) depth_at[i] = -1;
    depth_at[0] = 0;
    var max_depth: u32 = 0;

    var pc: u32 = 0;
    while (pc < n) : (pc += 1) {
        const D = depth_at[pc];
        if (D < 0) continue; // unreachable
        const Du: u32 = @intCast(D);
        if (Du > max_depth) max_depth = Du;
        const ins = std.mem.readInt(u32, code_bytes[pc * 4 ..][0..4], .little);
        const op = bc.opOf(ins);
        var fall_d: ?i32 = null;
        switch (op) {
            .push_lit, .push_self, .push_local,
            .push_nil, .push_true, .push_false, .push_global => {
                fall_d = D + 1;
            },
            .pop => {
                if (Du == 0) return null;
                fall_d = D - 1;
            },
            .store_local => {
                if (Du == 0) return null;
                fall_d = D;
            },
            .send => {
                const arity = bc.sendArityOf(ins);
                if (arity > 4) return null;
                const total_pop: u32 = @as(u32, arity) + 1;
                if (Du < total_pop) return null;
                fall_d = D - @as(i32, arity);
            },
            .return_top => {
                if (Du == 0) return null;
                // No fall through.
            },
            .jump => {
                const off = bc.signedOperandOf(ins);
                const target: i32 = @as(i32, @intCast(pc)) + 1 + off;
                if (target < 0 or target >= @as(i32, @intCast(n))) return null;
                const t: u32 = @intCast(target);
                if (depth_at[t] >= 0 and depth_at[t] != D) return null;
                depth_at[t] = D;
                // No fall through.
            },
            .jump_if_false, .jump_if_true => {
                if (Du == 0) return null;
                const off = bc.signedOperandOf(ins);
                const target: i32 = @as(i32, @intCast(pc)) + 1 + off;
                if (target < 0 or target >= @as(i32, @intCast(n))) return null;
                const t: u32 = @intCast(target);
                const D_after = D - 1;
                if (depth_at[t] >= 0 and depth_at[t] != D_after) return null;
                depth_at[t] = D_after;
                fall_d = D_after;
            },
            else => return null,
        }
        if (fall_d) |fd| {
            if (pc + 1 < n) {
                if (depth_at[pc + 1] >= 0 and depth_at[pc + 1] != fd) return null;
                depth_at[pc + 1] = fd;
            }
        }
    }
    return max_depth;
}

// SmallInt arithmetic / comparison fast paths. Emitted inline at SEND
// sites where the compile-time selector matches one of these and
// arity == 1. All runtime decisions (tag check, overflow check)
// branch to the slow path on miss; the slow path stores its result
// at the same eval-stack slot, so control merges cleanly afterward.
const FastOp = enum { add, sub, lt, le, gt, ge };

// Emit the generic SEND with a *bimorphic* inline cache. Two
// (cached_class, cached_method, bl_offset) entries are checked in
// sequence; each has its own direct-call BL that vm_jit_send_caching
// patches on fill. Once both entries are full and a third class
// arrives, the helper LRU-evicts entry A.
//
//   ; classOf(recv) → x16
//   ; adr x17, .ic_data
//   ; ldr x7, [x17, #0]        cached_class_a
//   ; cmp x16, x7
//   ; b.eq .hit_a
//   ; ldr x7, [x17, #24]       cached_class_b
//   ; cmp x16, x7
//   ; b.eq .hit_b
//   ; b   .miss
//   ;
//   ; .hit_a: mov x0,x19; ldr x1,[x17,#8]; mov x2,recv; mov x3..x6,args
//   ;         bl <patched_a>; b .post_call
//   ; .hit_b: mov x0,x19; ldr x1,[x17,#32]; mov x2,recv; mov x3..x6,args
//   ;         bl <patched_b>
//   ;         (fall through to .post_call)
//   ; .post_call: ldr jit_error; cbnz err; ldr x20, current_frame
//   ;             b .after
//   ; .miss: spill; vm_jit_send_caching(...); ldr jit_error; cbnz err;
//   ;        ldr x20; (falls through to .after)
//   ; .ic_data:
//   ;   .quad 0  cached_class_a   (runtime)
//   ;   .quad 0  cached_method_a  (runtime; GC-walked)
//   ;   .quad bl_a_off
//   ;   .quad 0  cached_class_b
//   ;   .quad 0  cached_method_b  (GC-walked)
//   ;   .quad bl_b_off
//   ; .after:
fn emitGenericSend(
    buf: *JitBuf,
    vm: anytype,
    sel_idx: u32,
    recv_reg: u5,
    arg_regs: []const u5,
    recv_slot: u32,
    send_addr: u64,
    error_sites: *[256]u32,
    n_error_sites: *u32,
) void {
    const eval_mod = @import("eval.zig");
    const arity: u32 = @intCast(arg_regs.len);

    // ---- Inline classOf on recv_reg → x16 ----
    const tbz_to_heap_off: u32 = @intCast(buf.pos);
    buf.emit(tbz(recv_reg, 0, 0));
    buf.emit(ldrImm(16, 19, eval_mod.Vm.VM_SMALLINT_CLASS_OFFSET));
    const b_have_class_off: u32 = @intCast(buf.pos);
    buf.emit(bUncond(0));

    const check_heap_off: u32 = @intCast(buf.pos);
    patchBranch14(buf, tbz_to_heap_off, check_heap_off);
    const tbnz_b1_miss_off: u32 = @intCast(buf.pos);
    buf.emit(tbnz(recv_reg, 1, 0));
    const tbnz_b2_miss_off: u32 = @intCast(buf.pos);
    buf.emit(tbnz(recv_reg, 2, 0));
    const cbz_nil_miss_off: u32 = @intCast(buf.pos);
    buf.emit(cbz(recv_reg, 0));
    buf.emit(ldrImm(16, recv_reg, 0));

    const have_class_off: u32 = @intCast(buf.pos);
    patchBranch26(buf, b_have_class_off, have_class_off);

    // ---- Bimorphic IC dispatch ----
    const adr_off: u32 = @intCast(buf.pos);
    buf.emit(adr(17, 0));

    // Entry A: cmp class_a; b.eq .hit_a
    buf.emit(ldrImm(7, 17, 0));
    buf.emit(cmpReg(16, 7));
    const beq_a_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(.eq, 0));

    // Entry B: cmp class_b; b.eq .hit_b
    buf.emit(ldrImm(7, 17, 24));
    buf.emit(cmpReg(16, 7));
    const beq_b_off: u32 = @intCast(buf.pos);
    buf.emit(bCond(.eq, 0));

    // Both miss → b .miss
    const b_miss_off: u32 = @intCast(buf.pos);
    buf.emit(bUncond(0));

    // ---- .hit_a ----
    const hit_a_off: u32 = @intCast(buf.pos);
    patchBranch19(buf, beq_a_off, hit_a_off);
    buf.emit(movReg(0, 19));
    buf.emit(ldrImm(1, 17, 8));
    if (recv_reg != 2) buf.emit(movReg(2, recv_reg));
    var ai_a: u32 = 0;
    while (ai_a < arity) : (ai_a += 1) {
        const dst: u5 = @intCast(3 + ai_a);
        if (dst != arg_regs[ai_a]) buf.emit(movReg(dst, arg_regs[ai_a]));
    }
    const bl_a_off: u32 = @intCast(buf.pos);
    buf.emit(bl(0));
    const b_post_a_off: u32 = @intCast(buf.pos);
    buf.emit(bUncond(0));

    // ---- .hit_b ----
    const hit_b_off: u32 = @intCast(buf.pos);
    patchBranch19(buf, beq_b_off, hit_b_off);
    buf.emit(movReg(0, 19));
    buf.emit(ldrImm(1, 17, 32));
    if (recv_reg != 2) buf.emit(movReg(2, recv_reg));
    var ai_b: u32 = 0;
    while (ai_b < arity) : (ai_b += 1) {
        const dst: u5 = @intCast(3 + ai_b);
        if (dst != arg_regs[ai_b]) buf.emit(movReg(dst, arg_regs[ai_b]));
    }
    const bl_b_off: u32 = @intCast(buf.pos);
    buf.emit(bl(0));
    // (fall through to .post_call)

    // ---- .post_call ----
    const post_call_off: u32 = @intCast(buf.pos);
    patchBranch26(buf, b_post_a_off, post_call_off);
    buf.emit(ldrImm(9, 19, eval_mod.Vm.VM_JIT_ERROR_OFFSET));
    const post_cbnz_off: u32 = @intCast(buf.pos);
    buf.emit(cbnz(9, 0));
    if (n_error_sites.* < error_sites.len) {
        error_sites[n_error_sites.*] = post_cbnz_off;
        n_error_sites.* += 1;
    }
    buf.emit(ldrImm(20, 19, eval_mod.Vm.VM_CURRENT_FRAME_OFFSET));
    const b_after_post_off: u32 = @intCast(buf.pos);
    buf.emit(bUncond(0));

    // ---- .miss ----
    const miss_off: u32 = @intCast(buf.pos);
    patchBranch14(buf, tbnz_b1_miss_off, miss_off);
    patchBranch14(buf, tbnz_b2_miss_off, miss_off);
    patchBranch19(buf, cbz_nil_miss_off, miss_off);
    patchBranch26(buf, b_miss_off, miss_off);
    // Initial BL targets for both entries land in .miss until the
    // helper patches them on first fill.
    patchBranch26(buf, bl_a_off, miss_off);
    patchBranch26(buf, bl_b_off, miss_off);

    // Spill recv + args to slots so the args-pointer-ABI helper can
    // see them.
    buf.emit(strImm(recv_reg, 20, slotByteOffset(recv_slot)));
    var sai: u32 = 0;
    while (sai < arity) : (sai += 1) {
        buf.emit(strImm(arg_regs[sai], 20, slotByteOffset(recv_slot + 1 + sai)));
    }

    buf.emit(movReg(0, 19));
    if (recv_reg != 1) buf.emit(movReg(1, recv_reg));
    buf.emit(ldrImm(2, 20, slotByteOffset(object.SLOT_FRAME_SOURCE)));
    buf.emit(ldrImm(2, 2, slotByteOffset(object.SLOT_METHOD_LITERALS)));
    buf.emit(ldrImm(2, 2, slotByteOffset(sel_idx)));
    if (arity > 0) {
        buf.emit(addImm(3, 20, slotByteOffset(recv_slot + 1)));
    } else {
        buf.emit(movz(3, 0, 0));
    }
    buf.emit(movz(4, @intCast(arity), 0));
    const adr2_off: u32 = @intCast(buf.pos);
    buf.emit(adr(5, 0));
    movImm64(buf, 9, send_addr);
    buf.emit(blr(9));
    buf.emit(ldrImm(9, 19, eval_mod.Vm.VM_JIT_ERROR_OFFSET));
    const miss_cbnz_off: u32 = @intCast(buf.pos);
    buf.emit(cbnz(9, 0));
    if (n_error_sites.* < error_sites.len) {
        error_sites[n_error_sites.*] = miss_cbnz_off;
        n_error_sites.* += 1;
    }
    buf.emit(ldrImm(20, 19, eval_mod.Vm.VM_CURRENT_FRAME_OFFSET));
    const miss_b_after_off: u32 = @intCast(buf.pos);
    buf.emit(bUncond(0));

    // ---- IC data ----
    if ((buf.pos & 7) != 0) {
        buf.emit(0xD503201F); // NOP pad
    }
    const ic_data_off: u32 = @intCast(buf.pos);
    // Entry A: class, method, bl_offset
    buf.emit(0); buf.emit(0);
    buf.emit(0); buf.emit(0);
    buf.emit(bl_a_off); buf.emit(0);
    // Entry B
    buf.emit(0); buf.emit(0);
    buf.emit(0); buf.emit(0);
    buf.emit(bl_b_off); buf.emit(0);

    // Register the two (class, method) PAIRS with vm.jit_ic_slots so
    // the GC walks them. Each registered pointer points at a class
    // slot; the GC reads slot[0] as the class and slot[1] as the
    // method (the bl_offset slot at +16 is a raw numeric offset and
    // is NOT walked).
    const entry_a_ptr: [*]u64 = @ptrCast(@alignCast(buf.bytes.ptr + ic_data_off));
    const entry_b_ptr: [*]u64 = @ptrCast(@alignCast(buf.bytes.ptr + ic_data_off + 24));
    vm.registerJitIcSlot(entry_a_ptr);
    vm.registerJitIcSlot(entry_b_ptr);

    // ---- Patch up forward references ----
    const after_off: u32 = @intCast(buf.pos);
    patchAdr(buf, adr_off, ic_data_off);
    patchAdr(buf, adr2_off, ic_data_off);
    patchBranch26(buf, b_after_post_off, after_off);
    patchBranch26(buf, miss_b_after_off, after_off);
}

fn patchAdr(buf: *JitBuf, instr_off: u32, target_off: u32) void {
    const off: i32 = @as(i32, @intCast(target_off)) - @as(i32, @intCast(instr_off));
    const ub: u32 = @as(u32, @bitCast(off)) & 0x1FFFFF;
    const immlo = ub & 0x3;
    const immhi = (ub >> 2) & 0x7FFFF;
    var instr = std.mem.readInt(u32, buf.bytes[instr_off..][0..4], .little);
    instr = (instr & ~((@as(u32, 0x3) << 29) | (@as(u32, 0x7FFFF) << 5))) | (immlo << 29) | (immhi << 5);
    std.mem.writeInt(u32, buf.bytes[instr_off..][0..4], instr, .little);
}

fn compileWithFrame(vm_ptr: *anyopaque, method: Oop, buf: *JitBuf) ?CompileResult {
    const eval_mod = @import("eval.zig");
    const Vm = eval_mod.Vm;
    const vm: *Vm = @ptrCast(@alignCast(vm_ptr));
    const code_oop = object.slot(method, object.SLOT_METHOD_BYTECODE);
    if (!oop_mod.isHeapPtr(code_oop)) return null;
    const code_hdr = object.headerOf(code_oop);
    const code_bytes = object.bytesOf(code_oop)[0..code_hdr.size];
    var depth_at: [MAX_BYTECODE_INSTRS]i32 = undefined;
    const max_depth = analyseSupportedAndDepth(code_bytes, &depth_at) orelse return null;
    // v4.A.1 register-resident eval stack: TOS at depth d lives in
    // x(9+d). Caller-saved regs x9..x15 give us 7 eval-stack slots;
    // anything deeper falls back to the bytecode interpreter.
    if (max_depth > 7) return null;

    const n_values = nValuesForMethod(method);
    const eval_base_slot: u32 = object.FRAME_VALUES_OFFSET + n_values;
    const lits = object.slot(method, object.SLOT_METHOD_LITERALS);
    if (!oop_mod.isHeapPtr(lits)) return null;

    const enter_addr: u64 = @intFromPtr(&Vm.vm_jit_method_enter);
    const collect_addr: u64 = @intFromPtr(&Vm.vm_jit_collect);
    const send_addr: u64 = @intFromPtr(&Vm.vm_jit_send_caching);

    // Detect stack-eligibility: a method whose bytecode never
    // creates a block closure can have its frame on the JIT'd
    // function's native stack. The block's home_method points back
    // at our frame; if a block escapes, it would dangle. (Other
    // escape vectors — thisContext, returning self — aren't
    // exposed in our system.)
    const total_instrs: u32 = @intCast(code_bytes.len / 4);
    var stack_eligible = true;
    // v4.C tag tracking: per-bytecode-PC, mark which PCs are jump
    // targets (so we conservatively reset eval-stack int knowledge
    // there) and which locals are ever STORE_LOCAL'd (so we can
    // leave the rest's int-state pinned to their entry values).
    var is_jump_target: [MAX_BYTECODE_INSTRS]bool = undefined;
    var local_was_stored: [256]bool = undefined;
    {
        var j: u32 = 0;
        while (j < total_instrs) : (j += 1) is_jump_target[j] = false;
        var k: u32 = 0;
        while (k < local_was_stored.len) : (k += 1) local_was_stored[k] = false;
        var p: u32 = 0;
        while (p < total_instrs) : (p += 1) {
            const ins = std.mem.readInt(u32, code_bytes[p * 4 ..][0..4], .little);
            const op = bc.opOf(ins);
            switch (op) {
                .push_block_ast => stack_eligible = false,
                .store_local => {
                    const idx = bc.operandOf(ins);
                    if (idx < local_was_stored.len) local_was_stored[idx] = true;
                },
                .jump, .jump_if_false, .jump_if_true => {
                    const off = bc.signedOperandOf(ins);
                    const t: i32 = @as(i32, @intCast(p)) + 1 + off;
                    if (t >= 0 and t < @as(i32, @intCast(total_instrs))) {
                        is_jump_target[@intCast(t)] = true;
                    }
                },
                else => {},
            }
        }
    }
    // Self is SmallInt-typed at entry iff this method is defined on
    // SmallInteger. fib lives there; so do all the integer arith
    // primitives. For other defining classes, self could be anything.
    const defining_class = object.slot(method, object.SLOT_METHOD_DEFINING_CLASS);
    const self_is_int: bool = (defining_class == vm.globals.smallinteger_class);
    // Per-frame slot count (matches what enter_stack writes).
    const stack_frame_slots: u32 = object.FRAME_VALUES_OFFSET + n_values + max_depth;
    const stack_frame_bytes_raw: u32 = @sizeOf(object.Header) + stack_frame_slots * 8;
    const stack_frame_bytes: u32 = std.mem.alignForward(u32, stack_frame_bytes_raw, 16);
    // Params count is known at JIT time and equals the arity callers
    // pass; the fully-inlined prologue stores args[i] into the frame
    // without the runtime arity check the helper used to do.
    const params_arr = object.slot(method, object.SLOT_METHOD_PARAMS);
    const params_count: u32 = if (oop_mod.isHeapPtr(params_arr)) object.headerOf(params_arr).size else 0;
    // Cap: imm12 in sub-sp can be 0..4095 bytes. Anything bigger,
    // fall back to heap allocation. (Realistic methods are well
    // under this; fib's frame is ~64 bytes.)
    if (stack_frame_bytes > 0xFFF) stack_eligible = false;

    const offset: u32 = @intCast(buf.pos);
    buf.markWritable();

    // v4.I.1 — register cache for locals. Each local up to
    // MAX_CACHED_LOCALS gets a callee-saved register home. PUSH_LOCAL
    // reads from the cached reg via mov when valid (free on Apple
    // Silicon's renamer vs a load-port slot for ldr); STORE_LOCAL
    // writes to both the frame slot and the cache (write-through).
    // Caches invalidate after every generic SEND opcode (the call
    // may fire GC and move heap-pointer locals). Pure fast-path
    // arith doesn't fire GC and leaves caches valid — that's where
    // the cache pays off (sum/count's tight loops).
    const temps_arr_for_count = object.slot(method, object.SLOT_METHOD_TEMPS);
    const temps_count_for_locals: u32 = if (oop_mod.isHeapPtr(temps_arr_for_count)) object.headerOf(temps_arr_for_count).size else 0;
    const MAX_CACHED_LOCALS: u32 = 7;
    const n_locals_total: u32 = 1 + params_count + temps_count_for_locals;
    const n_cached_locals: u32 = @min(n_locals_total, MAX_CACHED_LOCALS);

    // Pre-declare the cbnz/cbz patch table — the prologue needs it
    // to register the enter-failure check.
    var error_sites: [256]u32 = undefined;
    var n_error_sites: u32 = 0;

    // ---- Prologue ----
    // stp x29, x30, [sp, #-16]!
    buf.emit(stpPre(29, 30, 31, -16));
    // mov x29, sp  (alias of add x29, sp, #0)
    buf.emit(addSpToReg(29, 0));
    // stp x19, x20, [sp, #-16]!
    buf.emit(stpPre(19, 20, 31, -16));
    // stp x21, x22, [sp, #-16]!
    buf.emit(stpPre(21, 22, 31, -16));
    // v4.I.1 — additional callee-saved pairs for local register cache.
    // Each pair adds 16 bytes to the frame; pairs are saved
    // conditionally based on how many locals get reg homes (x22 is
    // already saved above as part of the existing x21/x22 pair).
    if (n_cached_locals >= 2) buf.emit(stpPre(23, 24, 31, -16));
    if (n_cached_locals >= 4) buf.emit(stpPre(25, 26, 31, -16));
    if (n_cached_locals >= 6) buf.emit(stpPre(27, 28, 31, -16));
    // sub sp, sp, #(PIN_STORAGE_BYTES [+ frame_storage when stack-eligible])
    const total_sp_reserve: u32 = if (stack_eligible)
        PIN_STORAGE_BYTES + stack_frame_bytes
    else
        PIN_STORAGE_BYTES;
    buf.emit(subSpImm(total_sp_reserve));
    // mov x19, x0   ; vm
    buf.emit(movReg(19, 0));
    // Native ABI: (vm, method, receiver, a0, a1, a2, a3) with the
    // first three already in x0..x2 by the call. a0..a3 are in
    // x3..x6 untouched. The heap-allocated path adds pin in x7 and
    // calls vm_jit_method_enter; the stack-eligible path inlines
    // the entire helper body using x16 as scratch (since x9..x15
    // are reserved for the body's eval-stack regalloc and x3..x6
    // still hold the incoming args).
    if (stack_eligible) {
        // x16 (IP0) = &pin (above frame storage). Using x16 avoids
        // clobbering x3..x6 (which carry a0..a3 — written into the
        // frame below) and x5..x7 (also reserved by the new ABI).
        buf.emit(addSpToReg(16, stack_frame_bytes));
        buf.emit(addSpToReg(17, 0));   // x17 (IP1) = &frame_storage

        // ---- Fill BcPin (5 fields). stack_base stays undefined. ----
        // x16 = &pin throughout this block. We use x16/x17 (IP0/IP1)
        // as scratch so the incoming a0..a3 in x3..x6 stay live for
        // the args-to-frame copy below.
        // pin.sp_ptr = &vm.bc_jit_zero_sp
        buf.emit(addImm(9, 19, Vm.VM_BC_JIT_ZERO_SP_OFFSET));
        buf.emit(strImm(9, 16, Vm.BCPIN_SP_PTR_OFFSET));
        // pin.parent = vm.bc_pin
        buf.emit(ldrImm(9, 19, Vm.VM_BC_PIN_OFFSET));
        buf.emit(strImm(9, 16, Vm.BCPIN_PARENT_OFFSET));
        // pin.saved_frame = vm.current_frame
        buf.emit(ldrImm(9, 19, Vm.VM_CURRENT_FRAME_OFFSET));
        buf.emit(strImm(9, 16, Vm.BCPIN_SAVED_FRAME_OFFSET));
        // pin.saved_method_frame = vm.current_method_frame
        buf.emit(ldrImm(9, 19, Vm.VM_CURRENT_METHOD_FRAME_OFFSET));
        buf.emit(strImm(9, 16, Vm.BCPIN_SAVED_METHOD_FRAME_OFFSET));
        // pin.saved_method_class = vm.current_method_class
        buf.emit(ldrImm(9, 19, Vm.VM_CURRENT_METHOD_CLASS_OFFSET));
        buf.emit(strImm(9, 16, Vm.BCPIN_SAVED_METHOD_CLASS_OFFSET));

        // ---- Init frame Header at x17 (= &frame_storage) ----
        // hdr.class = vm.globals.frame_class
        buf.emit(ldrImm(9, 19, Vm.VM_FRAME_CLASS_OFFSET));
        buf.emit(strImm(9, 17, 0));
        // hdr.size = stack_frame_slots; hdr.flags = 0. Both u32; a
        // single 64-bit store of the slot count (high 32 bits zero)
        // writes both fields in one instruction.
        buf.emit(movz(9, @intCast(stack_frame_slots), 0));
        buf.emit(strImm(9, 17, 8));

        // ---- Zero only the slots that won't be written below ----
        // We unconditionally write parent, source, self, and a0..a(N-1)
        // for arity N; everything else (temps + eval-stack) must be
        // NIL'd so the bytecode interpreter sees a clean local
        // environment and the GC sees no stale pointers.
        const init_count: u32 = object.FRAME_VALUES_OFFSET + 1 + params_count;
        var z: u32 = init_count;
        while (z < stack_frame_slots) : (z += 1) {
            buf.emit(strImm(31, 17, 16 + z * 8)); // str xzr, [x17, #...]
        }

        // ---- Fill the slots ----
        // frame[SLOT_FRAME_PARENT] = NIL: written explicitly so we
        // can skip its zeroing above.
        buf.emit(strImm(31, 17, 16 + object.SLOT_FRAME_PARENT * 8));
        // frame[SLOT_FRAME_SOURCE] = method (still in x1 from caller).
        buf.emit(strImm(1, 17, 16 + object.SLOT_FRAME_SOURCE * 8));
        // frame[FRAME_VALUES_OFFSET + 0] = receiver (x2).
        buf.emit(strImm(2, 17, 16 + object.FRAME_VALUES_OFFSET * 8));
        // frame[FRAME_VALUES_OFFSET + 1 + i] = args[i] from x(3+i).
        var pi: u32 = 0;
        while (pi < params_count and pi < 4) : (pi += 1) {
            const arg_reg: u5 = @intCast(3 + pi);
            buf.emit(strImm(arg_reg, 17, 16 + (object.FRAME_VALUES_OFFSET + 1 + pi) * 8));
        }

        // ---- Update vm.{bc_pin, current_frame, current_method_frame, current_method_class} ----
        buf.emit(strImm(16, 19, Vm.VM_BC_PIN_OFFSET));
        buf.emit(strImm(17, 19, Vm.VM_CURRENT_FRAME_OFFSET));
        buf.emit(strImm(17, 19, Vm.VM_CURRENT_METHOD_FRAME_OFFSET));
        // vm.current_method_class = method.SLOT_METHOD_DEFINING_CLASS
        buf.emit(ldrImm(9, 1, 16 + object.SLOT_METHOD_DEFINING_CLASS * 8));
        buf.emit(strImm(9, 19, Vm.VM_CURRENT_METHOD_CLASS_OFFSET));

        // x20 = frame (= x17). Set early so the maybe-GC path can
        // overwrite it with the post-GC value loaded from
        // vm.current_frame; if no GC fires, x20 already holds the
        // correct address.
        buf.emit(movReg(20, 17));

        // ---- Inline maybe-GC ----
        // if (heap.used > heap.gc_threshold) vm_jit_collect(vm).
        // Forward branch over the GC-call when used <= threshold.
        buf.emit(ldrImm(9, 19, Vm.VM_HEAP_OFFSET));
        buf.emit(ldrImm(10, 9, Vm.HEAP_USED_OFFSET));
        buf.emit(ldrImm(11, 9, Vm.HEAP_GC_THRESHOLD_OFFSET));
        buf.emit(cmpReg(10, 11));
        const skip_gc_off: u32 = @intCast(buf.pos);
        buf.emit(bCond(.ls, 0)); // patched to past_gc

        // GC slow path.
        buf.emit(movReg(0, 19)); // x0 = vm
        movImm64(buf, 9, collect_addr);
        buf.emit(blr(9));
        // jit_error check.
        buf.emit(ldrImm(9, 19, Vm.VM_JIT_ERROR_OFFSET));
        const gc_err_off: u32 = @intCast(buf.pos);
        buf.emit(cbnz(9, 0));
        if (n_error_sites < error_sites.len) {
            error_sites[n_error_sites] = gc_err_off;
            n_error_sites += 1;
        }
        // Frame doesn't move (it's on our native stack), but
        // vm.current_frame may have been overwritten if anything
        // re-entered. Reload x20 from the canonical slot.
        buf.emit(ldrImm(20, 19, Vm.VM_CURRENT_FRAME_OFFSET));

        // past_gc:
        const past_gc_off: u32 = @intCast(buf.pos);
        patchBranch19(buf, skip_gc_off, past_gc_off);
    } else {
        // Heap-frame path: vm_jit_method_enter takes (vm, method,
        // recv, a0, a1, a2, a3, pin). x0..x6 already match; pin
        // goes in x7.
        buf.emit(addSpToReg(7, 0));
        movImm64(buf, 9, enter_addr);
        buf.emit(blr(9));
        // x0 = frame oop, or NIL on alloc failure.
        const enter_err_off: u32 = @intCast(buf.pos);
        buf.emit(cbz(0, 0));
        if (n_error_sites < error_sites.len) {
            error_sites[n_error_sites] = enter_err_off;
            n_error_sites += 1;
        }
        buf.emit(movReg(20, 0));
    }

    // ---- Body ----
    // Tracks the JIT byte offset where each bytecode instruction's
    // emission begins. Used to resolve backward jumps immediately
    // and forward jumps via patch.
    var instr_offsets: [MAX_BYTECODE_INSTRS]u32 = undefined;
    // Pending forward-jump patches: native instr offset + target
    // bytecode-instr index. Resolved after body emission.
    const ForwardPatch = struct {
        jit_off: u32,
        target_instr: u32,
        kind: enum { b26, b14_tbz, b14_tbnz },
    };
    var forward_patches: [256]ForwardPatch = undefined;
    var n_forward_patches: u32 = 0;
    const n_instrs: u32 = @intCast(code_bytes.len / 4);
    var i: u32 = 0;
    var saw_return = false;
    const g = &vm.globals;
    var depth: u32 = 0;

    // v4.C tag tracking: per-eval-stack-reg and per-local "is this
    // value a tagged SmallInt right now?" Initialized so values[0]
    // (self) reflects the defining-class hint, and all other locals
    // default to Unknown. Mutated as opcodes execute; reset at jump
    // targets (eval-stack always; locals only when they're stored
    // somewhere in this method).
    var stack_is_int: [16]bool = undefined;
    {
        var z: u32 = 0;
        while (z < stack_is_int.len) : (z += 1) stack_is_int[z] = false;
    }
    var local_is_int: [256]bool = undefined;
    {
        var z: u32 = 0;
        while (z < local_is_int.len) : (z += 1) local_is_int[z] = false;
    }
    local_is_int[0] = self_is_int;

    // v4.I.1 — register cache for locals (counters for which slots
    // get cache regs were computed before the prologue; here we
    // initialise the per-local validity bits and assign actual reg
    // numbers).
    var local_reg: [256]?u5 = .{null} ** 256;
    var local_cache_valid: [256]bool = .{false} ** 256;
    {
        var li: u32 = 0;
        while (li < n_cached_locals) : (li += 1) {
            local_reg[li] = @intCast(22 + li); // x22..x28
        }
    }

    // v4.I.2 — eval-stack register map. Each depth maps to the reg
    // currently holding that eval-stack value. By default
    // eval_reg_at[d] = 9 + d (the canonical caller-saved scratch).
    // PUSH_LOCAL with a cache hit aliases this to the local's cache
    // reg directly (no mov emitted) so subsequent ops can read the
    // local's value without an intermediate copy. The map resets to
    // canonical at each jump target and after every SEND consume
    // (the SEND writes its result back to the canonical reg).
    var eval_reg_at: [16]u5 = undefined;
    {
        var d: u32 = 0;
        while (d < eval_reg_at.len) : (d += 1) eval_reg_at[d] = @intCast(9 + d);
    }

    while (i < n_instrs) : (i += 1) {
        // Skip unreachable instructions (e.g., dead code after a
        // backward unconditional jump).
        if (depth_at[i] < 0) continue;
        depth = @intCast(depth_at[i]);
        instr_offsets[i] = @intCast(buf.pos);

        // Reset eval-stack and any "could-be-stored" locals at jump
        // targets — we don't track per-edge dataflow, so the merge
        // is conservative.
        if (is_jump_target[i]) {
            var z: u32 = 0;
            while (z < stack_is_int.len) : (z += 1) stack_is_int[z] = false;
            var lz: u32 = 0;
            while (lz < local_is_int.len) : (lz += 1) {
                if (local_was_stored[lz]) local_is_int[lz] = false;
            }
            // v4.I.1 — at a jump target, control may arrive from a
            // backedge whose path included a SEND that fired GC.
            // Conservatively invalidate the cache so the first
            // push_local in the new block reloads from slot.
            var ci: u32 = 0;
            while (ci < local_cache_valid.len) : (ci += 1) local_cache_valid[ci] = false;
            // v4.I.2 — also re-canonicalise the eval-stack reg map.
            // Different paths into this block may have aliased
            // eval-stack values to different regs; the conservative
            // merge restores the canonical assignment.
            var ri: u32 = 0;
            while (ri < eval_reg_at.len) : (ri += 1) eval_reg_at[ri] = @intCast(9 + ri);
        }
        const ins = std.mem.readInt(u32, code_bytes[i * 4 ..][0..4], .little);
        const op = bc.opOf(ins);
        switch (op) {
            .push_lit => {
                const dst: u5 = @intCast(9 + depth);
                const lit_idx = bc.operandOf(ins);
                buf.emit(ldrImm(dst, 20, slotByteOffset(object.SLOT_FRAME_SOURCE)));
                buf.emit(ldrImm(dst, dst, slotByteOffset(object.SLOT_METHOD_LITERALS)));
                buf.emit(ldrImm(dst, dst, slotByteOffset(lit_idx)));
                eval_reg_at[depth] = dst;
                stack_is_int[depth] = oop_mod.isInt(object.slot(lits, lit_idx));
                depth += 1;
            },
            .push_self => {
                // v4.I.2 — on cache hit, alias the eval-stack reg to
                // the local's cache reg directly. No mov emitted.
                // Subsequent consumers read via eval_reg_at, which
                // points at x_cache. The SEND emit's result writes
                // back to the canonical reg, never to x_cache, so
                // x_cache is preserved through the SEND.
                if (local_reg[0]) |cached| {
                    if (local_cache_valid[0]) {
                        eval_reg_at[depth] = cached;
                    } else {
                        const dst: u5 = @intCast(9 + depth);
                        buf.emit(ldrImm(dst, 20, slotByteOffset(object.FRAME_VALUES_OFFSET + 0)));
                        buf.emit(movReg(cached, dst));
                        local_cache_valid[0] = true;
                        eval_reg_at[depth] = dst;
                    }
                } else {
                    const dst: u5 = @intCast(9 + depth);
                    buf.emit(ldrImm(dst, 20, slotByteOffset(object.FRAME_VALUES_OFFSET + 0)));
                    eval_reg_at[depth] = dst;
                }
                stack_is_int[depth] = local_is_int[0];
                depth += 1;
            },
            .push_local => {
                const idx = bc.operandOf(ins);
                if (idx < local_reg.len and local_reg[idx] != null and local_cache_valid[idx]) {
                    eval_reg_at[depth] = local_reg[idx].?;
                } else if (idx < local_reg.len and local_reg[idx] != null) {
                    const dst: u5 = @intCast(9 + depth);
                    buf.emit(ldrImm(dst, 20, slotByteOffset(object.FRAME_VALUES_OFFSET + idx)));
                    buf.emit(movReg(local_reg[idx].?, dst));
                    local_cache_valid[idx] = true;
                    eval_reg_at[depth] = dst;
                } else {
                    const dst: u5 = @intCast(9 + depth);
                    buf.emit(ldrImm(dst, 20, slotByteOffset(object.FRAME_VALUES_OFFSET + idx)));
                    eval_reg_at[depth] = dst;
                }
                stack_is_int[depth] = if (idx < local_is_int.len) local_is_int[idx] else false;
                depth += 1;
            },
            .push_nil => {
                const dst: u5 = @intCast(9 + depth);
                buf.emit(movz(dst, oop_mod.NIL, 0));
                eval_reg_at[depth] = dst;
                stack_is_int[depth] = false;
                depth += 1;
            },
            .push_true => {
                const dst: u5 = @intCast(9 + depth);
                buf.emit(movz(dst, oop_mod.TRUE, 0));
                eval_reg_at[depth] = dst;
                stack_is_int[depth] = false;
                depth += 1;
            },
            .push_false => {
                const dst: u5 = @intCast(9 + depth);
                buf.emit(movz(dst, oop_mod.FALSE, 0));
                eval_reg_at[depth] = dst;
                stack_is_int[depth] = false;
                depth += 1;
            },
            .push_global => {
                // Spill survivors before the helper call (it may
                // fire GC). Then load the symbol from the literal
                // pool, marshal (vm, sym) into x0/x1, BL the helper.
                const lit_idx = bc.operandOf(ins);
                var spill_i: u32 = 0;
                while (spill_i < depth) : (spill_i += 1) {
                    buf.emit(strImm(eval_reg_at[spill_i], 20, slotByteOffset(eval_base_slot + spill_i)));
                }
                buf.emit(movReg(0, 19));
                buf.emit(ldrImm(1, 20, slotByteOffset(object.SLOT_FRAME_SOURCE)));
                buf.emit(ldrImm(1, 1, slotByteOffset(object.SLOT_METHOD_LITERALS)));
                buf.emit(ldrImm(1, 1, slotByteOffset(lit_idx)));
                const lookup_addr: u64 = @intFromPtr(&Vm.vm_jit_lookup_global);
                movImm64(buf, 9, lookup_addr);
                buf.emit(blr(9));
                // Check error.
                buf.emit(ldrImm(9, 19, Vm.VM_JIT_ERROR_OFFSET));
                const err_off: u32 = @intCast(buf.pos);
                buf.emit(cbnz(9, 0));
                if (n_error_sites < error_sites.len) {
                    error_sites[n_error_sites] = err_off;
                    n_error_sites += 1;
                }
                // Reload x20 (frame may have moved if GC fired) and
                // re-canonicalise eval-stack regs from slots.
                buf.emit(ldrImm(20, 19, Vm.VM_CURRENT_FRAME_OFFSET));
                var rl: u32 = 0;
                while (rl < depth) : (rl += 1) {
                    buf.emit(ldrImm(@intCast(9 + rl), 20, slotByteOffset(eval_base_slot + rl)));
                    eval_reg_at[rl] = @intCast(9 + rl);
                }
                // Result is in x0; mov to canonical TOS.
                const dst: u5 = @intCast(9 + depth);
                if (dst != 0) buf.emit(movReg(dst, 0));
                eval_reg_at[depth] = dst;
                stack_is_int[depth] = false;
                // Local cache may have heap pointers; the helper
                // could have fired GC.
                {
                    var ci: u32 = 0;
                    while (ci < local_cache_valid.len) : (ci += 1) local_cache_valid[ci] = false;
                }
                depth += 1;
            },
            .pop => {
                depth -= 1;
            },
            .store_local => {
                // Peek TOS reg via eval_reg_at; depth unchanged.
                const src: u5 = eval_reg_at[depth - 1];
                const idx = bc.operandOf(ins);
                buf.emit(strImm(src, 20, slotByteOffset(object.FRAME_VALUES_OFFSET + idx)));
                if (idx < local_reg.len) {
                    if (local_reg[idx]) |cached| {
                        if (cached != src) buf.emit(movReg(cached, src));
                        local_cache_valid[idx] = true;
                    }
                }
                if (idx < local_is_int.len) local_is_int[idx] = stack_is_int[depth - 1];
            },
            .send => {
                const arity_u8 = bc.sendArityOf(ins);
                const arity: u32 = arity_u8;
                const sel_idx_u16 = bc.sendSelOf(ins);
                const sel_idx: u32 = sel_idx_u16;
                const sel = object.slot(lits, sel_idx);
                const new_depth: u32 = depth - arity;
                // Operand regs come from the eval-stack alias map —
                // they may be the canonical x(9+d) or a cached
                // local's reg if the most recent push_local aliased.
                const recv_reg: u5 = eval_reg_at[depth - arity - 1];
                const arg_reg: u5 = if (arity > 0) eval_reg_at[depth - 1] else 0;
                // The result destination is always the canonical reg
                // for the post-pop TOS, so we never clobber a cached
                // local's reg even when its value was used as recv.
                const result_reg: u5 = @intCast(9 + depth - arity - 1);
                // x16 (IP0) is the universal fast-path scratch; eval-stack
                // regalloc only goes up to x15, so x16 is always free.
                const SCRATCH: u5 = 16;

                // Detect SmallInt fast-path opportunity.
                var fast: ?FastOp = null;
                if (arity == 1) {
                    if (sel == g.sym_plus) fast = .add
                    else if (sel == g.sym_minus) fast = .sub
                    else if (sel == g.sym_lt) fast = .lt
                    else if (sel == g.sym_le) fast = .le
                    else if (sel == g.sym_gt) fast = .gt
                    else if (sel == g.sym_ge) fast = .ge;
                }

                var join_branch_off: u32 = 0;
                var have_join = false;

                // Survivors at indices [0, depth-arity-2] may be
                // aliased to a cached-local register (e.g. push_self
                // aliasing eval_reg_at[d] to x22) without ever having
                // been written to their canonical x(9+d) reg. The
                // post-SEND recanonicalisation below blindly resets
                // eval_reg_at[ri] = 9+ri, so on the FAST PATH (which
                // skips the slow path's spill-to-slot + reload-from-
                // slot) the canonical reg silently holds whatever
                // some earlier opcode happened to leave there. Force
                // each aliased survivor into its canonical reg now
                // so the post-SEND map matches reality on both paths.
                {
                    var si: u32 = 0;
                    while (si + arity + 1 < depth) : (si += 1) {
                        const canon: u5 = @intCast(9 + si);
                        if (eval_reg_at[si] != canon) {
                            buf.emit(movReg(canon, eval_reg_at[si]));
                            eval_reg_at[si] = canon;
                        }
                    }
                }

                if (fast) |fop| {
                    // Fast path: operands already in regs (x_recv,
                    // x_arg). When both are statically known to be
                    // SmallInt, skip the inline tag check entirely;
                    // otherwise emit the `and+tbz` guard. Result
                    // overwrites x_recv on success; failure falls
                    // through to the spill block (recv/arg untouched
                    // — intermediates write to x16).
                    const both_int = stack_is_int[depth - 1] and stack_is_int[depth - 2];
                    var tbz_off: u32 = 0;
                    var have_tag_check = false;
                    if (!both_int) {
                        buf.emit(andReg(SCRATCH, recv_reg, arg_reg));
                        tbz_off = @intCast(buf.pos);
                        buf.emit(tbz(SCRATCH, 0, 0));
                        have_tag_check = true;
                    }

                    switch (fop) {
                        .add => {
                            buf.emit(addsReg(SCRATCH, recv_reg, arg_reg));
                            const bvs_off: u32 = @intCast(buf.pos);
                            buf.emit(bCond(.vs, 0));
                            buf.emit(subImm(result_reg, SCRATCH, 1));
                            const bafter_off: u32 = @intCast(buf.pos);
                            buf.emit(bUncond(0));
                            const slow_off: u32 = @intCast(buf.pos);
                            if (have_tag_check) patchBranch14(buf, tbz_off, slow_off);
                            patchBranch19(buf, bvs_off, slow_off);
                            join_branch_off = bafter_off;
                            have_join = true;
                        },
                        .sub => {
                            buf.emit(subsReg(SCRATCH, recv_reg, arg_reg));
                            const bvs_off: u32 = @intCast(buf.pos);
                            buf.emit(bCond(.vs, 0));
                            buf.emit(addImm(result_reg, SCRATCH, 1));
                            const bafter_off: u32 = @intCast(buf.pos);
                            buf.emit(bUncond(0));
                            const slow_off: u32 = @intCast(buf.pos);
                            if (have_tag_check) patchBranch14(buf, tbz_off, slow_off);
                            patchBranch19(buf, bvs_off, slow_off);
                            join_branch_off = bafter_off;
                            have_join = true;
                        },
                        .lt, .le, .gt, .ge => {
                            buf.emit(cmpReg(recv_reg, arg_reg));
                            const cond: Cond = switch (fop) {
                                .lt => .lt,
                                .le => .le,
                                .gt => .gt,
                                .ge => .ge,
                                else => unreachable,
                            };
                            buf.emit(cset(SCRATCH, cond));
                            buf.emit(lslImm(SCRATCH, SCRATCH, 1));
                            buf.emit(addImm(result_reg, SCRATCH, 2));
                            const bafter_off: u32 = @intCast(buf.pos);
                            buf.emit(bUncond(0));
                            const slow_off: u32 = @intCast(buf.pos);
                            if (have_tag_check) patchBranch14(buf, tbz_off, slow_off);
                            join_branch_off = bafter_off;
                            have_join = true;
                        },
                    }
                }

                // ---- Slow path entry ----
                // Under the args-in-regs ABI, recv lives in x_recv and
                // args in x(arg_reg+i). We don't spill them on the hit
                // path: emitGenericSend's hit code marshals straight
                // from these regs into x2..x6, and the BL clobbers
                // them on its way out (their lifetimes end at the
                // call). The miss path spills recv/args inside its
                // own block since the helper expects an args pointer.
                //
                // Survivors — values below recv on the eval stack
                // that this SEND doesn't consume — DO need to be
                // spilled so they survive the BLR. caller-saved
                // x9..x15 are clobbered by the call.
                // Spill survivors using their CURRENT regs (which
                // may be aliased local-cache regs after v4.I.2's
                // push_local aliasing). The slot they spill to stays
                // canonical so the GC root walker sees them.
                var spill_i: u32 = 0;
                while (spill_i + arity + 1 < depth) : (spill_i += 1) {
                    buf.emit(strImm(eval_reg_at[spill_i], 20, slotByteOffset(eval_base_slot + spill_i)));
                }

                var arg_regs_buf: [4]u5 = undefined;
                var ari: u32 = 0;
                while (ari < arity) : (ari += 1) {
                    arg_regs_buf[ari] = eval_reg_at[depth - arity + ari];
                }
                const arg_regs = arg_regs_buf[0..arity];

                const recv_slot = eval_base_slot + depth - arity - 1;
                emitGenericSend(buf, vm, sel_idx, recv_reg, arg_regs, recv_slot, send_addr,
                    &error_sites, &n_error_sites);

                // Result is in x0; mov to the canonical post-pop TOS
                // reg. Then re-canonicalise eval_reg_at so subsequent
                // ops see the standard layout.
                const result_reg_after: u5 = @intCast(9 + depth - arity - 1);
                if (result_reg_after != 0) buf.emit(movReg(result_reg_after, 0));

                // Reload survivors back into their canonical regs.
                var rl: u32 = 0;
                while (rl + 1 < new_depth) : (rl += 1) {
                    buf.emit(ldrImm(@intCast(9 + rl), 20, slotByteOffset(eval_base_slot + rl)));
                }
                // Re-canonicalise eval_reg_at across the surviving stack.
                {
                    var ri: u32 = 0;
                    while (ri < new_depth) : (ri += 1) eval_reg_at[ri] = @intCast(9 + ri);
                }

                if (have_join) {
                    const after_off: u32 = @intCast(buf.pos);
                    patchBranch26(buf, join_branch_off, after_off);
                }

                depth -= arity;
                // Result type after a SEND is conservatively Unknown:
                // even an arith fast-path's overflow falls through to
                // the slow path and that result could be LargeInteger.
                stack_is_int[depth - 1] = false;
                // v4.I.1 — invalidate the local register cache. The
                // SEND's slow path can fire GC, which would relocate
                // any heap-pointer locals; the frame slot is updated
                // by the GC root walker but the cache reg is stale.
                // Fast-path arith doesn't fire GC, so for sum/count's
                // tight all-arith loops this branch is unreachable in
                // practice and the next push_local hits the cache
                // again. (More precise tracking — only invalidate
                // when the SEND went through the slow path — would
                // need per-edge dataflow at the join.)
                {
                    var ci: u32 = 0;
                    while (ci < local_cache_valid.len) : (ci += 1) local_cache_valid[ci] = false;
                }
            },
            .return_top => {
                // Save TOS to x21 (callee-saved) and branch to the
                // shared leave/restore epilogue.
                buf.emit(movReg(21, eval_reg_at[depth - 1]));
                const ret_jump_off: u32 = @intCast(buf.pos);
                buf.emit(bUncond(0));
                if (n_forward_patches < forward_patches.len) {
                    forward_patches[n_forward_patches] = .{
                        .jit_off = ret_jump_off,
                        .target_instr = std.math.maxInt(u32), // sentinel: epilogue
                        .kind = .b26,
                    };
                    n_forward_patches += 1;
                }
                saw_return = true;
            },
            .jump => {
                const off = bc.signedOperandOf(ins);
                const target: u32 = @intCast(@as(i32, @intCast(i)) + 1 + off);
                if (target <= i) {
                    // Backward — fully resolved.
                    const from_byte: i32 = @intCast(buf.pos);
                    const to_byte: i32 = @intCast(instr_offsets[target]);
                    buf.emit(bUncond(to_byte - from_byte));
                } else {
                    const jp: u32 = @intCast(buf.pos);
                    buf.emit(bUncond(0));
                    if (n_forward_patches < forward_patches.len) {
                        forward_patches[n_forward_patches] = .{
                            .jit_off = jp,
                            .target_instr = target,
                            .kind = .b26,
                        };
                        n_forward_patches += 1;
                    }
                }
            },
            .jump_if_false => {
                const top_reg: u5 = eval_reg_at[depth - 1];
                const off = bc.signedOperandOf(ins);
                const target: u32 = @intCast(@as(i32, @intCast(i)) + 1 + off);
                if (target <= i) {
                    const from_byte: i32 = @intCast(buf.pos);
                    const to_byte: i32 = @intCast(instr_offsets[target]);
                    buf.emit(tbz(top_reg, 2, to_byte - from_byte));
                } else {
                    const jp: u32 = @intCast(buf.pos);
                    buf.emit(tbz(top_reg, 2, 0));
                    if (n_forward_patches < forward_patches.len) {
                        forward_patches[n_forward_patches] = .{
                            .jit_off = jp,
                            .target_instr = target,
                            .kind = .b14_tbz,
                        };
                        n_forward_patches += 1;
                    }
                }
            },
            .jump_if_true => {
                const top_reg: u5 = eval_reg_at[depth - 1];
                const off = bc.signedOperandOf(ins);
                const target: u32 = @intCast(@as(i32, @intCast(i)) + 1 + off);
                if (target <= i) {
                    const from_byte: i32 = @intCast(buf.pos);
                    const to_byte: i32 = @intCast(instr_offsets[target]);
                    buf.emit(tbnz(top_reg, 2, to_byte - from_byte));
                } else {
                    const jp: u32 = @intCast(buf.pos);
                    buf.emit(tbnz(top_reg, 2, 0));
                    if (n_forward_patches < forward_patches.len) {
                        forward_patches[n_forward_patches] = .{
                            .jit_off = jp,
                            .target_instr = target,
                            .kind = .b14_tbnz,
                        };
                        n_forward_patches += 1;
                    }
                }
            },
            else => {
                // Should be unreachable since analyseSupportedAndDepth
                // would have returned null. But guard defensively.
                buf.markExecutable();
                return null;
            },
        }
    }
    if (!saw_return) {
        // Fall-through: return self. Load values[0] into x21.
        buf.emit(ldrImm(21, 20, slotByteOffset(object.FRAME_VALUES_OFFSET + 0)));
    }

    // Resolve all forward jumps. Targets that point at a bytecode
    // instr index land at instr_offsets[idx]; the sentinel
    // maxInt(u32) means "epilogue" — patched after we know its
    // location.
    const skip_err_off: u32 = @intCast(buf.pos);
    buf.emit(bUncond(0));
    const err_label_off: u32 = @intCast(buf.pos);
    buf.emit(movz(21, 0, 0)); // x21 = NIL on error
    const epilogue_off: u32 = @intCast(buf.pos);
    patchBranch26(buf, skip_err_off, epilogue_off);

    var fpi: u32 = 0;
    while (fpi < n_forward_patches) : (fpi += 1) {
        const fp = forward_patches[fpi];
        const target_byte: u32 = if (fp.target_instr == std.math.maxInt(u32))
            epilogue_off
        else
            instr_offsets[fp.target_instr];
        switch (fp.kind) {
            .b26 => patchBranch26(buf, fp.jit_off, target_byte),
            .b14_tbz, .b14_tbnz => patchBranch14(buf, fp.jit_off, target_byte),
        }
    }

    // Patch every error_check cbnz to land at err_label_off.
    var pi: u32 = 0;
    while (pi < n_error_sites) : (pi += 1) {
        patchBranch19(buf, error_sites[pi], err_label_off);
    }

    // ---- Epilogue ----
    // Inlined vm_jit_method_leave: copy pin.{parent,saved_*} back
    // into vm.{bc_pin,current_*}. Saves a movImm64 + blr + 4-instr
    // helper body per return.
    // x1 = &pin (pin lives above the frame storage on stack-eligible
    // methods; at sp+0 otherwise — same shape as the prologue).
    if (stack_eligible) {
        buf.emit(addSpToReg(1, stack_frame_bytes));
    } else {
        buf.emit(addSpToReg(1, 0));
    }
    buf.emit(ldrImm(9, 1, Vm.BCPIN_PARENT_OFFSET));
    buf.emit(strImm(9, 19, Vm.VM_BC_PIN_OFFSET));
    buf.emit(ldrImm(9, 1, Vm.BCPIN_SAVED_FRAME_OFFSET));
    buf.emit(strImm(9, 19, Vm.VM_CURRENT_FRAME_OFFSET));
    buf.emit(ldrImm(9, 1, Vm.BCPIN_SAVED_METHOD_FRAME_OFFSET));
    buf.emit(strImm(9, 19, Vm.VM_CURRENT_METHOD_FRAME_OFFSET));
    buf.emit(ldrImm(9, 1, Vm.BCPIN_SAVED_METHOD_CLASS_OFFSET));
    buf.emit(strImm(9, 19, Vm.VM_CURRENT_METHOD_CLASS_OFFSET));
    buf.emit(movReg(0, 21));         // x0 = result

    // Restore stack and return. Must match the prologue's sub sp.
    buf.emit(addSpImm(total_sp_reserve));
    // Restore local-cache callee-saves in reverse order of save.
    if (n_cached_locals >= 6) buf.emit(ldpPost(27, 28, 31, 16));
    if (n_cached_locals >= 4) buf.emit(ldpPost(25, 26, 31, 16));
    if (n_cached_locals >= 2) buf.emit(ldpPost(23, 24, 31, 16));
    buf.emit(ldpPost(21, 22, 31, 16));
    buf.emit(ldpPost(19, 20, 31, 16));
    buf.emit(ldpPost(29, 30, 31, 16));
    buf.emit(ret());

    buf.markExecutable();
    return .{ .offset = offset, .max_depth = max_depth };
}

// ---- tests ----

test "JIT a function that returns 42" {
    var buf = try JitBuf.alloc(4096);
    defer buf.deinit();

    buf.markWritable();
    movImm64(&buf, 0, 42);
    buf.emit(ret());
    buf.markExecutable();

    const Fn = *const fn () callconv(.c) u64;
    const f: Fn = @ptrCast(@alignCast(buf.entry()));
    try std.testing.expectEqual(@as(u64, 42), f());
}

test "JIT a function that returns a 64-bit immediate" {
    var buf = try JitBuf.alloc(4096);
    defer buf.deinit();

    buf.markWritable();
    movImm64(&buf, 0, 0x1234_5678_9abc_def0);
    buf.emit(ret());
    buf.markExecutable();

    const Fn = *const fn () callconv(.c) u64;
    const f: Fn = @ptrCast(@alignCast(buf.entry()));
    try std.testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), f());
}
