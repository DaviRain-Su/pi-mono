const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const event_stream = @import("../event_stream.zig");
const websocket_client = @import("../websocket_client.zig");
const abort_helper = @import("../shared/abort_signal.zig");
const diagnostics_helper = @import("../shared/diagnostics.zig");
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const finalize = @import("../shared/finalize.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_json_put = @import("../shared/provider_json_put.zig");
const provider_stream = @import("../shared/provider_stream.zig");

const putBoolValue = provider_json_put.putBoolValue;
const putStringValue = provider_json_put.putStringValue;
const putIntegerValue = provider_json_put.putIntegerValue;
const putFloatValue = provider_json_put.putFloatValue;
const putObjectValue = provider_json_put.putObjectValue;
const responses_api = @import("../shared/responses_api.zig");
const sse_loop = @import("../shared/sse_loop.zig");
const stop_reason_mod = @import("../shared/stop_reason.zig");
const openai_usage = @import("../shared/openai_usage.zig");
const openai = @import("openai.zig");
const openai_responses = @import("openai_responses.zig");
const test_stream_server = @import("test_stream_server.zig");
const test_websocket_server = @import("../shared/test_websocket_server.zig");

const DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api";
const DEFAULT_CODEX_SYSTEM_PROMPT = "You are a helpful assistant.";
const CODEX_AUTH_CLAIM = "https://api.openai.com/auth";

const CurrentBlock = responses_api.CurrentBlock;
const deinitCurrentBlock = responses_api.deinitCurrentBlock;
const extractReasoningSummary = responses_api.extractReasoningSummary;
const finalizeCurrentBlock = responses_api.finalizeCurrentBlock;
const updateCurrentMessagePart = responses_api.updateCurrentMessagePart;

const websocket_cache = @import("openai_codex_responses/websocket_cache.zig");

pub const isWebSocketSseFallbackActive = websocket_cache.isWebSocketSseFallbackActive;
pub const recordWebSocketFailure = websocket_cache.recordWebSocketFailure;
pub const resetWebSocketFallbackRegistry = websocket_cache.resetWebSocketFallbackRegistry;
pub const setWebSocketCacheNowOverrideForTesting = websocket_cache.setWebSocketCacheNowOverrideForTesting;
pub const hasCachedWebSocketSessionForTesting = websocket_cache.hasCachedWebSocketSessionForTesting;
pub const closeOpenAICodexWebSocketSessions = websocket_cache.closeOpenAICodexWebSocketSessions;

const SESSION_WEBSOCKET_CACHE_TTL_NS = websocket_cache.SESSION_WEBSOCKET_CACHE_TTL_NS;
const WebSocketCacheEntry = websocket_cache.Entry;
const CacheBusyState = websocket_cache.BusyState;
const isCodexNonTransportError = websocket_cache.isCodexNonTransportError;
const peekCacheBusyState = websocket_cache.peekCacheBusyState;
const acquireExistingEntry = websocket_cache.acquireExistingEntry;
const installCacheEntry = websocket_cache.installCacheEntry;
const releaseCacheEntry = websocket_cache.releaseCacheEntry;
const setEntryContinuation = websocket_cache.setEntryContinuation;
const clearEntryContinuation = websocket_cache.clearEntryContinuation;
const buildCachedWebSocketRequestBody = websocket_cache.buildCachedWebSocketRequestBody;

/// Refreshes the continuation snapshot on `entry` after a successful
/// response. `original_request_body` and `output` are NOT mutated. Returns
/// `OutOfMemory` if the snapshot cannot be allocated; on any other failure
/// the prior continuation is cleared.
fn updateCacheContinuation(
    allocator: std.mem.Allocator,
    entry: *WebSocketCacheEntry,
    original_request_body: std.json.Value,
    output: types.AssistantMessage,
) !void {
    const response_id = output.response_id orelse {
        // No response_id — clear any prior continuation; we can't chain.
        clearEntryContinuation(entry);
        return;
    };

    const entry_alloc = entry.allocator;
    const body_clone = try provider_json.cloneValue(entry_alloc, original_request_body);
    errdefer provider_json.freeValue(entry_alloc, body_clone);
    const id_owned = try entry_alloc.dupe(u8, response_id);
    errdefer entry_alloc.free(id_owned);

    var response_items = try buildResponseItemsForContinuation(allocator, output);
    // Items currently live in `allocator`; transfer to entry_alloc.
    var items_in_entry_alloc = std.json.Array.init(entry_alloc);
    errdefer {
        for (items_in_entry_alloc.items) |item| provider_json.freeValue(entry_alloc, item);
        items_in_entry_alloc.deinit();
    }
    for (response_items.items) |item| {
        const cloned = try provider_json.cloneValue(entry_alloc, item);
        errdefer provider_json.freeValue(entry_alloc, cloned);
        try items_in_entry_alloc.append(cloned);
    }
    // Free the temporary copies in `allocator`.
    for (response_items.items) |item| provider_json.freeValue(allocator, item);
    response_items.deinit();

    setEntryContinuation(entry, body_clone, id_owned, items_in_entry_alloc);
}

/// Builds the list of response items the server effectively emitted for
/// `output`, filtering out `function_call_output` items (which the server
/// expects the next request to re-supply as part of the delta input).
/// Returned array is owned by the caller.
fn buildResponseItemsForContinuation(
    allocator: std.mem.Allocator,
    output: types.AssistantMessage,
) !std.json.Array {
    var input = std.json.Array.init(allocator);
    errdefer {
        for (input.items) |item| provider_json.freeValue(allocator, item);
        input.deinit();
    }
    if (types.shouldReplayAssistantInProviderContext(output)) {
        // message_index = 0 is fine because we only use the items for
        // equality comparison; the synthesized `msg_0` id is stable.
        // Build via the struct path, then roundtrip the items to std.json.Value
        // so the downstream filter (which inspects .object/.string) still works.
        var builder = CodexBuilder{ .allocator = allocator };
        defer builder.deinit();
        var input_struct = std.ArrayList(CodexInputItem).empty;
        defer input_struct.deinit(allocator);
        try appendCodexAssistant(allocator, &input_struct, output, 0, &builder);
        for (input_struct.items) |item| {
            const bytes = try std.json.Stringify.valueAlloc(allocator, item, .{
                .emit_null_optional_fields = false,
            });
            defer allocator.free(bytes);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
            defer parsed.deinit();
            try input.append(try provider_json.cloneValue(allocator, parsed.value));
        }
    }
    // Filter out function_call_output (defensive — assistant outputs
    // shouldn't carry them, but the TS reference does the filter so we
    // mirror it exactly).
    var filtered = std.json.Array.init(allocator);
    errdefer {
        for (filtered.items) |item| provider_json.freeValue(allocator, item);
        filtered.deinit();
    }
    for (input.items) |item| {
        if (item == .object) {
            if (item.object.get("type")) |type_value| {
                if (type_value == .string and std.mem.eql(u8, type_value.string, "function_call_output")) {
                    provider_json.freeValue(allocator, item);
                    continue;
                }
            }
        }
        try filtered.append(item);
    }
    // `input` borrowed items into `filtered`; deinit only the array shell.
    input.deinit();
    input = filtered;
    return input;
}

/// Outcome of a single WebSocket attempt by `streamProductionAutoWebSocket`.
const WebSocketAttempt = union(enum) {
    /// The WebSocket completed normally and pushed a terminal `done` event.
    /// The caller must not attempt SSE fallback.
    done,
    /// The WebSocket attempt failed before any event reached the consumer.
    /// The caller may fall back to SSE.
    fallback: FallbackInfo,
    /// The WebSocket attempt failed after events were already pushed to the
    /// consumer. The caller must NOT fall back (would duplicate events) and
    /// must instead emit a terminal `error_event`.
    started_then_failed: FallbackInfo,
    /// The Codex server reported an application/protocol-level failure
    /// (`response.failed` / `error` event). The terminal error event was
    /// already pushed; the caller must NOT fall back.
    api_error,
    /// The caller's abort signal was set; the stream has been terminated.
    aborted,

    const FallbackInfo = struct {
        err: anyerror,
    };
};

pub const OpenAICodexResponsesProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("openai-codex-responses", streamProduction);
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
            const error_message = try std.fmt.allocPrint(allocator, "No API key for provider: {s}", .{model.provider});
            defer allocator.free(error_message);
            try provider_error.pushTerminalStreamError(allocator, stream_instance, model, error_message);
            return;
        }

        const api_key = resolved.?.key;

        const normalized_token = stripBearerPrefix(std.mem.trim(u8, api_key, " \t\r\n"));
        const account_id = extractAccountId(allocator, normalized_token) catch |err| {
            const error_message = try std.fmt.allocPrint(allocator, "Invalid Codex API key: {s}", .{@errorName(err)});
            defer allocator.free(error_message);
            try provider_error.pushTerminalStreamError(allocator, stream_instance, model, error_message);
            return;
        };
        defer allocator.free(account_id);

        var payload = try buildRequestPayload(allocator, model, context, options);
        defer provider_json.freeValue(allocator, payload);

        if (options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                const maybe_replacement = callback(allocator, payload, model) catch |err| {
                    const error_message = try std.fmt.allocPrint(allocator, "onPayload callback failed: {s}", .{@errorName(err)});
                    defer allocator.free(error_message);
                    try provider_error.pushTerminalStreamError(allocator, stream_instance, model, error_message);
                    return;
                };
                if (maybe_replacement) |replacement| {
                    provider_json.freeValue(allocator, payload);
                    payload = replacement;
                }
            }
        }

        const transport = if (options) |stream_options| stream_options.transport else .auto;
        if (transport == .websocket or transport == .websocket_cached) {
            try streamProductionWebSocket(
                allocator,
                io,
                model,
                options,
                normalized_token,
                account_id,
                payload,
                stream_instance,
            );
            return;
        }

        const session_id_for_registry: ?[]const u8 = if (options) |opts| opts.session_id else null;
        const ws_disabled_for_session = transport == .auto and
            isWebSocketSseFallbackActive(session_id_for_registry, io);

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        var fallback_diagnostic: ?types.AssistantMessageDiagnostic = null;
        defer if (fallback_diagnostic) |d| freeOwnedDiagnostic(allocator, d);

        if (transport == .auto and !ws_disabled_for_session) {
            const attempt = try runCodexWebSocketAttempt(
                allocator,
                io,
                model,
                options,
                normalized_token,
                account_id,
                payload,
                stream_instance,
                .auto,
            );
            switch (attempt) {
                .done, .aborted, .api_error, .started_then_failed => return,
                .fallback => |info| {
                    recordWebSocketFailure(session_id_for_registry, io);
                    fallback_diagnostic = buildTransportFailureDiagnostic(
                        allocator,
                        info.err,
                        false,
                        json_body.len,
                    ) catch null;
                    // Fall through to SSE attempt below.
                },
            }
        }

        const url = try resolveCodexUrl(allocator, model.base_url);
        defer allocator.free(url);

        var headers = try buildRequestHeaders(allocator, model, options, normalized_token, account_id, .sse);
        defer deinitOwnedHeaders(allocator, &headers);

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
                if (response.response_headers) |response_headers| {
                    callback(response.status, response_headers, model) catch |err| {
                        const error_message = try std.fmt.allocPrint(allocator, "onResponse callback failed: {s}", .{@errorName(err)});
                        defer allocator.free(error_message);
                        try provider_error.pushTerminalStreamError(allocator, stream_instance, model, error_message);
                        return;
                    };
                } else {
                    var response_headers = std.StringHashMap([]const u8).init(allocator);
                    defer response_headers.deinit();
                    callback(response.status, response_headers, model) catch |err| {
                        const error_message = try std.fmt.allocPrint(allocator, "onResponse callback failed: {s}", .{@errorName(err)});
                        defer allocator.free(error_message);
                        try provider_error.pushTerminalStreamError(allocator, stream_instance, model, error_message);
                        return;
                    };
                }
            }
        }

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, response.status, response_body);
            return;
        }

        const consumed_diagnostic = fallback_diagnostic;
        fallback_diagnostic = null;
        try parseSseStreamLinesWithDiagnostic(
            allocator,
            stream_instance,
            &response,
            model,
            options,
            consumed_diagnostic,
        );
    }
};

// =============================================================================
// Declarative payload structs for Codex Responses API.
// Differs from openai_responses: instructions string instead of system msg,
// always-on tool_choice/parallel_tool_calls/text.verbosity/include, no compat,
// no cache_retention, no normalized_tool_call_ids, simpler reasoning block.
// =============================================================================

const CodexRequestPayload = struct {
    model: []const u8,
    input: []const CodexInputItem,
    store: bool = false,
    stream: bool = true,
    tool_choice: []const u8 = "auto",
    parallel_tool_calls: bool = true,
    text: CodexTextConfig,
    include: []const []const u8,
    instructions: []const u8,
    temperature: ?f32 = null,
    service_tier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    reasoning: ?CodexReasoning = null,
    tools: ?[]const CodexToolItem = null,
};

const CodexTextConfig = struct { verbosity: []const u8 };
const CodexReasoning = struct { effort: []const u8, summary: []const u8 };
const CodexToolItem = struct {
    type: []const u8 = "function",
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value, // cloned
    strict: ?bool = null, // emitted as null in JSON

    pub fn jsonStringify(self: CodexToolItem, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("description");
        try jw.write(self.description);
        try jw.objectField("parameters");
        try jw.write(self.parameters);
        try jw.objectField("strict");
        try jw.write(@as(?bool, null));
        try jw.endObject();
    }
};

