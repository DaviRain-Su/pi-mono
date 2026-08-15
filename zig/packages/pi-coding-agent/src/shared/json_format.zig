const std = @import("std");

/// Writes `value` into `writer` as a JSON string literal — quoted and
/// fully escaped per RFC 8259.
///
/// Several modules used to ship a private copy of this helper (ts_rpc_wire,
/// extension_dialog, plus a same-shape writeJsonStringValue in main.zig).
/// Centralizing the implementation here keeps the escape rules consistent
/// and makes it the single place to
/// touch when std.json's stringify API evolves.
pub fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

test "writeJsonString quotes and escapes value" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonString(std.testing.allocator, &out.writer, "hello\nworld");
    try std.testing.expectEqualStrings("\"hello\\nworld\"", out.written());
}

test "writeJsonString empty value yields empty quoted string" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonString(std.testing.allocator, &out.writer, "");
    try std.testing.expectEqualStrings("\"\"", out.written());
}
