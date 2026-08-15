const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const abort_helper = @import("../shared/abort_signal.zig");
const finalize = @import("../shared/finalize.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_json_put = @import("../shared/provider_json_put.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const sse_loop = @import("../shared/sse_loop.zig");

const putBoolValue = provider_json_put.putBoolValue;
const putStringValue = provider_json_put.putStringValue;
const putIntegerValue = provider_json_put.putIntegerValue;
const putFloatValue = provider_json_put.putFloatValue;
const putObjectValue = provider_json_put.putObjectValue;
const stop_reason_mod = @import("../shared/stop_reason.zig");
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const openai = @import("openai.zig");
const test_stream_server = @import("test_stream_server.zig");

pub const KimiProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("kimi-completions", streamProduction);
    pub const api = BaseProvider.api;
    pub const stream = BaseProvider.stream;
    pub const streamSimple = BaseProvider.streamSimple;

    fn streamProduction(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
        stream_instance: *event_stream.AssistantMessageEventStream,
    ) !void {
        const resolved = try resolve_api_key.resolveApiKey(allocator, model, options);
        defer if (resolved) |r| r.deinit(allocator);

        if (resolved == null) {
            try resolve_api_key.pushMissingApiKeyError(allocator, stream_instance, model);
            return;
        }

        const api_key = resolved.?.key;

        // Fast path: struct → bytes directly, no intermediate ObjectMap.
        const json_body = try buildPayloadJsonBytes(allocator, model, context, options);
        defer allocator.free(json_body);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();

        if (model.headers) |model_headers| {
            var it = model_headers.iterator();
            while (it.next()) |entry| {
                try headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        try headers.put("Content-Type", "application/json");
        try headers.put("Accept", "text/event-stream");

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth_header);
        try headers.put("Authorization", auth_header);

        if (options) |stream_options| {
            if (stream_options.headers) |extra_headers| {
                var it = extra_headers.iterator();
                while (it.next()) |entry| {
                    try headers.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url});
        defer allocator.free(url);

        const request = http_client.HttpRequest{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .timeout_ms = if (options) |stream_options| stream_options.timeout_ms orelse 0 else 0,
            .aborted = if (options) |stream_options| stream_options.signal else null,
        };

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var streaming = try client.requestStreaming(request);
        defer streaming.deinit();

        if (options) |stream_options| {
            if (stream_options.on_response) |callback| {
                try provider_stream.invokeOnResponse(allocator, callback, streaming.status, streaming.response_headers, model);
            }
        }

        if (streaming.status != 200) {
            const response_body = try streaming.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, streaming.status, response_body);
            return;
        }

        try parseSseStreamLines(allocator, stream_instance, &streaming, model, options);
    }
};

const ActiveTextBlock = struct {
    event_index: usize,
    text: std.ArrayList(u8),
};

const ActiveThinkingBlock = struct {
    event_index: usize,
    text: std.ArrayList(u8),
};

const ActiveToolCallBlock = struct {
    event_index: usize,
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    partial_args: std.ArrayList(u8),
};

const StreamingBlockKind = enum { text, thinking, tool_call };

const StreamingBlockOrderEntry = struct {
    kind: StreamingBlockKind,
    tool_call_index: ?usize = null,
};

fn deinitActiveTextBlock(allocator: std.mem.Allocator, block: *ActiveTextBlock) void {
    block.text.deinit(allocator);
}

fn deinitActiveThinkingBlock(allocator: std.mem.Allocator, block: *ActiveThinkingBlock) void {
    block.text.deinit(allocator);
}

fn deinitActiveToolCallBlock(allocator: std.mem.Allocator, block: *ActiveToolCallBlock) void {
    block.id.deinit(allocator);
    block.name.deinit(allocator);
    block.partial_args.deinit(allocator);
}

// =============================================================================
// Declarative payload structs.
// =============================================================================

const RequestPayload = struct {
    model: []const u8,
    messages: []const Message,
    stream: bool = true,
    stream_options: StreamOptionsConfig = .{},
    max_completion_tokens: ?u32 = null,
    temperature: ?f32 = null,
    prompt_cache_key: ?[]const u8 = null,
    thinking: ?ThinkingConfig = null,
    tools: ?[]const Tool = null,
};

const StreamOptionsConfig = struct {
    include_usage: bool = true,
};

const ThinkingConfig = struct {
    type: []const u8 = "enabled",
    keep: ?[]const u8 = null,
};

const Message = union(enum) {
    system: StringContentMessage,
    user_text: StringContentMessage,
    user_chunks: ChunkContentMessage,
    assistant: AssistantBody,
    tool: ToolBody,

    pub fn jsonStringify(self: Message, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role");
        switch (self) {
            .system => |m| {
                try jw.write("system");
                try jw.objectField("content");
                try jw.write(m.content);
            },
            .user_text => |m| {
                try jw.write("user");
                try jw.objectField("content");
                try jw.write(m.content);
            },
            .user_chunks => |m| {
                try jw.write("user");
                try jw.objectField("content");
                try jw.write(m.content);
            },
            .assistant => |m| {
                try jw.write("assistant");
                try jw.objectField("content");
                try jw.write(m.content);
                if (m.reasoning_content) |r| {
                    try jw.objectField("reasoning_content");
                    try jw.write(r);
                }
                if (m.partial) {
                    try jw.objectField("partial");
                    try jw.write(true);
                }
                if (m.tool_calls) |tc| {
                    try jw.objectField("tool_calls");
                    try jw.write(tc);
                }
            },
            .tool => |m| {
                try jw.write("tool");
                try jw.objectField("content");
                try jw.write(m.content);
                try jw.objectField("tool_call_id");
                try jw.write(m.tool_call_id);
                if (m.name) |n| {
                    try jw.objectField("name");
                    try jw.write(n);
                }
            },
        }
        try jw.endObject();
    }
};

const StringContentMessage = struct { content: []const u8 };
const ChunkContentMessage = struct { content: []const Chunk };

const AssistantBody = struct {
    content: []const u8,
    reasoning_content: ?[]const u8 = null,
    partial: bool = false,
    tool_calls: ?[]const ToolCallItem = null,
};

const ToolBody = struct {
    content: []const u8,
    tool_call_id: []const u8,
    name: ?[]const u8 = null,
};

const Chunk = union(enum) {
    text: TextChunk,
    image_url: ImageChunk,

    pub fn jsonStringify(self: Chunk, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        switch (self) {
            .text => |t| {
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(t.text);
            },
            .image_url => |i| {
                try jw.write("image_url");
                try jw.objectField("image_url");
                try jw.beginObject();
                try jw.objectField("url");
                try jw.write(i.url);
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

const TextChunk = struct { text: []const u8 };
const ImageChunk = struct { url: []const u8 };

const ToolCallItem = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
};

const FunctionCall = struct {
    name: []const u8,
    arguments: []const u8, // pre-serialized JSON string
};

const Tool = struct {
    type: []const u8 = "function",
    function: ToolFunction,
};

const ToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value, // cloned
};

// =============================================================================
// OwnedPayload + builder.
// =============================================================================

const OwnedPayload = struct {
    allocator: std.mem.Allocator,
    payload: RequestPayload,
    messages_buf: []Message,
    tools_buf: ?[]Tool,
    chunk_lists: []const []Chunk,
    tool_call_lists: []const []ToolCallItem,
    owned_strings: []const []const u8,
    owned_clones: []std.json.Value,

    fn deinit(self: OwnedPayload) void {
        if (self.tools_buf) |t| self.allocator.free(t);
        for (self.chunk_lists) |list| self.allocator.free(list);
        self.allocator.free(self.chunk_lists);
        for (self.tool_call_lists) |list| self.allocator.free(list);
        self.allocator.free(self.tool_call_lists);
        for (self.owned_strings) |s| self.allocator.free(s);
        self.allocator.free(self.owned_strings);
        for (self.owned_clones) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_clones);
        self.allocator.free(self.messages_buf);
    }
};

const OwnedPayloadBuilder = struct {
    allocator: std.mem.Allocator,
    chunk_lists: std.ArrayList([]Chunk) = .empty,
    tool_call_lists: std.ArrayList([]ToolCallItem) = .empty,
    owned_strings: std.ArrayList([]const u8) = .empty,
    owned_clones: std.ArrayList(std.json.Value) = .empty,

    fn deinit(self: *OwnedPayloadBuilder) void {
        for (self.chunk_lists.items) |list| self.allocator.free(list);
        self.chunk_lists.deinit(self.allocator);
        for (self.tool_call_lists.items) |list| self.allocator.free(list);
        self.tool_call_lists.deinit(self.allocator);
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
        for (self.owned_clones.items) |v| provider_json.freeValue(self.allocator, v);
        self.owned_clones.deinit(self.allocator);
    }
};

fn buildOwnedPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !OwnedPayload {
    var builder = OwnedPayloadBuilder{ .allocator = allocator };
    errdefer builder.deinit();

    var messages_list = std.ArrayList(Message).empty;
    errdefer messages_list.deinit(allocator);

    if (context.system_prompt) |system_prompt| {
        const sanitized = try sanitizeSurrogates(allocator, system_prompt);
        try builder.owned_strings.append(allocator, sanitized);
        try messages_list.append(allocator, .{ .system = .{ .content = sanitized } });
    }

    for (context.messages) |message| {
        switch (message) {
            .user => |user_message| {
                const msg = try buildUserMessageStruct(allocator, model, user_message, &builder);
                try messages_list.append(allocator, msg);
            },
            .assistant => |assistant_message| {
                const msg = try buildAssistantMessageStruct(allocator, assistant_message, &builder);
                try messages_list.append(allocator, msg);
            },
            .tool_result => |tool_result| {
                const msg = try buildToolResultMessageStruct(allocator, tool_result, &builder);
                try messages_list.append(allocator, msg);
            },
        }
    }

    const messages_buf = try messages_list.toOwnedSlice(allocator);
    errdefer allocator.free(messages_buf);

    var tools_buf: ?[]Tool = null;
    if (context.tools) |tools| if (tools.len > 0) {
        const tool_array = try allocator.alloc(Tool, tools.len);
        errdefer allocator.free(tool_array);
        for (tools, 0..) |tool, i| {
            const params_clone = try provider_json.cloneValue(allocator, tool.parameters);
            try builder.owned_clones.append(allocator, params_clone);
            tool_array[i] = .{
                .function = .{
                    .name = tool.name,
                    .description = tool.description,
                    .parameters = params_clone,
                },
            };
        }
        tools_buf = tool_array;
    };
    errdefer if (tools_buf) |t| allocator.free(t);

    var max_completion_tokens: ?u32 = null;
    var temperature: ?f32 = null;
    var prompt_cache_key: ?[]const u8 = null;
    if (options) |stream_config| {
        if (stream_config.max_tokens) |m| max_completion_tokens = @intCast(m);
        temperature = stream_config.temperature;
        if (stream_config.session_id) |session_id| {
            if (stream_config.cache_retention != .none) {
                prompt_cache_key = session_id;
            }
        }
    }

    var thinking: ?ThinkingConfig = null;
    if (model.reasoning) {
        thinking = .{
            .type = "enabled",
            .keep = if (containsHistoricalThinking(context)) "all" else null,
        };
    }

    const chunk_lists_slice = try builder.chunk_lists.toOwnedSlice(allocator);
    const tool_call_lists_slice = try builder.tool_call_lists.toOwnedSlice(allocator);
    const owned_strings_slice = try builder.owned_strings.toOwnedSlice(allocator);
    const owned_clones_slice = try builder.owned_clones.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .payload = .{
            .model = model.id,
            .messages = messages_buf,
            .max_completion_tokens = max_completion_tokens,
            .temperature = temperature,
            .prompt_cache_key = prompt_cache_key,
            .thinking = thinking,
            .tools = tools_buf,
        },
        .messages_buf = messages_buf,
        .tools_buf = tools_buf,
        .chunk_lists = chunk_lists_slice,
        .tool_call_lists = tool_call_lists_slice,
        .owned_strings = owned_strings_slice,
        .owned_clones = owned_clones_slice,
    };
}

fn buildUserMessageStruct(
    allocator: std.mem.Allocator,
    model: types.Model,
    user_message: types.UserMessage,
    builder: *OwnedPayloadBuilder,
) !Message {
    var has_images = false;
    for (user_message.content) |block| {
        if (block == .image) {
            has_images = true;
            break;
        }
    }

    var supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            supports_images = true;
            break;
        }
    }

    if (has_images and supports_images) {
        var chunks = std.ArrayList(Chunk).empty;
        errdefer chunks.deinit(allocator);

        for (user_message.content) |block| {
            switch (block) {
                .text => |text| {
                    const sanitized = try sanitizeSurrogates(allocator, text.text);
                    try builder.owned_strings.append(allocator, sanitized);
                    try chunks.append(allocator, .{ .text = .{ .text = sanitized } });
                },
                .image => |image| {
                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    try builder.owned_strings.append(allocator, url);
                    try chunks.append(allocator, .{ .image_url = .{ .url = url } });
                },
                .thinking, .tool_call => {},
            }
        }

        const slice = try chunks.toOwnedSlice(allocator);
        errdefer allocator.free(slice);
        try builder.chunk_lists.append(allocator, slice);
        return .{ .user_chunks = .{ .content = slice } };
    }

    // Plain text content path: concatenate text blocks, optionally add image
    // placeholder when the model doesn't support images.
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    for (user_message.content) |block| {
        switch (block) {
            .text => |content| {
                if (text.items.len > 0) try text.appendSlice(allocator, "\n");
                try text.appendSlice(allocator, content.text);
            },
            .image => {
                if (!supports_images) {
                    if (text.items.len > 0) try text.appendSlice(allocator, "\n");
                    try text.appendSlice(allocator, "(image omitted: model does not support images)");
                }
            },
            .thinking, .tool_call => {},
        }
    }

    const sanitized = try sanitizeSurrogates(allocator, text.items);
    try builder.owned_strings.append(allocator, sanitized);
    return .{ .user_text = .{ .content = sanitized } };
}

