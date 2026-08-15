const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const env_api_keys = @import("../env_api_keys.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const finalize = @import("../shared/finalize.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_json_put = @import("../shared/provider_json_put.zig");
const sse_loop = @import("../shared/sse_loop.zig");

const putBoolValue = provider_json_put.putBoolValue;
const putStringValue = provider_json_put.putStringValue;
const putIntegerValue = provider_json_put.putIntegerValue;
const putFloatValue = provider_json_put.putFloatValue;
const putObjectValue = provider_json_put.putObjectValue;
const stop_reason_mod = @import("../shared/stop_reason.zig");
const test_stream_server = @import("test_stream_server.zig");
const asn1 = std.crypto.codecs.asn1;

const DEFAULT_SCOPE = "https://www.googleapis.com/auth/cloud-platform";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const DEFAULT_VERTEX_ROOT = "https://{location}-aiplatform.googleapis.com/v1";
const DEFAULT_TOKEN_LIFETIME_SECS: i64 = 3600;
const AUTHENTICATED_SENTINEL = "<authenticated>";
const SHA256_DIGEST_INFO_PREFIX = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65,
    0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

const VertexProviderError = error{
    MissingGoogleVertexCredentials,
    MissingVertexProject,
    MissingVertexLocation,
    InvalidGoogleCredentials,
    UnsupportedGoogleCredentialsType,
    MissingGoogleRefreshToken,
    MissingGoogleClientId,
    MissingGoogleClientSecret,
    MissingGoogleClientEmail,
    MissingGooglePrivateKey,
    MissingGoogleTokenUri,
    InvalidPrivateKeyPem,
    InvalidPrivateKeyDer,
    InvalidTokenResponse,
    MissingAccessToken,
    OAuthTokenRequestFailed,
};

const OwnedHeader = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: OwnedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

const AuthorizedUserCredentials = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
    token_uri: []const u8,

    fn deinit(self: AuthorizedUserCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.refresh_token);
        allocator.free(self.token_uri);
    }
};

const ServiceAccountCredentials = struct {
    client_email: []const u8,
    private_key_pem: []const u8,
    token_uri: []const u8,
    project_id: ?[]const u8 = null,

    fn deinit(self: ServiceAccountCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.client_email);
        allocator.free(self.private_key_pem);
        allocator.free(self.token_uri);
        if (self.project_id) |project_id| allocator.free(project_id);
    }
};

const VertexAuth = union(enum) {
    api_key: []const u8,
    bearer_token: []const u8,
    authorized_user: AuthorizedUserCredentials,
    service_account: ServiceAccountCredentials,

    fn deinit(self: VertexAuth, allocator: std.mem.Allocator) void {
        switch (self) {
            .api_key => |value| allocator.free(value),
            .bearer_token => |value| allocator.free(value),
            .authorized_user => |value| value.deinit(allocator),
            .service_account => |value| value.deinit(allocator),
        }
    }
};

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

pub const GoogleVertexProvider = struct {
    pub const api = "google-vertex";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        const auth_header = resolveVertexAuthHeader(allocator, io, options) catch |err| {
            try provider_error.pushTerminalStreamError(allocator, &stream_instance, model, authErrorMessage(err));
            return stream_instance;
        };
        defer auth_header.deinit(allocator);

        try provider_stream.runSetupOrEmit(streamProduction, .{ allocator, io, model, context, options, &stream_instance, auth_header }, &stream_instance, model, options);
        return stream_instance;
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return stream(allocator, io, model, context, options);
    }

    fn streamProduction(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
        stream_instance: *event_stream.AssistantMessageEventStream,
        auth_header: OwnedHeader,
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

        const url = try buildRequestUrl(allocator, model);
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer provider_stream.deinitOwnedHeaders(allocator, &headers);
        try provider_stream.putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try provider_stream.putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
        try provider_stream.putOwnedHeader(allocator, &headers, auth_header.name, auth_header.value);
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
// Declarative payload structs (Vertex-shaped — same wire format as Gemini API,
// but Vertex always nests tool-result images inside functionResponse.parts and
// does not emit a separate "Tool result image:" user turn).
// =============================================================================

const RequestPayload = struct {
    contents: []const Content,
    systemInstruction: ?SystemInstruction = null,
    generationConfig: GenerationConfig,
    tools: ?[]const ToolGroup = null,
    toolConfig: ?ToolConfig = null,
};

const SystemInstruction = struct { parts: []const TextOnlyPart };
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
const ImagePart = struct { mime_type: []const u8, data: []const u8 };
const FunctionResponsePart = struct {
    name: []const u8,
    response_text: []const u8,
    is_error: bool,
    parts: ?[]const Part = null,
};

const ToolGroup = struct { functionDeclarations: []const ToolDeclaration };
const ToolDeclaration = struct {
    name: []const u8,
    description: []const u8,
    parametersJsonSchema: std.json.Value, // cloned
};
const ToolConfig = struct { functionCallingConfig: FunctionCallingConfig };
const FunctionCallingConfig = struct { mode: []const u8 };

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
                index += result.consumed - 1;
            },
        }
    }

    const contents_buf = try contents_list.toOwnedSlice(allocator);
    errdefer allocator.free(contents_buf);

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
    consumed: usize,
};

