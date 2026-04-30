const std = @import("std");
const oop_mod = @import("oop.zig");
const Oop = oop_mod.Oop;

// Object layout in the heap:
//
//   +------------------+  <- address used as Oop
//   | class : Oop      |  8 bytes
//   | size  : u32      |  4 bytes (number of slots)
//   | flags : u32      |  4 bytes (reserved; e.g. byte-array bit)
//   | slot[0] : Oop    |  8 bytes
//   | slot[1] : Oop    |  ...
//   | ...              |
//   +------------------+
//
// All allocations 8-byte aligned. Slots are Oops for pointer objects; a
// future byte-array flag will reinterpret slots as raw bytes.

pub const Header = extern struct {
    class: Oop,
    size: u32,
    flags: u32,
};

pub const FLAG_BYTES: u32 = 1 << 0;
// Set on a from-space object during GC to mean "this has been copied;
// the new address is in the class slot." Cleared (always 0) on
// objects in to-space and after GC completes.
pub const FLAG_FORWARDED: u32 = 1 << 1;

// Slot layout for Behavior (and everything that inherits it: Class, Metaclass).
pub const SLOT_SUPERCLASS: u32 = 0;
pub const SLOT_METHOD_DICT: u32 = 1;
pub const SLOT_INST_VAR_COUNT: u32 = 2;

// Class adds a `name` slot. Metaclass uses the same physical slot for
// `thisClass` (its associated regular class).
pub const SLOT_NAME: u32 = 3;
pub const SLOT_THIS_CLASS: u32 = 3;
// Class adds an `instVarNames` slot (Array of Symbols). Metaclass leaves
// it NIL — we keep the layouts symmetric for now.
pub const SLOT_CLASS_IVAR_NAMES: u32 = 4;
pub const CLASS_INST_SIZE: u32 = 5;

// Dictionary v0: parallel arrays of keys and values, plus a count.
pub const SLOT_DICT_KEYS: u32 = 0;
pub const SLOT_DICT_VALUES: u32 = 1;
pub const SLOT_DICT_COUNT: u32 = 2;
pub const DICT_INST_SIZE: u32 = 3;
pub const DICT_INITIAL_CAPACITY: u32 = 64;

// SystemDictionary needs headroom for kernel entries (~16) plus runtime
// globals introduced by `assign`. v0 uses a fixed-capacity dictionary
// (no rehash); 256 is comfortable while we have no GC and no millions
// of names.
pub const SYSTEM_DICT_CAPACITY: u32 = 256;
// Symbol intern table — every distinct Symbol byte sequence maps to a
// unique heap object. Sized for the kernel plus user code; v0 has no
// rehash.
pub const INTERN_TABLE_CAPACITY: u32 = 4096;

// CompiledMethod slot layout. Six slots cover both kinds:
//   slot[3] is primitive_id when kind=primitive, body_holder when kind=AST
//   slots 4-5 are params/temps Symbol arrays for AST methods, NIL for primitives
pub const SLOT_METHOD_SELECTOR: u32 = 0;
pub const SLOT_METHOD_ARG_COUNT: u32 = 1;
pub const SLOT_METHOD_KIND: u32 = 2;
pub const SLOT_METHOD_PRIMITIVE: u32 = 3;
pub const SLOT_METHOD_BODY: u32 = 3;
pub const SLOT_METHOD_PARAMS: u32 = 4;
pub const SLOT_METHOD_TEMPS: u32 = 5;
// The class in whose method dictionary this method lives. Used by
// `super` to start lookup at defining_class.superclass.
pub const SLOT_METHOD_DEFINING_CLASS: u32 = 6;
// Bytecode cache. For KIND_AST methods these slots are NIL until the
// method is compiled to bytecode (Phase D). For KIND_BYTECODE methods
// they hold the compiled byte stream and the literal-pool array.
pub const SLOT_METHOD_BYTECODE: u32 = 7;
pub const SLOT_METHOD_LITERALS: u32 = 8;
// Tier-up plumbing for the ARM64 JIT (Phase J). HOT_COUNT is a tagged
// SmallInteger that increments on each bytecode invocation; once it
// crosses the JIT threshold we attempt compileTrivial / compileMethod.
// NATIVE_ENTRY is the byte offset into vm.jit_buf at which the
// compiled function begins; only meaningful when KIND == NATIVE.
pub const SLOT_METHOD_HOT_COUNT: u32 = 9;
pub const SLOT_METHOD_NATIVE_ENTRY: u32 = 10;
pub const METHOD_INST_SIZE: u32 = 11;

pub const METHOD_KIND_PRIMITIVE: i64 = 0;
pub const METHOD_KIND_AST: i64 = 1;
pub const METHOD_KIND_BYTECODE: i64 = 2;
pub const METHOD_KIND_NATIVE: i64 = 3;

// Frame: a method/block activation record. Variable lookup walks the
// chain via the parent slot before falling back to Smalltalk.
// Variable-sized Frame: two header slots (parent, source) followed
// by the inline value array. value_count = 1+params+temps for method
// frames (slot 0 is `self`) or params+temps for block frames. The
// AST interpreter virtualizes the names array via frame.source —
// see frame.zig findBySym.
pub const SLOT_FRAME_PARENT: u32 = 0;
pub const SLOT_FRAME_SOURCE: u32 = 1;
pub const FRAME_VALUES_OFFSET: u32 = 2;