fn buildAssistantMessageStruct(
    allocator: std.mem.Allocator,
    assistant_message: types.AssistantMessage,
    builder: *OwnedPayloadBuilder,
) !Message {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    var reasoning = std.ArrayList(u8).empty;
    defer reasoning.deinit(allocator);

    for (assistant_message.content) |block| {
        switch (block) {
            .text => |content| {
                if (text.items.len > 0) try text.appendSlice(allocator, "\n");
                try text.appendSlice(allocator, content.text);
            },
            .thinking => |thinking| {
                if (reasoning.items.len > 0) try reasoning.appendSlice(allocator, "\n");
                try reasoning.appendSlice(allocator, thinking.thinking);
            },
            .image, .tool_call => {},
        }
    }

    const sanitized_text = try sanitizeSurrogates(allocator, text.items);
    try builder.owned_strings.append(allocator, sanitized_text);

    var reasoning_slice: ?[]const u8 = null;
    if (reasoning.items.len > 0) {
        const sanitized_reasoning = try sanitizeSurrogates(allocator, reasoning.items);
        try builder.owned_strings.append(allocator, sanitized_reasoning);
        reasoning_slice = sanitized_reasoning;
    }

    var tool_calls_slice: ?[]ToolCallItem = null;
    if (assistant_message.tool_calls) |tool_calls| {
        const tc_buf = try allocator.alloc(ToolCallItem, tool_calls.len);
        errdefer allocator.free(tc_buf);
        for (tool_calls, 0..) |tool_call, i| {
            const arguments_json = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{});
            try builder.owned_strings.append(allocator, arguments_json);
            tc_buf[i] = .{
                .id = tool_call.id,
                .function = .{ .name = tool_call.name, .arguments = arguments_json },
            };
        }
        try builder.tool_call_lists.append(allocator, tc_buf);
        tool_calls_slice = tc_buf;
    }

    return .{ .assistant = .{
        .content = sanitized_text,
        .reasoning_content = reasoning_slice,
        .partial = assistant_message.stop_reason == .aborted,
        .tool_calls = tool_calls_slice,
    } };
}

