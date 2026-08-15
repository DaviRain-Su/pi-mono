const std = @import("std");

pub const ProcessedFiles = struct {
    text: []u8,
    image_count: usize = 0,

    pub fn deinit(self: *ProcessedFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn formatTextFileReference(allocator: std.mem.Allocator, absolute_path: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "<file name=\"{s}\">\n{s}\n</file>\n", .{ absolute_path, content });
}

test "formatTextFileReference wraps content in file tag" {
    const allocator = std.testing.allocator;
    const text = try formatTextFileReference(allocator, "/tmp/a.txt", "body");
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "<file name=\"/tmp/a.txt\">") != null);
}
