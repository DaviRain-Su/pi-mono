const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const finalize = @import("../shared/finalize.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const provider_json = @import("../shared/provider_json.zig");
const sse_loop = @import("../shared/sse_loop.zig");

const stop_reason_mod = @import("../shared/stop_reason.zig");
const test_stream_server = @import("test_stream_server.zig");

pub const GoogleProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("google-generative-ai", streamProduction);
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
        const callback_opt: ?*const fn (std.mem.Allocator, std.json.Value, types.Model) anyerror!?std.json.Value =
            if (options) |o| o.on_payload else null;

        const json_body = blk: {
            if (callback_opt) |callback| {
                var payload = try buildRequestPayload(allocator, model, context, options);
                defer provider_json.freeValue(allocator, payload);
                if (try callback(allocator, payload, model)) |replacement| {
                    provider_json.freeValue(allocator, payload);
                    payload = replacement;
                }
                break :blk try std.json.Stringify.valueAlloc(allocator, payload, .{});
            }
            break :blk try buildPayloadJsonBytes(allocator, model, context, options);
        };
        defer allocator.free(json_body);

        const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ model.base_url, model.id });
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer provider_stream.deinitOwnedHeaders(allocator, &headers);
        try provider_stream.putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try provider_stream.putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
        if (options) |stream_options| {
            if (stream_options.api_key) |api_key| {
                try provider_stream.putOwnedHeader(allocator, &headers, "x-goog-api-key", api_key);
            }
        }
        try provider_stream.mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try provider_stream.mergeHeaders(allocator, &headers, stream_options.headers);
        }

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try client.requestStreaming(.{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .timeout_ms = if (options) |stream_options| stream_options.timeout_ms orelse 0 else 0,
            .aborted = if (options) |stream_options| stream_options.signal else null,
        });
        defer response.deinit();

        if (options) |stream_options| {
            if (stream_options.on_response) |callback| {
                try provider_stream.invokeOnResponse(allocator, callback, response.status, response.response_headers, model);
            }
        }

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
// Declarative payload structs (Gemini-shaped).
// =============================================================================

const RequestPayload = struct {
    contents: []const Content,
    systemInstruction: ?SystemInstruction = null,
    generationConfig: GenerationConfig,
    tools: ?[]const ToolGroup = null,
    toolConfig: ?ToolConfig = null,
};

const SystemInstruction = struct {
    parts: []const TextOnlyPart,
};

const TextOnlyPart = struct { text: []const u8 };

const GenerationConfig = struct {
    temperature: ?f32 = null,
    maxOutputTokens: ?u32 = null,
    thinkingConfig: ?ThinkingConfig = null,
};

const ThinkingConfig = struct {
    includeThoughts: ?bool = null,
    thinkingBudget: ?i32 = null,
    thinkingLevel: ?[]const u8 = null,
};

const Content = struct {
    role: []const u8,
    parts: []const Part,
};

const Part = union(enum) {
    text: TextPart,
    thought: ThoughtPart,
    function_call: FunctionCallPart,
    image: ImagePart,
    function_response: FunctionResponsePart,

    pub fn jsonStringify(self: Part, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .text => |t| {
                try jw.objectField("text");
                try jw.write(t.text);
                if (t.thought_signature) |sig| if (sig.len > 0) {
                    try jw.objectField("thoughtSignature");
                    try jw.write(sig);
                };
            },
            .thought => |t| {
                try jw.objectField("thought");
                try jw.write(true);
                try jw.objectField("text");
                try jw.write(t.text);
                if (t.thought_signature) |sig| {
                    try jw.objectField("thoughtSignature");
                    try jw.write(sig);
                }
            },
            .function_call => |fc| {
                if (fc.thought_signature) |sig| {
                    try jw.objectField("thoughtSignature");
                    try jw.write(sig);
                }
                try jw.objectField("functionCall");
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(fc.name);
                try jw.objectField("args");
                try jw.write(fc.args);
                try jw.endObject();
            },
            .image => |i| {
                try jw.objectField("inlineData");
                try jw.beginObject();
                try jw.objectField("mimeType");
                try jw.write(i.mime_type);
                try jw.objectField("data");
                try jw.write(i.data);
                try jw.endObject();
            },
            .function_response => |fr| {
                try jw.objectField("functionResponse");
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(fr.name);
                try jw.objectField("response");
                try jw.beginObject();
                try jw.objectField(if (fr.is_error) "error" else "output");
                try jw.write(fr.response_text);
                try jw.endObject();
                if (fr.parts) |inner_parts| {
                    try jw.objectField("parts");
                    try jw.write(inner_parts);
                }
                try jw.endObject();
            },
        }
        try jw.endObject();
    }
};

const TextPart = struct { text: []const u8, thought_signature: ?[]const u8 = null };
const ThoughtPart = struct { text: []const u8, thought_signature: ?[]const u8 = null };
const FunctionCallPart = struct {
    name: []const u8,
    args: std.json.Value, // cloned
    thought_signature: ?[]const u8 = null,
};
const ImagePart = struct {
    mime_type: []const u8,
    data: []const u8,
};
const FunctionResponsePart = struct {
    name: []const u8,
    response_text: []const u8,
    is_error: bool,
    parts: ?[]const Part = null,
};

const ToolGroup = struct {
    functionDeclarations: []const ToolDeclaration,
};

const ToolDeclaration = struct {
    name: []const u8,
    description: []const u8,
    parametersJsonSchema: std.json.Value, // cloned
};

const ToolConfig = struct {
    functionCallingConfig: FunctionCallingConfig,
};

const FunctionCallingConfig = struct {
    mode: []const u8,
};

// =============================================================================
// OwnedPayload + builder.
// =============================================================================

