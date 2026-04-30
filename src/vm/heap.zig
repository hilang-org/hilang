const std = @import("std");
const posix = std.posix;
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const Oop = oop_mod.Oop;

// Magic bytes "HILANGIM" little-endian. Identifies a hilang image.
pub const IMAGE_MAGIC: u64 = 0x4D49474E414C4948;

// Bumped whenever the on-disk kernel layout changes incompatibly.
pub const KERNEL_VERSION: u32 = 9;

pub const FLAG_BOOTSTRAPPED: u32 = 1 << 0;

// Reserved at heap offset 0. Always at the start of the mmap region;
// shared between both halves and never moves during GC.
pub const ImageHeader = extern struct {
    magic: u64,
    version: u32,
    flags: u32,
    smalltalk: Oop,
    // The absolute address of the active half at save time. The loader
    // computes `delta = new_active_base - saved_base` to relocate
    // every Oop in the image. Zero in a fresh heap.
    saved_base: u64 = 0,
    // Bytes used in the active half at save time. The loader copies
    // exactly this many bytes from the file into half 0.
    saved_used: u64 = 0,
    _reserved: [3]u64 = .{ 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(ImageHeader) == 64);
    std.debug.assert(@alignOf(ImageHeader) <= 8);
}

// Two-space heap. The mmap region is one contiguous block:
//   [ImageHeader (64B, page-padded)] [half 0 (half_size)] [half 1 (half_size)]
// `active` selects which half allocations land in. GC copies live
// objects to the other half and swaps. Image save writes the header
// followed by the active half's used prefix.

pub const Heap = struct {
    base: [*]align(std.heap.page_size_min) u8,
    capacity: usize, // total mmap size
    half_size: usize, // bytes per half (excluding shared header)
    headers_padding: usize, // distance from base to half 0 (>= sizeof(header), page-aligned)
    active: u32, // 0 or 1
    used: usize, // bytes used in the active half (counts from half base)
    // Precomputed high-water mark (~75% of half_size). The JIT loads
    // this directly to do the maybe-GC check inline; keeping it on
    // the Heap struct means a single ldr instead of an ldr+arithmetic
    // shape per safe point.
    gc_threshold: usize,
    // Precomputed absolute address of the active half. Refreshed
    // whenever the GC swaps halves so the inline-alloc fast path can
    // compute the new object's address with a single ldr instead of
    // base + padding + active*halfsize each time.
    active_base_addr: usize,
    // Bumped every time GC swaps halves. Long-lived call sites with
    // cached Zig-stack Oops (the bytecode interpreter) compare it
    // against a saved value to detect when their locals went stale.
    gc_generation: u64 = 0,

    pub fn init(capacity_bytes: usize) !Heap {
        // Round up the requested capacity to page size and compute a
        // half size that leaves room for the header.
        const total = std.mem.alignForward(usize, capacity_bytes, std.heap.page_size_min);
        const padding = std.mem.alignForward(usize, @sizeOf(ImageHeader), std.heap.page_size_min);
        const usable = total - padding;
        const half = std.mem.alignBackward(usize, usable / 2, 8);

        const mem = try posix.mmap(
            null,
            total,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        var heap: Heap = .{
            .base = mem.ptr,
            .capacity = total,
            .half_size = half,
            .headers_padding = padding,
            .active = 0,
            .used = 0,
            .gc_threshold = (half * 3) / 4,
            .active_base_addr = @intFromPtr(mem.ptr) + padding,
        };
        heap.imageHeader().* = .{
            .magic = IMAGE_MAGIC,
            .version = KERNEL_VERSION,
            .flags = 0,
            .smalltalk = oop_mod.NIL,
        };
        return heap;
    }

    pub inline fn imageHeader(self: *Heap) *ImageHeader {
        return @ptrCast(@alignCast(self.base));
    }

    pub inline fn isBootstrapped(self: *Heap) bool {
        return (self.imageHeader().flags & FLAG_BOOTSTRAPPED) != 0;
    }

    pub inline fn halfBase(self: *Heap, which: u32) [*]u8 {
        return self.base + self.headers_padding + @as(usize, which) * self.half_size;
    }

    pub inline fn activeBase(self: *Heap) [*]u8 {
        return self.halfBase(self.active);
    }

    pub inline fn inactiveBase(self: *Heap) [*]u8 {
        return self.halfBase(self.active ^ 1);
    }

    pub fn deinit(self: *Heap) void {
        posix.munmap(self.base[0..self.capacity]);
        self.* = undefined;
    }

    pub fn allocSlots(self: *Heap, class: Oop, n_slots: u32) !Oop {
        const total = @sizeOf(object.Header) + @as(usize, n_slots) * @sizeOf(Oop);
        const aligned = std.mem.alignForward(usize, total, 8);
        if (self.used + aligned > self.half_size) return error.OutOfMemory;

        const addr_ptr: [*]u8 = self.activeBase() + self.used;
        self.used += aligned;

        const addr: Oop = @intFromPtr(addr_ptr);
        std.debug.assert(addr >= oop_mod.MIN_HEAP_OOP);
        std.debug.assert(addr % 8 == 0);

        const hdr = object.headerOf(addr);
        hdr.* = .{ .class = class, .size = n_slots, .flags = 0 };

        const slots = object.slotsOf(addr);
        var i: u32 = 0;
        while (i < n_slots) : (i += 1) slots[i] = oop_mod.NIL;

        return addr;
    }

    pub fn allocBytes(self: *Heap, class: Oop, n_bytes: u32) !Oop {
        const total = @sizeOf(object.Header) + n_bytes;
        const aligned = std.mem.alignForward(usize, total, 8);
        if (self.used + aligned > self.half_size) return error.OutOfMemory;

        const addr_ptr: [*]u8 = self.activeBase() + self.used;
        self.used += aligned;

        const addr: Oop = @intFromPtr(addr_ptr);
        const hdr = object.headerOf(addr);
        hdr.* = .{ .class = class, .size = n_bytes, .flags = object.FLAG_BYTES };
        @memset(object.bytesOf(addr)[0..n_bytes], 0);
        return addr;
    }
};
