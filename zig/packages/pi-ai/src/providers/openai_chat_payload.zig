const std = @import("std");
const types = @import("../types.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_json_put = @import("../shared/provider_json_put.zig");
const transform_messages = @import("../shared/transform_messages.zig");
const sanitize_unicode = @import("../shared/sanitize_unicode.zig");

const putBoolValue = provider_json_put.putBoolValue;
const putStringValue = provider_json_put.putStringValue;
const putIntegerValue = provider_json_put.putIntegerValue;
const putFloatValue = provider_json_put.putFloatValue;
const putObjectValue = provider_json_put.putObjectValue;

pub fn freeOwnedJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

/// Mirror TypeScript Array.prototype.filter(Boolean) semantics for parsed
/// JSON values produced by JSON.parse. Returns true if the value would be
/// filtered out by `filter(Boolean)`.
///
/// JSON.parse can yield: null, true/false, number, string, array, object.
/// Of these, the falsey ones are: null, false, 0 (integer or float), and
/// empty string. NaN cannot appear from JSON.parse (it is not valid JSON),
/// but we conservatively treat number_string-encoded NaN-like values the
/// same as the underlying numeric semantics.
fn isFalseyJsonValue(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .bool => |b| !b,
        .integer => |i| i == 0,
        .float => |f| f == 0.0 or std.math.isNan(f),
        .number_string => |ns| ns.len == 0 or std.mem.eql(u8, ns, "0") or std.mem.eql(u8, ns, "-0") or std.mem.eql(u8, ns, "NaN"),
        .string => |s| s.len == 0,
        .array, .object => false,
    };
}

/// Removes unpaired Unicode surrogate characters from text.
/// Valid paired surrogates (proper emoji) are preserved.
/// Delegates to the canonical shared implementation.
pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return sanitize_unicode.sanitizeSurrogates(allocator, text);
}

pub fn processCacheRetentionEnv() ?[]const u8 {
    const value = std.c.getenv("PI_CACHE_RETENTION") orelse return null;
    return std.mem.span(value);
}

pub fn resolveCacheRetention(cache_retention: types.CacheRetention, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return switch (cache_retention) {
        .unset => if (pi_cache_retention_env) |value|
            if (std.mem.eql(u8, value, "long")) .long else .short
        else
            .short,
        .none, .short, .long => cache_retention,
    };
}

pub fn resolveOptionsCacheRetention(options: ?types.StreamOptions, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return resolveCacheRetention(if (options) |opts| opts.cache_retention else .unset, pi_cache_retention_env);
}

pub fn buildFinalRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return buildFinalRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

pub fn buildFinalRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    var payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
    errdefer provider_json.freeValue(allocator, payload);

    if (options) |opts| {
        if (opts.on_payload) |on_payload| {
            if (try on_payload(allocator, payload, model)) |replacement| {
                provider_json.freeValue(allocator, payload);
                payload = replacement;
            }
        }
    }

    return payload;
}

/// Build the request payload for OpenAI chat completions API
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

// =============================================================================
// Outer-envelope payload struct for OpenAI chat completions API
// (and OpenAI-compatible providers — many flavors via OpenAICompat matrix).
//
// `messages` and `tools` are kept as std.json.Value passthroughs because
// the Anthropic-on-OpenRouter cache_control surgery
// (applyCacheControlOnArrays) mutates individual blocks/items in those
// Value subtrees. The surgery now runs BEFORE struct assembly so the
// passthrough Values reach the serializer already-mutated and the
// serializer is single-pass (no parse+remutate+restringify).
//
// The 5-branch thinking_format conditional (zai/qwen, qwen-chat-template,
// deepseek, openrouter, together, plus plain reasoning_effort) maps onto
// optional struct fields where each branch sets the 1-2 fields it cares
// about; the rest stay null and are skipped via emit_null_optional_fields.
// =============================================================================

const ChatRequestPayload = struct {
    model: []const u8,
    messages: std.json.Value, // passthrough Array (already cache_control-patched)
    stream: bool = true,
    stream_options: ?StreamOptionsField = null,
    store: ?bool = null,
    prompt_cache_key: ?[]const u8 = null,
    temperature: ?f32 = null,
    // Only one of max_tokens / max_completion_tokens is non-null at a time
    // (mutual exclusion enforced by buildOwnedChat via compat.max_tokens_field).
    max_tokens: ?u64 = null,
    max_completion_tokens: ?u64 = null,
    tool_choice: ?std.json.Value = null,
    prompt_cache_retention: ?[]const u8 = null,
    tools: ?std.json.Value = null,
    tool_stream: ?bool = null,
    // Reasoning shape variants — at most a few are non-null per request:
    enable_thinking: ?bool = null,
    chat_template_kwargs: ?QwenChatTemplateKwargs = null,
    thinking: ?DeepseekThinking = null,
    reasoning_effort: ?[]const u8 = null,
    reasoning: ?ReasoningBlock = null, // openrouter / together
    // Routing variants:
    provider: ?std.json.Value = null, // openrouter routing block (cloned)
    providerOptions: ?VercelGatewayRouting = null, // vercel gateway routing block
};

const StreamOptionsField = struct { include_usage: bool };
const QwenChatTemplateKwargs = struct { enable_thinking: bool, preserve_thinking: bool };
const DeepseekThinking = struct { type: []const u8 };

/// Reasoning block emitted by openrouter/together thinking_format
/// branches. Replaces the two per-request ObjectMap allocations that
/// previously built `{effort: "..."}` and `{enabled: bool}` trees.
const ReasoningBlock = union(enum) {
    openrouter: struct { effort: []const u8 },
    together: struct { enabled: bool },

    pub fn jsonStringify(self: ReasoningBlock, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .openrouter => |o| {
                try jw.objectField("effort");
                try jw.write(o.effort);
            },
            .together => |t| {
                try jw.objectField("enabled");
                try jw.write(t.enabled);
            },
        }
        try jw.endObject();
    }
};

/// Vercel AI Gateway routing block. Replaces the two per-request
/// ObjectMap allocations (`providerOptions` and inner `gateway` wrapper).
/// The leaf `only`/`order` fields stay as std.json.Value passthroughs
/// because the cloned routing data may be any shape (string, array,
/// object) the Vercel Gateway upstream accepts.
const VercelGatewayRouting = struct {
    gateway: VercelGatewayInner,
};

const VercelGatewayInner = struct {
    only: ?std.json.Value = null,
    order: ?std.json.Value = null,
};

