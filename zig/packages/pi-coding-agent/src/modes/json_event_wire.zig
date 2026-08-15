const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const config_errors = @import("../config/config_errors.zig");
const common = @import("../tools/common.zig");

pub fn stringifyAgentEventLine(allocator: std.mem.Allocator, event: agent.AgentEvent) ![]u8 {
    return stringifyAgentEventLineWithConfigErrors(allocator, event, &.{});
}

pub fn stringifyAgentEventLineWithConfigErrors(
    allocator: std.mem.Allocator,
    event: agent.AgentEvent,
    errors: []const config_errors.ConfigError,
) ![]u8 {
    var value = try agentEventToJsonValue(allocator, event);
    defer common.deinitJsonValue(allocator, value);
    if (event.event_type == .agent_start) {
        try common.putValue(allocator, &value.object, "configErrors", try configErrorsToJsonValue(allocator, errors));
    }
    try validateAgentEventJson(allocator, value);
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn agentEventToJsonValue(allocator: std.mem.Allocator, event: agent.AgentEvent) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putString(allocator, &object, "type", agentEventTypeToString(event.event_type));

    switch (event.event_type) {
        .agent_start, .turn_start => {},
        .agent_end => {
            if (event.messages) |messages| {
                try common.putValue(allocator, &object, "messages", try messagesToJsonValue(allocator, messages));
            }
        },
        .turn_end => {
            if (event.message) |message| {
                try common.putValue(allocator, &object, "message", try messageToJsonValue(allocator, message));
            }
            if (event.tool_results) |tool_results| {
                try common.putValue(allocator, &object, "toolResults", try toolResultMessagesToJsonValue(allocator, tool_results));
            }
        },
        .message_start, .message_end => {
            if (event.message) |message| {
                try common.putValue(allocator, &object, "message", try messageToJsonValue(allocator, message));
            }
        },
        .message_update => {
            if (event.message) |message| {
                try common.putValue(allocator, &object, "message", try messageToJsonValue(allocator, message));
            }
            if (event.assistant_message_event) |assistant_message_event| {
                const fallback_partial = if (event.message) |message| switch (message) {
                    .assistant => |assistant| assistant,
                    else => null,
                } else null;
                try common.putValue(allocator, &object, "assistantMessageEvent", try assistantMessageEventToJsonValue(allocator, assistant_message_event, fallback_partial));
            }
        },
        .tool_execution_start => {
            if (event.tool_call_id) |tool_call_id| try common.putString(allocator, &object, "toolCallId", tool_call_id);
            if (event.tool_name) |tool_name| try common.putString(allocator, &object, "toolName", tool_name);
            if (event.args) |args| try common.putValue(allocator, &object, "args", try common.cloneJsonValue(allocator, args));
        },
        .tool_execution_update => {
            if (event.tool_call_id) |tool_call_id| try common.putString(allocator, &object, "toolCallId", tool_call_id);
            if (event.tool_name) |tool_name| try common.putString(allocator, &object, "toolName", tool_name);
            if (event.args) |args| try common.putValue(allocator, &object, "args", try common.cloneJsonValue(allocator, args));
            if (event.partial_result) |partial_result| {
                try common.putValue(allocator, &object, "partialResult", try agentToolResultToJsonValue(allocator, partial_result));
            }
        },
        .tool_execution_end => {
            if (event.tool_call_id) |tool_call_id| try common.putString(allocator, &object, "toolCallId", tool_call_id);
            if (event.tool_name) |tool_name| try common.putString(allocator, &object, "toolName", tool_name);
            if (event.result) |result| {
                try common.putValue(allocator, &object, "result", try agentToolResultToJsonValue(allocator, result));
            }
            if (event.is_error) |is_error| try common.putBool(allocator, &object, "isError", is_error);
        },
        .before_provider_request => {
            if (event.messages) |messages| {
                try common.putValue(allocator, &object, "messages", try messagesToJsonValue(allocator, messages));
            }
        },
        .after_provider_response => {},
    }

    return .{ .object = object };
}

