const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");
const finalize = @import("../shared/finalize.zig");
const provider_error = @import("../shared/provider_error.zig");
const provider_json = @import("../shared/provider_json.zig");
const provider_stream = @import("../shared/provider_stream.zig");
const responses_api = @import("../shared/responses_api.zig");
const sse_loop = @import("../shared/sse_loop.zig");
const stop_reason_mod = @import("../shared/stop_reason.zig");
const openai_usage = @import("../shared/openai_usage.zig");
const openai = @import("openai.zig");
const openai_responses = @import("openai_responses.zig");
const test_stream_server = @import("test_stream_server.zig");

const DEFAULT_AZURE_API_VERSION = "v1";
const AZURE_BASE_URL_ENV = "AZURE_OPENAI_BASE_URL";
const AZURE_RESOURCE_NAME_ENV = "AZURE_OPENAI_RESOURCE_NAME";
const AZURE_API_VERSION_ENV = "AZURE_OPENAI_API_VERSION";
const AZURE_DEPLOYMENT_MAP_ENV = "AZURE_OPENAI_DEPLOYMENT_NAME_MAP";

const CurrentBlock = responses_api.CurrentBlock;
const deinitCurrentBlock = responses_api.deinitCurrentBlock;
const extractMessageText = responses_api.extractMessageText;
const extractReasoningSummary = responses_api.extractReasoningSummary;
const finalizeCurrentBlock = responses_api.finalizeCurrentBlock;
const updateCurrentMessagePart = responses_api.updateCurrentMessagePart;

const OwnedHeader = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: OwnedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const AzureOpenAIResponsesProvider = struct {
    const BaseProvider = provider_stream.DefineProvider("azure-openai-responses", streamProduction);
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
        const deployment_name = try resolveDeploymentName(allocator, model.id, options);
        defer allocator.free(deployment_name);

        var request_model = model;
        request_model.id = deployment_name;

        const callback_opt: ?*const fn (std.mem.Allocator, std.json.Value, types.Model) anyerror!?std.json.Value =
            if (options) |o| o.on_payload else null;

        const json_body = blk: {
            if (callback_opt) |callback| {
                var payload = try buildAzureRequestPayload(allocator, request_model, context, options);
                defer provider_json.freeValue(allocator, payload);
                if (try callback(allocator, payload, model)) |replacement| {
                    provider_json.freeValue(allocator, payload);
                    payload = replacement;
                }
                break :blk try std.json.Stringify.valueAlloc(allocator, payload, .{});
            }
            break :blk try buildAzurePayloadJsonBytes(allocator, request_model, context, options);
        };
        defer allocator.free(json_body);

        const base_url = try resolveAzureBaseUrl(allocator, model, options);
        defer allocator.free(base_url);

        const api_version = try resolveAzureApiVersion(allocator, options);
        defer if (api_version.owned) allocator.free(api_version.value);

        const url = try buildRequestUrl(allocator, base_url, api_version.value);
        defer allocator.free(url);

        var headers = try buildRequestHeaders(allocator, model, options);
        defer provider_stream.deinitOwnedHeaders(allocator, &headers);

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

pub fn buildAzureRequestPayload(
    allocator: std.mem.Allocator,
    request_model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var payload = try openai_responses.buildRequestPayload(allocator, request_model, context, options);
    errdefer provider_json.freeValue(allocator, payload);

    try removeObjectField(allocator, &payload, "store");
    try removeObjectField(allocator, &payload, "prompt_cache_retention");
    try removeObjectField(allocator, &payload, "service_tier");
    try removeObjectField(allocator, &payload, "metadata");

    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            try removeObjectField(allocator, &payload, "prompt_cache_key");
            if (payload == .object) {
                try payload.object.put(
                    allocator,
                    try allocator.dupe(u8, "prompt_cache_key"),
                    .{ .string = try allocator.dupe(u8, session_id) },
                );
            }
        }
    }

    return payload;
}

/// Bytes-native fast path: pulls openai_responses bytes directly (struct →
/// Stringify) and applies Azure's field-removal / prompt_cache_key swap
/// in the parsed Value tree before re-stringifying. Saves the extra
/// parse+clone round-trip that buildAzureRequestPayload incurs through
/// openai_responses.buildRequestPayload.
pub fn buildAzurePayloadJsonBytes(
    allocator: std.mem.Allocator,
    request_model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) ![]u8 {
    const upstream_bytes = try openai_responses.buildPayloadJsonBytes(allocator, request_model, context, options);
    defer allocator.free(upstream_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, upstream_bytes, .{});
    defer parsed.deinit();

    var payload = try provider_json.cloneValue(allocator, parsed.value);
    defer provider_json.freeValue(allocator, payload);

    try removeObjectField(allocator, &payload, "store");
    try removeObjectField(allocator, &payload, "prompt_cache_retention");
    try removeObjectField(allocator, &payload, "service_tier");
    try removeObjectField(allocator, &payload, "metadata");

    if (options) |stream_options| {
        if (stream_options.session_id) |session_id| {
            try removeObjectField(allocator, &payload, "prompt_cache_key");
            if (payload == .object) {
                try payload.object.put(
                    allocator,
                    try allocator.dupe(u8, "prompt_cache_key"),
                    .{ .string = try allocator.dupe(u8, session_id) },
                );
            }
        }
    }

    return try std.json.Stringify.valueAlloc(allocator, payload, .{});
}

