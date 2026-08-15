pub const ThinkingLevel = enum {
    low,
    medium,
    high,
    xhigh,
};

pub const DEFAULT_THINKING_LEVEL: ThinkingLevel = .medium;

test "default thinking level is medium" {
    try @import("std").testing.expectEqual(ThinkingLevel.medium, DEFAULT_THINKING_LEVEL);
}
