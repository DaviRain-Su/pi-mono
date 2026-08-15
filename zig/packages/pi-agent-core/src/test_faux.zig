const std = @import("std");
const pi_types = @import("pi-types");

pub const DEFAULT_API = "faux";
pub const DEFAULT_PROVIDER = "faux";
const DEFAULT_MODEL_ID = "faux-1";
const DEFAULT_MODEL_NAME = "Faux Model";
const DEFAULT_BASE_URL = "http://localhost:0";
const DEFAULT_MIN_TOKEN_SIZE: usize = 3;
const DEFAULT_MAX_TOKEN_SIZE: usize = 5;
const DEFAULT_CONTEXT_WINDOW: u32 = 128000;
const DEFAULT_MAX_TOKENS: u32 = 16384;

pub const FauxTokenSize = struct {
    min: ?u32 = null,
    max: ?u32 = null,
};

pub const FauxContentBlock = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call: pi_types.ToolCall,
};

pub const FauxAssistantMessageOptions = struct {
    stop_reason: pi_types.StopReason = .stop,
    error_message: ?[]const u8 = null,
    response_id: ?[]const u8 = null,
    timestamp: ?i64 = null,
};

pub const FauxAssistantMessage = struct {
    content: []const FauxContentBlock,
    stop_reason: pi_types.StopReason = .stop,
    error_message: ?[]const u8 = null,
    response_id: ?[]const u8 = null,
    timestamp: i64,
};

pub const FauxToolCallOptions = struct {
    id: ?[]const u8 = null,
};

pub const FauxResponseFactory = *const fn (
    allocator: std.mem.Allocator,
    context: pi_types.Context,
    options: ?pi_types.StreamOptions,
    call_count: *usize,
    model: pi_types.Model,
) anyerror!FauxAssistantMessage;

pub const FauxResponseStep = union(enum) {
    message: FauxAssistantMessage,
    factory: FauxResponseFactory,
};

pub const RegisterFauxProviderOptions = struct {
    api: ?[]const u8 = null,
    provider: ?[]const u8 = DEFAULT_PROVIDER,
    token_size: ?FauxTokenSize = null,
};

const FauxProviderState = struct {
    allocator: std.mem.Allocator,
    api: []u8,
    provider: []u8,
    min_token_size: usize,
    max_token_size: usize,
    pending_responses: std.ArrayList(FauxResponseStep),
    call_count: usize,
    models: std.ArrayList(pi_types.Model),

    fn deinit(self: *FauxProviderState) void {
        self.pending_responses.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.allocator.free(self.api);
        self.allocator.free(self.provider);
    }
};

pub const FauxProviderRegistration = struct {
    state: *FauxProviderState,

    pub fn getModel(self: FauxProviderRegistration) pi_types.Model {
        return self.state.models.items[0];
    }

    pub fn setResponses(self: FauxProviderRegistration, responses: []const FauxResponseStep) !void {
        self.state.pending_responses.clearRetainingCapacity();
        for (responses) |response| {
            try self.state.pending_responses.append(self.state.allocator, response);
        }
    }

    pub fn unregister(self: FauxProviderRegistration) void {
        unregisterProvider(self.state.api);
        self.state.deinit();
        self.state.allocator.destroy(self.state);
    }
};

var registry: std.StringHashMap(*FauxProviderState) = undefined;
var registry_initialized = false;
var tool_call_count: usize = 0;

fn ensureRegistry() void {
    if (!registry_initialized) {
        registry = std.StringHashMap(*FauxProviderState).init(std.heap.page_allocator);
        registry_initialized = true;
    }
}

fn lookupState(api: []const u8) ?*FauxProviderState {
    if (!registry_initialized) return null;
    return registry.get(api);
}

fn unregisterProvider(api: []const u8) void {
    if (!registry_initialized) return;
    _ = registry.remove(api);
}

pub fn fauxText(text: []const u8) FauxContentBlock {
    return .{ .text = text };
}

pub fn fauxThinking(thinking: []const u8) FauxContentBlock {
    return .{ .thinking = thinking };
}

pub fn fauxToolCall(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: std.json.Value,
    options: FauxToolCallOptions,
) !FauxContentBlock {
    const id = if (options.id) |provided|
        try allocator.dupe(u8, provided)
    else blk: {
        tool_call_count += 1;
        break :blk try std.fmt.allocPrint(allocator, "tool-{d}", .{tool_call_count});
    };

    return .{ .tool_call = .{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .arguments = try pi_types.json.cloneValue(allocator, arguments),
    } };
}

pub fn fauxAssistantMessage(content: []const FauxContentBlock, options: FauxAssistantMessageOptions) FauxAssistantMessage {
    return .{
        .content = content,
        .stop_reason = options.stop_reason,
        .error_message = options.error_message,
        .response_id = options.response_id,
        .timestamp = options.timestamp orelse 0,
    };
}

