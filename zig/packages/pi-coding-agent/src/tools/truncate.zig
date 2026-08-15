const std = @import("std");

pub const DEFAULT_MAX_LINES: usize = 2000;
pub const DEFAULT_MAX_BYTES: usize = 50 * 1024;

pub const TruncatedBy = enum {
    lines,
    bytes,
};

pub const TruncationOptions = struct {
    max_lines: usize = DEFAULT_MAX_LINES,
    max_bytes: usize = DEFAULT_MAX_BYTES,
};

pub const TruncationResult = struct {
    content: []const u8,
    truncated: bool,
    truncated_by: ?TruncatedBy,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool = false,
    first_line_exceeds_limit: bool = false,
    max_lines: usize = DEFAULT_MAX_LINES,
    max_bytes: usize = DEFAULT_MAX_BYTES,

    pub fn deinit(self: *TruncationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn truncateHead(
    allocator: std.mem.Allocator,
    content: []const u8,
    options: TruncationOptions,
) !TruncationResult {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    try splitLines(allocator, content, &lines);

    const total_lines = lines.items.len;
    const total_bytes = content.len;

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        const output = try allocator.dupe(u8, content);
        return .{
            .content = output,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = output.len,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    const first_line_bytes = if (lines.items.len == 0) 0 else lines.items[0].len;
    if (first_line_bytes > options.max_bytes) {
        return .{
            .content = try allocator.dupe(u8, ""),
            .truncated = true,
            .truncated_by = .bytes,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = 0,
            .output_bytes = 0,
            .first_line_exceeds_limit = true,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    var output_lines = std.ArrayList([]const u8).empty;
    defer output_lines.deinit(allocator);

    var output_bytes: usize = 0;
    var truncated_by: TruncatedBy = .lines;
    const line_limit = @min(lines.items.len, options.max_lines);

    for (lines.items[0..line_limit]) |line| {
        const line_bytes = line.len + if (output_lines.items.len > 0) @as(usize, 1) else 0;
        if (output_bytes + line_bytes > options.max_bytes) {
            truncated_by = .bytes;
            break;
        }
        try output_lines.append(allocator, line);
        output_bytes += line_bytes;
    }

    if (output_lines.items.len >= options.max_lines and output_bytes <= options.max_bytes) {
        truncated_by = .lines;
    }

    const output = try std.mem.join(allocator, "\n", output_lines.items);
    return .{
        .content = output,
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = output_lines.items.len,
        .output_bytes = output.len,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

pub fn truncateTail(
    allocator: std.mem.Allocator,
    content: []const u8,
    options: TruncationOptions,
) !TruncationResult {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    try splitLines(allocator, content, &lines);

    const total_lines = lines.items.len;
    const total_bytes = content.len;

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        const output = try allocator.dupe(u8, content);
        return .{
            .content = output,
            .truncated = false,
            .truncated_by = null,
            .total_lines = total_lines,
            .total_bytes = total_bytes,
            .output_lines = total_lines,
            .output_bytes = output.len,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
        };
    }

    var output_lines = std.ArrayList([]const u8).empty;
    defer output_lines.deinit(allocator);

    var output_bytes: usize = 0;
    var truncated_by: TruncatedBy = .lines;
    var last_line_partial = false;
    var index = lines.items.len;

    while (index > 0 and output_lines.items.len < options.max_lines) {
        index -= 1;
        const line = lines.items[index];
        const line_bytes = line.len + if (output_lines.items.len > 0) @as(usize, 1) else 0;
        if (output_bytes + line_bytes > options.max_bytes) {
            truncated_by = .bytes;
            if (output_lines.items.len == 0) {
                try output_lines.append(allocator, try truncateLineFromEnd(allocator, line, options.max_bytes));
                last_line_partial = true;
            }
            break;
        }
        try output_lines.append(allocator, line);
        output_bytes += line_bytes;
    }

    std.mem.reverse([]const u8, output_lines.items);
    if (output_lines.items.len >= options.max_lines and output_bytes <= options.max_bytes) {
        truncated_by = .lines;
    }

    const output = try std.mem.join(allocator, "\n", output_lines.items);
    if (last_line_partial) {
        allocator.free(output_lines.items[0]);
    }

    return .{
        .content = output,
        .truncated = true,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = output_lines.items.len,
        .output_bytes = output.len,
        .last_line_partial = last_line_partial,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

fn splitLines(
    allocator: std.mem.Allocator,
    content: []const u8,
    lines: *std.ArrayList([]const u8),
) !void {
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |line| {
        try lines.append(allocator, line);
    }
}

fn truncateLineFromEnd(allocator: std.mem.Allocator, line: []const u8, max_bytes: usize) ![]u8 {
    if (line.len <= max_bytes) return allocator.dupe(u8, line);

    var start = line.len - max_bytes;
    while (start < line.len and (line[start] & 0xc0) == 0x80) : (start += 1) {}
    return allocator.dupe(u8, line[start..]);
}

test "truncateHead keeps the beginning of long content" {
    const content =
        "line 1\n" ++
        "line 2\n" ++
        "line 3\n" ++
        "line 4";

    var result = try truncateHead(std.testing.allocator, content, .{ .max_lines = 2, .max_bytes = DEFAULT_MAX_BYTES });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.truncated);
    try std.testing.expectEqual(TruncatedBy.lines, result.truncated_by.?);
    try std.testing.expectEqualStrings("line 1\nline 2", result.content);
    try std.testing.expectEqual(@as(usize, 4), result.total_lines);
    try std.testing.expectEqual(@as(usize, 2), result.output_lines);
}

test "truncateTail keeps the end of long content" {
    const content =
        "line 1\n" ++
        "line 2\n" ++
        "line 3\n" ++
        "line 4";

    var result = try truncateTail(std.testing.allocator, content, .{ .max_lines = 2, .max_bytes = DEFAULT_MAX_BYTES });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.truncated);
    try std.testing.expectEqual(TruncatedBy.lines, result.truncated_by.?);
    try std.testing.expectEqualStrings("line 3\nline 4", result.content);
    try std.testing.expectEqual(@as(usize, 2), result.output_lines);
}
