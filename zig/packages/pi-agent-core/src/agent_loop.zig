const std = @import("std");
const pi_types = @import("pi-types");
const provider_json = pi_types.json;
const types = @import("types.zig");
const json_schema = @import("json_schema.zig");
const accumulator = @import("accumulator.zig");
const content_clone = @import("content_clone.zig");
const tool_execution = @import("tool_execution.zig");
const streaming = @import("streaming.zig");
const test_streams = @import("agent_loop_test_streams.zig");
const test_faux = @import("test_faux.zig");

pub const AgentLoopError = types.AgentLoopError;

/// Returns the assistant payload of `event.message` when both the message and
/// its role are assistant. Returns null otherwise. Used to collapse the
/// recurring `if (event.message) |m| switch (m) { .assistant => |a| ..., else => {} }`
/// boilerplate in event-callback code.
inline fn assistantOfEvent(event: types.AgentEvent) ?pi_types.AssistantMessage {
    const message = event.message orelse return null;
    return switch (message) {
        .assistant => |assistant| assistant,
        else => null,
    };
}

/// Returns the tool_result payload of `event.message` when both the message
/// and its role are tool_result. Returns null otherwise. Mirrors
/// `assistantOfEvent` for the tool_result branch.
inline fn toolResultOfEvent(event: types.AgentEvent) ?types.ToolResultMessage {
    const message = event.message orelse return null;
    return switch (message) {
        .tool_result => |tool_result| tool_result,
        else => null,
    };
}

pub fn runAgentLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const types.AgentMessage,
    context: types.AgentContext,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
    stream_fn: ?types.StreamFn,
) ![]const types.AgentMessage {
    var new_messages = std.ArrayList(types.AgentMessage).empty;
    errdefer new_messages.deinit(allocator);

    var current_messages = std.ArrayList(types.AgentMessage).empty;
    defer current_messages.deinit(allocator);
    try current_messages.appendSlice(allocator, context.messages);

    try emit(emit_context, .{ .event_type = .agent_start });
    try emit(emit_context, .{ .event_type = .turn_start });

    for (prompts) |prompt| {
        try current_messages.append(allocator, prompt);
        try new_messages.append(allocator, prompt);
        try emit(emit_context, .{
            .event_type = .message_start,
            .message = prompt,
        });
        try emit(emit_context, .{
            .event_type = .message_end,
            .message = prompt,
        });
    }

    try runLoop(
        allocator,
        io,
        &current_messages,
        &new_messages,
        context.system_prompt,
        context.tools,
        config,
        emit_context,
        emit,
        signal,
        stream_fn,
    );
    return try allocator.dupe(types.AgentMessage, new_messages.items);
}

fn runLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_messages: *std.ArrayList(types.AgentMessage),
    new_messages: *std.ArrayList(types.AgentMessage),
    system_prompt: []const u8,
    tools: []const types.AgentTool,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
    stream_fn: ?types.StreamFn,
) !void {
    var loop_config = config;
    var current_system_prompt = system_prompt;
    var current_tools = tools;
    var current_extension_hook_context = config.extension_hook_context;
    var first_turn = true;
    var pending_messages = try getPendingMessages(
        allocator,
        loop_config.get_steering_messages,
        loop_config.get_steering_messages_context,
    );
    defer allocator.free(pending_messages);

    while (true) {
        var has_more_tool_calls = true;

        while (has_more_tool_calls or pending_messages.len > 0) {
            if (first_turn) {
                first_turn = false;
            } else {
                try emit(emit_context, .{ .event_type = .turn_start });
            }

            if (pending_messages.len > 0) {
                for (pending_messages) |message| {
                    try current_messages.append(allocator, message);
                    try new_messages.append(allocator, message);
                    try emit(emit_context, .{
                        .event_type = .message_start,
                        .message = message,
                    });
                    try emit(emit_context, .{
                        .event_type = .message_end,
                        .message = message,
                    });
                }

                allocator.free(pending_messages);
                pending_messages = try allocator.alloc(types.AgentMessage, 0);
            }

            const current_context = types.AgentContext{
                .system_prompt = current_system_prompt,
                .messages = current_messages.items,
                .tools = current_tools,
                .extension_hook_context = current_extension_hook_context,
            };

            const assistant = try streaming.streamAssistantResponse(
                allocator,
                io,
                current_context,
                loop_config,
                emit_context,
                emit,
                signal,
                stream_fn,
            );

            try current_messages.append(allocator, .{ .assistant = assistant });
            try new_messages.append(allocator, .{ .assistant = assistant });

            var tool_results = std.ArrayList(types.ToolResultMessage).empty;
            defer tool_results.deinit(allocator);

            if (assistant.stop_reason == .error_reason or assistant.stop_reason == .aborted) {
                try emit(emit_context, .{
                    .event_type = .turn_end,
                    .message = .{ .assistant = assistant },
                    .tool_results = tool_results.items,
                });
                try emit(emit_context, .{
                    .event_type = .agent_end,
                    .messages = new_messages.items,
                });
                return;
            }

            const tool_calls = try pi_types.collectAssistantToolCalls(allocator, assistant);
            defer allocator.free(tool_calls);
            has_more_tool_calls = tool_calls.len > 0;

            if (has_more_tool_calls) {
                const executed_tool_results = try tool_execution.executeToolCalls(
                    allocator,
                    io,
                    current_context,
                    assistant,
                    tool_calls,
                    loop_config,
                    emit_context,
                    emit,
                    signal,
                );
                defer allocator.free(executed_tool_results);

                try tool_results.appendSlice(allocator, executed_tool_results);
                for (tool_results.items) |tool_result| {
                    try current_messages.append(allocator, .{ .tool_result = tool_result });
                    try new_messages.append(allocator, .{ .tool_result = tool_result });
                }
            }

            try emit(emit_context, .{
                .event_type = .turn_end,
                .message = .{ .assistant = assistant },
                .tool_results = tool_results.items,
            });

            if (loop_config.prepare_next_turn) |prepare_next_turn| {
                const after_turn_context = types.AgentContext{
                    .system_prompt = current_system_prompt,
                    .messages = current_messages.items,
                    .tools = current_tools,
                    .extension_hook_context = current_extension_hook_context,
                };
                if (try prepare_next_turn(
                    allocator,
                    .{
                        .assistant_message = assistant,
                        .tool_results = tool_results.items,
                        .context = after_turn_context,
                        .new_messages = new_messages.items,
                    },
                    loop_config.prepare_next_turn_context,
                    signal,
                )) |turn_update| {
                    if (turn_update.context) |next_context| {
                        current_system_prompt = next_context.system_prompt;
                        current_tools = next_context.tools;
                        current_extension_hook_context = next_context.extension_hook_context;
                        if (next_context.messages.ptr != current_messages.items.ptr or
                            next_context.messages.len != current_messages.items.len)
                        {
                            const copied_messages = try allocator.dupe(types.AgentMessage, next_context.messages);
                            defer allocator.free(copied_messages);
                            current_messages.clearRetainingCapacity();
                            try current_messages.appendSlice(allocator, copied_messages);
                        }
                    }
                    if (turn_update.model) |next_model| {
                        loop_config.model = next_model;
                    }
                    if (turn_update.thinking_level) |thinking_level| {
                        loop_config.reasoning = if (thinking_level == .off) null else thinking_level;
                    }
                }
            }

            if (loop_config.should_stop_after_turn) |should_stop_after_turn| {
                const after_turn_context = types.AgentContext{
                    .system_prompt = current_system_prompt,
                    .messages = current_messages.items,
                    .tools = current_tools,
                    .extension_hook_context = current_extension_hook_context,
                };
                if (try should_stop_after_turn(
                    allocator,
                    .{
                        .assistant_message = assistant,
                        .tool_results = tool_results.items,
                        .context = after_turn_context,
                        .new_messages = new_messages.items,
                    },
                    loop_config.should_stop_after_turn_context,
                    signal,
                )) {
                    try emit(emit_context, .{
                        .event_type = .agent_end,
                        .messages = new_messages.items,
                    });
                    return;
                }
            }

            if (isAbortRequested(signal)) {
                try emit(emit_context, .{
                    .event_type = .agent_end,
                    .messages = new_messages.items,
                });
                return;
            }

            allocator.free(pending_messages);
            pending_messages = try getPendingMessages(
                allocator,
                loop_config.get_steering_messages,
                loop_config.get_steering_messages_context,
            );
        }

        allocator.free(pending_messages);
        pending_messages = try getPendingMessages(
            allocator,
            loop_config.get_follow_up_messages,
            loop_config.get_follow_up_messages_context,
        );
        if (pending_messages.len > 0) {
            continue;
        }

        break;
    }

    try emit(emit_context, .{
        .event_type = .agent_end,
        .messages = new_messages.items,
    });
}

fn getPendingMessages(
    allocator: std.mem.Allocator,
    callback: ?types.PendingMessagesFn,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    if (callback) |drain_messages| {
        return try drain_messages(allocator, context);
    }
    return try allocator.alloc(types.AgentMessage, 0);
}

fn isAbortRequested(signal: ?*const std.atomic.Value(bool)) bool {
    return if (signal) |abort_signal| abort_signal.load(.seq_cst) else false;
}

const TestCapture = struct {
    allocator: std.mem.Allocator,
    event_types: std.ArrayList(types.AgentEventType),
    event_messages: std.ArrayList(types.AgentMessage),

    fn init(allocator: std.mem.Allocator) TestCapture {
        return .{
            .allocator = allocator,
            .event_types = .empty,
            .event_messages = .empty,
        };
    }

    fn deinit(self: *TestCapture) void {
        self.event_types.deinit(self.allocator);
        self.event_messages.deinit(self.allocator);
    }
};

fn captureEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *TestCapture = @ptrCast(@alignCast(context.?));
    try capture.event_types.append(capture.allocator, event.event_type);
    if (event.message) |message| {
        try capture.event_messages.append(capture.allocator, message);
    }
}

fn defaultConvertToLlmForTest(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) ![]pi_types.Message {
    return try allocator.dupe(pi_types.Message, messages);
}

fn createUserMessage(text: []const u8, timestamp: i64) types.AgentMessage {
    const content = std.heap.page_allocator.alloc(pi_types.ContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = text } };
    return .{ .user = .{
        .content = content,
        .timestamp = timestamp,
    } };
}

fn expectUserText(message: types.AgentMessage, expected: []const u8) !void {
    switch (message) {
        .user => |user| {
            try std.testing.expectEqual(@as(usize, 1), user.content.len);
            try std.testing.expectEqualStrings(expected, user.content[0].text.text);
        },
        else => return error.UnexpectedMessageRole,
    }
}

fn jsonStringObject(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(
        allocator,
        try allocator.dupe(u8, key),
        .{ .string = try allocator.dupe(u8, value) },
    );
    return .{ .object = object };
}

fn textToolResult(allocator: std.mem.Allocator, text: []const u8) !types.AgentToolResult {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, text),
        },
    };
    return .{
        .content = content,
        .details = null,
    };
}

const ToolResultContentCapture = struct {
    content_ptr: ?[*]const pi_types.ContentBlock = null,
    text_ptr: ?[*]const u8 = null,
    text_len: usize = 0,
};

const ToolResultContentCaptureFixture = struct {
    capture: ToolResultContentCapture = .{},
};

fn capturingEchoToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const result = try echoToolExecute(allocator, tool_call_id, params, tool_context, signal, on_update_context, on_update);
    const fixture: *ToolResultContentCaptureFixture = @ptrCast(@alignCast(tool_context orelse return result));

    fixture.capture.content_ptr = result.content.ptr;
    switch (result.content[0]) {
        .text => |text| {
            fixture.capture.text_ptr = text.text.ptr;
            fixture.capture.text_len = text.text.len;
        },
        else => return error.UnexpectedToolResultContent,
    }

    return result;
}

