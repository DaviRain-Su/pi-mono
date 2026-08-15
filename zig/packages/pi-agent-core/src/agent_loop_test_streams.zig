const std = @import("std");
const pi_types = @import("pi-types");

fn jsonStringObject(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(
        allocator,
        try allocator.dupe(u8, key),
        .{ .string = try allocator.dupe(u8, value) },
    );
    return .{ .object = object };
}

pub fn ownedDeltaStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    const text = try result_allocator.dupe(u8, "streamed response");
    const content = try result_allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "streamed "),
        .owns_delta = true,
    });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "response"),
        .owns_delta = true,
    });
    stream.push(.{ .event_type = .text_end, .content_index = 0 });
    stream.push(.{
        .event_type = .done,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = pi_types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream;
}

pub fn toolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    var args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    try args_object.put(
        result_allocator,
        try result_allocator.dupe(u8, "command"),
        .{ .string = try result_allocator.dupe(u8, "echo hi") },
    );
    const tool_calls = try result_allocator.alloc(pi_types.ToolCall, 1);
    tool_calls[0] = .{
        .id = try result_allocator.dupe(u8, "tool-1"),
        .name = try result_allocator.dupe(u8, "bash"),
        .arguments = .{ .object = args_object },
    };
    var content_args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    try content_args_object.put(
        result_allocator,
        try result_allocator.dupe(u8, "command"),
        .{ .string = try result_allocator.dupe(u8, "echo hi") },
    );
    const content = try result_allocator.alloc(pi_types.ContentBlock, 1);
    content[0] = .{ .tool_call = .{
        .id = try result_allocator.dupe(u8, "tool-1"),
        .name = try result_allocator.dupe(u8, "bash"),
        .arguments = .{ .object = content_args_object },
    } };
    const final_message = pi_types.AssistantMessage{
        .content = content,
        .tool_calls = tool_calls,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start, .message = final_message });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 0 });
    stream.push(.{ .event_type = .toolcall_delta, .content_index = 0, .delta = "{\"command\":\"echo hi\"}" });
    stream.push(.{ .event_type = .toolcall_end, .content_index = 0, .tool_call = tool_calls[0] });
    stream.push(.{ .event_type = .done, .message = final_message });
    return stream;
}

pub fn crossPartialUpdateStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    var content_args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    try content_args_object.put(
        result_allocator,
        try result_allocator.dupe(u8, "query"),
        .{ .string = try result_allocator.dupe(u8, "partial") },
    );
    const content = try result_allocator.alloc(pi_types.ContentBlock, 3);
    content[0] = .{ .thinking = .{ .thinking = try result_allocator.dupe(u8, "plan first") } };
    content[1] = .{ .text = .{ .text = try result_allocator.dupe(u8, "prior text") } };
    content[2] = .{ .tool_call = .{
        .id = try result_allocator.dupe(u8, "call_1"),
        .name = try result_allocator.dupe(u8, "lookup"),
        .arguments = .{ .object = content_args_object },
    } };
    const final_message = pi_types.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .thinking_start, .content_index = 0 });
    stream.push(.{ .event_type = .thinking_delta, .content_index = 0, .delta = "plan " });
    stream.push(.{ .event_type = .thinking_delta, .content_index = 0, .delta = "first" });
    stream.push(.{ .event_type = .thinking_end, .content_index = 0, .content = "plan first" });
    stream.push(.{ .event_type = .text_start, .content_index = 1 });
    stream.push(.{ .event_type = .text_delta, .content_index = 1, .delta = "prior " });
    stream.push(.{ .event_type = .text_delta, .content_index = 1, .delta = "text" });
    stream.push(.{ .event_type = .text_end, .content_index = 1, .content = "prior text" });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 2 });
    stream.push(.{ .event_type = .toolcall_delta, .content_index = 2, .delta = "{\"query\":\"par" });
    stream.push(.{ .event_type = .toolcall_end, .content_index = 2, .tool_call = content[2].tool_call });
    stream.push(.{ .event_type = .done, .message = final_message });
    return stream;
}

