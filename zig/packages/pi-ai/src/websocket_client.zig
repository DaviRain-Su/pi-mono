//! Minimal RFC 6455 WebSocket client.
//!
//! Scope (Mission J, commit 1):
//!   * HTTP/1.1 Upgrade handshake (computes Sec-WebSocket-Accept via SHA-1
//!     + base64 and verifies the server response).
//!   * Reading data/control frames from a server (text, binary, ping, pong,
//!     close, plus opcode 0x0 continuation reassembly).
//!   * Writing client frames with mandatory masking.
//!   * Automatic pong replies to server pings.
//!   * Sending a close frame and observing the server's close echo.
//!
//! Out of scope here: provider wire-up, deflate/permessage-deflate, custom
//! sub-protocols, half-duplex shutdown beyond a single close handshake, and
//! integration with the request abort/timeout watchdogs used by
//! `http_client.zig`. Those land in later Mission J commits.
//!
//! Memory model:
//!   * `Client.next` returns a `Frame` whose payload bytes are allocated
//!     out of the `Client`'s allocator. The caller MUST release each yielded
//!     frame via `Frame.deinit(allocator)` before requesting the next frame.
//!   * Fragmentation reassembly uses an internal `std.ArrayList(u8)`. The
//!     buffer is capped at `Options.max_fragment_bytes` (default 32 MiB);
//!     overflow returns `error.FrameTooLarge`.
//!
//! TLS approach:
//!   * For `wss://`, the client opens a TCP connection, then drives
//!     `std.crypto.tls.Client.init` directly. The integration is intentionally
//!     a small, parallel implementation of the helper inside
//!     `http_client.zig` (~70 LOC) so this module remains standalone for the
//!     first commit. If future commits need to share more transport
//!     machinery, those refactors can lift the helper into a common place.

const std = @import("std");

const Sha1 = std.crypto.hash.Sha1;
const base64 = std.base64.standard;

/// RFC 6455 §1.3 GUID — appended to the client nonce before SHA-1.
pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const CloseInfo = struct {
    code: u16,
    reason: []const u8,
};

