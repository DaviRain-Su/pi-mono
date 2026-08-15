const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_json_put = @import("../shared/provider_json_put.zig");
const provider_stream = @import("../shared/provider_stream.zig");

const putBoolValue = provider_json_put.putBoolValue;
const putStringValue = provider_json_put.putStringValue;
const putObjectValue = provider_json_put.putObjectValue;
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const shared_url = @import("../shared/url.zig");
const cloudflare = @import("cloudflare.zig");
const github_copilot_headers = @import("github_copilot_headers.zig");
const chat_payload = @import("openai_chat_payload.zig");
const chat_sse = @import("openai_chat_sse.zig");
const test_stream_server = @import("test_stream_server.zig");

const parseSseStreamLines = chat_sse.parseSseStreamLines;
const parseChunkUsage = chat_sse.parseChunkUsage;
const mapStopReason = chat_sse.mapStopReason;

pub const OpenAIProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("openai-completions", streamProduction);
    pub const api = BaseProvider.api;
    pub const stream = BaseProvider.stream;
    pub const streamSimple = BaseProvider.streamSimple;

    fn streamProduction(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
        event_stream_instance: *event_stream.AssistantMessageEventStream,
    ) !void {
        // Build request payload
        const payload = try buildFinalRequestPayload(allocator, model, context, options);
        defer provider_json.freeValue(allocator, payload);

        // Serialize payload to JSON
        var json_out: std.Io.Writer.Allocating = .init(allocator);
        const json_writer = &json_out.writer;
        defer json_out.deinit();

        try std.json.Stringify.value(payload, .{}, json_writer);

        // Resolve provider authentication.
        const resolved = try resolve_api_key.resolveApiKey(allocator, model, options);
        defer if (resolved) |r| r.deinit(allocator);

        if (resolved == null) {
            try resolve_api_key.pushMissingApiKeyError(allocator, event_stream_instance, model);
            return;
        }

        var resolved_options = if (options) |stream_options| stream_options else types.StreamOptions{};
        resolved_options.api_key = resolved.?.key;

        // Build HTTP request
        var headers = try buildRequestHeaders(allocator, model, resolved_options);
        defer provider_stream.deinitOwnedHeaders(allocator, &headers);

        try github_copilot_headers.applyDynamicHeadersIfCopilot(allocator, &headers, model, context.messages);

        const resolved_base_url = try cloudflare.resolveBaseUrlOrNull(allocator, model);
        defer if (resolved_base_url) |url| allocator.free(url);

        const request_target = try buildOpenAIChatRequestTarget(allocator, resolved_base_url orelse model.base_url);
        defer request_target.deinit(allocator);

        const req = http_client.HttpRequest{
            .method = .POST,
            .url = request_target.url,
            .headers = headers,
            .body = json_out.written(),
            .timeout_ms = if (options) |opts| opts.timeout_ms orelse 0 else 0,
            .aborted = if (options) |opts| opts.signal else null,
        };

        // Send request and process response
        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var streaming = try client.requestStreaming(req);
        defer streaming.deinit();

        if (options) |opts| {
            if (opts.on_response) |on_response| {
                try provider_stream.invokeOnResponse(allocator, on_response, streaming.status, streaming.response_headers, model);
            }
        }

        if (streaming.status != 200) {
            const response_body = try streaming.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, event_stream_instance, model, streaming.status, response_body);
            return;
        }

        // Parse SSE stream incrementally from lines
        try parseSseStreamLines(allocator, event_stream_instance, &streaming, model, options);
    }
};

/// Free allocated fields within an AssistantMessageEvent.
/// Note: this only frees fields that are exclusively owned by this event.
/// The `done` event's message content is shared with earlier events and should NOT be freed here.
fn freeEvent(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    if (event.owns_delta) {
        if (event.delta) |d| allocator.free(d);
    }
    // Do NOT free event.content or event.message - they are shared with content_blocks
    if (event.error_message) |em| allocator.free(em);
}

/// Removes unpaired Unicode surrogate characters from text.
/// Valid paired surrogates (proper emoji) are preserved.
pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return chat_payload.sanitizeSurrogates(allocator, text);
}

/// Recursively free a JSON value and all its children, including ObjectMap keys.
/// Use this only for values where ALL keys and strings were allocated by the same allocator.
pub fn freeOwnedJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

fn processCacheRetentionEnv() ?[]const u8 {
    return chat_payload.processCacheRetentionEnv();
}

fn resolveCacheRetention(cache_retention: types.CacheRetention, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return chat_payload.resolveCacheRetention(cache_retention, pi_cache_retention_env);
}

fn resolveOptionsCacheRetention(options: ?types.StreamOptions, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return chat_payload.resolveOptionsCacheRetention(options, pi_cache_retention_env);
}

pub fn buildFinalRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return chat_payload.buildFinalRequestPayload(allocator, model, context, options);
}

fn buildFinalRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    return chat_payload.buildFinalRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
}

/// Build the request payload for OpenAI chat completions API
pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return chat_payload.buildRequestPayload(allocator, model, context, options);
}

fn buildRequestPayloadWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    return chat_payload.buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
}

fn getCompat(model: types.Model) chat_payload.OpenAICompat {
    return chat_payload.getCompat(model);
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.StringHashMap([]const u8) {
    return buildRequestHeadersWithCacheRetentionEnv(allocator, model, options, processCacheRetentionEnv());
}

fn buildRequestHeadersWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer provider_stream.deinitOwnedHeaders(allocator, &headers);
    const compat = getCompat(model);
    const cache_retention = resolveOptionsCacheRetention(options, pi_cache_retention_env);

    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Content-Type", "application/json");
    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Accept", "text/event-stream");

    const api_key = if (options) |opts| opts.api_key orelse "" else "";
    if (std.mem.trim(u8, api_key, &std.ascii.whitespace).len > 0) {
        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        defer allocator.free(auth_header);
        if (std.mem.eql(u8, model.provider, "cloudflare-ai-gateway")) {
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "cf-aig-authorization", auth_header);
        } else {
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Authorization", auth_header);
        }
    }

    try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, model.headers);
    if (options) |stream_options| {
        if (cache_retention != .none and stream_options.session_id != null and compat.send_session_affinity_headers) {
            const session_id = stream_options.session_id.?;
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "session_id", session_id);
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "x-client-request-id", session_id);
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "x-session-affinity", session_id);
        }
        try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, stream_options.headers);
    }

    return headers;
}