fn buildToolResultContents(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
    builder: *OwnedPayloadBuilder,
) !ToolResultContents {
    const supports_images = modelSupportsImages(model);

    var parts = std.ArrayList(Part).empty;
    errdefer parts.deinit(allocator);

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                const text_response = try buildToolResultText(allocator, model, tool_result.content);
                try builder.owned_strings.append(allocator, text_response);

                var inner_image_parts: ?[]Part = null;
                if (supports_images) {
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
            },
            else => break,
        }
    }

    const parts_slice = try parts.toOwnedSlice(allocator);
    errdefer allocator.free(parts_slice);
    try builder.parts_lists.append(allocator, parts_slice);

    return .{
        .function_response_content = .{ .role = "user", .parts = parts_slice },
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

fn buildRequestUrl(allocator: std.mem.Allocator, model: types.Model) ![]const u8 {
    const trimmed_base = std.mem.trim(u8, model.base_url, " \t\r\n");
    if (trimmed_base.len == 0) {
        const project = try resolveVertexProject(allocator, null);
        defer allocator.free(project);
        const location = try resolveVertexLocation(allocator, null);
        defer allocator.free(location);
        return try buildPublisherUrlFromRoot(allocator, DEFAULT_VERTEX_ROOT, project, location, model.id);
    }

    const resolved_base = try resolveLocationPlaceholder(allocator, trimmed_base);
    defer allocator.free(resolved_base);

    const base = trimTrailingSlash(resolved_base);
    if (std.mem.indexOf(u8, base, "/publishers/") != null) {
        if (std.mem.endsWith(u8, base, "/models")) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}:streamGenerateContent?alt=sse", .{ base, model.id });
        }
        return try std.fmt.allocPrint(allocator, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ base, model.id });
    }

    const project = try resolveVertexProject(allocator, base);
    defer allocator.free(project);
    const location = try resolveVertexLocation(allocator, base);
    defer allocator.free(location);
    return try buildPublisherUrlFromRoot(allocator, base, project, location, model.id);
}

fn buildPublisherUrlFromRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    project: []const u8,
    location: []const u8,
    model_id: []const u8,
) ![]const u8 {
    const normalized_root = trimTrailingSlash(root);
    const with_location = if (std.mem.indexOf(u8, normalized_root, "{location}") != null)
        try std.mem.replaceOwned(u8, allocator, normalized_root, "{location}", location)
    else
        try allocator.dupe(u8, normalized_root);
    defer allocator.free(with_location);

    const effective_root = if (pathHasApiVersion(with_location))
        with_location
    else
        try std.fmt.allocPrint(allocator, "{s}/v1", .{with_location});
    defer if (effective_root.ptr != with_location.ptr) allocator.free(effective_root);

    return try std.fmt.allocPrint(
        allocator,
        "{s}/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent?alt=sse",
        .{ trimTrailingSlash(effective_root), project, location, model_id },
    );
}

fn resolveVertexAuthHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ?types.StreamOptions,
) !OwnedHeader {
    const provided = if (options) |stream_options| stream_options.api_key else null;

    var env_auth: ?[]u8 = null;
    defer if (env_auth) |value| allocator.free(value);
    if (provided == null) {
        env_auth = try env_api_keys.getEnvApiKey(allocator, "google-vertex");
    }

    const adc_json: ?[]u8 = try loadApplicationDefaultCredentials(allocator, io);
    defer if (adc_json) |value| allocator.free(value);

    const auth = try resolveCredentialsFromInputs(allocator, io, provided, env_auth, adc_json);
    defer auth.deinit(allocator);

    return switch (auth) {
        .api_key => |api_key| .{
            .name = try allocator.dupe(u8, "x-goog-api-key"),
            .value = try allocator.dupe(u8, api_key),
        },
        .bearer_token => |token| .{
            .name = try allocator.dupe(u8, "Authorization"),
            .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
        },
        .authorized_user => |credentials| blk: {
            const token = try fetchAuthorizedUserAccessToken(allocator, io, credentials);
            defer allocator.free(token);
            break :blk .{
                .name = try allocator.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
            };
        },
        .service_account => |credentials| blk: {
            const token = try fetchServiceAccountAccessToken(allocator, io, credentials);
            defer allocator.free(token);
            break :blk .{
                .name = try allocator.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
            };
        },
    };
}

fn resolveCredentialsFromInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    provided_auth: ?[]const u8,
    env_auth: ?[]const u8,
    adc_json: ?[]const u8,
) !VertexAuth {
    if (provided_auth) |value| {
        if (try parseProvidedCredentialSpec(allocator, io, value, adc_json)) |auth| return auth;
    }

    if (env_auth) |value| {
        if (try parseProvidedCredentialSpec(allocator, io, value, adc_json)) |auth| return auth;
    }

    if (adc_json) |json| return try parseCredentialJson(allocator, json);
    return VertexProviderError.MissingGoogleVertexCredentials;
}

fn parseProvidedCredentialSpec(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw_value: []const u8,
    adc_json: ?[]const u8,
) !?VertexAuth {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, AUTHENTICATED_SENTINEL)) {
        if (adc_json) |json| return try parseCredentialJson(allocator, json);
        return VertexProviderError.MissingGoogleVertexCredentials;
    }
    if (std.mem.startsWith(u8, trimmed, "Bearer ")) {
        return .{ .bearer_token = try allocator.dupe(u8, std.mem.trim(u8, trimmed["Bearer ".len..], " \t\r\n")) };
    }
    if (trimmed[0] == '{') return try parseCredentialJson(allocator, trimmed);
    if (try maybeReadCredentialFile(allocator, io, trimmed)) |contents| {
        defer allocator.free(contents);
        return try parseCredentialJson(allocator, contents);
    }
    return .{ .api_key = try allocator.dupe(u8, trimmed) };
}

fn parseCredentialJson(allocator: std.mem.Allocator, json_text: []const u8) !VertexAuth {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return VertexProviderError.InvalidGoogleCredentials;
    defer parsed.deinit();

    const value = parsed.value;
    if (value != .object) return VertexProviderError.InvalidGoogleCredentials;

    const type_value = if (value.object.get("type")) |field|
        if (field == .string) field.string else null
    else
        null;

    if (std.mem.eql(u8, type_value orelse "", "authorized_user") or
        (value.object.get("refresh_token") != null and value.object.get("client_id") != null))
    {
        return .{ .authorized_user = .{
            .client_id = try duplicateRequiredJsonString(allocator, value, "client_id", VertexProviderError.MissingGoogleClientId),
            .client_secret = try duplicateRequiredJsonString(allocator, value, "client_secret", VertexProviderError.MissingGoogleClientSecret),
            .refresh_token = try duplicateRequiredJsonString(allocator, value, "refresh_token", VertexProviderError.MissingGoogleRefreshToken),
            .token_uri = try duplicateOptionalJsonStringOrDefault(allocator, value, "token_uri", DEFAULT_TOKEN_URI),
        } };
    }

    if (std.mem.eql(u8, type_value orelse "", "service_account") or
        (value.object.get("client_email") != null and value.object.get("private_key") != null))
    {
        return .{ .service_account = .{
            .client_email = try duplicateRequiredJsonString(allocator, value, "client_email", VertexProviderError.MissingGoogleClientEmail),
            .private_key_pem = try duplicateRequiredJsonString(allocator, value, "private_key", VertexProviderError.MissingGooglePrivateKey),
            .token_uri = try duplicateOptionalJsonStringOrDefault(allocator, value, "token_uri", DEFAULT_TOKEN_URI),
            .project_id = if (value.object.get("project_id")) |project_id|
                if (project_id == .string and project_id.string.len > 0) try allocator.dupe(u8, project_id.string) else null
            else
                null,
        } };
    }

    return VertexProviderError.UnsupportedGoogleCredentialsType;
}

