const std = @import("std");

pub const ProviderKind = enum {
    anthropic,
    openai_codex,
    xai_oauth,
};

pub fn defaultCallbackPath(kind: ProviderKind) []const u8 {
    return switch (kind) {
        .anthropic => "/callback",
        .openai_codex => "/auth/callback",
        .xai_oauth => "/callback",
    };
}

pub fn defaultCallbackPort(kind: ProviderKind) u16 {
    return switch (kind) {
        .anthropic => 53692,
        .openai_codex => 1455,
        .xai_oauth => 56121,
    };
}

pub const OAuthCallbackListener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    kind: ProviderKind,
    expected_path: []const u8,
    expected_state: []const u8,
    redirect_uri: []u8,
    mutex: std.Io.Mutex = .init,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completed_callback_url: ?[]u8 = null,
    thread: ?std.Thread = null,

    const Self = @This();

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: ProviderKind,
        expected_state: []const u8,
    ) !*Self {
        return createOnPort(allocator, io, kind, expected_state, defaultCallbackPort(kind));
    }

    pub fn createForTesting(
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: ProviderKind,
        expected_state: []const u8,
        bind_port: u16,
    ) !*Self {
        return createOnPort(allocator, io, kind, expected_state, bind_port);
    }

    fn createOnPort(
        allocator: std.mem.Allocator,
        io: std.Io,
        kind: ProviderKind,
        expected_state: []const u8,
        bind_port: u16,
    ) !*Self {
        const expected_path = defaultCallbackPath(kind);
        var server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(bind_port) }, io, .{ .reuse_address = false });
        errdefer server.deinit(io);

        const actual_port = server.socket.address.getPort();
        const redirect_uri = try std.fmt.allocPrint(allocator, "http://localhost:{d}{s}", .{ actual_port, expected_path });
        errdefer allocator.free(redirect_uri);

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .kind = kind,
            .expected_path = expected_path,
            .expected_state = expected_state,
            .redirect_uri = redirect_uri,
        };
        return self;
    }

    pub fn start(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *Self) void {
        self.closing.store(true, .release);
        if (self.thread) |thread| {
            self.wakeAccept();
            thread.join();
        }
        self.server.deinit(self.io);
        self.mutex.lockUncancelable(self.io);
        const completed = self.completed_callback_url;
        self.completed_callback_url = null;
        self.mutex.unlock(self.io);
        if (completed) |url| self.allocator.free(url);
        self.allocator.free(self.redirect_uri);
        self.* = undefined;
    }

    pub fn destroy(self: *Self) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn port(self: *const Self) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn takeCompletedCallbackUrl(self: *Self) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const url = self.completed_callback_url orelse return null;
        self.completed_callback_url = null;
        return url;
    }

    fn run(self: *Self) void {
        while (true) {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => return,
            };
            defer stream.close(self.io);
            if (self.closing.load(.acquire)) return;

            const should_stop = self.handleStream(stream) catch false;
            if (should_stop) return;
        }
    }

    fn wakeAccept(self: *Self) void {
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        const stream = address.connect(self.io, .{ .mode = .stream }) catch return;
        stream.close(self.io);
    }

    fn handleStream(self: *Self, stream: std.Io.net.Stream) !bool {
        const request_head = try readRequestHead(self.allocator, self.io, stream);
        defer self.allocator.free(request_head);

        const request = parseRequestLine(request_head) orelse {
            try writeCallbackResponse(stream, self.io, 400, "Bad Request", errorBody("Invalid OAuth callback request."));
            return false;
        };

        const query_index = std.mem.indexOfScalar(u8, request.target, '?') orelse request.target.len;
        const path = request.target[0..query_index];
        const query = if (query_index < request.target.len) request.target[query_index + 1 ..] else "";

        if (!std.mem.eql(u8, path, self.expected_path)) {
            try writeCallbackResponse(stream, self.io, 404, "Not Found", errorBody("Callback route not found."));
            return false;
        }

        if (request.method == .OPTIONS) {
            try writePreflightResponse(stream, self.io);
            return false;
        }
        if (request.method != .GET) {
            try writeCallbackResponse(stream, self.io, 405, "Method Not Allowed", errorBody("Unsupported OAuth callback method."));
            return false;
        }

        var parsed = try parseCallbackQuery(self.allocator, query);
        defer parsed.deinit(self.allocator);

        if (parsed.oauth_error != null) {
            try writeCallbackResponse(stream, self.io, 400, "Bad Request", errorBody("OAuth provider returned an error."));
            return false;
        }

        const state = parsed.state orelse {
            try writeCallbackResponse(stream, self.io, 400, "Bad Request", errorBody("OAuth callback is missing state."));
            return false;
        };
        if (!std.mem.eql(u8, state, self.expected_state)) {
            try writeCallbackResponse(stream, self.io, 400, "Bad Request", errorBody("OAuth callback state does not match this login attempt."));
            return false;
        }

        const code = parsed.code orelse {
            try writeCallbackResponse(stream, self.io, 400, "Bad Request", errorBody("OAuth callback is missing code."));
            return false;
        };
        _ = code;

        const callback_url = try std.fmt.allocPrint(self.allocator, "{s}?{s}", .{ self.redirect_uri, query });
        errdefer self.allocator.free(callback_url);
        self.mutex.lockUncancelable(self.io);
        if (self.completed_callback_url) |old_url| self.allocator.free(old_url);
        self.completed_callback_url = callback_url;
        self.mutex.unlock(self.io);

        try writeCallbackResponse(stream, self.io, 200, "OK", successBody());
        return true;
    }
};

