pub const oop = @import("oop.zig");
pub const object = @import("object.zig");
pub const heap = @import("heap.zig");
pub const ast = @import("ast.zig");
pub const eval = @import("eval.zig");
pub const print = @import("print.zig");
pub const globals = @import("globals.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const dict = @import("dict.zig");
pub const method = @import("method.zig");
pub const prims = @import("prims.zig");
pub const class = @import("class.zig");
pub const image = @import("image.zig");
pub const gc = @import("gc.zig");
pub const stdlib = @import("stdlib.zig");
pub const jit = @import("jit.zig");
pub const scheduler = @import("scheduler.zig");

pub const Heap = heap.Heap;
pub const Vm = eval.Vm;
pub const Oop = oop.Oop;
pub const Globals = globals.Globals;

// `pub const x = @import(...)` registers the namespace but does
// NOT pull a file's `test "..."` blocks into `zig build test` —
// only `comptime { _ = @import(...) }` does. List every vm-side
// file that contains tests so they're discovered.
comptime {
    _ = @import("bootstrap.zig");
    _ = @import("eval.zig");
    _ = @import("jit.zig");
    _ = @import("scheduler.zig");
}