fn buildToolResultMessageStruct(
    allocator: std.mem.Allocator,
    tool_result: types.ToolResultMessage,
    builder: *OwnedPayloadBuilder,
) !Message {
    var content = std.ArrayList(u8).empty;
    defer content.deinit(allocator);

    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (content.items.len > 0) try content.appendSlice(allocator, "\n");
                try content.appendSlice(allocator, text.text);
            },
            .image, .thinking, .tool_call => {},
        }
    }

    const sanitized_content = try sanitizeSurrogates(allocator, content.items);
    try builder.owned_strings.append(allocator, sanitized_content);

    return .{ .tool = .{
        .content = sanitized_content,
        .tool_call_id = tool_result.tool_call_id,
        .name = if (tool_result.tool_name.len > 0) tool_result.tool_name else null,
    } };
}

// =============================================================================
// Public API.
// =============================================================================

pub fn buildPayloadJsonBytes(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    var owned = try buildOwnedPayload(allocator, model, context, options);
    defer owned.deinit();
    return try std.json.Stringify.valueAlloc(allocator, owned.payload, .{
        .emit_null_optional_fields = false,
    });
}

/// Compat wrapper for the in-file test that asserts on a std.json.Value tree.
/// Production (`streamProduction`) should call `buildPayloadJsonBytes`.
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    const bytes = try buildPayloadJsonBytes(allocator, model, context, options);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    return try provider_json.cloneValue(allocator, parsed.value);
}