const OwnedPayload = struct {
    allocator: std.mem.Allocator,
    payload: RequestPayload,
    contents_buf: []Content,
    system_parts_buf: ?[]TextOnlyPart,
    tool_groups_buf: ?[]ToolGroup,
    tool_decls_buf: ?[]ToolDeclaration,
    parts_lists: []const []Part,
    owned_strings: []const []const u8,
    owned_clones: []std.json.Value,

    fn deinit(self: OwnedPayload) void {
        self.allocator.free(self.contents_buf);
        if (self.system_parts_buf) |s| self.allocator.free(s);
        if (self.tool_groups_buf) |g| self.allocator.free(g);
        if (self.tool_decls_buf) |d| self.allocator.free(d);
        for (self.parts_lists) |list| self.allocator.free(list);
        self.allocator.free(self.parts_lists);
        for (self.owned_strings) |s| self.allocator.free(s);
        self.allocator.free(self.owned_strings);
        for (self.owned_clones) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_clones);
    }
};

const OwnedPayloadBuilder = struct {
    allocator: std.mem.Allocator,
    parts_lists: std.ArrayList([]Part) = .empty,
    owned_strings: std.ArrayList([]const u8) = .empty,
    owned_clones: std.ArrayList(std.json.Value) = .empty,

    fn deinit(self: *OwnedPayloadBuilder) void {
        for (self.parts_lists.items) |list| self.allocator.free(list);
        self.parts_lists.deinit(self.allocator);
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

    // Build contents (user/model/user-from-tool-result, optionally + image turn).
    var contents_list = std.ArrayList(Content).empty;
    errdefer contents_list.deinit(allocator);

    var index: usize = 0;
    while (index < context.messages.len) : (index += 1) {
        switch (context.messages[index]) {
            .user => |user| {
                const content = try buildUserContent(allocator, model, user, &builder);
                try contents_list.append(allocator, content);
            },
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    if (try buildAssistantContent(allocator, assistant, &builder)) |content| {
                        try contents_list.append(allocator, content);
                    }
                }
            },
            .tool_result => {
                const result = try buildToolResultContents(allocator, model, context.messages[index..], &builder);
                try contents_list.append(allocator, result.function_response_content);
                if (result.image_turn_content) |img_content| {
                    try contents_list.append(allocator, img_content);
                }
                index += result.consumed - 1;
            },
        }
    }

    const contents_buf = try contents_list.toOwnedSlice(allocator);
    errdefer allocator.free(contents_buf);

    // systemInstruction (single text part).
    var system_parts_buf: ?[]TextOnlyPart = null;
    var system_instruction: ?SystemInstruction = null;
    if (context.system_prompt) |system_prompt| {
        const parts = try allocator.alloc(TextOnlyPart, 1);
        errdefer allocator.free(parts);
        parts[0] = .{ .text = system_prompt };
        system_parts_buf = parts;
        system_instruction = .{ .parts = parts };
    }
    errdefer if (system_parts_buf) |p| allocator.free(p);

    // generationConfig (always present, even if all fields null → emits "{}").
    var generation_config = GenerationConfig{};
    if (options) |stream_options| {
        generation_config.temperature = stream_options.temperature;
        if (stream_options.max_tokens) |m| generation_config.maxOutputTokens = @intCast(m);
        const google_opts = stream_options.providerOptions("google");
        if (google_opts.thinking) |thinking| {
            if (model.reasoning) {
                var thinking_config = ThinkingConfig{};
                if (thinking.enabled) {
                    thinking_config.includeThoughts = true;
                    if (thinking.budget_tokens) |budget_tokens| {
                        thinking_config.thinkingBudget = @intCast(budget_tokens);
                    }
                    if (thinking.level) |level| {
                        thinking_config.thinkingLevel = level;
                    }
                } else {
                    thinking_config.thinkingBudget = 0;
                }
                generation_config.thinkingConfig = thinking_config;
            }
        }
    }

    // tools + toolConfig.
    var tool_groups_buf: ?[]ToolGroup = null;
    var tool_decls_buf: ?[]ToolDeclaration = null;
    var tool_config: ?ToolConfig = null;
    if (context.tools) |tools| if (tools.len > 0) {
        const decls = try allocator.alloc(ToolDeclaration, tools.len);
        errdefer allocator.free(decls);
        for (tools, 0..) |tool, i| {
            const params_clone = try provider_json.cloneValue(allocator, tool.parameters);
            try builder.owned_clones.append(allocator, params_clone);
            decls[i] = .{
                .name = tool.name,
                .description = tool.description,
                .parametersJsonSchema = params_clone,
            };
        }
        tool_decls_buf = decls;

        const groups = try allocator.alloc(ToolGroup, 1);
        errdefer allocator.free(groups);
        groups[0] = .{ .functionDeclarations = decls };
        tool_groups_buf = groups;

        if (options) |stream_options| {
            const google_opts = stream_options.providerOptions("google");
            if (google_opts.tool_choice) |tool_choice| {
                tool_config = .{ .functionCallingConfig = .{ .mode = mapToolChoice(tool_choice) } };
            }
        }
    };
    errdefer {
        if (tool_decls_buf) |d| allocator.free(d);
        if (tool_groups_buf) |g| allocator.free(g);
    }

    const parts_lists_slice = try builder.parts_lists.toOwnedSlice(allocator);
    const owned_strings_slice = try builder.owned_strings.toOwnedSlice(allocator);
    const owned_clones_slice = try builder.owned_clones.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .payload = .{
            .contents = contents_buf,
            .systemInstruction = system_instruction,
            .generationConfig = generation_config,
            .tools = tool_groups_buf,
            .toolConfig = tool_config,
        },
        .contents_buf = contents_buf,
        .system_parts_buf = system_parts_buf,
        .tool_groups_buf = tool_groups_buf,
        .tool_decls_buf = tool_decls_buf,
        .parts_lists = parts_lists_slice,
        .owned_strings = owned_strings_slice,
        .owned_clones = owned_clones_slice,
    };
}