const CodexContentPart = union(enum) {
    input_text: struct { text: []const u8 },
    input_image: struct { image_url: []const u8 },

    pub fn jsonStringify(self: CodexContentPart, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .input_text => |t| {
                try jw.objectField("type");
                try jw.write("input_text");
                try jw.objectField("text");
                try jw.write(t.text);
            },
            .input_image => |i| {
                try jw.objectField("type");
                try jw.write("input_image");
                try jw.objectField("detail");
                try jw.write("auto");
                try jw.objectField("image_url");
                try jw.write(i.image_url);
            },
        }
        try jw.endObject();
    }
};

const CodexInputItem = union(enum) {
    user_message: struct { content: []const CodexContentPart },
    assistant_message: struct { id: []const u8, text: []const u8 },
    passthrough_value: std.json.Value,
    function_call: struct {
        call_id: []const u8,
        id: ?[]const u8,
        name: []const u8,
        arguments: []const u8, // pre-stringified JSON
    },
    function_call_output_text: struct { call_id: []const u8, output: []const u8 },
    function_call_output_parts: struct { call_id: []const u8, parts: []const CodexContentPart },

    pub fn jsonStringify(self: CodexInputItem, jw: anytype) !void {
        switch (self) {
            .user_message => |m| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("user");
                try jw.objectField("content");
                try jw.write(m.content);
                try jw.endObject();
            },
            .assistant_message => |m| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("message");
                try jw.objectField("role");
                try jw.write("assistant");
                try jw.objectField("status");
                try jw.write("completed");
                try jw.objectField("id");
                try jw.write(m.id);
                try jw.objectField("content");
                try jw.beginArray();
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("output_text");
                try jw.objectField("text");
                try jw.write(m.text);
                try jw.objectField("annotations");
                try jw.beginArray();
                try jw.endArray();
                try jw.endObject();
                try jw.endArray();
                try jw.endObject();
            },
            .passthrough_value => |v| try jw.write(v),
            .function_call => |fc| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call");
                try jw.objectField("call_id");
                try jw.write(fc.call_id);
                if (fc.id) |id| {
                    try jw.objectField("id");
                    try jw.write(id);
                }
                try jw.objectField("name");
                try jw.write(fc.name);
                try jw.objectField("arguments");
                try jw.write(fc.arguments);
                try jw.endObject();
            },
            .function_call_output_text => |out| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call_output");
                try jw.objectField("call_id");
                try jw.write(out.call_id);
                try jw.objectField("output");
                try jw.write(out.output);
                try jw.endObject();
            },
            .function_call_output_parts => |out| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call_output");
                try jw.objectField("call_id");
                try jw.write(out.call_id);
                try jw.objectField("output");
                try jw.write(out.parts);
                try jw.endObject();
            },
        }
    }
};

const CodexOwned = struct {
    allocator: std.mem.Allocator,
    payload: CodexRequestPayload,
    input_buf: []CodexInputItem,
    tools_buf: ?[]CodexToolItem,
    content_lists: []const []CodexContentPart,
    owned_strings: []const []const u8,
    owned_values: []std.json.Value,
    include_buf: [][]const u8,

    fn deinit(self: CodexOwned) void {
        self.allocator.free(self.input_buf);
        if (self.tools_buf) |b| self.allocator.free(b);
        for (self.content_lists) |list| self.allocator.free(list);
        self.allocator.free(self.content_lists);
        for (self.owned_strings) |s| self.allocator.free(s);
        self.allocator.free(self.owned_strings);
        for (self.owned_values) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_values);
        self.allocator.free(self.include_buf);
    }
};

const CodexBuilder = struct {
    allocator: std.mem.Allocator,
    content_lists: std.ArrayList([]CodexContentPart) = .empty,
    owned_strings: std.ArrayList([]const u8) = .empty,
    owned_values: std.ArrayList(std.json.Value) = .empty,

    fn deinit(self: *CodexBuilder) void {
        for (self.content_lists.items) |list| self.allocator.free(list);
        self.content_lists.deinit(self.allocator);
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
        for (self.owned_values.items) |v| provider_json.freeValue(self.allocator, v);
        self.owned_values.deinit(self.allocator);
    }
};

fn buildOwnedCodex(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !CodexOwned {
    var builder = CodexBuilder{ .allocator = allocator };
    errdefer builder.deinit();

    var input_list = std.ArrayList(CodexInputItem).empty;
    errdefer input_list.deinit(allocator);

    for (context.messages, 0..) |message, message_index| {
        try appendCodexInputItems(allocator, &input_list, model, message, message_index, &builder);
    }

    const input_buf = try input_list.toOwnedSlice(allocator);
    errdefer allocator.free(input_buf);

    var responses_opts = if (options) |stream_options| stream_options.providerOptions("responses") else types.ResponsesStreamOptions{};
    const verbosity = responses_opts.text_verbosity orelse "low";

    const raw_instructions = if (context.system_prompt) |system_prompt|
        if (system_prompt.len > 0) system_prompt else DEFAULT_CODEX_SYSTEM_PROMPT
    else
        DEFAULT_CODEX_SYSTEM_PROMPT;
    const instructions = try openai.sanitizeSurrogates(allocator, raw_instructions);
    try builder.owned_strings.append(allocator, instructions);

    var temperature: ?f32 = null;
    var service_tier: ?[]const u8 = null;
    var prompt_cache_key: ?[]const u8 = null;
    var reasoning: ?CodexReasoning = null;
    if (options) |stream_options| {
        responses_opts = stream_options.providerOptions("responses");
        temperature = stream_options.temperature;
        if (responses_opts.service_tier) |st| service_tier = st;
        if (stream_options.session_id) |sid| prompt_cache_key = sid;
        if (model.reasoning) {
            if (responses_opts.reasoning_effort) |re| {
                reasoning = .{
                    .effort = @tagName(re),
                    .summary = responses_opts.reasoning_summary orelse "auto",
                };
            }
        }
    }

    // include is always a single-element array.
    const include_buf = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(include_buf);
    include_buf[0] = "reasoning.encrypted_content";

    var tools_buf: ?[]CodexToolItem = null;
    if (context.tools) |tools| if (tools.len > 0) {
        const buf = try allocator.alloc(CodexToolItem, tools.len);
        errdefer allocator.free(buf);
        for (tools, 0..) |tool, i| {
            const params_clone = try provider_json.cloneValue(allocator, tool.parameters);
            try builder.owned_values.append(allocator, params_clone);
            buf[i] = .{
                .name = tool.name,
                .description = tool.description,
                .parameters = params_clone,
            };
        }
        tools_buf = buf;
    };
    errdefer if (tools_buf) |b| allocator.free(b);

    const content_lists_slice = try builder.content_lists.toOwnedSlice(allocator);
    const owned_strings_slice = try builder.owned_strings.toOwnedSlice(allocator);
    const owned_values_slice = try builder.owned_values.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .payload = .{
            .model = model.id,
            .input = input_buf,
            .text = .{ .verbosity = verbosity },
            .include = include_buf,
            .instructions = instructions,
            .temperature = temperature,
            .service_tier = service_tier,
            .prompt_cache_key = prompt_cache_key,
            .reasoning = reasoning,
            .tools = tools_buf,
        },
        .input_buf = input_buf,
        .tools_buf = tools_buf,
        .content_lists = content_lists_slice,
        .owned_strings = owned_strings_slice,
        .owned_values = owned_values_slice,
        .include_buf = include_buf,
    };
}

fn appendCodexInputItems(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(CodexInputItem),
    model: types.Model,
    message: types.Message,
    message_index: usize,
    builder: *CodexBuilder,
) !void {
    switch (message) {
        .user => |user| try appendCodexUser(allocator, input_list, model, user, builder),
        .assistant => |assistant| {
            if (types.shouldReplayAssistantInProviderContext(assistant)) {
                try appendCodexAssistant(allocator, input_list, assistant, message_index, builder);
            }
        },
        .tool_result => |tool_result| try appendCodexToolResult(allocator, input_list, model, tool_result, builder),
    }
}

fn appendCodexUser(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(CodexInputItem),
    model: types.Model,
    user: types.UserMessage,
    builder: *CodexBuilder,
) !void {
    const supports_images = modelSupportsImages(model);
    var parts = std.ArrayList(CodexContentPart).empty;
    errdefer parts.deinit(allocator);
    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                const sanitized = try openai.sanitizeSurrogates(allocator, text.text);
                try builder.owned_strings.append(allocator, sanitized);
                try parts.append(allocator, .{ .input_text = .{ .text = sanitized } });
            },
            .image => |image| {
                if (!supports_images) continue;
                const image_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                try builder.owned_strings.append(allocator, image_url);
                try parts.append(allocator, .{ .input_image = .{ .image_url = image_url } });
            },
            .thinking, .tool_call => {},
        }
    }
    const slice = try parts.toOwnedSlice(allocator);
    errdefer allocator.free(slice);
    try builder.content_lists.append(allocator, slice);
    try input_list.append(allocator, .{ .user_message = .{ .content = slice } });
}

fn appendCodexAssistant(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(CodexInputItem),
    assistant: types.AssistantMessage,
    message_index: usize,
    builder: *CodexBuilder,
) !void {
    for (assistant.content) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (types.thinkingSignature(thinking)) |signature| {
                    var parsed = std.json.parseFromSlice(std.json.Value, allocator, signature, .{}) catch continue;
                    defer parsed.deinit();
                    const cloned = try provider_json.cloneValue(allocator, parsed.value);
                    try builder.owned_values.append(allocator, cloned);
                    try input_list.append(allocator, .{ .passthrough_value = cloned });
                }
            },
            .text => |text| {
                const message_id = try std.fmt.allocPrint(allocator, "msg_{d}", .{message_index});
                try builder.owned_strings.append(allocator, message_id);
                const sanitized = try openai.sanitizeSurrogates(allocator, text.text);
                try builder.owned_strings.append(allocator, sanitized);
                try input_list.append(allocator, .{ .assistant_message = .{
                    .id = message_id,
                    .text = sanitized,
                } });
            },
            .image, .tool_call => {},
        }
    }

    const tool_calls_source = if (types.hasInlineToolCalls(assistant))
        try types.collectAssistantToolCalls(allocator, assistant)
    else
        null;
    defer if (tool_calls_source) |calls| allocator.free(calls);

    if (tool_calls_source orelse assistant.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| {
            const split = splitToolCallId(tool_call.id);
            const call_id_owned = try allocator.dupe(u8, split.call_id);
            try builder.owned_strings.append(allocator, call_id_owned);
            var id_owned: ?[]const u8 = null;
            if (split.item_id) |item_id| {
                const dup = try allocator.dupe(u8, item_id);
                try builder.owned_strings.append(allocator, dup);
                id_owned = dup;
            }
            const name_owned = try allocator.dupe(u8, tool_call.name);
            try builder.owned_strings.append(allocator, name_owned);
            const arguments_json = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{});
            try builder.owned_strings.append(allocator, arguments_json);
            try input_list.append(allocator, .{ .function_call = .{
                .call_id = call_id_owned,
                .id = id_owned,
                .name = name_owned,
                .arguments = arguments_json,
            } });
        }
    }
}

fn appendCodexToolResult(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(CodexInputItem),
    model: types.Model,
    tool_result: types.ToolResultMessage,
    builder: *CodexBuilder,
) !void {
    const supports_images = modelSupportsImages(model);
    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);
    var image_count: usize = 0;
    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_parts.items.len > 0) try text_parts.appendSlice(allocator, "\n");
                try text_parts.appendSlice(allocator, text.text);
            },
            .image => image_count += 1,
            .thinking, .tool_call => {},
        }
    }
    const call_id_owned = try allocator.dupe(u8, splitToolCallId(tool_result.tool_call_id).call_id);
    try builder.owned_strings.append(allocator, call_id_owned);

    if (supports_images and image_count > 0) {
        var parts = std.ArrayList(CodexContentPart).empty;
        errdefer parts.deinit(allocator);
        if (text_parts.items.len > 0) {
            const sanitized = try openai.sanitizeSurrogates(allocator, text_parts.items);
            try builder.owned_strings.append(allocator, sanitized);
            try parts.append(allocator, .{ .input_text = .{ .text = sanitized } });
        }
        for (tool_result.content) |block| {
            switch (block) {
                .image => |image| {
                    const image_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    try builder.owned_strings.append(allocator, image_url);
                    try parts.append(allocator, .{ .input_image = .{ .image_url = image_url } });
                },
                else => {},
            }
        }
        const slice = try parts.toOwnedSlice(allocator);
        errdefer allocator.free(slice);
        try builder.content_lists.append(allocator, slice);
        try input_list.append(allocator, .{ .function_call_output_parts = .{
            .call_id = call_id_owned,
            .parts = slice,
        } });
    } else {
        const output_text = if (text_parts.items.len > 0)
            try openai.sanitizeSurrogates(allocator, text_parts.items)
        else if (image_count > 0)
            try allocator.dupe(u8, "(see attached image)")
        else
            try allocator.dupe(u8, "");
        try builder.owned_strings.append(allocator, output_text);
        try input_list.append(allocator, .{ .function_call_output_text = .{
            .call_id = call_id_owned,
            .output = output_text,
        } });
    }
}

