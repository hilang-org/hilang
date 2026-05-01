const std = @import("std");

const posix = std.posix;
const Hash = std.crypto.hash.sha2.Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const X25519 = std.crypto.dh.X25519;

pub const protocol_name = "Noise_XX_25519_ChaChaPoly_SHA256";
pub const PublicKey = [X25519.public_length]u8;
pub const SecretKey = [X25519.secret_length]u8;
pub const KeyPair = X25519.KeyPair;

pub const HandshakeError = error{
    UnexpectedEof,
    BadHandshakeMessage,
    NonceExhausted,
    PeerKeyMismatch,
    PeerNotAllowed,
    InvalidKey,
    InvalidKeyFile,
} || posix.ReadError || posix.WriteError || posix.OpenError || posix.UnexpectedError || std.mem.Allocator.Error || std.crypto.errors.IdentityElementError || error{AuthenticationFailed};

pub const TcpConnectError = error{
    ConnectFailed,
    HostNotFound,
} || posix.OpenError || posix.UnexpectedError;

pub const TcpListenError = error{
    BindFailed,
    ListenFailed,
    HostNotFound,
} || posix.OpenError || posix.UnexpectedError;

pub const Channel = struct {
    send: CipherState,
    recv: CipherState,
    remote_static: PublicKey,

    pub fn sendFrame(self: *Channel, allocator: std.mem.Allocator, fd: posix.fd_t, plaintext: []const u8) !void {
        const sealed = try self.send.encrypt(allocator, "", plaintext);
        defer allocator.free(sealed);

        var header: [4]u8 = undefined;
        writeU32Be(&header, @intCast(sealed.len));
        try writeAll(fd, &header);
        try writeAll(fd, sealed);
    }

    pub fn recvFrame(self: *Channel, allocator: std.mem.Allocator, fd: posix.fd_t, max_plaintext: usize) ![]u8 {
        var header: [4]u8 = undefined;
        try readExact(fd, &header);
        const sealed_len = readU32Be(&header);
        if (sealed_len < Aead.tag_length or sealed_len > max_plaintext + Aead.tag_length) return error.BadHandshakeMessage;

        const sealed = try allocator.alloc(u8, sealed_len);
        defer allocator.free(sealed);
        try readExact(fd, sealed);
        return self.recv.decrypt(allocator, "", sealed);
    }
};

const CipherState = struct {
    has_key: bool = false,
    key: [Aead.key_length]u8 = [_]u8{0} ** Aead.key_length,
    nonce: u64 = 0,

    fn initializeKey(self: *CipherState, key_opt: ?[Aead.key_length]u8) void {
        if (key_opt) |key| {
            self.key = key;
            self.has_key = true;
            self.nonce = 0;
        } else {
            self.key = [_]u8{0} ** Aead.key_length;
            self.has_key = false;
            self.nonce = 0;
        }
    }

    fn encrypt(self: *CipherState, allocator: std.mem.Allocator, ad: []const u8, plaintext: []const u8) ![]u8 {
        if (!self.has_key) return allocator.dupe(u8, plaintext);
        if (self.nonce == std.math.maxInt(u64)) return error.NonceExhausted;

        const out = try allocator.alloc(u8, plaintext.len + Aead.tag_length);
        errdefer allocator.free(out);
        const nonce = makeNonce(self.nonce);
        const tag: *[Aead.tag_length]u8 = @ptrCast(out[plaintext.len .. plaintext.len + Aead.tag_length].ptr);
        Aead.encrypt(out[0..plaintext.len], tag, plaintext, ad, nonce, self.key);
        self.nonce += 1;
        return out;
    }

    fn decrypt(self: *CipherState, allocator: std.mem.Allocator, ad: []const u8, ciphertext: []const u8) ![]u8 {
        if (!self.has_key) return allocator.dupe(u8, ciphertext);
        if (self.nonce == std.math.maxInt(u64)) return error.NonceExhausted;
        if (ciphertext.len < Aead.tag_length) return error.BadHandshakeMessage;

        const out_len = ciphertext.len - Aead.tag_length;
        const out = try allocator.alloc(u8, out_len);
        errdefer allocator.free(out);
        const nonce = makeNonce(self.nonce);
        const tag: *const [Aead.tag_length]u8 = @ptrCast(ciphertext[out_len .. out_len + Aead.tag_length].ptr);
        try Aead.decrypt(out, ciphertext[0..out_len], tag.*, ad, nonce, self.key);
        self.nonce += 1;
        return out;
    }
};

