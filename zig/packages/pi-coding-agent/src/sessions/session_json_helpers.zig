const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tools_common = @import("../tools/common.zig");

pub fn makeObject(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
}

pub fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try tools_common.putString(allocator, &object, key, value);
}

pub fn putBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try tools_common.putBool(allocator, &object, key, value);
}

pub fn putInt(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: i64) !void {
    try tools_common.putInt(allocator, &object, key, value);
}

pub fn putValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try tools_common.putValue(allocator, &object, key, value);
}

pub fn jsonObjectWithString(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, object);
    try putString(allocator, &object.object, key, value);
    return object;
}

pub fn jsonObjectWithTruncateInput(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_lines: i64,
    max_bytes: i64,
) !std.json.Value {
    var object = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, object);
    try putString(allocator, &object.object, "content", content);
    try putInt(allocator, &object.object, "maxLines", max_lines);
    try putInt(allocator, &object.object, "maxBytes", max_bytes);
    return object;
}

/// Builds `{ "role": ..., "content": "first text" }` for a single AgentMessage.
/// Shared by putMessageSummary (single message) and putMessagesSummary (array)
/// so the per-variant role/content extraction stays in one place.
fn messageSummaryEntry(allocator: std.mem.Allocator, message: agent.AgentMessage) !std.json.ObjectMap {
    var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = entry });
    const role: []const u8, const content: []const u8 = switch (message) {
        .user => |user| .{ "user", firstText(user.content) orelse "" },
        .assistant => |assistant| .{ "assistant", firstText(assistant.content) orelse "" },
        .tool_result => |tool| .{ "tool", firstText(tool.content) orelse "" },
    };
    try putString(allocator, &entry, "role", role);
    try putString(allocator, &entry, "content", content);
    return entry;
}

pub fn putMessageSummary(allocator: std.mem.Allocator, object: *std.json.ObjectMap, message: agent.AgentMessage) !void {
    const entry = try messageSummaryEntry(allocator, message);
    try putValue(allocator, object, "message", .{ .object = entry });
}

pub fn putMessagesSummary(allocator: std.mem.Allocator, object: *std.json.ObjectMap, messages: []const agent.AgentMessage) !void {
    var array = std.json.Array.init(allocator);
    for (messages) |message| {
        const entry = try messageSummaryEntry(allocator, message);
        try array.append(.{ .object = entry });
    }
    try putValue(allocator, object, "messages", .{ .array = array });
}

/// Builds `{ toolCallId, toolName, content, isError }` for an
/// agent.types.ToolResultMessage; used inside lifecycle events that carry a
/// `toolResults` array.
pub fn toolResultMessageEntry(allocator: std.mem.Allocator, tool_result: agent.types.ToolResultMessage) !std.json.ObjectMap {
    var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = entry });
    try putString(allocator, &entry, "toolCallId", tool_result.tool_call_id);
    try putString(allocator, &entry, "toolName", tool_result.tool_name);
    try putString(allocator, &entry, "content", firstText(tool_result.content) orelse "");
    try putBool(allocator, &entry, "isError", tool_result.is_error);
    return entry;
}

pub fn makeToolResultPayload(allocator: std.mem.Allocator, result: agent.types.AgentToolResult) !std.json.Value {
    var payload = try makeObject(allocator);
    errdefer tools_common.deinitJsonValue(allocator, payload);
    try putValue(allocator, &payload.object, "content", try contentBlocksToJsonArray(allocator, result.content));
    if (result.details) |details| try putValue(allocator, &payload.object, "details", try tools_common.cloneJsonValue(allocator, details));
    try putBool(allocator, &payload.object, "isError", result.is_error);
    return payload;
}

pub fn contentBlocksToJsonArray(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |item| tools_common.deinitJsonValue(allocator, item);
        array.deinit();
    }
    for (blocks) |block| switch (block) {
        .text => |text| {
            var entry = try makeObject(allocator);
            errdefer tools_common.deinitJsonValue(allocator, entry);
            try putString(allocator, &entry.object, "type", "text");
            try putString(allocator, &entry.object, "text", text.text);
            try array.append(entry);
        },
        .image => |image| {
            var entry = try makeObject(allocator);
            errdefer tools_common.deinitJsonValue(allocator, entry);
            try putString(allocator, &entry.object, "type", "image");
            try putString(allocator, &entry.object, "data", image.data);
            try putString(allocator, &entry.object, "mimeType", image.mime_type);
            try array.append(entry);
        },
        else => {},
    };
    return .{ .array = array };
}

fn firstText(content: []const ai.ContentBlock) ?[]const u8 {
    for (content) |block| switch (block) {
        .text => |text| return text.text,
        else => {},
    };
    return null;
}
