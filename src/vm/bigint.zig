// Sign-magnitude arbitrary-precision integers stored as byte-payload
// heap objects. Two classes — LargePositiveInteger and
// LargeNegativeInteger — discriminate sign; the byte payload is the
// magnitude in little-endian base-256 with no trailing zero limbs
// (canonical form).
//
// We operate on u8 digits because the Zig-side arithmetic is simple,
// the absolute sizes we produce in v2 are tiny (factorials of ~30,
// gcd intermediates), and the overhead of base-256 vs base-2^32 is
// negligible at this size. v3 can swap the digit base without
// changing the public class identity.

const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const globals_mod = @import("globals.zig");
const Heap = heap_mod.Heap;
const Globals = globals_mod.Globals;
const Oop = oop_mod.Oop;

pub const Sign = enum { positive, negative };

inline fn classFor(g: *const Globals, sign: Sign) Oop {
    return switch (sign) {
        .positive => g.large_positive_integer_class,
        .negative => g.large_negative_integer_class,
    };
}

// Construct a Large* whose magnitude is the given little-endian bytes.
// Strips trailing zero bytes. If the magnitude is zero, returns the
// SmallInteger 0 instead (canonical zero is a SmallInt).
pub fn fromMagnitude(heap: *Heap, g: *const Globals, sign: Sign, mag_le: []const u8) !Oop {
    var len: u32 = @intCast(mag_le.len);
    while (len > 0 and mag_le[len - 1] == 0) : (len -= 1) {}
    if (len == 0) return oop_mod.fromInt(0);
    const o = try heap.allocBytes(classFor(g, sign), len);
    @memcpy(object.bytesOf(o)[0..len], mag_le[0..len]);
    return o;
}

// Promote a possibly-already-Small i64 into the canonical numeric Oop.
// Returns SmallInteger if it fits, otherwise a Large.
pub fn fromI64(heap: *Heap, g: *const Globals, i: i64) !Oop {
    if (oop_mod.fitsSmallInt(i)) return oop_mod.fromInt(i);
    const sign: Sign = if (i < 0) .negative else .positive;
    // Convert magnitude carefully: -i64.min is undefined, but
    // SMALL_INT_MIN-1 (which is what we land on when overflowing
    // sub) is inside i64 range, so we can safely negate via two's
    // complement bit pattern.
    const mag_u: u64 = if (i < 0)
        @as(u64, @bitCast(-(i + 1))) + 1
    else
        @as(u64, @intCast(i));
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, mag_u, .little);
    return fromMagnitude(heap, g, sign, &buf);
}

// Try to compress a Large back to a SmallInteger. Returns the
// receiver unchanged if it doesn't fit.
pub fn normalizeSmall(g: *const Globals, o: Oop) Oop {
    if (!oop_mod.isHeapPtr(o)) return o;
    const hdr = object.headerOf(o);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return o;
    const sign = signOfWithGlobals(g, o) orelse return o;
    const mag = object.bytesOf(o)[0..hdr.size];
    if (mag.len > 8) return o; // > 64 bits, definitely too big.
    var u: u64 = 0;
    for (mag, 0..) |b, i| u |= @as(u64, b) << @intCast(i * 8);
    if (sign == .positive) {
        if (u <= @as(u64, @intCast(oop_mod.SMALL_INT_MAX))) return oop_mod.fromInt(@intCast(u));
        return o;
    } else {
        // Negative: representable iff u <= |SMALL_INT_MIN|.
        const min_mag: u64 = @as(u64, @intCast(-(oop_mod.SMALL_INT_MIN + 1))) + 1;
        if (u <= min_mag) {
            // Reconstruct without overflow.
            const i: i64 = if (u == min_mag) oop_mod.SMALL_INT_MIN else -@as(i64, @intCast(u));
            return oop_mod.fromInt(i);
        }
        return o;
    }
}

pub fn isLarge(g: *const Globals, o: Oop) bool {
    if (!oop_mod.isHeapPtr(o)) return false;
    const cls = object.headerOf(o).class;
    return cls == g.large_positive_integer_class or cls == g.large_negative_integer_class;
}

pub fn signOfWithGlobals(g: *const Globals, o: Oop) ?Sign {
    if (!oop_mod.isHeapPtr(o)) return null;
    const cls = object.headerOf(o).class;
    if (cls == g.large_positive_integer_class) return .positive;
    if (cls == g.large_negative_integer_class) return .negative;
    return null;
}

