const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const dict = @import("dict.zig");
const heap_mod = @import("heap.zig");
const globals_mod = @import("globals.zig");

const Heap = heap_mod.Heap;
const Globals = globals_mod.Globals;
const Oop = oop_mod.Oop;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidSymbol,
    MissingField,
    BadFieldType,
    IntOverflow,
    UnsupportedLiteral,
    UnsupportedMethod,
    OutOfMemory,
};

pub const Literal = union(enum) {
    nil,
    true_lit,
    false_lit,
    int: i64,
    float: f64,
    string: []const u8,
    symbol: []const u8,
};

pub const Node = union(enum) {
    literal: Literal,
    var_ref: []const u8,
    assign: struct {
        name: []const u8,
        value: *Node,
    },
    send: struct {
        receiver: *Node,
        selector: []const u8,
        args: []const *Node,
    },
    super_send: struct {
        selector: []const u8,
        args: []const *Node,
    },
    block: struct {
        params: []const []const u8,
        temps: []const []const u8,
        body: []const *Node,
    },
    seq: []const *Node,
    ret: *Node,
};

pub const Method = struct {
    selector: []const u8,
    params: []const []const u8,
    temps: []const []const u8,
    body: []const *Node,
};

pub const LoweredMethod = struct {
    selector: []const u8,
    arg_count: u32,
    params_arr: Oop,
    temps_arr: Oop,
    body_arr: Oop,
};

const TokenKind = enum {
    eof,
    identifier,
    keyword,
    binary,
    int_lit,
    float_lit,
    string_lit,
    hash,
    assign,
    return_op,
    lparen,
    rparen,
    lbracket,
    rbracket,
    period,
    colon,
    bar,
};

const Token = struct {
    kind: TokenKind,
    lexeme: []const u8 = "",
    int_value: i64 = 0,
    float_value: f64 = 0,
    string_value: []const u8 = "",
};

pub fn parseTopLevel(allocator: std.mem.Allocator, source: []const u8) ParseError!*Node {
    var parser = try Parser.init(allocator, source);
    return parser.parseTopLevel();
}

pub fn parseMethod(allocator: std.mem.Allocator, source: []const u8) ParseError!Method {
    var parser = try Parser.init(allocator, source);
    return parser.parseMethod();
}

pub fn parseTopLevelToJson(allocator: std.mem.Allocator, source: []const u8) anyerror![]u8 {
    const node = try parseTopLevel(allocator, source);
    return renderTopLevelJson(allocator, node);
}

pub fn parseMethodToJson(allocator: std.mem.Allocator, source: []const u8) anyerror![]u8 {
    const method = try parseMethod(allocator, source);
    return renderMethodJson(allocator, method);
}

pub fn renderTopLevelSource(allocator: std.mem.Allocator, node: *const Node) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (node.* == .seq) {
        try appendStatements(allocator, &out, node.seq, 0);
    } else {
        try appendStatement(allocator, &out, node, 0);
    }
    return out.toOwnedSlice(allocator);
}

pub fn renderMethodSource(allocator: std.mem.Allocator, method: Method) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendMethod(allocator, &out, method);
    return out.toOwnedSlice(allocator);
}

pub fn renderTopLevelJson(allocator: std.mem.Allocator, node: *const Node) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendNodeJson(allocator, &out, node);
    return out.toOwnedSlice(allocator);
}

pub fn renderMethodJson(allocator: std.mem.Allocator, method: Method) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendMethodJson(allocator, &out, method);
    return out.toOwnedSlice(allocator);
}

pub fn nodeFromJson(allocator: std.mem.Allocator, json_text: []const u8) ParseError!*Node {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return error.BadFieldType;
    defer parsed.deinit();
    return nodeFromJsonValue(allocator, parsed.value);
}

pub fn methodFromJson(allocator: std.mem.Allocator, json_text: []const u8) ParseError!Method {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return error.BadFieldType;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadFieldType;
    return methodFromJsonObject(allocator, parsed.value.object);
}

pub fn nodeFromJsonValue(allocator: std.mem.Allocator, v: std.json.Value) ParseError!*Node {
    if (v != .object) return error.BadFieldType;
    const obj = v.object;
    if (obj.count() != 1) return error.BadFieldType;
    var it = obj.iterator();
    const entry = it.next() orelse return error.BadFieldType;
    const kind = entry.key_ptr.*;
    const payload = entry.value_ptr.*;

    if (std.mem.eql(u8, kind, "literal")) {
        return newNode(allocator, .{ .literal = try literalFromJsonValue(payload) });
    }
    if (std.mem.eql(u8, kind, "var_ref")) {
        if (payload != .string) return error.BadFieldType;
        return newNode(allocator, .{ .var_ref = payload.string });
    }
    if (std.mem.eql(u8, kind, "assign")) {
        if (payload != .object) return error.BadFieldType;
        const name_v = payload.object.get("name") orelse return error.MissingField;
        const value_v = payload.object.get("value") orelse return error.MissingField;
        if (name_v != .string) return error.BadFieldType;
        return newNode(allocator, .{
            .assign = .{
                .name = name_v.string,
                .value = try nodeFromJsonValue(allocator, value_v),
            },
        });
    }
    if (std.mem.eql(u8, kind, "send")) {
        if (payload != .object) return error.BadFieldType;
        const recv_v = payload.object.get("receiver") orelse return error.MissingField;
        const sel_v = payload.object.get("selector") orelse return error.MissingField;
        const args_v = payload.object.get("args") orelse return error.MissingField;
        if (sel_v != .string or args_v != .array) return error.BadFieldType;
        return newNode(allocator, .{
            .send = .{
                .receiver = try nodeFromJsonValue(allocator, recv_v),
                .selector = sel_v.string,
                .args = try nodeSliceFromJsonArray(allocator, args_v.array.items),
            },
        });
    }
    if (std.mem.eql(u8, kind, "super_send")) {
        if (payload != .object) return error.BadFieldType;
        const sel_v = payload.object.get("selector") orelse return error.MissingField;
        const args_v = payload.object.get("args") orelse return error.MissingField;
        if (sel_v != .string or args_v != .array) return error.BadFieldType;
        return newNode(allocator, .{
            .super_send = .{
                .selector = sel_v.string,
                .args = try nodeSliceFromJsonArray(allocator, args_v.array.items),
            },
        });
    }
    if (std.mem.eql(u8, kind, "block")) {
        if (payload != .object) return error.BadFieldType;
        const params_v = payload.object.get("params") orelse return error.MissingField;
        const temps_v = payload.object.get("temps") orelse return error.MissingField;
        const body_v = payload.object.get("body") orelse return error.MissingField;
        if (params_v != .array or temps_v != .array or body_v != .array) return error.BadFieldType;
        return newNode(allocator, .{
            .block = .{
                .params = try stringSliceFromJsonArray(allocator, params_v.array.items),
                .temps = try stringSliceFromJsonArray(allocator, temps_v.array.items),
                .body = try nodeSliceFromJsonArray(allocator, body_v.array.items),
            },
        });
    }
    if (std.mem.eql(u8, kind, "seq")) {
        if (payload != .array) return error.BadFieldType;
        return newNode(allocator, .{ .seq = try nodeSliceFromJsonArray(allocator, payload.array.items) });
    }
    if (std.mem.eql(u8, kind, "ret")) {
        return newNode(allocator, .{ .ret = try nodeFromJsonValue(allocator, payload) });
    }
    return error.BadFieldType;
}