const ChatOwned = struct {
    allocator: std.mem.Allocator,
    payload: ChatRequestPayload,
    owned_values: []std.json.Value,

    fn deinit(self: ChatOwned) void {
        for (self.owned_values) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_values);
    }
};

fn buildOwnedChat(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !ChatOwned {
    var owned_values_list = std.ArrayList(std.json.Value).empty;
    errdefer {
        for (owned_values_list.items) |v| provider_json.freeValue(allocator, v);
        owned_values_list.deinit(allocator);
    }

    const compat = getCompat(model);
    const cache_retention = resolveOptionsCacheRetention(options, pi_cache_retention_env);
    const has_tool_history = hasToolHistory(context.messages);

    // Build messages Array (Value passthrough).
    const messages_array = try buildMessages(allocator, model, context, compat);
    errdefer provider_json.freeValue(allocator, .{ .array = messages_array });
    var messages_value: std.json.Value = .{ .array = messages_array };

    // Build tools Array (Value passthrough), if applicable.
    var tools_value: ?std.json.Value = null;
    if (context.tools) |tools| {
        if (tools.len > 0) {
            var arr = std.json.Array.init(allocator);
            errdefer provider_json.freeValue(allocator, .{ .array = arr });
            for (tools) |tool| try arr.append(try buildToolObject(allocator, tool, compat));
            tools_value = .{ .array = arr };
        } else if (has_tool_history) {
            tools_value = .{ .array = std.json.Array.init(allocator) };
        }
    } else if (has_tool_history) {
        tools_value = .{ .array = std.json.Array.init(allocator) };
    }
    errdefer if (tools_value) |tv| provider_json.freeValue(allocator, tv);

    // Apply cache_control mutations on the messages/tools Arrays BEFORE
    // they are handed to the serializer (mirrors the legacy
    // applyAnthropicCacheControl payload-walk, but operating on the
    // subtrees directly so we stay single-pass).
    if (try buildCompatCacheControl(allocator, compat, cache_retention)) |cache_control| {
        defer provider_json.freeValue(allocator, cache_control);
        if (messages_value == .array) {
            try addCacheControlToInstructionMessage(allocator, &messages_value.array, cache_control);
            try addCacheControlToLastConversationMessage(allocator, &messages_value.array, cache_control);
        }
        if (tools_value) |tv| {
            if (tv == .array and tv.array.items.len > 0) {
                const last_tool = &tv.array.items[tv.array.items.len - 1];
                if (last_tool.* == .object) {
                    try putJsonObjectFieldReplacing(allocator, &last_tool.object, "cache_control", try provider_json.cloneValue(allocator, cache_control));
                }
            }
        }
    }

    // Record subtrees as owned so deinit() releases them.
    try owned_values_list.append(allocator, messages_value);
    if (tools_value) |tv| try owned_values_list.append(allocator, tv);

    // Common (compat-driven) fields.
    var stream_options_field: ?StreamOptionsField = null;
    if (compat.supports_usage_in_streaming) stream_options_field = .{ .include_usage = true };
    var store: ?bool = null;
    if (compat.supports_store) store = false;
    const tool_stream: ?bool = if (tools_value != null and tools_value.?.array.items.len > 0 and compat.zai_tool_stream) true else null;

    // Option-driven fields.
    var prompt_cache_key: ?[]const u8 = null;
    var prompt_cache_retention: ?[]const u8 = null;
    var temperature: ?f32 = null;
    var max_tokens: ?u64 = null;
    var max_completion_tokens: ?u64 = null;
    var tool_choice_owned: ?std.json.Value = null;

    if (options) |opts| {
        if (opts.session_id) |session_id| {
            if ((std.mem.indexOf(u8, model.base_url, "api.openai.com") != null and cache_retention != .none) or
                (cache_retention == .long and compat.supports_long_cache_retention))
            {
                prompt_cache_key = session_id;
            }
        }
        if (opts.temperature) |t| temperature = t;
        if (opts.max_tokens) |m| {
            if (std.mem.eql(u8, compat.max_tokens_field, "max_tokens")) {
                max_tokens = m;
            } else {
                max_completion_tokens = m;
            }
        }
        const openai_opts = opts.providerOptions("openai");
        if (openai_opts.tool_choice) |tc| {
            const tcv = try provider_json.cloneValue(allocator, tc);
            try owned_values_list.append(allocator, tcv);
            tool_choice_owned = tcv;
        }
    }
    if (cache_retention == .long and compat.supports_long_cache_retention) {
        prompt_cache_retention = "24h";
    }

    // Reasoning fields (5-branch dispatch on compat.thinking_format).
    var enable_thinking_field: ?bool = null;
    var chat_template_kwargs: ?QwenChatTemplateKwargs = null;
    var thinking_field: ?DeepseekThinking = null;
    var reasoning_effort: ?[]const u8 = null;
    var reasoning_block: ?ReasoningBlock = null;

    if (model.reasoning) {
        const openai_opts = if (options) |opts| opts.providerOptions("openai") else types.OpenAIChatStreamOptions{};
        const effort = openai_opts.reasoning_effort;
        if (std.mem.eql(u8, compat.thinking_format, "zai") or std.mem.eql(u8, compat.thinking_format, "qwen")) {
            enable_thinking_field = (effort != null);
        } else if (std.mem.eql(u8, compat.thinking_format, "qwen-chat-template")) {
            chat_template_kwargs = .{ .enable_thinking = (effort != null), .preserve_thinking = true };
        } else if (std.mem.eql(u8, compat.thinking_format, "deepseek")) {
            thinking_field = .{ .type = if (effort != null) "enabled" else "disabled" };
            if (effort) |value| reasoning_effort = value;
        } else if (std.mem.eql(u8, compat.thinking_format, "openrouter")) {
            reasoning_block = .{ .openrouter = .{ .effort = effort orelse "none" } };
        } else if (std.mem.eql(u8, compat.thinking_format, "together")) {
            reasoning_block = .{ .together = .{ .enabled = effort != null } };
            if (effort) |value| {
                if (compat.supports_reasoning_effort) {
                    reasoning_effort = mappedReasoningEffort(model, value);
                }
            }
        } else if (effort) |value| {
            if (compat.supports_reasoning_effort) reasoning_effort = value;
        }
    }

    // Routing fields.
    var provider_owned: ?std.json.Value = null;
    if (std.mem.indexOf(u8, model.base_url, "openrouter.ai") != null) {
        if (compat.open_router_routing) |routing| {
            const cloned = try provider_json.cloneValue(allocator, routing);
            try owned_values_list.append(allocator, cloned);
            provider_owned = cloned;
        }
    }
    var gateway_routing_owned: ?VercelGatewayRouting = null;
    if (std.mem.indexOf(u8, model.base_url, "ai-gateway.vercel.sh") != null) {
        if (compat.vercel_gateway_routing) |routing| {
            if (routing == .object and (routing.object.get("only") != null or routing.object.get("order") != null)) {
                var only_value: ?std.json.Value = null;
                var order_value: ?std.json.Value = null;
                if (routing.object.get("only")) |only| {
                    const cloned = try provider_json.cloneValue(allocator, only);
                    try owned_values_list.append(allocator, cloned);
                    only_value = cloned;
                }
                if (routing.object.get("order")) |order| {
                    const cloned = try provider_json.cloneValue(allocator, order);
                    try owned_values_list.append(allocator, cloned);
                    order_value = cloned;
                }
                gateway_routing_owned = .{ .gateway = .{ .only = only_value, .order = order_value } };
            }
        }
    }

    const owned_values_slice = try owned_values_list.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .payload = .{
            .model = model.id,
            .messages = messages_value,
            .stream_options = stream_options_field,
            .store = store,
            .prompt_cache_key = prompt_cache_key,
            .temperature = temperature,
            .max_tokens = max_tokens,
            .max_completion_tokens = max_completion_tokens,
            .tool_choice = tool_choice_owned,
            .prompt_cache_retention = prompt_cache_retention,
            .tools = tools_value,
            .tool_stream = tool_stream,
            .enable_thinking = enable_thinking_field,
            .chat_template_kwargs = chat_template_kwargs,
            .thinking = thinking_field,
            .reasoning_effort = reasoning_effort,
            .reasoning = reasoning_block,
            .provider = provider_owned,
            .providerOptions = gateway_routing_owned,
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
    return buildPayloadJsonBytesWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

pub fn buildPayloadJsonBytesWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) ![]u8 {
    var owned = try buildOwnedChat(allocator, model, context, options, pi_cache_retention_env);
    defer owned.deinit();
    return try std.json.Stringify.valueAlloc(allocator, owned.payload, .{
        .emit_null_optional_fields = false,
    });
}

pub fn buildRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    const bytes = try buildPayloadJsonBytesWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    return try provider_json.cloneValue(allocator, parsed.value);
}

fn buildMessages(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    compat: OpenAICompat,
) !std.json.Array {
    const transformed_messages = try transform_messages.transformMessages(
        allocator,
        context.messages,
        model,
        &normalizeToolCallId,
    );
    defer transform_messages.freeMessages(allocator, transformed_messages);

    var messages = std.json.Array.init(allocator);
    errdefer messages.deinit();

    // Determine if we should use developer role for reasoning models
    const use_developer_role = model.reasoning and compat.supports_developer_role;

    // Add system prompt if present
    if (context.system_prompt) |system| {
        const role = if (use_developer_role) "developer" else "system";
        const sanitized = try sanitizeSurrogates(allocator, system);
        defer allocator.free(sanitized);
        try messages.append(std.json.Value{ .object = try buildMessageObject(allocator, role, sanitized) });
    }

    // Add conversation messages
    var last_role: ?[]const u8 = null;
    var message_index: usize = 0;
    while (message_index < transformed_messages.len) : (message_index += 1) {
        const msg = transformed_messages[message_index];
        if (compat.requires_assistant_after_tool_result and last_role != null and std.mem.eql(u8, last_role.?, "toolResult") and msg == .user) {
            try messages.append(.{ .object = try buildMessageObject(allocator, "assistant", "I have processed the tool results.") });
        }
        switch (msg) {
            .user => |user_msg| {
                if (user_msg.content.len == 0) continue;
                try messages.append(try buildUserMessage(allocator, model, user_msg));
                last_role = "user";
            },
            .assistant => |assistant_msg| {
                if (try buildAssistantMessage(allocator, model, assistant_msg)) |assistant_message| {
                    try messages.append(assistant_message);
                    last_role = "assistant";
                }
            },
            .tool_result => {
                const append_result = try appendToolResultMessages(allocator, &messages, model, transformed_messages, message_index);
                message_index = append_result.next_index - 1;
                last_role = if (append_result.appended_image_user) "user" else "toolResult";
            },
        }
    }

    return messages;
}

fn mappedReasoningEffort(model: types.Model, effort: []const u8) []const u8 {
    const level = modelThinkingLevel(effort) orelse return effort;
    const map = model.thinking_level_map orelse return effort;
    const entry = map.get(level) orelse return effort;
    return switch (entry) {
        .mapped => |mapped| mapped,
        .unsupported => effort,
    };
}

fn modelThinkingLevel(effort: []const u8) ?types.ModelThinkingLevel {
    if (std.mem.eql(u8, effort, "off")) return .off;
    if (std.mem.eql(u8, effort, "minimal")) return .minimal;
    if (std.mem.eql(u8, effort, "low")) return .low;
    if (std.mem.eql(u8, effort, "medium")) return .medium;
    if (std.mem.eql(u8, effort, "high")) return .high;
    if (std.mem.eql(u8, effort, "xhigh")) return .xhigh;
    return null;
}

fn buildCompatCacheControl(
    allocator: std.mem.Allocator,
    compat: OpenAICompat,
    cache_retention: types.CacheRetention,
) !?std.json.Value {
    const format = compat.cache_control_format orelse return null;
    if (!std.mem.eql(u8, format, "anthropic") or cache_retention == .none) return null;

    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "type", "ephemeral");
    if (cache_retention == .long and compat.supports_long_cache_retention) {
        try putStringValue(allocator, &object, "ttl", "1h");
    }
    return .{ .object = object };
}

