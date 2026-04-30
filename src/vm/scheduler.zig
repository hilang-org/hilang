// Cooperative context-switching primitives for green-thread support.
// One-process / one-stack / one-Context per Smalltalk Process. Built
// for AArch64 only; ports come later.
//
// What lives here:
//   * `Context`  — a saved set of AArch64 callee-saved registers
//                  (x19-x28, fp/lr, sp, d8-d15). Layout matches the
//                  asm in `swap` byte-for-byte.
//   * `swap`     — a naked function that stores callee-saved state
//                  into one Context, loads it from another, and
//                  returns into the new context. After it returns,
//                  the caller is executing on the new stack.
//   * `Stack`    — an mmap'd anonymous region used as a Process's
//                  native stack. 16-byte aligned top, AArch64 PCS.
//   * `prepare`  — first-time setup: positions a Context so its
//                  initial `swap`-in lands in a user-supplied `entry`
//                  function with a single `arg` pointer.
//
// What does NOT live here yet (next commit): the scheduler that
// picks which Process runs next, the fork/yield/wait integration,
// and the GC walk over suspended-process stacks.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("scheduler.zig is AArch64-only for now");
    }
}

/// Saved AArch64 callee-saved register state. The AArch64 PCS says
/// the *caller* preserves x0-x18 across calls, so cooperative
/// switching only needs to save the callee-saved set: x19-x28, fp
/// (x29), lr (x30), sp, and the low half of v8-v15 (d8-d15).
///
/// Total size: 21 u64 = 168 bytes. The byte offsets the asm uses
/// must stay in lock-step with this declaration order.
pub const Context = extern struct {
    x19: u64 = 0, // [  0]
    x20: u64 = 0,
    x21: u64 = 0, // [ 16]
    x22: u64 = 0,
    x23: u64 = 0, // [ 32]
    x24: u64 = 0,
    x25: u64 = 0, // [ 48]
    x26: u64 = 0,
    x27: u64 = 0, // [ 64]
    x28: u64 = 0,
    fp: u64 = 0, // [ 80] x29
    lr: u64 = 0, //       x30 (return address)
    sp: u64 = 0, // [ 96]
    d8: u64 = 0, // [104]
    d9: u64 = 0,
    d10: u64 = 0, // [120]
    d11: u64 = 0,
    d12: u64 = 0, // [136]
    d13: u64 = 0,
    d14: u64 = 0, // [152]
    d15: u64 = 0,
};

comptime {
    if (@sizeOf(Context) != 168) {
        @compileError("Context layout drift — asm offsets in swap are hard-coded");
    }
}

/// Save current execution state into `old_ctx`, load it from
/// `new_ctx`, and return into the new context. After this returns,
/// the caller is running on the stack that `new_ctx.sp` points at,
/// with the callee-saved register state `new_ctx` was prepared with,
/// and execution continues at `new_ctx.lr`.
///
/// The first time a freshly-prepared Context is swapped *into*, its
/// `lr` points at the trampoline below, which dispatches into the
/// user-supplied entry function.
// Standard Zig coroutine pattern: `pub extern fn` declares the
// symbol for callers; the body lives in top-level `asm()` so the
// compiler can never inline, decorate, or otherwise reshape it.
// Inline-asm-inside-naked-fn forms ran into ReleaseFast issues
// (PAC signing of an LR we then restore against the wrong SP, or
// the optimizer interleaving body around a Zig-generated frame),
// hence this extra layer.
//
// Mach-O symbols take a leading underscore; `extern fn swap`
// references `_swap`, which is the label below.
pub extern fn swap(old_ctx: *Context, new_ctx: *Context) void;