/// Parse an OpenAI Chat SSE byte slice and return the final AssistantMessage.
/// This is a test/parity helper that wraps the extracted SSE stream parser.
/// The caller owns the returned message; free with the same allocator used for parsing.
pub fn parseSseAssistantMessageFromSlice(
    allocator: std.mem.Allocator,
    io: std.Io,
    sse_data: []const u8,
    model: types.Model,
) !types.AssistantMessage {
    return chat_sse.parseSseAssistantMessageFromSlice(allocator, io, sse_data, model);
}

/// Parse SSE line and extract JSON data.
pub fn parseSseLine(line: []const u8) ?[]const u8 {
    return chat_sse.parseSseLine(line);
}

/// Parse a streaming chunk from OpenAI.
/// Returns a parsed JSON value or null. Caller must call `.deinit()` on the result.
pub fn parseChunk(allocator: std.mem.Allocator, data: []const u8) !?std.json.Parsed(std.json.Value) {
    return chat_sse.parseChunk(allocator, data);
}

pub fn buildResolvedCompatSnapshotValue(allocator: std.mem.Allocator, model: types.Model) !std.json.Value {
    return chat_payload.buildResolvedCompatSnapshotValue(allocator, model);
}

pub fn buildRequestSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return buildRequestSnapshotValueWithCacheRetentionEnv(allocator, model, context, options, processCacheRetentionEnv());
}

pub fn buildRequestSnapshotValueWithCacheRetentionEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    pi_cache_retention_env: ?[]const u8,
) !std.json.Value {
    var payload = try buildFinalRequestPayloadWithCacheRetentionEnv(allocator, model, context, options, pi_cache_retention_env);
    errdefer provider_json.freeValue(allocator, payload);

    var headers = try buildRequestHeadersWithCacheRetentionEnv(allocator, model, options, pi_cache_retention_env);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    // Use provider_json.freeValue (full deep-free) instead of snapshot.deinit
    // (shallow map-only deinit) so duped keys + string values cannot leak.
    var snapshot = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = snapshot });

    const request_target = try buildOpenAIChatRequestTarget(allocator, model.base_url);
    defer request_target.deinit(allocator);

    try putStringValue(allocator, &snapshot, "baseUrl", model.base_url);
    try putObjectValue(allocator, &snapshot, "headers", .{ .object = try normalizeSemanticHeaders(allocator, headers) });
    try putObjectValue(allocator, &snapshot, "jsonPayload", payload);
    payload = .null;
    try putStringValue(allocator, &snapshot, "method", "POST");
    try putStringValue(allocator, &snapshot, "path", request_target.path);
    try putStringValue(allocator, &snapshot, "url", request_target.url);

    return .{ .object = snapshot };
}

const OpenAIChatRequestTarget = struct {
    url: []const u8,
    path: []const u8,

    fn deinit(self: OpenAIChatRequestTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.url);
    }
};

fn buildOpenAIChatRequestTarget(allocator: std.mem.Allocator, base_url: []const u8) !OpenAIChatRequestTarget {
    const url = try buildOpenAIChatRequestUrl(allocator, base_url);
    errdefer allocator.free(url);

    const path = try buildRequestPathFromUrl(allocator, url);
    errdefer allocator.free(path);

    return .{
        .url = url,
        .path = path,
    };
}

fn buildOpenAIChatRequestUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    return shared_url.buildUrl("/chat/completions", allocator, base_url);
}

fn buildRequestPathFromUrl(allocator: std.mem.Allocator, request_url: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, request_url, "://") orelse return try allocator.dupe(u8, "/chat/completions");
    const after_scheme_index = scheme + 3;
    const after_origin = request_url[after_scheme_index..];
    const slash_index = std.mem.indexOfScalar(u8, after_origin, '/') orelse return try allocator.dupe(u8, "/");
    return try allocator.dupe(u8, request_url[after_scheme_index + slash_index ..]);
}

fn normalizeSemanticHeaders(
    allocator: std.mem.Allocator,
    headers: std.StringHashMap([]const u8),
) !std.json.ObjectMap {
    var semantic = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer semantic.deinit(allocator);

    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        const lower = try asciiLowerAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(lower);
        const include = std.mem.eql(u8, lower, "authorization") or
            std.mem.eql(u8, lower, "content-type") or
            std.mem.eql(u8, lower, "session_id") or
            std.mem.eql(u8, lower, "x-client-request-id") or
            std.mem.eql(u8, lower, "x-session-affinity") or
            std.mem.startsWith(u8, lower, "x-fixture-");
        if (!include) continue;

        const value = if (std.mem.eql(u8, lower, "authorization"))
            if (entry.value_ptr.*.len > 0) "<redacted-present>" else "<redacted-empty>"
        else
            entry.value_ptr.*;

        const next_value = std.json.Value{ .string = try allocator.dupe(u8, value) };
        if (semantic.getPtr(lower)) |existing| {
            provider_json.freeValue(allocator, existing.*);
            existing.* = next_value;
        } else {
            try semantic.put(allocator, try allocator.dupe(u8, lower), next_value);
        }
    }

    return semantic;
}

const asciiLowerAlloc = @import("../shared/string_utils.zig").asciiLowerAlloc;

fn trimRightScalar(value: []const u8, scalar: u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == scalar) : (end -= 1) {}
    return value[0..end];
}

fn buildAssistantMessage(allocator: std.mem.Allocator, model: types.Model, assistant_msg: types.AssistantMessage) !?std.json.Value {
    return chat_payload.buildAssistantMessage(allocator, model, assistant_msg);
}

test "buildRequestPayload basic" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1234567890,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload == .object);
    const model_val = payload.object.get("model").?;
    try std.testing.expectEqualStrings("gpt-4", model_val.string);

    const messages = payload.object.get("messages").?;
    try std.testing.expect(messages == .array);
    try std.testing.expectEqual(@as(usize, 2), messages.array.items.len);

    // Check stream_options.include_usage
    const stream_options = payload.object.get("stream_options").?;
    try std.testing.expect(stream_options == .object);
    const include_usage = stream_options.object.get("include_usage").?;
    try std.testing.expect(include_usage == .bool);
    try std.testing.expect(include_usage.bool);
}

