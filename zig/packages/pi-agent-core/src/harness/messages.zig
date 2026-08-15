const std = @import("std");
const types = @import("types.zig");

pub fn userMessage(content: []const u8) types.HarnessMessage {
    return .{ .role = .user, .content = content };
}

pub fn assistantMessage(content: []const u8) types.HarnessMessage {
    return .{ .role = .assistant, .content = content };
}

test "messages create user role" {
    try std.testing.expectEqual(types.HarnessRole.user, userMessage("x").role);
}