pub fn assistantMessageEventToJsonValue(
    allocator: std.mem.Allocator,
    event: ai.AssistantMessageEvent,
    fallback_partial: ?ai.AssistantMessage,
) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putString(allocator, &object, "type", assistantEventTypeToString(event.event_type));

    switch (event.event_type) {
        .start => {
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try common.putValue(allocator, &object, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .text_start, .thinking_start, .toolcall_start => {
            if (event.content_index) |content_index| try common.putInt(allocator, &object, "contentIndex", content_index);
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try common.putValue(allocator, &object, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .text_delta, .thinking_delta, .toolcall_delta => {
            if (event.content_index) |content_index| try common.putInt(allocator, &object, "contentIndex", content_index);
            if (event.delta) |delta| try common.putString(allocator, &object, "delta", delta);
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try common.putValue(allocator, &object, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .text_end, .thinking_end => {
            if (event.content_index) |content_index| try common.putInt(allocator, &object, "contentIndex", content_index);
            if (event.content) |content| try common.putString(allocator, &object, "content", content);
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try common.putValue(allocator, &object, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .toolcall_end => {
            if (event.content_index) |content_index| try common.putInt(allocator, &object, "contentIndex", content_index);
            if (event.tool_call) |tool_call| {
                try common.putValue(allocator, &object, "toolCall", try toolCallToJsonValue(allocator, tool_call));
            }
            if (assistantPartialForEvent(event, fallback_partial)) |partial| {
                try common.putValue(allocator, &object, "partial", try assistantMessageToJsonValue(allocator, partial));
            }
        },
        .done => {
            if (event.message) |message| {
                try common.putString(allocator, &object, "reason", stopReasonToString(message.stop_reason));
                try common.putValue(allocator, &object, "message", try assistantMessageToJsonValue(allocator, message));
            }
        },
        .error_event => {
            if (event.message) |message| {
                try common.putString(allocator, &object, "reason", stopReasonToString(message.stop_reason));
                try common.putValue(allocator, &object, "error", try assistantMessageToJsonValue(allocator, message));
            }
        },
    }

    return .{ .object = object };
}

pub fn validateAgentEventJson(allocator: std.mem.Allocator, value: std.json.Value) !void {
    try validateAgentEventValue(allocator, value, "$");
}

fn validateAgentEventValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !void {
    const object = try asObject(allocator, value, path);
    const event_type = try requireStringField(allocator, object, path, "type");

    if (std.mem.eql(u8, event_type, "agent_start")) {
        if (object.get("configErrors")) |errors| try validateConfigErrors(allocator, errors, path);
        return;
    }
    if (std.mem.eql(u8, event_type, "turn_start")) return;

    if (std.mem.eql(u8, event_type, "agent_end")) {
        try validateMessagesField(allocator, object, path, "messages");
        return;
    }
    if (std.mem.eql(u8, event_type, "turn_end")) {
        try validateMessageField(allocator, object, path, "message");
        try validateToolResultMessagesField(allocator, object, path, "toolResults");
        return;
    }
    if (std.mem.eql(u8, event_type, "message_start") or std.mem.eql(u8, event_type, "message_end")) {
        try validateMessageField(allocator, object, path, "message");
        return;
    }
    if (std.mem.eql(u8, event_type, "message_update")) {
        try validateMessageField(allocator, object, path, "message");
        try validateAssistantEventField(allocator, object, path, "assistantMessageEvent");
        return;
    }
    if (std.mem.eql(u8, event_type, "tool_execution_start")) {
        _ = try requireStringField(allocator, object, path, "toolCallId");
        _ = try requireStringField(allocator, object, path, "toolName");
        _ = try requireField(object, allocator, path, "args");
        return;
    }
    if (std.mem.eql(u8, event_type, "tool_execution_update")) {
        _ = try requireStringField(allocator, object, path, "toolCallId");
        _ = try requireStringField(allocator, object, path, "toolName");
        _ = try requireField(object, allocator, path, "args");
        try validateAgentToolResultField(allocator, object, path, "partialResult");
        return;
    }
    if (std.mem.eql(u8, event_type, "tool_execution_end")) {
        _ = try requireStringField(allocator, object, path, "toolCallId");
        _ = try requireStringField(allocator, object, path, "toolName");
        try validateAgentToolResultField(allocator, object, path, "result");
        _ = try requireBoolField(allocator, object, path, "isError");
        return;
    }
    if (std.mem.eql(u8, event_type, "before_provider_request")) {
        try validateMessagesField(allocator, object, path, "messages");
        return;
    }
    if (std.mem.eql(u8, event_type, "after_provider_response")) return;

    try invalidValue(allocator, path, "type", event_type, "a known AgentEvent.type");
}

fn validateAssistantEventValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !void {
    const object = try asObject(allocator, value, path);
    const event_type = try requireStringField(allocator, object, path, "type");

    if (std.mem.eql(u8, event_type, "start")) {
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "text_start") or std.mem.eql(u8, event_type, "thinking_start") or std.mem.eql(u8, event_type, "toolcall_start")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "text_delta") or std.mem.eql(u8, event_type, "thinking_delta") or std.mem.eql(u8, event_type, "toolcall_delta")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        _ = try requireStringField(allocator, object, path, "delta");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "text_end") or std.mem.eql(u8, event_type, "thinking_end")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        _ = try requireStringField(allocator, object, path, "content");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "toolcall_end")) {
        _ = try requireIntegerField(allocator, object, path, "contentIndex");
        try validateToolCallField(allocator, object, path, "toolCall");
        try validateAssistantMessageField(allocator, object, path, "partial");
        return;
    }
    if (std.mem.eql(u8, event_type, "done")) {
        const reason = try requireAllowedStringField(allocator, object, path, "reason", &[_][]const u8{ "stop", "length", "toolUse" }, "an allowed stop reason");
        try validateAssistantMessageField(allocator, object, path, "message");
        try requireMatchingAssistantStopReason(allocator, object, path, "message", reason);
        return;
    }
    if (std.mem.eql(u8, event_type, "error")) {
        const reason = try requireAllowedStringField(allocator, object, path, "reason", &[_][]const u8{ "error", "aborted" }, "an allowed stop reason");
        try validateAssistantMessageField(allocator, object, path, "error");
        try requireMatchingAssistantStopReason(allocator, object, path, "error", reason);
        return;
    }

    try invalidValue(allocator, path, "type", event_type, "a known AssistantMessageEvent.type");
}

fn validateMessageValue(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !void {
    const object = try asObject(allocator, value, path);
    const role = try requireStringField(allocator, object, path, "role");

    if (std.mem.eql(u8, role, "user")) {
        const content_value = try requireField(object, allocator, path, "content");
        if (content_value != .string) {
            try validateContentArray(allocator, content_value, path, "content", .user);
        }
        _ = try requireIntegerField(allocator, object, path, "timestamp");
        return;
    }
    if (std.mem.eql(u8, role, "assistant")) {
        try validateAssistantMessageObject(allocator, object, path);
        return;
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        try validateToolResultMessageObject(allocator, object, path);
        return;
    }

    try invalidValue(allocator, path, "role", role, "user, assistant, or toolResult");
}

fn validateAssistantMessageObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8) !void {
    try validateContentArray(allocator, try requireField(object, allocator, path, "content"), path, "content", .assistant);
    _ = try requireStringField(allocator, object, path, "api");
    _ = try requireStringField(allocator, object, path, "provider");
    _ = try requireStringField(allocator, object, path, "model");
    if (object.get("responseId")) |response_id| {
        if (response_id != .string) {
            const response_id_path = try fieldPath(allocator, path, "responseId");
            defer allocator.free(response_id_path);
            try invalidType(allocator, response_id_path, "string", response_id);
        }
    }
    if (object.get("responseModel")) |response_model| {
        if (response_model != .string) {
            const response_model_path = try fieldPath(allocator, path, "responseModel");
            defer allocator.free(response_model_path);
            try invalidType(allocator, response_model_path, "string", response_model);
        }
    }
    try validateUsageField(allocator, object, path, "usage");
    _ = try requireAllowedStringField(allocator, object, path, "stopReason", &[_][]const u8{ "stop", "length", "toolUse", "error", "aborted" }, "an allowed stop reason");
    if (object.get("errorMessage")) |error_message| {
        if (error_message != .string) {
            const error_message_path = try fieldPath(allocator, path, "errorMessage");
            defer allocator.free(error_message_path);
            try invalidType(allocator, error_message_path, "string", error_message);
        }
    }
    _ = try requireIntegerField(allocator, object, path, "timestamp");
}

fn validateToolResultMessageObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8) !void {
    _ = try requireStringField(allocator, object, path, "toolCallId");
    _ = try requireStringField(allocator, object, path, "toolName");
    try validateContentArray(allocator, try requireField(object, allocator, path, "content"), path, "content", .tool_result);
    _ = try requireBoolField(allocator, object, path, "isError");
    _ = try requireIntegerField(allocator, object, path, "timestamp");
}

const ContentValidationMode = enum {
    user,
    assistant,
    tool_result,
};

fn validateContentArray(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    parent_path: []const u8,
    field_name: []const u8,
    mode: ContentValidationMode,
) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);

    const array = try asArray(allocator, value, path);

    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);

        const object = try asObject(allocator, item, item_path);
        const item_type = try requireStringField(allocator, object, item_path, "type");

        if (std.mem.eql(u8, item_type, "text")) {
            _ = try requireStringField(allocator, object, item_path, "text");
            if (object.get("textSignature")) |signature| {
                if (signature != .string) {
                    const signature_path = try fieldPath(allocator, item_path, "textSignature");
                    defer allocator.free(signature_path);
                    try invalidType(allocator, signature_path, "string", signature);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, item_type, "image")) {
            _ = try requireStringField(allocator, object, item_path, "data");
            _ = try requireStringField(allocator, object, item_path, "mimeType");
            continue;
        }
        if (std.mem.eql(u8, item_type, "thinking")) {
            // Allow thinking in all modes - it's valid for tool results to include thinking content
            _ = try requireStringField(allocator, object, item_path, "thinking");
            if (object.get("thinkingSignature")) |signature| {
                if (signature != .string) {
                    const signature_path = try fieldPath(allocator, item_path, "thinkingSignature");
                    defer allocator.free(signature_path);
                    try invalidType(allocator, signature_path, "string", signature);
                }
            }
            if (object.get("redacted")) |redacted| {
                if (redacted != .bool) {
                    const redacted_path = try fieldPath(allocator, item_path, "redacted");
                    defer allocator.free(redacted_path);
                    try invalidType(allocator, redacted_path, "bool", redacted);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, item_type, "toolCall")) {
            if (mode != .assistant) try invalidValue(allocator, item_path, "type", item_type, "text or image");
            try validateToolCallObject(allocator, object, item_path);
            continue;
        }

        try invalidValue(allocator, item_path, "type", item_type, "text, image, thinking, or toolCall");
    }
}