/// A frame yielded by `Client.next`. The caller owns the payload bytes; the
/// caller MUST free them with `Frame.deinit(allocator)` before requesting
/// another frame.
pub const Frame = union(enum) {
    text: []u8,
    binary: []u8,
    pong: []u8,
    close: CloseInfo,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        switch (self) {
            .text, .binary, .pong => |bytes| allocator.free(bytes),
            .close => |info| if (info.reason.len > 0) allocator.free(info.reason),
        }
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Error = error{
    InvalidUrl,
    UnsupportedScheme,
    HandshakeFailed,
    InvalidHandshakeResponse,
    InvalidFrame,
    MaskedServerFrame,
    FrameTooLarge,
    InvalidContinuation,
    ConnectionClosed,
    TlsFailure,
};

/// Maximum default size for a reassembled fragment payload. Conservative cap
/// chosen so a malicious server cannot drive the client into unbounded
/// allocation while still leaving room for any legitimate Codex envelope.
pub const default_max_fragment_bytes: usize = 32 * 1024 * 1024;

/// Computes the Sec-WebSocket-Accept value for a given client nonce, per
/// RFC 6455 §4.2.2. The returned slice is owned by `allocator`.
pub fn computeAccept(allocator: std.mem.Allocator, client_key: []const u8) ![]u8 {
    var hasher = Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(WS_GUID);
    var digest: [Sha1.digest_length]u8 = undefined;
    hasher.final(&digest);

    const encoded_len = base64.Encoder.calcSize(digest.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = base64.Encoder.encode(out, &digest);
    return out;
}

/// Random nonce source. Tests substitute `.fixed` to remove non-determinism.
pub const RandomSource = union(enum) {
    io: std.Io,
    fixed_mask: [4]u8,
    fixed_key: [16]u8,

    fn maskBytes(self: RandomSource, out: *[4]u8) void {
        switch (self) {
            .io => |io| io.random(out),
            .fixed_mask => |m| out.* = m,
            .fixed_key => out.* = .{ 0, 0, 0, 0 },
        }
    }

    fn keyBytes(self: RandomSource, out: *[16]u8) void {
        switch (self) {
            .io => |io| io.random(out),
            .fixed_mask => out.* = .{0} ** 16,
            .fixed_key => |k| out.* = k,
        }
    }
};

// -------------------------------------------------------------------------
// Frame parser and writer (low-level, work on any *Reader / *Writer).
// -------------------------------------------------------------------------

const RawFrame = struct {
    fin: bool,
    opcode: u4,
    payload: []u8,

    fn deinit(self: RawFrame, allocator: std.mem.Allocator) void {
        if (self.payload.len > 0) allocator.free(self.payload);
    }
};

/// Reads exactly one WebSocket frame from `reader`. The returned payload is
/// allocated out of `allocator` and owned by the caller. Server frames MUST
/// NOT be masked (RFC 6455 §5.3) — this function rejects masked frames with
/// `error.MaskedServerFrame`.
fn readRawFrame(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_payload: usize,
) !RawFrame {
    const header0 = try reader.takeByte();
    const header1 = try reader.takeByte();

    const fin = (header0 & 0x80) != 0;
    // RFC 6455 reserves bits RSV1..RSV3; without extensions they must be 0.
    if ((header0 & 0x70) != 0) return Error.InvalidFrame;
    const opcode: u4 = @truncate(header0 & 0x0F);

    const masked = (header1 & 0x80) != 0;
    if (masked) return Error.MaskedServerFrame;

    const len_field: u7 = @truncate(header1 & 0x7F);
    const payload_len: u64 = switch (len_field) {
        126 => try reader.takeInt(u16, .big),
        127 => try reader.takeInt(u64, .big),
        else => @as(u64, len_field),
    };

    if (payload_len > max_payload) return Error.FrameTooLarge;
    // Control frames (opcode high bit set) must have payloads of <= 125 and
    // must not be fragmented (RFC 6455 §5.5).
    if ((opcode & 0x8) != 0) {
        if (!fin or payload_len > 125) return Error.InvalidFrame;
    }

    const payload = if (payload_len == 0)
        try allocator.alloc(u8, 0)
    else blk: {
        const buf = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(buf);
        try reader.readSliceAll(buf);
        break :blk buf;
    };

    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// Writes a single WebSocket frame to `writer`. `opcode` may be a data
/// (0x1/0x2) or control opcode (0x8/0x9/0xA); continuation frames (0x0) are
/// not produced by this module (we always send unfragmented client frames).
fn writeFrame(
    writer: *std.Io.Writer,
    opcode: u4,
    payload: []const u8,
    mask: [4]u8,
) !void {
    var header_buf: [14]u8 = undefined;
    var header_len: usize = 0;

    header_buf[0] = 0x80 | @as(u8, opcode); // FIN=1
    if (payload.len < 126) {
        header_buf[1] = 0x80 | @as(u8, @intCast(payload.len)); // mask bit set
        header_len = 2;
    } else if (payload.len <= std.math.maxInt(u16)) {
        header_buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header_buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }
    @memcpy(header_buf[header_len..][0..4], &mask);
    header_len += 4;

    try writer.writeAll(header_buf[0..header_len]);

    if (payload.len > 0) {
        // Mask the payload in fixed-size chunks to avoid allocating an entire
        // copy of large payloads.
        var stack_buf: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < payload.len) {
            const chunk_len = @min(stack_buf.len, payload.len - offset);
            var i: usize = 0;
            while (i < chunk_len) : (i += 1) {
                stack_buf[i] = payload[offset + i] ^ mask[(offset + i) & 0x3];
            }
            try writer.writeAll(stack_buf[0..chunk_len]);
            offset += chunk_len;
        }
    }
    try writer.flush();
}

/// Sends a close frame. Code 1000 is the default normal-closure value per
/// RFC 6455 §7.4.1. Passing `code = 0` produces an empty close payload,
/// which is also valid.
fn sendCloseFrame(
    writer: *std.Io.Writer,
    code: u16,
    reason: []const u8,
    mask: [4]u8,
) !void {
    if (code == 0) {
        try writeFrame(writer, @intFromEnum(Opcode.close), &.{}, mask);
        return;
    }
    if (reason.len > 123) return Error.FrameTooLarge;

    var stack_buf: [125]u8 = undefined;
    std.mem.writeInt(u16, stack_buf[0..2], code, .big);
    if (reason.len > 0) @memcpy(stack_buf[2..][0..reason.len], reason);
    try writeFrame(
        writer,
        @intFromEnum(Opcode.close),
        stack_buf[0 .. 2 + reason.len],
        mask,
    );
}

// -------------------------------------------------------------------------
// Frame decoder: handles fragmentation reassembly + control-frame routing.
// -------------------------------------------------------------------------

/// Stateful frame decoder. Reads from a `*std.Io.Reader`, replies to pings
/// via the supplied `*std.Io.Writer`, reassembles continuation chains, and
/// yields `Frame` values whose payload bytes are owned by the caller.
pub const FrameDecoder = struct {
    allocator: std.mem.Allocator,
    max_fragment_bytes: usize,
    fragment_buf: std.ArrayList(u8) = .empty,
    fragment_opcode: ?u4 = null,
    received_close: bool = false,
    sent_close: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_fragment_bytes: usize) FrameDecoder {
        return .{
            .allocator = allocator,
            .max_fragment_bytes = max_fragment_bytes,
        };
    }

    pub fn deinit(self: *FrameDecoder) void {
        self.fragment_buf.deinit(self.allocator);
    }

    /// Reads frames until a yield-able event occurs. Returns `null` when the
    /// remote side has signaled close and we've replied (i.e. the session
    /// reached half-closed-from-remote).
    pub fn next(
        self: *FrameDecoder,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        random: RandomSource,
    ) !?Frame {
        if (self.received_close) return null;

        while (true) {
            const raw = readRawFrame(self.allocator, reader, self.max_fragment_bytes) catch |err| switch (err) {
                error.EndOfStream => {
                    // Treat clean EOF as remote close without close-frame.
                    self.received_close = true;
                    return null;
                },
                else => return err,
            };
            // We must free `raw.payload` ourselves in branches that copy or
            // ignore it. Branches that hand it to the caller transfer
            // ownership and skip the deinit.
            var raw_owned = true;
            defer if (raw_owned) raw.deinit(self.allocator);

            switch (raw.opcode) {
                @intFromEnum(Opcode.ping) => {
                    var mask: [4]u8 = undefined;
                    random.maskBytes(&mask);
                    try writeFrame(writer, @intFromEnum(Opcode.pong), raw.payload, mask);
                    // continue: pings are not yielded to the caller
                },
                @intFromEnum(Opcode.pong) => {
                    raw_owned = false;
                    return Frame{ .pong = raw.payload };
                },
                @intFromEnum(Opcode.close) => {
                    self.received_close = true;
                    var info: CloseInfo = .{ .code = 1005, .reason = "" };
                    if (raw.payload.len >= 2) {
                        info.code = std.mem.readInt(u16, raw.payload[0..2], .big);
                        if (raw.payload.len > 2) {
                            info.reason = try self.allocator.dupe(u8, raw.payload[2..]);
                        }
                    }
                    if (!self.sent_close) {
                        var mask: [4]u8 = undefined;
                        random.maskBytes(&mask);
                        // Echo back with the same code, empty reason; RFC §7.4
                        // recommends echoing the close code.
                        sendCloseFrame(writer, info.code, "", mask) catch {};
                        self.sent_close = true;
                    }
                    return Frame{ .close = info };
                },
                @intFromEnum(Opcode.text), @intFromEnum(Opcode.binary) => {
                    if (self.fragment_opcode != null) return Error.InvalidContinuation;
                    if (raw.fin) {
                        raw_owned = false;
                        return wrapDataFrame(raw.opcode, raw.payload);
                    }
                    self.fragment_opcode = raw.opcode;
                    try self.appendFragment(raw.payload);
                },
                @intFromEnum(Opcode.continuation) => {
                    if (self.fragment_opcode == null) return Error.InvalidContinuation;
                    try self.appendFragment(raw.payload);
                    if (raw.fin) {
                        const opcode = self.fragment_opcode.?;
                        const payload = try self.fragment_buf.toOwnedSlice(self.allocator);
                        self.fragment_buf = .empty;
                        self.fragment_opcode = null;
                        return wrapDataFrame(opcode, payload);
                    }
                },
                else => return Error.InvalidFrame,
            }
        }
    }

    fn appendFragment(self: *FrameDecoder, bytes: []const u8) !void {
        const new_len = self.fragment_buf.items.len + bytes.len;
        if (new_len > self.max_fragment_bytes) return Error.FrameTooLarge;
        try self.fragment_buf.appendSlice(self.allocator, bytes);
    }

    fn wrapDataFrame(opcode: u4, payload: []u8) Frame {
        return switch (opcode) {
            @intFromEnum(Opcode.text) => .{ .text = payload },
            @intFromEnum(Opcode.binary) => .{ .binary = payload },
            else => unreachable, // caller filters
        };
    }
};

// -------------------------------------------------------------------------
// URL parsing helpers.
// -------------------------------------------------------------------------

const ParsedUrl = struct {
    is_tls: bool,
    host: []const u8, // borrowed from input or scratch
    port: u16,
    path_and_query: []const u8, // includes leading '/'

    fn defaultPort(is_tls: bool) u16 {
        return if (is_tls) 443 else 80;
    }
};

fn parseWsUrl(allocator: std.mem.Allocator, raw: []const u8) !struct {
    parsed: ParsedUrl,
    scratch: []u8, // owned buffer backing the slices above; must be freed
} {
    // We don't fully use std.Uri here because the path slice it returns has
    // unhelpful encoding; for handshake purposes we just need the literal
    // request-target. Do a minimal parse.
    var is_tls: bool = false;
    var rest: []const u8 = raw;

    if (std.mem.startsWith(u8, raw, "ws://")) {
        rest = raw[5..];
    } else if (std.mem.startsWith(u8, raw, "wss://")) {
        is_tls = true;
        rest = raw[6..];
    } else if (std.mem.startsWith(u8, raw, "http://")) {
        rest = raw[7..];
    } else if (std.mem.startsWith(u8, raw, "https://")) {
        is_tls = true;
        rest = raw[8..];
    } else {
        return Error.UnsupportedScheme;
    }

    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..path_start];
    const path_text = if (path_start == rest.len) "/" else rest[path_start..];

    // Authority may be `host:port` or `[ipv6]:port`. Keep it simple:
    // support host:port and bare host.
    var host: []const u8 = authority;
    var port: u16 = ParsedUrl.defaultPort(is_tls);
    if (authority.len > 0 and authority[0] == '[') {
        const end = std.mem.indexOfScalar(u8, authority, ']') orelse return Error.InvalidUrl;
        host = authority[1..end];
        if (end + 1 < authority.len and authority[end + 1] == ':') {
            port = std.fmt.parseInt(u16, authority[end + 2 ..], 10) catch return Error.InvalidUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return Error.InvalidUrl;
    }
    if (host.len == 0) return Error.InvalidUrl;

    // Allocate one buffer for host + path so we can free it together when
    // the Client deinits.
    var scratch = try allocator.alloc(u8, host.len + path_text.len);
    errdefer allocator.free(scratch);
    @memcpy(scratch[0..host.len], host);
    @memcpy(scratch[host.len..], path_text);

    return .{
        .parsed = .{
            .is_tls = is_tls,
            .host = scratch[0..host.len],
            .port = port,
            .path_and_query = scratch[host.len..],
        },
        .scratch = scratch,
    };
}

// -------------------------------------------------------------------------
// Transport layer (TCP + optional TLS).
// -------------------------------------------------------------------------

const TlsState = struct {
    client: std.crypto.tls.Client,
    read_buffer: []u8,
    write_buffer: []u8,
};

const Transport = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    socket_reader: std.Io.net.Stream.Reader,
    socket_writer: std.Io.net.Stream.Writer,
    socket_read_buf: []u8,
    socket_write_buf: []u8,

    tls: ?*TlsState = null,

    fn reader(self: *Transport) *std.Io.Reader {
        if (self.tls) |t| return &t.client.reader;
        return &self.socket_reader.interface;
    }

    fn writer(self: *Transport) *std.Io.Writer {
        if (self.tls) |t| return &t.client.writer;
        return &self.socket_writer.interface;
    }

    fn deinit(self: *Transport, allocator: std.mem.Allocator) void {
        if (self.tls) |t| {
            allocator.free(t.read_buffer);
            allocator.free(t.write_buffer);
            allocator.destroy(t);
            self.tls = null;
        }
        self.stream.close(self.io);
        allocator.free(self.socket_read_buf);
        allocator.free(self.socket_write_buf);
    }
};

