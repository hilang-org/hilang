const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const ast = @import("ast.zig");
const dict = @import("dict.zig");
const method_mod = @import("method.zig");
const prims = @import("prims.zig");
const frame_mod = @import("frame.zig");
const class_mod = @import("class.zig");
const gc_mod = @import("gc.zig");
const scheduler_mod = @import("scheduler.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

pub const EvalError = error{
    OutOfMemory,
    NotImplemented,
    IntOverflow,
    UndefinedVariable,
    DictionaryFull,
    EmptySequence,
    DoesNotUnderstand,
    PrimitiveFailed,
    ArityMismatch,
    TypeError,
    UnknownPrimitive,
    TooManyArgs,
    InvalidReturn,
    UnknownNodeClass,
    // Control-flow signal raised by `ret`. Caught by the AST method
    // invocation site whose frame matches Vm.return_target. Re-thrown
    // otherwise.
    MethodReturn,
    // Smalltalk-level exception raised by Exception>>signal: or
    // ExceptionClass>>signal:. The in-flight exception object is in
    // Vm.signaled_exception. Caught by Block>>on:do: when the class
    // matches.
    UserSignal,
};

pub const OutputSink = struct {
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

// Walk a possibly-stack-allocated frame Oop and add each of its
// slots' addresses to the GC root list. Heap-resident frames are
// already covered by current_frame / pin saved_frame entries
// elsewhere; this only fires for addresses outside the heap region.
fn addStackFrameSlots(
    vm: *Vm,
    frame: Oop,
    heap_lo: u64,
    heap_hi: u64,
    n: *usize,
) !void {
    if (!oop_mod.isHeapPtr(frame)) return;
    if (frame >= heap_lo and frame < heap_hi) return; // heap frame: handled elsewhere.
    const hdr: *object.Header = @ptrFromInt(frame);
    const slots: [*]Oop = @ptrFromInt(frame + @sizeOf(object.Header));
    var i: u32 = 0;
    while (i < hdr.size) : (i += 1) {
        try vm.pushRoot(n, &slots[i]);
    }
}

// Linked-list of active runBytecode invocations. Each frame points
// at the bytecode-interpreter stack for one method/block-on-stack;
// collectGarbage walks the chain so stack[0..sp] entries become
// additional roots, letting GC fire safely between bytecode
// instructions. The `saved_*` fields are the Vm state to restore on
// return — they live in BcPin (not Zig defers) so GC can walk them
// and prevent staleness when the caller defers fire after a
// child-triggered GC.
pub const BcPin = struct {
    stack_base: [*]Oop,
    sp_ptr: *u32,
    parent: ?*BcPin,
    saved_frame: Oop,
    saved_method_frame: Oop,
    saved_method_class: Oop,
};

// Generic GC root pin for Zig-stack Oop locals that need to survive
// a potential GC. Push on the `Vm.root_pin` chain on entry, pop via
// defer. GC's collectGarbage walks the chain and treats each slot
// pointer as a root, so its target gets rewritten in place.
//
// This is the discipline for the Oop-locals audit: any Zig function
// that holds an Oop in a stack local across an operation that may
// allocate or recurse into the interpreter must pin those locals.
pub const RootPin = struct {
    parent: ?*RootPin,
    slots: [*]?*Oop,
    n: u32,
};

/// CLOCK_MONOTONIC value as nanoseconds since boot. Returned as i64
/// so it composes with deadline arithmetic and SmallInt encoding;
/// CLOCK_MONOTONIC fits in i64 for ~292 years post-boot. On clock
/// failure returns 0 so callers degrade to "deadline already passed"
/// rather than aborting the scheduler.
///
/// Zig 0.16 dropped the `std.posix.clock_gettime` wrapper in favour
/// of raw `std.posix.system.clock_gettime` bindings (see
/// std/Io/Threaded.zig:11431); we follow the same pattern.
pub fn monotonicNanos() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

/// Sleep for `delta_nanos` of wall time. Returns early on signal
/// interruption (rare in this VM) — the caller's expireSleepers
/// retry loop handles partial sleeps.
fn nanosleepFor(delta_nanos: i64) void {
    if (delta_nanos <= 0) return;
    var req: std.posix.timespec = .{
        .sec = @intCast(@divTrunc(delta_nanos, std.time.ns_per_s)),
        .nsec = @intCast(@mod(delta_nanos, std.time.ns_per_s)),
    };
    var rem: std.posix.timespec = undefined;
    _ = std.posix.system.nanosleep(&req, &rem);
}

pub const Vm = struct {
    heap: *Heap,
    globals: Globals = .{},
    output: ?OutputSink = null,
    current_frame: Oop = oop_mod.NIL,
    current_method_frame: Oop = oop_mod.NIL,
    current_method_class: Oop = oop_mod.NIL,
    return_value: Oop = oop_mod.NIL,
    return_target: Oop = oop_mod.NIL,
    // The in-flight exception object during a UserSignal unwind.
    signaled_exception: Oop = oop_mod.NIL,
    // Top of the bytecode-pin chain (Phase v3.B.1). NIL when no
    // bytecode method is on the stack.
    bc_pin: ?*BcPin = null,
    // Top of the generic root-pin chain. Used by Zig code paths
    // (AST eval, prims) that hold Oop locals across GC points.
    root_pin: ?*RootPin = null,
    // Instructions remaining before the bytecode interpreter checks
    // heap pressure and possibly runs GC. Shared across all
    // runBytecode invocations on the stack so deeply recursive calls
    // (where each method has < 64 instructions) still hit the check.
    bc_instr_budget: u32 = 256,
    // ARM64 JIT code buffer (Phase J). Lazily allocated on first
    // tier-up. Methods that compile to native store their entry as a
    // byte offset into this buffer; invokeMethod casts that offset to
    // a function pointer and calls it directly.
    jit_buf: ?@import("jit.zig").JitBuf = null,
    // Used by BcPins owned by JIT'd code: their sp_ptr points at this
    // always-zero u32 so collectGarbage's stack-walk loop is a no-op
    // (the JIT puts everything on the heap-resident frame; nothing
    // lives in the bc-pin's stack array).
    bc_jit_zero_sp: u32 = 0,
    // Out-of-band error channel for runtime helpers called from JIT
    // code. Zig errors don't unwind through `callconv(.c)` boundaries,
    // so vm_jit_send (and friends) catch them here. JIT'd functions
    // check this slot after every callout; a non-zero value (we use
    // the int representation of an EvalError tag) means the helper
    // failed and the JIT'd function must return early.
    jit_error: u64 = 0,
    // GC roots for the JIT'd inline cache. Each entry points at the
    // first quad (cached_class) of a 3-quad IC triple embedded in
    // JIT'd code. Held as a heap-allocated slice rather than an
    // inline array so:
    //   (1) the rest of Vm's fields stay at small offsets — the
    //       inline 32 KiB array used to push bc_jit_zero_sp's
    //       offset past the JIT's addImm imm12 ceiling, crashing
    //       debug builds the moment a hot bytecode method tiered up.
    //   (2) capacity grows with demand instead of being capped at
    //       a number the GC root buffer couldn't safely hold anyway.
    // Use `registerJitIcSlot` to add entries (handles the lazy
    // first-allocation and the realloc-on-grow).
    jit_ic_slots: []?[*]u64 = &.{},
    jit_ic_count: u32 = 0,

    // Heap-allocated root buffer reused across collects. Grown on
    // demand via ensureRootCapacity. Lives outside the stack so a
    // large root set (thousands of JIT IC slots) doesn't cost a
    // page-faulting stack frame on every collectGarbage call.
    gc_root_buf: []*Oop = &.{},

    // ── Concurrency ───────────────────────────────────────────────
    //
    // The currently-executing Smalltalk Process (a heap oop). NIL
    // before the first fork; after that always points at whichever
    // green thread we're running on right now. Mirrored into
    // Processor.activeProcess so user code can read it.
    current_process: Oop = oop_mod.NIL,
    // Owned mmap'd stacks for forked processes. The Vm keeps a
    // strong reference so they get munmap'd in `Vm.deinit` even if
    // the owning Process oop is GC'd. ArrayList rather than a free
    // list because process churn is low and bookkeeping cheaper.
    process_stacks: std.ArrayList(scheduler_mod.Stack) = .empty,
    // Every Process oop the Vm is responsible for (main + every
    // forked one). Each entry's slot address is pushed as a GC
    // root so the Process oop relocates; collectGarbage iterates
    // the list to walk every non-active Process's bc_pin chain
    // (their chains live on the suspended process's mmap stack,
    // outside heap range, so the standard slot walk doesn't see
    // them). Terminated processes stay in the list — their
    // ProcessState.bc_pin is zero, so the chain walk is a no-op.
    all_processes: std.ArrayList(Oop) = .empty,

    // Collect garbage. Roots are every Oop field on the Vm itself plus
    // the Smalltalk anchor in the heap header (the GC handles the
    // anchor). After return, any external Oops the caller is holding
    // are STALE — only Vm fields and slots reachable through them have
    // been updated.
    pub fn collectGarbage(self: *Vm) !void {
        var n: usize = 0;
        const g = &self.globals;
        const all_globals = [_]*Oop{
            &g.object_class,           &g.behavior_class,           &g.class_description_class,
            &g.class_class,            &g.metaclass_class,          &g.undefined_class,
            &g.boolean_class,          &g.true_class,               &g.false_class,
            &g.smallinteger_class,     &g.small_float_class,        &g.large_positive_integer_class,
            &g.large_negative_integer_class, &g.byte_array_class,    &g.string_class,
            &g.symbol_class,           &g.array_class,              &g.dictionary_class,
            &g.compiled_method_class,  &g.frame_class,              &g.block_closure_class,
            &g.literal_node_class,     &g.var_ref_node_class,       &g.assign_node_class,
            &g.send_node_class,        &g.super_send_node_class,    &g.block_node_class,
            &g.seq_node_class,         &g.ret_node_class,           &g.exception_class,
            &g.process_class,          &g.semaphore_class,          &g.scheduler_class,
            &g.processor,
            &g.smalltalk,              &g.symbol_table,
            &g.sym_nil,                &g.sym_true,                 &g.sym_false,
            &g.sym_smalltalk,          &g.sym_thisContext,          &g.sym_self,
            &g.sym_value,              &g.sym_value_colon,
            &g.sym_plus,               &g.sym_minus,                &g.sym_times,
            &g.sym_lt,                 &g.sym_le,                   &g.sym_gt,
            &g.sym_ge,                 &g.sym_printString,
            &g.sym_runnable,           &g.sym_suspended,
            &g.sym_waiting,            &g.sym_terminated,
        };
        for (all_globals) |p| try self.pushRoot(&n, p);
        try self.pushRoot(&n, &self.current_frame);
        try self.pushRoot(&n, &self.current_method_frame);
        try self.pushRoot(&n, &self.current_method_class);
        try self.pushRoot(&n, &self.return_value);
        try self.pushRoot(&n, &self.return_target);
        try self.pushRoot(&n, &self.signaled_exception);
        try self.pushRoot(&n, &self.current_process);

        // Walk the bytecode-pin chain. Each pin contributes its live
        // stack slots (stack[0..*sp]) as extra roots. pushRoot grows
        // gc_root_buf on demand, so deep recursion is bounded only
        // by the page allocator, not by a static buffer.
        var pin = self.bc_pin;
        while (pin) |p| : (pin = p.parent) {
            const sp = p.sp_ptr.*;
            var i: u32 = 0;
            while (i < sp) : (i += 1) try self.pushRoot(&n, &p.stack_base[i]);
            try self.pushRoot(&n, &p.saved_frame);
            try self.pushRoot(&n, &p.saved_method_frame);
            try self.pushRoot(&n, &p.saved_method_class);
        }

        // Suspended processes own a separate bc_pin chain rooted in
        // their ProcessState. Active's chain was just walked above.
        for (self.all_processes.items) |*proc_slot| {
            try self.pushRoot(&n, proc_slot);
            const proc = proc_slot.*;
            if (proc == self.current_process) continue;
            if (!oop_mod.isHeapPtr(proc)) continue;
            const state = processStateOf(proc);
            var spin: ?*BcPin = @ptrFromInt(state.bc_pin);
            while (spin) |p| : (spin = p.parent) {
                const sp_susp = p.sp_ptr.*;
                var i: u32 = 0;
                while (i < sp_susp) : (i += 1) try self.pushRoot(&n, &p.stack_base[i]);
                try self.pushRoot(&n, &p.saved_frame);
                try self.pushRoot(&n, &p.saved_method_frame);
                try self.pushRoot(&n, &p.saved_method_class);
            }
        }

        // Root-pin chain: Zig stack locals explicitly pinned by AST
        // eval / prim helpers that can't keep their Oops in heap
        // slots while a child interpretation is in flight.
        var rp = self.root_pin;
        while (rp) |r| : (rp = r.parent) {
            var k: u32 = 0;
            while (k < r.n) : (k += 1) {
                if (r.slots[k]) |slot_ptr| try self.pushRoot(&n, slot_ptr);
            }
        }

        // JIT inline-cache slots. GC walks both cached_class
        // (offset 0) and cached_method (offset +8). cached_entry at
        // offset +16 is a raw fn-pointer into the JIT page and
        // doesn't move.
        var ic_i: u32 = 0;
        while (ic_i < self.jit_ic_count) : (ic_i += 1) {
            const slot_opt = self.jit_ic_slots[ic_i];
            if (slot_opt) |slot_ptr| {
                try self.pushRoot(&n, @ptrCast(slot_ptr)); // cached_class
                try self.pushRoot(&n, @ptrCast(slot_ptr + 1)); // cached_method
            }
        }

        // Stack-allocated frames produced by the JIT live outside
        // the Smalltalk heap; copy() returns their addresses
        // unchanged. But their slots can hold heap pointers that
        // still need to be walked. Add each slot of every reachable
        // stack frame to the roots list. Reachability comes from
        // current_frame, current_method_frame, and the saved_frame
        // slots in the bc_pin chain (already pushed above).
        const heap_lo: u64 = @intFromPtr(self.heap.base);
        const heap_hi: u64 = heap_lo + self.heap.capacity;
        try addStackFrameSlots(self, self.current_frame, heap_lo, heap_hi, &n);
        try addStackFrameSlots(self, self.current_method_frame, heap_lo, heap_hi, &n);
        var sp = self.bc_pin;
        while (sp) |p| : (sp = p.parent) {
            try addStackFrameSlots(self, p.saved_frame, heap_lo, heap_hi, &n);
            try addStackFrameSlots(self, p.saved_method_frame, heap_lo, heap_hi, &n);
        }

        // Suspended processes' JIT stack frames also need their
        // heap-pointer slots walked. saved_frame slots cover the
        // outer frames; the bc_pin chain saved_frame/method_frame
        // pin the SEND-time current frames too.
        for (self.all_processes.items) |proc_slot_v| {
            const proc = proc_slot_v;
            if (proc == self.current_process) continue;
            if (!oop_mod.isHeapPtr(proc)) continue;
            try addStackFrameSlots(self, object.slot(proc, object.SLOT_PROCESS_SAVED_FRAME), heap_lo, heap_hi, &n);
            try addStackFrameSlots(self, object.slot(proc, object.SLOT_PROCESS_SAVED_METHOD_FRAME), heap_lo, heap_hi, &n);
            var ssp: ?*BcPin = @ptrFromInt(processStateOf(proc).bc_pin);
            while (ssp) |p| : (ssp = p.parent) {
                try addStackFrameSlots(self, p.saved_frame, heap_lo, heap_hi, &n);
                try addStackFrameSlots(self, p.saved_method_frame, heap_lo, heap_hi, &n);
            }
        }

        const fields = self.gc_root_buf;

        // GC will rewrite the cached_method slots embedded in the JIT
        // page (we registered them as additional roots above). The
        // page is RX while running JIT'd code, so flip per-thread to
        // RW for the duration of the collect.
        if (self.jit_buf) |*buf| buf.markWritable();
        defer if (self.jit_buf) |*buf| buf.markExecutable();
        try gc_mod.collect(self.heap, .{ .fields = fields[0..n] });
    }

    // Threshold-driven GC: run when the active half is more than
    // ~75% full. Called from the bytecode interpreter's safe point
    // (between instructions); never from inside AST evaluation.
    pub fn maybeCollectGarbage(self: *Vm) !void {
        if (self.heap.used > self.heap.gc_threshold) try self.collectGarbage();
    }

    // ── Cooperative scheduler ─────────────────────────────────────
    //
    // Each green thread is a Smalltalk Process oop with a heap-
    // resident ByteArray backing its `scheduler.ProcessState`
    // (registers + saved Vm fields + mmap stack metadata). The
    // active process is `self.current_process`; switching means
    //   1. snapshot vm.{bc_pin, current_frame, ...} into the
    //      active Process's ProcessState,
    //   2. update vm.* from the target's ProcessState,
    //   3. call scheduler.swap to actually transfer stacks.
    // After the swap returns, this Vm is again the *previous*
    // process — vm.* fields were just restored by whoever swapped
    // back to us.

    fn processStateOf(proc: Oop) *scheduler_mod.ProcessState {
        const ba = object.slot(proc, object.SLOT_PROCESS_SUSPENDED_CONTEXT);
        return @ptrCast(@alignCast(object.bytesOf(ba)));
    }

    /// Lazy creation of a Process oop representing the host thread
    /// that started the Vm. Called the first time anything wants
    /// to swap; cheap no-op afterwards.
    pub fn ensureMainProcess(self: *Vm) !void {
        if (oop_mod.isHeapPtr(self.current_process)) return;
        if (!oop_mod.isHeapPtr(self.globals.process_class)) return;
        const main = try self.heap.allocSlots(self.globals.process_class, object.PROCESS_INST_SIZE);
        object.setSlot(main, object.SLOT_PROCESS_PRIORITY, oop_mod.fromInt(object.PRIORITY_USER_SCHEDULING));
        object.setSlot(main, object.SLOT_PROCESS_STATE, self.globals.sym_runnable);
        object.setSlot(main, object.SLOT_PROCESS_BLOCK, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_NAME, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_RESULT, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_SAVED_FRAME, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_SAVED_METHOD_FRAME, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_SAVED_METHOD_CLASS, oop_mod.NIL);
        object.setSlot(main, object.SLOT_PROCESS_DEADLINE, oop_mod.fromInt(0));
        var main_pin: Oop = main;
        var slots: [1]?*Oop = .{&main_pin};
        var pin = RootPin{ .parent = self.root_pin, .slots = &slots, .n = 1 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;
        const ba = try self.heap.allocBytes(self.globals.byte_array_class, @sizeOf(scheduler_mod.ProcessState));
        // Zero-init the bytes — Context starts clean; the first
        // swap-out into `main` writes its callee-saved state in.
        @memset(object.bytesOf(ba)[0..@sizeOf(scheduler_mod.ProcessState)], 0);
        object.setSlot(main_pin, object.SLOT_PROCESS_SUSPENDED_CONTEXT, ba);
        self.current_process = main_pin;
        if (oop_mod.isHeapPtr(self.globals.processor)) {
            object.setSlot(self.globals.processor, object.SLOT_SCHEDULER_ACTIVE, main_pin);
        }
        self.all_processes.append(std.heap.page_allocator, main_pin) catch return error.OutOfMemory;
    }

    /// Switch from the active process to `target`. Save current
    /// vm.* into active's ProcessState (registers + stack info) and
    /// its slot fields (saved Vm Oops), then load target's, then
    /// swap stacks. Returns when something else later swaps back
    /// to us.
    pub fn swapTo(self: *Vm, target: Oop) void {
        if (target == self.current_process) return;
        const prev = self.current_process;
        const prev_state = processStateOf(prev);
        prev_state.bc_pin = @intFromPtr(self.bc_pin);
        object.setSlot(prev, object.SLOT_PROCESS_SAVED_FRAME, self.current_frame);
        object.setSlot(prev, object.SLOT_PROCESS_SAVED_METHOD_FRAME, self.current_method_frame);
        object.setSlot(prev, object.SLOT_PROCESS_SAVED_METHOD_CLASS, self.current_method_class);

        self.current_process = target;
        if (oop_mod.isHeapPtr(self.globals.processor)) {
            object.setSlot(self.globals.processor, object.SLOT_SCHEDULER_ACTIVE, target);
        }
        const tgt_state = processStateOf(target);
        self.bc_pin = @ptrFromInt(tgt_state.bc_pin);
        self.current_frame = object.slot(target, object.SLOT_PROCESS_SAVED_FRAME);
        self.current_method_frame = object.slot(target, object.SLOT_PROCESS_SAVED_METHOD_FRAME);
        self.current_method_class = object.slot(target, object.SLOT_PROCESS_SAVED_METHOD_CLASS);

        scheduler_mod.swap(&prev_state.ctx, &tgt_state.ctx);
    }

    /// Pop the head of the highest-priority non-empty runnable list.
    /// NIL when nobody is runnable. Drains expired sleepers off the
    /// delay queue first so they get a chance to run, then reaps
    /// any terminated processes' mmap stacks.
    fn dequeueHighestRunnable(self: *Vm) Oop {
        self.expireSleepers(monotonicNanos());
        self.reapTerminated();
        const sched = self.globals.processor;
        if (!oop_mod.isHeapPtr(sched)) return oop_mod.NIL;
        const lists = object.slot(sched, object.SLOT_SCHEDULER_QLISTS);
        if (!oop_mod.isHeapPtr(lists)) return oop_mod.NIL;
        const cap = object.headerOf(lists).size;
        var pri: u32 = if (cap > object.MAX_PRIORITY) object.MAX_PRIORITY else cap - 1;
        while (pri >= 1) : (pri -= 1) {
            const head = object.slot(lists, pri);
            if (!oop_mod.isHeapPtr(head)) {
                if (pri == 0) break;
                continue;
            }
            const next = object.slot(head, object.SLOT_PROCESS_NEXT_LINK);
            object.setSlot(lists, pri, next);
            object.setSlot(head, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
            return head;
        }
        return oop_mod.NIL;
    }

    /// Insert `process` into the scheduler's delay list, sorted
    /// ascending by deadline. The list is linked through
    /// SLOT_PROCESS_NEXT_LINK; the head is the earliest deadline.
    pub fn delayEnqueue(self: *Vm, process: Oop) void {
        const sched = self.globals.processor;
        if (!oop_mod.isHeapPtr(sched)) return;
        const dl_oop = object.slot(process, object.SLOT_PROCESS_DEADLINE);
        if (!oop_mod.isInt(dl_oop)) return;
        const dl = oop_mod.toInt(dl_oop);
        object.setSlot(process, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);

        const head = object.slot(sched, object.SLOT_SCHEDULER_DELAY_HEAD);
        if (oop_mod.isNil(head)) {
            object.setSlot(sched, object.SLOT_SCHEDULER_DELAY_HEAD, process);
            return;
        }
        const head_dl_oop = object.slot(head, object.SLOT_PROCESS_DEADLINE);
        if (oop_mod.isInt(head_dl_oop) and dl < oop_mod.toInt(head_dl_oop)) {
            object.setSlot(process, object.SLOT_PROCESS_NEXT_LINK, head);
            object.setSlot(sched, object.SLOT_SCHEDULER_DELAY_HEAD, process);
            return;
        }
        // Insert after the last process whose deadline is <= ours
        // (ties go to FIFO).
        var cur = head;
        while (true) {
            const nxt = object.slot(cur, object.SLOT_PROCESS_NEXT_LINK);
            if (oop_mod.isNil(nxt)) break;
            const nxt_dl_oop = object.slot(nxt, object.SLOT_PROCESS_DEADLINE);
            if (!oop_mod.isInt(nxt_dl_oop)) break;
            if (dl < oop_mod.toInt(nxt_dl_oop)) break;
            cur = nxt;
        }
        const after = object.slot(cur, object.SLOT_PROCESS_NEXT_LINK);
        object.setSlot(process, object.SLOT_PROCESS_NEXT_LINK, after);
        object.setSlot(cur, object.SLOT_PROCESS_NEXT_LINK, process);
    }

    /// Move every sleeping process whose deadline has passed off
    /// the delay list and onto the runnable queue.
    pub fn expireSleepers(self: *Vm, now: i64) void {
        const sched = self.globals.processor;
        if (!oop_mod.isHeapPtr(sched)) return;
        var head = object.slot(sched, object.SLOT_SCHEDULER_DELAY_HEAD);
        while (oop_mod.isHeapPtr(head)) {
            const dl_oop = object.slot(head, object.SLOT_PROCESS_DEADLINE);
            if (!oop_mod.isInt(dl_oop)) break;
            if (oop_mod.toInt(dl_oop) > now) break;
            const next = object.slot(head, object.SLOT_PROCESS_NEXT_LINK);
            object.setSlot(head, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
            object.setSlot(head, object.SLOT_PROCESS_DEADLINE, oop_mod.fromInt(0));
            object.setSlot(head, object.SLOT_PROCESS_STATE, self.globals.sym_runnable);
            self.enqueueRunnable(head);
            head = next;
        }
        object.setSlot(sched, object.SLOT_SCHEDULER_DELAY_HEAD, head);
    }

    /// Sweep `all_processes` for terminated entries: munmap their
    /// per-process stacks and drop them from the list (so the next
    /// GC can collect the Process oop). Skips the active process —
    /// `processEntry` calls `scheduleNext` *while still on its own
    /// stack*, so we mustn't free it from under itself.
    ///
    /// Trade-off: removing terminated entries means `aProcess result`
    /// after termination is racy (the Process oop may have been
    /// collected before the read). hilang's userland doesn't poll
    /// fork results today; revisit if a join: protocol lands.
    fn reapTerminated(self: *Vm) void {
        var i: usize = 0;
        while (i < self.all_processes.items.len) {
            const proc = self.all_processes.items[i];
            if (proc == self.current_process or !oop_mod.isHeapPtr(proc)) {
                i += 1;
                continue;
            }
            const state_oop = object.slot(proc, object.SLOT_PROCESS_STATE);
            if (state_oop != self.globals.sym_terminated) {
                i += 1;
                continue;
            }
            const ps = processStateOf(proc);
            if (ps.stack_base != 0) {
                var j: usize = 0;
                while (j < self.process_stacks.items.len) : (j += 1) {
                    if (@intFromPtr(self.process_stacks.items[j].base.ptr) == ps.stack_base) {
                        self.process_stacks.items[j].free();
                        _ = self.process_stacks.swapRemove(j);
                        break;
                    }
                }
                ps.stack_base = 0;
                ps.stack_size = 0;
                ps.bc_pin = 0;
            }
            _ = self.all_processes.swapRemove(i);
            // Don't bump i — swapRemove brought a new entry to this slot.
        }
    }

    /// Append a Process at the tail of its priority's runnable list.
    /// Used by yield (when active is still runnable) and by signal/
    /// resume.
    pub fn enqueueRunnable(self: *Vm, process: Oop) void {
        const sched = self.globals.processor;
        if (!oop_mod.isHeapPtr(sched)) return;
        const lists = object.slot(sched, object.SLOT_SCHEDULER_QLISTS);
        if (!oop_mod.isHeapPtr(lists)) return;
        const pri_oop = object.slot(process, object.SLOT_PROCESS_PRIORITY);
        if (!oop_mod.isInt(pri_oop)) return;
        const pri: u32 = @intCast(@max(@as(i64, 1), @min(@as(i64, object.MAX_PRIORITY), oop_mod.toInt(pri_oop))));
        if (pri >= object.headerOf(lists).size) return;
        object.setSlot(process, object.SLOT_PROCESS_NEXT_LINK, oop_mod.NIL);
        const head = object.slot(lists, pri);
        if (oop_mod.isNil(head)) {
            object.setSlot(lists, pri, process);
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

    /// Pick the highest-priority runnable Process and swap to it.
    /// If the active is still runnable (voluntary yield), it gets
    /// re-enqueued so it'll come back later.
    ///
    /// Three terminal cases:
    ///   * Active is runnable and nobody else is queued → no-op,
    ///     continue running active.
    ///   * Active is non-runnable (waiting/terminated/suspended)
    ///     and the runnable list is empty → deadlock; raise
    ///     PrimitiveFailed so the caller surfaces something useful
    ///     instead of dropping into an unrecoverable state.
    ///   * Otherwise → swap to the dequeued process.
    pub fn scheduleNext(self: *Vm) !void {
        try self.ensureMainProcess();
        const active = self.current_process;
        const active_state = object.slot(active, object.SLOT_PROCESS_STATE);

        var next = self.dequeueHighestRunnable();
        // Active is non-runnable and the run queue is empty, but
        // some processes may still be sleeping. Block the host
        // thread until the earliest deadline, expire, retry.
        while (oop_mod.isNil(next) and active_state != self.globals.sym_runnable) {
            const sched = self.globals.processor;
            if (!oop_mod.isHeapPtr(sched)) break;
            const head = object.slot(sched, object.SLOT_SCHEDULER_DELAY_HEAD);
            if (!oop_mod.isHeapPtr(head)) break;
            const dl_oop = object.slot(head, object.SLOT_PROCESS_DEADLINE);
            if (!oop_mod.isInt(dl_oop)) break;
            nanosleepFor(oop_mod.toInt(dl_oop) - monotonicNanos());
            next = self.dequeueHighestRunnable();
        }

        if (oop_mod.isNil(next)) {
            if (active_state != self.globals.sym_runnable) return error.PrimitiveFailed;
            return;
        }
        if (next == active) return;
        if (active_state == self.globals.sym_runnable) {
            self.enqueueRunnable(active);
        }
        self.swapTo(next);
    }

    /// Allocate a stack + ProcessState for a fresh Process so the
    /// first swap-into it lands in `processEntry(self)`. The Process
    /// must already have its block / priority / etc. slots filled.
    pub fn primeProcess(self: *Vm, proc: Oop) EvalError!void {
        if (!oop_mod.isHeapPtr(proc)) return error.TypeError;
        // Pin proc across the allocBytes call so a future GC retry
        // there can't leave us holding a moved-from oop. Cheap;
        // matches the discipline elsewhere in the file.
        var proc_pin: Oop = proc;
        var slots: [1]?*Oop = .{&proc_pin};
        var pin = RootPin{ .parent = self.root_pin, .slots = &slots, .n = 1 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        const ba = try self.heap.allocBytes(self.globals.byte_array_class, @sizeOf(scheduler_mod.ProcessState));
        @memset(object.bytesOf(ba)[0..@sizeOf(scheduler_mod.ProcessState)], 0);
        object.setSlot(proc_pin, object.SLOT_PROCESS_SUSPENDED_CONTEXT, ba);
        // mmap can fail with platform-specific error codes that
        // aren't part of EvalError; squash them into OutOfMemory
        // so primitives can `try` without enumerating mmap errors.
        // 2 MiB matches the conservative side of classic Smalltalk
        // green-thread defaults; smaller (e.g. 128 KiB) overflowed
        // when a forked block triggered AST→bytecode compile of a
        // nested send.
        const stack = scheduler_mod.Stack.alloc(2 * 1024 * 1024) catch return error.OutOfMemory;
        self.process_stacks.append(std.heap.page_allocator, stack) catch return error.OutOfMemory;
        const state = processStateOf(proc_pin);
        state.* = .{
            .ctx = .{},
            .stack_base = @intFromPtr(stack.base.ptr),
            .stack_size = stack.base.len,
        };
        scheduler_mod.prepare(&state.ctx, stack, processEntry, self);
        // Register only after the ProcessState bytes are zeroed so
        // a GC walking us during a sibling allocation finds a
        // safely-empty bc_pin chain rather than uninitialised bytes.
        self.all_processes.append(std.heap.page_allocator, proc_pin) catch return error.OutOfMemory;
    }

    pub fn classOf(self: *const Vm, o: Oop) Oop {
        if (oop_mod.isNil(o)) return self.globals.undefined_class;
        if (o == oop_mod.TRUE) return self.globals.true_class;
        if (o == oop_mod.FALSE) return self.globals.false_class;
        if (oop_mod.isInt(o)) return self.globals.smallinteger_class;
        if (oop_mod.isFloat(o)) return self.globals.small_float_class;
        if (oop_mod.isHeapPtr(o)) return object.headerOf(o).class;
        return oop_mod.NIL;
    }

    // The interpreter dispatches on the AST node's class identity. Each
    // branch reads the relevant slots from the heap object and hands
    // off to the corresponding eval helper.
    // Top-level entry: wrap an arbitrary expression node in a
    // synthetic CompiledMethod (kind=AST initially, no params/temps,
    // body=node) and invoke it. invokeMethod's lazy-compile path
    // will switch the synthetic method to bytecode if it compiles,
    // so top-level expressions benefit from the bytecode loop's
    // auto-GC at safe points (Phase v3.B.1). Falls back to direct
    // AST eval if the wrap fails (OOM).
    fn collectTopLevelTemps(g: *const Globals, node: Oop, out: *[64]Oop, n: *u32) void {
        if (!oop_mod.isHeapPtr(node)) return;
        const cls = object.headerOf(node).class;
        if (cls == g.assign_node_class) {
            const sym = object.slot(node, object.SLOT_ASSIGN_NAME);
            // Skip pseudo-vars and shadowed names like self/Smalltalk.
            if (sym == g.sym_self or sym == g.sym_smalltalk) return;
            // Dedup.
            var i: u32 = 0;
            while (i < n.*) : (i += 1) {
                if (out[i] == sym) {
                    collectTopLevelTemps(g, object.slot(node, object.SLOT_ASSIGN_VALUE), out, n);
                    return;
                }
            }
            if (n.* < out.len) {
                out[n.*] = sym;
                n.* += 1;
            }
            collectTopLevelTemps(g, object.slot(node, object.SLOT_ASSIGN_VALUE), out, n);
            return;
        }
        if (cls == g.seq_node_class) {
            const stmts = object.slot(node, object.SLOT_SEQ_BODY);
            if (oop_mod.isHeapPtr(stmts)) {
                const sn = object.headerOf(stmts).size;
                var i: u32 = 0;
                while (i < sn) : (i += 1) collectTopLevelTemps(g, object.slot(stmts, i), out, n);
            }
            return;
        }
        if (cls == g.ret_node_class) {
            collectTopLevelTemps(g, object.slot(node, object.SLOT_RET_INNER), out, n);
            return;
        }
        if (cls == g.send_node_class) {
            collectTopLevelTemps(g, object.slot(node, object.SLOT_SEND_RECEIVER), out, n);
            const args = object.slot(node, object.SLOT_SEND_ARGS);
            if (oop_mod.isHeapPtr(args)) {
                const an = object.headerOf(args).size;
                var i: u32 = 0;
                while (i < an) : (i += 1) collectTopLevelTemps(g, object.slot(args, i), out, n);
            }
            return;
        }
        // BlockNode and SuperSendNode: introduce their own scope, so
        // don't descend. Other node kinds (literal, var_ref) have no
        // assign children.
    }

    pub fn evalAsTopLevel(self: *Vm, node: Oop) EvalError!Oop {
        const g = &self.globals;
        // Each top-level eval is its own request boundary. The
        // previous eval's last in-flight GC ran when the heap was
        // still pinned by its locals; once that eval returned those
        // locals went unreachable but no safe-point GC has fired
        // since (heap.used reflects pre-return live size, not
        // post-return). Without this check, the first allocation
        // below — the temps array — would OOM whenever the previous
        // eval grew the heap past half_size, and the AST fallback
        // path doesn't auto-GC either. Cheap when the heap is
        // healthy (gated on used > gc_threshold).
        self.maybeCollectGarbage() catch |e| return e;
        // Walk the node and collect every AssignNode target name
        // visible at this scope (we don't descend into BlockNode —
        // those have their own param/temp scope). Those become the
        // synthetic method's temps so the compiler can resolve them
        // as locals; without this, top-level assigns force AST
        // fallback and miss the bytecode auto-GC entirely.
        var temp_syms: [64]Oop = undefined;
        var n_temps: u32 = 0;
        collectTopLevelTemps(g, node, &temp_syms, &n_temps);

        const temps = self.heap.allocSlots(g.array_class, n_temps) catch return self.eval(node);
        var ti: u32 = 0;
        while (ti < n_temps) : (ti += 1) object.setSlot(temps, ti, temp_syms[ti]);
        const empty = self.heap.allocSlots(g.array_class, 0) catch return self.eval(node);

        // Wrap as `^node` so the synthetic method returns the
        // expression's value rather than the (NIL) receiver.
        const ret_node = self.heap.allocSlots(g.ret_node_class, object.RET_INST_SIZE) catch return self.eval(node);
        object.setSlot(ret_node, object.SLOT_RET_INNER, node);
        const body = self.heap.allocSlots(g.array_class, 1) catch return self.eval(node);
        object.setSlot(body, 0, ret_node);
        const m = self.heap.allocSlots(g.compiled_method_class, object.METHOD_INST_SIZE) catch return self.eval(node);
        object.setSlot(m, object.SLOT_METHOD_SELECTOR, oop_mod.NIL);
        object.setSlot(m, object.SLOT_METHOD_ARG_COUNT, oop_mod.fromInt(0));
        object.setSlot(m, object.SLOT_METHOD_KIND, oop_mod.fromInt(object.METHOD_KIND_AST));
        object.setSlot(m, object.SLOT_METHOD_BODY, body);
        object.setSlot(m, object.SLOT_METHOD_PARAMS, empty);
        object.setSlot(m, object.SLOT_METHOD_TEMPS, temps);
        object.setSlot(m, object.SLOT_METHOD_DEFINING_CLASS, g.object_class);
        // Eagerly request tier-up. The synthetic top-level method
        // is invoked exactly once but its body typically contains
        // an inlined whileTrue: loop that runs millions of times.
        // Setting HOT_COUNT to the threshold means the first
        // invokeMethod tries JIT compile immediately rather than
        // running the bytecode interpreter for the entire eval.
        object.setSlot(m, object.SLOT_METHOD_HOT_COUNT, oop_mod.fromInt(HOT_THRESHOLD));
        const result = self.invokeMethod(m, oop_mod.NIL, &.{}) catch |e| switch (e) {
            error.MethodReturn => return self.return_value,
            else => return e,
        };
        return result;
    }

    pub fn eval(self: *Vm, node: Oop) EvalError!Oop {
        if (!oop_mod.isHeapPtr(node)) return error.UnknownNodeClass;
        const cls = self.classOf(node);
        const g = &self.globals;

        if (cls == g.literal_node_class) {
            return object.slot(node, object.SLOT_LIT_VALUE);
        }
        if (cls == g.var_ref_node_class) {
            return self.evalVarRef(object.slot(node, object.SLOT_VARREF_NAME));
        }
        if (cls == g.assign_node_class) {
            const sym = object.slot(node, object.SLOT_ASSIGN_NAME);
            const value_node = object.slot(node, object.SLOT_ASSIGN_VALUE);
            return self.evalAssign(sym, value_node);
        }
        if (cls == g.send_node_class) {
            return self.evalSend(node);
        }
        if (cls == g.super_send_node_class) {
            return self.evalSuperSend(node);
        }
        if (cls == g.block_node_class) {
            const params_arr = object.slot(node, object.SLOT_BLOCKNODE_PARAMS);
            const temps_arr = object.slot(node, object.SLOT_BLOCKNODE_TEMPS);
            const body_arr = object.slot(node, object.SLOT_BLOCKNODE_BODY);
            return self.evalBlock(params_arr, temps_arr, body_arr);
        }
        if (cls == g.seq_node_class) {
            return self.evalSeq(object.slot(node, object.SLOT_SEQ_BODY));
        }
        if (cls == g.ret_node_class) {
            return self.evalRet(object.slot(node, object.SLOT_RET_INNER));
        }
        return error.UnknownNodeClass;
    }

    fn evalVarRef(self: *Vm, sym: Oop) EvalError!Oop {
        const g = &self.globals;
        if (sym == g.sym_nil) return oop_mod.NIL;
        if (sym == g.sym_true) return oop_mod.TRUE;
        if (sym == g.sym_false) return oop_mod.FALSE;
        if (sym == g.sym_smalltalk) return g.smalltalk;
        if (sym == g.sym_thisContext) return self.current_frame;

        if (frame_mod.findBySym(self.current_frame, sym)) |b| {
            return frame_mod.read(b.frame, b.index);
        }

        if (frame_mod.findBySym(self.current_frame, g.sym_self)) |sb| {
            const receiver = frame_mod.read(sb.frame, sb.index);
            if (oop_mod.isHeapPtr(receiver)) {
                const cls = self.classOf(receiver);
                if (class_mod.ivarSlotForSym(cls, sym)) |idx| {
                    return object.slot(receiver, idx);
                }
            }
        }

        if (!dict.hasSym(g.smalltalk, sym)) return error.UndefinedVariable;
        return dict.lookupBySym(g.smalltalk, sym);
    }

    fn evalAssign(self: *Vm, sym_in: Oop, value_node_in: Oop) EvalError!Oop {
        // self.eval(value_node) may fire GC. `sym` is an interned
        // Symbol that GC moves; pin it so frame_mod.findBySym below
        // and dict.atPutSym still see the live address. value_node
        // we don't reuse, but pin defensively.
        var sym_pin: Oop = sym_in;
        var value_node_pin: Oop = value_node_in;
        var value_pin: Oop = oop_mod.NIL;
        var slot_ptrs: [3]?*Oop = .{ &sym_pin, &value_node_pin, &value_pin };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 3 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        value_pin = try self.eval(value_node_pin);
        const sym = sym_pin;
        const value = value_pin;
        const g = &self.globals;

        if (frame_mod.findBySym(self.current_frame, sym)) |b| {
            frame_mod.write(b.frame, b.index, value);
            return value;
        }

        if (frame_mod.findBySym(self.current_frame, g.sym_self)) |sb| {
            const receiver = frame_mod.read(sb.frame, sb.index);
            if (oop_mod.isHeapPtr(receiver)) {
                const cls = self.classOf(receiver);
                if (class_mod.ivarSlotForSym(cls, sym)) |idx| {
                    object.setSlot(receiver, idx, value);
                    return value;
                }
            }
        }

        _ = dict.atPutSym(self.heap, g.smalltalk, sym, value) catch |e| switch (e) {
            error.DictionaryFull => return error.DictionaryFull,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return value;
    }

    fn evalSeq(self: *Vm, body_arr_in: Oop) EvalError!Oop {
        if (!oop_mod.isHeapPtr(body_arr_in)) return error.EmptySequence;
        var body_arr_pin: Oop = body_arr_in;
        var last: Oop = oop_mod.NIL;
        var slot_ptrs: [2]?*Oop = .{ &body_arr_pin, &last };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 2 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        const count = object.headerOf(body_arr_pin).size;
        if (count == 0) return error.EmptySequence;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            last = try self.eval(object.slot(body_arr_pin, i));
        }
        return last;
    }

    fn evalRet(self: *Vm, inner: Oop) EvalError!Oop {
        const value = try self.eval(inner);
        if (oop_mod.isNil(self.current_method_frame)) return error.InvalidReturn;
        self.return_value = value;
        self.return_target = self.current_method_frame;
        return error.MethodReturn;
    }

    fn evalSend(self: *Vm, node_in: Oop) EvalError!Oop {
        // All Oops below survive across self.eval(...) calls that
        // can GC. Pin them so the root-walker rewrites their slots
        // in place; otherwise an arg evaluated early in the loop
        // would hold a moved-from address by the time we dispatch.
        var node_pin: Oop = node_in;
        var recv_node_pin: Oop = object.slot(node_in, object.SLOT_SEND_RECEIVER);
        var sel_sym_pin: Oop = object.slot(node_in, object.SLOT_SEND_SELECTOR);
        var args_arr_pin: Oop = object.slot(node_in, object.SLOT_SEND_ARGS);
        var receiver_pin: Oop = oop_mod.NIL;
        var args_buf: [16]Oop = .{oop_mod.NIL} ** 16;
        var slot_ptrs: [21]?*Oop = .{
            &node_pin, &recv_node_pin, &sel_sym_pin, &args_arr_pin, &receiver_pin,
            &args_buf[0],  &args_buf[1],  &args_buf[2],  &args_buf[3],
            &args_buf[4],  &args_buf[5],  &args_buf[6],  &args_buf[7],
            &args_buf[8],  &args_buf[9],  &args_buf[10], &args_buf[11],
            &args_buf[12], &args_buf[13], &args_buf[14], &args_buf[15],
        };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 21 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        receiver_pin = try self.eval(recv_node_pin);
        const arg_count: u32 = if (oop_mod.isHeapPtr(args_arr_pin)) object.headerOf(args_arr_pin).size else 0;
        if (arg_count > args_buf.len) return error.TooManyArgs;
        var i: u32 = 0;
        while (i < arg_count) : (i += 1) {
            args_buf[i] = try self.eval(object.slot(args_arr_pin, i));
        }
        const receiver = receiver_pin;
        const sel_sym = sel_sym_pin;
        const node = node_pin;
        const args = args_buf[0..arg_count];

        // ---- AST-level fast paths. ----
        //
        // These bypass method lookup, IC, and primitive dispatch for
        // the tightest hot paths: SmallInteger arithmetic when both
        // operands are tagged ints, and BlockClosure>>value when the
        // receiver is a block. A user-defined override on SmallInteger
        // is invisible here (matches Pharo's inline-primitive policy).
        const g = &self.globals;
        if (oop_mod.isInt(receiver) and arg_count == 1 and oop_mod.isInt(args[0])) {
            const a = oop_mod.toInt(receiver);
            const b = oop_mod.toInt(args[0]);
            // Comparisons never overflow.
            if (sel_sym == g.sym_lt) return oop_mod.fromBool(a < b);
            if (sel_sym == g.sym_le) return oop_mod.fromBool(a <= b);
            if (sel_sym == g.sym_gt) return oop_mod.fromBool(a > b);
            if (sel_sym == g.sym_ge) return oop_mod.fromBool(a >= b);
            // Arithmetic: fast-path only when the result fits an i63
            // tagged SmallInteger; on overflow fall through to the
            // primitive, which auto-promotes to LargeInteger.
            if (sel_sym == g.sym_plus) {
                const s = a +% b;
                if (((a ^ s) & (b ^ s)) >= 0 and oop_mod.fitsSmallInt(s)) return oop_mod.fromInt(s);
            } else if (sel_sym == g.sym_minus) {
                const d = a -% b;
                if (((a ^ b) & (a ^ d)) >= 0 and oop_mod.fitsSmallInt(d)) return oop_mod.fromInt(d);
            } else if (sel_sym == g.sym_times) {
                const m = @mulWithOverflow(a, b);
                if (m[1] == 0 and oop_mod.fitsSmallInt(m[0])) return oop_mod.fromInt(m[0]);
            }
        }
        if (oop_mod.isHeapPtr(receiver) and arg_count == 0 and sel_sym == g.sym_value) {
            if (object.headerOf(receiver).class == g.block_closure_class) {
                return invokeBlock(self, receiver, args);
            }
        }

        // Bimorphic inline cache: check the most-recently-installed
        // entry first, then the demoted entry. On miss, full lookup
        // and shift slot 1 → slot 2 (LRU).
        const receiver_class = self.classOf(receiver);
        const cached_class_1 = object.slot(node, object.SLOT_SEND_CACHED_CLASS);
        if (cached_class_1 == receiver_class) {
            const cached = object.slot(node, object.SLOT_SEND_CACHED_METHOD);
            if (oop_mod.isHeapPtr(cached)) {
                return self.invokeMethod(cached, receiver, args);
            }
        }
        const cached_method_1 = object.slot(node, object.SLOT_SEND_CACHED_METHOD);
        const cached_class_2 = object.slot(node, object.SLOT_SEND_CACHED_CLASS_2);
        if (cached_class_2 == receiver_class) {
            const cached_2 = object.slot(node, object.SLOT_SEND_CACHED_METHOD_2);
            if (oop_mod.isHeapPtr(cached_2)) {
                // Promote slot 2 to slot 1 so a steady alternating
                // workload still benefits from the fast slot.
                object.setSlot(node, object.SLOT_SEND_CACHED_CLASS, cached_class_2);
                object.setSlot(node, object.SLOT_SEND_CACHED_METHOD, cached_2);
                object.setSlot(node, object.SLOT_SEND_CACHED_CLASS_2, cached_class_1);
                object.setSlot(node, object.SLOT_SEND_CACHED_METHOD_2, cached_method_1);
                return self.invokeMethod(cached_2, receiver, args);
            }
        }

        // Cache miss: full lookup. Demote slot 1 to slot 2, install
        // new in slot 1.
        const method = method_mod.lookupBySym(receiver_class, sel_sym);
        if (oop_mod.isNil(method)) return error.DoesNotUnderstand;
        object.setSlot(node, object.SLOT_SEND_CACHED_CLASS_2, cached_class_1);
        object.setSlot(node, object.SLOT_SEND_CACHED_METHOD_2, cached_method_1);
        object.setSlot(node, object.SLOT_SEND_CACHED_CLASS, receiver_class);
        object.setSlot(node, object.SLOT_SEND_CACHED_METHOD, method);
        return self.invokeMethod(method, receiver, args);
    }

    fn evalSuperSend(self: *Vm, node_in: Oop) EvalError!Oop {
        if (oop_mod.isNil(self.current_method_class)) return error.InvalidReturn;
        var node_pin: Oop = node_in;
        var sel_sym_pin: Oop = object.slot(node_in, object.SLOT_SUPER_SELECTOR);
        var args_arr_pin: Oop = object.slot(node_in, object.SLOT_SUPER_ARGS);
        var receiver_pin: Oop = blk: {
            const sb = frame_mod.findBySym(self.current_frame, self.globals.sym_self) orelse return error.InvalidReturn;
            break :blk frame_mod.read(sb.frame, sb.index);
        };
        var args_buf: [16]Oop = .{oop_mod.NIL} ** 16;
        var slot_ptrs: [21]?*Oop = .{
            &node_pin, &sel_sym_pin, &args_arr_pin, &receiver_pin, null,
            &args_buf[0],  &args_buf[1],  &args_buf[2],  &args_buf[3],
            &args_buf[4],  &args_buf[5],  &args_buf[6],  &args_buf[7],
            &args_buf[8],  &args_buf[9],  &args_buf[10], &args_buf[11],
            &args_buf[12], &args_buf[13], &args_buf[14], &args_buf[15],
        };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 21 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        const arg_count: u32 = if (oop_mod.isHeapPtr(args_arr_pin)) object.headerOf(args_arr_pin).size else 0;
        if (arg_count > args_buf.len) return error.TooManyArgs;
        var i: u32 = 0;
        while (i < arg_count) : (i += 1) {
            args_buf[i] = try self.eval(object.slot(args_arr_pin, i));
        }
        const node = node_pin;
        const sel_sym = sel_sym_pin;
        const receiver = receiver_pin;
        const args = args_buf[0..arg_count];

        const cached = object.slot(node, object.SLOT_SUPER_CACHED_METHOD);
        if (oop_mod.isHeapPtr(cached)) {
            return self.invokeMethod(cached, receiver, args);
        }
        const start_class = object.slot(self.current_method_class, object.SLOT_SUPERCLASS);
        const method = method_mod.lookupBySym(start_class, sel_sym);
        if (oop_mod.isNil(method)) return error.DoesNotUnderstand;
        object.setSlot(node, object.SLOT_SUPER_CACHED_METHOD, method);
        return self.invokeMethod(method, receiver, args);
    }

    // The dispatch tail used by both evalSend and evalSuperSend after
    // they've located the method (cached or not). Pin method and
    // receiver: compileMethod / maybeTierUp / the JIT prologue's
    // inline maybe-GC are all reachable allocation paths between
    // entry and the final invokeXxxMethod call. Without the pin, the
    // re-reads of `method`'s slots after compileMethod / maybeTierUp
    // would dereference a stale Oop if any of those paths gained a
    // GC retry. The args slice is consumed by the callee's prologue
    // (frame copy or arg-reg marshalling) before the prologue's GC
    // fires, so its underlying storage doesn't need pinning here.
    fn invokeMethod(self: *Vm, method: Oop, receiver: Oop, args: []const Oop) EvalError!Oop {
        var method_pin: Oop = method;
        var recv_pin: Oop = receiver;
        var slot_ptrs: [2]?*Oop = .{ &method_pin, &recv_pin };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 2 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        const expected: i64 = oop_mod.toInt(object.slot(method_pin, object.SLOT_METHOD_ARG_COUNT));
        if (expected != @as(i64, @intCast(args.len))) return error.ArityMismatch;

        var kind = oop_mod.toInt(object.slot(method_pin, object.SLOT_METHOD_KIND));
        if (kind == object.METHOD_KIND_PRIMITIVE) {
            const prim_id: u32 = @intCast(oop_mod.toInt(object.slot(method_pin, object.SLOT_METHOD_PRIMITIVE)));
            return prims.dispatch(self, prim_id, recv_pin, args);
        }
        if (kind == object.METHOD_KIND_AST) {
            // Lazy compile to bytecode on first invoke. If the body
            // contains a node the compiler doesn't yet handle, mark
            // the method's bytecode slot with FALSE so we don't
            // retry compilation on every call.
            const bc_slot = object.slot(method_pin, object.SLOT_METHOD_BYTECODE);
            if (bc_slot != oop_mod.FALSE) {
                const compile = @import("compile.zig");
                compile.compileMethod(self.heap, &self.globals, method_pin) catch |e| switch (e) {
                    error.Unsupported, error.OperandOverflow => {
                        object.setSlot(method_pin, object.SLOT_METHOD_BYTECODE, oop_mod.FALSE);
                        return invokeAstMethod(self, method_pin, recv_pin, args);
                    },
                    else => return error.OutOfMemory,
                };
                kind = oop_mod.toInt(object.slot(method_pin, object.SLOT_METHOD_KIND));
            } else {
                return invokeAstMethod(self, method_pin, recv_pin, args);
            }
        }
        if (kind == object.METHOD_KIND_BYTECODE) {
            // Tier-up to native after the bytecode interpreter has
            // proven this method is hot. maybeTierUp may flip kind
            // to NATIVE; re-read on return.
            self.maybeTierUp(method_pin);
            kind = oop_mod.toInt(object.slot(method_pin, object.SLOT_METHOD_KIND));
        }
        if (kind == object.METHOD_KIND_NATIVE) {
            return self.invokeNativeMethod(method_pin, recv_pin, args);
        }
        if (kind == object.METHOD_KIND_BYTECODE) {
            return invokeBytecodeMethod(self, method_pin, recv_pin, args);
        }
        return error.NotImplemented;
    }

    // Native call ABI matches the bytecode interpreter's parameters:
    //   x0 = vm, x1 = receiver, x2 = args ptr, x3 = arity
    // Result returned in x0.
    // Pass method as a runtime arg in x1 (was an embedded immediate
    // in the JIT'd code; that goes stale across GC).
    // Native ABI: args are passed in registers x3..x6 (a0..a3) per
    // the AArch64 PCS, so JIT'd callers can BL directly without
    // building an args buffer in the frame. Methods with arity > 4
    // are rejected by analyseSupportedAndDepth, so a fixed 4-slot
    // signature covers the entire stdlib. Unused arg slots are
    // ignored by the callee.
    pub const NativeFn = *const fn (vm: *Vm, method: Oop, receiver: Oop, a0: Oop, a1: Oop, a2: Oop, a3: Oop) callconv(.c) Oop;

    // JIT helper: allocate and populate a method frame, link a BcPin
    // on the chain, and update vm.current_frame / current_method_*.
    // The native function provides storage for the BcPin on its own
    // stack and passes a pointer in `pin`. Returns the frame Oop.
    // On allocation failure returns NIL; the caller is expected to
    // detect and surface error.OutOfMemory.
    pub export fn vm_jit_method_enter(
        vm: *Vm,
        method: Oop,
        receiver: Oop,
        a0: Oop,
        a1: Oop,
        a2: Oop,
        a3: Oop,
        pin: *BcPin,
    ) callconv(.c) Oop {
        // Fill the pin with the current Vm state up front so that
        // even if frame allocation fails, the JIT'd function's
        // unconditional leave call restores those original values
        // (i.e. becomes a no-op rather than writing garbage into
        // vm.current_frame).
        pin.* = .{
            .stack_base = undefined,
            .sp_ptr = &vm.bc_jit_zero_sp,
            .parent = vm.bc_pin,
            .saved_frame = vm.current_frame,
            .saved_method_frame = vm.current_method_frame,
            .saved_method_class = vm.current_method_class,
        };
        const params_arr = object.slot(method, object.SLOT_METHOD_PARAMS);
        const temps_arr = object.slot(method, object.SLOT_METHOD_TEMPS);
        const params_count = if (oop_mod.isHeapPtr(params_arr)) object.headerOf(params_arr).size else 0;
        const temps_count = if (oop_mod.isHeapPtr(temps_arr)) object.headerOf(temps_arr).size else 0;

        const max_depth_oop = object.slot(method, object.SLOT_METHOD_HOT_COUNT);
        const max_depth: u32 = if (oop_mod.isInt(max_depth_oop)) @intCast(@max(@as(i64, 0), oop_mod.toInt(max_depth_oop))) else 0;

        const total_values: u32 = 1 + params_count + temps_count;
        const frame_size: u32 = object.FRAME_VALUES_OFFSET + total_values + max_depth;
        const frame = vm.heap.allocSlots(vm.globals.frame_class, frame_size) catch {
            vm.jit_error = @intFromError(error.OutOfMemory);
            return oop_mod.NIL;
        };
        object.setSlot(frame, object.SLOT_FRAME_PARENT, oop_mod.NIL);
        object.setSlot(frame, object.SLOT_FRAME_SOURCE, method);
        object.setSlot(frame, object.FRAME_VALUES_OFFSET + 0, receiver);
        const args_pack: [4]Oop = .{ a0, a1, a2, a3 };
        var i: u32 = 0;
        while (i < params_count and i < 4) : (i += 1) {
            object.setSlot(frame, object.FRAME_VALUES_OFFSET + 1 + i, args_pack[i]);
        }

        // Pin already filled at entry; just link it on the chain
        // and update the running Vm state for the new method.
        vm.bc_pin = pin;
        vm.current_frame = frame;
        vm.current_method_frame = frame;
        vm.current_method_class = object.slot(method, object.SLOT_METHOD_DEFINING_CLASS);

        // Safe-point GC. We're now in a fully-rooted state: every
        // incoming Oop (method, receiver, args) lives in the new
        // heap frame; pin's saved_* protect the caller state. GC
        // fires only above the 75%-full threshold, so most calls
        // pay just a load + compare.
        vm.maybeCollectGarbage() catch {
            vm.jit_error = @intFromError(error.OutOfMemory);
            // Even on GC failure, leave the bookkeeping consistent
            // — the JIT'd function's leave call will roll us back
            // through the pin's saved fields.
            return oop_mod.NIL;
        };
        // Return the post-GC frame address; GC may have moved it.
        return vm.current_frame;
    }

    // (vm_jit_method_enter_stack used to do the same work as the
    // inlined stack prologue does post-J.10. The inlined version
    // is the only path now; the helper is gone.)

    // Runtime-callout from JIT'd SEND. Calls the existing sendSym
    // dispatch; on success returns the result Oop; on failure stashes
    // the error tag in vm.jit_error and returns NIL. JIT'd code is
    // expected to check vm.jit_error immediately after the call.
    pub export fn vm_jit_send(
        vm: *Vm,
        receiver: Oop,
        sel_sym: Oop,
        args_ptr: [*]const Oop,
        arity: u32,
    ) callconv(.c) Oop {
        const slice: []const Oop = if (arity == 0) &[_]Oop{} else args_ptr[0..arity];
        return vm.sendSym(receiver, sel_sym, slice) catch |e| {
            vm.jit_error = @intFromError(e);
            return oop_mod.NIL;
        };
    }

    // Slow-path SEND with side-effect of populating a *bimorphic*
    // inline cache. ic_data is a 6-quad block:
    //   [0] cached_class_a   [1] cached_method_a   [2] bl_offset_a
    //   [3] cached_class_b   [4] cached_method_b   [5] bl_offset_b
    //
    // On miss: pick a slot to fill — the first empty one if any,
    // otherwise LRU-evict entry A (we don't track recency, so this
    // is an approximation). Write the slot's class/method, patch
    // its BL to point at the (possibly-inlined-stub) entry.
    pub export fn vm_jit_send_caching(
        vm: *Vm,
        receiver: Oop,
        sel_sym: Oop,
        args_ptr: [*]const Oop,
        arity: u32,
        ic_data: [*]u64,
    ) callconv(.c) Oop {
        // Pin receiver and sel_sym across the sendSym dispatch. Without
        // this, a GC fired anywhere under sendSym leaves these Zig
        // locals pointing at moved-from from-space, and the post-call
        // classOf / lookupBySym below would return forwarding pointers
        // dressed as classes/methods — which the IC fill code below
        // would then write into ic_data as if they were valid roots,
        // corrupting the cache and feeding the next GC stale pointers
        // to follow.
        var receiver_pin: Oop = receiver;
        var sel_sym_pin: Oop = sel_sym;
        var slot_ptrs: [2]?*Oop = .{ &receiver_pin, &sel_sym_pin };
        var pin = RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 2 };
        vm.root_pin = &pin;
        defer vm.root_pin = pin.parent;

        const slice: []const Oop = if (arity == 0) &[_]Oop{} else args_ptr[0..arity];
        const result = vm.sendSym(receiver_pin, sel_sym_pin, slice) catch |e| {
            vm.jit_error = @intFromError(e);
            return oop_mod.NIL;
        };
        const start_class = vm.classOf(receiver_pin);
        const method = method_mod.lookupBySym(start_class, sel_sym_pin);
        if (oop_mod.isHeapPtr(method)) {
            const kind = oop_mod.toInt(object.slot(method, object.SLOT_METHOD_KIND));
            // Methods reached via a JIT'd IC dispatch are by
            // definition hot — there's a JIT'd caller looping into
            // them. Pre-bump HOT_COUNT so the *next* invocation
            // tier-ups instead of waiting 50 calls. For one-shot
            // benchmarks (alloc, sum, count) this means the
            // method's body becomes JIT'd by the second eval, with
            // its own SEND-site stubs (including alloc) firing
            // from the third onward.
            if (kind == object.METHOD_KIND_BYTECODE) {
                const cnt_oop = object.slot(method, object.SLOT_METHOD_HOT_COUNT);
                const cnt: i64 = if (oop_mod.isInt(cnt_oop)) oop_mod.toInt(cnt_oop) else 0;
                if (cnt >= 0 and cnt < HOT_THRESHOLD) {
                    object.setSlot(method, object.SLOT_METHOD_HOT_COUNT, oop_mod.fromInt(HOT_THRESHOLD));
                }
            }
            // Inline-alloc stub for `Class>>new` (PRIM_CLASS_NEW).
            // Bake the ivar count of the receiver class into the stub
            // so the inline path does heap-bump + header init + slot
            // zeroing without any function call. Bail to
            // vm_jit_alloc_slow on overflow vs gc_threshold.
            if (kind == object.METHOD_KIND_PRIMITIVE) {
                const prim_id = oop_mod.toInt(object.slot(method, object.SLOT_METHOD_PRIMITIVE));
                if (prim_id == @import("prims.zig").PRIM_CLASS_NEW and oop_mod.isHeapPtr(receiver_pin)) {
                    if (vm.jit_buf) |*buf| {
                        const ivar_count = class_mod.countIvars(receiver_pin);
                        const slot_base: usize = if (ic_data[0] == 0) 0 else if (ic_data[3] == 0) 3 else 0;
                        const bl_off: u64 = ic_data[slot_base + 2];
                        const bl_addr: u64 = @intFromPtr(buf.bytes.ptr) + bl_off;

                        buf.markWritable();
                        ic_data[slot_base + 0] = start_class;
                        ic_data[slot_base + 1] = method;

                        const jit_mod = @import("jit.zig");
                        const slow_addr: u64 = @intFromPtr(&Vm.vm_jit_alloc_slow);
                        const stub_offset: ?u32 = jit_mod.emitAllocStubExt(buf, ivar_count, slow_addr);
                        if (stub_offset) |so| {
                            const target_addr: u64 = @intFromPtr(buf.bytes.ptr) + so;
                            const delta_bytes: i64 = @as(i64, @intCast(target_addr)) - @as(i64, @intCast(bl_addr));
                            const off_words: i32 = @intCast(@divExact(delta_bytes, 4));
                            const imm26: u32 = @as(u32, @bitCast(off_words)) & 0x03FFFFFF;
                            const new_bl: u32 = 0x94000000 | imm26;
                            const bl_ptr: *u32 = @ptrFromInt(bl_addr);
                            bl_ptr.* = new_bl;
                        }
                        buf.markExecutable();
                    }
                }
            }
            if (kind == object.METHOD_KIND_NATIVE) {
                if (vm.jit_buf) |*buf| {
                    // Pick the entry to (re)fill.
                    //  - If A is empty (class_a == 0): fill A.
                    //  - Else if B is empty: fill B.
                    //  - Else: this is a third-class arrival; evict A.
                    //    (Without recency tracking, A is a reasonable
                    //    default — the first-installed class.)
                    const slot_base: usize = if (ic_data[0] == 0) 0 else if (ic_data[3] == 0) 3 else 0;

                    const entry_offset_i: i64 = oop_mod.toInt(object.slot(method, object.SLOT_METHOD_NATIVE_ENTRY));
                    const entry_offset: u32 = @intCast(entry_offset_i);
                    const bl_off: u64 = ic_data[slot_base + 2];
                    const bl_addr: u64 = @intFromPtr(buf.bytes.ptr) + bl_off;

                    buf.markWritable();
                    ic_data[slot_base + 0] = start_class;
                    ic_data[slot_base + 1] = method;

                    // Try to generate an inline stub for the target;
                    // fall back to the full method's entry if the
                    // bytecode shape isn't recognised.
                    const jit_mod = @import("jit.zig");
                    // The IC entry's runtime address (slot containing
                    // [class, method, bl_offset]) — the stub bakes
                    // this so that on bail it can re-load
                    // cached_method from a GC-current slot rather
                    // than from a stack-saved Oop that may have
                    // gone stale across a deeper-bail's GC fire.
                    const ic_entry_addr: u64 = @intFromPtr(ic_data + slot_base);
                    const stub_offset: ?u32 = jit_mod.tryGenerateInlineStub(
                        buf, method, entry_offset, start_class, ic_entry_addr, &vm.globals,
                    );
                    const target_offset: u32 = stub_offset orelse entry_offset;
                    const target_addr: u64 = @intFromPtr(buf.bytes.ptr) + target_offset;

                    const delta_bytes: i64 = @as(i64, @intCast(target_addr)) - @as(i64, @intCast(bl_addr));
                    const off_words: i32 = @intCast(@divExact(delta_bytes, 4));
                    const imm26: u32 = @as(u32, @bitCast(off_words)) & 0x03FFFFFF;
                    const new_bl: u32 = 0x94000000 | imm26;
                    const bl_ptr: *u32 = @ptrFromInt(bl_addr);
                    bl_ptr.* = new_bl;
                    buf.markExecutable();
                }
            }
        }
        return result;
    }

    pub export fn vm_jit_method_leave(vm: *Vm, pin: *BcPin) callconv(.c) void {
        vm.bc_pin = pin.parent;
        vm.current_frame = pin.saved_frame;
        vm.current_method_frame = pin.saved_method_frame;
        vm.current_method_class = pin.saved_method_class;
    }

    fn invokeNativeMethod(self: *Vm, method: Oop, receiver: Oop, args: []const Oop) EvalError!Oop {
        const offset: usize = @intCast(oop_mod.toInt(object.slot(method, object.SLOT_METHOD_NATIVE_ENTRY)));
        const buf = &(self.jit_buf orelse return error.NotImplemented);
        const code_ptr = buf.bytes.ptr + offset;
        const fn_ptr: NativeFn = @ptrCast(@alignCast(code_ptr));
        // Repackage the args slice into individual register-arg slots.
        // The callee reads only as many as its declared arity; unused
        // slots are NIL and ignored.
        const a0: Oop = if (args.len > 0) args[0] else oop_mod.NIL;
        const a1: Oop = if (args.len > 1) args[1] else oop_mod.NIL;
        const a2: Oop = if (args.len > 2) args[2] else oop_mod.NIL;
        const a3: Oop = if (args.len > 3) args[3] else oop_mod.NIL;
        const result = fn_ptr(self, method, receiver, a0, a1, a2, a3);
        if (self.jit_error != 0) {
            const err: EvalError = @errorCast(@errorFromInt(@as(u16, @intCast(self.jit_error))));
            self.jit_error = 0;
            return err;
        }
        return result;
    }

    // Public byte-offsets for the JIT to embed in load/store
    // instructions. Centralised so eval.zig and jit.zig agree.
    pub const VM_JIT_ERROR_OFFSET: u32 = @offsetOf(Vm, "jit_error");
    pub const VM_CURRENT_FRAME_OFFSET: u32 = @offsetOf(Vm, "current_frame");
    pub const VM_CURRENT_METHOD_FRAME_OFFSET: u32 = @offsetOf(Vm, "current_method_frame");
    pub const VM_CURRENT_METHOD_CLASS_OFFSET: u32 = @offsetOf(Vm, "current_method_class");
    pub const VM_BC_PIN_OFFSET: u32 = @offsetOf(Vm, "bc_pin");
    pub const VM_BC_JIT_ZERO_SP_OFFSET: u32 = @offsetOf(Vm, "bc_jit_zero_sp");
    pub const VM_HEAP_OFFSET: u32 = @offsetOf(Vm, "heap");
    pub const VM_SMALLINT_CLASS_OFFSET: u32 =
        @offsetOf(Vm, "globals") + @offsetOf(@import("globals.zig").Globals, "smallinteger_class");
    pub const VM_FRAME_CLASS_OFFSET: u32 =
        @offsetOf(Vm, "globals") + @offsetOf(@import("globals.zig").Globals, "frame_class");

    pub const BCPIN_SP_PTR_OFFSET: u32 = @offsetOf(BcPin, "sp_ptr");
    pub const BCPIN_PARENT_OFFSET: u32 = @offsetOf(BcPin, "parent");
    pub const BCPIN_SAVED_FRAME_OFFSET: u32 = @offsetOf(BcPin, "saved_frame");
    pub const BCPIN_SAVED_METHOD_FRAME_OFFSET: u32 = @offsetOf(BcPin, "saved_method_frame");
    pub const BCPIN_SAVED_METHOD_CLASS_OFFSET: u32 = @offsetOf(BcPin, "saved_method_class");

    pub const HEAP_USED_OFFSET: u32 =
        @offsetOf(@import("heap.zig").Heap, "used");
    pub const HEAP_GC_THRESHOLD_OFFSET: u32 =
        @offsetOf(@import("heap.zig").Heap, "gc_threshold");
    pub const HEAP_ACTIVE_BASE_ADDR_OFFSET: u32 =
        @offsetOf(@import("heap.zig").Heap, "active_base_addr");

    // Add a JIT IC slot pointer to the GC root list, lazily growing
    // jit_ic_slots when needed. Failures (page allocator OOM) are
    // swallowed: the IC just doesn't get registered, which leaves a
    // small leak but doesn't crash. This is hot enough that the
    // grow path is rare — jit_ic_slots starts at 1024 entries and
    // doubles each time.
    pub fn registerJitIcSlot(self: *Vm, slot_ptr: [*]u64) void {
        const allocator = std.heap.page_allocator;
        if (self.jit_ic_count >= self.jit_ic_slots.len) {
            const new_len: usize = if (self.jit_ic_slots.len == 0) 1024 else self.jit_ic_slots.len * 2;
            const new_buf = if (self.jit_ic_slots.len == 0)
                allocator.alloc(?[*]u64, new_len) catch return
            else
                allocator.realloc(self.jit_ic_slots, new_len) catch return;
            var i = self.jit_ic_count;
            while (i < new_len) : (i += 1) new_buf[i] = null;
            self.jit_ic_slots = new_buf;
        }
        self.jit_ic_slots[self.jit_ic_count] = slot_ptr;
        self.jit_ic_count += 1;
    }

    // Invalidate every registered JIT IC entry whose cached_method
    // has selector == sel_sym. Called when a method is redefined so
    // existing call sites stop dispatching the old body. Clearing the
    // cached_class to 0 is sufficient: the dispatch path compares
    // class oops with `cmp`, and 0 never equals a real heap class
    // pointer, so the site falls through to the IC-miss handler and
    // refills against the new method.
    pub fn invalidateJitICs(self: *Vm, sel_sym: Oop) void {
        if (self.jit_ic_count == 0) return;
        if (self.jit_buf) |*buf| buf.markWritable();
        defer if (self.jit_buf) |*buf| buf.markExecutable();
        var i: u32 = 0;
        while (i < self.jit_ic_count) : (i += 1) {
            const slot_opt = self.jit_ic_slots[i];
            const slot_ptr = slot_opt orelse continue;
            const cached_method = slot_ptr[1];
            if (!oop_mod.isHeapPtr(cached_method)) continue;
            const sel = object.slot(cached_method, object.SLOT_METHOD_SELECTOR);
            if (sel == sel_sym) {
                slot_ptr[0] = 0;
                slot_ptr[1] = 0;
            }
        }
    }

    // Append a root to gc_root_buf, growing the buffer on demand.
    // Used during collectGarbage to drive root accumulation without
    // pre-computing an upper bound.
    pub fn pushRoot(self: *Vm, n: *usize, ptr: *Oop) !void {
        if (n.* >= self.gc_root_buf.len) {
            try self.ensureRootCapacity(n.* + 1);
        }
        self.gc_root_buf[n.*] = ptr;
        n.* += 1;
    }

    // Grow gc_root_buf to at least `min_cap` entries. Reused across
    // collectGarbage calls so the typical fast path is a length
    // comparison and a return.
    pub fn ensureRootCapacity(self: *Vm, min_cap: usize) !void {
        if (self.gc_root_buf.len >= min_cap) return;
        const allocator = std.heap.page_allocator;
        var new_len: usize = if (self.gc_root_buf.len == 0) 4096 else self.gc_root_buf.len;
        while (new_len < min_cap) new_len *= 2;
        const new_buf = if (self.gc_root_buf.len == 0)
            try allocator.alloc(*Oop, new_len)
        else
            try allocator.realloc(self.gc_root_buf, new_len);
        self.gc_root_buf = new_buf;
    }

    // Exposed for JIT-emitted maybe-GC slow path. If a previous error
    // is already in flight (jit_error != 0), bail out: the unwinding
    // chain is on its way back and we don't want to do recoverable
    // work or risk a second OOM that masks the original failure.
    pub export fn vm_jit_collect(vm: *Vm) callconv(.c) void {
        if (vm.jit_error != 0) return;
        vm.collectGarbage() catch |e| {
            vm.jit_error = @intFromError(e);
        };
    }

    // Resolve a global by symbol; called from JIT'd `push_global`.
    // Stashes UndefinedVariable on jit_error if the lookup misses.
    pub export fn vm_jit_lookup_global(vm: *Vm, sym: Oop) callconv(.c) Oop {
        if (!dict.hasSym(vm.globals.smalltalk, sym)) {
            vm.jit_error = @intFromError(error.UndefinedVariable);
            return oop_mod.NIL;
        }
        return dict.lookupBySym(vm.globals.smalltalk, sym);
    }

    // Slow path for the inline alloc stub. Called when the inline
    // bump-pointer would push past gc_threshold. Tries an allocation;
    // on OOM, runs GC and retries once.
    pub export fn vm_jit_alloc_slow(vm: *Vm, class: Oop, n_slots: u32) callconv(.c) Oop {
        if (vm.heap.allocSlots(class, n_slots)) |o| {
            return o;
        } else |e1| {
            if (e1 == error.OutOfMemory) {
                // Pin `class` across the GC retry. Otherwise the
                // second allocSlots call below would write a moved-
                // from class oop into the new object's hdr.class
                // (allocSlots doesn't dereference the oop, just
                // stores it), seeding a stale pointer for every
                // future GC to chase.
                var class_pin: Oop = class;
                var slot_ptrs: [1]?*Oop = .{&class_pin};
                var pin = RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 1 };
                vm.root_pin = &pin;
                defer vm.root_pin = pin.parent;
                vm.collectGarbage() catch |e| {
                    vm.jit_error = @intFromError(e);
                    return oop_mod.NIL;
                };
                if (vm.heap.allocSlots(class_pin, n_slots)) |o2| {
                    return o2;
                } else |e2| {
                    vm.jit_error = @intFromError(e2);
                    return oop_mod.NIL;
                }
            }
            vm.jit_error = @intFromError(e1);
            return oop_mod.NIL;
        }
    }

    // Hot-counter and tier-up gate. Called from invokeMethod before
    // dispatching a bytecode method; on the call where the counter
    // crosses the threshold we attempt a JIT compile. On success the
    // method's kind flips to NATIVE for all subsequent invocations.
    // Failure (unsupported bytecode shape) sets HOT_COUNT to the
    // sentinel -1 so we never retry.
    const HOT_THRESHOLD: i64 = 50;
    fn maybeTierUp(self: *Vm, method: Oop) void {
        const cnt_oop = object.slot(method, object.SLOT_METHOD_HOT_COUNT);
        const cnt: i64 = if (oop_mod.isInt(cnt_oop)) oop_mod.toInt(cnt_oop) else 0;
        if (cnt < 0) return; // sentinel: previously failed
        if (cnt < HOT_THRESHOLD) {
            object.setSlot(method, object.SLOT_METHOD_HOT_COUNT, oop_mod.fromInt(cnt + 1));
            return;
        }
        // cnt == HOT_THRESHOLD → first attempt.
        const jit_mod = @import("jit.zig");
        if (self.jit_buf == null) {
            self.jit_buf = jit_mod.JitBuf.alloc(64 * 1024) catch {
                object.setSlot(method, object.SLOT_METHOD_HOT_COUNT, oop_mod.fromInt(-1));
                return;
            };
        }
        const result = jit_mod.compileMethod(self, method, &self.jit_buf.?) orelse {
            object.setSlot(method, object.SLOT_METHOD_HOT_COUNT, oop_mod.fromInt(-1));
            return;
        };
        object.setSlot(method, object.SLOT_METHOD_NATIVE_ENTRY, oop_mod.fromInt(@intCast(result.offset)));
        // Reuse HOT_COUNT to carry the eval-stack depth into the
        // enter helper. After tier-up the slot is no longer used for
        // counting.
        object.setSlot(method, object.SLOT_METHOD_HOT_COUNT, oop_mod.fromInt(@intCast(result.max_depth)));
        object.setSlot(method, object.SLOT_METHOD_KIND, oop_mod.fromInt(object.METHOD_KIND_NATIVE));
    }

    fn evalBlock(self: *Vm, params_arr: Oop, temps_arr: Oop, body_arr: Oop) EvalError!Oop {
        const block = self.heap.allocSlots(self.globals.block_closure_class, object.BLOCK_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(block, object.SLOT_BLOCK_PARENT_FRAME, self.current_frame);
        object.setSlot(block, object.SLOT_BLOCK_PARAMS, params_arr);
        object.setSlot(block, object.SLOT_BLOCK_TEMPS, temps_arr);
        object.setSlot(block, object.SLOT_BLOCK_BODY, body_arr);
        object.setSlot(block, object.SLOT_BLOCK_HOME_METHOD, self.current_method_frame);
        return block;
    }

    // Convenience for primitives that have a byte-string selector.
    // Interns the selector once and dispatches via the fast path.
    // Pins receiver across newSymbol so the contract holds even if
    // newSymbol gains a GC retry path later.
    pub fn send(self: *Vm, receiver: Oop, selector: []const u8, args: []const Oop) EvalError!Oop {
        var recv_pin: Oop = receiver;
        var sym_pin: Oop = oop_mod.NIL;
        var slot_ptrs: [2]?*Oop = .{ &recv_pin, &sym_pin };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 2 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;
        sym_pin = dict.newSymbol(self.heap, &self.globals, selector) catch return error.OutOfMemory;
        return self.sendSym(recv_pin, sym_pin, args);
    }

    pub fn sendSym(self: *Vm, receiver: Oop, sel_sym: Oop, args: []const Oop) EvalError!Oop {
        return self.sendSymFrom(receiver, self.classOf(receiver), sel_sym, args);
    }

    pub fn sendSymFrom(self: *Vm, receiver: Oop, start_class: Oop, sel_sym: Oop, args: []const Oop) EvalError!Oop {
        const method = method_mod.lookupBySym(start_class, sel_sym);
        if (oop_mod.isNil(method)) return self.dispatchDoesNotUnderstand(receiver, start_class, sel_sym, args);
        return self.invokeMethod(method, receiver, args);
    }

    /// Slow path for unknown sends: reify the failed call as a
    /// `Message` (selector + Array of arguments) and re-dispatch
    /// `doesNotUnderstand:` against the receiver. If the receiver's
    /// class chain has no `doesNotUnderstand:` method (only possible
    /// on a malformed image where Object's default is gone),
    /// surface the original Zig error.
    fn dispatchDoesNotUnderstand(self: *Vm, receiver: Oop, start_class: Oop, sel_sym: Oop, args: []const Oop) EvalError!Oop {
        const dnu_method = method_mod.lookupBySym(start_class, self.globals.sym_does_not_understand);
        if (oop_mod.isNil(dnu_method)) return error.DoesNotUnderstand;
        if (!oop_mod.isHeapPtr(self.globals.message_class)) return error.DoesNotUnderstand;

        // Pin receiver/selector/args across the allocations below.
        var recv_pin: Oop = receiver;
        var sel_pin: Oop = sel_sym;
        var args_arr_pin: Oop = oop_mod.NIL;
        var msg_pin: Oop = oop_mod.NIL;
        var slot_ptrs: [4]?*Oop = .{ &recv_pin, &sel_pin, &args_arr_pin, &msg_pin };
        var pin = RootPin{ .parent = self.root_pin, .slots = &slot_ptrs, .n = 4 };
        self.root_pin = &pin;
        defer self.root_pin = pin.parent;

        args_arr_pin = try self.heap.allocSlots(self.globals.array_class, @intCast(args.len));
        for (args, 0..) |a, i| object.setSlot(args_arr_pin, @intCast(i), a);
        msg_pin = try self.heap.allocSlots(self.globals.message_class, object.MESSAGE_INST_SIZE);
        object.setSlot(msg_pin, object.SLOT_MESSAGE_SELECTOR, sel_pin);
        object.setSlot(msg_pin, object.SLOT_MESSAGE_ARGUMENTS, args_arr_pin);

        var dnu_args: [1]Oop = .{msg_pin};
        return self.invokeMethod(dnu_method, recv_pin, &dnu_args);
    }

    // Test-only convenience: parse a JSON AST string and evaluate.
    pub fn evalSource(self: *Vm, scratch: std.mem.Allocator, json: []const u8) EvalError!Oop {
        const node = ast.parse(self.heap, &self.globals, scratch, json) catch |e| switch (e) {
            error.InvalidJson => return error.NotImplemented,
            error.UnknownNodeKind => return error.UnknownNodeClass,
            error.MissingField, error.BadFieldType => return error.NotImplemented,
            error.IntOverflow => return error.IntOverflow,
            error.OutOfMemory => return error.OutOfMemory,
            error.DictionaryFull => return error.DictionaryFull,
        };
        return self.eval(node);
    }
};

// Read the byte payload of a Symbol heap object as a slice. Asserts
// the receiver is in fact a byte object — caller is responsible for
// passing a Symbol or String.
pub fn symbolBytes(sym: Oop) []const u8 {
    const hdr = object.headerOf(sym);
    return object.bytesOf(sym)[0..hdr.size];
}

// Entry trampoline for a freshly-forked Process. The first time the
// scheduler swaps INTO this process, control lands here (via
// scheduler.prepare → scheduler.trampoline → us). We pull the block
// off the Process oop, run it, stash the return value, mark the
// Process terminated, and hand control to the next runnable thread
// (typically the main host thread if nothing else is queued).
fn processEntry(arg: ?*anyopaque) callconv(.c) noreturn {
    const vm: *Vm = @ptrCast(@alignCast(arg.?));
    const proc = vm.current_process;
    const block = object.slot(proc, object.SLOT_PROCESS_BLOCK);
    var result: Oop = oop_mod.NIL;
    if (oop_mod.isHeapPtr(block)) {
        result = vm.send(block, "value", &.{}) catch oop_mod.NIL;
    }
    object.setSlot(proc, object.SLOT_PROCESS_RESULT, result);
    object.setSlot(proc, object.SLOT_PROCESS_STATE, vm.globals.sym_terminated);
    // Find someone to hand the host thread back to. If the runnable
    // list is empty, every other Process has finished too — but the
    // host's main Process is special-cased: it's not on the runnable
    // list when active, so when its yield returns it picks up where
    // it left off. Reach into it directly here.
    vm.scheduleNext() catch {};
    // If we get here, the main Process must have been re-enqueued
    // somewhere along the way and we already swapped to it. Reaching
    // this line means scheduleNext found nothing — that's a bug.
    @panic("processEntry: no runnable Process after termination");
}

pub fn invokeBlock(vm: *Vm, block: Oop, args: []const Oop) EvalError!Oop {
    const body_arr = object.slot(block, object.SLOT_BLOCK_BODY);
    if (oop_mod.isNil(body_arr)) return error.NotImplemented;
    // Bytecode body: ByteArray (FLAG_BYTES). Dispatch to the bytecode
    // interpreter; AST blocks fall through to the legacy loop below.
    if ((object.headerOf(body_arr).flags & object.FLAG_BYTES) != 0) {
        return invokeBytecodeBlock(vm, block, args);
    }
    const params_arr = object.slot(block, object.SLOT_BLOCK_PARAMS);
    const temps_arr = object.slot(block, object.SLOT_BLOCK_TEMPS);
    const parent = object.slot(block, object.SLOT_BLOCK_PARENT_FRAME);
    const home_method = object.slot(block, object.SLOT_BLOCK_HOME_METHOD);

    const params_count = object.headerOf(params_arr).size;
    const temps_count = object.headerOf(temps_arr).size;
    if (args.len != params_count) return error.ArityMismatch;

    const total_values: u32 = params_count + temps_count;
    const frame_size: u32 = object.FRAME_VALUES_OFFSET + total_values;
    const frame = vm.heap.allocSlots(vm.globals.frame_class, frame_size) catch return error.OutOfMemory;
    object.setSlot(frame, object.SLOT_FRAME_PARENT, parent);
    object.setSlot(frame, object.SLOT_FRAME_SOURCE, block);
    var i: u32 = 0;
    while (i < params_count) : (i += 1) {
        object.setSlot(frame, object.FRAME_VALUES_OFFSET + i, args[i]);
    }
    // Temp slots stay NIL (allocSlots zero-initializes).

    var saved_frame = vm.current_frame;
    var saved_method = vm.current_method_frame;
    vm.current_frame = frame;
    vm.current_method_frame = home_method;

    // Pin the saved Vm-state Oops: vm.eval(...) below may fire a GC
    // that moves the parent frame and the home method, but they live
    // here only as Zig stack locals. The defer would then write
    // moved-from addresses back into vm.current_frame and corrupt
    // the caller's view.
    var body_arr_pin: Oop = body_arr;
    var last: Oop = oop_mod.NIL;
    var slot_ptrs: [4]?*Oop = .{ &saved_frame, &saved_method, &body_arr_pin, &last };
    var pin = RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 4 };
    vm.root_pin = &pin;
    defer {
        vm.current_frame = saved_frame;
        vm.current_method_frame = saved_method;
        vm.root_pin = pin.parent;
    }

    const body_count = object.headerOf(body_arr_pin).size;
    if (body_count == 0) return oop_mod.NIL;
    var k: u32 = 0;
    while (k < body_count) : (k += 1) {
        last = try vm.eval(object.slot(body_arr_pin, k));
    }
    return last;
}

// Stack-based bytecode interpreter. Frame layout matches the AST
// interpreter so bytecode and AST methods can call each other freely.
// Blocks compiled to bytecode (Phase D.2) reuse the same loop with
// block-style frame setup.
pub fn invokeBytecodeMethod(vm: *Vm, method: Oop, receiver: Oop, args: []const Oop) EvalError!Oop {
    const params_arr = object.slot(method, object.SLOT_METHOD_PARAMS);
    const temps_arr = object.slot(method, object.SLOT_METHOD_TEMPS);
    if (!oop_mod.isHeapPtr(object.slot(method, object.SLOT_METHOD_BYTECODE))) return error.NotImplemented;

    const params_count = if (oop_mod.isHeapPtr(params_arr)) object.headerOf(params_arr).size else 0;
    const temps_count = if (oop_mod.isHeapPtr(temps_arr)) object.headerOf(temps_arr).size else 0;
    if (args.len != params_count) return error.ArityMismatch;

    // Method-frame value layout: [self, params..., temps...].
    const total_values: u32 = 1 + params_count + temps_count;
    const frame_size: u32 = object.FRAME_VALUES_OFFSET + total_values;
    const frame = vm.heap.allocSlots(vm.globals.frame_class, frame_size) catch return error.OutOfMemory;
    object.setSlot(frame, object.SLOT_FRAME_PARENT, oop_mod.NIL);
    object.setSlot(frame, object.SLOT_FRAME_SOURCE, method);
    object.setSlot(frame, object.FRAME_VALUES_OFFSET + 0, receiver);
    var i: u32 = 0;
    while (i < params_count) : (i += 1) {
        object.setSlot(frame, object.FRAME_VALUES_OFFSET + 1 + i, args[i]);
    }
    // Temp slots stay NIL from allocSlots.

    return runBytecodeWithPin(vm, frame, object.slot(method, object.SLOT_METHOD_DEFINING_CLASS), false);
}

// Block invocation when the block has a bytecode body. Mirrors the
// AST invokeBlock path but ends with the bytecode loop instead of an
// AST eval.
pub fn invokeBytecodeBlock(vm: *Vm, block: Oop, args: []const Oop) EvalError!Oop {
    const params_arr = object.slot(block, object.SLOT_BLOCK_PARAMS);
    const temps_arr = object.slot(block, object.SLOT_BLOCK_TEMPS);
    const parent = object.slot(block, object.SLOT_BLOCK_PARENT_FRAME);

    const params_count = object.headerOf(params_arr).size;
    const temps_count = object.headerOf(temps_arr).size;
    if (args.len != params_count) return error.ArityMismatch;

    // Block-frame value layout: [params..., temps...]. self isn't in
    // the frame; PUSH_SELF reads it via the home method's frame.
    const total_values: u32 = params_count + temps_count;
    const frame_size: u32 = object.FRAME_VALUES_OFFSET + total_values;
    const frame = vm.heap.allocSlots(vm.globals.frame_class, frame_size) catch return error.OutOfMemory;
    object.setSlot(frame, object.SLOT_FRAME_PARENT, parent);
    object.setSlot(frame, object.SLOT_FRAME_SOURCE, block);
    var i: u32 = 0;
    while (i < params_count) : (i += 1) {
        object.setSlot(frame, object.FRAME_VALUES_OFFSET + i, args[i]);
    }

    return runBytecodeWithPin(vm, frame, vm.current_method_class, true);
}

// Set up Vm bookkeeping (current_frame, current_method_frame,
// current_method_class) inside a BcPin so the saved values survive
// any GC fired by the bytecode body. The previous Zig-defer scheme
// captured the saves on the Zig stack, where GC couldn't update
// them; this single funnel keeps them in heap-walkable storage.
fn runBytecodeWithPin(vm: *Vm, frame: Oop, method_class: Oop, is_block: bool) EvalError!Oop {
    var pin = BcPin{
        .stack_base = undefined,
        .sp_ptr = undefined,
        .parent = vm.bc_pin,
        .saved_frame = vm.current_frame,
        .saved_method_frame = vm.current_method_frame,
        .saved_method_class = vm.current_method_class,
    };
    vm.current_frame = frame;
    if (!is_block) {
        vm.current_method_frame = frame;
        vm.current_method_class = method_class;
    }
    // For blocks: current_method_frame stays at the home method's
    // frame (set by callers via the frame's source slot logic);
    // current_method_class likewise unchanged.
    if (is_block) {
        const block = object.slot(frame, object.SLOT_FRAME_SOURCE);
        vm.current_method_frame = object.slot(block, object.SLOT_BLOCK_HOME_METHOD);
    }
    defer {
        vm.bc_pin = pin.parent;
        vm.current_frame = pin.saved_frame;
        vm.current_method_frame = pin.saved_method_frame;
        vm.current_method_class = pin.saved_method_class;
    }
    return runBytecode(vm, frame, is_block, &pin);
}

// Re-fetch the code/literal/values/receiver Oops for `frame`. Called
// once at start and again after every GC at a safe point. For block
// frames receiver lives in the home method's values[0]; for method
// frames it lives in this frame's own values[0].
inline fn refreshBytecodeLocals(
    frame: Oop,
    is_block: bool,
    code: *Oop,
    lits: *Oop,
    receiver: *Oop,
    code_bytes: *[]u8,
    n_instrs: *u32,
) void {
    const source = object.slot(frame, object.SLOT_FRAME_SOURCE);
    if (is_block) {
        code.* = object.slot(source, object.SLOT_BLOCK_BODY);
        lits.* = object.slot(source, object.SLOT_BLOCK_LITERALS);
        const home_method = object.slot(source, object.SLOT_BLOCK_HOME_METHOD);
        // Home method's value slot 0 is `self`; reach it through the
        // frame's inline-values area at FRAME_VALUES_OFFSET.
        receiver.* = if (oop_mod.isHeapPtr(home_method))
            object.slot(home_method, object.FRAME_VALUES_OFFSET + 0)
        else
            oop_mod.NIL;
    } else {
        code.* = object.slot(source, object.SLOT_METHOD_BYTECODE);
        lits.* = object.slot(source, object.SLOT_METHOD_LITERALS);
        receiver.* = object.slot(frame, object.FRAME_VALUES_OFFSET + 0);
    }
    const code_hdr = object.headerOf(code.*);
    code_bytes.* = object.bytesOf(code.*)[0..code_hdr.size];
    n_instrs.* = code_hdr.size / @sizeOf(@import("bytecode.zig").Instr);
}

fn runBytecode(vm: *Vm, frame_in: Oop, is_block: bool, pin: *BcPin) EvalError!Oop {
    const bc = @import("bytecode.zig");
    _ = frame_in; // Re-read from vm.current_frame each refresh so a
    // mid-eval GC doesn't leave us with a stale Zig-local.

    // NIL-init the eval stack so any slot above sp that the GC root
    // walker still happens to inspect is a sentinel (NIL is a no-op
    // for copy()), not C-stack garbage that may pass isHeapPtr.
    var stack: [256]Oop = .{oop_mod.NIL} ** 256;
    var sp: u32 = 0;
    var pc: u32 = 0;

    var code: Oop = oop_mod.NIL;
    var lits: Oop = oop_mod.NIL;
    var receiver: Oop = oop_mod.NIL;
    var code_bytes: []u8 = &.{};
    var n_instrs: u32 = 0;
    refreshBytecodeLocals(vm.current_frame, is_block, &code, &lits, &receiver, &code_bytes, &n_instrs);

    // Finish populating the BcPin (its saves are already valid; we
    // just need to bind the stack so collectGarbage can pin its
    // contents) and register on the chain.
    pin.stack_base = &stack;
    pin.sp_ptr = &sp;
    vm.bc_pin = pin;

    var saved_gc_gen: u64 = vm.heap.gc_generation;
    while (pc < n_instrs) {
        // Detect GC that fired during a child runBytecode (or any
        // other call below us). If the generation moved, our
        // Zig-stack code/lits/values/receiver are stale.
        if (vm.heap.gc_generation != saved_gc_gen) {
            saved_gc_gen = vm.heap.gc_generation;
            refreshBytecodeLocals(vm.current_frame, is_block, &code, &lits, &receiver, &code_bytes, &n_instrs);
        }
        if (vm.bc_instr_budget == 0) {
            vm.bc_instr_budget = 256;
            try vm.maybeCollectGarbage();
            if (vm.heap.gc_generation != saved_gc_gen) {
                saved_gc_gen = vm.heap.gc_generation;
                refreshBytecodeLocals(vm.current_frame, is_block, &code, &lits, &receiver, &code_bytes, &n_instrs);
            }
        } else {
            vm.bc_instr_budget -= 1;
        }
        const instr = std.mem.readInt(u32, code_bytes[pc * 4 ..][0..4], .little);
        pc += 1;
        const op = bc.opOf(instr);
        switch (op) {
            .push_lit => {
                stack[sp] = object.slot(lits, bc.operandOf(instr));
                sp += 1;
            },
            .push_self => {
                stack[sp] = receiver;
                sp += 1;
            },
            .push_local => {
                // Operand is a value-array offset (relative to the
                // frame's inline values). For method frames slot 0
                // is `self`; the bytecode compiler emits PUSH_SELF
                // for that case so we never see operand 0 here for
                // methods. For block frames slot 0 is the first
                // param (no off-by-one).
                stack[sp] = object.slot(vm.current_frame, object.FRAME_VALUES_OFFSET + bc.operandOf(instr));
                sp += 1;
            },
            .store_local => {
                object.setSlot(vm.current_frame, object.FRAME_VALUES_OFFSET + bc.operandOf(instr), stack[sp - 1]);
            },
            .pop => sp -= 1,
            .push_nil => {
                stack[sp] = oop_mod.NIL;
                sp += 1;
            },
            .push_true => {
                stack[sp] = oop_mod.TRUE;
                sp += 1;
            },
            .push_false => {
                stack[sp] = oop_mod.FALSE;
                sp += 1;
            },
            .push_global => {
                const sym = object.slot(lits, bc.operandOf(instr));
                if (!dict.hasSym(vm.globals.smalltalk, sym)) return error.UndefinedVariable;
                stack[sp] = dict.lookupBySym(vm.globals.smalltalk, sym);
                sp += 1;
            },
            .send => {
                const arity = bc.sendArityOf(instr);
                const sel_idx = bc.sendSelOf(instr);
                const sel_sym = object.slot(lits, sel_idx);
                const recv = stack[sp - 1 - arity];

                // SmallInt arithmetic fast path — same as evalSend.
                // Bypasses method lookup, IC, and primitive dispatch
                // for the tightest loops. Comparisons never overflow;
                // arithmetic falls through on overflow so the
                // primitive can promote to Large.
                if (arity == 1 and oop_mod.isInt(recv) and oop_mod.isInt(stack[sp - 1])) {
                    const g = &vm.globals;
                    const a = oop_mod.toInt(recv);
                    const b = oop_mod.toInt(stack[sp - 1]);
                    var fast: ?Oop = null;
                    if (sel_sym == g.sym_lt) fast = oop_mod.fromBool(a < b)
                    else if (sel_sym == g.sym_le) fast = oop_mod.fromBool(a <= b)
                    else if (sel_sym == g.sym_gt) fast = oop_mod.fromBool(a > b)
                    else if (sel_sym == g.sym_ge) fast = oop_mod.fromBool(a >= b)
                    else if (sel_sym == g.sym_plus) {
                        const s = a +% b;
                        if (((a ^ s) & (b ^ s)) >= 0 and oop_mod.fitsSmallInt(s)) fast = oop_mod.fromInt(s);
                    } else if (sel_sym == g.sym_minus) {
                        const d = a -% b;
                        if (((a ^ b) & (a ^ d)) >= 0 and oop_mod.fitsSmallInt(d)) fast = oop_mod.fromInt(d);
                    } else if (sel_sym == g.sym_times) {
                        const m = @mulWithOverflow(a, b);
                        if (m[1] == 0 and oop_mod.fitsSmallInt(m[0])) fast = oop_mod.fromInt(m[0]);
                    }
                    if (fast) |v| {
                        sp -= 2;
                        stack[sp] = v;
                        sp += 1;
                        continue;
                    }
                }

                const send_args = stack[sp - arity .. sp];
                const result = try vm.sendSym(recv, sel_sym, send_args);
                sp -= arity + 1;
                stack[sp] = result;
                sp += 1;
            },
            .push_block_ast => {
                // Operand is the literal index of a 4-slot Array
                // [params, temps, bc_or_ast_body, literals]. The
                // compiler stores this template as a literal so
                // PUSH_BLOCK_AST is just a heap allocation + 6 slot
                // writes.
                const tmpl = object.slot(lits, bc.operandOf(instr));
                const params = object.slot(tmpl, 0);
                const temps = object.slot(tmpl, 1);
                const body = object.slot(tmpl, 2);
                const block_lits = object.slot(tmpl, 3);
                const block = vm.heap.allocSlots(vm.globals.block_closure_class, object.BLOCK_INST_SIZE) catch return error.OutOfMemory;
                object.setSlot(block, object.SLOT_BLOCK_PARENT_FRAME, vm.current_frame);
                object.setSlot(block, object.SLOT_BLOCK_PARAMS, params);
                object.setSlot(block, object.SLOT_BLOCK_TEMPS, temps);
                object.setSlot(block, object.SLOT_BLOCK_BODY, body);
                object.setSlot(block, object.SLOT_BLOCK_HOME_METHOD, vm.current_method_frame);
                object.setSlot(block, object.SLOT_BLOCK_LITERALS, block_lits);
                stack[sp] = block;
                sp += 1;
            },
            .return_top => {
                if (sp == 0) return receiver;
                return stack[sp - 1];
            },
            .jump => {
                const off = bc.signedOperandOf(instr);
                pc = @intCast(@as(i64, pc) + off);
            },
            .jump_if_false => {
                const top = stack[sp - 1];
                sp -= 1;
                if (top == oop_mod.FALSE) {
                    const off = bc.signedOperandOf(instr);
                    pc = @intCast(@as(i64, pc) + off);
                }
            },
            .jump_if_true => {
                const top = stack[sp - 1];
                sp -= 1;
                if (top == oop_mod.TRUE) {
                    const off = bc.signedOperandOf(instr);
                    pc = @intCast(@as(i64, pc) + off);
                }
            },
            else => return error.NotImplemented,
        }
    }
    return receiver;
}

pub fn invokeAstMethod(vm: *Vm, method: Oop, receiver: Oop, args: []const Oop) EvalError!Oop {
    const body_arr = object.slot(method, object.SLOT_METHOD_BODY);
    if (oop_mod.isNil(body_arr)) return error.NotImplemented;
    const params_arr = object.slot(method, object.SLOT_METHOD_PARAMS);
    const temps_arr = object.slot(method, object.SLOT_METHOD_TEMPS);
    const params_count = object.headerOf(params_arr).size;
    const temps_count = object.headerOf(temps_arr).size;
    if (args.len != params_count) return error.ArityMismatch;

    // Frame value layout: [self, params..., temps...]. names are
    // virtualized through frame.source by frame_mod.findBySym.
    const total_values: u32 = 1 + params_count + temps_count;
    const frame_size: u32 = object.FRAME_VALUES_OFFSET + total_values;
    const frame = vm.heap.allocSlots(vm.globals.frame_class, frame_size) catch return error.OutOfMemory;
    object.setSlot(frame, object.SLOT_FRAME_PARENT, oop_mod.NIL);
    object.setSlot(frame, object.SLOT_FRAME_SOURCE, method);
    object.setSlot(frame, object.FRAME_VALUES_OFFSET + 0, receiver);
    var i: u32 = 0;
    while (i < params_count) : (i += 1) {
        object.setSlot(frame, object.FRAME_VALUES_OFFSET + 1 + i, args[i]);
    }
    // Temp slots stay NIL.

    var body_arr_pin: Oop = body_arr;
    var frame_pin: Oop = frame;
    var receiver_pin: Oop = receiver;

    // Pin saved_frame/saved_method/saved_class via BcPin so that GC's
    // bc_pin walk runs addStackFrameSlots on the saved frames if
    // they're stack-allocated (JIT-emitted frames). A bare RootPin
    // would pin their Oops as roots but wouldn't walk their slots —
    // so a JIT'd caller (e.g. dictChurn) calling into an AST callee
    // (Dictionary>>at:put:) would have its frame's source/literals
    // skipped by the safe-point GC fired below, leaving stale
    // Symbol oops in the literal pool.
    var bcpin = BcPin{
        .stack_base = undefined,
        .sp_ptr = &vm.bc_jit_zero_sp,
        .parent = vm.bc_pin,
        .saved_frame = vm.current_frame,
        .saved_method_frame = vm.current_method_frame,
        .saved_method_class = vm.current_method_class,
    };
    vm.bc_pin = &bcpin;
    vm.current_frame = frame;
    vm.current_method_frame = frame;
    vm.current_method_class = object.slot(method, object.SLOT_METHOD_DEFINING_CLASS);

    // Pin body_arr/frame/receiver via RootPin (single-Oop walk).
    var slot_ptrs: [3]?*Oop = .{ &body_arr_pin, &frame_pin, &receiver_pin };
    var rpin = RootPin{ .parent = vm.root_pin, .slots = &slot_ptrs, .n = 3 };
    vm.root_pin = &rpin;
    defer {
        // GC's bc_pin walk pins saved_frame/saved_method/saved_class,
        // so on return they hold the post-GC values.
        vm.current_frame = bcpin.saved_frame;
        vm.current_method_frame = bcpin.saved_method_frame;
        vm.current_method_class = bcpin.saved_method_class;
        vm.bc_pin = bcpin.parent;
        vm.root_pin = rpin.parent;
    }

    // Safe-point GC. AST methods don't tier up to bytecode (the
    // body uses an unsupported feature, e.g. ivar refs in user-level
    // Dictionary>>at:put:); without this, a tight outer loop calling
    // an AST method 5000+ times never reaches the bytecode-interp's
    // 256-instr safe point during the AST callee, and the heap can
    // grow without bound across calls. Cheap when below threshold.
    vm.maybeCollectGarbage() catch |e| return e;

    const body_count = object.headerOf(body_arr_pin).size;
    var k: u32 = 0;
    while (k < body_count) : (k += 1) {
        _ = vm.eval(object.slot(body_arr_pin, k)) catch |e| switch (e) {
            error.MethodReturn => {
                if (vm.return_target == frame_pin) return vm.return_value;
                return error.MethodReturn;
            },
            else => return e,
        };
    }
    return receiver_pin;
}

const bootstrap_mod = @import("bootstrap.zig");

const TestEnv = struct {
    heap: Heap,
    vm: Vm,

    fn init(self: *TestEnv) !void {
        self.heap = try Heap.init(1 * 1024 * 1024);
        const g = try bootstrap_mod.bootstrap(&self.heap);
        self.vm = .{ .heap = &self.heap, .globals = g };
    }

    fn deinit(self: *TestEnv) void {
        self.heap.deinit();
    }

    fn evalJson(self: *TestEnv, json: []const u8) EvalError!Oop {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        return self.vm.evalSource(arena.allocator(), json);
    }
};

test "var_ref to a kernel global resolves" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = try env.evalJson("{\"var_ref\":\"Object\"}");
    try std.testing.expectEqual(env.vm.globals.object_class, result);
}

test "var_ref to undefined name errors" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = env.evalJson("{\"var_ref\":\"NoSuchThing\"}");
    try std.testing.expectError(error.UndefinedVariable, result);
}

test "assign + var_ref + seq round-trip" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"seq":[
        \\  {"assign":{"name":"x","value":{"literal":{"int":42}}}},
        \\  {"var_ref":"x"}
        \\]}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 42), oop_mod.toInt(result));
}

