pub const InitialMessageInput = struct {
    messages: []const []const u8,
    file_text: ?[]const u8 = null,
    stdin_content: ?[]const u8 = null,
};

pub const InitialMessageResult = struct {
    initial_message: ?[]const u8 = null,
    consumed_message_count: usize = 0,
};

pub fn buildInitialMessage(input: InitialMessageInput) InitialMessageResult {
    if (input.stdin_content) |value| return .{ .initial_message = value };
    if (input.file_text) |value| return .{ .initial_message = value };
    if (input.messages.len > 0) return .{ .initial_message = input.messages[0], .consumed_message_count = 1 };
    return .{};
}

test "buildInitialMessage consumes first CLI message" {
    const std = @import("std");
    const messages = [_][]const u8{"hello"};
    const result = buildInitialMessage(.{ .messages = &messages });
    try std.testing.expectEqualStrings("hello", result.initial_message.?);
    try std.testing.expectEqual(@as(usize, 1), result.consumed_message_count);
}