pub fn registerFauxProvider(
    allocator: std.mem.Allocator,
    options: RegisterFauxProviderOptions,
) !FauxProviderRegistration {
    const api_name = try allocator.dupe(u8, options.api orelse DEFAULT_API);
    errdefer allocator.free(api_name);
    const provider_name = try allocator.dupe(u8, options.provider orelse DEFAULT_PROVIDER);
    errdefer allocator.free(provider_name);

    const token_size = options.token_size orelse FauxTokenSize{};
    const configured_min = @as(usize, token_size.min orelse DEFAULT_MIN_TOKEN_SIZE);
    const configured_max = @as(usize, token_size.max orelse DEFAULT_MAX_TOKEN_SIZE);
    const min_token_size = @max(@as(usize, 1), @min(configured_min, configured_max));
    const max_token_size = @max(min_token_size, configured_max);

    const state = try allocator.create(FauxProviderState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .api = api_name,
        .provider = provider_name,
        .min_token_size = min_token_size,
        .max_token_size = max_token_size,
        .pending_responses = .empty,
        .call_count = 0,
        .models = .empty,
    };
    try state.models.append(allocator, .{
        .id = DEFAULT_MODEL_ID,
        .name = DEFAULT_MODEL_NAME,
        .api = state.api,
        .provider = state.provider,
        .base_url = DEFAULT_BASE_URL,
        .reasoning = false,
        .input_types = &[_][]const u8{ "text", "image" },
        .cost = .{},
        .context_window = DEFAULT_CONTEXT_WINDOW,
        .max_tokens = DEFAULT_MAX_TOKENS,
    });

    ensureRegistry();
    try registry.put(state.api, state);
    return .{ .state = state };
}

fn isAbortRequested(signal: ?*const std.atomic.Value(bool)) bool {
    return if (signal) |flag| flag.load(.seq_cst) else false;
}

fn emitChunks(
    out_stream: *pi_types.event_stream.AssistantMessageEventStream,
    allocator: std.mem.Allocator,
    event_type: pi_types.EventType,
    content_index: usize,
    full_text: []const u8,
    min_token_size: usize,
    max_token_size: usize,
    own_chunks: bool,
    signal: ?*const std.atomic.Value(bool),
) bool {
    const min_chars = @max(@as(usize, 1), min_token_size * 4);
    const max_chars = @max(min_chars, max_token_size * 4);
    var offset: usize = 0;
    var chunk_index: usize = 0;

    while (offset < full_text.len) {
        const span = if (min_token_size == max_token_size)
            min_chars
        else
            @min(max_chars, @max(min_chars, (min_token_size + (chunk_index % (max_token_size - min_token_size + 1))) * 4));
        const end = @min(full_text.len, offset + span);
        const chunk = full_text[offset..end];
        if (isAbortRequested(signal)) return false;
        out_stream.push(.{
            .event_type = event_type,
            .content_index = @as(u32, @intCast(content_index)),
            .delta = if (own_chunks) allocator.dupe(u8, chunk) catch return false else chunk,
            .owns_delta = own_chunks,
        });
        offset = end;
        chunk_index += 1;
    }

    if (full_text.len == 0) {
        out_stream.push(.{
            .event_type = event_type,
            .content_index = @as(u32, @intCast(content_index)),
            .delta = "",
            .owns_delta = false,
        });
    }
    return true;
}

fn emitAbort(
    out_stream: *pi_types.event_stream.AssistantMessageEventStream,
    model: pi_types.Model,
) void {
    const aborted = pi_types.AssistantMessage{
        .content = &[_]pi_types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = pi_types.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .timestamp = 0,
    };
    out_stream.push(.{
        .event_type = .error_event,
        .error_message = aborted.error_message,
        .message = aborted,
    });
    out_stream.end(aborted);
}