const ResolvedApiVersion = struct {
    value: []const u8,
    owned: bool,
};

pub const SnapshotEnv = struct {
    azure_api_version: ?[]const u8 = null,
    azure_base_url: ?[]const u8 = null,
    azure_resource_name: ?[]const u8 = null,
    azure_deployment_name_map: ?[]const u8 = null,
};

pub fn buildRequestSnapshotValueWithEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    env: SnapshotEnv,
    snapshot_options: openai_responses.RequestSnapshotOptions,
) !std.json.Value {
    const deployment_name = try resolveDeploymentNameWithEnv(allocator, model.id, options, env.azure_deployment_name_map);
    defer allocator.free(deployment_name);

    var request_model = model;
    request_model.id = deployment_name;

    var payload = if (snapshot_options.payload_override) |override|
        try provider_json.cloneValue(allocator, override)
    else
        try buildAzureRequestPayload(allocator, request_model, context, options);
    errdefer provider_json.freeValue(allocator, payload);

    const base_url = try resolveAzureBaseUrlWithEnv(allocator, model, options, env.azure_base_url, env.azure_resource_name);
    defer allocator.free(base_url);

    const api_version = try resolveAzureApiVersionWithEnv(allocator, options, env.azure_api_version);
    defer if (api_version.owned) allocator.free(api_version.value);

    const url = try buildRequestUrl(allocator, base_url, api_version.value);
    defer allocator.free(url);

    var headers = try buildRequestHeaders(allocator, model, options);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    var snapshot = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer snapshot.deinit(allocator);

    try snapshot.put(allocator, try allocator.dupe(u8, "baseUrl"), .{ .string = try openai_responses.inferResponsesBaseUrlFromUrl(allocator, url, snapshot_options.provider_family) });
    try snapshot.put(allocator, try allocator.dupe(u8, "headers"), .{ .object = try openai_responses.normalizeSemanticHeaders(allocator, headers) });
    try snapshot.put(allocator, try allocator.dupe(u8, "jsonPayload"), payload);
    payload = .null;
    try snapshot.put(allocator, try allocator.dupe(u8, "method"), .{ .string = try allocator.dupe(u8, snapshot_options.method) });
    try snapshot.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try openai_responses.buildResponsesRequestPathFromUrl(allocator, url) });
    try snapshot.put(allocator, try allocator.dupe(u8, "query"), .{ .object = try openai_responses.buildResponsesRequestQueryObjectFromUrl(allocator, url) });
    try snapshot.put(allocator, try allocator.dupe(u8, "requestOptions"), .{ .object = try openai_responses.buildRequestOptionsSnapshotObject(allocator, options, true) });
    try snapshot.put(allocator, try allocator.dupe(u8, "transportMetadata"), .{ .object = try openai_responses.buildTransportMetadataSnapshotObject(
        allocator,
        snapshot_options.scenario_id,
        snapshot_options.provider_family,
        snapshot_options.transport_mode,
        snapshot_options.mocked_status,
    ) });
    try snapshot.put(allocator, try allocator.dupe(u8, "url"), .{ .string = try allocator.dupe(u8, url) });

    return .{ .object = snapshot };
}

fn resolveDeploymentName(allocator: std.mem.Allocator, model_id: []const u8, options: ?types.StreamOptions) ![]const u8 {
    const env_value = try loadEnvOptional(allocator, AZURE_DEPLOYMENT_MAP_ENV);
    defer if (env_value) |value| allocator.free(value);

    return resolveDeploymentNameWithEnv(allocator, model_id, options, env_value);
}

fn resolveDeploymentNameWithEnv(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    options: ?types.StreamOptions,
    env_deployment_map: ?[]const u8,
) ![]const u8 {
    if (options) |stream_options| {
        const azure_opts = stream_options.providerOptions("azure");
        if (azure_opts.deployment_name) |deployment_name| {
            if (deployment_name.len > 0) return try allocator.dupe(u8, deployment_name);
        }
    }

    if (env_deployment_map) |value| {
        var entries = std.mem.splitScalar(u8, value, ',');
        while (entries.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |separator_index| {
                const lhs = std.mem.trim(u8, trimmed[0..separator_index], " \t\r\n");
                const rhs = std.mem.trim(u8, trimmed[separator_index + 1 ..], " \t\r\n");
                if (lhs.len == 0 or rhs.len == 0) continue;
                if (std.mem.eql(u8, lhs, model_id)) return try allocator.dupe(u8, rhs);
            }
        }
    }

    return try allocator.dupe(u8, model_id);
}