test "send 1 + 2 returns 3" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"+","args":[{"literal":{"int":2}}]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 3), oop_mod.toInt(result));
}

test "send (3 * 4) - 5 = 7" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":3}},"selector":"*","args":[{"literal":{"int":4}}]}},"selector":"-","args":[{"literal":{"int":5}}]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 7), oop_mod.toInt(result));
}

test "send 1 < 2 returns true" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"<","args":[{"literal":{"int":2}}]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(oop_mod.TRUE, result);
}

test "send class returns the receiver's class" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"literal":{"int":42}},"selector":"class","args":[]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(env.vm.globals.smallinteger_class, result);
}

test "send to unknown selector returns DoesNotUnderstand" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"literal":{"int":1}},"selector":"flarble","args":[]}}
    ;
    const result = env.evalJson(src);
    try std.testing.expectError(error.DoesNotUnderstand, result);
}

test "printNl writes to output sink" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    env.vm.output = .{ .buffer = &buf, .allocator = std.testing.allocator };

    const src =
        \\{"send":{"receiver":{"literal":{"int":42}},"selector":"printNl","args":[]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 42), oop_mod.toInt(result));
    try std.testing.expectEqualStrings("42\n", buf.items);
}

test "send is inherited from a superclass" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"literal":{"string":"hi"}},"selector":"class","args":[]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(env.vm.globals.string_class, result);
}

