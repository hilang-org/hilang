const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

// v0 Dictionary: parallel keys and values arrays plus a count. Lookup
// is linear-scan, capacity is fixed at allocation time. Good enough
// while name spaces stay small (kernel + a workspace's globals).

pub const DictError = error{
    DictionaryFull,
    OutOfMemory,
};

pub fn lookup(dict: Oop, key: []const u8) Oop {
    if (oop_mod.isNil(dict)) return oop_mod.NIL;
    const idx = findIndex(dict, key) orelse return oop_mod.NIL;
    const vals = object.slot(dict, object.SLOT_DICT_VALUES);
    return object.slot(vals, idx);
}

// Insert or update. Returns the value slot index that ended up holding
// `value` (mostly for tests; production callers ignore it).
pub fn atPut(heap: *Heap, dict: Oop, g: *const Globals, key: []const u8, value: Oop) DictError!u32 {
    if (findIndex(dict, key)) |idx| {
        const vals = object.slot(dict, object.SLOT_DICT_VALUES);
        object.setSlot(vals, idx, value);
        return idx;
    }

    const keys = object.slot(dict, object.SLOT_DICT_KEYS);
    const vals = object.slot(dict, object.SLOT_DICT_VALUES);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(dict, object.SLOT_DICT_COUNT)));
    const cap = object.headerOf(keys).size;
    if (count >= cap) return error.DictionaryFull;

    const sym = newSymbol(heap, g, key) catch return error.OutOfMemory;
    object.setSlot(keys, count, sym);
    object.setSlot(vals, count, value);
    object.setSlot(dict, object.SLOT_DICT_COUNT, oop_mod.fromInt(@intCast(count + 1)));
    return count;
}

pub fn has(dict: Oop, key: []const u8) bool {
    return findIndex(dict, key) != null;
}

// Identity lookup. Assumes both the dictionary's keys and `sym` are
// interned Symbols, so equal byte sequences are the same Oop. Hot
// path for method dispatch and variable resolution.
pub fn lookupBySym(dict: Oop, sym: Oop) Oop {
    if (!oop_mod.isHeapPtr(dict)) return oop_mod.NIL;
    const keys = object.slot(dict, object.SLOT_DICT_KEYS);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(dict, object.SLOT_DICT_COUNT)));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (object.slot(keys, i) == sym) {
            const vals = object.slot(dict, object.SLOT_DICT_VALUES);
            return object.slot(vals, i);
        }
    }
    return oop_mod.NIL;
}

pub fn hasSym(dict: Oop, sym: Oop) bool {
    if (!oop_mod.isHeapPtr(dict)) return false;
    const keys = object.slot(dict, object.SLOT_DICT_KEYS);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(dict, object.SLOT_DICT_COUNT)));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (object.slot(keys, i) == sym) return true;
    }
    return false;
}

// Identity-keyed atPut. The caller passes an already-interned Symbol;
// we don't allocate or look up by bytes.
pub fn atPutSym(heap: *Heap, dict: Oop, sym: Oop, value: Oop) DictError!u32 {
    _ = heap;
    if (!oop_mod.isHeapPtr(dict)) return error.DictionaryFull;
    const keys = object.slot(dict, object.SLOT_DICT_KEYS);
    const vals = object.slot(dict, object.SLOT_DICT_VALUES);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(dict, object.SLOT_DICT_COUNT)));

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (object.slot(keys, i) == sym) {
            object.setSlot(vals, i, value);
            return i;
        }
    }
    const cap = object.headerOf(keys).size;
    if (count >= cap) return error.DictionaryFull;
    object.setSlot(keys, count, sym);
    object.setSlot(vals, count, value);
    object.setSlot(dict, object.SLOT_DICT_COUNT, oop_mod.fromInt(@intCast(count + 1)));
    return count;
}

