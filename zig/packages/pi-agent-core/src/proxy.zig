const std = @import("std");

pub const ProxyStreamOptions = struct {
    auth_token: []const u8,
    proxy_url: []const u8,
};

pub fn streamEndpoint(allocator: std.mem.Allocator, proxy_url: []const u8) ![]u8 {
    var end = proxy_url.len;
    while (end > 0 and proxy_url[end - 1] == '/') : (end -= 1) {}
    const trimmed = proxy_url[0..end];
    return std.fmt.allocPrint(allocator, "{s}/api/stream", .{trimmed});
}

test "proxy stream endpoint trims trailing slash" {
    const allocator = std.testing.allocator;
    const endpoint = try streamEndpoint(allocator, "https://example.test/");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://example.test/api/stream", endpoint);
}
