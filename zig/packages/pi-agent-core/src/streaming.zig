const std = @import("std");
const pi_types = @import("pi-types");
const provider_json = pi_types.json;
const types = @import("types.zig");
const accumulator = @import("accumulator.zig");
const tool_execution = @import("tool_execution.zig");
const content_clone = @import("content_clone.zig");

fn mapThinkingLevel(level: types.ThinkingLevel) ?pi_types.ThinkingLevel {
    return switch (level) {
        .off => null,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

pub fn streamAssistantResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: types.AgentContext,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
    stream_fn: ?types.StreamFn,
) !pi_types.AssistantMessage {
    const transformed_messages = if (config.transform_context) |transform|
        try transform(allocator, context.messages, signal, config.transform_context_context)
    else
        context.messages;

    const llm_messages = try config.convert_to_llm(allocator, transformed_messages, config.convert_to_llm_context);

    const llm_tools = if (context.tools.len > 0)
        try convertToolsToLlm(allocator, context.tools)
    else
        null;

    const llm_context = pi_types.Context{
        .system_prompt = if (context.system_prompt.len > 0) context.system_prompt else null,
        .messages = llm_messages,
        .tools = llm_tools,
    };
    const options = pi_types.SimpleStreamOptions{
        .api_key = config.api_key,
        .session_id = config.session_id,
        .signal = signal,
        .reasoning = if (config.reasoning) |reasoning| mapThinkingLevel(reasoning) else null,
    };

    try emit(emit_context, .{
        .event_type = .before_provider_request,
        .messages = transformed_messages,
    });
    const active_stream_fn = stream_fn orelse return error.MissingStreamFn;
    var stream = try active_stream_fn(allocator, io, config.model, llm_context, options, config.stream_context);
    defer stream.deinit();
    try emit(emit_context, .{
        .event_type = .after_provider_response,
    });

    var partial_template: ?pi_types.AssistantMessage = null;
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(allocator);
    defer partial_accumulator.deinit();
    var saw_message_start = false;

    while (stream.next()) |event| {
        defer event.deinitTransient(allocator);
        switch (event.event_type) {
            .start => {
                if (event.message) |message| {
                    partial_template = message;
                    saw_message_start = true;
                    try emit(emit_context, .{
                        .event_type = .message_start,
                        .message = .{ .assistant = message },
                    });
                }
            },
            .text_start => {
                if (partial_template) |template| {
                    try partial_accumulator.applyEvent(event);
                    try emitPartialMessageUpdate(
                        allocator,
                        emit_context,
                        emit,
                        template,
                        event,
                        &partial_accumulator,
                    );
                }
            },
            .text_delta => {
                if (partial_template) |template| {
                    try partial_accumulator.applyEvent(event);
                    try emitPartialMessageUpdate(
                        allocator,
                        emit_context,
                        emit,
                        template,
                        event,
                        &partial_accumulator,
                    );
                }
            },
            .text_end => {
                if (partial_template) |template| {
                    try partial_accumulator.applyEvent(event);
                    try emitPartialMessageUpdate(
                        allocator,
                        emit_context,
                        emit,
                        template,
                        event,
                        &partial_accumulator,
                    );
                }
            },
            .thinking_start,
            .thinking_delta,
            .thinking_end,
            .toolcall_start,
            .toolcall_delta,
            .toolcall_end,
            => {
                const template = if (partial_template) |value| value else pi_types.AssistantMessage{
                    .content = &[_]pi_types.ContentBlock{},
                    .api = config.model.api,
                    .provider = config.model.provider,
                    .model = config.model.id,
                    .usage = pi_types.Usage.init(),
                    .stop_reason = .stop,
                    .timestamp = types.nowMilliseconds(),
                };
                try partial_accumulator.applyEvent(event);
                try emitPartialMessageUpdate(
                    allocator,
                    emit_context,
                    emit,
                    template,
                    event,
                    &partial_accumulator,
                );
            },
            .done, .error_event => {
                const final_message = event.message orelse stream.result() orelse return types.AgentLoopError.MissingAssistantResult;
                if (!saw_message_start) {
                    try emit(emit_context, .{
                        .event_type = .message_start,
                        .message = .{ .assistant = final_message },
                    });
                }
                try emit(emit_context, .{
                    .event_type = .message_end,
                    .message = .{ .assistant = final_message },
                });
                return final_message;
            },
        }
    }

    const final_message = stream.result() orelse return types.AgentLoopError.MissingAssistantResult;
    if (!saw_message_start) {
        try emit(emit_context, .{
            .event_type = .message_start,
            .message = .{ .assistant = final_message },
        });
    }
    try emit(emit_context, .{
        .event_type = .message_end,
        .message = .{ .assistant = final_message },
    });
    return final_message;
}

fn emitPartialMessageUpdate(
    allocator: std.mem.Allocator,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    template: pi_types.AssistantMessage,
    assistant_message_event: pi_types.AssistantMessageEvent,
    partial_accumulator: *accumulator.PartialAssistantAccumulator,
) !void {
    if ((assistant_message_event.event_type == .toolcall_start or
        assistant_message_event.event_type == .toolcall_delta or
        assistant_message_event.event_type == .toolcall_end) and
        partial_accumulator.hasOnlyLeadingToolCall())
    {
        var partial_message = template;
        partial_message.content = &[_]pi_types.ContentBlock{};
        partial_message.tool_calls = null;
        try emit(emit_context, .{
            .event_type = .message_update,
            .message = .{ .assistant = partial_message },
            .assistant_message_event = assistant_message_event,
        });
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // `partial_accumulator` owns long-lived partial bytes with the parent
    // allocator, while this arena owns the callback-scoped message shape
    // (`content` slices and temporary parsed JSON). Every pointer in the
    // emitted update is borrowed for this callback only; subscribers that keep
    // any update data must clone it before returning.
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try emit(emit_context, .{
        .event_type = .message_update,
        .message = .{ .assistant = partial_message },
        .assistant_message_event = assistant_message_event,
    });
}

fn convertToolsToLlm(
    allocator: std.mem.Allocator,
    tools: []const types.AgentTool,
) ![]pi_types.Tool {
    const converted = try allocator.alloc(pi_types.Tool, tools.len);
    for (tools, converted) |tool, *slot| {
        slot.* = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = tool.parameters,
        };
    }
    return converted;
}
