const std = @import("std");
const provider_json = @import("provider_json.zig");
const types = @import("../types.zig");

const NON_VISION_USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)";
const NON_VISION_TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)";
const SYNTHETIC_TOOL_RESULT_TEXT = "No result provided";

pub const NormalizeToolCallIdFn = *const fn (
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) anyerror![]const u8;

pub fn transformMessages(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    model: types.Model,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
) ![]types.Message {
    var normalized_tool_call_ids = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = normalized_tool_call_ids.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        normalized_tool_call_ids.deinit();
    }

    var first_pass = std.ArrayList(types.Message).empty;
    defer first_pass.deinit(allocator);

    for (messages) |message| {
        switch (message) {
            .user => |user| try first_pass.append(allocator, .{
                .user = .{
                    .content = try cloneUserLikeContent(allocator, user.content, modelSupportsImages(model), NON_VISION_USER_IMAGE_PLACEHOLDER),
                    .timestamp = user.timestamp,
                },
            }),
            .tool_result => |tool_result| try first_pass.append(allocator, .{
                .tool_result = .{
                    .tool_call_id = try cloneNormalizedToolCallId(allocator, tool_result.tool_call_id, &normalized_tool_call_ids),
                    .tool_name = try allocator.dupe(u8, tool_result.tool_name),
                    .content = try cloneUserLikeContent(allocator, tool_result.content, modelSupportsImages(model), NON_VISION_TOOL_IMAGE_PLACEHOLDER),
                    .details = if (tool_result.details) |details| try provider_json.cloneValue(allocator, details) else null,
                    .is_error = tool_result.is_error,
                    .timestamp = tool_result.timestamp,
                },
            }),
            .assistant => |assistant| try first_pass.append(allocator, .{
                .assistant = try cloneAssistantMessage(allocator, assistant, model, normalize_tool_call_id, &normalized_tool_call_ids),
            }),
        }
    }

    const transformed = try first_pass.toOwnedSlice(allocator);
    var result = std.ArrayList(types.Message).empty;
    errdefer {
        const owned = result.items;
        for (owned) |message| freeMessage(allocator, message);
        result.deinit(allocator);
    }

    var pending_tool_calls: ?[]const types.ToolCall = null;
    var pending_timestamp: i64 = 0;
    var existing_tool_result_ids = std.ArrayList([]const u8).empty;
    defer existing_tool_result_ids.deinit(allocator);

    for (transformed) |message| {
        switch (message) {
            .assistant => |assistant| {
                try insertSyntheticToolResults(allocator, &result, pending_tool_calls, existing_tool_result_ids.items, pending_timestamp);
                pending_tool_calls = null;
                existing_tool_result_ids.clearRetainingCapacity();

                if (assistant.stop_reason == .error_reason or assistant.stop_reason == .aborted) {
                    freeMessage(allocator, message);
                    continue;
                }

                try result.append(allocator, message);

                if (assistant.tool_calls) |tool_calls| {
                    if (tool_calls.len > 0) {
                        pending_tool_calls = tool_calls;
                        pending_timestamp = assistant.timestamp;
                    }
                }
            },
            .tool_result => |tool_result| {
                try existing_tool_result_ids.append(allocator, tool_result.tool_call_id);
                try result.append(allocator, message);
            },
            .user => {
                try insertSyntheticToolResults(allocator, &result, pending_tool_calls, existing_tool_result_ids.items, pending_timestamp);
                pending_tool_calls = null;
                existing_tool_result_ids.clearRetainingCapacity();
                try result.append(allocator, message);
            },
        }
    }

    try insertSyntheticToolResults(allocator, &result, pending_tool_calls, existing_tool_result_ids.items, pending_timestamp);
    allocator.free(transformed);
    return try result.toOwnedSlice(allocator);
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []const types.Message) void {
    for (messages) |message| freeMessage(allocator, message);
    allocator.free(messages);
}

