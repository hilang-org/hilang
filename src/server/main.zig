const std = @import("std");
const posix = std.posix;
const vm = @import("vm");

const DEFAULT_SOCKET = "/tmp/hilang.sock";
const HEAP_BYTES: usize = 256 * 1024 * 1024;
const MAX_REQUEST: usize = 1 * 1024 * 1024;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Args: [--socket PATH] [--image PATH] [--heap-mb N]
    var socket_path: []const u8 = DEFAULT_SOCKET;
    var image_path: ?[]const u8 = null;
    var heap_bytes: usize = HEAP_BYTES;
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // program name
    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |s| allocator.free(s);
        args_list.deinit(allocator);
    }
    while (it.next()) |arg| {
        try args_list.append(allocator, try allocator.dupe(u8, arg));
    }
    var i: usize = 0;
    while (i < args_list.items.len) : (i += 1) {
        if (std.mem.eql(u8, args_list.items[i], "--socket") and i + 1 < args_list.items.len) {
            socket_path = args_list.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args_list.items[i], "--image") and i + 1 < args_list.items.len) {
            image_path = args_list.items[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args_list.items[i], "--heap-mb") and i + 1 < args_list.items.len) {
            heap_bytes = (try std.fmt.parseInt(usize, args_list.items[i + 1], 10)) * 1024 * 1024;
            i += 1;
        }
    }

    var heap: vm.Heap = undefined;
    var g: vm.Globals = undefined;
    if (image_path) |p| {
        const loaded = try vm.image.load(p, heap_bytes);
        heap = loaded.heap;
        g = loaded.globals;
        std.debug.print("hilang-vm: loaded image {s}\n", .{p});
    } else {
        heap = try vm.Heap.init(heap_bytes);
        g = try vm.bootstrap.bootstrap(&heap);
    }
    defer heap.deinit();

    var machine = vm.Vm{ .heap = &heap, .globals = g };

    // Remove any stale socket. Ignore errors (likely ENOENT).
    {
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        if (socket_path.len < path_buf.len) {
            @memcpy(path_buf[0..socket_path.len], socket_path);
            path_buf[socket_path.len] = 0;
            _ = std.posix.system.unlink(@ptrCast(&path_buf));
        }
    }

    const listen_fd = try unixListen(socket_path);
    defer _ = std.posix.system.close(listen_fd);

    std.debug.print("hilang-vm: listening on {s} (heap {d} MiB)\n", .{ socket_path, heap_bytes / (1024 * 1024) });

    while (true) {
        const conn_fd = std.posix.system.accept(listen_fd, null, null);
        if (conn_fd < 0) {
            std.debug.print("accept error\n", .{});
            continue;
        }
        handleConn(allocator, &machine, conn_fd) catch |e| {
            std.debug.print("conn error: {s}\n", .{@errorName(e)});
        };
        _ = std.posix.system.close(conn_fd);
    }
}

fn unixListen(path: []const u8) !std.posix.fd_t {
    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.posix.system.close(fd);

    var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    // Try to remove any leftover socket; ignore errors.
    _ = std.posix.system.unlink(@ptrCast(&addr.path));

    const len: std.posix.socklen_t = @intCast(@sizeOf(std.posix.sockaddr.un));
    if (std.posix.system.bind(fd, @ptrCast(&addr), len) != 0) return error.BindFailed;
    if (std.posix.system.listen(fd, 16) != 0) return error.ListenFailed;
    return fd;
}

fn readAll(fd: std.posix.fd_t, buf: []u8) !usize {
    const n = std.posix.system.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.posix.system.write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn handleConn(allocator: std.mem.Allocator, machine: *vm.Vm, fd: std.posix.fd_t) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try readAll(fd, &chunk);
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
        if (buf.items.len > MAX_REQUEST) return error.RequestTooLarge;
        if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
    }

    const newline_idx = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
    const line = buf.items[0..newline_idx];

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    try dispatch(allocator, machine, line, &resp);
    try resp.append(allocator, '\n');
    try writeAll(fd, resp.items);
}

