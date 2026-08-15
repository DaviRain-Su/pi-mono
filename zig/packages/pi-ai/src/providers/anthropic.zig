const std = @import("std");
const env_api_keys = @import("../env_api_keys.zig");
const resolve_api_key_mod = @import("../shared/resolve_api_key.zig");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
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
const sse_loop = @import("../shared/sse_loop.zig");
const stop_reason_mod = @import("../shared/stop_reason.zig");
const shared_url = @import("../shared/url.zig");
const cloudflare = @import("cloudflare.zig");
const github_copilot_headers = @import("github_copilot_headers.zig");
const anthropic_json = @import("anthropic_json.zig");
const test_stream_server = @import("test_stream_server.zig");

const AnthropicError = error{
    InvalidAnthropicChunk,
};

const CLAUDE_CODE_IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude.";
const CLAUDE_CODE_VERSION = "2.1.75";
const TOOL_PLACEHOLDER_TEXT = "";
const FINE_GRAINED_TOOL_STREAMING_BETA = "fine-grained-tool-streaming-2025-05-14";
const INTERLEAVED_THINKING_BETA = "interleaved-thinking-2025-05-14";

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
        redacted: bool,
    },
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        partial_json: std.ArrayList(u8),
    },
};

const BlockEntry = struct {
    anthropic_index: usize,
    event_index: usize,
    block: CurrentBlock,
};

const AnthropicCompat = struct {
    supports_eager_tool_input_streaming: bool = true,
    supports_long_cache_retention: bool = true,
    send_session_affinity_headers: bool = false,
    supports_cache_control_on_tools: bool = true,
    supports_temperature: bool = true,
    allow_empty_signature: bool = false,
};

const ResolvedOptions = struct {
    options: ?types.StreamOptions,
    owned_api_key: ?[]u8 = null,

    fn deinit(self: ResolvedOptions, allocator: std.mem.Allocator) void {
        if (self.owned_api_key) |api_key| allocator.free(api_key);
    }
};

pub const AnthropicProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("anthropic-messages", streamProduction);
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
        const resolved_options = try resolveStreamOptions(allocator, model, options);
        defer resolved_options.deinit(allocator);

        // After resolving env-based credentials, missing or blank auth must
        // surface as a deterministic terminal stream error rather than a
        // silent unauthenticated request. Mirrors the TypeScript
        // `No API key for provider:` diagnostic.
        const resolved_api_key = if (resolved_options.options) |stream_options|
            stream_options.api_key orelse ""
        else
            "";
        if (resolved_api_key.len == 0) {
            try resolve_api_key_mod.pushMissingApiKeyError(allocator, stream_instance, model);
            return;
        }

        var payload = try buildRequestPayload(allocator, model, context, resolved_options.options);
        defer provider_json.freeValue(allocator, payload);

        try provider_stream.applyOnPayloadCallback(allocator, &payload, model, resolved_options.options);

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        const resolved_base_url = try cloudflare.resolveBaseUrlOrNull(allocator, model);
        defer if (resolved_base_url) |b| allocator.free(b);

        const url = try buildMessagesUrl(allocator, resolved_base_url orelse model.base_url);
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer deinitOwnedHeaders(allocator, &headers);
        try applyBaseAnthropicHeaders(allocator, &headers, model);
        try applyAuthHeaders(allocator, &headers, model, resolved_options.options);
        try applyDefaultAnthropicHeaders(allocator, &headers, model, context, resolved_options.options);
        try applySessionAffinityHeaders(allocator, &headers, model, resolved_options.options);
        try mergeHeaders(allocator, &headers, model.headers);
        if (resolved_options.options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
        }

        try github_copilot_headers.applyDynamicHeadersIfCopilot(allocator, &headers, model, context.messages);

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try provider_stream.executeStreamingRequest(
            &client,
            url,
            headers,
            json_body,
            resolved_options.options,
            model,
        );
        defer response.deinit();

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, response.status, response_body);
            return;
        }

        try parseSseStreamLines(allocator, stream_instance, &response, model, context, resolved_options.options);
    }
};

fn buildMessagesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    return shared_url.buildUrlV1Normalized("/messages", allocator, base_url);
}

test "buildMessagesUrl appends SDK-compatible Anthropic path" {
    const allocator = std.testing.allocator;

    const anthropic_url = try buildMessagesUrl(allocator, "https://api.anthropic.com/v1");
    defer allocator.free(anthropic_url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic_url);

    const kimi_url = try buildMessagesUrl(allocator, "https://api.kimi.com/coding");
    defer allocator.free(kimi_url);
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1/messages", kimi_url);
}

fn resolveStreamOptions(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !ResolvedOptions {
    return resolveStreamOptionsWithEnvMap(allocator, model, options, null);
}

fn resolveStreamOptionsWithEnvMap(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    env_map: ?*const std.process.Environ.Map,
) !ResolvedOptions {
    var resolved = ResolvedOptions{ .options = options };
    const provided_api_key = if (options) |stream_options| stream_options.api_key else null;
    if (provided_api_key) |api_key| {
        if (api_key.len > 0) return resolved;
    }

    const env_api_key = if (env_map) |map|
        try env_api_keys.getEnvApiKeyFromMap(allocator, map, model.provider)
    else
        try env_api_keys.getEnvApiKey(allocator, model.provider);

    resolved.owned_api_key = env_api_key;
    if (env_api_key) |api_key| {
        var updated = options orelse types.StreamOptions{};
        updated.api_key = api_key;
        resolved.options = updated;
    } else if (options) |stream_options| {
        resolved.options = stream_options;
    }

    return resolved;
}

// =============================================================================
// Outer-envelope payload struct for Anthropic Messages API.
//
// The inner content trees (system, messages, tools) are Value-typed
// passthroughs because cache_control markers are inserted by the
// build*Value helpers during construction; expressing those marker
// insertions declaratively would require modeling the entire Anthropic
// content block taxonomy (text/image/thinking/tool_use/tool_result with
// per-block cache_control sidecars) as structs, which is a larger refactor.
// =============================================================================

const RequestPayload = struct {
    model: []const u8,
    max_tokens: u32,
    stream: bool = true,
    system: ?std.json.Value = null,
    messages: std.json.Value,
    tools: ?std.json.Value = null,
    temperature: ?f32 = null,
    thinking: ?Thinking = null,
    output_config: ?OutputConfig = null,
    metadata: ?Metadata = null,
    tool_choice: ?std.json.Value = null,
};

const Thinking = union(enum) {
    adaptive: struct { display: []const u8 },
    enabled: struct { budget_tokens: i64, display: []const u8 },
    disabled,

    pub fn jsonStringify(self: Thinking, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .adaptive => |a| {
                try jw.objectField("type");
                try jw.write("adaptive");
                try jw.objectField("display");
                try jw.write(a.display);
            },
            .enabled => |e| {
                try jw.objectField("type");
                try jw.write("enabled");
                try jw.objectField("budget_tokens");
                try jw.write(e.budget_tokens);
                try jw.objectField("display");
                try jw.write(e.display);
            },
            .disabled => {
                try jw.objectField("type");
                try jw.write("disabled");
            },
        }
        try jw.endObject();
    }
};

const OutputConfig = struct { effort: []const u8 };
const Metadata = struct { user_id: []const u8 };

const OwnedAnthropic = struct {
    allocator: std.mem.Allocator,
    payload: RequestPayload,
    owned_values: []std.json.Value,

    fn deinit(self: OwnedAnthropic) void {
        for (self.owned_values) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_values);
    }
};

fn buildOwnedAnthropic(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !OwnedAnthropic {
    var owned_values_list = std.ArrayList(std.json.Value).empty;
    errdefer {
        for (owned_values_list.items) |v| provider_json.freeValue(allocator, v);
        owned_values_list.deinit(allocator);
    }

    const compat = getAnthropicCompat(model);
    const cache_retention = resolveOptionsCacheRetention(options);
    const cache_control = try buildCacheControl(allocator, compat, cache_retention);
    defer if (cache_control) |value| provider_json.freeValue(allocator, value);

    const is_oauth = usesAnthropicOAuth(model, if (options) |stream_options| stream_options.api_key orelse "" else "");

    var system_owned: ?std.json.Value = null;
    if (try buildSystemPromptValue(allocator, context.system_prompt, is_oauth, cache_control)) |v| {
        try owned_values_list.append(allocator, v);
        system_owned = v;
    }

    const messages_value = try buildMessagesValue(allocator, context.messages, context.tools, is_oauth, cache_control, compat.allow_empty_signature);
    try owned_values_list.append(allocator, messages_value);

    var tools_owned: ?std.json.Value = null;
    if (context.tools) |tools| {
        const tool_cache_control = if (compat.supports_cache_control_on_tools) cache_control else null;
        const tv = try buildToolsValue(allocator, tools, is_oauth, compat.supports_eager_tool_input_streaming, tool_cache_control);
        try owned_values_list.append(allocator, tv);
        tools_owned = tv;
    }

    var temperature: ?f32 = null;
    var thinking: ?Thinking = null;
    var output_config: ?OutputConfig = null;
    var metadata: ?Metadata = null;
    var tool_choice_owned: ?std.json.Value = null;

    if (options) |stream_options| {
        const anthropic_opts = stream_options.providerOptions("anthropic");
        if (stream_options.temperature) |t| {
            if (anthropic_opts.thinking_enabled != true and compat.supports_temperature) temperature = t;
        }
        if (model.reasoning) {
            if (anthropic_opts.thinking_enabled == true) {
                const display = @tagName(anthropic_opts.thinking_display orelse types.AnthropicThinkingDisplay.summarized);
                if (supportsAdaptiveThinking(model)) {
                    thinking = .{ .adaptive = .{ .display = display } };
                    if (anthropic_opts.effort) |effort| {
                        output_config = .{ .effort = @tagName(effort) };
                    }
                } else {
                    thinking = .{ .enabled = .{
                        .budget_tokens = @intCast(anthropic_opts.thinking_budget_tokens orelse 1024),
                        .display = display,
                    } };
                }
            } else if (anthropic_opts.thinking_enabled == false) {
                thinking = .disabled;
            }
        }
        if (stream_options.metadata) |md| {
            if (md == .object) {
                if (md.object.get("user_id")) |user_id| {
                    if (user_id == .string) metadata = .{ .user_id = user_id.string };
                }
            }
        }
        if (anthropic_opts.tool_choice) |tc| {
            const tcv = try buildToolChoiceValue(allocator, tc, is_oauth);
            try owned_values_list.append(allocator, tcv);
            tool_choice_owned = tcv;
        }
    }

    const resolved_max_tokens: u32 = if (options) |stream_options|
        if (stream_options.max_tokens) |m| @intCast(m) else @intCast(model.max_tokens / 3)
    else
        @intCast(model.max_tokens / 3);

    const owned_values_slice = try owned_values_list.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .payload = .{
            .model = model.id,
            .max_tokens = resolved_max_tokens,
            .system = system_owned,
            .messages = messages_value,
            .tools = tools_owned,
            .temperature = temperature,
            .thinking = thinking,
            .output_config = output_config,
            .metadata = metadata,
            .tool_choice = tool_choice_owned,
        },
        .owned_values = owned_values_slice,
    };
}