fn cloneAssistantMessage(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    model: types.Model,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) !types.AssistantMessage {
    const is_same_model = std.mem.eql(u8, assistant.provider, model.provider) and
        std.mem.eql(u8, assistant.api, model.api) and
        std.mem.eql(u8, assistant.model, model.id);

    return .{
        .content = try cloneAssistantContent(allocator, assistant.content, assistant, model, is_same_model, normalize_tool_call_id, normalized_tool_call_ids),
        .tool_calls = try cloneToolCalls(allocator, assistant, model, is_same_model, normalize_tool_call_id, normalized_tool_call_ids),
        .api = try allocator.dupe(u8, assistant.api),
        .provider = try allocator.dupe(u8, assistant.provider),
        .model = try allocator.dupe(u8, assistant.model),
        .response_id = if (assistant.response_id) |response_id| try allocator.dupe(u8, response_id) else null,
        .response_model = if (assistant.response_model) |response_model| try allocator.dupe(u8, response_model) else null,
        .usage = assistant.usage,
        .stop_reason = assistant.stop_reason,
        .error_message = if (assistant.error_message) |error_message| try allocator.dupe(u8, error_message) else null,
        .timestamp = assistant.timestamp,
    };
}

fn cloneToolCalls(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    model: types.Model,
    is_same_model: bool,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) !?[]types.ToolCall {
    if (types.hasInlineToolCalls(assistant)) {
        var tool_calls = std.ArrayList(types.ToolCall).empty;
        errdefer {
            for (tool_calls.items) |tool_call| freeToolCall(allocator, tool_call);
            tool_calls.deinit(allocator);
        }

        for (assistant.content) |block| {
            if (block != .tool_call) continue;
            try tool_calls.append(allocator, try cloneToolCallWithTransform(
                allocator,
                block.tool_call,
                assistant,
                model,
                is_same_model,
                normalize_tool_call_id,
                normalized_tool_call_ids,
            ));
        }

        return try tool_calls.toOwnedSlice(allocator);
    }

    const source_tool_calls = assistant.tool_calls orelse return null;
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    errdefer {
        for (tool_calls.items) |tool_call| freeToolCall(allocator, tool_call);
        tool_calls.deinit(allocator);
    }

    for (source_tool_calls) |tool_call| {
        try tool_calls.append(allocator, try cloneToolCallWithTransform(
            allocator,
            tool_call,
            assistant,
            model,
            is_same_model,
            normalize_tool_call_id,
            normalized_tool_call_ids,
        ));
    }

    return try tool_calls.toOwnedSlice(allocator);
}

fn cloneToolCallWithTransform(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    assistant: types.AssistantMessage,
    model: types.Model,
    is_same_model: bool,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) !types.ToolCall {
    var id: []const u8 = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);

    if (!is_same_model) {
        if (normalized_tool_call_ids.get(tool_call.id)) |existing_id| {
            allocator.free(id);
            id = try allocator.dupe(u8, existing_id);
        } else if (normalize_tool_call_id) |normalizer| {
            const normalized_id = try normalizer(allocator, tool_call.id, model, assistant);
            if (!std.mem.eql(u8, normalized_id, tool_call.id)) {
                allocator.free(id);
                id = normalized_id;
                try normalized_tool_call_ids.put(try allocator.dupe(u8, tool_call.id), try allocator.dupe(u8, normalized_id));
            } else {
                allocator.free(normalized_id);
            }
        }
    }

    return .{
        .id = id,
        .name = try allocator.dupe(u8, tool_call.name),
        .arguments = try provider_json.cloneValue(allocator, tool_call.arguments),
        .thought_signature = if (is_same_model) if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null else null,
    };
}