fn resolveAzureBaseUrl(allocator: std.mem.Allocator, model: types.Model, options: ?types.StreamOptions) ![]const u8 {
    const env_base_url = try loadEnvOptional(allocator, AZURE_BASE_URL_ENV);
    defer if (env_base_url) |value| allocator.free(value);
    const env_resource_name = try loadEnvOptional(allocator, AZURE_RESOURCE_NAME_ENV);
    defer if (env_resource_name) |value| allocator.free(value);

    return resolveAzureBaseUrlWithEnv(allocator, model, options, env_base_url, env_resource_name);
}

fn resolveAzureBaseUrlWithEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    env_base_url: ?[]const u8,
    env_resource_name: ?[]const u8,
) ![]const u8 {
    if (options) |stream_options| {
        const azure_opts = stream_options.providerOptions("azure");
        if (azure_opts.base_url) |value| {
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
                return try normalizeAzureBaseUrl(allocator, value);
            }
        }
        if (azure_opts.resource_name) |value| {
            const resource_name = std.mem.trim(u8, value, " \t\r\n");
            if (resource_name.len > 0) {
                return try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource_name});
            }
        }
    }

    if (env_base_url) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) {
            return try normalizeAzureBaseUrl(allocator, value);
        }
    }

    if (env_resource_name) |value| {
        const resource_name = std.mem.trim(u8, value, " \t\r\n");
        if (resource_name.len > 0) {
            return try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource_name});
        }
    }

    if (env_resource_name) |value| {
        const resource_name = std.mem.trim(u8, value, " \t\r\n");
        if (resource_name.len > 0) {
            return try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource_name});
        }
    }

    if (std.mem.trim(u8, model.base_url, " \t\r\n").len > 0) {
        return try normalizeAzureBaseUrl(allocator, model.base_url);
    }

    return error.MissingAzureBaseUrl;
}

fn resolveAzureApiVersion(allocator: std.mem.Allocator, options: ?types.StreamOptions) !ResolvedApiVersion {
    const env_api_version = try loadEnvOptional(allocator, AZURE_API_VERSION_ENV);
    defer if (env_api_version) |value| allocator.free(value);

    return resolveAzureApiVersionWithEnv(allocator, options, env_api_version);
}

fn resolveAzureApiVersionWithEnv(
    allocator: std.mem.Allocator,
    options: ?types.StreamOptions,
    env_api_version: ?[]const u8,
) !ResolvedApiVersion {
    if (options) |stream_options| {
        const azure_opts = stream_options.providerOptions("azure");
        if (azure_opts.api_version) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) return .{ .value = trimmed, .owned = false };
        }
    }

    if (env_api_version) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) return .{ .value = try allocator.dupe(u8, trimmed), .owned = true };
    }
    return .{ .value = DEFAULT_AZURE_API_VERSION, .owned = false };
}

fn normalizeAzureBaseUrl(allocator: std.mem.Allocator, raw_base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw_base_url, " \t\r\n"), "/");
    if (trimmed.len == 0) return error.MissingAzureBaseUrl;
    const uri = std.Uri.parse(trimmed) catch return error.InvalidAzureBaseUrl;
    const host = uri.host orelse return error.InvalidAzureBaseUrl;
    const host_text = host.percent_encoded;
    const path_text = uri.path.percent_encoded;
    const normalized_path = std.mem.trimEnd(u8, path_text, "/");
    const is_azure_host = std.mem.endsWith(u8, host_text, ".openai.azure.com") or
        std.mem.endsWith(u8, host_text, ".cognitiveservices.azure.com");

    if (is_azure_host and (normalized_path.len == 0 or std.mem.eql(u8, normalized_path, "/") or std.mem.eql(u8, normalized_path, "/openai"))) {
        return try std.fmt.allocPrint(allocator, "{s}://{s}/openai/v1", .{ uri.scheme, host_text });
    }

    return try allocator.dupe(u8, trimmed);
}

fn buildRequestUrl(allocator: std.mem.Allocator, raw_base_url: []const u8, api_version: []const u8) ![]const u8 {
    const base_url = try normalizeAzureBaseUrl(allocator, raw_base_url);
    defer allocator.free(base_url);

    if (std.mem.indexOfScalar(u8, base_url, '?')) |query_index| {
        return try std.fmt.allocPrint(
            allocator,
            "{s}?api-version={s}",
            .{ base_url[0..query_index], api_version },
        );
    }
    return try std.fmt.allocPrint(allocator, "{s}/responses?api-version={s}", .{ base_url, api_version });
}

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Content-Type", "application/json");
    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Accept", "application/json");
    try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, model.headers);
    if (options) |stream_options| {
        try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, stream_options.headers);
    }

    const auth = try resolveAzureAuthHeader(allocator, options);
    defer auth.deinit(allocator);
    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, auth.name, auth.value);

    return headers;
}

