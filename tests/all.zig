// Test entry: pulls every test file in for `zig build test` discovery.

comptime {
    _ = @import("test_floats.zig");
    _ = @import("test_largeint.zig");
    _ = @import("test_fraction.zig");
    _ = @import("test_math.zig");
    _ = @import("test_blocks.zig");
    _ = @import("test_warmup.zig");
    _ = @import("test_concurrency.zig");
    _ = @import("test_dnu.zig");
    _ = @import("test_io.zig");
    _ = @import("test_reflection.zig");
    _ = @import("test_exceptions.zig");
    _ = @import("test_collections.zig");
    _ = @import("test_sockets.zig");
    _ = @import("test_json.zig");
}