fn containsHistoricalThinking(context: types.Context) bool {
    for (context.messages) |message| {
        switch (message) {
            .assistant => |assistant_message| {
                for (assistant_message.content) |block| {
                    if (block == .thinking and block.thinking.thinking.len > 0) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var state = KimiStreamState.init();
    defer state.deinit(allocator);

    stream_ptr.push(.{ .event_type = .start });

    var handler = KimiSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .state = &state,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
    };
    const loop_result = try sse_loop.run(KimiSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped) {
        return;
    }

    try finishStreamingBlocks(allocator, &state, &content_blocks, &tool_calls, stream_ptr);

    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve, .coerce_stop_reason_for_tool_calls = true });
    // Tool calls live inline in output.content; legacy field intentionally null.
    // tool_calls is borrow-only bookkeeping.

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const KimiStreamState = struct {
    text_block: ?ActiveTextBlock = null,
    thinking_block: ?ActiveThinkingBlock = null,
    active_tool_calls: std.ArrayList(ActiveToolCallBlock) = .empty,
    block_order: std.ArrayList(StreamingBlockOrderEntry) = .empty,

    fn init() KimiStreamState {
        return .{};
    }

    fn deinit(self: *KimiStreamState, allocator: std.mem.Allocator) void {
        if (self.text_block) |*block| deinitActiveTextBlock(allocator, block);
        if (self.thinking_block) |*block| deinitActiveThinkingBlock(allocator, block);
        for (self.active_tool_calls.items) |*tool_call| deinitActiveToolCallBlock(allocator, tool_call);
        self.active_tool_calls.deinit(allocator);
        self.block_order.deinit(allocator);
    }
};

const KimiSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    state: *KimiStreamState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),

    pub fn extractDataLine(_: *KimiSseLoopHandler, line: []const u8) ?[]const u8 {
        return parseSseLine(line);
    }

    pub fn isDoneData(_: *KimiSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *KimiSseLoopHandler, data: []const u8) !bool {
        return try processKimiSseData(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.state,
            self.content_blocks,
            self.tool_calls,
            data,
        );
    }

    pub fn handleRuntimeFailure(self: *KimiSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.state,
            self.content_blocks,
            self.tool_calls,
            err,
        );
    }
};

fn processKimiSseData(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    state: *KimiStreamState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    data: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, stream_ptr, output, state, content_blocks, tool_calls, err);
            return false;
        },
    };
    defer parsed.deinit();

    if (parsed.value != .object) return true;
    const value = parsed.value;

    if (value.object.get("id")) |id_value| {
        if (id_value == .string and output.response_id == null) {
            output.response_id = try allocator.dupe(u8, id_value.string);
        }
    }

    if (value.object.get("usage")) |usage_value| {
        output.usage = parseChunkUsage(usage_value);
    }

    const choices = value.object.get("choices") orelse return true;
    if (choices != .array or choices.array.items.len == 0) return true;

    const choice = choices.array.items[0];
    if (choice != .object) return true;

    if (choice.object.get("usage")) |usage_value| {
        output.usage = parseChunkUsage(usage_value);
    }

    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason == .string) {
            const mapped = try mapStopReason(allocator, finish_reason.string);
            output.stop_reason = mapped.stop_reason;
            if (mapped.error_message) |error_message| {
                if (output.error_message) |existing| allocator.free(existing);
                output.error_message = error_message;
            } else if (output.error_message) |existing| {
                allocator.free(existing);
                output.error_message = null;
            }
        }
    }

    const delta = choice.object.get("delta") orelse return true;
    if (delta != .object) return true;

    if (delta.object.get("reasoning_content")) |reasoning_value| {
        if (reasoning_value == .string and reasoning_value.string.len > 0) {
            try appendThinkingDelta(allocator, state, stream_ptr, reasoning_value.string);
        }
    } else if (delta.object.get("reasoning")) |reasoning_value| {
        if (reasoning_value == .string and reasoning_value.string.len > 0) {
            try appendThinkingDelta(allocator, state, stream_ptr, reasoning_value.string);
        }
    }

    if (delta.object.get("content")) |content_value| {
        if (content_value == .string and content_value.string.len > 0) {
            try appendTextDelta(allocator, state, stream_ptr, content_value.string);
        }
    }

    if (delta.object.get("tool_calls")) |tool_calls_value| {
        if (tool_calls_value == .array) {
            for (tool_calls_value.array.items) |tool_call_value| {
                if (tool_call_value != .object) continue;

                const tool_call_id = if (tool_call_value.object.get("id")) |id_value|
                    if (id_value == .string) id_value.string else null
                else
                    null;

                const tool_call_name = if (tool_call_value.object.get("function")) |function_value| blk: {
                    if (function_value == .object) {
                        if (function_value.object.get("name")) |name_value| {
                            if (name_value == .string) break :blk name_value.string;
                        }
                    }
                    break :blk null;
                } else null;

                const tool_call_arguments = if (tool_call_value.object.get("function")) |function_value| blk: {
                    if (function_value == .object) {
                        if (function_value.object.get("arguments")) |arguments_value| {
                            if (arguments_value == .string) break :blk arguments_value.string;
                        }
                    }
                    break :blk null;
                } else null;

                // Mirrors the TS Chat Completions parser (`ensureTextBlock` /
                // `ensureToolCallBlock` in `packages/ai/src/providers/openai-completions.ts`):
                // the active text block is never closed by an incoming tool-call delta.
                // A subsequent text delta resumes the SAME text block (same content_index)
                // so that text -> tool -> text streams coalesce into one text block plus
                // one tool_call block instead of splitting around the tool. Mirrors the
                // E.4 fix in openai_chat_sse.zig (commit 3050a003) for the Kimi provider.
                const active_tool_call = try ensureActiveToolCallBlock(
                    allocator,
                    state,
                    stream_ptr,
                    tool_call_id,
                );

                if (tool_call_id) |id| {
                    active_tool_call.id.clearRetainingCapacity();
                    try active_tool_call.id.appendSlice(allocator, id);
                }
                if (tool_call_name) |name| {
                    active_tool_call.name.clearRetainingCapacity();
                    try active_tool_call.name.appendSlice(allocator, name);
                }
                const event_delta = if (tool_call_arguments) |arguments| blk: {
                    try active_tool_call.partial_args.appendSlice(allocator, arguments);
                    break :blk try allocator.dupe(u8, arguments);
                } else null;
                stream_ptr.push(.{
                    .event_type = .toolcall_delta,
                    .content_index = @intCast(active_tool_call.event_index),
                    .delta = event_delta,
                    .owns_delta = event_delta != null,
                });
            }
        }
    }

    return true;
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    state: *KimiStreamState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finishStreamingBlocks(allocator, state, content_blocks, tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, output, .{ .content_blocks = content_blocks, .tool_calls = tool_calls }, .{ .content_transfer = .when_output_empty, .total_tokens = .preserve, .coerce_stop_reason_for_tool_calls = false });
    // Tool calls live inline in output.content; legacy field intentionally null.
    // tool_calls is borrow-only bookkeeping.
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    state: *KimiStreamState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, state, content_blocks, tool_calls, stream_ptr);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn appendTextDelta(
    allocator: std.mem.Allocator,
    state: *KimiStreamState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    delta: []const u8,
) !void {
    if (state.text_block == null) {
        const event_index = state.block_order.items.len;
        state.text_block = .{ .event_index = event_index, .text = std.ArrayList(u8).empty };
        try state.block_order.append(allocator, .{ .kind = .text });
        stream_ptr.push(.{
            .event_type = .text_start,
            .content_index = @intCast(event_index),
        });
    }
    if (state.text_block) |*block| {
        try block.text.appendSlice(allocator, delta);
        stream_ptr.push(.{
            .event_type = .text_delta,
            .content_index = @intCast(block.event_index),
            .delta = try allocator.dupe(u8, delta),
            .owns_delta = true,
        });
    }
}