fn getStringArg(args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return error.InvalidToolArguments;
    const value = args.object.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn yieldForIterations(iterations: usize) void {
    var remaining = iterations;
    while (remaining > 0) : (remaining -= 1) {
        std.Thread.yield() catch {};
    }
}

const ToolExecutionCapture = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(types.AgentEvent),
    turn_tool_result_ids: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) ToolExecutionCapture {
        return .{
            .allocator = allocator,
            .events = .empty,
            .turn_tool_result_ids = .empty,
        };
    }

    fn deinit(self: *ToolExecutionCapture) void {
        for (self.turn_tool_result_ids.items) |tool_call_id| self.allocator.free(tool_call_id);
        self.turn_tool_result_ids.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }
};

const ParallelStreamingCapture = struct {
    main_thread_id: std.Thread.Id,
    slow_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_fast_update_before_slow_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_update_off_main_thread: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    invalid_main_thread_event: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    concurrent_callback_entry: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    update_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    in_callback: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const ParallelHookOrderingCapture = struct {
    allocator: std.mem.Allocator,
    first_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    second_observed_before_first_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    after_hook_order: std.ArrayList([]const u8) = .empty,
    tool_end_order: std.ArrayList([]const u8) = .empty,
    tool_message_order: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) ParallelHookOrderingCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ParallelHookOrderingCapture) void {
        self.after_hook_order.deinit(self.allocator);
        self.tool_end_order.deinit(self.allocator);
        self.tool_message_order.deinit(self.allocator);
    }
};

fn captureToolEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ToolExecutionCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type == .turn_end) {
        if (event.tool_results) |tool_results| {
            for (tool_results) |tool_result| {
                try capture.turn_tool_result_ids.append(
                    capture.allocator,
                    try capture.allocator.dupe(u8, tool_result.tool_call_id),
                );
            }
        }
    }
    try capture.events.append(capture.allocator, event);
}

fn captureParallelHookOrderingEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ParallelHookOrderingCapture = @ptrCast(@alignCast(context.?));
    switch (event.event_type) {
        .tool_execution_end => {
            try capture.tool_end_order.append(capture.allocator, event.tool_call_id orelse return error.MissingToolCallId);
        },
        .message_end => if (toolResultOfEvent(event)) |tool_result| {
            try capture.tool_message_order.append(capture.allocator, tool_result.tool_call_id);
        },
        else => {},
    }
}

fn captureParallelStreamingEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ParallelStreamingCapture = @ptrCast(@alignCast(context.?));
    const current_thread_id = std.Thread.getCurrentId();
    switch (event.event_type) {
        .tool_execution_start, .tool_execution_end => {
            if (current_thread_id != capture.main_thread_id) {
                capture.invalid_main_thread_event.store(true, .seq_cst);
            }
        },
        .tool_execution_update => {
            if (capture.in_callback.swap(true, .seq_cst)) {
                capture.concurrent_callback_entry.store(true, .seq_cst);
            }
            defer capture.in_callback.store(false, .seq_cst);

            if (current_thread_id != capture.main_thread_id) {
                capture.saw_update_off_main_thread.store(true, .seq_cst);
            }
            _ = capture.update_count.fetchAdd(1, .seq_cst);
            if (event.tool_call_id) |tool_call_id| {
                if (std.mem.eql(u8, tool_call_id, "fast") and !capture.slow_done.load(.seq_cst)) {
                    capture.saw_fast_update_before_slow_done.store(true, .seq_cst);
                }
            }
            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        },
        else => {},
    }
}

fn ignoreEvent(_: ?*anyopaque, _: types.AgentEvent) !void {}

fn passthroughConvertToLlmForTest(
    _: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) ![]pi_types.Message {
    return @constCast(messages);
}

const PartialUpdateCrossCapture = struct {
    saw_thinking_delta: bool = false,
    saw_thinking_end: bool = false,
    saw_text_delta: bool = false,
    saw_toolcall_delta: bool = false,
    saw_toolcall_end: bool = false,
};

const StreamingUpdateSnapshotCapture = struct {
    allocator: std.mem.Allocator,
    snapshots: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) StreamingUpdateSnapshotCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StreamingUpdateSnapshotCapture) void {
        for (self.snapshots.items) |snapshot| self.allocator.free(snapshot);
        self.snapshots.deinit(self.allocator);
    }
};

const MessageUpdateCountCapture = struct {
    message_update_count: usize = 0,
    message_end_count: usize = 0,
};

fn capturePartialUpdateCrossEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *PartialUpdateCrossCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_update) return;
    const assistant_event = event.assistant_message_event orelse return;
    const message = event.message orelse return error.MissingPartialMessage;
    const assistant = switch (message) {
        .assistant => |assistant_message| assistant_message,
        else => return error.UnexpectedMessageRole,
    };

    switch (assistant_event.event_type) {
        .thinking_delta => {
            if (!std.mem.eql(u8, assistant_event.delta orelse "", "first")) return;
            capture.saw_thinking_delta = true;
            try std.testing.expectEqual(@as(?u32, 0), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
        },
        .thinking_end => {
            capture.saw_thinking_end = true;
            try std.testing.expectEqual(@as(?u32, 0), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
        },
        .text_delta => {
            if (!std.mem.eql(u8, assistant_event.delta orelse "", "text")) return;
            capture.saw_text_delta = true;
            try std.testing.expectEqual(@as(?u32, 1), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
        },
        .toolcall_delta => {
            capture.saw_toolcall_delta = true;
            try std.testing.expectEqual(@as(?u32, 2), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
            try std.testing.expect(assistant.content[2] == .tool_call);
            const arguments = assistant.content[2].tool_call.arguments;
            try std.testing.expect(arguments == .object);
            try std.testing.expectEqualStrings("par", arguments.object.get("query").?.string);
        },
        .toolcall_end => {
            capture.saw_toolcall_end = true;
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
            try std.testing.expectEqualStrings("call_1", assistant.content[2].tool_call.id);
            try std.testing.expectEqualStrings("lookup", assistant.content[2].tool_call.name);
            try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
        },
        else => {},
    }
}

fn captureStreamingUpdateSnapshotEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *StreamingUpdateSnapshotCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_update) return;

    const snapshot = try streamingUpdateSnapshot(capture.allocator, event);
    errdefer capture.allocator.free(snapshot);
    try capture.snapshots.append(capture.allocator, snapshot);
}

fn countMessageUpdateEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *MessageUpdateCountCapture = @ptrCast(@alignCast(context.?));
    switch (event.event_type) {
        .message_update => capture.message_update_count += 1,
        .message_end => capture.message_end_count += 1,
        else => {},
    }
}

fn streamingUpdateSnapshot(allocator: std.mem.Allocator, event: types.AgentEvent) ![]const u8 {
    const assistant_event = event.assistant_message_event orelse return error.MissingAssistantMessageEvent;
    const message = event.message orelse return error.MissingPartialMessage;
    const assistant = switch (message) {
        .assistant => |assistant_message| assistant_message,
        else => return error.UnexpectedMessageRole,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("event={s}", .{@tagName(assistant_event.event_type)});
    if (assistant_event.content_index) |content_index| {
        try out.writer.print("|index={d}", .{content_index});
    }
    if (assistant_event.delta) |delta| {
        try out.writer.print("|delta={s}", .{delta});
    }
    if (assistant_event.content) |content| {
        try out.writer.print("|content={s}", .{content});
    }
    if (assistant_event.tool_call) |tool_call| {
        try out.writer.writeAll("|eventToolCall=");
        try writeToolCallSnapshot(allocator, &out.writer, tool_call);
    }

    try out.writer.writeAll("|message=");
    try writeContentSnapshot(allocator, &out.writer, assistant.content);
    return allocator.dupe(u8, out.written());
}

fn writeContentSnapshot(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    content: []const pi_types.ContentBlock,
) !void {
    try writer.writeAll("[");
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        switch (block) {
            .text => |text| try writer.print("text:{s}", .{text.text}),
            .thinking => |thinking| try writer.print("thinking:{s}", .{thinking.thinking}),
            .tool_call => |tool_call| {
                try writer.writeAll("toolCall:");
                try writeToolCallSnapshot(allocator, writer, tool_call);
            },
            .image => try writer.writeAll("image"),
        }
    }
    try writer.writeAll("]");
}

fn writeToolCallSnapshot(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tool_call: pi_types.ToolCall,
) !void {
    const args_json = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{});
    defer allocator.free(args_json);
    try writer.print("id={s},name={s},args={s}", .{ tool_call.id, tool_call.name, args_json });
}

const MalformedPartialArgsCapture = struct {
    saw_malformed_toolcall_delta: bool = false,
};

fn captureMalformedPartialArgsEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *MalformedPartialArgsCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_update) return;
    const assistant_event = event.assistant_message_event orelse return;
    if (assistant_event.event_type != .toolcall_delta) return;

    const message = event.message orelse return error.MissingPartialMessage;
    const assistant = switch (message) {
        .assistant => |assistant_message| assistant_message,
        else => return error.UnexpectedMessageRole,
    };

    capture.saw_malformed_toolcall_delta = true;
    try std.testing.expectEqual(@as(?u32, 1), assistant_event.content_index);
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expectEqualStrings("before tool", assistant.content[0].text.text);
    try std.testing.expect(assistant.content[1] == .tool_call);
    const arguments = assistant.content[1].tool_call.arguments;
    try std.testing.expect(arguments == .object);
    try std.testing.expectEqual(@as(usize, 0), arguments.object.count());
}

const CountedToolFixture = struct {
    execute_count: usize = 0,
};

const HookLifecycleFixture = struct {
    execute_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    after_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn echoToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const value = try getStringArg(params, "value");
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
    );
}

fn countedEchoToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *CountedToolFixture = @ptrCast(@alignCast(tool_context orelse return error.MissingCountedToolFixture));
    fixture.execute_count += 1;
    return try echoToolExecute(allocator, tool_call_id, params, tool_context, signal, on_update_context, on_update);
}

fn lifecycleEchoToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *HookLifecycleFixture = @ptrCast(@alignCast(tool_context orelse return error.MissingHookLifecycleFixture));
    _ = fixture.execute_count.fetchAdd(1, .seq_cst);
    return try echoToolExecute(allocator, tool_call_id, params, tool_context, signal, on_update_context, on_update);
}

fn requireValuePrepareArguments(
    allocator: std.mem.Allocator,
    args: std.json.Value,
) !std.json.Value {
    _ = try getStringArg(args, "value");
    return try provider_json.cloneValue(allocator, args);
}

fn failingToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    _ = allocator;
    return error.ToolFailure;
}

const ParallelObservation = struct {
    first_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    parallel_observed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn parallelAwareEchoToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const observation: *ParallelObservation = @ptrCast(@alignCast(tool_context orelse return error.MissingParallelObservation));
    const value = try getStringArg(params, "value");
    if (std.mem.eql(u8, value, "first")) {
        yieldForIterations(50_000);
        observation.first_finished.store(true, .seq_cst);
    } else if (!observation.first_finished.load(.seq_cst)) {
        observation.parallel_observed.store(true, .seq_cst);
    }
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
    );
}

fn hookOrderingToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const capture: *ParallelHookOrderingCapture = @ptrCast(@alignCast(tool_context orelse return error.MissingParallelHookOrderingCapture));
    const value = try getStringArg(params, "value");
    if (std.mem.eql(u8, value, "first")) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
        capture.first_finished.store(true, .seq_cst);
    } else if (!capture.first_finished.load(.seq_cst)) {
        capture.second_observed_before_first_finished.store(true, .seq_cst);
    }
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
    );
}

