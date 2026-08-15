const std = @import("std");
const api_registry = @import("api_registry.zig");
const event_stream = @import("event_stream.zig");
const model_registry = @import("model_registry.zig");
const register_builtins = @import("providers/register_builtins.zig");
const abort_helper = @import("shared/abort_signal.zig");
const simple_options_mod = @import("shared/simple_options.zig");
const types = @import("types.zig");

const EntryFunctionError = error{
    MissingCompletionResult,
};

pub fn stream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return dispatchProviderStream(allocator, io, model, context, options, false);
}

fn dispatchProviderStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    simple: bool,
) !event_stream.AssistantMessageEventStream {
    if (isAbortRequested(options)) {
        return createProviderContractErrorStream(allocator, io, model, .aborted, "Request was aborted");
    }

    const provider = api_registry.get(model.api) orelse
        return createProviderContractErrorStream(allocator, io, model, .error_reason, "ProviderNotFound");

    const stream_fn = if (simple) provider.stream_simple else provider.stream;
    return stream_fn(allocator, io, model, context, options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return createProviderContractErrorStream(allocator, io, model, .error_reason, @errorName(err)),
    };
}

pub fn complete(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !types.AssistantMessage {
    var stream_instance = try stream(allocator, io, model, context, options);
    defer stream_instance.deinit();

    while (stream_instance.next()) |event| {
        defer event.deinitTransient(allocator);
    }

    return stream_instance.result() orelse EntryFunctionError.MissingCompletionResult;
}

pub fn streamSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.SimpleStreamOptions,
) !event_stream.AssistantMessageEventStream {
    const stream_options = if (options) |simple_options| blk: {
        var mapped = simple_options_mod.buildBaseOptions(model, simple_options, null);
        applyAnthropicSimpleOptions(&mapped, model, simple_options);
        applyResponsesSimpleOptions(&mapped, model, simple_options.reasoning);
        applyMistralSimpleOptions(&mapped, model, simple_options.reasoning);
        break :blk mapped;
    } else null;
    return try dispatchProviderStream(allocator, io, model, context, stream_options, true);
}

pub fn completeSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.SimpleStreamOptions,
) !types.AssistantMessage {
    var stream_instance = try streamSimple(allocator, io, model, context, options);
    defer stream_instance.deinit();

    while (stream_instance.next()) |event| {
        defer event.deinitTransient(allocator);
    }

    return stream_instance.result() orelse EntryFunctionError.MissingCompletionResult;
}

fn applyAnthropicSimpleOptions(
    stream_options: *types.StreamOptions,
    model: types.Model,
    options: types.SimpleStreamOptions,
) void {
    if (!model.reasoning) return;
    if (!std.mem.eql(u8, model.api, "anthropic-messages")) return;

    if (options.reasoning == null) {
        stream_options.provider.anthropic = .{ .thinking_enabled = false };
        return;
    }

    if (supportsAdaptiveAnthropicThinking(model)) {
        const effort = mapThinkingLevelToAnthropicEffort(model, options.reasoning.?);
        stream_options.provider.anthropic = .{ .thinking_enabled = true, .effort = effort };
        return;
    }

    const base_max_tokens = stream_options.max_tokens orelse 0;
    const adjusted = simple_options_mod.adjustMaxTokensForThinking(
        base_max_tokens,
        model.max_tokens,
        options.reasoning.?,
        options.thinking_budgets,
    );
    stream_options.max_tokens = adjusted.max_tokens;
    stream_options.provider.anthropic = .{ .thinking_enabled = true, .thinking_budget_tokens = adjusted.thinking_budget };
}

fn applyMistralSimpleOptions(
    stream_options: *types.StreamOptions,
    model: types.Model,
    reasoning: ?types.ThinkingLevel,
) void {
    if (reasoning == null) return;
    if (!model.reasoning) return;
    if (!std.mem.eql(u8, model.api, "mistral-conversations")) return;

    if (std.mem.eql(u8, model.id, "mistral-small-2603") or std.mem.eql(u8, model.id, "mistral-small-latest")) {
        stream_options.provider.mistral = .{ .reasoning_effort = "high" };
    } else {
        stream_options.provider.mistral = .{ .prompt_mode = "reasoning" };
    }
}