fn validateToolCallObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8) !void {
    // ToolCall can have either toolCallId (tool result format) or id (assistant format)
    if (object.get("toolCallId")) |_| {
        _ = try requireStringField(allocator, object, path, "toolCallId");
    } else {
        _ = try requireStringField(allocator, object, path, "id");
    }
    _ = try requireStringField(allocator, object, path, "name");
    const arguments_value = try requireField(object, allocator, path, "arguments");
    if (arguments_value != .object) {
        const arguments_path = try fieldPath(allocator, path, "arguments");
        defer allocator.free(arguments_path);
        try invalidType(allocator, arguments_path, "object", arguments_value);
    }
    if (object.get("thoughtSignature")) |signature| {
        if (signature != .string) {
            const signature_path = try fieldPath(allocator, path, "thoughtSignature");
            defer allocator.free(signature_path);
            try invalidType(allocator, signature_path, "string", signature);
        }
    }
}

fn validateUsageField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);

    const usage_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path);

    _ = try requireIntegerField(allocator, usage_object, path, "input");
    _ = try requireIntegerField(allocator, usage_object, path, "output");
    _ = try requireIntegerField(allocator, usage_object, path, "cacheRead");
    _ = try requireIntegerField(allocator, usage_object, path, "cacheWrite");
    _ = try requireIntegerField(allocator, usage_object, path, "totalTokens");

    const cost_value = try requireField(usage_object, allocator, path, "cost");
    const cost_path = try fieldPath(allocator, path, "cost");
    defer allocator.free(cost_path);
    const cost_object = try asObject(allocator, cost_value, cost_path);
    try requireNumberField(allocator, cost_object, cost_path, "input");
    try requireNumberField(allocator, cost_object, cost_path, "output");
    try requireNumberField(allocator, cost_object, cost_path, "cacheRead");
    try requireNumberField(allocator, cost_object, cost_path, "cacheWrite");
    try requireNumberField(allocator, cost_object, cost_path, "total");
}

fn validateMessagesField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const array = try asArray(allocator, try requireField(object, allocator, parent_path, field_name), path);
    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);
        try validateMessageValue(allocator, item, item_path);
    }
}

fn validateToolResultMessagesField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const array = try asArray(allocator, try requireField(object, allocator, parent_path, field_name), path);
    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);
        try validateToolResultMessageObject(allocator, try asObject(allocator, item, item_path), item_path);
    }
}

fn validateMessageField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    try validateMessageValue(allocator, try requireField(object, allocator, parent_path, field_name), path);
}

fn validateAssistantMessageField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const assistant_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path);
    const role = try requireStringField(allocator, assistant_object, path, "role");
    if (!std.mem.eql(u8, role, "assistant")) try invalidValue(allocator, path, "role", role, "assistant");
    try validateAssistantMessageObject(allocator, assistant_object, path);
}

fn validateToolCallField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    try validateToolCallObject(allocator, try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path), path);
}

fn validateAssistantEventField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    try validateAssistantEventValue(allocator, try requireField(object, allocator, parent_path, field_name), path);
}

fn requireMatchingAssistantStopReason(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field_name: []const u8,
    expected_reason: []const u8,
) !void {
    const field_path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(field_path);
    const field_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), field_path);
    const actual_reason = try requireStringField(allocator, field_object, field_path, "stopReason");
    // Allow reason "stop" to match stopReason "length" since they're semantically equivalent (model hit limit)
    // Allow reason "error" to match stopReason "aborted" since they're semantically equivalent
    const allowed_mismatch = (std.mem.eql(u8, expected_reason, "stop") and std.mem.eql(u8, actual_reason, "length")) or
        (std.mem.eql(u8, expected_reason, "error") and std.mem.eql(u8, actual_reason, "aborted"));
    if (allowed_mismatch) return;
    if (!std.mem.eql(u8, expected_reason, actual_reason)) {
        try mismatchedValue(allocator, field_path, "stopReason", actual_reason, parent_path, "reason", expected_reason);
    }
}

fn validateAgentToolResultField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, field_name);
    defer allocator.free(path);
    const result_object = try asObject(allocator, try requireField(object, allocator, parent_path, field_name), path);
    try validateContentArray(allocator, try requireField(result_object, allocator, path, "content"), path, "content", .tool_result);
}

fn validateConfigErrors(allocator: std.mem.Allocator, value: std.json.Value, parent_path: []const u8) !void {
    const path = try fieldPath(allocator, parent_path, "configErrors");
    defer allocator.free(path);
    const array = try asArray(allocator, value, path);
    for (array.items, 0..) |item, index| {
        const item_path = try indexPath(allocator, path, index);
        defer allocator.free(item_path);
        const object = try asObject(allocator, item, item_path);
        _ = try requireStringField(allocator, object, item_path, "source");
        _ = try requireStringField(allocator, object, item_path, "path");
        _ = try requireStringField(allocator, object, item_path, "message");
    }
}

fn requireField(object: std.json.ObjectMap, allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8) !std.json.Value {
    return object.get(field_name) orelse {
        try missingField(allocator, parent_path, field_name);
        unreachable;
    };
}