fn cloneUserLikeContent(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    supports_images: bool,
    placeholder: []const u8,
) ![]types.ContentBlock {
    if (supports_images) return try cloneContentBlocks(allocator, content);

    var blocks = std.ArrayList(types.ContentBlock).empty;
    errdefer {
        for (blocks.items) |block| freeContentBlock(allocator, block);
        blocks.deinit(allocator);
    }

    var previous_was_placeholder = false;
    for (content) |block| {
        switch (block) {
            .image => {
                if (!previous_was_placeholder) {
                    try blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, placeholder) } });
                }
                previous_was_placeholder = true;
            },
            .text => |text| {
                try blocks.append(allocator, .{ .text = .{
                    .text = try allocator.dupe(u8, text.text),
                    .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
                } });
                previous_was_placeholder = std.mem.eql(u8, text.text, placeholder);
            },
            .thinking => |thinking| {
                const signature = types.thinkingSignature(thinking);
                try blocks.append(allocator, .{ .thinking = .{
                    .thinking = try allocator.dupe(u8, thinking.thinking),
                    .thinking_signature = if (signature) |value| try allocator.dupe(u8, value) else null,
                    .signature = if (signature) |value| try allocator.dupe(u8, value) else null,
                    .redacted = thinking.redacted,
                } });
                previous_was_placeholder = false;
            },
            .tool_call => |tool_call| {
                try blocks.append(allocator, .{ .tool_call = try cloneToolCall(allocator, tool_call) });
                previous_was_placeholder = false;
            },
        }
    }

    return try blocks.toOwnedSlice(allocator);
}

fn cloneAssistantContent(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    assistant: types.AssistantMessage,
    model: types.Model,
    is_same_model: bool,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) ![]types.ContentBlock {
    var blocks = std.ArrayList(types.ContentBlock).empty;
    errdefer {
        for (blocks.items) |block| freeContentBlock(allocator, block);
        blocks.deinit(allocator);
    }

    for (content) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (thinking.redacted and !is_same_model) continue;
                const signature = types.thinkingSignature(thinking);
                if (!is_same_model) {
                    const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    try blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, thinking.thinking) } });
                    continue;
                }

                if (signature != null or std.mem.trim(u8, thinking.thinking, " \t\r\n").len > 0) {
                    try blocks.append(allocator, .{ .thinking = .{
                        .thinking = try allocator.dupe(u8, thinking.thinking),
                        .thinking_signature = if (signature) |value| try allocator.dupe(u8, value) else null,
                        .signature = if (signature) |value| try allocator.dupe(u8, value) else null,
                        .redacted = thinking.redacted,
                    } });
                }
            },
            .text => |text| {
                try blocks.append(allocator, .{ .text = .{
                    .text = try allocator.dupe(u8, text.text),
                    .text_signature = if (is_same_model) if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null else null,
                } });
            },
            .tool_call => |tool_call| {
                try blocks.append(allocator, .{ .tool_call = try cloneToolCallWithTransform(
                    allocator,
                    tool_call,
                    assistant,
                    model,
                    is_same_model,
                    normalize_tool_call_id,
                    normalized_tool_call_ids,
                ) });
            },
            .image => try blocks.append(allocator, try cloneContentBlock(allocator, block)),
        }
    }

    return try blocks.toOwnedSlice(allocator);
}

fn cloneContentBlocks(allocator: std.mem.Allocator, content: []const types.ContentBlock) ![]types.ContentBlock {
    var blocks = std.ArrayList(types.ContentBlock).empty;
    errdefer {
        for (blocks.items) |block| freeContentBlock(allocator, block);
        blocks.deinit(allocator);
    }

    for (content) |block| try blocks.append(allocator, try cloneContentBlock(allocator, block));
    return try blocks.toOwnedSlice(allocator);
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: types.ContentBlock) !types.ContentBlock {
    return switch (block) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
        .image => |image| .{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| blk: {
            const signature = types.thinkingSignature(thinking);
            break :blk .{ .thinking = .{
                .thinking = try allocator.dupe(u8, thinking.thinking),
                .thinking_signature = if (signature) |value| try allocator.dupe(u8, value) else null,
                .signature = if (signature) |value| try allocator.dupe(u8, value) else null,
                .redacted = thinking.redacted,
            } };
        },
        .tool_call => |tool_call| .{ .tool_call = try cloneToolCall(allocator, tool_call) },
    };
}