pub fn buildPayloadJsonBytes(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    var owned = try buildOwnedAnthropic(allocator, model, context, options);
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

pub fn mapStopReason(reason: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.anthropic_mappings, reason, .error_reason);
}

fn applyProviderStopReason(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    reason: []const u8,
    explanation: ?[]const u8,
) !void {
    const mapped = mapStopReason(reason);
    output.stop_reason = mapped;
    if (mapped == .error_reason) {
        if (output.error_message) |existing| allocator.free(existing);
        if (explanation) |msg| {
            output.error_message = try allocator.dupe(u8, msg);
        } else {
            output.error_message = try std.fmt.allocPrint(allocator, "Provider stop_reason: {s}", .{reason});
        }
    } else if (output.error_message) |existing| {
        allocator.free(existing);
        output.error_message = null;
    }
}

fn supportsAdaptiveThinking(model: types.Model) bool {
    // Prefer the explicit compat flag when set; fall back to model ID heuristics.
    if (compatBoolField(model.compat, "forceAdaptiveThinking")) |flag| return flag;
    return std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null or
        std.mem.indexOf(u8, model.id, "opus-4-7") != null or
        std.mem.indexOf(u8, model.id, "opus-4.7") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4.6") != null;
}

fn buildToolChoiceValue(
    allocator: std.mem.Allocator,
    tool_choice: types.AnthropicToolChoice,
    is_oauth: bool,
) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    switch (tool_choice) {
        .auto => try putStringValue(allocator, &object, "type", "auto"),
        .any => try putStringValue(allocator, &object, "type", "any"),
        .none => try putStringValue(allocator, &object, "type", "none"),
        .tool => |name| {
            try putStringValue(allocator, &object, "type", "tool");
            try putStringValue(allocator, &object, "name", if (is_oauth) canonicalClaudeCodeToolName(name) else name);
        },
    }
    return .{ .object = object };
}

test "VAL-MSG-010 Anthropic skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
    const first_user = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const failed_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "partial" } },
        .{ .tool_call = .{ .id = "failed-tool", .name = "lookup", .arguments = .null } },
    };
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .user = .{ .content = &first_user, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude-3-7-sonnet-latest",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "anthropic-messages",
            .provider = "anthropic",
            .model = "claude-3-7-sonnet-latest",
            .usage = types.Usage.init(),
            .stop_reason = .aborted,
            .error_message = "aborted",
            .timestamp = 3,
        } },
        .{ .user = .{ .content = &final_user, .timestamp = 4 } },
    } }, null);
    defer provider_json.freeValue(allocator, payload);

    const messages = payload.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", messages.items[1].object.get("role").?.string);
}

test "buildRequestPayload includes system tools and cache control without default thinking" {
    const allocator = std.testing.allocator;

    var tool_params = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_params.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "string") });
    const tool_params_value = std.json.Value{ .object = tool_params };
    defer provider_json.freeValue(allocator, tool_params_value);

    const tools = &[_]types.Tool{.{
        .name = "read",
        .description = "Read a file",
        .parameters = tool_params_value,
    }};

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
        .tools = tools,
    };

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .max_tokens = 4096,
        .cache_retention = .long,
    });
    defer provider_json.freeValue(allocator, payload);

    const object = payload.object;
    try std.testing.expectEqualStrings("claude-3-7-sonnet-latest", object.get("model").?.string);
    try std.testing.expect(object.get("system").? == .array);
    try std.testing.expect(object.get("messages").? == .array);
    try std.testing.expect(object.get("tools").? == .array);
    try std.testing.expect(object.get("thinking") == null);
}

test "buildRequestPayload applies Claude Code stealth mode for oauth" {
    const allocator = std.testing.allocator;
    const oauth_token_placeholder = "placeholder-" ++ "sk" ++ "-ant-oat" ++ "-token";

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    const context = types.Context{
        .system_prompt = "Follow mission boundaries.",
        .messages = &[_]types.Message{},
        .tools = tools,
    };

    const model = types.Model{
        .id = "claude-3-5-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .api_key = oauth_token_placeholder,
    });
    defer provider_json.freeValue(allocator, payload);

    const system_val = payload.object.get("system").?;
    try std.testing.expect(system_val == .array);
    try std.testing.expect(system_val.array.items.len >= 2);

    const tools_val = payload.object.get("tools").?;
    try std.testing.expect(tools_val == .array);
    const first_tool = tools_val.array.items[0].object;
    try std.testing.expectEqualStrings("TodoWrite", first_tool.get("name").?.string);
}

test "parse anthropic stream emits text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":3}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .cost = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Hello", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("Hello", done.message.?.content[0].text.text);
    try std.testing.expectEqual(@as(u32, 10), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 5), done.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 2), done.message.?.usage.cache_read);
    try std.testing.expectEqual(@as(u32, 3), done.message.?.usage.cache_write);
    try std.testing.expectEqual(@as(u32, 20), done.message.?.usage.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00011685), done.message.?.usage.cost.total, 0.000000001);
}

test "parse anthropic stream handles compact data fields and provider errors" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: error\n" ++
        "data:{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad request\"}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqualStrings("invalid_request_error: bad request", error_event.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
}

test "parse anthropic-compatible stream preserves error stop reason message" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi_search_refusal\",\"usage\":{\"input_tokens\":9,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Sources:\\n- Result one\\n\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"sensitive\"},\"usage\":{\"output_tokens\":4}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .done) done_message = event.message.?;
    }

    try std.testing.expect(done_message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, done_message.?.stop_reason);
    try std.testing.expect(done_message.?.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, done_message.?.error_message.?, "sensitive") != null);
    try std.testing.expectEqualStrings("Sources:\n- Result one\n", done_message.?.content[0].text.text);
}

test "parse anthropic stream preserves frame-aware multiline data under shared SSE loop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        ": keepalive\n" ++
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multiline\",\"usage\":{\"input_tokens\":4,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: ignored_vendor_event\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ignored\"}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\n" ++
        "data: \"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Frame\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("Frame", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("msg_multiline", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("Frame", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 4), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 2), done.message.?.usage.output);
}

test "parse anthropic stream returns error for empty successful stream" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_empty\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqualStrings("Provider returned an empty assistant response", error_event.error_message.?);
}

test "parse anthropic stream emits tool call and thinking events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const oauth_token_placeholder = "placeholder-" ++ "sk" ++ "-ant-oat" ++ "-token";

    const body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"I should inspect the file.\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-1\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"TodoWrite\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"todos\\\":\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"item\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":20,\"output_tokens\":12}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) },
    }};

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
        .tools = tools,
    }, .{
        .api_key = oauth_token_placeholder,
    });

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    _ = stream_instance.next().?;
    _ = stream_instance.next().?;
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("todoWrite", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("item", tool_end.tool_call.?.arguments.object.get("todos").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[1] == .tool_call);
    try std.testing.expectEqualStrings("todoWrite", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("item", done.message.?.content[1].tool_call.arguments.object.get("todos").?.string);
    try std.testing.expect(done.message.?.tool_calls == null);
}

test "ISS-001 EOF mid-thinking preserves signature on terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_eof_thinking\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"partial signed reasoning\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-part-1\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-part-2\"}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial signed reasoning", delta.delta.?);
    const thinking_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqualStrings("partial signed reasoning", thinking_end.content.?);
    const terminal = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("InvalidAnthropicChunk", terminal.error_message.?);
    try std.testing.expectEqualStrings("msg_eof_thinking", terminal.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 1), terminal.message.?.content.len);
    try std.testing.expect(terminal.message.?.content[0] == .thinking);
    try std.testing.expectEqualStrings("partial signed reasoning", terminal.message.?.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("sig-part-1sig-part-2", types.thinkingSignature(terminal.message.?.content[0].thinking).?);
    try std.testing.expect(!terminal.message.?.content[0].thinking.redacted);
    try std.testing.expect(stream_instance.next() == null);
}

test "ISS-002 Anthropic content_index remains stable after block removal" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_content_index\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"intro\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_content_index\",\"name\":\"lookup\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"stable\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":8}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);

    const text_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(?u32, 0), text_start.content_index);

    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 0), text_delta.content_index);
    try std.testing.expectEqualStrings("intro", text_delta.delta.?);

    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(?u32, 0), text_end.content_index);
    try std.testing.expectEqualStrings("intro", text_end.content.?);

    const tool_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(?u32, 1), tool_start.content_index);

    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 1), tool_delta.content_index);
    try std.testing.expectEqualStrings("{\"query\":\"stable\"}", tool_delta.delta.?);

    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(?u32, 1), tool_end.content_index);
    try std.testing.expectEqualStrings("toolu_content_index", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("stable", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[0] == .text);
    try std.testing.expectEqualStrings("intro", done.message.?.content[0].text.text);
    try std.testing.expect(done.message.?.content[1] == .tool_call);
    try std.testing.expectEqualStrings("toolu_content_index", done.message.?.content[1].tool_call.id);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[1].tool_call.name);
    try std.testing.expectEqualStrings("stable", done.message.?.content[1].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(done.message.?.tool_calls == null);
    try std.testing.expect(stream_instance.next() == null);
}

test "parse anthropic stream coerces end_turn to tool_use when tool calls are present" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stop_tool\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_stop_coerce\",\"name\":\"lookup\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"coerce\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream_instance.next().?.event_type);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("lookup", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("coerce", tool_end.tool_call.?.arguments.object.get("query").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), done.message.?.content.len);
    try std.testing.expect(done.message.?.content[0] == .tool_call);
    try std.testing.expect(done.message.?.tool_calls == null);
    try std.testing.expect(stream_instance.next() == null);
}

