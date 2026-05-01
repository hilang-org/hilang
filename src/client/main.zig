const std = @import("std");
const noise = @import("noise");

const DEFAULT_SOCKET = "/tmp/hilang.sock";
const MAX_RESPONSE: usize = 1 * 1024 * 1024;

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
    var host: ?[]const u8 = null;
    var port: ?u16 = null;
    var noise_secret_path: ?[]const u8 = null;
    var noise_peer_path: ?[]const u8 = null;
    var idx: usize = 0;
    while (idx < args_list.items.len) : (idx += 1) {
        if (std.mem.eql(u8, args_list.items[idx], "--socket") and idx + 1 < args_list.items.len) {
            socket_path = args_list.items[idx + 1];
            idx += 1;
        } else if (std.mem.eql(u8, args_list.items[idx], "--host") and idx + 1 < args_list.items.len) {
            host = args_list.items[idx + 1];
            idx += 1;
        } else if (std.mem.eql(u8, args_list.items[idx], "--port") and idx + 1 < args_list.items.len) {
            port = try std.fmt.parseInt(u16, args_list.items[idx + 1], 10);
            idx += 1;
        } else if (std.mem.eql(u8, args_list.items[idx], "--noise-secret") and idx + 1 < args_list.items.len) {
            noise_secret_path = args_list.items[idx + 1];
            idx += 1;
        } else if (std.mem.eql(u8, args_list.items[idx], "--noise-peer") and idx + 1 < args_list.items.len) {
            noise_peer_path = args_list.items[idx + 1];
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

    if (std.mem.eql(u8, cmd, "noise-keygen")) {
        if (idx >= args_list.items.len) {
            std.debug.print("noise-keygen: missing output prefix\n", .{});
            std.process.exit(2);
        }
        try keygen(allocator, args_list.items[idx]);
        return;
    }

    if (std.mem.eql(u8, cmd, "ping")) {
        try sendRequest(allocator, socket_path, host, port, noise_secret_path, noise_peer_path, "{\"kind\":\"ping\"}");
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

        try sendRequest(allocator, socket_path, host, port, noise_secret_path, noise_peer_path, req.items);
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

        try sendRequest(allocator, socket_path, host, port, noise_secret_path, noise_peer_path, req.items);
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
        \\  hilang --host HOST --port PORT --noise-secret KEY --noise-peer KEY <command> [args...]
        \\
        \\Commands:
        \\  ping                 health check
        \\  eval <ast-json>      evaluate an AST node, print response
        \\  eval-st <source>     evaluate canonical Smalltalk source
        \\  noise-keygen PREFIX  write PREFIX.noise-secret / PREFIX.noise-public
        \\
    ;
    std.debug.print("{s}", .{msg});
}

fn sendRequest(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    host: ?[]const u8,
    port: ?u16,
    noise_secret_path: ?[]const u8,
    noise_peer_path: ?[]const u8,
    request: []const u8,
) !void {
    if ((host != null) or (port != null)) {
        if (host == null or port == null) return error.BadRequest;
        if (noise_secret_path == null or noise_peer_path == null) return error.BadRequest;
        return sendRequestNoise(allocator, host.?, port.?, noise_secret_path.?, noise_peer_path.?, request);
    }
    if (noise_secret_path != null or noise_peer_path != null) return error.BadRequest;
    return sendRequestUnix(allocator, socket_path, request);
}

fn sendRequestUnix(allocator: std.mem.Allocator, socket_path: []const u8, request: []const u8) !void {
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

fn sendRequestNoise(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    secret_path: []const u8,
    peer_path: []const u8,
    request: []const u8,
) !void {
    const local_static = try noise.loadSecretKeyFile(allocator, secret_path);
    const peer = try noise.loadPublicKeyFile(allocator, peer_path);
    const fd = try noise.tcpConnect(host, port);
    defer _ = std.posix.system.close(fd);

    var chan = try noise.clientHandshake(allocator, fd, local_static, peer);
    try chan.sendFrame(allocator, fd, request);
    const resp = try chan.recvFrame(allocator, fd, MAX_RESPONSE);
    defer allocator.free(resp);

    _ = std.posix.system.write(1, resp.ptr, resp.len);
    _ = std.posix.system.write(1, "\n", 1);
}

fn keygen(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const kp = try noise.generateKeyPair();
    const secret_path = try std.fmt.allocPrint(allocator, "{s}.noise-secret", .{prefix});
    defer allocator.free(secret_path);
    const public_path = try std.fmt.allocPrint(allocator, "{s}.noise-public", .{prefix});
    defer allocator.free(public_path);

    try noise.writeKeyFile(secret_path, kp.secret_key);
    try noise.writeKeyFile(public_path, kp.public_key);

    var pub_hex: [64]u8 = undefined;
    std.debug.print(
        "wrote {s}\nwrote {s}\npublic {s}\n",
        .{ secret_path, public_path, noise.encodeKeyHex(&pub_hex, kp.public_key) },
    );
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
