const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const abort_helper = @import("../shared/abort_signal.zig");
const provider_error = @import("../shared/provider_error.zig");
const finalize = @import("../shared/finalize.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const provider_json = @import("../shared/provider_json.zig");
const sse_loop = @import("../shared/sse_loop.zig");
const stop_reason_mod = @import("../shared/stop_reason.zig");
const test_stream_server = @import("test_stream_server.zig");

const MISTRAL_TOOL_CALL_ID_LENGTH: usize = 9;
const IMAGE_OMITTED_TEXT = "(image omitted: model does not support images)";
const TOOL_IMAGE_OMITTED_TEXT = "(tool image omitted: model does not support images)";

const ToolCallIdMapping = struct {
    original: []const u8,
    normalized: []const u8,
};

const CurrentBlock = union(enum) {
    text: struct {
        event_index: usize,
        text: std.ArrayList(u8),
    },
    thinking: struct {
        event_index: usize,
        text: std.ArrayList(u8),
    },
};

const StreamingToolCall = struct {
    event_index: usize,
    index: usize,
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    partial_args: std.ArrayList(u8),

    fn deinit(self: *StreamingToolCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.partial_args.deinit(allocator);
    }
};

const ToolCallIdNormalizer = struct {
    allocator: std.mem.Allocator,
    mappings: std.ArrayList(ToolCallIdMapping),

    fn init(allocator: std.mem.Allocator) ToolCallIdNormalizer {
        return .{
            .allocator = allocator,
            .mappings = std.ArrayList(ToolCallIdMapping).empty,
        };
    }

    fn deinit(self: *ToolCallIdNormalizer) void {
        for (self.mappings.items) |entry| {
            self.allocator.free(entry.normalized);
        }
        self.mappings.deinit(self.allocator);
    }

    fn normalize(self: *ToolCallIdNormalizer, original: []const u8) ![]const u8 {
        for (self.mappings.items) |entry| {
            if (std.mem.eql(u8, entry.original, original)) return entry.normalized;
        }

        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const candidate = try deriveMistralToolCallId(self.allocator, original, attempt);
            var collision = false;
            for (self.mappings.items) |entry| {
                if (std.mem.eql(u8, entry.normalized, candidate) and !std.mem.eql(u8, entry.original, original)) {
                    collision = true;
                    break;
                }
            }
            if (!collision) {
                try self.mappings.append(self.allocator, .{
                    .original = original,
                    .normalized = candidate,
                });
                return candidate;
            }
            self.allocator.free(candidate);
        }
    }
};

pub const MistralProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("mistral-conversations", streamProduction);
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

        // Fast path: build payload struct and serialize directly to bytes.
        var json_body = try buildPayloadJsonBytes(allocator, model, context, options);
        defer allocator.free(json_body);

        // Test-fixture path: on_payload still expects std.json.Value. Round-trip
        // through parse + stringify only when the callback is set; production
        // skips this entirely.
        if (options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_body, .{});
                defer parsed.deinit();
                if (try callback(allocator, parsed.value, model)) |replacement| {
                    defer provider_json.freeValue(allocator, replacement);
                    const new_body = try std.json.Stringify.valueAlloc(allocator, replacement, .{});
                    allocator.free(json_body);
                    json_body = new_body;
                }
            }
        }

        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url});
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer provider_stream.deinitOwnedHeaders(allocator, &headers);
        try provider_stream.putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try provider_stream.putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth_header);
        try provider_stream.putOwnedHeader(allocator, &headers, "Authorization", auth_header);
        try provider_stream.mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try provider_stream.mergeHeaders(allocator, &headers, stream_options.headers);
            // x-affinity header is only sent when prompt caching is active (cache_retention != .none).
            if (stream_options.cache_retention != .none) {
                if (stream_options.session_id) |session_id| {
                    if (!provider_stream.containsHeaderCaseInsensitive(&headers, "x-affinity")) {
                        try provider_stream.putOwnedHeader(allocator, &headers, "x-affinity", session_id);
                    }
                }
            }
        }

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try provider_stream.executeStreamingRequest(
            &client,
            url,
            headers,
            json_body,
            options,
            model,
        );
        defer response.deinit();

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, response.status, response_body);
            return;
        }

        try parseSseStreamLines(allocator, stream_instance, &response, model, options);
    }
};

// =============================================================================
// Declarative payload structs (struct → std.json.Stringify reflection).
// =============================================================================

const RequestPayload = struct {
    model: []const u8,
    stream: bool = true,
    messages: []const Message,
    tools: ?[]const Tool = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    metadata: ?std.json.Value = null,
    reasoning_effort: ?[]const u8 = null,
    prompt_mode: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
};

const Message = union(enum) {
    system: SystemPayload,
    user: UserPayload,
    assistant: AssistantPayload,
    tool: ToolPayload,

    pub fn jsonStringify(self: Message, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("role");
        switch (self) {
            .system => |s| {
                try jw.write("system");
                try jw.objectField("content");
                try jw.write(s.content);
            },
            .user => |u| {
                try jw.write("user");
                try jw.objectField("content");
                try jw.write(u.content);
            },
            .assistant => |a| {
                try jw.write("assistant");
                if (a.content) |c| {
                    try jw.objectField("content");
                    try jw.write(c);
                }
                if (a.tool_calls) |tc| {
                    try jw.objectField("tool_calls");
                    try jw.write(tc);
                }
            },
            .tool => |t| {
                try jw.write("tool");
                try jw.objectField("tool_call_id");
                try jw.write(t.tool_call_id);
                try jw.objectField("name");
                try jw.write(t.name);
                try jw.objectField("content");
                try jw.write(t.content);
            },
        }
        try jw.endObject();
    }
};