fn addCacheControlToInstructionMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    cache_control: std.json.Value,
) !void {
    for (messages.items) |*message| {
        if (message.* != .object) continue;
        const role = objectStringField(message.object, "role") orelse continue;
        if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            _ = try addCacheControlToTextContent(allocator, &message.object, cache_control);
            return;
        }
    }
}

fn addCacheControlToLastConversationMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    cache_control: std.json.Value,
) !void {
    var index = messages.items.len;
    while (index > 0) {
        index -= 1;
        const message = &messages.items[index];
        if (message.* != .object) continue;
        const role = objectStringField(message.object, "role") orelse continue;
        if (std.mem.eql(u8, role, "user") or std.mem.eql(u8, role, "assistant")) {
            if (try addCacheControlToTextContent(allocator, &message.object, cache_control)) return;
        }
    }
}

fn addCacheControlToTextContent(
    allocator: std.mem.Allocator,
    message: *std.json.ObjectMap,
    cache_control: std.json.Value,
) !bool {
    const content = message.getPtr("content") orelse return false;
    switch (content.*) {
        .string => |text| {
            if (text.len == 0) return false;
            var parts = std.json.Array.init(allocator);
            errdefer provider_json.freeValue(allocator, .{ .array = parts });

            const part_value: std.json.Value = blk: {
                var part = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = part });
                try putStringValue(allocator, &part, "type", "text");
                try putStringValue(allocator, &part, "text", text);
                try putObjectValue(allocator, &part, "cache_control", try provider_json.cloneValue(allocator, cache_control));
                break :blk .{ .object = part };
            };
            try parts.append(part_value);

            provider_json.freeValue(allocator, content.*);
            content.* = .{ .array = parts };
            return true;
        },
        .array => |*parts| {
            var index = parts.items.len;
            while (index > 0) {
                index -= 1;
                const part = &parts.items[index];
                if (part.* != .object) continue;
                const part_type = objectStringField(part.object, "type") orelse continue;
                if (std.mem.eql(u8, part_type, "text")) {
                    try putJsonObjectFieldReplacing(allocator, &part.object, "cache_control", try provider_json.cloneValue(allocator, cache_control));
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn objectStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn putJsonObjectFieldReplacing(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    if (object.getPtr(key)) |existing| {
        provider_json.freeValue(allocator, existing.*);
        existing.* = value;
    } else {
        try object.put(allocator, try allocator.dupe(u8, key), value);
    }
}

fn hasToolHistory(messages: []const types.Message) bool {
    for (messages) |message| {
        switch (message) {
            .tool_result => return true,
            .assistant => |assistant| {
                if (types.hasInlineToolCalls(assistant)) return true;
                if (assistant.tool_calls) |tool_calls| {
                    if (tool_calls.len > 0) return true;
                }
            },
            .user => {},
        }
    }
    return false;
}

pub const OpenAICompat = struct {
    supports_store: bool = true,
    supports_developer_role: bool = true,
    supports_reasoning_effort: bool = true,
    supports_usage_in_streaming: bool = true,
    max_tokens_field: []const u8 = "max_completion_tokens",
    requires_tool_result_name: bool = false,
    requires_assistant_after_tool_result: bool = false,
    requires_thinking_as_text: bool = false,
    requires_reasoning_content_on_assistant_messages: bool = false,
    thinking_format: []const u8 = "openai",
    open_router_routing: ?std.json.Value = null,
    vercel_gateway_routing: ?std.json.Value = null,
    zai_tool_stream: bool = false,
    supports_strict_mode: bool = true,
    cache_control_format: ?[]const u8 = null,
    send_session_affinity_headers: bool = false,
    supports_long_cache_retention: bool = true,
};

/// Comptime-known descriptor for an OpenAI-compatible provider flavor. Each row
/// declares the (provider id, base_url substring) signals that identify the
/// flavor and any per-field overrides that flavor applies on top of the
/// default OpenAI behavior. `getCompat` iterates `FLAVORS` once via `inline for`
/// and uses first-match-wins semantics per optional field — adding a new
/// OpenAI-compatible provider is one row.
const OpenAICompatFlavor = struct {
    providers: []const []const u8 = &.{},
    base_url_substrings: []const []const u8 = &.{},
    is_non_standard: bool = false,
    supports_reasoning_effort: ?bool = null,
    max_tokens_field: ?[]const u8 = null,
    requires_reasoning_content_on_assistant_messages: ?bool = null,
    thinking_format: ?[]const u8 = null,
    supports_strict_mode: ?bool = null,
    supports_long_cache_retention: ?bool = null,
};

/// Precedence-ordered flavor table. Order only matters for fields where
/// distinct flavors set different non-null values; in practice that is just
/// `thinking_format` (deepseek > zai > together > openrouter). Every other
/// field is either set by at most one flavor or set to the same value by all
/// flavors that override it.
const FLAVORS: []const OpenAICompatFlavor = &.{
    // DeepSeek matched by provider id only — note: provider="deepseek" does
    // NOT mark the model non-standard; only the deepseek.com URL does. This
    // mirrors TypeScript's `detectCompat` in `openai-completions.ts`.
    .{
        .providers = &.{"deepseek"},
        .requires_reasoning_content_on_assistant_messages = true,
        .thinking_format = "deepseek",
    },
    .{
        .base_url_substrings = &.{"deepseek.com"},
        .is_non_standard = true,
        .requires_reasoning_content_on_assistant_messages = true,
        .thinking_format = "deepseek",
    },
    .{
        .providers = &.{"zai"},
        .base_url_substrings = &.{ "api.z.ai", "open.bigmodel.cn" },
        .is_non_standard = true,
        .supports_reasoning_effort = false,
        .thinking_format = "zai",
    },
    .{
        .providers = &.{"xai"},
        .base_url_substrings = &.{"api.x.ai"},
        .is_non_standard = true,
        .supports_reasoning_effort = false,
    },
    .{
        .providers = &.{"together"},
        .base_url_substrings = &.{ "api.together.ai", "api.together.xyz" },
        .is_non_standard = true,
        .supports_reasoning_effort = false,
        .max_tokens_field = "max_tokens",
        .thinking_format = "together",
        .supports_strict_mode = false,
        .supports_long_cache_retention = false,
    },
    .{
        .base_url_substrings = &.{"chutes.ai"},
        .is_non_standard = true,
        .max_tokens_field = "max_tokens",
    },
    .{
        .providers = &.{"cerebras"},
        .base_url_substrings = &.{"cerebras.ai"},
        .is_non_standard = true,
    },
    .{
        .providers = &.{"opencode"},
        .base_url_substrings = &.{"opencode.ai"},
        .is_non_standard = true,
    },
    .{
        .providers = &.{"cloudflare-workers-ai"},
        .base_url_substrings = &.{"api.cloudflare.com"},
        .is_non_standard = true,
        .supports_long_cache_retention = false,
    },
    .{
        .providers = &.{"cloudflare-ai-gateway"},
        .base_url_substrings = &.{"gateway.ai.cloudflare.com"},
        .is_non_standard = true,
        .supports_reasoning_effort = false,
        .max_tokens_field = "max_tokens",
        .supports_strict_mode = false,
        .supports_long_cache_retention = false,
    },
    .{
        .providers = &.{"openrouter"},
        .base_url_substrings = &.{"openrouter.ai"},
        .thinking_format = "openrouter",
    },
};

fn flavorMatches(model: types.Model, comptime flavor: OpenAICompatFlavor) bool {
    inline for (flavor.providers) |p| {
        if (std.mem.eql(u8, model.provider, p)) return true;
    }
    inline for (flavor.base_url_substrings) |s| {
        if (std.mem.indexOf(u8, model.base_url, s) != null) return true;
    }
    return false;
}

pub fn getCompat(model: types.Model) OpenAICompat {
    var is_non_standard: bool = false;
    var supports_reasoning_effort: ?bool = null;
    var max_tokens_field: ?[]const u8 = null;
    var requires_reasoning_content: ?bool = null;
    var thinking_format: ?[]const u8 = null;
    var supports_strict_mode: ?bool = null;
    var supports_long_cache_retention: ?bool = null;

    inline for (FLAVORS) |flavor| {
        if (flavorMatches(model, flavor)) {
            if (flavor.is_non_standard) is_non_standard = true;
            if (supports_reasoning_effort == null) supports_reasoning_effort = flavor.supports_reasoning_effort;
            if (max_tokens_field == null) max_tokens_field = flavor.max_tokens_field;
            if (requires_reasoning_content == null) requires_reasoning_content = flavor.requires_reasoning_content_on_assistant_messages;
            if (thinking_format == null) thinking_format = flavor.thinking_format;
            if (supports_strict_mode == null) supports_strict_mode = flavor.supports_strict_mode;
            if (supports_long_cache_retention == null) supports_long_cache_retention = flavor.supports_long_cache_retention;
        }
    }

    // Non-tabular: OpenRouter routes anthropic/* models to Anthropic's API,
    // which needs the anthropic cache_control breadcrumb on messages/tools.
    // This is provider+id specific so it doesn't fit a (provider, base_url)
    // flavor row.
    const detected_cache_control_format: ?[]const u8 = if (std.mem.eql(u8, model.provider, "openrouter") and std.mem.startsWith(u8, model.id, "anthropic/"))
        "anthropic"
    else
        null;

    return .{
        .supports_store = compatBoolField(model.compat, "supportsStore") orelse !is_non_standard,
        .supports_developer_role = compatBoolField(model.compat, "supportsDeveloperRole") orelse !is_non_standard,
        .supports_reasoning_effort = compatBoolField(model.compat, "supportsReasoningEffort") orelse (supports_reasoning_effort orelse true),
        .supports_usage_in_streaming = compatBoolField(model.compat, "supportsUsageInStreaming") orelse true,
        .max_tokens_field = compatStringField(model.compat, "maxTokensField") orelse (max_tokens_field orelse "max_completion_tokens"),
        .requires_tool_result_name = compatBoolField(model.compat, "requiresToolResultName") orelse false,
        .requires_assistant_after_tool_result = compatBoolField(model.compat, "requiresAssistantAfterToolResult") orelse false,
        .requires_thinking_as_text = compatBoolField(model.compat, "requiresThinkingAsText") orelse false,
        .requires_reasoning_content_on_assistant_messages = compatBoolField(model.compat, "requiresReasoningContentOnAssistantMessages") orelse (requires_reasoning_content orelse false),
        .thinking_format = compatStringField(model.compat, "thinkingFormat") orelse (thinking_format orelse "openai"),
        .open_router_routing = compatObjectValueField(model.compat, "openRouterRouting") orelse null,
        .vercel_gateway_routing = compatObjectValueField(model.compat, "vercelGatewayRouting") orelse null,
        .zai_tool_stream = compatBoolField(model.compat, "zaiToolStream") orelse false,
        .supports_strict_mode = compatBoolField(model.compat, "supportsStrictMode") orelse (supports_strict_mode orelse true),
        .cache_control_format = compatStringField(model.compat, "cacheControlFormat") orelse detected_cache_control_format,
        .send_session_affinity_headers = compatBoolField(model.compat, "sendSessionAffinityHeaders") orelse false,
        .supports_long_cache_retention = compatBoolField(model.compat, "supportsLongCacheRetention") orelse (supports_long_cache_retention orelse true),
    };
}

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn compatStringField(compat: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn compatObjectValueField(compat: ?std.json.Value, key: []const u8) ?std.json.Value {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .object) return null;
    return field;
}

fn isNonStandardProvider(model: types.Model) bool {
    inline for (FLAVORS) |flavor| {
        if (flavor.is_non_standard and flavorMatches(model, flavor)) return true;
    }
    return false;
}

pub fn buildResolvedCompatSnapshotValue(allocator: std.mem.Allocator, model: types.Model) !std.json.Value {
    const compat = getCompat(model);
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    try putBoolValue(allocator, &object, "requiresAssistantAfterToolResult", compat.requires_assistant_after_tool_result);
    try putBoolValue(allocator, &object, "requiresReasoningContentOnAssistantMessages", compat.requires_reasoning_content_on_assistant_messages);
    try putBoolValue(allocator, &object, "requiresThinkingAsText", compat.requires_thinking_as_text);
    try putBoolValue(allocator, &object, "requiresToolResultName", compat.requires_tool_result_name);
    try putObjectValue(allocator, &object, "openRouterRouting", if (compat.open_router_routing) |routing| try provider_json.cloneValue(allocator, routing) else try emptyObjectValue(allocator));
    try putBoolValue(allocator, &object, "sendSessionAffinityHeaders", compat.send_session_affinity_headers);
    try putBoolValue(allocator, &object, "supportsDeveloperRole", compat.supports_developer_role);
    try putBoolValue(allocator, &object, "supportsLongCacheRetention", compat.supports_long_cache_retention);
    try putBoolValue(allocator, &object, "supportsReasoningEffort", compat.supports_reasoning_effort);
    try putBoolValue(allocator, &object, "supportsStore", compat.supports_store);
    try putBoolValue(allocator, &object, "supportsStrictMode", compat.supports_strict_mode);
    try putBoolValue(allocator, &object, "supportsUsageInStreaming", compat.supports_usage_in_streaming);
    try putStringValue(allocator, &object, "maxTokensField", compat.max_tokens_field);
    try putStringValue(allocator, &object, "thinkingFormat", compat.thinking_format);
    try putObjectValue(allocator, &object, "vercelGatewayRouting", if (compat.vercel_gateway_routing) |routing| try provider_json.cloneValue(allocator, routing) else try emptyObjectValue(allocator));
    try putBoolValue(allocator, &object, "zaiToolStream", compat.zai_tool_stream);
    if (compat.cache_control_format) |format| {
        try putStringValue(allocator, &object, "cacheControlFormat", format);
    }

    return .{ .object = object };
}

fn emptyObjectValue(allocator: std.mem.Allocator) !std.json.Value {
    return provider_json.emptyObjectValue(allocator);
}

fn normalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    _ = source;

    if (std.mem.indexOfScalar(u8, id, '|')) |separator_index| {
        const prefix = id[0..separator_index];
        return sanitizeOpenAIToolCallId(allocator, prefix);
    }

    if (std.mem.eql(u8, model.provider, "openai")) {
        const trimmed = if (id.len > 40) id[0..40] else id;
        return try allocator.dupe(u8, trimmed);
    }

    return try allocator.dupe(u8, id);
}

fn sanitizeOpenAIToolCallId(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') {
            try result.append(allocator, byte);
        } else {
            try result.append(allocator, '_');
        }
        if (result.items.len == 40) break;
    }

    return try result.toOwnedSlice(allocator);
}