test "buildRequestPayload with developer role for reasoning model" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "o1-preview",
        .name = "O1 Preview",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 32768,
    };

    const context = types.Context{
        .system_prompt = "You are a reasoning assistant.",
        .messages = &[_]types.Message{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    const messages = payload.object.get("messages").?;
    try std.testing.expectEqual(@as(usize, 1), messages.array.items.len);

    const first_msg = messages.array.items[0];
    try std.testing.expect(first_msg == .object);
    const role = first_msg.object.get("role").?;
    try std.testing.expectEqualStrings("developer", role.string);
}

test "buildRequestPayload with tools" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    var tool_schema = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
    defer provider_json.freeValue(allocator, tool_schema);
    try putStringValue(allocator, &tool_schema.object, "type", "object");

    const tools = &[_]types.Tool{
        .{
            .name = "get_weather",
            .description = "Get the weather for a location",
            .parameters = tool_schema,
        },
    };

    const context = types.Context{
        .system_prompt = null,
        .messages = &[_]types.Message{},
        .tools = tools,
    };

    {
        const payload = try buildRequestPayload(allocator, model, context, null);
        defer provider_json.freeValue(allocator, payload);

        const tools_val = payload.object.get("tools").?;
        try std.testing.expect(tools_val == .array);
        try std.testing.expectEqual(@as(usize, 1), tools_val.array.items.len);

        const tool = tools_val.array.items[0];
        try std.testing.expect(tool == .object);
        const tool_type = tool.object.get("type").?;
        try std.testing.expectEqualStrings("function", tool_type.string);
    }

    const schema_type = tool_schema.object.get("type").?;
    try std.testing.expectEqualStrings("object", schema_type.string);
    try putObjectValue(allocator, &tool_schema.object, "required", .{ .array = std.json.Array.init(allocator) });
}

test "buildRequestPayload with image content" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4-vision",
        .name = "GPT-4 Vision",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .system_prompt = null,
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "What's in this image?" } },
                    .{ .image = .{ .data = "base64data", .mime_type = "image/png" } },
                },
                .timestamp = 1234567890,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    const messages = payload.object.get("messages").?;
    const user_msg = messages.array.items[0];
    try std.testing.expect(user_msg == .object);

    const content = user_msg.object.get("content").?;
    try std.testing.expect(content == .array);
    try std.testing.expectEqual(@as(usize, 2), content.array.items.len);

    const image_part = content.array.items[1];
    try std.testing.expect(image_part == .object);
    const part_type = image_part.object.get("type").?;
    try std.testing.expectEqualStrings("image_url", part_type.string);
}

test "parseSseLine" {
    const line = "data: {\"foo\": 123}";
    const result = parseSseLine(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("{\"foo\": 123}", result.?);

    const no_data = "event: start";
    const no_result = parseSseLine(no_data);
    try std.testing.expect(no_result == null);
}

test "parseChunk" {
    const allocator = std.testing.allocator;

    const done = try parseChunk(allocator, "[DONE]");
    try std.testing.expect(done == null);

    const empty = try parseChunk(allocator, "");
    try std.testing.expect(empty == null);

    const valid = try parseChunk(allocator, "{\"foo\": 123}");
    defer if (valid) |*v| v.deinit();
    try std.testing.expect(valid != null);
    try std.testing.expect(valid.?.value == .object);
}

test "mapStopReason" {
    const allocator = std.testing.allocator;

    const r1 = try mapStopReason(allocator, "stop");
    try std.testing.expectEqual(types.StopReason.stop, r1.stop_reason);
    try std.testing.expect(r1.error_message == null);

    const r2 = try mapStopReason(allocator, "length");
    try std.testing.expectEqual(types.StopReason.length, r2.stop_reason);
    try std.testing.expect(r2.error_message == null);

    const r3 = try mapStopReason(allocator, "tool_calls");
    try std.testing.expectEqual(types.StopReason.tool_use, r3.stop_reason);
    try std.testing.expect(r3.error_message == null);

    const r4 = try mapStopReason(allocator, "content_filter");
    defer if (r4.error_message) |message| allocator.free(message);
    try std.testing.expectEqual(types.StopReason.error_reason, r4.stop_reason);
    try std.testing.expect(r4.error_message != null);
    try std.testing.expectEqualStrings("Provider finish_reason: content_filter", r4.error_message.?);

    const reason = "unknown_reason";
    const r5 = try mapStopReason(allocator, reason);
    defer if (r5.error_message) |message| allocator.free(message);
    try std.testing.expectEqual(types.StopReason.error_reason, r5.stop_reason);
    try std.testing.expect(r5.error_message != null);
    try std.testing.expectEqualStrings("Provider finish_reason: unknown_reason", r5.error_message.?);
    try std.testing.expect(r5.error_message.?.ptr != reason.ptr);
}

test "sanitizeSurrogates preserves valid emoji" {
    const allocator = std.testing.allocator;
    // "🙈" in UTF-8: F0 9F 99 88 (not surrogates, it's a 4-byte sequence)
    const text = "Hello 🙈 World";
    const result = try sanitizeSurrogates(allocator, text);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(text, result);
}

test "sanitizeSurrogates removes unpaired surrogate bytes with caller allocator" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'A', 0xED, 0xA0, 0x80, 'B', 0xED, 0xB0, 0x80, 'C' };
    const result = try sanitizeSurrogates(allocator, &input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ABC", result);
}

test "buildRequestHeaders merges model and option headers" {
    const allocator = std.testing.allocator;

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("X-Model", "model");
    try model_headers.put("X-Shared", "model");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("X-Option", "option");
    try option_headers.put("X-Shared", "option");

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
        .headers = model_headers,
    };

    var headers = try buildRequestHeaders(allocator, model, .{
        .api_key = "test-key",
        .headers = option_headers,
    });
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("Bearer test-key", headers.get("Authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", headers.get("Accept").?);
    try std.testing.expectEqualStrings("model", headers.get("X-Model").?);
    try std.testing.expectEqualStrings("option", headers.get("X-Option").?);
    try std.testing.expectEqualStrings("option", headers.get("X-Shared").?);

    var anonymous_headers = try buildRequestHeaders(allocator, model, .{});
    defer provider_stream.deinitOwnedHeaders(allocator, &anonymous_headers);
    try std.testing.expect(anonymous_headers.get("Authorization") == null);
}