fn applyResponsesSimpleOptions(
    stream_options: *types.StreamOptions,
    model: types.Model,
    reasoning: ?types.ThinkingLevel,
) void {
    if (reasoning == null) return;
    if (!model.reasoning) return;
    if (!std.mem.eql(u8, model.api, "openai-responses") and
        !std.mem.eql(u8, model.api, "openai-codex-responses") and
        !std.mem.eql(u8, model.api, "azure-openai-responses"))
    {
        return;
    }

    const effort = if (model_registry.supportsXhigh(model))
        reasoning.?
    else
        simple_options_mod.clampReasoning(reasoning).?;
    stream_options.provider.responses = .{ .reasoning_effort = effort };
}

fn supportsAdaptiveAnthropicThinking(model: types.Model) bool {
    return std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null or
        std.mem.indexOf(u8, model.id, "opus-4-7") != null or
        std.mem.indexOf(u8, model.id, "opus-4.7") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4-6") != null or
        std.mem.indexOf(u8, model.id, "sonnet-4.6") != null;
}

fn mapThinkingLevelToAnthropicEffort(
    model: types.Model,
    reasoning: types.ThinkingLevel,
) types.AnthropicEffort {
    return switch (reasoning) {
        .minimal, .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => if (std.mem.indexOf(u8, model.id, "opus-4-6") != null or
            std.mem.indexOf(u8, model.id, "opus-4.6") != null)
            .max
        else if (std.mem.indexOf(u8, model.id, "opus-4-7") != null or
            std.mem.indexOf(u8, model.id, "opus-4.7") != null)
            .xhigh
        else
            .high,
    };
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    return abort_helper.isRequestedFromOptions(options);
}

fn createProviderContractErrorStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    stop_reason: types.StopReason,
    error_message: []const u8,
) !event_stream.AssistantMessageEventStream {
    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = stop_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_instance.push(.{
        .event_type = .error_event,
        .message = message,
        .error_message = message.error_message,
    });
    return stream_instance;
}

const RecordingState = struct {
    stream_calls: usize = 0,
    stream_simple_calls: usize = 0,
    saw_model_api: ?[]const u8 = null,
    saw_model_provider: ?[]const u8 = null,
    saw_model_id: ?[]const u8 = null,
    saw_max_tokens: ?u32 = null,
    saw_temperature: ?f32 = null,
    saw_api_key: ?[]const u8 = null,
    saw_responses_options: ?types.ResponsesStreamOptions = null,
    saw_mistral_options: ?types.MistralStreamOptions = null,
    saw_anthropic_options: ?types.AnthropicStreamOptions = null,
    saw_bedrock_options: ?types.BedrockStreamOptions = null,
    response_text: []const u8 = "recorded response",
};

var recording_state = RecordingState{};

fn resetRecordingState() void {
    recording_state = .{};
}

fn recordingStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    _ = io;
    recording_state.stream_calls += 1;
    recording_state.saw_model_api = model.api;
    recording_state.saw_model_provider = model.provider;
    recording_state.saw_model_id = model.id;
    if (options) |stream_options| {
        recording_state.saw_max_tokens = stream_options.max_tokens;
        recording_state.saw_temperature = stream_options.temperature;
        recording_state.saw_api_key = stream_options.api_key;
        recording_state.saw_responses_options = stream_options.providerOptions("responses");
        recording_state.saw_mistral_options = stream_options.providerOptions("mistral");
        recording_state.saw_anthropic_options = stream_options.providerOptions("anthropic");
        recording_state.saw_bedrock_options = stream_options.providerOptions("bedrock");
    }

    const result_allocator = std.heap.page_allocator;
    const text = try result_allocator.dupe(u8, recording_state.response_text);
    const content = try result_allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, std.Io.failing);
    stream_instance.push(.{
        .event_type = .done,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream_instance;
}

const StreamContractFixtureError = error{
    CallbackFailed,
};

var failing_stream_calls: usize = 0;

fn failingContractStream(
    _: std.mem.Allocator,
    _: std.Io,
    _: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    failing_stream_calls += 1;
    return StreamContractFixtureError.CallbackFailed;
}

fn partialRuntimeFailureStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "partial" } }},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "ProviderParseFailure",
        .timestamp = 0,
    };
    stream_instance.push(.{ .event_type = .start });
    stream_instance.push(.{ .event_type = .text_start, .content_index = 0 });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial",
    });
    stream_instance.push(.{
        .event_type = .text_end,
        .content_index = 0,
        .content = "partial",
    });
    stream_instance.push(.{
        .event_type = .error_event,
        .error_message = message.error_message,
        .message = message,
    });
    return stream_instance;
}