fn buildUserMessage(allocator: std.mem.Allocator, model: types.Model, user_msg: types.UserMessage) !std.json.Value {
    // Check if message contains images
    var has_images = false;
    for (user_msg.content) |block| {
        if (block == .image) {
            has_images = true;
            break;
        }
    }

    // Check if model supports images
    var model_supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            model_supports_images = true;
            break;
        }
    }

    if (has_images and model_supports_images) {
        // Build content as array of parts
        var content_parts = std.json.Array.init(allocator);
        errdefer provider_json.freeValue(allocator, .{ .array = content_parts });

        for (user_msg.content) |block| {
            switch (block) {
                .text => |text| {
                    const sanitized = try sanitizeSurrogates(allocator, text.text);
                    defer allocator.free(sanitized);
                    var part = try provider_json.initObject(allocator);
                    errdefer provider_json.freeValue(allocator, .{ .object = part });
                    try putStringValue(allocator, &part, "type", "text");
                    try putStringValue(allocator, &part, "text", sanitized);
                    try content_parts.append(.{ .object = part });
                },
                .image => |image| {
                    var part = try provider_json.initObject(allocator);
                    errdefer provider_json.freeValue(allocator, .{ .object = part });
                    try putStringValue(allocator, &part, "type", "image_url");

                    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
                    defer allocator.free(url);

                    const image_url_value: std.json.Value = blk: {
                        var image_url = try provider_json.initObject(allocator);
                        errdefer provider_json.freeValue(allocator, .{ .object = image_url });
                        try putStringValue(allocator, &image_url, "url", url);
                        break :blk .{ .object = image_url };
                    };
                    try putObjectValue(allocator, &part, "image_url", image_url_value);
                    try content_parts.append(.{ .object = part });
                },
                .thinking, .tool_call => continue, // User messages shouldn't have thinking/tool-call blocks
            }
        }

        var obj = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = obj });
        try putStringValue(allocator, &obj, "role", "user");
        try putObjectValue(allocator, &obj, "content", .{ .array = content_parts });
        return .{ .object = obj };
    } else {
        // Plain text content
        var text_parts = std.ArrayList(u8).empty;
        defer text_parts.deinit(allocator);

        for (user_msg.content) |block| {
            switch (block) {
                .text => |text| {
                    if (text_parts.items.len > 0) {
                        try text_parts.appendSlice(allocator, "\n");
                    }
                    try text_parts.appendSlice(allocator, text.text);
                },
                .image => {
                    if (!model_supports_images) {
                        if (text_parts.items.len > 0) {
                            try text_parts.appendSlice(allocator, "\n");
                        }
                        try text_parts.appendSlice(allocator, "(image omitted: model does not support images)");
                    }
                },
                .thinking, .tool_call => continue,
            }
        }

        const sanitized = try sanitizeSurrogates(allocator, text_parts.items);
        defer allocator.free(sanitized);
        return std.json.Value{ .object = try buildMessageObject(allocator, "user", sanitized) };
    }
}

