const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const Oop = oop_mod.Oop;

// Cheney-style two-space copying collector. Live objects in the active
// half are copied into the inactive half, then we swap. No scratch
// buffer, no second relocation pass — pointers in to-space objects
// already point at to-space because copy() rewrites them as it goes.
//
// Failure semantics: collect is atomic. If it returns OutOfMemory,
// every root, the Smalltalk anchor, and every from-space object are
// restored to their pre-call state. We achieve this with:
//   * A snapshot of every root value (and the anchor) taken before
//     any mutation.
//   * An undo log filled by copy() — for every from-space object we
//     forward, we record the original (from_addr, original_class).
//     We can't recover the original class from the to-space copy
//     because the to-space scan rewrites it in place (the class oop
//     itself migrates to to-space, and copy() overwrites the to-space
//     copy's header.class to track the move).
//
// On rollback we walk the undo log, clear FLAG_FORWARDED, and put
// the original class back. Then we restore the roots. To-space
// contents are simply discarded (heap.used / heap.active stay
// untouched, so the next allocation pass overwrites that half).
//
// Duplicate-root handling: addStackFrameSlots and the bc_pin walk
// can push the same physical slot multiple times (current_frame and
// current_method_frame collapse to the same frame for method-context
// invocations; pin.saved_frame and pin.saved_method_frame likewise).
// The root-copy loop must use the snapshot value at each iteration,
// not re-read root.*, otherwise the second visit sees the to-space
// address the first visit wrote and feeds copy() a to-space input
// that it cannot distinguish from a fresh from-space object —
// cascading into runaway re-copying that fills to-space.

pub const RootSet = struct {
    fields: []*Oop,
};

const UndoEntry = struct {
    from_addr: u64,
    original_class: u64,
};

const UndoLog = std.ArrayList(UndoEntry);

pub fn collect(heap: *Heap, roots: RootSet) !void {
    const to_base: u64 = @intFromPtr(heap.inactiveBase());
    const heap_lo: u64 = @intFromPtr(heap.base);
    const heap_hi: u64 = heap_lo + heap.capacity;
    var to_used: usize = 0;

    const allocator = std.heap.page_allocator;

    // Snapshot every root + the Smalltalk anchor.
    const saved_roots = try allocator.alloc(Oop, roots.fields.len);
    defer allocator.free(saved_roots);
    for (roots.fields, 0..) |root, i| saved_roots[i] = root.*;
    const hdr = heap.imageHeader();
    const saved_smalltalk: Oop = hdr.smalltalk;

    // Undo log: appended to by copy(). On failure we walk it back.
    // On success we just drop it.
    var undo: UndoLog = .empty;
    defer undo.deinit(allocator);

    // Copy each root into to-space using the snapshot value, not
    // re-reading root.*. See the file-header comment about
    // duplicate-root handling.
    for (roots.fields, 0..) |root, idx| {
        const new_v = copy(heap_lo, heap_hi, to_base, &to_used, heap.half_size, &undo, allocator, saved_roots[idx]) catch |e| {
            rollback(roots, saved_roots, hdr, saved_smalltalk, &undo);
            return e;
        };
        root.* = new_v;
    }

    // Smalltalk anchor in the header.
    hdr.smalltalk = copy(heap_lo, heap_hi, to_base, &to_used, heap.half_size, &undo, allocator, hdr.smalltalk) catch |e| {
        rollback(roots, saved_roots, hdr, saved_smalltalk, &undo);
        return e;
    };

    // Scan to-space, copying every reachable pointer.
    var scan: usize = 0;
    while (scan < to_used) {
        const obj_addr: u64 = to_base + scan;
        const obj_hdr: *object.Header = @ptrFromInt(obj_addr);
        obj_hdr.class = copy(heap_lo, heap_hi, to_base, &to_used, heap.half_size, &undo, allocator, obj_hdr.class) catch |e| {
            rollback(roots, saved_roots, hdr, saved_smalltalk, &undo);
            return e;
        };

        const is_bytes = (obj_hdr.flags & object.FLAG_BYTES) != 0;
        if (!is_bytes) {
            const slots: [*]Oop = @ptrFromInt(obj_addr + @sizeOf(object.Header));
            var i: u32 = 0;
            while (i < obj_hdr.size) : (i += 1) {
                slots[i] = copy(heap_lo, heap_hi, to_base, &to_used, heap.half_size, &undo, allocator, slots[i]) catch |e| {
                    rollback(roots, saved_roots, hdr, saved_smalltalk, &undo);
                    return e;
                };
            }
        }

        const payload_bytes = if (is_bytes) obj_hdr.size else obj_hdr.size * @sizeOf(Oop);
        const total = @sizeOf(object.Header) + payload_bytes;
        scan += std.mem.alignForward(usize, total, 8);
    }

    // Flip. Old active is now logically empty; new active holds the
    // compacted live set.
    heap.active ^= 1;
    heap.used = to_used;
    heap.active_base_addr = @intFromPtr(heap.activeBase());
    heap.gc_generation += 1;
}