inline fn magOf(o: Oop) []const u8 {
    const hdr = object.headerOf(o);
    return object.bytesOf(o)[0..hdr.size];
}

// Lex compare on magnitudes (little-endian): longer wins; same length
// compared by digit from MSB.
fn cmpMag(a: []const u8, b: []const u8) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    var i: usize = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return std.math.order(a[i], b[i]);
    }
    return .eq;
}

fn addMag(heap: *Heap, g: *const Globals, sign: Sign, a: []const u8, b: []const u8) !Oop {
    const max = @max(a.len, b.len);
    var out: [40]u8 = undefined; // up to ~80 base-256 digits = ~190 decimal digits, plenty for v2.
    if (max + 1 > out.len) return error.OutOfMemory;
    var carry: u16 = 0;
    var i: usize = 0;
    while (i < max) : (i += 1) {
        const x: u16 = if (i < a.len) a[i] else 0;
        const y: u16 = if (i < b.len) b[i] else 0;
        const s = x + y + carry;
        out[i] = @intCast(s & 0xff);
        carry = s >> 8;
    }
    if (carry != 0) {
        out[i] = @intCast(carry);
        i += 1;
    }
    return fromMagnitude(heap, g, sign, out[0..i]);
}

// Precondition: cmpMag(a, b) >= 0. Returns sign-magnitude `sign * (a - b)`.
fn subMag(heap: *Heap, g: *const Globals, sign: Sign, a: []const u8, b: []const u8) !Oop {
    var out: [40]u8 = undefined;
    if (a.len > out.len) return error.OutOfMemory;
    var borrow: i16 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const x: i16 = a[i];
        const y: i16 = if (i < b.len) b[i] else 0;
        var d: i16 = x - y - borrow;
        if (d < 0) {
            d += 256;
            borrow = 1;
        } else {
            borrow = 0;
        }
        out[i] = @intCast(d);
    }
    return fromMagnitude(heap, g, sign, out[0..a.len]);
}

fn mulMag(heap: *Heap, g: *const Globals, sign: Sign, a: []const u8, b: []const u8) !Oop {
    var out: [80]u8 = undefined;
    const total = a.len + b.len;
    if (total > out.len) return error.OutOfMemory;
    @memset(out[0..total], 0);
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        var carry: u32 = 0;
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            const prod: u32 = @as(u32, a[i]) * @as(u32, b[j]) + @as(u32, out[i + j]) + carry;
            out[i + j] = @intCast(prod & 0xff);
            carry = prod >> 8;
        }
        out[i + b.len] = @intCast(carry);
    }
    return fromMagnitude(heap, g, sign, out[0..total]);
}

// Coerce an Oop (SmallInt or Large) into a (sign, magnitude bytes)
// view. Magnitude bytes for SmallInts are written into `tmp`.
const Bigview = struct { sign: Sign, mag: []const u8 };

fn view(g: *const Globals, o: Oop, tmp: *[8]u8) ?Bigview {
    if (oop_mod.isInt(o)) {
        const i = oop_mod.toInt(o);
        const sign: Sign = if (i < 0) .negative else .positive;
        const mag_u: u64 = if (i < 0)
            @as(u64, @bitCast(-(i + 1))) + 1
        else
            @as(u64, @intCast(i));
        std.mem.writeInt(u64, tmp, mag_u, .little);
        var len: u32 = 8;
        while (len > 0 and tmp[len - 1] == 0) : (len -= 1) {}
        return .{ .sign = sign, .mag = tmp[0..len] };
    }
    const sign = signOfWithGlobals(g, o) orelse return null;
    return .{ .sign = sign, .mag = magOf(o) };
}

// Public: a + b where each is SmallInt or Large. Result is normalized.
pub fn add(heap: *Heap, g: *const Globals, a: Oop, b: Oop) !Oop {
    var ta: [8]u8 = undefined;
    var tb: [8]u8 = undefined;
    const va = view(g, a, &ta) orelse return error.TypeError;
    const vb = view(g, b, &tb) orelse return error.TypeError;
    const result = if (va.sign == vb.sign)
        try addMag(heap, g, va.sign, va.mag, vb.mag)
    else switch (cmpMag(va.mag, vb.mag)) {
        .eq => return oop_mod.fromInt(0),
        .gt => try subMag(heap, g, va.sign, va.mag, vb.mag),
        .lt => try subMag(heap, g, vb.sign, vb.mag, va.mag),
    };
    return normalizeSmall(g, result);
}