pub fn buildPayloadJsonBytes(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    var owned = try buildOwnedCodex(allocator, model, context, options);
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

pub fn buildRequestSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    snapshot_options: openai_responses.RequestSnapshotOptions,
) !std.json.Value {
    var payload = if (snapshot_options.payload_override) |override|
        try provider_json.cloneValue(allocator, override)
    else
        try buildRequestPayload(allocator, model, context, options);
    errdefer provider_json.freeValue(allocator, payload);

    const api_key = if (options) |stream_options| stream_options.api_key orelse "fixture-api-key-redacted" else "fixture-api-key-redacted";
    const normalized_token = stripBearerPrefix(std.mem.trim(u8, api_key, " \t\r\n"));
    const account_id = try extractAccountId(allocator, normalized_token);
    defer allocator.free(account_id);

    const sse_url = try resolveCodexUrl(allocator, model.base_url);
    defer allocator.free(sse_url);
    const websocket = snapshot_options.transport_mode == .deferred_websocket and std.mem.eql(u8, snapshot_options.method, "WEBSOCKET");
    const url = if (websocket) try buildWebSocketUrl(allocator, sse_url) else try allocator.dupe(u8, sse_url);
    defer allocator.free(url);

    var headers = try buildRequestHeaders(
        allocator,
        model,
        options,
        normalized_token,
        account_id,
        if (websocket) .deferred_websocket else .sse,
    );
    defer deinitOwnedHeaders(allocator, &headers);

    if (websocket) {
        payload = try buildWebSocketRequestPayload(allocator, payload);
    }

    var snapshot = try initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = snapshot });

    const base_url_owned = try openai_responses.inferResponsesBaseUrlFromUrl(allocator, url, snapshot_options.provider_family);
    errdefer allocator.free(base_url_owned);
    try snapshot.put(allocator, try allocator.dupe(u8, "baseUrl"), .{ .string = base_url_owned });
    try putObjectValue(allocator, &snapshot, "headers", .{ .object = try openai_responses.normalizeSemanticHeaders(allocator, headers) });
    try putObjectValue(allocator, &snapshot, "jsonPayload", payload);
    payload = .null;
    try putStringValue(allocator, &snapshot, "method", snapshot_options.method);
    const path_owned = try openai_responses.buildResponsesRequestPathFromUrl(allocator, url);
    errdefer allocator.free(path_owned);
    try snapshot.put(allocator, try allocator.dupe(u8, "path"), .{ .string = path_owned });
    try putObjectValue(allocator, &snapshot, "query", .{ .object = try openai_responses.buildResponsesRequestQueryObjectFromUrl(allocator, url) });
    try putObjectValue(allocator, &snapshot, "requestOptions", .{ .object = try openai_responses.buildRequestOptionsSnapshotObject(allocator, options, false) });
    try putObjectValue(allocator, &snapshot, "transportMetadata", .{ .object = try openai_responses.buildTransportMetadataSnapshotObject(
        allocator,
        snapshot_options.scenario_id,
        snapshot_options.provider_family,
        snapshot_options.transport_mode,
        snapshot_options.mocked_status,
    ) });
    try putStringValue(allocator, &snapshot, "url", url);

    return .{ .object = snapshot };
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn splitToolCallId(id: []const u8) struct { call_id: []const u8, item_id: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, id, '|')) |separator_index| {
        const item_id = id[separator_index + 1 ..];
        return .{
            .call_id = id[0..separator_index],
            .item_id = if (item_id.len > 0) item_id else null,
        };
    }
    return .{ .call_id = id, .item_id = null };
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    return parseSseStreamLinesWithDiagnostic(
        allocator,
        stream_ptr,
        streaming,
        model,
        options,
        null,
    );
}

fn parseSseStreamLinesWithDiagnostic(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
    prefilled_diagnostic: ?types.AssistantMessageDiagnostic,
) !void {
    var diagnostic_owner = prefilled_diagnostic;
    errdefer if (diagnostic_owner) |d| freeOwnedDiagnostic(allocator, d);

    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    if (diagnostic_owner) |d| {
        try diagnostics_helper.appendAssistantMessageDiagnostic(allocator, &output, d);
        diagnostic_owner = null;
    }

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    stream_ptr.push(.{ .event_type = .start });

    const request_service_tier: ?[]const u8 = if (options) |stream_options|
        stream_options.providerOptions("responses").service_tier
    else
        null;
    var response_service_tier: ?[]const u8 = null;

    var handler = CodexResponsesSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .current_block = &current_block,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .model = model,
        .request_service_tier = request_service_tier,
        .response_service_tier = &response_service_tier,
    };
    const loop_result = try sse_loop.run(CodexResponsesSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped and !handler.normal_completion) {
        return;
    }

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });
    // Tool calls live inline in output.content; legacy field intentionally null.

    finalize.calculateCost(model, &output.usage);
    const effective_service_tier = resolveCodexServiceTier(response_service_tier, request_service_tier);
    applyServiceTierPricing(&output.usage, effective_service_tier, model);

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

/// Build a `provider_transport_failure` diagnostic mirroring TS:
/// `{ configuredTransport, fallbackTransport, eventsEmitted, phase, requestBytes }`.
fn buildTransportFailureDiagnostic(
    allocator: std.mem.Allocator,
    err: anyerror,
    events_emitted: bool,
    request_bytes: usize,
) !types.AssistantMessageDiagnostic {
    var details = try provider_json.initObject(allocator);
    var details_owned = true;
    errdefer if (details_owned) provider_json.freeValue(allocator, .{ .object = details });

    try details.put(
        allocator,
        try allocator.dupe(u8, "configuredTransport"),
        .{ .string = try allocator.dupe(u8, "auto") },
    );
    if (!events_emitted) {
        try details.put(
            allocator,
            try allocator.dupe(u8, "fallbackTransport"),
            .{ .string = try allocator.dupe(u8, "sse") },
        );
    }
    try details.put(
        allocator,
        try allocator.dupe(u8, "eventsEmitted"),
        .{ .bool = events_emitted },
    );
    try details.put(
        allocator,
        try allocator.dupe(u8, "phase"),
        .{ .string = try allocator.dupe(u8, if (events_emitted)
            "after_message_stream_start"
        else
            "before_message_stream_start") },
    );
    try details.put(
        allocator,
        try allocator.dupe(u8, "requestBytes"),
        .{ .integer = @intCast(request_bytes) },
    );

    // Avoid copying `details` through `cloneValue`: build the diagnostic
    // directly and hand the object map's ownership to the diagnostic.
    const type_owned = try allocator.dupe(u8, "provider_transport_failure");
    errdefer allocator.free(type_owned);
    const error_info = try diagnostics_helper.extractDiagnosticError(allocator, err);
    errdefer {
        if (error_info.name) |name| allocator.free(name);
        allocator.free(error_info.message);
        if (error_info.stack) |stack| allocator.free(stack);
        if (error_info.code) |code| provider_json.freeValue(allocator, code);
    }

    const diagnostic: types.AssistantMessageDiagnostic = .{
        .type = type_owned,
        .timestamp = 0,
        .error_info = error_info,
        .details = .{ .object = details },
    };
    details_owned = false;
    return diagnostic;
}

fn freeOwnedDiagnostic(allocator: std.mem.Allocator, diagnostic: types.AssistantMessageDiagnostic) void {
    allocator.free(diagnostic.type);
    if (diagnostic.error_info) |info| {
        if (info.name) |name| allocator.free(name);
        allocator.free(info.message);
        if (info.stack) |stack| allocator.free(stack);
        if (info.code) |code| provider_json.freeValue(allocator, code);
    }
    if (diagnostic.details) |details| provider_json.freeValue(allocator, details);
}

const WsAttemptMode = enum {
    /// `.websocket` / `.websocket_cached` transports — failures are terminal.
    hard_fail,
    /// `.auto` transport — transport-class failures return a fallback signal
    /// (no terminal event) so the caller can retry over SSE.
    auto,
};

fn streamProductionWebSocket(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    options: ?types.StreamOptions,
    normalized_token: []const u8,
    account_id: []const u8,
    payload: std.json.Value,
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    _ = try runCodexWebSocketAttempt(
        allocator,
        io,
        model,
        options,
        normalized_token,
        account_id,
        payload,
        stream_ptr,
        .hard_fail,
    );
}

/// Returns true when the current call should consult the WebSocket
/// connection cache. Mirrors TS `useCachedContext` (transport is
/// `.websocket_cached` or `.auto`). The plain `.websocket` transport is
/// always single-shot.
fn callUsesCachedContext(transport: types.Transport) bool {
    return transport == .websocket_cached or transport == .auto;
}

fn runCodexWebSocketAttempt(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    options: ?types.StreamOptions,
    normalized_token: []const u8,
    account_id: []const u8,
    payload: std.json.Value,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    mode: WsAttemptMode,
) !WebSocketAttempt {
    const http_url = try resolveCodexUrl(allocator, model.base_url);
    defer allocator.free(http_url);
    const ws_url = try buildWebSocketUrl(allocator, http_url);
    defer allocator.free(ws_url);

    const request_id = try resolveWebSocketRequestId(allocator, io, options);
    defer allocator.free(request_id);

    var headers = try buildWebSocketRequestHeaders(allocator, model, options, normalized_token, account_id, request_id);
    defer deinitOwnedHeaders(allocator, &headers);

    var header_list = std.ArrayList(websocket_client.Header).empty;
    defer header_list.deinit(allocator);
    var headers_iter = headers.iterator();
    while (headers_iter.next()) |entry| {
        try header_list.append(allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    }

    const transport_value: types.Transport = if (options) |stream_options| stream_options.transport else .auto;
    const session_id_opt: ?[]const u8 = blk: {
        const opts = options orelse break :blk null;
        const id = opts.session_id orelse break :blk null;
        if (id.len == 0) break :blk null;
        break :blk id;
    };
    const want_cache = callUsesCachedContext(transport_value) and session_id_opt != null;

    // Decide cache vs single-shot. `cached_entry` is non-null iff the
    // current call uses (or installs) a cached connection. `single_shot`
    // is non-null otherwise, in which case it must be deinit'd on return.
    var cached_entry: ?*WebSocketCacheEntry = null;
    var single_shot: ?websocket_client.Client = null;
    var keep_cached_on_release: bool = false;
    var single_shot_owned: bool = false;
    defer {
        if (cached_entry) |entry| {
            releaseCacheEntry(session_id_opt.?, entry, keep_cached_on_release, io);
        }
        if (single_shot_owned) {
            if (single_shot) |*c| c.deinit();
        }
    }

    // If we want a cached connection, peek; on `.free` try to grab it;
    // on `.busy_skip` fall through to a fresh (uncached) single-shot
    // connection just for this call.
    var reused_cached = false;
    if (want_cache) {
        const session_id = session_id_opt.?;
        const state = peekCacheBusyState(session_id, io);
        switch (state) {
            .free => if (acquireExistingEntry(session_id, io)) |entry| {
                cached_entry = entry;
                reused_cached = true;
            } else {
                // Raced to expiry between peek and acquire; open fresh.
            },
            .busy_skip => {
                // Open a fresh, uncached single-shot connection.
            },
            .fresh => {},
        }
    }

    // Open a new connection if we didn't reuse one. If `want_cache` is
    // true (and we're not in busy_skip), install the new client into the
    // cache after a successful connect.
    if (cached_entry == null) {
        // Try to open a fresh client.
        const new_client = websocket_client.Client.connect(.{
            .allocator = allocator,
            .io = io,
            .url = ws_url,
            .headers = header_list.items,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => switch (mode) {
                .hard_fail => {
                    const error_message = try std.fmt.allocPrint(
                        allocator,
                        "WebSocket connect failed: {s}",
                        .{@errorName(err)},
                    );
                    defer allocator.free(error_message);
                    try provider_error.pushTerminalStreamError(allocator, stream_ptr, model, error_message);
                    return .done;
                },
                .auto => return WebSocketAttempt{ .fallback = .{ .err = err } },
            },
        };

        // If the connection was successful, decide whether to install in
        // the cache. We install when: `.websocket_cached` or `.auto` AND
        // the cache state was `.free`/`.fresh` (not `.busy_skip`).
        const should_install = want_cache and blk: {
            const state = peekCacheBusyState(session_id_opt.?, io);
            // Re-check: install only if no other entry exists or it
            // expired. If `.busy_skip`, do not install — let the prior
            // owner keep its entry.
            break :blk state != .busy_skip;
        };
        if (should_install) {
            const heap_client = std.heap.page_allocator.create(websocket_client.Client) catch |err| {
                var mutable = new_client;
                mutable.deinit();
                return err;
            };
            heap_client.* = new_client;
            const entry = installCacheEntry(session_id_opt.?, heap_client, io) catch |err| {
                // Install failed; tear down the heap client.
                heap_client.deinit();
                std.heap.page_allocator.destroy(heap_client);
                return err;
            };
            cached_entry = entry;
        } else {
            single_shot = new_client;
            single_shot_owned = true;
        }
    }

    // Resolve the active client pointer.
    const active_client: *websocket_client.Client = if (cached_entry) |entry| entry.client else &single_shot.?;

    // Compute the request body (full vs delta-rewritten).
    var rewritten_body: ?std.json.Value = null;
    defer if (rewritten_body) |v| provider_json.freeValue(allocator, v);
    var body_for_send = payload;
    if (reused_cached) {
        if (cached_entry) |entry| {
            if (try buildCachedWebSocketRequestBody(allocator, entry, payload)) |delta_body| {
                rewritten_body = delta_body;
                body_for_send = delta_body;
            }
        }
    }

    // Build the WS request body envelope: {"type":"response.create", ...body_for_send}.
    var envelope = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = envelope });
    try envelope.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "response.create") });
    if (body_for_send == .object) {
        var iterator = body_for_send.object.iterator();
        while (iterator.next()) |entry| {
            try envelope.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try provider_json.cloneValue(allocator, entry.value_ptr.*),
            );
        }
    }
    const envelope_value: std.json.Value = .{ .object = envelope };
    const envelope_json = try std.json.Stringify.valueAlloc(allocator, envelope_value, .{});
    defer allocator.free(envelope_json);

    active_client.sendText(envelope_json) catch |err| switch (mode) {
        .hard_fail => {
            const error_message = try std.fmt.allocPrint(
                allocator,
                "WebSocket send failed: {s}",
                .{@errorName(err)},
            );
            defer allocator.free(error_message);
            try provider_error.pushTerminalStreamError(allocator, stream_ptr, model, error_message);
            return .done;
        },
        .auto => return WebSocketAttempt{ .fallback = .{ .err = err } },
    };

    const ctx = CodexWebSocketContext{
        .cached_entry = cached_entry,
        .original_request_body = payload,
        .want_cache = want_cache,
    };
    const outcome = try processCodexWebSocketStream(allocator, active_client, stream_ptr, model, options, mode, ctx);
    // On a clean `.done` outcome, if we owned a cache entry, keep it
    // alive. All other outcomes evict the entry so transient errors
    // don't leak a half-broken socket.
    switch (outcome) {
        .done => keep_cached_on_release = (cached_entry != null),
        else => keep_cached_on_release = false,
    }
    return outcome;
}