fn streamingParallelToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const capture: *ParallelStreamingCapture = @ptrCast(@alignCast(tool_context.?));
    const value = try getStringArg(params, "value");
    if (std.mem.eql(u8, value, "slow")) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
        capture.slow_done.store(true, .seq_cst);
    } else {
        if (on_update) |callback| {
            const update = try textToolResult(
                allocator,
                try std.fmt.allocPrint(allocator, "{s} update", .{tool_call_id}),
            );
            try callback(on_update_context, update);
        }
    }
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "{s} done", .{value}),
    );
}

fn stressStreamingParallelToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    if (on_update) |callback| {
        for (0..100) |index| {
            const update = try textToolResult(
                allocator,
                try std.fmt.allocPrint(allocator, "{s}:{d}", .{ tool_call_id, index }),
            );
            try callback(on_update_context, update);
        }
    }
    return try textToolResult(allocator, try std.fmt.allocPrint(allocator, "{s} done", .{tool_call_id}));
}

fn blockBeforeToolCall(
    _: std.mem.Allocator,
    _: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    return .{
        .block = true,
        .reason = "blocked by hook",
    };
}

fn errorBeforeToolCall(
    _: std.mem.Allocator,
    _: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    return error.BeforeToolCallFailed;
}

fn mixedBeforeToolCall(
    _: std.mem.Allocator,
    context: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    const value = try getStringArg(context.args.*, "value");
    if (std.mem.eql(u8, value, "block")) {
        return .{
            .block = true,
            .reason = "blocked by mixed hook",
        };
    }
    if (std.mem.eql(u8, value, "error")) {
        return error.BeforeToolCallFailed;
    }
    return null;
}

fn recordAfterToolCallOrder(
    _: std.mem.Allocator,
    context: types.AfterToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.AfterToolCallResult {
    const tool = tool_execution.findTool(context.context.tools, context.tool_call.name) orelse return error.MissingParallelHookOrderingTool;
    const capture: *ParallelHookOrderingCapture = @ptrCast(@alignCast(tool.execute_context orelse return error.MissingParallelHookOrderingCapture));
    try capture.after_hook_order.append(capture.allocator, context.tool_call.id);
    return null;
}

fn recordHookLifecycleAfterToolCall(
    _: std.mem.Allocator,
    context: types.AfterToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.AfterToolCallResult {
    const tool = tool_execution.findTool(context.context.tools, context.tool_call.name) orelse return error.MissingHookLifecycleTool;
    const fixture: *HookLifecycleFixture = @ptrCast(@alignCast(tool.execute_context orelse return error.MissingHookLifecycleFixture));
    _ = fixture.after_count.fetchAdd(1, .seq_cst);
    return null;
}

fn overrideAfterToolCall(
    allocator: std.mem.Allocator,
    _: types.AfterToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.AfterToolCallResult {
    const content = try allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, "modified by hook"),
        },
    };
    return .{
        .content = content,
        .is_error = false,
    };
}

const ReentrantToolContext = struct {
    nested_event_count: usize = 0,
};

fn countReentrantNestedEvent(context: ?*anyopaque, _: types.AgentEvent) !void {
    const fixture: *ReentrantToolContext = @ptrCast(@alignCast(context.?));
    fixture.nested_event_count += 1;
}

fn reentrantToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *ReentrantToolContext = @ptrCast(@alignCast(tool_context orelse return error.MissingReentrantToolContext));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const nested_model = pi_types.Model{
        .id = "nested-model",
        .name = "Nested Model",
        .api = "recording:test:reentrant-nested",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    const nested_prompts = [_]types.AgentMessage{createUserMessage("nested prompt", 1)};
    const nested_result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        nested_prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = nested_model,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        fixture,
        countReentrantNestedEvent,
        signal,
        test_streams.ownedDeltaStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 2), nested_result.len);
    try std.testing.expectEqualStrings("streamed response", nested_result[1].assistant.content[0].text.text);
    return try textToolResult(allocator, "nested: streamed response");
}

const PendingQueueTestState = struct {
    steering_poll_count: usize = 0,
    follow_up_poll_count: usize = 0,
};

const ShouldStopAfterTurnTestState = struct {
    callback_count: usize = 0,
    stop_after_call: ?usize = null,
    context_message_len: usize = 0,
    context_system_prompt: []const u8 = "",
    new_message_len: usize = 0,
    tool_result_len: usize = 0,
    assistant_stop_reason: pi_types.StopReason = .stop,
};

fn shouldStopAfterTurnForTest(
    _: std.mem.Allocator,
    context: types.ShouldStopAfterTurnContext,
    callback_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
) !bool {
    const state: *ShouldStopAfterTurnTestState = @ptrCast(@alignCast(callback_context.?));
    state.callback_count += 1;
    state.context_message_len = context.context.messages.len;
    state.context_system_prompt = context.context.system_prompt;
    state.new_message_len = context.new_messages.len;
    state.tool_result_len = context.tool_results.len;
    state.assistant_stop_reason = context.assistant_message.stop_reason;
    if (state.stop_after_call) |stop_after_call| {
        return state.callback_count >= stop_after_call;
    }
    return false;
}

const PrepareNextTurnTestState = struct {
    callback_count: usize = 0,
    context_message_len: usize = 0,
    new_message_len: usize = 0,
    tool_result_len: usize = 0,
    system_prompt: ?[]const u8 = null,
    tools: []const types.AgentTool = &.{},
    model: ?pi_types.Model = null,
    thinking_level: ?types.ThinkingLevel = null,
};

fn prepareNextTurnForTest(
    _: std.mem.Allocator,
    context: types.PrepareNextTurnContext,
    callback_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
) !?types.AgentLoopTurnUpdate {
    const state: *PrepareNextTurnTestState = @ptrCast(@alignCast(callback_context.?));
    state.callback_count += 1;
    state.context_message_len = context.context.messages.len;
    state.new_message_len = context.new_messages.len;
    state.tool_result_len = context.tool_results.len;
    if (state.callback_count > 1) return null;

    var update = types.AgentLoopTurnUpdate{};
    if (state.system_prompt != null or state.tools.len > 0) {
        update.context = .{
            .system_prompt = state.system_prompt orelse context.context.system_prompt,
            .messages = context.context.messages,
            .tools = if (state.tools.len > 0) state.tools else context.context.tools,
            .extension_hook_context = context.context.extension_hook_context,
        };
    }
    update.model = state.model;
    update.thinking_level = state.thinking_level;
    return update;
}

fn drainSteeringForTest(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const state: *PendingQueueTestState = @ptrCast(@alignCast(context.?));
    state.steering_poll_count += 1;
    if (state.steering_poll_count == 2) {
        const messages = try allocator.alloc(types.AgentMessage, 1);
        messages[0] = createUserMessage("steer now", 2);
        return messages;
    }
    return try allocator.alloc(types.AgentMessage, 0);
}

fn drainFollowUpsForTest(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const state: *PendingQueueTestState = @ptrCast(@alignCast(context.?));
    state.follow_up_poll_count += 1;
    if (state.follow_up_poll_count == 1) {
        const messages = try allocator.alloc(types.AgentMessage, 1);
        messages[0] = createUserMessage("follow up", 2);
        return messages;
    }
    return try allocator.alloc(types.AgentMessage, 0);
}

fn drainNoMessages(
    allocator: std.mem.Allocator,
    _: ?*anyopaque,
) ![]types.AgentMessage {
    return try allocator.alloc(types.AgentMessage, 0);
}

fn steeringQueueFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;

    switch (call_count.*) {
        1 => {
            try std.testing.expectEqual(@as(usize, 1), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("first reply");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        2 => {
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
            try expectUserText(context.messages[2], "steer now");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("after steer");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => return error.UnexpectedFactoryCallCount,
    }
}

fn followUpQueueFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;

    switch (call_count.*) {
        1 => {
            try std.testing.expectEqual(@as(usize, 1), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("first reply");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        2 => {
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
            try expectUserText(context.messages[2], "follow up");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("after follow up");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => return error.UnexpectedFactoryCallCount,
    }
}

fn prepareContextUpdateFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;

    switch (call_count.*) {
        1 => {
            try std.testing.expectEqualStrings("first prompt", context.system_prompt.?);
            const llm_tools = context.tools orelse return error.MissingTools;
            try std.testing.expectEqual(@as(usize, 1), llm_tools.len);
            try std.testing.expectEqualStrings("echo", llm_tools[0].name);
            return try buildToolCallAssistantMessage(allocator, "tool-1", "echo", "hello");
        },
        2 => {
            try std.testing.expectEqualStrings("second prompt", context.system_prompt.?);
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            const llm_tools = context.tools orelse return error.MissingTools;
            try std.testing.expectEqual(@as(usize, 1), llm_tools.len);
            try std.testing.expectEqualStrings("replacement", llm_tools[0].name);
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("done after prepared context");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => return error.UnexpectedFactoryCallCount,
    }
}

const PrepareModelReasoningStreamState = struct {
    call_count: usize = 0,
};

fn prepareModelReasoningStreamFn(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const state: *PrepareModelReasoningStreamState = @ptrCast(@alignCast(stream_context orelse return error.MissingPrepareModelReasoningState));
    state.call_count += 1;
    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);

    const assistant = switch (state.call_count) {
        1 => blk: {
            try std.testing.expectEqualStrings("model-one", model.id);
            const args = try jsonStringObject(allocator, "value", "hello");
            const tool_calls = try allocator.alloc(pi_types.ToolCall, 1);
            tool_calls[0] = .{
                .id = try allocator.dupe(u8, "tool-1"),
                .name = try allocator.dupe(u8, "echo"),
                .arguments = args,
            };
            const content_args = try jsonStringObject(allocator, "value", "hello");
            const content = try allocator.alloc(pi_types.ContentBlock, 1);
            content[0] = .{ .tool_call = .{
                .id = try allocator.dupe(u8, "tool-1"),
                .name = try allocator.dupe(u8, "echo"),
                .arguments = content_args,
            } };
            break :blk pi_types.AssistantMessage{
                .content = content,
                .tool_calls = tool_calls,
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = pi_types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 1,
            };
        },
        2 => blk: {
            try std.testing.expectEqualStrings("model-two", model.id);
            const stream_options = options orelse return error.MissingStreamOptions;
            try std.testing.expectEqual(pi_types.ThinkingLevel.high, stream_options.reasoning.?);
            const content = try allocator.alloc(pi_types.ContentBlock, 1);
            content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "done with next model") } };
            break :blk pi_types.AssistantMessage{
                .content = content,
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = pi_types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 1,
            };
        },
        else => return error.UnexpectedFactoryCallCount,
    };
    stream.push(.{
        .event_type = if (assistant.stop_reason == .tool_use) .start else .done,
        .message = assistant,
    });
    if (assistant.stop_reason == .tool_use) {
        stream.push(.{ .event_type = .done, .message = assistant });
    }
    stream.end(assistant);
    return stream;
}

fn prepareStopFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqualStrings("first prompt", context.system_prompt.?);
    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("stop before follow up");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "runAgentLoop injects steering messages before the next LLM call" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = steeringQueueFactory },
        .{ .factory = steeringQueueFactory },
    });

    var queue_state = PendingQueueTestState{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainSteeringForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqualStrings("first reply", result[1].assistant.content[0].text.text);
    try expectUserText(result[2], "steer now");
    try std.testing.expectEqualStrings("after steer", result[3].assistant.content[0].text.text);
}

test "runAgentLoop processes follow-up messages only after the agent would otherwise stop" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = followUpQueueFactory },
        .{ .factory = followUpQueueFactory },
    });

    var queue_state = PendingQueueTestState{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainNoMessages,
            .get_follow_up_messages_context = &queue_state,
            .get_follow_up_messages = drainFollowUpsForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqualStrings("first reply", result[1].assistant.content[0].text.text);
    try expectUserText(result[2], "follow up");
    try std.testing.expectEqualStrings("after follow up", result[3].assistant.content[0].text.text);
}

