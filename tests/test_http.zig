// HttpClient end-to-end test. Spin up a tiny HTTP/1.0 server
// in a forked process, hit it from the main process via
// HttpClient class>>get:, and assert the parsed response.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "URL parser splits scheme://host[:port]/path correctly" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // 'http://example.com:8080/foo/bar' parseUrl
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"P1"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"HttpClient"},"selector":"parseUrl:","args":[{"literal":{"string":"http://example.com:8080/foo/bar"}}]}}
        \\]}}
    );
    const host = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"P1"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"host"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqualStrings("example.com", vm.object.bytesOf(host)[0..vm.object.headerOf(host).size]);
    const port = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"P1"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"port"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqual(@as(i64, 8080), vm.oop.toInt(port));
    const path = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"P1"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"path"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqualStrings("/foo/bar", vm.object.bytesOf(path)[0..vm.object.headerOf(path).size]);

    // No port → defaults to 80; no path → '/'.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"P2"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"HttpClient"},"selector":"parseUrl:","args":[{"literal":{"string":"http://example.com"}}]}}
        \\]}}
    );
    const port2 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"P2"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"port"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqual(@as(i64, 80), vm.oop.toInt(port2));
    const path2 = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"P2"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"path"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqualStrings("/", vm.object.bytesOf(path2)[0..vm.object.headerOf(path2).size]);
}

test "parseResponse: pulls status code, headers, body" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Synthesize a minimal HTTP/1.0 response and parse it.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"R"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"HttpClient"},"selector":"parseResponse:","args":[
        \\    {"literal":{"string":"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nX-Note: hi\r\n\r\nhello body"}}
        \\  ]}}
        \\]}}
    );
    const code = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"R"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"statusCode"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqual(@as(i64, 200), vm.oop.toInt(code));
    const body = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"R"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"body"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqualStrings("hello body", vm.object.bytesOf(body)[0..vm.object.headerOf(body).size]);
    // Header keys are lower-cased.
    const ct = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"R"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"headers"}},"selector":"asSymbol","args":[]}}]}},
        \\  "selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"content-type"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqualStrings("text/plain", vm.object.bytesOf(ct)[0..vm.object.headerOf(ct).size]);
}

// Tiny HTTP/1.0 server running on a real OS thread. Cooperative
// green threads can't double as a server here — they share the
// single host thread and any blocking syscall (accept / read)
// freezes the client running in parallel. Spawning an OS thread
// dodges that until non-blocking I/O lands.
fn httpMockServer(port: u16, ready: *std.atomic.Value(bool)) void {
    const server_fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (server_fd < 0) return;
    defer _ = std.posix.system.close(server_fd);

    const reuse: c_int = 1;
    _ = std.posix.system.setsockopt(server_fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &reuse, @sizeOf(c_int));
    var sa: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    };
    const sa_ptr: *const std.posix.sockaddr = @ptrCast(&sa);
    if (std.posix.system.bind(server_fd, sa_ptr, @sizeOf(@TypeOf(sa))) != 0) return;
    if (std.posix.system.listen(server_fd, 4) != 0) return;
    ready.store(true, .release);

    const client_fd = std.posix.system.accept(server_fd, null, null);
    if (client_fd < 0) return;
    defer _ = std.posix.system.close(client_fd);

    // Drain the request — we don't actually care what the client
    // sent; canned reply.
    var dump: [4096]u8 = undefined;
    _ = std.posix.read(client_fd, &dump) catch {};

    const reply = "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world";
    _ = std.posix.system.write(client_fd, reply.ptr, reply.len);
}

test "HttpClient>>get end-to-end against a real-thread mock server" {
    // Cooperative scheduler can't run a green-thread server while
    // the client is blocked in readAll, so the server lives on a
    // dedicated OS thread.
    var ready = std.atomic.Value(bool).init(false);
    const port: u16 = 47921;
    const thread = try std.Thread.spawn(.{}, httpMockServer, .{ port, &ready });
    defer thread.join();

    // Spin until the listener is bound to avoid a connect race.
    while (!ready.load(.acquire)) std.Thread.yield() catch {};

    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Resp"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"HttpClient"},"selector":"get:","args":[{"literal":{"string":"http://localhost:47921/hi"}}]}}
        \\]}}
    );

    const code = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Resp"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"statusCode"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqual(@as(i64, 200), vm.oop.toInt(code));
    const body = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Resp"},"selector":"at:","args":[{"send":{"receiver":{"literal":{"string":"body"}},"selector":"asSymbol","args":[]}}]}}
    );
    try std.testing.expectEqualStrings("hello world", vm.object.bytesOf(body)[0..vm.object.headerOf(body).size]);
}