pub fn buildAssistantMessage(allocator: std.mem.Allocator, model: types.Model, assistant_msg: types.AssistantMessage) !?std.json.Value {
    const compat = getCompat(model);
    const tool_calls_source = if (types.hasInlineToolCalls(assistant_msg))
        try types.collectAssistantToolCalls(allocator, assistant_msg)
    else
        null;
    defer if (tool_calls_source) |calls| allocator.free(calls);
    const assistant_tool_calls = tool_calls_source orelse assistant_msg.tool_calls;
    const has_tool_calls = if (assistant_tool_calls) |calls| calls.len > 0 else false;

    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStringValue(allocator, &obj, "role", "assistant");

    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);
    var thinking_parts = std.ArrayList(u8).empty;
    defer thinking_parts.deinit(allocator);
    var reasoning_field_name: ?[]const u8 = null;

    for (assistant_msg.content) |block| {
        switch (block) {
            .text => |text| {
                try text_parts.appendSlice(allocator, text.text);
            },
            .thinking => |thinking| {
                const signature = types.thinkingSignature(thinking);
                const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                if (trimmed.len == 0 and signature == null) continue;
                if (compat.requires_thinking_as_text) {
                    if (trimmed.len == 0) continue;
                    if (thinking_parts.items.len > 0) {
                        try thinking_parts.appendSlice(allocator, "\n\n");
                    }
                    try thinking_parts.appendSlice(allocator, thinking.thinking);
                } else if (signature) |value| {
                    if (trimmed.len > 0) {
                        if (reasoning_field_name == null) reasoning_field_name = value;
                        if (reasoning_field_name != null and std.mem.eql(u8, reasoning_field_name.?, value)) {
                            if (thinking_parts.items.len > 0) {
                                try thinking_parts.appendSlice(allocator, "\n");
                            }
                            try thinking_parts.appendSlice(allocator, thinking.thinking);
                        }
                    }
                }
            },
            .image, .tool_call => continue,
        }
    }

    if (compat.requires_thinking_as_text and thinking_parts.items.len > 0) {
        var content_parts = std.json.Array.init(allocator);
        errdefer provider_json.freeValue(allocator, .{ .array = content_parts });

        const sanitized_thinking = try sanitizeSurrogates(allocator, thinking_parts.items);
        defer allocator.free(sanitized_thinking);
        const thinking_part_value: std.json.Value = blk: {
            var thinking_part = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = thinking_part });
            try putStringValue(allocator, &thinking_part, "type", "text");
            try putStringValue(allocator, &thinking_part, "text", sanitized_thinking);
            break :blk .{ .object = thinking_part };
        };
        try content_parts.append(thinking_part_value);

        if (text_parts.items.len > 0) {
            const sanitized_text = try sanitizeSurrogates(allocator, text_parts.items);
            defer allocator.free(sanitized_text);
            const text_part_value: std.json.Value = blk: {
                var text_part = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = text_part });
                try putStringValue(allocator, &text_part, "type", "text");
                try putStringValue(allocator, &text_part, "text", sanitized_text);
                break :blk .{ .object = text_part };
            };
            try content_parts.append(text_part_value);
        }

        try putObjectValue(allocator, &obj, "content", .{ .array = content_parts });
    } else {
        const content = if (text_parts.items.len > 0) try sanitizeSurrogates(allocator, text_parts.items) else try allocator.dupe(u8, "");
        defer allocator.free(content);
        if (content.len == 0 and has_tool_calls) {
            if (compat.requires_assistant_after_tool_result) {
                try putStringValue(allocator, &obj, "content", "");
            } else {
                try putObjectValue(allocator, &obj, "content", .null);
            }
        } else if (content.len > 0) {
            try putStringValue(allocator, &obj, "content", content);
        } else if (compat.requires_assistant_after_tool_result) {
            try putStringValue(allocator, &obj, "content", "");
        } else {
            try putObjectValue(allocator, &obj, "content", .null);
        }
    }

    if (!compat.requires_thinking_as_text and thinking_parts.items.len > 0 and reasoning_field_name != null) {
        const sanitized_reasoning = try sanitizeSurrogates(allocator, thinking_parts.items);
        defer allocator.free(sanitized_reasoning);
        try putStringValue(allocator, &obj, reasoning_field_name.?, sanitized_reasoning);
    } else if (compat.requires_reasoning_content_on_assistant_messages and model.reasoning and obj.get("reasoning_content") == null) {
        try putStringValue(allocator, &obj, "reasoning_content", "");
    }

    if (assistant_tool_calls) |tool_calls| {
        try appendAssistantToolCalls(allocator, &obj, tool_calls);
    }

    const content_value = obj.get("content") orelse .null;
    const has_content = switch (content_value) {
        .string => |content| content.len > 0,
        .array => |content| content.items.len > 0,
        else => false,
    };
    if (!has_content and !has_tool_calls) {
        provider_json.freeValue(allocator, .{ .object = obj });
        return null;
    }

    return std.json.Value{ .object = obj };
}

