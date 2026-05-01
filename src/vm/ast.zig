const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const dict = @import("dict.zig");
const Heap = @import("heap.zig").Heap;
const Globals = @import("globals.zig").Globals;
const Oop = oop_mod.Oop;

// AST nodes are real heap objects, one class per kind. There is no
// Zig-side AST representation any more — the parser walks the JSON
// Value tree and materializes objects directly in the heap. Eval
// dispatches by class identity and reads slots.

pub const ParseError = error{
    InvalidJson,
    UnknownNodeKind,
    MissingField,
    BadFieldType,
    IntOverflow,
    OutOfMemory,
    DictionaryFull,
};

// Parse a JSON string into a heap-resident AST. `scratch` is used for
// transient std.json.Value parsing only; the returned Oop and any
// objects it transitively references live in the heap.
pub fn parse(heap: *Heap, g: *const Globals, scratch: std.mem.Allocator, json_text: []const u8) ParseError!Oop {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, json_text, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    return fromValue(heap, g, scratch, parsed.value);
}

// Build heap AST nodes from an already-parsed JSON Value. Useful when
// the caller has the Value in hand (e.g. from a request envelope) and
// doesn't want to re-stringify and re-parse.
pub fn fromValue(heap: *Heap, g: *const Globals, scratch: std.mem.Allocator, v: std.json.Value) ParseError!Oop {
    if (v != .object) return error.BadFieldType;
    const obj = v.object;
    if (obj.count() != 1) return error.UnknownNodeKind;

    var it = obj.iterator();
    const entry = it.next() orelse return error.UnknownNodeKind;
    const kind = entry.key_ptr.*;
    const payload = entry.value_ptr.*;

    if (std.mem.eql(u8, kind, "literal")) {
        const value = try parseLiteralValue(heap, g, payload);
        const node = heap.allocSlots(g.literal_node_class, object.LIT_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_LIT_VALUE, value);
        return node;
    }
    if (std.mem.eql(u8, kind, "var_ref")) {
        if (payload != .string) return error.BadFieldType;
        const sym = dict.newSymbol(heap, g, payload.string) catch return error.OutOfMemory;
        const node = heap.allocSlots(g.var_ref_node_class, object.VARREF_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_VARREF_NAME, sym);
        return node;
    }
    if (std.mem.eql(u8, kind, "assign")) {
        if (payload != .object) return error.BadFieldType;
        const name_v = payload.object.get("name") orelse return error.MissingField;
        const value_v = payload.object.get("value") orelse return error.MissingField;
        if (name_v != .string) return error.BadFieldType;
        const sym = dict.newSymbol(heap, g, name_v.string) catch return error.OutOfMemory;
        const value = try fromValue(heap, g, scratch, value_v);
        const node = heap.allocSlots(g.assign_node_class, object.ASSIGN_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_ASSIGN_NAME, sym);
        object.setSlot(node, object.SLOT_ASSIGN_VALUE, value);
        return node;
    }
    if (std.mem.eql(u8, kind, "send")) {
        if (payload != .object) return error.BadFieldType;
        const recv_v = payload.object.get("receiver") orelse return error.MissingField;
        const sel_v = payload.object.get("selector") orelse return error.MissingField;
        const args_v = payload.object.get("args") orelse return error.MissingField;
        if (sel_v != .string or args_v != .array) return error.BadFieldType;
        const recv = try fromValue(heap, g, scratch, recv_v);
        const sel_sym = dict.newSymbol(heap, g, sel_v.string) catch return error.OutOfMemory;
        const args_arr = try buildNodeArray(heap, g, scratch, args_v.array.items);
        const node = heap.allocSlots(g.send_node_class, object.SEND_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_SEND_RECEIVER, recv);
        object.setSlot(node, object.SLOT_SEND_SELECTOR, sel_sym);
        object.setSlot(node, object.SLOT_SEND_ARGS, args_arr);
        return node;
    }
    if (std.mem.eql(u8, kind, "super_send")) {
        if (payload != .object) return error.BadFieldType;
        const sel_v = payload.object.get("selector") orelse return error.MissingField;
        const args_v = payload.object.get("args") orelse return error.MissingField;
        if (sel_v != .string or args_v != .array) return error.BadFieldType;
        const sel_sym = dict.newSymbol(heap, g, sel_v.string) catch return error.OutOfMemory;
        const args_arr = try buildNodeArray(heap, g, scratch, args_v.array.items);
        const node = heap.allocSlots(g.super_send_node_class, object.SUPER_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_SUPER_SELECTOR, sel_sym);
        object.setSlot(node, object.SLOT_SUPER_ARGS, args_arr);
        return node;
    }
    if (std.mem.eql(u8, kind, "block")) {
        if (payload != .object) return error.BadFieldType;
        const params_v = payload.object.get("params") orelse return error.MissingField;
        const temps_v = payload.object.get("temps") orelse return error.MissingField;
        const body_v = payload.object.get("body") orelse return error.MissingField;
        if (params_v != .array or temps_v != .array or body_v != .array) return error.BadFieldType;
        const params_arr = try buildSymbolArray(heap, g, params_v.array.items);
        const temps_arr = try buildSymbolArray(heap, g, temps_v.array.items);
        const body_arr = try buildNodeArray(heap, g, scratch, body_v.array.items);
        const node = heap.allocSlots(g.block_node_class, object.BLOCKNODE_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_BLOCKNODE_PARAMS, params_arr);
        object.setSlot(node, object.SLOT_BLOCKNODE_TEMPS, temps_arr);
        object.setSlot(node, object.SLOT_BLOCKNODE_BODY, body_arr);
        return node;
    }
    if (std.mem.eql(u8, kind, "seq")) {
        if (payload != .array) return error.BadFieldType;
        const body_arr = try buildNodeArray(heap, g, scratch, payload.array.items);
        const node = heap.allocSlots(g.seq_node_class, object.SEQ_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_SEQ_BODY, body_arr);
        return node;
    }
    if (std.mem.eql(u8, kind, "ret")) {
        const inner = try fromValue(heap, g, scratch, payload);
        const node = heap.allocSlots(g.ret_node_class, object.RET_INST_SIZE) catch return error.OutOfMemory;
        object.setSlot(node, object.SLOT_RET_INNER, inner);
        return node;
    }
    return error.UnknownNodeKind;
}