fn cloneToolCall(allocator: std.mem.Allocator, tool_call: types.ToolCall) !types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, tool_call.id),
        .name = try allocator.dupe(u8, tool_call.name),
        .arguments = try provider_json.cloneValue(allocator, tool_call.arguments),
        .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
    };
}

fn cloneNormalizedToolCallId(
    allocator: std.mem.Allocator,
    original_id: []const u8,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) ![]const u8 {
    if (normalized_tool_call_ids.get(original_id)) |normalized_id| {
        return try allocator.dupe(u8, normalized_id);
    }
    return try allocator.dupe(u8, original_id);
}

fn insertSyntheticToolResults(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(types.Message),
    pending_tool_calls: ?[]const types.ToolCall,
    existing_tool_result_ids: []const []const u8,
    pending_timestamp: i64,
) !void {
    const tool_calls = pending_tool_calls orelse return;
    for (tool_calls) |tool_call| {
        if (containsToolResult(existing_tool_result_ids, tool_call.id)) continue;
        const content = try allocator.alloc(types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, SYNTHETIC_TOOL_RESULT_TEXT) } };
        try result.append(allocator, .{
            .tool_result = .{
                .tool_call_id = try allocator.dupe(u8, tool_call.id),
                .tool_name = try allocator.dupe(u8, tool_call.name),
                .content = content,
                .is_error = true,
                .timestamp = pending_timestamp,
            },
        });
    }
}

fn containsToolResult(ids: []const []const u8, candidate: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, candidate)) return true;
    }
    return false;
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn freeMessage(allocator: std.mem.Allocator, message: types.Message) void {
    switch (message) {
        .user => |user| {
            freeContentBlocks(allocator, user.content);
        },
        .tool_result => |tool_result| {
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            freeContentBlocks(allocator, tool_result.content);
            if (tool_result.details) |details| provider_json.freeValue(allocator, details);
        },
        .assistant => |assistant| {
            allocator.free(assistant.api);
            allocator.free(assistant.provider);
            allocator.free(assistant.model);
            if (assistant.response_id) |response_id| allocator.free(response_id);
            if (assistant.response_model) |response_model| allocator.free(response_model);
            if (assistant.error_message) |error_message| allocator.free(error_message);
            freeContentBlocks(allocator, assistant.content);
            if (assistant.tool_calls) |tool_calls| {
                for (tool_calls) |tool_call| freeToolCall(allocator, tool_call);
                allocator.free(tool_calls);
            }
        },
    }
}

fn freeContentBlocks(allocator: std.mem.Allocator, blocks: []const types.ContentBlock) void {
    for (blocks) |block| freeContentBlock(allocator, block);
    allocator.free(blocks);
}

fn freeContentBlock(allocator: std.mem.Allocator, block: types.ContentBlock) void {
    switch (block) {
        .text => |text| {
            allocator.free(text.text);
            if (text.text_signature) |signature| allocator.free(signature);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |signature| allocator.free(signature);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |tool_call| freeToolCall(allocator, tool_call),
    }
}

fn freeToolCall(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    provider_json.freeValue(allocator, tool_call.arguments);
}

fn normalizeToolCallIdForTest(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    _ = model;
    _ = source;
    return try std.fmt.allocPrint(allocator, "normalized-{s}", .{id});
}

test "transformMessages downgrades unsupported user and tool result images" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "text-only",
        .name = "Text Only",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 32000,
        .max_tokens = 4000,
    };

    const user_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "before" } },
        .{ .image = .{ .data = "a", .mime_type = "image/png" } },
        .{ .image = .{ .data = "b", .mime_type = "image/png" } },
        .{ .text = .{ .text = "after" } },
    };
    const tool_content = [_]types.ContentBlock{
        .{ .image = .{ .data = "c", .mime_type = "image/png" } },
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .user = .{ .content = &user_content, .timestamp = 1 } },
        .{ .tool_result = .{
            .tool_call_id = "tool-1",
            .tool_name = "capture",
            .content = &tool_content,
            .timestamp = 2,
        } },
    }, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 2), transformed.len);
    try std.testing.expectEqual(@as(usize, 3), transformed[0].user.content.len);
    try std.testing.expectEqualStrings(NON_VISION_USER_IMAGE_PLACEHOLDER, transformed[0].user.content[1].text.text);
    try std.testing.expectEqualStrings(NON_VISION_TOOL_IMAGE_PLACEHOLDER, transformed[1].tool_result.content[0].text.text);
}