pub fn methodFromJsonObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Method {
    const selector_v = obj.get("selector") orelse return error.MissingField;
    const params_v = obj.get("params") orelse return error.MissingField;
    const temps_v = obj.get("temps") orelse return error.MissingField;
    const body_v = obj.get("body") orelse return error.MissingField;
    if (selector_v != .string or params_v != .array or temps_v != .array or body_v != .array) return error.BadFieldType;
    return .{
        .selector = selector_v.string,
        .params = try stringSliceFromJsonArray(allocator, params_v.array.items),
        .temps = try stringSliceFromJsonArray(allocator, temps_v.array.items),
        .body = try nodeSliceFromJsonArray(allocator, body_v.array.items),
    };
}

pub fn renderTopLevelSourceFromJson(allocator: std.mem.Allocator, json_text: []const u8) anyerror![]u8 {
    const node = try nodeFromJson(allocator, json_text);
    return renderTopLevelSource(allocator, node);
}

pub fn renderMethodSourceFromJson(allocator: std.mem.Allocator, json_text: []const u8) anyerror![]u8 {
    const method = try methodFromJson(allocator, json_text);
    return renderMethodSource(allocator, method);
}

pub fn lowerTopLevelToHeap(heap: *Heap, g: *const Globals, node: *const Node) ParseError!Oop {
    return lowerNodeToHeap(heap, g, node);
}

pub fn lowerMethodToHeap(heap: *Heap, g: *const Globals, method: Method) ParseError!LoweredMethod {
    return .{
        .selector = method.selector,
        .arg_count = @intCast(method.params.len),
        .params_arr = try lowerSymbolArray(heap, g, method.params),
        .temps_arr = try lowerSymbolArray(heap, g, method.temps),
        .body_arr = try lowerBodyArray(heap, g, method.body),
    };
}

pub fn parseTopLevelToHeap(heap: *Heap, g: *const Globals, allocator: std.mem.Allocator, source: []const u8) ParseError!Oop {
    const node = try parseTopLevel(allocator, source);
    return lowerTopLevelToHeap(heap, g, node);
}

pub fn parseMethodToHeap(heap: *Heap, g: *const Globals, allocator: std.mem.Allocator, source: []const u8) ParseError!LoweredMethod {
    const method = try parseMethod(allocator, source);
    return lowerMethodToHeap(heap, g, method);
}

