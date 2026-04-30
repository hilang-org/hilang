// FileStream tests. Each test uses a per-test path under /tmp,
// deleting the file before and after to keep runs idempotent.

const std = @import("std");
const vm = @import("vm");
const harness = @import("harness.zig");
const TestEnv = harness.TestEnv;

fn rmIgnore(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    _ = std.posix.system.unlink(path_z);
}

test "FileStream roundtrip: write then read" {
    const path = "/tmp/hilang_test_io_roundtrip";
    rmIgnore(path);
    defer rmIgnore(path);

    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // (FileStream write: path) nextPutAll: 'hello world'; close.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"FileStream"},
        \\  "selector":"write:","args":[{"literal":{"string":"/tmp/hilang_test_io_roundtrip"}}]}},
        \\  "selector":"nextPutAll:","args":[{"literal":{"string":"hello world"}}]}},
        \\  "selector":"close","args":[]}}
    );

    // ((FileStream read: path) readAll) — close after.
    const got = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"FileStream"},
        \\  "selector":"read:","args":[{"literal":{"string":"/tmp/hilang_test_io_roundtrip"}}]}},
        \\  "selector":"readAll","args":[]}}
    );
    try std.testing.expect(vm.oop.isHeapPtr(got));
    try std.testing.expectEqualStrings(
        "hello world",
        vm.object.bytesOf(got)[0..vm.object.headerOf(got).size],
    );
}

test "FileStream append mode concatenates content" {
    const path = "/tmp/hilang_test_io_append";
    rmIgnore(path);
    defer rmIgnore(path);

    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    _ = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"FileStream"},
        \\  "selector":"write:","args":[{"literal":{"string":"/tmp/hilang_test_io_append"}}]}},
        \\  "selector":"nextPutAll:","args":[{"literal":{"string":"foo"}}]}},
        \\  "selector":"close","args":[]}}
    );
    _ = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"FileStream"},
        \\  "selector":"append:","args":[{"literal":{"string":"/tmp/hilang_test_io_append"}}]}},
        \\  "selector":"nextPutAll:","args":[{"literal":{"string":"bar"}}]}},
        \\  "selector":"close","args":[]}}
    );

    const got = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"var_ref":"FileStream"},
        \\  "selector":"read:","args":[{"literal":{"string":"/tmp/hilang_test_io_append"}}]}},
        \\  "selector":"contents","args":[]}}
    );
    try std.testing.expectEqualStrings(
        "foobar",
        vm.object.bytesOf(got)[0..vm.object.headerOf(got).size],
    );
}

test "FileStream read: returns chunks until EOF" {
    const path = "/tmp/hilang_test_io_chunks";
    rmIgnore(path);
    defer rmIgnore(path);

    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Write a 10 KB string of 'x'. Build via a 3-deep concat tree
    // so we don't have to embed 10 000 bytes in a literal.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IoBig"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"WriteStream"},
        \\    "selector":"new","args":[]}},"selector":"setContents:","args":[{"literal":{"string":""}}]}},
        \\    "selector":"contents","args":[]}}
        \\]}}
    );
    // Append 10000 'x's via 100 iterations of 100 chars each. Keep
    // the JSON tractable by literalising a 100-char chunk.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"literal":{"int":100}},"selector":"timesRepeat:","args":[
        \\  {"block":{"params":[],"temps":[],"body":[
        \\    {"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\      {"send":{"receiver":{"literal":{"string":"IoBig"}},"selector":"asSymbol","args":[]}},
        \\      {"send":{"receiver":{"var_ref":"IoBig"},"selector":",","args":[
        \\        {"literal":{"string":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}
        \\      ]}}
        \\    ]}}
        \\  ]}}
        \\]}}
    );

    const written = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IoBig"},"selector":"size","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 10_000), vm.oop.toInt(written));

    // Write to file.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"send":{"receiver":{"send":{"receiver":{"var_ref":"FileStream"},
        \\  "selector":"write:","args":[{"literal":{"string":"/tmp/hilang_test_io_chunks"}}]}},
        \\  "selector":"nextPutAll:","args":[{"var_ref":"IoBig"}]}},
        \\  "selector":"close","args":[]}}
    );

    // Read in 1024-byte chunks until EOF, accumulating sizes.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IoFs"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"FileStream"},"selector":"read:","args":[{"literal":{"string":"/tmp/hilang_test_io_chunks"}}]}}
        \\]}}
    );

    var total: i64 = 0;
    while (true) {
        const chunk = try env.evalJson(
            \\{"send":{"receiver":{"var_ref":"IoFs"},"selector":"read:","args":[{"literal":{"int":1024}}]}}
        );
        try std.testing.expect(vm.oop.isHeapPtr(chunk));
        const n: i64 = @intCast(vm.object.headerOf(chunk).size);
        if (n == 0) break;
        total += n;
    }
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IoFs"},"selector":"close","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, 10_000), total);
}

test "FileStream open of nonexistent file fails" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const result = env.evalJson(
        \\{"send":{"receiver":{"var_ref":"FileStream"},"selector":"read:","args":[
        \\  {"literal":{"string":"/tmp/hilang_test_io_definitely_not_here_98765"}}
        \\]}}
    );
    try std.testing.expectError(error.PrimitiveFailed, result);
}

test "FileStream close is idempotent" {
    const path = "/tmp/hilang_test_io_close";
    rmIgnore(path);
    defer rmIgnore(path);

    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // Stash the FileStream so we can close it twice.
    _ = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"Smalltalk"},"selector":"at:put:","args":[
        \\  {"send":{"receiver":{"literal":{"string":"IoFc"}},"selector":"asSymbol","args":[]}},
        \\  {"send":{"receiver":{"var_ref":"FileStream"},"selector":"write:","args":[{"literal":{"string":"/tmp/hilang_test_io_close"}}]}}
        \\]}}
    );
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"IoFc\"},\"selector\":\"close\",\"args\":[]}}");
    _ = try env.evalJson("{\"send\":{\"receiver\":{\"var_ref\":\"IoFc\"},\"selector\":\"close\",\"args\":[]}}");

    // After two closes, fd is -1.
    const fd = try env.evalJson(
        \\{"send":{"receiver":{"var_ref":"IoFc"},"selector":"fd","args":[]}}
    );
    try std.testing.expectEqual(@as(i64, -1), vm.oop.toInt(fd));
}