fn dispatch(allocator: std.mem.Allocator, machine: *vm.Vm, line: []const u8, out: *std.ArrayList(u8)) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        try writeError(allocator, out, "InvalidJson", "could not parse request");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeError(allocator, out, "BadRequest", "request must be a JSON object");
        return;
    }
    const obj = parsed.value.object;
    const kind_v = obj.get("kind") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'kind' field");
        return;
    };
    if (kind_v != .string) {
        try writeError(allocator, out, "BadRequest", "'kind' must be a string");
        return;
    }
    const kind = kind_v.string;

    if (std.mem.eql(u8, kind, "ping")) {
        try out.appendSlice(allocator, "{\"ok\":true,\"pong\":true}");
        return;
    }

    if (std.mem.eql(u8, kind, "eval")) {
        try handleEval(allocator, machine, obj, out);
        return;
    }

    if (std.mem.eql(u8, kind, "classes")) {
        try handleClasses(allocator, machine, out);
        return;
    }

    if (std.mem.eql(u8, kind, "define_method")) {
        try handleDefineMethod(allocator, machine, obj, out);
        return;
    }

    if (std.mem.eql(u8, kind, "define_class")) {
        try handleDefineClass(allocator, machine, obj, out);
        return;
    }

    if (std.mem.eql(u8, kind, "inspect")) {
        try handleInspect(allocator, machine, obj, out);
        return;
    }

    if (std.mem.eql(u8, kind, "methods")) {
        try handleMethods(allocator, machine, obj, out);
        return;
    }

    if (std.mem.eql(u8, kind, "snapshot")) {
        try handleSnapshot(allocator, machine, obj, out);
        return;
    }

    if (std.mem.eql(u8, kind, "gc")) {
        const before = machine.heap.used;
        machine.collectGarbage() catch |e| {
            try writeError(allocator, out, "GcFailed", @errorName(e));
            return;
        };
        const after = machine.heap.used;
        try out.appendSlice(allocator, "{\"ok\":true,\"before\":");
        var num_buf: [32]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{before}));
        try out.appendSlice(allocator, ",\"after\":");
        try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{after}));
        try out.appendSlice(allocator, "}");
        return;
    }

    try writeError(allocator, out, "UnknownKind", kind);
}

// Try parsing+evaluating; on OOM, GC once and retry. After GC, the
// transient AST from the failed attempt is unreachable garbage and
// gets reclaimed; the JSON Value tree (in the request arena) survives
// for the second parse.
fn parseAndEvalWithRetry(machine: *vm.Vm, scratch: std.mem.Allocator, node_v: std.json.Value) !vm.Oop {
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const node = vm.ast.fromValue(machine.heap, &machine.globals, scratch, node_v) catch |e| {
            if (e == error.OutOfMemory and attempt == 0) {
                try machine.collectGarbage();
                continue;
            }
            return e;
        };
        return machine.evalAsTopLevel(node) catch |e| {
            if (e == error.OutOfMemory and attempt == 0) {
                try machine.collectGarbage();
                continue;
            }
            return e;
        };
    }
    return error.OutOfMemory;
}

fn handleEval(allocator: std.mem.Allocator, machine: *vm.Vm, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) !void {
    const node_v = obj.get("node") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'node' field");
        return;
    };

    // Per-request arena for transient strings (printString, JSON
    // building). AST nodes are heap objects materialized directly into
    // machine.heap by ast.fromValue.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(allocator);
    machine.output = .{ .buffer = &capture, .allocator = allocator };
    defer machine.output = null;

    // Try once; if anything OOMs, GC and retry once. After a successful
    // GC, the AST from the first parse is unreachable garbage; we
    // reparse from the same JSON Value.
    const t_start = nowNs();
    const result = parseAndEvalWithRetry(machine, a, node_v) catch |e| {
        try writeError(allocator, out, "EvalError", @errorName(e));
        return;
    };
    const duration_ns = nowNs() - t_start;

    const printed = vm.print.printString(a, machine, result) catch |e| {
        try writeError(allocator, out, "PrintError", @errorName(e));
        return;
    };

    try out.appendSlice(allocator, "{\"ok\":true,\"oop\":");
    var oop_buf: [32]u8 = undefined;
    const oop_str = try std.fmt.bufPrint(&oop_buf, "{d}", .{result});
    try out.appendSlice(allocator, oop_str);
    try out.appendSlice(allocator, ",\"printed\":");
    try writeJsonString(allocator, out, printed);
    try out.appendSlice(allocator, ",\"output\":");
    try writeJsonString(allocator, out, capture.items);
    try out.appendSlice(allocator, ",\"duration_ns\":");
    var dur_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&dur_buf, "{d}", .{duration_ns}));
    try out.appendSlice(allocator, "}");
}

