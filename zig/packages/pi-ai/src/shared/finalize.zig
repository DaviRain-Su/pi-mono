const std = @import("std");

const provider_json = @import("provider_json.zig");
const provider_error = @import("provider_error.zig");
const types = @import("../types.zig");

/// Calculate per-token cost from usage counts and model pricing.
/// Per-million-token pricing is the convention across all providers.
pub fn calculateCost(model: types.Model, usage: *types.Usage) void {
    // Anthropic charges 2x base input for 1h cache writes.
    const long_write = usage.cache_write_1h;
    const short_write = usage.cache_write - long_write;
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (model.cost.cache_write * @as(f64, @floatFromInt(short_write)) + model.cost.input * 2.0 * @as(f64, @floatFromInt(long_write))) / 1_000_000.0;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

pub const FinalizeState = struct {
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
};

pub const ContentTransferMode = enum {
    when_output_empty,
    always,
};

pub const TotalTokenMode = enum {
    preserve,
    preserve_or_input_output,
    preserve_or_full_usage,
};

pub const FinalizeOutputOptions = struct {
    content_transfer: ContentTransferMode = .when_output_empty,
    total_tokens: TotalTokenMode = .preserve_or_input_output,
    coerce_stop_reason_for_tool_calls: bool = false,
};

pub fn finalizeOutput(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    state: FinalizeState,
    options: FinalizeOutputOptions,
) !void {
    switch (options.content_transfer) {
        .when_output_empty => {
            if (output.content.len == 0 and state.content_blocks.items.len > 0) {
                output.content = try state.content_blocks.toOwnedSlice(allocator);
            }
        },
        .always => {
            if (output.content.len == 0 or state.content_blocks.items.len > 0) {
                output.content = try state.content_blocks.toOwnedSlice(allocator);
            }
        },
    }

    switch (options.total_tokens) {
        .preserve => {},
        .preserve_or_input_output => {
            if (output.usage.total_tokens == 0) {
                output.usage.total_tokens = output.usage.input + output.usage.output;
            }
        },
        .preserve_or_full_usage => {
            if (output.usage.total_tokens == 0) {
                output.usage.total_tokens = output.usage.input + output.usage.output + output.usage.cache_read + output.usage.cache_write;
            }
        },
    }

    if (options.coerce_stop_reason_for_tool_calls) {
        output.stop_reason = provider_error.coerceStopReasonForToolCalls(output.stop_reason, state.tool_calls.items.len > 0);
    }
}

pub fn appendInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    owned_tool_call: types.ToolCall,
) !void {
    try storeInlineToolCall(allocator, content_blocks, tool_calls, null, owned_tool_call);
}

pub fn insertInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    insert_index: usize,
    owned_tool_call: types.ToolCall,
) !void {
    try storeInlineToolCall(allocator, content_blocks, tool_calls, insert_index, owned_tool_call);
}

fn storeInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    maybe_insert_index: ?usize,
    owned_tool_call: types.ToolCall,
) !void {
    var transferred = false;
    errdefer {
        if (!transferred) freeToolCallOwned(allocator, owned_tool_call);
    }

    try tool_calls.append(allocator, owned_tool_call);
    errdefer {
        if (!transferred) _ = tool_calls.pop();
    }

    if (maybe_insert_index) |insert_index| {
        try content_blocks.insert(allocator, insert_index, .{ .tool_call = owned_tool_call });
    } else {
        try content_blocks.append(allocator, .{ .tool_call = owned_tool_call });
    }
    transferred = true;
}

pub fn freeToolCallOwned(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    provider_json.freeValue(allocator, tool_call.arguments);
}

fn makeTestToolCall(
    allocator: std.mem.Allocator,
    comptime include_signature: bool,
) !types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, "call_1"),
        .name = try allocator.dupe(u8, "lookup"),
        .arguments = .null,
        .thought_signature = if (include_signature) try allocator.dupe(u8, "thought-sig") else null,
    };
}