fn appendThinkingDelta(
    allocator: std.mem.Allocator,
    state: *KimiStreamState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    delta: []const u8,
) !void {
    if (state.thinking_block == null) {
        const event_index = state.block_order.items.len;
        state.thinking_block = .{ .event_index = event_index, .text = std.ArrayList(u8).empty };
        try state.block_order.append(allocator, .{ .kind = .thinking });
        stream_ptr.push(.{
            .event_type = .thinking_start,
            .content_index = @intCast(event_index),
        });
    }
    if (state.thinking_block) |*block| {
        try block.text.appendSlice(allocator, delta);
        stream_ptr.push(.{
            .event_type = .thinking_delta,
            .content_index = @intCast(block.event_index),
            .delta = try allocator.dupe(u8, delta),
            .owns_delta = true,
        });
    }
}

fn ensureActiveToolCallBlock(
    allocator: std.mem.Allocator,
    state: *KimiStreamState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    id: ?[]const u8,
) !*ActiveToolCallBlock {
    if (state.active_tool_calls.items.len > 0) {
        const last_index = state.active_tool_calls.items.len - 1;
        const last = &state.active_tool_calls.items[last_index];
        const reuse = blk: {
            if (id) |incoming_id| {
                const current_id = std.mem.trim(u8, last.id.items, " ");
                if (current_id.len == 0) break :blk true;
                break :blk std.mem.eql(u8, current_id, incoming_id);
            }
            break :blk true;
        };
        if (reuse) return last;
    }

    const event_index = state.block_order.items.len;
    const tool_call_index = state.active_tool_calls.items.len;
    try state.active_tool_calls.append(allocator, .{
        .event_index = event_index,
        .id = std.ArrayList(u8).empty,
        .name = std.ArrayList(u8).empty,
        .partial_args = std.ArrayList(u8).empty,
    });
    try state.block_order.append(allocator, .{ .kind = .tool_call, .tool_call_index = tool_call_index });
    stream_ptr.push(.{
        .event_type = .toolcall_start,
        .content_index = @intCast(event_index),
    });
    return &state.active_tool_calls.items[tool_call_index];
}

fn finishStreamingBlocks(
    allocator: std.mem.Allocator,
    state: *KimiStreamState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    for (state.block_order.items) |entry| {
        switch (entry.kind) {
            .text => {
                if (state.text_block) |*block| {
                    const owned = try allocator.dupe(u8, block.text.items);
                    try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                    stream_ptr.push(.{
                        .event_type = .text_end,
                        .content_index = @intCast(block.event_index),
                        .content = owned,
                    });
                    deinitActiveTextBlock(allocator, block);
                    state.text_block = null;
                }
            },
            .thinking => {
                if (state.thinking_block) |*block| {
                    const owned = try allocator.dupe(u8, block.text.items);
                    try content_blocks.append(allocator, .{ .thinking = .{
                        .thinking = owned,
                        .signature = null,
                        .redacted = false,
                    } });
                    stream_ptr.push(.{
                        .event_type = .thinking_end,
                        .content_index = @intCast(block.event_index),
                        .content = owned,
                    });
                    deinitActiveThinkingBlock(allocator, block);
                    state.thinking_block = null;
                }
            },
            .tool_call => {
                const tool_call_index = entry.tool_call_index orelse continue;
                if (tool_call_index >= state.active_tool_calls.items.len) continue;
                const tool_call = &state.active_tool_calls.items[tool_call_index];
                const stored_tool_call: types.ToolCall = blk: {
                    const id = try allocator.dupe(u8, std.mem.trim(u8, tool_call.id.items, " "));
                    errdefer allocator.free(id);
                    const name = try allocator.dupe(u8, std.mem.trim(u8, tool_call.name.items, " "));
                    errdefer allocator.free(name);
                    const arguments = try parseStreamingJsonToValue(allocator, std.mem.trim(u8, tool_call.partial_args.items, " "));
                    errdefer provider_json.freeValue(allocator, arguments);
                    break :blk .{
                        .id = id,
                        .name = name,
                        .arguments = arguments,
                    };
                };
                try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, stored_tool_call);
                stream_ptr.push(.{
                    .event_type = .toolcall_end,
                    .content_index = @intCast(tool_call.event_index),
                    .tool_call = stored_tool_call,
                });
            },
        }
    }

    for (state.active_tool_calls.items) |*tool_call| deinitActiveToolCallBlock(allocator, tool_call);
    state.active_tool_calls.clearRetainingCapacity();
    state.block_order.clearRetainingCapacity();
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    return abort_helper.isRequestedFromOptions(options);
}

pub fn parseSseLine(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "data: ")) return line[6..];
    if (std.mem.startsWith(u8, line, "data:")) return std.mem.trim(u8, line[5..], " ");
    return null;
}

pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8) !?std.json.Parsed(std.json.Value) {
    if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) return null;
    return try std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always });
}

fn parseChunkUsage(value: std.json.Value) types.Usage {
    var usage = types.Usage.init();
    if (value != .object) return usage;

    const prompt_tokens = extractU32Field(value, "prompt_tokens");
    const completion_tokens = extractU32Field(value, "completion_tokens");
    const explicit_total_tokens = extractU32Field(value, "total_tokens");

    var cached_tokens = extractU32Field(value, "cached_tokens");
    var cache_write_tokens: u32 = 0;
    var reasoning_tokens: u32 = 0;

    if (value.object.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            cached_tokens = @max(cached_tokens, extractU32Field(details, "cached_tokens"));
            cache_write_tokens = extractU32Field(details, "cache_write_tokens");
        }
    }

    if (value.object.get("completion_tokens_details")) |details| {
        if (details == .object) {
            reasoning_tokens = extractU32Field(details, "reasoning_tokens");
        }
    }

    const cache_read_tokens = if (cache_write_tokens > 0)
        @max(@as(u32, 0), cached_tokens - cache_write_tokens)
    else
        cached_tokens;

    usage.input = @max(@as(u32, 0), prompt_tokens - cache_read_tokens - cache_write_tokens);
    usage.output = completion_tokens + reasoning_tokens;
    usage.cache_read = cache_read_tokens;
    usage.cache_write = cache_write_tokens;
    usage.total_tokens = if (explicit_total_tokens > 0)
        explicit_total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
    return usage;
}

fn extractU32Field(value: std.json.Value, key: []const u8) u32 {
    if (value != .object) return 0;
    if (value.object.get(key)) |field| {
        return switch (field) {
            .integer => @intCast(field.integer),
            else => 0,
        };
    }
    return 0;
}

fn mapStopReason(allocator: std.mem.Allocator, reason: []const u8) !stop_reason_mod.StopReasonResult {
    const mapped = stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.kimi_mappings, reason, .error_reason);
    return .{
        .stop_reason = mapped,
        .error_message = if (mapped == .error_reason)
            try std.fmt.allocPrint(allocator, "Provider finish_reason: {s}", .{reason})
        else
            null,
    };
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return provider_json.emptyObjectValue(allocator);
    var parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return provider_json.emptyObjectValue(allocator);
    };
    defer parsed.deinit();
    return try provider_json.cloneValue(allocator, parsed.value);
}

fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return try openai.sanitizeSurrogates(allocator, text);
}

fn freeEvent(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    event.deinitTransient(allocator);
    if (event.error_message) |error_message| allocator.free(error_message);
}

const freeToolCallOwned = types.freeToolCall;
const freeAssistantMessageOwned = types.freeAssistantMessage;

test "buildRequestPayload uses kimi-specific fields" {
    const allocator = std.testing.allocator;

    var tool_schema = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    defer provider_json.freeValue(allocator, tool_schema);
    try putStringValue(allocator, &tool_schema.object, "type", "object");

    const tools = &[_]types.Tool{
        .{
            .name = "CodeRunner",
            .description = "Run code",
            .parameters = tool_schema,
        },
    };

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{
                    .{ .thinking = .{ .thinking = "Need to preserve reasoning." } },
                    .{ .text = .{ .text = "Partial answer" } },
                },
                .api = "kimi-completions",
                .provider = "kimi",
                .model = "kimi-k2.6",
                .usage = types.Usage.init(),
                .stop_reason = .aborted,
                .timestamp = 1,
            } },
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Please continue" } }},
                .timestamp = 2,
            } },
        },
        .tools = tools,
    };

    const options = types.StreamOptions{
        .max_tokens = 4096,
        .session_id = "session-123",
    };

    const payload = try buildRequestPayload(allocator, model, context, options);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings("kimi-k2.6", payload.object.get("model").?.string);
    try std.testing.expect(payload.object.get("max_completion_tokens") != null);
    try std.testing.expect(payload.object.get("max_tokens") == null);
    try std.testing.expectEqualStrings("session-123", payload.object.get("prompt_cache_key").?.string);

    const thinking = payload.object.get("thinking").?;
    try std.testing.expect(thinking == .object);
    try std.testing.expectEqualStrings("enabled", thinking.object.get("type").?.string);
    try std.testing.expectEqualStrings("all", thinking.object.get("keep").?.string);

    const messages = payload.object.get("messages").?;
    try std.testing.expect(messages == .array);
    const assistant_message = messages.array.items[0];
    try std.testing.expect(assistant_message == .object);
    try std.testing.expect(assistant_message.object.get("partial").?.bool);
    try std.testing.expectEqualStrings("Need to preserve reasoning.", assistant_message.object.get("reasoning_content").?.string);

    const tools_value = payload.object.get("tools").?;
    const tool_function = tools_value.array.items[0].object.get("function").?;
    try std.testing.expect(tool_function == .object);
    try std.testing.expect(tool_function.object.get("strict") == null);
}

test "parseSseStream emits kimi thinking and text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"cmpl_kimi\",\"choices\":[{\"delta\":{\"reasoning_content\":\"Need tool\"},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"Done\"},\"finish_reason\":\"stop\",\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"cached_tokens\":4}}]}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    const event1 = stream_instance.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream_instance.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.thinking_start, event2.event_type);

    const event3 = stream_instance.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.thinking_delta, event3.event_type);
    try std.testing.expectEqualStrings("Need tool", event3.delta.?);

    // Block-close events are emitted at end-of-stream via finishStreamingBlocks,
    // so thinking_end no longer precedes the next text_start.
    const event4 = stream_instance.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.text_start, event4.event_type);

    const event5 = stream_instance.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.text_delta, event5.event_type);
    try std.testing.expectEqualStrings("Done", event5.delta.?);

    const event6 = stream_instance.next().?;
    defer freeEvent(allocator, event6);
    try std.testing.expectEqual(types.EventType.thinking_end, event6.event_type);

    const event7 = stream_instance.next().?;
    defer freeEvent(allocator, event7);
    try std.testing.expectEqual(types.EventType.text_end, event7.event_type);

    const event8 = stream_instance.next().?;
    defer freeEvent(allocator, event8);
    try std.testing.expectEqual(types.EventType.done, event8.event_type);
    try std.testing.expectEqualStrings("cmpl_kimi", event8.message.?.response_id.?);
    try std.testing.expectEqual(@as(u32, 6), event8.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 20), event8.message.?.usage.output);
    try std.testing.expectEqual(types.StopReason.stop, event8.message.?.stop_reason);
}