test "ISS-003 kimi anthropic-compatible stream repairs malformed json and ignores unknown events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"not\":\"an anthropic event\"}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello \\_Kimi\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_kimi\",\"name\":\"run_terminal\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"echo \\_Kimi\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"unknown_tool_delta\",\"ignored\":\"safe\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    var saw_text_delta = false;
    var saw_tool_end = false;
    var saw_error = false;
    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .text_delta) {
            saw_text_delta = true;
            try std.testing.expectEqualStrings("Hello \\_Kimi", event.delta.?);
        } else if (event.event_type == .toolcall_end) {
            saw_tool_end = true;
            try std.testing.expectEqualStrings("run_terminal", event.tool_call.?.name);
            try std.testing.expectEqualStrings("echo \\_Kimi", event.tool_call.?.arguments.object.get("command").?.string);
        } else if (event.event_type == .error_event) {
            saw_error = true;
            if (event.error_message) |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "SyntaxError") == null);
            }
        } else if (event.event_type == .done) {
            done_message = event.message.?;
        }
    }

    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_tool_end);
    try std.testing.expect(!saw_error);
    try std.testing.expect(done_message != null);
    try std.testing.expectEqualStrings("kimi-coding", done_message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done_message.?.model);
    try std.testing.expectEqual(types.StopReason.tool_use, done_message.?.stop_reason);
}

test "ISS-003 kimi anthropic-compatible stream tolerates noncanonical chunk shapes" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi_noncanonical\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"review notes\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":99,\"delta\":{\"type\":\"unknown_delta\",\"payload\":\"ignored\"}}\n" ++
        "\n" ++
        "data: {\"control\":\"keepalive\",\"payload\":{\"ignored\":true}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":42}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_kimi_noncanonical\",\"name\":\"run_terminal\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"zig test\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"unknown_tool_delta\",\"ignored\":\"safe\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":6}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    var saw_text_delta = false;
    var saw_text_end = false;
    var saw_tool_end = false;
    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .text_delta) {
            saw_text_delta = true;
            try std.testing.expectEqualStrings("review notes", event.delta.?);
        } else if (event.event_type == .text_end) {
            saw_text_end = true;
            try std.testing.expectEqualStrings("review notes", event.content.?);
        } else if (event.event_type == .toolcall_end) {
            saw_tool_end = true;
            try std.testing.expectEqualStrings("run_terminal", event.tool_call.?.name);
            try std.testing.expectEqualStrings("zig test", event.tool_call.?.arguments.object.get("command").?.string);
        } else if (event.event_type == .error_event) {
            if (event.error_message) |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "InvalidAnthropicChunk") == null);
            }
            return error.UnexpectedKimiNoncanonicalError;
        } else if (event.event_type == .done) {
            done_message = event.message.?;
        }
    }

    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_text_end);
    try std.testing.expect(saw_tool_end);
    try std.testing.expect(done_message != null);
    try std.testing.expectEqualStrings("kimi-coding", done_message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done_message.?.model);
    try std.testing.expectEqual(types.StopReason.tool_use, done_message.?.stop_reason);
    try std.testing.expectEqualStrings("review notes", done_message.?.content[0].text.text);
}

test "parse kimi anthropic-compatible stream ignores orphan tool input deltas after tool stop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_kimi_orphan_tool_delta\",\"usage\":{\"input_tokens\":74,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_kimi_code_review\",\"name\":\"ls\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/Users/davirian/dev/active/pi-mono-davirain\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/tmp/duplicate-should-be-ignored\\\"}\"}}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":106}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    var tool_end_count: usize = 0;
    var tool_delta_count: usize = 0;
    var done_message: ?types.AssistantMessage = null;
    while (stream_instance.next()) |event| {
        if (event.event_type == .toolcall_delta) {
            tool_delta_count += 1;
        } else if (event.event_type == .toolcall_end) {
            tool_end_count += 1;
            try std.testing.expectEqualStrings("tool_kimi_code_review", event.tool_call.?.id);
            try std.testing.expectEqualStrings("ls", event.tool_call.?.name);
            try std.testing.expectEqualStrings("/Users/davirian/dev/active/pi-mono-davirain", event.tool_call.?.arguments.object.get("path").?.string);
        } else if (event.event_type == .error_event) {
            if (event.error_message) |message| {
                try std.testing.expect(std.mem.indexOf(u8, message, "InvalidAnthropicChunk") == null);
            }
            return error.UnexpectedKimiOrphanToolDeltaError;
        } else if (event.event_type == .done) {
            done_message = event.message.?;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), tool_delta_count);
    try std.testing.expectEqual(@as(usize, 1), tool_end_count);
    try std.testing.expect(done_message != null);
    try std.testing.expectEqualStrings("kimi-coding", done_message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done_message.?.model);
    try std.testing.expectEqual(types.StopReason.tool_use, done_message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), done_message.?.content.len);
    try std.testing.expect(done_message.?.content[0] == .tool_call);
    try std.testing.expectEqualStrings("tool_kimi_code_review", done_message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("ls", done_message.?.content[0].tool_call.name);
    try std.testing.expectEqualStrings("/Users/davirian/dev/active/pi-mono-davirain", done_message.?.content[0].tool_call.arguments.object.get("path").?.string);
    try std.testing.expect(done_message.?.tool_calls == null);
}

test "ISS-003 kimi anthropic-compatible stream finalizes recoverable partial EOF" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial code review\"}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .api_key = "placeholder-kimi-auth-value",
    });

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial code review", delta.delta.?);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial code review", text_end.content.?);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqualStrings("kimi-coding", done.message.?.provider);
    try std.testing.expectEqualStrings("kimi-for-coding", done.message.?.model);
    try std.testing.expectEqualStrings("partial code review", done.message.?.content[0].text.text);
    try std.testing.expect(stream_instance.next() == null);
}

test "ISS-003 first-party anthropic unmatched lifecycle remains strict" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_anthropic_strict\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqualStrings("InvalidAnthropicChunk", error_event.error_message.?);
    try std.testing.expectEqualStrings("anthropic", error_event.message.?.provider);
    try std.testing.expectEqualStrings("claude-3-7-sonnet-latest", error_event.message.?.model);
    try std.testing.expect(stream_instance.next() == null);
}

test "ISS-003 first-party anthropic malformed json remains strict" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_anthropic_strict_json\"}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"before strict failure\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"repair \\_blocked\"}}\n" ++
        "\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("before strict failure", delta.delta.?);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("before strict failure", text_end.content.?);
    const error_event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("anthropic", error_event.message.?.provider);
    try std.testing.expectEqualStrings("claude-3-7-sonnet-latest", error_event.message.?.model);
    try std.testing.expectEqual(@as(usize, 1), error_event.message.?.content.len);
    try std.testing.expectEqualStrings("before strict failure", error_event.message.?.content[0].text.text);
    try std.testing.expect(stream_instance.next() == null);
}

test "mapStopReason covers anthropic variants" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("end_turn"));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason("max_tokens"));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReason("tool_use"));
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("pause_turn"));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReason("unexpected"));
}

test "buildRequestPayload adds eager_input_streaming by default" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
        .tools = tools,
    }, null);
    defer provider_json.freeValue(allocator, payload);

    const first_tool = payload.object.get("tools").?.array.items[0];
    try std.testing.expect(first_tool == .object);
    try std.testing.expectEqual(true, first_tool.object.get("eager_input_streaming").?.bool);
    const cache_control = first_tool.object.get("cache_control").?;
    try std.testing.expect(cache_control == .object);
    try std.testing.expectEqualStrings("ephemeral", cache_control.object.get("type").?.string);
}

test "fireworks compat omits unsupported tool cache control and eager streaming fields" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "lookup",
        .description = "Look up a value",
        .parameters = tool_schema_value,
    }};

    const model = types.Model{
        .id = "accounts/fireworks/models/kimi-k2p6",
        .name = "Kimi K2.6",
        .api = "anthropic-messages",
        .provider = "fireworks",
        .base_url = "https://api.fireworks.ai/inference",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 262000,
        .max_tokens = 262000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
        .tools = tools,
    }, null);
    defer provider_json.freeValue(allocator, payload);

    const first_tool = payload.object.get("tools").?.array.items[0];
    try std.testing.expect(first_tool == .object);
    try std.testing.expect(first_tool.object.get("eager_input_streaming") == null);
    try std.testing.expect(first_tool.object.get("cache_control") == null);
}

test "github-copilot compat disables eager_input_streaming and enables legacy beta header" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "supportsEagerToolInputStreaming"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "github-copilot",
        .base_url = "https://api.githubcopilot.com/anthropic",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
        .compat = compat_value,
    };

    const context = types.Context{
        .messages = &[_]types.Message{},
        .tools = tools,
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    const first_tool = payload.object.get("tools").?.array.items[0];
    try std.testing.expect(first_tool == .object);
    try std.testing.expect(first_tool.object.get("eager_input_streaming") == null);

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applyDefaultAnthropicHeaders(allocator, &headers, model, context, null);
    try std.testing.expectEqualStrings(
        "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14",
        headers.get("anthropic-beta").?,
    );
}

test "kimi-coding api-key headers preserve truthful client identity" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applyBaseAnthropicHeaders(allocator, &headers, model);
    try applyAuthHeaders(allocator, &headers, model, .{ .api_key = "placeholder-auth-value" });
    try applyDefaultAnthropicHeaders(allocator, &headers, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "placeholder-auth-value",
    });

    try std.testing.expect(headers.get("user-agent") == null);
    try std.testing.expectEqualStrings("placeholder-auth-value", headers.get("x-api-key").?);
    try std.testing.expect(headers.get("Authorization") == null);
    try std.testing.expect(headers.get("anthropic-beta") == null);
    try std.testing.expect(headers.get("anthropic-dangerous-direct-browser-access") == null);
}

