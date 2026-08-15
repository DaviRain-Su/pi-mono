const std = @import("std");
const provider_stream = @import("provider_stream.zig");

pub fn headersToRecord(
    allocator: std.mem.Allocator,
    headers: std.StringHashMap([]const u8),
) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(allocator);
    errdefer provider_stream.deinitOwnedHeaders(allocator, &result);

    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        try provider_stream.putOwnedHeader(allocator, &result, entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
}

test "headersToRecord clones header entries" {
    const allocator = std.testing.allocator;
    var source = std.StringHashMap([]const u8).init(allocator);
    defer source.deinit();
    try source.put("content-type", "application/json");

    var cloned = try headersToRecord(allocator, source);
    defer provider_stream.deinitOwnedHeaders(allocator, &cloned);

    try std.testing.expectEqualStrings("application/json", cloned.get("content-type").?);
}
