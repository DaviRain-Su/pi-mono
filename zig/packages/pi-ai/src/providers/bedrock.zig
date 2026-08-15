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

const putStringField = provider_json_put.putStringValue;
const putStringValue = provider_json_put.putStringValue;
const putIntegerField = provider_json_put.putIntegerValue;
const putIntegerValue = provider_json_put.putIntegerValue;
const putBoolValue = provider_json_put.putBoolValue;
const putFloatValue = provider_json_put.putFloatValue;
const putObjectValue = provider_json_put.putObjectValue;
const sse_loop = @import("../shared/sse_loop.zig");
const stop_reason_mod = @import("../shared/stop_reason.zig");
const transform_messages = @import("../shared/transform_messages.zig");
const simple_options = @import("../shared/simple_options.zig");
const openai = @import("openai.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const SERVICE_NAME = "bedrock";
const SHA256_HEX_LEN = std.crypto.hash.sha2.Sha256.digest_length * 2;

const BedrockError = error{
    MissingAwsAccessKeyId,
    MissingAwsSecretAccessKey,
    InvalidBedrockChunk,
    InvalidBedrockEventStream,
    DuplicateBedrockMessageStart,
    MissingBedrockMessageStart,
    UnsupportedEventStreamHeaderType,
    UnexpectedBedrockMessageRole,
};

const AwsCredentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,

    fn deinit(self: AwsCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.access_key_id);
        allocator.free(self.secret_access_key);
        if (self.session_token) |value| allocator.free(value);
    }
};

const BedrockAuth = union(enum) {
    sigv4: AwsCredentials,
    bearer: []const u8,
    profile,

    fn deinit(self: BedrockAuth, allocator: std.mem.Allocator) void {
        switch (self) {
            .sigv4 => |credentials| credentials.deinit(allocator),
            .bearer => |token| allocator.free(token),
            .profile => {},
        }
    }
};

const ResolvedBedrockEndpoint = struct {
    base_url: []const u8,
    region: []const u8,

    fn deinit(self: ResolvedBedrockEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.region);
    }
};

pub const FixtureEnv = struct {
    aws_access_key_id: ?[]const u8 = null,
    aws_secret_access_key: ?[]const u8 = null,
    aws_session_token: ?[]const u8 = null,
    aws_profile: ?[]const u8 = null,
    aws_bearer_token_bedrock: ?[]const u8 = null,
    aws_region: ?[]const u8 = null,
    aws_default_region: ?[]const u8 = null,
    aws_bedrock_skip_auth: ?[]const u8 = null,
};

const RequestTimestamp = struct {
    amz_date: []const u8,
    date_stamp: []const u8,

    fn deinit(self: RequestTimestamp, allocator: std.mem.Allocator) void {
        allocator.free(self.amz_date);
        allocator.free(self.date_stamp);
    }
};

const CanonicalHeader = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: CanonicalHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        partial_json: std.ArrayList(u8),
    },
};

const BlockEntry = struct {
    bedrock_index: usize,
    event_index: usize,
    block: CurrentBlock,
};

const StreamParseState = struct {
    saw_message_start: bool = false,
    closed_indexes: [64]usize = [_]usize{0} ** 64,
    closed_count: usize = 0,
};

fn isClosedContentBlock(state: *const StreamParseState, bedrock_index: usize) bool {
    for (state.closed_indexes[0..state.closed_count]) |closed_index| {
        if (closed_index == bedrock_index) return true;
    }
    return false;
}

fn markClosedContentBlock(state: *StreamParseState, bedrock_index: usize) !void {
    if (isClosedContentBlock(state, bedrock_index)) return BedrockError.InvalidBedrockChunk;
    if (state.closed_count >= state.closed_indexes.len) return BedrockError.InvalidBedrockChunk;
    state.closed_indexes[state.closed_count] = bedrock_index;
    state.closed_count += 1;
}

pub const BedrockProvider = struct {
    pub const api = "bedrock-converse-stream";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        try provider_stream.runSetupOrEmit(streamProduction, .{ allocator, io, model, context, options, &stream_instance }, &stream_instance, model, options);
        return stream_instance;
    }

    fn streamProduction(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
        stream_instance: *event_stream.AssistantMessageEventStream,
    ) !void {
        if (isAbortRequested(options)) {
            var output = initOutput(model);
            var content_blocks = std.ArrayList(types.ContentBlock).empty;
            defer content_blocks.deinit(allocator);
            var tool_calls = std.ArrayList(types.ToolCall).empty;
            defer tool_calls.deinit(allocator);
            var active_blocks = std.ArrayList(BlockEntry).empty;
            defer active_blocks.deinit(allocator);
            try emitRuntimeFailure(allocator, stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, model, error.RequestAborted);
            return;
        }

        const auth = resolveBedrockAuth(allocator, options) catch |err| {
            try provider_error.pushTerminalStreamError(allocator, stream_instance, model, authErrorMessage(err));
            return;
        };
        defer auth.deinit(allocator);

        const timestamp = try currentTimestamp(allocator);
        defer timestamp.deinit(allocator);

        var payload = try buildRequestPayload(allocator, model, context, options);
        defer provider_json.freeValue(allocator, payload);

        if (options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                if (try callback(allocator, payload, model)) |replacement| {
                    provider_json.freeValue(allocator, payload);
                    payload = replacement;
                }
            }
        }

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        const request_path = try buildRequestPath(allocator, model.id);
        defer allocator.free(request_path);

        const endpoint = try resolveBedrockEndpoint(allocator, model.base_url, options);
        defer endpoint.deinit(allocator);

        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ endpoint.base_url, request_path });
        defer allocator.free(url);

        var headers = try buildBedrockRequestHeaders(allocator, model, options, auth, endpoint, request_path, json_body, timestamp);
        defer deinitHeaderMap(allocator, &headers);

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = client.requestStreaming(.{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .timeout_ms = if (options) |stream_options| stream_options.timeout_ms orelse 0 else 0,
            .aborted = if (options) |stream_options| stream_options.signal else null,
        }) catch |err| switch (err) {
            error.RequestAborted => {
                var output = initOutput(model);
                var content_blocks = std.ArrayList(types.ContentBlock).empty;
                defer content_blocks.deinit(allocator);
                var tool_calls = std.ArrayList(types.ToolCall).empty;
                defer tool_calls.deinit(allocator);
                var active_blocks = std.ArrayList(BlockEntry).empty;
                defer active_blocks.deinit(allocator);
                try emitRuntimeFailure(allocator, stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                return;
            },
            else => return err,
        };
        defer response.deinit();

        if (options) |stream_options| {
            if (stream_options.on_response) |callback| {
                if (response.response_headers) |response_headers| {
                    try callback(response.status, response_headers, model);
                } else {
                    var response_headers = std.StringHashMap([]const u8).init(allocator);
                    defer response_headers.deinit();
                    try callback(response.status, response_headers, model);
                }
            }
        }

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, stream_instance, model, response.status, response_body);
            return;
        }

        try parseStreamBody(allocator, stream_instance, &response, model, options);
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        const base = buildStreamSimpleBedrockOptions(model, options);
        return stream(allocator, io, model, context, base);
    }
};

fn buildStreamSimpleBedrockOptions(model: types.Model, options: ?types.StreamOptions) types.StreamOptions {
    const stream_options = options orelse types.StreamOptions{};
    var base = stream_options;
    if (base.max_tokens == null) base.max_tokens = defaultSimpleMaxTokens(model);

    var bedrock_opts = stream_options.providerOptions("bedrock");
    const reasoning = bedrock_opts.reasoning orelse return base;
    if (isAnthropicClaudeModel(model) and !supportsAdaptiveThinking(model.id, model.name)) {
        const adjusted = simple_options.adjustMaxTokensForThinking(
            base.max_tokens orelse 0,
            model.max_tokens,
            reasoning,
            bedrock_opts.thinking_budgets,
        );
        base.max_tokens = adjusted.max_tokens;
        var budgets = bedrock_opts.thinking_budgets orelse types.ThinkingBudgets{};
        switch (simple_options.clampReasoning(reasoning).?) {
            .minimal => budgets.minimal = adjusted.thinking_budget,
            .low => budgets.low = adjusted.thinking_budget,
            .medium => budgets.medium = adjusted.thinking_budget,
            .high, .xhigh => budgets.high = adjusted.thinking_budget,
        }
        bedrock_opts.thinking_budgets = budgets;
    }
    base.provider.bedrock = bedrock_opts;
    return base;
}

fn defaultSimpleMaxTokens(model: types.Model) ?u32 {
    if (model.max_tokens == 0) return null;
    return @min(model.max_tokens, @as(u32, 32000));
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return try buildRequestPayloadWithFixtureEnv(allocator, model, context, options, null);
}

// =============================================================================
// Outer-envelope payload struct for Bedrock Converse Stream.
//
// Inner blocks (messages, system, inferenceConfig, toolConfig,
// requestMetadata, additionalModelRequestFields) stay as Value passthroughs
// because they involve Bedrock-specific block taxonomy (text/image/
// reasoningContent/toolUse/toolResult, cachePoint markers, image base64
// transcoding, additional model fields like Claude thinking config) that
// would require a substantial separate refactor to model declaratively.
// =============================================================================

const BedrockRequestPayload = struct {
    messages: std.json.Value,
    system: ?std.json.Value = null,
    inferenceConfig: std.json.Value,
    toolConfig: ?std.json.Value = null,
    requestMetadata: ?std.json.Value = null,
    additionalModelRequestFields: ?std.json.Value = null,
};

const BedrockOwned = struct {
    allocator: std.mem.Allocator,
    payload: BedrockRequestPayload,
    owned_values: []std.json.Value,

    fn deinit(self: BedrockOwned) void {
        for (self.owned_values) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_values);
    }
};

fn buildOwnedBedrock(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    fixture_env: ?FixtureEnv,
) !BedrockOwned {
    var owned_values_list = std.ArrayList(std.json.Value).empty;
    errdefer {
        for (owned_values_list.items) |v| provider_json.freeValue(allocator, v);
        owned_values_list.deinit(allocator);
    }

    const cache_retention = resolveOptionsCacheRetention(options, processCacheRetentionEnv());

    const messages_value = try buildMessagesValue(allocator, model, context.messages, cache_retention);
    try owned_values_list.append(allocator, messages_value);

    var system_owned: ?std.json.Value = null;
    if (context.system_prompt) |system_prompt| {
        const v = try buildSystemValue(allocator, system_prompt, model, cache_retention);
        try owned_values_list.append(allocator, v);
        system_owned = v;
    }

    const inference_config = try buildInferenceConfigValue(allocator, model, options);
    try owned_values_list.append(allocator, inference_config);

    var tool_config_owned: ?std.json.Value = null;
    if (context.tools) |tools| {
        if (tools.len > 0) {
            if (try buildToolConfigValue(allocator, tools, options)) |tc| {
                try owned_values_list.append(allocator, tc);
                tool_config_owned = tc;
            }
        }
    }

    var request_metadata_owned: ?std.json.Value = null;
    var additional_fields_owned: ?std.json.Value = null;
    if (options) |stream_options| {
        const bedrock_opts = stream_options.providerOptions("bedrock");
        if (try buildRequestMetadataValue(allocator, bedrock_opts.request_metadata)) |rm| {
            try owned_values_list.append(allocator, rm);
            request_metadata_owned = rm;
        }
        if (try buildAdditionalModelRequestFieldsValue(allocator, model, stream_options, fixture_env)) |af| {
            try owned_values_list.append(allocator, af);
            additional_fields_owned = af;
        }
    }

    const owned_values_slice = try owned_values_list.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .payload = .{
            .messages = messages_value,
            .system = system_owned,
            .inferenceConfig = inference_config,
            .toolConfig = tool_config_owned,
            .requestMetadata = request_metadata_owned,
            .additionalModelRequestFields = additional_fields_owned,
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
    var owned = try buildOwnedBedrock(allocator, model, context, options, null);
    defer owned.deinit();
    return try std.json.Stringify.valueAlloc(allocator, owned.payload, .{
        .emit_null_optional_fields = false,
    });
}

fn buildRequestPayloadWithFixtureEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    fixture_env: ?FixtureEnv,
) !std.json.Value {
    var owned = try buildOwnedBedrock(allocator, model, context, options, fixture_env);
    defer owned.deinit();
    const bytes = try std.json.Stringify.valueAlloc(allocator, owned.payload, .{
        .emit_null_optional_fields = false,
    });
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
    mode: []const u8,
) !std.json.Value {
    return try buildRequestSnapshotValueWithFixtureEnv(allocator, model, context, options, mode, null);
}

pub fn buildRequestSnapshotValueWithFixtureEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    mode: []const u8,
    fixture_env: ?FixtureEnv,
) !std.json.Value {
    var request = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = request });
    try putStringValue(allocator, &request, "mode", mode);

    var snapshot_options = options;
    var simple_snapshot_options: types.StreamOptions = undefined;
    if (std.mem.eql(u8, mode, "streamSimpleBedrock") or std.mem.eql(u8, mode, "streamSimple")) {
        simple_snapshot_options = buildStreamSimpleBedrockOptions(model, options);
        snapshot_options = simple_snapshot_options;
    }

    var payload = try buildRequestPayloadWithFixtureEnv(allocator, model, context, snapshot_options, fixture_env);
    errdefer provider_json.freeValue(allocator, payload);
    try putStringValue(allocator, &payload.object, "modelId", model.id);
    if (snapshot_options) |stream_options| {
        if (stream_options.on_payload) |callback| {
            if (try callback(allocator, payload, model)) |replacement| {
                provider_json.freeValue(allocator, payload);
                payload = replacement;
            }
        }
    }
    try putObjectValue(allocator, &request, "payload", payload);
    return .{ .object = request };
}