fn buildUserContent(
    allocator: std.mem.Allocator,
    model: types.Model,
    user: types.UserMessage,
    builder: *OwnedPayloadBuilder,
) !Content {
    const supports_images = modelSupportsImages(model);
    var parts = std.ArrayList(Part).empty;
    errdefer parts.deinit(allocator);

    var inserted_placeholder = false;
    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                try parts.append(allocator, .{ .text = .{ .text = text.text } });
                inserted_placeholder = false;
            },
            .image => |image| {
                if (supports_images) {
                    try parts.append(allocator, .{ .image = .{ .mime_type = image.mime_type, .data = image.data } });
                } else if (!inserted_placeholder) {
                    try parts.append(allocator, .{ .text = .{ .text = "(image omitted: model does not support images)" } });
                    inserted_placeholder = true;
                }
            },
            .thinking, .tool_call => {},
        }
    }

    if (parts.items.len == 0) {
        try parts.append(allocator, .{ .text = .{ .text = "" } });
    }

    const slice = try parts.toOwnedSlice(allocator);
    errdefer allocator.free(slice);
    try builder.parts_lists.append(allocator, slice);
    return .{ .role = "user", .parts = slice };
}

fn buildAssistantContent(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    builder: *OwnedPayloadBuilder,
) !?Content {
    var parts = std.ArrayList(Part).empty;
    errdefer parts.deinit(allocator);

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try parts.append(allocator, .{ .text = .{ .text = text.text, .thought_signature = text.text_signature } });
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                try parts.append(allocator, .{ .thought = .{
                    .text = thinking.thinking,
                    .thought_signature = types.thinkingSignature(thinking),
                } });
            },
            .image => {},
            .tool_call => |tool_call| {
                const args_clone = try provider_json.cloneValue(allocator, tool_call.arguments);
                try builder.owned_clones.append(allocator, args_clone);
                try parts.append(allocator, .{ .function_call = .{
                    .name = tool_call.name,
                    .args = args_clone,
                    .thought_signature = tool_call.thought_signature,
                } });
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
        if (assistant.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                const args_clone = try provider_json.cloneValue(allocator, tool_call.arguments);
                try builder.owned_clones.append(allocator, args_clone);
                try parts.append(allocator, .{ .function_call = .{
                    .name = tool_call.name,
                    .args = args_clone,
                    .thought_signature = tool_call.thought_signature,
                } });
            }
        }
    }

    if (parts.items.len == 0) return null;

    const slice = try parts.toOwnedSlice(allocator);
    errdefer allocator.free(slice);
    try builder.parts_lists.append(allocator, slice);
    return .{ .role = "model", .parts = slice };
}

const ToolResultContents = struct {
    function_response_content: Content,
    image_turn_content: ?Content,
    consumed: usize,
};

fn buildToolResultContents(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
    builder: *OwnedPayloadBuilder,
) !ToolResultContents {
    const supports_images = modelSupportsImages(model);
    const supports_multimodal_fn = supportsMultimodalFunctionResponse(model.id);

    var parts = std.ArrayList(Part).empty;
    errdefer parts.deinit(allocator);

    var image_parts = std.ArrayList(Part).empty;
    errdefer image_parts.deinit(allocator);

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                const text_response = try buildToolResultText(allocator, model, tool_result.content);
                try builder.owned_strings.append(allocator, text_response);

                var inner_image_parts: ?[]Part = null;
                if (supports_images and supports_multimodal_fn) {
                    if (try collectImageParts(allocator, tool_result.content, builder)) |inner| {
                        inner_image_parts = inner;
                    }
                }

                try parts.append(allocator, .{ .function_response = .{
                    .name = tool_result.tool_name,
                    .response_text = text_response,
                    .is_error = tool_result.is_error,
                    .parts = inner_image_parts,
                } });

                // Gemini < 3: images become a separate user turn.
                if (supports_images and !supports_multimodal_fn) {
                    for (tool_result.content) |block| {
                        if (block == .image) {
                            if (image_parts.items.len == 0) {
                                try image_parts.append(allocator, .{ .text = .{ .text = "Tool result image:" } });
                            }
                            try image_parts.append(allocator, .{ .image = .{
                                .mime_type = block.image.mime_type,
                                .data = block.image.data,
                            } });
                        }
                    }
                }
            },
            else => break,
        }
    }

    const parts_slice = try parts.toOwnedSlice(allocator);
    errdefer allocator.free(parts_slice);
    try builder.parts_lists.append(allocator, parts_slice);

    var image_turn_content: ?Content = null;
    if (image_parts.items.len > 0) {
        const img_slice = try image_parts.toOwnedSlice(allocator);
        errdefer allocator.free(img_slice);
        try builder.parts_lists.append(allocator, img_slice);
        image_turn_content = .{ .role = "user", .parts = img_slice };
    } else {
        image_parts.deinit(allocator);
    }

    return .{
        .function_response_content = .{ .role = "user", .parts = parts_slice },
        .image_turn_content = image_turn_content,
        .consumed = consumed,
    };
}

fn collectImageParts(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    builder: *OwnedPayloadBuilder,
) !?[]Part {
    var count: usize = 0;
    for (content) |block| {
        if (block == .image) count += 1;
    }
    if (count == 0) return null;
    const arr = try allocator.alloc(Part, count);
    errdefer allocator.free(arr);
    var i: usize = 0;
    for (content) |block| {
        if (block == .image) {
            arr[i] = .{ .image = .{ .mime_type = block.image.mime_type, .data = block.image.data } };
            i += 1;
        }
    }
    try builder.parts_lists.append(allocator, arr);
    return arr;
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

const CurrentBlock = union(enum) {
    text: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
};

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

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    var generated_tool_call_count: usize = 0;

    stream_ptr.push(.{ .event_type = .start });

    var handler = GoogleSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .current_block = &current_block,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .generated_tool_call_count = &generated_tool_call_count,
        .model = model,
    };
    const loop_result = try sse_loop.run(GoogleSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped) {
        return;
    }

    try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
    finalize.calculateCost(model, &output.usage);
    output.content = try content_blocks.toOwnedSlice(allocator);

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const GoogleSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    generated_tool_call_count: *usize,
    model: types.Model,

    pub fn extractDataLine(_: *GoogleSseLoopHandler, line: []const u8) ?[]const u8 {
        return provider_stream.parseCanonicalSseDataLine(line);
    }

    pub fn isDoneData(_: *GoogleSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *GoogleSseLoopHandler, data: []const u8) !bool {
        return try processGoogleSseData(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.current_block,
            self.content_blocks,
            self.tool_calls,
            self.generated_tool_call_count,
            self.model,
            data,
        );
    }

    pub fn handleRuntimeFailure(self: *GoogleSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.current_block,
            self.content_blocks,
            self.tool_calls,
            self.model,
            err,
        );
    }
};