fn rollback(
    roots: RootSet,
    saved_roots: []const Oop,
    hdr: *heap_mod.ImageHeader,
    saved_smalltalk: Oop,
    undo: *const UndoLog,
) void {
    // Walk the undo log in reverse so the from-space mutations come
    // off in the order they were applied. Each entry: a from-space
    // object we forwarded, and the class oop it had before we
    // overwrote it with the forwarding pointer.
    var i: usize = undo.items.len;
    while (i > 0) {
        i -= 1;
        const e = undo.items[i];
        const h: *object.Header = @ptrFromInt(e.from_addr);
        h.class = e.original_class;
        h.flags &= ~@as(@TypeOf(h.flags), object.FLAG_FORWARDED);
    }

    for (roots.fields, saved_roots) |root, orig| root.* = orig;
    hdr.smalltalk = saved_smalltalk;
}

// Copy a from-space object into to-space, returning the new address.
// SmallIntegers, sentinels, addresses outside the heap region (e.g.
// stack-allocated frames produced by the JIT, or JIT-page IC slots),
// and already-forwarded objects all pass through unchanged.
fn copy(
    heap_lo: u64,
    heap_hi: u64,
    to_base: u64,
    to_used: *usize,
    capacity: usize,
    undo: *UndoLog,
    allocator: std.mem.Allocator,
    o: Oop,
) !Oop {
    if (oop_mod.isInt(o)) return o;
    if (o == oop_mod.NIL or o == oop_mod.TRUE or o == oop_mod.FALSE) return o;
    if (!oop_mod.isHeapPtr(o)) return o;
    if (o < heap_lo or o >= heap_hi) return o;

    const hdr: *object.Header = @ptrFromInt(o);
    if ((hdr.flags & object.FLAG_FORWARDED) != 0) {
        return hdr.class;
    }

    const is_bytes = (hdr.flags & object.FLAG_BYTES) != 0;
    const payload_bytes = if (is_bytes) hdr.size else hdr.size * @sizeOf(Oop);
    const total = @sizeOf(object.Header) + payload_bytes;
    const aligned = std.mem.alignForward(usize, total, 8);

    if (to_used.* + aligned > capacity) return error.OutOfMemory;

    const new_addr_int: u64 = to_base + to_used.*;
    const new_addr_ptr: [*]u8 = @ptrFromInt(new_addr_int);
    const old_ptr: [*]const u8 = @ptrFromInt(o);

    // Record the undo entry BEFORE mutating from-space, so that even
    // if append() OOMs we don't leave a forwarded object un-tracked.
    try undo.append(allocator, .{ .from_addr = o, .original_class = hdr.class });

    @memcpy(new_addr_ptr[0..total], old_ptr[0..total]);
    to_used.* += aligned;

    hdr.flags |= object.FLAG_FORWARDED;
    hdr.class = new_addr_int;

    return new_addr_int;
}