pub fn newDictionary(heap: *Heap, dict_class: Oop, array_class: Oop, capacity: u32) !Oop {
    const keys = try heap.allocSlots(array_class, capacity);
    const vals = try heap.allocSlots(array_class, capacity);
    const dict = try heap.allocSlots(dict_class, object.DICT_INST_SIZE);
    object.setSlot(dict, object.SLOT_DICT_KEYS, keys);
    object.setSlot(dict, object.SLOT_DICT_VALUES, vals);
    object.setSlot(dict, object.SLOT_DICT_COUNT, oop_mod.fromInt(0));
    return dict;
}

// Allocate a Symbol with the given bytes. If the global symbol table
// exists, the returned Oop is the unique interned Symbol for these
// bytes — equal byte sequences always yield identical Oops. Before the
// table is set up (early bootstrap), each call allocates a fresh
// Symbol; bootstrap installs the table after the first kernel
// allocations and before any setName/atPut calls.
pub fn newSymbol(heap: *Heap, g: *const Globals, s: []const u8) !Oop {
    if (oop_mod.isHeapPtr(g.symbol_table)) {
        // Look up the existing intern.
        const keys = object.slot(g.symbol_table, object.SLOT_DICT_KEYS);
        const count: u32 = @intCast(oop_mod.toInt(object.slot(g.symbol_table, object.SLOT_DICT_COUNT)));
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const existing = object.slot(keys, i);
            if (!oop_mod.isHeapPtr(existing)) continue;
            const hdr = object.headerOf(existing);
            if ((hdr.flags & object.FLAG_BYTES) == 0) continue;
            const bytes = object.bytesOf(existing)[0..hdr.size];
            if (std.mem.eql(u8, bytes, s)) return existing;
        }
        // Not found — allocate a fresh Symbol and add to the table.
        const sym = try newSymbolRaw(heap, g.symbol_class, s);
        const cap = object.headerOf(keys).size;
        if (count >= cap) return error.DictionaryFull;
        const vals = object.slot(g.symbol_table, object.SLOT_DICT_VALUES);
        object.setSlot(keys, count, sym);
        object.setSlot(vals, count, oop_mod.NIL);
        object.setSlot(g.symbol_table, object.SLOT_DICT_COUNT, oop_mod.fromInt(@intCast(count + 1)));
        return sym;
    }
    return newSymbolRaw(heap, g.symbol_class, s);
}

fn newSymbolRaw(heap: *Heap, symbol_class: Oop, s: []const u8) !Oop {
    const sym = try heap.allocBytes(symbol_class, @intCast(s.len));
    @memcpy(object.bytesOf(sym)[0..s.len], s);
    return sym;
}

// Look up an interned Symbol by bytes without allocating. Returns NIL
// when absent. Used by image.load to recover pre-interned Symbols
// after a load — every Symbol that was interned at save time will be
// in the loaded symbol_table, so allocation is never needed.
pub fn lookupSymbol(g: *const Globals, s: []const u8) Oop {
    if (!oop_mod.isHeapPtr(g.symbol_table)) return oop_mod.NIL;
    const keys = object.slot(g.symbol_table, object.SLOT_DICT_KEYS);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(g.symbol_table, object.SLOT_DICT_COUNT)));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const existing = object.slot(keys, i);
        if (!oop_mod.isHeapPtr(existing)) continue;
        const hdr = object.headerOf(existing);
        if ((hdr.flags & object.FLAG_BYTES) == 0) continue;
        const bytes = object.bytesOf(existing)[0..hdr.size];
        if (std.mem.eql(u8, bytes, s)) return existing;
    }
    return oop_mod.NIL;
}

fn findIndex(dict: Oop, key: []const u8) ?u32 {
    if (!oop_mod.isHeapPtr(dict)) return null;
    const keys = object.slot(dict, object.SLOT_DICT_KEYS);
    const count: u32 = @intCast(oop_mod.toInt(object.slot(dict, object.SLOT_DICT_COUNT)));
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const k = object.slot(keys, i);
        if (!oop_mod.isHeapPtr(k)) continue;
        const hdr = object.headerOf(k);
        if ((hdr.flags & object.FLAG_BYTES) == 0) continue;
        const bytes = object.bytesOf(k)[0..hdr.size];
        if (std.mem.eql(u8, bytes, key)) return i;
    }
    return null;
}
