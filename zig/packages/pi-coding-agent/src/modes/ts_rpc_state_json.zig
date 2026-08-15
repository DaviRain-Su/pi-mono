const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const ts_rpc_wire = @import("ts_rpc_wire.zig");
const json_event_wire = @import("json_event_wire.zig");
const common = @import("../tools/common.zig");
const session_mod = @import("../sessions/session.zig");
const session_advanced = @import("../sessions/session_advanced.zig");

const writeJsonString = ts_rpc_wire.writeJsonString;

pub fn buildStateJson(allocator: std.mem.Allocator, session: *session_mod.AgentSession) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try writeModelJson(allocator, writer, session.agent.getModel());
    try writer.writeAll(",\"thinkingLevel\":");
    try writeJsonString(allocator, writer, thinkingLevelName(session.agent.getThinkingLevel()));
    try writer.writeAll(",\"isStreaming\":");
    try writer.writeAll(if (session.isStreaming()) "true" else "false");
    try writer.writeAll(",\"isCompacting\":");
    try writer.writeAll(if (session.isCompacting()) "true" else "false");
    try writer.writeAll(",\"steeringMode\":");
    try writeJsonString(allocator, writer, queueModeName(session.agent.steering_queue.mode));
    try writer.writeAll(",\"followUpMode\":");
    try writeJsonString(allocator, writer, queueModeName(session.agent.follow_up_queue.mode));
    if (session.session_manager.getSessionFile()) |session_file| {
        try writer.writeAll(",\"sessionFile\":");
        try writeJsonString(allocator, writer, session_file);
    }
    try writer.writeAll(",\"sessionId\":");
    try writeJsonString(allocator, writer, session.session_manager.getSessionId());
    if (session.session_manager.getSessionName()) |session_name| {
        try writer.writeAll(",\"sessionName\":");
        try writeJsonString(allocator, writer, session_name);
    }
    try writer.writeAll(",\"autoCompactionEnabled\":");
    try writer.writeAll(if (session.compaction_settings.enabled) "true" else "false");
    try writer.print(",\"messageCount\":{d}", .{session.agent.getMessages().len});
    try writer.print(",\"pendingMessageCount\":{d}", .{session.agent.steeringQueueLen() + session.agent.followUpQueueLen()});
    try writer.writeAll("}");

    return try allocator.dupe(u8, out.written());
}

pub fn buildMessagesJson(allocator: std.mem.Allocator, messages: []const agent.AgentMessage) ![]u8 {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (messages) |message| {
        try array.append(try json_event_wire.messageToJsonValue(allocator, message));
    }
    const value = std.json.Value{ .object = blk: {
        var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer object.deinit(allocator);
        try common.putValue(allocator, &object, "messages", .{ .array = array });
        break :blk object;
    } };
    defer common.deinitJsonValue(allocator, value);
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn buildModelJson(allocator: std.mem.Allocator, model: ai.Model) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeModelJson(allocator, &out.writer, model);
    return try allocator.dupe(u8, out.written());
}

pub fn buildAvailableModelsJson(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const registry = ai.model_registry.getDefault();
    try out.writer.writeAll("{\"models\":[");
    for (registry.models.items, 0..) |entry, index| {
        if (index > 0) try out.writer.writeAll(",");
        try writeModelJson(allocator, &out.writer, entry.model);
    }
    try out.writer.writeAll("]}");
    return try allocator.dupe(u8, out.written());
}

pub fn buildCompactionResultJson(allocator: std.mem.Allocator, result: session_mod.CompactionResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"summary\":");
    try writeJsonString(allocator, &out.writer, result.summary);
    try out.writer.writeAll(",\"firstKeptEntryId\":");
    try writeJsonString(allocator, &out.writer, result.first_kept_entry_id);
    try out.writer.print(",\"tokensBefore\":{d}", .{result.tokens_before});
    try out.writer.writeAll("}");
    return try allocator.dupe(u8, out.written());
}