fn duplicateRequiredJsonString(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    comptime err: anytype,
) ![]const u8 {
    const field = value.object.get(key) orelse return err;
    if (field != .string or std.mem.trim(u8, field.string, " \t\r\n").len == 0) return err;
    return try allocator.dupe(u8, field.string);
}

fn duplicateOptionalJsonStringOrDefault(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    default_value: []const u8,
) ![]const u8 {
    if (value.object.get(key)) |field| {
        if (field == .string and field.string.len > 0) return try allocator.dupe(u8, field.string);
    }
    return try allocator.dupe(u8, default_value);
}

fn fetchAuthorizedUserAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: AuthorizedUserCredentials,
) ![]const u8 {
    const body = try buildAuthorizedUserTokenRequestBody(allocator, credentials);
    defer allocator.free(body);
    return try fetchOAuthAccessToken(allocator, io, credentials.token_uri, body);
}

fn fetchServiceAccountAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: ServiceAccountCredentials,
) ![]const u8 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    const issued_at: i64 = @intCast(now.sec);
    const assertion = try buildServiceAccountAssertion(allocator, credentials, issued_at);
    defer allocator.free(assertion);

    const body = try buildServiceAccountTokenRequestBody(allocator, assertion);
    defer allocator.free(body);
    return try fetchOAuthAccessToken(allocator, io, credentials.token_uri, body);
}

fn fetchOAuthAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_uri: []const u8,
    body: []const u8,
) ![]const u8 {
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);
    try provider_stream.putOwnedHeader(allocator, &headers, "Content-Type", "application/x-www-form-urlencoded");
    try provider_stream.putOwnedHeader(allocator, &headers, "Accept", "application/json");

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = try client.request(.{
        .method = .POST,
        .url = token_uri,
        .headers = headers,
        .body = body,
    });
    defer response.deinit();

    if (response.status != 200) return VertexProviderError.OAuthTokenRequestFailed;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return VertexProviderError.InvalidTokenResponse;
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return VertexProviderError.InvalidTokenResponse;
    const access_token = value.object.get("access_token") orelse return VertexProviderError.MissingAccessToken;
    if (access_token != .string or access_token.string.len == 0) return VertexProviderError.MissingAccessToken;
    return try allocator.dupe(u8, access_token.string);
}

fn buildAuthorizedUserTokenRequestBody(
    allocator: std.mem.Allocator,
    credentials: AuthorizedUserCredentials,
) ![]const u8 {
    const client_id = try formEncode(allocator, credentials.client_id);
    defer allocator.free(client_id);
    const client_secret = try formEncode(allocator, credentials.client_secret);
    defer allocator.free(client_secret);
    const refresh_token = try formEncode(allocator, credentials.refresh_token);
    defer allocator.free(refresh_token);

    return try std.fmt.allocPrint(
        allocator,
        "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
        .{ client_id, client_secret, refresh_token },
    );
}

fn buildServiceAccountTokenRequestBody(allocator: std.mem.Allocator, assertion: []const u8) ![]const u8 {
    const encoded_assertion = try formEncode(allocator, assertion);
    defer allocator.free(encoded_assertion);

    return try std.fmt.allocPrint(
        allocator,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
        .{encoded_assertion},
    );
}

fn buildServiceAccountAssertion(
    allocator: std.mem.Allocator,
    credentials: ServiceAccountCredentials,
    issued_at: i64,
) ![]const u8 {
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const expires_at = issued_at + DEFAULT_TOKEN_LIFETIME_SECS;
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"{s}\",\"sub\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ credentials.client_email, credentials.client_email, DEFAULT_SCOPE, credentials.token_uri, issued_at, expires_at },
    );
    defer allocator.free(payload_json);

    const encoded_header = try base64UrlEncodeAlloc(allocator, header_json);
    defer allocator.free(encoded_header);
    const encoded_payload = try base64UrlEncodeAlloc(allocator, payload_json);
    defer allocator.free(encoded_payload);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_header, encoded_payload });
    defer allocator.free(signing_input);

    const signature = try signRs256(allocator, credentials.private_key_pem, signing_input);
    defer allocator.free(signature);
    const encoded_signature = try base64UrlEncodeAlloc(allocator, signature);
    defer allocator.free(encoded_signature);

    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, encoded_signature });
}

fn signRs256(
    allocator: std.mem.Allocator,
    private_key_pem: []const u8,
    message: []const u8,
) ![]u8 {
    const private_key_der = try decodePemPrivateKey(allocator, private_key_pem);
    defer allocator.free(private_key_der);

    const key = try parsePkcs8RsaPrivateKey(private_key_der);
    const modulus_len = key.modulus.len;
    if (modulus_len < SHA256_DIGEST_INFO_PREFIX.len + std.crypto.hash.sha2.Sha256.digest_length + 11) {
        return VertexProviderError.InvalidPrivateKeyDer;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});

    const encoded = try allocator.alloc(u8, modulus_len);
    defer allocator.free(encoded);
    try encodePkcs1DigestInfo(encoded, &digest);

    const Uint = std.crypto.ff.Uint(4096);
    const Modulus = std.crypto.ff.Modulus(4096);
    const Fe = Modulus.Fe;

    const modulus_uint = try Uint.fromBytes(key.modulus, .big);
    const modulus = try Modulus.fromUint(modulus_uint);
    const message_fe = try Fe.fromBytes(modulus, encoded, .big);
    const private_exponent = try Fe.fromBytes(modulus, key.private_exponent, .big);
    const signature_fe = try modulus.pow(message_fe, private_exponent);

    const signature = try allocator.alloc(u8, modulus_len);
    try signature_fe.toBytes(signature, .big);
    return signature;
}