test "fireworks session affinity header follows cache retention" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "accounts/fireworks/models/kimi-k2p6",
        .name = "Kimi K2.6",
        .api = "anthropic-messages",
        .provider = "fireworks",
        .base_url = "https://api.fireworks.ai/inference",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 262000,
        .max_tokens = 262000,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applySessionAffinityHeaders(allocator, &headers, model, .{
        .session_id = "fireworks-session-1",
        .cache_retention = .short,
    });
    try std.testing.expectEqualStrings("fireworks-session-1", headers.get("x-session-affinity").?);

    var disabled_headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &disabled_headers);

    try applySessionAffinityHeaders(allocator, &disabled_headers, model, .{
        .session_id = "fireworks-session-2",
        .cache_retention = .none,
    });
    try std.testing.expect(disabled_headers.get("x-session-affinity") == null);
}

test "non-fireworks anthropic session affinity defaults remain disabled" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applySessionAffinityHeaders(allocator, &headers, model, .{
        .session_id = "anthropic-session-1",
        .cache_retention = .short,
    });
    try std.testing.expect(headers.get("x-session-affinity") == null);
}

test "cloudflare anthropic gateway session affinity defaults enabled" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "cloudflare-ai-gateway",
        .base_url = "https://gateway.ai.cloudflare.com/v1/account/gateway/anthropic",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applySessionAffinityHeaders(allocator, &headers, model, .{
        .session_id = "cloudflare-anthropic-session",
        .cache_retention = .short,
    });
    try std.testing.expectEqualStrings("cloudflare-anthropic-session", headers.get("x-session-affinity").?);
}

test "kimi-coding api-key payload does not inject Claude Code identity" {
    const allocator = std.testing.allocator;

    const tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "todoWrite",
        .description = "Write todos",
        .parameters = tool_schema_value,
    }};

    const model = types.Model{
        .id = "kimi-for-coding",
        .name = "Kimi For Coding",
        .api = "anthropic-messages",
        .provider = "kimi-coding",
        .base_url = "https://api.kimi.com/coding",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 262144,
        .max_tokens = 32768,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .system_prompt = "Identify yourself according to the selected provider.",
        .messages = &[_]types.Message{},
        .tools = tools,
    }, .{
        .api_key = "placeholder-auth-value",
    });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expectEqualStrings("kimi-for-coding", payload.object.get("model").?.string);
    const system = payload.object.get("system").?;
    try std.testing.expect(system == .array);
    try std.testing.expectEqual(@as(usize, 1), system.array.items.len);
    const system_text = system.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, system_text, "Claude Code") == null);
    try std.testing.expect(std.mem.indexOf(u8, system_text, "Anthropic") == null);

    const first_tool = payload.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("todoWrite", first_tool.get("name").?.string);
}

test "buildRequestPayload omits anthropic long cache ttl when compat disables it" {
    const allocator = std.testing.allocator;

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "supportsLongCacheRetention"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
        .compat = compat_value,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .system_prompt = "Cache me",
        .messages = &[_]types.Message{},
    }, .{
        .cache_retention = .long,
    });
    defer provider_json.freeValue(allocator, payload);

    const system = payload.object.get("system").?.array.items[0];
    try std.testing.expect(system == .object);
    const cache_control = system.object.get("cache_control").?;
    try std.testing.expect(cache_control == .object);
    try std.testing.expect(cache_control.object.get("ttl") == null);
}

test "buildRequestPayload supports disabled thinking and temperature" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .temperature = 0.25,
        .provider = .{ .anthropic = .{ .thinking_enabled = false } },
    });
    defer provider_json.freeValue(allocator, payload);

    const thinking = payload.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("disabled", thinking.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 0.25), payload.object.get("temperature").?.float);
}

test "buildRequestPayload supports adaptive thinking effort" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-opus-4-6",
        .name = "Claude Opus 4.6",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .provider = .{ .anthropic = .{
            .thinking_enabled = true,
            .effort = .max,
        } },
    });
    defer provider_json.freeValue(allocator, payload);

    const thinking = payload.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("adaptive", thinking.get("type").?.string);
    try std.testing.expectEqualStrings("summarized", thinking.get("display").?.string);
    const output_config = payload.object.get("output_config").?.object;
    try std.testing.expectEqualStrings("max", output_config.get("effort").?.string);
    try std.testing.expect(payload.object.get("temperature") == null);
}

test "buildRequestPayload supports budget thinking display and tool choice" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .provider = .{ .anthropic = .{
            .thinking_enabled = true,
            .thinking_budget_tokens = 4096,
            .thinking_display = .omitted,
            .tool_choice = .{ .tool = "todoWrite" },
        } },
    });
    defer provider_json.freeValue(allocator, payload);

    const thinking = payload.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("enabled", thinking.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 4096), thinking.get("budget_tokens").?.integer);
    try std.testing.expectEqualStrings("omitted", thinking.get("display").?.string);

    const tool_choice = payload.object.get("tool_choice").?.object;
    try std.testing.expectEqualStrings("tool", tool_choice.get("type").?.string);
    try std.testing.expectEqualStrings("todoWrite", tool_choice.get("name").?.string);
}

test "applyDefaultAnthropicHeaders adds interleaved thinking beta for legacy models" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer deinitOwnedHeaders(allocator, &headers);

    try applyDefaultAnthropicHeaders(allocator, &headers, model, .{
        .messages = &[_]types.Message{},
    }, .{
        .provider = .{ .anthropic = .{ .interleaved_thinking = true } },
    });

    try std.testing.expectEqualStrings("interleaved-thinking-2025-05-14", headers.get("anthropic-beta").?);
}

test "resolveStreamOptions falls back to env api key before building payload" {
    const allocator = std.testing.allocator;
    const oauth_token_placeholder = "placeholder-" ++ "sk" ++ "-ant-oat" ++ "-env-token";

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_OAUTH_TOKEN", oauth_token_placeholder);

    const model = types.Model{
        .id = "claude-3-5-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const resolved = try resolveStreamOptionsWithEnvMap(allocator, model, null, &env_map);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings(oauth_token_placeholder, resolved.options.?.api_key.?);

    const payload = try buildRequestPayload(allocator, model, .{
        .messages = &[_]types.Message{},
    }, resolved.options);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("system").? == .array);
}

test "stream on_response receives actual response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_headers\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n" ++
        "\n";

    var server = try ResponseHeaderServer.init(
        io,
        "x-request-id: req_123\r\nanthropic-processing-ms: 17\r\n",
        body,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    const user_content = [_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }};
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &user_content,
                .timestamp = 1,
            } },
        },
    };

    OnResponseCapture.reset();

    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{
        .api_key = "test-key",
        .on_response = &OnResponseCapture.callback,
    });
    defer stream.deinit();

    try drainStreamAndFreeDoneMessage(allocator, &stream);

    try std.testing.expect(OnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 200), OnResponseCapture.status);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const redacted_secret_placeholder = "sk" ++ "-anthropic-secret";
    const body = "{\"type\":\"error\",\"error\":{\"message\":\"bad request\",\"authorization\":\"Bearer " ++ redacted_secret_placeholder ++ "\",\"request_id\":\"req_anthropic_random_123456\"},\"trace\":\"/Users/alice/pi/anthropic.zig\"}";
    var server = try provider_error.TestStatusServer.init(io, 401, "Unauthorized", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 401: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "bad request") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, redacted_secret_placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_anthropic_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("anthropic-messages", result.api);
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    context: types.Context,
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

    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }

    stream_ptr.push(.{ .event_type = .start });

    var handler = AnthropicSseFrameHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .active_blocks = &active_blocks,
        .model = model,
        .context = context,
        .options = options,
    };
    const loop_result = sse_loop.runFrames(allocator, AnthropicSseFrameHandler, &handler, streaming, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
            return;
        },
    };
    if (loop_result == .stopped) {
        return;
    }

    if (active_blocks.items.len > 0) {
        if (shouldTolerateNoncanonicalAnthropicChunk(model)) {
            try finalizeOutputFromPartials(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model);
            if (output.content.len == 0 and output.tool_calls == null) {
                const error_message = try allocator.dupe(u8, "Provider returned an empty assistant response");
                output.stop_reason = .error_reason;
                output.error_message = error_message;
                stream_ptr.push(.{
                    .event_type = .error_event,
                    .error_message = error_message,
                    .message = output,
                });
                stream_ptr.end(output);
                return;
            }
            stream_ptr.push(.{
                .event_type = .done,
                .message = output,
            });
            stream_ptr.end(output);
            return;
        } else {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, AnthropicError.InvalidAnthropicChunk);
            return;
        }
    }

    if (!shouldTolerateNoncanonicalAnthropicChunk(model) and handler.saw_message_start and !handler.saw_message_stop) {
        const error_message = try allocator.dupe(u8, "Anthropic stream ended before message_stop");
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, error_message);
        return;
    }

    if (content_blocks.items.len == 0 and tool_calls.items.len == 0) {
        const error_message = try allocator.dupe(u8, "Provider returned an empty assistant response");
        output.stop_reason = .error_reason;
        output.error_message = error_message;
        stream_ptr.push(.{
            .event_type = .error_event,
            .error_message = error_message,
            .message = output,
        });
        stream_ptr.end(output);
        return;
    }

    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });
    finalize.calculateCost(model, &output.usage);
    // Tool calls live inline in output.content; legacy AssistantMessage.tool_calls
    // is intentionally left null. tool_calls ArrayList holds borrow-only copies
    // and tool_calls.deinit only releases its buffer.

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const AnthropicSseFrameHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    saw_message_start: bool = false,
    saw_message_stop: bool = false,

    pub fn handleFrame(self: *AnthropicSseFrameHandler, sse_event: []const u8, data: []const u8) !bool {
        const event_finished = try processAnthropicSseEvent(
            self.allocator,
            self.stream_ptr,
            sse_event,
            data,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.model,
            self.context,
            self.options,
            &self.saw_message_start,
            &self.saw_message_stop,
        );
        return !event_finished;
    }

    pub fn handleRuntimeFailure(self: *AnthropicSseFrameHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.model,
            err,
        );
    }
};

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
) !void {
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .thinking => |thinking| {
                const text = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null;
                try content_blocks.append(allocator, .{ .thinking = .{ .thinking = text, .signature = signature, .redacted = thinking.redacted } });
                stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = text });
            },
            .tool_call => |tool| {
                var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
                defer parsed_arguments.deinit();
                const arguments = try provider_json.cloneValue(allocator, parsed_arguments.value);
                const final_tool_call = blk: {
                    errdefer provider_json.freeValue(allocator, arguments);
                    const id = try allocator.dupe(u8, tool.id);
                    errdefer allocator.free(id);
                    const name = try allocator.dupe(u8, tool.name);
                    errdefer allocator.free(name);
                    break :blk types.ToolCall{
                        .id = id,
                        .name = name,
                        .arguments = arguments,
                    };
                };
                try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, final_tool_call);
                stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
            },
        }
    }

    try finalize.finalizeOutput(allocator, output, .{ .content_blocks = content_blocks, .tool_calls = tool_calls }, .{ .content_transfer = .when_output_empty, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = false });
    finalize.calculateCost(model, &output.usage);
    // Tool calls are emitted inline; legacy field intentionally null.
}
fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn isAnthropicMessageSseEvent(event_name: []const u8) bool {
    return std.mem.eql(u8, event_name, "message_start") or
        std.mem.eql(u8, event_name, "message_delta") or
        std.mem.eql(u8, event_name, "message_stop") or
        std.mem.eql(u8, event_name, "content_block_start") or
        std.mem.eql(u8, event_name, "content_block_delta") or
        std.mem.eql(u8, event_name, "content_block_stop");
}

