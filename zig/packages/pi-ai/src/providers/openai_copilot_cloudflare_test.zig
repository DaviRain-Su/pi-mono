const std = @import("std");
const openai = @import("openai.zig");
const types = @import("../types.zig");

/// A minimal server that accepts one connection, captures request headers, and
/// responds with an empty 200 SSE stream so the provider can complete setup.
const RequestCaptureServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    captured: ?CapturedRequest = null,

    const CapturedRequest = struct {
        headers: std.StringHashMap([]const u8),

        fn deinit(self: *CapturedRequest, allocator: std.mem.Allocator) void {
            var iterator = self.headers.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.* = undefined;
        }
    };

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
        var read_buffer: [4096]u8 = undefined;
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
        _ = lines.next(); // skip request line

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
        }

        self.captured = .{ .headers = headers };
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

test "openai stream github-copilot provider injects copilot dynamic headers" {
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
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "github-copilot",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream = try openai.OpenAIProvider.stream(allocator, io, model, context, .{
        .api_key = "copilot-token",
    });
    defer stream.deinit();

    const captured = server.captured orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("user", captured.headers.get("x-initiator").?);
    try std.testing.expectEqualStrings("conversation-edits", captured.headers.get("openai-intent").?);
    // No images in context, so Copilot-Vision-Request must be absent
    try std.testing.expect(captured.headers.get("copilot-vision-request") == null);
}