fn recordingStreamSimple(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    recording_state.stream_simple_calls += 1;
    return recordingStream(allocator, io, model, context, options);
}

fn ownedDeltaStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    const result_allocator = std.heap.page_allocator;
    const text = try result_allocator.dupe(u8, "owned delta complete");
    const content = try result_allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    stream_instance.push(.{ .event_type = .start });
    stream_instance.push(.{ .event_type = .text_start, .content_index = 0 });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "owned "),
        .owns_delta = true,
    });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "delta "),
        .owns_delta = true,
    });
    stream_instance.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "complete"),
        .owns_delta = true,
    });
    stream_instance.push(.{ .event_type = .text_end, .content_index = 0 });
    stream_instance.push(.{
        .event_type = .done,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream_instance;
}

fn streamContractTestModel(api: []const u8, provider: []const u8, id: []const u8) types.Model {
    return .{
        .id = id,
        .name = "Stream Contract Model",
        .api = api,
        .provider = provider,
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
}

fn expectSingleTerminalError(
    stream_instance: *event_stream.AssistantMessageEventStream,
    expected_api: []const u8,
    expected_provider: []const u8,
    expected_model: []const u8,
    expected_stop_reason: types.StopReason,
    expected_error: []const u8,
) !void {
    const event = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(expected_error, event.error_message.?);
    try std.testing.expectEqualStrings(expected_error, event.message.?.error_message.?);
    try std.testing.expectEqualStrings(expected_api, event.message.?.api);
    try std.testing.expectEqualStrings(expected_provider, event.message.?.provider);
    try std.testing.expectEqualStrings(expected_model, event.message.?.model);
    try std.testing.expectEqual(expected_stop_reason, event.message.?.stop_reason);
    try std.testing.expectEqual(@as(i64, 0), event.message.?.timestamp);
    try std.testing.expect(stream_instance.next() == null);

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqual(event.message.?.stop_reason, result.stop_reason);
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(event.message.?.timestamp, result.timestamp);
}

test "stream routes to registered provider" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "hello from stream";

    try api_registry.register(.{
        .api = "recording:test:stream",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:stream",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();
    while (stream_instance.next()) |_| {}

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings("hello from stream", result.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 0), recording_state.stream_simple_calls);
}

test "phase4 provider expansion models route through shared api streams" {
    api_registry.resetForTesting();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "openai-completions",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });
    try api_registry.register(.{
        .api = "anthropic-messages",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const cases = [_]struct {
        provider: []const u8,
        expected_api: []const u8,
    }{
        .{ .provider = "xai", .expected_api = "openai-completions" },
        .{ .provider = "groq", .expected_api = "openai-completions" },
        .{ .provider = "cerebras", .expected_api = "openai-completions" },
        .{ .provider = "openrouter", .expected_api = "openai-completions" },
        .{ .provider = "vercel-ai-gateway", .expected_api = "anthropic-messages" },
        .{ .provider = "zai", .expected_api = "openai-completions" },
        .{ .provider = "minimax", .expected_api = "anthropic-messages" },
        .{ .provider = "moonshotai", .expected_api = "openai-completions" },
        .{ .provider = "moonshotai-cn", .expected_api = "openai-completions" },
        .{ .provider = "kimi-code-openai", .expected_api = "openai-completions" },
        .{ .provider = "cloudflare-workers-ai", .expected_api = "openai-completions" },
        .{ .provider = "cloudflare-ai-gateway", .expected_api = "openai-completions" },
        .{ .provider = "huggingface", .expected_api = "openai-completions" },
        .{ .provider = "fireworks", .expected_api = "anthropic-messages" },
        .{ .provider = "opencode", .expected_api = "openai-completions" },
        .{ .provider = "xiaomi", .expected_api = "anthropic-messages" },
        .{ .provider = "xiaomi-token-plan-cn", .expected_api = "anthropic-messages" },
        .{ .provider = "xiaomi-token-plan-ams", .expected_api = "anthropic-messages" },
        .{ .provider = "xiaomi-token-plan-sgp", .expected_api = "anthropic-messages" },
    };

    for (cases) |case| {
        resetRecordingState();
        recording_state.response_text = case.provider;

        const provider_config = model_registry.getProviderConfig(case.provider).?;
        const model = model_registry.find(case.provider, provider_config.default_model_id.?).?;

        var stream_instance = try stream(
            std.testing.allocator,
            std.Io.failing,
            model,
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();
        while (stream_instance.next()) |_| {}

        const result = stream_instance.result().?;
        try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
        try std.testing.expectEqualStrings(case.expected_api, recording_state.saw_model_api.?);
        try std.testing.expectEqualStrings(case.provider, recording_state.saw_model_provider.?);
        try std.testing.expectEqualStrings(provider_config.default_model_id.?, recording_state.saw_model_id.?);
        try std.testing.expectEqualStrings(case.provider, result.content[0].text.text);
        try std.testing.expectEqualStrings(case.provider, result.provider);
        try std.testing.expectEqualStrings(case.expected_api, result.api);
    }
}

test "streamSimple maps simple options and routes through provider streamSimple" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "simple complete";

    try api_registry.register(.{
        .api = "recording:test",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var stream_instance = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{
            .temperature = 0.25,
            .max_tokens = 42,
            .api_key = "test-key",
        },
    );
    defer stream_instance.deinit();
    while (stream_instance.next()) |_| {}

    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_simple_calls);
    try std.testing.expectEqual(@as(?u32, 42), recording_state.saw_max_tokens);
    try std.testing.expectEqual(@as(?f32, 0.25), recording_state.saw_temperature);
    try std.testing.expectEqualStrings("test-key", recording_state.saw_api_key.?);
    try std.testing.expect(recording_state.saw_mistral_options.?.prompt_mode == null);
    try std.testing.expect(recording_state.saw_mistral_options.?.reasoning_effort == null);
}

test "streamSimple routes Bedrock fixed reasoning through provider adjustment" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "bedrock-converse-stream",
        .stream = recordingStream,
        .stream_simple = struct {
            fn f(
                allocator: std.mem.Allocator,
                io: std.Io,
                model: types.Model,
                context: types.Context,
                options: ?types.StreamOptions,
            ) !event_stream.AssistantMessageEventStream {
                recording_state.stream_simple_calls += 1;
                const base = options orelse types.StreamOptions{};
                const bedrock_opts = base.providerOptions("bedrock");
                const adjusted = simple_options_mod.adjustMaxTokensForThinking(
                    base.max_tokens orelse 0,
                    model.max_tokens,
                    bedrock_opts.reasoning.?,
                    bedrock_opts.thinking_budgets,
                );
                var provider_options = base;
                provider_options.max_tokens = adjusted.max_tokens;
                var budgets = bedrock_opts.thinking_budgets orelse types.ThinkingBudgets{};
                budgets.high = adjusted.thinking_budget;
                var updated_bedrock = bedrock_opts;
                updated_bedrock.thinking_budgets = budgets;
                provider_options.provider.bedrock = updated_bedrock;
                return recordingStream(allocator, io, model, context, provider_options);
            }
        }.f,
    });

    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };

    resetRecordingState();
    var stream_instance = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .max_tokens = 128, .reasoning = .high },
    );
    defer stream_instance.deinit();
    while (stream_instance.next()) |_| {}

    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_simple_calls);
    try std.testing.expectEqual(@as(?u32, 4096), recording_state.saw_max_tokens);
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .high), recording_state.saw_bedrock_options.?.reasoning);
    try std.testing.expectEqual(@as(u32, 3072), recording_state.saw_bedrock_options.?.thinking_budgets.?.high);
}