pub fn buildSessionStatsJson(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = session_advanced.getSessionStats(session);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{");
    if (stats.session_file) |session_file| {
        try writer.writeAll("\"sessionFile\":");
        try writeJsonString(allocator, writer, session_file);
        try writer.writeAll(",");
    }
    try writer.writeAll("\"sessionId\":");
    try writeJsonString(allocator, writer, stats.session_id);
    try writer.print(
        ",\"userMessages\":{d},\"assistantMessages\":{d},\"toolCalls\":{d},\"toolResults\":{d},\"totalMessages\":{d}",
        .{ stats.user_messages, stats.assistant_messages, stats.tool_calls, stats.tool_results, stats.total_messages },
    );
    try writer.print(
        ",\"tokens\":{{\"input\":{d},\"output\":{d},\"cacheRead\":{d},\"cacheWrite\":{d},\"total\":{d}}}",
        .{ stats.tokens.input, stats.tokens.output, stats.tokens.cache_read, stats.tokens.cache_write, stats.tokens.total },
    );
    try writer.writeAll(",\"cost\":");
    try writeJsonNumber(allocator, writer, stats.cost);
    if (stats.context_usage) |context_usage| {
        try writer.writeAll(",\"contextUsage\":{\"used\":");
        if (context_usage.tokens) |tokens| {
            try writer.print("{d}", .{tokens});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"available\":{d},\"percentage\":", .{context_usage.context_window});
        if (context_usage.percent) |percent| {
            try writeJsonNumber(allocator, writer, percent);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
    return try allocator.dupe(u8, out.written());
}

pub fn buildForkMessagesJson(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"messages\":[");
    var first = true;
    for (session.session_manager.getEntries()) |entry| {
        switch (entry) {
            .message => |message_entry| switch (message_entry.message) {
                .user => |user| {
                    const text = try textBlocksConcat(allocator, user.content);
                    defer allocator.free(text);
                    if (text.len == 0) continue;
                    if (!first) try out.writer.writeAll(",");
                    first = false;
                    try out.writer.writeAll("{\"entryId\":");
                    try writeJsonString(allocator, &out.writer, message_entry.id);
                    try out.writer.writeAll(",\"text\":");
                    try writeJsonString(allocator, &out.writer, text);
                    try out.writer.writeAll("}");
                },
                else => {},
            },
            else => {},
        }
    }
    try out.writer.writeAll("]}");
    return try allocator.dupe(u8, out.written());
}

pub fn parseThinkingLevel(object: std.json.ObjectMap, key: []const u8) !agent.ThinkingLevel {
    const value = try requiredString(object, key);
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return error.InvalidFieldType;
}

pub fn nextSupportedThinkingLevel(model: ai.Model, current: agent.ThinkingLevel) agent.ThinkingLevel {
    const levels = [_]agent.ThinkingLevel{ .off, .minimal, .low, .medium, .high, .xhigh };
    const current_index = for (levels, 0..) |level, index| {
        if (level == current) break index;
    } else 0;

    for (1..levels.len + 1) |offset| {
        const candidate = levels[(current_index + offset) % levels.len];
        if (ai.model_registry.thinkingLevelSupported(model, agentThinkingLevelToModel(candidate))) return candidate;
    }
    return .off;
}

pub fn parseQueueMode(object: std.json.ObjectMap, key: []const u8) !agent.QueueMode {
    const value = try requiredString(object, key);
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "one-at-a-time")) return .one_at_a_time;
    return error.InvalidFieldType;
}

