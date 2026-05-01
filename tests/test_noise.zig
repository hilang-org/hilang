const std = @import("std");
const noise = @import("noise");

test "Noise XX handshake and encrypted frame round-trip over socketpair" {
    const client_static = try noise.KeyPair.generateDeterministic([_]u8{0x11} ** 32);
    const server_static = try noise.KeyPair.generateDeterministic([_]u8{0x22} ** 32);

    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) {
        return error.SocketFailed;
    }

    const Ctx = struct {
        fd: std.posix.fd_t,
        server_static: noise.KeyPair,
        allowed: [1]noise.PublicKey,
        err: ?anyerror = null,
        remote: ?noise.PublicKey = null,
    };

    var ctx = Ctx{
        .fd = fds[1],
        .server_static = server_static,
        .allowed = .{client_static.public_key},
    };

    const worker = struct {
        fn run(inner: *Ctx) void {
            runInner(inner) catch |err| {
                inner.err = err;
            };
        }

        fn runInner(inner: *Ctx) !void {
            defer _ = std.posix.system.close(inner.fd);
            var chan = try noise.serverHandshake(std.testing.allocator, inner.fd, inner.server_static, inner.allowed[0..]);
            inner.remote = chan.remote_static;
            const req = try chan.recvFrame(std.testing.allocator, inner.fd, 4096);
            defer std.testing.allocator.free(req);
            try std.testing.expectEqualStrings("ping", req);
            try chan.sendFrame(std.testing.allocator, inner.fd, "pong");
        }
    };

    const thread = try std.Thread.spawn(.{}, worker.run, .{&ctx});
    var client_err: ?anyerror = null;
    const maybe_chan: ?noise.Channel = noise.clientHandshake(std.testing.allocator, fds[0], client_static, server_static.public_key) catch |err| blk: {
            client_err = err;
            break :blk null;
        };
    if (maybe_chan) |chan_ok| {
        var chan = chan_ok;
        try std.testing.expectEqualDeep(server_static.public_key, chan.remote_static);
        try chan.sendFrame(std.testing.allocator, fds[0], "ping");
        const resp = try chan.recvFrame(std.testing.allocator, fds[0], 4096);
        defer std.testing.allocator.free(resp);
        try std.testing.expectEqualStrings("pong", resp);
    }
    _ = std.posix.system.close(fds[0]);
    thread.join();

    if (client_err) |err| return err;
    if (ctx.err) |err| return err;
    try std.testing.expect(ctx.remote != null);
    try std.testing.expectEqualDeep(client_static.public_key, ctx.remote.?);
}

test "Noise key hex encode/decode round-trip" {
    const kp = try noise.KeyPair.generateDeterministic([_]u8{0x33} ** 32);
    var buf: [64]u8 = undefined;
    const hex = noise.encodeKeyHex(&buf, kp.public_key);
    const parsed = try noise.decodeKeyHex(hex);
    try std.testing.expectEqualDeep(kp.public_key, parsed);
}