fn handleSnapshot(allocator: std.mem.Allocator, machine: *vm.Vm, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) !void {
    const path_v = obj.get("path") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'path'");
        return;
    };
    if (path_v != .string) {
        try writeError(allocator, out, "BadRequest", "'path' must be string");
        return;
    }
    vm.image.save(machine.heap, path_v.string) catch |e| {
        try writeError(allocator, out, "SaveFailed", @errorName(e));
        return;
    };
    try out.appendSlice(allocator, "{\"ok\":true,\"path\":");
    try writeJsonString(allocator, out, path_v.string);
    try out.appendSlice(allocator, ",\"bytes\":");
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{machine.heap.used}));
    try out.appendSlice(allocator, "}");
}

fn handleInspect(allocator: std.mem.Allocator, machine: *vm.Vm, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) !void {
    const oop_v = obj.get("oop") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'oop'");
        return;
    };
    if (oop_v != .integer) {
        try writeError(allocator, out, "BadRequest", "'oop' must be integer");
        return;
    }
    const o: vm.Oop = @bitCast(oop_v.integer);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const class_oop = machine.classOf(o);
    const class_name = (try vm.print.classDisplayName(a, machine, class_oop)) orelse "?";
    const printed = try vm.print.printString(a, machine, o);

    try out.appendSlice(allocator, "{\"ok\":true,\"oop\":");
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{o}));
    try out.appendSlice(allocator, ",\"class\":");
    try writeJsonString(allocator, out, class_name);
    try out.appendSlice(allocator, ",\"printed\":");
    try writeJsonString(allocator, out, printed);

    if (!vm.oop.isHeapPtr(o)) {
        try out.appendSlice(allocator, ",\"slots\":[]}");
        return;
    }

    const hdr = vm.object.headerOf(o);
    const is_bytes = (hdr.flags & vm.object.FLAG_BYTES) != 0;
    try out.appendSlice(allocator, ",\"is_bytes\":");
    try out.appendSlice(allocator, if (is_bytes) "true" else "false");
    try out.appendSlice(allocator, ",\"size\":");
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{hdr.size}));

    if (is_bytes) {
        try out.appendSlice(allocator, ",\"bytes\":");
        const bytes = vm.object.bytesOf(o)[0..hdr.size];
        try writeJsonString(allocator, out, bytes);
        try out.appendSlice(allocator, "}");
        return;
    }

    // Pointer object: dump each slot. If the receiver's class chain has
    // ivar names, pair them with slot indices.
    var ivar_names: std.ArrayList([]const u8) = .empty;
    defer ivar_names.deinit(a);
    try gatherIvarNames(a, &ivar_names, class_oop);

    try out.appendSlice(allocator, ",\"slots\":[");
    var i: u32 = 0;
    while (i < hdr.size) : (i += 1) {
        if (i > 0) try out.append(allocator, ',');
        const v = vm.object.slot(o, i);
        const slot_class_name = (try vm.print.classDisplayName(a, machine, machine.classOf(v))) orelse "?";
        const slot_printed = try vm.print.printString(a, machine, v);
        try out.appendSlice(allocator, "{\"index\":");
        try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{i}));
        try out.appendSlice(allocator, ",\"name\":");
        if (i < ivar_names.items.len) {
            try writeJsonString(allocator, out, ivar_names.items[i]);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.appendSlice(allocator, ",\"oop\":");
        try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{v}));
        try out.appendSlice(allocator, ",\"class\":");
        try writeJsonString(allocator, out, slot_class_name);
        try out.appendSlice(allocator, ",\"printed\":");
        try writeJsonString(allocator, out, slot_printed);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
}