test "runAgentLoop uses prepare_next_turn context snapshot before continuing" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = prepareContextUpdateFactory },
        .{ .factory = prepareContextUpdateFactory },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const echo_tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute = echoToolExecute,
    };
    const replacement_tool = types.AgentTool{
        .name = "replacement",
        .description = "Replacement tool",
        .label = "Replacement",
        .parameters = .null,
    };
    const replacement_tools = [_]types.AgentTool{replacement_tool};
    var prepare_state = PrepareNextTurnTestState{
        .system_prompt = "second prompt",
        .tools = replacement_tools[0..],
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "first prompt",
            .messages = &.{},
            .tools = &[_]types.AgentTool{echo_tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .prepare_next_turn_context = &prepare_state,
            .prepare_next_turn = prepareNextTurnForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("done after prepared context", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 2), prepare_state.callback_count);
    try std.testing.expectEqual(@as(usize, 4), prepare_state.context_message_len);
    try std.testing.expectEqual(@as(usize, 4), prepare_state.new_message_len);
}

test "runAgentLoop applies prepare_next_turn model and thinking level to the next request" {
    const initial_model = pi_types.Model{
        .id = "model-one",
        .name = "Model One",
        .api = "recording:test:prepare-model",
        .provider = "recording",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    const next_model = pi_types.Model{
        .id = "model-two",
        .name = "Model Two",
        .api = "recording:test:prepare-model",
        .provider = "recording",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stream_state = PrepareModelReasoningStreamState{};

    const echo_tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute = echoToolExecute,
    };
    var prepare_state = PrepareNextTurnTestState{
        .model = next_model,
        .thinking_level = .high,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{echo_tool},
        },
        .{
            .model = initial_model,
            .convert_to_llm = defaultConvertToLlmForTest,
            .prepare_next_turn_context = &prepare_state,
            .prepare_next_turn = prepareNextTurnForTest,
            .stream_context = &stream_state,
        },
        null,
        ignoreEvent,
        null,
        prepareModelReasoningStreamFn,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("model-two", result[3].assistant.model);
    try std.testing.expectEqualStrings("done with next model", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 2), prepare_state.callback_count);
    try std.testing.expectEqual(@as(usize, 2), stream_state.call_count);
}

test "runAgentLoop runs prepare_next_turn before should_stop_after_turn and does not continue when stopped" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = prepareStopFactory },
    });

    var queue_state = PendingQueueTestState{};
    var prepare_state = PrepareNextTurnTestState{ .system_prompt = "prepared prompt" };
    var stop_state = ShouldStopAfterTurnTestState{ .stop_after_call = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "first prompt",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainSteeringForTest,
            .get_follow_up_messages_context = &queue_state,
            .get_follow_up_messages = drainFollowUpsForTest,
            .prepare_next_turn_context = &prepare_state,
            .prepare_next_turn = prepareNextTurnForTest,
            .should_stop_after_turn_context = &stop_state,
            .should_stop_after_turn = shouldStopAfterTurnForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("stop before follow up", result[1].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), prepare_state.callback_count);
    try std.testing.expectEqual(@as(usize, 1), stop_state.callback_count);
    try std.testing.expectEqualStrings("prepared prompt", stop_state.context_system_prompt);
    try std.testing.expectEqual(@as(usize, 1), queue_state.steering_poll_count);
    try std.testing.expectEqual(@as(usize, 0), queue_state.follow_up_poll_count);
}

test "runAgentLoop continues normally when should_stop_after_turn returns false" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = followUpQueueFactory },
        .{ .factory = followUpQueueFactory },
    });

    var queue_state = PendingQueueTestState{};
    var stop_state = ShouldStopAfterTurnTestState{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages = drainNoMessages,
            .get_follow_up_messages_context = &queue_state,
            .get_follow_up_messages = drainFollowUpsForTest,
            .should_stop_after_turn_context = &stop_state,
            .should_stop_after_turn = shouldStopAfterTurnForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqualStrings("first reply", result[1].assistant.content[0].text.text);
    try expectUserText(result[2], "follow up");
    try std.testing.expectEqualStrings("after follow up", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 2), stop_state.callback_count);
    try std.testing.expectEqual(@as(usize, 2), queue_state.follow_up_poll_count);
    try std.testing.expectEqual(@as(usize, 4), stop_state.context_message_len);
    try std.testing.expectEqual(@as(usize, 4), stop_state.new_message_len);
    try std.testing.expectEqual(@as(usize, 0), stop_state.tool_result_len);
    try std.testing.expectEqual(pi_types.StopReason.stop, stop_state.assistant_stop_reason);
}

test "runAgentLoop stops after first assistant turn when should_stop_after_turn returns true" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = followUpQueueFactory },
    });

    var queue_state = PendingQueueTestState{};
    var stop_state = ShouldStopAfterTurnTestState{ .stop_after_call = 1 };
    var capture = TestCapture.init(std.testing.allocator);
    defer capture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainSteeringForTest,
            .get_follow_up_messages_context = &queue_state,
            .get_follow_up_messages = drainFollowUpsForTest,
            .should_stop_after_turn_context = &stop_state,
            .should_stop_after_turn = shouldStopAfterTurnForTest,
        },
        &capture,
        captureEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqualStrings("first reply", result[1].assistant.content[0].text.text);
    try std.testing.expectEqual(pi_types.StopReason.stop, result[1].assistant.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), stop_state.callback_count);
    try std.testing.expectEqual(@as(usize, 1), queue_state.steering_poll_count);
    try std.testing.expectEqual(@as(usize, 0), queue_state.follow_up_poll_count);
    try std.testing.expectEqual(@as(usize, 2), stop_state.context_message_len);
    try std.testing.expectEqual(@as(usize, 2), stop_state.new_message_len);
    try std.testing.expectEqual(@as(usize, 0), stop_state.tool_result_len);
    try std.testing.expectEqual(pi_types.StopReason.stop, stop_state.assistant_stop_reason);
    try std.testing.expectEqual(types.AgentEventType.turn_end, capture.event_types.items[capture.event_types.items.len - 2]);
    try std.testing.expectEqual(types.AgentEventType.agent_end, capture.event_types.items[capture.event_types.items.len - 1]);
}

test "runAgentLoop stops after tool roundtrip when should_stop_after_turn returns true" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
    });

    var queue_state = PendingQueueTestState{};
    var stop_state = ShouldStopAfterTurnTestState{ .stop_after_call = 1 };
    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainSteeringForTest,
            .get_follow_up_messages_context = &queue_state,
            .get_follow_up_messages = drainFollowUpsForTest,
            .should_stop_after_turn_context = &stop_state,
            .should_stop_after_turn = shouldStopAfterTurnForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqual(pi_types.StopReason.tool_use, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("echoed: hello", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_count);
    try std.testing.expectEqual(@as(usize, 1), stop_state.callback_count);
    try std.testing.expectEqual(@as(usize, 1), queue_state.steering_poll_count);
    try std.testing.expectEqual(@as(usize, 0), queue_state.follow_up_poll_count);
    try std.testing.expectEqual(@as(usize, 3), stop_state.context_message_len);
    try std.testing.expectEqual(@as(usize, 3), stop_state.new_message_len);
    try std.testing.expectEqual(@as(usize, 1), stop_state.tool_result_len);
    try std.testing.expectEqual(pi_types.StopReason.tool_use, stop_state.assistant_stop_reason);
    try std.testing.expectEqual(@as(usize, 1), capture.turn_tool_result_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", capture.turn_tool_result_ids.items[0]);
    try std.testing.expectEqual(types.AgentEventType.turn_end, capture.events.items[capture.events.items.len - 2].event_type);
    try std.testing.expectEqual(types.AgentEventType.agent_end, capture.events.items[capture.events.items.len - 1].event_type);
}

fn buildToolCallAssistantMessage(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    value: []const u8,
) !test_faux.FauxAssistantMessage {
    const args = try jsonStringObject(allocator, "value", value);
    const blocks = try allocator.alloc(test_faux.FauxContentBlock, 1);
    blocks[0] = try test_faux.fauxToolCall(allocator, name, args, .{ .id = id });
    return test_faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .tool_use,
    });
}

