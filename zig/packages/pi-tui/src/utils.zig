const std = @import("std");
const ansi = @import("vaxis-widgets").ansi;

pub const visibleWidth = ansi.visibleWidth;
pub const sliceByColumn = ansi.sliceVisibleAlloc;

pub fn normalizeTerminalOutput(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "\xE0\xB8\xB3")) {
            try out.appendSlice(allocator, "\xE0\xB9\x8D\xE0\xB8\xB2");
            index += 3;
        } else if (std.mem.startsWith(u8, text[index..], "\xE0\xBA\xB3")) {
            try out.appendSlice(allocator, "\xE0\xBB\x8D\xE0\xBA\xB2");
            index += 3;
        } else {
            try out.append(allocator, text[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const AnsiCode = struct {
    code: []const u8,
    len: usize,
};

pub fn extractAnsiCode(text: []const u8, pos: usize) ?AnsiCode {
    if (pos >= text.len or text[pos] != 0x1b or pos + 1 >= text.len) return null;
    const next = text[pos + 1];
    if (next == '[') {
        var index = pos + 2;
        while (index < text.len and !isCsiFinal(text[index])) : (index += 1) {}
        if (index < text.len) return .{ .code = text[pos .. index + 1], .len = index + 1 - pos };
        return null;
    }
    if (next == ']' or next == '_') {
        var index = pos + 2;
        while (index < text.len) : (index += 1) {
            if (text[index] == 0x07) return .{ .code = text[pos .. index + 1], .len = index + 1 - pos };
            if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') {
                return .{ .code = text[pos .. index + 2], .len = index + 2 - pos };
            }
        }
    }
    return null;
}

pub fn wrapTextWithAnsi(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]const []const u8 {
    if (text.len == 0) {
        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = try allocator.dupe(u8, "");
        return lines;
    }

    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| {
        try wrapSingleLine(allocator, &lines, line, width);
    }
    return lines.toOwnedSlice(allocator);
}

pub fn truncateToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: usize, ellipsis: []const u8, pad: bool) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    const text_width = visibleWidth(text);
    if (text_width <= max_width) {
        var out = try allocator.dupe(u8, text);
        if (pad and text_width < max_width) {
            out = try appendSpaces(allocator, out, max_width - text_width);
        }
        return out;
    }

    const ellipsis_width = visibleWidth(ellipsis);
    if (ellipsis_width >= max_width) {
        const clipped = try ansi.sliceVisibleAlloc(allocator, ellipsis, 0, max_width);
        if (pad and visibleWidth(clipped) < max_width) return appendSpaces(allocator, clipped, max_width - visibleWidth(clipped));
        return clipped;
    }

    const prefix = try ansi.sliceVisibleAlloc(allocator, text, 0, max_width - ellipsis_width);
    defer allocator.free(prefix);
    var out = try std.fmt.allocPrint(allocator, "{s}\x1b[0m{s}\x1b[0m", .{ prefix, ellipsis });
    if (pad and visibleWidth(prefix) + ellipsis_width < max_width) {
        out = try appendSpaces(allocator, out, max_width - visibleWidth(prefix) - ellipsis_width);
    }
    return out;
}

pub fn isWhitespaceChar(char: u21) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

const punctuation_table: [128]bool = blk: {
    var t = [_]bool{false} ** 128;
    for ([_]u8{
        '(', ')', '{', '}', '[',  ']',  '<', '>',
        '.', ',', ';', ':', '\'', '"',  '!', '?',
        '+', '-', '=', '*', '/',  '\\', '|', '&',
        '%', '^', '$', '#', '@',  '~',  '`',
    }) |c| {
        t[c] = true;
    }
    break :blk t;
};

pub fn isPunctuationChar(char: u21) bool {
    if (char >= 128) return false;
    return punctuation_table[@intCast(char)];
}

fn wrapSingleLine(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), line: []const u8, width: usize) !void {
    if (width == 0) {
        try lines.append(allocator, try allocator.dupe(u8, ""));
        return;
    }
    if (visibleWidth(line) <= width) {
        try lines.append(allocator, try allocator.dupe(u8, line));
        return;
    }

    var start_col: usize = 0;
    const total = visibleWidth(line);
    while (start_col < total) : (start_col += width) {
        try lines.append(allocator, try ansi.sliceVisibleAlloc(allocator, line, start_col, width));
    }
}

fn appendSpaces(allocator: std.mem.Allocator, original: []u8, count: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, original);
    allocator.free(original);
    try out.appendNTimes(allocator, ' ', count);
    return out.toOwnedSlice(allocator);
}

const csi_final_table: [128]bool = blk: {
    var t = [_]bool{false} ** 128;
    for ([_]u8{ 'm', 'G', 'K', 'H', 'J' }) |c| {
        t[c] = true;
    }
    break :blk t;
};

fn isCsiFinal(byte: u8) bool {
    if (byte >= 128) return false;
    return csi_final_table[byte];
}

test "utils wraps and truncates visible text" {
    const wrapped = try wrapTextWithAnsi(std.testing.allocator, "abcdef", 3);
    defer {
        for (wrapped) |line| std.testing.allocator.free(line);
        std.testing.allocator.free(wrapped);
    }
    try std.testing.expectEqual(@as(usize, 2), wrapped.len);
    try std.testing.expectEqualStrings("abc", wrapped[0]);

    const truncated = try truncateToWidth(std.testing.allocator, "abcdef", 4, "...", false);
    defer std.testing.allocator.free(truncated);
    try std.testing.expectEqualStrings("a\x1b[0m...\x1b[0m", truncated);
}
