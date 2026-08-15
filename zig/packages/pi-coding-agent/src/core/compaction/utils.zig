const std = @import("std");

pub fn estimateTextTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    return @max(@as(usize, 1), (text.len + 3) / 4);
}

pub fn shouldCompact(tokens: usize, reserve_tokens: usize, context_window: usize) bool {
    return tokens + reserve_tokens >= context_window;
}

test "compaction utils estimate text tokens conservatively" {
    try std.testing.expectEqual(@as(usize, 1), estimateTextTokens("abc"));
    try std.testing.expect(shouldCompact(90, 10, 100));
}
