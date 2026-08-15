const std = @import("std");
const api_registry = @import("../api_registry.zig");
const event_stream = @import("../event_stream.zig");
const provider_json = @import("../shared/provider_json.zig");
const register_builtins = @import("register_builtins.zig");
const stream_ops = @import("../stream.zig");
const types = @import("../types.zig");

const ToolCallOwnershipContract = enum {
    normalized_inline,
    legacy_dual_allocated,
};

const ToolCallOwnershipCase = struct {
    label: []const u8,
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    contract: ToolCallOwnershipContract,
    built_in: bool = true,
};

const tool_call_ownership_matrix = [_]ToolCallOwnershipCase{
    .{ .label = "Anthropic", .api = "anthropic-messages", .provider = "anthropic", .model = "claude-3-7-sonnet", .contract = .normalized_inline },
    .{ .label = "OpenAI Completions / openai_chat_sse", .api = "openai-completions", .provider = "openai", .model = "gpt-4.1-mini", .contract = .legacy_dual_allocated },
    .{ .label = "Legacy Kimi/Moonshot", .api = "kimi-completions", .provider = "kimi", .model = "kimi-k2.6", .contract = .normalized_inline },
    .{ .label = "Kimi Code Anthropic Compatible", .api = "anthropic-messages", .provider = "kimi-coding", .model = "kimi-for-coding", .contract = .normalized_inline, .built_in = false },
    .{ .label = "Kimi Code OpenAI Compatible / openai_chat_sse", .api = "openai-completions", .provider = "kimi-code-openai", .model = "kimi-for-coding", .contract = .legacy_dual_allocated, .built_in = false },
    .{ .label = "Mistral", .api = "mistral-conversations", .provider = "mistral", .model = "mistral-medium-latest", .contract = .normalized_inline },
    .{ .label = "OpenAI Responses", .api = "openai-responses", .provider = "openai", .model = "gpt-5-mini", .contract = .normalized_inline },
    .{ .label = "Azure OpenAI Responses", .api = "azure-openai-responses", .provider = "azure-openai-responses", .model = "azure-gpt-5-mini", .contract = .normalized_inline },
    .{ .label = "OpenAI Codex Responses", .api = "openai-codex-responses", .provider = "openai-codex", .model = "codex-mini-latest", .contract = .normalized_inline },
    .{ .label = "Google Generative AI", .api = "google-generative-ai", .provider = "google", .model = "gemini-2.5-pro", .contract = .normalized_inline },
    .{ .label = "Google Vertex", .api = "google-vertex", .provider = "google-vertex", .model = "gemini-2.5-pro", .contract = .normalized_inline },
    .{ .label = "Amazon Bedrock", .api = "bedrock-converse-stream", .provider = "amazon-bedrock", .model = "anthropic.claude-3-7-sonnet-20250219-v1:0", .contract = .normalized_inline },
    .{ .label = "Faux", .api = "faux", .provider = "faux", .model = "faux-contract-model", .contract = .normalized_inline, .built_in = false },
};

const freeToolCallOwned = types.freeToolCall;
const freeAssistantMessageOwned = types.freeAssistantMessage;

fn freeEventOwned(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) void {
    event.deinitTransient(allocator);
    if (event.tool_call) |tool_call| freeToolCallOwned(allocator, tool_call);
    if (event.error_message) |error_message| allocator.free(error_message);
}

fn toolArguments(allocator: std.mem.Allocator) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "city"), .{ .string = try allocator.dupe(u8, "Berlin") });
    return .{ .object = object };
}

fn ownedToolCall(allocator: std.mem.Allocator) !types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, "call_contract_1"),
        .name = try allocator.dupe(u8, "get_weather"),
        .arguments = try toolArguments(allocator),
    };
}

fn ownedToolCallClone(allocator: std.mem.Allocator, tool_call: types.ToolCall) !types.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);
    const arguments = try provider_json.cloneValue(allocator, tool_call.arguments);
    errdefer provider_json.freeValue(allocator, arguments);
    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
        .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
    };
}

fn contractForApiAndProvider(api: []const u8, provider: []const u8) ToolCallOwnershipContract {
    for (tool_call_ownership_matrix) |case| {
        if (std.mem.eql(u8, api, case.api) and std.mem.eql(u8, provider, case.provider)) {
            return case.contract;
        }
    }
    return .normalized_inline;
}