// Collect ivar names in slot-index order: superclass ivars first.
fn gatherIvarNames(a: std.mem.Allocator, list: *std.ArrayList([]const u8), class: vm.Oop) !void {
    if (!vm.oop.isHeapPtr(class)) return;
    const super = vm.object.slot(class, vm.object.SLOT_SUPERCLASS);
    try gatherIvarNames(a, list, super);

    if (vm.object.headerOf(class).size <= vm.object.SLOT_CLASS_IVAR_NAMES) return;
    const names = vm.object.slot(class, vm.object.SLOT_CLASS_IVAR_NAMES);
    if (!vm.oop.isHeapPtr(names)) return;
    const n = vm.object.headerOf(names).size;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const sym = vm.object.slot(names, i);
        if (!vm.oop.isHeapPtr(sym)) continue;
        const hdr = vm.object.headerOf(sym);
        if ((hdr.flags & vm.object.FLAG_BYTES) == 0) continue;
        const bytes = vm.object.bytesOf(sym)[0..hdr.size];
        try list.append(a, bytes);
    }
}

fn handleMethods(allocator: std.mem.Allocator, machine: *vm.Vm, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) !void {
    const class_v = obj.get("class") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'class'");
        return;
    };
    if (class_v != .string) {
        try writeError(allocator, out, "BadRequest", "'class' must be string");
        return;
    }
    const include_inherited = blk: {
        const v = obj.get("include_inherited") orelse break :blk false;
        if (v == .bool) break :blk v.bool;
        break :blk false;
    };

    const start_class = vm.dict.lookup(machine.globals.smalltalk, class_v.string);
    if (vm.oop.isNil(start_class)) {
        try writeError(allocator, out, "UnknownClass", class_v.string);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try out.appendSlice(allocator, "{\"ok\":true,\"class\":");
    try writeJsonString(allocator, out, class_v.string);
    try out.appendSlice(allocator, ",\"entries\":[");

    var first: bool = true;
    var cls = start_class;
    while (vm.oop.isHeapPtr(cls)) {
        const md = vm.object.slot(cls, vm.object.SLOT_METHOD_DICT);
        if (vm.oop.isHeapPtr(md)) {
            const keys = vm.object.slot(md, vm.object.SLOT_DICT_KEYS);
            const vals = vm.object.slot(md, vm.object.SLOT_DICT_VALUES);
            const count: u32 = @intCast(vm.oop.toInt(vm.object.slot(md, vm.object.SLOT_DICT_COUNT)));
            const cls_name = (try vm.print.classDisplayName(a, machine, cls)) orelse "?";

            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (!first) try out.append(allocator, ',');
                first = false;

                const sel = vm.object.slot(keys, i);
                const sel_hdr = vm.object.headerOf(sel);
                const sel_bytes = vm.object.bytesOf(sel)[0..sel_hdr.size];

                const m = vm.object.slot(vals, i);
                const arg_count = vm.oop.toInt(vm.object.slot(m, vm.object.SLOT_METHOD_ARG_COUNT));
                const kind = vm.oop.toInt(vm.object.slot(m, vm.object.SLOT_METHOD_KIND));
                const kind_str: []const u8 = if (kind == vm.object.METHOD_KIND_PRIMITIVE) "primitive" else "ast";

                try out.appendSlice(allocator, "{\"selector\":");
                try writeJsonString(allocator, out, sel_bytes);
                try out.appendSlice(allocator, ",\"arg_count\":");
                var num_buf: [32]u8 = undefined;
                try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{arg_count}));
                try out.appendSlice(allocator, ",\"kind\":");
                try writeJsonString(allocator, out, kind_str);
                try out.appendSlice(allocator, ",\"defined_in\":");
                try writeJsonString(allocator, out, cls_name);
                try out.append(allocator, '}');
            }
        }
        if (!include_inherited) break;
        cls = vm.object.slot(cls, vm.object.SLOT_SUPERCLASS);
    }

    try out.appendSlice(allocator, "]}");
}

