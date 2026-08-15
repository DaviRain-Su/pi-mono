const std = @import("std");

const event_stream = @import("../event_stream.zig");
const finalize = @import("finalize.zig");
const json_parse = @import("../json_parse.zig");
const provider_json = @import("provider_json.zig");
const types = @import("../types.zig");

pub const MessagePartKind = enum {
    output_text,
    refusal,
};

pub const CurrentBlock = union(enum) {
    text: struct {
        event_index: usize,
        text: std.ArrayList(u8),
        part_kind: MessagePartKind,
    },
    thinking: struct {
        event_index: usize,
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    tool_call: struct {
        event_index: usize,
        id: ?[]const u8,
        name: ?[]const u8,
        partial_json: std.ArrayList(u8),
    },
};

pub fn initThinkingBlock(event_index: usize) CurrentBlock {
    return .{ .thinking = .{
        .event_index = event_index,
        .text = std.ArrayList(u8).empty,
        .signature = null,
    } };
}

pub fn initTextBlock(event_index: usize) CurrentBlock {
    return .{ .text = .{
        .event_index = event_index,
        .text = std.ArrayList(u8).empty,
        .part_kind = .output_text,
    } };
}

pub fn initToolCallBlockFromItem(
    allocator: std.mem.Allocator,
    event_index: usize,
    item_value: std.json.Value,
) !CurrentBlock {
    var block = CurrentBlock{ .tool_call = .{
        .event_index = event_index,
        .id = try extractCombinedToolCallId(allocator, item_value),
        .name = try extractOwnedStringField(allocator, item_value, "name"),
        .partial_json = std.ArrayList(u8).empty,
    } };
    errdefer deinitCurrentBlock(allocator, &block);

    if (item_value == .object) {
        if (item_value.object.get("arguments")) |arguments_value| {
            if (arguments_value == .string and arguments_value.string.len > 0) {
                try block.tool_call.partial_json.appendSlice(allocator, arguments_value.string);
            }
        }
    }

    return block;
}

pub fn updateCurrentMessagePart(item_value: std.json.Value, current_block: *?CurrentBlock) void {
    if (item_value != .object) return;
    const part_type_value = item_value.object.get("type") orelse return;
    if (part_type_value != .string) return;

    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                if (std.mem.eql(u8, part_type_value.string, "refusal")) {
                    text.part_kind = .refusal;
                } else {
                    text.part_kind = .output_text;
                }
            },
            else => {},
        }
    }
}

pub fn finalizeCurrentBlock(
    allocator: std.mem.Allocator,
    maybe_item_value: ?std.json.Value,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                const owned = if (try extractMessageText(allocator, maybe_item_value)) |final_text|
                    final_text
                else
                    try allocator.dupe(u8, text.text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking| {
                const owned = if (try extractReasoningSummary(allocator, maybe_item_value)) |final_text|
                    final_text
                else
                    try allocator.dupe(u8, thinking.text.items);
                const signature = if (maybe_item_value) |item_value| blk: {
                    if (item_value == .object) {
                        if (item_value.object.get("encrypted_content")) |encrypted| {
                            if (encrypted == .string) break :blk try std.json.Stringify.valueAlloc(allocator, item_value, .{});
                        }
                    }
                    break :blk null;
                } else if (thinking.signature) |existing|
                    try allocator.dupe(u8, existing)
                else
                    null;
                try content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = owned,
                    .thinking_signature = signature,
                    .redacted = false,
                } });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(thinking.event_index),
                    .content = owned,
                });
            },
            .tool_call => |*tool_call| {
                const item_id_owned = if (tool_call.id == null and maybe_item_value != null)
                    try extractCombinedToolCallId(allocator, maybe_item_value.?)
                else
                    null;
                defer if (item_id_owned) |value| allocator.free(value);
                const final_id = item_id_owned orelse tool_call.id orelse "";

                const item_name_owned = if (tool_call.name == null and maybe_item_value != null)
                    try extractOwnedStringField(allocator, maybe_item_value.?, "name")
                else
                    null;
                defer if (item_name_owned) |value| allocator.free(value);
                const final_name = item_name_owned orelse tool_call.name orelse "";

                const arguments_source = if (maybe_item_value) |item_value|
                    extractStringField(item_value, "arguments") orelse tool_call.partial_json.items
                else
                    tool_call.partial_json.items;
                const arguments = try parseStreamingJsonToValue(allocator, arguments_source);
                const stored_tool_call = blk: {
                    errdefer provider_json.freeValue(allocator, arguments);
                    const id = try allocator.dupe(u8, final_id);
                    errdefer allocator.free(id);
                    const name = try allocator.dupe(u8, final_name);
                    errdefer allocator.free(name);
                    break :blk types.ToolCall{
                        .id = id,
                        .name = name,
                        .arguments = arguments,
                    };
                };
                try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, stored_tool_call);
                stream_ptr.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(tool_call.event_index),
                    .tool_call = .{
                        .id = try allocator.dupe(u8, stored_tool_call.id),
                        .name = try allocator.dupe(u8, stored_tool_call.name),
                        .arguments = try provider_json.cloneValue(allocator, stored_tool_call.arguments),
                    },
                });
            },
        }

        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