const SystemPayload = struct { content: []const u8 };
const UserPayload = struct { content: []const Chunk };
const AssistantPayload = struct {
    content: ?[]const Chunk = null,
    tool_calls: ?[]const ToolCallItem = null,
};
const ToolPayload = struct {
    tool_call_id: []const u8,
    name: []const u8,
    content: []const Chunk,
};

const Chunk = union(enum) {
    text: TextChunk,
    image_url: ImageChunk,
    thinking_text: ThinkingChunk,

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
                try jw.write(i.url);
            },
            .thinking_text => |t| {
                try jw.write("thinking");
                try jw.objectField("thinking");
                try jw.beginArray();
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(t.text);
                try jw.endObject();
                try jw.endArray();
            },
        }
        try jw.endObject();
    }
};

const TextChunk = struct { text: []const u8 };
const ImageChunk = struct { url: []const u8 };
const ThinkingChunk = struct { text: []const u8 };

const ToolCallItem = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: FunctionCall,
    index: usize,
};

const FunctionCall = struct {
    name: []const u8,
    arguments: std.json.Value, // cloned, freed by OwnedPayload
};

const Tool = struct {
    type: []const u8 = "function",
    function: ToolFunction,
};

const ToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value, // cloned, freed by OwnedPayload
    strict: bool = false,
};

// =============================================================================
// OwnedPayload + builder: track all runtime-allocated bytes referenced by the
// struct tree (sanitized text, base64 data URLs, cloned dynamic Values, the
// chunk/tool-call slice backing storage). Free in reverse order via `deinit`
// AFTER the struct has been serialized.
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
    normalizer: *ToolCallIdNormalizer,
) !OwnedPayload {
    var builder = OwnedPayloadBuilder{ .allocator = allocator };
    errdefer builder.deinit();

    var messages_list = std.ArrayList(Message).empty;
    errdefer messages_list.deinit(allocator);

    if (context.system_prompt) |system_prompt| {
        try messages_list.append(allocator, .{ .system = .{ .content = system_prompt } });
    }

    for (context.messages) |message| {
        switch (message) {
            .user => |user| {
                const msg = try buildUserMessage(allocator, model, user, &builder);
                try messages_list.append(allocator, msg);
            },
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    if (try buildAssistantMessage(allocator, assistant, normalizer, &builder)) |msg| {
                        try messages_list.append(allocator, msg);
                    }
                }
            },
            .tool_result => |tool_result| {
                const msg = try buildToolResultMessage(allocator, model, tool_result, normalizer, &builder);
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

    var temperature: ?f32 = null;
    var max_tokens: ?u32 = null;
    var metadata: ?std.json.Value = null;
    var reasoning_effort: ?[]const u8 = null;
    var prompt_mode: ?[]const u8 = null;
    var prompt_cache_key: ?[]const u8 = null;
    if (options) |opts| {
        temperature = opts.temperature;
        max_tokens = if (opts.max_tokens) |m| @intCast(m) else null;
        if (opts.metadata) |m| {
            const cloned = try provider_json.cloneValue(allocator, m);
            try builder.owned_clones.append(allocator, cloned);
            metadata = cloned;
        }
        const mistral_opts = opts.providerOptions("mistral");
        reasoning_effort = mistral_opts.reasoning_effort;
        prompt_mode = mistral_opts.prompt_mode;
        // Prompt caching: only when cache retention is not "none" and a session ID is set.
        if (opts.cache_retention != .none) {
            if (opts.session_id) |sid| prompt_cache_key = sid;
        }
    }

    // Promote builder lists to owned slices (transfer ownership to OwnedPayload).
    const chunk_lists_slice = try builder.chunk_lists.toOwnedSlice(allocator);
    const tool_call_lists_slice = try builder.tool_call_lists.toOwnedSlice(allocator);
    const owned_strings_slice = try builder.owned_strings.toOwnedSlice(allocator);
    const owned_clones_slice = try builder.owned_clones.toOwnedSlice(allocator);
    // Builder is now empty — no further errdefer cleanup needed for it.

    return .{
        .allocator = allocator,
        .payload = .{
            .model = model.id,
            .messages = messages_buf,
            .tools = tools_buf,
            .temperature = temperature,
            .max_tokens = max_tokens,
            .metadata = metadata,
            .reasoning_effort = reasoning_effort,
            .prompt_mode = prompt_mode,
            .prompt_cache_key = prompt_cache_key,
        },
        .messages_buf = messages_buf,
        .tools_buf = tools_buf,
        .chunk_lists = chunk_lists_slice,
        .tool_call_lists = tool_call_lists_slice,
        .owned_strings = owned_strings_slice,
        .owned_clones = owned_clones_slice,
    };
}

fn buildUserMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    user: types.UserMessage,
    builder: *OwnedPayloadBuilder,
) !Message {
    const supports_images = modelSupportsImages(model);
    var chunks = std.ArrayList(Chunk).empty;
    errdefer chunks.deinit(allocator);

    var inserted_image_placeholder = false;
    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                try chunks.append(allocator, .{ .text = .{ .text = text.text } });
                inserted_image_placeholder = false;
            },
            .image => |image| {
                if (supports_images) {
                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    errdefer allocator.free(url);
                    try builder.owned_strings.append(allocator, url);
                    try chunks.append(allocator, .{ .image_url = .{ .url = url } });
                } else if (!inserted_image_placeholder) {
                    try chunks.append(allocator, .{ .text = .{ .text = IMAGE_OMITTED_TEXT } });
                    inserted_image_placeholder = true;
                }
            },
            .thinking, .tool_call => {},
        }
    }

    if (chunks.items.len == 0) {
        try chunks.append(allocator, .{ .text = .{ .text = "" } });
    }

    const chunks_slice = try chunks.toOwnedSlice(allocator);
    errdefer allocator.free(chunks_slice);
    try builder.chunk_lists.append(allocator, chunks_slice);

    return .{ .user = .{ .content = chunks_slice } };
}