test "assign overwrites existing binding" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    _ = try env.evalJson("{\"assign\":{\"name\":\"x\",\"value\":{\"literal\":{\"int\":1}}}}");
    _ = try env.evalJson("{\"assign\":{\"name\":\"x\",\"value\":{\"literal\":{\"int\":2}}}}");
    const result = try env.evalJson("{\"var_ref\":\"x\"}");
    try std.testing.expectEqual(@as(i64, 2), oop_mod.toInt(result));
}

test "block with no params: [1 + 2] value" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"literal":{"int":1}},"selector":"+","args":[{"literal":{"int":2}}]}}
        \\]}},"selector":"value","args":[]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 3), oop_mod.toInt(result));
}

test "block with one param: [:x | x * x] value: 5" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"block":{"params":["x"],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"x"},"selector":"*","args":[{"var_ref":"x"}]}}
        \\]}},"selector":"value:","args":[{"literal":{"int":5}}]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 25), oop_mod.toInt(result));
}

test "block with two params: [:x :y | x + y] value: 3 value: 4" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"block":{"params":["x","y"],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"x"},"selector":"+","args":[{"var_ref":"y"}]}}
        \\]}},"selector":"value:value:","args":[{"literal":{"int":3}},{"literal":{"int":4}}]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 7), oop_mod.toInt(result));
}