const CodexWebSocketContext = struct {
    cached_entry: ?*WebSocketCacheEntry = null,
    /// Original (un-rewritten) request body for this call. We record this
    /// into the continuation snapshot so the next call's body equality
    /// check compares against the user-visible body, not the delta one.
    original_request_body: std.json.Value = .null,
    want_cache: bool = false,
};

fn processCodexWebSocketStream(
    allocator: std.mem.Allocator,
    client: *websocket_client.Client,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    options: ?types.StreamOptions,
    mode: WsAttemptMode,
    ctx: CodexWebSocketContext,
) !WebSocketAttempt {
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

    // In hard_fail mode the consumer must observe `.start` before any other
    // events, matching the existing `.websocket` contract. In auto mode we
    // defer `.start` until the first text frame arrives so a connect-time
    // failure can still cleanly fall back to SSE without leaking a stray
    // `start` into the downstream stream.
    var started = false;
    if (mode == .hard_fail) {
        stream_ptr.push(.{ .event_type = .start });
        started = true;
    }

    const request_service_tier: ?[]const u8 = if (options) |stream_options|
        stream_options.providerOptions("responses").service_tier
    else
        null;
    var response_service_tier: ?[]const u8 = null;

    var state = CodexResponsesSseState{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .current_block = &current_block,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .model = model,
        .request_service_tier = request_service_tier,
        .response_service_tier = &response_service_tier,
    };

    var saw_completion = false;
    while (true) {
        if (abort_helper.isRequestedFromOptions(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, error.RequestAborted);
            return if (mode == .auto) WebSocketAttempt.aborted else WebSocketAttempt.done;
        }

        const frame_opt = client.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => switch (mode) {
                .hard_fail => {
                    try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, err);
                    return WebSocketAttempt.done;
                },
                .auto => {
                    if (started) {
                        try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, err);
                        return WebSocketAttempt{ .started_then_failed = .{ .err = err } };
                    }
                    return WebSocketAttempt{ .fallback = .{ .err = err } };
                },
            },
        };
        const frame = frame_opt orelse break;
        defer frame.deinit(allocator);

        switch (frame) {
            .text => |bytes| {
                if (mode == .auto and !started) {
                    stream_ptr.push(.{ .event_type = .start });
                    started = true;
                }
                const result = try processCodexResponsesSseData(&state, bytes);
                switch (result) {
                    .continue_loop => {},
                    .complete_loop => {
                        saw_completion = true;
                        break;
                    },
                    // .stop_loop: a Codex application/protocol error already
                    // pushed a terminal `error_event`. Do NOT fall back —
                    // mirror TS `isCodexNonTransportError` semantics.
                    .stop_loop => return if (mode == .auto) WebSocketAttempt.api_error else WebSocketAttempt.done,
                }
            },
            .binary => {
                // Codex doesn't send binary frames; ignore defensively.
            },
            .pong => {},
            .close => break,
        }
    }

    if (!saw_completion) {
        const err = error.WebSocketClosedBeforeCompletion;
        switch (mode) {
            .hard_fail => {
                try emitRuntimeFailure(
                    allocator,
                    stream_ptr,
                    &output,
                    &current_block,
                    &content_blocks,
                    &tool_calls,
                    err,
                );
                return WebSocketAttempt.done;
            },
            .auto => {
                if (started) {
                    try emitRuntimeFailure(
                        allocator,
                        stream_ptr,
                        &output,
                        &current_block,
                        &content_blocks,
                        &tool_calls,
                        err,
                    );
                    return WebSocketAttempt{ .started_then_failed = .{ .err = err } };
                }
                return WebSocketAttempt{ .fallback = .{ .err = err } };
            },
        }
    }

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });

    finalize.calculateCost(model, &output.usage);
    const effective_service_tier = resolveCodexServiceTier(response_service_tier, request_service_tier);
    applyServiceTierPricing(&output.usage, effective_service_tier, model);

    // Snapshot the continuation state BEFORE handing `output` to the
    // stream (stream takes ownership of the AssistantMessage on .end).
    if (ctx.want_cache) {
        if (ctx.cached_entry) |entry| {
            try updateCacheContinuation(allocator, entry, ctx.original_request_body, output);
        }
    }

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
    return WebSocketAttempt.done;
}

fn resolveWebSocketRequestId(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ?types.StreamOptions,
) ![]u8 {
    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            if (session_id.len > 0) return try allocator.dupe(u8, session_id);
        }
    }

    var random_bytes: [4]u8 = undefined;
    io.random(&random_bytes);
    const random_value = std.mem.readInt(u32, &random_bytes, .big);
    const ts = std.Io.Clock.real.now(io);
    return try std.fmt.allocPrint(allocator, "codex_{d}_{x:0>8}", .{ ts, random_value });
}

fn buildWebSocketRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    normalized_token: []const u8,
    account_id: []const u8,
    request_id: []const u8,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &headers);

    try mergeHeaders(allocator, &headers, model.headers);
    if (options) |stream_options| {
        try mergeHeaders(allocator, &headers, stream_options.headers);
    }

    // Mirror buildWebSocketHeaders() in the TS implementation: drop SSE-only
    // headers, then set the WS-specific ones.
    _ = removeHeaderCaseInsensitive(allocator, &headers, "accept");
    _ = removeHeaderCaseInsensitive(allocator, &headers, "content-type");
    _ = removeHeaderCaseInsensitive(allocator, &headers, "OpenAI-Beta");
    _ = removeHeaderCaseInsensitive(allocator, &headers, "openai-beta");

    try putOwnedHeader(allocator, &headers, "OpenAI-Beta", "responses_websockets=2026-02-06");
    try putOwnedHeader(allocator, &headers, "originator", "pi");
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{normalized_token});
    defer allocator.free(auth_header);
    try putOwnedHeader(allocator, &headers, "Authorization", auth_header);
    try putOwnedHeader(allocator, &headers, "chatgpt-account-id", account_id);
    try putOwnedHeader(allocator, &headers, "x-client-request-id", request_id);
    try putOwnedHeader(allocator, &headers, "session_id", request_id);

    return headers;
}

fn removeHeaderCaseInsensitive(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
) bool {
    var key_to_remove: ?[]const u8 = null;
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
            key_to_remove = entry.key_ptr.*;
            break;
        }
    }
    if (key_to_remove) |key| {
        if (headers.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
            return true;
        }
    }
    return false;
}

const CodexResponsesSseDataResult = enum {
    continue_loop,
    complete_loop,
    stop_loop,
};

const CodexResponsesSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    request_service_tier: ?[]const u8,
    response_service_tier: *?[]const u8,
    normal_completion: bool = false,

    pub fn extractDataLine(_: *CodexResponsesSseLoopHandler, line: []const u8) ?[]const u8 {
        return parseSseLine(line);
    }

    pub fn isDoneData(_: *CodexResponsesSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *CodexResponsesSseLoopHandler, data: []const u8) !bool {
        var state = CodexResponsesSseState{
            .allocator = self.allocator,
            .stream_ptr = self.stream_ptr,
            .output = self.output,
            .current_block = self.current_block,
            .content_blocks = self.content_blocks,
            .tool_calls = self.tool_calls,
            .model = self.model,
            .request_service_tier = self.request_service_tier,
            .response_service_tier = self.response_service_tier,
        };
        const result = try processCodexResponsesSseData(&state, data);
        switch (result) {
            .continue_loop => return true,
            .complete_loop => {
                self.normal_completion = true;
                return false;
            },
            .stop_loop => return false,
        }
    }

    pub fn handleRuntimeFailure(self: *CodexResponsesSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.current_block,
            self.content_blocks,
            self.tool_calls,
            err,
        );
    }
};

const CodexResponsesSseState = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    request_service_tier: ?[]const u8,
    response_service_tier: *?[]const u8,
};

fn processCodexResponsesSseData(state: *CodexResponsesSseState, data: []const u8) !CodexResponsesSseDataResult {
    const allocator = state.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, state.stream_ptr, state.output, state.current_block, state.content_blocks, state.tool_calls, err);
            return .stop_loop;
        },
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return .continue_loop;

    const event_type = extractStringField(value, "type") orelse return .continue_loop;

    if (std.mem.eql(u8, event_type, "response.created")) {
        if (value.object.get("response")) |response_value| {
            updateResponseIdFromResponseObject(allocator, state.output, response_value) catch {};
        }
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        const item_value = value.object.get("item") orelse return .continue_loop;
        try handleOutputItemAdded(allocator, item_value, state.current_block, state.content_blocks, state.stream_ptr);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        try appendCodexThinkingDelta(state, delta_value.string);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
        if (state.current_block.*) |*block| {
            switch (block.*) {
                .thinking => |*thinking| {
                    if (thinking.text.items.len > 0) {
                        try thinking.text.appendSlice(allocator, "\n\n");
                        state.stream_ptr.push(.{
                            .event_type = .thinking_delta,
                            .content_index = @intCast(thinking.event_index),
                            .delta = try allocator.dupe(u8, "\n\n"),
                            .owns_delta = true,
                        });
                    }
                },
                else => {},
            }
        }
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_text.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        try appendCodexThinkingDelta(state, delta_value.string);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.content_part.added")) {
        const part_value = value.object.get("part") orelse return .continue_loop;
        updateCurrentMessagePart(part_value, state.current_block);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.output_text.delta") or std.mem.eql(u8, event_type, "response.refusal.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        if (state.current_block.*) |*block| {
            switch (block.*) {
                .text => |*text| {
                    try text.text.appendSlice(allocator, delta_value.string);
                    state.stream_ptr.push(.{
                        .event_type = .text_delta,
                        .content_index = @intCast(text.event_index),
                        .delta = try allocator.dupe(u8, delta_value.string),
                        .owns_delta = true,
                    });
                },
                else => {},
            }
        }
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        if (state.current_block.*) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    try tool_call.partial_json.appendSlice(allocator, delta_value.string);
                    state.stream_ptr.push(.{
                        .event_type = .toolcall_delta,
                        .content_index = @intCast(tool_call.event_index),
                        .delta = try allocator.dupe(u8, delta_value.string),
                        .owns_delta = true,
                    });
                },
                else => {},
            }
        }
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
        const arguments_value = value.object.get("arguments") orelse return .continue_loop;
        if (arguments_value != .string) return .continue_loop;
        if (state.current_block.*) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    const previous = tool_call.partial_json.items;
                    if (std.mem.startsWith(u8, arguments_value.string, previous)) {
                        const delta = arguments_value.string[previous.len..];
                        tool_call.partial_json.clearRetainingCapacity();
                        try tool_call.partial_json.appendSlice(allocator, arguments_value.string);
                        if (delta.len > 0) {
                            state.stream_ptr.push(.{
                                .event_type = .toolcall_delta,
                                .content_index = @intCast(tool_call.event_index),
                                .delta = try allocator.dupe(u8, delta),
                                .owns_delta = true,
                            });
                        }
                    } else {
                        tool_call.partial_json.clearRetainingCapacity();
                        try tool_call.partial_json.appendSlice(allocator, arguments_value.string);
                    }
                },
                else => {},
            }
        }
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item_value = value.object.get("item") orelse return .continue_loop;
        try finalizeCurrentBlock(allocator, item_value, state.current_block, state.content_blocks, state.tool_calls, state.stream_ptr);
        return .continue_loop;
    }

    if (try handleCodexTerminalEvent(state, event_type, value)) |result| return result;

    return .continue_loop;
}

fn handleCodexTerminalEvent(
    state: *CodexResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?CodexResponsesSseDataResult {
    if (std.mem.eql(u8, event_type, "response.done") or std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
        if (value.object.get("response")) |response_value| {
            try updateCompletedResponse(state.allocator, state.output, response_value, state.model, state.response_service_tier);
        }
        return .complete_loop;
    }

    if (std.mem.eql(u8, event_type, "response.failed")) {
        const error_message = try extractFailureMessage(state.allocator, value.object.get("response"));
        try emitCodexResponsesTerminalError(state, error_message);
        return .stop_loop;
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const error_message = try extractTopLevelErrorMessage(state.allocator, value);
        try emitCodexResponsesTerminalError(state, error_message);
        return .stop_loop;
    }

    return null;
}

fn appendCodexThinkingDelta(state: *CodexResponsesSseState, delta: []const u8) !void {
    if (state.current_block.*) |*block| {
        switch (block.*) {
            .thinking => |*thinking| {
                try thinking.text.appendSlice(state.allocator, delta);
                state.stream_ptr.push(.{
                    .event_type = .thinking_delta,
                    .content_index = @intCast(thinking.event_index),
                    .delta = try state.allocator.dupe(u8, delta),
                    .owns_delta = true,
                });
            },
            else => {},
        }
    }
}

fn emitCodexResponsesTerminalError(state: *CodexResponsesSseState, error_message: []const u8) !void {
    try finalizeOutputFromPartials(state.allocator, state.output, state.current_block, state.content_blocks, state.tool_calls, state.stream_ptr);
    state.output.stop_reason = .error_reason;
    state.output.error_message = error_message;
    state.stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = state.output.*,
    });
    state.stream_ptr.end(state.output.*);
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finalizeCurrentBlock(allocator, null, current_block, content_blocks, tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, output, .{ .content_blocks = content_blocks, .tool_calls = tool_calls }, .{ .content_transfer = .when_output_empty, .total_tokens = .preserve, .coerce_stop_reason_for_tool_calls = false });
    // Tool calls live inline in output.content; legacy field intentionally null.
    // tool_calls is borrow-only bookkeeping.
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, content_blocks, tool_calls, stream_ptr);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn handleOutputItemAdded(
    allocator: std.mem.Allocator,
    item_value: std.json.Value,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (item_value != .object) return;
    const item_type = extractStringField(item_value, "type") orelse return;

    if (std.mem.eql(u8, item_type, "reasoning")) {
        if (current_block.* != null) return;
        current_block.* = responses_api.initThinkingBlock(content_blocks.items.len);
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type, "message")) {
        if (current_block.* != null) return;
        current_block.* = responses_api.initTextBlock(content_blocks.items.len);
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type, "function_call")) {
        if (current_block.* != null) return;
        current_block.* = try responses_api.initToolCallBlockFromItem(allocator, content_blocks.items.len, item_value);
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(content_blocks.items.len) });
    }
}

