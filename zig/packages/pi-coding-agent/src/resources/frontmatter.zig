const std = @import("std");

pub const FrontmatterParseResult = struct {
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    argument_hint: ?[]u8 = null,
    disable_model_invocation: bool = false,
    body: []u8,

    pub fn deinit(self: *const FrontmatterParseResult, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.argument_hint) |value| allocator.free(value);
        allocator.free(self.body);
    }
};

pub fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) !FrontmatterParseResult {
    if (!std.mem.startsWith(u8, content, "---")) {
        return .{ .body = try allocator.dupe(u8, content) };
    }

    const line_break = std.mem.indexOfScalar(u8, content, '\n') orelse return .{ .body = try allocator.dupe(u8, content) };
    const marker = "\n---";
    const end_index = std.mem.indexOfPos(u8, content, line_break + 1, marker) orelse return .{ .body = try allocator.dupe(u8, content) };
    const header = content[line_break + 1 .. end_index];
    var result = FrontmatterParseResult{
        .body = try allocator.dupe(u8, std.mem.trim(u8, content[end_index + marker.len ..], "\r\n")),
    };
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon_index], " \t");
        const value = std.mem.trim(u8, line[colon_index + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "name")) {
            result.name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "description")) {
            result.description = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "argument-hint")) {
            result.argument_hint = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            result.disable_model_invocation = std.mem.eql(u8, value, "true");
        }
    }

    return result;
}

pub fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}