fn processAnthropicSseEvent(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    sse_event: []const u8,
    data: []const u8,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    saw_message_start: *bool,
    saw_message_stop: *bool,
) !bool {
    if (data.len == 0) return false;
    if (std.mem.eql(u8, std.mem.trim(u8, data, " \t\r\n"), "[DONE]")) return true;
    const tolerate_noncanonical = shouldTolerateNoncanonicalAnthropicChunk(model);
    if (sse_event.len > 0 and
        !std.mem.eql(u8, sse_event, "error") and
        !isAnthropicMessageSseEvent(sse_event))
    {
        return false;
    }

    var parsed = parseAnthropicSseJson(allocator, data, tolerate_noncanonical) catch |err| {
        if (std.mem.eql(u8, sse_event, "error")) {
            try emitAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, data);
            return true;
        }
        return err;
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return AnthropicError.InvalidAnthropicChunk;

    if (std.mem.eql(u8, sse_event, "error")) {
        const error_message = try formatAnthropicStreamError(allocator, value, data);
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
        return true;
    }

    const event_type = value.object.get("type") orelse {
        if (value.object.get("error") != null) {
            const error_message = try formatAnthropicStreamError(allocator, value, data);
            try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
            return true;
        }
        if (tolerate_noncanonical) return false;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (event_type != .string) {
        if (tolerate_noncanonical) return false;
        return AnthropicError.InvalidAnthropicChunk;
    }

    if (std.mem.eql(u8, event_type.string, "message_start")) {
        saw_message_start.* = true;
        if (value.object.get("message")) |message_value| {
            if (message_value == .object) {
                if (message_value.object.get("id")) |id_value| {
                    if (id_value == .string and output.response_id == null) {
                        output.response_id = try allocator.dupe(u8, id_value.string);
                    }
                }
                if (message_value.object.get("usage")) |usage_value| {
                    updateUsage(&output.usage, usage_value);
                    finalize.calculateCost(model, &output.usage);
                }
            }
        }
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_start")) {
        try handleContentBlockStart(allocator, active_blocks, stream_ptr, value, context, options, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_delta")) {
        try handleContentBlockDelta(allocator, active_blocks, stream_ptr, value, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "content_block_stop")) {
        try handleContentBlockStop(allocator, active_blocks, content_blocks, tool_calls, stream_ptr, value, tolerate_noncanonical);
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "message_delta")) {
        if (value.object.get("delta")) |delta_value| {
            if (delta_value == .object) {
                if (delta_value.object.get("stop_reason")) |stop_reason| {
                    if (stop_reason == .string) {
                        var explanation: ?[]const u8 = null;
                        if (delta_value.object.get("stop_details")) |stop_details| {
                            if (stop_details == .object) {
                                if (stop_details.object.get("explanation")) |exp| {
                                    if (exp == .string) explanation = exp.string;
                                }
                            }
                        }
                        try applyProviderStopReason(allocator, output, stop_reason.string, explanation);
                    }
                }
            }
        }
        if (value.object.get("usage")) |usage_value| {
            updateUsage(&output.usage, usage_value);
        }
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "message_stop")) {
        saw_message_stop.* = true;
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "ping")) {
        return false;
    }

    if (std.mem.eql(u8, event_type.string, "error")) {
        const error_message = try formatAnthropicStreamError(allocator, value, data);
        try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
        return true;
    }

    return false;
}

fn parseAnthropicSseJson(
    allocator: std.mem.Allocator,
    data: []const u8,
    tolerate_noncanonical: bool,
) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (tolerate_noncanonical) {
        return json_parse.parseJsonWithRepair(allocator, trimmed);
    }
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{ .allocate = .alloc_always });
}

fn emitAnthropicStreamError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    data: []const u8,
) !void {
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, data);
    defer allocator.free(detail);
    const error_message = try std.fmt.allocPrint(allocator, "Provider stream error: {s}", .{detail});
    try emitOwnedAnthropicStreamError(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, error_message);
}

fn emitOwnedAnthropicStreamError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    error_message: []const u8,
) !void {
    try finalizeOutputFromPartials(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model);
    output.stop_reason = .error_reason;
    output.error_message = error_message;
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = output.*,
    });
    stream_ptr.end(output.*);
}

fn formatAnthropicStreamError(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    raw: []const u8,
) ![]u8 {
    if (value == .object) {
        if (value.object.get("error")) |error_value| {
            if (error_value == .object) {
                const error_type = if (error_value.object.get("type")) |type_value|
                    if (type_value == .string) type_value.string else "error"
                else
                    "error";
                const message = if (error_value.object.get("message")) |message_value|
                    if (message_value == .string) message_value.string else raw
                else
                    raw;
                const detail = try provider_error.sanitizeProviderErrorDetail(allocator, message);
                defer allocator.free(detail);
                return std.fmt.allocPrint(allocator, "{s}: {s}", .{ error_type, detail });
            }
        }
        if (value.object.get("message")) |message_value| {
            if (message_value == .string) return provider_error.sanitizeProviderErrorDetail(allocator, message_value.string);
        }
    }
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, raw);
    defer allocator.free(detail);
    return std.fmt.allocPrint(allocator, "Provider stream error: {s}", .{detail});
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    context: types.Context,
    options: ?types.StreamOptions,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);
    const content_block = value.object.get("content_block") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (content_block != .object) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const block_type = content_block.object.get("type") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (block_type != .string) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }

    const event_index = anthropic_index;
    if (std.mem.eql(u8, block_type.string, "text")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .text = std.ArrayList(u8).empty },
        });
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "thinking")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = std.ArrayList(u8).empty,
                .signature = null,
                .redacted = false,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "redacted_thinking")) {
        const signature = if (content_block.object.get("data")) |data_value|
            if (data_value == .string) try allocator.dupe(u8, data_value.string) else null
        else
            null;
        var text = std.ArrayList(u8).empty;
        try text.appendSlice(allocator, "[Reasoning redacted]");
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = text,
                .signature = signature,
                .redacted = true,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return;
    }

    if (std.mem.eql(u8, block_type.string, "tool_use")) {
        const id_value = content_block.object.get("id") orelse return AnthropicError.InvalidAnthropicChunk;
        const name_value = content_block.object.get("name") orelse return AnthropicError.InvalidAnthropicChunk;
        if (id_value != .string or name_value != .string) return AnthropicError.InvalidAnthropicChunk;
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .tool_call = .{
                .id = try allocator.dupe(u8, id_value.string),
                .name = try normalizeIncomingToolName(allocator, name_value.string, context.tools, options),
                .partial_json = std.ArrayList(u8).empty,
            } },
        });
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(event_index) });
        return;
    }
}

fn handleContentBlockDelta(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);
    const delta_value = value.object.get("delta") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (delta_value != .object) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const delta_type = delta_value.object.get("type") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (delta_type != .string) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    var entry: *BlockEntry = undefined;
    if (findActiveBlockIndex(active_blocks, anthropic_index)) |found_index| {
        entry = &active_blocks.items[found_index];
    } else {
        if (tolerate_noncanonical) {
            if (!isSupportedAnthropicDeltaType(delta_type.string)) return;
            if (std.mem.eql(u8, delta_type.string, "input_json_delta")) return;
            entry = try createImplicitActiveBlock(allocator, active_blocks, stream_ptr, anthropic_index, delta_type.string);
        } else {
            return AnthropicError.InvalidAnthropicChunk;
        }
    }

    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
        const text_value = delta_value.object.get("text") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (text_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .text) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.text.appendSlice(allocator, text_value.string);
        stream_ptr.push(.{
            .event_type = .text_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, text_value.string),
            .owns_delta = true,
        });
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
        const thinking_value = delta_value.object.get("thinking") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (thinking_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .thinking) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.thinking.text.appendSlice(allocator, thinking_value.string);
        stream_ptr.push(.{
            .event_type = .thinking_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, thinking_value.string),
            .owns_delta = true,
        });
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "signature_delta")) {
        const signature_value = delta_value.object.get("signature") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (signature_value != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .thinking) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block.thinking.signature) |existing| {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, signature_value.string });
            allocator.free(existing);
            entry.block.thinking.signature = combined;
        } else {
            entry.block.thinking.signature = try allocator.dupe(u8, signature_value.string);
        }
        return;
    }

    if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
        const partial_json = delta_value.object.get("partial_json") orelse {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        };
        if (partial_json != .string) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        if (entry.block != .tool_call) {
            if (tolerate_noncanonical) return;
            return AnthropicError.InvalidAnthropicChunk;
        }
        try entry.block.tool_call.partial_json.appendSlice(allocator, partial_json.string);
        stream_ptr.push(.{
            .event_type = .toolcall_delta,
            .content_index = @intCast(entry.event_index),
            .delta = try allocator.dupe(u8, partial_json.string),
            .owns_delta = true,
        });
        return;
    }
}

fn isSupportedAnthropicDeltaType(delta_type: []const u8) bool {
    return std.mem.eql(u8, delta_type, "text_delta") or
        std.mem.eql(u8, delta_type, "thinking_delta") or
        std.mem.eql(u8, delta_type, "signature_delta") or
        std.mem.eql(u8, delta_type, "input_json_delta");
}