fn runtimeToolCallStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    _: types.Context,
    _: ?types.StreamOptions,
) !event_stream.AssistantMessageEventStream {
    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream_instance.deinit();

    const inline_tool_call = try ownedToolCall(allocator);
    errdefer freeToolCallOwned(allocator, inline_tool_call);

    const content = try allocator.alloc(types.ContentBlock, 1);
    errdefer allocator.free(content);
    content[0] = .{ .tool_call = inline_tool_call };

    const event_tool_call = try ownedToolCallClone(allocator, inline_tool_call);
    errdefer freeToolCallOwned(allocator, event_tool_call);

    var legacy_tool_calls: ?[]types.ToolCall = null;
    if (contractForApiAndProvider(model.api, model.provider) == .legacy_dual_allocated) {
        legacy_tool_calls = try allocator.alloc(types.ToolCall, 1);
        errdefer allocator.free(legacy_tool_calls.?);
        legacy_tool_calls.?[0] = try ownedToolCallClone(allocator, inline_tool_call);
    }

    stream_instance.push(.{ .event_type = .start });
    stream_instance.push(.{
        .event_type = .toolcall_start,
        .content_index = 0,
    });
    stream_instance.push(.{
        .event_type = .toolcall_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "{\"city\":\"Berlin\"}"),
        .owns_delta = true,
    });
    stream_instance.push(.{
        .event_type = .toolcall_end,
        .content_index = 0,
        .tool_call = event_tool_call,
    });
    stream_instance.push(.{
        .event_type = .done,
        .message = .{
            .role = "assistant",
            .content = content,
            .tool_calls = legacy_tool_calls,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = types.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 0,
        },
    });
    return stream_instance;
}

fn contractModel(case: ToolCallOwnershipCase) types.Model {
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
    for (tool_call_ownership_matrix) |case| {
        if (case.built_in and std.mem.eql(u8, case.api, api)) return true;
    }
    return false;
}

fn expectMatrixCoversBuiltIns() !void {
    var built_in_count: usize = 0;
    for (tool_call_ownership_matrix) |case| {
        if (!case.built_in) continue;
        built_in_count += 1;
        try std.testing.expect(containsExpectedBuiltInApi(case.api));
    }

    try std.testing.expectEqual(register_builtins.expectedBuiltInApiCount(), built_in_count);
    for (register_builtins.expectedBuiltInApis()) |api| {
        try std.testing.expect(containsMatrixBuiltInApi(api));
    }
}

fn configureProviderMatrix() !void {
    api_registry.resetForTesting();

    for (tool_call_ownership_matrix) |case| {
        if (!case.built_in) continue;
        try register_builtins.setProviderOverride(case.api, .{
            .stream = runtimeToolCallStream,
            .stream_simple = runtimeToolCallStream,
        });
    }

    api_registry.resetToBuiltIns();
    try api_registry.register(.{
        .api = "faux",
        .stream = runtimeToolCallStream,
        .stream_simple = runtimeToolCallStream,
    });
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

fn expectToolCallMessage(case: ToolCallOwnershipCase, message: types.AssistantMessage) !void {
    try std.testing.expectEqualStrings(case.api, message.api);
    try std.testing.expectEqualStrings(case.provider, message.provider);
    try std.testing.expectEqualStrings(case.model, message.model);
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), message.content.len);
    try std.testing.expect(message.content[0] == .tool_call);
    try std.testing.expectEqualStrings("call_contract_1", message.content[0].tool_call.id);
    try std.testing.expectEqualStrings("get_weather", message.content[0].tool_call.name);
    try std.testing.expectEqualStrings("Berlin", message.content[0].tool_call.arguments.object.get("city").?.string);
}