pub fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.text.deinit(allocator),
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            if (tool_call.id) |id| allocator.free(id);
            if (tool_call.name) |name| allocator.free(name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

pub fn extractMessageText(allocator: std.mem.Allocator, maybe_item_value: ?std.json.Value) !?[]const u8 {
    const item_value = maybe_item_value orelse return null;
    if (item_value != .object) return null;
    const content_value = item_value.object.get("content") orelse return null;
    if (content_value != .array) return null;

    var total_len: usize = 0;
    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const part_type = extractStringField(part, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "output_text")) {
            if (extractStringField(part, "text")) |text| total_len += text.len;
        } else if (std.mem.eql(u8, part_type, "refusal")) {
            if (extractStringField(part, "refusal")) |text| total_len += text.len;
        }
    }
    if (total_len == 0) return null;

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const part_type = extractStringField(part, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "output_text")) {
            if (extractStringField(part, "text")) |text| try buffer.appendSlice(allocator, text);
        } else if (std.mem.eql(u8, part_type, "refusal")) {
            if (extractStringField(part, "refusal")) |text| try buffer.appendSlice(allocator, text);
        }
    }
    return try buffer.toOwnedSlice(allocator);
}

pub fn extractReasoningSummary(allocator: std.mem.Allocator, maybe_item_value: ?std.json.Value) !?[]const u8 {
    const item_value = maybe_item_value orelse return null;
    if (item_value != .object) return null;

    if (item_value.object.get("summary")) |summary_value| {
        if (summary_value == .array and summary_value.array.items.len > 0) {
            if (try extractJoinedTextFields(allocator, summary_value)) |summary_text| {
                return summary_text;
            }
        }
    }

    if (item_value.object.get("content")) |content_value| {
        if (content_value == .array and content_value.array.items.len > 0) {
            if (try extractJoinedTextFields(allocator, content_value)) |content_text| {
                return content_text;
            }
        }
    }

    return null;
}

fn extractJoinedTextFields(allocator: std.mem.Allocator, array_value: std.json.Value) !?[]const u8 {
    if (array_value != .array) return null;

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var appended: usize = 0;
    for (array_value.array.items) |part| {
        if (part != .object) continue;
        const text = extractStringField(part, "text") orelse continue;
        if (appended > 0) try buffer.appendSlice(allocator, "\n\n");
        try buffer.appendSlice(allocator, text);
        appended += 1;
    }
    if (buffer.items.len == 0) {
        buffer.deinit(allocator);
        return null;
    }
    return try buffer.toOwnedSlice(allocator);
}

fn extractCombinedToolCallId(allocator: std.mem.Allocator, item_value: std.json.Value) !?[]const u8 {
    if (item_value != .object) return null;
    const call_id = extractStringField(item_value, "call_id") orelse return null;
    const item_id = extractStringField(item_value, "id");
    if (item_id) |value| {
        return try std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, value });
    }
    return try allocator.dupe(u8, call_id);
}

