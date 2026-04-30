const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const dict = @import("dict.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

// A Frame holds parameter and temporary bindings for one activation.
// Layout (variable-sized):
//   slot 0      : parent (lexical parent frame, or NIL for method frames)
//   slot 1      : source (CompiledMethod or BlockClosure — used by the
//                  AST tier to virtualize the legacy `names` array)
//   slots 2..   : values, inline. For method frames: [self, params..., temps...].
//                  For block frames: [params..., temps...] (self lives in
//                  the home method's frame and is reached via parent chain).

pub fn newFrame(
    heap: *Heap,
    g: *const Globals,
    parent: Oop,
    source: Oop,
    n: u32,
    initial_values: []const Oop,
) !Oop {
    // Caller's `source` should already carry params/temps describing
    // these `n` value slots — the AST tier reads names through
    // source rather than from a parallel names array on the frame.
    const total: u32 = object.FRAME_VALUES_OFFSET + n;
    const f = try heap.allocSlots(g.frame_class, total);
    object.setSlot(f, object.SLOT_FRAME_PARENT, parent);
    object.setSlot(f, object.SLOT_FRAME_SOURCE, source);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const v: Oop = if (i < initial_values.len) initial_values[i] else oop_mod.NIL;
        object.setSlot(f, object.FRAME_VALUES_OFFSET + i, v);
    }
    return f;
}

// (frame, index) where index is the value-array offset (0-based, same
// units the bytecode interpreter and AST writer use).
pub const FoundBinding = struct {
    frame: Oop,
    index: u32,
};

// Resolve a Symbol against the frame's effective name sequence
// (synthesized from frame.source). Walks the parent chain on miss.
pub fn findBySym(starting_frame: Oop, sym: Oop) ?FoundBinding {
    var f = starting_frame;
    while (oop_mod.isHeapPtr(f)) {
        if (resolveSym(f, sym)) |idx| return .{ .frame = f, .index = idx };
        f = object.slot(f, object.SLOT_FRAME_PARENT);
    }
    return null;
}

pub fn find(starting_frame: Oop, name: []const u8) ?FoundBinding {
    var f = starting_frame;
    while (oop_mod.isHeapPtr(f)) {
        if (resolveBytes(f, name)) |idx| return .{ .frame = f, .index = idx };
        f = object.slot(f, object.SLOT_FRAME_PARENT);
    }
    return null;
}

pub fn read(frame: Oop, index: u32) Oop {
    return object.slot(frame, object.FRAME_VALUES_OFFSET + index);
}

pub fn write(frame: Oop, index: u32, value: Oop) void {
    object.setSlot(frame, object.FRAME_VALUES_OFFSET + index, value);
}

// --- internals ---

// Iterate the frame's effective names without allocating. For method
// frames the sequence is [#self] ++ source.params ++ source.temps;
// for block frames it's source.params ++ source.temps.
fn resolveSym(frame: Oop, sym: Oop) ?u32 {
    const source = object.slot(frame, object.SLOT_FRAME_SOURCE);
    if (!oop_mod.isHeapPtr(source)) return null;
    const src_cls = object.headerOf(source).class;
    const is_method = src_cls != oop_mod.NIL and isCompiledMethod(source);
    const is_block = !is_method and isBlockClosure(source);
    if (!is_method and !is_block) return null;

    var idx: u32 = 0;
    if (is_method) {
        // slot 0 = #self. We can't access globals from here without
        // threading them in; compare bytes instead.
        if (oop_mod.isHeapPtr(sym)) {
            const hdr = object.headerOf(sym);
            if ((hdr.flags & object.FLAG_BYTES) != 0) {
                const bytes = object.bytesOf(sym)[0..hdr.size];
                if (std.mem.eql(u8, bytes, "self")) return idx;
            }
        }
        idx = 1;
    }
    const params = if (is_method)
        object.slot(source, object.SLOT_METHOD_PARAMS)
    else
        object.slot(source, object.SLOT_BLOCK_PARAMS);
    if (oop_mod.isHeapPtr(params)) {
        const np = object.headerOf(params).size;
        var i: u32 = 0;
        while (i < np) : (i += 1) {
            if (object.slot(params, i) == sym) return idx + i;
            // Identity miss: AST tier sometimes hands us a freshly
            // interned Symbol with the same bytes; fall back to byte
            // compare to keep findBySym tolerant.
            if (sameSymBytes(object.slot(params, i), sym)) return idx + i;
        }
        idx += np;
    }
    const temps = if (is_method)
        object.slot(source, object.SLOT_METHOD_TEMPS)
    else
        object.slot(source, object.SLOT_BLOCK_TEMPS);
    if (oop_mod.isHeapPtr(temps)) {
        const nt = object.headerOf(temps).size;
        var i: u32 = 0;
        while (i < nt) : (i += 1) {
            if (object.slot(temps, i) == sym) return idx + i;
            if (sameSymBytes(object.slot(temps, i), sym)) return idx + i;
        }
    }
    return null;
}

