// Harness for end-to-end protocol-level tests and benchmarks. Stands up
// a fresh VM (heap + bootstrap + globals), parses Smalltalk programs
// from JSON-AST literals (the same shape the daemon's eval and
// define_method requests carry), and exposes installMethod/defineClass
// helpers so callers can build small classes and invoke them
// in-process. Used by tests/ and bench/.

const std = @import("std");
const vm = @import("vm");

pub const TestEnv = struct {
    heap: vm.Heap,
    machine: vm.Vm,

    /// 8 MiB default. Override for heap-pressure tests by calling
    /// initWithHeap directly.
    pub fn init(self: *TestEnv) !void {
        return self.initWithHeap(8 * 1024 * 1024);
    }

    pub fn initWithHeap(self: *TestEnv, heap_bytes: usize) !void {
        self.heap = try vm.Heap.init(heap_bytes);
        const g = try vm.bootstrap.bootstrap(&self.heap);
        self.machine = .{ .heap = &self.heap, .globals = g };
    }

    pub fn deinit(self: *TestEnv) void {
        self.heap.deinit();
    }

    /// Parse and evaluate. Routes through evalAsTopLevel so the result
    /// goes through the JIT eager-tier-up path the daemon uses — that
    /// way benchmarks see the same dispatch shape they'd see in
    /// production, and tests catch JIT-specific regressions.
    pub fn evalJson(self: *TestEnv, json: []const u8) !vm.Oop {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const node = vm.ast.parse(&self.heap, &self.machine.globals, arena.allocator(), json) catch |e| switch (e) {
            error.InvalidJson => return error.NotImplemented,
            error.UnknownNodeKind => return error.UnknownNodeClass,
            error.MissingField, error.BadFieldType => return error.NotImplemented,
            error.IntOverflow => return error.IntOverflow,
            error.OutOfMemory => return error.OutOfMemory,
            error.DictionaryFull => return error.DictionaryFull,
        };
        return self.machine.evalAsTopLevel(node);
    }

    pub fn evalSource(self: *TestEnv, source: []const u8) !vm.Oop {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const node = try vm.smalltalk.parseTopLevelToHeap(&self.heap, &self.machine.globals, arena.allocator(), source);
        return self.machine.evalAsTopLevel(node);
    }

    pub fn defineClass(
        self: *TestEnv,
        name: []const u8,
        super_name: []const u8,
        ivars: []const []const u8,
    ) !vm.Oop {
        const super = vm.dict.lookup(self.machine.globals.smalltalk, super_name);
        if (vm.oop.isNil(super)) return error.UnknownClass;
        const cls = try vm.class.defineClass(&self.heap, &self.machine.globals, name, super, ivars);
        _ = try vm.dict.atPut(&self.heap, self.machine.globals.smalltalk, &self.machine.globals, name, cls);
        return cls;
    }

    /// Install a method whose body is a JSON array of statement nodes
    /// (e.g. `[{"send":...}, {"assign":...}]`). Mirrors the daemon's
    /// define_method shape so test bodies look like the original Python
    /// driver but compile in-tree as Zig.
    pub fn installMethod(
        self: *TestEnv,
        class_name: []const u8,
        selector: []const u8,
        params: []const []const u8,
        temps: []const []const u8,
        body_json: []const u8,
    ) !void {
        const cls = vm.dict.lookup(self.machine.globals.smalltalk, class_name);
        if (vm.oop.isNil(cls)) return error.UnknownClass;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var parsed = try std.json.parseFromSlice(std.json.Value, a, body_json, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.BadFieldType;

        const body_arr = try self.heap.allocSlots(
            self.machine.globals.array_class,
            @intCast(parsed.value.array.items.len),
        );
        for (parsed.value.array.items, 0..) |stmt, i| {
            const node = try vm.ast.fromValue(&self.heap, &self.machine.globals, a, stmt);
            vm.object.setSlot(body_arr, @intCast(i), node);
        }

        const params_arr = try self.heap.allocSlots(
            self.machine.globals.array_class,
            @intCast(params.len),
        );
        for (params, 0..) |p, i| {
            const sym = try vm.dict.newSymbol(&self.heap, &self.machine.globals, p);
            vm.object.setSlot(params_arr, @intCast(i), sym);
        }

        const temps_arr = try self.heap.allocSlots(
            self.machine.globals.array_class,
            @intCast(temps.len),
        );
        for (temps, 0..) |t, i| {
            const sym = try vm.dict.newSymbol(&self.heap, &self.machine.globals, t);
            vm.object.setSlot(temps_arr, @intCast(i), sym);
        }

        const method = try vm.method.newAst(
            &self.heap,
            &self.machine.globals,
            cls,
            selector,
            @intCast(params.len),
            params_arr,
            temps_arr,
            body_arr,
        );
        try vm.method.install(
            &self.heap,
            &self.machine.globals,
            &self.machine,
            cls,
            selector,
            method,
        );
    }

    pub fn installMethodSource(
        self: *TestEnv,
        class_name: []const u8,
        method_source: []const u8,
    ) !void {
        const cls = vm.dict.lookup(self.machine.globals.smalltalk, class_name);
        if (vm.oop.isNil(cls)) return error.UnknownClass;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const lowered = try vm.smalltalk.parseMethodToHeap(
            &self.heap,
            &self.machine.globals,
            arena.allocator(),
            method_source,
        );

        const method = try vm.method.newAst(
            &self.heap,
            &self.machine.globals,
            cls,
            lowered.selector,
            lowered.arg_count,
            lowered.params_arr,
            lowered.temps_arr,
            lowered.body_arr,
        );
        try vm.method.install(
            &self.heap,
            &self.machine.globals,
            &self.machine,
            cls,
            lowered.selector,
            method,
        );
    }
};

/// Format an Oop into `buf` via vm.print.printString. Returns the
/// written slice; errors with OutputTooLarge if the result wouldn't
/// fit.
pub fn printString(env: *TestEnv, o: vm.Oop, buf: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const s = try vm.print.printString(arena.allocator(), &env.machine, o);
    if (s.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}