pub fn buildRequestSurfaceSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    payload: std.json.Value,
    fixture_env: FixtureEnv,
) !std.json.Value {
    var scoped_env = try ScopedFixtureEnv.init(allocator, fixture_env);
    defer scoped_env.deinit();

    const request_path = try buildRequestPath(allocator, model.id);
    defer allocator.free(request_path);
    const endpoint = try resolveBedrockEndpoint(allocator, model.base_url, options);
    defer endpoint.deinit(allocator);
    const region = requestSurfaceRegionSnapshot(model.base_url, options, fixture_env, endpoint);
    const use_http_boundary = useProductionHttpRequestBoundary(options, fixture_env);

    const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json_body);

    const auth = resolveBedrockAuth(allocator, options) catch |err| blk: {
        if (err == error.MissingAwsAccessKeyId or err == error.MissingAwsSecretAccessKey) {
            break :blk null;
        }
        return err;
    };
    defer if (auth) |resolved| resolved.deinit(allocator);

    const fixed_timestamp = RequestTimestamp{ .amz_date = "20250115T120000Z", .date_stamp = "20250115" };
    var headers = if (use_http_boundary and auth != null)
        try buildBedrockRequestHeaders(allocator, model, options, auth.?, endpoint, request_path, json_body, fixed_timestamp)
    else
        std.StringHashMap([]const u8).init(allocator);
    defer deinitHeaderMap(allocator, &headers);

    var root = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = root });
    try putStringValue(allocator, &root, "boundary", if (use_http_boundary) "aws-sdk-finalized-http-request" else "aws-sdk-client-config-boundary");
    try putStringValue(allocator, &root, "method", "POST");
    try putStringValue(allocator, &root, "path", request_path);
    const surface_endpoint = requestSurfaceEndpointSnapshot(model.base_url, options, fixture_env, endpoint, use_http_boundary);
    if (surface_endpoint.value) |base_url| {
        // url uses allocPrint which returns an owned string we must transfer via put_string-like.
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, request_path });
        errdefer allocator.free(url);
        try root.put(allocator, try allocator.dupe(u8, "url"), .{ .string = url });
    } else {
        try putStringValue(allocator, &root, "url", "sdk-profile-resolution");
    }

    const endpoint_value: std.json.Value = blk: {
        var endpoint_object = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = endpoint_object });
        try putStringValue(allocator, &endpoint_object, "mode", surface_endpoint.mode);
        if (surface_endpoint.value) |value| try putStringValue(allocator, &endpoint_object, "value", value);
        break :blk .{ .object = endpoint_object };
    };
    try putObjectValue(allocator, &root, "endpoint", endpoint_value);

    const region_value: std.json.Value = blk: {
        var region_object = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = region_object });
        try putStringValue(allocator, &region_object, "source", region.source);
        if (region.value) |value| try putStringValue(allocator, &region_object, "value", value);
        break :blk .{ .object = region_object };
    };
    try putObjectValue(allocator, &root, "region", region_value);

    const client_config_value: std.json.Value = blk: {
        var client_config = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = client_config });
        if (options) |stream_options| {
            const bedrock_opts = stream_options.providerOptions("bedrock");
            if (bedrock_opts.profile) |profile| try putStringValue(allocator, &client_config, "profile", profile);
        }
        if (fixture_env.aws_profile) |profile| try putStringValue(allocator, &client_config, "envProfile", profile);
        if (!use_http_boundary and std.mem.eql(u8, surface_endpoint.mode, "explicit")) {
            if (surface_endpoint.value) |value| try putStringValue(allocator, &client_config, "endpoint", value);
        }
        if (region.value) |value| try putStringValue(allocator, &client_config, "region", value);
        break :blk .{ .object = client_config };
    };
    try putObjectValue(allocator, &root, "clientConfig", client_config_value);

    const auth_snapshot = try buildProductionAuthSnapshot(allocator, auth, options, fixture_env, region, &headers);
    try putObjectValue(allocator, &root, "auth", auth_snapshot);
    try putStringValue(allocator, &root, "redaction", "secrets-redacted");
    return .{ .object = root };
}

pub fn buildStreamSnapshotValueFromLocalEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    events: []const std.json.Value,
) !std.json.Value {
    return buildStreamSnapshotValueFromLocalEventsWithTerminalFailure(allocator, io, model, events, null);
}

pub const FixtureTerminalFailureTiming = enum {
    before_events,
    after_events,
};

pub const FixtureTerminalFailure = struct {
    timing: FixtureTerminalFailureTiming,
    stop_reason: types.StopReason,
    message: []const u8,
};

pub fn buildStreamSnapshotValueFromLocalEventsWithTerminalFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    events: []const std.json.Value,
    terminal_failure: ?FixtureTerminalFailure,
) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    var stream_instance = event_stream.createAssistantMessageEventStream(parse_allocator, io);
    defer stream_instance.deinit();

    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(parse_allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(parse_allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(parse_allocator, &entry.block);
        active_blocks.deinit(parse_allocator);
    }
    var state = StreamParseState{};

    if (terminal_failure) |failure| {
        if (failure.timing == .before_events) {
            try emitStreamFailureMessage(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, failure.stop_reason, failure.message);
            return try snapshotStreamEvents(allocator, parse_allocator, &stream_instance);
        }
    }

    for (events) |event_value| {
        var failed = false;
        handleEventValue(parse_allocator, &stream_instance, event_value, &output, &content_blocks, &tool_calls, &active_blocks, &state, model) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                failed = true;
            },
        };
        if (failed) break;
        if (stream_instance.result() != null) break;
    }
    if (stream_instance.result() == null) {
        if (terminal_failure) |failure| {
            if (failure.timing == .after_events) {
                try emitStreamFailureMessage(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, failure.stop_reason, failure.message);
            } else {
                try finalizeOutputSafely(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
            }
        } else {
            try finalizeOutputSafely(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
        }
    }

    return try snapshotStreamEvents(allocator, parse_allocator, &stream_instance);
}

pub fn buildStreamSnapshotValueFromBinaryBody(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    body: []const u8,
) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    var stream_instance = event_stream.createAssistantMessageEventStream(parse_allocator, io);
    defer stream_instance.deinit();
    try parseEventStreamFrames(parse_allocator, &stream_instance, body, model, null);
    return try snapshotStreamEvents(allocator, parse_allocator, &stream_instance);
}

fn buildSystemValue(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    model: types.Model,
    cache_retention: types.CacheRetention,
) !std.json.Value {
    var blocks = std.json.Array.init(allocator);
    errdefer blocks.deinit();
    try blocks.append(try buildTextBlockObject(allocator, system_prompt));
    if (cache_retention != .none and supportsPromptCaching(model)) {
        try blocks.append(try buildCachePointBlockObject(allocator, cache_retention));
    }
    return .{ .array = blocks };
}

fn buildInferenceConfigValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.json.Value {
    _ = model;
    var config = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = config });

    if (options) |stream_options| {
        if (stream_options.max_tokens) |max_tokens| {
            try putIntegerValue(allocator, &config, "maxTokens", max_tokens);
        }
        if (stream_options.temperature) |temperature| {
            try putFloatValue(allocator, &config, "temperature", temperature);
        }
    }

    return .{ .object = config };
}

fn buildRequestMetadataValue(allocator: std.mem.Allocator, metadata: ?std.json.Value) !?std.json.Value {
    if (metadata) |value| {
        if (value != .object) return null;
        var object = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = object });

        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            try putStringValue(allocator, &object, entry.key_ptr.*, entry.value_ptr.*.string);
        }
        return .{ .object = object };
    }
    return null;
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
        else => cache_retention,
    };
}

fn resolveOptionsCacheRetention(options: ?types.StreamOptions, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return resolveCacheRetention(if (options) |stream_options| stream_options.cache_retention else .unset, pi_cache_retention_env);
}

fn buildCachePointBlockObject(allocator: std.mem.Allocator, cache_retention: types.CacheRetention) !std.json.Value {
    const cache_point_value: std.json.Value = blk: {
        var cache_point = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = cache_point });
        try putStringValue(allocator, &cache_point, "type", "default");
        if (cache_retention == .long) {
            try putStringValue(allocator, &cache_point, "ttl", "1h");
        }
        break :blk .{ .object = cache_point };
    };

    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putObjectValue(allocator, &object, "cachePoint", cache_point_value);
    return .{ .object = object };
}

fn buildImageBlockObject(allocator: std.mem.Allocator, image: types.ImageContent) !std.json.Value {
    const format = try bedrockImageFormat(image.mime_type);

    const image_object_value: std.json.Value = blk: {
        var image_object = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = image_object });
        const source_value: std.json.Value = inner: {
            var source = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = source });
            try putStringValue(allocator, &source, "bytes", image.data);
            break :inner .{ .object = source };
        };
        try putObjectValue(allocator, &image_object, "source", source_value);
        try putStringValue(allocator, &image_object, "format", format);
        break :blk .{ .object = image_object };
    };

    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putObjectValue(allocator, &object, "image", image_object_value);
    return .{ .object = object };
}

fn bedrockImageFormat(mime_type: []const u8) ![]const u8 {
    if (std.mem.eql(u8, mime_type, "image/jpeg") or std.mem.eql(u8, mime_type, "image/jpg")) return "jpeg";
    if (std.mem.eql(u8, mime_type, "image/png")) return "png";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "webp";
    return error.UnknownBedrockImageType;
}

fn normalizeBedrockToolCallIdForTransform(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    _ = model;
    _ = source;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    for (id) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-') {
            try output.append(allocator, char);
        } else {
            try output.append(allocator, '_');
        }
        if (output.items.len == 64) break;
    }
    return try output.toOwnedSlice(allocator);
}

fn modelMatchCandidateContains(model: types.Model, needle: []const u8) bool {
    return textMatchCandidateContains(model.id, needle) or textMatchCandidateContains(model.name, needle);
}

fn textMatchCandidateContains(value: []const u8, needle: []const u8) bool {
    var buffer: [512]u8 = undefined;
    const lower = std.ascii.lowerString(buffer[0..@min(value.len, buffer.len)], value[0..@min(value.len, buffer.len)]);
    if (std.mem.indexOf(u8, lower, needle) != null) return true;
    var normalized: [512]u8 = undefined;
    for (lower, 0..) |char, index| {
        normalized[index] = switch (char) {
            ' ', '_', '.', ':' => '-',
            else => char,
        };
    }
    return std.mem.indexOf(u8, normalized[0..lower.len], needle) != null;
}

fn isAnthropicClaudeModel(model: types.Model) bool {
    return modelMatchCandidateContains(model, "anthropic.claude") or
        modelMatchCandidateContains(model, "anthropic/claude") or
        modelMatchCandidateContains(model, "claude");
}

fn supportsAdaptiveThinking(model_id: []const u8, model_name: []const u8) bool {
    const model = types.Model{
        .id = model_id,
        .name = model_name,
        .api = "",
        .provider = "",
        .base_url = "",
        .input_types = &[_][]const u8{},
        .context_window = 0,
        .max_tokens = 0,
    };
    return modelMatchCandidateContains(model, "opus-4-6") or
        modelMatchCandidateContains(model, "opus-4-7") or
        modelMatchCandidateContains(model, "sonnet-4-6");
}

fn supportsPromptCaching(model: types.Model) bool {
    if (!modelMatchCandidateContains(model, "claude")) {
        const forced = std.c.getenv("AWS_BEDROCK_FORCE_CACHE") orelse return false;
        return std.mem.eql(u8, std.mem.span(forced), "1");
    }
    return modelMatchCandidateContains(model, "-4-") or
        modelMatchCandidateContains(model, "claude-3-7-sonnet") or
        modelMatchCandidateContains(model, "claude-3-5-haiku");
}

fn isGovCloudBedrockTarget(model: types.Model, options: types.StreamOptions, fixture_env: ?FixtureEnv) bool {
    if (configuredBedrockRegion(options, fixture_env)) |region| {
        if (asciiStartsWithIgnoreCase(region, "us-gov-")) return true;
    }
    return asciiStartsWithIgnoreCase(model.id, "us-gov.") or asciiStartsWithIgnoreCase(model.id, "arn:aws-us-gov:");
}

fn configuredBedrockRegion(options: types.StreamOptions, fixture_env: ?FixtureEnv) ?[]const u8 {
    const bedrock_opts = options.providerOptions("bedrock");
    if (bedrock_opts.region) |region| return region;
    if (fixture_env) |env| {
        if (nonEmpty(env.aws_region)) |region| return region;
        if (nonEmpty(env.aws_default_region)) |region| return region;
        return null;
    }
    if (std.c.getenv("AWS_REGION")) |region| {
        const value = std.mem.span(region);
        if (value.len > 0) return value;
    }
    if (std.c.getenv("AWS_DEFAULT_REGION")) |region| {
        const value = std.mem.span(region);
        if (value.len > 0) return value;
    }
    return null;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn mapThinkingLevelToEffort(level: types.ThinkingLevel, model: types.Model) []const u8 {
    return switch (level) {
        .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => if (modelMatchCandidateContains(model, "opus-4-7")) "xhigh" else "high",
    };
}

fn buildAdditionalModelRequestFieldsValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: types.StreamOptions,
    fixture_env: ?FixtureEnv,
) !?std.json.Value {
    const bedrock_opts = options.providerOptions("bedrock");
    const reasoning = bedrock_opts.reasoning orelse return null;
    if (!model.reasoning or !isAnthropicClaudeModel(model)) return null;

    const display = if (isGovCloudBedrockTarget(model, options, fixture_env)) null else bedrock_opts.thinking_display orelse .summarized;
    var result = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = result });

    if (supportsAdaptiveThinking(model.id, model.name)) {
        const thinking_value: std.json.Value = blk: {
            var thinking = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = thinking });
            try putStringValue(allocator, &thinking, "type", "adaptive");
            if (display) |display_value| {
                try putStringValue(allocator, &thinking, "display", @tagName(display_value));
            }
            break :blk .{ .object = thinking };
        };
        try putObjectValue(allocator, &result, "thinking", thinking_value);

        const output_config_value: std.json.Value = blk: {
            var output_config = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = output_config });
            try putStringValue(allocator, &output_config, "effort", mapThinkingLevelToEffort(reasoning, model));
            break :blk .{ .object = output_config };
        };
        try putObjectValue(allocator, &result, "output_config", output_config_value);
    } else {
        const budgets = bedrock_opts.thinking_budgets orelse types.ThinkingBudgets{};
        const budget = switch (reasoning) {
            .minimal => budgets.minimal,
            .low => budgets.low,
            .medium => budgets.medium,
            .high, .xhigh => budgets.high,
        };
        const thinking_value: std.json.Value = blk: {
            var thinking = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = thinking });
            try putStringValue(allocator, &thinking, "type", "enabled");
            try putIntegerValue(allocator, &thinking, "budget_tokens", budget);
            if (display) |display_value| {
                try putStringValue(allocator, &thinking, "display", @tagName(display_value));
            }
            break :blk .{ .object = thinking };
        };
        try putObjectValue(allocator, &result, "thinking", thinking_value);
        if (bedrock_opts.interleaved_thinking orelse true) {
            var beta = std.json.Array.init(allocator);
            errdefer provider_json.freeValue(allocator, .{ .array = beta });
            try beta.append(.{ .string = try allocator.dupe(u8, "interleaved-thinking-2025-05-14") });
            try putObjectValue(allocator, &result, "anthropic_beta", .{ .array = beta });
        }
    }

    return .{ .object = result };
}