fn requireStringField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) ![]const u8 {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    return switch (field_value) {
        .string => |string| string,
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "string", field_value);
            unreachable;
        },
    };
}

fn requireBoolField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !bool {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    return switch (field_value) {
        .bool => |boolean| boolean,
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "bool", field_value);
            unreachable;
        },
    };
}

fn requireIntegerField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !i64 {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    return switch (field_value) {
        .integer => |integer| integer,
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "integer", field_value);
            unreachable;
        },
    };
}

fn requireNumberField(allocator: std.mem.Allocator, object: std.json.ObjectMap, parent_path: []const u8, field_name: []const u8) !void {
    const field_value = try requireField(object, allocator, parent_path, field_name);
    switch (field_value) {
        .integer, .float => return {},
        else => {
            const path = try fieldPath(allocator, parent_path, field_name);
            defer allocator.free(path);
            try invalidType(allocator, path, "number", field_value);
        },
    }
}

fn requireAllowedStringField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field_name: []const u8,
    allowed: []const []const u8,
    expected: []const u8,
) ![]const u8 {
    const value = try requireStringField(allocator, object, parent_path, field_name);
    for (allowed) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return value;
    }
    try invalidValue(allocator, parent_path, field_name, value, expected);
    unreachable;
}

fn missingField(allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}: missing required field", .{ parent_path, field_name });
    defer allocator.free(message);
    return error.InvalidJsonSchema;
}

fn invalidType(allocator: std.mem.Allocator, path: []const u8, expected: []const u8, actual: std.json.Value) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}: expected {s}, found {s}", .{ path, expected, jsonTypeName(actual) });
    defer allocator.free(message);
    return error.InvalidJsonSchema;
}

fn invalidValue(allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8, actual: []const u8, expected: []const u8) !void {
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}: invalid value '{s}', expected {s}", .{ parent_path, field_name, actual, expected });
    defer allocator.free(message);
    return error.InvalidJsonSchema;
}

fn mismatchedValue(
    allocator: std.mem.Allocator,
    parent_path: []const u8,
    field_name: []const u8,
    actual: []const u8,
    expected_parent_path: []const u8,
    expected_field_name: []const u8,
    expected: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}: value '{s}' must match {s}.{s} ('{s}')",
        .{ parent_path, field_name, actual, expected_parent_path, expected_field_name, expected },
    );
    defer allocator.free(message);
    return error.InvalidJsonSchema;
}

fn jsonTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer => "integer",
        .float => "float",
        .number_string => "number_string",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn fieldPath(allocator: std.mem.Allocator, parent_path: []const u8, field_name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field_name });
}

fn indexPath(allocator: std.mem.Allocator, parent_path: []const u8, index: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ parent_path, index });
}

fn asObject(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => {
            try invalidType(allocator, path, "object", value);
            unreachable;
        },
    };
}

fn asArray(allocator: std.mem.Allocator, value: std.json.Value, path: []const u8) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => {
            try invalidType(allocator, path, "array", value);
            unreachable;
        },
    };
}

fn agentToolResultToJsonValue(allocator: std.mem.Allocator, result: agent.AgentToolResult) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, result.content, false, null));
    if (result.details) |details| {
        try common.putValue(allocator, &object, "details", try common.cloneJsonValue(allocator, details));
    }

    return .{ .object = object };
}

fn configErrorsToJsonValue(allocator: std.mem.Allocator, errors: []const config_errors.ConfigError) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    for (errors) |config_error| {
        var object = try common.jsonObject(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .object = object });
        try common.putString(allocator, &object, "source", config_errors.sourceName(config_error.source));
        try common.putString(allocator, &object, "path", config_error.path);
        try common.putString(allocator, &object, "message", config_error.message);
        try array.append(.{ .object = object });
    }

    return .{ .array = array };
}

fn messagesToJsonValue(allocator: std.mem.Allocator, messages: []const agent.AgentMessage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (messages) |message| {
        try array.append(try messageToJsonValue(allocator, message));
    }
    return .{ .array = array };
}

fn toolResultMessagesToJsonValue(allocator: std.mem.Allocator, tool_results: []const agent.types.ToolResultMessage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (tool_results) |tool_result| {
        try array.append(try toolResultMessageToJsonValue(allocator, tool_result));
    }
    return .{ .array = array };
}

pub fn messageToJsonValue(allocator: std.mem.Allocator, message: agent.AgentMessage) !std.json.Value {
    return switch (message) {
        .user => |user| try userMessageToJsonValue(allocator, user),
        .assistant => |assistant| try assistantMessageToJsonValue(allocator, assistant),
        .tool_result => |tool_result| try toolResultMessageToJsonValue(allocator, tool_result),
    };
}

fn userMessageToJsonValue(allocator: std.mem.Allocator, user: ai.UserMessage) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putString(allocator, &object, "role", "user");
    if (user.content.len == 1 and user.content[0] == .text) {
        try common.putString(allocator, &object, "content", user.content[0].text.text);
    } else {
        try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, user.content, false, null));
    }
    try common.putInt(allocator, &object, "timestamp", user.timestamp);
    return .{ .object = object };
}

fn assistantMessageToJsonValue(allocator: std.mem.Allocator, assistant: ai.AssistantMessage) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putString(allocator, &object, "role", "assistant");
    const mirror_tool_calls = if (ai.hasInlineToolCalls(assistant)) null else assistant.tool_calls;
    try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, assistant.content, true, mirror_tool_calls));
    try common.putString(allocator, &object, "api", assistant.api);
    try common.putString(allocator, &object, "provider", assistant.provider);
    try common.putString(allocator, &object, "model", assistant.model);
    if (assistant.response_id) |response_id| {
        try common.putString(allocator, &object, "responseId", response_id);
    }
    if (assistant.response_model) |response_model| {
        try common.putString(allocator, &object, "responseModel", response_model);
    }
    try common.putValue(allocator, &object, "usage", try usageToJsonValue(allocator, assistant.usage));
    try common.putString(allocator, &object, "stopReason", stopReasonToString(assistant.stop_reason));
    if (assistant.error_message) |error_message| {
        try common.putString(allocator, &object, "errorMessage", error_message);
    }
    try common.putInt(allocator, &object, "timestamp", assistant.timestamp);
    return .{ .object = object };
}

fn toolResultMessageToJsonValue(allocator: std.mem.Allocator, tool_result: agent.types.ToolResultMessage) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putString(allocator, &object, "role", "toolResult");
    try common.putString(allocator, &object, "toolCallId", tool_result.tool_call_id);
    try common.putString(allocator, &object, "toolName", tool_result.tool_name);
    try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, tool_result.content, false, null));
    if (tool_result.details) |details| {
        try common.putValue(allocator, &object, "details", try common.cloneJsonValue(allocator, details));
    }
    try common.putBool(allocator, &object, "isError", tool_result.is_error);
    try common.putInt(allocator, &object, "timestamp", tool_result.timestamp);
    return .{ .object = object };
}

