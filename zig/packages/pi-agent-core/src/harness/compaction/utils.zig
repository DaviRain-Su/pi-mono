pub fn estimateTokens(text: []const u8) usize {
    return (text.len + 3) / 4;
}

test "estimateTokens rounds up by four byte chunks" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("abcde"));
}
