// Tagged 64-bit object pointer (OOP).
//
// Encoding (bottom 3 bits):
//   xxx1  -> SmallInteger (i63 in upper bits, arithmetic shift)
//   x110  -> SmallFloat   (lossy f64: bottom 3 mantissa bits dropped)
//   x000  -> heap pointer (≥ MIN_HEAP_OOP) or reserved sentinel
//
// Heap allocations are 8-byte aligned, so heap addresses always have
// the bottom 3 bits clear. Sentinels live in the bottom region (< 16)
// with bottom 3 bits also clear:
//
//   0  -> nil
//   2  -> false
//   4  -> true
//
// SmallFloat compresses f64 into 61 bits by dropping the 3 LSBs of
// the mantissa. Effective precision: 49-bit mantissa, ~14.7 decimal
// digits, ULP at 1.0 ≈ 1.8e-15. Exponent range and sign are
// preserved. Pharo-style exponent-bias compression (full mantissa,
// 1-bit range loss) is a v3 swap-in: the public API stays the same.

pub const Oop = u64;

pub const NIL: Oop = 0;
pub const FALSE: Oop = 2;
pub const TRUE: Oop = 4;

pub const MIN_HEAP_OOP: Oop = 16;

const TAG_INT: u64 = 0b001;
const TAG_FLOAT: u64 = 0b110;
const TAG_MASK: u64 = 0b111;

pub inline fn isInt(o: Oop) bool {
    return (o & TAG_INT) != 0;
}

pub inline fn isFloat(o: Oop) bool {
    return (o & TAG_MASK) == TAG_FLOAT;
}

pub inline fn isHeapPtr(o: Oop) bool {
    return (o & TAG_MASK) == 0 and o >= MIN_HEAP_OOP;
}

pub inline fn isNil(o: Oop) bool {
    return o == NIL;
}

pub inline fn isBool(o: Oop) bool {
    return o == TRUE or o == FALSE;
}

// Inclusive range of values representable as a tagged SmallInteger.
// Anything outside this range must be promoted to a heap-resident
// LargePositiveInteger / LargeNegativeInteger (Phase A.3).
pub const SMALL_INT_MIN: i64 = -(@as(i64, 1) << 62);
pub const SMALL_INT_MAX: i64 = (@as(i64, 1) << 62) - 1;

pub inline fn fitsSmallInt(i: i64) bool {
    return i >= SMALL_INT_MIN and i <= SMALL_INT_MAX;
}

pub inline fn fromInt(i: i64) Oop {
    // Caller is responsible for ensuring i fits in i63.
    const shifted: i64 = i << 1;
    return @as(u64, @bitCast(shifted)) | TAG_INT;
}

pub inline fn toInt(o: Oop) i64 {
    // Arithmetic shift right preserves sign.
    return @as(i64, @bitCast(o)) >> 1;
}

pub inline fn fromBool(b: bool) Oop {
    return if (b) TRUE else FALSE;
}

// Encode an f64 as a tagged SmallFloat. The 3 LSBs of the f64's
// in-memory representation are discarded; the result is the f64
// rounded toward zero in mantissa-LSB by up to 7 ULP.
pub inline fn fromF64(f: f64) Oop {
    const bits: u64 = @bitCast(f);
    return (bits & ~TAG_MASK) | TAG_FLOAT;
}

pub inline fn toF64(o: Oop) f64 {
    return @bitCast(o & ~TAG_MASK);
}