const tcp_buffer_bytes: usize = 16 * 1024;
const tls_read_extra_bytes: usize = 16 * 1024;

fn socketBufferBytes(is_tls: bool) usize {
    return if (is_tls)
        @max(tcp_buffer_bytes, std.crypto.tls.Client.min_buffer_len)
    else
        tcp_buffer_bytes;
}

fn resolveHostAddress(
    io: std.Io,
    host: []const u8,
    port: u16,
) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |addr| return addr else |_| {}

    if (std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "localhost."))
    {
        return .{ .ip4 = .loopback(port) };
    }

    // DNS lookup. Use a small inline queue; getaddrinfo-style failures
    // surface as `Error.InvalidUrl`.
    var slots: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&slots);
    const host_name = std.Io.net.HostName.init(host) catch return Error.InvalidUrl;
    host_name.lookup(io, &queue, .{ .port = port }) catch return Error.InvalidUrl;

    while (true) {
        var item: [1]std.Io.net.HostName.LookupResult = undefined;
        const n = queue.get(io, &item, 1) catch return Error.InvalidUrl;
        if (n == 0) return Error.InvalidUrl;
        switch (item[0]) {
            .address => |addr| {
                var resolved = addr;
                switch (resolved) {
                    .ip4 => |*a| a.port = port,
                    .ip6 => |*a| a.port = port,
                }
                return resolved;
            },
            .canonical_name => continue,
        }
    }
}