const CallbackQuery = struct {
    code: ?[]u8 = null,
    state: ?[]u8 = null,
    oauth_error: ?[]u8 = null,

    fn deinit(self: *CallbackQuery, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
        if (self.oauth_error) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn readRequestHead(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) ![]u8 {
    var reader_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    var head = std.ArrayList(u8).empty;
    errdefer head.deinit(allocator);

    var tail = [_]u8{ 0, 0, 0, 0 };
    var count: usize = 0;
    while (count < 16 * 1024) : (count += 1) {
        const byte = try reader.interface.takeByte();
        try head.append(allocator, byte);
        tail[count % tail.len] = byte;
        if (count + 1 >= 4) {
            const start_index = (count + 1) % tail.len;
            const ordered = [_]u8{
                tail[start_index],
                tail[(start_index + 1) % tail.len],
                tail[(start_index + 2) % tail.len],
                tail[(start_index + 3) % tail.len],
            };
            if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
        }
    }
    return try head.toOwnedSlice(allocator);
}

const RequestMethod = enum {
    GET,
    OPTIONS,
    other,
};

const RequestLine = struct {
    method: RequestMethod,
    target: []const u8,
};

fn parseRequestLine(request_head: []const u8) ?RequestLine {
    const first_line_end = std.mem.indexOf(u8, request_head, "\r\n") orelse return null;
    const first_line = request_head[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return null;
    const request_method: RequestMethod = if (std.mem.eql(u8, method, "GET"))
        .GET
    else if (std.mem.eql(u8, method, "OPTIONS"))
        .OPTIONS
    else
        .other;
    return .{
        .method = request_method,
        .target = parts.next() orelse return null,
    };
}

fn parseCallbackQuery(allocator: std.mem.Allocator, query: []const u8) !CallbackQuery {
    var result = CallbackQuery{};
    errdefer result.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, query, '&');
    while (iterator.next()) |part| {
        const equals_index = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const name = part[0..equals_index];
        const value = try percentDecodeAlloc(allocator, part[equals_index + 1 ..]);
        errdefer allocator.free(value);
        if (std.mem.eql(u8, name, "code")) {
            if (result.code) |existing| allocator.free(existing);
            result.code = value;
        } else if (std.mem.eql(u8, name, "state")) {
            if (result.state) |existing| allocator.free(existing);
            result.state = value;
        } else if (std.mem.eql(u8, name, "error")) {
            if (result.oauth_error) |existing| allocator.free(existing);
            result.oauth_error = value;
        } else {
            allocator.free(value);
        }
    }

    return result;
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < encoded.len) {
        if (encoded[index] == '%' and index + 2 < encoded.len) {
            const high = std.fmt.charToDigit(encoded[index + 1], 16) catch null;
            const low = std.fmt.charToDigit(encoded[index + 2], 16) catch null;
            if (high) |hi| {
                if (low) |lo| {
                    try output.append(allocator, @as(u8, @intCast(hi * 16 + lo)));
                    index += 3;
                    continue;
                }
            }
        }
        try output.append(allocator, if (encoded[index] == '+') ' ' else encoded[index]);
        index += 1;
    }

    return try output.toOwnedSlice(allocator);
}

fn writeCallbackResponse(
    stream: std.Io.net.Stream,
    io: std.Io,
    status_code: u16,
    reason: []const u8,
    body: []const u8,
) !void {
    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n\r\n{s}",
        .{ status_code, reason, body.len, body },
    );
    try writer.interface.flush();
}

fn writePreflightResponse(stream: std.Io.net.Stream, io: std.Io) !void {
    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.writeAll(
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n\r\n",
    );
    try writer.interface.flush();
}

fn successBody() []const u8 {
    return "<!doctype html><html><body><h1>Login complete</h1><p>You can close this browser tab and return to pi.</p></body></html>";
}

fn errorBody(message: []const u8) []const u8 {
    _ = message;
    return "<!doctype html><html><body><h1>Login could not be completed</h1><p>Return to pi and try again.</p></body></html>";
}

