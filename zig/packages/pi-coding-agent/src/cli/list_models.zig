const std = @import("std");

pub fn formatTokenCount(allocator: std.mem.Allocator, count: u64) ![]u8 {
    if (count >= 1_000_000) {
        const millions = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        if (count % 1_000_000 == 0) return std.fmt.allocPrint(allocator, "{d}M", .{count / 1_000_000});
        return std.fmt.allocPrint(allocator, "{d:.1}M", .{millions});
    }
    if (count >= 1_000) {
        const thousands = @as(f64, @floatFromInt(count)) / 1_000.0;
        if (count % 1_000 == 0) return std.fmt.allocPrint(allocator, "{d}K", .{count / 1_000});
        return std.fmt.allocPrint(allocator, "{d:.1}K", .{thousands});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

test "formatTokenCount abbreviates model context sizes" {
    const allocator = std.testing.allocator;
    const value = try formatTokenCount(allocator, 200_000);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("200K", value);
}