fn appendAssistantToolCalls(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    tool_calls: []const types.ToolCall,
) !void {
    var tc_array = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = tc_array });
    for (tool_calls) |tc| {
        const tc_value: std.json.Value = blk: {
            var tc_obj = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = tc_obj });
            try putStringValue(allocator, &tc_obj, "id", tc.id);
            try putStringValue(allocator, &tc_obj, "type", "function");

            const func_value: std.json.Value = inner: {
                var func_obj = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = func_obj });
                try putStringValue(allocator, &func_obj, "name", tc.name);
                const args_owned = try std.json.Stringify.valueAlloc(allocator, tc.arguments, .{});
                defer allocator.free(args_owned);
                try putStringValue(allocator, &func_obj, "arguments", args_owned);
                break :inner .{ .object = func_obj };
            };
            try putObjectValue(allocator, &tc_obj, "function", func_value);
            break :blk .{ .object = tc_obj };
        };
        try tc_array.append(tc_value);
    }
    try putObjectValue(allocator, obj, "tool_calls", .{ .array = tc_array });
    try appendAssistantReasoningDetails(allocator, obj, tool_calls);
}

fn appendAssistantReasoningDetails(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    tool_calls: []const types.ToolCall,
) !void {
    var reasoning_details = std.json.Array.init(allocator);
    for (tool_calls) |tc| {
        if (tc.thought_signature) |sig| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, sig, .{}) catch continue;
            defer parsed.deinit();
            if (isFalseyJsonValue(parsed.value)) continue;
            reasoning_details.append(try provider_json.cloneValue(allocator, parsed.value)) catch continue;
        }
    }
    if (reasoning_details.items.len > 0) {
        try putObjectValue(allocator, obj, "reasoning_details", .{ .array = reasoning_details });
    } else {
        reasoning_details.deinit();
    }
}