fn processGoogleSseData(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    generated_tool_call_count: *usize,
    model: types.Model,
    data: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, stream_ptr, output, current_block, content_blocks, tool_calls, model, err);
            return false;
        },
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return true;
    if (value.object.get("responseId")) |response_id| {
        if (response_id == .string and output.response_id == null) {
            output.response_id = try allocator.dupe(u8, response_id.string);
        }
    }
    if (value.object.get("usageMetadata")) |usage_metadata| {
        updateUsage(&output.usage, usage_metadata);
        finalize.calculateCost(model, &output.usage);
    }
    const candidates_value = value.object.get("candidates") orelse return true;
    if (candidates_value != .array or candidates_value.array.items.len == 0) return true;
    const candidate = candidates_value.array.items[0];
    if (candidate != .object) return true;
    if (candidate.object.get("content")) |content_value| {
        if (content_value == .object) {
            if (content_value.object.get("parts")) |parts_value| {
                if (parts_value == .array) {
                    for (parts_value.array.items) |part| {
                        if (part != .object) continue;

                        if (part.object.get("text")) |text_value| {
                            if (text_value == .string and text_value.string.len > 0) {
                                const is_thinking = if (part.object.get("thought")) |thought_value|
                                    thought_value == .bool and thought_value.bool
                                else
                                    false;

                                if (current_block.* == null or !matchesCurrentBlock(current_block.*.?, is_thinking)) {
                                    try finishCurrentBlock(allocator, current_block, content_blocks, stream_ptr);
                                    current_block.* = if (is_thinking)
                                        .{ .thinking = .{ .text = std.ArrayList(u8).empty, .signature = null } }
                                    else
                                        .{ .text = .{ .text = std.ArrayList(u8).empty, .signature = null } };
                                    stream_ptr.push(.{
                                        .event_type = if (is_thinking) .thinking_start else .text_start,
                                        .content_index = @intCast(content_blocks.items.len),
                                    });
                                }

                                if (current_block.*) |*block| {
                                    switch (block.*) {
                                        .text => |*text| {
                                            try text.text.appendSlice(allocator, text_value.string);
                                            if (part.object.get("thoughtSignature")) |signature_value| {
                                                if (signature_value == .string and signature_value.string.len > 0) {
                                                    if (text.signature) |existing| allocator.free(existing);
                                                    text.signature = try allocator.dupe(u8, signature_value.string);
                                                }
                                            }
                                        },
                                        .thinking => |*thinking| {
                                            try thinking.text.appendSlice(allocator, text_value.string);
                                            if (part.object.get("thoughtSignature")) |signature_value| {
                                                if (signature_value == .string and signature_value.string.len > 0) {
                                                    if (thinking.signature) |existing| allocator.free(existing);
                                                    thinking.signature = try allocator.dupe(u8, signature_value.string);
                                                }
                                            }
                                        },
                                    }
                                }

                                stream_ptr.push(.{
                                    .event_type = if (is_thinking) .thinking_delta else .text_delta,
                                    .content_index = @intCast(content_blocks.items.len),
                                    .delta = try allocator.dupe(u8, text_value.string),
                                    .owns_delta = true,
                                });
                            }
                        }

                        if (part.object.get("functionCall")) |function_call_value| {
                            if (function_call_value == .object) {
                                try finishCurrentBlock(allocator, current_block, content_blocks, stream_ptr);
                                const name_value = function_call_value.object.get("name");
                                if (name_value == null or name_value.? != .string) continue;

                                const args = if (function_call_value.object.get("args")) |args_value|
                                    try provider_json.cloneValue(allocator, args_value)
                                else
                                    try emptyJsonObject(allocator);

                                const tool_call_id = blk: {
                                    if (function_call_value.object.get("id")) |id_value| {
                                        if (id_value == .string and id_value.string.len > 0) {
                                            var collides = false;
                                            for (content_blocks.items) |existing_block| {
                                                if (existing_block == .tool_call and std.mem.eql(u8, existing_block.tool_call.id, id_value.string)) {
                                                    collides = true;
                                                    break;
                                                }
                                            }
                                            if (!collides) break :blk try allocator.dupe(u8, id_value.string);
                                        }
                                    }
                                    break :blk try generateToolCallId(allocator, generated_tool_call_count);
                                };

                                const thought_signature = if (part.object.get("thoughtSignature")) |signature_value|
                                    if (signature_value == .string and signature_value.string.len > 0) try allocator.dupe(u8, signature_value.string) else null
                                else
                                    null;

                                const tool_call = types.ToolCall{
                                    .id = tool_call_id,
                                    .name = try allocator.dupe(u8, name_value.?.string),
                                    .arguments = args,
                                    .thought_signature = thought_signature,
                                };
                                try content_blocks.append(allocator, .{ .tool_call = tool_call });
                                const content_index = content_blocks.items.len - 1;
                                try tool_calls.append(allocator, content_blocks.items[content_index].tool_call);

                                stream_ptr.push(.{
                                    .event_type = .toolcall_start,
                                    .content_index = @intCast(content_index),
                                });

                                const args_json = try std.json.Stringify.valueAlloc(allocator, args, .{});
                                defer allocator.free(args_json);
                                stream_ptr.push(.{
                                    .event_type = .toolcall_delta,
                                    .content_index = @intCast(content_index),
                                    .delta = try allocator.dupe(u8, args_json),
                                    .owns_delta = true,
                                });
                                stream_ptr.push(.{
                                    .event_type = .toolcall_end,
                                    .content_index = @intCast(content_index),
                                    .tool_call = content_blocks.items[content_index].tool_call,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    if (candidate.object.get("finishReason")) |finish_reason| {
        if (finish_reason == .string) {
            output.stop_reason = if (tool_calls.items.len > 0) .tool_use else mapStopReason(finish_reason.string);
        }
    }

    return true;
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    _: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
) !void {
    try finishCurrentBlock(allocator, current_block, content_blocks, stream_ptr);
    finalize.calculateCost(model, &output.usage);
    if (output.content.len == 0 and content_blocks.items.len > 0) {
        output.content = try content_blocks.toOwnedSlice(allocator);
    }
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, content_blocks, tool_calls, stream_ptr, model);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn matchesCurrentBlock(block: CurrentBlock, is_thinking: bool) bool {
    return switch (block) {
        .text => !is_thinking,
        .thinking => is_thinking,
    };
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.text.items);
                const signature = if (text.signature) |value| try allocator.dupe(u8, value) else null;
                try content_blocks.append(allocator, .{ .text = .{
                    .text = owned,
                    .text_signature = signature,
                } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = owned,
                });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value| try allocator.dupe(u8, value) else null;
                try content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = owned,
                    .signature = signature,
                    .redacted = false,
                } });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = owned,
                });
            },
        }
        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| {
            text.text.deinit(allocator);
            if (text.signature) |signature| allocator.free(signature);
        },
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
    }
}