pub fn sub(heap: *Heap, g: *const Globals, a: Oop, b: Oop) !Oop {
    var ta: [8]u8 = undefined;
    var tb: [8]u8 = undefined;
    const va = view(g, a, &ta) orelse return error.TypeError;
    const vb_orig = view(g, b, &tb) orelse return error.TypeError;
    // a - b = a + (-b)
    const vb_sign: Sign = if (vb_orig.sign == .positive) .negative else .positive;
    const result = if (va.sign == vb_sign)
        try addMag(heap, g, va.sign, va.mag, vb_orig.mag)
    else switch (cmpMag(va.mag, vb_orig.mag)) {
        .eq => return oop_mod.fromInt(0),
        .gt => try subMag(heap, g, va.sign, va.mag, vb_orig.mag),
        .lt => try subMag(heap, g, vb_sign, vb_orig.mag, va.mag),
    };
    return normalizeSmall(g, result);
}

pub fn mul(heap: *Heap, g: *const Globals, a: Oop, b: Oop) !Oop {
    var ta: [8]u8 = undefined;
    var tb: [8]u8 = undefined;
    const va = view(g, a, &ta) orelse return error.TypeError;
    const vb = view(g, b, &tb) orelse return error.TypeError;
    if (va.mag.len == 0 or vb.mag.len == 0) return oop_mod.fromInt(0);
    const sign: Sign = if (va.sign == vb.sign) .positive else .negative;
    const result = try mulMag(heap, g, sign, va.mag, vb.mag);
    return normalizeSmall(g, result);
}

// Compare a vs b returning std.math.Order.
pub fn cmp(g: *const Globals, a: Oop, b: Oop) ?std.math.Order {
    var ta: [8]u8 = undefined;
    var tb: [8]u8 = undefined;
    const va = view(g, a, &ta) orelse return null;
    const vb = view(g, b, &tb) orelse return null;
    if (va.sign != vb.sign) {
        // Either is zero? mag.len == 0 means zero.
        if (va.mag.len == 0 and vb.mag.len == 0) return .eq;
        return if (va.sign == .positive) .gt else .lt;
    }
    // Same sign.
    const m = cmpMag(va.mag, vb.mag);
    return if (va.sign == .positive) m else switch (m) {
        .eq => .eq,
        .lt => .gt,
        .gt => .lt,
    };
}

// Decimal string for a Large or Small, allocated in the heap as a String.
pub fn asString(heap: *Heap, g: *const Globals, o: Oop) !Oop {
    if (oop_mod.isInt(o)) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{oop_mod.toInt(o)}) catch return error.OutOfMemory;
        const out = try heap.allocBytes(g.string_class, @intCast(s.len));
        @memcpy(object.bytesOf(out)[0..s.len], s);
        return out;
    }
    const sign = signOfWithGlobals(g, o) orelse return error.TypeError;
    var work: [80]u8 = undefined;
    const src = magOf(o);
    if (src.len > work.len) return error.OutOfMemory;
    @memcpy(work[0..src.len], src);
    var len: usize = src.len;
    // Repeated division by 10.
    var digits: [200]u8 = undefined;
    var n_digits: usize = 0;
    while (len > 0) {
        // Trim leading zero limbs.
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
        if (n_digits >= digits.len) return error.OutOfMemory;
        digits[n_digits] = @intCast('0' + rem);
        n_digits += 1;
    }
    const total: u32 = @intCast(n_digits + @intFromBool(sign == .negative));
    const out = try heap.allocBytes(g.string_class, total);
    const dst = object.bytesOf(out);
    var off: u32 = 0;
    if (sign == .negative) {
        dst[0] = '-';
        off = 1;
    }
    var k: usize = 0;
    while (k < n_digits) : (k += 1) {
        dst[off + k] = digits[n_digits - 1 - k];
    }
    return out;
}

// Convert a Large or Small to f64 (lossy for very large magnitudes).
pub fn toF64(g: *const Globals, o: Oop) ?f64 {
    if (oop_mod.isInt(o)) return @floatFromInt(oop_mod.toInt(o));
    const sign = signOfWithGlobals(g, o) orelse return null;
    const mag = magOf(o);
    var f: f64 = 0;
    var i: usize = mag.len;
    while (i > 0) {
        i -= 1;
        f = f * 256.0 + @as(f64, @floatFromInt(mag[i]));
    }
    return if (sign == .negative) -f else f;
}