fn expectToolCallOwnershipCase(allocator: std.mem.Allocator, case: ToolCallOwnershipCase) !void {
    var stream_instance = try stream_ops.stream(
        allocator,
        std.Io.failing,
        contractModel(case),
        .{ .messages = &[_]types.Message{} },
        null,
    );
    defer stream_instance.deinit();

    var saw_done = false;
    while (stream_instance.next()) |event| {
        switch (event.event_type) {
            .start => {},
            .toolcall_start => {
                try std.testing.expectEqual(@as(?u32, 0), event.content_index);
            },
            .toolcall_delta => {
                defer freeEventOwned(allocator, event);
                try std.testing.expectEqual(@as(?u32, 0), event.content_index);
                try std.testing.expectEqualStrings("{\"city\":\"Berlin\"}", event.delta.?);
            },
            .toolcall_end => {
                defer freeEventOwned(allocator, event);
                try std.testing.expectEqual(@as(?u32, 0), event.content_index);
                try std.testing.expectEqualStrings("get_weather", event.tool_call.?.name);
            },
            .done => {
                defer freeAssistantMessageOwned(allocator, event.message.?);
                try expectToolCallMessage(case, event.message.?);
                switch (case.contract) {
                    .normalized_inline => try std.testing.expect(event.message.?.tool_calls == null),
                    .legacy_dual_allocated => {
                        try std.testing.expect(event.message.?.tool_calls != null);
                        try std.testing.expectEqual(@as(usize, 1), event.message.?.tool_calls.?.len);
                        try std.testing.expect(event.message.?.tool_calls.?[0].id.ptr != event.message.?.content[0].tool_call.id.ptr);
                        try std.testing.expect(event.message.?.tool_calls.?[0].name.ptr != event.message.?.content[0].tool_call.name.ptr);
                    },
                }
                saw_done = true;
            },
            else => {
                freeEventOwned(allocator, event);
                try std.testing.expect(false);
            },
        }
    }

    try std.testing.expect(saw_done);
}

fn readFixtureJson(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        path,
        allocator,
        .limited(1_000_000),
    );
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn objectFieldString(value: std.json.Value, field: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidFixtureField;
    const field_value = value.object.get(field) orelse return error.MissingFixtureField;
    if (field_value != .string) return error.InvalidFixtureField;
    return field_value.string;
}

