const std = @import("std");
const ai = @import("ai");

const api_registry = ai.api_registry;
const event_stream = ai.event_stream;
const register_builtins = ai.providers.register_builtins;
const types = ai.types;

const ProviderStreamContractError = error{
    ContractSetupFailure,
};

const ProviderStreamContractCase = struct {
    label: []const u8,
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    built_in: bool = true,
};

const provider_stream_contract_matrix = [_]ProviderStreamContractCase{
    .{ .label = "Anthropic", .api = "anthropic-messages", .provider = "anthropic", .model = "claude-3-7-sonnet" },
    .{ .label = "OpenAI Completions", .api = "openai-completions", .provider = "openai", .model = "gpt-4.1-mini" },
    .{ .label = "Legacy Kimi/Moonshot", .api = "kimi-completions", .provider = "kimi", .model = "kimi-k2.6" },
    .{ .label = "Kimi Code Anthropic Compatible", .api = "anthropic-messages", .provider = "kimi-coding", .model = "kimi-for-coding", .built_in = false },
    .{ .label = "Kimi Code OpenAI Compatible", .api = "openai-completions", .provider = "kimi-code-openai", .model = "kimi-for-coding", .built_in = false },
    .{ .label = "Mistral", .api = "mistral-conversations", .provider = "mistral", .model = "mistral-medium-latest" },
    .{ .label = "OpenAI Responses", .api = "openai-responses", .provider = "openai", .model = "gpt-5-mini" },
    .{ .label = "Azure OpenAI Responses", .api = "azure-openai-responses", .provider = "azure-openai-responses", .model = "azure-gpt-5-mini" },
    .{ .label = "OpenAI Codex Responses", .api = "openai-codex-responses", .provider = "openai-codex", .model = "codex-mini-latest" },
    .{ .label = "Google Generative AI", .api = "google-generative-ai", .provider = "google", .model = "gemini-2.5-pro" },
    .{ .label = "Google Vertex", .api = "google-vertex", .provider = "google-vertex", .model = "gemini-2.5-pro" },
    .{ .label = "Amazon Bedrock", .api = "bedrock-converse-stream", .provider = "amazon-bedrock", .model = "anthropic.claude-3-7-sonnet-20250219-v1:0" },
    .{ .label = "Faux", .api = "faux", .provider = "faux", .model = "faux-contract-model", .built_in = false },
};

fn setupFailureStream(
    _: std.mem.Allocator,
    _: std.Io,
    _: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    return ProviderStreamContractError.ContractSetupFailure;
}

fn runtimeFailureStream(
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
        .error_message = "ProviderRuntimeFailure",
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

fn contractModel(case: ProviderStreamContractCase) types.Model {
    return .{
        .id = case.model,
        .name = case.label,
        .api = case.api,
        .provider = case.provider,
        .base_url = "http://127.0.0.1:1",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
}

fn containsExpectedBuiltInApi(api: []const u8) bool {
    for (register_builtins.expectedBuiltInApis()) |expected| {
        if (std.mem.eql(u8, api, expected)) return true;
    }
    return false;
}

fn containsMatrixBuiltInApi(api: []const u8) bool {
    for (provider_stream_contract_matrix) |case| {
        if (case.built_in and std.mem.eql(u8, case.api, api)) return true;
    }
    return false;
}

fn expectMatrixCoversBuiltIns() !void {
    var built_in_count: usize = 0;
    for (provider_stream_contract_matrix) |case| {
        if (!case.built_in) continue;
        built_in_count += 1;
        try std.testing.expect(containsExpectedBuiltInApi(case.api));
    }

    try std.testing.expectEqual(register_builtins.expectedBuiltInApiCount(), built_in_count);
    for (register_builtins.expectedBuiltInApis()) |api| {
        try std.testing.expect(containsMatrixBuiltInApi(api));
    }
}

fn configureProviderMatrix(stream_fn: api_registry.StreamFunction) !void {
    api_registry.resetForTesting();

    for (provider_stream_contract_matrix) |case| {
        if (!case.built_in) continue;
        try register_builtins.setProviderOverride(case.api, .{
            .stream = stream_fn,
            .stream_simple = stream_fn,
        });
    }

    api_registry.resetToBuiltIns();
    try api_registry.register(.{
        .api = "faux",
        .stream = stream_fn,
        .stream_simple = stream_fn,
    });
}

fn expectTerminalErrorMetadata(
    stream_instance: *event_stream.AssistantMessageEventStream,
    case: ProviderStreamContractCase,
    expected_error: []const u8,
) !void {
    const event = stream_instance.next() orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings(expected_error, event.error_message.?);
    try std.testing.expectEqualStrings(expected_error, event.message.?.error_message.?);
    try std.testing.expectEqualStrings(case.api, event.message.?.api);
    try std.testing.expectEqualStrings(case.provider, event.message.?.provider);
    try std.testing.expectEqualStrings(case.model, event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(stream_instance.next() == null);

    const result = stream_instance.result().?;
    try std.testing.expectEqualStrings(case.api, result.api);
    try std.testing.expectEqualStrings(case.provider, result.provider);
    try std.testing.expectEqualStrings(case.model, result.model);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings(expected_error, result.error_message.?);
}

fn expectNextEventType(
    stream_instance: *event_stream.AssistantMessageEventStream,
    expected: types.EventType,
) !types.AssistantMessageEvent {
    const event = stream_instance.next() orelse {
        try std.testing.expect(false);
        return error.MissingEvent;
    };
    try std.testing.expectEqual(expected, event.event_type);
    return event;
}

test "provider stream contract matrix covers every built-in API plus faux" {
    try expectMatrixCoversBuiltIns();
}

test "provider stream contract matrix converts setup failures into terminal error streams" {
    try expectMatrixCoversBuiltIns();
    try configureProviderMatrix(setupFailureStream);
    defer api_registry.resetForTesting();

    for (provider_stream_contract_matrix) |case| {
        var stream_instance = try ai.stream(
            std.testing.allocator,
            std.Io.failing,
            contractModel(case),
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();

        try expectTerminalErrorMetadata(&stream_instance, case, "ContractSetupFailure");
    }
}

test "provider stream contract matrix preserves runtime terminal error streams" {
    try expectMatrixCoversBuiltIns();
    try configureProviderMatrix(runtimeFailureStream);
    defer api_registry.resetForTesting();

    for (provider_stream_contract_matrix) |case| {
        var stream_instance = try ai.stream(
            std.testing.allocator,
            std.Io.failing,
            contractModel(case),
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();

        _ = try expectNextEventType(&stream_instance, .start);
        _ = try expectNextEventType(&stream_instance, .text_start);
        const delta = try expectNextEventType(&stream_instance, .text_delta);
        try std.testing.expectEqualStrings("partial", delta.delta.?);
        const text_end = try expectNextEventType(&stream_instance, .text_end);
        try std.testing.expectEqualStrings("partial", text_end.content.?);
        try expectTerminalErrorMetadata(&stream_instance, case, "ProviderRuntimeFailure");

        const result = stream_instance.result().?;
        try std.testing.expectEqualStrings("partial", result.content[0].text.text);
    }
}