fn buildAssistantMessage(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    normalizer: *ToolCallIdNormalizer,
    builder: *OwnedPayloadBuilder,
) !?Message {
    var chunks = std.ArrayList(Chunk).empty;
    errdefer chunks.deinit(allocator);

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try chunks.append(allocator, .{ .text = .{ .text = text.text } });
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                try chunks.append(allocator, .{ .thinking_text = .{ .text = thinking.thinking } });
            },
            .image, .tool_call => {},
        }
    }

    var content_slice: ?[]Chunk = null;
    if (chunks.items.len > 0) {
        const slice = try chunks.toOwnedSlice(allocator);
        errdefer allocator.free(slice);
        try builder.chunk_lists.append(allocator, slice);
        content_slice = slice;
    } else {
        chunks.deinit(allocator);
    }

    const tool_calls_source = if (types.hasInlineToolCalls(assistant)) blk: {
        break :blk try types.collectAssistantToolCalls(allocator, assistant);
    } else null;
    defer if (tool_calls_source) |calls| allocator.free(calls);

    var tool_calls_slice: ?[]ToolCallItem = null;
    if (tool_calls_source orelse assistant.tool_calls) |tool_calls| {
        if (tool_calls.len > 0) {
            const tc_buf = try allocator.alloc(ToolCallItem, tool_calls.len);
            errdefer allocator.free(tc_buf);
            for (tool_calls, 0..) |tc, i| {
                const normalized_id = try normalizer.normalize(tc.id);
                const args_clone = try provider_json.cloneValue(allocator, tc.arguments);
                try builder.owned_clones.append(allocator, args_clone);
                tc_buf[i] = .{
                    .id = normalized_id,
                    .function = .{ .name = tc.name, .arguments = args_clone },
                    .index = i,
                };
            }
            try builder.tool_call_lists.append(allocator, tc_buf);
            tool_calls_slice = tc_buf;
        }
    }

    if (content_slice == null and tool_calls_slice == null) return null;
    return .{ .assistant = .{ .content = content_slice, .tool_calls = tool_calls_slice } };
}

fn buildToolResultMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
    normalizer: *ToolCallIdNormalizer,
    builder: *OwnedPayloadBuilder,
) !Message {
    const supports_images = modelSupportsImages(model);
    const normalized_id = try normalizer.normalize(tool_result.tool_call_id);

    var chunks = std.ArrayList(Chunk).empty;
    errdefer chunks.deinit(allocator);

    const tool_text = try buildToolResultText(allocator, tool_result.content, supports_images, tool_result.is_error);
    {
        errdefer allocator.free(tool_text);
        try builder.owned_strings.append(allocator, tool_text);
    }
    try chunks.append(allocator, .{ .text = .{ .text = tool_text } });

    if (supports_images) {
        for (tool_result.content) |block| {
            switch (block) {
                .image => |image| {
                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    errdefer allocator.free(url);
                    try builder.owned_strings.append(allocator, url);
                    try chunks.append(allocator, .{ .image_url = .{ .url = url } });
                },
                else => {},
            }
        }
    }

    const chunks_slice = try chunks.toOwnedSlice(allocator);
    errdefer allocator.free(chunks_slice);
    try builder.chunk_lists.append(allocator, chunks_slice);

    return .{ .tool = .{
        .tool_call_id = normalized_id,
        .name = tool_result.tool_name,
        .content = chunks_slice,
    } };
}

// =============================================================================
// Public API.
// =============================================================================

/// Fast path: build the payload struct and serialize it directly to JSON
/// bytes via std.json.Stringify reflection. No intermediate ObjectMap, no
/// per-key allocator dupes.
pub fn buildPayloadJsonBytes(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    var normalizer = ToolCallIdNormalizer.init(allocator);
    defer normalizer.deinit();

    var owned = try buildOwnedPayload(allocator, model, context, options, &normalizer);
    defer owned.deinit();

    return try std.json.Stringify.valueAlloc(allocator, owned.payload, .{
        .emit_null_optional_fields = false,
    });
}

/// Compatibility wrapper that returns a `std.json.Value` tree by going
/// through `buildPayloadJsonBytes` + `parseFromSlice` + `cloneValue`. Used
/// by tests that assert on the tree shape and by `register_builtins.zig`'s
/// smoke test. Production (`streamProduction`) should call
/// `buildPayloadJsonBytes` directly.
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