fn resolveAzureAuthHeader(allocator: std.mem.Allocator, options: ?types.StreamOptions) !OwnedHeader {
    const provided = if (options) |stream_options| stream_options.api_key else null;

    var env_api_key: ?[]u8 = null;
    defer if (env_api_key) |value| allocator.free(value);
    if (provided == null) {
        env_api_key = try env_api_keys.getEnvApiKey(allocator, "azure-openai-responses");
    }

    return resolveAuthHeaderValue(allocator, provided, env_api_key);
}

fn resolveAuthHeaderValue(
    allocator: std.mem.Allocator,
    provided_auth: ?[]const u8,
    env_api_key: ?[]const u8,
) !OwnedHeader {
    if (provided_auth) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            return .{
                .name = try allocator.dupe(u8, "api-key"),
                .value = try allocator.dupe(u8, trimmed),
            };
        }
    }

    if (env_api_key) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            return .{
                .name = try allocator.dupe(u8, "api-key"),
                .value = try allocator.dupe(u8, trimmed),
            };
        }
    }

    return error.MissingAzureCredentials;
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
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

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    stream_ptr.push(.{ .event_type = .start });

    var handler = AzureResponsesSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .current_block = &current_block,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .model = model,
    };
    const loop_result = try sse_loop.run(AzureResponsesSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped and !handler.normal_completion) {
        return;
    }

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });
    // Tool calls live inline in output.content; legacy field intentionally null.

    finalize.calculateCost(model, &output.usage);

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const AzureResponsesSseDataResult = enum {
    continue_loop,
    complete_loop,
    stop_loop,
};

const AzureResponsesSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    normal_completion: bool = false,

    pub fn extractDataLine(_: *AzureResponsesSseLoopHandler, line: []const u8) ?[]const u8 {
        return provider_stream.parseCanonicalSseDataLine(line);
    }

    pub fn isDoneData(_: *AzureResponsesSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *AzureResponsesSseLoopHandler, data: []const u8) !bool {
        var state = AzureResponsesSseState{
            .allocator = self.allocator,
            .stream_ptr = self.stream_ptr,
            .output = self.output,
            .current_block = self.current_block,
            .content_blocks = self.content_blocks,
            .tool_calls = self.tool_calls,
            .model = self.model,
        };
        const result = try processAzureResponsesSseData(&state, data);
        switch (result) {
            .continue_loop => return true,
            .complete_loop => {
                self.normal_completion = true;
                return false;
            },
            .stop_loop => return false,
        }
    }

    pub fn handleRuntimeFailure(self: *AzureResponsesSseLoopHandler, err: anyerror) !void {
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

const AzureResponsesSseState = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
};

fn processAzureResponsesSseData(state: *AzureResponsesSseState, data: []const u8) !AzureResponsesSseDataResult {
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

    const event_type_value = value.object.get("type") orelse return .continue_loop;
    if (event_type_value != .string) return .continue_loop;
    const event_type = event_type_value.string;

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

    if (try handleAzureResponsesReasoningEvent(state, event_type, value)) |result| return result;
    if (try handleAzureResponsesTextEvent(state, event_type, value)) |result| return result;
    if (try handleAzureResponsesToolEvent(state, event_type, value)) |result| return result;

    if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
        if (value.object.get("response")) |response_value| {
            try updateCompletedResponse(allocator, state.output, response_value, state.model);
        }
        return .complete_loop;
    }

    if (std.mem.eql(u8, event_type, "response.failed")) {
        const error_message = try extractFailureMessage(allocator, value.object.get("response"));
        try emitAzureResponsesTerminalError(state, error_message);
        return .stop_loop;
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const error_message = try extractTopLevelErrorMessage(allocator, value);
        try emitAzureResponsesTerminalError(state, error_message);
        return .stop_loop;
    }

    return .continue_loop;
}