fn buildMessagesValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
    cache_retention: types.CacheRetention,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    const transformed_messages = try transform_messages.transformMessages(allocator, messages, model, normalizeBedrockToolCallIdForTransform);
    defer transform_messages.freeMessages(allocator, transformed_messages);

    var index: usize = 0;
    while (index < transformed_messages.len) : (index += 1) {
        switch (transformed_messages[index]) {
            .user => |user| try array.append(try buildUserMessageValue(allocator, model, user)),
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    if (try buildAssistantMessageValue(allocator, model, assistant)) |message_value| {
                        try array.append(message_value);
                    }
                }
            },
            .tool_result => {
                const grouped = try buildToolResultMessageValue(allocator, model, transformed_messages[index..]);
                try array.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }

    if (cache_retention != .none and supportsPromptCaching(model) and array.items.len > 0) {
        const last_message = &array.items[array.items.len - 1];
        if (last_message.* == .object) {
            const role = last_message.object.get("role");
            const content = last_message.object.getPtr("content");
            if (role != null and role.? == .string and std.mem.eql(u8, role.?.string, "user") and content != null and content.?.* == .array) {
                try content.?.array.append(try buildCachePointBlockObject(allocator, cache_retention));
            }
        }
    }

    return .{ .array = array };
}

fn buildUserMessageValue(allocator: std.mem.Allocator, model: types.Model, user: types.UserMessage) !std.json.Value {
    _ = model;
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text));
            },
            .image => |image| try content.append(try buildImageBlockObject(allocator, image)),
            .thinking, .tool_call => {},
        }
    }

    if (content.items.len == 0) try content.append(try buildTextBlockObject(allocator, ""));
    return try buildRoleMessageObject(allocator, "user", .{ .array = content });
}

fn buildAssistantMessageValue(allocator: std.mem.Allocator, model: types.Model, assistant: types.AssistantMessage) !?std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text));
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                if (isAnthropicClaudeModel(model)) {
                    if (types.thinkingSignature(thinking)) |signature| {
                        try content.append(try buildReasoningContentBlock(allocator, thinking.thinking, signature));
                    } else {
                        try content.append(try buildTextBlockObject(allocator, thinking.thinking));
                    }
                } else {
                    try content.append(try buildReasoningContentBlock(allocator, thinking.thinking, null));
                }
            },
            .image => |image| try content.append(try buildImageBlockObject(allocator, image)),
            .tool_call => |tool_call| {
                try content.append(try buildToolUseBlock(allocator, tool_call));
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
        if (assistant.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                try content.append(try buildToolUseBlock(allocator, tool_call));
            }
        }
    }

    if (content.items.len == 0) return null;
    return try buildRoleMessageObject(allocator, "assistant", .{ .array = content });
}

fn buildToolResultMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
    _ = model;
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                var tool_result_blocks = std.json.Array.init(allocator);
                errdefer tool_result_blocks.deinit();
                for (tool_result.content) |block| {
                    switch (block) {
                        .text => |text| try tool_result_blocks.append(try buildTextBlockObject(allocator, text.text)),
                        .image => |image| try tool_result_blocks.append(try buildImageBlockObject(allocator, image)),
                        .thinking => |thinking| try tool_result_blocks.append(try buildTextBlockObject(allocator, thinking.thinking)),
                        .tool_call => {},
                    }
                }
                if (tool_result_blocks.items.len == 0) {
                    try tool_result_blocks.append(try buildTextBlockObject(allocator, ""));
                }

                const tool_result_value: std.json.Value = blk: {
                    var tool_result_obj = try provider_json.initObject(allocator);
                    errdefer provider_json.freeValue(allocator, .{ .object = tool_result_obj });
                    try putStringValue(allocator, &tool_result_obj, "toolUseId", tool_result.tool_call_id);
                    try putObjectValue(allocator, &tool_result_obj, "content", .{ .array = tool_result_blocks });
                    try putStringValue(allocator, &tool_result_obj, "status", if (tool_result.is_error) "error" else "success");
                    break :blk .{ .object = tool_result_obj };
                };

                var wrapper = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = wrapper });
                try putObjectValue(allocator, &wrapper, "toolResult", tool_result_value);
                try content.append(.{ .object = wrapper });
            },
            else => break,
        }
    }

    return .{
        .value = try buildRoleMessageObject(allocator, "user", .{ .array = content }),
        .consumed = consumed,
    };
}

fn buildToolConfigValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    options: ?types.StreamOptions,
) !?std.json.Value {
    if (options) |stream_options| {
        const bedrock_opts = stream_options.providerOptions("bedrock");
        if (bedrock_opts.tool_choice) |tool_choice| {
            if (tool_choice == .none) return null;
        }
    }

    var tool_entries = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = tool_entries });
    for (tools) |tool| {
        const tool_object_value: std.json.Value = blk: {
            var tool_spec = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = tool_spec });
            try putStringValue(allocator, &tool_spec, "name", tool.name);
            try putStringValue(allocator, &tool_spec, "description", tool.description);

            const input_schema_value: std.json.Value = inner: {
                var input_schema = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = input_schema });
                try putObjectValue(allocator, &input_schema, "json", try provider_json.cloneValue(allocator, tool.parameters));
                break :inner .{ .object = input_schema };
            };
            try putObjectValue(allocator, &tool_spec, "inputSchema", input_schema_value);

            var tool_object = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = tool_object });
            try putObjectValue(allocator, &tool_object, "toolSpec", .{ .object = tool_spec });
            break :blk .{ .object = tool_object };
        };
        try tool_entries.append(tool_object_value);
    }

    var config = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = config });
    try putObjectValue(allocator, &config, "tools", .{ .array = tool_entries });

    if (options) |stream_options| {
        const bedrock_opts = stream_options.providerOptions("bedrock");
        if (bedrock_opts.tool_choice) |tool_choice| {
            if (try buildToolChoiceValue(allocator, tool_choice)) |choice_value| {
                try putObjectValue(allocator, &config, "toolChoice", choice_value);
            }
        }
    }

    return .{ .object = config };
}

fn buildToolChoiceValue(allocator: std.mem.Allocator, tool_choice: types.BedrockToolChoice) !?std.json.Value {
    switch (tool_choice) {
        .none => return null,
        .auto => return try buildWrappedEmptyObject(allocator, "auto"),
        .any => return try buildWrappedEmptyObject(allocator, "any"),
        .tool => |name| {
            const tool_value: std.json.Value = blk: {
                var tool = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = tool });
                try putStringValue(allocator, &tool, "name", name);
                break :blk .{ .object = tool };
            };
            var object = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = object });
            try putObjectValue(allocator, &object, "tool", tool_value);
            return .{ .object = object };
        },
    }
}

fn buildWrappedEmptyObject(allocator: std.mem.Allocator, key: []const u8) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putObjectValue(allocator, &object, key, try provider_json.emptyObjectValue(allocator));
    return .{ .object = object };
}

fn buildTextBlockObject(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    const sanitized = try openai.sanitizeSurrogates(allocator, text);
    defer allocator.free(sanitized);
    try putStringValue(allocator, &object, "text", sanitized);
    return .{ .object = object };
}

fn buildRoleMessageObject(allocator: std.mem.Allocator, role: []const u8, content: std.json.Value) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "role", role);
    try putObjectValue(allocator, &object, "content", content);
    return .{ .object = object };
}

fn buildReasoningContentBlock(allocator: std.mem.Allocator, thinking_text: []const u8, signature: ?[]const u8) !std.json.Value {
    const reasoning_text_value: std.json.Value = blk: {
        var reasoning_text = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = reasoning_text });
        const sanitized = try openai.sanitizeSurrogates(allocator, thinking_text);
        defer allocator.free(sanitized);
        try putStringValue(allocator, &reasoning_text, "text", sanitized);
        if (signature) |sig| {
            try putStringValue(allocator, &reasoning_text, "signature", sig);
        }
        break :blk .{ .object = reasoning_text };
    };

    const reasoning_content_value: std.json.Value = blk: {
        var reasoning_content = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = reasoning_content });
        try putObjectValue(allocator, &reasoning_content, "reasoningText", reasoning_text_value);
        break :blk .{ .object = reasoning_content };
    };

    var block_object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = block_object });
    try putObjectValue(allocator, &block_object, "reasoningContent", reasoning_content_value);
    return .{ .object = block_object };
}

fn buildToolUseBlock(allocator: std.mem.Allocator, tool_call: types.ToolCall) !std.json.Value {
    const tool_use_value: std.json.Value = blk: {
        var tool_use = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = tool_use });
        try putStringValue(allocator, &tool_use, "toolUseId", tool_call.id);
        try putStringValue(allocator, &tool_use, "name", tool_call.name);
        try putObjectValue(allocator, &tool_use, "input", try provider_json.cloneValue(allocator, tool_call.arguments));
        break :blk .{ .object = tool_use };
    };
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putObjectValue(allocator, &object, "toolUse", tool_use_value);
    return .{ .object = object };
}

fn resolveAwsCredentials(allocator: std.mem.Allocator) !AwsCredentials {
    const access_key_id = try loadEnvRequired(allocator, "AWS_ACCESS_KEY_ID", BedrockError.MissingAwsAccessKeyId);
    errdefer allocator.free(access_key_id);
    const secret_access_key = try loadEnvRequired(allocator, "AWS_SECRET_ACCESS_KEY", BedrockError.MissingAwsSecretAccessKey);
    errdefer allocator.free(secret_access_key);
    const session_token = try loadEnvOptional(allocator, "AWS_SESSION_TOKEN");

    return .{
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = session_token,
    };
}

fn resolveBedrockAuth(allocator: std.mem.Allocator, options: ?types.StreamOptions) !BedrockAuth {
    const skip_auth = if (try loadEnvOptional(allocator, "AWS_BEDROCK_SKIP_AUTH")) |value| blk: {
        defer allocator.free(value);
        break :blk std.mem.eql(u8, value, "1");
    } else false;

    if (skip_auth) {
        return .{ .sigv4 = .{
            .access_key_id = try allocator.dupe(u8, "dummy-access-key"),
            .secret_access_key = try allocator.dupe(u8, "dummy-secret-key"),
        } };
    }

    if (options) |stream_options| {
        const bedrock_opts = stream_options.providerOptions("bedrock");
        if (bedrock_opts.bearer_token) |token| {
            if (std.mem.trim(u8, token, " \t\r\n").len > 0) {
                return .{ .bearer = try allocator.dupe(u8, token) };
            }
        }
        if (bedrock_opts.profile) |profile| {
            if (std.mem.trim(u8, profile, " \t\r\n").len > 0) return .profile;
        }
    }

    if (try loadEnvOptional(allocator, "AWS_BEARER_TOKEN_BEDROCK")) |token| {
        return .{ .bearer = token };
    }

    if (try loadEnvOptional(allocator, "AWS_PROFILE")) |profile| {
        allocator.free(profile);
        return .profile;
    }

    return .{ .sigv4 = try resolveAwsCredentials(allocator) };
}

fn loadEnvRequired(allocator: std.mem.Allocator, name: []const u8, comptime err: anytype) ![]u8 {
    return try loadEnvOptional(allocator, name) orelse err;
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    const value_slice = std.mem.span(value);
    if (value_slice.len == 0) return null;
    return try allocator.dupe(u8, value_slice);
}

fn currentTimestamp(allocator: std.mem.Allocator) !RequestTimestamp {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(tv.sec) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .amz_date = try std.fmt.allocPrint(
            allocator,
            "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
            .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() },
        ),
        .date_stamp = try std.fmt.allocPrint(
            allocator,
            "{d:0>4}{d:0>2}{d:0>2}",
            .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 },
        ),
    };
}

fn buildRequestPath(allocator: std.mem.Allocator, model_id: []const u8) ![]const u8 {
    const encoded_model_id = try percentEncodePathSegment(allocator, model_id);
    defer allocator.free(encoded_model_id);
    return try std.fmt.allocPrint(allocator, "/model/{s}/converse-stream", .{encoded_model_id});
}

