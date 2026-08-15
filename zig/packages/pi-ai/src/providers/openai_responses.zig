const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const resolve_api_key = @import("../shared/resolve_api_key.zig");
const model_registry = @import("../model_registry.zig");
const abort_helper = @import("../shared/abort_signal.zig");
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
const responses_api = @import("../shared/responses_api.zig");
const openai_usage = @import("../shared/openai_usage.zig");
const shared_url = @import("../shared/url.zig");
const cloudflare = @import("cloudflare.zig");
const openai = @import("openai.zig");
const copilot_headers = @import("github_copilot_headers.zig");
const test_stream_server = @import("test_stream_server.zig");

const CurrentBlock = responses_api.CurrentBlock;
const deinitCurrentBlock = responses_api.deinitCurrentBlock;
const extractMessageText = responses_api.extractMessageText;
const extractReasoningSummary = responses_api.extractReasoningSummary;
const finalizeCurrentBlock = responses_api.finalizeCurrentBlock;
const updateCurrentMessagePart = responses_api.updateCurrentMessagePart;

const ToolCallRef = struct {
    output_index: ?usize = null,
    item_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
};

const ActiveToolCallBlock = struct {
    event_index: usize,
    output_index: ?usize,
    item_id: ?[]const u8,
    call_id: ?[]const u8,
    id: ?[]const u8,
    name: ?[]const u8,
    partial_json: std.ArrayList(u8),
};

const PendingFinalizedToolCallBlock = struct {
    event_index: usize,
    tool_call: types.ToolCall,
};

const ContinuationAnchor = struct {
    response_id: []const u8,
    message_start_index: usize,
};

const ResponsesCompat = struct {
    send_session_id_header: bool = true,
    supports_long_cache_retention: bool = true,
};

pub const OpenAIResponsesProvider = struct {
    pub const api = "openai-responses";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        if (provider_error.isAbortRequested(options)) {
            provider_stream.emitSetupRuntimeFailure(&stream_instance, model, options, error.RequestAborted);
            return stream_instance;
        }

        try provider_stream.runSetupOrEmit(streamProduction, .{ allocator, io, model, context, options, &stream_instance }, &stream_instance, model, options);
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

        const resolved = try resolve_api_key.resolveApiKey(allocator, model, options);
        defer if (resolved) |r| r.deinit(allocator);

        if (resolved == null) {
            try resolve_api_key.pushMissingApiKeyError(allocator, stream_instance, model);
            return;
        }

        const api_key = resolved.?.key;

        const resolved_base_url = try cloudflare.resolveBaseUrlOrNull(allocator, model);
        defer if (resolved_base_url) |base_url| allocator.free(base_url);

        const url = try buildRequestUrl(allocator, resolved_base_url orelse model.base_url);
        defer allocator.free(url);

        var resolved_options = if (options) |stream_options| stream_options else types.StreamOptions{};
        resolved_options.api_key = api_key;

        var headers = try buildRequestHeaders(allocator, model, context, resolved_options);
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

fn buildRequestHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: types.StreamOptions,
) !std.StringHashMap([]const u8) {
    const api_key = options.api_key orelse return error.MissingApiKey;
    const compat = getCompat(model);
    const cache_retention = resolveCacheRetention(options.cache_retention, processCacheRetentionEnv());

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Content-Type", "application/json");
    try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Accept", "application/json");
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(authorization);
    if (std.mem.eql(u8, model.provider, "cloudflare-ai-gateway")) {
        try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "cf-aig-authorization", authorization);
    } else {
        try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Authorization", authorization);
    }
    try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, model.headers);

    if (std.mem.eql(u8, model.provider, "github-copilot")) {
        try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "X-Initiator", copilot_headers.inferCopilotInitiator(context.messages));
        try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Openai-Intent", "conversation-edits");
        if (copilot_headers.hasCopilotVisionInput(context.messages)) {
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "Copilot-Vision-Request", "true");
        }
    }

    if (options.session_id) |session_id| {
        if (cache_retention != .none) {
            try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "x-client-request-id", session_id);
            if (compat.send_session_id_header) {
                try provider_stream.putOwnedHeaderCaseInsensitive(allocator, &headers, "session_id", session_id);
            }
        }
    }
    try provider_stream.mergeHeadersCaseInsensitive(allocator, &headers, options.headers);

    return headers;
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

    var active_tool_calls = std.ArrayList(ActiveToolCallBlock).empty;
    defer {
        for (active_tool_calls.items) |*tool_call| {
            deinitActiveToolCallBlock(allocator, tool_call);
        }
        active_tool_calls.deinit(allocator);
    }

    var pending_tool_calls = std.ArrayList(PendingFinalizedToolCallBlock).empty;
    defer {
        for (pending_tool_calls.items) |pending| {
            freeToolCallOwned(allocator, pending.tool_call);
        }
        pending_tool_calls.deinit(allocator);
    }

    stream_ptr.push(.{ .event_type = .start });

    const request_service_tier: ?[]const u8 = if (options) |stream_options|
        stream_options.providerOptions("responses").service_tier
    else
        null;
    var response_service_tier: ?[]const u8 = null;

    var handler = OpenAIResponsesSseLoopHandler{
        .allocator = allocator,
        .stream_ptr = stream_ptr,
        .output = &output,
        .current_block = &current_block,
        .active_tool_calls = &active_tool_calls,
        .pending_tool_calls = &pending_tool_calls,
        .content_blocks = &content_blocks,
        .tool_calls = &tool_calls,
        .model = model,
        .request_service_tier = request_service_tier,
        .response_service_tier = &response_service_tier,
    };
    const loop_result = try sse_loop.run(OpenAIResponsesSseLoopHandler, &handler, streaming, options);
    if (loop_result == .stopped and !handler.normal_completion) {
        return;
    }

    try finalizeCurrentBlock(allocator, null, &current_block, &content_blocks, &tool_calls, stream_ptr);
    try flushPendingFinalizedToolCalls(allocator, &pending_tool_calls, &content_blocks, &tool_calls);
    try finalizeActiveToolCalls(allocator, &active_tool_calls, &pending_tool_calls, &content_blocks, &tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, &output, .{ .content_blocks = &content_blocks, .tool_calls = &tool_calls }, .{ .content_transfer = .always, .total_tokens = .preserve_or_full_usage, .coerce_stop_reason_for_tool_calls = true });
    // Tool calls live inline in output.content; legacy field intentionally null.

    finalize.calculateCost(model, &output.usage);
    const effective_service_tier = response_service_tier orelse request_service_tier;
    applyServiceTierPricing(&output.usage, effective_service_tier, model);

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

const OpenAIResponsesSseDataResult = enum {
    continue_loop,
    complete_loop,
    stop_loop,
};

const OpenAIResponsesSseLoopHandler = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    request_service_tier: ?[]const u8,
    response_service_tier: *?[]const u8,
    normal_completion: bool = false,

    pub fn extractDataLine(_: *OpenAIResponsesSseLoopHandler, line: []const u8) ?[]const u8 {
        return provider_stream.parseCanonicalSseDataLine(line);
    }

    pub fn isDoneData(_: *OpenAIResponsesSseLoopHandler, data: []const u8) bool {
        return std.mem.eql(u8, data, "[DONE]");
    }

    pub fn handleData(self: *OpenAIResponsesSseLoopHandler, data: []const u8) !bool {
        var state = OpenAIResponsesSseState{
            .allocator = self.allocator,
            .stream_ptr = self.stream_ptr,
            .output = self.output,
            .current_block = self.current_block,
            .active_tool_calls = self.active_tool_calls,
            .pending_tool_calls = self.pending_tool_calls,
            .content_blocks = self.content_blocks,
            .tool_calls = self.tool_calls,
            .model = self.model,
            .request_service_tier = self.request_service_tier,
            .response_service_tier = self.response_service_tier,
        };
        const result = try processOpenAIResponsesSseData(&state, data);
        switch (result) {
            .continue_loop => return true,
            .complete_loop => {
                self.normal_completion = true;
                return false;
            },
            .stop_loop => return false,
        }
    }

    pub fn handleRuntimeFailure(self: *OpenAIResponsesSseLoopHandler, err: anyerror) !void {
        try emitRuntimeFailure(
            self.allocator,
            self.stream_ptr,
            self.output,
            self.current_block,
            self.active_tool_calls,
            self.pending_tool_calls,
            self.content_blocks,
            self.tool_calls,
            err,
        );
    }
};

const OpenAIResponsesSseState = struct {
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    request_service_tier: ?[]const u8,
    response_service_tier: *?[]const u8,
};

fn processOpenAIResponsesSseData(state: *OpenAIResponsesSseState, data: []const u8) !OpenAIResponsesSseDataResult {
    const allocator = state.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try emitRuntimeFailure(allocator, state.stream_ptr, state.output, state.current_block, state.active_tool_calls, state.pending_tool_calls, state.content_blocks, state.tool_calls, err);
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
        try handleOutputItemAdded(allocator, value, item_value, state.current_block, state.active_tool_calls, state.pending_tool_calls, state.content_blocks, state.stream_ptr);
        return .continue_loop;
    }

    if (try handleOpenAIResponsesReasoningEvent(state, event_type, value)) |result| return result;
    if (try handleOpenAIResponsesTextEvent(state, event_type, value)) |result| return result;
    if (try handleOpenAIResponsesToolEvent(state, event_type, value)) |result| return result;

    if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
        if (value.object.get("response")) |response_value| {
            try updateCompletedResponse(allocator, state.output, response_value, state.model, state.response_service_tier);
        }
        return .complete_loop;
    }

    if (std.mem.eql(u8, event_type, "response.failed")) {
        const error_message = try extractFailureMessage(allocator, value.object.get("response"));
        try emitOpenAIResponsesTerminalError(state, error_message);
        return .stop_loop;
    }

    if (std.mem.eql(u8, event_type, "error")) {
        const error_message = try extractTopLevelErrorMessage(allocator, value);
        try emitOpenAIResponsesTerminalError(state, error_message);
        return .stop_loop;
    }

    return .continue_loop;
}

fn handleOpenAIResponsesReasoningEvent(
    state: *OpenAIResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?OpenAIResponsesSseDataResult {
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        try appendOpenAIResponsesThinkingDelta(state, delta_value.string);
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
        try appendOpenAIResponsesThinkingDelta(state, delta_value.string);
        return .continue_loop;
    }

    return null;
}