/// Returns the Gemini major version from a model ID, e.g. "gemini-2.5-pro" → 2,
/// "gemini-live-3.0-pro" → 3. Returns null for non-Gemini models.
fn getGeminiMajorVersion(model_id: []const u8) ?u32 {
    var buf: [128]u8 = undefined;
    const len = @min(model_id.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..len], model_id[0..len]);

    const rest: []const u8 = if (std.mem.startsWith(u8, lower, "gemini-live-"))
        lower["gemini-live-".len..]
    else if (std.mem.startsWith(u8, lower, "gemini-"))
        lower["gemini-".len..]
    else
        return null;

    if (rest.len == 0 or !std.ascii.isDigit(rest[0])) return null;
    var n: u32 = 0;
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
        n = n * 10 + (rest[i] - '0');
    }
    return n;
}

/// Mirrors TS supportsMultimodalFunctionResponse: Gemini 3+ and non-Gemini models
/// keep image inlineData inside functionResponse.parts. Gemini < 3 requires a
/// separate user turn for images.
fn supportsMultimodalFunctionResponse(model_id: []const u8) bool {
    if (getGeminiMajorVersion(model_id)) |version| {
        return version >= 3;
    }
    return true;
}

fn buildToolResultText(
    allocator: std.mem.Allocator,
    model: types.Model,
    content: []const types.ContentBlock,
) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var has_images = false;
    var has_text = false;
    for (content) |block| {
        switch (block) {
            .text => |text_block| {
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, text_block.text);
                has_text = true;
            },
            .image => has_images = true,
            .thinking => |thinking| {
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, thinking.thinking);
                has_text = true;
            },
            .tool_call => {},
        }
    }

    if (!has_text and has_images and modelSupportsImages(model)) {
        try text.appendSlice(allocator, "(see attached image)");
    }

    return try allocator.dupe(u8, text.items);
}

fn mapToolChoice(tool_choice: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(tool_choice, "none")) return "NONE";
    if (std.ascii.eqlIgnoreCase(tool_choice, "any")) return "ANY";
    return "AUTO";
}

fn mapStopReason(reason: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.google_mappings, reason, .error_reason);
}

fn generateToolCallId(allocator: std.mem.Allocator, counter: *usize) ![]const u8 {
    counter.* += 1;
    return try std.fmt.allocPrint(allocator, "google-call-{d}", .{counter.*});
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn emptyJsonObject(allocator: std.mem.Allocator) !std.json.Value {
    return provider_json.emptyObjectValue(allocator);
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;

    const prompt_tokens = getJsonU32(usage_value.object.get("promptTokenCount"));
    const cached_tokens = getJsonU32(usage_value.object.get("cachedContentTokenCount"));
    const candidate_tokens = getJsonU32(usage_value.object.get("candidatesTokenCount"));
    const thought_tokens = getJsonU32(usage_value.object.get("thoughtsTokenCount"));
    const total_tokens = getJsonU32(usage_value.object.get("totalTokenCount"));

    usage.input = prompt_tokens -| cached_tokens;
    usage.output = candidate_tokens + thought_tokens;
    usage.cache_read = cached_tokens;
    usage.cache_write = 0;
    usage.total_tokens = if (total_tokens > 0) total_tokens else usage.input + usage.output + usage.cache_read;
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

test "VAL-MSG-010 Google skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };
    const first_user = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const failed_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "partial", .text_signature = "failed-text-sig" } },
        .{ .tool_call = .{ .id = "failed-tool", .name = "lookup", .arguments = .null, .thought_signature = "failed-tool-sig" } },
    };
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .user = .{ .content = &first_user, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "google-generative-ai",
            .provider = "google",
            .model = "gemini-2.5-pro",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "google-generative-ai",
            .provider = "google",
            .model = "gemini-2.5-pro",
            .usage = types.Usage.init(),
            .stop_reason = .aborted,
            .error_message = "aborted",
            .timestamp = 3,
        } },
        .{ .user = .{ .content = &final_user, .timestamp = 4 } },
    } }, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?.array;
    try std.testing.expectEqual(@as(usize, 2), contents.items.len);
    try std.testing.expectEqualStrings("user", contents.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", contents.items[1].object.get("role").?.string);
}

