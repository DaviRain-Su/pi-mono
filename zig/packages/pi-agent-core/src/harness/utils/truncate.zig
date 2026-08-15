pub fn truncateBytes(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    return value[0..max_bytes];
}

test "truncateBytes limits output" {
    const std = @import("std");
    try std.testing.expectEqualStrings("ab", truncateBytes("abcd", 2));
}