fn encodePkcs1DigestInfo(buffer: []u8, digest: *const [std.crypto.hash.sha2.Sha256.digest_length]u8) !void {
    const digest_info_len = SHA256_DIGEST_INFO_PREFIX.len + digest.len;
    const padding_len = buffer.len - digest_info_len - 3;
    buffer[0] = 0x00;
    buffer[1] = 0x01;
    @memset(buffer[2 .. 2 + padding_len], 0xff);
    buffer[2 + padding_len] = 0x00;
    @memcpy(buffer[3 + padding_len .. 3 + padding_len + SHA256_DIGEST_INFO_PREFIX.len], &SHA256_DIGEST_INFO_PREFIX);
    @memcpy(buffer[3 + padding_len + SHA256_DIGEST_INFO_PREFIX.len ..], digest);
}

fn decodePemPrivateKey(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin_marker = "-----BEGIN PRIVATE KEY-----";
    const end_marker = "-----END PRIVATE KEY-----";
    const begin = std.mem.indexOf(u8, pem, begin_marker) orelse return VertexProviderError.InvalidPrivateKeyPem;
    const end = std.mem.indexOf(u8, pem, end_marker) orelse return VertexProviderError.InvalidPrivateKeyPem;
    if (end <= begin) return VertexProviderError.InvalidPrivateKeyPem;

    var base64_data = std.ArrayList(u8).empty;
    defer base64_data.deinit(allocator);

    const body = pem[begin + begin_marker.len .. end];
    for (body) |char| {
        switch (char) {
            '\n', '\r', ' ', '\t' => {},
            else => try base64_data.append(allocator, char),
        }
    }

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64_data.items) catch return VertexProviderError.InvalidPrivateKeyPem;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, base64_data.items);
    return decoded;
}

fn parsePkcs8RsaPrivateKey(private_key_der: []const u8) !struct { modulus: []const u8, private_exponent: []const u8 } {
    const private_key_info = try asn1.Element.decode(private_key_der, 0);
    if (private_key_info.tag.number != .sequence) return VertexProviderError.InvalidPrivateKeyDer;

    var index = private_key_info.slice.start;
    const version = try asn1.Element.decode(private_key_der, index);
    if (version.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    index = version.slice.end;

    const algorithm = try asn1.Element.decode(private_key_der, index);
    if (algorithm.tag.number != .sequence) return VertexProviderError.InvalidPrivateKeyDer;
    index = algorithm.slice.end;

    const private_key = try asn1.Element.decode(private_key_der, index);
    if (private_key.tag.number != .octetstring) return VertexProviderError.InvalidPrivateKeyDer;

    const rsa_private_key = private_key.slice.view(private_key_der);
    const rsa_sequence = try asn1.Element.decode(rsa_private_key, 0);
    if (rsa_sequence.tag.number != .sequence) return VertexProviderError.InvalidPrivateKeyDer;

    var rsa_index = rsa_sequence.slice.start;
    const rsa_version = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (rsa_version.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    rsa_index = rsa_version.slice.end;

    const modulus = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (modulus.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    rsa_index = modulus.slice.end;

    const public_exponent = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (public_exponent.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    rsa_index = public_exponent.slice.end;

    const private_exponent = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (private_exponent.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;

    return .{
        .modulus = trimLeadingZeroBytes(modulus.slice.view(rsa_private_key)),
        .private_exponent = trimLeadingZeroBytes(private_exponent.slice.view(rsa_private_key)),
    };
}

fn trimLeadingZeroBytes(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index + 1 < bytes.len and bytes[index] == 0) : (index += 1) {}
    return bytes[index..];
}

fn base64UrlEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
}

fn formEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    for (raw) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
            try list.append(allocator, char);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, std.fmt.digitToChar(@intCast(char >> 4), .upper));
            try list.append(allocator, std.fmt.digitToChar(@intCast(char & 0x0f), .upper));
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn loadApplicationDefaultCredentials(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try loadEnvOptional(allocator, "GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        defer allocator.free(path);
        return try readFileAllocMaybe(allocator, io, path);
    }

    if (try loadEnvOptional(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const candidates = [_][]const u8{
            try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "gcloud", "application_default_credentials.json" }),
            try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Application Support", "gcloud", "application_default_credentials.json" }),
        };
        defer {
            for (candidates) |candidate| allocator.free(candidate);
        }

        for (candidates) |candidate| {
            if (try readFileAllocMaybe(allocator, io, candidate)) |contents| return contents;
        }
    }

    return null;
}

fn maybeReadCredentialFile(allocator: std.mem.Allocator, io: std.Io, spec: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, spec, '/') == null and
        std.mem.indexOfScalar(u8, spec, '\\') == null and
        !std.mem.endsWith(u8, spec, ".json"))
    {
        return null;
    }
    return try readFileAllocMaybe(allocator, io, spec);
}

fn readFileAllocMaybe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
}

fn resolveVertexProject(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    if (try loadEnvOptional(allocator, "GOOGLE_CLOUD_PROJECT")) |project| return project;
    if (try loadEnvOptional(allocator, "GCLOUD_PROJECT")) |project| return project;
    if (base_url) |url| {
        if (extractPathSegment(url, "/projects/")) |project| return try allocator.dupe(u8, project);
    }
    return VertexProviderError.MissingVertexProject;
}

fn resolveVertexLocation(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    if (try loadEnvOptional(allocator, "GOOGLE_CLOUD_LOCATION")) |location| return location;
    if (base_url) |url| {
        if (extractPathSegment(url, "/locations/")) |location| return try allocator.dupe(u8, location);
        if (extractHostPrefix(url, "-aiplatform.googleapis.com")) |location| return try allocator.dupe(u8, location);
    }
    return VertexProviderError.MissingVertexLocation;
}

fn resolveLocationPlaceholder(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, base_url, "{location}") == null) return try allocator.dupe(u8, base_url);
    const location = try resolveVertexLocation(allocator, base_url);
    defer allocator.free(location);
    return try std.mem.replaceOwned(u8, allocator, base_url, "{location}", location);
}