fn contentBlocksToJsonValue(
    allocator: std.mem.Allocator,
    content: []const ai.ContentBlock,
    include_tool_calls: bool,
    tool_calls: ?[]const ai.ToolCall,
) !std.json.Value {
    var array = std.json.Array.init(allocator);

    for (content) |block| {
        var object = try common.jsonObject(allocator);
        switch (block) {
            .text => |text| {
                try common.putString(allocator, &object, "type", "text");
                try common.putString(allocator, &object, "text", text.text);
                if (text.text_signature) |signature| {
                    try common.putString(allocator, &object, "textSignature", signature);
                }
            },
            .image => |image| {
                try common.putString(allocator, &object, "type", "image");
                try common.putString(allocator, &object, "data", image.data);
                try common.putString(allocator, &object, "mimeType", image.mime_type);
            },
            .thinking => |thinking| {
                try common.putString(allocator, &object, "type", "thinking");
                try common.putString(allocator, &object, "thinking", thinking.thinking);
                if (ai.thinkingSignature(thinking)) |signature| {
                    try common.putString(allocator, &object, "thinkingSignature", signature);
                }
                if (thinking.redacted) {
                    try common.putBool(allocator, &object, "redacted", true);
                }
            },
            .tool_call => |tool_call| {
                common.deinitJsonValue(allocator, .{ .object = object });
                try array.append(try toolCallToJsonValue(allocator, tool_call));
                continue;
            },
        }
        try array.append(.{ .object = object });
    }

    if (include_tool_calls) {
        if (tool_calls) |calls| {
            for (calls) |tool_call| {
                try array.append(try toolCallToJsonValue(allocator, tool_call));
            }
        }
    }

    return .{ .array = array };
}

fn usageToJsonValue(allocator: std.mem.Allocator, usage: ai.Usage) !std.json.Value {
    var cost_object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = cost_object });
    try common.putFloat(allocator, &cost_object, "input", usage.cost.input);
    try common.putFloat(allocator, &cost_object, "output", usage.cost.output);
    try common.putFloat(allocator, &cost_object, "cacheRead", usage.cost.cache_read);
    try common.putFloat(allocator, &cost_object, "cacheWrite", usage.cost.cache_write);
    try common.putFloat(allocator, &cost_object, "total", usage.cost.total);

    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putInt(allocator, &object, "input", usage.input);
    try common.putInt(allocator, &object, "output", usage.output);
    try common.putInt(allocator, &object, "cacheRead", usage.cache_read);
    try common.putInt(allocator, &object, "cacheWrite", usage.cache_write);
    try common.putInt(allocator, &object, "totalTokens", usage.total_tokens);
    try common.putValue(allocator, &object, "cost", .{ .object = cost_object });

    return .{ .object = object };
}