fn iss409MixedContinuationFactory(
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    _: ?pi_types.StreamOptions,
    call_count: *usize,
    _: pi_types.Model,
) !test_faux.FauxAssistantMessage {
    const faux = test_faux;
    try std.testing.expectEqual(@as(usize, 2), call_count.*);
    try std.testing.expectEqual(@as(usize, 6), context.messages.len);
    try expectUserText(context.messages[0], "hello");
    try std.testing.expectEqual(pi_types.StopReason.tool_use, context.messages[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("tool-1", context.messages[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-blocked", context.messages[3].tool_result.tool_call_id);
    try std.testing.expect(context.messages[3].tool_result.is_error);
    try std.testing.expectEqualStrings("blocked by mixed hook", context.messages[3].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("tool-error", context.messages[4].tool_result.tool_call_id);
    try std.testing.expect(context.messages[4].tool_result.is_error);
    try std.testing.expectEqualStrings("BeforeToolCallFailed", context.messages[4].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("tool-2", context.messages[5].tool_result.tool_call_id);

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("continued after mixed hooks");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "runAgentLoop executes a single tool call and appends the tool result to the transcript" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const second_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    const responses = [_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(second_blocks[0..], .{}) },
    };
    try registration.setResponses(responses[0..]);

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const start_ms = types.nowMilliseconds();
    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("hello", result[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("echo", result[2].tool_result.tool_name);
    try std.testing.expectEqualStrings("echoed: hello", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("done", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_count);
    const end_ms = types.nowMilliseconds();
    try std.testing.expect(result[2].tool_result.timestamp > 0);
    try std.testing.expect(result[2].tool_result.timestamp >= start_ms - 2000);
    try std.testing.expect(result[2].tool_result.timestamp <= end_ms + 2000);

    var saw_tool_start = false;
    var saw_tool_end = false;
    for (capture.events.items) |event| {
        if (event.event_type == .tool_execution_start) saw_tool_start = true;
        if (event.event_type == .tool_execution_end) saw_tool_end = true;
    }
    try std.testing.expect(saw_tool_start);
    try std.testing.expect(saw_tool_end);
}

test "ISS-405 tool execution and result messages follow assistant message_end" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:tool-ordering",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "bash",
        .description = "Echo command",
        .label = "Bash",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };
    var stream_context = test_streams.ReentrantOuterStreamContext{};
    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = model,
            .convert_to_llm = defaultConvertToLlmForTest,
            .stream_context = &stream_context,
            .tool_execution = .sequential,
        },
        &capture,
        captureToolEvent,
        null,
        test_streams.reentrantOuterStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("streamed response", result[3].assistant.content[0].text.text);

    var assistant_start_index: ?usize = null;
    var assistant_end_index: ?usize = null;
    var last_update_index: ?usize = null;
    var tool_start_index: ?usize = null;
    var tool_end_index: ?usize = null;
    var tool_result_message_start_index: ?usize = null;
    var tool_result_message_index: ?usize = null;
    var turn_end_index: ?usize = null;

    for (capture.events.items, 0..) |event, index| {
        switch (event.event_type) {
            .message_update => last_update_index = index,
            .message_start => {
                if (assistantOfEvent(event)) |assistant| {
                    if (assistant.stop_reason == .tool_use and assistant_start_index == null) {
                        assistant_start_index = index;
                    }
                }
                if (toolResultOfEvent(event)) |_| {
                    if (tool_result_message_start_index == null) tool_result_message_start_index = index;
                }
            },
            .message_end => {
                if (assistantOfEvent(event)) |assistant| {
                    if (assistant.stop_reason == .tool_use and assistant_end_index == null) {
                        assistant_end_index = index;
                    }
                }
                if (toolResultOfEvent(event)) |_| {
                    if (tool_result_message_index == null) tool_result_message_index = index;
                }
            },
            .tool_execution_start => {
                if (tool_start_index == null) tool_start_index = index;
            },
            .tool_execution_end => {
                if (tool_end_index == null) tool_end_index = index;
            },
            .turn_end => if (turn_end_index == null) {
                turn_end_index = index;
            },
            else => {},
        }
    }

    try std.testing.expect(assistant_start_index != null);
    try std.testing.expect(last_update_index != null);
    try std.testing.expect(assistant_end_index != null);
    try std.testing.expect(tool_start_index != null);
    try std.testing.expect(tool_end_index != null);
    try std.testing.expect(tool_result_message_start_index != null);
    try std.testing.expect(tool_result_message_index != null);
    try std.testing.expect(turn_end_index != null);
    for (capture.events.items[assistant_start_index.? + 1 .. assistant_end_index.?]) |event| {
        switch (event.event_type) {
            .tool_execution_start, .tool_execution_update, .tool_execution_end => return error.ToolLifecycleInterleavedInAssistantWindow,
            .message_start, .message_end => if (toolResultOfEvent(event)) |_| return error.ToolResultInterleavedInAssistantWindow,
            else => {},
        }
    }
    try std.testing.expect(last_update_index.? < assistant_end_index.?);
    try std.testing.expect(assistant_end_index.? < tool_start_index.?);
    try std.testing.expect(tool_start_index.? < tool_end_index.?);
    try std.testing.expect(tool_end_index.? < tool_result_message_start_index.?);
    try std.testing.expect(tool_end_index.? < tool_result_message_index.?);
    try std.testing.expect(tool_result_message_index.? < turn_end_index.?);
    try std.testing.expectEqual(@as(usize, 1), capture.turn_tool_result_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", capture.turn_tool_result_ids.items[0]);
}

test "ISS-405 immediate tool outcomes follow assistant message_end and precede result messages" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("continued after missing tool")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "missing-tool", "missing", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("missing-tool", result[2].tool_result.tool_call_id);
    try std.testing.expect(result[2].tool_result.is_error);

    var assistant_start_index: ?usize = null;
    var assistant_end_index: ?usize = null;
    var tool_start_index: ?usize = null;
    var tool_end_index: ?usize = null;
    var tool_result_start_index: ?usize = null;
    var tool_result_end_index: ?usize = null;
    var turn_end_index: ?usize = null;

    for (capture.events.items, 0..) |event, index| {
        switch (event.event_type) {
            .message_start => {
                if (assistantOfEvent(event)) |assistant| {
                    if (assistant.stop_reason == .tool_use and assistant_start_index == null) assistant_start_index = index;
                }
                if (toolResultOfEvent(event)) |_| {
                    if (tool_result_start_index == null) tool_result_start_index = index;
                }
            },
            .message_end => {
                if (assistantOfEvent(event)) |assistant| {
                    if (assistant.stop_reason == .tool_use and assistant_end_index == null) assistant_end_index = index;
                }
                if (toolResultOfEvent(event)) |_| {
                    if (tool_result_end_index == null) tool_result_end_index = index;
                }
            },
            .tool_execution_start => if (tool_start_index == null) {
                tool_start_index = index;
            },
            .tool_execution_end => if (tool_end_index == null) {
                tool_end_index = index;
            },
            .turn_end => if (turn_end_index == null) {
                turn_end_index = index;
            },
            else => {},
        }
    }

    try std.testing.expect(assistant_start_index != null);
    try std.testing.expect(assistant_end_index != null);
    try std.testing.expect(tool_start_index != null);
    try std.testing.expect(tool_end_index != null);
    try std.testing.expect(tool_result_start_index != null);
    try std.testing.expect(tool_result_end_index != null);
    try std.testing.expect(turn_end_index != null);
    for (capture.events.items[assistant_start_index.? + 1 .. assistant_end_index.?]) |event| {
        switch (event.event_type) {
            .tool_execution_start, .tool_execution_update, .tool_execution_end => return error.ImmediateToolOutcomeInterleavedInAssistantWindow,
            .message_start, .message_end => if (toolResultOfEvent(event)) |_| return error.ImmediateToolResultInterleavedInAssistantWindow,
            else => {},
        }
    }
    try std.testing.expect(assistant_end_index.? < tool_start_index.?);
    try std.testing.expect(tool_start_index.? < tool_end_index.?);
    try std.testing.expect(tool_end_index.? < tool_result_start_index.?);
    try std.testing.expect(tool_result_start_index.? < tool_result_end_index.?);
    try std.testing.expect(tool_result_end_index.? < turn_end_index.?);
    try std.testing.expectEqual(@as(usize, 1), capture.turn_tool_result_ids.items.len);
    try std.testing.expectEqualStrings("missing-tool", capture.turn_tool_result_ids.items[0]);
}

test "ISS-405 parallel tool completions keep transcript and turn_end source ordered" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_args, .{ .id = "tool-1" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", second_args, .{ .id = "tool-2" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    var ordering = ParallelHookOrderingCapture.init(std.testing.allocator);
    defer ordering.deinit();
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = &ordering,
        .execute = hookOrderingToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.testing.io,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expect(ordering.second_observed_before_first_finished.load(.seq_cst));
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-2", result[3].tool_result.tool_call_id);

    var assistant_start_index: ?usize = null;
    var assistant_end_index: ?usize = null;
    var first_tool_start_index: ?usize = null;
    var tool_end_ids = std.ArrayList([]const u8).empty;
    defer tool_end_ids.deinit(std.testing.allocator);
    var tool_result_message_ids = std.ArrayList([]const u8).empty;
    defer tool_result_message_ids.deinit(std.testing.allocator);
    var first_turn_end_index: ?usize = null;

    for (capture.events.items, 0..) |event, index| {
        switch (event.event_type) {
            .message_start => if (assistantOfEvent(event)) |assistant| {
                if (assistant.stop_reason == .tool_use and assistant_start_index == null) assistant_start_index = index;
            },
            .message_end => {
                if (assistantOfEvent(event)) |assistant| {
                    if (assistant.stop_reason == .tool_use and assistant_end_index == null) assistant_end_index = index;
                }
                if (toolResultOfEvent(event)) |tool_result| {
                    try tool_result_message_ids.append(std.testing.allocator, tool_result.tool_call_id);
                }
            },
            .tool_execution_start => if (first_tool_start_index == null) {
                first_tool_start_index = index;
            },
            .tool_execution_end => try tool_end_ids.append(std.testing.allocator, event.tool_call_id orelse return error.MissingToolCallId),
            .turn_end => if (event.tool_results) |tool_results| {
                if (tool_results.len > 0 and first_turn_end_index == null) first_turn_end_index = index;
            },
            else => {},
        }
    }

    try std.testing.expect(assistant_start_index != null);
    try std.testing.expect(assistant_end_index != null);
    try std.testing.expect(first_tool_start_index != null);
    try std.testing.expect(first_turn_end_index != null);
    for (capture.events.items[assistant_start_index.? + 1 .. assistant_end_index.?]) |event| {
        switch (event.event_type) {
            .tool_execution_start, .tool_execution_update, .tool_execution_end => return error.ParallelToolLifecycleInterleavedInAssistantWindow,
            .message_start, .message_end => if (toolResultOfEvent(event)) |_| return error.ParallelToolResultInterleavedInAssistantWindow,
            else => {},
        }
    }
    try std.testing.expect(assistant_end_index.? < first_tool_start_index.?);
    try std.testing.expectEqual(@as(usize, 2), tool_end_ids.items.len);
    try std.testing.expectEqualStrings("tool-2", tool_end_ids.items[0]);
    try std.testing.expectEqualStrings("tool-1", tool_end_ids.items[1]);
    try std.testing.expectEqual(@as(usize, 2), tool_result_message_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", tool_result_message_ids.items[0]);
    try std.testing.expectEqualStrings("tool-2", tool_result_message_ids.items[1]);

    try std.testing.expectEqual(@as(usize, 2), capture.turn_tool_result_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", capture.turn_tool_result_ids.items[0]);
    try std.testing.expectEqualStrings("tool-2", capture.turn_tool_result_ids.items[1]);
}

test "ISS-408 nested agent loop does not corrupt outer streaming state" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:reentrant-outer",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tool_context = ReentrantToolContext{};
    const tool = types.AgentTool{
        .name = "bash",
        .description = "Runs a nested agent loop",
        .label = "Nested",
        .parameters = .null,
        .execute_context = &tool_context,
        .execute = reentrantToolExecute,
    };
    var stream_context = test_streams.ReentrantOuterStreamContext{};

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = model,
            .convert_to_llm = defaultConvertToLlmForTest,
            .stream_context = &stream_context,
            .tool_execution = .sequential,
        },
        null,
        ignoreEvent,
        null,
        test_streams.reentrantOuterStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("nested: streamed response", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("streamed response", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 2), stream_context.call_count);
    try std.testing.expect(tool_context.nested_event_count > 0);
}

test "runAgentLoop sends fallback tool arguments through normal validation" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty_args = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 1);
    blocks[0] = try faux.fauxToolCall(
        arena.allocator(),
        "echo",
        .{ .object = empty_args },
        .{ .id = "tool-1" },
    );
    const response = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
    const done_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = response },
        .{ .message = faux.fauxAssistantMessage(done_blocks[0..], .{}) },
    });

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .prepare_arguments = requireValuePrepareArguments,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("echo", result[2].tool_result.tool_name);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("done", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
}

test "streamAssistantResponse frees owned streaming deltas after consumption" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:owned-delta",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_streams.ownedDeltaStreamForAgentLoopTest,
    );
    defer pi_types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expectEqualStrings("streamed response", assistant.content[0].text.text);
}

test "route-a m1 streamAssistantResponse emits toolcall message updates" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:toolcall-stream",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_streams.toolCallStreamForAgentLoopTest,
    );
    defer pi_types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expectEqual(@as(usize, 1), assistant.tool_calls.?.len);
    try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
    try std.testing.expect(assistant.content[0] == .tool_call);
    try std.testing.expectEqualStrings("tool-1", assistant.content[0].tool_call.id);
    const expected = [_]pi_types.EventType{ .toolcall_start, .toolcall_delta, .toolcall_end };
    var next_expected: usize = 0;
    for (capture.events.items) |event| {
        if (event.event_type != .message_update) continue;
        const assistant_event = event.assistant_message_event orelse continue;
        if (assistant_event.event_type == .toolcall_start or
            assistant_event.event_type == .toolcall_delta or
            assistant_event.event_type == .toolcall_end)
        {
            try std.testing.expect(next_expected < expected.len);
            try std.testing.expectEqual(expected[next_expected], assistant_event.event_type);
            next_expected += 1;
        }
    }
    try std.testing.expectEqual(expected.len, next_expected);
}

test "VAL-CROSS-004 streamAssistantResponse accumulates ordered partial content while tool JSON repairs" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:cross-partials",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = PartialUpdateCrossCapture{};
    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        capturePartialUpdateCrossEvent,
        null,
        test_streams.crossPartialUpdateStreamForAgentLoopTest,
    );
    defer pi_types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expect(capture.saw_thinking_delta);
    try std.testing.expect(capture.saw_thinking_end);
    try std.testing.expect(capture.saw_text_delta);
    try std.testing.expect(capture.saw_toolcall_delta);
    try std.testing.expect(capture.saw_toolcall_end);
    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
    try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
}