test "buildRequestHeaders applies case-insensitive override order" {
    const allocator = std.testing.allocator;

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("authorization", "Bearer model");
    try model_headers.put("accept", "application/json");
    try model_headers.put("X-Shared", "model");

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("AUTHORIZATION", "Bearer option");
    try option_headers.put("CONTENT-TYPE", "application/x-fixture");
    try option_headers.put("x-shared", "option");

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
        .headers = model_headers,
    };

    var headers = try buildRequestHeaders(allocator, model, .{
        .api_key = "test-key",
        .headers = option_headers,
    });
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqual(@as(u32, 4), headers.count());
    try std.testing.expect(headers.get("Authorization") == null);
    try std.testing.expect(headers.get("authorization") == null);
    try std.testing.expectEqualStrings("Bearer option", headers.get("AUTHORIZATION").?);
    try std.testing.expect(headers.get("Content-Type") == null);
    try std.testing.expectEqualStrings("application/x-fixture", headers.get("CONTENT-TYPE").?);
    try std.testing.expect(headers.get("Accept") == null);
    try std.testing.expectEqualStrings("application/json", headers.get("accept").?);
    try std.testing.expect(headers.get("X-Shared") == null);
    try std.testing.expectEqualStrings("option", headers.get("x-shared").?);
}

test "OpenAI Chat request target uses one production URL builder for trailing slash and base path" {
    const allocator = std.testing.allocator;

    const base_path_target = try buildOpenAIChatRequestTarget(allocator, "https://proxy.example.test/custom/openai/v1/");
    defer base_path_target.deinit(allocator);
    try std.testing.expectEqualStrings("https://proxy.example.test/custom/openai/v1/chat/completions", base_path_target.url);
    try std.testing.expectEqualStrings("/custom/openai/v1/chat/completions", base_path_target.path);

    const root_target = try buildOpenAIChatRequestTarget(allocator, "https://api.openai.com");
    defer root_target.deinit(allocator);
    try std.testing.expectEqualStrings("https://api.openai.com/chat/completions", root_target.url);
    try std.testing.expectEqualStrings("/chat/completions", root_target.path);

    const standard_target = try buildOpenAIChatRequestTarget(allocator, "https://api.openai.com/v1");
    defer standard_target.deinit(allocator);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", standard_target.url);
    try std.testing.expectEqualStrings("/v1/chat/completions", standard_target.path);
}

test "OpenAI Chat cache retention resolver preserves explicit values over env fallback" {
    try std.testing.expectEqual(types.CacheRetention.long, resolveCacheRetention(.unset, "long"));
    try std.testing.expectEqual(types.CacheRetention.short, resolveCacheRetention(.unset, null));
    try std.testing.expectEqual(types.CacheRetention.short, resolveCacheRetention(.short, "long"));
    try std.testing.expectEqual(types.CacheRetention.none, resolveCacheRetention(.none, "long"));
    try std.testing.expectEqual(types.CacheRetention.long, resolveCacheRetention(.long, null));
}

test "buildRequestPayload uses production cache retention resolver for prompt cache fields" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
    const context = types.Context{ .messages = &[_]types.Message{} };

    const env_long_payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .session_id = "session-env-long",
        .cache_retention = .unset,
    }, "long");
    defer provider_json.freeValue(allocator, env_long_payload);
    try std.testing.expectEqualStrings("session-env-long", env_long_payload.object.get("prompt_cache_key").?.string);
    try std.testing.expectEqualStrings("24h", env_long_payload.object.get("prompt_cache_retention").?.string);

    const explicit_short_payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .session_id = "session-short",
        .cache_retention = .short,
    }, "long");
    defer provider_json.freeValue(allocator, explicit_short_payload);
    try std.testing.expectEqualStrings("session-short", explicit_short_payload.object.get("prompt_cache_key").?.string);
    try std.testing.expect(explicit_short_payload.object.get("prompt_cache_retention") == null);

    const explicit_none_payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .session_id = "session-none",
        .cache_retention = .none,
    }, "long");
    defer provider_json.freeValue(allocator, explicit_none_payload);
    try std.testing.expect(explicit_none_payload.object.get("prompt_cache_key") == null);
    try std.testing.expect(explicit_none_payload.object.get("prompt_cache_retention") == null);

    const omitted_without_env_payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .session_id = "session-default-short",
        .cache_retention = .unset,
    }, null);
    defer provider_json.freeValue(allocator, omitted_without_env_payload);
    try std.testing.expectEqualStrings("session-default-short", omitted_without_env_payload.object.get("prompt_cache_key").?.string);
    try std.testing.expect(omitted_without_env_payload.object.get("prompt_cache_retention") == null);
}

test "buildRequestHeaders uses production cache retention resolver for session affinity" {
    const allocator = std.testing.allocator;

    var compat = try provider_json.initObject(allocator);
    try putBoolValue(allocator, &compat, "sendSessionAffinityHeaders", true);
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "openrouter-session-affinity",
        .name = "OpenRouter Session Affinity",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
        .compat = compat_value,
    };

    var env_long_headers = try buildRequestHeadersWithCacheRetentionEnv(allocator, model, .{
        .session_id = "session-env-long",
        .cache_retention = .unset,
    }, "long");
    defer provider_stream.deinitOwnedHeaders(allocator, &env_long_headers);
    try std.testing.expectEqualStrings("session-env-long", env_long_headers.get("session_id").?);
    try std.testing.expectEqualStrings("session-env-long", env_long_headers.get("x-client-request-id").?);
    try std.testing.expectEqualStrings("session-env-long", env_long_headers.get("x-session-affinity").?);

    var explicit_none_headers = try buildRequestHeadersWithCacheRetentionEnv(allocator, model, .{
        .session_id = "session-none",
        .cache_retention = .none,
    }, "long");
    defer provider_stream.deinitOwnedHeaders(allocator, &explicit_none_headers);
    try std.testing.expect(explicit_none_headers.get("session_id") == null);
    try std.testing.expect(explicit_none_headers.get("x-client-request-id") == null);
    try std.testing.expect(explicit_none_headers.get("x-session-affinity") == null);
}

test "buildRequestPayload uses production cache retention resolver for Anthropic cache control" {
    const allocator = std.testing.allocator;

    var compat = try provider_json.initObject(allocator);
    try putStringValue(allocator, &compat, "cacheControlFormat", "anthropic");
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "anthropic-cache-control",
        .name = "Anthropic Cache Control",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
        .compat = compat_value,
    };
    const context = types.Context{
        .system_prompt = "Cache the instruction.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Cache the user text." } }},
                .timestamp = 0,
            } },
        },
    };

    const env_long_payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .cache_retention = .unset,
    }, "long");
    defer provider_json.freeValue(allocator, env_long_payload);
    const env_long_messages = env_long_payload.object.get("messages").?.array.items;
    const env_long_instruction_content = env_long_messages[0].object.get("content").?.array.items;
    const env_long_cache_control = env_long_instruction_content[0].object.get("cache_control").?.object;
    try std.testing.expectEqualStrings("ephemeral", env_long_cache_control.get("type").?.string);
    try std.testing.expectEqualStrings("1h", env_long_cache_control.get("ttl").?.string);

    const explicit_short_payload = try buildRequestPayloadWithCacheRetentionEnv(allocator, model, context, .{
        .cache_retention = .short,
    }, "long");
    defer provider_json.freeValue(allocator, explicit_short_payload);
    const explicit_short_messages = explicit_short_payload.object.get("messages").?.array.items;
    const explicit_short_instruction_content = explicit_short_messages[0].object.get("content").?.array.items;
    const explicit_short_cache_control = explicit_short_instruction_content[0].object.get("cache_control").?.object;
    try std.testing.expectEqualStrings("ephemeral", explicit_short_cache_control.get("type").?.string);
    try std.testing.expect(explicit_short_cache_control.get("ttl") == null);
}