fn createImplicitActiveBlock(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    anthropic_index: usize,
    delta_type: []const u8,
) !*BlockEntry {
    const event_index = anthropic_index;
    if (std.mem.eql(u8, delta_type, "text_delta")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .text = std.ArrayList(u8).empty },
        });
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(event_index) });
        return &active_blocks.items[active_blocks.items.len - 1];
    }
    if (std.mem.eql(u8, delta_type, "thinking_delta") or std.mem.eql(u8, delta_type, "signature_delta")) {
        try active_blocks.append(allocator, .{
            .anthropic_index = anthropic_index,
            .event_index = event_index,
            .block = .{ .thinking = .{
                .text = std.ArrayList(u8).empty,
                .signature = null,
                .redacted = false,
            } },
        });
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(event_index) });
        return &active_blocks.items[active_blocks.items.len - 1];
    }
    return AnthropicError.InvalidAnthropicChunk;
}

fn handleContentBlockStop(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    tolerate_noncanonical: bool,
) !void {
    const index_value = value.object.get("index") orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    if (index_value != .integer) {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    }
    const anthropic_index: usize = @intCast(index_value.integer);

    const remove_index = findActiveBlockIndex(active_blocks, anthropic_index) orelse {
        if (tolerate_noncanonical) return;
        return AnthropicError.InvalidAnthropicChunk;
    };
    var entry = active_blocks.orderedRemove(remove_index);
    defer deinitCurrentBlock(allocator, &entry.block);

    switch (entry.block) {
        .text => |text| {
            const owned = try allocator.dupe(u8, text.items);
            try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
            stream_ptr.push(.{
                .event_type = .text_end,
                .content_index = @intCast(entry.event_index),
                .content = owned,
            });
        },
        .thinking => |thinking| {
            const text = try allocator.dupe(u8, thinking.text.items);
            const signature = if (thinking.signature) |sig| try allocator.dupe(u8, sig) else null;
            try content_blocks.append(allocator, .{ .thinking = .{
                .thinking = text,
                .signature = signature,
                .redacted = thinking.redacted,
            } });
            stream_ptr.push(.{
                .event_type = .thinking_end,
                .content_index = @intCast(entry.event_index),
                .content = text,
            });
        },
        .tool_call => |tool| {
            var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
            defer parsed_arguments.deinit();
            const arguments = try provider_json.cloneValue(allocator, parsed_arguments.value);
            const final_tool_call = blk: {
                errdefer provider_json.freeValue(allocator, arguments);
                const id = try allocator.dupe(u8, tool.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, tool.name);
                errdefer allocator.free(name);
                break :blk types.ToolCall{
                    .id = id,
                    .name = name,
                    .arguments = arguments,
                };
            };
            try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, final_tool_call);
            stream_ptr.push(.{
                .event_type = .toolcall_end,
                .content_index = @intCast(entry.event_index),
                .tool_call = final_tool_call,
            });
        },
    }
}

fn getAnthropicCompat(model: types.Model) AnthropicCompat {
    const is_fireworks = std.mem.eql(u8, model.provider, "fireworks");
    const is_cloudflare_ai_gateway_anthropic =
        std.mem.eql(u8, model.provider, "cloudflare-ai-gateway") and
        std.mem.indexOf(u8, model.base_url, "anthropic") != null;

    return .{
        .supports_eager_tool_input_streaming = compatBoolField(model.compat, "supportsEagerToolInputStreaming") orelse !is_fireworks,
        .supports_long_cache_retention = compatBoolField(model.compat, "supportsLongCacheRetention") orelse !is_fireworks,
        .send_session_affinity_headers = compatBoolField(model.compat, "sendSessionAffinityHeaders") orelse (is_fireworks or is_cloudflare_ai_gateway_anthropic),
        .supports_cache_control_on_tools = compatBoolField(model.compat, "supportsCacheControlOnTools") orelse !is_fireworks,
        .supports_temperature = compatBoolField(model.compat, "supportsTemperature") orelse true,
        .allow_empty_signature = compatBoolField(model.compat, "allowEmptySignature") orelse false,
    };
}

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn buildCacheControl(
    allocator: std.mem.Allocator,
    compat: AnthropicCompat,
    retention: types.CacheRetention,
) !?std.json.Value {
    return anthropic_json.buildCacheControl(allocator, .{
        .supports_eager_tool_input_streaming = compat.supports_eager_tool_input_streaming,
        .supports_long_cache_retention = compat.supports_long_cache_retention,
    }, retention);
}

fn processCacheRetentionEnv() ?[]const u8 {
    const value = std.c.getenv("PI_CACHE_RETENTION") orelse return null;
    return std.mem.span(value);
}

fn resolveCacheRetention(cache_retention: types.CacheRetention, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return switch (cache_retention) {
        .unset => if (pi_cache_retention_env) |value|
            if (std.mem.eql(u8, value, "long")) .long else .short
        else
            .short,
        .none, .short, .long => cache_retention,
    };
}

fn resolveOptionsCacheRetention(options: ?types.StreamOptions) types.CacheRetention {
    return resolveCacheRetention(if (options) |stream_options| stream_options.cache_retention else .unset, processCacheRetentionEnv());
}

fn buildSystemPromptValue(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    is_oauth: bool,
    cache_control: ?std.json.Value,
) !?std.json.Value {
    return anthropic_json.buildSystemPromptValue(allocator, system_prompt, is_oauth, cache_control);
}

fn buildMessagesValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    is_oauth: bool,
    cache_control: ?std.json.Value,
    allow_empty_signature: bool,
) !std.json.Value {
    return anthropic_json.buildMessagesValue(allocator, messages, tools, is_oauth, cache_control, allow_empty_signature);
}

fn buildUserMessageValue(allocator: std.mem.Allocator, user: types.UserMessage) !std.json.Value {
    return anthropic_json.buildUserMessageValue(allocator, user);
}

fn buildAssistantMessageValue(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
    is_oauth: bool,
    allow_empty_signature: bool,
) !std.json.Value {
    return anthropic_json.buildAssistantMessageValue(allocator, assistant, is_oauth, allow_empty_signature);
}

fn buildToolResultUserMessageValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
    return anthropic_json.buildToolResultUserMessageValue(allocator, messages);
}

fn buildToolResultContentValue(allocator: std.mem.Allocator, content: []const types.ContentBlock) !std.json.Value {
    return anthropic_json.buildToolResultContentValue(allocator, content);
}

fn buildToolsValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    is_oauth: bool,
    supports_eager_tool_input_streaming: bool,
    cache_control: ?std.json.Value,
) !std.json.Value {
    return anthropic_json.buildToolsValue(allocator, tools, is_oauth, supports_eager_tool_input_streaming, cache_control);
}

fn applyAuthHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    const api_key = if (options) |stream_options| stream_options.api_key orelse "" else "";
    if (api_key.len == 0) return;

    if (std.mem.eql(u8, model.provider, "cloudflare-ai-gateway")) {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(authorization);
        try putOwnedHeader(allocator, headers, "cf-aig-authorization", authorization);
    } else if (std.mem.eql(u8, model.provider, "github-copilot") or usesAnthropicOAuth(model, api_key)) {
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(authorization);
        try putOwnedHeader(allocator, headers, "Authorization", authorization);
    } else {
        try putOwnedHeader(allocator, headers, "x-api-key", api_key);
    }
}

fn applyBaseAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
) !void {
    try putOwnedHeader(allocator, headers, "Content-Type", "application/json");
    try putOwnedHeader(allocator, headers, "Accept", "application/json");
    if (!isKimiCodingProvider(model)) {
        try putOwnedHeader(allocator, headers, "anthropic-dangerous-direct-browser-access", "true");
    }
    try putOwnedHeader(allocator, headers, "anthropic-version", "2023-06-01");
}

fn applyDefaultAnthropicHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !void {
    const api_key = if (options) |stream_options| stream_options.api_key orelse "" else "";
    if (try buildAnthropicBetaHeader(allocator, model, context, options, api_key)) |beta_header| {
        defer allocator.free(beta_header);
        try putOwnedHeader(allocator, headers, "anthropic-beta", beta_header);
    }

    if (usesAnthropicOAuth(model, api_key)) {
        const user_agent = try std.fmt.allocPrint(allocator, "claude-cli/{s}", .{CLAUDE_CODE_VERSION});
        defer allocator.free(user_agent);
        try putOwnedHeader(allocator, headers, "user-agent", user_agent);
        try putOwnedHeader(allocator, headers, "x-app", "cli");
    }
}

fn applySessionAffinityHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    const stream_options = options orelse return;
    const session_id = stream_options.session_id orelse return;
    if (resolveOptionsCacheRetention(options) == .none) return;
    if (!getAnthropicCompat(model).send_session_affinity_headers) return;
    try putOwnedHeader(allocator, headers, "x-session-affinity", session_id);
}

fn shouldUseFineGrainedToolStreamingBeta(model: types.Model, context: types.Context) bool {
    if (context.tools == null or context.tools.?.len == 0) return false;
    return !getAnthropicCompat(model).supports_eager_tool_input_streaming;
}

fn shouldUseInterleavedThinkingBeta(model: types.Model, options: ?types.StreamOptions) bool {
    if (supportsAdaptiveThinking(model)) return false;
    if (options) |stream_options| {
        const anthropic_opts = stream_options.providerOptions("anthropic");
        return anthropic_opts.interleaved_thinking orelse true;
    }
    return true;
}

fn buildAnthropicBetaHeader(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    api_key: []const u8,
) !?[]u8 {
    if (isKimiCodingProvider(model)) return null;

    var features: [4][]const u8 = undefined;
    var count: usize = 0;

    if (!std.mem.eql(u8, model.provider, "github-copilot") and usesAnthropicOAuth(model, api_key)) {
        features[count] = "claude-code-20250219";
        count += 1;
        features[count] = "oauth-2025-04-20";
        count += 1;
    }

    if (shouldUseFineGrainedToolStreamingBeta(model, context)) {
        features[count] = FINE_GRAINED_TOOL_STREAMING_BETA;
        count += 1;
    }

    if (shouldUseInterleavedThinkingBeta(model, options)) {
        features[count] = INTERLEAVED_THINKING_BETA;
        count += 1;
    }

    if (count == 0) return null;
    return try std.mem.join(allocator, ",", features[0..count]);
}

fn isKimiCodingProvider(model: types.Model) bool {
    return std.mem.eql(u8, model.provider, "kimi-coding");
}

fn shouldTolerateNoncanonicalAnthropicChunk(model: types.Model) bool {
    return isKimiCodingProvider(model);
}