fn extractOwnedStringField(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) !?[]const u8 {
    const string = extractStringField(value, key) orelse return null;
    return try allocator.dupe(u8, string);
}

fn extractStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(key) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return .{ .object = try initObject(allocator) };
    const parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return .{ .object = try initObject(allocator) };
    };
    defer parsed.deinit();
    return try provider_json.cloneValue(allocator, parsed.value);
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return provider_json.initObject(allocator);
}

fn freeToolCallOwned(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    provider_json.freeValue(allocator, tool_call.arguments);
}

fn freeEventOwned(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    if (event.delta) |delta| allocator.free(delta);
    if (event.tool_call) |tool_call| freeToolCallOwned(allocator, tool_call);
}

test "extractMessageText joins output text and refusal parts" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"refusal\",\"refusal\":\" no\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractMessageText(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Hello no", text);
}

test "extractReasoningSummary prefers summary and falls back to content text" {
    const allocator = std.testing.allocator;
    const summary_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[{\"text\":\"summary wins\"}],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"content loses\"}]}",
        .{},
    );
    defer summary_parsed.deinit();
    const summary_text = (try extractReasoningSummary(allocator, summary_parsed.value)).?;
    defer allocator.free(summary_text);
    try std.testing.expectEqualStrings("summary wins", summary_text);

    const content_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"content first\"},{\"type\":\"reasoning_text\",\"text\":\"content second\"}]}",
        .{},
    );
    defer content_parsed.deinit();
    const content_text = (try extractReasoningSummary(allocator, content_parsed.value)).?;
    defer allocator.free(content_text);
    try std.testing.expectEqualStrings("content first\n\ncontent second", content_text);
}

test "finalizeCurrentBlock preserves text fallback and emits text_end" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    var current_block: ?CurrentBlock = .{ .text = .{
        .event_index = 0,
        .text = std.ArrayList(u8).empty,
        .part_kind = .output_text,
    } };
    try current_block.?.text.text.appendSlice(allocator, "delta fallback");
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer {
        if (content_blocks.items.len > 0) allocator.free(content_blocks.items[0].text.text);
        content_blocks.deinit(allocator);
    }
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    // Establish the open block invariant the production stream would have set
    // up before reaching `finalizeCurrentBlock`.
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    _ = stream.next().?;

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, &stream);

    try std.testing.expect(current_block == null);
    try std.testing.expectEqual(@as(usize, 1), content_blocks.items.len);
    try std.testing.expectEqualStrings("delta fallback", content_blocks.items[0].text.text);

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, event.event_type);
    try std.testing.expectEqualStrings("delta fallback", event.content.?);
}

test "finalizeCurrentBlock stores inline tool call and emits end event" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    var current_block: ?CurrentBlock = .{ .tool_call = .{
        .event_index = 0,
        .id = try allocator.dupe(u8, "call_1|fc_1"),
        .name = try allocator.dupe(u8, "lookup"),
        .partial_json = std.ArrayList(u8).empty,
    } };
    try current_block.?.tool_call.partial_json.appendSlice(allocator, "{\"city\":\"Berlin\"}");
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    // Establish the open block invariant the production stream would have set
    // up before reaching `finalizeCurrentBlock`.
    stream.push(.{ .event_type = .toolcall_start, .content_index = 0 });
    _ = stream.next().?;

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, &stream);
    defer freeToolCallOwned(allocator, content_blocks.items[0].tool_call);

    try std.testing.expect(current_block == null);
    try std.testing.expectEqual(@as(usize, 1), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1|fc_1", content_blocks.items[0].tool_call.id);
    try std.testing.expectEqualStrings("Berlin", content_blocks.items[0].tool_call.arguments.object.get("city").?.string);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.id.ptr, tool_calls.items[0].id.ptr);

    const event = stream.next().?;
    defer freeEventOwned(allocator, event);
    try std.testing.expectEqual(types.EventType.toolcall_end, event.event_type);
    try std.testing.expect(event.tool_call != null);
    try std.testing.expectEqualStrings("lookup", event.tool_call.?.name);
}