fn stripBearerPrefix(token: []const u8) []const u8 {
    if (std.mem.startsWith(u8, token, "Bearer ")) {
        return std.mem.trim(u8, token["Bearer ".len..], " \t\r\n");
    }
    return token;
}

fn extractAccountId(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const payload_segment = parts.next() orelse return error.InvalidJwt;
    if (payload_segment.len == 0) return error.InvalidJwt;

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJwtPayload;
    const auth_value = parsed.value.object.get(CODEX_AUTH_CLAIM) orelse return error.MissingAccountId;
    if (auth_value != .object) return error.MissingAccountId;
    const account_id_value = auth_value.object.get("chatgpt_account_id") orelse return error.MissingAccountId;
    if (account_id_value != .string or account_id_value.string.len == 0) return error.MissingAccountId;

    return try allocator.dupe(u8, account_id_value.string);
}

fn resolveCodexUrl(allocator: std.mem.Allocator, raw_base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw_base_url, " \t\r\n"), "/");
    const base_url = if (trimmed.len > 0) trimmed else DEFAULT_CODEX_BASE_URL;

    if (std.mem.endsWith(u8, base_url, "/codex/responses")) return try allocator.dupe(u8, base_url);
    if (std.mem.endsWith(u8, base_url, "/codex")) return try std.fmt.allocPrint(allocator, "{s}/responses", .{base_url});
    return try std.fmt.allocPrint(allocator, "{s}/codex/responses", .{base_url});
}

fn buildWebSocketUrl(allocator: std.mem.Allocator, http_url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, http_url, "https://")) return try std.fmt.allocPrint(allocator, "wss://{s}", .{http_url["https://".len..]});
    if (std.mem.startsWith(u8, http_url, "http://")) return try std.fmt.allocPrint(allocator, "ws://{s}", .{http_url["http://".len..]});
    return try allocator.dupe(u8, http_url);
}

fn buildWebSocketRequestPayload(allocator: std.mem.Allocator, payload: std.json.Value) !std.json.Value {
    var message = try initObject(allocator);
    errdefer message.deinit(allocator);

    try message.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "response.create") });
    if (payload == .object) {
        var iterator = payload.object.iterator();
        while (iterator.next()) |entry| {
            try message.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try provider_json.cloneValue(allocator, entry.value_ptr.*));
        }
    }
    provider_json.freeValue(allocator, payload);
    return .{ .object = message };
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    normalized_token: []const u8,
    account_id: []const u8,
    transport_mode: openai_responses.RequestSnapshotTransportMode,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &headers);

    try mergeHeaders(allocator, &headers, model.headers);
    if (options) |stream_options| {
        try mergeHeaders(allocator, &headers, stream_options.headers);
    }

    if (transport_mode == .deferred_websocket) {
        try putOwnedHeader(allocator, &headers, "OpenAI-Beta", "responses_websockets=2026-02-06");
    } else {
        try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
        try putOwnedHeader(allocator, &headers, "OpenAI-Beta", "responses=experimental");
    }
    try putOwnedHeader(allocator, &headers, "originator", "pi");
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{normalized_token});
    defer allocator.free(auth_header);
    try putOwnedHeader(allocator, &headers, "Authorization", auth_header);
    try putOwnedHeader(allocator, &headers, "chatgpt-account-id", account_id);
    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            try putOwnedHeader(allocator, &headers, "session_id", session_id);
            try putOwnedHeader(allocator, &headers, "x-client-request-id", session_id);
        }
    }

    return headers;
}

fn updateResponseIdFromResponseObject(allocator: std.mem.Allocator, output: *types.AssistantMessage, response_value: std.json.Value) !void {
    const response_id = extractStringField(response_value, "id") orelse return;
    if (output.response_id == null) {
        output.response_id = try allocator.dupe(u8, response_id);
    }
}

fn updateCompletedResponse(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    response_value: std.json.Value,
    model: types.Model,
    response_service_tier_out: *?[]const u8,
) !void {
    if (response_value != .object) return;
    try updateResponseIdFromResponseObject(allocator, output, response_value);

    if (response_value.object.get("usage")) |usage_value| {
        output.usage = parseUsage(usage_value);
        finalize.calculateCost(model, &output.usage);
    }

    if (extractStringField(response_value, "service_tier")) |tier| {
        response_service_tier_out.* = tier;
    }

    if (extractStringField(response_value, "status")) |status| {
        output.stop_reason = mapStopReason(status);
    }
}

/// Port of TS `resolveCodexServiceTier` in `packages/ai/src/providers/openai-codex-responses.ts`.
/// If response echoes "default" but request asked for "flex"/"priority", use the request value.
fn resolveCodexServiceTier(
    response_service_tier: ?[]const u8,
    request_service_tier: ?[]const u8,
) ?[]const u8 {
    if (response_service_tier) |response_tier| {
        if (std.mem.eql(u8, response_tier, "default")) {
            if (request_service_tier) |request_tier| {
                if (std.mem.eql(u8, request_tier, "flex") or std.mem.eql(u8, request_tier, "priority")) {
                    return request_tier;
                }
            }
        }
        return response_tier;
    }
    return request_service_tier;
}

/// Port of TS `applyServiceTierPricing` in `packages/ai/src/providers/openai-codex-responses.ts`.
/// Multipliers: flex=0.5, priority=2 (or 2.5 for model id "gpt-5.5"). Applied after
/// `finalize.calculateCost` on `response.completed`/`response.done`.
fn applyServiceTierPricing(
    usage: *types.Usage,
    service_tier: ?[]const u8,
    model: types.Model,
) void {
    const multiplier = getServiceTierCostMultiplier(model, service_tier);
    if (multiplier == 1.0) return;

    usage.cost.input *= multiplier;
    usage.cost.output *= multiplier;
    usage.cost.cache_read *= multiplier;
    usage.cost.cache_write *= multiplier;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn getServiceTierCostMultiplier(model: types.Model, service_tier: ?[]const u8) f64 {
    const tier = service_tier orelse return 1.0;
    if (std.mem.eql(u8, tier, "flex")) return 0.5;
    if (std.mem.eql(u8, tier, "priority")) {
        if (std.mem.eql(u8, model.id, "gpt-5.5")) return 2.5;
        return 2.0;
    }
    return 1.0;
}

pub const parseUsage = openai_usage.parseResponsesUsage;

fn extractStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(key) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn extractFailureMessage(allocator: std.mem.Allocator, response_value: ?std.json.Value) ![]const u8 {
    const response = response_value orelse return try allocator.dupe(u8, "Unknown error (no error details in response)");
    if (response != .object) return try allocator.dupe(u8, "Unknown error (no error details in response)");

    if (response.object.get("error")) |error_value| {
        if (error_value == .object) {
            const code = extractStringField(error_value, "code") orelse "unknown";
            const message = extractStringField(error_value, "message") orelse "no message";
            return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ code, message });
        }
    }

    if (response.object.get("incomplete_details")) |details_value| {
        if (details_value == .object) {
            if (extractStringField(details_value, "reason")) |reason| {
                return try std.fmt.allocPrint(allocator, "incomplete: {s}", .{reason});
            }
        }
    }

    return try allocator.dupe(u8, "Unknown error (no error details in response)");
}

fn extractTopLevelErrorMessage(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (extractStringField(value, "code")) |code| {
        const message = extractStringField(value, "message") orelse "Unknown error";
        return try std.fmt.allocPrint(allocator, "Error Code {s}: {s}", .{ code, message });
    }
    if (extractStringField(value, "message")) |message| {
        return try allocator.dupe(u8, message);
    }
    return try allocator.dupe(u8, "Unknown error");
}

fn mapStopReason(status: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.openai_responses_mappings, status, .error_reason);
}

const jsonIntegerToU32 = openai_usage.jsonIntegerToU32;

fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return provider_json.initObject(allocator);
}

const freeToolCallOwned = types.freeToolCall;
const freeAssistantMessageOwned = types.freeAssistantMessage;

fn freeEventOwned(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    if (event.delta) |delta| allocator.free(delta);
    if (event.tool_call) |tool_call| freeToolCallOwned(allocator, tool_call);
}

test "VAL-MSG-010 Codex Responses skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api/codex/responses",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const failed_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "partial" } },
        .{ .tool_call = .{ .id = "failed-call", .name = "lookup", .arguments = .null } },
    };
    const user_content = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};
    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .assistant = .{
            .content = &failed_content,
            .api = "openai-codex-responses",
            .provider = "openai-codex",
            .model = "gpt-5.1-codex",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 1,
        } },
        .{ .user = .{ .content = &user_content, .timestamp = 2 } },
    } }, null);
    defer provider_json.freeValue(allocator, payload);

    const input = payload.object.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 1), input.items.len);
    try std.testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);
}

test "buildRequestPayload uses Codex-specific request shape" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Say hello" } }},
                .timestamp = 1,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .session_id = "session-123",
        .cache_retention = .short,
    });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload == .object);
    try std.testing.expectEqualStrings("gpt-5.1-codex", payload.object.get("model").?.string);
    try std.testing.expectEqualStrings("You are a helpful assistant.", payload.object.get("instructions").?.string);
    try std.testing.expectEqualStrings("session-123", payload.object.get("prompt_cache_key").?.string);
    try std.testing.expectEqualStrings("auto", payload.object.get("tool_choice").?.string);
    try std.testing.expectEqual(payload.object.get("parallel_tool_calls").?.bool, true);
    try std.testing.expect(payload.object.get("max_output_tokens") == null);

    const text_config = payload.object.get("text").?;
    try std.testing.expect(text_config == .object);
    try std.testing.expectEqualStrings("low", text_config.object.get("verbosity").?.string);

    const include = payload.object.get("include").?;
    try std.testing.expect(include == .array);
    try std.testing.expectEqualStrings("reasoning.encrypted_content", include.array.items[0].string);

    const input = payload.object.get("input").?;
    try std.testing.expect(input == .array);
    try std.testing.expectEqual(@as(usize, 1), input.array.items.len);
    try std.testing.expectEqualStrings("user", input.array.items[0].object.get("role").?.string);
}

test "extractReasoningSummary prefers summary and falls back to content text" {
    const allocator = std.testing.allocator;
    const fallback_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"content fallback\"}]}",
        .{},
    );
    defer fallback_parsed.deinit();

    const fallback_text = (try extractReasoningSummary(allocator, fallback_parsed.value)).?;
    defer allocator.free(fallback_text);
    try std.testing.expectEqualStrings("content fallback", fallback_text);

    const summary_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[{\"text\":\"summary wins\"}],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"content loses\"}]}",
        .{},
    );
    defer summary_parsed.deinit();

    const summary_text = (try extractReasoningSummary(allocator, summary_parsed.value)).?;
    defer allocator.free(summary_text);
    try std.testing.expectEqualStrings("summary wins", summary_text);
}