test "VAL-REVIEW-M8-001 streaming message_update snapshots cover partial tool-call UX policy" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:partial-tool-ux-snapshots",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = StreamingUpdateSnapshotCapture.init(std.testing.allocator);
    defer capture.deinit();

    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        captureStreamingUpdateSnapshotEvent,
        null,
        test_streams.crossPartialUpdateStreamForAgentLoopTest,
    );
    defer pi_types.freeAssistantMessage(std.testing.allocator, assistant);

    const expected = [_][]const u8{
        "event=thinking_start|index=0|message=[thinking:]",
        "event=thinking_delta|index=0|delta=plan |message=[thinking:plan ]",
        "event=thinking_delta|index=0|delta=first|message=[thinking:plan first]",
        "event=thinking_end|index=0|content=plan first|message=[thinking:plan first]",
        "event=text_start|index=1|message=[thinking:plan first,text:]",
        "event=text_delta|index=1|delta=prior |message=[thinking:plan first,text:prior ]",
        "event=text_delta|index=1|delta=text|message=[thinking:plan first,text:prior text]",
        "event=text_end|index=1|content=prior text|message=[thinking:plan first,text:prior text]",
        "event=toolcall_start|index=2|message=[thinking:plan first,text:prior text,toolCall:id=,name=,args={}]",
        "event=toolcall_delta|index=2|delta={\"query\":\"par|message=[thinking:plan first,text:prior text,toolCall:id=,name=,args={\"query\":\"par\"}]",
        "event=toolcall_end|index=2|eventToolCall=id=call_1,name=lookup,args={\"query\":\"partial\"}|message=[thinking:plan first,text:prior text,toolCall:id=call_1,name=lookup,args={\"query\":\"partial\"}]",
    };

    try std.testing.expectEqual(expected.len, capture.snapshots.items.len);
    for (expected, capture.snapshots.items) |expected_snapshot, actual_snapshot| {
        try std.testing.expectEqualStrings(expected_snapshot, actual_snapshot);
    }

    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
}

test "VAL-CROSS-004 partial tool-call malformed arguments fall back to empty object" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:malformed-partial-args",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = MalformedPartialArgsCapture{};
    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        captureMalformedPartialArgsEvent,
        null,
        test_streams.malformedPartialToolCallStreamForAgentLoopTest,
    );
    defer pi_types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expect(capture.saw_malformed_toolcall_delta);
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expectEqualStrings("call_bad_args", assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), assistant.content[1].tool_call.arguments.object.count());
}

test "ISS-401 aborted stream cleans partial accumulator tool state" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:partial-abort-cleanup",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var aborted = std.atomic.Value(bool).init(false);
    var capture = MessageUpdateCountCapture{};
    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        countMessageUpdateEvent,
        &aborted,
        test_streams.abortedPartialToolCallStreamForAgentLoopTest,
    );

    try std.testing.expect(aborted.load(.seq_cst));
    try std.testing.expectEqual(pi_types.StopReason.aborted, assistant.stop_reason);
    try std.testing.expectEqualStrings("Request was aborted", assistant.error_message.?);
    try std.testing.expectEqual(@as(usize, 5), capture.message_update_count);
    try std.testing.expectEqual(@as(usize, 1), capture.message_end_count);
}

test "ISS-401 runtime error stream cleans partial tool state and skips terminal tool calls" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:partial-runtime-error-cleanup",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = model,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_streams.runtimeErrorToolCallStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(pi_types.StopReason.error_reason, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("ProviderParseFailure", result[1].assistant.error_message.?);
    try std.testing.expectEqualStrings("partial before runtime error", result[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("runtime-error-terminal", result[1].assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);

    var terminal_assistant_messages: usize = 0;
    var turn_end_count: usize = 0;
    var agent_end_count: usize = 0;
    for (capture.events.items) |event| {
        try std.testing.expect(event.event_type != .tool_execution_start);
        try std.testing.expect(event.event_type != .tool_execution_end);
        switch (event.event_type) {
            .message_end => if (assistantOfEvent(event)) |assistant| {
                if (assistant.stop_reason == .error_reason) terminal_assistant_messages += 1;
            },
            .turn_end => turn_end_count += 1,
            .agent_end => agent_end_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), terminal_assistant_messages);
    try std.testing.expectEqual(@as(usize, 1), turn_end_count);
    try std.testing.expectEqual(@as(usize, 1), agent_end_count);
}

test "ISS-403 cloneToolCall retainers deinit replacement and cloned content" {
    const allocator = std.testing.allocator;

    var partial_tool_call = accumulator.PartialToolCallBlock{};
    try partial_tool_call.setFinal(allocator, .{
        .id = "first-tool",
        .name = "lookup",
        .arguments = .{ .string = "first args" },
        .thought_signature = "first signature",
    });
    try std.testing.expectEqualStrings("first-tool", partial_tool_call.final_tool_call.?.id);

    try partial_tool_call.setFinal(allocator, .{
        .id = "second-tool",
        .name = "lookup",
        .arguments = .{ .string = "second args" },
        .thought_signature = "second signature",
    });
    try std.testing.expectEqualStrings("second-tool", partial_tool_call.final_tool_call.?.id);
    try std.testing.expectEqualStrings("second args", partial_tool_call.final_tool_call.?.arguments.string);
    partial_tool_call.deinit(allocator);

    const source = [_]pi_types.ContentBlock{.{ .tool_call = .{
        .id = "content-tool",
        .name = "lookup",
        .arguments = .{ .string = "content args" },
        .thought_signature = "content signature",
    } }};

    const cloned = try content_clone.cloneContentBlocks(allocator, source[0..]);
    defer {
        content_clone.deinitContentBlocks(allocator, cloned);
        allocator.free(cloned);
    }

    try std.testing.expectEqual(@as(usize, 1), cloned.len);
    try std.testing.expect(cloned[0] == .tool_call);
    try std.testing.expectEqualStrings("content-tool", cloned[0].tool_call.id);
    try std.testing.expectEqualStrings("lookup", cloned[0].tool_call.name);
    try std.testing.expectEqualStrings("content args", cloned[0].tool_call.arguments.string);
    try std.testing.expectEqualStrings("content signature", cloned[0].tool_call.thought_signature.?);
    try std.testing.expect(cloned[0].tool_call.id.ptr != source[0].tool_call.id.ptr);
    try std.testing.expect(cloned[0].tool_call.name.ptr != source[0].tool_call.name.ptr);
    try std.testing.expect(cloned[0].tool_call.arguments.string.ptr != source[0].tool_call.arguments.string.ptr);
    try std.testing.expect(cloned[0].tool_call.thought_signature.?.ptr != source[0].tool_call.thought_signature.?.ptr);
}

fn checkCloneToolCallAllocation(allocator: std.mem.Allocator, source: pi_types.ToolCall) !void {
    const cloned = try content_clone.cloneToolCall(allocator, source);
    defer content_clone.deinitToolCall(allocator, cloned);
}

fn checkCloneContentBlocksAllocation(allocator: std.mem.Allocator, source: []const pi_types.ContentBlock) !void {
    const cloned = try content_clone.cloneContentBlocks(allocator, source);
    defer {
        content_clone.deinitContentBlocks(allocator, cloned);
        allocator.free(cloned);
    }
}

test "ISS-403 accumulator.PartialToolCallBlock keeps existing final tool call on replacement allocation failure" {
    const allocator = std.testing.allocator;

    var partial_tool_call = accumulator.PartialToolCallBlock{};
    defer partial_tool_call.deinit(allocator);

    try partial_tool_call.setFinal(allocator, .{
        .id = "stable-tool",
        .name = "lookup",
        .arguments = .{ .string = "stable args" },
        .thought_signature = "stable signature",
    });

    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();

        try std.testing.expectError(
            error.OutOfMemory,
            partial_tool_call.setFinal(failing_allocator, .{
                .id = "replacement-tool",
                .name = "lookup",
                .arguments = .{ .string = "replacement args" },
                .thought_signature = "replacement signature",
            }),
        );

        try std.testing.expectEqualStrings("stable-tool", partial_tool_call.final_tool_call.?.id);
        try std.testing.expectEqualStrings("lookup", partial_tool_call.final_tool_call.?.name);
        try std.testing.expectEqualStrings("stable args", partial_tool_call.final_tool_call.?.arguments.string);
        try std.testing.expectEqualStrings("stable signature", partial_tool_call.final_tool_call.?.thought_signature.?);
    }
}

test "ISS-403 cloneToolCall allocation failures clean partial clones" {
    const allocator = std.testing.allocator;

    const source_args = try jsonStringObject(allocator, "query", "owned source");
    defer provider_json.freeValue(allocator, source_args);

    const source = pi_types.ToolCall{
        .id = "tool-with-owned-args",
        .name = "lookup",
        .arguments = source_args,
        .thought_signature = "signature",
    };
    try std.testing.checkAllAllocationFailures(allocator, checkCloneToolCallAllocation, .{source});

    var array_args = std.json.Array.init(allocator);
    defer array_args.deinit();
    try array_args.append(.{ .string = "array argument" });
    try array_args.append(.{ .number_string = "123" });

    const array_source = pi_types.ToolCall{
        .id = "tool-with-array-args",
        .name = "lookup",
        .arguments = .{ .array = array_args },
        .thought_signature = "signature",
    };
    try std.testing.checkAllAllocationFailures(allocator, checkCloneToolCallAllocation, .{array_source});
}

test "ISS-403 cloneContentBlocks allocation failures unwind owned blocks once" {
    const allocator = std.testing.allocator;

    const tool_args = try jsonStringObject(allocator, "query", "content tool args");
    defer provider_json.freeValue(allocator, tool_args);

    const source = [_]pi_types.ContentBlock{
        .{ .text = .{
            .text = "text body",
            .text_signature = "text signature",
        } },
        .{ .image = .{
            .data = "base64-image",
            .mime_type = "image/png",
        } },
        .{ .thinking = .{
            .thinking = "thinking body",
            .thinking_signature = "thinking signature",
            .redacted = false,
        } },
        .{ .tool_call = .{
            .id = "content-tool",
            .name = "lookup",
            .arguments = tool_args,
            .thought_signature = "tool signature",
        } },
    };

    try std.testing.checkAllAllocationFailures(allocator, checkCloneContentBlocksAllocation, .{source[0..]});
}

test "ISS-406 partial accumulator rejects stale explicit content_index reuse after end" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "draft",
    });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_end,
        .content_index = 0,
        .content = "final text",
    });

    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{
            .event_type = .text_delta,
            .content_index = 0,
            .delta = " stale delta",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 }),
    );

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:partial-index-reuse",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 1), partial_message.content.len);
    try std.testing.expect(partial_message.content[0] == .text);
    try std.testing.expectEqualStrings("final text", partial_message.content[0].text.text);
}

test "ISS-400 partial accumulator rejects explicit deltas before start" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .text_delta,
            .content_index = 0,
            .delta = "orphan text",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .thinking_delta,
            .content_index = 1,
            .delta = "orphan thinking",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .toolcall_delta,
            .content_index = 2,
            .delta = "{\"value\":\"orphan\"}",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .text_end,
            .content_index = 0,
            .content = "orphan text",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .thinking_end,
            .content_index = 1,
            .content = "orphan thinking",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .toolcall_end, .content_index = 2 }),
    );

    // Sparse starts remain valid: the policy rejects non-start events for an
    // unmapped explicit provider index, not sparse provider content indices.
    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 3 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_delta,
        .content_index = 3,
        .delta = "mapped text",
    });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_end,
        .content_index = 3,
        .content = "mapped text",
    });

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:partial-out-of-order",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 1), partial_message.content.len);
    try std.testing.expectEqualStrings("mapped text", partial_message.content[0].text.text);
}