comptime {
    asm (
        \\ .global _swap
        \\ .p2align 2
        \\ _swap:
        \\   stp x19, x20, [x0,  #0]
        \\   stp x21, x22, [x0, #16]
        \\   stp x23, x24, [x0, #32]
        \\   stp x25, x26, [x0, #48]
        \\   stp x27, x28, [x0, #64]
        \\   stp x29, x30, [x0, #80]
        \\   mov x9, sp
        \\   str x9,       [x0, #96]
        \\   stp d8,  d9,  [x0, #104]
        \\   stp d10, d11, [x0, #120]
        \\   stp d12, d13, [x0, #136]
        \\   stp d14, d15, [x0, #152]
        \\
        \\   ldp x19, x20, [x1,  #0]
        \\   ldp x21, x22, [x1, #16]
        \\   ldp x23, x24, [x1, #32]
        \\   ldp x25, x26, [x1, #48]
        \\   ldp x27, x28, [x1, #64]
        \\   ldp x29, x30, [x1, #80]
        \\   ldr x9,       [x1, #96]
        \\   mov sp, x9
        \\   ldp d8,  d9,  [x1, #104]
        \\   ldp d10, d11, [x1, #120]
        \\   ldp d12, d13, [x1, #136]
        \\   ldp d14, d15, [x1, #152]
        \\   ret
    );
}

/// First-time entry trampoline. When a freshly-`prepare`d Context
/// is swapped into, its `lr` lands here. We move the user-supplied
/// `arg` (parked in x19 by `prepare`) into the AArch64 first-arg
/// register x0, then jump into the entry function (parked in x20).
/// The entry function is `noreturn`; if it ever does return, we
/// trap.
fn trampoline() callconv(.naked) noreturn {
    asm volatile (
        \\ mov x0, x19
        \\ blr x20
        \\ brk #0
    );
}

/// An mmap'd anonymous region used as a Process's native stack.
/// `base` is the slice as returned by mmap; `top()` returns the
/// initial 16-byte-aligned SP value (AArch64 requires 16-byte SP).
pub const Stack = struct {
    base: []align(std.heap.page_size_min) u8,

    pub fn alloc(size_bytes: usize) !Stack {
        const total = std.mem.alignForward(usize, size_bytes, std.heap.page_size_min);
        const mem = try std.posix.mmap(
            null,
            total,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        return .{ .base = mem };
    }

    pub fn free(self: Stack) void {
        std.posix.munmap(self.base);
    }

    /// Initial SP value: top of the region, rounded down to 16.
    pub fn top(self: Stack) u64 {
        const t = @intFromPtr(self.base.ptr) + self.base.len;
        return t & ~@as(u64, 15);
    }
};

/// Set up `ctx` so that the first `swap`-into it transfers control
/// to `entry(arg)`, running on `stack`. `entry` is `noreturn` —
/// when its work is done it must `swap` back to a saved Context
/// (typically the scheduler's main one).
pub fn prepare(
    ctx: *Context,
    stack: Stack,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn,
    arg: ?*anyopaque,
) void {
    ctx.* = .{};
    ctx.sp = stack.top();
    ctx.x19 = @intFromPtr(arg);
    ctx.x20 = @intFromPtr(entry);
    ctx.lr = @intFromPtr(&trampoline);
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

const Probe = struct {
    main: *Context,
    side: *Context,
    counter: u32 = 0,
};

fn sideEntry(arg: ?*anyopaque) callconv(.c) noreturn {
    const probe: *Probe = @ptrCast(@alignCast(arg.?));
    probe.counter += 1;
    swap(probe.side, probe.main);
    // Re-entered after main swaps back in. Bump again, swap back.
    probe.counter += 10;
    swap(probe.side, probe.main);
    unreachable;
}

test "swap into a side context, run, swap back" {
    var main_ctx: Context = .{};
    var side_ctx: Context = .{};
    var stack = try Stack.alloc(64 * 1024);
    defer stack.free();

    var probe = Probe{ .main = &main_ctx, .side = &side_ctx };
    prepare(&side_ctx, stack, sideEntry, &probe);

    // First entry: counter goes 0 → 1, then we land back here.
    swap(&main_ctx, &side_ctx);
    try std.testing.expectEqual(@as(u32, 1), probe.counter);

    // Second entry: counter goes 1 → 11.
    swap(&main_ctx, &side_ctx);
    try std.testing.expectEqual(@as(u32, 11), probe.counter);
}

test "two side contexts, ping-pong" {
    var main_ctx: Context = .{};
    var a_ctx: Context = .{};
    var b_ctx: Context = .{};
    var a_stack = try Stack.alloc(64 * 1024);
    defer a_stack.free();
    var b_stack = try Stack.alloc(64 * 1024);
    defer b_stack.free();

    const Pong = struct {
        main: *Context,
        a: *Context,
        b: *Context,
        log: [16]u8 = undefined,
        len: usize = 0,
        fn write(self: *@This(), c: u8) void {
            self.log[self.len] = c;
            self.len += 1;
        }
    };

    const aEntry = struct {
        fn f(arg: ?*anyopaque) callconv(.c) noreturn {
            const p: *Pong = @ptrCast(@alignCast(arg.?));
            p.write('A');
            swap(p.a, p.b);
            p.write('A');
            swap(p.a, p.main);
            unreachable;
        }
    }.f;

    const bEntry = struct {
        fn f(arg: ?*anyopaque) callconv(.c) noreturn {
            const p: *Pong = @ptrCast(@alignCast(arg.?));
            p.write('B');
            swap(p.b, p.a);
            unreachable;
        }
    }.f;

    var p = Pong{ .main = &main_ctx, .a = &a_ctx, .b = &b_ctx };
    prepare(&a_ctx, a_stack, aEntry, &p);
    prepare(&b_ctx, b_stack, bEntry, &p);

    swap(&main_ctx, &a_ctx);
    try std.testing.expectEqualStrings("ABA", p.log[0..p.len]);
}

test "stack-local writes survive a round-trip swap" {
    var main_ctx: Context = .{};
    var side_ctx: Context = .{};
    var stack = try Stack.alloc(64 * 1024);
    defer stack.free();

    const Holder = struct {
        main: *Context,
        side: *Context,
        observed_first: u64 = 0,
        observed_second: u64 = 0,
    };

    const entry = struct {
        fn f(arg: ?*anyopaque) callconv(.c) noreturn {
            const h: *Holder = @ptrCast(@alignCast(arg.?));
            // A genuinely stack-resident local that must survive
            // being parked across a swap-out / swap-in cycle.
            var on_stack: [4]u64 = .{ 11, 22, 33, 44 };
            h.observed_first = on_stack[2]; // 33
            swap(h.side, h.main);
            on_stack[2] += 1;
            h.observed_second = on_stack[2]; // 34
            swap(h.side, h.main);
            unreachable;
        }
    }.f;

    var holder = Holder{ .main = &main_ctx, .side = &side_ctx };
    prepare(&side_ctx, stack, entry, &holder);

    swap(&main_ctx, &side_ctx);
    try std.testing.expectEqual(@as(u64, 33), holder.observed_first);

    swap(&main_ctx, &side_ctx);
    try std.testing.expectEqual(@as(u64, 34), holder.observed_second);
}