test "buildRequestPayload includes contents, tools, generation config, and thinking config" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "get_weather",
        .description = "Get the weather",
        .parameters = tool_schema_value,
    }};

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Describe this image" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
        },
        .tools = tools,
    };

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.5,
        .max_tokens = 2048,
        .provider = .{ .google = .{
            .tool_choice = "any",
            .thinking = .{
                .enabled = true,
                .budget_tokens = 8192,
            },
        } },
    });
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?;
    try std.testing.expect(contents == .array);
    try std.testing.expectEqual(@as(usize, 1), contents.array.items.len);

    const user_message = contents.array.items[0];
    try std.testing.expect(user_message == .object);
    try std.testing.expectEqualStrings("user", user_message.object.get("role").?.string);

    const parts = user_message.object.get("parts").?;
    try std.testing.expect(parts == .array);
    try std.testing.expectEqual(@as(usize, 2), parts.array.items.len);
    try std.testing.expect(parts.array.items[1].object.get("inlineData") != null);

    const system_instruction = payload.object.get("systemInstruction").?;
    try std.testing.expect(system_instruction == .object);
    try std.testing.expect(system_instruction.object.get("parts") != null);

    const generation_config = payload.object.get("generationConfig").?;
    try std.testing.expect(generation_config == .object);
    try std.testing.expectEqual(@as(i64, 2048), generation_config.object.get("maxOutputTokens").?.integer);
    try std.testing.expect(generation_config.object.get("thinkingConfig") != null);

    const tool_config = payload.object.get("toolConfig").?;
    try std.testing.expect(tool_config == .object);
    try std.testing.expectEqualStrings("ANY", tool_config.object.get("functionCallingConfig").?.object.get("mode").?.string);

    const payload_tools = payload.object.get("tools").?;
    try std.testing.expect(payload_tools == .array);
    try std.testing.expectEqual(@as(usize, 1), payload_tools.array.items.len);
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    if (value) |json_value| {
        if (json_value == .string) return json_value.string;
    }
    return null;
}

fn expectScenarioString(scenario: []const u8, expected: []const u8, actual: ?[]const u8) !void {
    if (actual) |actual_value| {
        if (std.mem.eql(u8, expected, actual_value)) return;
        std.debug.print("{s}: expected {s}, actual {s}\n", .{ scenario, expected, actual_value });
        return error.MessageSignatureFixtureMismatch;
    }
    std.debug.print("{s}: expected {s}, actual <null>\n", .{ scenario, expected });
    return error.MessageSignatureFixtureMismatch;
}

test "VAL-MSG-004 VAL-MSG-011 Google same-model request signature parity fixtures" {
    const allocator = std.testing.allocator;

    var tool_args = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_args.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });
    const tool_args_value = std.json.Value{ .object = tool_args };
    defer provider_json.freeValue(allocator, tool_args_value);

    const inline_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "signed text", .text_signature = "ts-text-sig" } },
        .{ .tool_call = .{
            .id = "inline-tool-1",
            .name = "get_weather",
            .arguments = tool_args_value,
            .thought_signature = "ts-tool-sig",
        } },
    };
    const legacy_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "legacy mirror" } },
    };
    const legacy_tool_calls = [_]types.ToolCall{.{
        .id = "legacy-tool-1",
        .name = "get_weather",
        .arguments = tool_args_value,
        .thought_signature = "ts-legacy-tool-sig",
    }};

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &inline_content,
                .api = "google-generative-ai",
                .provider = "google",
                .model = "gemini-2.5-pro",
                .usage = types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 2,
            } },
            .{ .assistant = .{
                .content = &legacy_content,
                .tool_calls = &legacy_tool_calls,
                .api = "google-generative-ai",
                .provider = "google",
                .model = "gemini-2.5-pro",
                .usage = types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 3,
            } },
        },
    };

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?.array;
    const inline_parts = contents.items[0].object.get("parts").?.array;
    const legacy_parts = contents.items[1].object.get("parts").?.array;

    try expectScenarioString(
        "VAL-MSG-004/google-inline-text-signature",
        "ts-text-sig",
        optionalString(inline_parts.items[0].object.get("thoughtSignature")),
    );
    try expectScenarioString(
        "VAL-MSG-004/google-inline-tool-signature",
        "ts-tool-sig",
        optionalString(inline_parts.items[1].object.get("thoughtSignature")),
    );
    try std.testing.expect(inline_parts.items[1].object.get("functionCall").?.object.get("thoughtSignature") == null);
    try expectScenarioString(
        "VAL-MSG-011/google-legacy-tool-signature-mirror",
        "ts-legacy-tool-sig",
        optionalString(legacy_parts.items[1].object.get("thoughtSignature")),
    );
    try std.testing.expect(legacy_parts.items[1].object.get("functionCall").?.object.get("thoughtSignature") == null);
}

test "buildRequestPayload converts assistant tool calls and tool results" {
    const allocator = std.testing.allocator;

    var tool_args = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_args.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });
    const tool_args_value = std.json.Value{ .object = tool_args };
    defer provider_json.freeValue(allocator, tool_args_value);

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{
                    .{ .thinking = .{ .thinking = "Need weather data", .signature = "c2ln", .redacted = false } },
                    .{ .text = .{ .text = "Calling tool" } },
                    .{ .tool_call = .{
                        .id = "tool-1",
                        .name = "get_weather",
                        .arguments = tool_args_value,
                        .thought_signature = "tool-thought-sig",
                    } },
                },
                .api = "google-generative-ai",
                .provider = "google",
                .model = "gemini-2.5-pro",
                .usage = types.Usage.init(),
                .stop_reason = .tool_use,
                .timestamp = 2,
            } },
            .{ .tool_result = .{
                .tool_call_id = "tool-1",
                .tool_name = "get_weather",
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Sunny" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 3,
            } },
        },
    };

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?;
    try std.testing.expect(contents == .array);
    // 3 items: assistant message, tool result user turn, separate image user turn (Gemini < 3)
    try std.testing.expectEqual(@as(usize, 3), contents.array.items.len);

    const assistant_message = contents.array.items[0];
    try std.testing.expectEqualStrings("model", assistant_message.object.get("role").?.string);
    const assistant_parts = assistant_message.object.get("parts").?.array;
    try std.testing.expectEqual(@as(usize, 3), assistant_parts.items.len);
    try std.testing.expect(assistant_parts.items[0].object.get("thought") != null);
    try std.testing.expect(assistant_parts.items[2].object.get("functionCall") != null);
    try std.testing.expectEqualStrings("tool-thought-sig", assistant_parts.items[2].object.get("thoughtSignature").?.string);
    try std.testing.expect(assistant_parts.items[2].object.get("functionCall").?.object.get("thoughtSignature") == null);

    // For gemini-2.5-pro (Gemini 2.x < 3), images go in a separate user turn.
    try std.testing.expectEqual(@as(usize, 3), contents.array.items.len);

    const tool_result_message = contents.array.items[1];
    try std.testing.expectEqualStrings("user", tool_result_message.object.get("role").?.string);
    const tool_result_parts = tool_result_message.object.get("parts").?.array;
    try std.testing.expectEqual(@as(usize, 1), tool_result_parts.items.len);
    const function_response = tool_result_parts.items[0].object.get("functionResponse").?;
    try std.testing.expect(function_response == .object);
    // Gemini 2.x does NOT put images inside functionResponse.parts
    try std.testing.expect(function_response.object.get("parts") == null);

    // Separate user turn for images (Gemini < 3 behavior)
    const image_turn = contents.array.items[2];
    try std.testing.expectEqualStrings("user", image_turn.object.get("role").?.string);
    const image_turn_parts = image_turn.object.get("parts").?.array;
    try std.testing.expect(image_turn_parts.items.len >= 2); // "Tool result image:" text + image
    try std.testing.expectEqualStrings("Tool result image:", image_turn_parts.items[0].object.get("text").?.string);
    try std.testing.expect(image_turn_parts.items[1].object.get("inlineData") != null);
}