test "buildRequestPayload transforms orphaned tool calls and normalizes ids" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 16384,
    };

    const assistant_arguments = std.json.Value{
        .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}),
    };
    defer provider_json.freeValue(allocator, assistant_arguments);

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .tool_calls = &[_]types.ToolCall{.{
            .id = "call_1|fc_1",
            .name = "weather",
            .arguments = assistant_arguments,
        }},
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-5",
        .usage = types.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = assistant },
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Continue" } }},
                .timestamp = 2,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    const messages = payload.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);

    const assistant_message = messages[0].object;
    const tool_calls = assistant_message.get("tool_calls").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tool_calls.len);
    try std.testing.expectEqualStrings("call_1", tool_calls[0].object.get("id").?.string);

    const synthetic_tool_result = messages[1].object;
    try std.testing.expectEqualStrings("tool", synthetic_tool_result.get("role").?.string);
    try std.testing.expectEqualStrings("call_1", synthetic_tool_result.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings("No result provided", synthetic_tool_result.get("content").?.string);

    const user_message = messages[2].object;
    try std.testing.expectEqualStrings("user", user_message.get("role").?.string);
}

test "buildRequestPayload omits empty tools array" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .messages = &[_]types.Message{},
        .tools = &[_]types.Tool{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("tools") == null);
}

test "buildAssistantMessage separates thinking from text" {
    const allocator = std.testing.allocator;

    var compat = try provider_json.initObject(allocator);
    try putBoolValue(allocator, &compat, "requiresThinkingAsText", false);
    try putBoolValue(allocator, &compat, "requiresReasoningContentOnAssistantMessages", true);
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "deepseek-reasoner",
        .name = "DeepSeek Reasoner",
        .api = "openai-completions",
        .provider = "deepseek",
        .base_url = "https://api.deepseek.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 32768,
        .compat = compat_value,
    };

    const assistant = types.AssistantMessage{
        .content = &[_]types.ContentBlock{
            .{ .thinking = .{ .thinking = "internal reasoning", .signature = "reasoning_content" } },
            .{ .text = .{ .text = "final answer" } },
        },
        .api = "openai-completions",
        .provider = "deepseek",
        .model = "deepseek-reasoner",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    const message = (try buildAssistantMessage(allocator, model, assistant)).?;
    defer provider_json.freeValue(allocator, message);

    try std.testing.expectEqualStrings("final answer", message.object.get("content").?.string);
    try std.testing.expectEqualStrings("internal reasoning", message.object.get("reasoning_content").?.string);
}

test "stream respects pre-aborted signal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try OpenAIProvider.stream(allocator, io, model, context, .{
        .api_key = "test-key",
        .signal = &aborted,
    });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("Request was aborted", event.error_message.?);
    try std.testing.expectEqual(types.StopReason.aborted, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.aborted, result.stop_reason);
}

test "VAL-M9-STREAM-010 streamSimple matches stream pre-aborted terminal cancellation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var simple_stream = try OpenAIProvider.streamSimple(allocator, io, model, context, .{
        .api_key = "test-key",
        .signal = &aborted,
    });
    defer simple_stream.deinit();

    const event = simple_stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("Request was aborted", event.error_message.?);
    try std.testing.expectEqual(types.StopReason.aborted, event.message.?.stop_reason);
    try std.testing.expect(simple_stream.next() == null);

    const result = simple_stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.aborted, result.stop_reason);
}

test "stream emits single terminal sanitized error for HTTP status" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":\"quota exceeded\",\"Authorization\":\"Bearer sk-live-secret\",\"request_id\":\"req_random_123456789\",\"trace\":\"/Users/alice/pi/trace.zig:1\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(
        io,
        429,
        "Too Many Requests",
        "x-request-id: req_header_secret\r\n",
        body.items,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream_instance = try OpenAIProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream_instance.deinit();

    const event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "quota exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-live-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("openai-completions", event.message.?.api);
    try std.testing.expectEqualStrings("openai", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-4", event.message.?.model);
    try std.testing.expect(stream_instance.next() == null);

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(event.message.?.stop_reason, result.stop_reason);
    try std.testing.expectEqual(event.message.?.usage.total_tokens, result.usage.total_tokens);
}

const RuntimeFailureServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    first_chunk: []const u8,
    second_chunk: []const u8,
    delay_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, first_chunk: []const u8, second_chunk: []const u8, delay_ms: u64) !RuntimeFailureServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .first_chunk = first_chunk,
            .second_chunk = second_chunk,
            .delay_ms = delay_ms,
        };
    }

    fn start(self: *RuntimeFailureServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *RuntimeFailureServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn url(self: *const RuntimeFailureServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *RuntimeFailureServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("runtime failure server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch |err| std.debug.panic("runtime failure server read failed: {}", .{err});
        writeResponse(self, stream) catch {};
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

    fn writeResponse(self: *RuntimeFailureServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        const total_len = self.first_chunk.len + self.second_chunk.len;
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{total_len},
        );
        try writer.interface.flush();
        try writer.interface.writeAll(self.first_chunk);
        try writer.interface.flush();
        if (self.delay_ms > 0) {
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        }
        try writer.interface.writeAll(self.second_chunk);
        try writer.interface.flush();
    }
};

fn runtimeFailureTestModel(base_url: []const u8) types.Model {
    return .{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

fn runtimeFailureContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

const OnPayloadPassThrough = struct {
    var called = false;
    var observed_post_compat_fields = false;

    fn reset() void {
        called = false;
        observed_post_compat_fields = false;
    }

    fn callback(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
        _ = allocator;
        called = true;
        try std.testing.expectEqualStrings("gpt-4", model.id);
        try std.testing.expect(payload == .object);
        observed_post_compat_fields = payload.object.get("stream_options") != null and
            payload.object.get("store") != null and
            payload.object.get("messages") != null;
        return null;
    }
};

const OnPayloadReplacement = struct {
    var called = false;

    fn reset() void {
        called = false;
    }

    fn callback(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
        _ = model;
        called = true;
        try std.testing.expect(payload == .object);
        try std.testing.expect(payload.object.get("messages") != null);

        var replacement = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = replacement });
        try putStringValue(allocator, &replacement, "fixture_marker", "replacement");
        try putBoolValue(allocator, &replacement, "stream", true);
        return .{ .object = replacement };
    }
};

fn failingOnPayload(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
    _ = allocator;
    _ = payload;
    _ = model;
    return error.FixtureOnPayloadFailure;
}

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
        try std.testing.expectEqualStrings("openai-completions", model.api);
        try std.testing.expectEqualStrings("application/json", headers.get("content-type").?);
        try std.testing.expectEqualStrings("callback-fixture", headers.get("x-fixture-response").?);
        try std.testing.expect(headers.get("Content-Type") == null);
    }
};