fn openTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedUrl,
) !Transport {
    const address = try resolveHostAddress(io, parsed.host, parsed.port);

    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .timeout = .none }) catch {
        return Error.HandshakeFailed;
    };
    errdefer stream.close(io);

    const socket_buffer_bytes = socketBufferBytes(parsed.is_tls);
    const sock_read = try allocator.alloc(u8, socket_buffer_bytes);
    errdefer allocator.free(sock_read);
    const sock_write = try allocator.alloc(u8, socket_buffer_bytes);
    errdefer allocator.free(sock_write);

    var transport: Transport = .{
        .io = io,
        .stream = stream,
        .socket_reader = stream.reader(io, sock_read),
        .socket_writer = stream.writer(io, sock_write),
        .socket_read_buf = sock_read,
        .socket_write_buf = sock_write,
    };

    if (parsed.is_tls) {
        if (std.http.Client.disable_tls) return Error.TlsFailure;

        const tls_read_buf = try allocator.alloc(
            u8,
            std.crypto.tls.Client.min_buffer_len + tls_read_extra_bytes,
        );
        errdefer allocator.free(tls_read_buf);
        const tls_write_buf = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
        errdefer allocator.free(tls_write_buf);

        const state = try allocator.create(TlsState);
        errdefer allocator.destroy(state);

        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(allocator);
        var ca_lock: std.Io.RwLock = .init;
        bundle.rescan(allocator, io, std.Io.Clock.real.now(io)) catch return Error.TlsFailure;

        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);

        state.* = .{
            .client = std.crypto.tls.Client.init(
                &transport.socket_reader.interface,
                &transport.socket_writer.interface,
                .{
                    .host = .{ .explicit = parsed.host },
                    .ca = .{ .bundle = .{
                        .gpa = allocator,
                        .io = io,
                        .lock = &ca_lock,
                        .bundle = &bundle,
                    } },
                    .read_buffer = tls_read_buf,
                    .write_buffer = tls_write_buf,
                    .entropy = &entropy,
                    .realtime_now = std.Io.Clock.real.now(io),
                    .allow_truncation_attacks = true,
                },
            ) catch return Error.TlsFailure,
            .read_buffer = tls_read_buf,
            .write_buffer = tls_write_buf,
        };
        transport.tls = state;
    }

    return transport;
}