test "transformMessages normalizes cross model tool call ids and matching tool results" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "mistral-large",
        .name = "Mistral Large",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 4000,
    };

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iterator = arguments.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = arguments;
        owned.deinit(allocator);
    }
    try arguments.put(allocator, try allocator.dupe(u8, "city"), .{ .string = "Berlin" });

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .thinking = .{ .thinking = "Need a tool call." } }},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "tool-call-1",
            .name = "weather",
            .arguments = .{ .object = arguments },
        }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 3,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .assistant = assistant },
        .{ .tool_result = .{
            .tool_call_id = "tool-call-1",
            .tool_name = "weather",
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "sunny" } }},
            .timestamp = 4,
        } },
    }, model, normalizeToolCallIdForTest);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqualStrings("Need a tool call.", transformed[0].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("normalized-tool-call-1", transformed[0].assistant.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("normalized-tool-call-1", transformed[1].tool_result.tool_call_id);
}

test "transformMessages inserts synthetic tool results for orphaned calls and drops errored or aborted assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "claude-sonnet",
        .name = "Claude Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    const orphaned_assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Calling tool" } }},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "tool-1",
            .name = "lookup",
            .arguments = .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) },
        }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 5,
    };

    const errored_assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "partial" } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "boom",
        .timestamp = 6,
    };

    const aborted_assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .tool_call = .{
            .id = "aborted-tool",
            .name = "lookup",
            .arguments = .null,
        } }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet",
        .usage = types.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "aborted",
        .timestamp = 8,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .assistant = orphaned_assistant },
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "next" } }}, .timestamp = 7 } },
        .{ .assistant = errored_assistant },
        .{ .assistant = aborted_assistant },
    }, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 3), transformed.len);
    try std.testing.expect(transformed[0] == .assistant);
    try std.testing.expect(transformed[1] == .tool_result);
    try std.testing.expectEqualStrings("tool-1", transformed[1].tool_result.tool_call_id);
    try std.testing.expect(transformed[1].tool_result.is_error);
    try std.testing.expectEqualStrings(SYNTHETIC_TOOL_RESULT_TEXT, transformed[1].tool_result.content[0].text.text);
    try std.testing.expect(transformed[2] == .user);
}

test "transformMessages preserves ordered inline content and signatures for same model" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5",
        .name = "GPT-5",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iterator = arguments.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = arguments;
        owned.deinit(allocator);
    }
    try arguments.put(allocator, try allocator.dupe(u8, "city"), .{ .string = "Berlin" });

    const content = [_]types.ContentBlock{
        .{ .text = .{ .text = "visible", .text_signature = "text-sig" } },
        .{ .thinking = .{ .thinking = "", .thinking_signature = "thinking-sig" } },
        .{ .tool_call = .{
            .id = "call_1",
            .name = "weather",
            .arguments = .{ .object = arguments },
            .thought_signature = "thought-sig",
        } },
        .{ .text = .{ .text = "after" } },
    };

    const assistant = types.AssistantMessage{
        .content = &content,
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 10,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{.{ .assistant = assistant }}, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 2), transformed.len);
    try std.testing.expectEqual(@as(usize, 4), transformed[0].assistant.content.len);
    try std.testing.expectEqualStrings("text-sig", transformed[0].assistant.content[0].text.text_signature.?);
    try std.testing.expectEqualStrings("thinking-sig", types.thinkingSignature(transformed[0].assistant.content[1].thinking).?);
    try std.testing.expectEqualStrings("call_1", transformed[0].assistant.content[2].tool_call.id);
    try std.testing.expectEqualStrings("thought-sig", transformed[0].assistant.content[2].tool_call.thought_signature.?);
    try std.testing.expectEqual(@as(usize, 1), transformed[0].assistant.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", transformed[0].assistant.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("call_1", transformed[1].tool_result.tool_call_id);
    try std.testing.expect(transformed[1].tool_result.is_error);
}