fn appendOpenAIResponsesThinkingDelta(state: *OpenAIResponsesSseState, delta: []const u8) !void {
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

fn handleOpenAIResponsesTextEvent(
    state: *OpenAIResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?OpenAIResponsesSseDataResult {
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

fn handleOpenAIResponsesToolEvent(
    state: *OpenAIResponsesSseState,
    event_type: []const u8,
    value: std.json.Value,
) !?OpenAIResponsesSseDataResult {
    const allocator = state.allocator;
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const delta_value = value.object.get("delta") orelse return .continue_loop;
        if (delta_value != .string) return .continue_loop;
        const ref = extractToolCallRef(value, null);
        const tool_call = try ensureActiveToolCall(allocator, state.active_tool_calls, state.stream_ptr, nextToolCallContentIndex(state.content_blocks, state.pending_tool_calls, state.current_block), ref, null);
        try tool_call.partial_json.appendSlice(allocator, delta_value.string);
        state.stream_ptr.push(.{
            .event_type = .toolcall_delta,
            .content_index = @intCast(tool_call.event_index),
            .delta = try allocator.dupe(u8, delta_value.string),
            .owns_delta = true,
        });
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
        const arguments_value = value.object.get("arguments") orelse return .continue_loop;
        if (arguments_value != .string) return .continue_loop;
        const ref = extractToolCallRef(value, null);
        const tool_call = try ensureActiveToolCall(allocator, state.active_tool_calls, state.stream_ptr, nextToolCallContentIndex(state.content_blocks, state.pending_tool_calls, state.current_block), ref, null);
        try replaceDoneToolArguments(state, tool_call, arguments_value.string);
        return .continue_loop;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item_value = value.object.get("item") orelse return .continue_loop;
        if (isFunctionCallItem(item_value)) {
            try finalizeActiveToolCallForItem(allocator, value, item_value, state.active_tool_calls, state.pending_tool_calls, state.content_blocks, state.tool_calls, state.stream_ptr, nextToolCallContentIndex(state.content_blocks, state.pending_tool_calls, state.current_block));
        } else {
            try finalizeCurrentBlock(allocator, item_value, state.current_block, state.content_blocks, state.tool_calls, state.stream_ptr);
            try flushPendingFinalizedToolCalls(allocator, state.pending_tool_calls, state.content_blocks, state.tool_calls);
        }
        return .continue_loop;
    }

    return null;
}

fn replaceDoneToolArguments(
    state: *OpenAIResponsesSseState,
    tool_call: *ActiveToolCallBlock,
    arguments: []const u8,
) !void {
    const previous = tool_call.partial_json.items;
    if (std.mem.startsWith(u8, arguments, previous)) {
        const delta = arguments[previous.len..];
        tool_call.partial_json.clearRetainingCapacity();
        try tool_call.partial_json.appendSlice(state.allocator, arguments);
        if (delta.len > 0) {
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
}

fn emitOpenAIResponsesTerminalError(state: *OpenAIResponsesSseState, error_message: []const u8) !void {
    try finalizeOutputFromPartials(state.allocator, state.output, state.current_block, state.active_tool_calls, state.pending_tool_calls, state.content_blocks, state.tool_calls, state.stream_ptr);
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
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    try finalizeCurrentBlock(allocator, null, current_block, content_blocks, tool_calls, stream_ptr);
    try flushPendingFinalizedToolCalls(allocator, pending_tool_calls, content_blocks, tool_calls);
    try finalizeActiveToolCalls(allocator, active_tool_calls, pending_tool_calls, content_blocks, tool_calls, stream_ptr);
    try finalize.finalizeOutput(allocator, output, .{ .content_blocks = content_blocks, .tool_calls = tool_calls }, .{ .content_transfer = .when_output_empty, .total_tokens = .preserve, .coerce_stop_reason_for_tool_calls = false });
    // Tool calls live inline in output.content; legacy field intentionally null.
    // tool_calls is borrow-only bookkeeping.
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, active_tool_calls, pending_tool_calls, content_blocks, tool_calls, stream_ptr);
    provider_error.emitTerminalRuntimeFailure(stream_ptr, output, err);
}

fn handleOutputItemAdded(
    allocator: std.mem.Allocator,
    event_value: std.json.Value,
    item_value: std.json.Value,
    current_block: *?CurrentBlock,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (item_value != .object) return;
    const item_type_value = item_value.object.get("type") orelse return;
    if (item_type_value != .string) return;

    if (std.mem.eql(u8, item_type_value.string, "reasoning")) {
        if (current_block.* != null) return;
        current_block.* = .{ .thinking = .{
            .event_index = content_blocks.items.len,
            .text = std.ArrayList(u8).empty,
            .signature = null,
        } };
        stream_ptr.push(.{ .event_type = .thinking_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type_value.string, "message")) {
        if (current_block.* != null) return;
        current_block.* = .{ .text = .{
            .event_index = content_blocks.items.len,
            .text = std.ArrayList(u8).empty,
            .part_kind = .output_text,
        } };
        stream_ptr.push(.{ .event_type = .text_start, .content_index = @intCast(content_blocks.items.len) });
        return;
    }

    if (std.mem.eql(u8, item_type_value.string, "function_call")) {
        const ref = extractToolCallRef(event_value, item_value);
        const tool_call = try ensureActiveToolCall(allocator, active_tool_calls, stream_ptr, nextToolCallContentIndex(content_blocks, pending_tool_calls, current_block), ref, item_value);
        if (item_value.object.get("arguments")) |arguments_value| {
            if (arguments_value == .string and arguments_value.string.len > 0) {
                try tool_call.partial_json.appendSlice(allocator, arguments_value.string);
            }
        }
    }
}

fn deinitActiveToolCallBlock(allocator: std.mem.Allocator, block: *ActiveToolCallBlock) void {
    if (block.item_id) |value| allocator.free(value);
    if (block.call_id) |value| allocator.free(value);
    if (block.id) |value| allocator.free(value);
    if (block.name) |value| allocator.free(value);
    block.partial_json.deinit(allocator);
}

fn isFunctionCallItem(item_value: std.json.Value) bool {
    if (item_value != .object) return false;
    const item_type_value = item_value.object.get("type") orelse return false;
    return item_type_value == .string and std.mem.eql(u8, item_type_value.string, "function_call");
}

fn extractToolCallRef(event_value: std.json.Value, maybe_item_value: ?std.json.Value) ToolCallRef {
    var ref = ToolCallRef{};
    if (event_value == .object) {
        if (event_value.object.get("output_index")) |index_value| {
            if (index_value == .integer and index_value.integer >= 0) ref.output_index = @intCast(index_value.integer);
        }
        if (extractStringField(event_value, "item_id")) |item_id| ref.item_id = item_id;
        if (extractStringField(event_value, "call_id")) |call_id| ref.call_id = call_id;
    }
    if (maybe_item_value) |item_value| {
        if (item_value == .object) {
            if (ref.item_id == null) ref.item_id = extractStringField(item_value, "id");
            if (ref.call_id == null) ref.call_id = extractStringField(item_value, "call_id");
        }
    }
    return ref;
}

fn matchesToolCallRef(block: ActiveToolCallBlock, ref: ToolCallRef) bool {
    if (ref.output_index) |output_index| {
        if (block.output_index != null and block.output_index.? == output_index) return true;
    }
    if (ref.item_id) |item_id| {
        if (block.item_id) |block_item_id| {
            if (std.mem.eql(u8, block_item_id, item_id)) return true;
        }
    }
    if (ref.call_id) |call_id| {
        if (block.call_id) |block_call_id| {
            if (std.mem.eql(u8, block_call_id, call_id)) return true;
        }
    }
    return false;
}

fn updateToolCallRef(
    allocator: std.mem.Allocator,
    block: *ActiveToolCallBlock,
    ref: ToolCallRef,
    maybe_item_value: ?std.json.Value,
) !void {
    if (block.output_index == null) block.output_index = ref.output_index;
    if (block.item_id == null) {
        if (ref.item_id) |item_id| block.item_id = try allocator.dupe(u8, item_id);
    }
    if (block.call_id == null) {
        if (ref.call_id) |call_id| block.call_id = try allocator.dupe(u8, call_id);
    }
    if (maybe_item_value) |item_value| {
        if (item_value == .object) {
            if (block.id == null) block.id = try extractCombinedToolCallId(allocator, item_value);
            if (block.name == null) block.name = try extractOwnedStringField(allocator, item_value, "name");
        }
    }
}

fn ensureActiveToolCall(
    allocator: std.mem.Allocator,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    ref: ToolCallRef,
    maybe_item_value: ?std.json.Value,
) !*ActiveToolCallBlock {
    for (active_tool_calls.items) |*tool_call| {
        if (matchesToolCallRef(tool_call.*, ref)) {
            try updateToolCallRef(allocator, tool_call, ref, maybe_item_value);
            return tool_call;
        }
    }

    if (ref.output_index == null and ref.item_id == null and ref.call_id == null and active_tool_calls.items.len == 1) {
        const tool_call = &active_tool_calls.items[0];
        try updateToolCallRef(allocator, tool_call, ref, maybe_item_value);
        return tool_call;
    }

    const event_index = completed_count + active_tool_calls.items.len;
    try active_tool_calls.append(allocator, .{
        .event_index = event_index,
        .output_index = ref.output_index,
        .item_id = if (ref.item_id) |item_id| try allocator.dupe(u8, item_id) else null,
        .call_id = if (ref.call_id) |call_id| try allocator.dupe(u8, call_id) else null,
        .id = null,
        .name = null,
        .partial_json = std.ArrayList(u8).empty,
    });
    const tool_call = &active_tool_calls.items[active_tool_calls.items.len - 1];
    try updateToolCallRef(allocator, tool_call, ref, maybe_item_value);
    stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(event_index) });
    return tool_call;
}

fn nextToolCallContentIndex(
    content_blocks: *std.ArrayList(types.ContentBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    current_block: *?CurrentBlock,
) usize {
    return content_blocks.items.len + pending_tool_calls.items.len + if (current_block.* != null) @as(usize, 1) else 0;
}

fn finalizeActiveToolCallAt(
    allocator: std.mem.Allocator,
    index: usize,
    maybe_item_value: ?std.json.Value,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    var tool_call = active_tool_calls.orderedRemove(index);
    defer deinitActiveToolCallBlock(allocator, &tool_call);

    if (maybe_item_value) |item_value| {
        try updateToolCallRef(allocator, &tool_call, extractToolCallRef(.null, item_value), item_value);
    }

    const final_id = tool_call.id orelse "";
    const final_name = tool_call.name orelse "";
    const arguments = if (maybe_item_value) |item_value| blk: {
        if (item_value == .object) {
            if (item_value.object.get("arguments")) |arguments_value| {
                if (arguments_value == .object or arguments_value == .array) {
                    break :blk try provider_json.cloneValue(allocator, arguments_value);
                }
                if (arguments_value == .string) {
                    break :blk try parseStreamingJsonToValue(allocator, arguments_value.string);
                }
            }
        }
        break :blk try parseStreamingJsonToValue(allocator, tool_call.partial_json.items);
    } else try parseStreamingJsonToValue(allocator, tool_call.partial_json.items);

    const stored_tool_call = blk: {
        errdefer provider_json.freeValue(allocator, arguments);
        const id = try allocator.dupe(u8, final_id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, final_name);
        errdefer allocator.free(name);
        break :blk types.ToolCall{
            .id = id,
            .name = name,
            .arguments = arguments,
        };
    };
    var stored_tool_call_owned = true;
    errdefer if (stored_tool_call_owned) freeToolCallOwned(allocator, stored_tool_call);

    if (tool_call.event_index == content_blocks.items.len) {
        try appendFinalizedToolCallCopies(allocator, stored_tool_call, content_blocks, tool_calls);
        try flushPendingFinalizedToolCalls(allocator, pending_tool_calls, content_blocks, tool_calls);
    } else {
        const pending_tool_call = try cloneToolCallOwned(allocator, stored_tool_call);
        var pending_tool_call_transferred = false;
        errdefer if (!pending_tool_call_transferred) freeToolCallOwned(allocator, pending_tool_call);
        try pending_tool_calls.append(allocator, .{
            .event_index = tool_call.event_index,
            .tool_call = pending_tool_call,
        });
        pending_tool_call_transferred = true;
    }
    stream_ptr.push(.{
        .event_type = .toolcall_end,
        .content_index = @intCast(tool_call.event_index),
        .tool_call = .{
            .id = try allocator.dupe(u8, stored_tool_call.id),
            .name = try allocator.dupe(u8, stored_tool_call.name),
            .arguments = try provider_json.cloneValue(allocator, stored_tool_call.arguments),
        },
    });
    stored_tool_call_owned = false;
    freeToolCallOwned(allocator, stored_tool_call);
}

fn finalizeActiveToolCallForItem(
    allocator: std.mem.Allocator,
    event_value: std.json.Value,
    item_value: std.json.Value,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
) !void {
    const ref = extractToolCallRef(event_value, item_value);
    var index: usize = 0;
    while (index < active_tool_calls.items.len) : (index += 1) {
        if (matchesToolCallRef(active_tool_calls.items[index], ref)) {
            try finalizeActiveToolCallAt(allocator, index, item_value, active_tool_calls, pending_tool_calls, content_blocks, tool_calls, stream_ptr);
            return;
        }
    }

    _ = try ensureActiveToolCall(allocator, active_tool_calls, stream_ptr, completed_count, ref, item_value);
    try finalizeActiveToolCallAt(allocator, active_tool_calls.items.len - 1, item_value, active_tool_calls, pending_tool_calls, content_blocks, tool_calls, stream_ptr);
}

fn finalizeActiveToolCalls(
    allocator: std.mem.Allocator,
    active_tool_calls: *std.ArrayList(ActiveToolCallBlock),
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    while (active_tool_calls.items.len > 0) {
        try finalizeActiveToolCallAt(allocator, 0, null, active_tool_calls, pending_tool_calls, content_blocks, tool_calls, stream_ptr);
    }
    try flushPendingFinalizedToolCalls(allocator, pending_tool_calls, content_blocks, tool_calls);
}

fn appendFinalizedToolCallCopies(
    allocator: std.mem.Allocator,
    source: types.ToolCall,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
) !void {
    const owned = try cloneToolCallOwned(allocator, source);
    try finalize.appendInlineToolCall(allocator, content_blocks, tool_calls, owned);
}

fn flushPendingFinalizedToolCalls(
    allocator: std.mem.Allocator,
    pending_tool_calls: *std.ArrayList(PendingFinalizedToolCallBlock),
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
) !void {
    while (true) {
        var pending_index: ?usize = null;
        for (pending_tool_calls.items, 0..) |pending, index| {
            if (pending.event_index == content_blocks.items.len) {
                pending_index = index;
                break;
            }
        }

        const index = pending_index orelse return;
        const pending = pending_tool_calls.orderedRemove(index);
        errdefer freeToolCallOwned(allocator, pending.tool_call);
        try appendFinalizedToolCallCopies(allocator, pending.tool_call, content_blocks, tool_calls);
        freeToolCallOwned(allocator, pending.tool_call);
    }
}

fn findContinuationAnchor(context: types.Context, model: types.Model) ?ContinuationAnchor {
    if (context.messages.len < 2) return null;

    var index = context.messages.len;
    while (index > 0) {
        index -= 1;
        const message = context.messages[index];
        switch (message) {
            .assistant => |assistant| {
                if (!types.shouldReplayAssistantInProviderContext(assistant)) continue;
                if (assistant.response_id == null) continue;
                if (!std.mem.eql(u8, assistant.provider, model.provider)) continue;
                if (!std.mem.eql(u8, assistant.api, model.api)) continue;
                if (index + 1 >= context.messages.len) continue;
                if (!continuationMessagesAreCompatible(context.messages[index + 1 ..])) continue;
                return .{
                    .response_id = assistant.response_id.?,
                    .message_start_index = index + 1,
                };
            },
            else => {},
        }
    }

    return null;
}

fn continuationMessagesAreCompatible(messages: []const types.Message) bool {
    if (messages.len == 0) return false;
    for (messages) |message| {
        if (message == .assistant and types.shouldReplayAssistantInProviderContext(message.assistant)) return false;
    }
    return true;
}

// =============================================================================
// Declarative payload structs for Responses API.
//
// The Responses API has many input-item shapes (system message, user message,
// assistant message, opaque thinking-signature value, function_call,
// function_call_output {text|parts}). We model them as a tagged union with a
// custom jsonStringify that emits the right field set for each variant.
// =============================================================================

const RequestPayload = struct {
    model: []const u8,
    input: []const InputItem,
    stream: bool = true,
    store: bool = false,
    max_output_tokens: ?u32 = null,
    temperature: ?f32 = null,
    metadata: ?std.json.Value = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_retention: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    reasoning: ?ReasoningConfig = null,
    include: ?[]const []const u8 = null,
    tools: ?[]const ToolItem = null,
};

const ReasoningConfig = struct {
    effort: []const u8,
    summary: ?[]const u8 = null,
};

const ToolItem = struct {
    type: []const u8 = "function",
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value, // cloned
    strict: bool = false,
};

const ContentPart = union(enum) {
    input_text: TextPart,
    input_image: ImagePart,

    pub fn jsonStringify(self: ContentPart, jw: anytype) !void {
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

const TextPart = struct { text: []const u8 };
const ImagePart = struct { image_url: []const u8 };

const AssistantOutputPart = struct {
    text: []const u8,
};

const InputItem = union(enum) {
    system_message: SystemMessageItem,
    user_message: UserMessageItem,
    assistant_message: AssistantMessageItem,
    passthrough_value: std.json.Value, // for opaque thinking-signature trees
    function_call: FunctionCallItem,
    function_call_output_text: FunctionCallOutputTextItem,
    function_call_output_parts: FunctionCallOutputPartsItem,

    pub fn jsonStringify(self: InputItem, jw: anytype) !void {
        switch (self) {
            .system_message => |m| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write(m.role);
                try jw.objectField("content");
                try jw.write(m.content);
                try jw.endObject();
            },
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
                if (m.phase) |phase| {
                    try jw.objectField("phase");
                    try jw.write(phase);
                }
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
            .passthrough_value => |v| {
                try jw.write(v);
            },
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

const SystemMessageItem = struct {
    role: []const u8, // "system" or "developer"
    content: []const u8, // sanitized
};

const UserMessageItem = struct {
    content: []const ContentPart,
};

const AssistantMessageItem = struct {
    id: []const u8,
    phase: ?[]const u8 = null,
    text: []const u8, // sanitized
};

const FunctionCallItem = struct {
    call_id: []const u8,
    id: ?[]const u8 = null,
    name: []const u8,
    arguments: []const u8, // pre-stringified JSON
};

const FunctionCallOutputTextItem = struct {
    call_id: []const u8,
    output: []const u8, // sanitized or "(see attached image)" or ""
};

const FunctionCallOutputPartsItem = struct {
    call_id: []const u8,
    parts: []const ContentPart,
};

const OwnedPayload = struct {
    allocator: std.mem.Allocator,
    payload: RequestPayload,
    input_buf: []InputItem,
    tools_buf: ?[]ToolItem,
    content_lists: []const []ContentPart,
    owned_strings: []const []const u8,
    owned_values: []std.json.Value,
    metadata_clone: ?std.json.Value,
    include_buf: ?[][]const u8,

    fn deinit(self: OwnedPayload) void {
        self.allocator.free(self.input_buf);
        if (self.tools_buf) |b| self.allocator.free(b);
        for (self.content_lists) |list| self.allocator.free(list);
        self.allocator.free(self.content_lists);
        for (self.owned_strings) |s| self.allocator.free(s);
        self.allocator.free(self.owned_strings);
        for (self.owned_values) |v| provider_json.freeValue(self.allocator, v);
        self.allocator.free(self.owned_values);
        if (self.metadata_clone) |v| provider_json.freeValue(self.allocator, v);
        if (self.include_buf) |b| self.allocator.free(b);
    }
};

const OwnedPayloadBuilder = struct {
    allocator: std.mem.Allocator,
    content_lists: std.ArrayList([]ContentPart) = .empty,
    owned_strings: std.ArrayList([]const u8) = .empty,
    owned_values: std.ArrayList(std.json.Value) = .empty,

    fn deinit(self: *OwnedPayloadBuilder) void {
        for (self.content_lists.items) |list| self.allocator.free(list);
        self.content_lists.deinit(self.allocator);
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
        for (self.owned_values.items) |v| provider_json.freeValue(self.allocator, v);
        self.owned_values.deinit(self.allocator);
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

    const compat = getCompat(model);
    const cache_retention = resolveOptionsCacheRetention(options, processCacheRetentionEnv());

    var input_list = std.ArrayList(InputItem).empty;
    errdefer input_list.deinit(allocator);

    if (context.system_prompt) |system_prompt| {
        const sanitized = try openai.sanitizeSurrogates(allocator, system_prompt);
        try builder.owned_strings.append(allocator, sanitized);
        try input_list.append(allocator, .{ .system_message = .{
            .role = if (model.reasoning) "developer" else "system",
            .content = sanitized,
        } });
    }

    var normalized_tool_call_ids = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = normalized_tool_call_ids.iterator();
        while (iterator.next()) |entry| allocator.free(entry.value_ptr.*);
        normalized_tool_call_ids.deinit();
    }

    var replay_message_index: usize = 0;
    for (context.messages) |message| {
        const appended = try appendInputItems(allocator, &input_list, model, message, replay_message_index, &normalized_tool_call_ids, &builder);
        if (appended) replay_message_index += 1;
    }

    const input_buf = try input_list.toOwnedSlice(allocator);
    errdefer allocator.free(input_buf);

    // Optional top-level fields.
    var max_output_tokens: ?u32 = null;
    var temperature: ?f32 = null;
    var metadata_clone: ?std.json.Value = null;
    var prompt_cache_key: ?[]const u8 = null;
    var prompt_cache_retention: ?[]const u8 = null;
    var service_tier: ?[]const u8 = null;
    var reasoning: ?ReasoningConfig = null;
    var include_buf: ?[][]const u8 = null;

    if (options) |stream_options| {
        if (stream_options.max_tokens) |m| max_output_tokens = @intCast(m);
        temperature = stream_options.temperature;
        if (stream_options.metadata) |metadata| {
            const cloned = try provider_json.cloneValue(allocator, metadata);
            metadata_clone = cloned;
        }
        if (stream_options.session_id) |session_id| {
            if (cache_retention != .none) prompt_cache_key = session_id;
            if (cache_retention == .long and compat.supports_long_cache_retention) {
                prompt_cache_retention = "24h";
            }
        }
        const responses_opts = stream_options.providerOptions("responses");
        if (responses_opts.service_tier) |st| service_tier = st;
        if (model.reasoning) {
            if (responses_opts.reasoning_effort != null or responses_opts.reasoning_summary != null) {
                const effort = if (responses_opts.reasoning_effort) |re|
                    model_registry.mappedThinkingLevelValue(model, modelThinkingLevel(re)) orelse @tagName(re)
                else
                    "medium";
                const summary = responses_opts.reasoning_summary orelse "auto";
                reasoning = .{ .effort = effort, .summary = summary };

                const buf = try allocator.alloc([]const u8, 1);
                errdefer allocator.free(buf);
                buf[0] = "reasoning.encrypted_content";
                include_buf = buf;
            } else if (!std.mem.eql(u8, model.provider, "github-copilot") and model_registry.thinkingLevelSupported(model, .off)) {
                reasoning = .{ .effort = model_registry.mappedThinkingLevelValue(model, .off) orelse "none" };
            }
        }
    }
    if (options == null and model.reasoning and !std.mem.eql(u8, model.provider, "github-copilot") and model_registry.thinkingLevelSupported(model, .off)) {
        reasoning = .{ .effort = model_registry.mappedThinkingLevelValue(model, .off) orelse "none" };
    }
    errdefer if (include_buf) |b| allocator.free(b);

    // Tools.
    var tools_buf: ?[]ToolItem = null;
    if (context.tools) |tools| if (tools.len > 0) {
        const buf = try allocator.alloc(ToolItem, tools.len);
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
            .max_output_tokens = max_output_tokens,
            .temperature = temperature,
            .metadata = metadata_clone,
            .prompt_cache_key = prompt_cache_key,
            .prompt_cache_retention = prompt_cache_retention,
            .service_tier = service_tier,
            .reasoning = reasoning,
            .include = include_buf,
            .tools = tools_buf,
        },
        .input_buf = input_buf,
        .tools_buf = tools_buf,
        .content_lists = content_lists_slice,
        .owned_strings = owned_strings_slice,
        .owned_values = owned_values_slice,
        .metadata_clone = metadata_clone,
        .include_buf = include_buf,
    };
}

fn appendInputItems(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(InputItem),
    model: types.Model,
    message: types.Message,
    message_index: usize,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
    builder: *OwnedPayloadBuilder,
) !bool {
    switch (message) {
        .user => |user| {
            return try appendUserInputItem(allocator, input_list, model, user, builder);
        },
        .assistant => |assistant| {
            if (!types.shouldReplayAssistantInProviderContext(assistant)) return false;
            return try appendAssistantInputItemsStruct(allocator, input_list, model, assistant, message_index, normalized_tool_call_ids, builder);
        },
        .tool_result => |tool_result| {
            try appendToolResultInputItem(allocator, input_list, model, tool_result, normalized_tool_call_ids, builder);
            return true;
        },
    }
}

fn appendUserInputItem(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(InputItem),
    model: types.Model,
    user: types.UserMessage,
    builder: *OwnedPayloadBuilder,
) !bool {
    const supports_images = modelSupportsImages(model);
    var parts = std.ArrayList(ContentPart).empty;
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

    if (parts.items.len == 0) {
        parts.deinit(allocator);
        return false;
    }
    const slice = try parts.toOwnedSlice(allocator);
    errdefer allocator.free(slice);
    try builder.content_lists.append(allocator, slice);
    try input_list.append(allocator, .{ .user_message = .{ .content = slice } });
    return true;
}

fn appendAssistantInputItemsStruct(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(InputItem),
    model: types.Model,
    assistant: types.AssistantMessage,
    message_index: usize,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
    builder: *OwnedPayloadBuilder,
) !bool {
    const is_same_provider_api =
        std.mem.eql(u8, assistant.provider, model.provider) and
        std.mem.eql(u8, assistant.api, model.api);
    const is_same_model =
        is_same_provider_api and
        std.mem.eql(u8, assistant.model, model.id);
    const is_different_model_same_provider_api = is_same_provider_api and !is_same_model;
    const start_len = input_list.items.len;

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
                const sanitized = try openai.sanitizeSurrogates(allocator, text.text);
                try builder.owned_strings.append(allocator, sanitized);

                const parsed_signature = if (is_same_model)
                    try parseTextSignature(allocator, text.text_signature, message_index)
                else
                    try parseTextSignature(allocator, null, message_index);
                try builder.owned_strings.append(allocator, parsed_signature.id);
                const phase_opt = parsed_signature.phase;
                if (phase_opt) |phase| try builder.owned_strings.append(allocator, phase);

                try input_list.append(allocator, .{ .assistant_message = .{
                    .id = parsed_signature.id,
                    .phase = phase_opt,
                    .text = sanitized,
                } });
            },
            .image => {},
            .tool_call => {},
        }
    }

    const tool_calls_source = if (types.hasInlineToolCalls(assistant))
        try types.collectAssistantToolCalls(allocator, assistant)
    else
        null;
    defer if (tool_calls_source) |calls| allocator.free(calls);

    if (tool_calls_source orelse assistant.tool_calls) |tool_calls| {
        for (tool_calls) |tool_call| {
            const normalized_id = if (is_same_model)
                try allocator.dupe(u8, tool_call.id)
            else
                try normalizeToolCallId(allocator, tool_call.id, model, assistant);
            defer allocator.free(normalized_id);
            if (!std.mem.eql(u8, tool_call.id, normalized_id)) {
                if (normalized_tool_call_ids.get(tool_call.id)) |existing| {
                    allocator.free(existing);
                }
                try normalized_tool_call_ids.put(tool_call.id, try allocator.dupe(u8, normalized_id));
            }
            const split = splitToolCallId(normalized_id);
            const call_id_owned = try allocator.dupe(u8, split.call_id);
            try builder.owned_strings.append(allocator, call_id_owned);

            var id_owned: ?[]const u8 = null;
            if (split.item_id) |item_id| {
                if (!(is_different_model_same_provider_api and std.mem.startsWith(u8, item_id, "fc_"))) {
                    const dup = try allocator.dupe(u8, item_id);
                    try builder.owned_strings.append(allocator, dup);
                    id_owned = dup;
                }
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

    return input_list.items.len > start_len;
}

fn appendToolResultInputItem(
    allocator: std.mem.Allocator,
    input_list: *std.ArrayList(InputItem),
    model: types.Model,
    tool_result: types.ToolResultMessage,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
    builder: *OwnedPayloadBuilder,
) !void {
    const normalized_id = normalized_tool_call_ids.get(tool_result.tool_call_id) orelse tool_result.tool_call_id;
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

    const call_id_owned = try allocator.dupe(u8, splitToolCallId(normalized_id).call_id);
    try builder.owned_strings.append(allocator, call_id_owned);

    if (supports_images and image_count > 0) {
        var parts = std.ArrayList(ContentPart).empty;
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
    var owned = try buildOwnedPayload(allocator, model, context, options);
    defer owned.deinit();
    return try std.json.Stringify.valueAlloc(allocator, owned.payload, .{
        .emit_null_optional_fields = false,
    });
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

const ParsedTextSignature = struct {
    id: []const u8,
    phase: ?[]const u8,
};

pub fn buildRequestUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const whitespace_trimmed = std.mem.trim(u8, base_url, " \t\r\n");
    return shared_url.buildUrl("/responses", allocator, whitespace_trimmed);
}

pub const RequestSnapshotTransportMode = enum {
    sse,
    deferred_websocket,
};

pub const RequestSnapshotOptions = struct {
    scenario_id: []const u8,
    provider_family: []const u8,
    payload_override: ?std.json.Value = null,
    transport_mode: RequestSnapshotTransportMode = .sse,
    mocked_status: u16 = 200,
    method: []const u8 = "POST",
};

pub fn buildRequestSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    snapshot_options: RequestSnapshotOptions,
) !std.json.Value {
    var payload = if (snapshot_options.payload_override) |override|
        try provider_json.cloneValue(allocator, override)
    else
        try buildRequestPayload(allocator, model, context, options);
    errdefer provider_json.freeValue(allocator, payload);

    var resolved_options = if (options) |stream_options| stream_options else types.StreamOptions{};
    if (resolved_options.api_key == null) resolved_options.api_key = "fixture-api-key-redacted";

    var headers = try buildRequestHeaders(allocator, model, context, resolved_options);
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    const url = try buildRequestUrl(allocator, model.base_url);
    defer allocator.free(url);

    var snapshot = try initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = snapshot });

    // baseUrl: inferResponsesBaseUrlFromUrl returns an owned string; wrap so a
    // dup_key OOM in putStringValue doesn't leak it.
    const base_url_owned = try inferResponsesBaseUrlFromUrl(allocator, url, snapshot_options.provider_family);
    errdefer allocator.free(base_url_owned);
    try snapshot.put(allocator, try allocator.dupe(u8, "baseUrl"), .{ .string = base_url_owned });
    try putObjectValue(allocator, &snapshot, "headers", .{ .object = try normalizeSemanticHeaders(allocator, headers) });
    try putObjectValue(allocator, &snapshot, "jsonPayload", payload);
    payload = .null;
    try putStringValue(allocator, &snapshot, "method", snapshot_options.method);
    const path_owned = try buildResponsesRequestPathFromUrl(allocator, url);
    errdefer allocator.free(path_owned);
    try snapshot.put(allocator, try allocator.dupe(u8, "path"), .{ .string = path_owned });
    try putObjectValue(allocator, &snapshot, "query", .{ .object = try buildResponsesRequestQueryObjectFromUrl(allocator, url) });
    try putObjectValue(allocator, &snapshot, "requestOptions", .{ .object = try buildRequestOptionsSnapshotObject(allocator, options, true) });
    try putObjectValue(allocator, &snapshot, "transportMetadata", .{ .object = try buildTransportMetadataSnapshotObject(
        allocator,
        snapshot_options.scenario_id,
        snapshot_options.provider_family,
        snapshot_options.transport_mode,
        snapshot_options.mocked_status,
    ) });
    try putStringValue(allocator, &snapshot, "url", url);

    return .{ .object = snapshot };
}

pub fn buildRequestOptionsSnapshotObject(
    allocator: std.mem.Allocator,
    options: ?types.StreamOptions,
    include_timeout_retries: bool,
) !std.json.ObjectMap {
    var object = try initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });

    const signal = if (options) |stream_options|
        if (stream_options.signal != null) "provided" else "not-provided"
    else
        "not-provided";
    try putStringValue(allocator, &object, "signal", signal);

    if (include_timeout_retries) {
        if (options) |stream_options| {
            if (stream_options.max_retries) |max_retries| {
                try putIntegerValue(allocator, &object, "maxRetries", max_retries);
            }
            if (stream_options.timeout_ms) |timeout_ms| {
                try putIntegerValue(allocator, &object, "timeoutMs", timeout_ms);
            }
        }
    }

    return object;
}

pub fn buildTransportMetadataSnapshotObject(
    allocator: std.mem.Allocator,
    scenario_id: []const u8,
    provider_family: []const u8,
    mode: RequestSnapshotTransportMode,
    mocked_status: u16,
) !std.json.ObjectMap {
    var object = try initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });

    const response_headers_value: std.json.Value = blk: {
        var response_headers = try initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = response_headers });
        if (mode == .sse) {
            try putStringValue(allocator, &response_headers, "content-type", "text/event-stream");
        }
        try putStringValue(allocator, &response_headers, "x-fixture-response", scenario_id);
        break :blk .{ .object = response_headers };
    };

    try putObjectValue(allocator, &object, "mockedResponseHeaders", response_headers_value);
    try putIntegerValue(allocator, &object, "mockedStatus", mocked_status);
    try putStringValue(allocator, &object, "mode", switch (mode) {
        .sse => "sse",
        .deferred_websocket => "deferred-websocket",
    });
    try putStringValue(allocator, &object, "providerFamily", provider_family);
    try putStringValue(allocator, &object, "requestBoundary", switch (mode) {
        .sse => "before local mocked SSE response body is consumed",
        .deferred_websocket => "before local mocked WebSocket message stream is consumed; no live socket opened",
    });

    return object;
}