const OnResponseFailure = struct {
    var called = false;

    fn reset() void {
        called = false;
    }

    fn callback(callback_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        _ = model;
        called = true;
        try std.testing.expectEqual(@as(u16, 200), callback_status);
        try std.testing.expectEqualStrings("callback-fixture", headers.get("x-fixture-response").?);
        return error.FixtureOnResponseFailure;
    }
};

fn openAiCallbackTestModel(base_url: []const u8) types.Model {
    return .{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

fn openAiCallbackTestContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello callback" } }},
                .timestamp = 1,
            } },
        },
    };
}

fn expectOnlyTerminalError(
    stream: *event_stream.AssistantMessageEventStream,
    expected_error: []const u8,
) !void {
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings(expected_error, event.error_message.?);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
}

test "buildFinalRequestPayload on_payload observes post-compat payload and passes through" {
    const allocator = std.testing.allocator;
    OnPayloadPassThrough.reset();

    var payload = try buildFinalRequestPayload(
        allocator,
        openAiCallbackTestModel("https://api.openai.com/v1"),
        openAiCallbackTestContext(),
        .{ .api_key = "test-key", .on_payload = &OnPayloadPassThrough.callback },
    );
    defer freeOwnedJsonValue(allocator, payload);

    try std.testing.expect(OnPayloadPassThrough.called);
    try std.testing.expect(OnPayloadPassThrough.observed_post_compat_fields);
    try std.testing.expect(payload.object.get("fixture_marker") == null);
    try std.testing.expectEqualStrings("gpt-4", payload.object.get("model").?.string);
    try std.testing.expect(payload.object.get("stream_options") != null);
}

test "buildFinalRequestPayload on_payload replacement becomes submitted payload" {
    const allocator = std.testing.allocator;
    OnPayloadReplacement.reset();

    var payload = try buildFinalRequestPayload(
        allocator,
        openAiCallbackTestModel("https://api.openai.com/v1"),
        openAiCallbackTestContext(),
        .{ .api_key = "test-key", .on_payload = &OnPayloadReplacement.callback },
    );
    defer freeOwnedJsonValue(allocator, payload);

    try std.testing.expect(OnPayloadReplacement.called);
    try std.testing.expectEqualStrings("replacement", payload.object.get("fixture_marker").?.string);
    try std.testing.expect(payload.object.get("messages") == null);
}

test "stream on_payload failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIProvider.stream(
        allocator,
        io,
        openAiCallbackTestModel("https://api.openai.com/v1"),
        openAiCallbackTestContext(),
        .{ .api_key = "test-key", .on_payload = failingOnPayload },
    );
    defer stream.deinit();

    try expectOnlyTerminalError(&stream, "FixtureOnPayloadFailure");
}

test "stream on_response observes mocked status and normalized headers before body" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    OnResponseCapture.reset();

    const body = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":null}]}\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n" ++
        "data: [DONE]\n";
    var server = try provider_error.TestStatusServer.init(
        io,
        200,
        "OK",
        "x-fixture-response: callback-fixture\r\n",
        body,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try OpenAIProvider.stream(
        allocator,
        io,
        openAiCallbackTestModel(url),
        openAiCallbackTestContext(),
        .{ .api_key = "test-key", .on_response = &OnResponseCapture.callback },
    );
    defer stream.deinit();

    try std.testing.expect(OnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 200), OnResponseCapture.status);
    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    var saw_done = false;
    while (stream.next()) |event| {
        if (event.event_type == .done) {
            saw_done = true;
            try std.testing.expect(event.message != null);
            try std.testing.expectEqual(types.StopReason.stop, event.message.?.stop_reason);
            break;
        }
    }
    try std.testing.expect(saw_done);
}

test "stream on_response failure returns one terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    OnResponseFailure.reset();

    const body = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"unread\"},\"finish_reason\":null}]}\n" ++
        "data: [DONE]\n";
    var server = try provider_error.TestStatusServer.init(
        io,
        200,
        "OK",
        "x-fixture-response: callback-fixture\r\n",
        body,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try OpenAIProvider.stream(
        allocator,
        io,
        openAiCallbackTestModel(url),
        openAiCallbackTestContext(),
        .{ .api_key = "test-key", .on_response = &OnResponseFailure.callback },
    );
    defer stream.deinit();

    try std.testing.expect(OnResponseFailure.called);
    try expectOnlyTerminalError(&stream, "FixtureOnResponseFailure");
}

test "stream URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIProvider.stream(
        allocator,
        io,
        openAiCallbackTestModel("http://[::1"),
        openAiCallbackTestContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalError(&stream, "InvalidUrl");
}

fn expectMissingApiKeyTerminalError(
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
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "OPENAI_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "ANTHROPIC_API_KEY") == null);
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

    var stream = try OpenAIProvider.stream(
        allocator,
        io,
        openAiCallbackTestModel("https://api.openai.com/v1"),
        openAiCallbackTestContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalError(&stream, "openai");
}

test "VAL-M9-STREAM-006 streamSimple missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIProvider.streamSimple(
        allocator,
        io,
        openAiCallbackTestModel("https://api.openai.com/v1"),
        openAiCallbackTestContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalError(&stream, "openai");
}

test "VAL-M9-STREAM-006 stream null api key options returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIProvider.stream(
        allocator,
        io,
        openAiCallbackTestModel("https://api.openai.com/v1"),
        openAiCallbackTestContext(),
        null,
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalError(&stream, "openai");
}