fn handleDefineClass(allocator: std.mem.Allocator, machine: *vm.Vm, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) !void {
    const name_v = obj.get("name") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'name'");
        return;
    };
    const super_v = obj.get("super") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'super'");
        return;
    };
    const ivars_v = obj.get("ivars") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'ivars'");
        return;
    };
    if (name_v != .string or super_v != .string or ivars_v != .array) {
        try writeError(allocator, out, "BadRequest", "wrong field types");
        return;
    }

    const super = vm.dict.lookup(machine.globals.smalltalk, super_v.string);
    if (vm.oop.isNil(super)) {
        try writeError(allocator, out, "UnknownClass", super_v.string);
        return;
    }

    var ivar_buf: [64][]const u8 = undefined;
    if (ivars_v.array.items.len > ivar_buf.len) {
        try writeError(allocator, out, "BadRequest", "too many ivars");
        return;
    }
    for (ivars_v.array.items, 0..) |iv, i| {
        if (iv != .string) {
            try writeError(allocator, out, "BadRequest", "ivar must be string");
            return;
        }
        ivar_buf[i] = iv.string;
    }
    const ivars = ivar_buf[0..ivars_v.array.items.len];

    const cls = vm.class.defineClass(machine.heap, &machine.globals, name_v.string, super, ivars) catch {
        try writeError(allocator, out, "DefineFailed", "alloc");
        return;
    };
    _ = vm.dict.atPut(machine.heap, machine.globals.smalltalk, &machine.globals, name_v.string, cls) catch {
        try writeError(allocator, out, "DefineFailed", "register");
        return;
    };

    try out.appendSlice(allocator, "{\"ok\":true,\"class\":");
    try writeJsonString(allocator, out, name_v.string);
    try out.appendSlice(allocator, ",\"oop\":");
    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{cls}));
    try out.appendSlice(allocator, "}");
}

fn handleDefineMethod(allocator: std.mem.Allocator, machine: *vm.Vm, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) !void {
    const class_v = obj.get("class") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'class'");
        return;
    };
    const sel_v = obj.get("selector") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'selector'");
        return;
    };
    const params_v = obj.get("params") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'params'");
        return;
    };
    const temps_v = obj.get("temps") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'temps'");
        return;
    };
    const body_v = obj.get("body") orelse {
        try writeError(allocator, out, "BadRequest", "missing 'body'");
        return;
    };
    if (class_v != .string or sel_v != .string or params_v != .array or temps_v != .array or body_v != .array) {
        try writeError(allocator, out, "BadRequest", "wrong field types");
        return;
    }

    const cls = vm.dict.lookup(machine.globals.smalltalk, class_v.string);
    if (vm.oop.isNil(cls)) {
        try writeError(allocator, out, "UnknownClass", class_v.string);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Body is an Array of AST node Oops, materialized directly into
    // the heap. Survives image save/load like any other heap object.
    const body_arr = machine.heap.allocSlots(machine.globals.array_class, @intCast(body_v.array.items.len)) catch {
        try writeError(allocator, out, "OutOfMemory", "body");
        return;
    };
    for (body_v.array.items, 0..) |stmt, i| {
        const stmt_node = vm.ast.fromValue(machine.heap, &machine.globals, a, stmt) catch |e| {
            try writeError(allocator, out, "ParseError", @errorName(e));
            return;
        };
        vm.object.setSlot(body_arr, @intCast(i), stmt_node);
    }

    // Params and temps Symbol arrays.
    const params_arr = machine.heap.allocSlots(machine.globals.array_class, @intCast(params_v.array.items.len)) catch {
        try writeError(allocator, out, "OutOfMemory", "params");
        return;
    };
    for (params_v.array.items, 0..) |p, i| {
        if (p != .string) {
            try writeError(allocator, out, "BadRequest", "param must be string");
            return;
        }
        const sym = vm.dict.newSymbol(machine.heap, &machine.globals, p.string) catch {
            try writeError(allocator, out, "OutOfMemory", "param symbol");
            return;
        };
        vm.object.setSlot(params_arr, @intCast(i), sym);
    }
    const temps_arr = machine.heap.allocSlots(machine.globals.array_class, @intCast(temps_v.array.items.len)) catch {
        try writeError(allocator, out, "OutOfMemory", "temps");
        return;
    };
    for (temps_v.array.items, 0..) |t, i| {
        if (t != .string) {
            try writeError(allocator, out, "BadRequest", "temp must be string");
            return;
        }
        const sym = vm.dict.newSymbol(machine.heap, &machine.globals, t.string) catch {
            try writeError(allocator, out, "OutOfMemory", "temp symbol");
            return;
        };
        vm.object.setSlot(temps_arr, @intCast(i), sym);
    }

    const method = vm.method.newAst(
        machine.heap,
        &machine.globals,
        cls,
        sel_v.string,
        @intCast(params_v.array.items.len),
        params_arr,
        temps_arr,
        body_arr,
    ) catch {
        try writeError(allocator, out, "OutOfMemory", "newAst");
        return;
    };

    vm.method.install(machine.heap, &machine.globals, machine, cls, sel_v.string, method) catch {
        try writeError(allocator, out, "InstallFailed", "install");
        return;
    };

    try out.appendSlice(allocator, "{\"ok\":true,\"class\":");
    try writeJsonString(allocator, out, class_v.string);
    try out.appendSlice(allocator, ",\"selector\":");
    try writeJsonString(allocator, out, sel_v.string);
    try out.appendSlice(allocator, "}");
}