pub fn parseImages(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]ai.ImageContent {
    const images_value = object.get("images") orelse return try allocator.alloc(ai.ImageContent, 0);
    const images_array = switch (images_value) {
        .array => |array| array,
        else => return error.InvalidFieldType,
    };

    const images = try allocator.alloc(ai.ImageContent, images_array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (images[0..initialized]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(images);
    }

    for (images_array.items, 0..) |item, index| {
        const image_object = switch (item) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const data = requiredString(image_object, "data") catch return error.InvalidFieldType;
        const mime_type = requiredString(image_object, "mimeType") catch return error.InvalidFieldType;
        images[index] = .{
            .data = try allocator.dupe(u8, data),
            .mime_type = try allocator.dupe(u8, mime_type),
        };
        initialized += 1;
    }
    return images;
}

pub fn deinitImages(allocator: std.mem.Allocator, images: []ai.ImageContent) void {
    for (images) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
    allocator.free(images);
}

pub fn thinkingLevelName(level: agent.ThinkingLevel) []const u8 {
    return @tagName(level);
}

pub fn queueModeName(mode: agent.QueueMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

pub fn writeModelJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, model: ai.Model) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(allocator, writer, model.id);
    try writer.writeAll(",\"name\":");
    try writeJsonString(allocator, writer, model.name);
    try writer.writeAll(",\"api\":");
    try writeJsonString(allocator, writer, model.api);
    try writer.writeAll(",\"provider\":");
    try writeJsonString(allocator, writer, model.provider);
    try writer.writeAll(",\"baseUrl\":");
    try writeJsonString(allocator, writer, model.base_url);
    try writer.writeAll(",\"reasoning\":");
    try writer.writeAll(if (model.reasoning) "true" else "false");
    if (model.thinking_level_map) |map| {
        try writer.writeAll(",\"thinkingLevelMap\":{");
        var first = true;
        try writeThinkingLevelMapEntry(allocator, writer, "off", map.off, &first);
        try writeThinkingLevelMapEntry(allocator, writer, "minimal", map.minimal, &first);
        try writeThinkingLevelMapEntry(allocator, writer, "low", map.low, &first);
        try writeThinkingLevelMapEntry(allocator, writer, "medium", map.medium, &first);
        try writeThinkingLevelMapEntry(allocator, writer, "high", map.high, &first);
        try writeThinkingLevelMapEntry(allocator, writer, "xhigh", map.xhigh, &first);
        try writer.writeAll("}");
    }
    try writer.writeAll(",\"input\":[");
    for (model.input_types, 0..) |input, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, input);
    }
    try writer.writeAll("],\"cost\":{\"input\":");
    try writeJsonNumber(allocator, writer, model.cost.input);
    try writer.writeAll(",\"output\":");
    try writeJsonNumber(allocator, writer, model.cost.output);
    try writer.writeAll(",\"cacheRead\":");
    try writeJsonNumber(allocator, writer, model.cost.cache_read);
    try writer.writeAll(",\"cacheWrite\":");
    try writeJsonNumber(allocator, writer, model.cost.cache_write);
    try writer.writeAll("}");
    try writer.print(",\"contextWindow\":{d},\"maxTokens\":{d}", .{ model.context_window, model.max_tokens });
    if (model.headers) |headers| {
        try writer.writeAll(",\"headers\":{");
        var iterator = headers.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writeJsonString(allocator, writer, entry.key_ptr.*);
            try writer.writeAll(":");
            try writeJsonString(allocator, writer, entry.value_ptr.*);
        }
        try writer.writeAll("}");
    }
    if (model.compat) |compat| {
        const compat_json = try std.json.Stringify.valueAlloc(allocator, compat, .{});
        defer allocator.free(compat_json);
        try writer.writeAll(",\"compat\":");
        try writer.writeAll(compat_json);
    }
    try writer.writeAll("}");
}

pub fn writeQueuedMessageTexts(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    messages: []const agent.AgentMessage,
) !void {
    try writer.writeAll("[");
    var first = true;
    for (messages) |message| {
        const text = switch (message) {
            .user => |user| firstTextBlock(user.content),
            else => "",
        };
        if (!first) try writer.writeAll(",");
        first = false;
        try writeJsonString(allocator, writer, text);
    }
    try writer.writeAll("]");
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingRequiredField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn agentThinkingLevelToModel(level: agent.ThinkingLevel) ai.types.ModelThinkingLevel {
    return switch (level) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn writeThinkingLevelMapEntry(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    key: []const u8,
    mapping: ?ai.types.ThinkingLevelMapping,
    first: *bool,
) !void {
    const value = mapping orelse return;
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writeJsonString(allocator, writer, key);
    try writer.writeAll(":");
    switch (value) {
        .unsupported => try writer.writeAll("null"),
        .mapped => |mapped| try writeJsonString(allocator, writer, mapped),
    }
}

fn writeJsonNumber(allocator: std.mem.Allocator, writer: *std.Io.Writer, number: f64) !void {
    _ = allocator;
    try writer.print("{d}", .{number});
}

fn firstTextBlock(blocks: []const ai.ContentBlock) []const u8 {
    for (blocks) |block| {
        switch (block) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return "";
}

fn textBlocksConcat(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            else => {},
        }
    }
    const text = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    const owned = try allocator.dupe(u8, text);
    out.deinit(allocator);
    return owned;
}

test "TS RPC state JSON writes model fields in stable order" {
    const allocator = std.testing.allocator;
    const model = ai.Model{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = "faux",
        .provider = "faux",
        .base_url = "https://example.invalid",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1234,
        .max_tokens = 321,
    };

    const json = try buildModelJson(allocator, model);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(
        "{\"id\":\"fixture-model\",\"name\":\"Fixture Model\",\"api\":\"faux\",\"provider\":\"faux\",\"baseUrl\":\"https://example.invalid\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":1234,\"maxTokens\":321}",
        json,
    );
}

test "TS RPC state JSON parses image command payloads" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"images\":[{\"data\":\"abc\",\"mimeType\":\"image/png\"}]}", .{});
    defer parsed.deinit();

    const images = try parseImages(allocator, parsed.value.object);
    defer deinitImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualStrings("abc", images[0].data);
    try std.testing.expectEqualStrings("image/png", images[0].mime_type);
}