pub fn mapStopReason(reason: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.mistral_mappings, reason, .stop);
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

    var content_slots = std.ArrayList(?types.ContentBlock).empty;
    defer content_slots.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var active_tool_calls = std.ArrayList(StreamingToolCall).empty;
    defer {
        for (active_tool_calls.items) |*tool_call| tool_call.deinit(allocator);
        active_tool_calls.deinit(allocator);
    }

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    var next_content_index: usize = 0;

    stream_ptr.push(.{ .event_type = .start });

    var handler = MistralSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .current_block = &current_block,
        .content_slots = &content_slots,
        .tool_calls = &tool_calls,
        .active_tool_calls = &active_tool_calls,
        .next_content_index = &next_content_index,
        .model = model,
    };
    const loop_result = try sse_loop.run(MistralSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped) {
        return;
    }

    try finishCurrentBlock(allocator, &current_block, &content_slots, stream_ptr);

    for (active_tool_calls.items) |*tool_call| {
        const arguments = try parseStreamingJsonToValue(allocator, tool_call.partial_args.items);
        const final_tool_call = types.ToolCall{
            .id = try allocator.dupe(u8, tool_call.id.items),
            .name = try allocator.dupe(u8, std.mem.trim(u8, tool_call.name.items, " ")),
            .arguments = arguments,
        };
        try ensureContentSlotCapacity(allocator, &content_slots, tool_call.event_index);
        // Inline tool call lives in `content` as the single source of truth.
        // The legacy AssistantMessage.tool_calls cache is intentionally left
        // null; readers go through collectAssistantToolCalls / inline blocks.
        content_slots.items[tool_call.event_index] = .{ .tool_call = final_tool_call };
        try tool_calls.append(allocator, final_tool_call);
        stream_ptr.push(.{
            .event_type = .toolcall_end,
            .content_index = @intCast(tool_call.event_index),
            .tool_call = final_tool_call,
        });
    }

    finalize.calculateCost(model, &output.usage);
    output.content = try materializeContent(allocator, content_slots.items);
    output.stop_reason = provider_error.coerceStopReasonForToolCalls(output.stop_reason, tool_calls.items.len > 0);

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const MistralSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_tool_calls: *std.ArrayList(StreamingToolCall),
    next_content_index: *usize,
    model: types.Model,

    pub fn extractDataLine(_: *MistralSseLoopHandler, line: []const u8) ?[]const u8 {
        return provider_stream.parseCanonicalSseDataLine(line);
    }

    pub fn isDoneData(_: *MistralSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *MistralSseLoopHandler, data: []const u8) !bool {
        return try processMistralSseData(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.current_block,
            self.content_slots,
            self.tool_calls,
            self.active_tool_calls,
            self.next_content_index,
            self.model,
            data,
        );
    }

    pub fn handleRuntimeFailure(self: *MistralSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.current_block,
            self.content_slots,
            self.tool_calls,
            self.active_tool_calls,
            self.model,
            err,
        );
    }
};

