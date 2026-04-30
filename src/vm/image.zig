const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const globals_mod = @import("globals.zig");
const dict = @import("dict.zig");
const Heap = heap_mod.Heap;
const Globals = globals_mod.Globals;
const Oop = oop_mod.Oop;

pub const ImageError = error{
    BadMagic,
    BadVersion,
    NotBootstrapped,
    UnknownClass,
    SaveFailed,
    OpenFailed,
    WriteFailed,
    ReadFailed,
    PathTooLong,
} || std.posix.MMapError || std.mem.Allocator.Error;

const O = std.posix.O;

fn cstr(buf: *[std.posix.PATH_MAX]u8, path: []const u8) ![*:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.posix.system.write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.posix.system.read(fd, buf.ptr + off, buf.len - off);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        off += @intCast(n);
    }
    return off;
}

// Save the live heap. The on-disk layout is:
//   [ImageHeader bytes][active half bytes (heap.used long)]
// saved_base records the absolute address of the active half so the
// loader can compute the relocation delta.
pub fn save(heap: *Heap, path: []const u8) !void {
    const hdr = heap.imageHeader();
    hdr.saved_base = @intFromPtr(heap.activeBase());
    hdr.saved_used = heap.used;

    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const cpath = try cstr(&path_buf, path);
    const flags: u32 = @bitCast(O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true });
    const fd = std.posix.system.open(cpath, @bitCast(flags), @as(std.posix.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.posix.system.close(fd);
    try writeAll(fd, heap.base[0..@sizeOf(heap_mod.ImageHeader)]);
    try writeAll(fd, heap.activeBase()[0..heap.used]);
}

// Load a saved image: allocate a fresh heap of the same capacity, copy
// file contents, walk every heap pointer rewriting it by the relocation
// delta. Then invalidate all AST bodies (their Zig-arena pointers are
// stale) and re-discover well-known classes from the SystemDictionary.
pub fn load(path: []const u8, capacity_bytes: usize) !struct { heap: Heap, globals: Globals } {
    var heap = try Heap.init(capacity_bytes);
    errdefer heap.deinit();

    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const cpath = try cstr(&path_buf, path);
    const fd = std.posix.system.open(cpath, @bitCast(@as(u32, @bitCast(O{ .ACCMODE = .RDONLY }))), @as(std.posix.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.posix.system.close(fd);

    var header_buf: [@sizeOf(heap_mod.ImageHeader)]u8 = undefined;
    const hn = try readExact(fd, &header_buf);
    if (hn != header_buf.len) return error.BadMagic;
    @memcpy(heap.base[0..header_buf.len], &header_buf);

    const hdr = heap.imageHeader();
    if (hdr.magic != heap_mod.IMAGE_MAGIC) return error.BadMagic;
    if (hdr.version != heap_mod.KERNEL_VERSION) return error.BadVersion;
    if ((hdr.flags & heap_mod.FLAG_BOOTSTRAPPED) == 0) return error.NotBootstrapped;

    // Read the active-half payload into half 0. Read in chunks so we
    // don't need to stat() the file separately.
    heap.active = 0;
    const half0 = heap.halfBase(0);
    var payload_size: usize = 0;
    while (payload_size < heap.half_size) {
        const n = std.posix.system.read(fd, half0 + payload_size, heap.half_size - payload_size);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        payload_size += @intCast(n);
    }
    heap.used = payload_size;

    const old_base = hdr.saved_base;
    const old_used = hdr.saved_used;
    const old_end = old_base + old_used;
    const new_base: u64 = @intFromPtr(half0);

    relocate(half0, old_base, old_end, new_base, payload_size);
    hdr.smalltalk = relocOne(hdr.smalltalk, old_base, old_end, new_base);
    hdr.saved_base = new_base;

    const g = try rediscoverGlobals(hdr.smalltalk);
    return .{ .heap = heap, .globals = g };
}

// Walk every object in [half_base, half_base + used), rewriting Oops
// from the saved address space to the loaded one.
fn relocate(half_base: [*]u8, old_base: u64, old_end: u64, new_base: u64, used: usize) void {
    const start: u64 = @intFromPtr(half_base);
    var addr: u64 = start;
    const end = start + used;
    while (addr < end) {
        const hdr: *object.Header = @ptrFromInt(addr);
        hdr.class = relocOne(hdr.class, old_base, old_end, new_base);

        const size = hdr.size;
        const is_bytes = (hdr.flags & object.FLAG_BYTES) != 0;
        const payload_bytes = if (is_bytes) size else size * @sizeOf(Oop);
        const total = @sizeOf(object.Header) + payload_bytes;
        const aligned = std.mem.alignForward(usize, total, 8);

        if (!is_bytes) {
            const slots: [*]Oop = @ptrFromInt(addr + @sizeOf(object.Header));
            var i: u32 = 0;
            while (i < size) : (i += 1) {
                slots[i] = relocOne(slots[i], old_base, old_end, new_base);
            }
        }

        addr += aligned;
    }
}

fn relocOne(o: Oop, old_base: u64, old_end: u64, new_base: u64) Oop {
    if (oop_mod.isInt(o)) return o;
    if (o == oop_mod.NIL or o == oop_mod.TRUE or o == oop_mod.FALSE) return o;
    if (o < old_base or o >= old_end) return o; // outside old image; leave alone
    return o - old_base + new_base;
}

fn rediscoverGlobals(smalltalk: Oop) !Globals {
    var g: Globals = .{};
    g.smalltalk = smalltalk;
    g.symbol_table = try mustLookup(smalltalk, "SymbolTable");

    // Pseudo-var Symbols were interned at save time and are still in
    // the loaded symbol_table. lookupSymbol recovers them without
    // allocating.
    g.sym_nil = try mustLookupSymbol(&g, "nil");
    g.sym_true = try mustLookupSymbol(&g, "true");
    g.sym_false = try mustLookupSymbol(&g, "false");
    g.sym_smalltalk = try mustLookupSymbol(&g, "Smalltalk");
    g.sym_thisContext = try mustLookupSymbol(&g, "thisContext");
    g.sym_self = try mustLookupSymbol(&g, "self");
    g.sym_value = try mustLookupSymbol(&g, "value");
    g.sym_value_colon = try mustLookupSymbol(&g, "value:");
    g.sym_plus = try mustLookupSymbol(&g, "+");
    g.sym_minus = try mustLookupSymbol(&g, "-");
    g.sym_times = try mustLookupSymbol(&g, "*");
    g.sym_lt = try mustLookupSymbol(&g, "<");
    g.sym_le = try mustLookupSymbol(&g, "<=");
    g.sym_gt = try mustLookupSymbol(&g, ">");
    g.sym_ge = try mustLookupSymbol(&g, ">=");
    g.sym_printString = try mustLookupSymbol(&g, "printString");

    g.object_class = try mustLookup(smalltalk, "Object");
    g.behavior_class = try mustLookup(smalltalk, "Behavior");
    g.class_description_class = try mustLookup(smalltalk, "ClassDescription");
    g.class_class = try mustLookup(smalltalk, "Class");
    g.metaclass_class = try mustLookup(smalltalk, "Metaclass");
    g.undefined_class = try mustLookup(smalltalk, "UndefinedObject");
    g.boolean_class = try mustLookup(smalltalk, "Boolean");
    g.true_class = try mustLookup(smalltalk, "True");
    g.false_class = try mustLookup(smalltalk, "False");
    g.smallinteger_class = try mustLookup(smalltalk, "SmallInteger");
    g.large_positive_integer_class = try mustLookup(smalltalk, "LargePositiveInteger");
    g.large_negative_integer_class = try mustLookup(smalltalk, "LargeNegativeInteger");
    g.small_float_class = try mustLookup(smalltalk, "SmallFloat");
    g.byte_array_class = try mustLookup(smalltalk, "ByteArray");
    g.string_class = try mustLookup(smalltalk, "String");
    g.symbol_class = try mustLookup(smalltalk, "Symbol");
    g.array_class = try mustLookup(smalltalk, "Array");
    g.dictionary_class = try mustLookup(smalltalk, "Dictionary");
    g.compiled_method_class = try mustLookup(smalltalk, "CompiledMethod");
    g.frame_class = try mustLookup(smalltalk, "Frame");
    g.block_closure_class = try mustLookup(smalltalk, "BlockClosure");
    g.literal_node_class = try mustLookup(smalltalk, "LiteralNode");
    g.var_ref_node_class = try mustLookup(smalltalk, "VarRefNode");
    g.assign_node_class = try mustLookup(smalltalk, "AssignNode");
    g.send_node_class = try mustLookup(smalltalk, "SendNode");
    g.super_send_node_class = try mustLookup(smalltalk, "SuperSendNode");
    g.block_node_class = try mustLookup(smalltalk, "BlockNode");
    g.seq_node_class = try mustLookup(smalltalk, "SeqNode");
    g.ret_node_class = try mustLookup(smalltalk, "RetNode");
    g.exception_class = try mustLookup(smalltalk, "Exception");

    return g;
}

fn mustLookup(smalltalk: Oop, name: []const u8) !Oop {
    const v = dict.lookup(smalltalk, name);
    if (oop_mod.isNil(v)) return error.UnknownClass;
    return v;
}

fn mustLookupSymbol(g: *const Globals, name: []const u8) !Oop {
    const v = dict.lookupSymbol(g, name);
    if (oop_mod.isNil(v)) return error.UnknownClass;
    return v;
}

