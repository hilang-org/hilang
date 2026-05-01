const std = @import("std");

const DEFAULT_SOCKET = "/tmp/hilang.sock";

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    var socket_path: []const u8 = DEFAULT_SOCKET;
    var idx: usize = 0;
    while (idx < args_list.items.len) : (idx += 1) {
        if (std.mem.eql(u8, args_list.items[idx], "--socket") and idx + 1 < args_list.items.len) {
            socket_path = args_list.items[idx + 1];
            idx += 1;
        } else {
            break;
        }
    }

    if (idx >= args_list.items.len) {
        try usage();
        return;
    }

    const cmd = args_list.items[idx];
    idx += 1;

    if (std.mem.eql(u8, cmd, "ping")) {
        try sendRequest(allocator, socket_path, "{\"kind\":\"ping\"}");
        return;
    }

    if (std.mem.eql(u8, cmd, "eval")) {
        if (idx >= args_list.items.len) {
            std.debug.print("eval: missing AST JSON argument\n", .{});
            std.process.exit(2);
        }
        const node_json = args_list.items[idx];

        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.appendSlice(allocator, "{\"kind\":\"eval\",\"node\":");
        try req.appendSlice(allocator, node_json);
        try req.appendSlice(allocator, "}");

        try sendRequest(allocator, socket_path, req.items);
        return;
    }

    if (std.mem.eql(u8, cmd, "eval-st")) {
        if (idx >= args_list.items.len) {
            std.debug.print("eval-st: missing Smalltalk source argument\n", .{});
            std.process.exit(2);
        }
        const source = args_list.items[idx];

        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);
        try req.appendSlice(allocator, "{\"kind\":\"eval_source\",\"source\":");
        try appendJsonString(allocator, &req, source);
        try req.append(allocator, '}');

        try sendRequest(allocator, socket_path, req.items);
        return;
    }

    try usage();
    std.process.exit(2);
}

fn usage() !void {
    const msg =
        \\hilang -- client for the hilang Smalltalk VM
        \\
        \\Usage:
        \\  hilang [--socket PATH] <command> [args...]
        \\
        \\Commands:
        \\  ping                 health check
        \\  eval <ast-json>      evaluate an AST node, print response
        \\  eval-st <source>     evaluate canonical Smalltalk source
        \\
    ;
    std.debug.print("{s}", .{msg});
}

fn sendRequest(allocator: std.mem.Allocator, socket_path: []const u8, request: []const u8) !void {
    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.posix.system.close(fd);

    var addr: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    if (socket_path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    addr.path[socket_path.len] = 0;
    const len: std.posix.socklen_t = @intCast(@sizeOf(std.posix.sockaddr.un));
    if (std.posix.system.connect(fd, @ptrCast(&addr), len) != 0) return error.ConnectFailed;

    try writeAll(fd, request);
    try writeAll(fd, "\n");

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.system.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try resp.appendSlice(allocator, chunk[0..@intCast(n)]);
        if (std.mem.indexOfScalar(u8, resp.items, '\n') != null) break;
    }

    const end = std.mem.indexOfScalar(u8, resp.items, '\n') orelse resp.items.len;
    _ = std.posix.system.write(1, resp.items.ptr, end);
    _ = std.posix.system.write(1, "\n", 1);
}

fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.posix.system.write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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