fn handleClasses(allocator: std.mem.Allocator, machine: *vm.Vm, out: *std.ArrayList(u8)) !void {
    const dict = machine.globals.smalltalk;
    if (vm.oop.isNil(dict)) {
        try writeError(allocator, out, "NoSmalltalk", "SystemDictionary not bootstrapped");
        return;
    }
    const keys = vm.object.slot(dict, vm.object.SLOT_DICT_KEYS);
    const vals = vm.object.slot(dict, vm.object.SLOT_DICT_VALUES);
    const count: u32 = @intCast(vm.oop.toInt(vm.object.slot(dict, vm.object.SLOT_DICT_COUNT)));

    try out.appendSlice(allocator, "{\"ok\":true,\"entries\":[");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try out.append(allocator, ',');
        const key = vm.object.slot(keys, i);
        const val = vm.object.slot(vals, i);

        const key_hdr = vm.object.headerOf(key);
        const key_bytes = vm.object.bytesOf(key)[0..key_hdr.size];

        try out.appendSlice(allocator, "{\"name\":");
        try writeJsonString(allocator, out, key_bytes);
        try out.appendSlice(allocator, ",\"oop\":");
        var num_buf: [32]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{val}));

        // Superclass name (or null for Object, whose superclass is nil,
        // and for non-class entries like Smalltalk itself).
        const is_class = blk: {
            const meta = machine.classOf(val);
            if (!vm.oop.isHeapPtr(meta)) break :blk false;
            break :blk machine.classOf(meta) == machine.globals.metaclass_class;
        };
        const super_name: ?[]const u8 = blk: {
            if (!is_class) break :blk null;
            const super = vm.object.slot(val, vm.object.SLOT_SUPERCLASS);
            break :blk vm.print.classNameBytes(machine, super);
        };
        try out.appendSlice(allocator, ",\"superclass\":");
        if (super_name) |n| try writeJsonString(allocator, out, n) else try out.appendSlice(allocator, "null");

        // header.class rendered as a string. For classes this is a
        // metaclass; classDisplayName renders it as "Foo class".
        const meta_name = try vm.print.classDisplayName(allocator, machine, machine.classOf(val));
        defer if (meta_name) |n| allocator.free(n);
        try out.appendSlice(allocator, ",\"class\":");
        if (meta_name) |n| try writeJsonString(allocator, out, n) else try out.appendSlice(allocator, "null");

        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}");
}

fn writeError(allocator: std.mem.Allocator, out: *std.ArrayList(u8), code: []const u8, msg: []const u8) !void {
    try out.appendSlice(allocator, "{\"ok\":false,\"error\":");
    try writeJsonString(allocator, out, code);
    try out.appendSlice(allocator, ",\"message\":");
    try writeJsonString(allocator, out, msg);
    try out.appendSlice(allocator, "}");
}

fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var hex: [6]u8 = undefined;
                    _ = try std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c});
                    try out.appendSlice(allocator, &hex);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}