fn percentEncodePathSegment(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    for (value) |char| {
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

fn resolveBedrockRegion(allocator: std.mem.Allocator, base_url: []const u8, options: ?types.StreamOptions) ![]u8 {
    if (options) |stream_options| {
        if (stream_options.providerOptions("bedrock").region) |region| return try allocator.dupe(u8, region);
    }
    if (try loadEnvOptional(allocator, "AWS_REGION")) |region| return region;
    if (try loadEnvOptional(allocator, "AWS_DEFAULT_REGION")) |region| return region;

    const host = try extractHostFromUrl(allocator, base_url);
    defer allocator.free(host);

    const lowered = try std.ascii.allocLowerString(allocator, host);
    defer allocator.free(lowered);

    const patterns = [_][]const u8{
        "bedrock-runtime.",
        "bedrock-runtime-fips.",
    };
    for (patterns) |pattern| {
        if (std.mem.startsWith(u8, lowered, pattern)) {
            const rest = lowered[pattern.len..];
            if (std.mem.indexOf(u8, rest, ".amazonaws.com")) |end| {
                return try allocator.dupe(u8, rest[0..end]);
            }
            if (std.mem.indexOf(u8, rest, ".amazonaws.com.cn")) |end| {
                return try allocator.dupe(u8, rest[0..end]);
            }
        }
    }

    return try allocator.dupe(u8, "us-east-1");
}

fn hasConfiguredBedrockRegion(allocator: std.mem.Allocator, options: ?types.StreamOptions) !bool {
    if (options) |stream_options| {
        if (nonEmpty(stream_options.providerOptions("bedrock").region) != null) return true;
    }
    if (try loadEnvOptional(allocator, "AWS_REGION")) |region| {
        allocator.free(region);
        return true;
    }
    if (try loadEnvOptional(allocator, "AWS_DEFAULT_REGION")) |region| {
        allocator.free(region);
        return true;
    }
    return false;
}

fn hasConfiguredAwsProfile(allocator: std.mem.Allocator) !bool {
    if (try loadEnvOptional(allocator, "AWS_PROFILE")) |profile| {
        allocator.free(profile);
        return true;
    }
    return false;
}

fn sdkDefaultBedrockEndpoint(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    const suffix = if (std.mem.startsWith(u8, region, "cn-")) "amazonaws.com.cn" else "amazonaws.com";
    return try std.fmt.allocPrint(allocator, "https://bedrock-runtime.{s}.{s}", .{ region, suffix });
}

fn resolveBedrockEndpoint(allocator: std.mem.Allocator, base_url: []const u8, options: ?types.StreamOptions) !ResolvedBedrockEndpoint {
    const region = try resolveBedrockRegion(allocator, base_url, options);
    errdefer allocator.free(region);

    const endpoint_region = standardEndpointRegion(base_url);
    const use_explicit_endpoint = endpoint_region == null or (!(try hasConfiguredBedrockRegion(allocator, options)) and !(try hasConfiguredAwsProfile(allocator)));
    const resolved_base_url = if (use_explicit_endpoint)
        try allocator.dupe(u8, trimTrailingSlash(base_url))
    else
        try sdkDefaultBedrockEndpoint(allocator, region);

    return .{
        .base_url = resolved_base_url,
        .region = region,
    };
}

fn extractHostFromUrl(allocator: std.mem.Allocator, url_text: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url_text);
    const host = uri.host orelse return error.InvalidUrl;
    return try allocator.dupe(u8, try host.toRawMaybeAlloc(allocator));
}

fn signRequestHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    endpoint_base_url: []const u8,
    request_path: []const u8,
    body: []const u8,
    credentials: AwsCredentials,
    timestamp: RequestTimestamp,
    region: []const u8,
) !void {
    const host = try extractHostFromUrl(allocator, endpoint_base_url);
    defer allocator.free(host);

    try putOwnedHeader(allocator, headers, "host", host);

    var body_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &body_hash, .{});
    const body_hash_hex = try bytesToHexAlloc(allocator, &body_hash);
    defer allocator.free(body_hash_hex);

    try putOwnedHeader(allocator, headers, "x-amz-content-sha256", body_hash_hex);
    try putOwnedHeader(allocator, headers, "x-amz-date", timestamp.amz_date);
    if (credentials.session_token) |session_token| {
        try putOwnedHeader(allocator, headers, "x-amz-security-token", session_token);
    }

    var canonical_headers = std.ArrayList(CanonicalHeader).empty;
    defer {
        for (canonical_headers.items) |entry| entry.deinit(allocator);
        canonical_headers.deinit(allocator);
    }

    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Authorization")) continue;
        try canonical_headers.append(allocator, .{
            .name = try std.ascii.allocLowerString(allocator, entry.key_ptr.*),
            .value = try normalizeHeaderValue(allocator, entry.value_ptr.*),
        });
    }
    std.mem.sort(CanonicalHeader, canonical_headers.items, {}, struct {
        fn lessThan(_: void, a: CanonicalHeader, b: CanonicalHeader) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var canonical_header_text = std.ArrayList(u8).empty;
    defer canonical_header_text.deinit(allocator);
    var signed_headers = std.ArrayList(u8).empty;
    defer signed_headers.deinit(allocator);

    for (canonical_headers.items, 0..) |entry, index| {
        try canonical_header_text.appendSlice(allocator, entry.name);
        try canonical_header_text.append(allocator, ':');
        try canonical_header_text.appendSlice(allocator, entry.value);
        try canonical_header_text.append(allocator, '\n');

        if (index > 0) try signed_headers.append(allocator, ';');
        try signed_headers.appendSlice(allocator, entry.name);
    }

    const canonical_request = try std.fmt.allocPrint(
        allocator,
        "POST\n{s}\n\n{s}\n{s}\n{s}",
        .{ request_path, canonical_header_text.items, signed_headers.items, body_hash_hex },
    );
    defer allocator.free(canonical_request);

    var canonical_request_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_request, &canonical_request_hash, .{});
    const canonical_request_hash_hex = try bytesToHexAlloc(allocator, &canonical_request_hash);
    defer allocator.free(canonical_request_hash_hex);

    const credential_scope = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/aws4_request", .{ timestamp.date_stamp, region, SERVICE_NAME });
    defer allocator.free(credential_scope);

    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
        .{ timestamp.amz_date, credential_scope, canonical_request_hash_hex },
    );
    defer allocator.free(string_to_sign);

    const signing_key = try deriveSigningKey(allocator, credentials.secret_access_key, timestamp.date_stamp, region, SERVICE_NAME);
    defer allocator.free(signing_key);

    var signature: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign, signing_key);
    const signature_hex = try bytesToHexAlloc(allocator, &signature);
    defer allocator.free(signature_hex);

    const authorization = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ credentials.access_key_id, credential_scope, signed_headers.items, signature_hex },
    );
    defer allocator.free(authorization);
    try putOwnedHeader(allocator, headers, "Authorization", authorization);
}

fn deriveSigningKey(
    allocator: std.mem.Allocator,
    secret_access_key: []const u8,
    date_stamp: []const u8,
    region: []const u8,
    service: []const u8,
) ![]u8 {
    const seed = try std.fmt.allocPrint(allocator, "AWS4{s}", .{secret_access_key});
    defer allocator.free(seed);

    var k_date: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date_stamp, seed);

    var k_region: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_region, region, &k_date);

    var k_service: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_service, service, &k_region);

    var signing_key: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signing_key, "aws4_request", &k_service);
    return try allocator.dupe(u8, &signing_key);
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        output[index * 2] = std.fmt.digitToChar(@intCast(byte >> 4), .lower);
        output[index * 2 + 1] = std.fmt.digitToChar(@intCast(byte & 0x0f), .lower);
    }
    return output;
}

fn normalizeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    var previous_was_space = false;
    for (trimmed) |char| {
        const is_space = char == ' ' or char == '\t' or char == '\r' or char == '\n';
        if (is_space) {
            if (!previous_was_space) {
                try list.append(allocator, ' ');
                previous_was_space = true;
            }
        } else {
            try list.append(allocator, char);
            previous_was_space = false;
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    if (headers.fetchRemove(name)) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
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

fn deinitHeaderMap(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn buildBedrockRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    auth: BedrockAuth,
    endpoint: ResolvedBedrockEndpoint,
    request_path: []const u8,
    json_body: []const u8,
    timestamp: RequestTimestamp,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitHeaderMap(allocator, &headers);

    try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
    try mergeHeaders(allocator, &headers, model.headers);
    if (options) |stream_options| {
        try mergeHeaders(allocator, &headers, stream_options.headers);
    }
    switch (auth) {
        .sigv4 => |credentials| try signRequestHeaders(allocator, &headers, endpoint.base_url, request_path, json_body, credentials, timestamp, endpoint.region),
        .bearer => |token| {
            const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            defer allocator.free(authorization);
            try putOwnedHeader(allocator, &headers, "Authorization", authorization);
        },
        .profile => {},
    }
    return headers;
}

fn parseStreamBody(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    if (looksLikeBinaryEventStream(streaming.body)) {
        try parseEventStreamFrames(allocator, stream_ptr, streaming.body, model, options);
        return;
    }
    try parseTextStreamLines(allocator, stream_ptr, streaming, model, options);
}

fn looksLikeBinaryEventStream(body: []const u8) bool {
    if (body.len == 0) return false;
    if (std.mem.indexOfScalar(u8, body, 0) != null) return true;

    for (body) |char| {
        switch (char) {
            ' ', '\t', '\r', '\n' => continue,
            '{', '[', 'd', 'e' => return false,
            else => return !std.ascii.isPrint(char),
        }
    }
    return false;
}

fn parseEventStreamFrames(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    body: []const u8,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }
    var state = StreamParseState{};

    var cursor: usize = 0;
    while (cursor < body.len) {
        if (isAbortRequested(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, error.RequestAborted);
            return;
        }

        if (body.len - cursor < 16) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, BedrockError.InvalidBedrockEventStream);
            return;
        }
        const total_length = readBigEndianU32(body[cursor..][0..4]);
        const headers_length = readBigEndianU32(body[cursor..][4..8]);
        if (total_length < 16 or cursor + total_length > body.len) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, BedrockError.InvalidBedrockEventStream);
            return;
        }
        const headers_start = cursor + 12;
        const headers_end = headers_start + headers_length;
        if (headers_end + 4 > cursor + total_length) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, BedrockError.InvalidBedrockEventStream);
            return;
        }
        const payload_end = cursor + total_length - 4;

        const parsed_headers = parseEventStreamHeaders(body[headers_start..headers_end]) catch |err| {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
            return;
        };
        const payload = body[headers_end..payload_end];
        cursor += total_length;

        if (payload.len == 0) continue;
        parseWrappedEventPayload(allocator, stream_ptr, payload, parsed_headers.event_type, parsed_headers.exception_type, &output, &content_blocks, &tool_calls, &active_blocks, &state, model) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                return;
            },
        };
        if (output.stop_reason == .error_reason and output.error_message != null and stream_ptr.result() != null) return;
    }

    try finalizeOutputSafely(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
}

const EventStreamHeaders = struct {
    event_type: ?[]const u8 = null,
    exception_type: ?[]const u8 = null,
};

fn parseEventStreamHeaders(headers_bytes: []const u8) !EventStreamHeaders {
    var result = EventStreamHeaders{};
    var cursor: usize = 0;
    while (cursor < headers_bytes.len) {
        if (cursor + 2 > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
        const name_len = headers_bytes[cursor];
        cursor += 1;
        if (cursor + name_len + 1 > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
        const name = headers_bytes[cursor .. cursor + name_len];
        cursor += name_len;
        const header_type = headers_bytes[cursor];
        cursor += 1;

        const value = switch (header_type) {
            7 => blk: {
                if (cursor + 2 > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
                const value_len = readBigEndianU16(headers_bytes[cursor..][0..2]);
                cursor += 2;
                if (cursor + value_len > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
                const string_value = headers_bytes[cursor .. cursor + value_len];
                cursor += value_len;
                break :blk string_value;
            },
            else => return BedrockError.UnsupportedEventStreamHeaderType,
        };

        if (std.mem.eql(u8, name, ":event-type")) result.event_type = value;
        if (std.mem.eql(u8, name, ":exception-type")) result.exception_type = value;
    }
    return result;
}

fn readBigEndianU32(bytes: []const u8) usize {
    return @as(usize, bytes[0]) << 24 |
        @as(usize, bytes[1]) << 16 |
        @as(usize, bytes[2]) << 8 |
        @as(usize, bytes[3]);
}

fn readBigEndianU16(bytes: []const u8) usize {
    return @as(usize, bytes[0]) << 8 |
        @as(usize, bytes[1]);
}

fn parseWrappedEventPayload(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    payload: []const u8,
    event_type: ?[]const u8,
    exception_type: ?[]const u8,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object or !containsKnownEventField(parsed.value)) {
        const wrapped = try wrapEventValue(allocator, parsed.value, event_type, exception_type);
        defer provider_json.freeValue(allocator, wrapped);
        try handleEventValue(allocator, stream_ptr, wrapped, output, content_blocks, tool_calls, active_blocks, state, model);
        return;
    }
    try handleEventValue(allocator, stream_ptr, parsed.value, output, content_blocks, tool_calls, active_blocks, state, model);
}

fn containsKnownEventField(value: std.json.Value) bool {
    if (value != .object) return false;
    const keys = [_][]const u8{
        "messageStart",
        "contentBlockStart",
        "contentBlockDelta",
        "contentBlockStop",
        "messageStop",
        "metadata",
        "internalServerException",
        "modelStreamErrorException",
        "validationException",
        "throttlingException",
        "serviceUnavailableException",
    };
    inline for (keys) |key| {
        if (value.object.get(key) != null) return true;
    }
    return false;
}

fn wrapEventValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    event_type: ?[]const u8,
    exception_type: ?[]const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    if (event_type) |name| {
        try object.put(allocator, try allocator.dupe(u8, name), try provider_json.cloneValue(allocator, value));
        return .{ .object = object };
    }
    if (exception_type) |name| {
        const field_name = try normalizeEventStreamExceptionName(allocator, name);
        defer allocator.free(field_name);
        try object.put(allocator, try allocator.dupe(u8, field_name), try provider_json.cloneValue(allocator, value));
        return .{ .object = object };
    }
    return BedrockError.InvalidBedrockChunk;
}

fn normalizeEventStreamExceptionName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const mappings = [_]struct { raw: []const u8, field: []const u8 }{
        .{ .raw = "InternalServerException", .field = "internalServerException" },
        .{ .raw = "ModelStreamErrorException", .field = "modelStreamErrorException" },
        .{ .raw = "ValidationException", .field = "validationException" },
        .{ .raw = "ThrottlingException", .field = "throttlingException" },
        .{ .raw = "ServiceUnavailableException", .field = "serviceUnavailableException" },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, name, mapping.raw) or std.mem.eql(u8, name, mapping.field)) {
            return allocator.dupe(u8, mapping.field);
        }
    }
    return allocator.dupe(u8, name);
}