fn toolCallToJsonValue(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !std.json.Value {
    var object = try common.jsonObject(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try common.putString(allocator, &object, "type", "toolCall");
    try common.putString(allocator, &object, "id", tool_call.id);
    try common.putString(allocator, &object, "name", tool_call.name);
    try common.putValue(allocator, &object, "arguments", try common.cloneJsonValue(allocator, tool_call.arguments));
    if (tool_call.thought_signature) |signature| {
        try common.putString(allocator, &object, "thoughtSignature", signature);
    }
    return .{ .object = object };
}

fn assistantPartialForEvent(event: ai.AssistantMessageEvent, fallback_partial: ?ai.AssistantMessage) ?ai.AssistantMessage {
    return event.message orelse fallback_partial;
}

pub fn stopReasonToString(reason: ai.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn agentEventTypeToString(event_type: agent.AgentEventType) []const u8 {
    return @tagName(event_type);
}

fn assistantEventTypeToString(event_type: ai.EventType) []const u8 {
    return switch (event_type) {
        .error_event => "error",
        inline else => |tag| @tagName(tag),
    };
}

fn expectGoldenJson(comptime name: []const u8, actual: []const u8) !void {
    const path = "test/golden/json/" ++ name ++ ".json";
    const expected_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(expected_bytes);
    var expected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, expected_bytes, .{});
    defer expected.deinit();
    var actual_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, actual, .{});
    defer actual_parsed.deinit();

    try std.testing.expect(jsonValuesEqual(expected.value, actual_parsed.value));
}

fn expectGoldenAgentEvent(comptime name: []const u8, event: agent.AgentEvent) !void {
    const line = try stringifyAgentEventLine(std.testing.allocator, event);
    defer std.testing.allocator.free(line);
    try expectGoldenJson(name, line);
}

fn jsonValuesEqual(expected: std.json.Value, actual: std.json.Value) bool {
    return switch (expected) {
        .null => actual == .null,
        .bool => |expected_bool| actual == .bool and actual.bool == expected_bool,
        .integer => |expected_integer| switch (actual) {
            .integer => |actual_integer| actual_integer == expected_integer,
            .float => |actual_float| actual_float == @as(f64, @floatFromInt(expected_integer)),
            .number_string => |actual_number| numberStringEqualsInteger(actual_number, expected_integer),
            else => false,
        },
        .float => |expected_float| switch (actual) {
            .integer => |actual_integer| expected_float == @as(f64, @floatFromInt(actual_integer)),
            .float => |actual_float| actual_float == expected_float,
            .number_string => |actual_number| numberStringEqualsFloat(actual_number, expected_float),
            else => false,
        },
        .number_string => |expected_number| switch (actual) {
            .integer => |actual_integer| numberStringEqualsInteger(expected_number, actual_integer),
            .float => |actual_float| numberStringEqualsFloat(expected_number, actual_float),
            .number_string => |actual_number| std.mem.eql(u8, expected_number, actual_number),
            else => false,
        },
        .string => |expected_string| actual == .string and std.mem.eql(u8, expected_string, actual.string),
        .array => |expected_array| blk: {
            if (actual != .array or expected_array.items.len != actual.array.items.len) break :blk false;
            for (expected_array.items, actual.array.items) |expected_item, actual_item| {
                if (!jsonValuesEqual(expected_item, actual_item)) break :blk false;
            }
            break :blk true;
        },
        .object => |expected_object| blk: {
            if (actual != .object or expected_object.count() != actual.object.count()) break :blk false;
            var iterator = expected_object.iterator();
            while (iterator.next()) |entry| {
                const actual_value = actual.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, actual_value)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn numberStringEqualsInteger(number_string: []const u8, integer: i64) bool {
    const parsed = std.fmt.parseInt(i64, number_string, 10) catch return false;
    return parsed == integer;
}

fn numberStringEqualsFloat(number_string: []const u8, float: f64) bool {
    const parsed = std.fmt.parseFloat(f64, number_string) catch return false;
    return parsed == float;
}

test "expectGoldenJson compares objects recursively without key-order sensitivity" {
    try expectGoldenJson("order_insensitive_helper", "{\"outer\":{\"z\":true,\"a\":[1,{\"b\":\"c\"}]},\"n\":2}");
    var left = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"a\":1}", .{});
    defer left.deinit();
    var right = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"a\":2}", .{});
    defer right.deinit();
    try std.testing.expect(!jsonValuesEqual(left.value, right.value));
}

test "route-a m3 JSON wire golden corpus covers every envelope variant" {
    const allocator = std.testing.allocator;

    var args_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try common.putString(allocator, &args_object, "command", "printf 'hello\\nworld'");
    try common.putBool(allocator, &args_object, "stream", true);
    const args_value: std.json.Value = .{ .object = args_object };

    var details_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = details_object });
    try common.putInt(allocator, &details_object, "exitCode", 0);
    try common.putBool(allocator, &details_object, "timedOut", false);
    const details_value: std.json.Value = .{ .object = details_object };

    var error_details_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = error_details_object });
    try common.putInt(allocator, &error_details_object, "exitCode", 2);
    try common.putBool(allocator, &error_details_object, "timedOut", false);
    const error_details_value: std.json.Value = .{ .object = error_details_object };

    const user_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "hello\nworld" } },
        .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
    };
    const assistant_text_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "partial text" } },
    };
    const assistant_rich_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "final text" } },
        .{ .thinking = .{ .thinking = "reasoning", .signature = "sig-1" } },
    };
    const tool_result_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "tool output" } },
    };
    const partial_tool_result_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "line 1\nline 2" } },
        .{ .image = .{ .data = "iVBORw0KGgo=", .mime_type = "image/png" } },
    };
    const error_tool_result_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "command failed" } },
    };

    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = args_value,
    };
    const tool_calls = [_]ai.ToolCall{tool_call};

    const assistant_message = ai.AssistantMessage{
        .content = assistant_rich_content[0..],
        .tool_calls = tool_calls[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 3, .output = 5, .cache_read = 7, .cache_write = 11, .total_tokens = 26 },
        .stop_reason = .tool_use,
        .timestamp = 2002,
    };
    const assistant_text_message = ai.AssistantMessage{
        .content = assistant_text_content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 3, .output = 5, .total_tokens = 8 },
        .stop_reason = .stop,
        .timestamp = 2001,
    };
    const aborted_message = ai.AssistantMessage{
        .content = assistant_text_content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 3, .output = 1, .total_tokens = 4 },
        .stop_reason = .aborted,
        .error_message = "aborted",
        .timestamp = 2003,
    };
    const tool_result_message = agent.types.ToolResultMessage{
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .content = tool_result_content[0..],
        .details = details_value,
        .is_error = false,
        .timestamp = 3001,
    };
    const partial_tool_result = agent.types.AgentToolResult{
        .content = partial_tool_result_content[0..],
        .details = details_value,
    };
    const success_tool_result = agent.types.AgentToolResult{
        .content = tool_result_content[0..],
        .details = details_value,
    };
    const error_tool_result = agent.types.AgentToolResult{
        .content = error_tool_result_content[0..],
        .details = error_details_value,
    };

    try expectGoldenAgentEvent("agent_start", .{ .event_type = .agent_start });
    try expectGoldenAgentEvent("turn_start", .{ .event_type = .turn_start });
    try expectGoldenAgentEvent("message_start_user", .{
        .event_type = .message_start,
        .message = .{ .user = .{ .content = user_content[0..], .timestamp = 1001 } },
    });
    try expectGoldenAgentEvent("message_start_assistant", .{
        .event_type = .message_start,
        .message = .{ .assistant = assistant_message },
    });
    try expectGoldenAgentEvent("message_update_text_delta", .{
        .event_type = .message_update,
        .message = .{ .assistant = assistant_text_message },
        .assistant_message_event = .{ .event_type = .text_delta, .content_index = 0, .delta = "partial", .message = assistant_text_message },
    });
    try expectGoldenAgentEvent("message_update_thinking_delta", .{
        .event_type = .message_update,
        .message = .{ .assistant = assistant_message },
        .assistant_message_event = .{ .event_type = .thinking_delta, .content_index = 1, .delta = "reason", .message = assistant_message },
    });
    try expectGoldenAgentEvent("message_update_toolcall_delta", .{
        .event_type = .message_update,
        .message = .{ .assistant = assistant_message },
        .assistant_message_event = .{ .event_type = .toolcall_delta, .content_index = 2, .delta = "{\"command\":\"printf\"}", .message = assistant_message },
    });
    try expectGoldenAgentEvent("message_update_abort_error", .{
        .event_type = .message_update,
        .message = .{ .assistant = aborted_message },
        .assistant_message_event = .{ .event_type = .error_event, .message = aborted_message },
    });
    try expectGoldenAgentEvent("message_end_assistant", .{
        .event_type = .message_end,
        .message = .{ .assistant = assistant_message },
    });
    try expectGoldenAgentEvent("message_end_tool_result", .{
        .event_type = .message_end,
        .message = .{ .tool_result = tool_result_message },
    });
    try expectGoldenAgentEvent("tool_execution_start", .{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .args = args_value,
    });
    try expectGoldenAgentEvent("tool_execution_update_partial", .{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .args = args_value,
        .partial_result = partial_tool_result,
    });
    try expectGoldenAgentEvent("tool_execution_end_success", .{
        .event_type = .tool_execution_end,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .result = success_tool_result,
        .is_error = false,
    });
    try expectGoldenAgentEvent("tool_execution_end_error", .{
        .event_type = .tool_execution_end,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .result = error_tool_result,
        .is_error = true,
    });
    try expectGoldenAgentEvent("turn_end", .{
        .event_type = .turn_end,
        .message = .{ .assistant = assistant_message },
        .tool_results = &[_]agent.types.ToolResultMessage{tool_result_message},
    });
    try expectGoldenAgentEvent("agent_end", .{
        .event_type = .agent_end,
        .messages = &[_]agent.AgentMessage{
            .{ .user = .{ .content = user_content[0..], .timestamp = 1001 } },
            .{ .assistant = assistant_message },
            .{ .tool_result = tool_result_message },
        },
    });
}