fn usesAnthropicOAuth(model: types.Model, api_key: []const u8) bool {
    return std.mem.eql(u8, model.provider, "anthropic") and isOAuthToken(api_key);
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

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (try headers.fetchPut(owned_name, owned_value)) |previous| {
        allocator.free(previous.key);
        allocator.free(previous.value);
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

const asciiLowerAlloc = @import("../shared/string_utils.zig").asciiLowerAlloc;

/// Normalize response header names to TypeScript-compatible lowercase keys
/// before invoking `on_response` callbacks. Mirrors the OpenAI Chat path so
/// callbacks can rely on consistent lookup semantics regardless of the
/// on-the-wire casing emitted by the upstream server.
fn normalizedResponseHeaders(
    allocator: std.mem.Allocator,
    maybe_headers: ?std.StringHashMap([]const u8),
) !std.StringHashMap([]const u8) {
    var normalized = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &normalized);

    if (maybe_headers) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const lower = try asciiLowerAlloc(allocator, entry.key_ptr.*);
            defer allocator.free(lower);
            try putOwnedHeader(allocator, &normalized, lower, entry.value_ptr.*);
        }
    }

    return normalized;
}

fn isOAuthToken(api_key: []const u8) bool {
    return std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;
    if (usage_value.object.get("input_tokens")) |value| {
        if (value == .integer) usage.input = @intCast(value.integer);
    }
    if (usage_value.object.get("output_tokens")) |value| {
        if (value == .integer) usage.output = @intCast(value.integer);
    }
    if (usage_value.object.get("cache_read_input_tokens")) |value| {
        if (value == .integer) usage.cache_read = @intCast(value.integer);
    }
    if (usage_value.object.get("cache_creation_input_tokens")) |value| {
        if (value == .integer) usage.cache_write = @intCast(value.integer);
    }
    // Anthropic splits cache creation into ephemeral (5min, included in cache_write above)
    // and ephemeral_1h (1h retention). The 1h tokens are priced at 2x input.
    if (usage_value.object.get("cache_creation")) |cache_creation| {
        if (cache_creation == .object) {
            if (cache_creation.object.get("ephemeral_1h_input_tokens")) |eph| {
                if (eph == .integer) usage.cache_write_1h = @intCast(eph.integer);
            }
        }
    }
    usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;
}

fn findActiveBlock(active_blocks: *std.ArrayList(BlockEntry), value: std.json.Value) !*BlockEntry {
    const index_value = value.object.get("index") orelse return AnthropicError.InvalidAnthropicChunk;
    if (index_value != .integer) return AnthropicError.InvalidAnthropicChunk;
    const anthropic_index: usize = @intCast(index_value.integer);
    const found_index = findActiveBlockIndex(active_blocks, anthropic_index) orelse return AnthropicError.InvalidAnthropicChunk;
    return &active_blocks.items[found_index];
}

fn findActiveBlockIndex(active_blocks: *const std.ArrayList(BlockEntry), anthropic_index: usize) ?usize {
    for (active_blocks.items, 0..) |entry, index| {
        if (entry.anthropic_index == anthropic_index) return index;
    }
    return null;
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.deinit(allocator),
        .thinking => |*thinking| {
            textDeinit(allocator, &thinking.text);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

fn textDeinit(allocator: std.mem.Allocator, text: *std.ArrayList(u8)) void {
    text.deinit(allocator);
}

fn normalizeIncomingToolName(
    allocator: std.mem.Allocator,
    name: []const u8,
    tools: ?[]const types.Tool,
    options: ?types.StreamOptions,
) ![]const u8 {
    _ = options;
    if (tools) |available_tools| {
        for (available_tools) |tool| {
            if (std.ascii.eqlIgnoreCase(tool.name, name)) {
                return try allocator.dupe(u8, tool.name);
            }
        }
    }
    return try allocator.dupe(u8, name);
}

fn canonicalClaudeCodeToolName(name: []const u8) []const u8 {
    return anthropic_json.canonicalClaudeCodeToolName(name);
}

const ResponseHeaderServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    response_headers: []const u8,
    body: []const u8,
    thread: ?std.Thread = null,

    fn init(io: std.Io, response_headers: []const u8, body: []const u8) !ResponseHeaderServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .response_headers = response_headers,
            .body = body,
        };
    }

    fn start(self: *ResponseHeaderServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *ResponseHeaderServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn url(self: *const ResponseHeaderServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *ResponseHeaderServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("response header test server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch |err| std.debug.panic("response header test server read failed: {}", .{err});
        writeResponse(self, stream) catch |err| std.debug.panic("response header test server write failed: {}", .{err});
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(self: *ResponseHeaderServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n",
            .{ self.body.len, self.response_headers },
        );
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

const OnResponseCapture = struct {
    var called = false;
    var status: u16 = 0;

    fn reset() void {
        called = false;
        status = 0;
    }

    fn callback(callback_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        called = true;
        status = callback_status;
        try std.testing.expectEqualStrings("anthropic-messages", model.api);
        try std.testing.expectEqualStrings("text/event-stream", headers.get("content-type").?);
        try std.testing.expectEqualStrings("req_123", headers.get("x-request-id").?);
        try std.testing.expectEqualStrings("17", headers.get("anthropic-processing-ms").?);
        try std.testing.expect(headers.get("Content-Type") == null);
    }
};

fn drainStreamAndFreeDoneMessage(
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
) !void {
    while (stream.next()) |event| {
        defer event.deinitTransient(allocator);
        if (event.message) |message| types.freeAssistantMessage(allocator, message);
    }
}

fn deinitJsonArrayItems(allocator: std.mem.Allocator, array: *std.json.Array) void {
    anthropic_json.deinitJsonArrayItems(allocator, array);
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

test "parseSseStreamLines preserves partial Anthropic text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "event: message_start\n" ++
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"anthropic-runtime\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n" ++
            "data: {not-json}\n\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    const context = types.Context{ .messages = &[_]types.Message{} };

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("anthropic-messages", "anthropic"), context, null);

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
    try std.testing.expectEqualStrings("anthropic-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "stream preserves partial Anthropic text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "event: message_start\n" ++
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"anthropic-abort\"}}\n\n" ++
                "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial anthropic\"}}\n\n",
            .delay_after_ms = 1000,
        },
        .{ .bytes = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n" },
    };
    var server = try test_stream_server.DelayedChunkServer.init(io, &chunks);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);
    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
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

    var stream = try AnthropicProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial anthropic", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial anthropic", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("anthropic-abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial anthropic", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes partial Anthropic blocks before provider error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const redacted_secret_placeholder = "sk" ++ "-anthropic-secret";
    const body = try allocator.dupe(
        u8,
        "event: message_start\n" ++
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"anthropic-provider-error\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial text\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"partial thought\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-1\"}}\n\n" ++
            "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"todoWrite\",\"input\":{}}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"todos\\\":\\\"item\\\"}\"}}\n\n" ++
            "event: error\n" ++
            "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"provider failed with " ++ redacted_secret_placeholder ++ " at /Users/alice/file.zig\"}}\n\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    const context = types.Context{ .messages = &[_]types.Message{} };

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("anthropic-messages", "anthropic"), context, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial text", text_end.content.?);
    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqualStrings("partial thought", thinking_end.content.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("todoWrite", tool_end.tool_call.?.name);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("anthropic-provider-error", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial text", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("partial thought", terminal.message.?.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("sig-1", terminal.message.?.content[1].thinking.signature.?);
    try std.testing.expectEqualStrings("item", terminal.message.?.content[2].tool_call.arguments.object.get("todos").?.string);
    try std.testing.expect(terminal.message.?.tool_calls == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, redacted_secret_placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "/Users/alice") == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes partial Anthropic text before EOF terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "event: content_block_start\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "event: content_block_delta\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial before eof\"}}\n\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    const context = types.Context{ .messages = &[_]types.Message{} };

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("anthropic-messages", "anthropic"), context, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial before eof", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("partial before eof", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
}

fn streamErrorContractAnthropicModel(base_url: []const u8) types.Model {
    return .{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
}

fn streamErrorContractAnthropicContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

fn expectOnlyTerminalErrorAnthropic(
    stream: *event_stream.AssistantMessageEventStream,
    expected_error: []const u8,
    expected_stop: types.StopReason,
) !void {
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings(expected_error, event.error_message.?);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqual(expected_stop, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqual(expected_stop, result.stop_reason);
}

fn failingAnthropicOnPayload(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
    _ = allocator;
    _ = payload;
    _ = model;
    return error.FixtureAnthropicPayloadFailure;
}

fn failingAnthropicOnResponse(status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
    _ = status;
    _ = headers;
    _ = model;
    return error.FixtureAnthropicResponseFailure;
}

test "VAL-M9-STREAM-003 stream URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("not-a-valid-url"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "InvalidUrl", .error_reason);
}

test "VAL-M9-STREAM-003 streamSimple URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.streamSimple(
        allocator,
        io,
        streamErrorContractAnthropicModel("not-a-valid-url"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "InvalidUrl", .error_reason);
}

test "VAL-M9-STREAM-004 stream on_payload failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .on_payload = failingAnthropicOnPayload },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "FixtureAnthropicPayloadFailure", .error_reason);
}

test "VAL-M9-STREAM-005 stream on_response failure returns one terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_unread\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-7-sonnet-latest\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel(url),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .on_response = &failingAnthropicOnResponse },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "FixtureAnthropicResponseFailure", .error_reason);
}

test "anthropic stream ending after message_start without message_stop yields terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_premature\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-7-sonnet-latest\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel(url),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    const start_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, start_event.event_type);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.error_message != null);
    try std.testing.expectEqualStrings("Anthropic stream ended before message_stop", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);

    try std.testing.expect(stream.next() == null);
}

test "anthropic message_start populates usage cost so premature termination error reports non-zero cost" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_priced\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-7-sonnet-latest\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1000000,\"output_tokens\":500000,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const priced_model: types.Model = .{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.3, .cache_write = 3.75 },
    };

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        priced_model,
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    const start_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, start_event.event_type);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Anthropic stream ended before message_stop", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    const usage = terminal.message.?.usage;
    try std.testing.expectEqual(@as(u32, 1_000_000), usage.input);
    try std.testing.expectEqual(@as(u32, 500_000), usage.output);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), usage.cost.input, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), usage.cost.output, 1e-9);
    try std.testing.expect(usage.cost.total > 0);

    try std.testing.expect(stream.next() == null);
}

