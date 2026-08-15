const std = @import("std");

pub const ParsedFrontmatter = struct {
    yaml_string: ?[]u8,
    body: []u8,

    pub fn deinit(self: *ParsedFrontmatter, allocator: std.mem.Allocator) void {
        if (self.yaml_string) |value| allocator.free(value);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) !ParsedFrontmatter {
    const normalized = try normalizeNewlines(allocator, content);
    defer allocator.free(normalized);
    if (!std.mem.startsWith(u8, normalized, "---")) {
        return .{ .yaml_string = null, .body = try allocator.dupe(u8, normalized) };
    }
    const end_index = std.mem.indexOfPos(u8, normalized, 3, "\n---") orelse {
        return .{ .yaml_string = null, .body = try allocator.dupe(u8, normalized) };
    };
    return .{
        .yaml_string = try allocator.dupe(u8, normalized[4..end_index]),
        .body = try allocator.dupe(u8, std.mem.trim(u8, normalized[end_index + 4 ..], " \t\r\n")),
    };
}

pub fn stripFrontmatter(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var parsed = try parseFrontmatter(allocator, content);
    defer if (parsed.yaml_string) |value| allocator.free(value);
    const body = parsed.body;
    parsed.body = &.{};
    return body;
}

fn normalizeNewlines(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const without_crlf = try std.mem.replaceOwned(u8, allocator, value, "\r\n", "\n");
    errdefer allocator.free(without_crlf);
    const normalized = try std.mem.replaceOwned(u8, allocator, without_crlf, "\r", "\n");
    allocator.free(without_crlf);
    return normalized;
}

test "frontmatter extracts yaml and body" {
    var parsed = try parseFrontmatter(std.testing.allocator, "---\na: 1\n---\n\nBody\n");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a: 1", parsed.yaml_string.?);
    try std.testing.expectEqualStrings("Body", parsed.body);
}