const ToolResultAppendResult = struct {
    next_index: usize,
    appended_image_user: bool,
};

fn appendToolResultMessages(
    allocator: std.mem.Allocator,
    messages: *std.json.Array,
    model: types.Model,
    transformed_messages: []const types.Message,
    start_index: usize,
) !ToolResultAppendResult {
    const compat = getCompat(model);
    var image_parts = std.json.Array.init(allocator);
    defer image_parts.deinit();

    var index = start_index;
    while (index < transformed_messages.len and transformed_messages[index] == .tool_result) : (index += 1) {
        const tool_result = transformed_messages[index].tool_result;
        try messages.append(try buildToolResultMessage(allocator, model, tool_result));
        try appendToolResultImageParts(allocator, model, tool_result, &image_parts);
    }

    if (image_parts.items.len > 0) {
        if (compat.requires_assistant_after_tool_result) {
            try messages.append(.{ .object = try buildMessageObject(allocator, "assistant", "I have processed the tool results.") });
        }
        try messages.append(try buildToolResultImageUserMessage(allocator, image_parts));
        return .{ .next_index = index, .appended_image_user = true };
    }
    return .{ .next_index = index, .appended_image_user = false };
}

fn buildToolResultMessage(allocator: std.mem.Allocator, model: types.Model, tool_result: types.ToolResultMessage) !std.json.Value {
    const compat = getCompat(model);
    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);

    for (tool_result.content) |block| {
        switch (block) {
            .text => |text| {
                if (text_parts.items.len > 0) {
                    try text_parts.appendSlice(allocator, "\n");
                }
                try text_parts.appendSlice(allocator, text.text);
            },
            .image => {},
            .thinking, .tool_call => continue,
        }
    }

    const content = if (text_parts.items.len > 0)
        try sanitizeSurrogates(allocator, text_parts.items)
    else
        try allocator.dupe(u8, "(see attached image)");
    defer allocator.free(content);

    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStringValue(allocator, &obj, "role", "tool");
    try putStringValue(allocator, &obj, "content", content);
    try putStringValue(allocator, &obj, "tool_call_id", tool_result.tool_call_id);

    // Add name if required by provider
    if (compat.requires_tool_result_name and tool_result.tool_name.len > 0) {
        try putStringValue(allocator, &obj, "name", tool_result.tool_name);
    }

    return .{ .object = obj };
}