test "appendInlineToolCall transfers owned data inline and keeps borrow-only copy" {
    const allocator = std.testing.allocator;
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    const tool_call = try makeTestToolCall(allocator, true);
    try appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call);
    defer freeToolCallOwned(allocator, content_blocks.items[0].tool_call);

    try std.testing.expectEqual(@as(usize, 1), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", content_blocks.items[0].tool_call.id);
    try std.testing.expectEqualStrings("lookup", content_blocks.items[0].tool_call.name);
    try std.testing.expectEqualStrings("thought-sig", content_blocks.items[0].tool_call.thought_signature.?);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.id.ptr, tool_calls.items[0].id.ptr);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.name.ptr, tool_calls.items[0].name.ptr);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.thought_signature.?.ptr, tool_calls.items[0].thought_signature.?.ptr);
}

test "finalizeOutput transfers content and preserves borrow-only tool calls" {
    const allocator = std.testing.allocator;
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    try content_blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, "hello") } });
    const tool_call = try makeTestToolCall(allocator, false);
    try appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call);

    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
    output.usage.input = 3;
    output.usage.output = 5;

    try finalizeOutput(allocator, &output, .{
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
    }, .{ .content_transfer = .always, .coerce_stop_reason_for_tool_calls = true });
    defer {
        allocator.free(output.content[0].text.text);
        freeToolCallOwned(allocator, output.content[1].tool_call);
        allocator.free(output.content);
    }

    try std.testing.expectEqual(@as(usize, 0), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), output.content.len);
    try std.testing.expectEqualStrings("hello", output.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.tool_use, output.stop_reason);
    try std.testing.expectEqual(@as(u32, 8), output.usage.total_tokens);
    try std.testing.expectEqual(output.content[1].tool_call.id.ptr, tool_calls.items[0].id.ptr);
}

test "finalizeOutput can preserve existing output content" {
    const allocator = std.testing.allocator;
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer {
        for (content_blocks.items) |block| switch (block) {
            .text => |text| allocator.free(text.text),
            else => {},
        };
        content_blocks.deinit(allocator);
    }
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    try content_blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, "pending") } });
    const existing = try allocator.alloc(types.ContentBlock, 1);
    existing[0] = .{ .text = .{ .text = "existing" } };
    var output = types.AssistantMessage{
        .content = existing,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
    defer allocator.free(existing);

    try finalizeOutput(allocator, &output, .{
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
    }, .{ .content_transfer = .when_output_empty, .total_tokens = .preserve });

    try std.testing.expectEqual(@as(usize, 1), content_blocks.items.len);
    try std.testing.expectEqual(existing.ptr, output.content.ptr);
    try std.testing.expectEqual(@as(u32, 0), output.usage.total_tokens);
}

test "insertInlineToolCall transfers owned data at requested content index" {
    const allocator = std.testing.allocator;
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    try content_blocks.append(allocator, .{ .text = .{ .text = "before" } });
    try content_blocks.append(allocator, .{ .text = .{ .text = "after" } });

    const tool_call = try makeTestToolCall(allocator, false);
    try insertInlineToolCall(allocator, &content_blocks, &tool_calls, 1, tool_call);
    defer freeToolCallOwned(allocator, content_blocks.items[1].tool_call);

    try std.testing.expectEqual(@as(usize, 3), content_blocks.items.len);
    try std.testing.expect(content_blocks.items[1] == .tool_call);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);
    try std.testing.expectEqual(content_blocks.items[1].tool_call.id.ptr, tool_calls.items[0].id.ptr);
}

test "appendInlineToolCall frees owned data when tool-call bookkeeping append fails" {
    var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing_state.allocator();
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    const tool_call = try makeTestToolCall(allocator, false);
    try std.testing.expectError(error.OutOfMemory, appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call));
    try std.testing.expectEqual(@as(usize, 0), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), tool_calls.items.len);
}

test "appendInlineToolCall rolls back bookkeeping when inline append fails" {
    var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 4 });
    const allocator = failing_state.allocator();
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    const tool_call = try makeTestToolCall(allocator, true);
    try std.testing.expectError(error.OutOfMemory, appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call));
    try std.testing.expectEqual(@as(usize, 0), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), tool_calls.items.len);
}