fn buildNodeArray(heap: *Heap, g: *const Globals, scratch: std.mem.Allocator, items: []std.json.Value) ParseError!Oop {
    const arr = heap.allocSlots(g.array_class, @intCast(items.len)) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        const child = try fromValue(heap, g, scratch, item);
        object.setSlot(arr, @intCast(i), child);
    }
    return arr;
}

fn buildSymbolArray(heap: *Heap, g: *const Globals, items: []std.json.Value) ParseError!Oop {
    const arr = heap.allocSlots(g.array_class, @intCast(items.len)) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        if (item != .string) return error.BadFieldType;
        const sym = dict.newSymbol(heap, g, item.string) catch return error.OutOfMemory;
        object.setSlot(arr, @intCast(i), sym);
    }
    return arr;
}

fn parseLiteralValue(heap: *Heap, g: *const Globals, v: std.json.Value) ParseError!Oop {
    if (v != .object) return error.BadFieldType;
    const obj = v.object;
    var it = obj.iterator();
    const entry = it.next() orelse return error.MissingField;
    const tag = entry.key_ptr.*;
    const payload = entry.value_ptr.*;

    if (std.mem.eql(u8, tag, "nil")) return oop_mod.NIL;
    if (std.mem.eql(u8, tag, "true")) return oop_mod.TRUE;
    if (std.mem.eql(u8, tag, "false")) return oop_mod.FALSE;
    if (std.mem.eql(u8, tag, "int")) {
        if (payload != .integer) return error.BadFieldType;
        const min_i63 = -(@as(i64, 1) << 62);
        const max_i63 = (@as(i64, 1) << 62) - 1;
        if (payload.integer < min_i63 or payload.integer > max_i63) return error.IntOverflow;
        return oop_mod.fromInt(payload.integer);
    }
    if (std.mem.eql(u8, tag, "string")) {
        if (payload != .string) return error.BadFieldType;
        const s = payload.string;
        const obj_oop = heap.allocBytes(g.string_class, @intCast(s.len)) catch return error.OutOfMemory;
        @memcpy(object.bytesOf(obj_oop)[0..s.len], s);
        return obj_oop;
    }
    if (std.mem.eql(u8, tag, "symbol")) {
        if (payload != .string) return error.BadFieldType;
        return dict.newSymbol(heap, g, payload.string) catch return error.OutOfMemory;
    }
    if (std.mem.eql(u8, tag, "float")) {
        // Accept either a JSON number (real) or an integer.
        const f: f64 = switch (payload) {
            .float => payload.float,
            .integer => @floatFromInt(payload.integer),
            else => return error.BadFieldType,
        };
        return oop_mod.fromF64(f);
    }
    return error.UnknownNodeKind;
}