test "parse stream emits text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"text-sig\",\"text\":\"Hello\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}\n" ++
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
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
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
    try std.testing.expectEqualStrings("text-sig", done.message.?.content[0].text.text_signature.?);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), done.message.?.usage.output);
}

test "parse stream regenerates duplicate functionCall ids" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"id\":\"dup-id\",\"name\":\"get_weather\",\"args\":{\"city\":\"Berlin\"}}},{\"functionCall\":{\"id\":\"dup-id\",\"name\":\"get_weather\",\"args\":{\"city\":\"Paris\"}}}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}\n" ++
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
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);

    const first_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, first_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), first_start.content_index.?);
    const first_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, first_delta.event_type);
    const first_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, first_end.event_type);
    try std.testing.expectEqualStrings("dup-id", first_end.tool_call.?.id);

    const second_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, second_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), second_start.content_index.?);
    const second_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, second_delta.event_type);
    const second_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, second_end.event_type);
    try std.testing.expect(!std.mem.eql(u8, "dup-id", second_end.tool_call.?.id));

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[0] == .tool_call);
    try std.testing.expect(done.message.?.content[1] == .tool_call);
    try std.testing.expectEqualStrings("dup-id", done.message.?.content[0].tool_call.id);
    try std.testing.expect(!std.mem.eql(u8, "dup-id", done.message.?.content[1].tool_call.id));
}
test "parse stream emits thinking and tool call events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"Need tool\"},{\"thoughtSignature\":\"tool-sig\",\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Berlin\"}}},{\"text\":\"It is sunny.\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"cachedContentTokenCount\":2,\"candidatesTokenCount\":7,\"thoughtsTokenCount\":3,\"totalTokenCount\":30}}\n" ++
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
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
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
    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta.delta.?, "Berlin") != null);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    const text_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_start.content_index.?);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_delta.content_index.?);
    try std.testing.expectEqualStrings("It is sunny.", text_delta.delta.?);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), text_end.content_index.?);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[1] == .tool_call);
    try std.testing.expectEqualStrings("tool-sig", done.message.?.content[1].tool_call.thought_signature.?);
    try std.testing.expectEqualStrings("It is sunny.", done.message.?.content[2].text.text);
    try std.testing.expect(done.message.?.tool_calls == null);
    try std.testing.expectEqual(@as(u32, 18), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.output);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body = "{\"error\":{\"message\":\"permission denied\",\"x-goog-api-key\":\"AIza-google-secret\",\"request_id\":\"req_google_random_123456\"},\"trace\":\"/Users/alice/pi/google.zig\"}";
    var server = try provider_error.TestStatusServer.init(io, 403, "Forbidden", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try GoogleProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 403: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "permission denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "AIza-google-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_google_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("google-generative-ai", result.api);
}

test "stream preserves Google request headers and body through shared header helpers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try provider_error.TestCaptureServer.init(
        io,
        403,
        "Forbidden",
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
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
        .headers = model_headers,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "google capture prompt" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try GoogleProvider.stream(allocator, io, model, context, .{
        .api_key = "google-smoke-key",
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
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "post /models/gemini-2.5-flash:streamgeneratecontent?alt=sse http/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\ncontent-type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\naccept: text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-goog-api-key: google-smoke-key\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-model-header: model-value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-option-header: option-value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nauthorization:") == null);
    try std.testing.expect(std.mem.indexOf(u8, server.requestBody(), "\"google capture prompt\"") != null);
}

const GoogleOnResponseCapture = struct {
    var called: bool = false;
    var status: u16 = 0;

    fn reset() void {
        called = false;
        status = 0;
    }

    fn callback(response_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        called = true;
        status = response_status;
        try std.testing.expectEqualStrings("google-generative-ai", model.api);
        try std.testing.expect(headers.get("X-Fixture-Response") == null);
        try std.testing.expectEqualStrings("callback-fixture", headers.get("x-fixture-response").?);
    }
};

test "stream on_response receives normalized Google response headers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    GoogleOnResponseCapture.reset();

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
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    var stream = try GoogleProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .on_response = &GoogleOnResponseCapture.callback,
    });
    defer stream.deinit();

    try std.testing.expect(GoogleOnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 429), GoogleOnResponseCapture.status);
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines keeps Google canonical-only SSE data tolerance" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        ": keepalive\n" ++
            "event: content\n" ++
            "data:{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"compact-ignored\"}]}}]}\n" ++
            "\n" ++
            " data: {\"responseId\":\"google-canonical\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"canonical\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":4,\"totalTokenCount\":7}}\r\n" ++
            "data: [DONE]\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"after-done\"}]}}]}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-generative-ai", "google"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("canonical", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("canonical", text_end.content.?);
    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("google-canonical", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("canonical", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 3), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 4), done.message.?.usage.output);
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