test "parseSseStreamLines handles response.done terminal events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_codex\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello Codex\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello Codex\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8}}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Hello Codex", delta.delta.?);

    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("Hello Codex", text_end.content.?);

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("resp_codex", done.message.?.response_id.?);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("Hello Codex", done.message.?.content[0].text.text);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines preserves Codex canonical data-line strictness" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data:{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"compact_ignored\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data:{\"type\":\"response.output_text.delta\",\"delta\":\"ignored compact\"}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"canonical\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"canonical\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex_canonical\",\"status\":\"completed\"}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("canonical", delta.delta.?);

    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("canonical", text_end.content.?);

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("canonical", done.message.?.content[0].text.text);
    try std.testing.expect(stream_instance.next() == null);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines emits Codex reasoning_text deltas with final content fallback" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_codex_reasoning_text\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}\n" ++
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"codex \"}\n" ++
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"delta\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"codex final content\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex_reasoning_text\",\"status\":\"completed\"}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);

    const first_delta = stream_instance.next().?;
    defer freeEventOwned(allocator, first_delta);
    try std.testing.expectEqual(types.EventType.thinking_delta, first_delta.event_type);
    try std.testing.expectEqualStrings("codex ", first_delta.delta.?);

    const second_delta = stream_instance.next().?;
    defer freeEventOwned(allocator, second_delta);
    try std.testing.expectEqual(types.EventType.thinking_delta, second_delta.event_type);
    try std.testing.expectEqualStrings("delta", second_delta.delta.?);

    const thinking_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqualStrings("codex final content", thinking_end.content.?);

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("openai-codex-responses", done.message.?.api);
    try std.testing.expectEqualStrings("openai-codex", done.message.?.provider);
    try std.testing.expectEqualStrings("gpt-5.1-codex", done.message.?.model);
    try std.testing.expectEqualStrings("codex final content", done.message.?.content[0].thinking.thinking);
    try std.testing.expect(stream_instance.next() == null);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines preserves Codex content indexes across text tool text blocks" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_codex_content_index\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_before\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Before\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_before\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Before\"}]}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_after\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"After\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_after\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"After\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex_content_index\",\"status\":\"completed\"}}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_start.content_index.?);
    const text_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_delta.content_index.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), text_end.content_index.?);

    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_delta.content_index.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), tool_end.content_index.?);

    const after_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, after_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), after_start.content_index.?);
    const after_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, after_delta.event_type);
    try std.testing.expectEqual(@as(u32, 2), after_delta.content_index.?);
    const after_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, after_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), after_end.content_index.?);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(@as(usize, 3), done.message.?.content.len);
    try std.testing.expectEqualStrings("Before", done.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("get_weather", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("After", done.message.?.content[2].text.text);
}

test "parseSseStreamLines uses final output item text when delta stream is incomplete" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"What would you like to work\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"What would you like to work on?\"}]}}\n" ++
            "data: {\"type\":\"response.done\",\"response\":{\"id\":\"resp_codex\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7,\"total_tokens\":12}}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);
    _ = stream_instance.next();
    _ = stream_instance.next();

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqualStrings("What would you like to work on?", text_end.content.?);

    const done = stream_instance.next().?;
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("What would you like to work on?", done.message.?.content[0].text.text);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines maps incomplete Codex responses to length" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Partial\"}]}}\n" ++
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}}}\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);
    _ = stream_instance.next();
    _ = stream_instance.next();

    const delta = stream_instance.next().?;
    defer freeEventOwned(allocator, delta);
    _ = stream_instance.next();

    const done = stream_instance.next().?;
    try std.testing.expect(done.message != null);
    try std.testing.expectEqual(types.StopReason.length, done.message.?.stop_reason);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "finalizeCollectedOutput preserves Codex finalization semantics" {
    const allocator = std.testing.allocator;

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    try content_blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, "hello") } });
    try finalize.appendInlineToolCall(allocator, &content_blocks, &tool_calls, .{
        .id = try allocator.dupe(u8, "call_1|item_1"),
        .name = try allocator.dupe(u8, "lookup"),
        .arguments = .null,
    });

    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .model = "gpt-5.1-codex",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
    output.usage.input = 5;
    output.usage.output = 3;
    output.usage.cache_read = 2;
    output.usage.cache_write = 1;

    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });
    defer freeAssistantMessageOwned(allocator, output);

    try std.testing.expectEqual(@as(usize, 0), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), output.content.len);
    try std.testing.expectEqualStrings("hello", output.content[0].text.text);
    try std.testing.expect(output.content[1] == .tool_call);
    try std.testing.expectEqual(types.StopReason.tool_use, output.stop_reason);
    try std.testing.expectEqual(@as(u32, 11), output.usage.total_tokens);
    try std.testing.expectEqual(output.content[1].tool_call.id.ptr, tool_calls.items[0].id.ptr);
}

test "extractAccountId reads ChatGPT account ID from JWT payload" {
    const allocator = std.testing.allocator;
    const account_id = try extractAccountId(
        allocator,
        "aaa.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOiB7ImNoYXRncHRfYWNjb3VudF9pZCI6ICJhY2NfdGVzdCJ9fQ.bbb",
    );
    defer allocator.free(account_id);

    try std.testing.expectEqualStrings("acc_test", account_id);
}

test "resolveCodexUrl appends codex responses path" {
    const allocator = std.testing.allocator;
    const url = try resolveCodexUrl(allocator, "https://chatgpt.com/backend-api/");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", url);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"codex denied\",\"authorization\":\"Bearer sk-codex-secret\",\"request_id\":\"req_codex_random_123456\"},\"trace\":\"/Users/alice/pi/openai_codex_responses.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 429, "Too Many Requests", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const payload_json = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc_test\"}}";
    var encoded_payload: [std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len)]u8 = undefined;
    const payload_segment = std.base64.url_safe_no_pad.Encoder.encode(&encoded_payload, payload_json);
    const api_key = try std.fmt.allocPrint(allocator, "aaa.{s}.sig", .{payload_segment});
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, context, .{
        .api_key = api_key,
        .transport = .sse,
    });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "codex denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-codex-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_codex_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("openai-codex-responses", result.api);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "http://127.0.0.1:1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, context, .{ .api_key = api_key });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("openai-codex-responses", event.message.?.api);
    try std.testing.expectEqualStrings("openai-codex", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-5.1-codex", event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(event.message.?.error_message.?.len > 0);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial Codex Responses text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_codex_abort\"}}\n" ++
                "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
                "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial codex\"}\n",
            .delay_after_ms = 1000,
        },
        .{ .bytes = "data: [DONE]\n" },
    };
    var server = try test_stream_server.DelayedChunkServer.init(io, &chunks);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);
    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
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

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
        .transport = .sse,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial codex", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial codex", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_codex_abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial codex", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes Codex Responses tool call on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_codex_eof_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_eof\",\"call_id\":\"call_eof\",\"name\":\"lookup\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_eof\",\"delta\":\"{\\\"query\\\":\\\"local\\\"}\"}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), tool_delta.content_index.?);
    try std.testing.expectEqualStrings("{\"query\":\"local\"}", tool_delta.delta.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), tool_end.content_index.?);
    try std.testing.expectEqualStrings("call_eof|fc_eof", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("local", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), done.message.?.content.len);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[0].tool_call.name);
    try std.testing.expectEqualStrings("local", done.message.?.content[0].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(stream.next() == null);
}

fn buildTestCodexApiKey(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const payload_json = try std.fmt.allocPrint(allocator, "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}", .{account_id});
    defer allocator.free(payload_json);

    const encoded_payload = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len));
    defer allocator.free(encoded_payload);
    const payload_segment = std.base64.url_safe_no_pad.Encoder.encode(encoded_payload, payload_json);

    return try std.fmt.allocPrint(allocator, "aaa.{s}.sig", .{payload_segment});
}

const CodexOnPayloadObservation = struct {
    var called = false;

    fn reset() void {
        called = false;
    }

    fn observe(_: std.mem.Allocator, _: std.json.Value, _: types.Model) anyerror!?std.json.Value {
        called = true;
        return null;
    }
};

test "stream invalid account id fails before onPayload is observed" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    CodexOnPayloadObservation.reset();
    var stream = try OpenAICodexResponsesProvider.stream(allocator, std.Io.failing, model, context, .{
        .api_key = "not-a-jwt-before-onPayload",
        .on_payload = CodexOnPayloadObservation.observe,
    });
    defer stream.deinit();

    const event = stream.next().?;
    defer allocator.free(event.error_message.?);
    try std.testing.expect(!CodexOnPayloadObservation.called);
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "InvalidJwt") != null);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "stream onPayload failure is terminal error event" {
    const allocator = std.testing.allocator;
    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
    const Callback = struct {
        fn fail(_: std.mem.Allocator, _: std.json.Value, _: types.Model) anyerror!?std.json.Value {
            return error.PayloadCallbackFailed;
        }
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, std.Io.failing, model, context, .{
        .api_key = api_key,
        .on_payload = Callback.fail,
    });
    defer stream.deinit();

    const event = stream.next().?;
    defer allocator.free(event.error_message.?);
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "PayloadCallbackFailed") != null);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "stream onResponse failure is terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "x-fixture-response: codex\r\n", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const payload_json = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc_test\"}}";
    var encoded_payload: [std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len)]u8 = undefined;
    const payload_segment = std.base64.url_safe_no_pad.Encoder.encode(&encoded_payload, payload_json);
    const api_key = try std.fmt.allocPrint(allocator, "aaa.{s}.sig", .{payload_segment});
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
    const Callback = struct {
        fn fail(status: u16, headers: std.StringHashMap([]const u8), _: types.Model) anyerror!void {
            try std.testing.expectEqual(@as(u16, 200), status);
            try std.testing.expect(headers.get("x-fixture-response") != null);
            return error.ResponseCallbackFailed;
        }
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, context, .{
        .api_key = api_key,
        .on_response = Callback.fail,
        .transport = .sse,
    });
    defer stream.deinit();

    const event = stream.next().?;
    defer allocator.free(event.error_message.?);
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "ResponseCallbackFailed") != null);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "buildRequestPayload uses default instructions when no system prompt is provided" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings(DEFAULT_CODEX_SYSTEM_PROMPT, payload.object.get("instructions").?.string);
}

test "buildRequestPayload preserves requested Codex reasoning effort" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, .{
        .provider = .{ .responses = .{ .reasoning_effort = .xhigh } },
    });
    defer provider_json.freeValue(allocator, payload);

    const reasoning = payload.object.get("reasoning").?;
    try std.testing.expect(reasoning == .object);
    try std.testing.expectEqualStrings("xhigh", reasoning.object.get("effort").?.string);
    try std.testing.expectEqualStrings("auto", reasoning.object.get("summary").?.string);
}

test "buildRequestPayload applies Codex request option parity fields" {
    const allocator = std.testing.allocator;
    var metadata = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = metadata });
    try metadata.put(allocator, try allocator.dupe(u8, "fixture"), .{ .string = try allocator.dupe(u8, "codex-metadata-is-not-emitted") });

    const model = types.Model{
        .id = "gpt-5.3-codex",
        .name = "Codex GPT-5.3",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, .{
        .cache_retention = .none,
        .session_id = "codex-session",
        .metadata = .{ .object = metadata },
        .provider = .{ .responses = .{
            .reasoning_effort = .minimal,
            .reasoning_summary = "concise",
            .service_tier = "priority",
            .text_verbosity = "high",
        } },
    });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings("codex-session", payload.object.get("prompt_cache_key").?.string);
    try std.testing.expect(payload.object.get("prompt_cache_retention") == null);
    try std.testing.expect(payload.object.get("metadata") == null);
    try std.testing.expectEqualStrings("priority", payload.object.get("service_tier").?.string);
    try std.testing.expectEqualStrings("high", payload.object.get("text").?.object.get("verbosity").?.string);
    try std.testing.expectEqualStrings("minimal", payload.object.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqualStrings("concise", payload.object.get("reasoning").?.object.get("summary").?.string);
}

test "buildRequestPayload omits empty tools array" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "codex-mini",
        .name = "Codex Mini",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 65536,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
        .tools = &[_]types.Tool{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("tools") == null);
}

fn runCodexServiceTierPricingTest(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    service_tier: ?[]const u8,
    response_service_tier_json: []const u8,
    expected_input: f64,
    expected_output: f64,
    expected_cache_read: f64,
    expected_total: f64,
) !void {
    const io = std.Io.failing;

    const completed_event = try std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"response.done\",\"response\":{{\"id\":\"resp_tier\",\"status\":\"completed\"{s},\"usage\":{{\"input_tokens\":7,\"output_tokens\":5,\"total_tokens\":12,\"input_tokens_details\":{{\"cached_tokens\":2}}}}}}}}\n",
        .{response_service_tier_json},
    );
    defer allocator.free(completed_event);

    const body_prefix =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tier\"}}\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}}\n";

    const body = try std.fmt.allocPrint(allocator, "{s}{s}", .{ body_prefix, completed_event });

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    const model = types.Model{
        .id = model_id,
        .name = "Codex Test Model",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.5 },
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const options = types.StreamOptions{
        .provider = .{ .responses = .{ .service_tier = service_tier } },
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, options);

    while (stream_instance.next()) |event| {
        if (event.event_type != .done) {
            freeEventOwned(allocator, event);
            continue;
        }
        try std.testing.expect(event.message != null);
        try std.testing.expectApproxEqAbs(expected_input, event.message.?.usage.cost.input, 0.0000001);
        try std.testing.expectApproxEqAbs(expected_output, event.message.?.usage.cost.output, 0.0000001);
        try std.testing.expectApproxEqAbs(expected_cache_read, event.message.?.usage.cost.cache_read, 0.0000001);
        try std.testing.expectApproxEqAbs(expected_total, event.message.?.usage.cost.total, 0.0000001);
        freeAssistantMessageOwned(allocator, event.message.?);
        return;
    }
    return error.ExpectedDoneEvent;
}

test "Codex parseSseStreamLines applies no service_tier multiplier when unset" {
    try runCodexServiceTierPricingTest(std.testing.allocator, "gpt-5.1-codex", null, "", 0.000005, 0.000010, 0.000001, 0.000016);
}

test "Codex parseSseStreamLines halves cost for service_tier=flex" {
    try runCodexServiceTierPricingTest(std.testing.allocator, "gpt-5.1-codex", "flex", "", 0.0000025, 0.0000050, 0.0000005, 0.0000080);
}

test "Codex parseSseStreamLines doubles cost for service_tier=priority on non-gpt-5.5 model" {
    try runCodexServiceTierPricingTest(std.testing.allocator, "gpt-5.1-codex", "priority", "", 0.000010, 0.000020, 0.000002, 0.000032);
}

test "Codex parseSseStreamLines uses 2.5x multiplier for service_tier=priority on gpt-5.5" {
    try runCodexServiceTierPricingTest(std.testing.allocator, "gpt-5.5", "priority", "", 0.0000125, 0.0000250, 0.0000025, 0.0000400);
}

test "Codex parseSseStreamLines treats auto service_tier as no multiplier" {
    try runCodexServiceTierPricingTest(std.testing.allocator, "gpt-5.1-codex", "auto", "", 0.000005, 0.000010, 0.000001, 0.000016);
}

test "Codex parseSseStreamLines prefers request service_tier when response echoes default" {
    // request says priority on gpt-5.5, response echoes default -> still 2.5x
    try runCodexServiceTierPricingTest(
        std.testing.allocator,
        "gpt-5.5",
        "priority",
        ",\"service_tier\":\"default\"",
        0.0000125,
        0.0000250,
        0.0000025,
        0.0000400,
    );
}