test "streamSimple maps Mistral reasoning to provider options" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "mistral-conversations",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const medium_model = types.Model{
        .id = "mistral-medium-latest",
        .name = "Mistral Medium",
        .api = "mistral-conversations",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 131072,
        .max_tokens = 32768,
    };

    resetRecordingState();
    var medium_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        medium_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .medium },
    );
    defer medium_stream.deinit();
    while (medium_stream.next()) |_| {}

    try std.testing.expectEqualStrings("reasoning", recording_state.saw_mistral_options.?.prompt_mode.?);
    try std.testing.expect(recording_state.saw_mistral_options.?.reasoning_effort == null);

    const small_model = types.Model{
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

    resetRecordingState();
    var small_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        small_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .high },
    );
    defer small_stream.deinit();
    while (small_stream.next()) |_| {}

    try std.testing.expect(recording_state.saw_mistral_options.?.prompt_mode == null);
    try std.testing.expectEqualStrings("high", recording_state.saw_mistral_options.?.reasoning_effort.?);
}

test "streamSimple maps Anthropic reasoning to provider options" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "anthropic-messages",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const adaptive_model = types.Model{
        .id = "claude-sonnet-4-6",
        .name = "Claude Sonnet 4.6",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    resetRecordingState();
    var no_reasoning_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        adaptive_model,
        .{ .messages = &[_]types.Message{} },
        .{},
    );
    defer no_reasoning_stream.deinit();
    while (no_reasoning_stream.next()) |_| {}

    try std.testing.expectEqual(@as(?bool, false), recording_state.saw_anthropic_options.?.thinking_enabled);
    try std.testing.expect(recording_state.saw_anthropic_options.?.effort == null);

    resetRecordingState();
    var adaptive_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        adaptive_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .medium },
    );
    defer adaptive_stream.deinit();
    while (adaptive_stream.next()) |_| {}

    try std.testing.expectEqual(@as(?bool, true), recording_state.saw_anthropic_options.?.thinking_enabled);
    try std.testing.expectEqual(@as(?types.AnthropicEffort, .medium), recording_state.saw_anthropic_options.?.effort);
    try std.testing.expect(recording_state.saw_anthropic_options.?.thinking_budget_tokens == null);

    const opus46_model = types.Model{
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

    resetRecordingState();
    var opus46_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        opus46_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .xhigh },
    );
    defer opus46_stream.deinit();
    while (opus46_stream.next()) |_| {}

    try std.testing.expectEqual(@as(?types.AnthropicEffort, .max), recording_state.saw_anthropic_options.?.effort);

    const opus47_model = types.Model{
        .id = "claude-opus-4-7",
        .name = "Claude Opus 4.7",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    resetRecordingState();
    var opus47_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        opus47_model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .xhigh },
    );
    defer opus47_stream.deinit();
    while (opus47_stream.next()) |_| {}

    try std.testing.expectEqual(@as(?types.AnthropicEffort, .xhigh), recording_state.saw_anthropic_options.?.effort);

    const legacy_model = types.Model{
        .id = "claude-3-7-sonnet-latest",
        .name = "Claude 3.7 Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 64000,
    };

    resetRecordingState();
    var legacy_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        legacy_model,
        .{ .messages = &[_]types.Message{} },
        .{
            .reasoning = .medium,
            .thinking_budgets = .{ .medium = 4096 },
        },
    );
    defer legacy_stream.deinit();
    while (legacy_stream.next()) |_| {}

    try std.testing.expectEqual(@as(?bool, true), recording_state.saw_anthropic_options.?.thinking_enabled);
    try std.testing.expectEqual(@as(?u32, 4096), recording_state.saw_anthropic_options.?.thinking_budget_tokens);
    // Mirror TS fix(ai) #4539: defaultMaxTokens no longer caps at 32000;
    // adjustMaxTokensForThinking now clamps to model.max_tokens (64000)
    // when base + budget would exceed it.
    try std.testing.expectEqual(@as(?u32, 64000), recording_state.saw_max_tokens);
}