test "parseSseStreamLines preserves partial Google text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"google-runtime\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-generate-content", "google"), null);

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
    try std.testing.expectEqualStrings("google-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseSseStreamLines finalizes partial Google text on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"google-eof\",\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"eof-sig\",\"text\":\"partial eof\"}]}}]}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-generative-ai", "google"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), delta.content_index.?);
    try std.testing.expectEqualStrings("partial eof", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);
    try std.testing.expectEqualStrings("partial eof", text_end.content.?);
    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("google-eof", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial eof", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("eof-sig", done.message.?.content[0].text.text_signature.?);
    try std.testing.expect(stream.next() == null);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const model = types.Model{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try GoogleProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("google-generative-ai", error_event.message.?.api);
    try std.testing.expectEqualStrings("google", error_event.message.?.provider);
    try std.testing.expectEqualStrings("gemini-2.5-flash", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(error_event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}

test "stream preserves partial Google text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"responseId\":\"google-abort\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial google\"}]}}]}\n",
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
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
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

    var stream = try GoogleProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial google", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial google", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("google-abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial google", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "VAL-MISC-004 buildGenerationConfigValue disabled thinking emits thinkingBudget 0 for reasoning model" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &.{} }, .{
        .provider = .{ .google = .{ .thinking = .{ .enabled = false } } },
    });
    defer provider_json.freeValue(allocator, payload);

    const gen_config = payload.object.get("generationConfig").?;
    const thinking_config = gen_config.object.get("thinkingConfig");
    try std.testing.expect(thinking_config != null);
    try std.testing.expect(thinking_config.? == .object);
    try std.testing.expectEqual(@as(i64, 0), thinking_config.?.object.get("thinkingBudget").?.integer);
    // includeThoughts must NOT be set when disabled
    try std.testing.expect(thinking_config.?.object.get("includeThoughts") == null);
}

test "VAL-MISC-004 buildGenerationConfigValue non-reasoning model omits thinkingConfig" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-2.0-flash",
        .name = "Gemini 2.0 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = false,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &.{} }, .{
        .provider = .{ .google = .{ .thinking = .{ .enabled = false } } },
    });
    defer provider_json.freeValue(allocator, payload);

    const gen_config = payload.object.get("generationConfig").?;
    // Non-reasoning model must not get thinkingConfig regardless of the option
    try std.testing.expect(gen_config.object.get("thinkingConfig") == null);
}

test "VAL-MISC-005 buildToolResultMessageValue Gemini 3 nests images inside functionResponse.parts" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-3.0-pro",
        .name = "Gemini 3.0 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const messages = [_]types.Message{
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "get_image",
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Here is the image" } },
                .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
            },
            .timestamp = 1,
        } },
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &messages }, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?.array;
    // Gemini 3+: no extra image turn — only the tool_result content
    try std.testing.expectEqual(@as(usize, 1), contents.items.len);

    const parts = contents.items[0].object.get("parts").?.array;
    try std.testing.expectEqual(@as(usize, 1), parts.items.len);
    const fn_response = parts.items[0].object.get("functionResponse").?;
    // Image must be inside functionResponse.parts
    const fn_parts = fn_response.object.get("parts");
    try std.testing.expect(fn_parts != null);
    try std.testing.expect(fn_parts.?.array.items.len > 0);
    try std.testing.expect(fn_parts.?.array.items[0].object.get("inlineData") != null);
}

test "VAL-MISC-005 buildToolResultMessageValue Gemini 2.x puts images in separate user turn" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const messages = [_]types.Message{
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "get_image",
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Here is the image" } },
                .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
            },
            .timestamp = 1,
        } },
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &messages }, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?.array;
    // Gemini 2.x: tool_result content + separate image-only user turn
    try std.testing.expectEqual(@as(usize, 2), contents.items.len);

    const fn_response = contents.items[0].object.get("parts").?.array.items[0].object.get("functionResponse").?;
    // No parts inside functionResponse for Gemini 2.x
    try std.testing.expect(fn_response.object.get("parts") == null);

    // Separate image turn has "Tool result image:" text + inlineData
    const img_turn_parts = contents.items[1].object.get("parts").?.array;
    try std.testing.expectEqualStrings("Tool result image:", img_turn_parts.items[0].object.get("text").?.string);
    try std.testing.expect(img_turn_parts.items[1].object.get("inlineData") != null);
}

test "VAL-MISC-005 non-Gemini model nests images inside functionResponse.parts" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "claude-3-5-sonnet",
        .name = "Claude 3.5 Sonnet",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://example.googleapis.com/v1beta",
        .reasoning = false,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const messages = [_]types.Message{
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "get_image",
            .content = &[_]types.ContentBlock{
                .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/jpeg" } },
            },
            .timestamp = 1,
        } },
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &messages }, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?.array;
    // Non-Gemini model: no separate image turns
    try std.testing.expectEqual(@as(usize, 1), contents.items.len);
    const fn_response = contents.items[0].object.get("parts").?.array.items[0].object.get("functionResponse").?;
    try std.testing.expect(fn_response.object.get("parts") != null);
}

test "VAL-MISC-005 model without image input_types omits images entirely" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-3.0-pro",
        .name = "Gemini 3.0 Pro",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"}, // no "image"
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const messages = [_]types.Message{
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "get_image",
            .content = &[_]types.ContentBlock{
                .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
            },
            .timestamp = 1,
        } },
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &messages }, null);
    defer provider_json.freeValue(allocator, payload);

    const contents = payload.object.get("contents").?.array;
    // No image turns and no parts in functionResponse
    try std.testing.expectEqual(@as(usize, 1), contents.items.len);
    const fn_response = contents.items[0].object.get("parts").?.array.items[0].object.get("functionResponse").?;
    try std.testing.expect(fn_response.object.get("parts") == null);
}

test "stream happy path unchanged after streamProduction refactor" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"totalTokenCount\":15}}\n" ++
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
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = "google-generative-ai",
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.com/v1beta",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
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
}