fn resolveBytes(frame: Oop, name: []const u8) ?u32 {
    const source = object.slot(frame, object.SLOT_FRAME_SOURCE);
    if (!oop_mod.isHeapPtr(source)) return null;
    const is_method = isCompiledMethod(source);
    const is_block = !is_method and isBlockClosure(source);
    if (!is_method and !is_block) return null;

    var idx: u32 = 0;
    if (is_method) {
        if (std.mem.eql(u8, name, "self")) return 0;
        idx = 1;
    }
    const params = if (is_method)
        object.slot(source, object.SLOT_METHOD_PARAMS)
    else
        object.slot(source, object.SLOT_BLOCK_PARAMS);
    if (oop_mod.isHeapPtr(params)) {
        const np = object.headerOf(params).size;
        var i: u32 = 0;
        while (i < np) : (i += 1) {
            if (matchSymBytes(object.slot(params, i), name)) return idx + i;
        }
        idx += np;
    }
    const temps = if (is_method)
        object.slot(source, object.SLOT_METHOD_TEMPS)
    else
        object.slot(source, object.SLOT_BLOCK_TEMPS);
    if (oop_mod.isHeapPtr(temps)) {
        const nt = object.headerOf(temps).size;
        var i: u32 = 0;
        while (i < nt) : (i += 1) {
            if (matchSymBytes(object.slot(temps, i), name)) return idx + i;
        }
    }
    return null;
}

fn isCompiledMethod(o: Oop) bool {
    if (!oop_mod.isHeapPtr(o)) return false;
    // CompiledMethods carry a body / params / temps slot triplet at
    // the conventional offsets; the cheapest discriminator is to
    // check that they have at least METHOD_INST_SIZE slots and don't
    // have FLAG_BYTES. Class-equality would need globals threaded in.
    const hdr = object.headerOf(o);
    if ((hdr.flags & object.FLAG_BYTES) != 0) return false;
    return hdr.size >= object.METHOD_INST_SIZE;
}

fn isBlockClosure(o: Oop) bool {
    if (!oop_mod.isHeapPtr(o)) return false;
    const hdr = object.headerOf(o);
    if ((hdr.flags & object.FLAG_BYTES) != 0) return false;
    return hdr.size == object.BLOCK_INST_SIZE;
}

fn sameSymBytes(a: Oop, b: Oop) bool {
    if (!oop_mod.isHeapPtr(a) or !oop_mod.isHeapPtr(b)) return false;
    const ha = object.headerOf(a);
    const hb = object.headerOf(b);
    if ((ha.flags & object.FLAG_BYTES) == 0) return false;
    if ((hb.flags & object.FLAG_BYTES) == 0) return false;
    if (ha.size != hb.size) return false;
    return std.mem.eql(u8, object.bytesOf(a)[0..ha.size], object.bytesOf(b)[0..hb.size]);
}

fn matchSymBytes(a: Oop, name: []const u8) bool {
    if (!oop_mod.isHeapPtr(a)) return false;
    const ha = object.headerOf(a);
    if ((ha.flags & object.FLAG_BYTES) == 0) return false;
    return std.mem.eql(u8, object.bytesOf(a)[0..ha.size], name);
}
