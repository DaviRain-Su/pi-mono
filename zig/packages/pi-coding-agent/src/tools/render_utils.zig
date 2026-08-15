const std = @import("std");
const ai = @import("ai");

pub fn shortenPath(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, home)) {
        return std.fmt.allocPrint(allocator, "~{s}", .{path[home.len..]});
    }
    return allocator.dupe(u8, path);
}

pub fn str(value: ?[]const u8) []const u8 {
    return value orelse "";
}

pub fn replaceTabs(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |byte| {
        if (byte == '\t') {
            try out.appendSlice(allocator, "   ");
        } else {
            try out.append(allocator, byte);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn normalizeDisplayText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |byte| {
        if (byte != '\r') try out.append(allocator, byte);
    }
    return out.toOwnedSlice(allocator);
}

pub fn sanitizeBinaryOutput(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte <= 0x1f and byte != '\t' and byte != '\n' and byte != '\r') {
            index += 1;
            continue;
        }
        if (index + 2 < text.len and byte == 0xEF and text[index + 1] == 0xBF and
            (text[index + 2] == 0xB9 or text[index + 2] == 0xBA or text[index + 2] == 0xBB))
        {
            index += 3;
            continue;
        }
        try out.append(allocator, byte);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn getTextOutput(allocator: std.mem.Allocator, content: []const ai.ContentBlock, show_images: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var saw_text = false;
    var image_count: usize = 0;
    for (content) |block| {
        switch (block) {
            .text => |text| {
                const normalized = try normalizeDisplayText(allocator, text.text);
                defer allocator.free(normalized);
                const sanitized = try sanitizeBinaryOutput(allocator, normalized);
                defer allocator.free(sanitized);
                if (saw_text) try out.append(allocator, '\n');
                try out.appendSlice(allocator, sanitized);
                saw_text = true;
            },
            .image => image_count += 1,
            else => {},
        }
    }

    if (image_count > 0 and !show_images) {
        if (out.items.len > 0) try out.append(allocator, '\n');
        for (0..image_count) |index| {
            if (index > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, "[image]");
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn invalidArgText() []const u8 {
    return "[invalid arg]";
}

test "render utils normalize display text" {
    const allocator = std.testing.allocator;
    const no_tabs = try replaceTabs(allocator, "a\tb");
    defer allocator.free(no_tabs);
    try std.testing.expectEqualStrings("a   b", no_tabs);

    const normalized = try normalizeDisplayText(allocator, "a\rb");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("ab", normalized);
}