pub fn renderMethodSourceFromHeap(allocator: std.mem.Allocator, g: *const Globals, method_oop: Oop) anyerror![]u8 {
    const method = try liftMethodFromHeap(allocator, g, method_oop);
    return renderMethodSource(allocator, method);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    idx: usize = 0,

    fn init(allocator: std.mem.Allocator, source: []const u8) ParseError!Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = try tokenize(allocator, source),
        };
    }

    fn parseTopLevel(self: *Parser) ParseError!*Node {
        const body = try self.parseStatements(.eof, false);
        try self.expect(.eof);
        if (body.len == 0) return newNode(self.allocator, .{ .literal = .nil });
        if (body.len == 1) return body[0];
        return newNode(self.allocator, .{ .seq = body });
    }

    fn parseMethod(self: *Parser) ParseError!Method {
        const header = try self.parseMethodHeader();
        const temps = try self.parseOptionalTemps();
        const body = try self.parseStatements(.eof, true);
        try self.expect(.eof);
        return .{
            .selector = header.selector,
            .params = header.params,
            .temps = temps,
            .body = body,
        };
    }

    fn parseMethodHeader(self: *Parser) ParseError!struct { selector: []const u8, params: []const []const u8 } {
        if (self.current().kind == .identifier) {
            const selector = self.advance().lexeme;
            return .{ .selector = selector, .params = &.{} };
        }
        if (isBinarySelectorToken(self.current())) {
            const selector = self.advance().lexeme;
            const arg = try self.expectIdentifier();
            const params = try self.allocator.alloc([]const u8, 1);
            params[0] = arg.lexeme;
            return .{ .selector = selector, .params = params };
        }
        if (self.current().kind == .keyword) {
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(self.allocator);
            var params_list: std.ArrayList([]const u8) = .empty;
            defer params_list.deinit(self.allocator);
            while (self.current().kind == .keyword) {
                const part = self.advance();
                try parts.append(self.allocator, part.lexeme);
                const arg = try self.expectIdentifier();
                try params_list.append(self.allocator, arg.lexeme);
            }
            return .{
                .selector = try concatSlices(self.allocator, parts.items),
                .params = try params_list.toOwnedSlice(self.allocator),
            };
        }
        return error.UnexpectedToken;
    }

    fn parseOptionalTemps(self: *Parser) ParseError![]const []const u8 {
        if (self.current().kind != .bar) return &.{};
        _ = self.advance();
        var temps: std.ArrayList([]const u8) = .empty;
        defer temps.deinit(self.allocator);
        while (self.current().kind != .bar) {
            const tok = try self.expectIdentifier();
            try temps.append(self.allocator, tok.lexeme);
        }
        _ = self.advance();
        return temps.toOwnedSlice(self.allocator);
    }

    fn parseStatements(self: *Parser, end_kind: TokenKind, allow_temps: bool) ParseError![]const *Node {
        _ = allow_temps;
        var stmts: std.ArrayList(*Node) = .empty;
        defer stmts.deinit(self.allocator);
        while (self.current().kind != end_kind and self.current().kind != .eof) {
            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);
            if (self.current().kind == .period) {
                _ = self.advance();
                if (self.current().kind == end_kind or self.current().kind == .eof) break;
                continue;
            }
            break;
        }
        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser) ParseError!*Node {
        if (self.current().kind == .return_op) {
            _ = self.advance();
            return newNode(self.allocator, .{ .ret = try self.parseAssignment() });
        }
        return self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) ParseError!*Node {
        if (self.current().kind == .identifier and self.peek(1).kind == .assign) {
            const name = self.advance().lexeme;
            _ = self.advance();
            return newNode(self.allocator, .{
                .assign = .{
                    .name = name,
                    .value = try self.parseAssignment(),
                },
            });
        }
        return self.parseKeywordExpr();
    }

    fn parseKeywordExpr(self: *Parser) ParseError!*Node {
        var receiver = try self.parseBinaryExpr();
        if (self.current().kind != .keyword) return receiver;

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        var args: std.ArrayList(*Node) = .empty;
        defer args.deinit(self.allocator);

        while (self.current().kind == .keyword) {
            const part = self.advance();
            try parts.append(self.allocator, part.lexeme);
            try args.append(self.allocator, try self.parseBinaryExpr());
        }
        receiver = try makeSend(self.allocator, receiver, try concatSlices(self.allocator, parts.items), try args.toOwnedSlice(self.allocator));
        return receiver;
    }

    fn parseBinaryExpr(self: *Parser) ParseError!*Node {
        var receiver = try self.parseUnaryExpr();
        while (isBinarySelectorToken(self.current())) {
            const sel_tok = self.advance();
            const arg = try self.parseUnaryExpr();
            const selector = if (sel_tok.kind == .bar) "|" else sel_tok.lexeme;
            const args = try self.allocator.alloc(*Node, 1);
            args[0] = arg;
            receiver = try makeSend(self.allocator, receiver, selector, args);
        }
        return receiver;
    }

    fn parseUnaryExpr(self: *Parser) ParseError!*Node {
        var receiver = try self.parsePrimary();
        while (self.current().kind == .identifier) {
            const selector = self.advance().lexeme;
            receiver = try makeSend(self.allocator, receiver, selector, &.{});
        }
        return receiver;
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        const tok = self.current();
        switch (tok.kind) {
            .identifier => {
                _ = self.advance();
                if (std.mem.eql(u8, tok.lexeme, "nil")) return newNode(self.allocator, .{ .literal = .nil });
                if (std.mem.eql(u8, tok.lexeme, "true")) return newNode(self.allocator, .{ .literal = .true_lit });
                if (std.mem.eql(u8, tok.lexeme, "false")) return newNode(self.allocator, .{ .literal = .false_lit });
                return newNode(self.allocator, .{ .var_ref = tok.lexeme });
            },
            .int_lit => {
                _ = self.advance();
                return newNode(self.allocator, .{ .literal = .{ .int = tok.int_value } });
            },
            .float_lit => {
                _ = self.advance();
                return newNode(self.allocator, .{ .literal = .{ .float = tok.float_value } });
            },
            .string_lit => {
                _ = self.advance();
                return newNode(self.allocator, .{ .literal = .{ .string = tok.string_value } });
            },
            .hash => return self.parseSymbolLiteral(),
            .binary => {
                if (std.mem.eql(u8, tok.lexeme, "-") and (self.peek(1).kind == .int_lit or self.peek(1).kind == .float_lit)) {
                    _ = self.advance();
                    const inner = self.advance();
                    return switch (inner.kind) {
                        .int_lit => newNode(self.allocator, .{ .literal = .{ .int = -inner.int_value } }),
                        .float_lit => newNode(self.allocator, .{ .literal = .{ .float = -inner.float_value } }),
                        else => error.UnexpectedToken,
                    };
                }
                return error.UnexpectedToken;
            },
            .lparen => {
                _ = self.advance();
                const expr = try self.parseAssignment();
                try self.expect(.rparen);
                return expr;
            },
            .lbracket => return self.parseBlock(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseSymbolLiteral(self: *Parser) ParseError!*Node {
        _ = self.advance();
        if (self.current().kind == .string_lit) {
            const tok = self.advance();
            return newNode(self.allocator, .{ .literal = .{ .symbol = tok.string_value } });
        }
        if (self.current().kind == .identifier) {
            const tok = self.advance();
            return newNode(self.allocator, .{ .literal = .{ .symbol = tok.lexeme } });
        }
        if (isBinarySelectorToken(self.current())) {
            const tok = self.advance();
            const selector = if (tok.kind == .bar) "|" else tok.lexeme;
            return newNode(self.allocator, .{ .literal = .{ .symbol = selector } });
        }
        if (self.current().kind == .keyword) {
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(self.allocator);
            while (self.current().kind == .keyword) {
                const tok = self.advance();
                try parts.append(self.allocator, tok.lexeme);
            }
            return newNode(self.allocator, .{ .literal = .{ .symbol = try concatSlices(self.allocator, parts.items) } });
        }
        return error.InvalidSymbol;
    }

    fn parseBlock(self: *Parser) ParseError!*Node {
        _ = self.advance();
        var params: std.ArrayList([]const u8) = .empty;
        defer params.deinit(self.allocator);
        while (self.current().kind == .colon) {
            _ = self.advance();
            const tok = try self.expectIdentifier();
            try params.append(self.allocator, tok.lexeme);
        }
        if (params.items.len > 0) try self.expect(.bar);

        const temps = try self.parseOptionalTemps();
        const body = try self.parseStatements(.rbracket, true);
        try self.expect(.rbracket);
        return newNode(self.allocator, .{
            .block = .{
                .params = try params.toOwnedSlice(self.allocator),
                .temps = temps,
                .body = body,
            },
        });
    }

    fn current(self: *const Parser) Token {
        return self.tokens[self.idx];
    }

    fn peek(self: *const Parser, offset: usize) Token {
        const pos = self.idx + offset;
        if (pos >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[pos];
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.idx];
        if (self.idx + 1 < self.tokens.len) self.idx += 1;
        return tok;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        if (self.current().kind != kind) {
            if (self.current().kind == .eof) return error.UnexpectedEof;
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    fn expectIdentifier(self: *Parser) ParseError!Token {
        const tok = self.current();
        if (tok.kind != .identifier) {
            if (tok.kind == .eof) return error.UnexpectedEof;
            return error.UnexpectedToken;
        }
        _ = self.advance();
        return tok;
    }
};

fn tokenize(allocator: std.mem.Allocator, source: []const u8) ParseError![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);

    var i: usize = 0;
    while (true) {
        while (i < source.len) {
            const c = source[i];
            if (std.ascii.isWhitespace(c)) {
                i += 1;
                continue;
            }
            if (c == '"') {
                i += 1;
                while (i < source.len and source[i] != '"') : (i += 1) {}
                if (i >= source.len) return error.UnexpectedEof;
                i += 1;
                continue;
            }
            break;
        }
        if (i >= source.len) break;

        const c = source[i];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            i += 1;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) : (i += 1) {}
            if (i < source.len and source[i] == ':' and (i + 1 >= source.len or source[i + 1] != '=')) {
                i += 1;
                try tokens.append(allocator, .{ .kind = .keyword, .lexeme = source[start..i] });
            } else {
                try tokens.append(allocator, .{ .kind = .identifier, .lexeme = source[start..i] });
            }
            continue;
        }

        if (std.ascii.isDigit(c)) {
            const start = i;
            i += 1;
            while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
            if (i + 1 < source.len and source[i] == '.' and std.ascii.isDigit(source[i + 1])) {
                i += 1;
                while (i < source.len and std.ascii.isDigit(source[i])) : (i += 1) {}
                const lexeme = source[start..i];
                const value = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidNumber;
                try tokens.append(allocator, .{ .kind = .float_lit, .lexeme = lexeme, .float_value = value });
            } else {
                const lexeme = source[start..i];
                const value = std.fmt.parseInt(i64, lexeme, 10) catch return error.IntOverflow;
                try tokens.append(allocator, .{ .kind = .int_lit, .lexeme = lexeme, .int_value = value });
            }
            continue;
        }

        if (c == '\'') {
            const string = try parseStringLiteral(allocator, source, &i);
            try tokens.append(allocator, .{ .kind = .string_lit, .string_value = string });
            continue;
        }

        switch (c) {
            '#' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .hash, .lexeme = "#" });
            },
            ':' => {
                if (i + 1 < source.len and source[i + 1] == '=') {
                    i += 2;
                    try tokens.append(allocator, .{ .kind = .assign, .lexeme = ":=" });
                } else {
                    i += 1;
                    try tokens.append(allocator, .{ .kind = .colon, .lexeme = ":" });
                }
            },
            '^' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .return_op, .lexeme = "^" });
            },
            '(' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .lparen, .lexeme = "(" });
            },
            ')' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .rparen, .lexeme = ")" });
            },
            '[' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .lbracket, .lexeme = "[" });
            },
            ']' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .rbracket, .lexeme = "]" });
            },
            '.' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .period, .lexeme = "." });
            },
            '|' => {
                i += 1;
                try tokens.append(allocator, .{ .kind = .bar, .lexeme = "|" });
            },
            else => {
                if (!isBinaryChar(c)) return error.UnexpectedToken;
                const start = i;
                i += 1;
                while (i < source.len and isBinaryChar(source[i]) and source[i] != '|') : (i += 1) {}
                try tokens.append(allocator, .{ .kind = .binary, .lexeme = source[start..i] });
            },
        }
    }
    try tokens.append(allocator, .{ .kind = .eof, .lexeme = source[source.len..source.len] });
    return tokens.toOwnedSlice(allocator);
}

