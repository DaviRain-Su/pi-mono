const std = @import("std");
const types = @import("../types.zig");
const provider_stream = @import("../shared/provider_stream.zig");

const COPILOT_PROVIDER_ID = "github-copilot";

/// One-liner for the verbatim block every provider's streamProduction
/// repeats to layer github-copilot's dynamic per-request headers onto an
/// already-built header map:
/// ```zig
/// if (std.mem.eql(u8, model.provider, "github-copilot")) {
///     var copilot_hdrs = try github_copilot_headers.buildCopilotDynamicHeaders(allocator, context.messages);
///     defer { /* iterate + free values + deinit */ }
///     try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, copilot_hdrs);
/// }
/// ```
/// Noop for non-copilot providers; otherwise applies the dynamic headers
/// case-insensitively to the existing header map.
pub fn applyDynamicHeadersIfCopilot(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    messages: []const types.Message,
) !void {
    if (!std.mem.eql(u8, model.provider, COPILOT_PROVIDER_ID)) return;
    var copilot_hdrs = try buildCopilotDynamicHeaders(allocator, messages);
    defer {
        var it = copilot_hdrs.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        copilot_hdrs.deinit();
    }
    try provider_stream.mergeHeadersCaseInsensitive(allocator, headers, copilot_hdrs);
}

/// Infers the Copilot initiator based on the last message in the conversation.
/// Returns "user" if the last message is from a user, otherwise "agent" (for assistant or tool messages).
pub fn inferCopilotInitiator(messages: []const types.Message) []const u8 {
    if (messages.len == 0) {
        return "user";
    }
    const last = messages[messages.len - 1];
    switch (last) {
        .user => return "user",
        else => return "agent",
    }
}

/// Checks if any message contains images (for Copilot-Vision-Request header).
pub fn hasCopilotVisionInput(messages: []const types.Message) bool {
    for (messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                for (user_msg.content) |content_block| {
                    if (content_block == .image) {
                        return true;
                    }
                }
            },
            .tool_result => |tool_result_msg| {
                for (tool_result_msg.content) |content_block| {
                    if (content_block == .image) {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

/// Builds dynamic headers for GitHub Copilot requests.
/// Caller owns the returned map and must free all values, then call deinit().
pub fn buildCopilotDynamicHeaders(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();

    const initiator = inferCopilotInitiator(messages);
    try headers.put("X-Initiator", try allocator.dupe(u8, initiator));
    try headers.put("Openai-Intent", try allocator.dupe(u8, "conversation-edits"));

    if (hasCopilotVisionInput(messages)) {
        try headers.put("Copilot-Vision-Request", try allocator.dupe(u8, "true"));
    }

    return headers;
}

test "copilot inferCopilotInitiator with empty messages returns user" {
    const result = inferCopilotInitiator(&[_]types.Message{});
    try std.testing.expectEqualStrings("user", result);
}

test "copilot inferCopilotInitiator with last user message returns user" {
    const messages = [_]types.Message{
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }}, .timestamp = 1 } },
    };
    const result = inferCopilotInitiator(&messages);
    try std.testing.expectEqualStrings("user", result);
}

test "copilot inferCopilotInitiator with last assistant message returns agent" {
    const messages = [_]types.Message{
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }}, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "world" } }},
            .api = "openai-completions",
            .provider = "openai",
            .model = "gpt-4o",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };
    const result = inferCopilotInitiator(&messages);
    try std.testing.expectEqualStrings("agent", result);
}

test "copilot hasCopilotVisionInput no images returns false" {
    const messages = [_]types.Message{
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }}, .timestamp = 1 } },
    };
    try std.testing.expect(!hasCopilotVisionInput(&messages));
}

test "copilot hasCopilotVisionInput with image in user message returns true" {
    const messages = [_]types.Message{
        .{ .user = .{
            .content = &[_]types.ContentBlock{
                .{ .image = .{ .data = "base64data", .mime_type = "image/jpeg" } },
            },
            .timestamp = 1,
        } },
    };
    try std.testing.expect(hasCopilotVisionInput(&messages));
}

test "copilot hasCopilotVisionInput with image in tool_result message returns true" {
    const messages = [_]types.Message{
        .{ .tool_result = .{
            .tool_call_id = "call1",
            .tool_name = "screenshot",
            .content = &[_]types.ContentBlock{
                .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
            },
            .timestamp = 1,
        } },
    };
    try std.testing.expect(hasCopilotVisionInput(&messages));
}

test "copilot buildCopilotDynamicHeaders user initiator no images" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }}, .timestamp = 1 } },
    };
    var headers = try buildCopilotDynamicHeaders(allocator, &messages);
    defer {
        var it = headers.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        headers.deinit();
    }
    try std.testing.expectEqualStrings("user", headers.get("X-Initiator").?);
    try std.testing.expectEqualStrings("conversation-edits", headers.get("Openai-Intent").?);
    try std.testing.expect(headers.get("Copilot-Vision-Request") == null);
}

test "copilot buildCopilotDynamicHeaders agent initiator with image sets vision header" {
    const allocator = std.testing.allocator;
    const messages = [_]types.Message{
        .{ .user = .{
            .content = &[_]types.ContentBlock{
                .{ .image = .{ .data = "base64", .mime_type = "image/jpeg" } },
            },
            .timestamp = 1,
        } },
        .{ .assistant = .{
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "ok" } }},
            .api = "openai-completions",
            .provider = "github-copilot",
            .model = "gpt-4o",
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    };
    var headers = try buildCopilotDynamicHeaders(allocator, &messages);
    defer {
        var it = headers.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        headers.deinit();
    }
    try std.testing.expectEqualStrings("agent", headers.get("X-Initiator").?);
    try std.testing.expectEqualStrings("conversation-edits", headers.get("Openai-Intent").?);
    try std.testing.expectEqualStrings("true", headers.get("Copilot-Vision-Request").?);
}