// -------------------------------------------------------------------------
// Handshake.
// -------------------------------------------------------------------------

fn generateClientKey(random: RandomSource, allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    random.keyBytes(&raw);
    const encoded_len = base64.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = base64.Encoder.encode(out, &raw);
    return out;
}

fn sendHandshake(
    writer: *std.Io.Writer,
    host_header: []const u8,
    path_and_query: []const u8,
    client_key: []const u8,
    extra_headers: []const Header,
) !void {
    try writer.print(
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n",
        .{ path_and_query, host_header, client_key },
    );
    for (extra_headers) |h| {
        try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try writer.writeAll("\r\n");
    try writer.flush();
}

fn readHandshakeResponse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_accept: []const u8,
) !void {
    // Status line: "HTTP/1.1 101 ..."
    const status_line = try takeHeaderLine(allocator, reader);
    defer allocator.free(status_line);
    const status_iter = std.mem.splitScalar(u8, status_line, ' ');
    var it = status_iter;
    _ = it.next() orelse return Error.InvalidHandshakeResponse; // version
    const status_text = it.next() orelse return Error.InvalidHandshakeResponse;
    const status = std.fmt.parseInt(u16, status_text, 10) catch return Error.InvalidHandshakeResponse;
    if (status != 101) return Error.HandshakeFailed;

    var saw_upgrade = false;
    var saw_connection = false;
    var saw_accept = false;
    while (true) {
        const line = try takeHeaderLine(allocator, reader);
        defer allocator.free(line);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            if (std.ascii.eqlIgnoreCase(value, "websocket")) saw_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            // The value may be comma-separated.
            var parts = std.mem.splitScalar(u8, value, ',');
            while (parts.next()) |part| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), "upgrade")) saw_connection = true;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            if (std.mem.eql(u8, value, expected_accept)) saw_accept = true;
        }
    }
    if (!saw_upgrade or !saw_connection or !saw_accept) return Error.InvalidHandshakeResponse;
}