fn parseStringLiteral(allocator: std.mem.Allocator, source: []const u8, cursor: *usize) ParseError![]const u8 {
    std.debug.assert(source[cursor.*] == '\'');
    cursor.* += 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    while (cursor.* < source.len) {
        const c = source[cursor.*];
        if (c == '\'') {
            if (cursor.* + 1 < source.len and source[cursor.* + 1] == '\'') {
                try out.append(allocator, '\'');
                cursor.* += 2;
                continue;
            }
            cursor.* += 1;
            return out.toOwnedSlice(allocator);
        }
        try out.append(allocator, c);
        cursor.* += 1;
    }
    return error.InvalidString;
}

fn newNode(allocator: std.mem.Allocator, node: Node) ParseError!*Node {
    const p = allocator.create(Node) catch return error.OutOfMemory;
    p.* = node;
    return p;
}

fn literalFromJsonValue(v: std.json.Value) ParseError!Literal {
    if (v != .object) return error.BadFieldType;
    const obj = v.object;
    var it = obj.iterator();
    const entry = it.next() orelse return error.MissingField;
    const tag = entry.key_ptr.*;
    const payload = entry.value_ptr.*;

    if (std.mem.eql(u8, tag, "nil")) return .nil;
    if (std.mem.eql(u8, tag, "true")) return .true_lit;
    if (std.mem.eql(u8, tag, "false")) return .false_lit;
    if (std.mem.eql(u8, tag, "int")) {
        if (payload != .integer) return error.BadFieldType;
        return .{ .int = payload.integer };
    }
    if (std.mem.eql(u8, tag, "float")) {
        return switch (payload) {
            .float => .{ .float = payload.float },
            .integer => .{ .float = @floatFromInt(payload.integer) },
            else => error.BadFieldType,
        };
    }
    if (std.mem.eql(u8, tag, "string")) {
        if (payload != .string) return error.BadFieldType;
        return .{ .string = payload.string };
    }
    if (std.mem.eql(u8, tag, "symbol")) {
        if (payload != .string) return error.BadFieldType;
        return .{ .symbol = payload.string };
    }
    return error.UnsupportedLiteral;
}

fn stringSliceFromJsonArray(allocator: std.mem.Allocator, items: []std.json.Value) ParseError![]const []const u8 {
    const out = allocator.alloc([]const u8, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        if (item != .string) return error.BadFieldType;
        out[i] = item.string;
    }
    return out;
}

fn nodeSliceFromJsonArray(allocator: std.mem.Allocator, items: []std.json.Value) ParseError![]const *Node {
    const out = allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, i| out[i] = try nodeFromJsonValue(allocator, item);
    return out;
}

fn makeSend(allocator: std.mem.Allocator, receiver: *Node, selector: []const u8, args: []const *Node) ParseError!*Node {
    if (receiver.* == .var_ref and std.mem.eql(u8, receiver.var_ref, "super")) {
        return newNode(allocator, .{ .super_send = .{ .selector = selector, .args = args } });
    }
    return newNode(allocator, .{ .send = .{ .receiver = receiver, .selector = selector, .args = args } });
}

fn concatSlices(allocator: std.mem.Allocator, parts: []const []const u8) ParseError![]const u8 {
    var len: usize = 0;
    for (parts) |part| len += part.len;
    const out = allocator.alloc(u8, len) catch return error.OutOfMemory;
    var off: usize = 0;
    for (parts) |part| {
        @memcpy(out[off .. off + part.len], part);
        off += part.len;
    }
    return out;
}

fn isBinaryChar(c: u8) bool {
    return switch (c) {
        '!', '%', '&', '*', '+', ',', '/', '<', '=', '>', '?', '@', '\\', '~', '-', '|' => true,
        else => false,
    };
}

fn isBinarySelectorToken(tok: Token) bool {
    return tok.kind == .binary or tok.kind == .bar;
}