fn handleAzureResponsesReasoningEvent(
    state: *AzureResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?AzureResponsesSseDataResult {
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        try appendAzureThinkingDelta(state, delta_value.string);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
        if (state.current_block.*) |*block| {
            switch (block.*) {
                .thinking => |*thinking| {
                    if (thinking.text.items.len > 0) {
                        try thinking.text.appendSlice(state.allocator, "\n\n");
                        state.stream_ptr.push(.{
                            .event_type = .thinking_delta,
                            .content_index = @intCast(thinking.event_index),
                            .delta = try state.allocator.dupe(u8, "\n\n"),
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
        try appendAzureThinkingDelta(state, delta_value.string);
        return .continue_loop;
    }

    return null;
}

fn handleAzureResponsesTextEvent(
    state: *AzureResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?AzureResponsesSseDataResult {
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
                    try text.text.appendSlice(state.allocator, delta_value.string);
                    state.stream_ptr.push(.{
                        .event_type = .text_delta,
                        .content_index = @intCast(text.event_index),
                        .delta = try state.allocator.dupe(u8, delta_value.string),
                        .owns_delta = true,
                    });
                },
                else => {},
            }
        }
        return .continue_loop;
    }

    return null;
}

fn handleAzureResponsesToolEvent(
    state: *AzureResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?AzureResponsesSseDataResult {
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        if (state.current_block.*) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    try tool_call.partial_json.appendSlice(state.allocator, delta_value.string);
                    state.stream_ptr.push(.{
                        .event_type = .toolcall_delta,
                        .content_index = @intCast(tool_call.event_index),
                        .delta = try state.allocator.dupe(u8, delta_value.string),
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
        try replaceAzureDoneToolArguments(state, arguments_value.string);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item_value = value.object.get("item") orelse return .continue_loop;
        try finalizeCurrentBlock(state.allocator, item_value, state.current_block, state.content_blocks, state.tool_calls, state.stream_ptr);
        return .continue_loop;
    }

    return null;
}

fn replaceAzureDoneToolArguments(state: *AzureResponsesSseState, arguments: []const u8) !void {
    if (state.current_block.*) |*block| {
        switch (block.*) {
            .tool_call => |*tool_call| {
                const previous = tool_call.partial_json.items;
                if (std.mem.startsWith(u8, arguments, previous)) {
                    const delta = arguments[previous.len..];
                    if (delta.len > 0) {
                        tool_call.partial_json.clearRetainingCapacity();
                        try tool_call.partial_json.appendSlice(state.allocator, arguments);
                        state.stream_ptr.push(.{
                            .event_type = .toolcall_delta,
                            .content_index = @intCast(tool_call.event_index),
                            .delta = try state.allocator.dupe(u8, delta),
                            .owns_delta = true,
                        });
                    }
                } else {
                    tool_call.partial_json.clearRetainingCapacity();
                    try tool_call.partial_json.appendSlice(state.allocator, arguments);
                }
            },
            else => {},
        }
    }
}

fn appendAzureThinkingDelta(state: *AzureResponsesSseState, delta: []const u8) !void {
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

fn emitAzureResponsesTerminalError(state: *AzureResponsesSseState, error_message: []const u8) !void {
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
    const item_type_value = item_value.object.get("type") orelse return;
    if (item_type_value != .string) return;

    if (std.mem.eql(u8, item_type_value.string, "reasoning")) {
        if (current_block.* != null) return;
        current_block.* = responses_api.initThinkingBlock(content_blocks.items.len);
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type_value.string, "message")) {
        if (current_block.* != null) return;
        current_block.* = responses_api.initTextBlock(content_blocks.items.len);
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type_value.string, "function_call")) {
        if (current_block.* != null) return;
        current_block.* = try responses_api.initToolCallBlockFromItem(allocator, content_blocks.items.len, item_value);
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(content_blocks.items.len) });
    }
}

fn extractStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(key) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn updateResponseIdFromResponseObject(allocator: std.mem.Allocator, output: *types.AssistantMessage, response_value: std.json.Value) !void {
    if (response_value != .object) return;
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
) !void {
    if (response_value != .object) return;
    try updateResponseIdFromResponseObject(allocator, output, response_value);

    if (response_value.object.get("usage")) |usage_value| {
        output.usage = parseUsage(usage_value);
        finalize.calculateCost(model, &output.usage);
    }

    if (extractStringField(response_value, "status")) |status| {
        output.stop_reason = mapStopReason(status);
    }
}

pub const parseUsage = openai_usage.parseResponsesUsage;

fn extractFailureMessage(allocator: std.mem.Allocator, response_value: ?std.json.Value) ![]const u8 {
    const response = response_value orelse return try sanitizeProviderTerminalError(allocator, "Unknown error (no error details in response)");
    if (response != .object) return try sanitizeProviderTerminalError(allocator, "Unknown error (no error details in response)");

    if (response.object.get("error")) |error_value| {
        if (error_value == .object) {
            const code = extractStringField(error_value, "code") orelse "unknown";
            const message = extractStringField(error_value, "message") orelse "no message";
            const raw = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ code, message });
            defer allocator.free(raw);
            return try sanitizeProviderTerminalError(allocator, raw);
        }
    }

    if (response.object.get("incomplete_details")) |details_value| {
        if (details_value == .object) {
            if (extractStringField(details_value, "reason")) |reason| {
                const raw = try std.fmt.allocPrint(allocator, "incomplete: {s}", .{reason});
                defer allocator.free(raw);
                return try sanitizeProviderTerminalError(allocator, raw);
            }
        }
    }

    return try sanitizeProviderTerminalError(allocator, "Unknown error (no error details in response)");
}

fn extractTopLevelErrorMessage(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (extractStringField(value, "code")) |code| {
        const message = extractStringField(value, "message") orelse "Unknown error";
        const raw = try std.fmt.allocPrint(allocator, "Error Code {s}: {s}", .{ code, message });
        defer allocator.free(raw);
        return try sanitizeProviderTerminalError(allocator, raw);
    }
    if (extractStringField(value, "message")) |message| {
        return try sanitizeProviderTerminalError(allocator, message);
    }
    return try sanitizeProviderTerminalError(allocator, "Unknown error");
}

