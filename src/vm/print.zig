const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const Vm = @import("eval.zig").Vm;
const Oop = oop_mod.Oop;

// printString: short human-readable rendering of an Oop, similar to
// Smalltalk's `printString`. Allocated in the supplied allocator.
pub fn printString(allocator: std.mem.Allocator, vm: *const Vm, o: Oop) ![]u8 {
    if (oop_mod.isNil(o)) return allocator.dupe(u8, "nil");
    if (o == oop_mod.TRUE) return allocator.dupe(u8, "true");
    if (o == oop_mod.FALSE) return allocator.dupe(u8, "false");
    if (oop_mod.isInt(o)) {
        return std.fmt.allocPrint(allocator, "{d}", .{oop_mod.toInt(o)});
    }
    if (oop_mod.isFloat(o)) {
        return std.fmt.allocPrint(allocator, "{d}", .{oop_mod.toF64(o)});
    }
    if (!oop_mod.isHeapPtr(o)) {
        return std.fmt.allocPrint(allocator, "<oop {x}>", .{o});
    }

    const hdr = object.headerOf(o);

    // Large integers: render in decimal directly (we can't call
    // bigint.asString from a const Vm because it allocates a String
    // on the heap; this is the daemon-side fallback render).
    if (hdr.class == vm.globals.large_positive_integer_class or
        hdr.class == vm.globals.large_negative_integer_class)
    {
        const negative = hdr.class == vm.globals.large_negative_integer_class;
        const src = object.bytesOf(o)[0..hdr.size];
        var work: [80]u8 = undefined;
        if (src.len > work.len) return allocator.dupe(u8, "<large?>");
        @memcpy(work[0..src.len], src);
        var len: usize = src.len;
        var digits: [200]u8 = undefined;
        var nd: usize = 0;
        while (len > 0) {
            while (len > 0 and work[len - 1] == 0) : (len -= 1) {}
            if (len == 0) break;
            var rem: u32 = 0;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                const cur: u32 = (rem << 8) | work[i];
                work[i] = @intCast(cur / 10);
                rem = cur % 10;
            }
            digits[nd] = @intCast('0' + rem);
            nd += 1;
        }
        const total = nd + @intFromBool(negative);
        const out = try allocator.alloc(u8, total);
        var off: usize = 0;
        if (negative) {
            out[0] = '-';
            off = 1;
        }
        var k: usize = 0;
        while (k < nd) : (k += 1) out[off + k] = digits[nd - 1 - k];
        return out;
    }

    // Strings and Symbols print as their byte payload.
    if ((hdr.flags & object.FLAG_BYTES) != 0) {
        const bytes = object.bytesOf(o)[0..hdr.size];
        const cls = hdr.class;
        if (cls == vm.globals.symbol_class) {
            return std.fmt.allocPrint(allocator, "#{s}", .{bytes});
        }
        return std.fmt.allocPrint(allocator, "'{s}'", .{bytes});
    }

    // If `o` is itself a class or metaclass, print its own display name
    // (e.g. "Object", "Object class") rather than "a Metaclass".
    if (oop_mod.isHeapPtr(hdr.class)) {
        const meta_of_class = object.headerOf(hdr.class).class;
        if (meta_of_class == vm.globals.metaclass_class or hdr.class == vm.globals.metaclass_class) {
            if (try classDisplayName(allocator, vm, o)) |n| return n;
        }
    }

    // Pointer object: render as `a ClassName` using the class's name slot.
    const class_name = classNameBytes(vm, hdr.class);
    if (class_name) |name| {
        return std.fmt.allocPrint(allocator, "a {s}", .{name});
    }
    return std.fmt.allocPrint(allocator, "<obj@{x} size={d}>", .{ o, hdr.size });
}

pub fn classNameBytes(vm: *const Vm, cls: Oop) ?[]const u8 {
    _ = vm;
    if (!oop_mod.isHeapPtr(cls)) return null;
    const hdr = object.headerOf(cls);
    if (hdr.size <= object.SLOT_NAME) return null;
    const name_oop = object.slot(cls, object.SLOT_NAME);
    if (!oop_mod.isHeapPtr(name_oop)) return null;
    const name_hdr = object.headerOf(name_oop);
    if ((name_hdr.flags & object.FLAG_BYTES) == 0) return null;
    return object.bytesOf(name_oop)[0..name_hdr.size];
}

// Render the canonical name for a class or metaclass. Returns "Foo" for
// regular classes and "Foo class" for metaclass instances.
pub fn classDisplayName(allocator: std.mem.Allocator, vm: *const Vm, cls: Oop) !?[]u8 {
    if (!oop_mod.isHeapPtr(cls)) return null;
    if (classNameBytes(vm, cls)) |n| {
        return try allocator.dupe(u8, n);
    }
    // Likely a metaclass instance — its slot[SLOT_THIS_CLASS] points at
    // the regular class, whose name we can read.
    const hdr = object.headerOf(cls);
    if (hdr.size <= object.SLOT_THIS_CLASS) return null;
    const this_cls = object.slot(cls, object.SLOT_THIS_CLASS);
    if (classNameBytes(vm, this_cls)) |n| {
        return try std.fmt.allocPrint(allocator, "{s} class", .{n});
    }
    return null;
}