test "streamSimple preserves xhigh reasoning for Codex GPT-5.5" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();

    try api_registry.register(.{
        .api = "openai-codex-responses",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "gpt-5.5",
        .name = "Codex GPT-5.5",
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .thinking_level_map = .{ .xhigh = .{ .mapped = "xhigh" } },
        .input_types = &[_][]const u8{"text"},
        .context_window = 400000,
        .max_tokens = 128000,
    };

    var stream_instance = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .reasoning = .xhigh },
    );
    defer stream_instance.deinit();

    _ = stream_instance.next();
    try std.testing.expectEqual(@as(?types.ThinkingLevel, .xhigh), recording_state.saw_responses_options.?.reasoning_effort);
}

test "complete returns final assistant message" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "hello from complete";

    try api_registry.register(.{
        .api = "recording:test:complete",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:complete",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const result = try complete(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );

    try std.testing.expectEqualStrings("hello from complete", result.content[0].text.text);
}

test "complete frees owned streaming deltas after consumption" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "recording:test:owned-delta",
        .stream = ownedDeltaStream,
        .stream_simple = ownedDeltaStream,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:owned-delta",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const result = try complete(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );

    try std.testing.expectEqualStrings("owned delta complete", result.content[0].text.text);
}

test "completeSimple returns final assistant message from simple options" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "simple complete";

    try api_registry.register(.{
        .api = "recording:test:complete-simple",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = types.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:complete-simple",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const result = try completeSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .max_tokens = 7 },
    );

    try std.testing.expectEqualStrings("simple complete", result.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_calls);
    try std.testing.expectEqual(@as(usize, 1), recording_state.stream_simple_calls);
}