fn processMistralSseData(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_tool_calls: *std.ArrayList(StreamingToolCall),
    next_content_index: *usize,
    model: types.Model,
    data: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, stream_ptr, output, current_block, content_slots, tool_calls, active_tool_calls, model, err);
            return false;
        },
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return true;

    if (value.object.get("id")) |id_value| {
        if (id_value == .string and output.response_id == null) {
            output.response_id = try allocator.dupe(u8, id_value.string);
        }
    }

    if (value.object.get("usage")) |usage_value| {
        updateUsage(&output.usage, usage_value);
    }

    const choices_value = value.object.get("choices") orelse return true;
    if (choices_value != .array or choices_value.array.items.len == 0) return true;

    const choice = choices_value.array.items[0];
    if (choice != .object) return true;

    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason == .string) {
            output.stop_reason = mapStopReason(finish_reason.string);
        }
    }

    const delta_value = choice.object.get("delta") orelse return true;
    if (delta_value != .object) return true;

    if (delta_value.object.get("content")) |content_value| {
        switch (content_value) {
            .string => |text_delta| {
                if (text_delta.len > 0) {
                    try appendTextDelta(allocator, current_block, content_slots, stream_ptr, next_content_index, text_delta, false);
                }
            },
            .array => |content_array| {
                for (content_array.items) |item| {
                    if (item != .object) continue;
                    const chunk_type = item.object.get("type") orelse continue;
                    if (chunk_type != .string) continue;

                    if (std.mem.eql(u8, chunk_type.string, "text")) {
                        if (item.object.get("text")) |text_value| {
                            if (text_value == .string and text_value.string.len > 0) {
                                try appendTextDelta(allocator, current_block, content_slots, stream_ptr, next_content_index, text_value.string, false);
                            }
                        }
                        continue;
                    }

                    if (std.mem.eql(u8, chunk_type.string, "thinking")) {
                        if (try extractThinkingText(allocator, item)) |thinking_delta| {
                            defer allocator.free(thinking_delta);
                            try appendTextDelta(allocator, current_block, content_slots, stream_ptr, next_content_index, thinking_delta, true);
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (delta_value.object.get("tool_calls")) |tool_calls_value| {
        if (tool_calls_value == .array) {
            try finishCurrentBlock(allocator, current_block, content_slots, stream_ptr);
            for (tool_calls_value.array.items) |tool_call_value| {
                if (tool_call_value != .object) continue;
                const call_index = getJsonUsize(tool_call_value.object.get("index"));
                const raw_call_id = if (tool_call_value.object.get("id")) |id_value|
                    if (id_value == .string and !std.mem.eql(u8, id_value.string, "null")) id_value.string else null
                else
                    null;
                const normalized_call_id = if (raw_call_id) |call_id|
                    try deriveMistralToolCallId(allocator, call_id, 0)
                else blk: {
                    const generated_id = try std.fmt.allocPrint(allocator, "toolcall:{d}", .{call_index});
                    defer allocator.free(generated_id);
                    break :blk try deriveMistralToolCallId(allocator, generated_id, 0);
                };
                defer allocator.free(normalized_call_id);

                const tool_call = if (findStreamingToolCall(active_tool_calls, normalized_call_id, call_index)) |existing|
                    existing
                else blk: {
                    try active_tool_calls.append(allocator, .{
                        .event_index = next_content_index.*,
                        .index = call_index,
                        .id = std.ArrayList(u8).empty,
                        .name = std.ArrayList(u8).empty,
                        .partial_args = std.ArrayList(u8).empty,
                    });
                    try active_tool_calls.items[active_tool_calls.items.len - 1].id.appendSlice(allocator, normalized_call_id);
                    stream_ptr.push(.{
                        .event_type = .toolcall_start,
                        .content_index = @intCast(next_content_index.*),
                    });
                    next_content_index.* += 1;
                    break :blk &active_tool_calls.items[active_tool_calls.items.len - 1];
                };

                if (tool_call_value.object.get("function")) |function_value| {
                    if (function_value == .object) {
                        if (function_value.object.get("name")) |name_value| {
                            if (name_value == .string and name_value.string.len > 0) {
                                tool_call.name.clearRetainingCapacity();
                                try tool_call.name.appendSlice(allocator, name_value.string);
                            }
                        }
                        if (function_value.object.get("arguments")) |arguments_value| {
                            const arguments_delta = try stringifyArgumentsDelta(allocator, arguments_value);
                            defer allocator.free(arguments_delta);
                            try tool_call.partial_args.appendSlice(allocator, arguments_delta);
                            stream_ptr.push(.{
                                .event_type = .toolcall_delta,
                                .content_index = @intCast(tool_call.event_index),
                                .delta = try allocator.dupe(u8, arguments_delta),
                                .owns_delta = true,
                            });
                        }
                    }
                }
            }
        }
    }

    return true;
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_tool_calls: *std.ArrayList(StreamingToolCall),
    model: types.Model,
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finishCurrentBlock(allocator, current_block, content_slots, stream_ptr);

    for (active_tool_calls.items) |*tool_call| {
        const arguments = try parseStreamingJsonToValue(allocator, tool_call.partial_args.items);
        const final_tool_call = types.ToolCall{
            .id = try allocator.dupe(u8, tool_call.id.items),
            .name = try allocator.dupe(u8, std.mem.trim(u8, tool_call.name.items, " ")),
            .arguments = arguments,
        };
        try ensureContentSlotCapacity(allocator, content_slots, tool_call.event_index);
        // Inline tool call is the source of truth (see parseSseStreamLines).
        content_slots.items[tool_call.event_index] = .{ .tool_call = final_tool_call };
        try tool_calls.append(allocator, final_tool_call);
        stream_ptr.push(.{
            .event_type = .toolcall_end,
            .content_index = @intCast(tool_call.event_index),
            .tool_call = final_tool_call,
        });
    }
    active_tool_calls.clearRetainingCapacity();

    finalize.calculateCost(model, &output.usage);
    if (output.content.len == 0 and content_slots.items.len > 0) {
        output.content = try materializeContent(allocator, content_slots.items);
    }
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_tool_calls: *std.ArrayList(StreamingToolCall),
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, content_slots, tool_calls, active_tool_calls, model, stream_ptr);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn buildToolResultText(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    supports_images: bool,
    is_error: bool,
) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var has_text = false;
    var has_images = false;
    for (content) |block| {
        switch (block) {
            .text => |text_block| {
                const trimmed = std.mem.trim(u8, text_block.text, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, text_block.text);
                has_text = true;
            },
            .image => has_images = true,
            .thinking => |thinking| {
                const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, thinking.thinking);
                has_text = true;
            },
            .tool_call => {},
        }
    }

    if (has_text) {
        var final = std.ArrayList(u8).empty;
        defer final.deinit(allocator);
        if (is_error) try final.appendSlice(allocator, "[tool error] ");
        try final.appendSlice(allocator, text.items);
        if (has_images and !supports_images) {
            try final.appendSlice(allocator, "\n");
            try final.appendSlice(allocator, TOOL_IMAGE_OMITTED_TEXT);
        }
        return final.toOwnedSlice(allocator);
    }

    if (has_images) {
        if (supports_images) {
            return allocator.dupe(u8, if (is_error) "[tool error] (see attached image)" else "(see attached image)");
        }
        return allocator.dupe(u8, if (is_error) "[tool error] (image omitted: model does not support images)" else TOOL_IMAGE_OMITTED_TEXT);
    }

    return allocator.dupe(u8, if (is_error) "[tool error] (no tool output)" else "(no tool output)");
}

fn appendTextDelta(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    next_content_index: *usize,
    delta: []const u8,
    is_thinking: bool,
) !void {
    if (current_block.* == null or !matchesCurrentBlock(current_block.*.?, is_thinking)) {
        try finishCurrentBlock(allocator, current_block, content_slots, stream_ptr);
        current_block.* = if (is_thinking)
            .{ .thinking = .{ .event_index = next_content_index.*, .text = std.ArrayList(u8).empty } }
        else
            .{ .text = .{ .event_index = next_content_index.*, .text = std.ArrayList(u8).empty } };
        stream_ptr.push(.{
            .event_type = if (is_thinking) .thinking_start else .text_start,
            .content_index = @intCast(next_content_index.*),
        });
        next_content_index.* += 1;
    }

    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text_block| {
                try text_block.text.appendSlice(allocator, delta);
                stream_ptr.push(.{
                    .event_type = .text_delta,
                    .content_index = @intCast(text_block.event_index),
                    .delta = try allocator.dupe(u8, delta),
                    .owns_delta = true,
                });
            },
            .thinking => |*thinking_block| {
                try thinking_block.text.appendSlice(allocator, delta);
                stream_ptr.push(.{
                    .event_type = .thinking_delta,
                    .content_index = @intCast(thinking_block.event_index),
                    .delta = try allocator.dupe(u8, delta),
                    .owns_delta = true,
                });
            },
        }
    }
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_slots: *std.ArrayList(?types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text_block| {
                const owned = try allocator.dupe(u8, text_block.text.items);
                try ensureContentSlotCapacity(allocator, content_slots, text_block.event_index);
                content_slots.items[text_block.event_index] = types.ContentBlock{ .text = .{ .text = owned } };
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(text_block.event_index),
                    .content = owned,
                });
            },
            .thinking => |*thinking_block| {
                const owned = try allocator.dupe(u8, thinking_block.text.items);
                try ensureContentSlotCapacity(allocator, content_slots, thinking_block.event_index);
                content_slots.items[thinking_block.event_index] = types.ContentBlock{ .thinking = .{
                    .thinking = owned,
                    .signature = null,
                    .redacted = false,
                } };
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(thinking_block.event_index),
                    .content = owned,
                });
            },
        }
        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn matchesCurrentBlock(block: CurrentBlock, is_thinking: bool) bool {
    return switch (block) {
        .text => !is_thinking,
        .thinking => is_thinking,
    };
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text_block| text_block.text.deinit(allocator),
        .thinking => |*thinking_block| thinking_block.text.deinit(allocator),
    }
}