fn initOutput(model: types.Model) types.AssistantMessage {
    return .{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn parseTextStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }
    var state = StreamParseState{};

    var handler = BedrockSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .active_blocks = &active_blocks,
        .state = &state,
        .model = model,
    };
    const loop_result = try sse_loop.run(BedrockSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped) return;

    try finalizeOutputSafely(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
}

const BedrockSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,

    pub fn extractDataLine(_: *BedrockSseLoopHandler, line: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, line, "data: ")) return line[6..];
        return line;
    }

    pub fn isDoneData(_: *BedrockSseLoopHandler, _: []const u8) bool {
        return false;
    }

    pub fn handleData(self: *BedrockSseLoopHandler, data: []const u8) !bool {
        if (data.len == 0) return true;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try self.handleRuntimeFailure(err);
                return false;
            },
        };
        defer parsed.deinit();

        handleEventValue(
            self.allocator,
            self.stream_ptr,
            parsed.value,
            self.output,
            self.content_blocks,
            self.tool_calls,
            self.active_blocks,
            self.state,
            self.model,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try self.handleRuntimeFailure(err);
                return false;
            },
        };

        return self.stream_ptr.result() == null;
    }

    pub fn handleRuntimeFailure(self: *BedrockSseLoopHandler, err: anyerror) !void {
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

fn handleEventValue(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;

    const exception_fields = [_][]const u8{
        "internalServerException",
        "modelStreamErrorException",
        "validationException",
        "throttlingException",
        "serviceUnavailableException",
    };
    inline for (exception_fields) |field| {
        if (value.object.get(field)) |exception_value| {
            try collectOutputFromPartials(allocator, output, content_blocks, tool_calls, active_blocks);
            output.stop_reason = .error_reason;
            output.error_message = try buildExceptionMessage(allocator, field, exception_value);
            stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output.* });
            stream_ptr.end(output.*);
            return;
        }
    }
    var exception_iterator = value.object.iterator();
    while (exception_iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.key_ptr.*, "Exception")) {
            try collectOutputFromPartials(allocator, output, content_blocks, tool_calls, active_blocks);
            output.stop_reason = .error_reason;
            output.error_message = try buildExceptionMessage(allocator, entry.key_ptr.*, entry.value_ptr.*);
            stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output.* });
            stream_ptr.end(output.*);
            return;
        }
    }

    if (value.object.get("messageStart")) |start_value| {
        if (state.saw_message_start) return BedrockError.DuplicateBedrockMessageStart;
        state.saw_message_start = true;
        if (start_value != .object) return BedrockError.InvalidBedrockChunk;
        const role_value = start_value.object.get("role") orelse return BedrockError.InvalidBedrockChunk;
        if (role_value != .string) return BedrockError.InvalidBedrockChunk;
        if (!std.mem.eql(u8, role_value.string, "assistant")) {
            try emitStreamFailureMessage(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, .error_reason, "Unexpected assistant message start but got user message start instead");
            return;
        }
        stream_ptr.push(.{ .event_type = .start });
        return;
    }
    if (value.object.get("contentBlockStart")) |start_value| {
        try handleContentBlockStart(allocator, active_blocks, state, stream_ptr, content_blocks.items.len, start_value);
        return;
    }
    if (value.object.get("contentBlockDelta")) |delta_value| {
        try handleContentBlockDelta(allocator, active_blocks, state, stream_ptr, content_blocks.items.len, delta_value);
        return;
    }
    if (value.object.get("contentBlockStop")) |stop_value| {
        try handleContentBlockStop(allocator, active_blocks, state, content_blocks, tool_calls, stream_ptr, stop_value);
        return;
    }
    if (value.object.get("messageStop")) |stop_value| {
        if (stop_value == .object) {
            if (stop_value.object.get("stopReason")) |reason_value| {
                if (reason_value == .string) {
                    const mapped = try mapStopReasonWithMessage(allocator, reason_value.string);
                    output.stop_reason = mapped.stop_reason;
                    if (mapped.error_message) |message| {
                        replaceOutputErrorMessageOwned(allocator, output, message);
                    }
                }
            }
        }
        return;
    }
    if (value.object.get("metadata")) |metadata_value| {
        updateUsage(output, metadata_value, model);
        return;
    }
}

fn buildExceptionMessage(allocator: std.mem.Allocator, field: []const u8, value: std.json.Value) ![]const u8 {
    const raw_detail = if (value == .object and value.object.get("message") != null and value.object.get("message").? == .string)
        value.object.get("message").?.string
    else
        "Bedrock streaming request failed";
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, raw_detail);
    defer allocator.free(detail);
    const prefix = try bedrockExceptionPrefix(allocator, field);
    defer allocator.free(prefix);
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, detail });
}

fn bedrockExceptionPrefix(allocator: std.mem.Allocator, field: []const u8) ![]const u8 {
    if (std.mem.eql(u8, field, "internalServerException")) return allocator.dupe(u8, "Internal server error");
    if (std.mem.eql(u8, field, "modelStreamErrorException")) return allocator.dupe(u8, "Model stream error");
    if (std.mem.eql(u8, field, "validationException")) return allocator.dupe(u8, "Validation error");
    if (std.mem.eql(u8, field, "throttlingException")) return allocator.dupe(u8, "Throttling error");
    if (std.mem.eql(u8, field, "serviceUnavailableException")) return allocator.dupe(u8, "Service unavailable");
    return sanitizeExceptionName(allocator, field);
}

fn sanitizeExceptionName(allocator: std.mem.Allocator, field: []const u8) ![]const u8 {
    const limit = @min(field.len, 96);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (field[0..limit]) |byte| {
        try out.append(allocator, if (byte >= 0x20 and byte < 0x7f and byte != '\n' and byte != '\r' and byte != '\t') byte else '_');
    }
    if (out.items.len == 0) return allocator.dupe(u8, "Bedrock exception");
    if (field.len > limit) try out.appendSlice(allocator, "...");
    return out.toOwnedSlice(allocator);
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);
    if (findActiveBlock(active_blocks, bedrock_index) != null or isClosedContentBlock(state, bedrock_index)) return BedrockError.InvalidBedrockChunk;

    const start_value = value.object.get("start") orelse return;
    if (start_value != .object) return BedrockError.InvalidBedrockChunk;

    if (start_value.object.get("toolUse")) |tool_use_value| {
        if (tool_use_value != .object) return BedrockError.InvalidBedrockChunk;
        const id_value = tool_use_value.object.get("toolUseId") orelse return BedrockError.InvalidBedrockChunk;
        const name_value = tool_use_value.object.get("name") orelse return BedrockError.InvalidBedrockChunk;
        if (id_value != .string or name_value != .string) return BedrockError.InvalidBedrockChunk;

        const event_index = completed_count + active_blocks.items.len;
        try active_blocks.append(allocator, .{
            .bedrock_index = bedrock_index,
            .event_index = event_index,
            .block = .{ .tool_call = .{
                .id = try allocator.dupe(u8, id_value.string),
                .name = try allocator.dupe(u8, name_value.string),
                .partial_json = std.ArrayList(u8).empty,
            } },
        });
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(event_index) });
    }
}

fn handleContentBlockDelta(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);
    if (isClosedContentBlock(state, bedrock_index)) return BedrockError.InvalidBedrockChunk;
    const delta_value = value.object.get("delta") orelse return BedrockError.InvalidBedrockChunk;
    if (delta_value != .object) return BedrockError.InvalidBedrockChunk;

    if (delta_value.object.get("text")) |text_value| {
        if (text_value != .string) return BedrockError.InvalidBedrockChunk;
        var entry = try ensureActiveTextBlock(allocator, active_blocks, stream_ptr, completed_count, bedrock_index, false);
        if (entry.block != .text) return BedrockError.InvalidBedrockChunk;
        try entry.block.text.appendSlice(allocator, text_value.string);
        stream_ptr.push(.{ .event_type = .text_delta, .content_index = @intCast(entry.event_index), .delta = try allocator.dupe(u8, text_value.string), .owns_delta = true });
        return;
    }

    if (delta_value.object.get("toolUse")) |tool_use_value| {
        if (tool_use_value != .object) return BedrockError.InvalidBedrockChunk;
        const entry = findActiveBlock(active_blocks, bedrock_index) orelse return BedrockError.InvalidBedrockChunk;
        if (entry.block != .tool_call) return BedrockError.InvalidBedrockChunk;
        if (tool_use_value.object.get("input")) |input_value| {
            if (input_value != .string) return BedrockError.InvalidBedrockChunk;
            try entry.block.tool_call.partial_json.appendSlice(allocator, input_value.string);
            stream_ptr.push(.{ .event_type = .toolcall_delta, .content_index = @intCast(entry.event_index), .delta = try allocator.dupe(u8, input_value.string), .owns_delta = true });
        }
        return;
    }

    if (delta_value.object.get("reasoningContent")) |reasoning_value| {
        if (reasoning_value != .object) return BedrockError.InvalidBedrockChunk;
        var entry = try ensureActiveTextBlock(allocator, active_blocks, stream_ptr, completed_count, bedrock_index, true);
        if (entry.block != .thinking) return BedrockError.InvalidBedrockChunk;

        if (extractReasoningText(reasoning_value)) |text| {
            if (text.len > 0) {
                try entry.block.thinking.text.appendSlice(allocator, text);
                stream_ptr.push(.{ .event_type = .thinking_delta, .content_index = @intCast(entry.event_index), .delta = try allocator.dupe(u8, text), .owns_delta = true });
            }
        }
        if (extractReasoningSignature(reasoning_value)) |signature| {
            if (entry.block.thinking.signature) |existing| {
                const appended = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, signature });
                allocator.free(existing);
                entry.block.thinking.signature = appended;
            } else {
                entry.block.thinking.signature = try allocator.dupe(u8, signature);
            }
        }
        return;
    }
}

fn insertContentBlockAtEventIndex(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    event_index: usize,
    block: types.ContentBlock,
) !void {
    const insert_index = @min(event_index, content_blocks.items.len);
    try content_blocks.insert(allocator, insert_index, block);
}

fn ensureActiveTextBlock(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    bedrock_index: usize,
    is_thinking: bool,
) !*BlockEntry {
    if (findActiveBlock(active_blocks, bedrock_index)) |entry| return entry;

    const event_index = completed_count + active_blocks.items.len;
    try active_blocks.append(allocator, .{
        .bedrock_index = bedrock_index,
        .event_index = event_index,
        .block = if (is_thinking)
            .{ .thinking = .{ .text = std.ArrayList(u8).empty, .signature = null } }
        else
            .{ .text = std.ArrayList(u8).empty },
    });
    stream_ptr.push(.{ .event_type = if (is_thinking) .thinking_start else .text_start, .content_index = @intCast(event_index) });
    return &active_blocks.items[active_blocks.items.len - 1];
}

fn extractReasoningText(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("text")) |text_value| {
        if (text_value == .string) return text_value.string;
    }
    if (value.object.get("reasoningText")) |reasoning_text| {
        if (reasoning_text == .object) {
            if (reasoning_text.object.get("text")) |text_value| {
                if (text_value == .string) return text_value.string;
            }
        }
    }
    return null;
}

fn extractReasoningSignature(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("signature")) |signature_value| {
        if (signature_value == .string) return signature_value.string;
    }
    if (value.object.get("reasoningText")) |reasoning_text| {
        if (reasoning_text == .object) {
            if (reasoning_text.object.get("signature")) |signature_value| {
                if (signature_value == .string) return signature_value.string;
            }
        }
    }
    return null;
}

fn handleContentBlockStop(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);

    const remove_index = findActiveBlockIndex(active_blocks, bedrock_index) orelse return BedrockError.InvalidBedrockChunk;
    var entry = active_blocks.orderedRemove(remove_index);
    defer deinitCurrentBlock(allocator, &entry.block);
    try markClosedContentBlock(state, bedrock_index);

    switch (entry.block) {
        .text => |text| {
            const owned = try allocator.dupe(u8, text.items);
            try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .text = .{ .text = owned } });
            stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
        },
        .thinking => |thinking| {
            const owned = try allocator.dupe(u8, thinking.text.items);
            const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
            try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
            stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = owned });
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
            try finalize.insertInlineToolCall(allocator, content_blocks, tool_calls, @min(entry.event_index, content_blocks.items.len), final_tool_call);
            stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
        },
    }
}

fn findActiveBlock(active_blocks: *std.ArrayList(BlockEntry), bedrock_index: usize) ?*BlockEntry {
    const index = findActiveBlockIndex(active_blocks, bedrock_index) orelse return null;
    return &active_blocks.items[index];
}

fn findActiveBlockIndex(active_blocks: *const std.ArrayList(BlockEntry), bedrock_index: usize) ?usize {
    for (active_blocks.items, 0..) |entry, index| {
        if (entry.bedrock_index == bedrock_index) return index;
    }
    return null;
}