test "ISS-401 stream returns terminal error stream for unknown provider lookup failure" {
    api_registry.clear();
    defer api_registry.clear();

    const model = streamContractTestModel("missing-contract-api", "missing-provider", "missing-model");
    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();

    try expectSingleTerminalError(
        &stream_instance,
        "missing-contract-api",
        "missing-provider",
        "missing-model",
        .error_reason,
        "ProviderNotFound",
    );
}

test "ISS-401 stream converts provider setup callback failure into terminal error stream" {
    api_registry.clear();
    defer api_registry.clear();
    failing_stream_calls = 0;

    try api_registry.register(.{
        .api = "recording:test:callback-failure",
        .stream = failingContractStream,
        .stream_simple = failingContractStream,
    });

    const model = streamContractTestModel("recording:test:callback-failure", "recording", "recording-model");
    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();

    try std.testing.expectEqual(@as(usize, 1), failing_stream_calls);
    try expectSingleTerminalError(
        &stream_instance,
        "recording:test:callback-failure",
        "recording",
        "recording-model",
        .error_reason,
        "CallbackFailed",
    );
}

test "ISS-401 complete and streamSimple preserve provider failure stream semantics" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "recording:test:simple-failure",
        .stream = failingContractStream,
        .stream_simple = failingContractStream,
    });

    const model = streamContractTestModel("recording:test:simple-failure", "recording", "recording-model");
    var simple_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .api_key = "fixture-key" },
    );
    defer simple_stream.deinit();

    try expectSingleTerminalError(
        &simple_stream,
        "recording:test:simple-failure",
        "recording",
        "recording-model",
        .error_reason,
        "CallbackFailed",
    );

    const result = try complete(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );

    try std.testing.expectEqualStrings("recording:test:simple-failure", result.api);
    try std.testing.expectEqualStrings("recording", result.provider);
    try std.testing.expectEqualStrings("recording-model", result.model);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("CallbackFailed", result.error_message.?);
}

test "ISS-401 complete and streamSimple preserve partial runtime provider failure stream semantics" {
    api_registry.clear();
    defer api_registry.clear();

    try api_registry.register(.{
        .api = "recording:test:runtime-partial-failure",
        .stream = partialRuntimeFailureStream,
        .stream_simple = partialRuntimeFailureStream,
    });

    const model = streamContractTestModel("recording:test:runtime-partial-failure", "recording", "recording-model");
    var simple_stream = try streamSimple(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        .{ .api_key = "fixture-key" },
    );
    defer simple_stream.deinit();

    try std.testing.expectEqual(types.EventType.start, simple_stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, simple_stream.next().?.event_type);
    const delta = simple_stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, simple_stream.next().?.event_type);
    const terminal = simple_stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expectEqualStrings("ProviderParseFailure", terminal.error_message.?);
    try std.testing.expect(simple_stream.next() == null);

    const simple_result = simple_stream.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, simple_result.error_message.?);
    try std.testing.expectEqualStrings("partial", simple_result.content[0].text.text);

    const result = try complete(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );

    try std.testing.expectEqualStrings("recording:test:runtime-partial-failure", result.api);
    try std.testing.expectEqualStrings("recording", result.provider);
    try std.testing.expectEqualStrings("recording-model", result.model);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("ProviderParseFailure", result.error_message.?);
    try std.testing.expectEqualStrings("partial", result.content[0].text.text);
}