pub fn buildResponsesRequestPathFromUrl(allocator: std.mem.Allocator, request_url: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, request_url, "://") orelse return error.InvalidUrl;
    const after_host = request_url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after_host, '/') orelse return try allocator.dupe(u8, "/");
    const path_query = after_host[slash..];
    const query = std.mem.indexOfScalar(u8, path_query, '?') orelse return try allocator.dupe(u8, path_query);
    return try allocator.dupe(u8, path_query[0..query]);
}

pub fn buildResponsesRequestQueryObjectFromUrl(allocator: std.mem.Allocator, request_url: []const u8) !std.json.ObjectMap {
    var object = try initObject(allocator);
    errdefer object.deinit(allocator);

    const query_index = std.mem.indexOfScalar(u8, request_url, '?') orelse return object;
    var entries = std.mem.splitScalar(u8, request_url[query_index + 1 ..], '&');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        const key = entry[0..separator];
        const value = if (separator < entry.len) entry[separator + 1 ..] else "";
        try putStringValue(allocator, &object, key, value);
    }
    return object;
}

pub fn inferResponsesBaseUrlFromUrl(allocator: std.mem.Allocator, request_url: []const u8, provider_family: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, request_url, "://") orelse return error.InvalidUrl;
    const after_host = request_url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after_host, '/') orelse return try allocator.dupe(u8, request_url);
    const origin_end = scheme + 3 + slash;
    const query_index = std.mem.indexOfScalar(u8, request_url[origin_end..], '?');
    const path_end = if (query_index) |offset| origin_end + offset else request_url.len;
    const suffix = if (std.mem.eql(u8, provider_family, "openai-codex")) "/codex/responses" else "/responses";
    if (std.mem.endsWith(u8, request_url[origin_end..path_end], suffix)) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{
            request_url[0..origin_end],
            request_url[origin_end .. path_end - suffix.len],
        });
    }
    return try allocator.dupe(u8, request_url[0..path_end]);
}