fn extractPathSegment(value: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, value, marker) orelse return null;
    const rest = value[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn extractHostPrefix(value: []const u8, suffix: []const u8) ?[]const u8 {
    const scheme_index = std.mem.indexOf(u8, value, "://") orelse return null;
    const host_start = scheme_index + 3;
    const host_and_path = value[host_start..];
    const host_end = std.mem.indexOfScalar(u8, host_and_path, '/') orelse host_and_path.len;
    const host = host_and_path[0..host_end];
    if (!std.mem.endsWith(u8, host, suffix)) return null;
    return host[0 .. host.len - suffix.len];
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

fn pathHasApiVersion(base_url: []const u8) bool {
    if (std.mem.indexOf(u8, base_url, "/v1/") != null) return true;
    if (std.mem.endsWith(u8, base_url, "/v1")) return true;
    if (std.mem.indexOf(u8, base_url, "/v1beta") != null) return true;
    return false;
}

const VertexSseParseState = struct {
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    current_block: *?CurrentBlock,
    generated_tool_call_count: *usize,
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
    var state = VertexSseParseState{
        .output = &output,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .current_block = &current_block,
        .generated_tool_call_count = &generated_tool_call_count,
    };

    stream_ptr.push(.{ .event_type = .start });

    var handler = VertexSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .state = &state,
        .model = model,
    };
    const loop_result = try sse_loop.run(VertexSseLoopHandler, &handler, streaming, options);
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

const VertexSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    state: *VertexSseParseState,
    model: types.Model,

    pub fn extractDataLine(_: *VertexSseLoopHandler, line: []const u8) ?[]const u8 {
        return provider_stream.parseCanonicalSseDataLine(line);
    }

    pub fn isDoneData(_: *VertexSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *VertexSseLoopHandler, data: []const u8) !bool {
        return try processVertexSseData(
            self.allocator,
            self.stream_ptr,
            self.state,
            self.model,
            data,
        );
    }

    pub fn handleRuntimeFailure(self: *VertexSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.state.output,
            self.state.current_block,
            self.state.content_blocks,
            self.state.tool_calls,
            self.model,
            err,
        );
    }
};

fn processVertexSseData(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    state: *VertexSseParseState,
    model: types.Model,
    data: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(
                allocator,
                stream_ptr,
                state.output,
                state.current_block,
                state.content_blocks,
                state.tool_calls,
                model,
                err,
            );
            return false;
        },
    };
    defer parsed.deinit();

    const value = parsed.value;
    if (value != .object) return true;
    try processVertexSseObject(allocator, state, stream_ptr, model, value.object);
    return true;
}

fn processVertexSseObject(
    allocator: std.mem.Allocator,
    state: *VertexSseParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    object: std.json.ObjectMap,
) !void {
    if (object.get("responseId")) |response_id| {
        if (response_id == .string and state.output.response_id == null) {
            state.output.response_id = try allocator.dupe(u8, response_id.string);
        }
    }

    if (object.get("usageMetadata")) |usage_metadata| {
        updateUsage(&state.output.usage, usage_metadata);
        finalize.calculateCost(model, &state.output.usage);
    }

    const candidates_value = object.get("candidates") orelse return;
    if (candidates_value != .array or candidates_value.array.items.len == 0) return;

    const candidate = candidates_value.array.items[0];
    if (candidate != .object) return;

    try processVertexCandidateContent(allocator, state, stream_ptr, candidate.object);

    if (candidate.object.get("finishReason")) |finish_reason| {
        if (finish_reason == .string) {
            state.output.stop_reason = if (state.tool_calls.items.len > 0) .tool_use else mapStopReason(finish_reason.string);
        }
    }
}

fn processVertexCandidateContent(
    allocator: std.mem.Allocator,
    state: *VertexSseParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    candidate: std.json.ObjectMap,
) !void {
    const content_value = candidate.get("content") orelse return;
    if (content_value != .object) return;
    const parts_value = content_value.object.get("parts") orelse return;
    if (parts_value != .array) return;

    for (parts_value.array.items) |part| {
        if (part != .object) continue;
        try processVertexTextPart(allocator, state, stream_ptr, part.object);
        try processVertexFunctionCallPart(allocator, state, stream_ptr, part.object);
    }
}

fn processVertexTextPart(
    allocator: std.mem.Allocator,
    state: *VertexSseParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    part: std.json.ObjectMap,
) !void {
    const text_value = part.get("text") orelse return;
    if (text_value != .string or text_value.string.len == 0) return;

    const is_thinking = if (part.get("thought")) |thought_value|
        thought_value == .bool and thought_value.bool
    else
        false;

    if (state.current_block.* == null or !matchesCurrentBlock(state.current_block.*.?, is_thinking)) {
        try finishCurrentBlock(allocator, state.current_block, state.content_blocks, stream_ptr);
        state.current_block.* = if (is_thinking)
            .{ .thinking = .{ .text = std.ArrayList(u8).empty, .signature = null } }
        else
            .{ .text = .{ .text = std.ArrayList(u8).empty, .signature = null } };
        stream_ptr.push(.{
            .event_type = if (is_thinking) .thinking_start else .text_start,
            .content_index = @intCast(state.content_blocks.items.len),
        });
    }

    try appendVertexTextPart(allocator, state.current_block, part, text_value.string);
    stream_ptr.push(.{
        .event_type = if (is_thinking) .thinking_delta else .text_delta,
        .content_index = @intCast(state.content_blocks.items.len),
        .delta = try allocator.dupe(u8, text_value.string),
        .owns_delta = true,
    });
}

fn appendVertexTextPart(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    part: std.json.ObjectMap,
    text_delta: []const u8,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |*text| {
                try text.text.appendSlice(allocator, text_delta);
                try replaceCurrentBlockSignature(allocator, part, &text.signature);
            },
            .thinking => |*thinking| {
                try thinking.text.appendSlice(allocator, text_delta);
                try replaceCurrentBlockSignature(allocator, part, &thinking.signature);
            },
        }
    }
}