// BlockClosure: a code value capturing the lexical frame at creation
// time. The body slot encodes a pointer into the Vm's long-lived AST
// arena as a SmallInteger (v0 hack; replace with in-image AST later).
pub const SLOT_BLOCK_PARENT_FRAME: u32 = 0;
pub const SLOT_BLOCK_PARAMS: u32 = 1;
pub const SLOT_BLOCK_TEMPS: u32 = 2;
// Either an AST body (Array of statement nodes — kind AST) or a
// bytecode ByteArray (kind BYTECODE). The interpreter discriminates
// by checking the body's class.
pub const SLOT_BLOCK_BODY: u32 = 3;
pub const SLOT_BLOCK_HOME_METHOD: u32 = 4;
pub const SLOT_BLOCK_LITERALS: u32 = 5;
pub const BLOCK_INST_SIZE: u32 = 6;

// AST nodes are real heap objects, one class per node kind. Bodies of
// methods, blocks, and seq nodes hold an Array of AstNode Oops directly
// — no Zig-side arena, no body-holder hack.

// LiteralNode { value: Oop }
//   Eval just returns slot[0]; literal nil/true/false/int/string each
//   store the runtime value directly in slot[0].
pub const SLOT_LIT_VALUE: u32 = 0;
pub const LIT_INST_SIZE: u32 = 1;

// VarRefNode { name: Symbol }
pub const SLOT_VARREF_NAME: u32 = 0;
pub const VARREF_INST_SIZE: u32 = 1;

// AssignNode { name: Symbol, value: AstNode }
pub const SLOT_ASSIGN_NAME: u32 = 0;
pub const SLOT_ASSIGN_VALUE: u32 = 1;
pub const ASSIGN_INST_SIZE: u32 = 2;

// SendNode { receiver, selector, args,
//            cached_class_1, cached_method_1,
//            cached_class_2, cached_method_2 }
//   Bimorphic inline cache: two (class, method) pairs per call site.
//   Slot 1 is the most-recently-installed entry; on miss it gets
//   demoted to slot 2 and the new entry takes slot 1 (Phase C.1).
//   NIL slots indicate empty cache lines.
pub const SLOT_SEND_RECEIVER: u32 = 0;
pub const SLOT_SEND_SELECTOR: u32 = 1;
pub const SLOT_SEND_ARGS: u32 = 2;
pub const SLOT_SEND_CACHED_CLASS: u32 = 3;
pub const SLOT_SEND_CACHED_METHOD: u32 = 4;
pub const SLOT_SEND_CACHED_CLASS_2: u32 = 5;
pub const SLOT_SEND_CACHED_METHOD_2: u32 = 6;
pub const SEND_INST_SIZE: u32 = 7;

// SuperSendNode { selector, args, cached_method }
//   super lookup starts from a class fixed at parse time (the method's
//   defining class), so a single cached_method is enough — no class
//   check needed.
pub const SLOT_SUPER_SELECTOR: u32 = 0;
pub const SLOT_SUPER_ARGS: u32 = 1;
pub const SLOT_SUPER_CACHED_METHOD: u32 = 2;
pub const SUPER_INST_SIZE: u32 = 3;

// BlockNode { params: Array of Symbol, temps: Array of Symbol, body: Array of AstNode }
pub const SLOT_BLOCKNODE_PARAMS: u32 = 0;
pub const SLOT_BLOCKNODE_TEMPS: u32 = 1;
pub const SLOT_BLOCKNODE_BODY: u32 = 2;
pub const BLOCKNODE_INST_SIZE: u32 = 3;

// SeqNode { body: Array of AstNode }
pub const SLOT_SEQ_BODY: u32 = 0;
pub const SEQ_INST_SIZE: u32 = 1;

// RetNode { inner: AstNode }
pub const SLOT_RET_INNER: u32 = 0;
pub const RET_INST_SIZE: u32 = 1;

// Exception { messageText: String }
pub const SLOT_EXCEPTION_MESSAGE: u32 = 0;
pub const EXCEPTION_INST_SIZE: u32 = 1;

pub inline fn headerOf(addr: Oop) *Header {
    return @ptrFromInt(addr);
}

pub inline fn slotsOf(addr: Oop) [*]Oop {
    const base: [*]u8 = @ptrFromInt(addr);
    return @ptrCast(@alignCast(base + @sizeOf(Header)));
}

pub inline fn bytesOf(addr: Oop) [*]u8 {
    const base: [*]u8 = @ptrFromInt(addr);
    return base + @sizeOf(Header);
}

pub fn slot(addr: Oop, i: u32) Oop {
    std.debug.assert(i < headerOf(addr).size);
    return slotsOf(addr)[i];
}

pub fn setSlot(addr: Oop, i: u32, value: Oop) void {
    std.debug.assert(i < headerOf(addr).size);
    slotsOf(addr)[i] = value;
}