fn sanitizeProviderTerminalError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return provider_error.sanitizeProviderErrorDetail(allocator, message);
}

fn mapStopReason(status: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.openai_responses_mappings, status, .error_reason);
}

const jsonIntegerToU32 = openai_usage.jsonIntegerToU32;

fn removeObjectField(allocator: std.mem.Allocator, payload: *std.json.Value, field_name: []const u8) !void {
    if (payload.* != .object) return;

    var old_object = payload.object;
    var new_object = try initObject(allocator);
    errdefer new_object.deinit(allocator);

    var iterator = old_object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, field_name)) {
            allocator.free(entry.key_ptr.*);
            provider_json.freeValue(allocator, entry.value_ptr.*);
            continue;
        }
        try new_object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    old_object.deinit(allocator);
    payload.* = .{ .object = new_object };
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

const DelayedBodyServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    body: []const u8,
    body_delay_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, body: []const u8, body_delay_ms: u64) !DelayedBodyServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .body = body,
            .body_delay_ms = body_delay_ms,
        };
    }

    fn start(self: *DelayedBodyServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *DelayedBodyServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn url(self: *const DelayedBodyServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *DelayedBodyServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => return,
        };
        defer stream.close(self.io);

        writeResponse(self, stream) catch {};
    }

    fn writeResponse(self: *DelayedBodyServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        );
        try writer.interface.flush();
        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.body_delay_ms)), .awake) catch {};
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

const AzureOnResponseCapture = struct {
    var called = false;
    var status: u16 = 0;

    fn reset() void {
        called = false;
        status = 0;
    }

    fn callback(callback_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
        called = true;
        status = callback_status;
        try std.testing.expectEqualStrings("azure-openai-responses", model.api);
        try std.testing.expectEqualStrings("text/event-stream", headers.get("content-type").?);
        try std.testing.expect(headers.get("Content-Type") == null);
    }
};

test "buildRequestUrl normalizes Azure resource endpoints" {
    const allocator = std.testing.allocator;
    const url = try buildRequestUrl(allocator, "https://example.openai.azure.com/", "v1");
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://example.openai.azure.com/openai/v1/responses?api-version=v1",
        url,
    );
}

test "buildRequestUrl appends api-version for dated Azure APIs" {
    const allocator = std.testing.allocator;
    const url = try buildRequestUrl(allocator, "https://example.openai.azure.com/openai/v1", "2025-03-01-preview");
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://example.openai.azure.com/openai/v1/responses?api-version=2025-03-01-preview",
        url,
    );
}

test "ISS-031 Azure request snapshot audits endpoint query and api-key semantics" {
    const allocator = std.testing.allocator;

    const missing_endpoint_model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    try std.testing.expectError(error.MissingAzureBaseUrl, resolveAzureBaseUrlWithEnv(allocator, missing_endpoint_model, null, null, null));

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://ignored-resource.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Audit Azure request semantics." } }},
                .timestamp = 1,
            } },
        },
    };

    const snapshot = try buildRequestSnapshotValueWithEnv(
        allocator,
        model,
        context,
        .{
            .api_key = "azure-fixture-key",
            .provider = .{ .azure = .{ .api_version = "2025-03-01-preview" } },
        },
        .{
            .azure_resource_name = "semantic-resource",
            .azure_deployment_name_map = "other=ignored,gpt-4.1=semantic-deployment",
        },
        .{
            .scenario_id = "iss-031-azure-header-endpoint-audit",
            .provider_family = "azure-openai",
        },
    );
    defer provider_json.freeValue(allocator, snapshot);

    const object = snapshot.object;
    try std.testing.expectEqualStrings("https://semantic-resource.openai.azure.com/openai/v1", object.get("baseUrl").?.string);
    try std.testing.expectEqualStrings("POST", object.get("method").?.string);
    try std.testing.expectEqualStrings("/openai/v1/responses", object.get("path").?.string);
    try std.testing.expectEqualStrings(
        "https://semantic-resource.openai.azure.com/openai/v1/responses?api-version=2025-03-01-preview",
        object.get("url").?.string,
    );
    try std.testing.expectEqualStrings("2025-03-01-preview", object.get("query").?.object.get("api-version").?.string);

    const headers = object.get("headers").?.object;
    try std.testing.expectEqualStrings("application/json", headers.get("accept").?.string);
    try std.testing.expectEqualStrings("application/json", headers.get("content-type").?.string);
    try std.testing.expectEqualStrings("<redacted-present>", headers.get("api-key").?.string);
    try std.testing.expect(headers.get("authorization") == null);

    const payload = object.get("jsonPayload").?.object;
    try std.testing.expectEqualStrings("semantic-deployment", payload.get("model").?.string);
    try std.testing.expectEqualStrings("Audit Azure request semantics.", payload.get("input").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "resolveAuthHeaderValue prefers api-key for plain credentials" {
    const allocator = std.testing.allocator;
    const auth = try resolveAuthHeaderValue(allocator, "azure-key", null);
    defer auth.deinit(allocator);

    try std.testing.expectEqualStrings("api-key", auth.name);
    try std.testing.expectEqualStrings("azure-key", auth.value);
}

test "resolveAuthHeaderValue treats bearer-looking credentials as Azure API keys" {
    const allocator = std.testing.allocator;
    const auth = try resolveAuthHeaderValue(allocator, "Bearer entra-token", null);
    defer auth.deinit(allocator);

    try std.testing.expectEqualStrings("api-key", auth.name);
    try std.testing.expectEqualStrings("Bearer entra-token", auth.value);
}

test "extractMessageText uses caller allocator" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"refusal\",\"refusal\":\" Azure\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractMessageText(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Hello Azure", text);
}