test "block temps initialize to nil and are mutable" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"block":{"params":["x"],"temps":["y"],"body":[
        \\  {"assign":{"name":"y","value":{"send":{"receiver":{"var_ref":"x"},"selector":"*","args":[{"literal":{"int":2}}]}}}},
        \\  {"send":{"receiver":{"var_ref":"y"},"selector":"+","args":[{"literal":{"int":1}}]}}
        \\]}},"selector":"value:","args":[{"literal":{"int":5}}]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 11), oop_mod.toInt(result));
}

test "block closure captures outer global" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"seq":[
        \\  {"assign":{"name":"x","value":{"literal":{"int":10}}}},
        \\  {"send":{"receiver":{"block":{"params":["y"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"x"},"selector":"+","args":[{"var_ref":"y"}]}}
        \\  ]}},"selector":"value:","args":[{"literal":{"int":5}}]}}
        \\]}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 15), oop_mod.toInt(result));
}

test "true ifTrue:ifFalse: picks the first arm" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":1}},"selector":"<","args":[{"literal":{"int":2}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\  {"block":{"params":[],"temps":[],"body":[{"literal":{"int":10}}]}},
        \\  {"block":{"params":[],"temps":[],"body":[{"literal":{"int":20}}]}}
        \\]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 10), oop_mod.toInt(result));
}