pub fn normalizeSemanticHeaders(
    allocator: std.mem.Allocator,
    headers: std.StringHashMap([]const u8),
) !std.json.ObjectMap {
    var semantic = try initObject(allocator);
    errdefer semantic.deinit(allocator);

    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        const lower = try asciiLowerAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(lower);

        const include = std.mem.eql(u8, lower, "accept") or
            std.mem.eql(u8, lower, "api-key") or
            std.mem.eql(u8, lower, "authorization") or
            std.mem.eql(u8, lower, "chatgpt-account-id") or
            std.mem.eql(u8, lower, "content-type") or
            std.mem.eql(u8, lower, "copilot-integration-id") or
            std.mem.eql(u8, lower, "copilot-vision-request") or
            std.mem.eql(u8, lower, "editor-plugin-version") or
            std.mem.eql(u8, lower, "editor-version") or
            std.mem.eql(u8, lower, "openai-beta") or
            std.mem.eql(u8, lower, "openai-intent") or
            std.mem.eql(u8, lower, "originator") or
            std.mem.eql(u8, lower, "session_id") or
            (std.mem.eql(u8, lower, "user-agent") and std.mem.startsWith(u8, entry.value_ptr.*, "GitHubCopilotChat/")) or
            std.mem.eql(u8, lower, "x-client-request-id") or
            std.mem.eql(u8, lower, "x-initiator") or
            std.mem.startsWith(u8, lower, "x-fixture-");
        if (!include) continue;

        const value = if (std.mem.eql(u8, lower, "authorization") or std.mem.eql(u8, lower, "api-key"))
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

fn parseTextSignature(allocator: std.mem.Allocator, signature: ?[]const u8, message_index: usize) !ParsedTextSignature {
    const value = signature orelse return .{ .id = try std.fmt.allocPrint(allocator, "msg_{d}", .{message_index}), .phase = null };
    if (std.mem.startsWith(u8, value, "{")) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch {
            return .{ .id = try normalizedMessageIdFromSignature(allocator, value), .phase = null };
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("v")) |version| {
                if (version == .integer and version.integer == 1) {
                    if (extractStringField(parsed.value, "id")) |id| {
                        const phase = extractStringField(parsed.value, "phase");
                        const normalized_id = try normalizedMessageIdFromSignature(allocator, id);
                        if (phase != null and (std.mem.eql(u8, phase.?, "commentary") or std.mem.eql(u8, phase.?, "final_answer"))) {
                            return .{ .id = normalized_id, .phase = try allocator.dupe(u8, phase.?) };
                        }
                        return .{ .id = normalized_id, .phase = null };
                    }
                }
            }
        }
    }
    return .{ .id = try normalizedMessageIdFromSignature(allocator, value), .phase = null };
}