fn takeHeaderLine(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (true) {
        const b = try reader.takeByte();
        if (b == '\r') {
            const next = try reader.takeByte();
            if (next != '\n') return Error.InvalidHandshakeResponse;
            break;
        }
        // Cap header line length to avoid unbounded growth on a malicious server.
        if (buf.items.len >= 8192) return Error.InvalidHandshakeResponse;
        try buf.append(allocator, b);
    }
    return buf.toOwnedSlice(allocator);
}

// -------------------------------------------------------------------------
// Public Client API.
// -------------------------------------------------------------------------

pub const ConnectOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const Header = &.{},
    max_fragment_bytes: usize = default_max_fragment_bytes,
    /// Test-only seam: replaces the random source used for the client key
    /// and per-frame masks. Production callers should leave this null.
    random: ?RandomSource = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    url_scratch: []u8,
    transport: Transport,
    decoder: FrameDecoder,
    random: RandomSource,

    pub fn connect(opts: ConnectOptions) !Client {
        const parsed_result = try parseWsUrl(opts.allocator, opts.url);
        errdefer opts.allocator.free(parsed_result.scratch);

        var transport = try openTransport(opts.allocator, opts.io, parsed_result.parsed);
        errdefer transport.deinit(opts.allocator);

        const random = opts.random orelse RandomSource{ .io = opts.io };

        const client_key = try generateClientKey(random, opts.allocator);
        defer opts.allocator.free(client_key);
        const expected_accept = try computeAccept(opts.allocator, client_key);
        defer opts.allocator.free(expected_accept);

        // Format Host header: include port if non-default.
        var host_header_buf: [256]u8 = undefined;
        const default_port: u16 = if (parsed_result.parsed.is_tls) 443 else 80;
        const host_header = if (parsed_result.parsed.port == default_port)
            try std.fmt.bufPrint(&host_header_buf, "{s}", .{parsed_result.parsed.host})
        else
            try std.fmt.bufPrint(&host_header_buf, "{s}:{d}", .{ parsed_result.parsed.host, parsed_result.parsed.port });

        try sendHandshake(
            transport.writer(),
            host_header,
            parsed_result.parsed.path_and_query,
            client_key,
            opts.headers,
        );
        try readHandshakeResponse(opts.allocator, transport.reader(), expected_accept);

        return .{
            .allocator = opts.allocator,
            .io = opts.io,
            .url_scratch = parsed_result.scratch,
            .transport = transport,
            .decoder = FrameDecoder.init(opts.allocator, opts.max_fragment_bytes),
            .random = random,
        };
    }

    pub fn deinit(self: *Client) void {
        self.decoder.deinit();
        self.transport.deinit(self.allocator);
        self.allocator.free(self.url_scratch);
    }

    pub fn sendText(self: *Client, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        self.random.maskBytes(&mask);
        try writeFrame(self.transport.writer(), @intFromEnum(Opcode.text), payload, mask);
    }

    pub fn sendBinary(self: *Client, payload: []const u8) !void {
        var mask: [4]u8 = undefined;
        self.random.maskBytes(&mask);
        try writeFrame(self.transport.writer(), @intFromEnum(Opcode.binary), payload, mask);
    }

    pub fn sendClose(self: *Client, code: u16, reason: []const u8) !void {
        if (self.decoder.sent_close) return;
        var mask: [4]u8 = undefined;
        self.random.maskBytes(&mask);
        try sendCloseFrame(self.transport.writer(), code, reason, mask);
        self.decoder.sent_close = true;
    }

    pub fn next(self: *Client) !?Frame {
        return self.decoder.next(self.transport.reader(), self.transport.writer(), self.random);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "computeAccept matches RFC 6455 example" {
    const allocator = std.testing.allocator;
    const accept = try computeAccept(allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer allocator.free(accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "frame reader decodes single unmasked text frame" {
    // Server-sent text frame for "Hello": 0x81 (FIN+text), len=5, payload
    const bytes = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
    var r = std.Io.Reader.fixed(&bytes);

    var decoder = FrameDecoder.init(std.testing.allocator, default_max_fragment_bytes);
    defer decoder.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const frame_opt = try decoder.next(
        &r,
        &aw.writer,
        RandomSource{ .fixed_mask = .{ 0, 0, 0, 0 } },
    );
    try std.testing.expect(frame_opt != null);
    var frame = frame_opt.?;
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Hello", frame.text);
    try std.testing.expectEqual(@as(usize, 0), aw.writer.end);
}

test "frame reader decodes 16-bit-length frame" {
    // Build a 200-byte text frame.
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 200);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.append(allocator, 0x81); // FIN + text
    try bytes.append(allocator, 126);
    try bytes.appendSlice(allocator, &[_]u8{ 0x00, 0xC8 }); // 200, big-endian
    try bytes.appendSlice(allocator, payload);

    var r = std.Io.Reader.fixed(bytes.items);
    var decoder = FrameDecoder.init(allocator, default_max_fragment_bytes);
    defer decoder.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const frame_opt = try decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = .{ 0, 0, 0, 0 } });
    try std.testing.expect(frame_opt != null);
    var frame = frame_opt.?;
    defer frame.deinit(allocator);
    try std.testing.expectEqualSlices(u8, payload, frame.text);
}

test "frame reader decodes fragmented text across three frames" {
    // frame 1: text, FIN=0, "Hel"
    // frame 2: cont, FIN=0, "lo, "
    // frame 3: cont, FIN=1, "world"
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &[_]u8{ 0x01, 0x03, 'H', 'e', 'l' });
    try bytes.appendSlice(allocator, &[_]u8{ 0x00, 0x04, 'l', 'o', ',', ' ' });
    try bytes.appendSlice(allocator, &[_]u8{ 0x80, 0x05, 'w', 'o', 'r', 'l', 'd' });

    var r = std.Io.Reader.fixed(bytes.items);
    var decoder = FrameDecoder.init(allocator, default_max_fragment_bytes);
    defer decoder.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const frame_opt = try decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = .{ 0, 0, 0, 0 } });
    try std.testing.expect(frame_opt != null);
    var frame = frame_opt.?;
    defer frame.deinit(allocator);
    try std.testing.expectEqualStrings("Hello, world", frame.text);
}