test "transformMessages strips cross model signatures and normalizes inline tool calls/results" {
    const allocator = std.testing.allocator;
    const target_model = types.Model{
        .id = "claude-sonnet",
        .name = "Claude Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iterator = arguments.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = arguments;
        owned.deinit(allocator);
    }
    try arguments.put(allocator, try allocator.dupe(u8, "query"), .{ .string = "pi" });

    const content = [_]types.ContentBlock{
        .{ .text = .{ .text = "signed", .text_signature = "text-sig" } },
        .{ .thinking = .{ .thinking = "convert to text", .thinking_signature = "thinking-sig" } },
        .{ .thinking = .{ .thinking = "", .thinking_signature = "empty-signed" } },
        .{ .thinking = .{ .thinking = "redacted", .thinking_signature = "redacted-sig", .redacted = true } },
        .{ .tool_call = .{
            .id = "tool-call-1",
            .name = "lookup",
            .arguments = .{ .object = arguments },
            .thought_signature = "thought-sig",
        } },
    };

    const assistant = types.AssistantMessage{
        .content = &content,
        .tool_calls = &[_]types.ToolCall{.{
            .id = "stale-legacy",
            .name = "stale",
            .arguments = .null,
            .thought_signature = "stale-sig",
        }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 11,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .assistant = assistant },
        .{ .tool_result = .{
            .tool_call_id = "tool-call-1",
            .tool_name = "lookup",
            .content = &[_]types.ContentBlock{.{ .text = .{ .text = "ok" } }},
            .timestamp = 12,
        } },
    }, target_model, normalizeToolCallIdForTest);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 2), transformed.len);
    try std.testing.expectEqual(@as(usize, 3), transformed[0].assistant.content.len);
    try std.testing.expectEqualStrings("signed", transformed[0].assistant.content[0].text.text);
    try std.testing.expect(transformed[0].assistant.content[0].text.text_signature == null);
    try std.testing.expectEqualStrings("convert to text", transformed[0].assistant.content[1].text.text);
    try std.testing.expectEqualStrings("normalized-tool-call-1", transformed[0].assistant.content[2].tool_call.id);
    try std.testing.expect(transformed[0].assistant.content[2].tool_call.thought_signature == null);
    try std.testing.expectEqual(@as(usize, 1), transformed[0].assistant.tool_calls.?.len);
    try std.testing.expectEqualStrings("lookup", transformed[0].assistant.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("normalized-tool-call-1", transformed[0].assistant.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("normalized-tool-call-1", transformed[1].tool_result.tool_call_id);
}

// ---------------------------------------------------------------------------
// VAL-M8D-POLISH-001 / 002 / 003 / 004: ToolResultMessage.details preservation
// ---------------------------------------------------------------------------

// Deferred provider surfaces: Cloudflare AI Gateway and Moonshot/Moonshot CN
// provider-specific OpenAI-compatible surface outside M8D core transform parity.
// The OpenAI-compat compat-detection fixture (cloudflare-workers-ai-compat)
// exercises generic request-surface behavior only, not Cloudflare-specific
// provider implementation. Full Cloudflare/Moonshot parity is out of scope for
// this feature and the M8D milestone.

test "transformMessages preserves details on real tool result for same-provider replay" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5",
        .name = "GPT-5",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var details_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iter = details_obj.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = details_obj;
        owned.deinit(allocator);
    }
    try details_obj.put(allocator, try allocator.dupe(u8, "exit_code"), .{ .integer = 0 });
    try details_obj.put(allocator, try allocator.dupe(u8, "timed_out"), .{ .bool = false });
    try details_obj.put(allocator, try allocator.dupe(u8, "output_path"), .{ .string = "/tmp/result.txt" });

    const tool_result = types.ToolResultMessage{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "ok" } }},
        .details = .{ .object = details_obj },
        .is_error = false,
        .timestamp = 100,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .tool_result = tool_result },
    }, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 1), transformed.len);
    const result = transformed[0].tool_result;
    try std.testing.expect(result.details != null);
    const details = result.details.?.object;
    try std.testing.expectEqual(@as(i64, 0), details.get("exit_code").?.integer);
    try std.testing.expectEqual(false, details.get("timed_out").?.bool);
    try std.testing.expectEqualStrings("/tmp/result.txt", details.get("output_path").?.string);
}