const RawHttpResponse = struct {
    status_code: u16,
    body: []u8,

    fn deinit(self: *RawHttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

fn rawHttpRequest(allocator: std.mem.Allocator, io: std.Io, port: u16, method: []const u8, target: []const u8) !RawHttpResponse {
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var writer_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: localhost:{d}\r\nConnection: close\r\n\r\n", .{ method, target, port });
    try writer.interface.flush();

    var reader_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);
    while (true) {
        const byte = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try response.append(allocator, byte);
    }

    const bytes = response.items;
    const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = bytes[0..line_end];
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.InvalidHttpResponse;
    const status_text = parts.next() orelse return error.InvalidHttpResponse;
    const status_code = try std.fmt.parseInt(u16, status_text, 10);
    const body_index = if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |index| index + 4 else bytes.len;
    return .{
        .status_code = status_code,
        .body = try allocator.dupe(u8, bytes[body_index..]),
    };
}

fn rawHttpGet(allocator: std.mem.Allocator, io: std.Io, port: u16, target: []const u8) !RawHttpResponse {
    return rawHttpRequest(allocator, io, port, "GET", target);
}

test "OAuth callback listener accepts provider paths and captures callback URL" {
    const allocator = std.testing.allocator;
    const cases = [_]ProviderKind{ .anthropic, .openai_codex, .xai_oauth };

    for (cases) |kind| {
        var listener = try OAuthCallbackListener.createForTesting(allocator, std.testing.io, kind, "expected-state", 0);
        defer listener.destroy();
        try listener.start();

        try std.testing.expect(std.mem.endsWith(u8, listener.redirect_uri, defaultCallbackPath(kind)));
        const target = try std.fmt.allocPrint(allocator, "{s}?code=fake-code&state=expected-state", .{defaultCallbackPath(kind)});
        defer allocator.free(target);

        var response = try rawHttpGet(allocator, std.testing.io, listener.port(), target);
        defer response.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), response.status_code);
        try std.testing.expect(std.mem.indexOf(u8, response.body, "Login complete") != null);

        const completed = listener.takeCompletedCallbackUrl().?;
        defer allocator.free(completed);
        const expected = try std.fmt.allocPrint(allocator, "{s}?code=fake-code&state=expected-state", .{listener.redirect_uri});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, completed);
    }
}

test "OAuth callback listener answers preflight requests" {
    const allocator = std.testing.allocator;

    var listener = try OAuthCallbackListener.createForTesting(allocator, std.testing.io, .xai_oauth, "expected-state", 0);
    defer listener.destroy();
    try listener.start();

    var response = try rawHttpRequest(allocator, std.testing.io, listener.port(), "OPTIONS", "/callback");
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 204), response.status_code);
    try std.testing.expect(listener.takeCompletedCallbackUrl() == null);
}

test "OAuth callback listener rejects bad callbacks without completing login" {
    const allocator = std.testing.allocator;

    var listener = try OAuthCallbackListener.createForTesting(allocator, std.testing.io, .openai_codex, "expected-state", 0);
    defer listener.destroy();
    try listener.start();

    var wrong_path = try rawHttpGet(allocator, std.testing.io, listener.port(), "/wrong?code=fake-code&state=expected-state");
    defer wrong_path.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), wrong_path.status_code);
    try std.testing.expect(listener.takeCompletedCallbackUrl() == null);

    var missing_code = try rawHttpGet(allocator, std.testing.io, listener.port(), "/auth/callback?state=expected-state");
    defer missing_code.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), missing_code.status_code);
    try std.testing.expect(listener.takeCompletedCallbackUrl() == null);

    var wrong_state = try rawHttpGet(allocator, std.testing.io, listener.port(), "/auth/callback?code=fake-code&state=wrong-state");
    defer wrong_state.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), wrong_state.status_code);
    try std.testing.expect(listener.takeCompletedCallbackUrl() == null);

    var provider_error = try rawHttpGet(allocator, std.testing.io, listener.port(), "/auth/callback?error=access_denied&state=expected-state");
    defer provider_error.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), provider_error.status_code);
    try std.testing.expect(listener.takeCompletedCallbackUrl() == null);

    var success = try rawHttpGet(allocator, std.testing.io, listener.port(), "/auth/callback?code=fake-code&state=expected-state");
    defer success.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), success.status_code);
    const completed = listener.takeCompletedCallbackUrl().?;
    allocator.free(completed);
}

test "OAuth callback listener cancel closes port and bind failure is observable" {
    const allocator = std.testing.allocator;

    var listener = try OAuthCallbackListener.createForTesting(allocator, std.testing.io, .anthropic, "state", 0);
    const port = listener.port();
    try listener.start();
    listener.destroy();

    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    try std.testing.expectError(error.ConnectionRefused, address.connect(std.testing.io, .{ .mode = .stream }));

    var blocker = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, std.testing.io, .{ .reuse_address = false });
    defer blocker.deinit(std.testing.io);
    try std.testing.expectError(
        error.AddressInUse,
        OAuthCallbackListener.createForTesting(allocator, std.testing.io, .anthropic, "state", blocker.socket.address.getPort()),
    );
}