fn updateUsage(output: *types.AssistantMessage, metadata_value: std.json.Value, model: types.Model) void {
    if (metadata_value != .object) return;
    const usage_value = metadata_value.object.get("usage") orelse return;
    if (usage_value != .object) return;

    output.usage.input = getJsonU32(usage_value.object.get("inputTokens"));
    output.usage.output = getJsonU32(usage_value.object.get("outputTokens"));
    output.usage.cache_read = getJsonU32(usage_value.object.get("cacheReadInputTokens"));
    output.usage.cache_write = getJsonU32(usage_value.object.get("cacheWriteInputTokens"));
    output.usage.total_tokens = blk: {
        const total = getJsonU32(usage_value.object.get("totalTokens"));
        break :blk if (total > 0) total else output.usage.input + output.usage.output;
    };
    finalize.calculateCost(model, &output.usage);
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) return @intCast(json_value.integer);
    }
    return 0;
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
) !void {
    _ = model;
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
                stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .tool_call => |tool| {
                var parsed_arguments = (try parseCompleteToolArguments(allocator, tool.partial_json.items)) orelse continue;
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
                try finalize.insertInlineToolCall(allocator, content_blocks, tool_calls, @min(entry.event_index, content_blocks.items.len), final_tool_call);
                stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
            },
        }
    }

    try finalize.finalizeOutput(allocator, output, .{
        .content_blocks = content_blocks,
        .tool_calls = tool_calls,
    }, .{ .content_transfer = .when_output_empty });
    // Tool calls live inline in output.content; legacy AssistantMessage.tool_calls
    // is intentionally left null. tool_calls ArrayList holds borrow-only copies.
}

fn collectOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
) !void {
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .text = .{ .text = owned } });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
            },
            .tool_call => |tool| {
                var parsed_arguments = (try parseCompleteToolArguments(allocator, tool.partial_json.items)) orelse continue;
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
                try finalize.insertInlineToolCall(allocator, content_blocks, tool_calls, @min(entry.event_index, content_blocks.items.len), final_tool_call);
            },
        }
    }

    try finalize.finalizeOutput(allocator, output, .{
        .content_blocks = content_blocks,
        .tool_calls = tool_calls,
    }, .{ .content_transfer = .when_output_empty });
    // Tool calls are emitted inline; legacy field intentionally null.
}

fn parseCompleteToolArguments(allocator: std.mem.Allocator, input: []const u8) !?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn emitStreamFailureMessage(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    stop_reason: types.StopReason,
    message_text: []const u8,
) !void {
    try collectOutputFromPartials(allocator, output, content_blocks, tool_calls, active_blocks);
    output.stop_reason = stop_reason;
    try setOutputErrorMessageCopy(allocator, output, message_text);
    stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output.* });
    stream_ptr.end(output.*);
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
    _ = model;
    try emitStreamFailureMessage(
        allocator,
        stream_ptr,
        output,
        content_blocks,
        tool_calls,
        active_blocks,
        provider_error.runtimeStopReason(err),
        provider_error.runtimeErrorMessage(err),
    );
}

fn finalizeOutputSafely(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    finalizeOutput(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, state, model) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try emitRuntimeFailure(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, model, err),
    };
}

fn finalizeOutput(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    _ = model;
    if (!state.saw_message_start) {
        try emitStreamFailureMessage(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, .error_reason, "An unknown error occurred");
        return;
    }
    if (active_blocks.items.len != 0) return BedrockError.InvalidBedrockChunk;
    if (output.stop_reason == .error_reason or output.stop_reason == .aborted) {
        try emitStreamFailureMessage(
            allocator,
            stream_ptr,
            output,
            content_blocks,
            tool_calls,
            active_blocks,
            output.stop_reason,
            output.error_message orelse "An unknown error occurred",
        );
        return;
    }
    try finalize.finalizeOutput(allocator, output, .{
        .content_blocks = content_blocks,
        .tool_calls = tool_calls,
    }, .{
        .content_transfer = .always,
        .coerce_stop_reason_for_tool_calls = true,
    });
    // Tool calls are emitted inline; legacy field intentionally null.

    stream_ptr.push(.{ .event_type = .done, .message = output.* });
    stream_ptr.end(output.*);
}

pub fn mapStopReason(reason: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.bedrock_mappings, reason, .error_reason);
}

fn mapStopReasonWithMessage(allocator: std.mem.Allocator, reason: []const u8) !stop_reason_mod.StopReasonResult {
    inline for (stop_reason_mod.bedrock_mappings) |mapping| {
        if (std.mem.eql(u8, reason, mapping.literal)) {
            return .{
                .stop_reason = mapping.reason,
                .error_message = if (mapping.reason == .error_reason)
                    try std.fmt.allocPrint(allocator, "Bedrock stop reason: {s}", .{reason})
                else
                    null,
            };
        }
    }
    return .{
        .stop_reason = .error_reason,
        .error_message = try allocator.dupe(u8, "An unknown error occurred"),
    };
}

fn setOutputErrorMessageCopy(allocator: std.mem.Allocator, output: *types.AssistantMessage, message_text: []const u8) !void {
    if (output.error_message) |existing| {
        if (existing.ptr == message_text.ptr and existing.len == message_text.len) return;
        allocator.free(existing);
        output.error_message = null;
    }
    output.error_message = try allocator.dupe(u8, message_text);
}

fn replaceOutputErrorMessageOwned(allocator: std.mem.Allocator, output: *types.AssistantMessage, message: []const u8) void {
    if (output.error_message) |existing| allocator.free(existing);
    output.error_message = message;
}

test "ISS-041 mapStopReason aligns Bedrock safety stops with terminal errors" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("end_turn"));
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason("stop_sequence"));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason("max_tokens"));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason("model_context_window_exceeded"));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReason("tool_use"));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReason("guardrail_intervened"));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReason("content_filtered"));
    try std.testing.expectEqual(types.StopReason.error_reason, mapStopReason("future_stop_reason"));
}

test "ISS-041 Bedrock safety and unknown stop reasons emit terminal errors with reason metadata" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");

    const cases = [_]struct {
        reason: []const u8,
        expected_error: []const u8,
    }{
        .{ .reason = "guardrail_intervened", .expected_error = "Bedrock stop reason: guardrail_intervened" },
        .{ .reason = "content_filtered", .expected_error = "Bedrock stop reason: content_filtered" },
        .{ .reason = "future_stop_reason", .expected_error = "An unknown error occurred" },
    };

    for (cases) |case| {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
        try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial before safety stop\"}}");
        try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
        const message_stop = try std.fmt.allocPrint(allocator, "{{\"stopReason\":\"{s}\"}}", .{case.reason});
        defer allocator.free(message_stop);
        try appendEventStreamFrame(allocator, &body, "messageStop", message_stop);

        var stream = event_stream.createAssistantMessageEventStream(allocator, io);
        defer stream.deinit();

        try parseEventStreamFrames(allocator, &stream, body.items, model, null);

        try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
        try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
        try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
        try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);
        const terminal = stream.next().?;
        try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
        try std.testing.expect(terminal.message != null);
        try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
        try std.testing.expectEqualStrings("partial before safety stop", terminal.message.?.content[0].text.text);
        try std.testing.expectEqualStrings(case.expected_error, terminal.error_message.?);
        try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
        try std.testing.expect(stream.next() == null);
    }
}

fn authErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingAwsAccessKeyId => "Bedrock requires AWS_ACCESS_KEY_ID.",
        error.MissingAwsSecretAccessKey => "Bedrock requires AWS_SECRET_ACCESS_KEY.",
        else => "Bedrock authentication failed.",
    };
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

const FixtureRegion = struct {
    source: []const u8,
    value: ?[]const u8 = null,
};

const FixtureEndpoint = struct {
    mode: []const u8,
    value: ?[]const u8 = null,
};

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return text;
}

const fixture_env_names = [_][]const u8{
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_PROFILE",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
    "AWS_BEDROCK_SKIP_AUTH",
};

const ScopedFixtureEnv = struct {
    allocator: std.mem.Allocator,
    saved: [fixture_env_names.len]?[]u8,

    fn init(allocator: std.mem.Allocator, fixture_env: FixtureEnv) !ScopedFixtureEnv {
        var scoped = ScopedFixtureEnv{
            .allocator = allocator,
            .saved = [_]?[]u8{null} ** fixture_env_names.len,
        };
        errdefer scoped.deinit();

        inline for (fixture_env_names, 0..) |name, index| {
            scoped.saved[index] = try loadEnvOptional(allocator, name);
            try setProcessEnvOptional(allocator, name, fixtureEnvValue(fixture_env, index));
        }
        return scoped;
    }

    fn deinit(self: *ScopedFixtureEnv) void {
        inline for (fixture_env_names, 0..) |name, index| {
            setProcessEnvOptional(self.allocator, name, self.saved[index]) catch {};
            if (self.saved[index]) |value| self.allocator.free(value);
            self.saved[index] = null;
        }
    }
};

fn fixtureEnvValue(env: FixtureEnv, comptime index: usize) ?[]const u8 {
    return switch (index) {
        0 => env.aws_access_key_id,
        1 => env.aws_secret_access_key,
        2 => env.aws_session_token,
        3 => env.aws_profile,
        4 => env.aws_bearer_token_bedrock,
        5 => env.aws_region,
        6 => env.aws_default_region,
        7 => env.aws_bedrock_skip_auth,
        else => @compileError("unsupported fixture env index"),
    };
}

fn setProcessEnvOptional(allocator: std.mem.Allocator, name: []const u8, value: ?[]const u8) !void {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    if (value) |text| {
        const value_z = try allocator.dupeZ(u8, text);
        defer allocator.free(value_z);
        if (setenv(name_z.ptr, value_z.ptr, 1) != 0) return error.SetEnvironmentFailed;
    } else {
        if (unsetenv(name_z.ptr) != 0) return error.SetEnvironmentFailed;
    }
}

fn requestSurfaceRegionSnapshot(base_url: []const u8, options: ?types.StreamOptions, env: FixtureEnv, endpoint: ResolvedBedrockEndpoint) FixtureRegion {
    if (options) |stream_options| {
        if (nonEmpty(stream_options.providerOptions("bedrock").region) != null) return .{ .source = "options.region", .value = endpoint.region };
    }
    if (nonEmpty(env.aws_region) != null) return .{ .source = "AWS_REGION", .value = endpoint.region };
    if (nonEmpty(env.aws_default_region) != null) return .{ .source = "AWS_DEFAULT_REGION", .value = endpoint.region };
    if (standardEndpointRegion(base_url) != null and nonEmpty(env.aws_profile) == null) return .{ .source = "endpoint", .value = endpoint.region };
    if (nonEmpty(env.aws_profile) != null) return .{ .source = "sdk-profile-resolution" };
    return .{ .source = "default", .value = endpoint.region };
}

fn requestSurfaceEndpointSnapshot(
    base_url: []const u8,
    options: ?types.StreamOptions,
    env: FixtureEnv,
    endpoint: ResolvedBedrockEndpoint,
    use_http_boundary: bool,
) FixtureEndpoint {
    if (use_http_boundary) return .{ .mode = "sdk-http-request", .value = endpoint.base_url };
    if (nonEmpty(env.aws_profile) != null and !hasRequestSurfaceConfiguredRegion(options, env)) {
        return .{ .mode = "sdk-profile-resolution" };
    }
    if (standardEndpointRegion(base_url) == null) return .{ .mode = "explicit", .value = endpoint.base_url };
    if (hasRequestSurfaceConfiguredRegion(options, env)) return .{ .mode = "sdk-default", .value = endpoint.base_url };
    return .{ .mode = "explicit", .value = endpoint.base_url };
}

fn hasRequestSurfaceConfiguredRegion(options: ?types.StreamOptions, env: FixtureEnv) bool {
    if (options) |stream_options| {
        if (nonEmpty(stream_options.providerOptions("bedrock").region) != null) return true;
    }
    return nonEmpty(env.aws_region) != null or nonEmpty(env.aws_default_region) != null;
}

fn useProductionHttpRequestBoundary(options: ?types.StreamOptions, env: FixtureEnv) bool {
    if (std.mem.eql(u8, nonEmpty(env.aws_bedrock_skip_auth) orelse "", "1")) return false;
    if (options) |stream_options| {
        if (nonEmpty(stream_options.providerOptions("bedrock").bearer_token) != null) return true;
    }
    if (nonEmpty(env.aws_bearer_token_bedrock) != null) return true;
    return nonEmpty(env.aws_access_key_id) != null and nonEmpty(env.aws_secret_access_key) != null;
}