fn replaceCurrentBlockSignature(
    allocator: std.mem.Allocator,
    part: std.json.ObjectMap,
    signature: *?[]const u8,
) !void {
    const signature_value = part.get("thoughtSignature") orelse return;
    if (signature_value != .string or signature_value.string.len == 0) return;
    if (signature.*) |existing| allocator.free(existing);
    signature.* = try allocator.dupe(u8, signature_value.string);
}

fn processVertexFunctionCallPart(
    allocator: std.mem.Allocator,
    state: *VertexSseParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    part: std.json.ObjectMap,
) !void {
    const function_call_value = part.get("functionCall") orelse return;
    if (function_call_value != .object) return;

    try finishCurrentBlock(allocator, state.current_block, state.content_blocks, stream_ptr);
    const name_value = function_call_value.object.get("name");
    if (name_value == null or name_value.? != .string) return;

    const args = if (function_call_value.object.get("args")) |args_value|
        try provider_json.cloneValue(allocator, args_value)
    else
        try emptyJsonObject(allocator);

    const tool_call_id = if (function_call_value.object.get("id")) |id_value|
        if (id_value == .string and id_value.string.len > 0) try allocator.dupe(u8, id_value.string) else try generateToolCallId(allocator, state.generated_tool_call_count)
    else
        try generateToolCallId(allocator, state.generated_tool_call_count);

    const thought_signature = if (part.get("thoughtSignature")) |signature_value|
        if (signature_value == .string and signature_value.string.len > 0) try allocator.dupe(u8, signature_value.string) else null
    else
        null;

    const tool_call = types.ToolCall{
        .id = tool_call_id,
        .name = try allocator.dupe(u8, name_value.?.string),
        .arguments = args,
        .thought_signature = thought_signature,
    };
    try state.content_blocks.append(allocator, .{ .tool_call = tool_call });

    const content_index = state.content_blocks.items.len - 1;
    try state.tool_calls.append(allocator, state.content_blocks.items[content_index].tool_call);
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
        .tool_call = state.content_blocks.items[content_index].tool_call,
    });
}

fn authErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingGoogleVertexCredentials => "Vertex AI requires GOOGLE_CLOUD_API_KEY or Application Default Credentials.",
        error.MissingVertexProject => "Vertex AI requires a project ID. Set GOOGLE_CLOUD_PROJECT or GCLOUD_PROJECT.",
        error.MissingVertexLocation => "Vertex AI requires a location. Set GOOGLE_CLOUD_LOCATION or encode it in the endpoint.",
        error.InvalidGoogleCredentials => "Vertex AI credentials are not valid JSON or use an unsupported schema.",
        error.UnsupportedGoogleCredentialsType => "Vertex AI credentials must be an authorized_user or service_account JSON file.",
        error.MissingGoogleRefreshToken => "Vertex AI authorized_user credentials are missing refresh_token.",
        error.MissingGoogleClientId => "Vertex AI authorized_user credentials are missing client_id.",
        error.MissingGoogleClientSecret => "Vertex AI authorized_user credentials are missing client_secret.",
        error.MissingGoogleClientEmail => "Vertex AI service account credentials are missing client_email.",
        error.MissingGooglePrivateKey => "Vertex AI service account credentials are missing private_key.",
        error.InvalidPrivateKeyPem, error.InvalidPrivateKeyDer => "Vertex AI service account private key could not be parsed.",
        error.OAuthTokenRequestFailed, error.InvalidTokenResponse, error.MissingAccessToken => "Vertex AI OAuth token exchange failed.",
        else => "Vertex AI authentication failed.",
    };
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
    return try std.fmt.allocPrint(allocator, "vertex-call-{d}", .{counter.*});
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

fn extractErrorMessage(body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return if (trimmed.len == 0) body else trimmed;
}

test "buildRequestPayload includes Vertex contents, tools, and thinking config" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try putStringValue(allocator, &tool_schema, "type", "object");
    try putObjectValue(allocator, &tool_schema, "properties", try provider_json.emptyObjectValue(allocator));
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
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
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

    try std.testing.expect(payload.object.get("contents") != null);
    try std.testing.expect(payload.object.get("systemInstruction") != null);
    try std.testing.expect(payload.object.get("tools") != null);
    try std.testing.expect(payload.object.get("toolConfig") != null);
    try std.testing.expect(payload.object.get("generationConfig") != null);
}

test "buildRequestUrl formats Vertex publisher endpoint" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const url = try buildRequestUrl(allocator, model);
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google/models/gemini-2.5-pro:streamGenerateContent?alt=sse",
        url,
    );
}

test "buildAuthorizedUserTokenRequestBody encodes refresh token grant" {
    const allocator = std.testing.allocator;
    const body = try buildAuthorizedUserTokenRequestBody(allocator, .{
        .client_id = "client-id",
        .client_secret = "client secret",
        .refresh_token = "refresh/token",
        .token_uri = DEFAULT_TOKEN_URI,
    });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "client_secret=client%20secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "refresh_token=refresh%2Ftoken") != null);
}