const SymmetricState = struct {
    ck: [Hash.digest_length]u8,
    h: [Hash.digest_length]u8,
    cipher: CipherState,

    fn init() SymmetricState {
        var h: [Hash.digest_length]u8 = undefined;
        if (protocol_name.len <= Hash.digest_length) {
            h = [_]u8{0} ** Hash.digest_length;
            @memcpy(h[0..protocol_name.len], protocol_name);
        } else {
            Hash.hash(protocol_name, &h, .{});
        }
        return .{
            .ck = h,
            .h = h,
            .cipher = .{},
        };
    }

    fn mixHash(self: *SymmetricState, data: []const u8) void {
        var st = Hash.init(.{});
        st.update(&self.h);
        st.update(data);
        st.final(&self.h);
    }

    fn mixKey(self: *SymmetricState, ikm: []const u8) void {
        const out = hkdf2(self.ck, ikm);
        self.ck = out.ck;
        self.cipher.initializeKey(out.k);
    }

    fn encryptAndHash(self: *SymmetricState, allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
        if (!self.cipher.has_key) {
            self.mixHash(plaintext);
            return allocator.dupe(u8, plaintext);
        }
        const sealed = try self.cipher.encrypt(allocator, &self.h, plaintext);
        self.mixHash(sealed);
        return sealed;
    }

    fn decryptAndHash(self: *SymmetricState, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        if (!self.cipher.has_key) {
            self.mixHash(ciphertext);
            return allocator.dupe(u8, ciphertext);
        }
        const plaintext = try self.cipher.decrypt(allocator, &self.h, ciphertext);
        self.mixHash(ciphertext);
        return plaintext;
    }

    fn split(self: *SymmetricState) struct { c1: CipherState, c2: CipherState } {
        const out = hkdf2(self.ck, "");
        var c1 = CipherState{};
        var c2 = CipherState{};
        c1.initializeKey(out.ck);
        c2.initializeKey(out.k);
        return .{ .c1 = c1, .c2 = c2 };
    }
};

pub fn clientHandshake(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    local_static: KeyPair,
    expected_remote: PublicKey,
) !Channel {
    var ss = SymmetricState.init();
    const local_e = try generateKeyPair();

    var msg1 = local_e.public_key;
    ss.mixHash(&msg1);
    try writeAll(fd, &msg1);

    var msg2: [X25519.public_length + X25519.public_length + Aead.tag_length]u8 = undefined;
    try readExact(fd, &msg2);

    const remote_e: PublicKey = msg2[0..X25519.public_length].*;
    ss.mixHash(&remote_e);
    const ee = try X25519.scalarmult(local_e.secret_key, remote_e);
    ss.mixKey(&ee);

    const remote_s_bytes = try ss.decryptAndHash(allocator, msg2[X25519.public_length..]);
    defer allocator.free(remote_s_bytes);
    if (remote_s_bytes.len != X25519.public_length) return error.BadHandshakeMessage;
    const remote_s: PublicKey = remote_s_bytes[0..X25519.public_length].*;
    if (!std.mem.eql(u8, &remote_s, &expected_remote)) return error.PeerKeyMismatch;

    const es = try X25519.scalarmult(local_e.secret_key, remote_s);
    ss.mixKey(&es);

    const msg3 = try ss.encryptAndHash(allocator, &local_static.public_key);
    defer allocator.free(msg3);
    if (msg3.len != X25519.public_length + Aead.tag_length) return error.BadHandshakeMessage;
    const se = try X25519.scalarmult(local_static.secret_key, remote_e);
    ss.mixKey(&se);
    try writeAll(fd, msg3);

    const split = ss.split();
    return .{
        .send = split.c1,
        .recv = split.c2,
        .remote_static = remote_s,
    };
}

