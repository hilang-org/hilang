// Non-blocking socket I/O round-trip — server and client both
// run as green threads inside a single hilang VM, with the
// scheduler kqueue-park'ing whichever side is waiting on read
// or write. Pre-fix this would deadlock because accept/read on
// blocking sockets froze the whole host thread.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

test "Socket server and client both run as green threads" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"NbLog"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"var_ref":"OrderedCollection"},"selector":"new","args":[]}},"selector":"init","args":[]}}
        \\]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"NbServer"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"Socket"},"selector":"listenOn:","args":[{"literal":{"int":47931}}]}}
        \\]}}
    );

    // Server worker: accept (blocks via kqueue), read request,
    // write canned response, close.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":["c","req"],"body":[
        \\  {"assign":{"name":"c","value":{"send":{"receiver":{"var_ref":"NbServer"},"selector":"accept","args":[]}}}},
        \\  {"assign":{"name":"req","value":{"send":{"receiver":{"var_ref":"c"},"selector":"read:","args":[{"literal":{"int":4096}}]}}}},
        \\  {"send":{"receiver":{"var_ref":"NbLog"},"selector":"addLast:","args":[{"var_ref":"req"}]}},
        \\  {"send":{"receiver":{"var_ref":"c"},"selector":"nextPutAll:","args":[{"literal":{"string":"pong"}}]}},
        \\  {"send":{"receiver":{"var_ref":"c"},"selector":"close","args":[]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Client worker: connect, send a request, read the reply,
    // log it, close.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"block":{"params":[],"temps":["s","reply"],"body":[
        \\  {"assign":{"name":"s","value":{"send":{"receiver":{"var_ref":"Socket"},"selector":"connectTo:port:","args":[
        \\    {"literal":{"string":"127.0.0.1"}},{"literal":{"int":47931}}
        \\  ]}}}},
        \\  {"send":{"receiver":{"var_ref":"s"},"selector":"nextPutAll:","args":[{"literal":{"string":"ping"}}]}},
        \\  {"assign":{"name":"reply","value":{"send":{"receiver":{"var_ref":"s"},"selector":"read:","args":[{"literal":{"int":256}}]}}}},
        \\  {"send":{"receiver":{"var_ref":"NbLog"},"selector":"addLast:","args":[{"var_ref":"reply"}]}},
        \\  {"send":{"receiver":{"var_ref":"s"},"selector":"close","args":[]}}
        \\]}},"selector":"fork","args":[]}}
    );

    // Drive the schedule. Each yield gives the kqueue-poll a
    // chance to wake whichever side is unblocked. Plenty of
    // yields for safety; surplus is harmless.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        _ = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"Processor"},"selector":"yield","args":[]}}
        );
    }

    const sz = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"NbLog"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 2), vm.oop.toInt(sz));
    // Order is implementation-defined but both pieces must show up.
    const a = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"NbLog"},"selector":"at:","args":[{"literal":{"int":1}}]}}
    );
    const b = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"NbLog"},"selector":"at:","args":[{"literal":{"int":2}}]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(a));
    try std.testing.expect(vm.oop.isHeapPtr(b));
    const a_bytes = vm.object.bytesOf(a)[0..vm.object.headerOf(a).size];
    const b_bytes = vm.object.bytesOf(b)[0..vm.object.headerOf(b).size];
    const saw_ping = std.mem.eql(u8, a_bytes, "ping") or std.mem.eql(u8, b_bytes, "ping");
    const saw_pong = std.mem.eql(u8, a_bytes, "pong") or std.mem.eql(u8, b_bytes, "pong");
    try std.testing.expect(saw_ping);
    try std.testing.expect(saw_pong);

    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"NbServer"},"selector":"close","args":[]}}
    );
}