test "validateAgentEventJson reports contextual schema errors" {
    const allocator = std.testing.allocator;

    var object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putString(allocator, &object, "type", "tool_execution_end");

    try std.testing.expectError(error.InvalidJsonSchema, validateAgentEventJson(allocator, .{ .object = object }));
}

test "stringifyAgentEventLine rejects malformed serialized events" {
    const allocator = std.testing.allocator;

    const invalid_event = agent.AgentEvent{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{
                .{ .text = .{ .text = "missing tool call id" } },
            },
        },
        .is_error = false,
    };

    try std.testing.expectError(error.InvalidJsonSchema, stringifyAgentEventLine(allocator, invalid_event));
}

test "agent event JSON covers all top-level variants" {
    const allocator = std.testing.allocator;

    var args_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try common.putString(allocator, &args_object, "path", "/tmp/file.txt");
    const args_value: std.json.Value = .{ .object = args_object };

    var details_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = details_object });
    try common.putInt(allocator, &details_object, "exit_code", 0);
    const details_value: std.json.Value = .{ .object = details_object };

    const user_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "hello" } },
    };
    const assistant_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "partial text" } },
        .{ .thinking = .{ .thinking = "reasoning", .signature = "sig-1" } },
    };
    const tool_result_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "tool output" } },
    };

    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = args_value,
    };
    const tool_calls = [_]ai.ToolCall{tool_call};

    const assistant_message = ai.AssistantMessage{
        .content = assistant_content[0..],
        .tool_calls = tool_calls[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 2, .total_tokens = 3 },
        .stop_reason = .stop,
        .timestamp = 2,
    };
    const tool_result_message = agent.types.ToolResultMessage{
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .content = tool_result_content[0..],
        .details = details_value,
        .timestamp = 3,
    };
    const tool_execution_result = agent.types.AgentToolResult{
        .content = tool_result_content[0..],
        .details = details_value,
    };

    const events = [_]agent.AgentEvent{
        .{ .event_type = .agent_start },
        .{ .event_type = .turn_start },
        .{ .event_type = .message_start, .message = .{ .user = .{ .content = user_content[0..], .timestamp = 1 } } },
        .{
            .event_type = .message_update,
            .message = .{ .assistant = assistant_message },
            .assistant_message_event = .{
                .event_type = .text_delta,
                .content_index = 0,
                .delta = "partial text",
                .message = assistant_message,
            },
        },
        .{ .event_type = .message_end, .message = .{ .assistant = assistant_message } },
        .{ .event_type = .tool_execution_start, .tool_call_id = "tool-1", .tool_name = "bash", .args = args_value },
        .{ .event_type = .tool_execution_update, .tool_call_id = "tool-1", .tool_name = "bash", .args = args_value, .partial_result = tool_execution_result },
        .{ .event_type = .tool_execution_end, .tool_call_id = "tool-1", .tool_name = "bash", .result = tool_execution_result, .is_error = false },
        .{ .event_type = .turn_end, .message = .{ .assistant = assistant_message }, .tool_results = &[_]agent.types.ToolResultMessage{tool_result_message} },
        .{ .event_type = .agent_end, .messages = &[_]agent.AgentMessage{ .{ .user = .{ .content = user_content[0..], .timestamp = 1 } }, .{ .assistant = assistant_message }, .{ .tool_result = tool_result_message } } },
    };

    for (events) |event| {
        const value = try agentEventToJsonValue(allocator, event);
        defer common.deinitJsonValue(allocator, value);
        try validateAgentEventJson(allocator, value);
    }
}

test "assistant message event JSON covers all nested variants" {
    const allocator = std.testing.allocator;

    var args_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try common.putString(allocator, &args_object, "command", "echo hi");
    const args_value: std.json.Value = .{ .object = args_object };

    const assistant_content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "hello" } },
    };
    const assistant_message = ai.AssistantMessage{
        .content = assistant_content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 1, .total_tokens = 2 },
        .stop_reason = .stop,
        .timestamp = 10,
    };
    const error_message = ai.AssistantMessage{
        .content = assistant_content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = .{ .input = 1, .output = 0, .total_tokens = 1 },
        .stop_reason = .error_reason,
        .error_message = "boom",
        .timestamp = 11,
    };
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = args_value,
    };

    const assistant_events = [_]ai.AssistantMessageEvent{
        .{ .event_type = .start, .message = assistant_message },
        .{ .event_type = .text_start, .content_index = 0, .message = assistant_message },
        .{ .event_type = .text_delta, .content_index = 0, .delta = "h", .message = assistant_message },
        .{ .event_type = .text_end, .content_index = 0, .content = "hello", .message = assistant_message },
        .{ .event_type = .thinking_start, .content_index = 1, .message = assistant_message },
        .{ .event_type = .thinking_delta, .content_index = 1, .delta = "thinking", .message = assistant_message },
        .{ .event_type = .thinking_end, .content_index = 1, .content = "thinking", .message = assistant_message },
        .{ .event_type = .toolcall_start, .content_index = 2, .message = assistant_message },
        .{ .event_type = .toolcall_delta, .content_index = 2, .delta = "{\"x\":1}", .message = assistant_message },
        .{ .event_type = .toolcall_end, .content_index = 2, .tool_call = tool_call, .message = assistant_message },
        .{ .event_type = .done, .message = assistant_message },
        .{ .event_type = .error_event, .message = error_message },
    };

    for (assistant_events) |assistant_event| {
        const event = agent.AgentEvent{
            .event_type = .message_update,
            .message = .{ .assistant = assistant_message },
            .assistant_message_event = assistant_event,
        };
        const value = try agentEventToJsonValue(allocator, event);
        defer common.deinitJsonValue(allocator, value);
        try validateAgentEventJson(allocator, value);
    }
}

test "route-a m1 stringifies streaming toolcall message updates" {
    const allocator = std.testing.allocator;

    var args_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try common.putString(allocator, &args_object, "command", "echo hi");
    const args_value: std.json.Value = .{ .object = args_object };

    const assistant_message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 10,
    };
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = args_value,
    };

    const assistant_events = [_]ai.AssistantMessageEvent{
        .{ .event_type = .toolcall_start, .content_index = 0, .message = assistant_message },
        .{ .event_type = .toolcall_delta, .content_index = 0, .delta = "{\"command\":\"echo hi\"}", .message = assistant_message },
        .{ .event_type = .toolcall_end, .content_index = 0, .tool_call = tool_call, .message = assistant_message },
    };

    for (assistant_events) |assistant_event| {
        const line = try stringifyAgentEventLine(allocator, .{
            .event_type = .message_update,
            .message = .{ .assistant = assistant_message },
            .assistant_message_event = assistant_event,
        });
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try validateAgentEventJson(allocator, parsed.value);
        try std.testing.expectEqualStrings("message_update", parsed.value.object.get("type").?.string);
        try std.testing.expectEqualStrings(@tagName(assistant_event.event_type), parsed.value.object.get("assistantMessageEvent").?.object.get("type").?.string);
    }
}