fn lowerNodeToHeap(heap: *Heap, g: *const Globals, node: *const Node) ParseError!Oop {
    switch (node.*) {
        .literal => |lit| {
            const lit_node = heap.allocSlots(g.literal_node_class, object.LIT_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(lit_node, object.SLOT_LIT_VALUE, try lowerLiteralToHeap(heap, g, lit));
            return lit_node;
        },
        .var_ref => |name| {
            const sym = dict.newSymbol(heap, g, name) catch return error.OutOfMemory;
            const ref = heap.allocSlots(g.var_ref_node_class, object.VARREF_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(ref, object.SLOT_VARREF_NAME, sym);
            return ref;
        },
        .assign => |assign| {
            const sym = dict.newSymbol(heap, g, assign.name) catch return error.OutOfMemory;
            const value = try lowerNodeToHeap(heap, g, assign.value);
            const out = heap.allocSlots(g.assign_node_class, object.ASSIGN_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(out, object.SLOT_ASSIGN_NAME, sym);
            object.setSlot(out, object.SLOT_ASSIGN_VALUE, value);
            return out;
        },
        .send => |send| {
            const recv = try lowerNodeToHeap(heap, g, send.receiver);
            const sym = dict.newSymbol(heap, g, send.selector) catch return error.OutOfMemory;
            const args = try lowerNodeArray(heap, g, send.args);
            const out = heap.allocSlots(g.send_node_class, object.SEND_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(out, object.SLOT_SEND_RECEIVER, recv);
            object.setSlot(out, object.SLOT_SEND_SELECTOR, sym);
            object.setSlot(out, object.SLOT_SEND_ARGS, args);
            return out;
        },
        .super_send => |send| {
            const sym = dict.newSymbol(heap, g, send.selector) catch return error.OutOfMemory;
            const args = try lowerNodeArray(heap, g, send.args);
            const out = heap.allocSlots(g.super_send_node_class, object.SUPER_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(out, object.SLOT_SUPER_SELECTOR, sym);
            object.setSlot(out, object.SLOT_SUPER_ARGS, args);
            return out;
        },
        .block => |block| {
            const params = try lowerSymbolArray(heap, g, block.params);
            const temps = try lowerSymbolArray(heap, g, block.temps);
            const body = try lowerBodyArray(heap, g, block.body);
            const out = heap.allocSlots(g.block_node_class, object.BLOCKNODE_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(out, object.SLOT_BLOCKNODE_PARAMS, params);
            object.setSlot(out, object.SLOT_BLOCKNODE_TEMPS, temps);
            object.setSlot(out, object.SLOT_BLOCKNODE_BODY, body);
            return out;
        },
        .seq => |body| {
            const arr = try lowerBodyArray(heap, g, body);
            const out = heap.allocSlots(g.seq_node_class, object.SEQ_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(out, object.SLOT_SEQ_BODY, arr);
            return out;
        },
        .ret => |inner| {
            const lowered = try lowerNodeToHeap(heap, g, inner);
            const out = heap.allocSlots(g.ret_node_class, object.RET_INST_SIZE) catch return error.OutOfMemory;
            object.setSlot(out, object.SLOT_RET_INNER, lowered);
            return out;
        },
    }
}

fn lowerLiteralToHeap(heap: *Heap, g: *const Globals, lit: Literal) ParseError!Oop {
    return switch (lit) {
        .nil => oop_mod.NIL,
        .true_lit => oop_mod.TRUE,
        .false_lit => oop_mod.FALSE,
        .int => |n| blk: {
            const min_i63 = -(@as(i64, 1) << 62);
            const max_i63 = (@as(i64, 1) << 62) - 1;
            if (n < min_i63 or n > max_i63) return error.IntOverflow;
            break :blk oop_mod.fromInt(n);
        },
        .float => |n| oop_mod.fromF64(n),
        .string => |s| blk: {
            const str = heap.allocBytes(g.string_class, @intCast(s.len)) catch return error.OutOfMemory;
            @memcpy(object.bytesOf(str)[0..s.len], s);
            break :blk str;
        },
        .symbol => |s| dict.newSymbol(heap, g, s) catch return error.OutOfMemory,
    };
}

fn lowerNodeArray(heap: *Heap, g: *const Globals, items: []const *Node) ParseError!Oop {
    const arr = heap.allocSlots(g.array_class, @intCast(items.len)) catch return error.OutOfMemory;
    for (items, 0..) |item, i| object.setSlot(arr, @intCast(i), try lowerNodeToHeap(heap, g, item));
    return arr;
}

fn lowerBodyArray(heap: *Heap, g: *const Globals, items: []const *Node) ParseError!Oop {
    return lowerNodeArray(heap, g, items);
}

fn lowerSymbolArray(heap: *Heap, g: *const Globals, items: []const []const u8) ParseError!Oop {
    const arr = heap.allocSlots(g.array_class, @intCast(items.len)) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        const sym = dict.newSymbol(heap, g, item) catch return error.OutOfMemory;
        object.setSlot(arr, @intCast(i), sym);
    }
    return arr;
}

fn liftMethodFromHeap(allocator: std.mem.Allocator, g: *const Globals, method_oop: Oop) ParseError!Method {
    if (!oop_mod.isHeapPtr(method_oop)) return error.UnsupportedMethod;
    if (oop_mod.toInt(object.slot(method_oop, object.SLOT_METHOD_KIND)) == object.METHOD_KIND_PRIMITIVE) return error.UnsupportedMethod;

    const selector_sym = object.slot(method_oop, object.SLOT_METHOD_SELECTOR);
    const selector = try symbolBytes(selector_sym);
    return .{
        .selector = selector,
        .params = try liftSymbolArray(allocator, object.slot(method_oop, object.SLOT_METHOD_PARAMS)),
        .temps = try liftSymbolArray(allocator, object.slot(method_oop, object.SLOT_METHOD_TEMPS)),
        .body = try liftNodeArray(allocator, g, object.slot(method_oop, object.SLOT_METHOD_BODY)),
    };
}

fn liftNodeArray(allocator: std.mem.Allocator, g: *const Globals, arr: Oop) ParseError![]const *Node {
    if (!oop_mod.isHeapPtr(arr)) return &.{};
    const n = object.headerOf(arr).size;
    const out = allocator.alloc(*Node, n) catch return error.OutOfMemory;
    var i: u32 = 0;
    while (i < n) : (i += 1) out[i] = try liftNodeFromHeap(allocator, g, object.slot(arr, i));
    return out;
}

fn liftSymbolArray(allocator: std.mem.Allocator, arr: Oop) ParseError![]const []const u8 {
    if (!oop_mod.isHeapPtr(arr)) return &.{};
    const n = object.headerOf(arr).size;
    const out = allocator.alloc([]const u8, n) catch return error.OutOfMemory;
    var i: u32 = 0;
    while (i < n) : (i += 1) out[i] = try symbolBytes(object.slot(arr, i));
    return out;
}

fn symbolBytes(sym: Oop) ParseError![]const u8 {
    if (!oop_mod.isHeapPtr(sym)) return error.BadFieldType;
    const hdr = object.headerOf(sym);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.BadFieldType;
    return object.bytesOf(sym)[0..hdr.size];
}

fn liftLiteralFromHeap(lit_oop: Oop) ParseError!Literal {
    if (oop_mod.isNil(lit_oop)) return .nil;
    if (lit_oop == oop_mod.TRUE) return .true_lit;
    if (lit_oop == oop_mod.FALSE) return .false_lit;
    if (oop_mod.isInt(lit_oop)) return .{ .int = oop_mod.toInt(lit_oop) };
    if (oop_mod.isFloat(lit_oop)) return .{ .float = oop_mod.toF64(lit_oop) };
    if (!oop_mod.isHeapPtr(lit_oop)) return error.UnsupportedLiteral;
    const hdr = object.headerOf(lit_oop);
    if ((hdr.flags & object.FLAG_BYTES) == 0) return error.UnsupportedLiteral;
    const bytes = object.bytesOf(lit_oop)[0..hdr.size];
    return if (hdr.class == hdr.class) blk: {
        // Distinguish String vs Symbol by class name rather than hard-coded globals.
        break :blk .{ .string = bytes };
    } else error.UnsupportedLiteral;
}

fn liftNodeFromHeap(allocator: std.mem.Allocator, g: *const Globals, node_oop: Oop) ParseError!*Node {
    if (!oop_mod.isHeapPtr(node_oop)) return error.BadFieldType;
    const cls = object.headerOf(node_oop).class;
    if (cls == g.literal_node_class) {
        const value = object.slot(node_oop, object.SLOT_LIT_VALUE);
        if (oop_mod.isHeapPtr(value)) {
            const hdr = object.headerOf(value);
            if ((hdr.flags & object.FLAG_BYTES) != 0 and hdr.class == g.symbol_class) {
                return newNode(allocator, .{ .literal = .{ .symbol = object.bytesOf(value)[0..hdr.size] } });
            }
            if ((hdr.flags & object.FLAG_BYTES) != 0 and hdr.class == g.string_class) {
                return newNode(allocator, .{ .literal = .{ .string = object.bytesOf(value)[0..hdr.size] } });
            }
        }
        return newNode(allocator, .{ .literal = switch (try liftLiteralFromHeap(value)) {
            .nil => .nil,
            .true_lit => .true_lit,
            .false_lit => .false_lit,
            .int => |n| .{ .int = n },
            .float => |n| .{ .float = n },
            .string => |s| .{ .string = s },
            .symbol => |s| .{ .symbol = s },
        } });
    }
    if (cls == g.var_ref_node_class) {
        return newNode(allocator, .{ .var_ref = try symbolBytes(object.slot(node_oop, object.SLOT_VARREF_NAME)) });
    }
    if (cls == g.assign_node_class) {
        return newNode(allocator, .{
            .assign = .{
                .name = try symbolBytes(object.slot(node_oop, object.SLOT_ASSIGN_NAME)),
                .value = try liftNodeFromHeap(allocator, g, object.slot(node_oop, object.SLOT_ASSIGN_VALUE)),
            },
        });
    }
    if (cls == g.send_node_class) {
        return newNode(allocator, .{
            .send = .{
                .receiver = try liftNodeFromHeap(allocator, g, object.slot(node_oop, object.SLOT_SEND_RECEIVER)),
                .selector = try symbolBytes(object.slot(node_oop, object.SLOT_SEND_SELECTOR)),
                .args = try liftNodeArray(allocator, g, object.slot(node_oop, object.SLOT_SEND_ARGS)),
            },
        });
    }
    if (cls == g.super_send_node_class) {
        return newNode(allocator, .{
            .super_send = .{
                .selector = try symbolBytes(object.slot(node_oop, object.SLOT_SUPER_SELECTOR)),
                .args = try liftNodeArray(allocator, g, object.slot(node_oop, object.SLOT_SUPER_ARGS)),
            },
        });
    }
    if (cls == g.block_node_class) {
        return newNode(allocator, .{
            .block = .{
                .params = try liftSymbolArray(allocator, object.slot(node_oop, object.SLOT_BLOCKNODE_PARAMS)),
                .temps = try liftSymbolArray(allocator, object.slot(node_oop, object.SLOT_BLOCKNODE_TEMPS)),
                .body = try liftNodeArray(allocator, g, object.slot(node_oop, object.SLOT_BLOCKNODE_BODY)),
            },
        });
    }
    if (cls == g.seq_node_class) {
        return newNode(allocator, .{ .seq = try liftNodeArray(allocator, g, object.slot(node_oop, object.SLOT_SEQ_BODY)) });
    }
    if (cls == g.ret_node_class) {
        return newNode(allocator, .{ .ret = try liftNodeFromHeap(allocator, g, object.slot(node_oop, object.SLOT_RET_INNER)) });
    }
    return error.BadFieldType;
}

const Prec = enum(u8) {
    lowest = 0,
    assign = 1,
    keyword = 2,
    binary = 3,
    unary = 4,
    primary = 5,
};

const SelectorKind = enum {
    unary,
    binary,
    keyword,
};

fn selectorKind(selector: []const u8, arity: usize) SelectorKind {
    if (std.mem.indexOfScalar(u8, selector, ':') != null) return .keyword;
    if (arity == 0) return .unary;
    return .binary;
}

fn precedenceOf(node: *const Node) Prec {
    return switch (node.*) {
        .assign => .assign,
        .send => |send| switch (selectorKind(send.selector, send.args.len)) {
            .keyword => .keyword,
            .binary => .binary,
            .unary => .unary,
        },
        .super_send => |send| switch (selectorKind(send.selector, send.args.len)) {
            .keyword => .keyword,
            .binary => .binary,
            .unary => .unary,
        },
        .seq => .assign,
        else => .primary,
    };
}

fn appendMethod(allocator: std.mem.Allocator, out: *std.ArrayList(u8), method: Method) anyerror!void {
    try appendMethodHeader(allocator, out, method.selector, method.params);
    if (method.temps.len == 0 and method.body.len == 0) return;
    try out.append(allocator, '\n');
    if (method.temps.len > 0) {
        try appendIndent(allocator, out, 4);
        try out.append(allocator, '|');
        for (method.temps) |temp| {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, temp);
        }
        try out.appendSlice(allocator, " |");
        if (method.body.len > 0) try out.append(allocator, '\n');
    }
    try appendStatements(allocator, out, method.body, 4);
}

fn appendMethodHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selector: []const u8, params: []const []const u8) anyerror!void {
    switch (selectorKind(selector, params.len)) {
        .unary => try out.appendSlice(allocator, selector),
        .binary => {
            try out.appendSlice(allocator, selector);
            if (params.len > 0) {
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, params[0]);
            }
        },
        .keyword => {
            var part_it = std.mem.splitScalar(u8, selector, ':');
            var i: usize = 0;
            while (part_it.next()) |part| {
                if (part.len == 0 and i >= params.len) break;
                if (i > 0) try out.append(allocator, ' ');
                try out.appendSlice(allocator, part);
                try out.append(allocator, ':');
                if (i < params.len) {
                    try out.append(allocator, ' ');
                    try out.appendSlice(allocator, params[i]);
                }
                i += 1;
                if (i >= params.len) break;
            }
        },
    }
}

fn appendStatements(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const *Node, indent: usize) anyerror!void {
    for (body, 0..) |stmt, i| {
        if (i > 0) {
            try out.append(allocator, '.');
            try out.append(allocator, '\n');
        }
        try appendIndent(allocator, out, indent);
        try appendStatement(allocator, out, stmt, indent);
    }
}

fn appendStatement(allocator: std.mem.Allocator, out: *std.ArrayList(u8), node: *const Node, indent: usize) anyerror!void {
    switch (node.*) {
        .ret => |inner| {
            try out.append(allocator, '^');
            try appendExpr(allocator, out, inner, .lowest, indent);
        },
        else => try appendExpr(allocator, out, node, .lowest, indent),
    }
}

fn appendExpr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), node: *const Node, parent_prec: Prec, indent: usize) anyerror!void {
    const my_prec = precedenceOf(node);
    const need_parens = @intFromEnum(my_prec) < @intFromEnum(parent_prec);
    if (need_parens) try out.append(allocator, '(');
    switch (node.*) {
        .literal => |lit| try appendLiteralSource(allocator, out, lit),
        .var_ref => |name| try out.appendSlice(allocator, name),
        .assign => |assign| {
            try out.appendSlice(allocator, assign.name);
            try out.appendSlice(allocator, " := ");
            try appendExpr(allocator, out, assign.value, .assign, indent);
        },
        .send => |send| try appendSend(allocator, out, send.receiver, send.selector, send.args, false, indent),
        .super_send => |send| try appendSend(allocator, out, null, send.selector, send.args, true, indent),
        .block => |block| try appendBlock(allocator, out, block.params, block.temps, block.body, indent),
        .seq => |body| {
            try appendBlock(allocator, out, &.{}, &.{}, body, indent);
            try out.appendSlice(allocator, " value");
        },
        .ret => |inner| {
            try out.append(allocator, '^');
            try appendExpr(allocator, out, inner, .lowest, indent);
        },
    }
    if (need_parens) try out.append(allocator, ')');
}

fn appendSend(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    receiver: ?*const Node,
    selector: []const u8,
    args: []const *Node,
    is_super: bool,
    indent: usize,
) anyerror!void {
    const kind = selectorKind(selector, args.len);
    if (is_super) {
        try out.appendSlice(allocator, "super");
    } else if (receiver) |recv| {
        const recv_prec: Prec = switch (kind) {
            .unary => .unary,
            .binary => .binary,
            .keyword => .keyword,
        };
        try appendExpr(allocator, out, recv, recv_prec, indent);
    }

    switch (kind) {
        .unary => {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, selector);
        },
        .binary => {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, selector);
            try out.append(allocator, ' ');
            try appendExpr(allocator, out, args[0], .unary, indent);
        },
        .keyword => {
            var part_it = std.mem.splitScalar(u8, selector, ':');
            var i: usize = 0;
            while (part_it.next()) |part| {
                if (part.len == 0 and i >= args.len) break;
                try out.append(allocator, ' ');
                try out.appendSlice(allocator, part);
                try out.append(allocator, ':');
                if (i < args.len) {
                    try out.append(allocator, ' ');
                    try appendExpr(allocator, out, args[i], .binary, indent);
                }
                i += 1;
                if (i >= args.len) break;
            }
        },
    }
}