fn appendToolResultImageParts(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
    image_parts: *std.json.Array,
) !void {
    var model_supports_images = false;
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) {
            model_supports_images = true;
            break;
        }
    }
    if (!model_supports_images) return;

    for (tool_result.content) |block| {
        if (block != .image) continue;
        const part_value: std.json.Value = blk: {
            var part = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = part });
            try putStringValue(allocator, &part, "type", "image_url");

            const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ block.image.mime_type, block.image.data });
            defer allocator.free(url);

            const image_url_value: std.json.Value = inner: {
                var image_url = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = image_url });
                try putStringValue(allocator, &image_url, "url", url);
                break :inner .{ .object = image_url };
            };
            try putObjectValue(allocator, &part, "image_url", image_url_value);
            break :blk .{ .object = part };
        };
        try image_parts.append(part_value);
    }
}

fn buildToolResultImageUserMessage(
    allocator: std.mem.Allocator,
    image_parts: std.json.Array,
) !std.json.Value {
    var content_parts = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = content_parts });

    const text_part_value: std.json.Value = blk: {
        var text_part = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = text_part });
        try putStringValue(allocator, &text_part, "type", "text");
        try putStringValue(allocator, &text_part, "text", "Attached image(s) from tool result:");
        break :blk .{ .object = text_part };
    };
    try content_parts.append(text_part_value);

    for (image_parts.items) |part| {
        try content_parts.append(part);
    }

    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStringValue(allocator, &obj, "role", "user");
    try putObjectValue(allocator, &obj, "content", .{ .array = content_parts });
    return .{ .object = obj };
}

fn buildToolObject(allocator: std.mem.Allocator, tool: types.Tool, compat: OpenAICompat) !std.json.Value {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStringValue(allocator, &obj, "type", "function");

    const func_value: std.json.Value = blk: {
        var func_obj = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = func_obj });
        try putStringValue(allocator, &func_obj, "name", tool.name);
        try putStringValue(allocator, &func_obj, "description", tool.description);
        try putObjectValue(allocator, &func_obj, "parameters", try provider_json.cloneValue(allocator, tool.parameters));
        if (compat.supports_strict_mode) {
            try putBoolValue(allocator, &func_obj, "strict", false);
        }
        break :blk .{ .object = func_obj };
    };
    try putObjectValue(allocator, &obj, "function", func_value);
    return .{ .object = obj };
}

fn buildMessageObject(allocator: std.mem.Allocator, role: []const u8, content: []const u8) !std.json.ObjectMap {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStringValue(allocator, &obj, "role", role);
    try putStringValue(allocator, &obj, "content", content);
    return obj;
}

test "Together compat uses non-standard chat payload fields" {
    const allocator = std.testing.allocator;

    var tool_schema = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    defer provider_json.freeValue(allocator, tool_schema);
    try putStringValue(allocator, &tool_schema.object, "type", "object");

    const model = types.Model{
        .id = "moonshotai/Kimi-K2.6",
        .name = "Kimi K2.6",
        .api = "openai-completions",
        .provider = "together",
        .base_url = "https://api.together.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 262144,
        .max_tokens = 131000,
    };
    const context = types.Context{
        .system_prompt = "Follow instructions.",
        .messages = &[_]types.Message{},
        .tools = &[_]types.Tool{.{
            .name = "lookup",
            .description = "Look up data",
            .parameters = tool_schema,
        }},
    };

    const payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .max_tokens = 256,
        .session_id = "together-session",
        .cache_retention = .long,
        .provider = .{ .openai = .{ .reasoning_effort = "high" } },
    }, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("store") == null);
    try std.testing.expect(payload.object.get("prompt_cache_key") == null);
    try std.testing.expect(payload.object.get("prompt_cache_retention") == null);
    try std.testing.expect(payload.object.get("max_completion_tokens") == null);
    try std.testing.expectEqual(@as(i64, 256), payload.object.get("max_tokens").?.integer);
    try std.testing.expect(payload.object.get("reasoning_effort") == null);
    try std.testing.expectEqual(true, payload.object.get("reasoning").?.object.get("enabled").?.bool);

    const messages = payload.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings("system", messages[0].object.get("role").?.string);

    const tool = payload.object.get("tools").?.array.items[0].object;
    const function = tool.get("function").?.object;
    try std.testing.expect(function.get("strict") == null);
}

test "Together reasoning payload preserves supported mapped effort" {
    const allocator = std.testing.allocator;

    var compat = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try compat.put(allocator, try allocator.dupe(u8, "thinkingFormat"), .{ .string = try allocator.dupe(u8, "together") });
    try compat.put(allocator, try allocator.dupe(u8, "supportsReasoningEffort"), .{ .bool = true });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "deepseek-ai/DeepSeek-V4-Pro",
        .name = "DeepSeek V4 Pro",
        .api = "openai-completions",
        .provider = "custom-provider",
        .base_url = "https://api.together.xyz/v1",
        .reasoning = true,
        .thinking_level_map = .{ .high = .{ .mapped = "max" } },
        .input_types = &[_][]const u8{"text"},
        .context_window = 512000,
        .max_tokens = 384000,
        .compat = compat_value,
    };
    const context = types.Context{ .messages = &[_]types.Message{} };

    const enabled_payload = try buildRequestPayload(allocator, model, context, .{
        .provider = .{ .openai = .{ .reasoning_effort = "high" } },
    });
    defer provider_json.freeValue(allocator, enabled_payload);
    try std.testing.expectEqual(true, enabled_payload.object.get("reasoning").?.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("max", enabled_payload.object.get("reasoning_effort").?.string);

    const disabled_payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, disabled_payload);
    try std.testing.expectEqual(false, disabled_payload.object.get("reasoning").?.object.get("enabled").?.bool);
    try std.testing.expect(disabled_payload.object.get("reasoning_effort") == null);
}