test "Codex parseSseStreamLines uses response service_tier when set explicitly" {
    // request unset, response says flex -> 0.5x
    try runCodexServiceTierPricingTest(
        std.testing.allocator,
        "gpt-5.1-codex",
        null,
        ",\"service_tier\":\"flex\"",
        0.0000025,
        0.0000050,
        0.0000005,
        0.0000080,
    );
}

fn baseUrlFromTestWsUrl(allocator: std.mem.Allocator, ws_url: []const u8) ![]u8 {
    // server.url() returns ws://127.0.0.1:<port>/codex/responses; resolveCodexUrl
    // will keep it intact, and buildWebSocketUrl will swap http:// back to ws://.
    return try std.mem.replaceOwned(u8, allocator, ws_url, "ws://", "http://");
}

test "openai-codex-responses websocket transport streams events to terminal completion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const frames = [_]test_websocket_server.FrameDirective{
        .{ .text = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_ws\"}}" },
        .{ .text = "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_ws\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}" },
        .{ .text = "{\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}" },
        .{ .text = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello over ws\"}" },
        .{ .text = "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_ws\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello over ws\"}]}}" },
        .{ .text = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_ws\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}}" },
    };
    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .frames_to_send = &frames,
        .close_after_frames = .{ .code = 1000, .reason = "done" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .websocket,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);

    const delta = stream.next().?;
    defer freeEventOwned(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("hello over ws", delta.delta.?);

    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("hello over ws", text_end.content.?);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("resp_ws", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("hello over ws", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    freeAssistantMessageOwned(allocator, done.message.?);
}

test "openai-codex-responses websocket transport propagates handshake failure as error_event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .reject_with_status = 403,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .websocket,
    });
    defer stream.deinit();

    const event = stream.next().?;
    defer allocator.free(event.error_message.?);
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("openai-codex-responses", event.message.?.api);
    try std.testing.expectEqualStrings("openai-codex", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-5.1-codex", event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(event.message.?.error_message.?.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "WebSocket connect failed") != null);
    try std.testing.expect(stream.next() == null);
}

// ============================================================================
// J.4 — WebSocket failure recording + SSE fallback (port of TS PR #4133)
// ============================================================================

/// A test server that accepts TWO sequential TCP connections on one port:
///
/// 1. First connection: reads an HTTP request. If it's a WebSocket upgrade
///    (looks for "Upgrade: websocket"), it responds with a configurable
///    HTTP rejection status (default 403) — exercising the
///    `error.HandshakeFailed` transport-class branch. If it isn't a WS
///    upgrade, it responds with the SSE body immediately (so single-attempt
///    SSE-only tests can also use this server).
/// 2. Second connection: replies with the SSE body.
///
/// This is the smallest harness that lets `transport: .auto` go through its
/// WS-then-SSE fallback path in a single test without restructuring the
/// existing WS-only / SSE-only test fixtures.
const FallbackTestServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    ws_reject_status: u16,
    sse_body: []const u8,
    sse_status: u16 = 200,
    thread: ?std.Thread = null,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ws_reject_status: u16,
        sse_body: []const u8,
        sse_status: u16,
    ) !FallbackTestServer {
        return .{
            .allocator = allocator,
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .ws_reject_status = ws_reject_status,
            .sse_body = sse_body,
            .sse_status = sse_status,
        };
    }

    fn start(self: *FallbackTestServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *FallbackTestServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn url(self: *const FallbackTestServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *FallbackTestServer) void {
        var conn_count: usize = 0;
        while (conn_count < 2) : (conn_count += 1) {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                else => return,
            };
            self.handleConnection(stream) catch {};
            stream.close(self.io);
        }
    }

    fn handleConnection(self: *FallbackTestServer, stream: std.Io.net.Stream) !void {
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);

        const request_bytes = try readHttpRequestHead(self.allocator, &reader.interface);
        defer self.allocator.free(request_bytes);

        const is_ws_upgrade =
            std.ascii.indexOfIgnoreCase(request_bytes, "upgrade: websocket") != null;

        if (is_ws_upgrade) {
            const reason: []const u8 = switch (self.ws_reject_status) {
                400 => "Bad Request",
                401 => "Unauthorized",
                403 => "Forbidden",
                404 => "Not Found",
                else => "Error",
            };
            try writer.interface.print(
                "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                .{ self.ws_reject_status, reason },
            );
            try writer.interface.flush();
            return;
        }

        // Drain any POST body (we don't need to parse it for these tests).
        // The request head already consumed up to \r\n\r\n.

        const status_reason: []const u8 = switch (self.sse_status) {
            200 => "OK",
            400 => "Bad Request",
            500 => "Internal Server Error",
            else => "Error",
        };
        try writer.interface.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            .{ self.sse_status, status_reason },
        );
        // Emit body as one chunk + 0\r\n\r\n terminator.
        try writer.interface.print("{x}\r\n", .{self.sse_body.len});
        try writer.interface.writeAll(self.sse_body);
        try writer.interface.writeAll("\r\n0\r\n\r\n");
        try writer.interface.flush();
    }
};

fn readHttpRequestHead(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var tail: [4]u8 = .{ 0, 0, 0, 0 };
    var count: usize = 0;
    while (true) {
        const byte = try reader.takeByte();
        try buf.append(allocator, byte);
        tail[count % tail.len] = byte;
        count += 1;
        if (buf.items.len > 16 * 1024) return error.RequestHeaderTooLarge;
        if (count >= 4) {
            const start_idx = count % tail.len;
            const ordered = [_]u8{
                tail[start_idx],
                tail[(start_idx + 1) % tail.len],
                tail[(start_idx + 2) % tail.len],
                tail[(start_idx + 3) % tail.len],
            };
            if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
        }
    }
    return try buf.toOwnedSlice(allocator);
}

const SSE_BODY_OK_HELLO =
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_fb\"}}\n" ++
    "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_fb\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
    "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello via sse\"}\n" ++
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_fb\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello via sse\"}]}}\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fb\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}}\n";

test "transport=auto + ws handshake refused engages SSE fallback and emits diagnostic" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try FallbackTestServer.init(allocator, io, 403, SSE_BODY_OK_HELLO, 200);
    defer server.deinit();
    try server.start();

    const base_url = try server.url(allocator);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    // Use a unique session id so the per-process registry doesn't pollute
    // other tests.
    const session_id = "fallback-session-handshake-refused";
    resetWebSocketFallbackRegistry(session_id, io);
    defer resetWebSocketFallbackRegistry(session_id, io);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .auto,
        .session_id = session_id,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);

    const delta = stream.next().?;
    defer freeEventOwned(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("hello via sse", delta.delta.?);

    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("hello via sse", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);

    // provider_transport_failure diagnostic must be attached.
    const diagnostics = done.message.?.diagnostics orelse return error.TestExpectedTransportDiagnostic;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("provider_transport_failure", diagnostics[0].type);
    const details = diagnostics[0].details orelse return error.TestExpectedDiagnosticDetails;
    try std.testing.expect(details == .object);
    try std.testing.expectEqualStrings("auto", details.object.get("configuredTransport").?.string);
    try std.testing.expectEqualStrings("sse", details.object.get("fallbackTransport").?.string);
    try std.testing.expectEqual(false, details.object.get("eventsEmitted").?.bool);
    try std.testing.expectEqualStrings("before_message_stream_start", details.object.get("phase").?.string);

    try std.testing.expect(stream.next() == null);
    freeAssistantMessageOwned(allocator, done.message.?);

    // Registry must have been populated.
    try std.testing.expect(isWebSocketSseFallbackActive(session_id, io));
}

test "transport=auto + second call after ws failure skips websocket and uses SSE directly" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    // Pre-populate the registry to simulate a prior WS failure for this session.
    const session_id = "fallback-session-second-call";
    resetWebSocketFallbackRegistry(session_id, io);
    defer resetWebSocketFallbackRegistry(session_id, io);
    recordWebSocketFailure(session_id, io);
    try std.testing.expect(isWebSocketSseFallbackActive(session_id, io));

    // Server only handles ONE connection: the SSE POST. If the provider tried
    // to upgrade to WS first the test would deadlock or surface a different
    // event ordering.
    var server = try FallbackTestServer.init(allocator, io, 403, SSE_BODY_OK_HELLO, 200);
    defer server.deinit();
    try server.start();

    const base_url = try server.url(allocator);
    defer allocator.free(base_url);
    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .auto,
        .session_id = session_id,
    });
    defer stream.deinit();

    // Drain until done.
    var observed_text_end = false;
    while (stream.next()) |event| {
        if (event.event_type == .done) {
            try std.testing.expect(event.message != null);
            try std.testing.expectEqualStrings("hello via sse", event.message.?.content[0].text.text);
            // No fallback diagnostic — there was no WS attempt this call.
            try std.testing.expect(event.message.?.diagnostics == null);
            freeAssistantMessageOwned(allocator, event.message.?);
            break;
        }
        if (event.event_type == .text_end) {
            observed_text_end = true;
            try std.testing.expectEqualStrings("hello via sse", event.content.?);
        }
        freeEventOwned(allocator, event);
    }
    try std.testing.expect(observed_text_end);
}

test "transport=auto + server response.failed JSON is terminal, NO fallback registration" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    // WS server that ACCEPTS the upgrade and sends a `response.failed`
    // application error frame, then closes. This must NOT trigger the SSE
    // fallback path and must NOT populate the registry.
    const frames = [_]test_websocket_server.FrameDirective{
        .{ .text = "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"upstream failed\"}}}" },
    };
    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .frames_to_send = &frames,
        .close_after_frames = .{ .code = 1000, .reason = "done" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const session_id = "fallback-session-api-error";
    resetWebSocketFallbackRegistry(session_id, io);
    defer resetWebSocketFallbackRegistry(session_id, io);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .auto,
        .session_id = session_id,
    });
    defer stream.deinit();

    // The WS conversation began, so `.start` arrives first.
    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);

    // Drain until error_event.
    var saw_error = false;
    while (stream.next()) |event| {
        if (event.event_type == .error_event) {
            saw_error = true;
            try std.testing.expect(event.error_message != null);
            try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "upstream failed") != null);
            if (event.message) |message| freeAssistantMessageOwned(allocator, message);
            break;
        }
        if (event.message) |message| freeAssistantMessageOwned(allocator, message);
        freeEventOwned(allocator, event);
    }
    try std.testing.expect(saw_error);
    try std.testing.expect(stream.next() == null);

    // Application/protocol errors must NOT populate the registry.
    try std.testing.expect(!isWebSocketSseFallbackActive(session_id, io));
}

test "WebSocket fallback registry helpers track per-session state" {
    const io = std.testing.io;
    const sid_a = "registry-test-session-a";
    const sid_b = "registry-test-session-b";
    resetWebSocketFallbackRegistry(sid_a, io);
    resetWebSocketFallbackRegistry(sid_b, io);
    defer resetWebSocketFallbackRegistry(sid_a, io);
    defer resetWebSocketFallbackRegistry(sid_b, io);

    try std.testing.expect(!isWebSocketSseFallbackActive(sid_a, io));
    try std.testing.expect(!isWebSocketSseFallbackActive(sid_b, io));
    try std.testing.expect(!isWebSocketSseFallbackActive(null, io));
    try std.testing.expect(!isWebSocketSseFallbackActive("", io));

    recordWebSocketFailure(sid_a, io);
    try std.testing.expect(isWebSocketSseFallbackActive(sid_a, io));
    try std.testing.expect(!isWebSocketSseFallbackActive(sid_b, io));

    // Recording the same session twice is idempotent.
    recordWebSocketFailure(sid_a, io);
    try std.testing.expect(isWebSocketSseFallbackActive(sid_a, io));

    // null / empty session_id are no-ops.
    recordWebSocketFailure(null, io);
    recordWebSocketFailure("", io);

    resetWebSocketFallbackRegistry(sid_a, io);
    try std.testing.expect(!isWebSocketSseFallbackActive(sid_a, io));
}

test "isCodexNonTransportError distinguishes application from transport errors" {
    try std.testing.expect(isCodexNonTransportError(error.CodexApiError));
    try std.testing.expect(isCodexNonTransportError(error.CodexProtocolError));
    try std.testing.expect(!isCodexNonTransportError(error.HandshakeFailed));
    try std.testing.expect(!isCodexNonTransportError(error.ConnectionClosed));
    try std.testing.expect(!isCodexNonTransportError(error.TlsFailure));
    try std.testing.expect(!isCodexNonTransportError(error.InvalidHandshakeResponse));
    try std.testing.expect(!isCodexNonTransportError(error.MaskedServerFrame));
    try std.testing.expect(!isCodexNonTransportError(error.InvalidFrame));
    try std.testing.expect(!isCodexNonTransportError(error.FrameTooLarge));
    try std.testing.expect(!isCodexNonTransportError(error.WebSocketClosedBeforeCompletion));
}

test "openai-codex-responses websocket transport sends response.create frame with correct body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const frames = [_]test_websocket_server.FrameDirective{
        .{ .text = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_capture\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}" },
    };
    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .capture_first_client_frame = true,
        .frames_to_send = &frames,
        .close_after_frames = .{ .code = 1000, .reason = "done" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const model = types.Model{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .websocket,
    });
    defer stream.deinit();

    // Drain events to ensure server completes and captures the client frame.
    while (stream.next()) |event| {
        if (event.message) |message| freeAssistantMessageOwned(allocator, message);
        freeEventOwned(allocator, event);
        if (event.event_type == .done or event.event_type == .error_event) break;
    }

    server.awaitDone();
    const captured = server.capturedFrame() orelse return error.TestExpectedCapturedFrame;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, captured, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("response.create", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("gpt-5.1-codex", parsed.value.object.get("model").?.string);
}