fn buildProductionAuthSnapshot(
    allocator: std.mem.Allocator,
    auth: ?BedrockAuth,
    options: ?types.StreamOptions,
    env: FixtureEnv,
    region: FixtureRegion,
    headers: *const std.StringHashMap([]const u8),
) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });

    const option_bearer = if (options) |stream_options| nonEmpty(stream_options.providerOptions("bedrock").bearer_token) else null;
    const env_bearer = nonEmpty(env.aws_bearer_token_bedrock);

    if (std.mem.eql(u8, nonEmpty(env.aws_bedrock_skip_auth) orelse "", "1")) {
        try putStringValue(allocator, &object, "mode", "skip-auth");
        try putStringValue(allocator, &object, "credentialSource", "proxy-dummy");
        try putBoolValue(allocator, &object, "bearerSuppressed", option_bearer != null or env_bearer != null);
        try putStringValue(allocator, &object, "secrets", "redacted");
        return .{ .object = object };
    }

    const resolved_auth = auth orelse {
        try putStringValue(allocator, &object, "mode", "missing-credentials");
        try putStringValue(allocator, &object, "errorSurface", "async-stream-error");
        try putStringValue(allocator, &object, "message", "Bedrock requires AWS_ACCESS_KEY_ID.");
        try putStringValue(allocator, &object, "network", "not-attempted");
        return .{ .object = object };
    };

    switch (resolved_auth) {
        .bearer => {
            try putStringValue(allocator, &object, "mode", "bearer");
            try putStringValue(allocator, &object, "source", if (option_bearer != null) "options.bearerToken" else "env.bearerToken");
            try putStringValue(allocator, &object, "token", "redacted");
            try putBoolValue(allocator, &object, "sigv4", false);
        },
        .profile => {
            try putStringValue(allocator, &object, "mode", "profile");
            const profile_boundary_value: std.json.Value = blk: {
                var profile_boundary = try provider_json.initObject(allocator);
                errdefer provider_json.freeValue(allocator, .{ .object = profile_boundary });
                try putStringValue(allocator, &profile_boundary, "source", "aws-sdk-shared-ini-profile-resolution");
                const configured_profile = if (options) |stream_options| nonEmpty(stream_options.providerOptions("bedrock").profile) else null;
                const env_profile = nonEmpty(env.aws_profile);
                try putStringValue(allocator, &profile_boundary, "selectedProfile", configured_profile orelse env_profile orelse "default");
                if (options) |stream_options| {
                    if (nonEmpty(stream_options.providerOptions("bedrock").profile)) |profile| {
                        try putStringValue(allocator, &object, "optionsProfile", profile);
                        try putStringValue(allocator, &profile_boundary, "configuredProfile", profile);
                    }
                }
                if (nonEmpty(env.aws_profile)) |profile| {
                    try putStringValue(allocator, &object, "envProfile", profile);
                    try putStringValue(allocator, &profile_boundary, "envProfile", profile);
                }
                break :blk .{ .object = profile_boundary };
            };
            try putStringValue(allocator, &object, "credentialDiscovery", "sdk-profile-resolution");
            try putObjectValue(allocator, &object, "profileBoundary", profile_boundary_value);
        },
        .sigv4 => {
            const authorization = headerValueIgnoreCase(headers, "authorization");
            const credential_scope = if (authorization) |value| try parseCredentialScope(allocator, value, region.value orelse "us-east-1") else try defaultCredentialScope(allocator, region.value orelse "us-east-1");

            try putStringValue(allocator, &object, "mode", "sigv4");
            try putStringValue(allocator, &object, "method", "POST");
            try putStringValue(allocator, &object, "query", "");
            try putStringValue(allocator, &object, "service", SERVICE_NAME);
            try putStringValue(allocator, &object, "region", credential_scope.get("region").?.string);
            try putStringValue(allocator, &object, "amzDate", "20250115T120000Z");
            try putObjectValue(allocator, &object, "credentialScope", .{ .object = credential_scope });
            try putObjectValue(allocator, &object, "signedHeaders", try parseSignedHeadersValue(allocator, authorization orelse ""));
            try putStringValue(allocator, &object, "bodySha256", if (headerValueIgnoreCase(headers, "x-amz-content-sha256") != null) "normalized-payload-sha256" else "missing");
            if (headerValueIgnoreCase(headers, "x-amz-security-token") != null) try putStringValue(allocator, &object, "sessionToken", "redacted");
            try putStringValue(allocator, &object, "accessKeyId", "redacted");
            try putStringValue(allocator, &object, "signature", "normalized");
        },
    }
    return .{ .object = object };
}

fn headerValueIgnoreCase(headers: *const std.StringHashMap([]const u8), name: []const u8) ?[]const u8 {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn parseCredentialScope(allocator: std.mem.Allocator, authorization: []const u8, fallback_region: []const u8) !std.json.ObjectMap {
    const credential = extractAuthorizationParameter(authorization, "Credential") orelse return defaultCredentialScope(allocator, fallback_region);
    var parts = std.mem.splitScalar(u8, credential, '/');
    _ = parts.next();
    _ = parts.next();
    const parsed_region = parts.next() orelse fallback_region;
    const parsed_service = parts.next() orelse SERVICE_NAME;
    const parsed_terminal = parts.next() orelse "aws4_request";

    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "date", "20250115");
    try putStringValue(allocator, &object, "region", parsed_region);
    try putStringValue(allocator, &object, "service", parsed_service);
    try putStringValue(allocator, &object, "terminal", parsed_terminal);
    return object;
}

fn defaultCredentialScope(allocator: std.mem.Allocator, region: []const u8) !std.json.ObjectMap {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });
    try putStringValue(allocator, &object, "date", "20250115");
    try putStringValue(allocator, &object, "region", region);
    try putStringValue(allocator, &object, "service", SERVICE_NAME);
    try putStringValue(allocator, &object, "terminal", "aws4_request");
    return object;
}

fn extractAuthorizationParameter(authorization: []const u8, name: []const u8) ?[]const u8 {
    const prefix = std.fmt.allocPrint(std.heap.page_allocator, "{s}=", .{name}) catch return null;
    defer std.heap.page_allocator.free(prefix);
    const start = std.mem.indexOf(u8, authorization, prefix) orelse return null;
    const value_start = start + prefix.len;
    const rest = authorization[value_start..];
    const value_end = std.mem.indexOfAny(u8, rest, ", ") orelse rest.len;
    return rest[0..value_end];
}

fn parseSignedHeadersValue(allocator: std.mem.Allocator, authorization: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const signed_headers = extractAuthorizationParameter(authorization, "SignedHeaders") orelse "";
    var iterator = std.mem.splitScalar(u8, signed_headers, ';');
    while (iterator.next()) |header| {
        if (isSemanticSignedHeader(header)) {
            try array.append(.{ .string = try allocator.dupe(u8, header) });
        }
    }
    return .{ .array = array };
}

fn isSemanticSignedHeader(header: []const u8) bool {
    inline for (&[_][]const u8{ "content-type", "host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token" }) |semantic| {
        if (std.mem.eql(u8, header, semantic)) return true;
    }
    return false;
}

fn standardEndpointRegion(base_url: []const u8) ?[]const u8 {
    const prefix = "https://";
    const rest = if (std.mem.startsWith(u8, base_url, prefix)) base_url[prefix.len..] else base_url;
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..host_end];
    const prefixes = [_][]const u8{ "bedrock-runtime.", "bedrock-runtime-fips." };
    for (prefixes) |pattern| {
        if (std.mem.startsWith(u8, host, pattern)) {
            const after = host[pattern.len..];
            if (std.mem.indexOf(u8, after, ".amazonaws.com.cn")) |end| return after[0..end];
            if (std.mem.indexOf(u8, after, ".amazonaws.com")) |end| return after[0..end];
        }
    }
    return null;
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    return abort_helper.isRequestedFromOptions(options);
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.deinit(allocator),
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

fn eventTypeName(event_type: types.EventType) []const u8 {
    return switch (event_type) {
        .error_event => "error",
        inline else => |tag| @tagName(tag),
    };
}

fn stopReasonName(stop_reason: types.StopReason) []const u8 {
    return switch (stop_reason) {
        .tool_use => "toolUse",
        .error_reason => "error",
        inline else => |tag| @tagName(tag),
    };
}

fn snapshotCostValue(allocator: std.mem.Allocator, cost: types.UsageCost) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "cacheRead"), if (cost.cache_read == 0) .{ .integer = 0 } else .{ .float = cost.cache_read });
    try object.put(allocator, try allocator.dupe(u8, "cacheWrite"), if (cost.cache_write == 0) .{ .integer = 0 } else .{ .float = cost.cache_write });
    try object.put(allocator, try allocator.dupe(u8, "input"), if (cost.input == 0) .{ .integer = 0 } else .{ .float = cost.input });
    try object.put(allocator, try allocator.dupe(u8, "output"), if (cost.output == 0) .{ .integer = 0 } else .{ .float = cost.output });
    try object.put(allocator, try allocator.dupe(u8, "total"), if (cost.total == 0) .{ .integer = 0 } else .{ .float = cost.total });
    return .{ .object = object };
}

fn snapshotUsageValue(allocator: std.mem.Allocator, usage: types.Usage) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try putIntegerField(allocator, &object, "cacheRead", usage.cache_read);
    try putIntegerField(allocator, &object, "cacheWrite", usage.cache_write);
    try object.put(allocator, try allocator.dupe(u8, "cost"), try snapshotCostValue(allocator, usage.cost));
    try putIntegerField(allocator, &object, "input", usage.input);
    try putIntegerField(allocator, &object, "output", usage.output);
    try putIntegerField(allocator, &object, "totalTokens", usage.total_tokens);
    return .{ .object = object };
}

fn snapshotToolCallValue(allocator: std.mem.Allocator, tool_call: types.ToolCall) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "arguments"), try provider_json.cloneValue(allocator, tool_call.arguments));
    try putStringField(allocator, &object, "id", tool_call.id);
    try putStringField(allocator, &object, "name", tool_call.name);
    return .{ .object = object };
}

fn snapshotContentBlockValue(allocator: std.mem.Allocator, block: types.ContentBlock) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    switch (block) {
        .text => |text| {
            try putStringField(allocator, &object, "text", text.text);
            try putStringField(allocator, &object, "type", "text");
        },
        .thinking => |thinking| {
            try putStringField(allocator, &object, "thinking", thinking.thinking);
            if (types.thinkingSignature(thinking)) |signature| {
                try putStringField(allocator, &object, "thinkingSignature", signature);
            }
            try putStringField(allocator, &object, "type", "thinking");
        },
        .tool_call => |tool_call| {
            try object.put(allocator, try allocator.dupe(u8, "arguments"), try provider_json.cloneValue(allocator, tool_call.arguments));
            try putStringField(allocator, &object, "id", tool_call.id);
            try putStringField(allocator, &object, "name", tool_call.name);
            try putStringField(allocator, &object, "type", "toolCall");
        },
        .image => return BedrockError.InvalidBedrockChunk,
    }
    return .{ .object = object };
}

fn snapshotMessageValue(allocator: std.mem.Allocator, message: types.AssistantMessage) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try putStringField(allocator, &object, "api", message.api);
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();
    for (message.content) |block| {
        try content.append(try snapshotContentBlockValue(allocator, block));
    }
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    if (message.error_message) |error_message| try putStringField(allocator, &object, "errorMessage", error_message);
    try putStringField(allocator, &object, "model", message.model);
    try putStringField(allocator, &object, "provider", message.provider);
    try putStringField(allocator, &object, "role", "assistant");
    try putStringField(allocator, &object, "stopReason", stopReasonName(message.stop_reason));
    try object.put(allocator, try allocator.dupe(u8, "usage"), try snapshotUsageValue(allocator, message.usage));
    return .{ .object = object };
}

fn snapshotEventValue(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    if (event.content) |content| try putStringField(allocator, &object, "content", content);
    if (event.content_index) |content_index| try putIntegerField(allocator, &object, "contentIndex", content_index);
    if (event.delta) |delta| try putStringField(allocator, &object, "delta", delta);
    if (event.error_message) |error_message| try putStringField(allocator, &object, "errorMessage", error_message);
    if (event.message) |message| try object.put(allocator, try allocator.dupe(u8, "message"), try snapshotMessageValue(allocator, message));
    if (event.tool_call) |tool_call| try object.put(allocator, try allocator.dupe(u8, "toolCall"), try snapshotToolCallValue(allocator, tool_call));
    try putStringField(allocator, &object, "type", eventTypeName(event.event_type));
    return .{ .object = object };
}

fn snapshotStreamEvents(
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
    stream_instance: *event_stream.AssistantMessageEventStream,
) !std.json.Value {
    var events = std.json.Array.init(allocator);
    errdefer events.deinit();
    while (stream_instance.next()) |event| {
        defer event.deinitTransient(event_allocator);
        try events.append(try snapshotEventValue(allocator, event));
    }
    return .{ .array = events };
}

pub fn freeOwnedJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    provider_json.freeValue(allocator, value);
}

const BedrockOnResponseCapture = struct {
    var called: bool = false;
    var status: u16 = 0;
    var header_count: usize = 0;

    fn reset() void {
        called = false;
        status = 0;
        header_count = 0;
    }

    fn callback(response_status: u16, headers: std.StringHashMap([]const u8), model: types.Model) anyerror!void {
        called = true;
        status = response_status;
        header_count = headers.count();
        try std.testing.expectEqualStrings("bedrock-converse-stream", model.api);
    }
};

fn bedrockTestModel(base_url: []const u8) types.Model {
    return .{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude Bedrock",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };
}

fn bedrockTestContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

test "Bedrock production endpoint resolver replaces standard endpoint when region is configured" {
    const allocator = std.testing.allocator;

    const standard = try resolveBedrockEndpoint(
        allocator,
        "https://bedrock-runtime.eu-central-1.amazonaws.com",
        .{ .provider = .{ .bedrock = .{ .region = "us-west-2" } } },
    );
    defer standard.deinit(allocator);
    try std.testing.expectEqualStrings("https://bedrock-runtime.us-west-2.amazonaws.com", standard.base_url);
    try std.testing.expectEqualStrings("us-west-2", standard.region);

    const custom = try resolveBedrockEndpoint(
        allocator,
        "https://bedrock-vpc.example.com",
        .{ .provider = .{ .bedrock = .{ .region = "us-west-2" } } },
    );
    defer custom.deinit(allocator);
    try std.testing.expectEqualStrings("https://bedrock-vpc.example.com", custom.base_url);
    try std.testing.expectEqualStrings("us-west-2", custom.region);
}

test "Bedrock profile-only auth surface does not require IAM environment credentials" {
    const allocator = std.testing.allocator;
    const auth = try resolveBedrockAuth(allocator, .{ .provider = .{ .bedrock = .{ .profile = "fixture-option-profile" } } });
    defer auth.deinit(allocator);

    switch (auth) {
        .profile => {},
        else => return error.TestExpectedProfileAuth,
    }
}

test "Bedrock stream on_response observes non-200 metadata before sanitized error" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    BedrockOnResponseCapture.reset();

    var server = try provider_error.TestStatusServer.init(
        io,
        503,
        "Service Unavailable",
        "x-amzn-requestid: fixture-request-id\r\n",
        "{\"message\":\"service unavailable fixture\"}",
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try BedrockProvider.stream(
        allocator,
        io,
        bedrockTestModel(url),
        bedrockTestContext(),
        .{ .provider = .{ .bedrock = .{ .bearer_token = "fixture-token" } }, .on_response = &BedrockOnResponseCapture.callback },
    );
    defer stream.deinit();

    try std.testing.expect(BedrockOnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 503), BedrockOnResponseCapture.status);
    try std.testing.expect(BedrockOnResponseCapture.header_count > 0);

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.error_message != null);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 503:"));
}