fn normalizedMessageIdFromSignature(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    if (id.len <= 64) return try allocator.dupe(u8, id);
    const hash = try shortHash(allocator, id);
    defer allocator.free(hash);
    return try std.fmt.allocPrint(allocator, "msg_{s}", .{hash});
}

fn normalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    if (!isOpenAIResponsesToolCallProvider(model.provider)) return normalizeIdPart(allocator, id);
    const separator = std.mem.indexOfScalar(u8, id, '|') orelse return normalizeIdPart(allocator, id);
    const call_id = try normalizeIdPart(allocator, id[0..separator]);
    defer allocator.free(call_id);

    const item_id = id[separator + 1 ..];
    const is_foreign = !std.mem.eql(u8, source.provider, model.provider) or !std.mem.eql(u8, source.api, model.api);
    var normalized_item_id = if (is_foreign)
        try buildForeignResponsesItemId(allocator, item_id)
    else
        try normalizeIdPart(allocator, item_id);
    defer allocator.free(normalized_item_id);

    if (!std.mem.startsWith(u8, normalized_item_id, "fc_")) {
        const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{normalized_item_id});
        defer allocator.free(prefixed);
        const updated = try normalizeIdPart(allocator, prefixed);
        allocator.free(normalized_item_id);
        normalized_item_id = updated;
    }

    return try std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, normalized_item_id });
}

fn isOpenAIResponsesToolCallProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "openai") or
        std.mem.eql(u8, provider, "openai-codex") or
        std.mem.eql(u8, provider, "opencode");
}

fn normalizeIdPart(allocator: std.mem.Allocator, part: []const u8) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (part) |char| {
        const normalized: u8 = if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-') char else '_';
        try buffer.append(allocator, normalized);
        if (buffer.items.len == 64) break;
    }
    while (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '_') _ = buffer.pop();
    return try buffer.toOwnedSlice(allocator);
}

fn buildForeignResponsesItemId(allocator: std.mem.Allocator, item_id: []const u8) ![]const u8 {
    const hash = try shortHash(allocator, item_id);
    defer allocator.free(hash);
    const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{hash});
    defer allocator.free(prefixed);
    if (prefixed.len > 64) return try allocator.dupe(u8, prefixed[0..64]);
    return try allocator.dupe(u8, prefixed);
}

fn shortHash(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;
    for (input) |char| {
        const ch: u32 = char;
        h1 = (h1 ^ ch) *% 2654435761;
        h2 = (h2 ^ ch) *% 1597334677;
    }
    h1 = ((h1 ^ (h1 >> 16)) *% 2246822507) ^ ((h2 ^ (h2 >> 13)) *% 3266489909);
    h2 = ((h2 ^ (h2 >> 16)) *% 2246822507) ^ ((h1 ^ (h1 >> 13)) *% 3266489909);
    const high = try u32ToBase36(allocator, h2);
    defer allocator.free(high);
    const low = try u32ToBase36(allocator, h1);
    defer allocator.free(low);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ high, low });
}

fn u32ToBase36(allocator: std.mem.Allocator, value: u32) ![]const u8 {
    if (value == 0) return try allocator.dupe(u8, "0");
    var digits: [16]u8 = undefined;
    var current = value;
    var index: usize = digits.len;
    while (current > 0) {
        index -= 1;
        const digit: u8 = @intCast(current % 36);
        digits[index] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        current /= 36;
    }
    return try allocator.dupe(u8, digits[index..]);
}

fn trimRightScalar(value: []const u8, scalar: u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == scalar) : (end -= 1) {}
    return value[0..end];
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

fn extractCombinedToolCallId(allocator: std.mem.Allocator, item_value: std.json.Value) !?[]const u8 {
    if (item_value != .object) return null;
    const call_id = extractStringField(item_value, "call_id") orelse return null;
    const item_id = extractStringField(item_value, "id");
    if (item_id) |value| {
        return try std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, value });
    }
    return try allocator.dupe(u8, call_id);
}

fn extractOwnedStringField(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) !?[]const u8 {
    const string = extractStringField(value, key) orelse return null;
    return try allocator.dupe(u8, string);
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

/// Port of TS `applyServiceTierPricing` in `packages/ai/src/providers/openai-responses.ts`.
/// Multipliers: flex=0.5, priority=2 (or 2.5 for model id "gpt-5.5"). Applied after
/// `finalize.calculateCost` on `response.completed`.
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

fn parseStreamingJsonToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    if (input.len == 0) return .{ .object = try initObject(allocator) };
    const parsed = json_parse.parseStreamingJson(allocator, input) catch {
        return .{ .object = try initObject(allocator) };
    };
    defer parsed.deinit();
    return try provider_json.cloneValue(allocator, parsed.value);
}

fn mapStopReason(status: []const u8) types.StopReason {
    return stop_reason_mod.mapStopReasonFromTable(&stop_reason_mod.openai_responses_mappings, status, .error_reason);
}

const jsonIntegerToU32 = openai_usage.jsonIntegerToU32;

fn getCompat(model: types.Model) ResponsesCompat {
    return .{
        .send_session_id_header = compatBoolField(model.compat, "sendSessionIdHeader") orelse true,
        .supports_long_cache_retention = compatBoolField(model.compat, "supportsLongCacheRetention") orelse true,
    };
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

fn compatBoolField(compat: ?std.json.Value, key: []const u8) ?bool {
    const value = compat orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn modelThinkingLevel(level: types.ThinkingLevel) types.ModelThinkingLevel {
    return switch (level) {
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    return abort_helper.isRequestedFromOptions(options);
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return provider_json.initObject(allocator);
}

const freeToolCallOwned = types.freeToolCall;

fn cloneToolCallOwned(allocator: std.mem.Allocator, tool_call: types.ToolCall) !types.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);
    const arguments = try provider_json.cloneValue(allocator, tool_call.arguments);
    errdefer provider_json.freeValue(allocator, arguments);
    const thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null;
    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
        .thought_signature = thought_signature,
    };
}

const freeAssistantMessageOwned = types.freeAssistantMessage;

fn freeEventOwned(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    if (event.delta) |delta| allocator.free(delta);
    if (event.tool_call) |tool_call| freeToolCallOwned(allocator, tool_call);
}

const ResponseHeaderServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    response_headers: []const u8,
    body: []const u8,
    body_delay_ms: u64 = 0,
    thread: ?std.Thread = null,

    fn init(io: std.Io, response_headers: []const u8, body: []const u8) !ResponseHeaderServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .response_headers = response_headers,
            .body = body,
        };
    }

    fn initDelayed(io: std.Io, response_headers: []const u8, body: []const u8, body_delay_ms: u64) !ResponseHeaderServer {
        var server = try init(io, response_headers, body);
        server.body_delay_ms = body_delay_ms;
        return server;
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

        readRequestHead(stream) catch return;
        writeResponse(self, stream) catch return;
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var header_buffer: [16 * 1024]u8 = undefined;
        var header_len: usize = 0;
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            if (header_len >= header_buffer.len) return error.RequestHeaderTooLarge;
            header_buffer[header_len] = byte;
            header_len += 1;
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

        const content_length = parseContentLengthHeader(header_buffer[0..header_len]);
        var remaining = content_length;
        while (remaining > 0) : (remaining -= 1) {
            _ = try reader.interface.takeByte();
        }
    }

    fn writeResponse(self: *ResponseHeaderServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n",
            .{ self.body.len, self.response_headers },
        );
        try writer.interface.flush();
        if (self.body_delay_ms > 0) {
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.body_delay_ms)), .awake) catch {};
        }
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

fn parseContentLengthHeader(headers: []const u8) usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch 0;
    }
    return 0;
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
        try std.testing.expectEqualStrings("openai-responses", model.api);
        try std.testing.expectEqualStrings("text/event-stream", headers.get("content-type").?);
        try std.testing.expectEqualStrings("req_123", headers.get("x-request-id").?);
        try std.testing.expectEqualStrings("17", headers.get("openai-processing-ms").?);
        try std.testing.expect(headers.get("Content-Type") == null);
    }
};

fn drainStreamAndFreeDoneMessage(
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
) !void {
    while (stream.next()) |event| {
        if (event.delta != null or event.tool_call != null) {
            freeEventOwned(allocator, event);
        }
        if (event.message) |message| {
            if (event.event_type != .done) continue;
            freeAssistantMessageOwned(allocator, message);
        }
    }
}

test "extractMessageText uses caller allocator" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"},{\"type\":\"refusal\",\"refusal\":\" no\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractMessageText(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("Hello no", text);
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
        "{\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"content first\"},{\"type\":\"reasoning_text\",\"text\":\"content second\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractReasoningSummary(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("content first\n\ncontent second", text);
}