test "VAL-M9-STREAM-010 stream pre-aborted signal yields terminal aborted event without throwing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("http://127.0.0.1:1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .signal = &aborted },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&stream, "Request was aborted", .aborted);
}

test "VAL-M9-STREAM-010 streamSimple pre-aborted signal matches stream terminal aborted semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var simple_stream = try AnthropicProvider.streamSimple(
        allocator,
        io,
        streamErrorContractAnthropicModel("http://127.0.0.1:1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "test-key", .signal = &aborted },
    );
    defer simple_stream.deinit();

    try expectOnlyTerminalErrorAnthropic(&simple_stream, "Request was aborted", .aborted);
}

fn expectMissingApiKeyTerminalErrorAnthropic(
    stream: *event_stream.AssistantMessageEventStream,
    expected_provider: []const u8,
) !void {
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expect(event.error_message != null);

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "No API key for provider: {s}",
        .{expected_provider},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, event.error_message.?);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);

    // Diagnostic must not leak secrets, environment values, bearer tokens,
    // credential-store paths, or local auth paths.
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "Bearer") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-ant") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "ANTHROPIC_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "ANTHROPIC_OAUTH_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "x-api-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/home/") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "auth.json") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    std.testing.allocator.free(result.error_message.?);
}

test "VAL-M9-STREAM-006 stream missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorAnthropic(&stream, "anthropic");
}

test "VAL-M9-STREAM-006 streamSimple missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.streamSimple(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorAnthropic(&stream, "anthropic");
}

test "VAL-M9-STREAM-006 stream null api key options returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try AnthropicProvider.stream(
        allocator,
        io,
        streamErrorContractAnthropicModel("https://api.anthropic.com/v1"),
        streamErrorContractAnthropicContext(),
        null,
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorAnthropic(&stream, "anthropic");
}

test "anthropic stream cloudflare provider resolves base_url placeholders via env" {
    // Verifies that isCloudflareProvider gates resolveCloudflareBaseUrl: when the
    // env var referenced in base_url is absent, the stream returns a terminal
    // EnvironmentVariableNotFound error event rather than a networking error for a
    // literal {VAR} URL.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const model = types.Model{
        .id = "cloudflare-anthropic-model",
        .name = "Cloudflare Anthropic Model",
        .api = "anthropic-messages",
        .provider = "cloudflare-ai-gateway",
        .base_url = "https://gateway.ai.cloudflare.com/v1/{ANTHROPIC_WIRE_IN_CF_TEST_ABSENT_VAR}/{ANTHROPIC_WIRE_IN_CF_TEST_GATEWAY_ABSENT}/anthropic",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    const context = streamErrorContractAnthropicContext();

    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings("EnvironmentVariableNotFound", event.error_message.?);
    try std.testing.expect(stream.next() == null);
}

const SSE_FUZZ_SMOKE_SEED: u64 = 0x5eed_55e5_0000_0001;

const SseFuzzExpectation = union(enum) {
    text_done: []const u8,
    text_error: []const u8,
    empty_error,
};

test "VAL-REFACTOR-008 deterministic SSE parser chunk fuzz smoke" {
    const allocator = std.heap.page_allocator;
    const cases = [_]struct {
        label: []const u8,
        body: []const u8,
        model: types.Model,
        expected: SseFuzzExpectation,
    }{
        .{
            .label = "repairable-stream-with-unknown-fields",
            .body = ": ignored comment\n" ++
                "event: vendor_debug\n" ++
                "data: {\"ignored\":true}\n" ++
                "\n" ++
                "event: message_start\n" ++
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fuzz\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}},\"unknown\":true}\n" ++
                "\n" ++
                "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"},\"extra\":\"ok\"}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"repair\\\\q\"}}\n" ++
                "\n" ++
                "event: content_block_stop\n" ++
                "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
                "\n" ++
                "event: message_delta\n" ++
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n" ++
                "\n" ++
                "event: message_stop\n" ++
                "data: {\"type\":\"message_stop\"}\n" ++
                "\n",
            .model = sseFuzzModel("claude-fuzz", "anthropic"),
            .expected = .{ .text_done = "repair\\q" },
        },
        .{
            .label = "truncated-repairable-kimi-stream",
            .body = "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n" ++
                "\n",
            .model = sseFuzzModel("kimi-for-coding", "kimi-coding"),
            .expected = .{ .text_done = "partial" },
        },
        .{
            .label = "malformed-frame-preserves-partial-text",
            .body = "event: content_block_start\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"before\"}}\n" ++
                "\n" ++
                "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":123}}\n" ++
                "\n",
            .model = sseFuzzModel("claude-fuzz", "anthropic"),
            .expected = .{ .text_error = "before" },
        },
        .{
            .label = "boundary-size-repairable-text",
            .body = try sseFuzzBoundaryBody(allocator),
            .model = sseFuzzModel("kimi-for-coding", "kimi-coding"),
            .expected = .{ .text_done = "boundary-" },
        },
        .{
            .label = "malformed-truncated-empty-frame",
            .body = "event: content_block_delta\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"unterminated",
            .model = sseFuzzModel("claude-fuzz", "anthropic"),
            .expected = .empty_error,
        },
    };

    for (cases) |case| {
        var chunk_lengths = std.ArrayList(usize).empty;
        defer chunk_lengths.deinit(allocator);
        const chunked_body = try deterministicChunkedCopy(allocator, case.body, SSE_FUZZ_SMOKE_SEED, case.label, &chunk_lengths);
        defer allocator.free(chunked_body);

        sseFuzzSmokeCase(allocator, case.label, chunked_body, chunk_lengths.items, case.model, case.expected) catch |err| {
            reportSseFuzzFailure(SSE_FUZZ_SMOKE_SEED, case.label, chunked_body, chunk_lengths.items);
            return err;
        };
    }
}

fn sseFuzzModel(id: []const u8, provider: []const u8) types.Model {
    return .{
        .id = id,
        .name = id,
        .api = "anthropic-messages",
        .provider = provider,
        .base_url = "https://example.invalid/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
}

fn sseFuzzBoundaryBody(allocator: std.mem.Allocator) ![]const u8 {
    const text = try allocator.alloc(u8, 8192);
    @memset(text, 'x');
    defer allocator.free(text);
    return std.fmt.allocPrint(
        allocator,
        "event: content_block_start\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n" ++
            "\n" ++
            "event: content_block_delta\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"boundary-{s}\"}}}}\n" ++
            "\n",
        .{text},
    );
}

fn deterministicChunkedCopy(
    allocator: std.mem.Allocator,
    input: []const u8,
    seed: u64,
    label: []const u8,
    chunk_lengths: *std.ArrayList(usize),
) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed ^ std.hash.Wyhash.hash(seed, label));
    const random = prng.random();
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        const remaining = input.len - index;
        const max_chunk = @min(remaining, @as(usize, 31));
        const len = random.intRangeAtMost(usize, 1, max_chunk);
        try out.appendSlice(allocator, input[index .. index + len]);
        try chunk_lengths.append(allocator, len);
        index += len;
    }
    return out.toOwnedSlice(allocator);
}

fn sseFuzzSmokeCase(
    allocator: std.mem.Allocator,
    label: []const u8,
    body: []const u8,
    chunk_lengths: []const usize,
    model: types.Model,
    expected: SseFuzzExpectation,
) !void {
    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, std.Io.failing);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, .{ .messages = &[_]types.Message{} }, null);

    switch (expected) {
        .text_done => |prefix| try expectSseFuzzTerminal(label, chunk_lengths, &stream_instance, .done, prefix),
        .text_error => |prefix| try expectSseFuzzTerminal(label, chunk_lengths, &stream_instance, .error_event, prefix),
        .empty_error => try expectSseFuzzTerminal(label, chunk_lengths, &stream_instance, .error_event, null),
    }
}

fn expectSseFuzzTerminal(
    label: []const u8,
    chunk_lengths: []const usize,
    stream_instance: *event_stream.AssistantMessageEventStream,
    expected_terminal: types.EventType,
    expected_text_prefix: ?[]const u8,
) !void {
    var saw_terminal = false;
    while (stream_instance.next()) |event| {
        if (event.event_type == .done or event.event_type == .error_event) {
            saw_terminal = true;
            if (event.event_type != expected_terminal) {
                reportSseFuzzTerminalMismatch(label, chunk_lengths, expected_terminal, event.event_type);
                return error.TestExpectedEqual;
            }
            if (expected_text_prefix) |prefix| {
                if (event.message == null or event.message.?.content.len == 0 or event.message.?.content[0] != .text or
                    !std.mem.startsWith(u8, event.message.?.content[0].text.text, prefix))
                {
                    reportSseFuzzTerminalMismatch(label, chunk_lengths, expected_terminal, event.event_type);
                    return error.TestExpectedEqual;
                }
            }
        }
    }
    if (!saw_terminal) {
        reportSseFuzzTerminalMismatch(label, chunk_lengths, expected_terminal, .start);
        return error.TestExpectedEqual;
    }
}

fn reportSseFuzzFailure(seed: u64, label: []const u8, body: []const u8, chunk_lengths: []const usize) void {
    std.debug.print("SSE fuzz smoke failure seed=0x{x} case={s} input={s} chunks=", .{ seed, label, body });
    for (chunk_lengths, 0..) |len, index| {
        if (index > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{len});
    }
    std.debug.print("\n", .{});
}

fn reportSseFuzzTerminalMismatch(
    label: []const u8,
    chunk_lengths: []const usize,
    expected_terminal: types.EventType,
    actual_terminal: types.EventType,
) void {
    std.debug.print("SSE fuzz smoke assertion case={s} expected={s} actual={s} smallest_chunks=", .{
        label,
        @tagName(expected_terminal),
        @tagName(actual_terminal),
    });
    for (chunk_lengths, 0..) |len, index| {
        if (index > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{len});
    }
    std.debug.print("\n", .{});
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
    var stream = try AnthropicProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();
    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("anthropic-messages", error_event.message.?.api);
    try std.testing.expectEqualStrings("anthropic", error_event.message.?.provider);
    try std.testing.expectEqualStrings("claude-3-7-sonnet-latest", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(error_event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}