fn findStreamingToolCall(
    tool_calls: *std.ArrayList(StreamingToolCall),
    id: []const u8,
    index: usize,
) ?*StreamingToolCall {
    for (tool_calls.items) |*tool_call| {
        if (tool_call.index == index and std.mem.eql(u8, tool_call.id.items, id)) return tool_call;
    }
    return null;
}

fn stringifyArgumentsDelta(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| allocator.dupe(u8, string),
        else => std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

fn extractThinkingText(allocator: std.mem.Allocator, item: std.json.Value) !?[]const u8 {
    const thinking_value = item.object.get("thinking") orelse return null;
    if (thinking_value != .array) return null;

    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    for (thinking_value.array.items) |entry| {
        if (entry != .object) continue;
        if (entry.object.get("text")) |text_value| {
            if (text_value == .string) {
                try text.appendSlice(allocator, text_value.string);
            }
        }
    }

    if (text.items.len == 0) return null;
    return try allocator.dupe(u8, text.items);
}

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (std.mem.trim(u8, input, " \t\r\n").len == 0) {
        return emptyJsonObject(allocator);
    }

    var parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return emptyJsonObject(allocator);
    };
    defer parsed.deinit();
    return provider_json.cloneValue(allocator, parsed.value);
}

fn deriveMistralToolCallId(allocator: std.mem.Allocator, id: []const u8, attempt: usize) ![]const u8 {
    var normalized = std.ArrayList(u8).empty;
    defer normalized.deinit(allocator);
    for (id) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try normalized.append(allocator, char);
        }
    }

    if (attempt == 0 and normalized.items.len == MISTRAL_TOOL_CALL_ID_LENGTH) {
        return allocator.dupe(u8, normalized.items);
    }

    const seed = if (attempt == 0)
        try allocator.dupe(u8, if (normalized.items.len > 0) normalized.items else id)
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ if (normalized.items.len > 0) normalized.items else id, attempt });
    defer allocator.free(seed);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &digest, .{});
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex[index * 2] = hexDigitLower(byte >> 4);
        hex[index * 2 + 1] = hexDigitLower(byte & 0x0f);
    }
    return allocator.dupe(u8, hex[0..MISTRAL_TOOL_CALL_ID_LENGTH]);
}

fn hexDigitLower(nibble: u8) u8 {
    return "0123456789abcdef"[nibble & 0x0f];
}

fn ensureContentSlotCapacity(
    allocator: std.mem.Allocator,
    content_slots: *std.ArrayList(?types.ContentBlock),
    index: usize,
) !void {
    while (content_slots.items.len <= index) {
        try content_slots.append(allocator, null);
    }
}

fn materializeContent(
    allocator: std.mem.Allocator,
    content_slots: []const ?types.ContentBlock,
) ![]const types.ContentBlock {
    const blocks = try allocator.alloc(types.ContentBlock, content_slots.len);
    for (content_slots, 0..) |maybe_block, index| {
        blocks[index] = if (maybe_block) |block| try cloneContentBlock(allocator, block) else .{ .text = .{ .text = "" } };
    }
    return blocks;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: types.ContentBlock) !types.ContentBlock {
    return switch (block) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
        .image => |image| .{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| .{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .thinking_signature = if (types.thinkingSignature(thinking)) |signature| try allocator.dupe(u8, signature) else null,
            .signature = if (types.thinkingSignature(thinking)) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
        .tool_call => |tool_call| .{ .tool_call = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try provider_json.cloneValue(allocator, tool_call.arguments),
            .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
    };
}

fn cloneToolCallsSlice(allocator: std.mem.Allocator, tool_calls: []const types.ToolCall) ![]const types.ToolCall {
    const owned = try allocator.alloc(types.ToolCall, tool_calls.len);
    for (tool_calls, 0..) |tool_call, index| {
        owned[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try provider_json.cloneValue(allocator, tool_call.arguments),
            .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
        };
    }
    return owned;
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;
    const pt = getJsonU32(usage_value.object.get("prompt_tokens"));
    const ct = getJsonU32(usage_value.object.get("completion_tokens"));
    const tt = getJsonU32(usage_value.object.get("total_tokens"));

    // Extract cached prompt tokens from various possible field locations.
    const cached = getMistralCachedPromptTokens(usage_value, pt);

    usage.input = if (pt > cached) pt - cached else 0;
    usage.output = ct;
    usage.cache_read = cached;
    usage.cache_write = 0;
    usage.total_tokens = if (tt > 0) tt else usage.input + ct + cached;
}

fn getMistralCachedPromptTokens(usage_value: std.json.Value, prompt_tokens: u32) u32 {
    // Try nested objects: promptTokensDetails.cachedTokens, prompt_tokens_details.cached_tokens, etc.
    const candidates = [_]struct { outer: []const u8, inner: []const u8 }{
        .{ .outer = "promptTokensDetails", .inner = "cachedTokens" },
        .{ .outer = "prompt_tokens_details", .inner = "cached_tokens" },
        .{ .outer = "promptTokenDetails", .inner = "cachedTokens" },
        .{ .outer = "prompt_token_details", .inner = "cached_tokens" },
    };
    for (candidates) |c| {
        if (usage_value.object.get(c.outer)) |outer| {
            if (outer == .object) {
                if (outer.object.get(c.inner)) |val| {
                    if (val == .integer) return @min(prompt_tokens, @as(u32, @intCast(val.integer)));
                }
            }
        }
    }
    // Try flat fields: numCachedTokens, num_cached_tokens.
    if (usage_value.object.get("numCachedTokens")) |val| {
        if (val == .integer) return @min(prompt_tokens, @as(u32, @intCast(val.integer)));
    }
    if (usage_value.object.get("num_cached_tokens")) |val| {
        if (val == .integer) return @min(prompt_tokens, @as(u32, @intCast(val.integer)));
    }
    return 0;
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

fn getJsonUsize(value: ?std.json.Value) usize {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    return abort_helper.isRequestedFromOptions(options);
}

fn emptyJsonObject(allocator: std.mem.Allocator) !std.json.Value {
    return provider_json.emptyObjectValue(allocator);
}

test "VAL-MSG-010 Mistral skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };
    const first_user = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const valid_assistant_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "I can call a valid tool" } },
        .{ .tool_call = .{ .id = "valid-tool", .name = "lookup", .arguments = .null } },
    };
    const failed_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "partial content must not replay" } },
        .{ .tool_call = .{ .id = "failed-tool", .name = "lookup", .arguments = .null } },
    };
    const tool_result_content = [_]types.ContentBlock{.{ .text = .{ .text = "valid result" } }};
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .user = .{ .content = &first_user, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &valid_assistant_content,
            .api = "mistral-conversations",
            .provider = "mistral",
            .model = "mistral-medium-latest",
            .usage = types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "mistral-conversations",
            .provider = "mistral",
            .model = "mistral-medium-latest",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 3,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "mistral-conversations",
            .provider = "mistral",
            .model = "mistral-medium-latest",
            .usage = types.Usage.init(),
            .stop_reason = .aborted,
            .error_message = "aborted",
            .timestamp = 4,
        } },
        .{ .tool_result = .{
            .tool_call_id = "valid-tool",
            .tool_name = "lookup",
            .content = &tool_result_content,
            .timestamp = 5,
        } },
        .{ .user = .{ .content = &final_user, .timestamp = 6 } },
    } }, null);
    defer provider_json.freeValue(allocator, payload);

    const messages = payload.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant", messages.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("tool", messages.items[2].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", messages.items[3].object.get("role").?.string);

    const assistant_tool_call = messages.items[1].object.get("tool_calls").?.array.items[0].object;
    const normalized_id = assistant_tool_call.get("id").?.string;
    try std.testing.expectEqualStrings(normalized_id, messages.items[2].object.get("tool_call_id").?.string);
}