test "extractReasoningSummary uses caller allocator" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[{\"text\":\"first\"},{\"text\":\"second\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractReasoningSummary(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("first\n\nsecond", text);
}

test "extractReasoningSummary falls back to content text" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"azure content\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractReasoningSummary(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("azure content", text);
}

test "stream on_response normalizes Azure response headers" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_azure_headers\",\"status\":\"completed\"}}\n";
    var server = try DelayedBodyServer.init(io, body, 0);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = url,
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

    AzureOnResponseCapture.reset();

    var stream = try AzureOpenAIResponsesProvider.stream(allocator, io, model, context, .{
        .api_key = "test-key",
        .on_response = &AzureOnResponseCapture.callback,
    });
    defer stream.deinit();

    while (stream.next()) |event| {
        if (event.message) |message| {
            if (event.event_type == .done) freeAssistantMessageOwned(allocator, message);
        }
    }

    try std.testing.expect(AzureOnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 200), AzureOnResponseCapture.status);
}

test "parseSseStreamLines emits Azure text events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello Azure\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello Azure\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_azure\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":2,\"total_tokens\":4}}}\n" ++
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

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEventOwned(allocator, event3);
    try std.testing.expectEqual(types.EventType.text_delta, event3.event_type);
    try std.testing.expectEqualStrings("Hello Azure", event3.delta.?);

    const event4 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, event4.event_type);
    try std.testing.expectEqualStrings("Hello Azure", event4.content.?);

    const event5 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expect(event5.message != null);
    try std.testing.expectEqualStrings("resp_azure", event5.message.?.response_id.?);
    try std.testing.expectEqualStrings("Hello Azure", event5.message.?.content[0].text.text);

    freeAssistantMessageOwned(allocator, event5.message.?);
}

test "parseSseStreamLines keeps Azure canonical SSE strictness and terminal runtime ordering" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "event: response.output_item.added\n" ++
            "data:{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"compact_ignored\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial azure\"}\n" ++
            "data: {not-json}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"ignored\",\"status\":\"completed\"}}\n",
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

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);

    const delta = stream.next().?;
    defer freeEventOwned(allocator, delta);
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial azure", delta.delta.?);

    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial azure", text_end.content.?);

    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqualStrings("azure-openai-responses", error_event.message.?.api);
    try std.testing.expectEqualStrings("azure-openai-responses", error_event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1", error_event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial azure", error_event.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);

    var terminal_message = error_event.message.?;
    terminal_message.error_message = null;
    freeAssistantMessageOwned(allocator, terminal_message);
}

test "parseSseStreamLines emits Azure reasoning events without leaks" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_reasoning\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"first\"}\n" ++
            "data: {\"type\":\"response.reasoning_summary_part.done\"}\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"second\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"text\":\"first\"},{\"text\":\"second\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_reasoning\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":2,\"total_tokens\":4}}}\n" ++
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

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEventOwned(allocator, event3);
    try std.testing.expectEqual(types.EventType.thinking_delta, event3.event_type);
    try std.testing.expectEqualStrings("first", event3.delta.?);

    const event4 = stream.next().?;
    defer freeEventOwned(allocator, event4);
    try std.testing.expectEqual(types.EventType.thinking_delta, event4.event_type);
    try std.testing.expectEqualStrings("\n\n", event4.delta.?);

    const event5 = stream.next().?;
    defer freeEventOwned(allocator, event5);
    try std.testing.expectEqual(types.EventType.thinking_delta, event5.event_type);
    try std.testing.expectEqualStrings("second", event5.delta.?);

    const event6 = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, event6.event_type);
    try std.testing.expectEqualStrings("first\n\nsecond", event6.content.?);

    const event7 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event7.event_type);
    try std.testing.expect(event7.message != null);
    try std.testing.expectEqualStrings("first\n\nsecond", event7.message.?.content[0].thinking.thinking);

    freeAssistantMessageOwned(allocator, event7.message.?);
}