test "frame reader auto-replies pong to ping" {
    // ping frame: 0x89, len=4, payload=ABCD; then text "ok"
    const bytes = [_]u8{
        0x89, 0x04, 'A', 'B', 'C', 'D',
        0x81, 0x02, 'o', 'k',
    };
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed(&bytes);
    var decoder = FrameDecoder.init(allocator, default_max_fragment_bytes);
    defer decoder.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fixed_mask: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };
    const frame_opt = try decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = fixed_mask });
    try std.testing.expect(frame_opt != null);
    var frame = frame_opt.?;
    defer frame.deinit(allocator);
    try std.testing.expectEqualStrings("ok", frame.text);

    // The decoder should have written a pong (0x8A | 0x80) to the writer.
    const written = aw.writer.buffered();
    try std.testing.expect(written.len >= 6);
    try std.testing.expectEqual(@as(u8, 0x8A), written[0]); // FIN + pong
    try std.testing.expectEqual(@as(u8, 0x80 | 4), written[1]); // mask bit + len=4
    try std.testing.expectEqualSlices(u8, &fixed_mask, written[2..6]);
    // Payload XOR mask should equal "ABCD".
    var decoded: [4]u8 = undefined;
    for (written[6..10], 0..) |b, i| decoded[i] = b ^ fixed_mask[i & 3];
    try std.testing.expectEqualSlices(u8, "ABCD", &decoded);
}

test "frame reader handles close frame with code+reason" {
    // close frame: 0x88, len=8, code=1000, reason="bye-bye"
    const bytes = [_]u8{
        0x88, 0x09, 0x03, 0xE8, 'b', 'y', 'e', '-', 'b', 'y', 'e',
    };
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed(&bytes);
    var decoder = FrameDecoder.init(allocator, default_max_fragment_bytes);
    defer decoder.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const frame_opt = try decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = .{ 1, 2, 3, 4 } });
    try std.testing.expect(frame_opt != null);
    var frame = frame_opt.?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 1000), frame.close.code);
    try std.testing.expectEqualStrings("bye-bye", frame.close.reason);

    // Decoder should have echoed a close frame to the writer.
    const written = aw.writer.buffered();
    try std.testing.expect(written.len >= 6);
    try std.testing.expectEqual(@as(u8, 0x88), written[0]); // FIN + close
    // Subsequent next() returns null.
    const after = try decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = .{ 0, 0, 0, 0 } });
    try std.testing.expectEqual(@as(?Frame, null), after);
}