test "buildRequestPayload includes tools and normalized tool ids" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    var tool_args = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_args.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });
    const tool_args_value = std.json.Value{ .object = tool_args };
    defer provider_json.freeValue(allocator, tool_args_value);

    const context = types.Context{
        .system_prompt = "Use tools if needed.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Inspect this image" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Calling tool" } },
                    .{ .thinking = .{ .thinking = "Need weather data", .signature = null, .redacted = false } },
                },
                .tool_calls = &[_]types.ToolCall{.{
                    .id = "call_with_very_long_non_mistral_id",
                    .name = "get_weather",
                    .arguments = tool_args_value,
                }},
                .api = "mistral-conversations",
                .provider = "mistral",
                .model = "mistral-medium-latest",
                .usage = types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 2,
            } },
            .{ .tool_result = .{
                .tool_call_id = "call_with_very_long_non_mistral_id",
                .tool_name = "get_weather",
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Sunny" } },
                },
                .timestamp = 3,
            } },
        },
        .tools = &[_]types.Tool{.{
            .name = "get_weather",
            .description = "Get weather",
            .parameters = tool_schema_value,
        }},
    };

    const model = types.Model{
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 131072,
        .max_tokens = 32768,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.4,
        .max_tokens = 2048,
        .provider = .{ .mistral = .{ .prompt_mode = "reasoning" } },
    });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings("mistral-medium-latest", payload.object.get("model").?.string);
    try std.testing.expect(payload.object.get("messages").? == .array);
    try std.testing.expect(payload.object.get("tools").? == .array);
    try std.testing.expectEqualStrings("reasoning", payload.object.get("prompt_mode").?.string);

    const messages = payload.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    const assistant_message = messages.items[2].object;
    const assistant_tool_call = assistant_message.get("tool_calls").?.array.items[0].object;
    const normalized_id = assistant_tool_call.get("id").?.string;
    try std.testing.expectEqual(@as(usize, MISTRAL_TOOL_CALL_ID_LENGTH), normalized_id.len);
    const tool_message = messages.items[3].object;
    try std.testing.expectEqualStrings(normalized_id, tool_message.get("tool_call_id").?.string);
}

test "buildRequestPayload preserves reasoning_effort and unsupported image placeholder" {
    const allocator = std.testing.allocator;

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
        },
    };

    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .provider = .{ .mistral = .{ .reasoning_effort = "high" } },
    });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings("high", payload.object.get("reasoning_effort").?.string);
    const user_message = payload.object.get("messages").?.array.items[0].object;
    const content = user_message.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings(IMAGE_OMITTED_TEXT, content.get("text").?.string);
}

test "parse stream emits text events and usage" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"resp_1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n" ++
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n" ++
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
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Hello", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), done.message.?.usage.output);
    try std.testing.expectEqualStrings("resp_1", done.message.?.response_id.?);
}