fn pushResponse(
    allocator: std.mem.Allocator,
    out_stream: *pi_types.event_stream.AssistantMessageEventStream,
    model: pi_types.Model,
    response: FauxAssistantMessage,
    min_token_size: usize,
    max_token_size: usize,
    signal: ?*const std.atomic.Value(bool),
) !void {
    const content_blocks = try allocator.alloc(pi_types.ContentBlock, response.content.len);
    var serialized_args = try allocator.alloc([]const u8, response.content.len);
    for (response.content, 0..) |block, index| {
        serialized_args[index] = "";
        switch (block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text);
                content_blocks[index] = .{ .text = .{ .text = owned } };
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking);
                content_blocks[index] = .{ .thinking = .{ .thinking = owned } };
            },
            .tool_call => |tool_call| {
                const finalized = pi_types.ToolCall{
                    .id = try allocator.dupe(u8, tool_call.id),
                    .name = try allocator.dupe(u8, tool_call.name),
                    .arguments = try pi_types.json.cloneValue(allocator, tool_call.arguments),
                    .thought_signature = if (tool_call.thought_signature) |signature|
                        try allocator.dupe(u8, signature)
                    else
                        null,
                };
                content_blocks[index] = .{ .tool_call = finalized };
                serialized_args[index] = try std.json.Stringify.valueAlloc(allocator, finalized.arguments, .{});
            },
        }
    }

    const final_message = pi_types.AssistantMessage{
        .content = content_blocks,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .response_id = if (response.response_id) |response_id| try allocator.dupe(u8, response_id) else null,
        .usage = pi_types.Usage.init(),
        .stop_reason = response.stop_reason,
        .error_message = response.error_message,
        .timestamp = response.timestamp,
    };

    if (isAbortRequested(signal)) {
        emitAbort(out_stream, model);
        return;
    }

    out_stream.push(.{
        .event_type = .start,
        .message = .{
            .content = &[_]pi_types.ContentBlock{},
            .api = final_message.api,
            .provider = final_message.provider,
            .model = final_message.model,
            .response_id = final_message.response_id,
            .usage = final_message.usage,
            .stop_reason = final_message.stop_reason,
            .error_message = final_message.error_message,
            .timestamp = final_message.timestamp,
        },
    });

    for (content_blocks, 0..) |block, index| {
        switch (block) {
            .text => |text| {
                out_stream.push(.{ .event_type = .text_start, .content_index = @intCast(index) });
                if (!emitChunks(out_stream, allocator, .text_delta, index, text.text, min_token_size, max_token_size, signal != null, signal)) {
                    emitAbort(out_stream, model);
                    return;
                }
                out_stream.push(.{ .event_type = .text_end, .content_index = @intCast(index), .content = text.text });
            },
            .thinking => |thinking| {
                out_stream.push(.{ .event_type = .thinking_start, .content_index = @intCast(index) });
                if (!emitChunks(out_stream, allocator, .thinking_delta, index, thinking.thinking, min_token_size, max_token_size, signal != null, signal)) {
                    emitAbort(out_stream, model);
                    return;
                }
                out_stream.push(.{ .event_type = .thinking_end, .content_index = @intCast(index), .content = thinking.thinking });
            },
            .tool_call => |tool_call| {
                out_stream.push(.{ .event_type = .toolcall_start, .content_index = @intCast(index) });
                if (!emitChunks(out_stream, allocator, .toolcall_delta, index, serialized_args[index], min_token_size, max_token_size, true, signal)) {
                    emitAbort(out_stream, model);
                    return;
                }
                out_stream.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(index),
                    .tool_call = tool_call,
                });
            },
            .image => {},
        }
    }

    if (final_message.stop_reason == .error_reason or final_message.stop_reason == .aborted) {
        out_stream.push(.{
            .event_type = .error_event,
            .error_message = final_message.error_message,
            .message = final_message,
        });
        out_stream.end(final_message);
        return;
    }

    out_stream.push(.{
        .event_type = .done,
        .message = final_message,
    });
    out_stream.end(final_message);
}

pub fn stream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: pi_types.Model,
    context: pi_types.Context,
    options: ?pi_types.SimpleStreamOptions,
    _: ?*anyopaque,
) !pi_types.event_stream.AssistantMessageEventStream {
    var stream_instance = pi_types.event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream_instance.deinit();

    const state = lookupState(model.api) orelse {
        const error_message = pi_types.AssistantMessage{
            .content = &[_]pi_types.ContentBlock{},
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = pi_types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "No more faux responses queued",
            .timestamp = 0,
        };
        stream_instance.push(.{
            .event_type = .error_event,
            .error_message = error_message.error_message,
            .message = error_message,
        });
        stream_instance.end(error_message);
        return stream_instance;
    };

    const step = if (state.pending_responses.items.len > 0)
        state.pending_responses.orderedRemove(0)
    else
        null;
    state.call_count += 1;

    if (step == null) {
        const error_message = pi_types.AssistantMessage{
            .content = &[_]pi_types.ContentBlock{},
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = pi_types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "No more faux responses queued",
            .timestamp = 0,
        };
        stream_instance.push(.{
            .event_type = .error_event,
            .error_message = error_message.error_message,
            .message = error_message,
        });
        stream_instance.end(error_message);
        return stream_instance;
    }

    const signal = if (options) |opts| opts.signal else null;
    const resolved = switch (step.?) {
        .message => |message| message,
        .factory => |factory| factory(
            allocator,
            context,
            if (options) |opts| opts.toStreamOptions() else null,
            &state.call_count,
            model,
        ) catch |err| {
            const error_text = @errorName(err);
            const error_message = pi_types.AssistantMessage{
                .content = &[_]pi_types.ContentBlock{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = pi_types.Usage.init(),
                .stop_reason = .error_reason,
                .error_message = error_text,
                .timestamp = 0,
            };
            stream_instance.push(.{
                .event_type = .error_event,
                .error_message = error_message.error_message,
                .message = error_message,
            });
            stream_instance.end(error_message);
            return stream_instance;
        },
    };

    try pushResponse(
        allocator,
        &stream_instance,
        model,
        resolved,
        state.min_token_size,
        state.max_token_size,
        signal,
    );
    return stream_instance;
}
