const std = @import("std");
const types = @import("../types.zig");

pub const DeferredToolsMode = enum {
    additional_tools,
    tool_search,
};

pub const SplitDeferredTools = struct {
    immediate: []const types.Tool,
    deferred: std.StringHashMap(types.Tool),

    pub fn deinit(self: *SplitDeferredTools, allocator: std.mem.Allocator) void {
        allocator.free(self.immediate);
        self.deferred.deinit();
    }

    pub fn getDeferred(self: SplitDeferredTools, name: []const u8) ?types.Tool {
        return self.deferred.get(name);
    }
};

/// Split current tools into prefix (immediate) and transcript-loaded
/// (deferred) definitions. Port of TS `splitDeferredTools`.
pub fn splitDeferredTools(
    allocator: std.mem.Allocator,
    context: types.Context,
    enabled: bool,
) !SplitDeferredTools {
    var unique_order = std.ArrayList(types.Tool).empty;
    defer unique_order.deinit(allocator);
    var unique_index = std.StringHashMap(usize).init(allocator);
    defer unique_index.deinit();
    if (context.tools) |tools| {
        for (tools) |tool| {
            if (unique_index.get(tool.name)) |index| {
                unique_order.items[index] = tool;
            } else {
                try unique_index.put(tool.name, unique_order.items.len);
                try unique_order.append(allocator, tool);
            }
        }
    }

    if (!enabled) {
        const immediate = try allocator.dupe(types.Tool, unique_order.items);
        return .{
            .immediate = immediate,
            .deferred = std.StringHashMap(types.Tool).init(allocator),
        };
    }

    var deferred_names = std.StringHashMap(void).init(allocator);
    defer deferred_names.deinit();
    var used_names = std.StringHashMap(void).init(allocator);
    defer used_names.deinit();

    for (context.messages) |message| {
        switch (message) {
            .assistant => |assistant| {
                for (assistant.content) |block| {
                    if (block == .tool_call) try used_names.put(block.tool_call.name, {});
                }
                if (assistant.tool_calls) |tool_calls| {
                    for (tool_calls) |tool_call| try used_names.put(tool_call.name, {});
                }
            },
            .tool_result => |tool_result| {
                if (tool_result.added_tool_names) |names| {
                    for (names) |name| {
                        if (!used_names.contains(name)) try deferred_names.put(name, {});
                    }
                }
            },
            .user => {},
        }
    }

    var immediate_list = std.ArrayList(types.Tool).empty;
    errdefer immediate_list.deinit(allocator);
    var deferred = std.StringHashMap(types.Tool).init(allocator);
    errdefer deferred.deinit();

    for (unique_order.items) |tool| {
        if (deferred_names.contains(tool.name)) {
            try deferred.put(tool.name, tool);
        } else {
            try immediate_list.append(allocator, tool);
        }
    }

    return .{
        .immediate = try immediate_list.toOwnedSlice(allocator),
        .deferred = deferred,
    };
}

test "splitDeferredTools keeps all tools immediate when disabled" {
    const allocator = std.testing.allocator;
    var schema = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer schema.deinit(allocator);

    const tools = [_]types.Tool{
        .{ .name = "bash", .description = "Run", .parameters = .{ .object = schema } },
        .{ .name = "read", .description = "Read", .parameters = .{ .object = schema } },
    };
    const added = [_][]const u8{"read"};
    const messages = [_]types.Message{.{ .tool_result = .{
        .tool_call_id = "call_1",
        .tool_name = "bash",
        .content = &.{},
        .added_tool_names = &added,
        .timestamp = 1,
    } }};
    const context = types.Context{
        .messages = &messages,
        .tools = &tools,
    };

    var split = try splitDeferredTools(allocator, context, false);
    defer split.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), split.immediate.len);
    try std.testing.expectEqual(@as(u32, 0), split.deferred.count());
}

test "splitDeferredTools defers unused addedToolNames" {
    const allocator = std.testing.allocator;
    var schema = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer schema.deinit(allocator);

    const tools = [_]types.Tool{
        .{ .name = "bash", .description = "Run", .parameters = .{ .object = schema } },
        .{ .name = "read", .description = "Read", .parameters = .{ .object = schema } },
    };
    const added = [_][]const u8{"read"};
    const messages = [_]types.Message{.{ .tool_result = .{
        .tool_call_id = "call_1",
        .tool_name = "bash",
        .content = &.{},
        .added_tool_names = &added,
        .timestamp = 1,
    } }};
    const context = types.Context{
        .messages = &messages,
        .tools = &tools,
    };

    var split = try splitDeferredTools(allocator, context, true);
    defer split.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), split.immediate.len);
    try std.testing.expectEqualStrings("bash", split.immediate[0].name);
    try std.testing.expect(split.getDeferred("read") != null);
    try std.testing.expect(split.getDeferred("bash") == null);
}

test "splitDeferredTools keeps already-used added tools immediate" {
    const allocator = std.testing.allocator;
    var schema = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer schema.deinit(allocator);

    const tools = [_]types.Tool{
        .{ .name = "read", .description = "Read", .parameters = .{ .object = schema } },
    };
    const added = [_][]const u8{"read"};
    const messages = [_]types.Message{
        .{ .assistant = .{
            .content = &[_]types.ContentBlock{.{ .tool_call = .{
                .id = "call_1",
                .name = "read",
                .arguments = .null,
            } }},
            .api = "openai-responses",
            .provider = "openai",
            .model = "gpt-5.4",
            .usage = types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call_1",
            .tool_name = "read",
            .content = &.{},
            .added_tool_names = &added,
            .timestamp = 2,
        } },
    };
    const context = types.Context{
        .messages = &messages,
        .tools = &tools,
    };

    var split = try splitDeferredTools(allocator, context, true);
    defer split.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), split.immediate.len);
    try std.testing.expectEqualStrings("read", split.immediate[0].name);
    try std.testing.expectEqual(@as(u32, 0), split.deferred.count());
}