test "frame reader rejects masked server frame" {
    const bytes = [_]u8{ 0x81, 0x85, 0xAA, 0xBB, 0xCC, 0xDD, 'a', 'b', 'c', 'd', 'e' };
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed(&bytes);
    var decoder = FrameDecoder.init(allocator, default_max_fragment_bytes);
    defer decoder.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.testing.expectError(
        Error.MaskedServerFrame,
        decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = .{ 0, 0, 0, 0 } }),
    );
}

test "frame writer masks payload and round-trips through reader" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const mask: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    try writeFrame(&aw.writer, @intFromEnum(Opcode.text), "hello there", mask);

    const written = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 2 + 4 + 11), written.len);
    try std.testing.expectEqual(@as(u8, 0x81), written[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 0x80 | 11), written[1]); // mask + len
    try std.testing.expectEqualSlices(u8, &mask, written[2..6]);

    // XOR back and compare to original.
    var unmasked: [11]u8 = undefined;
    for (written[6..17], 0..) |b, i| unmasked[i] = b ^ mask[i & 3];
    try std.testing.expectEqualSlices(u8, "hello there", &unmasked);
}

test "FrameDecoder enforces fragment cap" {
    const allocator = std.testing.allocator;
    // Build a text fragment whose first piece exceeds the cap.
    const cap: usize = 64;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    // FIN=0, text, 16-bit len
    try bytes.appendSlice(allocator, &[_]u8{ 0x01, 126 });
    const payload_len: u16 = 100;
    try bytes.appendSlice(allocator, &[_]u8{ 0x00, 0x64 }); // 100
    try bytes.appendNTimes(allocator, 'x', payload_len);

    var r = std.Io.Reader.fixed(bytes.items);
    var decoder = FrameDecoder.init(allocator, cap);
    defer decoder.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.testing.expectError(
        Error.FrameTooLarge,
        decoder.next(&r, &aw.writer, RandomSource{ .fixed_mask = .{ 0, 0, 0, 0 } }),
    );
}

test "parseWsUrl ws and wss scheme handling" {
    const allocator = std.testing.allocator;

    {
        const r = try parseWsUrl(allocator, "ws://example.com/socket");
        defer allocator.free(r.scratch);
        try std.testing.expectEqual(false, r.parsed.is_tls);
        try std.testing.expectEqualStrings("example.com", r.parsed.host);
        try std.testing.expectEqual(@as(u16, 80), r.parsed.port);
        try std.testing.expectEqualStrings("/socket", r.parsed.path_and_query);
    }
    {
        const r = try parseWsUrl(allocator, "wss://api.example.com:8443/realtime?x=1");
        defer allocator.free(r.scratch);
        try std.testing.expectEqual(true, r.parsed.is_tls);
        try std.testing.expectEqualStrings("api.example.com", r.parsed.host);
        try std.testing.expectEqual(@as(u16, 8443), r.parsed.port);
        try std.testing.expectEqualStrings("/realtime?x=1", r.parsed.path_and_query);
    }
    {
        // Bare host -> default path "/".
        const r = try parseWsUrl(allocator, "ws://localhost");
        defer allocator.free(r.scratch);
        try std.testing.expectEqualStrings("localhost", r.parsed.host);
        try std.testing.expectEqualStrings("/", r.parsed.path_and_query);
    }
    {
        try std.testing.expectError(Error.UnsupportedScheme, parseWsUrl(allocator, "ftp://x/"));
    }
}

test "TLS socket buffer satisfies std crypto tls client minimum" {
    try std.testing.expect(socketBufferBytes(false) == tcp_buffer_bytes);
    try std.testing.expect(socketBufferBytes(true) >= std.crypto.tls.Client.min_buffer_len);
}

test "sendCloseFrame writes well-formed close payload" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const mask: [4]u8 = .{ 0, 0, 0, 0 };
    try sendCloseFrame(&aw.writer, 1000, "ok", mask);

    const written = aw.writer.buffered();
    try std.testing.expectEqual(@as(u8, 0x88), written[0]);
    try std.testing.expectEqual(@as(u8, 0x80 | 4), written[1]); // mask + 4 bytes
    // payload bytes (after unmask) = [0x03, 0xE8, 'o', 'k']
    try std.testing.expectEqual(@as(u8, 0x03), written[6]);
    try std.testing.expectEqual(@as(u8, 0xE8), written[7]);
    try std.testing.expectEqual(@as(u8, 'o'), written[8]);
    try std.testing.expectEqual(@as(u8, 'k'), written[9]);
}