test "ISS-400 sparse explicit starts preserve start order without placeholders" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 8 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_end,
        .content_index = 8,
        .content = "first sparse text",
    });
    try partial_accumulator.applyEvent(.{ .event_type = .thinking_start, .content_index = 2 });
    try partial_accumulator.applyEvent(.{
        .event_type = .thinking_end,
        .content_index = 2,
        .content = "second sparse thinking",
    });

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:partial-sparse-order",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 2), partial_message.content.len);
    try std.testing.expect(partial_message.content[0] == .text);
    try std.testing.expectEqualStrings("first sparse text", partial_message.content[0].text.text);
    try std.testing.expect(partial_message.content[1] == .thinking);
    try std.testing.expectEqualStrings("second sparse thinking", partial_message.content[1].thinking.thinking);
}

test "ISS-400 explicit content indexes reject kind mismatches without dropping partial content" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{ .event_type = .text_delta, .content_index = 0, .delta = "kept text" });
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .thinking_delta, .content_index = 0, .delta = "wrong kind" }),
    );

    try partial_accumulator.applyEvent(.{ .event_type = .thinking_start, .content_index = 5 });
    try partial_accumulator.applyEvent(.{ .event_type = .thinking_delta, .content_index = 5, .delta = "kept thinking" });
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .toolcall_end, .content_index = 5 }),
    );

    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_start, .content_index = 9 });
    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_delta, .content_index = 9, .delta = "{\"query\":\"kept\"}" });
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .text_delta, .content_index = 9, .delta = "wrong kind" }),
    );

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:partial-kind-mismatch",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 3), partial_message.content.len);
    try std.testing.expectEqualStrings("kept text", partial_message.content[0].text.text);
    try std.testing.expectEqualStrings("kept thinking", partial_message.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("kept", partial_message.content[2].tool_call.arguments.object.get("query").?.string);
}

test "ISS-400 duplicate explicit starts are rejected without resetting partial content" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{ .event_type = .text_delta, .content_index = 0, .delta = "text survives" });
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 }),
    );

    try partial_accumulator.applyEvent(.{ .event_type = .thinking_start, .content_index = 2 });
    try partial_accumulator.applyEvent(.{ .event_type = .thinking_delta, .content_index = 2, .delta = "thinking survives" });
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .thinking_start, .content_index = 2 }),
    );

    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_start, .content_index = 4 });
    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_delta, .content_index = 4, .delta = "{\"query\":\"survives\"}" });
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{ .event_type = .toolcall_start, .content_index = 4 }),
    );

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:partial-duplicate-start",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 3), partial_message.content.len);
    try std.testing.expectEqualStrings("text survives", partial_message.content[0].text.text);
    try std.testing.expectEqualStrings("thinking survives", partial_message.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("survives", partial_message.content[2].tool_call.arguments.object.get("query").?.string);
}

test "ISS-400 ended explicit indexes cannot be reused and finalized content remains intact" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_end,
        .content_index = 0,
        .content = "final text",
    });
    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{ .event_type = .text_delta, .content_index = 0, .delta = "late text" }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{ .event_type = .thinking_start, .content_index = 0 }),
    );

    try partial_accumulator.applyEvent(.{ .event_type = .thinking_start, .content_index = 4 });
    try partial_accumulator.applyEvent(.{
        .event_type = .thinking_end,
        .content_index = 4,
        .content = "final thinking",
    });
    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{ .event_type = .thinking_delta, .content_index = 4, .delta = "late thinking" }),
    );

    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_start, .content_index = 7 });
    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_delta, .content_index = 7, .delta = "{\"query\":\"final\"}" });
    try partial_accumulator.applyEvent(.{ .event_type = .toolcall_end, .content_index = 7 });
    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{ .event_type = .toolcall_start, .content_index = 7 }),
    );

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:partial-ended-reuse",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 3), partial_message.content.len);
    try std.testing.expectEqualStrings("final text", partial_message.content[0].text.text);
    try std.testing.expectEqualStrings("final thinking", partial_message.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("final", partial_message.content[2].tool_call.arguments.object.get("query").?.string);
}

test "ISS-400 stream rejection cleans partial accumulator state without terminal emissions" {
    const model = pi_types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    const config = types.AgentLoopConfig{
        .model = model,
        .convert_to_llm = passthroughConvertToLlmForTest,
    };
    const context = types.AgentContext{
        .system_prompt = "",
        .messages = &[_]types.AgentMessage{},
        .tools = &.{},
    };
    var capture = MessageUpdateCountCapture{};

    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        streaming.streamAssistantResponse(
            std.testing.allocator,
            std.Io.failing,
            context,
            config,
            &capture,
            countMessageUpdateEvent,
            null,
            test_streams.iss400OutOfOrderStreamForAgentLoopTest,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), capture.message_update_count);
    try std.testing.expectEqual(@as(usize, 0), capture.message_end_count);
}

test "VAL-REVIEW-M7-001 finalized tool call rejects double finalization" {
    const args = try jsonStringObject(std.testing.allocator, "value", "once");
    var prepared = tool_execution.PreparedToolCall{
        .tool_call = .{
            .id = "tool-double-finalize",
            .name = "echo",
            .arguments = .null,
        },
        .tool = .{
            .name = "echo",
            .description = "Echo input",
            .label = "Echo",
            .parameters = .null,
        },
        .args = args,
    };
    defer prepared.deinit(std.testing.allocator);

    const content = try std.testing.allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "already executed") } };
    const executed = tool_execution.ExecutedToolCallOutcome{
        .result = .{
            .content = content,
            .details = null,
        },
        .is_error = false,
    };
    defer {
        std.testing.allocator.free(content[0].text.text);
        std.testing.allocator.free(content);
    }

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const assistant_message = pi_types.AssistantMessage{
        .content = &.{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const context = types.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &.{prepared.tool},
    };
    const config = types.AgentLoopConfig{
        .model = .{
            .id = "faux-model",
            .name = "Faux Model",
            .api = "faux",
            .provider = "faux",
            .base_url = "http://localhost",
            .input_types = &[_][]const u8{"text"},
            .context_window = 1024,
            .max_tokens = 256,
        },
        .convert_to_llm = defaultConvertToLlmForTest,
    };

    const finalized = try tool_execution.finalizeExecutedToolCall(
        std.testing.allocator,
        context,
        assistant_message,
        &prepared,
        executed,
        false,
        config,
        &capture,
        captureToolEvent,
        null,
    );
    try std.testing.expectEqualStrings("already executed", finalized.result.content[0].text.text);
    try std.testing.expect(!finalized.is_error);
    try std.testing.expect(prepared.finalized);

    try std.testing.expectError(
        AgentLoopError.ToolCallAlreadyFinalized,
        tool_execution.finalizeExecutedToolCall(
            std.testing.allocator,
            context,
            assistant_message,
            &prepared,
            executed,
            false,
            config,
            &capture,
            captureToolEvent,
            null,
        ),
    );

    var end_count: usize = 0;
    for (capture.events.items) |event| {
        if (event.event_type == .tool_execution_end) {
            end_count += 1;
            try std.testing.expectEqualStrings("tool-double-finalize", event.tool_call_id.?);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), end_count);
}

test "ISS-401 ISS-407 message_update payload is callback-scoped and retained consumers clone" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "borrowed update",
    });

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = "recording:test:update-lifetime",
        .provider = "recording",
        .model = "recording-model",
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var temp_buffer: [4096]u8 = undefined;
    var temp_allocator = std.heap.FixedBufferAllocator.init(&temp_buffer);
    const partial_message = try partial_accumulator.buildMessage(temp_allocator.allocator(), template);

    try std.testing.expectEqual(@as(usize, 1), partial_message.content.len);
    try std.testing.expect(partial_message.content[0] == .text);
    try std.testing.expectEqualStrings("borrowed update", partial_message.content[0].text.text);

    const temp_start = @intFromPtr(&temp_buffer[0]);
    const temp_end = temp_start + temp_buffer.len;
    const content_ptr = @intFromPtr(partial_message.content.ptr);
    try std.testing.expect(content_ptr >= temp_start);
    try std.testing.expect(content_ptr < temp_end);

    const borrowed_text_ptr = partial_message.content[0].text.text.ptr;
    const retained_content = try content_clone.cloneContentBlocks(std.testing.allocator, partial_message.content);
    defer {
        content_clone.deinitContentBlocks(std.testing.allocator, retained_content);
        std.testing.allocator.free(retained_content);
    }

    try std.testing.expect(retained_content.ptr != partial_message.content.ptr);
    try std.testing.expect(retained_content[0] == .text);
    try std.testing.expect(retained_content[0].text.text.ptr != borrowed_text_ptr);

    @memset(temp_buffer[0..], 0xa5);

    try std.testing.expectEqualStrings("borrowed update", retained_content[0].text.text);
}

test "ISS-401 VAL-CROSS-002 terminal error with partial tool call suppresses tool execution" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = try jsonStringObject(arena.allocator(), "value", "should-not-run");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = faux.fauxText("partial before error");
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", args, .{ .id = "tool-error-1" });
    const response = faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .error_reason,
        .error_message = "provider failed after tool call",
        .response_id = "resp_error_partial",
    });
    try registration.setResponses(&[_]faux.FauxResponseStep{.{ .message = response }});

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(pi_types.StopReason.error_reason, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("resp_error_partial", result[1].assistant.response_id.?);
    try std.testing.expectEqualStrings("partial before error", result[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("tool-error-1", result[1].assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);

    for (capture.events.items) |event| {
        try std.testing.expect(event.event_type != .tool_execution_start);
        try std.testing.expect(event.event_type != .tool_execution_end);
    }
}

test "ISS-401 VAL-CROSS-002 terminal abort with partial tool call suppresses tool execution" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = try jsonStringObject(arena.allocator(), "value", "should-not-run");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = faux.fauxText("partial before abort");
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", args, .{ .id = "tool-abort-1" });
    const response = faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .response_id = "resp_abort_partial",
    });
    try registration.setResponses(&[_]faux.FauxResponseStep{.{ .message = response }});

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(pi_types.StopReason.aborted, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("resp_abort_partial", result[1].assistant.response_id.?);
    try std.testing.expectEqualStrings("partial before abort", result[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("tool-abort-1", result[1].assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
}

test "VAL-CROSS-003 interleaved repaired and fallback tool calls execute exactly once" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var first_object = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    try first_object.put(
        arena.allocator(),
        try arena.allocator().dupe(u8, "value"),
        .{ .string = try arena.allocator().dupe(u8, "first") },
    );
    const first_parsed = struct {
        value: std.json.Value,
    }{ .value = .{ .object = first_object } };
    const fallback_args = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_parsed.value, .{ .id = "tool-repaired" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "optional", .{ .object = fallback_args }, .{ .id = "tool-fallback" });
    const first_response = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
    const done_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    const second_response = faux.fauxAssistantMessage(done_blocks[0..], .{});
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = first_response },
        .{ .message = second_response },
    });

    const echo_fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(echo_fixture);
    echo_fixture.* = .{};
    const optional_fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(optional_fixture);
    optional_fixture.* = .{};

    const tools = [_]types.AgentTool{
        .{
            .name = "echo",
            .description = "Echo input",
            .label = "Echo",
            .parameters = .null,
            .execute_context = echo_fixture,
            .execute = countedEchoToolExecute,
        },
        .{
            .name = "optional",
            .description = "Accept fallback args",
            .label = "Optional",
            .parameters = .null,
            .execute_context = optional_fixture,
            .execute = countedEchoToolExecute,
        },
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = tools[0..],
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .tool_execution = .sequential,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("tool-repaired", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-fallback", result[3].tool_result.tool_call_id);
    try std.testing.expectEqual(@as(usize, 1), echo_fixture.execute_count);
    try std.testing.expectEqual(@as(usize, 1), optional_fixture.execute_count);
}

test "runAgentLoop executes multiple tool calls in parallel and emits tool results in source order" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_args, .{ .id = "tool-1" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", second_args, .{ .id = "tool-2" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const observation = try std.testing.allocator.create(ParallelObservation);
    defer std.testing.allocator.destroy(observation);
    observation.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = observation,
        .execute = parallelAwareEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expect(observation.parallel_observed.load(.seq_cst));
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-2", result[3].tool_result.tool_call_id);

    var first_end_index: ?usize = null;
    var start_count: usize = 0;
    for (capture.events.items, 0..) |event, index| {
        if (event.event_type == .tool_execution_start) start_count += 1;
        if (event.event_type == .tool_execution_end and first_end_index == null) {
            first_end_index = index;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), start_count);
    try std.testing.expect(first_end_index != null);
    for (capture.events.items[0..first_end_index.?]) |event| {
        if (event.event_type == .tool_execution_end) {
            return error.UnexpectedToolExecutionEndOrder;
        }
    }
}

test "ISS-404 parallel after_tool_call finalizes in completion order and emits messages in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const tool_calls = try arena.allocator().alloc(pi_types.ToolCall, 2);
    tool_calls[0] = .{ .id = "tool-1", .name = "echo", .arguments = first_args };
    tool_calls[1] = .{ .id = "tool-2", .name = "echo", .arguments = second_args };

    var capture = ParallelHookOrderingCapture.init(std.testing.allocator);
    defer capture.deinit();

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = &capture,
        .execute = hookOrderingToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = pi_types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .after_tool_call = recordAfterToolCallOrder,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureParallelHookOrderingEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expect(capture.second_observed_before_first_finished.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), capture.after_hook_order.items.len);
    try std.testing.expectEqualStrings("tool-2", capture.after_hook_order.items[0]);
    try std.testing.expectEqualStrings("tool-1", capture.after_hook_order.items[1]);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_end_order.items.len);
    try std.testing.expectEqualStrings("tool-2", capture.tool_end_order.items[0]);
    try std.testing.expectEqualStrings("tool-1", capture.tool_end_order.items[1]);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_message_order.items.len);
    try std.testing.expectEqualStrings("tool-1", capture.tool_message_order.items[0]);
    try std.testing.expectEqualStrings("tool-2", capture.tool_message_order.items[1]);
    try std.testing.expectEqualStrings("tool-1", results[0].tool_call_id);
    try std.testing.expectEqualStrings("tool-2", results[1].tool_call_id);
}