test "transformMessages preserves details on real tool result for cross-provider toolCallId normalization" {
    const allocator = std.testing.allocator;
    const target_model = types.Model{
        .id = "claude-sonnet",
        .name = "Claude Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    var details_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iter = details_obj.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = details_obj;
        owned.deinit(allocator);
    }
    try details_obj.put(allocator, try allocator.dupe(u8, "exit_code"), .{ .integer = 0 });
    try details_obj.put(allocator, try allocator.dupe(u8, "timed_out"), .{ .bool = false });

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iterator = arguments.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = arguments;
        owned.deinit(allocator);
    }
    try arguments.put(allocator, try allocator.dupe(u8, "cmd"), .{ .string = "echo hi" });

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "openai-call-1",
            .name = "bash",
            .arguments = .{ .object = arguments },
        }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 50,
    };

    const tool_result = types.ToolResultMessage{
        .tool_call_id = "openai-call-1",
        .tool_name = "bash",
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hi" } }},
        .details = .{ .object = details_obj },
        .is_error = false,
        .timestamp = 100,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .assistant = assistant },
        .{ .tool_result = tool_result },
    }, target_model, normalizeToolCallIdForTest);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 2), transformed.len);
    // Tool call ID was normalized
    try std.testing.expectEqualStrings("normalized-openai-call-1", transformed[0].assistant.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("normalized-openai-call-1", transformed[1].tool_result.tool_call_id);
    // Details survived normalization
    try std.testing.expect(transformed[1].tool_result.details != null);
    const details = transformed[1].tool_result.details.?.object;
    try std.testing.expectEqual(@as(i64, 0), details.get("exit_code").?.integer);
    try std.testing.expectEqual(false, details.get("timed_out").?.bool);
}

test "transformMessages preserves details on real tool result during non-vision image downgrade" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "text-only",
        .name = "Text Only",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 32000,
        .max_tokens = 4000,
    };

    var details_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iter = details_obj.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = details_obj;
        owned.deinit(allocator);
    }
    try details_obj.put(allocator, try allocator.dupe(u8, "exit_code"), .{ .integer = 1 });
    try details_obj.put(allocator, try allocator.dupe(u8, "timed_out"), .{ .bool = true });

    const tool_content = [_]types.ContentBlock{
        .{ .image = .{ .data = "base64png", .mime_type = "image/png" } },
        .{ .text = .{ .text = "screenshot captured" } },
    };

    const tool_result = types.ToolResultMessage{
        .tool_call_id = "tool-img-1",
        .tool_name = "capture",
        .content = &tool_content,
        .details = .{ .object = details_obj },
        .is_error = false,
        .timestamp = 200,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .tool_result = tool_result },
    }, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 1), transformed.len);
    const result = transformed[0].tool_result;
    // Image was downgraded to placeholder
    try std.testing.expectEqualStrings(NON_VISION_TOOL_IMAGE_PLACEHOLDER, result.content[0].text.text);
    try std.testing.expectEqualStrings("screenshot captured", result.content[1].text.text);
    // Details survived image downgrade
    try std.testing.expect(result.details != null);
    const details = result.details.?.object;
    try std.testing.expectEqual(@as(i64, 1), details.get("exit_code").?.integer);
    try std.testing.expectEqual(true, details.get("timed_out").?.bool);
}