pub fn serverHandshake(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    local_static: KeyPair,
    allowed_peers: []const PublicKey,
) !Channel {
    var ss = SymmetricState.init();

    var msg1: [X25519.public_length]u8 = undefined;
    try readExact(fd, &msg1);
    const remote_e: PublicKey = msg1;
    ss.mixHash(&remote_e);

    const local_e = try generateKeyPair();
    var msg2: std.ArrayList(u8) = .empty;
    defer msg2.deinit(allocator);

    try msg2.appendSlice(allocator, &local_e.public_key);
    ss.mixHash(&local_e.public_key);
    const ee = try X25519.scalarmult(local_e.secret_key, remote_e);
    ss.mixKey(&ee);

    const enc_static = try ss.encryptAndHash(allocator, &local_static.public_key);
    defer allocator.free(enc_static);
    try msg2.appendSlice(allocator, enc_static);
    const es = try X25519.scalarmult(local_static.secret_key, remote_e);
    ss.mixKey(&es);

    try writeAll(fd, msg2.items);

    var msg3: [X25519.public_length + Aead.tag_length]u8 = undefined;
    try readExact(fd, &msg3);
    const remote_s_bytes = try ss.decryptAndHash(allocator, &msg3);
    defer allocator.free(remote_s_bytes);
    if (remote_s_bytes.len != X25519.public_length) return error.BadHandshakeMessage;
    const remote_s: PublicKey = remote_s_bytes[0..X25519.public_length].*;
    const se = try X25519.scalarmult(local_e.secret_key, remote_s);
    ss.mixKey(&se);

    if (allowed_peers.len != 0 and !keyAllowed(remote_s, allowed_peers)) return error.PeerNotAllowed;

    const split = ss.split();
    return .{
        .send = split.c2,
        .recv = split.c1,
        .remote_static = remote_s,
    };
}

pub fn generateKeyPair() !KeyPair {
    while (true) {
        var seed: [X25519.seed_length]u8 = undefined;
        try fillRandom(&seed);
        return X25519.KeyPair.generateDeterministic(seed) catch continue;
    }
}

pub fn derivePublicKey(secret: SecretKey) !PublicKey {
    return try X25519.recoverPublicKey(secret);
}

pub fn encodeKeyHex(buf: *[64]u8, key: [32]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (key, 0..) |byte, i| {
        buf[i * 2] = digits[byte >> 4];
        buf[i * 2 + 1] = digits[byte & 0x0f];
    }
    return buf[0..];
}

pub fn decodeKeyHex(text: []const u8) ![32]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 64) return error.InvalidKeyFile;
    var key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, trimmed);
    return key;
}

pub fn loadSecretKeyFile(allocator: std.mem.Allocator, path: []const u8) !KeyPair {
    const bytes = try readSmallFile(allocator, path, 256);
    defer allocator.free(bytes);
    const secret = try decodeKeyHex(bytes);
    return .{
        .secret_key = secret,
        .public_key = try X25519.recoverPublicKey(secret),
    };
}

pub fn loadPublicKeyFile(allocator: std.mem.Allocator, path: []const u8) !PublicKey {
    const bytes = try readSmallFile(allocator, path, 256);
    defer allocator.free(bytes);
    return decodeKeyHex(bytes);
}

pub fn writeKeyFile(path: []const u8, key: [32]u8) !void {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o600);
    defer _ = posix.system.close(fd);

    var buf: [65]u8 = undefined;
    var hex: [64]u8 = undefined;
    @memcpy(buf[0..64], encodeKeyHex(&hex, key));
    buf[64] = '\n';
    try writeAll(fd, &buf);
}