test "extractReasoningSummary prefers summary over content text" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"summary\":[{\"text\":\"summary wins\"}],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"content loses\"}]}",
        .{},
    );
    defer parsed.deinit();

    const text = (try extractReasoningSummary(allocator, parsed.value)).?;
    defer allocator.free(text);

    try std.testing.expectEqualStrings("summary wins", text);
}

test "stream on_response receives actual response headers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const body =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_headers\"}}\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}}\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_headers\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n" ++
        "data: [DONE]\n";

    var server = try ResponseHeaderServer.init(
        io,
        "x-request-id: req_123\r\nopenai-processing-ms: 17\r\n",
        body,
    );
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = url,
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
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

    var stream = try OpenAIResponsesProvider.stream(allocator, io, model, context, .{
        .api_key = "test-key",
        .on_response = &OnResponseCapture.callback,
    });
    defer stream.deinit();

    try drainStreamAndFreeDoneMessage(allocator, &stream);

    try std.testing.expect(OnResponseCapture.called);
    try std.testing.expectEqual(@as(u16, 200), OnResponseCapture.status);
}

test "buildRequestUrl trims trailing slash before responses path" {
    const allocator = std.testing.allocator;
    const url = try buildRequestUrl(allocator, "https://proxy.example.test/custom/v1/");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://proxy.example.test/custom/v1/responses", url);
}

test "stream forwards timeout_ms to HTTP streaming request" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_timeout\",\"status\":\"completed\"}}\n";
    var server = try ResponseHeaderServer.initDelayed(io, "", body, 250);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
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

    var stream = try OpenAIResponsesProvider.stream(allocator, io, model, context, .{
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

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body = "{\"error\":{\"message\":\"bad gateway\",\"api_key\":\"sk-response-secret\",\"request_id\":\"req_response_random_123456\"},\"trace\":\"/Users/alice/pi/openai_responses.zig\"}";
    var server = try provider_error.TestStatusServer.init(io, 502, "Bad Gateway", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
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

    var stream = try OpenAIResponsesProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 502: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "bad gateway") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "sk-response-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_response_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("openai-responses", result.api);
}

test "VAL-MSG-010 OpenAI Responses skips failed assistants and replays valid responses" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const ok_content = [_]types.ContentBlock{.{ .text = .{ .text = "First answer" } }};
    const failed_content = [_]types.ContentBlock{
        .{ .text = .{ .text = "partial signed output", .text_signature = "failed-text-sig" } },
        .{ .tool_call = .{ .id = "failed-call", .name = "lookup", .arguments = .null, .thought_signature = "failed-tool-sig" } },
    };
    const user_after_anchor = [_]types.ContentBlock{.{ .text = .{ .text = "After anchor" } }};
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "Continue" } }};
    const context = types.Context{
        .system_prompt = "System prompt should be replayed with Responses input history.",
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &ok_content,
                .api = "openai-responses",
                .provider = "openai",
                .model = "gpt-5-mini",
                .response_id = "resp_ok",
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 1,
            } },
            .{ .user = .{ .content = &user_after_anchor, .timestamp = 2 } },
            .{ .assistant = .{
                .content = &failed_content,
                .api = "openai-responses",
                .provider = "openai",
                .model = "gpt-5-mini",
                .response_id = "resp_failed",
                .usage = types.Usage.init(),
                .stop_reason = .error_reason,
                .error_message = "provider failed",
                .timestamp = 3,
            } },
            .{ .assistant = .{
                .content = &failed_content,
                .api = "openai-responses",
                .provider = "openai",
                .model = "gpt-5-mini",
                .response_id = "resp_aborted",
                .usage = types.Usage.init(),
                .stop_reason = .aborted,
                .error_message = "aborted",
                .timestamp = 4,
            } },
            .{ .user = .{ .content = &final_user, .timestamp = 5 } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("previous_response_id") == null);
    const input = payload.object.get("input").?.array;
    try std.testing.expectEqual(@as(usize, 4), input.items.len);
    try std.testing.expectEqualStrings("developer", input.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("message", input.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("user", input.items[2].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", input.items[3].object.get("role").?.string);
}

test "buildRequestPayload replays assistant history without previous_response_id" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const assistant_content = [_]types.ContentBlock{.{ .text = .{ .text = "First answer" } }};
    const user_content = [_]types.ContentBlock{.{ .text = .{ .text = "Follow up" } }};
    const context = types.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &assistant_content,
                .api = "openai-responses",
                .provider = "openai",
                .model = "gpt-5-mini",
                .response_id = "resp_prev",
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 1,
            } },
            .{ .user = .{
                .content = &user_content,
                .timestamp = 2,
            } },
        },
    };

    const payload = try buildRequestPayload(allocator, model, context, .{ .session_id = "sess-1" });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload == .object);
    try std.testing.expect(payload.object.get("previous_response_id") == null);
    try std.testing.expectEqualStrings("sess-1", payload.object.get("prompt_cache_key").?.string);

    const input = payload.object.get("input").?;
    try std.testing.expect(input == .array);
    try std.testing.expectEqual(@as(usize, 3), input.array.items.len);

    const system_item = input.array.items[0];
    try std.testing.expect(system_item == .object);
    try std.testing.expectEqualStrings("developer", system_item.object.get("role").?.string);

    const assistant_item = input.array.items[1];
    try std.testing.expect(assistant_item == .object);
    try std.testing.expectEqualStrings("message", assistant_item.object.get("type").?.string);

    const user_item = input.array.items[2];
    try std.testing.expect(user_item == .object);
    try std.testing.expectEqualStrings("user", user_item.object.get("role").?.string);
    try std.testing.expect(user_item.object.get("content").? == .array);
}

test "parseSseStreamLines streams text and captures response_id" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8,\"input_tokens_details\":{\"cached_tokens\":1}}}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ignored\"}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
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
    try std.testing.expectEqualStrings("Hello", event3.delta.?);

    const event4 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, event4.event_type);
    try std.testing.expectEqualStrings("Hello", event4.content.?);

    const event5 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event5.event_type);
    try std.testing.expect(event5.message != null);
    try std.testing.expectEqualStrings("resp_1", event5.message.?.response_id.?);
    try std.testing.expectEqual(@as(u32, 4), event5.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 3), event5.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 8), event5.message.?.usage.total_tokens);
    try std.testing.expectEqualStrings("Hello", event5.message.?.content[0].text.text);

    freeAssistantMessageOwned(allocator, event5.message.?);
}

test "parseSseStreamLines preserves canonical-only data-line tolerance" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "event: ignored\n" ++
            "data:{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"compact\",\"message\":\"must be ignored\"}}}\n" ++
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_canonical_only\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"canonical\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"canonical\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_canonical_only\",\"status\":\"completed\"}}\n",
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
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
    try std.testing.expectEqualStrings("canonical", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream.next().?.event_type);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("resp_canonical_only", done.message.?.response_id.?);
    try std.testing.expectEqualStrings("canonical", done.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.stop, done.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines fills missing total tokens from full usage before cost" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_usage\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Usage\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Usage\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_usage\",\"status\":\"completed\",\"usage\":{\"input_tokens\":7,\"output_tokens\":5,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .cost = .{
            .input = 1.0,
            .output = 2.0,
            .cache_read = 0.5,
        },
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    while (stream.next()) |event| {
        if (event.event_type != .done) {
            freeEventOwned(allocator, event);
            continue;
        }
        try std.testing.expect(event.message != null);
        try std.testing.expectEqual(@as(u32, 5), event.message.?.usage.input);
        try std.testing.expectEqual(@as(u32, 5), event.message.?.usage.output);
        try std.testing.expectEqual(@as(u32, 2), event.message.?.usage.cache_read);
        try std.testing.expectEqual(@as(u32, 12), event.message.?.usage.total_tokens);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000005), event.message.?.usage.cost.input, 0.0000001);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000010), event.message.?.usage.cost.output, 0.0000001);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000001), event.message.?.usage.cost.cache_read, 0.0000001);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000016), event.message.?.usage.cost.total, 0.0000001);
        freeAssistantMessageOwned(allocator, event.message.?);
        return;
    }

    return error.ExpectedDoneEvent;
}

test "parseSseStreamLines streams reasoning_text deltas and final content fallback" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_reasoning_text\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}\n" ++
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"plan \"}\n" ++
            "data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"steps\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"final content reasoning\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_reasoning_text\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":2,\"total_tokens\":4}}}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
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
    try std.testing.expectEqualStrings("plan ", first_delta.delta.?);

    const second_delta = stream.next().?;
    defer freeEventOwned(allocator, second_delta);
    try std.testing.expectEqual(types.EventType.thinking_delta, second_delta.event_type);
    try std.testing.expectEqualStrings("steps", second_delta.delta.?);

    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqualStrings("final content reasoning", thinking_end.content.?);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    try std.testing.expectEqualStrings("openai-responses", done.message.?.api);
    try std.testing.expectEqualStrings("openai", done.message.?.provider);
    try std.testing.expectEqualStrings("gpt-5-mini", done.message.?.model);
    try std.testing.expectEqualStrings("final content reasoning", done.message.?.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("resp_reasoning_text", done.message.?.response_id.?);
    try std.testing.expect(stream.next() == null);

    freeAssistantMessageOwned(allocator, done.message.?);
}

test "parseSseStreamLines streams tool calls and finalizes arguments" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"city\\\":\\\"Ber\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"lin\\\"}\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tool\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}}}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, event2.event_type);

    const event3 = stream.next().?;
    defer freeEventOwned(allocator, event3);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event3.event_type);
    try std.testing.expectEqualStrings("{\"city\":\"Ber", event3.delta.?);

    const event4 = stream.next().?;
    defer freeEventOwned(allocator, event4);
    try std.testing.expectEqual(types.EventType.toolcall_delta, event4.event_type);
    try std.testing.expectEqualStrings("lin\"}", event4.delta.?);

    const event5 = stream.next().?;
    defer freeEventOwned(allocator, event5);
    try std.testing.expectEqual(types.EventType.toolcall_end, event5.event_type);
    try std.testing.expect(event5.tool_call != null);
    try std.testing.expectEqualStrings("call_1|fc_1", event5.tool_call.?.id);
    try std.testing.expectEqualStrings("get_weather", event5.tool_call.?.name);

    const event6 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event6.event_type);
    try std.testing.expect(event6.message != null);
    try std.testing.expectEqual(@as(usize, 1), event6.message.?.content.len);
    try std.testing.expect(event6.message.?.content[0] == .tool_call);
    try std.testing.expectEqualStrings("call_1|fc_1", event6.message.?.content[0].tool_call.id);
    try std.testing.expectEqualStrings("Berlin", event6.message.?.content[0].tool_call.arguments.object.get("city").?.string);
    try std.testing.expect(event6.message.?.tool_calls == null);
    try std.testing.expectEqual(types.StopReason.tool_use, event6.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_tool", event6.message.?.response_id.?);

    freeAssistantMessageOwned(allocator, event6.message.?);
}

test "parseSseStreamLines separates interleaved calls and lets final/object arguments win" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_2\",\"call_id\":\"call_2\",\"name\":\"get_count\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"item_id\":\"fc_2\",\"delta\":\"{\\\"count\\\":\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_1\",\"delta\":\"{\\\"city\\\":\\\"Paris\\\"}\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_1\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_2\",\"call_id\":\"call_2\",\"name\":\"get_count\",\"arguments\":{\"count\":2,\"nested\":{\"ok\":true}}}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tool\",\"status\":\"completed\"}}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    var done: ?types.AssistantMessageEvent = null;
    while (stream.next()) |event| {
        if (event.event_type == .done) {
            done = event;
            break;
        }
    }

    try std.testing.expect(done != null);
    const message = done.?.message.?;
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    try std.testing.expect(message.tool_calls == null);
    try std.testing.expectEqual(@as(usize, 2), message.content.len);
    try std.testing.expectEqualStrings("call_1|fc_1", message.content[0].tool_call.id);
    try std.testing.expectEqualStrings("call_2|fc_2", message.content[1].tool_call.id);
    try std.testing.expectEqualStrings("Berlin", message.content[0].tool_call.arguments.object.get("city").?.string);
    try std.testing.expectEqual(@as(i64, 2), message.content[1].tool_call.arguments.object.get("count").?.integer);
    try std.testing.expect(message.content[1].tool_call.arguments.object.get("nested").?.object.get("ok").?.bool);

    freeAssistantMessageOwned(allocator, message);
}