pub fn iss400OutOfOrderStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream.deinit();

    // Append directly so this agent-layer regression can exercise defensive
    // accumulator cleanup without the debug EventOrderingGuard panicking first.
    try stream.queue.append(allocator, .{ .event_type = .start, .message = template });
    try stream.queue.append(allocator, .{ .event_type = .text_start, .content_index = 0 });
    try stream.queue.append(allocator, .{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial text",
    });
    try stream.queue.append(allocator, .{
        .event_type = .thinking_delta,
        .content_index = 0,
        .delta = "wrong kind",
    });
    try stream.queue.append(allocator, .{ .event_type = .done, .message = template });
    return stream;
}

pub fn malformedPartialToolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    const content_args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    const content = try result_allocator.alloc(pi_types.ContentBlock, 2);
    content[0] = .{ .text = .{ .text = try result_allocator.dupe(u8, "before tool") } };
    content[1] = .{ .tool_call = .{
        .id = try result_allocator.dupe(u8, "call_bad_args"),
        .name = try result_allocator.dupe(u8, "lookup"),
        .arguments = .{ .object = content_args_object },
    } };
    const final_message = pi_types.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{ .event_type = .text_delta, .content_index = 0, .delta = "before tool" });
    stream.push(.{ .event_type = .text_end, .content_index = 0, .content = "before tool" });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 1 });
    stream.push(.{ .event_type = .toolcall_delta, .content_index = 1, .delta = "not-json" });
    stream.push(.{ .event_type = .toolcall_end, .content_index = 1, .tool_call = content[1].tool_call });
    stream.push(.{ .event_type = .done, .message = final_message });
    return stream;
}

pub fn abortedPartialToolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| @constCast(signal).store(true, .seq_cst);
    }

    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    const final_message = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .timestamp = 2,
    };
    const borrowed_final_tool = pi_types.ToolCall{
        .id = "abort-tool",
        .name = "lookup",
        .arguments = .{ .string = "borrowed final args" },
        .thought_signature = "borrowed signature",
    };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream.deinit();
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial before abort",
    });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 1 });
    stream.push(.{
        .event_type = .toolcall_delta,
        .content_index = 1,
        .delta = "{\"query\":\"owned partial\"}",
    });
    stream.push(.{
        .event_type = .toolcall_end,
        .content_index = 1,
        .tool_call = borrowed_final_tool,
    });
    stream.push(.{
        .event_type = .error_event,
        .message = final_message,
        .error_message = final_message.error_message,
    });
    return stream;
}

pub fn runtimeErrorToolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    _: pi_types.Context,
    _: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const template = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    const partial_tool = pi_types.ToolCall{
        .id = "runtime-error-partial",
        .name = "echo",
        .arguments = .{ .string = "borrowed partial args" },
        .thought_signature = "borrowed runtime signature",
    };

    const terminal_args = try jsonStringObject(allocator, "value", "should-not-run");
    const terminal_tool_calls = try allocator.alloc(pi_types.ToolCall, 1);
    terminal_tool_calls[0] = .{
        .id = try allocator.dupe(u8, "runtime-error-terminal"),
        .name = try allocator.dupe(u8, "echo"),
        .arguments = terminal_args,
    };
    const terminal_content = try allocator.alloc(pi_types.ContentBlock, 2);
    terminal_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "partial before runtime error") } };
    terminal_content[1] = .{ .tool_call = terminal_tool_calls[0] };

    const final_message = pi_types.AssistantMessage{
        .content = terminal_content,
        .tool_calls = terminal_tool_calls,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "ProviderParseFailure",
        .timestamp = 2,
    };

    var stream = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream.deinit();
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial before runtime error",
    });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 1 });
    stream.push(.{
        .event_type = .toolcall_delta,
        .content_index = 1,
        .delta = "{\"value\":\"should-not-run\"}",
    });
    stream.push(.{
        .event_type = .toolcall_end,
        .content_index = 1,
        .tool_call = partial_tool,
    });
    stream.push(.{
        .event_type = .error_event,
        .message = final_message,
        .error_message = final_message.error_message,
    });
    return stream;
}

pub const ReentrantOuterStreamContext = struct {
    call_count: usize = 0,
};

pub fn reentrantOuterStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    context: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    const fixture: *ReentrantOuterStreamContext = @ptrCast(@alignCast(stream_context.?));
    fixture.call_count += 1;
    if (fixture.call_count == 1) {
        return try toolCallStreamForAgentLoopTest(allocator, io, model, context, options, null);
    }
    return try ownedDeltaStreamForAgentLoopTest(allocator, io, model, context, options, null);
}