test "false ifTrue:ifFalse: picks the second arm" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"send":{"receiver":{"send":{"receiver":{"literal":{"int":5}},"selector":"<","args":[{"literal":{"int":2}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\  {"block":{"params":[],"temps":[],"body":[{"literal":{"int":10}}]}},
        \\  {"block":{"params":[],"temps":[],"body":[{"literal":{"int":20}}]}}
        \\]}}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 20), oop_mod.toInt(result));
}

test "whileTrue: counts to 10" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"seq":[
        \\  {"assign":{"name":"i","value":{"literal":{"int":0}}}},
        \\  {"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"i"},"selector":"<","args":[{"literal":{"int":10}}]}}
        \\  ]}},"selector":"whileTrue:","args":[
        \\    {"block":{"params":[],"temps":[],"body":[
        \\      {"assign":{"name":"i","value":{"send":{"receiver":{"var_ref":"i"},"selector":"+","args":[{"literal":{"int":1}}]}}}}
        \\    ]}}
        \\  ]}},
        \\  {"var_ref":"i"}
        \\]}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 10), oop_mod.toInt(result));
}

test "recursive global block: factorial" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const src =
        \\{"seq":[
        \\  {"assign":{"name":"factorial","value":{"block":{"params":["n"],"temps":[],"body":[
        \\    {"send":{"receiver":{"send":{"receiver":{"var_ref":"n"},"selector":"<","args":[{"literal":{"int":2}}]}},"selector":"ifTrue:ifFalse:","args":[
        \\      {"block":{"params":[],"temps":[],"body":[{"literal":{"int":1}}]}},
        \\      {"block":{"params":[],"temps":[],"body":[
        \\        {"send":{"receiver":{"var_ref":"n"},"selector":"*","args":[
        \\          {"send":{"receiver":{"var_ref":"factorial"},"selector":"value:","args":[
        \\            {"send":{"receiver":{"var_ref":"n"},"selector":"-","args":[{"literal":{"int":1}}]}}
        \\          ]}}
        \\        ]}}
        \\      ]}}
        \\    ]}}
        \\  ]}}}},
        \\  {"send":{"receiver":{"var_ref":"factorial"},"selector":"value:","args":[{"literal":{"int":6}}]}}
        \\]}
    ;
    const result = try env.evalJson(src);
    try std.testing.expectEqual(@as(i64, 720), oop_mod.toInt(result));
}