test "parse stream keeps Mistral canonical data-line strictness through shared SSE loop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "event: message\n" ++
            "data:{\"choices\":[{\"delta\":{\"content\":\"ignored compact\"}}]}\n" ++
            "data: {\"id\":\"resp_canonical\",\"choices\":[{\"delta\":{\"content\":\"canonical\"},\"finish_reason\":\"stop\"}]}\n" ++
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
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("canonical", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("canonical", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("resp_canonical", done.message.?.response_id.?);
    try std.testing.expect(stream_instance.next() == null);
}

test "parse stream emits thinking and tool call events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"content\":[{\"type\":\"thinking\",\"thinking\":[{\"type\":\"text\",\"text\":\"Need tool\"}]}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call-tool-1\",\"index\":0,\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call-tool-1\",\"index\":0,\"function\":{\"arguments\":\"\\\"Berlin\\\"}\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"content\":\"After tool\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":12,\"total_tokens\":32}}\n" ++
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
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const thinking_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_start, thinking_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_start.content_index.?);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_delta.content_index.?);
    try std.testing.expectEqualStrings("Need tool", thinking_delta.delta.?);
    const thinking_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_end.content_index.?);
    const tool_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta_one = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_one.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta_one.content_index.?);
    const tool_delta_two = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_two.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta_two.content_index.?);
    const text_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_start.content_index.?);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_delta.content_index.?);
    try std.testing.expectEqualStrings("After tool", text_delta.delta.?);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_end.content_index.?);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), done.message.?.content.len);
    try std.testing.expectEqualStrings("After tool", done.message.?.content[2].text.text);
    try std.testing.expectEqual(@as(u32, 20), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 12), done.message.?.usage.output);
}

test "mapStopReason handles tool calls and length" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("stop"));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason("model_length"));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReason("tool_calls"));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReason("error"));
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"mistral denied\",\"authorization\":\"Bearer sk-mistral-secret\",\"request_id\":\"req_mistral_random_123456\"},\"trace\":\"/Users/alice/pi/mistral.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 401, "Unauthorized", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
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

    var stream = try MistralProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 401: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "mistral denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-mistral-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_mistral_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("mistral-conversations", result.api);
}

test "stream preserves Mistral request headers and body through shared header helpers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try provider_error.TestCaptureServer.init(
        io,
        401,
        "Unauthorized",
        "",
        "{\"error\":{\"message\":\"provider smoke capture\"}}",
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("X-Model-Header", "model-value");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("X-Option-Header", "option-value");

    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
        .headers = model_headers,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "mistral capture prompt" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try MistralProvider.stream(allocator, io, model, context, .{
        .api_key = "mistral-smoke-key",
        .session_id = "mistral-session",
        .headers = option_headers,
    });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(stream.next() == null);

    try std.testing.expect(!server.request_head_truncated);
    try std.testing.expect(!server.request_body_truncated);
    const lower_head = try std.ascii.allocLowerString(allocator, server.requestHead());
    defer allocator.free(lower_head);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "post /chat/completions http/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\ncontent-type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\naccept: text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nauthorization: bearer mistral-smoke-key\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-affinity: mistral-session\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-model-header: model-value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-option-header: option-value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, server.requestBody(), "\"mistral capture prompt\"") != null);
}

const MistralOnResponseCapture = struct {
    var called: bool = false;
    var status: u16 = 0;

    fn reset() void {
        called = false;
        status = 0;
    }

    fn callback(response_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        called = true;
        status = response_status;
        try std.testing.expectEqualStrings("mistral-conversations", model.api);
        try std.testing.expect(headers.get("X-Fixture-Response") == null);
        try std.testing.expectEqualStrings("callback-fixture", headers.get("x-fixture-response").?);
    }
};

test "stream on_response receives normalized Mistral response headers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    MistralOnResponseCapture.reset();

    var server = try provider_error.TestStatusServer.init(
        io,
        429,
        "Too Many Requests",
        "X-Fixture-Response: callback-fixture\r\n",
        "{\"error\":{\"message\":\"rate limited\"}}",
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    var stream = try MistralProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .on_response = &MistralOnResponseCapture.callback,
    });
    defer stream.deinit();

    try std.testing.expect(MistralOnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 429), MistralOnResponseCapture.status);
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(stream.next() == null);
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

test "parseSseStreamLines preserves partial Mistral text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"mistral-runtime\",\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("mistral-conversations", "mistral"), null);

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
    try std.testing.expectEqualStrings("mistral-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseSseStreamLines finalizes Mistral text and tool call on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"mistral-eof\",\"choices\":[{\"delta\":{\"content\":\"before tool\"}}]}\n" ++
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_eof\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"query\\\":\\\"local\\\"}\"}}]}}]}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("mistral-conversations", "mistral"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);
    const text_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_delta.content_index.?);
    try std.testing.expectEqualStrings("before tool", text_delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);
    try std.testing.expectEqualStrings("before tool", text_end.content.?);

    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("local", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("mistral-eof", done.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expectEqualStrings("before tool", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("local", done.message.?.content[1].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial Mistral text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"id\":\"mistral-abort\",\"choices\":[{\"delta\":{\"content\":\"partial mistral\"},\"finish_reason\":null}]}\n",
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
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
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

    var stream = try MistralProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial mistral", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial mistral", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("mistral-abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial mistral", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "stream returns error_event when API key is empty" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
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
    var stream = try MistralProvider.stream(allocator, io, model, context, .{ .api_key = "" });
    defer stream.deinit();
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "No API key for provider: mistral") != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("mistral-conversations", event.message.?.api);
    try std.testing.expectEqualStrings("mistral", event.message.?.provider);
    try std.testing.expectEqualStrings("mistral-small-latest", event.message.?.model);
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
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
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
    // When options is null and no MISTRAL_API_KEY env var is set,
    // stream() must return a stream with error_event (not throw).
    var stream = try MistralProvider.stream(allocator, io, model, context, null);
    defer stream.deinit();
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "No API key for provider: mistral") != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("mistral-conversations", event.message.?.api);
    try std.testing.expectEqualStrings("mistral", event.message.?.provider);
    try std.testing.expectEqualStrings("mistral-small-latest", event.message.?.model);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    allocator.free(result.error_message.?);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const model = types.Model{
        .id = "mistral-small-latest",
        .name = "Mistral Small",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
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
    var stream = try MistralProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();
    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("mistral-conversations", error_event.message.?.api);
    try std.testing.expectEqualStrings("mistral", error_event.message.?.provider);
    try std.testing.expectEqualStrings("mistral-small-latest", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(error_event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}