test "ISS-401 pre-start abort takes precedence over provider lookup and setup failures" {
    api_registry.clear();
    defer api_registry.clear();
    failing_stream_calls = 0;

    try api_registry.register(.{
        .api = "recording:test:abort-precedence",
        .stream = failingContractStream,
        .stream_simple = failingContractStream,
    });

    var aborted = std.atomic.Value(bool).init(true);
    const options = types.StreamOptions{ .signal = &aborted };
    const model = streamContractTestModel("recording:test:abort-precedence", "recording", "recording-model");
    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        options,
    );
    defer stream_instance.deinit();

    try std.testing.expectEqual(@as(usize, 0), failing_stream_calls);
    try expectSingleTerminalError(
        &stream_instance,
        "recording:test:abort-precedence",
        "recording",
        "recording-model",
        .aborted,
        "Request was aborted",
    );

    var missing_provider_stream = try stream(
        std.testing.allocator,
        std.Io.failing,
        streamContractTestModel("missing-contract-api", "missing-provider", "missing-model"),
        .{ .messages = &[_]types.Message{} },
        options,
    );
    defer missing_provider_stream.deinit();

    try expectSingleTerminalError(
        &missing_provider_stream,
        "missing-contract-api",
        "missing-provider",
        "missing-model",
        .aborted,
        "Request was aborted",
    );
}

test "ISS-505 successful provider stream exposes one done terminal and null afterwards" {
    api_registry.clear();
    defer api_registry.clear();
    resetRecordingState();
    recording_state.response_text = "iss-505 complete";

    try api_registry.register(.{
        .api = "recording:test:iss-505-success",
        .stream = recordingStream,
        .stream_simple = recordingStreamSimple,
    });

    const model = streamContractTestModel("recording:test:iss-505-success", "recording", "recording-model");
    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();

    const terminal = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("recording:test:iss-505-success", terminal.message.?.api);
    try std.testing.expectEqualStrings("recording", terminal.message.?.provider);
    try std.testing.expectEqualStrings("recording-model", terminal.message.?.model);
    try std.testing.expectEqual(types.StopReason.stop, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("iss-505 complete", terminal.message.?.content[0].text.text);
    try std.testing.expect(stream_instance.next() == null);

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings(terminal.message.?.api, result.api);
    try std.testing.expectEqualStrings(terminal.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(terminal.message.?.model, result.model);
    try std.testing.expectEqual(terminal.message.?.stop_reason, result.stop_reason);
    try std.testing.expectEqualStrings(terminal.message.?.content[0].text.text, result.content[0].text.text);
}

test "ISS-505 provider setup failure exposes one terminal error output and null afterwards" {
    api_registry.clear();
    defer api_registry.clear();
    failing_stream_calls = 0;

    try api_registry.register(.{
        .api = "recording:test:iss-505-error",
        .stream = failingContractStream,
        .stream_simple = failingContractStream,
    });

    const model = streamContractTestModel("recording:test:iss-505-error", "recording", "recording-model");
    var stream_instance = try stream(
        std.testing.allocator,
        std.Io.failing,
        model,
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();

    try std.testing.expectEqual(@as(usize, 1), failing_stream_calls);
    try expectSingleTerminalError(
        &stream_instance,
        "recording:test:iss-505-error",
        "recording",
        "recording-model",
        .error_reason,
        "CallbackFailed",
    );
}

test "ISS-505 built-in representative provider families convert setup failures into terminal streams without network" {
    api_registry.resetForTesting();
    defer api_registry.clear();

    const cases = [_]struct {
        api: []const u8,
        provider: []const u8,
    }{
        .{ .api = "openai-completions", .provider = "openai" },
        .{ .api = "openai-responses", .provider = "openai" },
        .{ .api = "azure-openai-responses", .provider = "azure-openai-responses" },
        .{ .api = "openai-codex-responses", .provider = "openai-codex" },
        .{ .api = "anthropic-messages", .provider = "anthropic" },
        .{ .api = "kimi-completions", .provider = "kimi" },
        .{ .api = "mistral-conversations", .provider = "mistral" },
        .{ .api = "google-generative-ai", .provider = "google" },
        .{ .api = "google-vertex", .provider = "google-vertex" },
        .{ .api = "bedrock-converse-stream", .provider = "amazon-bedrock" },
    };

    for (cases) |case| {
        try register_builtins.setProviderOverride(case.api, .{
            .stream = failingContractStream,
            .stream_simple = failingContractStream,
        });
    }
    api_registry.resetToBuiltIns();

    for (cases) |case| {
        const model = streamContractTestModel(case.api, case.provider, "fixture-model");
        var stream_instance = try stream(
            std.testing.allocator,
            std.Io.failing,
            model,
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();

        try expectSingleTerminalError(
            &stream_instance,
            case.api,
            case.provider,
            "fixture-model",
            .error_reason,
            "CallbackFailed",
        );
    }
}