test "buildServiceAccountAssertion encodes a signed JWT" {
    const allocator = std.testing.allocator;

    const credentials = ServiceAccountCredentials{
        .client_email = "vertex-test@project.iam.gserviceaccount.com",
        .private_key_pem = "-----BEGIN PRIVATE KEY-----\n" ++
            "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAK/SEfVlRdzwgyBN\n" ++
            "UbxPuQ7NtfnaJgsbK+5rRa0qHQLKwpAsc0s3ZuT43vV1YbxPyYS044poIBwLmLs1\n" ++
            "/T9LSFeFNwyybUW5nVK1VGPO0woy82LoAjA46FmqEa4baaAu3f+Vq5jLWocmXI0w\n" ++
            "jLfSnje7C7nRVBY2kDwVS1/VHLNFAgMBAAECgYAb0f+pdsbhOOVmvRVL2MmNgBtl\n" ++
            "V5FhfIEtDqhNyDYi9PZoXcA4jKGpZX/SEyrN40odx4mhouxBw8v9A4P4+e6ON4hE\n" ++
            "wYrfJ5+LLTbT00CVvpP232eYj7L5NF9AcWoH/rIvs3SbIOoDrX0QA4J79TOIJVcs\n" ++
            "BWmV1hO23P9TxIXXGQJBANqoZ9qEloCnvhKhg+4vWIEZUCOULKcpEgZzG96RKiKZ\n" ++
            "tR7uooQuq0Vw6Hz0hZUxcUO3/27iGzy5X0MOu/FsFjsCQQDN2Ng+3HjZs3/hTcgt\n" ++
            "KGJ4r1RmXLvyO+AepWn7ahPG/d/5hSfo8GYixBuT+77pdCXiChQ6taPj1HguXNAI\n" ++
            "YkR/AkAo5crXAmmsErPohDFLAawKKZPls7dOZM4sSqdxz7ET27AW4weetaPvTxkN\n" ++
            "FidOKntG8UljkgMKLpn0zvK0S0U1AkBB2+cT9aYUwQFhLGmnSQx4YGA4f+MCFXYX\n" ++
            "WAUYk0/QktleE+Q4+vEynlvUdO8X8jlMoLzoK8VL12a8LqXAiPAxAkEAnZQ+rfph\n" ++
            "Br+fH6YFqGNfK1/QU0kis7YglMnydI1yo2/gfHfCK3mkAgPgdk7aQPPm//Dh/RYW\n" ++
            "oH//P8IEqjq+hQ==\n" ++
            "-----END PRIVATE KEY-----\n",
        .token_uri = DEFAULT_TOKEN_URI,
    };

    const assertion = try buildServiceAccountAssertion(allocator, credentials, 1_700_000_000);
    defer allocator.free(assertion);

    var parts = std.mem.splitScalar(u8, assertion, '.');
    try std.testing.expect(parts.next() != null);
    const payload_segment = parts.next().?;
    const signature_segment = parts.next().?;
    try std.testing.expect(parts.next() == null);
    try std.testing.expect(signature_segment.len > 0);

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment);

    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"iss\":\"vertex-test@project.iam.gserviceaccount.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"scope\":\"https://www.googleapis.com/auth/cloud-platform\"") != null);
}

test "resolveCredentialsFromInputs supports service account ADC and API key" {
    const allocator = std.testing.allocator;

    const service_account_json =
        "{\n" ++
        "  \"type\": \"service_account\",\n" ++
        "  \"project_id\": \"test-project\",\n" ++
        "  \"client_email\": \"vertex-test@project.iam.gserviceaccount.com\",\n" ++
        "  \"private_key\": \"-----BEGIN PRIVATE KEY-----\\nMIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAK/SEfVlRdzwgyBNUbxPuQ7NtfnaJgsbK+5rRa0qHQLKwpAsc0s3ZuT43vV1YbxPyYS044poIBwLmLs1/T9LSFeFNwyybUW5nVK1VGPO0woy82LoAjA46FmqEa4baaAu3f+Vq5jLWocmXI0wjLfSnje7C7nRVBY2kDwVS1/VHLNFAgMBAAECgYAb0f+pdsbhOOVmvRVL2MmNgBtlV5FhfIEtDqhNyDYi9PZoXcA4jKGpZX/SEyrN40odx4mhouxBw8v9A4P4+e6ON4hEwYrfJ5+LLTbT00CVvpP232eYj7L5NF9AcWoH/rIvs3SbIOoDrX0QA4J79TOIJVcsBWmV1hO23P9TxIXXGQJBANqoZ9qEloCnvhKhg+4vWIEZUCOULKcpEgZzG96RKiKZtR7uooQuq0Vw6Hz0hZUxcUO3/27iGzy5X0MOu/FsFjsCQQDN2Ng+3HjZs3/hTcgtKGJ4r1RmXLvyO+AepWn7ahPG/d/5hSfo8GYixBuT+77pdCXiChQ6taPj1HguXNAIYkR/AkAo5crXAmmsErPohDFLAawKKZPls7dOZM4sSqdxz7ET27AW4weetaPvTxkNFidOKntG8UljkgMKLpn0zvK0S0U1AkBB2+cT9aYUwQFhLGmnSQx4YGA4f+MCFXYXWAUYk0/QktleE+Q4+vEynlvUdO8X8jlMoLzoK8VL12a8LqXAiPAxAkEAnZQ+rfphBr+fH6YFqGNfK1/QU0kis7YglMnydI1yo2/gfHfCK3mkAgPgdk7aQPPm//Dh/RYWoH//P8IEqjq+hQ==\\n-----END PRIVATE KEY-----\\n\"\n" ++
        "}\n";

    var service_account = try resolveCredentialsFromInputs(allocator, std.Io.failing, null, AUTHENTICATED_SENTINEL, service_account_json);
    defer service_account.deinit(allocator);
    try std.testing.expect(service_account == .service_account);

    var api_key = try resolveCredentialsFromInputs(allocator, std.Io.failing, "vertex-api-key", null, null);
    defer api_key.deinit(allocator);
    try std.testing.expect(api_key == .api_key);
    try std.testing.expectEqualStrings("vertex-api-key", api_key.api_key);

    try std.testing.expectError(VertexProviderError.MissingGoogleVertexCredentials, resolveCredentialsFromInputs(allocator, std.Io.failing, null, null, null));
}