test "ISS-011 parseSseStreamLines keeps encrypted reasoning with multi-tool outputs" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_multi_reasoning\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_multi\",\"summary\":[]}}\n" ++
            "data: {\"type\":\"response.reasoning_summary_part.added\",\"output_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"delta\":\"choose tools\"}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_weather\",\"call_id\":\"call_weather\",\"name\":\"get_weather\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"fc_count\",\"call_id\":\"call_count\",\"name\":\"get_count\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"item_id\":\"fc_count\",\"delta\":\"{\\\"count\\\":\"}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"item_id\":\"fc_weather\",\"delta\":\"{\\\"city\\\":\\\"Paris\\\"}\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_multi\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"choose tools\"}],\"encrypted_content\":\"encrypted-multi\"}}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_weather\",\"call_id\":\"call_weather\",\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"}}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"id\":\"fc_count\",\"call_id\":\"call_count\",\"name\":\"get_count\",\"arguments\":{\"count\":2}}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_multi_reasoning\",\"status\":\"completed\"}}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream.next().?.event_type);
    const reasoning_delta = stream.next().?;
    defer freeEventOwned(allocator, reasoning_delta);
    try std.testing.expectEqual(types.EventType.thinking_delta, reasoning_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 0), reasoning_delta.content_index);
    try std.testing.expectEqualStrings("choose tools", reasoning_delta.delta.?);

    const weather_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, weather_start.event_type);
    try std.testing.expectEqual(@as(?u32, 1), weather_start.content_index);
    const count_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, count_start.event_type);
    try std.testing.expectEqual(@as(?u32, 2), count_start.content_index);
    const count_delta = stream.next().?;
    defer freeEventOwned(allocator, count_delta);
    try std.testing.expectEqual(types.EventType.toolcall_delta, count_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 2), count_delta.content_index);
    const weather_delta = stream.next().?;
    defer freeEventOwned(allocator, weather_delta);
    try std.testing.expectEqual(types.EventType.toolcall_delta, weather_delta.event_type);
    try std.testing.expectEqual(@as(?u32, 1), weather_delta.content_index);

    const thinking_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.thinking_end, thinking_end.event_type);
    try std.testing.expectEqual(@as(?u32, 0), thinking_end.content_index);
    try std.testing.expectEqualStrings("choose tools", thinking_end.content.?);
    const weather_end = stream.next().?;
    defer freeEventOwned(allocator, weather_end);
    try std.testing.expectEqual(types.EventType.toolcall_end, weather_end.event_type);
    try std.testing.expectEqual(@as(?u32, 1), weather_end.content_index);
    try std.testing.expectEqualStrings("call_weather|fc_weather", weather_end.tool_call.?.id);
    const count_end = stream.next().?;
    defer freeEventOwned(allocator, count_end);
    try std.testing.expectEqual(types.EventType.toolcall_end, count_end.event_type);
    try std.testing.expectEqual(@as(?u32, 2), count_end.content_index);
    try std.testing.expectEqualStrings("call_count|fc_count", count_end.tool_call.?.id);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    const message = done.message.?;
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    try std.testing.expectEqualStrings("resp_multi_reasoning", message.response_id.?);
    try std.testing.expect(message.tool_calls == null);
    try std.testing.expectEqual(@as(usize, 3), message.content.len);
    try std.testing.expect(message.content[0] == .thinking);
    try std.testing.expect(message.content[1] == .tool_call);
    try std.testing.expect(message.content[2] == .tool_call);
    try std.testing.expectEqualStrings("choose tools", message.content[0].thinking.thinking);
    const signature = types.thinkingSignature(message.content[0].thinking).?;
    try std.testing.expect(std.mem.indexOf(u8, signature, "\"id\":\"rs_multi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, signature, "\"encrypted_content\":\"encrypted-multi\"") != null);
    try std.testing.expectEqualStrings("call_weather|fc_weather", message.content[1].tool_call.id);
    try std.testing.expectEqualStrings("Paris", message.content[1].tool_call.arguments.object.get("city").?.string);
    try std.testing.expect(message.content[1].tool_call.thought_signature == null);
    try std.testing.expectEqualStrings("call_count|fc_count", message.content[2].tool_call.id);
    try std.testing.expectEqual(@as(i64, 2), message.content[2].tool_call.arguments.object.get("count").?.integer);
    try std.testing.expect(message.content[2].tool_call.thought_signature == null);
    try std.testing.expect(stream.next() == null);

    freeAssistantMessageOwned(allocator, message);
}

test "parseSseStreamLines preserves reserved indexes for out-of-order tool call done events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"first_tool\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_2\",\"call_id\":\"call_2\",\"name\":\"second_tool\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_2\",\"call_id\":\"call_2\",\"name\":\"second_tool\",\"arguments\":\"{\\\"value\\\":2}\"}}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"first_tool\",\"arguments\":\"{\\\"value\\\":1}\"}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tool\",\"status\":\"completed\"}}\n" ++
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
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

    const start = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, start.event_type);

    const first_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, first_start.event_type);
    try std.testing.expectEqual(@as(?u32, 0), first_start.content_index);

    const second_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, second_start.event_type);
    try std.testing.expectEqual(@as(?u32, 1), second_start.content_index);

    const second_end = stream.next().?;
    defer freeEventOwned(allocator, second_end);
    try std.testing.expectEqual(types.EventType.toolcall_end, second_end.event_type);
    try std.testing.expectEqual(@as(?u32, 1), second_end.content_index);
    try std.testing.expectEqualStrings("call_2|fc_2", second_end.tool_call.?.id);

    const first_end = stream.next().?;
    defer freeEventOwned(allocator, first_end);
    try std.testing.expectEqual(types.EventType.toolcall_end, first_end.event_type);
    try std.testing.expectEqual(@as(?u32, 0), first_end.content_index);
    try std.testing.expectEqualStrings("call_1|fc_1", first_end.tool_call.?.id);

    const done = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expect(done.message != null);
    const message = done.message.?;
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    try std.testing.expect(message.tool_calls == null);
    try std.testing.expectEqual(@as(usize, 2), message.content.len);
    try std.testing.expect(message.content[0] == .tool_call);
    try std.testing.expect(message.content[1] == .tool_call);
    try std.testing.expectEqualStrings("call_1|fc_1", message.content[0].tool_call.id);
    try std.testing.expectEqualStrings("call_2|fc_2", message.content[1].tool_call.id);
    try std.testing.expectEqual(@as(i64, 1), message.content[0].tool_call.arguments.object.get("value").?.integer);
    try std.testing.expectEqual(@as(i64, 2), message.content[1].tool_call.arguments.object.get("value").?.integer);
    try std.testing.expect(stream.next() == null);

    freeAssistantMessageOwned(allocator, message);
}

test "parseSseStreamLines preserves partial text before malformed response event terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_bad\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n" ++
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

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

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
    try std.testing.expectEqualStrings("resp_bad", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
}

test "buildRequestPayload omits long cache retention when compat disables it" {
    const allocator = std.testing.allocator;

    var compat = try initObject(allocator);
    try compat.put(allocator, try allocator.dupe(u8, "supportsLongCacheRetention"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
        .compat = compat_value,
    };

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{} }, .{
        .session_id = "sess-1",
        .cache_retention = .long,
    });
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("prompt_cache_key") != null);
    try std.testing.expect(payload.object.get("prompt_cache_retention") == null);
}

test "buildRequestPayload omits empty tools array" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
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
        .tools = &[_]types.Tool{},
    };

    const payload = try buildRequestPayload(allocator, model, context, null);
    defer provider_json.freeValue(allocator, payload);

    try std.testing.expect(payload.object.get("tools") == null);
}

test "buildRequestHeaders omits session_id when compat disables it" {
    const allocator = std.testing.allocator;

    var compat = try initObject(allocator);
    try compat.put(allocator, try allocator.dupe(u8, "sendSessionIdHeader"), .{ .bool = false });
    const compat_value = std.json.Value{ .object = compat };
    defer provider_json.freeValue(allocator, compat_value);

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
        .compat = compat_value,
    };

    var headers = try buildRequestHeaders(allocator, model, .{ .messages = &[_]types.Message{} }, .{
        .api_key = "test-key",
        .session_id = "sess-1",
        .cache_retention = .short,
    });
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqualStrings("Bearer test-key", headers.get("Authorization").?);
    try std.testing.expectEqualStrings("sess-1", headers.get("x-client-request-id").?);
    try std.testing.expect(headers.get("session_id") == null);
}

test "buildRequestHeaders applies Copilot dynamic headers before session and option headers" {
    const allocator = std.testing.allocator;

    var model_headers = std.StringHashMap([]const u8).init(allocator);
    defer model_headers.deinit();
    try model_headers.put("User-Agent", "GitHubCopilotChat/0.35.0");
    try model_headers.put("Editor-Version", "vscode/1.107.0");
    try model_headers.put("Editor-Plugin-Version", "copilot-chat/0.35.0");
    try model_headers.put("Copilot-Integration-Id", "vscode-chat");

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "github-copilot",
        .base_url = "https://api.individual.githubcopilot.com",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 400000,
        .max_tokens = 128000,
        .headers = model_headers,
    };

    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Describe this image." } },
                    .{ .image = .{ .data = "iVBORw0KGgo=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
        },
    };

    var option_headers = std.StringHashMap([]const u8).init(allocator);
    defer option_headers.deinit();
    try option_headers.put("user-agent", "GitHubCopilotChat/override");
    try option_headers.put("x-initiator", "option-initiator");
    try option_headers.put("Openai-Intent", "option-intent");
    try option_headers.put("Copilot-Vision-Request", "false");
    try option_headers.put("x-client-request-id", "option-request");

    var headers = try buildRequestHeaders(allocator, model, context, .{
        .api_key = "test-key",
        .session_id = "sess-1",
        .cache_retention = .short,
        .headers = option_headers,
    });
    defer provider_stream.deinitOwnedHeaders(allocator, &headers);

    try std.testing.expectEqualStrings("GitHubCopilotChat/override", headers.get("user-agent").?);
    try std.testing.expect(headers.get("User-Agent") == null);
    try std.testing.expectEqualStrings("vscode/1.107.0", headers.get("Editor-Version").?);
    try std.testing.expectEqualStrings("copilot-chat/0.35.0", headers.get("Editor-Plugin-Version").?);
    try std.testing.expectEqualStrings("vscode-chat", headers.get("Copilot-Integration-Id").?);
    try std.testing.expectEqualStrings("option-initiator", headers.get("x-initiator").?);
    try std.testing.expect(headers.get("X-Initiator") == null);
    try std.testing.expectEqualStrings("option-intent", headers.get("Openai-Intent").?);
    try std.testing.expectEqualStrings("false", headers.get("Copilot-Vision-Request").?);
    try std.testing.expectEqualStrings("option-request", headers.get("x-client-request-id").?);
}