pub fn tcpConnect(host: []const u8, port: u16) !posix.fd_t {
    var host_buf: [256]u8 = undefined;
    if (host.len + 1 > host_buf.len) return error.HostNotFound;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var port_z_buf: [8]u8 = undefined;
    @memcpy(port_z_buf[0..port_text.len], port_text);
    port_z_buf[port_text.len] = 0;

    var hints: posix.system.addrinfo = std.mem.zeroes(posix.system.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = posix.SOCK.STREAM;

    var res: ?*posix.system.addrinfo = null;
    const eai = posix.system.getaddrinfo(@ptrCast(&host_buf), @ptrCast(&port_z_buf), &hints, &res);
    if (@intFromEnum(eai) != 0) return error.HostNotFound;
    defer if (res) |r| posix.system.freeaddrinfo(r);

    var ai_opt: ?*posix.system.addrinfo = res;
    while (ai_opt) |ai| : (ai_opt = ai.next) {
        const fd = posix.system.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
        if (fd < 0) continue;
        errdefer _ = posix.system.close(fd);
        const addr = ai.addr orelse continue;
        if (posix.system.connect(fd, addr, ai.addrlen) == 0) return fd;
        _ = posix.system.close(fd);
    }
    return error.ConnectFailed;
}

pub fn tcpListen(host: []const u8, port: u16) !posix.fd_t {
    var host_buf: [256]u8 = undefined;
    if (host.len + 1 > host_buf.len) return error.HostNotFound;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    var port_buf: [8]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    var port_z_buf: [8]u8 = undefined;
    @memcpy(port_z_buf[0..port_text.len], port_text);
    port_z_buf[port_text.len] = 0;

    var hints: posix.system.addrinfo = std.mem.zeroes(posix.system.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = posix.SOCK.STREAM;
    hints.flags.PASSIVE = true;

    var res: ?*posix.system.addrinfo = null;
    const node: ?[*:0]const u8 = if (host.len == 0 or std.mem.eql(u8, host, "*")) null else @ptrCast(&host_buf);
    const eai = posix.system.getaddrinfo(node, @ptrCast(&port_z_buf), &hints, &res);
    if (@intFromEnum(eai) != 0) return error.HostNotFound;
    defer if (res) |r| posix.system.freeaddrinfo(r);

    var ai_opt: ?*posix.system.addrinfo = res;
    while (ai_opt) |ai| : (ai_opt = ai.next) {
        const fd = posix.system.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
        if (fd < 0) continue;
        errdefer _ = posix.system.close(fd);

        const reuse: c_int = 1;
        _ = posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &reuse, @sizeOf(c_int));

        const addr = ai.addr orelse continue;
        if (posix.system.bind(fd, addr, ai.addrlen) != 0) {
            _ = posix.system.close(fd);
            continue;
        }
        if (posix.system.listen(fd, 16) != 0) {
            _ = posix.system.close(fd);
            continue;
        }
        return fd;
    }
    return error.BindFailed;
}

fn hkdf2(ck: [Hash.digest_length]u8, ikm: []const u8) struct { ck: [Aead.key_length]u8, k: [Aead.key_length]u8 } {
    const prk = Hkdf.extract(&ck, ikm);
    var out: [64]u8 = undefined;
    Hkdf.expand(&out, "", prk);
    return .{
        .ck = out[0..32].*,
        .k = out[32..64].*,
    };
}

fn makeNonce(n: u64) [Aead.nonce_length]u8 {
    var nonce = [_]u8{0} ** Aead.nonce_length;
    const le = std.mem.nativeToLittle(u64, n);
    @memcpy(nonce[4..12], std.mem.asBytes(&le));
    return nonce;
}

fn keyAllowed(remote: PublicKey, allowed: []const PublicKey) bool {
    for (allowed) |candidate| {
        if (std.mem.eql(u8, &remote, &candidate)) return true;
    }
    return false;
}

fn fillRandom(buf: []u8) !void {
    const fd = try posix.openat(posix.AT.FDCWD, "/dev/urandom", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = posix.system.close(fd);

    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.UnexpectedEof;
        off += n;
    }
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8, max_len: usize) ![]u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = posix.system.close(fd);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
        if (out.items.len > max_len) return error.InvalidKeyFile;
    }
    return out.toOwnedSlice(allocator);
}

fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.UnexpectedEof;
        off += n;
    }
}

fn writeAll(fd: posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.system.write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn writeU32Be(buf: *[4]u8, value: u32) void {
    buf[0] = @truncate(value >> 24);
    buf[1] = @truncate(value >> 16);
    buf[2] = @truncate(value >> 8);
    buf[3] = @truncate(value);
}

fn readU32Be(buf: *const [4]u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);
}