test "parse stream emits Vertex thinking, tool, and text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"resp-vertex\",\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"Need tool\",\"thoughtSignature\":\"c2ln\"},{\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Berlin\"}}},{\"text\":\"It is sunny.\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"cachedContentTokenCount\":2,\"candidatesTokenCount\":7,\"thoughtsTokenCount\":3,\"totalTokenCount\":30}}\n" ++
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
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
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
    const thinking_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_end.content_index.?);
    const tool_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);
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
    try std.testing.expectEqualStrings("resp-vertex", done.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 3), done.message.?.content.len);
    try std.testing.expectEqualStrings("It is sunny.", done.message.?.content[2].text.text);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"vertex denied\",\"x-goog-api-key\":\"AIza-vertex-secret\",\"request_id\":\"req_vertex_random_123456\"},\"trace\":\"/Users/alice/pi/google_vertex.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 403, "Forbidden", "", body.items);
    defer server.deinit();
    try server.start();

    const server_url = try server.url(allocator);
    defer allocator.free(server_url);
    const base_url = try std.fmt.allocPrint(allocator, "{s}/v1/projects/test-project/locations/us-central1/publishers/google", .{server_url});
    defer allocator.free(base_url);

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = base_url,
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

    var stream = try GoogleVertexProvider.stream(allocator, io, model, context, .{ .api_key = "vertex-api-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 403: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "vertex denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "AIza-vertex-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_vertex_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("google-vertex", result.api);
}

test "stream preserves Vertex request headers and body through shared header helpers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try provider_error.TestCaptureServer.init(
        io,
        403,
        "Forbidden",
        "",
        "{\"error\":{\"message\":\"vertex capture\"}}",
    );
    defer server.deinit();
    try server.start();

    const server_url = try server.url(allocator);
    defer allocator.free(server_url);
    const base_url = try std.fmt.allocPrint(allocator, "{s}/v1/projects/test-project/locations/us-central1/publishers/google", .{server_url});
    defer allocator.free(base_url);

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("X-Model-Header", "model-value");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("X-Option-Header", "option-value");

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
        .headers = model_headers,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "vertex capture prompt" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try GoogleVertexProvider.stream(allocator, io, model, context, .{
        .api_key = "vertex-smoke-key",
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
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "post /v1/projects/test-project/locations/us-central1/publishers/google/models/gemini-2.5-pro:streamgeneratecontent?alt=sse http/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\ncontent-type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\naccept: text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-goog-api-key: vertex-smoke-key\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-model-header: model-value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nx-option-header: option-value\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_head, "\r\nauthorization:") == null);
    try std.testing.expect(std.mem.indexOf(u8, server.requestBody(), "\"vertex capture prompt\"") != null);
}

const VertexOnResponseCapture = struct {
    var called: bool = false;
    var status: u16 = 0;

    fn reset() void {
        called = false;
        status = 0;
    }

    fn callback(response_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        called = true;
        status = response_status;
        try std.testing.expectEqualStrings("google-vertex", model.api);
        try std.testing.expect(headers.get("X-Fixture-Response") == null);
        try std.testing.expectEqualStrings("vertex-callback", headers.get("x-fixture-response").?);
    }
};

test "stream on_response receives normalized Vertex response headers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    VertexOnResponseCapture.reset();

    var server = try provider_error.TestStatusServer.init(
        io,
        429,
        "Too Many Requests",
        "X-Fixture-Response: vertex-callback\r\n",
        "{\"error\":{\"message\":\"rate limited\"}}",
    );
    defer server.deinit();
    try server.start();

    const server_url = try server.url(allocator);
    defer allocator.free(server_url);
    const base_url = try std.fmt.allocPrint(allocator, "{s}/v1/projects/test-project/locations/us-central1/publishers/google", .{server_url});
    defer allocator.free(base_url);

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    var stream = try GoogleVertexProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "vertex-smoke-key",
        .on_response = &VertexOnResponseCapture.callback,
    });
    defer stream.deinit();

    try std.testing.expect(VertexOnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 429), VertexOnResponseCapture.status);
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

test "parseSseStreamLines keeps Vertex canonical-only SSE data tolerance" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        ": keepalive\n" ++
            "event: content\n" ++
            "data:{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"compact-ignored\"}]}}]}\n" ++
            "\n" ++
            " data: {\"responseId\":\"vertex-canonical\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"canonical\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":6,\"candidatesTokenCount\":5,\"totalTokenCount\":11}}\r\n" ++
            "data: [DONE]\n" ++
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"after-done\"}]}}]}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-vertex", "google-vertex"), null);

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
    try std.testing.expectEqualStrings("vertex-canonical", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("canonical", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 6), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), done.message.?.usage.output);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines preserves partial Vertex text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"vertex-runtime\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-vertex-generate-content", "google-vertex"), null);

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
    try std.testing.expectEqualStrings("vertex-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseSseStreamLines finalizes partial Vertex text on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"vertex-eof\",\"candidates\":[{\"content\":{\"parts\":[{\"thoughtSignature\":\"vertex-eof-sig\",\"text\":\"partial vertex eof\"}]}}]}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-vertex", "google-vertex"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), delta.content_index.?);
    try std.testing.expectEqualStrings("partial vertex eof", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);
    try std.testing.expectEqualStrings("partial vertex eof", text_end.content.?);
    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("vertex-eof", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial vertex eof", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("vertex-eof-sig", done.message.?.content[0].text.text_signature.?);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial Vertex text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"responseId\":\"vertex-abort\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial vertex\"}]}}]}\n",
            .delay_after_ms = 1000,
        },
        .{ .bytes = "data: [DONE]\n" },
    };
    var server = try test_stream_server.DelayedChunkServer.init(io, &chunks);
    defer server.deinit();
    try server.start();

    const server_url = try server.url(allocator);
    defer allocator.free(server_url);
    const base_url = try std.fmt.allocPrint(allocator, "{s}/v1/projects/test-project/locations/us-central1/publishers/google", .{server_url});
    defer allocator.free(base_url);

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = base_url,
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

    var stream = try GoogleVertexProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "vertex-smoke-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial vertex", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial vertex", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("vertex-abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial vertex", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "stream returns error_event on non-auth setup failure instead of throwing" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "http://127.0.0.1:1/v1/projects/test-project/locations/us-central1/publishers/google",
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
    var stream = try GoogleVertexProvider.stream(allocator, io, model, context, .{ .api_key = "vertex-api-key" });
    defer stream.deinit();
    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("google-vertex", error_event.message.?.api);
    try std.testing.expectEqualStrings("google-vertex", error_event.message.?.provider);
    try std.testing.expectEqualStrings("gemini-2.5-pro", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(error_event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}

test "stream returns auth error when Google Vertex credentials are missing" {
    // VAL-STREAM-010: auth error path in stream() returns a stream with error_event
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
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

    // Pass options with empty api_key so env var lookup is skipped but no valid key is provided
    var stream = try GoogleVertexProvider.stream(allocator, io, model, context, .{ .api_key = "" });
    defer stream.deinit();

    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("google-vertex", error_event.message.?.api);
    try std.testing.expectEqualStrings("google-vertex", error_event.message.?.provider);
    try std.testing.expectEqualStrings("gemini-2.5-pro", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
}
