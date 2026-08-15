const std = @import("std");
const ansi_to_html = @import("ansi_to_html.zig");

pub const RenderedToolResult = struct {
    collapsed: ?[]u8 = null,
    expanded: ?[]u8 = null,

    pub fn deinit(self: *RenderedToolResult, allocator: std.mem.Allocator) void {
        if (self.collapsed) |value| allocator.free(value);
        if (self.expanded) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn isBlankRenderedLine(line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len) {
        if (std.mem.startsWith(u8, line[index..], "\x1b[")) {
            const rest = line[index + 2 ..];
            if (std.mem.indexOfScalar(u8, rest, 'm')) |end| {
                index += 2 + end + 1;
                continue;
            }
        }
        if (!std.ascii.isWhitespace(line[index])) return false;
        index += 1;
    }
    return true;
}

pub fn trimRenderedResultLines(lines: []const []const u8) []const []const u8 {
    var start: usize = 0;
    var end: usize = lines.len;
    while (start < end and isBlankRenderedLine(lines[start])) start += 1;
    while (end > start and isBlankRenderedLine(lines[end - 1])) end -= 1;
    return lines[start..end];
}

pub fn renderLinesToHtml(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    return ansi_to_html.ansiLinesToHtml(allocator, trimRenderedResultLines(lines));
}

test "trimRenderedResultLines ignores ANSI-only blank lines" {
    const lines = [_][]const u8{ "\x1b[31m  \x1b[0m", "data", "" };
    const trimmed = trimRenderedResultLines(&lines);
    try std.testing.expectEqual(@as(usize, 1), trimmed.len);
    try std.testing.expectEqualStrings("data", trimmed[0]);
}
