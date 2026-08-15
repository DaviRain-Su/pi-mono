const std = @import("std");
const anthropic = @import("anthropic.zig");
const types = @import("../types.zig");

const CapturedRequest = struct {
    headers: std.StringHashMap([]const u8),
    body: []u8,

    fn deinit(self: *CapturedRequest, allocator: std.mem.Allocator) void {
        var iterator = self.headers.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        allocator.free(self.body);
        self.* = undefined;
    }
};

const RequestCaptureServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    captured: ?CapturedRequest = null,

    fn init(allocator: std.mem.Allocator, io: std.Io) !RequestCaptureServer {
        return .{
            .allocator = allocator,
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
        };
    }

    fn start(self: *RequestCaptureServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *RequestCaptureServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
        if (self.captured) |*captured| captured.deinit(self.allocator);
        self.* = undefined;
    }

    fn url(self: *const RequestCaptureServer) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *RequestCaptureServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("request capture server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        self.captureRequest(stream) catch |err| std.debug.panic("request capture server read failed: {}", .{err});
        self.writeResponse(stream) catch |err| std.debug.panic("request capture server write failed: {}", .{err});
    }

    fn captureRequest(self: *RequestCaptureServer, stream: std.Io.net.Stream) !void {
        var read_buffer: [2048]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);

        var head = std.ArrayList(u8).empty;
        defer head.deinit(self.allocator);

        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;
        while (true) {
            const byte = try reader.interface.takeByte();
            try head.append(self.allocator, byte);
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }

        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var iterator = headers.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }

        var lines = std.mem.splitSequence(u8, head.items, "\r\n");
        _ = lines.next();

        var content_length: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) break;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const raw_name = std.mem.trim(u8, line[0..colon], &std.ascii.whitespace);
            const raw_value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);

            const name = try std.ascii.allocLowerString(self.allocator, raw_name);
            errdefer self.allocator.free(name);

            const value = try self.allocator.dupe(u8, raw_value);
            errdefer self.allocator.free(value);

            try headers.put(name, value);
            if (std.mem.eql(u8, name, "content-length")) {
                content_length = try std.fmt.parseUnsigned(usize, raw_value, 10);
            }
        }

        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);

        for (body) |*byte| {
            byte.* = try reader.interface.takeByte();
        }

        self.captured = .{
            .headers = headers,
            .body = body,
        };
    }

    fn writeResponse(self: *RequestCaptureServer, stream: std.Io.net.Stream) !void {
        _ = self;
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(std.testing.io, &write_buffer);
        try writer.interface.writeAll(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Content-Length: 0\r\n" ++
                "Connection: close\r\n\r\n",
        );
        try writer.interface.flush();
    }
};

fn createCompatValue(allocator: std.mem.Allocator, supports_eager_tool_input_streaming: bool) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        if (supports_eager_tool_input_streaming)
            "{\"supportsEagerToolInputStreaming\":true}"
        else
            "{\"supportsEagerToolInputStreaming\":false}",
        .{},
    );
}

test "github-copilot eager streaming compat is applied to streamed anthropic requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var server = try RequestCaptureServer.init(allocator, io);
    defer server.deinit();
    try server.start();

    const base_url = try server.url();
    defer allocator.free(base_url);

    var tool_parameters = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer tool_parameters.deinit();

    var compat = try createCompatValue(allocator, false);
    defer compat.deinit();

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_parameters.value,
    }};

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Use a tool" } }},
                .timestamp = 1,
            } },
        },
        .tools = tools,
    };

    const model = types.Model{
        .id = "claude-sonnet-4.5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "github-copilot",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 144000,
        .max_tokens = 32000,
        .compat = compat.value,
    };

    var stream = try anthropic.AnthropicProvider.stream(allocator, io, model, context, .{
        .api_key = "copilot-token",
    });
    defer stream.deinit();

    const request = server.captured orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(
        "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
        request.headers.get("anthropic-beta").?,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request.body, .{});
    defer parsed.deinit();

    const first_tool = parsed.value.object.get("tools").?.array.items[0];
    try std.testing.expect(first_tool == .object);
    try std.testing.expect(first_tool.object.get("eager_input_streaming") == null);
}

test "anthropic stream github-copilot provider injects copilot dynamic headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var server = try RequestCaptureServer.init(allocator, io);
    defer server.deinit();
    try server.start();

    const base_url = try server.url();
    defer allocator.free(base_url);

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello copilot" } }},
                .timestamp = 1,
            } },
        },
    };

    const model = types.Model{
        .id = "claude-sonnet-4.5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "github-copilot",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 144000,
        .max_tokens = 32000,
    };

    var stream = try anthropic.AnthropicProvider.stream(allocator, io, model, context, .{
        .api_key = "copilot-token",
    });
    defer stream.deinit();

    const request = server.captured orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("user", request.headers.get("x-initiator").?);
    try std.testing.expectEqualStrings("conversation-edits", request.headers.get("openai-intent").?);
    // No images in context, so Copilot-Vision-Request must be absent
    try std.testing.expect(request.headers.get("copilot-vision-request") == null);
}