fn expectFieldContains(value: std.json.Value, field: []const u8, needle: []const u8) !void {
    const haystack = try objectFieldString(value, field);
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectScenarioPresent(manifest: std.json.Value, scenario_id: []const u8) !void {
    if (manifest != .object) return error.InvalidFixtureField;
    const scenario_ids = manifest.object.get("scenarioIds") orelse return error.MissingFixtureField;
    if (scenario_ids != .array) return error.InvalidFixtureField;
    for (scenario_ids.array.items) |value| {
        if (value == .string and std.mem.eql(u8, value.string, scenario_id)) return;
    }
    return error.MissingScenarioFixture;
}

test "ISS-200 provider stream matrix covers every built-in API for tool-call ownership" {
    try expectMatrixCoversBuiltIns();
}

test "ISS-201 debug allocator covers provider tool-call ownership matrix without leaks" {
    try expectMatrixCoversBuiltIns();
    try configureProviderMatrix();
    defer api_registry.resetForTesting();

    for (tool_call_ownership_matrix) |case| {
        var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
        try expectToolCallOwnershipCase(debug_allocator.allocator(), case);
        try std.testing.expectEqual(.ok, debug_allocator.deinit());
    }
}

test "ISS-200 ISS-201 normalized provider tool-call streams use inline-only ownership without leaks" {
    try expectMatrixCoversBuiltIns();
    try configureProviderMatrix();
    defer api_registry.resetForTesting();

    for (tool_call_ownership_matrix) |case| {
        if (case.contract != .normalized_inline) continue;

        var stream_instance = try stream_ops.stream(
            std.testing.allocator,
            std.Io.failing,
            contractModel(case),
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();

        _ = try expectNextEventType(&stream_instance, .start);
        _ = try expectNextEventType(&stream_instance, .toolcall_start);
        const delta = try expectNextEventType(&stream_instance, .toolcall_delta);
        defer freeEventOwned(std.testing.allocator, delta);
        try std.testing.expectEqualStrings("{\"city\":\"Berlin\"}", delta.delta.?);
        const tool_end = try expectNextEventType(&stream_instance, .toolcall_end);
        defer freeEventOwned(std.testing.allocator, tool_end);
        try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);

        const done = try expectNextEventType(&stream_instance, .done);
        defer freeAssistantMessageOwned(std.testing.allocator, done.message.?);
        try expectToolCallMessage(case, done.message.?);
        try std.testing.expect(done.message.?.tool_calls == null);
        try std.testing.expect(stream_instance.next() == null);

        const result = stream_instance.result().?;
        try expectToolCallMessage(case, result);
        try std.testing.expect(result.tool_calls == null);
    }
}

test "ISS-200 preserves openai_chat_sse dual-allocation exception in matrix" {
    try configureProviderMatrix();
    defer api_registry.resetForTesting();

    for (tool_call_ownership_matrix) |case| {
        if (case.contract != .legacy_dual_allocated) continue;

        var stream_instance = try stream_ops.stream(
            std.testing.allocator,
            std.Io.failing,
            contractModel(case),
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();

        while (stream_instance.next()) |event| {
            if (event.event_type == .done) {
                defer freeAssistantMessageOwned(std.testing.allocator, event.message.?);
                try expectToolCallMessage(case, event.message.?);
                try std.testing.expect(event.message.?.tool_calls != null);
                try std.testing.expectEqual(@as(usize, 1), event.message.?.tool_calls.?.len);
                try std.testing.expectEqualStrings("get_weather", event.message.?.tool_calls.?[0].name);
                try std.testing.expect(event.message.?.tool_calls.?[0].id.ptr != event.message.?.content[0].tool_call.id.ptr);
                try std.testing.expect(event.message.?.tool_calls.?[0].name.ptr != event.message.?.content[0].tool_call.name.ptr);
            } else {
                freeEventOwned(std.testing.allocator, event);
            }
        }
    }
}

test "ISS-100 OpenAI Chat dual-allocation exception stays isolated to chat-compatible streams" {
    try configureProviderMatrix();
    defer api_registry.resetForTesting();

    var legacy_count: usize = 0;
    for (tool_call_ownership_matrix) |case| {
        var stream_instance = try stream_ops.stream(
            std.testing.allocator,
            std.Io.failing,
            contractModel(case),
            .{ .messages = &[_]types.Message{} },
            null,
        );
        defer stream_instance.deinit();

        while (stream_instance.next()) |event| {
            if (event.event_type == .done) {
                defer freeAssistantMessageOwned(std.testing.allocator, event.message.?);
                try expectToolCallMessage(case, event.message.?);
                switch (case.contract) {
                    .legacy_dual_allocated => {
                        legacy_count += 1;
                        try std.testing.expectEqualStrings("openai-completions", case.api);
                        try std.testing.expect(event.message.?.tool_calls != null);
                        try std.testing.expect(event.message.?.tool_calls.?[0].id.ptr != event.message.?.content[0].tool_call.id.ptr);
                        try std.testing.expect(event.message.?.tool_calls.?[0].name.ptr != event.message.?.content[0].tool_call.name.ptr);
                    },
                    .normalized_inline => try std.testing.expect(event.message.?.tool_calls == null),
                }
            } else {
                freeEventOwned(std.testing.allocator, event);
            }
        }
        try std.testing.expect(stream_instance.next() == null);
    }

    try std.testing.expectEqual(@as(usize, 2), legacy_count);
}

test "ISS-100 OpenAI Chat parity manifest remains local mocked fetch with chat-specific stream fixtures" {
    const allocator = std.testing.allocator;
    const manifest = try readFixtureJson(allocator, "test/golden/openai-chat/manifest.json");
    defer manifest.deinit();

    try std.testing.expectEqualStrings(
        "zig/test/generate-openai-chat-fixtures.ts",
        try objectFieldString(manifest.value, "generatedBy"),
    );
    try expectFieldContains(manifest.value, "captureBoundary", "OpenAI Chat request");
    try expectFieldContains(manifest.value, "network", "local mocked global fetch only");
    try expectFieldContains(manifest.value, "network", "unhandled requests throw");
    try expectScenarioPresent(manifest.value, "signature-stream-multi-tool");
    try expectScenarioPresent(manifest.value, "signature-cross-model-stripped");
}

test "VAL-PROVIDER-010 provider parity manifests declare local no-network fixture boundaries" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        path: []const u8,
        generated_by: []const u8,
        network_needles: []const []const u8,
    }{
        .{
            .path = "test/golden/openai-chat/manifest.json",
            .generated_by = "zig/test/generate-openai-chat-fixtures.ts",
            .network_needles = &[_][]const u8{ "local mocked global fetch only", "unhandled requests throw" },
        },
        .{
            .path = "test/golden/openai-responses/manifest.json",
            .generated_by = "zig/test/generate-openai-responses-fixtures.ts",
            .network_needles = &[_][]const u8{ "local mocked global fetch only", "unhandled requests throw" },
        },
        .{
            .path = "test/golden/bedrock/manifest.json",
            .generated_by = "zig/test/generate-bedrock-fixtures.ts",
            .network_needles = &[_][]const u8{ "local BedrockRuntimeClient.send mock only", "no AWS metadata", "credential store", "remote Bedrock access" },
        },
    };

    for (cases) |case| {
        const manifest = try readFixtureJson(allocator, case.path);
        defer manifest.deinit();
        try std.testing.expectEqualStrings(case.generated_by, try objectFieldString(manifest.value, "generatedBy"));
        for (case.network_needles) |needle| {
            try expectFieldContains(manifest.value, "network", needle);
        }
    }
}
