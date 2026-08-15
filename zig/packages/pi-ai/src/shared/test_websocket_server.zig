//! Test-only WebSocket server harness, parallel to `TestStatusServer`.
//!
//! Listens on a loopback TCP port (random, OS-chosen) and accepts up to
//! `Config.max_connections` sequential client connections. For each
//! connection it performs the RFC 6455 upgrade handshake (or rejects it
//! with a caller-specified HTTP status), then executes a scripted sequence
//! of expect/send/close steps. The script can be supplied directly via
//! `Config.script` / `Config.per_connection_scripts`, or implicitly via the
//! legacy `frames_to_send` + `capture_first_client_frame` +
//! `close_after_frames` fields (which are converted to a script at start
//! time).
//!
//! Used by the Mission J integration tests for `websocket_client.zig`.

const std = @import("std");
const websocket_client = @import("../websocket_client.zig");

pub const ExpectedHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const CloseInfo = struct {
    code: u16,
    reason: []const u8 = "",
};

/// One server-driven frame to write to the client after the handshake.
/// Server frames are unmasked (RFC 6455 §5.3).
pub const FrameDirective = union(enum) {
    text: []const u8,
    binary: []const u8,
    ping: []const u8,
    /// Send a close frame with the given code and reason.
    close: CloseInfo,
    /// Send arbitrary, pre-encoded bytes (for malformed-frame tests).
    raw_bytes: []const u8,
};

/// A single scripted step on the server side of a connection. Steps are
/// executed in order; if any step fails (I/O, validator, etc.) the
/// connection is torn down silently — tests assert on the client side.
pub const Step = union(enum) {
    /// Read one text/binary frame from the client, capture its payload,
    /// and optionally validate the payload. If the validator returns
    /// false, the step fails.
    expect_client_frame: struct {
        payload_validator: ?*const fn ([]const u8) bool = null,
    },
    /// Write the listed frames to the client in order.
    send_frames: []const FrameDirective,
    /// Read frames from the client until a close frame arrives. Captured
    /// data frames are appended to `captured_frames`.
    wait_close,
    /// Send a server-initiated close frame.
    close: CloseInfo,
};

pub const Config = struct {
    /// If set, the server validates the request-line path and returns 404 if
    /// it doesn't match.
    expected_path: ?[]const u8 = null,
    /// Headers that MUST be present (case-insensitive name match, exact
    /// value match). If any check fails, the server responds with 400 and
    /// closes.
    expected_headers: []const ExpectedHeader = &.{},
    /// Legacy: if true, the server reads exactly one text/binary frame from
    /// the client after the handshake and stores its payload for
    /// `capturedFrame()`. Ignored if `script` or `per_connection_scripts` is
    /// set.
    capture_first_client_frame: bool = false,
    /// Legacy: pre-encoded frames the server sends after the handshake, in
    /// order. Ignored if `script` or `per_connection_scripts` is set.
    frames_to_send: []const FrameDirective = &.{},
    /// Legacy: if non-null, the server sends a final close frame with this
    /// info after `frames_to_send`. Ignored if `script` or
    /// `per_connection_scripts` is set.
    close_after_frames: ?CloseInfo = null,
    /// If set, the server skips the 101 upgrade entirely and instead sends
    /// a minimal HTTP error response with this status code. Useful for
    /// testing the client's HandshakeFailed error path.
    reject_with_status: ?u16 = null,
    /// Optional script run once per connection. Overrides the legacy
    /// frames_to_send / capture_first_client_frame / close_after_frames
    /// fields. If null, falls back to a synthesized script from those
    /// legacy fields.
    script: ?[]const Step = null,
    /// Optional per-connection scripts. The Nth connection runs the script
    /// at index `N % per_connection_scripts.len`. Overrides `script`.
    per_connection_scripts: ?[]const []const Step = null,
    /// Maximum number of sequential connections the server will accept
    /// before exiting. Default 1 preserves single-connection semantics.
    max_connections: usize = 1,
};