test "Copilot header inference follows final role and user or tool-result images only" {
    const user_final = types.Context{
        .messages = &[_]types.Message{
            .{ .assistant = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Earlier assistant." } }},
                .api = "openai-responses",
                .provider = "github-copilot",
                .model = "gpt-5-mini",
                .usage = types.Usage.init(),
                .stop_reason = .stop,
                .timestamp = 1,
            } },
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Final user." } }},
                .timestamp = 2,
            } },
        },
    };
    try std.testing.expectEqualStrings("user", copilot_headers.inferCopilotInitiator(&[_]types.Message{}));
    try std.testing.expectEqualStrings("user", copilot_headers.inferCopilotInitiator(user_final.messages));
    try std.testing.expect(!copilot_headers.hasCopilotVisionInput(user_final.messages));

    const tool_result_final = types.Context{
        .messages = &[_]types.Message{
            .{ .tool_result = .{
                .tool_call_id = "call_fixture",
                .tool_name = "fixture_tool",
                .content = &[_]types.ContentBlock{.{ .image = .{ .data = "iVBORw0KGgo=", .mime_type = "image/png" } }},
                .is_error = false,
                .timestamp = 3,
            } },
        },
    };
    try std.testing.expectEqualStrings("agent", copilot_headers.inferCopilotInitiator(tool_result_final.messages));
    try std.testing.expect(copilot_headers.hasCopilotVisionInput(tool_result_final.messages));
}

test "parseSseStreamLines finalizes partial text before response.failed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_failed\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n" ++
            "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_failed\",\"error\":{\"message\":\"provider failed\"}}}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

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
    try std.testing.expectEqualStrings("unknown: provider failed", terminal.error_message.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("resp_failed", terminal.message.?.response_id.?);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "ISS-310 parseSseStreamLines finalizes partial tool call before sanitized response.failed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_failed_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_failed\",\"call_id\":\"call_failed\",\"name\":\"lookup\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_failed\",\"delta\":\"{\\\"query\\\":\\\"local\\\"}\"}\n" ++
            "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_failed_tool\",\"error\":{\"code\":\"server_error\",\"message\":\"failed with sk-response-secret from /Users/alice/pi/openai_responses.zig and request_id req_response_random_123456\"}}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"must_not_emit\",\"status\":\"completed\"}}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, streamErrorContractTestModel("https://api.openai.com/v1"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const tool_start = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_start, tool_start.event_type);
    try std.testing.expectEqual(@as(u32, 0), tool_start.content_index.?);
    const tool_delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expectEqualStrings("{\"query\":\"local\"}", tool_delta.delta.?);
    const tool_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("call_failed|fc_failed", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("local", tool_end.tool_call.?.arguments.object.get("query").?.string);

    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings(terminal.error_message.?, terminal.message.?.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_failed_tool", terminal.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 1), terminal.message.?.content.len);
    try std.testing.expectEqualStrings("lookup", terminal.message.?.content[0].tool_call.name);
    try std.testing.expectEqualStrings("local", terminal.message.?.content[0].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "sk-response-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "/Users/alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "req_response_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "[REDACTED]") != null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

fn streamErrorContractTestModel(base_url: []const u8) types.Model {
    return .{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };
}

fn streamErrorContractTestContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };
}

fn expectOnlyTerminalErrorResponses(
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

fn failingResponsesOnPayload(allocator: std.mem.Allocator, payload: std.json.Value, model: types.Model) !?std.json.Value {
    _ = allocator;
    _ = payload;
    _ = model;
    return error.FixtureResponsesPayloadFailure;
}

fn failingResponsesOnResponse(status: u16, headers: std.StringHashMap([]const u8), model: types.Model) !void {
    _ = status;
    _ = headers;
    _ = model;
    return error.FixtureResponsesResponseFailure;
}

test "VAL-M9-STREAM-002 stream URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel("not-a-valid-url"),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "InvalidUrl", .error_reason);
}

test "VAL-M9-STREAM-002 streamSimple URL construction failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIResponsesProvider.streamSimple(
        allocator,
        io,
        streamErrorContractTestModel("not-a-valid-url"),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key" },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "InvalidUrl", .error_reason);
}

test "VAL-M9-STREAM-004 stream on_payload failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key", .on_payload = failingResponsesOnPayload },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "FixtureResponsesPayloadFailure", .error_reason);
}

test "VAL-RUNTIME-002 streamSimple on_payload failure returns one terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIResponsesProvider.streamSimple(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key", .on_payload = failingResponsesOnPayload },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "FixtureResponsesPayloadFailure", .error_reason);
}

test "VAL-M9-STREAM-005 stream on_response failure returns one terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_unread\"}}\n" ++
        "data: [DONE]\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel(url),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key", .on_response = &failingResponsesOnResponse },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "FixtureResponsesResponseFailure", .error_reason);
}

test "VAL-RUNTIME-002 streamSimple on_response failure returns one terminal error event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const body =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_unread\"}}\n" ++
        "data: [DONE]\n";
    var server = try provider_error.TestStatusServer.init(io, 200, "OK", "", body);
    defer server.deinit();
    try server.start();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var stream = try OpenAIResponsesProvider.streamSimple(
        allocator,
        io,
        streamErrorContractTestModel(url),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key", .on_response = &failingResponsesOnResponse },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "FixtureResponsesResponseFailure", .error_reason);
}

test "stream returns error_event on setup failure instead of throwing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const model = streamErrorContractTestModel("http://127.0.0.1:1");
    const context = streamErrorContractTestContext();

    var stream = try OpenAIResponsesProvider.stream(allocator, io, model, context, .{ .api_key = "test-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("openai-responses", event.message.?.api);
    try std.testing.expectEqualStrings("openai", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-5-mini", event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(event.message.?.error_message.?.len > 0);
    try std.testing.expect(stream.next() == null);
}

fn expectMissingApiKeyTerminalErrorResponses(
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

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorResponses(&stream, "openai");
}

test "VAL-M9-STREAM-006 streamSimple missing api key returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIResponsesProvider.streamSimple(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        .{ .api_key = "" },
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorResponses(&stream, "openai");
}

test "VAL-M9-STREAM-006 stream null api key options returns sanitized terminal error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        null,
    );
    defer stream.deinit();

    try expectMissingApiKeyTerminalErrorResponses(&stream, "openai");
}

test "VAL-M9-STREAM-010 stream pre-aborted signal yields terminal aborted event without throwing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel("http://127.0.0.1:1"),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key", .signal = &aborted },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "Request was aborted", .aborted);
}

test "VAL-M9-STREAM-010 streamSimple pre-aborted signal matches stream terminal aborted semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var simple_stream = try OpenAIResponsesProvider.streamSimple(
        allocator,
        io,
        streamErrorContractTestModel("http://127.0.0.1:1"),
        streamErrorContractTestContext(),
        .{ .api_key = "test-key", .signal = &aborted },
    );
    defer simple_stream.deinit();

    try expectOnlyTerminalErrorResponses(&simple_stream, "Request was aborted", .aborted);
}

test "VAL-RUNTIME-003 pre-aborted signal takes precedence over missing api key setup errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var aborted = std.atomic.Value(bool).init(true);

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        .{ .api_key = "", .signal = &aborted },
    );
    defer stream.deinit();

    try expectOnlyTerminalErrorResponses(&stream, "Request was aborted", .aborted);

    var simple_stream = try OpenAIResponsesProvider.streamSimple(
        allocator,
        io,
        streamErrorContractTestModel("https://api.openai.com/v1"),
        streamErrorContractTestContext(),
        .{ .api_key = "", .signal = &aborted },
    );
    defer simple_stream.deinit();

    try expectOnlyTerminalErrorResponses(&simple_stream, "Request was aborted", .aborted);
}

test "stream preserves partial Responses text before mid-stream abort terminal event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const chunks = [_]test_stream_server.DelayedChunk{
        .{
            .bytes = "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_abort\"}}\n" ++
                "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
                "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n",
            .delay_after_ms = 1000,
        },
        .{ .bytes = "data: [DONE]\n" },
    };
    var server = try test_stream_server.DelayedChunkServer.init(io, &chunks);
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

    var stream = try OpenAIResponsesProvider.stream(
        allocator,
        io,
        streamErrorContractTestModel(url),
        streamErrorContractTestContext(),
        .{
            .api_key = "test-key",
            .signal = &abort_signal,
            .on_response = &AbortAfterResponse.callback,
        },
    );
    defer stream.deinit();

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
    try std.testing.expectEqualStrings("Request was aborted", terminal.error_message.?);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp_abort", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes Responses tool call on EOF mid-block" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_eof_tool\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_eof\",\"call_id\":\"call_eof\",\"name\":\"lookup\",\"arguments\":\"\"}}\n" ++
            "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_eof\",\"delta\":\"{\\\"query\\\":\\\"local\\\"}\"}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, streamErrorContractTestModel("https://api.openai.com/v1"), null);

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
    try std.testing.expectEqualStrings("resp_eof_tool", done.message.?.response_id.?);
    try std.testing.expectEqual(@as(usize, 1), done.message.?.content.len);
    try std.testing.expectEqualStrings("lookup", done.message.?.content[0].tool_call.name);
    try std.testing.expectEqualStrings("local", done.message.?.content[0].tool_call.arguments.object.get("query").?.string);
    try std.testing.expect(stream.next() == null);
}

test "parseSseStreamLines finalizes partial text before top-level error terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_top_error\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n" ++
            "data: {\"type\":\"error\",\"message\":\"top-level failed\"}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    const model = types.Model{
        .id = "gpt-5-mini",
        .name = "GPT-5 Mini",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, null);

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
    try std.testing.expectEqualStrings("top-level failed", terminal.error_message.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("resp_top_error", terminal.message.?.response_id.?);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

fn runServiceTierPricingTest(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    service_tier: ?[]const u8,
    expected_input: f64,
    expected_output: f64,
    expected_cache_read: f64,
    expected_total: f64,
) !void {
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tier\"}}\n" ++
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n" ++
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}}\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tier\",\"status\":\"completed\",\"usage\":{\"input_tokens\":7,\"output_tokens\":5,\"total_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n" ++
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
        .id = model_id,
        .name = "Test Model",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.5 },
        .context_window = 400000,
        .max_tokens = 128000,
    };

    const options = types.StreamOptions{
        .provider = .{ .responses = .{ .service_tier = service_tier } },
    };

    try parseSseStreamLines(allocator, &stream, &streaming, model, options);

    while (stream.next()) |event| {
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

test "parseSseStreamLines applies no service_tier multiplier when unset" {
    // input=5 (after subtracting 2 cached), output=5, cache_read=2 ; cost.input=1.0, output=2.0, cache_read=0.5
    // base costs: 5e-6, 10e-6, 1e-6 ; total = 16e-6
    try runServiceTierPricingTest(std.testing.allocator, "gpt-5-mini", null, 0.000005, 0.000010, 0.000001, 0.000016);
}

test "parseSseStreamLines halves cost for service_tier=flex" {
    try runServiceTierPricingTest(std.testing.allocator, "gpt-5-mini", "flex", 0.0000025, 0.0000050, 0.0000005, 0.0000080);
}

test "parseSseStreamLines doubles cost for service_tier=priority on non-gpt-5.5 model" {
    try runServiceTierPricingTest(std.testing.allocator, "gpt-5-mini", "priority", 0.000010, 0.000020, 0.000002, 0.000032);
}

test "parseSseStreamLines uses 2.5x multiplier for service_tier=priority on gpt-5.5" {
    try runServiceTierPricingTest(std.testing.allocator, "gpt-5.5", "priority", 0.0000125, 0.0000250, 0.0000025, 0.0000400);
}

test "parseSseStreamLines treats auto service_tier as no multiplier" {
    try runServiceTierPricingTest(std.testing.allocator, "gpt-5-mini", "auto", 0.000005, 0.000010, 0.000001, 0.000016);
}