test "parseSseStreamLines preserves partial text before malformed event JSON terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimeFailureTestModel("https://api.openai.com/v1"), null);

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
    try std.testing.expectEqualStrings(terminal.error_message.?, terminal.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}

test "stream preserves partial text before timeout terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try RuntimeFailureServer.init(
        io,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n",
        "data: [DONE]\n",
        500,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try OpenAIProvider.stream(allocator, io, runtimeFailureTestModel(url), runtimeFailureContext(), .{
        .api_key = "test-key",
        .timeout_ms = 100,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Timeout", terminal.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var server = try RuntimeFailureServer.init(
        io,
        "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n",
        "data: [DONE]\n",
        1000,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

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

    var stream = try OpenAIProvider.stream(allocator, io, runtimeFailureTestModel(url), runtimeFailureContext(), .{
        .api_key = "test-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines preserves successful ordered OpenAI-compatible final assistant semantics" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"id\":\"chatcmpl_cross\",\"choices\":[{\"delta\":{\"reasoning_content\":\"Think.\"},\"finish_reason\":null}]}\n" ++
            "data: {\"id\":\"chatcmpl_cross\",\"choices\":[{\"delta\":{\"content\":\"Answer.\"},\"finish_reason\":null}]}\n" ++
            "data: {\"id\":\"chatcmpl_cross\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_weather\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"id\":\"chatcmpl_cross\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"Berlin\\\"}\"}}]},\"finish_reason\":null}]}\n" ++
            "data: {\"id\":\"chatcmpl_cross\",\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":3,\"cache_write_tokens\":1}}}\n" ++
            "data: [DONE]\n",
    );

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gpt-4.1-fixture",
        .name = "GPT 4.1 Fixture",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);

    const thinking_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_start, thinking_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_start.content_index.?);
    const thinking_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_delta.content_index.?);
    try std.testing.expectEqualStrings("Think.", thinking_delta.delta.?);

    const text_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), text_start.content_index.?);
    const text_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), text_delta.content_index.?);
    try std.testing.expectEqualStrings("Answer.", text_delta.delta.?);

    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_start.content_index.?);
    const tool_delta_1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_1.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_delta_1.content_index.?);
    try std.testing.expectEqualStrings("{\"city\":\"", tool_delta_1.delta.?);
    const tool_delta_2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_2.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_delta_2.content_index.?);
    try std.testing.expectEqualStrings("Berlin\"}", tool_delta_2.delta.?);

    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_end.content_index.?);
    try std.testing.expectEqualStrings("Think.", thinking_end.content.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), text_end.content_index.?);
    try std.testing.expectEqualStrings("Answer.", text_end.content.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_end.content_index.?);
    try std.testing.expect(tool_end.tool_call != null);
    try std.testing.expectEqualStrings("call_weather", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expect(stream.next() == null);

    const message = done.message.?;
    try std.testing.expectEqualStrings("assistant", message.role);
    try std.testing.expectEqualStrings("openai-completions", message.api);
    try std.testing.expectEqualStrings("openai", message.provider);
    try std.testing.expectEqualStrings("gpt-4.1-fixture", message.model);
    try std.testing.expectEqualStrings("chatcmpl_cross", message.response_id.?);
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    // cached_tokens=3 (cache_read), cache_write=1 => input = 10 - 3 - 1 = 6
    try std.testing.expectEqual(@as(u32, 6), message.usage.input);
    try std.testing.expectEqual(@as(u32, 5), message.usage.output);
    try std.testing.expectEqual(@as(u32, 3), message.usage.cache_read);
    try std.testing.expectEqual(@as(u32, 1), message.usage.cache_write);
    try std.testing.expectEqual(@as(u32, 15), message.usage.total_tokens);
    try std.testing.expectEqual(@as(usize, 3), message.content.len);
    try std.testing.expectEqualStrings("Think.", message.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("reasoning_content", types.thinkingSignature(message.content[0].thinking).?);
    try std.testing.expectEqualStrings("Answer.", message.content[1].text.text);
    try std.testing.expectEqualStrings("call_weather", message.content[2].tool_call.id);
    try std.testing.expect(message.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), message.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_weather", message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("get_weather", message.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("Berlin", message.tool_calls.?[0].arguments.object.get("city").?.string);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(message.role, result.role);
    try std.testing.expectEqualStrings(message.api, result.api);
    try std.testing.expectEqualStrings(message.provider, result.provider);
    try std.testing.expectEqualStrings(message.model, result.model);
    try std.testing.expectEqualStrings(message.response_id.?, result.response_id.?);
    try std.testing.expectEqual(message.stop_reason, result.stop_reason);
    try std.testing.expectEqual(message.usage.input, result.usage.input);
    try std.testing.expectEqual(message.usage.output, result.usage.output);
    try std.testing.expectEqual(message.usage.cache_read, result.usage.cache_read);
    try std.testing.expectEqual(message.usage.cache_write, result.usage.cache_write);
    try std.testing.expectEqual(message.usage.total_tokens, result.usage.total_tokens);
    try std.testing.expectEqualStrings(message.content[0].thinking.thinking, result.content[0].thinking.thinking);
    try std.testing.expectEqualStrings(message.content[1].text.text, result.content[1].text.text);
    try std.testing.expectEqualStrings(message.content[2].tool_call.id, result.content[2].tool_call.id);
}

test "parseSseStream with tool calls" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"call_123\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"NYC\\\"}\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n" ++
        "data: [DONE]\n");
    // body is owned by StreamingResponse, do not free here

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    // Should emit start, toolcall_start, toolcall_delta, toolcall_end, done
    const event1 = stream.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);

    const event4 = stream.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_end, event4.event_type);
    try std.testing.expect(event4.tool_call != null);
    try std.testing.expectEqualStrings("get_weather", event4.tool_call.?.name);

    const event5 = stream.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expect(event5.message != null);
    try std.testing.expectEqual(types.StopReason.tool_use, event5.message.?.stop_reason);
    try std.testing.expect(event5.message.?.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), event5.message.?.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_123", event5.message.?.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("get_weather", event5.message.?.tool_calls.?[0].name);
    try std.testing.expectEqual(@as(usize, 1), event5.message.?.content.len);
    try std.testing.expect(event5.message.?.content[0] == .tool_call);
    try std.testing.expectEqualStrings("call_123", event5.message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("NYC", event5.message.?.content[0].tool_call.arguments.object.get("city").?.string);
}

