const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const dict = @import("dict.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

// Total instance variable count for a class, summed up the chain.
// Subclass ivars come after superclass ivars in the slot layout, so a
// method on the superclass that touches its own ivars uses indices
// 0..super_count-1 regardless of which subclass the receiver is.
pub fn countIvars(class: Oop) u32 {
    if (!oop_mod.isHeapPtr(class)) return 0;
    const super = object.slot(class, object.SLOT_SUPERCLASS);
    var count: u32 = countIvars(super);
    const names = object.slot(class, object.SLOT_CLASS_IVAR_NAMES);
    if (oop_mod.isHeapPtr(names)) {
        count += object.headerOf(names).size;
    }
    return count;
}

// Resolves an ivar name against a class, returning the slot index that
// `name` corresponds to on instances of that class. null if unknown.
// Identity-keyed ivar resolution. Both the class's ivarNames and `sym`
// must be interned Symbols.
pub fn ivarSlotForSym(class: Oop, sym: Oop) ?u32 {
    if (!oop_mod.isHeapPtr(class)) return null;
    const super = object.slot(class, object.SLOT_SUPERCLASS);
    if (ivarSlotForSym(super, sym)) |idx| return idx;

    const names = object.slot(class, object.SLOT_CLASS_IVAR_NAMES);
    if (!oop_mod.isHeapPtr(names)) return null;
    const offset_super = countIvars(super);
    const n = object.headerOf(names).size;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (object.slot(names, i) == sym) return offset_super + i;
    }
    return null;
}

pub fn ivarSlotFor(class: Oop, name: []const u8) ?u32 {
    if (!oop_mod.isHeapPtr(class)) return null;
    // Recurse so superclass ivars get the lower indices.
    const super = object.slot(class, object.SLOT_SUPERCLASS);
    if (ivarSlotFor(super, name)) |idx| return idx;

    const names = object.slot(class, object.SLOT_CLASS_IVAR_NAMES);
    if (!oop_mod.isHeapPtr(names)) return null;
    const offset_super = countIvars(super);
    const n = object.headerOf(names).size;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const sym = object.slot(names, i);
        if (!oop_mod.isHeapPtr(sym)) continue;
        const hdr = object.headerOf(sym);
        if ((hdr.flags & object.FLAG_BYTES) == 0) continue;
        const bytes = object.bytesOf(sym)[0..hdr.size];
        if (std.mem.eql(u8, bytes, name)) return offset_super + i;
    }
    return null;
}

// Allocate a (class, metaclass) pair under an existing superclass and
// register it as a global in Smalltalk. Mirrors bootstrap's private
// defineClass helper but is callable at runtime by define_class.
pub fn defineClass(
    heap: *Heap,
    g: *const Globals,
    name: []const u8,
    super: Oop,
    ivar_names: []const []const u8,
) !Oop {
    const meta = try heap.allocSlots(g.metaclass_class, object.CLASS_INST_SIZE);
    const cls = try heap.allocSlots(meta, object.CLASS_INST_SIZE);

    // Regular side.
    object.setSlot(cls, object.SLOT_SUPERCLASS, super);
    object.setSlot(cls, object.SLOT_METHOD_DICT, oop_mod.NIL);
    object.setSlot(cls, object.SLOT_INST_VAR_COUNT, oop_mod.fromInt(@intCast(ivar_names.len)));

    const name_sym = try dict.newSymbol(heap, g, name);
    object.setSlot(cls, object.SLOT_NAME, name_sym);

    // ivar names array (NIL when no ivars, to keep parity with kernel).
    if (ivar_names.len == 0) {
        object.setSlot(cls, object.SLOT_CLASS_IVAR_NAMES, oop_mod.NIL);
    } else {
        const arr = try heap.allocSlots(g.array_class, @intCast(ivar_names.len));
        for (ivar_names, 0..) |iv, i| {
            const sym = try dict.newSymbol(heap, g, iv);
            object.setSlot(arr, @intCast(i), sym);
        }
        object.setSlot(cls, object.SLOT_CLASS_IVAR_NAMES, arr);
    }

    // Metaclass side.
    const super_meta = if (oop_mod.isNil(super))
        g.class_class
    else
        object.headerOf(super).class;
    object.setSlot(meta, object.SLOT_SUPERCLASS, super_meta);
    object.setSlot(meta, object.SLOT_METHOD_DICT, oop_mod.NIL);
    object.setSlot(meta, object.SLOT_INST_VAR_COUNT, oop_mod.fromInt(@intCast(object.CLASS_INST_SIZE)));
    object.setSlot(meta, object.SLOT_THIS_CLASS, cls);
    object.setSlot(meta, object.SLOT_CLASS_IVAR_NAMES, oop_mod.NIL);

    return cls;
}