fn appendBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    params: []const []const u8,
    temps: []const []const u8,
    body: []const *Node,
    indent: usize,
) anyerror!void {
    const simple = temps.len == 0 and body.len <= 1 and !containsMultilineNode(body);
    if (simple) {
        try out.append(allocator, '[');
        if (params.len > 0) {
            for (params) |param| {
                try out.appendSlice(allocator, " :");
                try out.appendSlice(allocator, param);
            }
            try out.appendSlice(allocator, " |");
        }
        if (body.len > 0) {
            try out.append(allocator, ' ');
            try appendStatement(allocator, out, body[0], indent + 4);
            try out.append(allocator, ' ');
        }
        try out.append(allocator, ']');
        return;
    }

    try out.appendSlice(allocator, "[\n");
    if (params.len > 0) {
        try appendIndent(allocator, out, indent + 4);
        for (params) |param| {
            try out.append(allocator, ':');
            try out.appendSlice(allocator, param);
            try out.append(allocator, ' ');
        }
        try out.append(allocator, '|');
        try out.append(allocator, '\n');
    }
    if (temps.len > 0) {
        try appendIndent(allocator, out, indent + 4);
        try out.append(allocator, '|');
        for (temps) |temp| {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, temp);
        }
        try out.appendSlice(allocator, " |");
        if (body.len > 0) try out.append(allocator, '\n');
    }
    try appendStatements(allocator, out, body, indent + 4);
    try out.append(allocator, '\n');
    try appendIndent(allocator, out, indent);
    try out.append(allocator, ']');
}

