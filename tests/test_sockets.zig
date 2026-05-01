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
    try std.testing.expectError(error.UserSignal, result);
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

test "connect refusal surfaces a Smalltalk Exception with messageText" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // [Socket connectTo: '127.0.0.1' port: 1] on: Exception do: [:e | e messageText]
    const got = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\    {"literal":{"string":"127.0.0.1"}},{"literal":{"int":1}}
        \\  ]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"e"},"selector":"messageText","args":[]}}
        \\  ]}}
        \\]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    const bytes = vm.object.bytesOf(got)[0..vm.object.headerOf(got).size];
    try std.testing.expect(std.mem.startsWith(u8, bytes, "connect:"));
}

test "connectTo:port:timeout: bounds the wait on a black hole" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // 198.51.100.1 is in TEST-NET-2 (RFC 5737). Different
    // environments respond differently: some return ECONNREFUSED
    // / EHOSTUNREACH within a few ms, others let the SYN sit
    // unanswered until our timeout fires. Both outcomes prove
    // the timeout machinery works — the meaningful invariant is
    // "we get a Smalltalk Exception promptly", not a specific
    // messageText. We allow up to 2 s of slack for slow CI
    // network paths; pre-fix this would have hung for ~75 s.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"CtT0"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Time"},"selector":"monotonicNanos","args":[]}}
        \\]}}
    );
    const got = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":[],"body":[
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:timeout:","args":[
        \\    {"literal":{"string":"198.51.100.1"}},{"literal":{"int":80}},{"literal":{"int":200}}
        \\  ]}}
        \\]}},"selector":"on:do:","args":[
        \\  {"var_ref":"Exception"},
        \\  {"block":{"params":["e"],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"e"},"selector":"messageText","args":[]}}
        \\  ]}}
        \\]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    const bytes = vm.object.bytesOf(got)[0..vm.object.headerOf(got).size];
    try std.testing.expect(std.mem.startsWith(u8, bytes, "connect:"));

    const elapsed_oop = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"Time"},"selector":"monotonicNanos","args":[]}},
        \\  "selector":"-","args":[{"var_ref":"CtT0"}]}}
    );
    const elapsed_ns = vm.oop.toInt(elapsed_oop);
    try std.testing.expect(elapsed_ns < 2_000_000_000);
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
    try std.testing.expectError(error.UserSignal, result);
}
