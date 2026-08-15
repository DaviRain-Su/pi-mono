const std = @import("std");
const ai = @import("ai");
const cli = @import("args.zig");

pub const InitialMessageInput = struct {
    parsed: *const cli.Args,
    file_text: ?[]const u8 = null,
    file_images: []const ai.ImageContent = &.{},
    stdin_content: ?[]const u8 = null,
};

pub const InitialMessageResult = struct {
    initial_message: ?[]u8 = null,
    initial_images: []ai.ImageContent = &.{},
    remaining_messages: []const []const u8 = &.{},

    pub fn deinit(self: *InitialMessageResult, allocator: std.mem.Allocator) void {
        if (self.initial_message) |message| allocator.free(message);
        for (self.initial_images) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        if (self.initial_images.len > 0) allocator.free(self.initial_images);
        self.* = .{};
    }
};

pub fn buildInitialMessage(allocator: std.mem.Allocator, input: InitialMessageInput) !InitialMessageResult {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    if (input.stdin_content) |content| try builder.appendSlice(allocator, content);
    if (input.file_text) |text| {
        if (text.len > 0) try builder.appendSlice(allocator, text);
    }

    const messages = input.parsed.messages orelse &.{};
    if (messages.len > 0) try builder.appendSlice(allocator, messages[0]);

    return .{
        .initial_message = if (builder.items.len > 0) try builder.toOwnedSlice(allocator) else null,
        .initial_images = try cloneImages(allocator, input.file_images),
        .remaining_messages = if (messages.len > 1) messages[1..] else &.{},
    };
}

fn cloneImages(allocator: std.mem.Allocator, images: []const ai.ImageContent) ![]ai.ImageContent {
    if (images.len == 0) return &.{};
    const out = try allocator.alloc(ai.ImageContent, images.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
    }

    for (images, 0..) |image, index| {
        out[index] = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        };
        initialized += 1;
    }
    return out;
}

test "buildInitialMessage combines stdin files and first positional message" {
    const allocator = std.testing.allocator;

    var parsed = cli.Args{
        .messages = &.{ "prompt", "follow-up" },
    };

    var result = try buildInitialMessage(allocator, .{
        .parsed = &parsed,
        .file_text = "<file></file>\n",
        .stdin_content = "stdin\n",
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("stdin\n<file></file>\nprompt", result.initial_message.?);
    try std.testing.expectEqual(@as(usize, 1), result.remaining_messages.len);
    try std.testing.expectEqualStrings("follow-up", result.remaining_messages[0]);
}
