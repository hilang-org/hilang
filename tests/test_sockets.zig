// TCP/IPv4 socket round-trip via the cooperative scheduler.
// Server forks a worker that does `accept`; main does the
// connect+write while the worker is parked. Loopback only;
// hostname resolution is intentionally out of scope for the
// first commit.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "Socket loopback round-trip: connect, write, accept, read" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Stash a log so the worker can record what it received.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"SockLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    // Listener up-front so connect() always finds a backlog slot.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Server"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"listenOn:","args":[{"literal":{"int":47917}}]}}
        \\]}}
    );

    // Worker block: accept, read, log, close. Forks idle until
    // main yields after queuing a connect+write.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":["c","m"],"body":[
        \\  {"assign":{"name":"c","value":{"send":{"receiver":{"var_ref":"Server"},"selector":"accept","args":[]}}}},
        \\  {"assign":{"name":"m","value":{"send":{"receiver":{"var_ref":"c"},"selector":"readAll","args":[]}}}},
        \\  {"send":{"receiver":{"var_ref":"SockLog"},"selector":"addLast:","args":[{"var_ref":"m"}]}},
        \\  {"send":{"receiver":{"var_ref":"c"},"selector":"close","args":[]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Main connects, writes, closes. The 3-way handshake on
    // loopback completes against the listener's kernel backlog
    // even before the worker calls accept(); when we yield,
    // the worker's accept() returns immediately.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"Cli"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\    {"literal":{"string":"127.0.0.1"}},{"literal":{"int":47917}}
        \\  ]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Cli"},"selector":"nextPutAll:","args":[{"literal":{"string":"hello world"}}]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Cli"},"selector":"close","args":[]}}
    );

    // Yield to let the worker accept + read. readAll blocks until
    // the peer closes; main's close above is what releases it.
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Processor\"},\"selector\":\"yield\",\"args\":[]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"Processor\"},\"selector\":\"yield\",\"args\":[]}}");

    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SockLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 1), vm.oop.toInt(sz));
    const msg = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"SockLog"},"selector":"first","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(msg));
    try std.testing.expectEqualStrings(
        "hello world",
        vm.object.bytesOf(msg)[0..vm.object.headerOf(msg).size],
    );

    // Cleanup the listener.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Server"},"selector":"close","args":[]}}
    );
}

test "connect to a closed port raises PrimitiveFailed" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Port 1 on loopback is reserved; nothing listens. Kernel
    // refuses with ECONNREFUSED → connect() returns -1 → prim
    // surfaces PrimitiveFailed.
    const result = env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\  {"literal":{"string":"127.0.0.1"}},{"literal":{"int":1}}
        \\]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}

test "DNS hostname resolves through getaddrinfo" {
    // 'localhost' should resolve to 127.0.0.1 (or ::1) and connect
    // to the listener established below. Proves getaddrinfo is
    // wired and the result list is walked.
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DnsServer"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"listenOn:","args":[{"literal":{"int":47918}}]}}
        \\]}}
    );
    // Connect via hostname rather than literal IP.
    const cli = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\  {"literal":{"string":"localhost"}},{"literal":{"int":47918}}
        \\]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(cli));
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"DnsCli"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\    {"literal":{"string":"localhost"}},{"literal":{"int":47918}}
        \\  ]}}
        \\]}}
    );
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"DnsCli\"},\"selector\":\"close\",\"args\":[]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"DnsServer\"},\"selector\":\"close\",\"args\":[]}}");
}

test "garbage hostname still raises PrimitiveFailed" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\  {"literal":{"string":"this.is.not.a.real.tld.zzz.invalid"}},{"literal":{"int":80}}
        \\]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}