test "ISS-401 executeToolCallsParallel returns tool result content that survives task arena cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tool_args = try jsonStringObject(arena.allocator(), "value", "hello");
    const tool_calls = try arena.allocator().alloc(pi_types.ToolCall, 1);
    tool_calls[0] = .{
        .id = "tool-1",
        .name = "echo",
        .arguments = tool_args,
    };

    const fixture = try std.testing.allocator.create(ToolResultContentCaptureFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = capturingEchoToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = pi_types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(fixture.capture.content_ptr != null);
    try std.testing.expect(fixture.capture.text_ptr != null);

    const scratch_blocks = try std.testing.allocator.alloc(pi_types.ContentBlock, 1);
    defer std.testing.allocator.free(scratch_blocks);
    const scratch_text = try std.testing.allocator.alloc(u8, fixture.capture.text_len);
    defer std.testing.allocator.free(scratch_text);
    @memset(scratch_text, 'x');
    scratch_blocks[0] = .{
        .text = .{
            .text = scratch_text,
        },
    };

    try std.testing.expect(results[0].content.ptr != fixture.capture.content_ptr.?);
    try std.testing.expect(results[0].content[0].text.text.ptr != fixture.capture.text_ptr.?);
    try std.testing.expectEqualStrings("echoed: hello", results[0].content[0].text.text);
}

test "route-a m1 parallel tool updates emit before join and only updates leave main thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fast_args = try jsonStringObject(arena.allocator(), "value", "fast");
    const slow_args = try jsonStringObject(arena.allocator(), "value", "slow");
    const tool_calls = try arena.allocator().alloc(pi_types.ToolCall, 2);
    tool_calls[0] = .{ .id = "fast", .name = "stream", .arguments = fast_args };
    tool_calls[1] = .{ .id = "slow", .name = "stream", .arguments = slow_args };

    var capture = ParallelStreamingCapture{ .main_thread_id = std.Thread.getCurrentId() };
    const tool = types.AgentTool{
        .name = "stream",
        .description = "Streaming test tool",
        .label = "Stream",
        .parameters = .null,
        .execute_context = &capture,
        .execute = streamingParallelToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = pi_types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureParallelStreamingEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(capture.saw_fast_update_before_slow_done.load(.seq_cst));
    try std.testing.expect(capture.saw_update_off_main_thread.load(.seq_cst));
    try std.testing.expect(!capture.invalid_main_thread_event.load(.seq_cst));
}

test "route-a m1 parallel emitter serializes concurrent update callbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tool_calls = try arena.allocator().alloc(pi_types.ToolCall, 4);
    for (tool_calls, 0..) |*tool_call, index| {
        tool_call.* = .{
            .id = try std.fmt.allocPrint(arena.allocator(), "tool-{d}", .{index}),
            .name = "stress",
            .arguments = .null,
        };
    }

    var capture = ParallelStreamingCapture{ .main_thread_id = std.Thread.getCurrentId() };
    const tool = types.AgentTool{
        .name = "stress",
        .description = "Stress streaming test tool",
        .label = "Stress",
        .parameters = .null,
        .execute_context = &capture,
        .execute = stressStreamingParallelToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = pi_types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureParallelStreamingEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqual(@as(usize, 400), capture.update_count.load(.seq_cst));
    try std.testing.expect(!capture.concurrent_callback_entry.load(.seq_cst));
}

test "runAgentLoop executes tool calls sequentially when configured" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_args, .{ .id = "tool-1" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", second_args, .{ .id = "tool-2" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const observation = try std.testing.allocator.create(ParallelObservation);
    defer std.testing.allocator.destroy(observation);
    observation.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = observation,
        .execute = parallelAwareEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    _ = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .sequential,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expect(!observation.parallel_observed.load(.seq_cst));
}

test "runAgentLoop emits an error tool result and continues the conversation when a tool fails" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("handled failure")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Failing tool",
        .label = "Echo",
        .parameters = .null,
        .execute = failingToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("ToolFailure", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("handled failure", result[3].assistant.content[0].text.text);
}

test "runAgentLoop lets beforeToolCall block execution" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("continued")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .before_tool_call = blockBeforeToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("blocked by hook", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("continued", result[3].assistant.content[0].text.text);
}

test "ISS-409 before_tool_call error skips execution and emits cleanup result" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("continued after hook error")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .before_tool_call = errorBeforeToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("BeforeToolCallFailed", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("continued after hook error", result[3].assistant.content[0].text.text);

    var tool_start_count: usize = 0;
    var tool_end_count: usize = 0;
    var tool_result_message_count: usize = 0;
    for (capture.events.items) |event| {
        switch (event.event_type) {
            .tool_execution_start => tool_start_count += 1,
            .tool_execution_end => {
                tool_end_count += 1;
                try std.testing.expectEqual(true, event.is_error.?);
                try std.testing.expectEqualStrings("BeforeToolCallFailed", event.result.?.content[0].text.text);
            },
            .message_end => if (toolResultOfEvent(event)) |tool_result| {
                tool_result_message_count += 1;
                try std.testing.expect(tool_result.is_error);
                try std.testing.expectEqualStrings("BeforeToolCallFailed", tool_result.content[0].text.text);
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tool_start_count);
    try std.testing.expectEqual(@as(usize, 1), tool_end_count);
    try std.testing.expectEqual(@as(usize, 1), tool_result_message_count);
}

test "ISS-409 parallel mixed before_tool_call outcomes preserve lifecycle and transcript order" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const blocked_args = try jsonStringObject(arena.allocator(), "value", "block");
    const error_args = try jsonStringObject(arena.allocator(), "value", "error");
    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 4);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_args, .{ .id = "tool-1" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", blocked_args, .{ .id = "tool-blocked" });
    blocks[2] = try faux.fauxToolCall(arena.allocator(), "echo", error_args, .{ .id = "tool-error" });
    blocks[3] = try faux.fauxToolCall(arena.allocator(), "echo", second_args, .{ .id = "tool-2" });

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .factory = iss409MixedContinuationFactory },
    });

    const fixture = try std.testing.allocator.create(HookLifecycleFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = lifecycleEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.testing.io,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .parallel,
            .before_tool_call = mixedBeforeToolCall,
            .after_tool_call = recordHookLifecycleAfterToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqual(@as(usize, 7), result.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.execute_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.after_count.load(.seq_cst));
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-blocked", result[3].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-error", result[4].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-2", result[5].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("continued after mixed hooks", result[6].assistant.content[0].text.text);
    try std.testing.expect(!result[2].tool_result.is_error);
    try std.testing.expect(result[3].tool_result.is_error);
    try std.testing.expect(result[4].tool_result.is_error);
    try std.testing.expect(!result[5].tool_result.is_error);

    var tool_start_count: usize = 0;
    var tool_end_count: usize = 0;
    var last_start_index: ?usize = null;
    var first_end_index: ?usize = null;
    var tool_result_message_ids = std.ArrayList([]const u8).empty;
    defer tool_result_message_ids.deinit(std.testing.allocator);

    for (capture.events.items, 0..) |event, index| {
        switch (event.event_type) {
            .tool_execution_start => {
                tool_start_count += 1;
                last_start_index = index;
            },
            .tool_execution_end => {
                tool_end_count += 1;
                if (first_end_index == null) first_end_index = index;
                if (std.mem.eql(u8, event.tool_call_id.?, "tool-blocked") or
                    std.mem.eql(u8, event.tool_call_id.?, "tool-error"))
                {
                    try std.testing.expectEqual(true, event.is_error.?);
                }
            },
            .message_end => if (toolResultOfEvent(event)) |tool_result| {
                try tool_result_message_ids.append(std.testing.allocator, tool_result.tool_call_id);
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), tool_start_count);
    try std.testing.expectEqual(@as(usize, 4), tool_end_count);
    try std.testing.expect(last_start_index != null);
    try std.testing.expect(first_end_index != null);
    try std.testing.expect(last_start_index.? < first_end_index.?);
    try std.testing.expectEqual(@as(usize, 4), tool_result_message_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", tool_result_message_ids.items[0]);
    try std.testing.expectEqualStrings("tool-blocked", tool_result_message_ids.items[1]);
    try std.testing.expectEqualStrings("tool-error", tool_result_message_ids.items[2]);
    try std.testing.expectEqualStrings("tool-2", tool_result_message_ids.items[3]);
    try std.testing.expectEqual(@as(usize, 4), capture.turn_tool_result_ids.items.len);
    try std.testing.expectEqualStrings("tool-1", capture.turn_tool_result_ids.items[0]);
    try std.testing.expectEqualStrings("tool-blocked", capture.turn_tool_result_ids.items[1]);
    try std.testing.expectEqualStrings("tool-error", capture.turn_tool_result_ids.items[2]);
    try std.testing.expectEqualStrings("tool-2", capture.turn_tool_result_ids.items[3]);
}

test "runAgentLoop lets afterToolCall override the tool result before it enters the transcript" {
    const faux = test_faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute = echoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .after_tool_call = overrideAfterToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        test_faux.stream,
    );

    try std.testing.expectEqualStrings("modified by hook", result[2].tool_result.content[0].text.text);
    try std.testing.expect(!result[2].tool_result.is_error);
}