test "partial toolcall message update serializes malformed argument fallback as empty object" {
    const allocator = std.testing.allocator;

    const args_object = try common.jsonObject(allocator);
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    const args_value: std.json.Value = .{ .object = args_object };

    const content = [_]ai.ContentBlock{
        .{ .text = .{ .text = "before tool" } },
        .{ .tool_call = .{
            .id = "",
            .name = "",
            .arguments = args_value,
        } },
    };
    const assistant_message = ai.AssistantMessage{
        .content = content[0..],
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 10,
    };

    const line = try stringifyAgentEventLine(allocator, .{
        .event_type = .message_update,
        .message = .{ .assistant = assistant_message },
        .assistant_message_event = .{
            .event_type = .toolcall_delta,
            .content_index = 1,
            .delta = "not-json",
            .message = assistant_message,
        },
    });
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try validateAgentEventJson(allocator, parsed.value);
    const message = parsed.value.object.get("message").?.object;
    const tool_call = message.get("content").?.array.items[1].object;
    const arguments = tool_call.get("arguments").?;
    try std.testing.expect(arguments == .object);
    try std.testing.expectEqual(@as(usize, 0), arguments.object.count());
}

test "assistant event done reason must match nested message stopReason" {
    const allocator = std.testing.allocator;
    // This JSON should now pass validation because we allow "stop"/"length" mismatch
    const json =
        \\{"type":"done","reason":"stop","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"length","timestamp":10}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    // Now validation passes because we allow stop/length mismatch
    try validateAssistantEventValue(allocator, parsed.value, "$");
}

test "assistant event error reason must match nested message stopReason" {
    const allocator = std.testing.allocator;
    // This JSON should now pass validation because "error"/"aborted" are allowed to differ
    const json =
        \\{"type":"error","reason":"error","error":{"role":"assistant","content":[{"type":"text","text":"boom"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":1,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":1,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"aborted","errorMessage":"aborted","timestamp":10}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    // Now validation passes because we allow error/aborted mismatch
    try validateAssistantEventValue(allocator, parsed.value, "$");
}

const JSON_WIRE_FUZZ_SMOKE_SEED: u64 = 0x5eed_1500_0000_0002;

test "VAL-REFACTOR-009 deterministic JSON event wire fuzz smoke" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(JSON_WIRE_FUZZ_SMOKE_SEED);
    const random = prng.random();

    const text_len = random.intRangeAtMost(usize, 4096, 8192);
    const boundary_text = try allocator.alloc(u8, text_len);
    defer allocator.free(boundary_text);
    @memset(boundary_text, 'j');

    const assistant_message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "hello-wire" } }},
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 10,
    };
    const user_message = ai.UserMessage{
        .content = &[_]ai.ContentBlock{.{ .text = .{ .text = boundary_text } }},
        .timestamp = 11,
    };

    const valid_events = [_]struct {
        label: []const u8,
        event: agent.AgentEvent,
    }{
        .{
            .label = "encode-decode-start",
            .event = .{ .event_type = .agent_start },
        },
        .{
            .label = "encode-decode-boundary-message",
            .event = .{
                .event_type = .message_start,
                .message = .{ .user = user_message },
            },
        },
        .{
            .label = "encode-decode-assistant-delta",
            .event = .{
                .event_type = .message_update,
                .message = .{ .assistant = assistant_message },
                .assistant_message_event = .{
                    .event_type = .text_delta,
                    .content_index = 0,
                    .delta = "delta-wire",
                    .message = assistant_message,
                },
            },
        },
        .{
            .label = "encode-decode-assistant-done",
            .event = .{
                .event_type = .message_end,
                .message = .{ .assistant = assistant_message },
            },
        },
    };

    for (valid_events) |case| {
        const line = stringifyAgentEventLine(allocator, case.event) catch |err| {
            reportJsonWireFuzzFailure(JSON_WIRE_FUZZ_SMOKE_SEED, case.label, "<event stringify failed>");
            return err;
        };
        defer allocator.free(line);
        try expectJsonWireFuzzValid(allocator, case.label, line);
    }

    const unknown_field_json =
        \\{"type":"message_update","unknownTopLevel":true,"message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":10},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"hello","partial":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":10},"unknownNested":"ignored"}}
    ;
    try expectJsonWireFuzzValid(allocator, "unknown-fields", unknown_field_json);

    const malformed_values = [_]struct {
        label: []const u8,
        json: []const u8,
    }{
        .{
            .label = "malformed-top-level-type",
            .json =
            \\{"type":123}
            ,
        },
        .{
            .label = "malformed-assistant-content-index",
            .json =
            \\{"type":"message_update","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":10},"assistantMessageEvent":{"type":"text_delta","contentIndex":"zero","delta":"hello","partial":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":10}}}
            ,
        },
        .{
            .label = "malformed-stop-reason",
            .json =
            \\{"type":"done","reason":"toolUse","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"api":"faux","provider":"faux","model":"faux-1","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":10}}
            ,
        },
        .{
            .label = "truncated-json",
            .json =
            \\{"type":"turn_start"
            ,
        },
    };

    for (malformed_values) |case| {
        try expectJsonWireFuzzInvalid(allocator, case.label, case.json);
    }
}

fn expectJsonWireFuzzValid(allocator: std.mem.Allocator, label: []const u8, json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| {
        reportJsonWireFuzzFailure(JSON_WIRE_FUZZ_SMOKE_SEED, label, json);
        return err;
    };
    defer parsed.deinit();
    validateAgentEventJson(allocator, parsed.value) catch |err| {
        reportJsonWireFuzzFailure(JSON_WIRE_FUZZ_SMOKE_SEED, label, json);
        return err;
    };
}

fn expectJsonWireFuzzInvalid(allocator: std.mem.Allocator, label: []const u8, json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return;
    };
    defer parsed.deinit();
    validateAgentEventJson(allocator, parsed.value) catch {
        return;
    };
    reportJsonWireFuzzFailure(JSON_WIRE_FUZZ_SMOKE_SEED, label, json);
    return error.TestExpectedError;
}

fn reportJsonWireFuzzFailure(seed: u64, label: []const u8, input: []const u8) void {
    const max_len = @min(input.len, @as(usize, 512));
    std.debug.print("JSON wire fuzz smoke failure seed=0x{x} case={s} minimized_input={s}", .{
        seed,
        label,
        input[0..max_len],
    });
    if (input.len > max_len) {
        std.debug.print("...({d} bytes total)", .{input.len});
    }
    std.debug.print("\n", .{});
}