pub const TestWebSocketServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    config: Config,
    thread: ?std.Thread = null,
    captured_frames: std.ArrayList([]u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !TestWebSocketServer {
        return .{
            .allocator = allocator,
            .io = io,
            .server = try std.Io.net.IpAddress.listen(
                &.{ .ip4 = .loopback(0) },
                io,
                .{ .reuse_address = true },
            ),
            .config = config,
        };
    }

    pub fn start(self: *TestWebSocketServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *TestWebSocketServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
        for (self.captured_frames.items) |bytes| self.allocator.free(bytes);
        self.captured_frames.deinit(self.allocator);
    }

    pub fn url(self: *const TestWebSocketServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "ws://127.0.0.1:{d}{s}",
            .{
                self.server.socket.address.getPort(),
                if (self.config.expected_path) |p| p else "/",
            },
        );
    }

    /// Returns the payload of the first text/binary frame captured by any
    /// `expect_client_frame` / `wait_close` step (or by the legacy
    /// `capture_first_client_frame` flag), or null if none were captured.
    /// Callers must drain the WS conversation (or call `awaitDone`) before
    /// reading this — captured state is only stable once the server
    /// thread has joined.
    pub fn capturedFrame(self: *const TestWebSocketServer) ?[]const u8 {
        if (self.captured_frames.items.len == 0) return null;
        return self.captured_frames.items[0];
    }

    /// Returns all captured client frames in arrival order, across all
    /// connections. The returned slice and its elements are owned by the
    /// server and freed in `deinit`. Same caller contract as
    /// `capturedFrame`.
    pub fn capturedFrames(self: *const TestWebSocketServer) []const []u8 {
        return self.captured_frames.items;
    }

    /// Joins the server thread so all writes/reads on the server side have
    /// completed. Safe to call once. After this returns, captured state is
    /// stable.
    pub fn awaitDone(self: *TestWebSocketServer) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    // ---------------------------------------------------------------------
    // Internals.
    // ---------------------------------------------------------------------

    fn run(self: *TestWebSocketServer) void {
        var conn_index: usize = 0;
        while (conn_index < self.config.max_connections) : (conn_index += 1) {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => std.debug.panic("test websocket server accept failed: {}", .{err}),
            };
            defer stream.close(self.io);

            self.handleConnection(stream, conn_index) catch |err| switch (err) {
                // Treat any I/O / protocol failure during the conversation
                // as benign — tests assert on the client side, and the
                // server side just needs to clean up. We deliberately
                // don't panic on these.
                else => {},
            };
        }
    }

    fn handleConnection(
        self: *TestWebSocketServer,
        stream: std.Io.net.Stream,
        conn_index: usize,
    ) !void {
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);

        const request = try readRequestHead(self.allocator, &reader.interface);
        defer self.allocator.free(request.bytes);

        if (self.config.reject_with_status) |status| {
            try writeRejectionResponse(&writer.interface, status);
            return;
        }

        if (self.config.expected_path) |expected| {
            if (!std.mem.eql(u8, request.path, expected)) {
                try writeRejectionResponse(&writer.interface, 404);
                return;
            }
        }

        for (self.config.expected_headers) |expected| {
            const value = findHeader(request.bytes, expected.name) orelse {
                try writeRejectionResponse(&writer.interface, 400);
                return;
            };
            if (!std.mem.eql(u8, value, expected.value)) {
                try writeRejectionResponse(&writer.interface, 400);
                return;
            }
        }

        const client_key = findHeader(request.bytes, "Sec-WebSocket-Key") orelse {
            try writeRejectionResponse(&writer.interface, 400);
            return;
        };

        const accept = try websocket_client.computeAccept(self.allocator, client_key);
        defer self.allocator.free(accept);

        try writer.interface.print(
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        try writer.interface.flush();

        try self.runScript(&reader.interface, &writer.interface, conn_index);
    }

    fn runScript(
        self: *TestWebSocketServer,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        conn_index: usize,
    ) !void {
        if (self.config.per_connection_scripts) |scripts| {
            if (scripts.len == 0) return;
            const script = scripts[conn_index % scripts.len];
            try self.executeSteps(reader, writer, script);
            return;
        }
        if (self.config.script) |script| {
            try self.executeSteps(reader, writer, script);
            return;
        }
        try self.executeLegacy(reader, writer);
    }

    fn executeSteps(
        self: *TestWebSocketServer,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        steps: []const Step,
    ) !void {
        for (steps) |step| {
            switch (step) {
                .expect_client_frame => |spec| {
                    const payload = try readClientDataFrame(self.allocator, reader);
                    errdefer self.allocator.free(payload);
                    if (spec.payload_validator) |validate| {
                        if (!validate(payload)) return error.ClientFrameRejected;
                    }
                    try self.captured_frames.append(self.allocator, payload);
                },
                .send_frames => |frames| {
                    for (frames) |directive| try writeDirective(writer, directive);
                },
                .wait_close => {
                    while (true) {
                        const result = readClientFrameAny(self.allocator, reader);
                        if (result) |outcome| {
                            switch (outcome) {
                                .data => |bytes| try self.captured_frames.append(self.allocator, bytes),
                                .close => return,
                            }
                        } else |err| {
                            return err;
                        }
                    }
                },
                .close => |info| try writeServerCloseFrame(writer, info.code, info.reason),
            }
        }
    }

    fn executeLegacy(
        self: *TestWebSocketServer,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) !void {
        if (self.config.capture_first_client_frame) {
            if (readClientDataFrame(self.allocator, reader)) |bytes| {
                try self.captured_frames.append(self.allocator, bytes);
            } else |_| {}
        }

        for (self.config.frames_to_send) |directive| {
            try writeDirective(writer, directive);
        }

        if (self.config.close_after_frames) |info| {
            try writeServerCloseFrame(writer, info.code, info.reason);
        }
    }

    const RequestHead = struct {
        bytes: []u8,
        path: []const u8, // borrowed from bytes
    };

    fn readRequestHead(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) !RequestHead {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var tail: [4]u8 = .{ 0, 0, 0, 0 };
        var count: usize = 0;
        while (true) {
            const byte = try reader.takeByte();
            try buf.append(allocator, byte);
            tail[count % tail.len] = byte;
            count += 1;
            // Cap to prevent unbounded growth on a misbehaving client.
            if (buf.items.len > 16 * 1024) return error.RequestHeaderTooLarge;
            if (count >= 4) {
                const start_idx = count % tail.len;
                const ordered = [_]u8{
                    tail[start_idx],
                    tail[(start_idx + 1) % tail.len],
                    tail[(start_idx + 2) % tail.len],
                    tail[(start_idx + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }

        const bytes = try buf.toOwnedSlice(allocator);
        errdefer allocator.free(bytes);

        // Request line: "GET <path> HTTP/1.1\r\n..."
        const line_end = std.mem.indexOfScalar(u8, bytes, '\r') orelse return error.MalformedRequest;
        const line = bytes[0..line_end];
        if (!std.mem.startsWith(u8, line, "GET ")) return error.MalformedRequest;
        const rest = line[4..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MalformedRequest;
        const path = rest[0..space];

        return .{ .bytes = bytes, .path = path };
    }

    fn findHeader(request: []const u8, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        _ = lines.next(); // skip request line
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const lname = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(lname, name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }

    fn writeRejectionResponse(writer: *std.Io.Writer, status: u16) !void {
        const reason: []const u8 = switch (status) {
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            else => "Error",
        };
        try writer.print(
            "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ status, reason },
        );
        try writer.flush();
    }

    /// Reads one masked client data frame (text or binary) and returns its
    /// unmasked payload, allocated out of `allocator`. Control frames are
    /// skipped; fragmentation is NOT supported here (tests send single
    /// unfragmented frames). Returns `error.UnexpectedClose` if the client
    /// sends a close frame instead.
    fn readClientDataFrame(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) ![]u8 {
        while (true) {
            const outcome = try readClientFrameAny(allocator, reader);
            switch (outcome) {
                .data => |bytes| return bytes,
                .close => return error.UnexpectedClose,
            }
        }
    }

    const ClientFrameOutcome = union(enum) {
        data: []u8,
        close,
    };

    /// Like `readClientDataFrame`, but instead of returning
    /// `error.UnexpectedClose` when a close frame is observed, yields a
    /// `.close` outcome so callers (e.g. `wait_close`) can terminate
    /// gracefully.
    fn readClientFrameAny(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) !ClientFrameOutcome {
        while (true) {
            const header0 = try reader.takeByte();
            const header1 = try reader.takeByte();
            const fin = (header0 & 0x80) != 0;
            const opcode: u4 = @truncate(header0 & 0x0F);
            const masked = (header1 & 0x80) != 0;
            const len_field: u7 = @truncate(header1 & 0x7F);
            const payload_len: u64 = switch (len_field) {
                126 => try reader.takeInt(u16, .big),
                127 => try reader.takeInt(u64, .big),
                else => @as(u64, len_field),
            };

            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) try reader.readSliceAll(mask[0..]);

            const payload = try allocator.alloc(u8, @intCast(payload_len));
            errdefer allocator.free(payload);
            if (payload.len > 0) try reader.readSliceAll(payload);
            if (masked) {
                for (payload, 0..) |*b, i| b.* ^= mask[i & 3];
            }

            if (fin and (opcode == 0x1 or opcode == 0x2)) return .{ .data = payload };
            if (opcode == 0x8) {
                allocator.free(payload);
                return .close;
            }
            allocator.free(payload);
        }
    }

    fn writeDirective(
        writer: *std.Io.Writer,
        directive: FrameDirective,
    ) !void {
        switch (directive) {
            .text => |bytes| try writeServerFrame(writer, 0x1, bytes),
            .binary => |bytes| try writeServerFrame(writer, 0x2, bytes),
            .ping => |bytes| try writeServerFrame(writer, 0x9, bytes),
            .close => |info| try writeServerCloseFrame(writer, info.code, info.reason),
            .raw_bytes => |bytes| {
                try writer.writeAll(bytes);
                try writer.flush();
            },
        }
    }

    /// Writes a single UNMASKED server frame. Server frames must not be
    /// masked (RFC 6455 §5.3).
    fn writeServerFrame(
        writer: *std.Io.Writer,
        opcode: u4,
        payload: []const u8,
    ) !void {
        var header_buf: [10]u8 = undefined;
        var header_len: usize = 0;

        header_buf[0] = 0x80 | @as(u8, opcode); // FIN=1, no RSV
        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len); // mask bit clear
            header_len = 2;
        } else if (payload.len <= std.math.maxInt(u16)) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        try writer.writeAll(header_buf[0..header_len]);
        if (payload.len > 0) try writer.writeAll(payload);
        try writer.flush();
    }

    fn writeServerCloseFrame(
        writer: *std.Io.Writer,
        code: u16,
        reason: []const u8,
    ) !void {
        if (reason.len > 123) return error.CloseReasonTooLong;
        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        if (reason.len > 0) @memcpy(buf[2..][0..reason.len], reason);
        try writeServerFrame(writer, 0x8, buf[0 .. 2 + reason.len]);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "TestWebSocketServer accepts upgrade and sends canned text frames" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const frames = [_]FrameDirective{
        .{ .text = "hello" },
        .{ .text = "world" },
    };
    var server = try TestWebSocketServer.init(allocator, io, .{
        .frames_to_send = &frames,
        .close_after_frames = .{ .code = 1000, .reason = "bye" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    var client = try websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    defer client.deinit();

    // First text frame.
    {
        const f = (try client.next()).?;
        defer f.deinit(allocator);
        try std.testing.expectEqualStrings("hello", f.text);
    }
    // Second text frame.
    {
        const f = (try client.next()).?;
        defer f.deinit(allocator);
        try std.testing.expectEqualStrings("world", f.text);
    }
    // Server close.
    {
        const f = (try client.next()).?;
        defer f.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 1000), f.close.code);
        try std.testing.expectEqualStrings("bye", f.close.reason);
    }
    // After close, the decoder should yield null.
    try std.testing.expect((try client.next()) == null);
}

test "TestWebSocketServer captures first client text frame" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestWebSocketServer.init(allocator, io, .{
        .capture_first_client_frame = true,
        .close_after_frames = .{ .code = 1000, .reason = "" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    var client = try websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    defer client.deinit();

    try client.sendText("ping from client");

    // Drain frames until we observe the server-driven close so the server
    // thread completes before we read `capturedFrame`.
    while (try client.next()) |frame| {
        defer frame.deinit(allocator);
        if (frame == .close) break;
    }
    server.awaitDone();
    const captured = server.capturedFrame() orelse return error.TestExpectedCapturedFrame;
    try std.testing.expectEqualStrings("ping from client", captured);
}

test "TestWebSocketServer rejects upgrade with custom status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestWebSocketServer.init(allocator, io, .{
        .reject_with_status = 403,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    const result = websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    try std.testing.expectError(websocket_client.Error.HandshakeFailed, result);
}

test "TestWebSocketServer handles multiple sequential connections" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const conn_a_frames = [_]FrameDirective{.{ .text = "conn-a" }};
    const conn_b_frames = [_]FrameDirective{.{ .text = "conn-b" }};
    const script_a = [_]Step{
        .{ .send_frames = &conn_a_frames },
        .{ .close = .{ .code = 1000, .reason = "a" } },
    };
    const script_b = [_]Step{
        .{ .send_frames = &conn_b_frames },
        .{ .close = .{ .code = 1000, .reason = "b" } },
    };
    const scripts = [_][]const Step{ &script_a, &script_b };

    var server = try TestWebSocketServer.init(allocator, io, .{
        .per_connection_scripts = &scripts,
        .max_connections = 2,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    const expected = [_][]const u8{ "conn-a", "conn-b" };
    for (expected) |expected_text| {
        var client = try websocket_client.Client.connect(.{
            .allocator = allocator,
            .io = io,
            .url = ws_url,
        });
        defer client.deinit();

        const text_frame = (try client.next()).?;
        defer text_frame.deinit(allocator);
        try std.testing.expectEqualStrings(expected_text, text_frame.text);

        const close_frame = (try client.next()).?;
        defer close_frame.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 1000), close_frame.close.code);
    }

    server.awaitDone();
}

test "TestWebSocketServer executes script with interleaved client/server frames" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const greeting = [_]FrameDirective{.{ .text = "hello" }};
    const ack = [_]FrameDirective{.{ .text = "ack" }};
    const script = [_]Step{
        .{ .send_frames = &greeting },
        .{ .expect_client_frame = .{} },
        .{ .send_frames = &ack },
        .{ .close = .{ .code = 1000, .reason = "done" } },
    };

    var server = try TestWebSocketServer.init(allocator, io, .{
        .script = &script,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    var client = try websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    defer client.deinit();

    {
        const frame = (try client.next()).?;
        defer frame.deinit(allocator);
        try std.testing.expectEqualStrings("hello", frame.text);
    }

    try client.sendText("client-says-hi");

    {
        const frame = (try client.next()).?;
        defer frame.deinit(allocator);
        try std.testing.expectEqualStrings("ack", frame.text);
    }

    {
        const frame = (try client.next()).?;
        defer frame.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 1000), frame.close.code);
        try std.testing.expectEqualStrings("done", frame.close.reason);
    }

    server.awaitDone();
    const captured = server.capturedFrames();
    try std.testing.expectEqual(@as(usize, 1), captured.len);
    try std.testing.expectEqualStrings("client-says-hi", captured[0]);
}

test "TestWebSocketServer captures multiple client frames in order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const script = [_]Step{
        .{ .expect_client_frame = .{} },
        .{ .expect_client_frame = .{} },
        .{ .expect_client_frame = .{} },
        .{ .close = .{ .code = 1000, .reason = "" } },
    };

    var server = try TestWebSocketServer.init(allocator, io, .{
        .script = &script,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    var client = try websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    defer client.deinit();

    try client.sendText("first");
    try client.sendText("second");
    try client.sendText("third");

    while (try client.next()) |frame| {
        defer frame.deinit(allocator);
        if (frame == .close) break;
    }
    server.awaitDone();

    const captured = server.capturedFrames();
    try std.testing.expectEqual(@as(usize, 3), captured.len);
    try std.testing.expectEqualStrings("first", captured[0]);
    try std.testing.expectEqualStrings("second", captured[1]);
    try std.testing.expectEqualStrings("third", captured[2]);
}