test "transformMessages synthetic orphan tool results have null details" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5",
        .name = "GPT-5",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iter = arguments.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = arguments;
        owned.deinit(allocator);
    }
    try arguments.put(allocator, try allocator.dupe(u8, "cmd"), .{ .string = "echo hi" });

    const orphan_assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Calling tool" } }},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "orphan-call-1",
            .name = "bash",
            .arguments = .{ .object = arguments },
        }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 50,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .assistant = orphan_assistant },
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "continue" } }}, .timestamp = 60 } },
    }, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 3), transformed.len);
    // Synthetic tool result was inserted
    try std.testing.expect(transformed[1] == .tool_result);
    try std.testing.expectEqualStrings("orphan-call-1", transformed[1].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("bash", transformed[1].tool_result.tool_name);
    try std.testing.expect(transformed[1].tool_result.is_error);
    try std.testing.expectEqualStrings(SYNTHETIC_TOOL_RESULT_TEXT, transformed[1].tool_result.content[0].text.text);
    // Synthetic result must NOT invent details
    try std.testing.expect(transformed[1].tool_result.details == null);
}

// ---------------------------------------------------------------------------
// response_model clone/transform preservation
// ---------------------------------------------------------------------------

test "transformMessages preserves response_model for same-provider replay" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "openrouter/auto",
        .name = "OpenRouter Auto",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello from routed model." } }},
        .api = "openai-completions",
        .provider = "openrouter",
        .model = "openrouter/auto",
        .response_model = "anthropic/claude-opus-4.7",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 100,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{.{ .assistant = assistant }}, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 1), transformed.len);
    try std.testing.expectEqualStrings("openrouter/auto", transformed[0].assistant.model);
    try std.testing.expect(transformed[0].assistant.response_model != null);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", transformed[0].assistant.response_model.?);
}

test "transformMessages leaves response_model null when source has none" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5",
        .name = "GPT-5",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "No routed model." } }},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 200,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{.{ .assistant = assistant }}, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 1), transformed.len);
    try std.testing.expect(transformed[0].assistant.response_model == null);
}

test "transformMessages preserves response_model through cross-provider replay" {
    const allocator = std.testing.allocator;
    const target_model = types.Model{
        .id = "claude-sonnet",
        .name = "Claude Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Cross provider with routed model." } }},
        .api = "openai-completions",
        .provider = "openrouter",
        .model = "openrouter/auto",
        .response_model = "anthropic/claude-opus-4.7",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 300,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{.{ .assistant = assistant }}, target_model, normalizeToolCallIdForTest);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 1), transformed.len);
    // model remains the original requested model, not the routed one
    try std.testing.expectEqualStrings("openrouter/auto", transformed[0].assistant.model);
    // response_model is preserved through cross-provider clone
    try std.testing.expect(transformed[0].assistant.response_model != null);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", transformed[0].assistant.response_model.?);
}

test "transformMessages preserves response_model with tool calls and synthetic results" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "openrouter/auto",
        .name = "OpenRouter Auto",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var arguments = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer {
        var iter = arguments.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        var owned = arguments;
        owned.deinit(allocator);
    }
    try arguments.put(allocator, try allocator.dupe(u8, "query"), .{ .string = "test" });

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Using tool." } }},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "call-routed-1",
            .name = "search",
            .arguments = .{ .object = arguments },
        }},
        .api = "openai-completions",
        .provider = "openrouter",
        .model = "openrouter/auto",
        .response_model = "anthropic/claude-opus-4.7",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 400,
    };

    const transformed = try transformMessages(allocator, &[_]types.Message{
        .{ .assistant = assistant },
        .{ .user = .{ .content = &[_]types.ContentBlock{.{ .text = .{ .text = "continue" } }}, .timestamp = 500 } },
    }, model, null);
    defer freeMessages(allocator, transformed);

    try std.testing.expectEqual(@as(usize, 3), transformed.len);
    // assistant response_model preserved despite synthetic tool result insertion
    try std.testing.expectEqualStrings("openrouter/auto", transformed[0].assistant.model);
    try std.testing.expect(transformed[0].assistant.response_model != null);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.7", transformed[0].assistant.response_model.?);
    // synthetic tool result has no response_model (not applicable)
    try std.testing.expect(transformed[1] == .tool_result);
}