test "AST method: SmallInteger>>double" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Build the method body via the heap parser.
    const body_node = try ast.parse(env.vm.heap, &env.vm.globals, arena.allocator(),
        "{\"ret\":{\"send\":{\"receiver\":{\"var_ref\":\"self\"},\"selector\":\"*\",\"args\":[{\"literal\":{\"int\":2}}]}}}");
    const body_arr = try env.vm.heap.allocSlots(env.vm.globals.array_class, 1);
    object.setSlot(body_arr, 0, body_node);

    const params = try env.vm.heap.allocSlots(env.vm.globals.array_class, 0);
    const temps = try env.vm.heap.allocSlots(env.vm.globals.array_class, 0);
    const m = try method_mod.newAst(env.vm.heap, &env.vm.globals, env.vm.globals.smallinteger_class, "double", 0, params, temps, body_arr);
    try method_mod.install(env.vm.heap, &env.vm.globals, &env.vm, env.vm.globals.smallinteger_class, "double", m);

    const result = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":21}},"selector":"double","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 42), oop_mod.toInt(result));
}

test "GC reclaims unreachable allocations and kernel still works" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const used_before = env.vm.heap.used;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        _ = try env.evalJson("{\"literal\":{\"string\":\"trash\"}}");
    }
    const used_with_garbage = env.vm.heap.used;
    try std.testing.expect(used_with_garbage > used_before);

    try env.vm.collectGarbage();
    const used_after_gc = env.vm.heap.used;
    try std.testing.expect(used_after_gc < used_with_garbage);

    const obj = try env.evalJson("{\"var_ref\":\"Object\"}");
    try std.testing.expectEqual(env.vm.globals.object_class, obj);
}
