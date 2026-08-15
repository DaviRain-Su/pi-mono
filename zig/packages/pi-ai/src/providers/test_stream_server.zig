const std = @import("std");

pub const DelayedChunk = struct {
    bytes: []const u8,
    delay_after_ms: u64 = 0,
};

pub const DelayedChunkServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    chunks: []const DelayedChunk,
    response_headers: []const u8 = "",
    thread: ?std.Thread = null,

    pub fn init(io: std.Io, chunks: []const DelayedChunk) !DelayedChunkServer {
        return try initWithHeaders(io, chunks, "");
    }

    pub fn initWithHeaders(io: std.Io, chunks: []const DelayedChunk, response_headers: []const u8) !DelayedChunkServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .chunks = chunks,
            .response_headers = response_headers,
        };
    }

    pub fn start(self: *DelayedChunkServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *DelayedChunkServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    pub fn url(self: *const DelayedChunkServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *DelayedChunkServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("delayed chunk server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch return;
        writeResponse(self, stream) catch return;
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var header_buffer: [16 * 1024]u8 = undefined;
        var header_len: usize = 0;
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            if (header_len >= header_buffer.len) return error.RequestHeaderTooLarge;
            header_buffer[header_len] = byte;
            header_len += 1;
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

        const content_length = parseContentLengthHeader(header_buffer[0..header_len]);
        var remaining = content_length;
        while (remaining > 0) : (remaining -= 1) {
            _ = try reader.interface.takeByte();
        }
    }

    fn writeResponse(self: *DelayedChunkServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        var total_len: usize = 0;
        for (self.chunks) |chunk| total_len += chunk.bytes.len;

        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n",
            .{ total_len, self.response_headers },
        );
        try writer.interface.flush();

        for (self.chunks) |chunk| {
            try writer.interface.writeAll(chunk.bytes);
            try writer.interface.flush();
            if (chunk.delay_after_ms > 0) {
                std.Io.sleep(self.io, .fromMilliseconds(@intCast(chunk.delay_after_ms)), .awake) catch {};
            }
        }
    }
};

fn parseContentLengthHeader(headers: []const u8) usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len < "Content-Length:".len) continue;
        if (std.ascii.eqlIgnoreCase(line[0.."Content-Length:".len], "Content-Length:")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " \t"), 10) catch 0;
        }
    }
    return 0;
}

pub fn startAbortThread(io: std.Io, signal: *std.atomic.Value(bool), delay_ms: u64) !std.Thread {
    return try std.Thread.spawn(.{}, struct {
        fn run(abort_signal: *std.atomic.Value(bool), test_io: std.Io, sleep_ms: u64) void {
            std.Io.sleep(test_io, .fromMilliseconds(@intCast(sleep_ms)), .awake) catch {};
            signalStore(abort_signal);
        }

        fn signalStore(abort_signal: *std.atomic.Value(bool)) void {
            abort_signal.store(true, .seq_cst);
        }
    }.run, .{ signal, io, delay_ms });
}