test "parseSseStream keeps interleaved indexed tool arguments separated" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"{\\\"unit\\\":\\\"\"}},{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\\\"Ber\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_city\",\"function\":{\"name\":\"get_city\",\"arguments\":\"lin\\\"}\"}},{\"index\":1,\"id\":\"call_unit\",\"function\":{\"name\":\"get_unit\",\"arguments\":\"C\\\"}\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n" ++
        "data: [DONE]\n");

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const start_unit = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, start_unit.event_type);
    try std.testing.expectEqual(@as(u32, 0), start_unit.content_index.?);
    const unit_delta_1 = stream.next().?;
    defer freeEvent(allocator, unit_delta_1);
    try std.testing.expectEqual(types.EventType.toolcall_delta, unit_delta_1.event_type);
    try std.testing.expectEqual(@as(u32, 0), unit_delta_1.content_index.?);

    const start_city = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, start_city.event_type);
    try std.testing.expectEqual(@as(u32, 1), start_city.content_index.?);
    const city_delta_1 = stream.next().?;
    defer freeEvent(allocator, city_delta_1);
    try std.testing.expectEqual(types.EventType.toolcall_delta, city_delta_1.event_type);
    try std.testing.expectEqual(@as(u32, 1), city_delta_1.content_index.?);

    const city_delta_2 = stream.next().?;
    defer freeEvent(allocator, city_delta_2);
    try std.testing.expectEqual(types.EventType.toolcall_delta, city_delta_2.event_type);
    try std.testing.expectEqual(@as(u32, 1), city_delta_2.content_index.?);
    const unit_delta_2 = stream.next().?;
    defer freeEvent(allocator, unit_delta_2);
    try std.testing.expectEqual(types.EventType.toolcall_delta, unit_delta_2.event_type);
    try std.testing.expectEqual(@as(u32, 0), unit_delta_2.content_index.?);

    const unit_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, unit_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), unit_end.content_index.?);
    try std.testing.expectEqualStrings("call_unit", unit_end.tool_call.?.id);
    try std.testing.expectEqualStrings("C", unit_end.tool_call.?.arguments.object.get("unit").?.string);
    const city_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, city_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), city_end.content_index.?);
    try std.testing.expectEqualStrings("call_city", city_end.tool_call.?.id);
    try std.testing.expectEqualStrings("Berlin", city_end.tool_call.?.arguments.object.get("city").?.string);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(@as(usize, 2), done.message.?.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_unit", done.message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("call_city", done.message.?.content[1].tool_call.id);
}

test "parseSseStream with reasoning content" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Let me think...\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n" ++
        "data: [DONE]\n");
    // body is owned by StreamingResponse, do not free here

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "deepseek-reasoner",
        .name = "DeepSeek Reasoner",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.thinking_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEvent(allocator, event3);
    try std.testing.expectEqual(types.EventType.thinking_delta, event3.event_type);
    try std.testing.expectEqualStrings("Let me think...", event3.delta.?);

    const event4 = stream.next().?;
    defer freeEvent(allocator, event4);
    try std.testing.expectEqual(types.EventType.thinking_end, event4.event_type);

    const event5 = stream.next().?;
    defer freeEvent(allocator, event5);
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
}

test "parseSseStream with usage" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(u8, "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20}}\n" ++
        "data: [DONE]\n");
    // body is owned by StreamingResponse, do not free here

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    defer freeEvent(allocator, event1);
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    defer freeEvent(allocator, event2);
    try std.testing.expectEqual(types.EventType.done, event2.event_type);

    const result = stream.result().?;
    try std.testing.expectEqual(@as(u32, 10), result.usage.input);
    try std.testing.expectEqual(@as(u32, 20), result.usage.output);
}

test "parseChunkUsage" {
    const allocator = std.testing.allocator;

    const usage_json = "{\"prompt_tokens\":100,\"completion_tokens\":50,\"prompt_tokens_details\":{\"cached_tokens\":20,\"cache_write_tokens\":10},\"completion_tokens_details\":{\"reasoning_tokens\":5}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, usage_json, .{});
    defer parsed.deinit();

    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const usage = parseChunkUsage(allocator, parsed.value, model);

    // cache_read = cached_tokens = 20 (no subtraction per OpenRouter semantics)
    // input = 100 - 20 - 10 = 70
    // output = 50 because completion_tokens already includes reasoning_tokens
    try std.testing.expectEqual(@as(u32, 70), usage.input);
    try std.testing.expectEqual(@as(u32, 50), usage.output);
    try std.testing.expectEqual(@as(u32, 20), usage.cache_read);
    try std.testing.expectEqual(@as(u32, 10), usage.cache_write);
    try std.testing.expectEqual(@as(u32, 150), usage.total_tokens);
}

// Regression: cache_write_tokens alone exceeding prompt_tokens must not trap.
// prompt_tokens=15, cache_write_tokens=20, no cached_tokens.
// cache_read=0, cache_total=20 >= 15 => input clamps to 0.
test "parseChunkUsage cache write exceeds prompt saturates to zero" {
    const allocator = std.testing.allocator;
    const usage_json = "{\"prompt_tokens\":15,\"completion_tokens\":4,\"prompt_tokens_details\":{\"cache_write_tokens\":20}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, usage_json, .{});
    defer parsed.deinit();
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
    const usage = parseChunkUsage(allocator, parsed.value, model);
    // input clamps to zero because cache_write_tokens(20) > prompt_tokens(15)
    try std.testing.expectEqual(@as(u32, 0), usage.input);
    try std.testing.expectEqual(@as(u32, 4), usage.output);
    try std.testing.expectEqual(@as(u32, 0), usage.cache_read);
    try std.testing.expectEqual(@as(u32, 20), usage.cache_write);
    try std.testing.expectEqual(@as(u32, 24), usage.total_tokens);
}

test "openai stream cloudflare provider resolves base_url placeholders via env" {
    // Verifies that isCloudflareProvider gates resolveCloudflareBaseUrl: when the
    // env var referenced in base_url is absent, the stream returns a terminal
    // EnvironmentVariableNotFound error event rather than a networking error for a
    // literal {VAR} URL.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const model = types.Model{
        .id = "cloudflare-model",
        .name = "Cloudflare Model",
        .api = "openai-completions",
        .provider = "cloudflare-workers-ai",
        .base_url = "https://api.cloudflare.com/v1/{OPENAI_WIRE_IN_CF_TEST_ABSENT_VAR}/chat",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try OpenAIProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings("EnvironmentVariableNotFound", event.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
    var stream = try OpenAIProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();
    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("openai-completions", error_event.message.?.api);
    try std.testing.expectEqualStrings("openai", error_event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-4", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(error_event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}