test "parseSseStreamLines emits Azure reasoning_text deltas with final content fallback" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure_reasoning_text\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}\n" ++
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"azure \"}\n" ++
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"delta\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"azure final content\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_azure_reasoning_text\",\"status\":\"completed\"}}\n" ++
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

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream.next().?.event_type);

    const first_delta = stream.next().?;
    defer freeEventOwned(allocator, first_delta);
    try std.testing.expectEqual(types.EventType.thinking_delta, first_delta.event_type);
    try std.testing.expectEqualStrings("azure ", first_delta.delta.?);

    const second_delta = stream.next().?;
    defer freeEventOwned(allocator, second_delta);
    try std.testing.expectEqual(types.EventType.thinking_delta, second_delta.event_type);
    try std.testing.expectEqualStrings("delta", second_delta.delta.?);

    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqualStrings("azure final content", thinking_end.content.?);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("azure-openai-responses", done.message.?.api);
    try std.testing.expectEqualStrings("azure-openai-responses", done.message.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1", done.message.?.model);
    try std.testing.expectEqualStrings("azure final content", done.message.?.content[0].thinking.thinking);
    try std.testing.expect(stream.next() == null);

    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines preserves Azure content indexes across text tool text blocks" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure_content_index\"}}\n" ++
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
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_azure_content_index\",\"status\":\"completed\"}}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
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

test "finalizeCollectedOutput preserves Azure finalization semantics" {
    const allocator = std.testing.allocator;

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    try content_blocks.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, "hello azure") } });
    try finalize.appendInlineToolCall(allocator, &content_blocks, &tool_calls, .{
        .id = try allocator.dupe(u8, "call_1|item_1"),
        .name = try allocator.dupe(u8, "lookup"),
        .arguments = .null,
    });

    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .model = "gpt-4.1",
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
    try std.testing.expectEqualStrings("hello azure", output.content[0].text.text);
    try std.testing.expect(output.content[1] == .tool_call);
    try std.testing.expectEqual(types.StopReason.tool_use, output.stop_reason);
    try std.testing.expectEqual(@as(u32, 11), output.usage.total_tokens);
    try std.testing.expectEqual(output.content[1].tool_call.id.ptr, tool_calls.items[0].id.ptr);
}

test "stream forwards timeout_ms to HTTP streaming request" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_azure_timeout\",\"status\":\"completed\"}}\n";
    var server = try DelayedBodyServer.init(io, body, 250);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = url,
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

    var stream = try AzureOpenAIResponsesProvider.stream(allocator, io, model, context, .{
        .api_key = "test-key",
        .timeout_ms = 50,
    });
    defer stream.deinit();

    var saw_timeout = false;
    while (stream.next()) |event| {
        if (event.event_type == .error_event) {
            saw_timeout = true;
            try std.testing.expectEqualStrings("Timeout", event.error_message.?);
            break;
        }
    }
    try std.testing.expect(saw_timeout);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "http://127.0.0.1:1",
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

    var stream = try AzureOpenAIResponsesProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("azure-openai-responses", event.message.?.api);
    try std.testing.expectEqualStrings("azure-openai-responses", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1", event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(event.message.?.error_message.?.len > 0);
    try std.testing.expect(stream.next() == null);
}

test "stream preserves partial Azure Responses text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure_abort\"}}\n" ++
                "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
                "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial azure\"}\n",
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
        .id = "gpt-4.1",
        .name = "Azure GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
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

    var stream = try AzureOpenAIResponsesProvider.stream(allocator, io, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .signal = &abort_signal,
        .on_response = &AbortAfterResponse.callback,
    });
    defer stream.deinit();

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial azure", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial azure", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_azure_abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial azure", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes Azure Responses tool call on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure_eof_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_eof\",\"call_id\":\"call_eof\",\"name\":\"lookup\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_eof\",\"delta\":\"{\\\"query\\\":\\\"local\\\"}\"}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "Azure GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 32768,
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

test "ISS-310 parseSseStreamLines finalizes Azure partial text before sanitized response.failed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_azure_failed\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_failed\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial azure\"}\n" ++
            "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_azure_failed\",\"error\":{\"code\":\"server_error\",\"message\":\"failed with sk-azure-secret from /Users/alice/pi/azure_openai_responses.zig and request_id req_azure_random_123456\"}}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"must_not_emit\",\"status\":\"completed\"}}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "Azure GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = "https://example.openai.azure.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 32768,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial azure", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial azure", text_end.content.?);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings(terminal.error_message.?, terminal.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_azure_failed", terminal.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 1), terminal.message.?.content.len);
    try std.testing.expectEqualStrings("partial azure", terminal.message.?.content[0].text.text);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "sk-azure-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "/Users/alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "req_azure_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "[REDACTED]") != null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"azure denied\",\"api_key\":\"sk-azure-secret\",\"request_id\":\"req_azure_random_123456\"},\"trace\":\"/Users/alice/pi/azure_openai_responses.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 429, "Too Many Requests", "", body.items);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-4.1",
        .name = "GPT-4.1",
        .api = "azure-openai-responses",
        .provider = "azure-openai-responses",
        .base_url = url,
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

    var stream = try AzureOpenAIResponsesProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "azure denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-azure-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_azure_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("azure-openai-responses", result.api);
}
