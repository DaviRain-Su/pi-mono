const std = @import("std");

pub const LineHandler = *const fn (ctx: ?*anyopaque, line: []const u8) anyerror!void;

pub fn serializeJsonLine(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r")) return line[0 .. line.len - 1];
    return line;
}

pub const JsonlLineReader = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) JsonlLineReader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *JsonlLineReader) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *JsonlLineReader, chunk: []const u8, ctx: ?*anyopaque, handler: LineHandler) !void {
        try self.buffer.appendSlice(self.allocator, chunk);
        while (std.mem.indexOfScalar(u8, self.buffer.items, '\n')) |newline_index| {
            const raw_line = self.buffer.items[0..newline_index];
            try handler(ctx, stripTrailingCarriageReturn(raw_line));
            std.mem.copyForwards(u8, self.buffer.items, self.buffer.items[newline_index + 1 ..]);
            self.buffer.shrinkRetainingCapacity(self.buffer.items.len - newline_index - 1);
        }
    }

    pub fn finish(self: *JsonlLineReader, ctx: ?*anyopaque, handler: LineHandler) !void {
        if (self.buffer.items.len == 0) return;
        try handler(ctx, stripTrailingCarriageReturn(self.buffer.items));
        self.buffer.clearRetainingCapacity();
    }
};

fn collectLine(ctx: ?*anyopaque, line: []const u8) !void {
    const lines: *std.ArrayList([]u8) = @ptrCast(@alignCast(ctx.?));
    try lines.append(std.testing.allocator, try std.testing.allocator.dupe(u8, line));
}

test "JsonlLineReader splits only on LF and strips CR" {
    var reader = JsonlLineReader.init(std.testing.allocator);
    defer reader.deinit();

    var lines = std.ArrayList([]u8).empty;
    defer {
        for (lines.items) |line| std.testing.allocator.free(line);
        lines.deinit(std.testing.allocator);
    }

    try reader.feed("a\r\nb", &lines, collectLine);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("a", lines.items[0]);
    try reader.feed("\n", &lines, collectLine);
    try reader.finish(&lines, collectLine);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("b", lines.items[1]);
}
