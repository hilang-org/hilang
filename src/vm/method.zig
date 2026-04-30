const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const dict = @import("dict.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

// Allocate a CompiledMethod backed by a primitive in prims.zig.
// `defining_class` records which class's method dict the method lives
// in — needed for `super` to start lookup one level up.
pub fn newPrimitive(
    heap: *Heap,
    g: *const Globals,
    defining_class: Oop,
    selector: []const u8,
    arg_count: u32,
    primitive_id: u32,
) !Oop {
    const sym = try dict.newSymbol(heap, g, selector);
    const m = try heap.allocSlots(g.compiled_method_class, object.METHOD_INST_SIZE);
    object.setSlot(m, object.SLOT_METHOD_SELECTOR, sym);
    object.setSlot(m, object.SLOT_METHOD_ARG_COUNT, oop_mod.fromInt(@intCast(arg_count)));
    object.setSlot(m, object.SLOT_METHOD_KIND, oop_mod.fromInt(object.METHOD_KIND_PRIMITIVE));
    object.setSlot(m, object.SLOT_METHOD_PRIMITIVE, oop_mod.fromInt(@intCast(primitive_id)));
    object.setSlot(m, object.SLOT_METHOD_DEFINING_CLASS, defining_class);
    // params/temps stay NIL from allocSlots; primitives don't use them.
    return m;
}

// Allocate a CompiledMethod whose body is AST. The caller has already
// allocated the param/temp Symbol arrays and the body holder (a 2-slot
// Array containing ptr+len of the body node slice).
pub fn newAst(
    heap: *Heap,
    g: *const Globals,
    defining_class: Oop,
    selector: []const u8,
    arg_count: u32,
    params: Oop,
    temps: Oop,
    body_holder: Oop,
) !Oop {
    const sym = try dict.newSymbol(heap, g, selector);
    const m = try heap.allocSlots(g.compiled_method_class, object.METHOD_INST_SIZE);
    object.setSlot(m, object.SLOT_METHOD_SELECTOR, sym);
    object.setSlot(m, object.SLOT_METHOD_ARG_COUNT, oop_mod.fromInt(@intCast(arg_count)));
    object.setSlot(m, object.SLOT_METHOD_KIND, oop_mod.fromInt(object.METHOD_KIND_AST));
    object.setSlot(m, object.SLOT_METHOD_BODY, body_holder);
    object.setSlot(m, object.SLOT_METHOD_PARAMS, params);
    object.setSlot(m, object.SLOT_METHOD_TEMPS, temps);
    object.setSlot(m, object.SLOT_METHOD_DEFINING_CLASS, defining_class);
    return m;
}

// Install a method into the class's methodDict, allocating the dict on
// first install. Overwrites if a method with the same selector exists.
// Invalidates any cached IC entries that target this selector — both
// AST send-cache slots on heap SendNodes and JIT inline-cache entries
// (when `vm` is non-null) — so a redefined method is picked up by
// existing call sites without waiting for a tier-up cycle. `vm` is
// allowed to be null for callers that run before the VM exists
// (bootstrap, image load) and therefore cannot have any JIT state.
pub fn install(
    heap: *Heap,
    g: *const Globals,
    vm: ?*anyopaque,
    cls: Oop,
    selector: []const u8,
    method: Oop,
) !void {
    var md = object.slot(cls, object.SLOT_METHOD_DICT);
    if (oop_mod.isNil(md)) {
        md = try dict.newDictionary(heap, g.dictionary_class, g.array_class, object.DICT_INITIAL_CAPACITY);
        object.setSlot(cls, object.SLOT_METHOD_DICT, md);
    }
    _ = try dict.atPut(heap, md, g, selector, method);
    const sel_sym = try dict.newSymbol(heap, g, selector);
    invalidateICs(heap, g, sel_sym);
    if (vm) |v| {
        const Vm = @import("eval.zig").Vm;
        const machine: *Vm = @ptrCast(@alignCast(v));
        machine.invalidateJitICs(sel_sym);
    }
}

// Walk the active heap and clear cache slots on every SendNode /
// SuperSendNode whose selector is `sel_sym`. Linear in heap.used,
// but only runs at define_method time (a rare, user-driven event).
pub fn invalidateICs(heap: *Heap, g: *const Globals, sel_sym: Oop) void {
    const send_cls = g.send_node_class;
    const super_cls = g.super_send_node_class;
    if (!oop_mod.isHeapPtr(send_cls) and !oop_mod.isHeapPtr(super_cls)) return;
    const start: u64 = @intFromPtr(heap.activeBase());
    var addr: u64 = start;
    const end = start + heap.used;
    while (addr < end) {
        const hdr: *object.Header = @ptrFromInt(addr);
        const size = hdr.size;
        const is_bytes = (hdr.flags & object.FLAG_BYTES) != 0;
        const payload_bytes = if (is_bytes) size else size * @sizeOf(Oop);
        const total = @sizeOf(object.Header) + payload_bytes;
        const aligned = std.mem.alignForward(usize, total, 8);

        if (!is_bytes) {
            if (hdr.class == send_cls and size >= object.SEND_INST_SIZE) {
                const sel = object.slot(addr, object.SLOT_SEND_SELECTOR);
                if (sel == sel_sym) {
                    object.setSlot(addr, object.SLOT_SEND_CACHED_CLASS, oop_mod.NIL);
                    object.setSlot(addr, object.SLOT_SEND_CACHED_METHOD, oop_mod.NIL);
                    object.setSlot(addr, object.SLOT_SEND_CACHED_CLASS_2, oop_mod.NIL);
                    object.setSlot(addr, object.SLOT_SEND_CACHED_METHOD_2, oop_mod.NIL);
                }
            } else if (hdr.class == super_cls and size >= object.SUPER_INST_SIZE) {
                const sel = object.slot(addr, object.SLOT_SUPER_SELECTOR);
                if (sel == sel_sym) {
                    object.setSlot(addr, object.SLOT_SUPER_CACHED_METHOD, oop_mod.NIL);
                }
            }
        }

        addr += aligned;
    }
}

// Walk the receiver's class up the superclass chain looking for a method
// with the given selector. Returns NIL if none found (DNU).
// Identity-keyed method lookup. Walks the superclass chain comparing
// Oops, not bytes. Hot path for every send.
pub fn lookupBySym(starting_class: Oop, sym: Oop) Oop {
    var cls = starting_class;
    while (oop_mod.isHeapPtr(cls)) {
        const md = object.slot(cls, object.SLOT_METHOD_DICT);
        if (!oop_mod.isNil(md)) {
            const m = dict.lookupBySym(md, sym);
            if (!oop_mod.isNil(m)) return m;
        }
        cls = object.slot(cls, object.SLOT_SUPERCLASS);
    }
    return oop_mod.NIL;
}

pub fn lookup(starting_class: Oop, selector: []const u8) Oop {
    var cls = starting_class;
    while (oop_mod.isHeapPtr(cls)) {
        const md = object.slot(cls, object.SLOT_METHOD_DICT);
        if (!oop_mod.isNil(md)) {
            const m = dict.lookup(md, selector);
            if (!oop_mod.isNil(m)) return m;
        }
        cls = object.slot(cls, object.SLOT_SUPERCLASS);
    }
    return oop_mod.NIL;
}