fn containsMultilineNode(body: []const *Node) bool {
    for (body) |stmt| {
        switch (stmt.*) {
            .block => |block| if (block.temps.len > 0 or block.body.len > 1 or containsMultilineNode(block.body)) return true,
            .seq => return true,
            else => {},
        }
    }
    return false;
}

fn appendLiteralSource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), lit: Literal) anyerror!void {
    switch (lit) {
        .nil => try out.appendSlice(allocator, "nil"),
        .true_lit => try out.appendSlice(allocator, "true"),
        .false_lit => try out.appendSlice(allocator, "false"),
        .int => |n| try appendFmt(allocator, out, "{d}", .{n}),
        .float => |n| try appendFmt(allocator, out, "{d}", .{n}),
        .string => |s| {
            try out.append(allocator, '\'');
            for (s) |c| {
                if (c == '\'') try out.append(allocator, '\'');
                try out.append(allocator, c);
            }
            try out.append(allocator, '\'');
        },
        .symbol => |s| {
            if (isSimpleSymbolLiteral(s)) {
                try out.append(allocator, '#');
                try out.appendSlice(allocator, s);
            } else {
                try out.appendSlice(allocator, "#'");
                for (s) |c| {
                    if (c == '\'') try out.append(allocator, '\'');
                    try out.append(allocator, c);
                }
                try out.append(allocator, '\'');
            }
        },
    }
}