test "parseSseStream keeps Kimi compact data-line tolerance under shared SSE loop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "event: message\n" ++
            "data:{\"id\":\"cmpl_compact\",\"choices\":[{\"delta\":{\"content\":\"Compact\"},\"finish_reason\":\"stop\"}]}\n" ++
            "data:[DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    defer freeEvent(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Compact", delta.delta.?);
    const text_end = stream_instance.next().?;
    defer freeEvent(allocator, text_end);
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("cmpl_compact", done.message.?.response_id.?);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStream preserves kimi error finish reason message" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"cmpl_kimi_content_filter\",\"choices\":[{\"delta\":{\"content\":\"Search results\\n- item\"},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\",\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3}}]}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .done) done_message = event.message.?;
    }

    try std.testing.expect(done_message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, done_message.?.stop_reason);
    try std.testing.expect(done_message.?.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, done_message.?.error_message.?, "content_filter") != null);
    try std.testing.expectEqualStrings("Search results\n- item", done_message.?.content[0].text.text);
    freeAssistantMessageOwned(allocator, done_message.?);
}

test "parseChunk rejects malformed provider control envelopes without JSON repair" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SyntaxError, parseChunk(allocator, "{\"id\":\"chunk\" trailing"));
}

test "parseSseStream coalesces kimi text-tool-text into a single text block" {
    // Port of TS PR #4228 (commit 6b271842) / openai_chat_sse.zig E.4 (commit
    // 3050a003): text deltas separated by tool-call deltas must reuse the same
    // text block (same content_index) rather than splitting around the tool call.
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"cmpl_kimi_coalesce\",\"choices\":[{\"delta\":{\"content\":\"before \"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_weather\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}]}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"after\"},\"finish_reason\":\"tool_calls\"}]}\n" ++
            "data: [DONE]\n",
    );

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const start = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, start.event_type);

    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);

    const first_text_delta = stream.next().?;
    defer first_text_delta.deinitTransient(allocator);
    try std.testing.expectEqual(types.EventType.text_delta, first_text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), first_text_delta.content_index.?);
    try std.testing.expectEqualStrings("before ", first_text_delta.delta.?);

    // Tool-call delta must NOT close the text block.
    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);

    const tool_delta = stream.next().?;
    defer tool_delta.deinitTransient(allocator);
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);

    // Subsequent text delta resumes the SAME text block (no new text_start,
    // same content_index 0).
    const second_text_delta = stream.next().?;
    defer second_text_delta.deinitTransient(allocator);
    try std.testing.expectEqual(types.EventType.text_delta, second_text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), second_text_delta.content_index.?);
    try std.testing.expectEqualStrings("after", second_text_delta.delta.?);

    // End-of-stream finalization closes the text block first (it was opened
    // before the tool call), then the tool call, matching the TS `finishBlock`
    // order over `blocks`.
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);
    try std.testing.expectEqualStrings("before after", text_end.content.?);

    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("call_weather", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expectEqualStrings("before after", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("call_weather", done.message.?.content[1].tool_call.id);
    try std.testing.expectEqualStrings("Berlin", done.message.?.content[1].tool_call.arguments.object.get("city").?.string);
    try std.testing.expect(stream.next() == null);

    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStream emits kimi tool call events across fragmented deltas" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_kimi\",\"function\":{\"name\":\"run_terminal\",\"arguments\":\"{\\\"command\\\":\\\"echo\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_kimi\",\"function\":{\"arguments\":\" hello\\\"}\"}}]},\"finish_reason\":\"tool_calls\",\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5,\"cached_tokens\":2}}]}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    const event1 = stream_instance.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream_instance.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream_instance.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);
    try std.testing.expect(event3.owns_delta);
    try std.testing.expectEqualStrings("{\"command\":\"echo", event3.delta.?);

    const event4 = stream_instance.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event4.event_type);
    try std.testing.expect(event4.owns_delta);
    try std.testing.expectEqualStrings(" hello\"}", event4.delta.?);

    const event5 = stream_instance.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.toolcall_end, event5.event_type);
    try std.testing.expect(event5.tool_call != null);
    try std.testing.expectEqualStrings("call_kimi", event5.tool_call.?.id);
    try std.testing.expectEqualStrings("run_terminal", event5.tool_call.?.name);
    try std.testing.expect(event5.tool_call.?.arguments == .object);
    try std.testing.expectEqualStrings("echo hello", event5.tool_call.?.arguments.object.get("command").?.string);

    const event6 = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, event6.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, event6.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), event6.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), event6.message.?.usage.output);
    try std.testing.expect(event6.message.?.tool_calls == null);
    try std.testing.expectEqual(@as(usize, 1), event6.message.?.content.len);
    try std.testing.expect(event6.message.?.content[0] == .tool_call);
    try std.testing.expectEqualStrings("run_terminal", event6.message.?.content[0].tool_call.name);
    try std.testing.expect(event6.message.?.content[0].tool_call.arguments == .object);
    try std.testing.expectEqualStrings("echo hello", event6.message.?.content[0].tool_call.arguments.object.get("command").?.string);
    try std.testing.expect(event5.tool_call.?.id.ptr == event6.message.?.content[0].tool_call.id.ptr);
    try std.testing.expect(event5.tool_call.?.name.ptr == event6.message.?.content[0].tool_call.name.ptr);
    try std.testing.expect(
        event5.tool_call.?.arguments.object.get("command").?.string.ptr ==
            event6.message.?.content[0].tool_call.arguments.object.get("command").?.string.ptr,
    );

    freeAssistantMessageOwned(allocator, event6.message.?);
}

