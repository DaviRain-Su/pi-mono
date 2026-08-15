const std = @import("std");

pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (index + 2 < text.len and text[index] == 0xED) {
            const is_high = text[index + 1] >= 0xA0 and text[index + 1] <= 0xAF;
            const is_low = text[index + 1] >= 0xB0 and text[index + 1] <= 0xBF;
            if (is_high) {
                if (index + 5 < text.len and text[index + 3] == 0xED and
                    text[index + 4] >= 0xB0 and text[index + 4] <= 0xBF)
                {
                    try result.appendSlice(allocator, text[index .. index + 6]);
                    index += 6;
                    continue;
                }
                index += 3;
                continue;
            }
            if (is_low) {
                index += 3;
                continue;
            }
        }
        try result.append(allocator, text[index]);
        index += 1;
    }

    return result.toOwnedSlice(allocator);
}

test "sanitizeSurrogates removes unpaired surrogate byte sequences" {
    const allocator = std.testing.allocator;
    const sanitized = try sanitizeSurrogates(allocator, "a\xED\xA0\x80b");
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("ab", sanitized);
}