fn isSimpleSymbolLiteral(sym: []const u8) bool {
    if (sym.len == 0) return false;
    if (isBinaryOnly(sym)) return true;
    if (std.mem.indexOfScalar(u8, sym, ':') != null) {
        var it = std.mem.splitScalar(u8, sym, ':');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (!isIdentifierLike(part)) return false;
        }
        return sym[sym.len - 1] == ':';
    }
    return isIdentifierLike(sym);
}

fn isIdentifierLike(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn isBinaryOnly(sym: []const u8) bool {
    if (sym.len == 0) return false;
    for (sym) |c| if (!isBinaryChar(c)) return false;
    return true;
}

fn appendMethodJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), method: Method) anyerror!void {
    try out.append(allocator, '{');
    try appendJsonFieldName(allocator, out, "selector");
    try appendJsonString(allocator, out, method.selector);
    try out.append(allocator, ',');
    try appendJsonFieldName(allocator, out, "params");
    try appendStringArrayJson(allocator, out, method.params);
    try out.append(allocator, ',');
    try appendJsonFieldName(allocator, out, "temps");
    try appendStringArrayJson(allocator, out, method.temps);
    try out.append(allocator, ',');
    try appendJsonFieldName(allocator, out, "body");
    try appendNodeArrayJson(allocator, out, method.body);
    try out.append(allocator, '}');
}

fn appendNodeJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), node: *const Node) anyerror!void {
    switch (node.*) {
        .literal => |lit| {
            try out.appendSlice(allocator, "{\"literal\":");
            try appendLiteralJson(allocator, out, lit);
            try out.append(allocator, '}');
        },
        .var_ref => |name| {
            try out.appendSlice(allocator, "{\"var_ref\":");
            try appendJsonString(allocator, out, name);
            try out.append(allocator, '}');
        },
        .assign => |assign| {
            try out.appendSlice(allocator, "{\"assign\":{");
            try appendJsonFieldName(allocator, out, "name");
            try appendJsonString(allocator, out, assign.name);
            try out.append(allocator, ',');
            try appendJsonFieldName(allocator, out, "value");
            try appendNodeJson(allocator, out, assign.value);
            try out.appendSlice(allocator, "}}");
        },
        .send => |send| {
            try out.appendSlice(allocator, "{\"send\":{");
            try appendJsonFieldName(allocator, out, "receiver");
            try appendNodeJson(allocator, out, send.receiver);
            try out.append(allocator, ',');
            try appendJsonFieldName(allocator, out, "selector");
            try appendJsonString(allocator, out, send.selector);
            try out.append(allocator, ',');
            try appendJsonFieldName(allocator, out, "args");
            try appendNodeArrayJson(allocator, out, send.args);
            try out.appendSlice(allocator, "}}");
        },
        .super_send => |send| {
            try out.appendSlice(allocator, "{\"super_send\":{");
            try appendJsonFieldName(allocator, out, "selector");
            try appendJsonString(allocator, out, send.selector);
            try out.append(allocator, ',');
            try appendJsonFieldName(allocator, out, "args");
            try appendNodeArrayJson(allocator, out, send.args);
            try out.appendSlice(allocator, "}}");
        },
        .block => |block| {
            try out.appendSlice(allocator, "{\"block\":{");
            try appendJsonFieldName(allocator, out, "params");
            try appendStringArrayJson(allocator, out, block.params);
            try out.append(allocator, ',');
            try appendJsonFieldName(allocator, out, "temps");
            try appendStringArrayJson(allocator, out, block.temps);
            try out.append(allocator, ',');
            try appendJsonFieldName(allocator, out, "body");
            try appendNodeArrayJson(allocator, out, block.body);
            try out.appendSlice(allocator, "}}");
        },
        .seq => |body| {
            try out.appendSlice(allocator, "{\"seq\":");
            try appendNodeArrayJson(allocator, out, body);
            try out.append(allocator, '}');
        },
        .ret => |inner| {
            try out.appendSlice(allocator, "{\"ret\":");
            try appendNodeJson(allocator, out, inner);
            try out.append(allocator, '}');
        },
    }
}

fn appendLiteralJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), lit: Literal) anyerror!void {
    switch (lit) {
        .nil => try out.appendSlice(allocator, "{\"nil\":true}"),
        .true_lit => try out.appendSlice(allocator, "{\"true\":true}"),
        .false_lit => try out.appendSlice(allocator, "{\"false\":true}"),
        .int => |n| {
            try out.appendSlice(allocator, "{\"int\":");
            try appendFmt(allocator, out, "{d}", .{n});
            try out.append(allocator, '}');
        },
        .float => |n| {
            try out.appendSlice(allocator, "{\"float\":");
            try appendFmt(allocator, out, "{d}", .{n});
            try out.append(allocator, '}');
        },
        .string => |s| {
            try out.appendSlice(allocator, "{\"string\":");
            try appendJsonString(allocator, out, s);
            try out.append(allocator, '}');
        },
        .symbol => |s| {
            try out.appendSlice(allocator, "{\"symbol\":");
            try appendJsonString(allocator, out, s);
            try out.append(allocator, '}');
        },
    }
}

fn appendStringArrayJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), items: []const []const u8) anyerror!void {
    try out.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendJsonString(allocator, out, item);
    }
    try out.append(allocator, ']');
}

fn appendNodeArrayJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), items: []const *Node) anyerror!void {
    try out.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendNodeJson(allocator, out, item);
    }
    try out.append(allocator, ']');
}

fn appendJsonFieldName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) anyerror!void {
    try appendJsonString(allocator, out, name);
    try out.append(allocator, ':');
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) anyerror!void {
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
                    try appendFmt(allocator, out, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn appendIndent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: usize) anyerror!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.append(allocator, ' ');
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) anyerror!void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}