test "parseSseStream preserves kimi content indexes across thinking tool text blocks" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"cmpl_kimi_index\",\"choices\":[{\"delta\":{\"reasoning_content\":\"Need tool\"},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_kimi\",\"function\":{\"name\":\"run_terminal\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"After tool\"},\"finish_reason\":\"stop\",\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5,\"cached_tokens\":2}}]}\n" ++
            "data: [DONE]\n",
    );

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const thinking_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_start, thinking_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_start.content_index.?);
    const thinking_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_delta.content_index.?);

    // Block-close events are emitted at end-of-stream via finishStreamingBlocks,
    // mirroring the TS `finishBlock` order. Tool/text starts happen first.
    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);

    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_start.content_index.?);
    const text_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_delta.content_index.?);
    try std.testing.expectEqualStrings("After tool", text_delta.delta.?);

    // End-of-stream finalization in block_order order: thinking(0), tool(1), text(2).
    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_end.content_index.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_end.content_index.?);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), done.message.?.content.len);
    try std.testing.expectEqualStrings("Need tool", done.message.?.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("run_terminal", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("After tool", done.message.?.content[2].text.text);
    try std.testing.expect(stream.next() == null);
}

test "ISS-060 ISS-061 parseSseStream omits placeholder text for tool-call-only response and coerces stop reason" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_kimi\",\"function\":{\"name\":\"run_terminal\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]},\"finish_reason\":\"stop\"}]}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    const event1 = stream_instance.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream_instance.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream_instance.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);

    const event4 = stream_instance.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_end, event4.event_type);

    const event5 = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, event5.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), event5.message.?.content.len);
    try std.testing.expect(event5.message.?.content[0] == .tool_call);
    try std.testing.expect(event5.message.?.tool_calls == null);
    try std.testing.expect(stream_instance.next() == null);

    freeAssistantMessageOwned(allocator, event5.message.?);
}

test "sanitizeSurrogates matches openai surrogate filtering" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'A', 0xED, 0xA0, 0x80, 'B' };
    const sanitized = try sanitizeSurrogates(allocator, &input);
    defer allocator.free(sanitized);
    const openai_sanitized = try openai.sanitizeSurrogates(allocator, &input);
    defer allocator.free(openai_sanitized);
    try std.testing.expectEqualStrings("AB", sanitized);
    try std.testing.expectEqualStrings(openai_sanitized, sanitized);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"kimi denied\",\"authorization\":\"Bearer sk-kimi-secret\",\"request_id\":\"req_kimi_random_123456\"},\"trace\":\"/Users/alice/pi/kimi.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 503, "Service Unavailable", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try KimiProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 503: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "kimi denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-kimi-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_kimi_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", result.api);
}

fn runtimePreservationTestModel(api: types.Api, provider: types.Provider) types.Model {
    return .{
        .id = "runtime-test-model",
        .name = "Runtime Test Model",
        .api = api,
        .provider = provider,
        .base_url = "https://example.test",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

test "parseSseStreamLines preserves partial Kimi text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"kimi-runtime\",\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("kimi-k2", "moonshot"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("kimi-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseSseStreamLines finalizes Kimi text and tool call on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"kimi-eof\",\"choices\":[{\"delta\":{\"content\":\"before tool\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_eof\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"local\\\"}\"}}]}}]}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("kimi-completions", "kimi"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);
    const text_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_delta.content_index.?);
    try std.testing.expectEqualStrings("before tool", text_delta.delta.?);

    // Tool-call delta no longer closes the text block; text_end is emitted at
    // EOF via finishStreamingBlocks instead.
    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);

    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);
    try std.testing.expectEqualStrings("before tool", text_end.content.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("call_eof", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("local", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-eof", done.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expectEqualStrings("before tool", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("local", done.message.?.content[1].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial Kimi text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"id\":\"kimi-abort\",\"choices\":[{\"delta\":{\"content\":\"partial kimi\"},\"finish_reason\":null}]}\n",
            .delay_after_ms = 1000,
        },
        .{ .bytes = "data: [DONE]\n" },
    };
    var server = try test_stream_server.DelayedChunkServer.init(io, &chunks);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);
    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    var abort_signal = std.atomic.Value(bool).init(false);
    const AbortAfterResponse = struct {
        var signal: ?*std.atomic.Value(bool) = null;
        var thread: ?std.Thread = null;

        fn callback(_: u16, _: std.StringHashMap([]const u8), _: types.Model) !void {
            thread = try test_stream_server.startAbortThread(std.testing.io, signal.?, 250);
        }
    };
    AbortAfterResponse.signal = &abort_signal;
    AbortAfterResponse.thread = null;
    defer if (AbortAfterResponse.thread) |thread| thread.join();

    var stream = try KimiProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial kimi", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial kimi", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial kimi", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "stream returns error_event when API key is empty" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try KimiProvider.stream(allocator, io, model, context, .{ .api_key = "" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "No API key for provider: kimi") != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", event.message.?.api);
    try std.testing.expectEqualStrings("kimi", event.message.?.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", event.message.?.model);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    allocator.free(result.error_message.?);
}

test "stream returns error_event when options is null (no API key available)" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "https://api.moonshot.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    // When options is null and no KIMI_API_KEY env var is set,
    // stream() must return a stream with error_event (not throw).
    var stream = try KimiProvider.stream(allocator, io, model, context, null);
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "No API key for provider: kimi") != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", event.message.?.api);
    try std.testing.expectEqualStrings("kimi", event.message.?.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", event.message.?.model);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    allocator.free(result.error_message.?);
}

test "stream returns error_event on non-API-key setup failure instead of throwing" {
    // VAL-STREAM-003: streamProduction wrapper catches connection failures when API key is present
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const model = types.Model{
        .id = "kimi-k2.6",
        .name = "Kimi K2.6",
        .api = "kimi-completions",
        .provider = "kimi",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try KimiProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("kimi-completions", error_event.message.?.api);
    try std.testing.expectEqualStrings("kimi", error_event.message.?.provider);
    try std.testing.expectEqualStrings("kimi-k2.6", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
}