// ============================================================================
// J.5 — WebSocket cached transport (port of TS `websocketSessionCache`).
// ============================================================================

const CODEX_RESP_COMPLETED_FRAME =
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_cached\",\"status\":\"completed\"," ++
    "\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}";

fn newCachedTestModel(base_url: []const u8) types.Model {
    return .{
        .id = "gpt-5.1-codex",
        .name = "GPT-5.1 Codex",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = base_url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
}

fn drainCodexStream(allocator: std.mem.Allocator, stream: *event_stream.AssistantMessageEventStream) void {
    while (stream.next()) |event| {
        if (event.message) |message| freeAssistantMessageOwned(allocator, message);
        freeEventOwned(allocator, event);
        if (event.event_type == .done or event.event_type == .error_event) break;
    }
}

test "buildCachedWebSocketRequestBody returns null when continuation is unset" {
    const allocator = std.testing.allocator;
    var entry = WebSocketCacheEntry{
        .allocator = allocator,
        .client = undefined,
        .busy = true,
        .last_used_ns = 0,
        .continuation = null,
    };

    var body_object = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = body_object });
    try body_object.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });

    const result = try buildCachedWebSocketRequestBody(allocator, &entry, .{ .object = body_object });
    try std.testing.expect(result == null);
}

test "buildCachedWebSocketRequestBody rewrites body when input is a prefix extension" {
    const allocator = std.testing.allocator;

    // Prior body: { model, input: [user_a] }
    var prior_body_obj = try initObject(allocator);
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    var prior_input = std.json.Array.init(allocator);
    try prior_input.append(.{ .string = try allocator.dupe(u8, "user_a") });
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = prior_input });

    // Prior response items: [assistant_a]
    var prior_response = std.json.Array.init(allocator);
    try prior_response.append(.{ .string = try allocator.dupe(u8, "assistant_a") });

    var entry = WebSocketCacheEntry{
        .allocator = allocator,
        .client = undefined,
        .busy = true,
        .last_used_ns = 0,
        .continuation = .{
            .last_request_body = .{ .object = prior_body_obj },
            .last_response_id = try allocator.dupe(u8, "resp_prior"),
            .last_response_items = prior_response,
        },
    };
    defer if (entry.continuation) |*c| c.deinit(allocator);

    // New body: { model, input: [user_a, assistant_a, user_b] }
    var new_body_obj = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = new_body_obj });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    var new_input = std.json.Array.init(allocator);
    try new_input.append(.{ .string = try allocator.dupe(u8, "user_a") });
    try new_input.append(.{ .string = try allocator.dupe(u8, "assistant_a") });
    try new_input.append(.{ .string = try allocator.dupe(u8, "user_b") });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = new_input });

    const result_opt = try buildCachedWebSocketRequestBody(allocator, &entry, .{ .object = new_body_obj });
    try std.testing.expect(result_opt != null);
    const result = result_opt.?;
    defer provider_json.freeValue(allocator, result);

    try std.testing.expectEqualStrings("resp_prior", result.object.get("previous_response_id").?.string);
    const delta = result.object.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 1), delta.items.len);
    try std.testing.expectEqualStrings("user_b", delta.items[0].string);
}

test "buildCachedWebSocketRequestBody returns null when input is not a prefix extension" {
    const allocator = std.testing.allocator;

    var prior_body_obj = try initObject(allocator);
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    var prior_input = std.json.Array.init(allocator);
    try prior_input.append(.{ .string = try allocator.dupe(u8, "user_a") });
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = prior_input });

    var prior_response = std.json.Array.init(allocator);
    try prior_response.append(.{ .string = try allocator.dupe(u8, "assistant_a") });

    var entry = WebSocketCacheEntry{
        .allocator = allocator,
        .client = undefined,
        .busy = true,
        .last_used_ns = 0,
        .continuation = .{
            .last_request_body = .{ .object = prior_body_obj },
            .last_response_id = try allocator.dupe(u8, "resp_prior"),
            .last_response_items = prior_response,
        },
    };
    defer if (entry.continuation) |*c| c.deinit(allocator);

    // New input differs at index 0 — not a prefix extension.
    var new_body_obj = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = new_body_obj });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    var new_input = std.json.Array.init(allocator);
    try new_input.append(.{ .string = try allocator.dupe(u8, "user_DIFFERENT") });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = new_input });

    const result = try buildCachedWebSocketRequestBody(allocator, &entry, .{ .object = new_body_obj });
    try std.testing.expect(result == null);
    try std.testing.expect(entry.continuation == null); // mismatch clears continuation
}

test "buildCachedWebSocketRequestBody returns null when non-input fields change" {
    const allocator = std.testing.allocator;

    var prior_body_obj = try initObject(allocator);
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = 0.5 });
    const prior_input = std.json.Array.init(allocator);
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = prior_input });

    var prior_response = std.json.Array.init(allocator);
    try prior_response.append(.{ .string = try allocator.dupe(u8, "assistant_a") });

    var entry = WebSocketCacheEntry{
        .allocator = allocator,
        .client = undefined,
        .busy = true,
        .last_used_ns = 0,
        .continuation = .{
            .last_request_body = .{ .object = prior_body_obj },
            .last_response_id = try allocator.dupe(u8, "resp_prior"),
            .last_response_items = prior_response,
        },
    };
    defer if (entry.continuation) |*c| c.deinit(allocator);

    // New body: temperature changed.
    var new_body_obj = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = new_body_obj });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = 0.9 });
    var new_input = std.json.Array.init(allocator);
    try new_input.append(.{ .string = try allocator.dupe(u8, "assistant_a") });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = new_input });

    const result = try buildCachedWebSocketRequestBody(allocator, &entry, .{ .object = new_body_obj });
    try std.testing.expect(result == null);
    try std.testing.expect(entry.continuation == null);
}

test "WebSocketConnectionCache peek returns .fresh for missing session" {
    const io = std.testing.io;
    closeOpenAICodexWebSocketSessions(null, io);
    defer closeOpenAICodexWebSocketSessions(null, io);
    try std.testing.expectEqual(CacheBusyState.fresh, peekCacheBusyState("no-such-session", io));
}

test "buildCachedWebSocketRequestBody returns null when prior input is not a strict prefix" {
    const allocator = std.testing.allocator;

    // Prior body: { model, input: [a, b] }
    var prior_body_obj = try initObject(allocator);
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    const prior_input_local = std.json.Array.init(allocator);
    var prior_input = prior_input_local;
    try prior_input.append(.{ .string = try allocator.dupe(u8, "a") });
    try prior_input.append(.{ .string = try allocator.dupe(u8, "b") });
    try prior_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = prior_input });

    var prior_response = std.json.Array.init(allocator);
    try prior_response.append(.{ .string = try allocator.dupe(u8, "r1") });

    var entry = WebSocketCacheEntry{
        .allocator = allocator,
        .client = undefined,
        .busy = true,
        .last_used_ns = 0,
        .continuation = .{
            .last_request_body = .{ .object = prior_body_obj },
            .last_response_id = try allocator.dupe(u8, "rid"),
            .last_response_items = prior_response,
        },
    };
    defer if (entry.continuation) |*c| c.deinit(allocator);

    // New input length (2) < baseline (prior_input(2) + prior_response(1) = 3).
    var new_body_obj = try initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = new_body_obj });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, "gpt-5.1-codex") });
    var new_input = std.json.Array.init(allocator);
    try new_input.append(.{ .string = try allocator.dupe(u8, "a") });
    try new_input.append(.{ .string = try allocator.dupe(u8, "b") });
    try new_body_obj.put(allocator, try allocator.dupe(u8, "input"), .{ .array = new_input });

    const result = try buildCachedWebSocketRequestBody(allocator, &entry, .{ .object = new_body_obj });
    try std.testing.expect(result == null);
}

test "WebSocketConnectionCache integration: two .websocket_cached calls reuse one socket" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    // Script: handle exactly ONE TCP connection that carries two
    // request/response cycles. The cache must reuse the same socket.
    const response_frames_1 = [_]test_websocket_server.FrameDirective{
        .{ .text = CODEX_RESP_COMPLETED_FRAME },
    };
    const response_frames_2 = [_]test_websocket_server.FrameDirective{
        .{ .text = CODEX_RESP_COMPLETED_FRAME },
    };
    const script = [_]test_websocket_server.Step{
        .{ .expect_client_frame = .{} },
        .{ .send_frames = &response_frames_1 },
        .{ .expect_client_frame = .{} },
        .{ .send_frames = &response_frames_2 },
        .{ .close = .{ .code = 1000, .reason = "done" } },
    };

    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .script = &script,
        .max_connections = 1,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const session_id = "ws-cached-reuse-session";
    closeOpenAICodexWebSocketSessions(session_id, io);
    defer closeOpenAICodexWebSocketSessions(session_id, io);

    const model = newCachedTestModel(base_url);

    // First call — opens and installs the cached connection.
    {
        var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
            .api_key = api_key,
            .transport = .websocket_cached,
            .session_id = session_id,
        });
        defer stream.deinit();
        drainCodexStream(allocator, &stream);
    }

    try std.testing.expect(hasCachedWebSocketSessionForTesting(session_id, io));

    // Second call — should reuse the same socket. If a new TCP connect
    // were attempted, the server would reject it (max_connections=1) and
    // the call would fail.
    {
        var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
            .api_key = api_key,
            .transport = .websocket_cached,
            .session_id = session_id,
        });
        defer stream.deinit();
        drainCodexStream(allocator, &stream);
    }

    // closeOpenAICodexWebSocketSessions tears down the cached socket so
    // the server thread can exit on the next wait_close/close step.
    closeOpenAICodexWebSocketSessions(session_id, io);
    try std.testing.expect(!hasCachedWebSocketSessionForTesting(session_id, io));
    server.awaitDone();

    // Verify the server captured two response.create frames.
    const captured = server.capturedFrames();
    try std.testing.expectEqual(@as(usize, 2), captured.len);
}

test "closeOpenAICodexWebSocketSessions(session_id) removes the cached entry" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const response_frames = [_]test_websocket_server.FrameDirective{
        .{ .text = CODEX_RESP_COMPLETED_FRAME },
    };
    const script = [_]test_websocket_server.Step{
        .{ .expect_client_frame = .{} },
        .{ .send_frames = &response_frames },
        .{ .wait_close = {} },
    };

    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .script = &script,
        .max_connections = 1,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const session_id = "ws-cached-close-session";
    closeOpenAICodexWebSocketSessions(session_id, io);
    defer closeOpenAICodexWebSocketSessions(session_id, io);

    const model = newCachedTestModel(base_url);
    var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = api_key,
        .transport = .websocket_cached,
        .session_id = session_id,
    });
    defer stream.deinit();
    drainCodexStream(allocator, &stream);

    try std.testing.expect(hasCachedWebSocketSessionForTesting(session_id, io));
    closeOpenAICodexWebSocketSessions(session_id, io);
    try std.testing.expect(!hasCachedWebSocketSessionForTesting(session_id, io));
    server.awaitDone();
}

test "WebSocketConnectionCache TTL: expired entry forces fresh connection" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    // Two independent connection scripts — one per call. If TTL didn't
    // expire, the second call would reuse and only 1 connection would
    // be observed (which would deadlock the second script).
    const response_frames_a = [_]test_websocket_server.FrameDirective{
        .{ .text = CODEX_RESP_COMPLETED_FRAME },
    };
    const response_frames_b = [_]test_websocket_server.FrameDirective{
        .{ .text = CODEX_RESP_COMPLETED_FRAME },
    };
    const script_a = [_]test_websocket_server.Step{
        .{ .expect_client_frame = .{} },
        .{ .send_frames = &response_frames_a },
        .{ .wait_close = {} },
    };
    const script_b = [_]test_websocket_server.Step{
        .{ .expect_client_frame = .{} },
        .{ .send_frames = &response_frames_b },
        .{ .close = .{ .code = 1000, .reason = "done" } },
    };
    const scripts = [_][]const test_websocket_server.Step{ &script_a, &script_b };

    var server = try test_websocket_server.TestWebSocketServer.init(allocator, io, .{
        .expected_path = "/codex/responses",
        .per_connection_scripts = &scripts,
        .max_connections = 2,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);
    const base_url = try baseUrlFromTestWsUrl(allocator, ws_url);
    defer allocator.free(base_url);

    const api_key = try buildTestCodexApiKey(allocator, "acc_test");
    defer allocator.free(api_key);

    const session_id = "ws-cached-ttl-session";
    closeOpenAICodexWebSocketSessions(session_id, io);
    defer closeOpenAICodexWebSocketSessions(session_id, io);

    setWebSocketCacheNowOverrideForTesting(0, io);
    defer setWebSocketCacheNowOverrideForTesting(null, io);

    const model = newCachedTestModel(base_url);
    {
        var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
            .api_key = api_key,
            .transport = .websocket_cached,
            .session_id = session_id,
        });
        defer stream.deinit();
        drainCodexStream(allocator, &stream);
    }

    try std.testing.expect(hasCachedWebSocketSessionForTesting(session_id, io));

    // Advance time past the TTL — the cached entry must be evicted on
    // the next peek/acquire.
    const ttl_plus_one = SESSION_WEBSOCKET_CACHE_TTL_NS + 1;
    setWebSocketCacheNowOverrideForTesting(ttl_plus_one, io);

    {
        var stream = try OpenAICodexResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
            .api_key = api_key,
            .transport = .websocket_cached,
            .session_id = session_id,
        });
        defer stream.deinit();
        drainCodexStream(allocator, &stream);
    }

    closeOpenAICodexWebSocketSessions(session_id, io);
    server.awaitDone();
}