test "Bedrock stream converts pre-aborted requestStreaming failure into terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    var aborted = std.atomic.Value(bool).init(true);

    var stream = try BedrockProvider.stream(
        allocator,
        io,
        bedrockTestModel("https://bedrock-runtime.us-east-1.amazonaws.com"),
        bedrockTestContext(),
        .{ .provider = .{ .bedrock = .{ .bearer_token = "fixture-token" } }, .signal = &aborted },
    );
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, event.message.?.stop_reason);
    try std.testing.expectEqualStrings("Request was aborted", event.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "VAL-MSG-010 Bedrock skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude Bedrock",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };
    const first_user = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const failed_content = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = "partial thinking", .thinking_signature = "sig" } },
        .{ .tool_call = .{ .id = "failed-tool", .name = "lookup", .arguments = .null } },
    };
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .user = .{ .content = &first_user, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "bedrock-converse-stream",
            .provider = "amazon-bedrock",
            .model = "anthropic.claude-3-7-sonnet-20250219-v1:0",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "bedrock-converse-stream",
            .provider = "amazon-bedrock",
            .model = "anthropic.claude-3-7-sonnet-20250219-v1:0",
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

test "buildRequestPayload includes bedrock system messages inference config and tools" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer provider_json.freeValue(allocator, tool_schema_value);

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello Bedrock" } }},
                .timestamp = 1,
            } },
        },
        .tools = &[_]types.Tool{.{
            .name = "get_weather",
            .description = "Get weather",
            .parameters = tool_schema_value,
        }},
    };

    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.25,
        .max_tokens = 512,
        .provider = .{ .google = .{ .tool_choice = "any" } },
    });
    defer provider_json.freeValue(allocator, payload);

    const object = payload.object;
    try std.testing.expect(object.get("system") != null);
    try std.testing.expect(object.get("messages") != null);
    try std.testing.expect(object.get("inferenceConfig") != null);
    try std.testing.expect(object.get("toolConfig") != null);
    try std.testing.expectEqual(@as(i64, 512), object.get("inferenceConfig").?.object.get("maxTokens").?.integer);
    try std.testing.expectEqualStrings("Hello Bedrock", object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "signRequestHeaders creates sigv4 authorization and security token" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        headers.deinit();
    }
    try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");

    try signRequestHeaders(
        allocator,
        &headers,
        model.base_url,
        "/model/anthropic.claude-3-7-sonnet-20250219-v1%3A0/converse-stream",
        "{}",
        .{
            .access_key_id = "AKIDEXAMPLE",
            .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            .session_token = "IQoJb3JpZ2luX2VjEOr//////////wEaCXVzLWVhc3QtMSJHMEUCIQDn",
        },
        .{
            .amz_date = "20250115T120000Z",
            .date_stamp = "20250115",
        },
        "us-east-1",
    );

    try std.testing.expectEqualStrings("bedrock-runtime.us-east-1.amazonaws.com", headers.get("host").?);
    try std.testing.expectEqualStrings("20250115T120000Z", headers.get("x-amz-date").?);
    try std.testing.expectEqualStrings("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", headers.get("x-amz-content-sha256").?);
    try std.testing.expectEqualStrings("IQoJb3JpZ2luX2VjEOr//////////wEaCXVzLWVhc3QtMSJHMEUCIQDn", headers.get("x-amz-security-token").?);
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20250115/us-east-1/bedrock/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=8271ddd75388cc7aeb4cececc432f97a4e5c9cbc5d072d94b5bcc4b30809cb1f",
        headers.get("Authorization").?,
    );
}

fn appendBigEndianU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendBigEndianU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendEventStreamHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    try headers.append(allocator, @intCast(name.len));
    try headers.appendSlice(allocator, name);
    try headers.append(allocator, 7);
    try appendBigEndianU16(headers, allocator, value.len);
    try headers.appendSlice(allocator, value);
}

fn appendEventStreamFrame(
    allocator: std.mem.Allocator,
    frames: *std.ArrayList(u8),
    event_type: []const u8,
    payload: []const u8,
) !void {
    var headers = std.ArrayList(u8).empty;
    defer headers.deinit(allocator);
    try appendEventStreamHeader(allocator, &headers, ":event-type", event_type);

    const total_length = 16 + headers.items.len + payload.len;
    try appendBigEndianU32(frames, allocator, total_length);
    try appendBigEndianU32(frames, allocator, headers.items.len);
    try appendBigEndianU32(frames, allocator, 0);
    try frames.appendSlice(allocator, headers.items);
    try frames.appendSlice(allocator, payload);
    try appendBigEndianU32(frames, allocator, 0);
}

fn appendEventStreamExceptionFrame(
    allocator: std.mem.Allocator,
    frames: *std.ArrayList(u8),
    exception_type: []const u8,
    payload: []const u8,
) !void {
    var headers = std.ArrayList(u8).empty;
    defer headers.deinit(allocator);
    try appendEventStreamHeader(allocator, &headers, ":exception-type", exception_type);

    const total_length = 16 + headers.items.len + payload.len;
    try appendBigEndianU32(frames, allocator, total_length);
    try appendBigEndianU32(frames, allocator, headers.items.len);
    try appendBigEndianU32(frames, allocator, 0);
    try frames.appendSlice(allocator, headers.items);
    try frames.appendSlice(allocator, payload);
    try appendBigEndianU32(frames, allocator, 0);
}

test "parseEventStreamFrames handles bedrock binary converse stream" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"reasoningText\":{\"text\":\"Need weather.\",\"signature\":\"sig-1\"}}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"text\":\"Checking now\"}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":1}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Ber\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"lin\\\",\\\"unit\\\":\\\"C\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":2}");
    try appendEventStreamFrame(allocator, &body, "messageStop", "{\"stopReason\":\"tool_use\"}");
    try appendEventStreamFrame(allocator, &body, "metadata", "{\"usage\":{\"inputTokens\":21,\"outputTokens\":9,\"totalTokens\":30}}");

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    try parseEventStreamFrames(allocator, &stream_instance, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqualStrings("Need weather.", thinking_delta.delta.?);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqualStrings("Checking now", text_delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    const tool_delta_one = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_one.event_type);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta_one.delta.?, "Ber") != null);
    const tool_delta_two = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_two.event_type);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta_two.delta.?, "unit") != null);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    try std.testing.expectEqualStrings("C", tool_end.tool_call.?.arguments.object.get("unit").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 21), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 9), done.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 30), done.message.?.usage.total_tokens);
}

test "parse bedrock stream emits text thinking and tool call events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "data: {\"messageStart\":{\"role\":\"assistant\"}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"text\":\"Need weather.\",\"signature\":\"sig-1\"}}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":0}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":1,\"delta\":{\"text\":\"Checking now\"}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":1}}\n" ++
        "data: {\"contentBlockStart\":{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":2}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":3,\"delta\":{\"text\":\"After tool\"}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":3}}\n" ++
        "data: {\"messageStop\":{\"stopReason\":\"tool_use\"}}\n" ++
        "data: {\"metadata\":{\"usage\":{\"inputTokens\":21,\"outputTokens\":9,\"totalTokens\":30}}}\n";

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
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    try parseTextStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    const thinking_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_start, thinking_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_start.content_index.?);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_delta.content_index.?);
    try std.testing.expectEqualStrings("Need weather.", thinking_delta.delta.?);
    const thinking_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqual(@as(u32, 0), thinking_end.content_index.?);
    const text_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_start, text_start.event_type);
    try std.testing.expectEqual(@as(u32, 1), text_start.content_index.?);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqual(@as(u32, 1), text_delta.content_index.?);
    try std.testing.expectEqualStrings("Checking now", text_delta.delta.?);
    const text_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqual(@as(u32, 1), text_end.content_index.?);
    const tool_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_start.content_index.?);
    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_delta.content_index.?);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta.delta.?, "Berlin") != null);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqual(@as(u32, 2), tool_end.content_index.?);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    const after_start = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_start, after_start.event_type);
    try std.testing.expectEqual(@as(u32, 3), after_start.content_index.?);
    const after_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, after_delta.event_type);
    try std.testing.expectEqual(@as(u32, 3), after_delta.content_index.?);
    try std.testing.expectEqualStrings("After tool", after_delta.delta.?);
    const after_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_end, after_end.event_type);
    try std.testing.expectEqual(@as(u32, 3), after_end.content_index.?);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), done.message.?.content.len);
    try std.testing.expectEqualStrings("After tool", done.message.?.content[3].text.text);
    try std.testing.expectEqual(@as(u32, 21), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 9), done.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 30), done.message.?.usage.total_tokens);
}

test "parseTextStreamLines preserves raw JSON line tolerance with shared SSE loop" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "{\"messageStart\":{\"role\":\"assistant\"}}\n" ++
            "{\"contentBlockDelta\":{\"contentBlockIndex\":0,\"delta\":{\"text\":\"raw text\"}}}\n" ++
            "{\"contentBlockStop\":{\"contentBlockIndex\":0}}\n" ++
            "{\"messageStop\":{\"stopReason\":\"end_turn\"}}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseTextStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("raw text", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("raw text", text_end.content.?);
    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("raw text", done.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseEventStreamFrames joins split tool call input fragments" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":0,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Ber\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"lin\\\",\\\"unit\\\":\\\"C\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
    try appendEventStreamFrame(allocator, &body, "messageStop", "{\"stopReason\":\"tool_use\"}");

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    try parseEventStreamFrames(allocator, &stream_instance, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    const tool_delta_one = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_one.event_type);
    try std.testing.expectEqualStrings("{\"city\":\"Ber", tool_delta_one.delta.?);
    const tool_delta_two = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_two.event_type);
    try std.testing.expectEqualStrings("lin\",\"unit\":\"C\"}", tool_delta_two.delta.?);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("tool-1", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    try std.testing.expectEqualStrings("C", tool_end.tool_call.?.arguments.object.get("unit").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
}

test "parseEventStreamFrames coerces end_turn to tool_use when tool calls are present" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":0,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-stop-coerce\",\"name\":\"lookup\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"{\\\"query\\\":\\\"coerce\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
    try appendEventStreamFrame(allocator, &body, "messageStop", "{\"stopReason\":\"end_turn\"}");

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    try parseEventStreamFrames(allocator, &stream_instance, body.items, model, null);

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

test "parseTextStreamLines preserves partial Bedrock text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"messageStart\":{\"role\":\"assistant\"}}\n" ++
            "data: {\"contentBlockDelta\":{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial\"}}}\n" ++
            "data: {not-json}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseTextStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("bedrock-converse-stream", "bedrock"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseEventStreamFrames finalizes partial Bedrock blocks before provider exception" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial text\"}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"reasoningContent\":{\"text\":\"partial thought\",\"signature\":\"sig-1\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "modelStreamErrorException", "{\"message\":\"provider failed with sk-bedrock-secret at /Users/alice/file.zig\"}");

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseEventStreamFrames(allocator, &stream, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("partial text", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("partial thought", terminal.message.?.content[1].thinking.thinking);
    try std.testing.expect(terminal.message.?.content[2] == .tool_call);
    try std.testing.expectEqualStrings("get_weather", terminal.message.?.content[2].tool_call.name);
    try std.testing.expectEqualStrings("Berlin", terminal.message.?.content[2].tool_call.arguments.object.get("city").?.string);
    try std.testing.expect(terminal.message.?.tool_calls == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "sk-bedrock-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "/Users/alice") == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "parseEventStreamFrames surfaces unknown binary exception raw name" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamExceptionFrame(allocator, &body, "UnmodeledBedrockException", "{\"message\":\"raw unknown failure\"}");

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseEventStreamFrames(allocator, &stream, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(std.mem.startsWith(u8, terminal.error_message.?, "UnmodeledBedrockException: raw unknown failure"));
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "parseEventStreamFrames converts invalid terminal state into partial-preserving error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial terminal text\"}}");

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseEventStreamFrames(allocator, &stream, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial terminal text", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("InvalidBedrockChunk", terminal.error_message.?);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "parseEventStreamFrames drops unsafe active tool scratch on terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"safe text\"}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":1,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\"}}}");

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseEventStreamFrames(allocator, &stream, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("safe text", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), terminal.message.?.content.len);
    try std.testing.expect(terminal.message.?.tool_calls == null);
    try std.testing.expectEqualStrings("InvalidBedrockChunk", terminal.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "Bedrock abort terminal finalizes active binary partial blocks" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");
    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }

    var text = std.ArrayList(u8).empty;
    try text.appendSlice(allocator, "partial before abort");
    try active_blocks.append(allocator, .{
        .bedrock_index = 0,
        .event_index = 0,
        .block = .{ .text = text },
    });

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    stream.push(.{ .event_type = .start });

    try emitRuntimeFailure(allocator, &stream, &output, &content_blocks, &tool_calls, &active_blocks, model, error.RequestAborted);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial before abort", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude Bedrock",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
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
    var stream = try BedrockProvider.stream(
        allocator,
        io,
        model,
        context,
        .{ .provider = .{ .bedrock = .{ .bearer_token = "placeholder" } } },
    );
    defer stream.deinit();
    const error_event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, error_event.event_type);
    try std.testing.expect(error_event.message != null);
    try std.testing.expect(error_event.error_message != null);
    try std.testing.expect(error_event.error_message.?.len > 0);
    try std.testing.expectEqual(types.StopReason.error_reason, error_event.message.?.stop_reason);
    try std.testing.expectEqualStrings("bedrock-converse-stream", error_event.message.?.api);
    try std.testing.expectEqualStrings("amazon-bedrock", error_event.message.?.provider);
    try std.testing.expectEqualStrings("anthropic.claude-3-7-sonnet-20250219-v1:0", error_event.message.?.model);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(error_event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}
