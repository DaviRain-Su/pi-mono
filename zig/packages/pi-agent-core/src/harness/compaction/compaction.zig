const utils = @import("utils.zig");

pub const DEFAULT_COMPACTION_SETTINGS = CompactionSettings{};

pub const CompactionSettings = struct {
    max_context_tokens: usize = 200_000,
    compact_threshold: f64 = 0.8,
};

pub fn estimateContextTokens(messages: []const []const u8) usize {
    var total: usize = 0;
    for (messages) |message| total += utils.estimateTokens(message);
    return total;
}

pub fn shouldCompact(used_tokens: usize, settings: CompactionSettings) bool {
    return @as(f64, @floatFromInt(used_tokens)) >= @as(f64, @floatFromInt(settings.max_context_tokens)) * settings.compact_threshold;
}

test "shouldCompact follows threshold" {
    const std = @import("std");
    try std.testing.expect(shouldCompact(80, .{ .max_context_tokens = 100, .compact_threshold = 0.8 }));
}
