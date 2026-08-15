const std = @import("std");
const types = @import("../types.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const model_registry = @import("../model_registry.zig");
const cloudflare = @import("cloudflare.zig");
const openai = @import("openai.zig");
const openai_responses = @import("openai_responses.zig");
const anthropic = @import("anthropic.zig");

const CaptureExpectation = struct {
    provider: []const u8,
    api: []const u8,
    model_id: []const u8,
    base_path: []const u8,
    expected_request_line: []const u8,
    expected_auth_header: []const u8,
    forbidden_auth_header: ?[]const u8 = null,
};

fn smokeContext() types.Context {
    return .{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "provider smoke" } }},
                .timestamp = 1,
            } },
        },
    };
}

fn smokeModel(expectation: CaptureExpectation, base_url: []const u8) types.Model {
    return .{
        .id = expectation.model_id,
        .name = "Provider Smoke Model",
        .api = expectation.api,
        .provider = expectation.provider,
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };
}

fn expectOnlyTerminalErrorMetadata(
    stream: *event_stream.AssistantMessageEventStream,
    expected_api: []const u8,
    expected_provider: []const u8,
    expected_model: []const u8,
) !void {
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.error_message != null);
    try std.testing.expect(event.error_message.?.len > 0);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(expected_api, event.message.?.api);
    try std.testing.expectEqualStrings(expected_provider, event.message.?.provider);
    try std.testing.expectEqualStrings(expected_model, event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(expected_api, result.api);
    try std.testing.expectEqualStrings(expected_provider, result.provider);
    try std.testing.expectEqualStrings(expected_model, result.model);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expect(result.error_message != null);
}

fn assertCapturedRequest(
    allocator: std.mem.Allocator,
    request_head: []const u8,
    expected_request_line: []const u8,
    expected_auth_header: []const u8,
    forbidden_auth_header: ?[]const u8,
) !void {
    const lower_request = try std.ascii.allocLowerString(allocator, request_head);
    defer allocator.free(lower_request);
    const lower_request_line = try std.ascii.allocLowerString(allocator, expected_request_line);
    defer allocator.free(lower_request_line);
    const lower_auth_header = try std.ascii.allocLowerString(allocator, expected_auth_header);
    defer allocator.free(lower_auth_header);

    try std.testing.expect(std.mem.indexOf(u8, lower_request, lower_request_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, lower_request, lower_auth_header) != null);
    if (forbidden_auth_header) |header| {
        const lower_forbidden = try std.ascii.allocLowerString(allocator, header);
        defer allocator.free(lower_forbidden);
        try std.testing.expect(std.mem.indexOf(u8, lower_request, lower_forbidden) == null);
    }
}

fn loopbackBaseUrl(
    allocator: std.mem.Allocator,
    server: *const provider_error.TestCaptureServer,
    path: []const u8,
) ![]u8 {
    const origin = try server.url(allocator);
    defer allocator.free(origin);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, path });
}

fn runOpenAICompatCapture(expectation: CaptureExpectation) !void {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    var server = try provider_error.TestCaptureServer.init(
        io,
        401,
        "Unauthorized",
        "",
        "{\"error\":\"provider smoke capture\"}",
    );
    try server.start();
    errdefer server.deinit();

    const base_url = try loopbackBaseUrl(allocator, &server, expectation.base_path);
    defer allocator.free(base_url);

    var stream = try openai.OpenAIProvider.stream(
        allocator,
        io,
        smokeModel(expectation, base_url),
        smokeContext(),
        .{ .api_key = "provider-smoke-key", .session_id = "provider-smoke-session" },
    );
    defer stream.deinit();
    try expectOnlyTerminalErrorMetadata(&stream, expectation.api, expectation.provider, expectation.model_id);

    server.deinit();
    try std.testing.expect(!server.request_head_truncated);
    try assertCapturedRequest(
        allocator,
        server.requestHead(),
        expectation.expected_request_line,
        expectation.expected_auth_header,
        expectation.forbidden_auth_header,
    );
}

fn runAnthropicCapture(expectation: CaptureExpectation) !void {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    var server = try provider_error.TestCaptureServer.init(
        io,
        401,
        "Unauthorized",
        "",
        "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"provider smoke capture\"}}",
    );
    try server.start();
    errdefer server.deinit();

    const base_url = try loopbackBaseUrl(allocator, &server, expectation.base_path);
    defer allocator.free(base_url);

    var stream = try anthropic.AnthropicProvider.stream(
        allocator,
        io,
        smokeModel(expectation, base_url),
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer stream.deinit();
    try expectOnlyTerminalErrorMetadata(&stream, expectation.api, expectation.provider, expectation.model_id);

    server.deinit();
    try std.testing.expect(!server.request_head_truncated);
    try assertCapturedRequest(
        allocator,
        server.requestHead(),
        expectation.expected_request_line,
        expectation.expected_auth_header,
        expectation.forbidden_auth_header,
    );
}

test "provider smoke Moonshot and Kimi Code standalone captures OpenAI routing auth and metadata" {
    const cases = [_]CaptureExpectation{
        .{
            .provider = "moonshotai",
            .api = "openai-completions",
            .model_id = "kimi-k2.6",
            .base_path = "/v1",
            .expected_request_line = "POST /v1/chat/completions HTTP/1.1",
            .expected_auth_header = "\r\nauthorization: bearer provider-smoke-key\r\n",
        },
        .{
            .provider = "moonshotai-cn",
            .api = "openai-completions",
            .model_id = "kimi-k2.6",
            .base_path = "/v1",
            .expected_request_line = "POST /v1/chat/completions HTTP/1.1",
            .expected_auth_header = "\r\nauthorization: bearer provider-smoke-key\r\n",
        },
        .{
            .provider = "kimi-code-openai",
            .api = "openai-completions",
            .model_id = "kimi-for-coding",
            .base_path = "/coding/v1",
            .expected_request_line = "POST /coding/v1/chat/completions HTTP/1.1",
            .expected_auth_header = "\r\nauthorization: bearer provider-smoke-key\r\n",
            .forbidden_auth_header = "\r\nuser-agent: kimicli/1.5\r\n",
        },
    };

    for (cases) |case| {
        const provider_config = model_registry.getProviderConfig(case.provider).?;
        try std.testing.expectEqualStrings(case.api, provider_config.api);
        try std.testing.expectEqualStrings(case.model_id, provider_config.default_model_id.?);
        const registered_model = model_registry.find(case.provider, case.model_id).?;
        try std.testing.expectEqualStrings(case.provider, registered_model.provider);
        try std.testing.expectEqualStrings(case.api, registered_model.api);
        try runOpenAICompatCapture(case);
    }
}

test "provider smoke Kimi Code Anthropic captures routing auth and metadata" {
    const case = CaptureExpectation{
        .provider = "kimi-coding",
        .api = "anthropic-messages",
        .model_id = "kimi-for-coding",
        .base_path = "/coding",
        .expected_request_line = "POST /coding/v1/messages HTTP/1.1",
        .expected_auth_header = "\r\nx-api-key: provider-smoke-key\r\n",
        .forbidden_auth_header = "\r\nuser-agent: kimicli/1.5\r\n",
    };

    const provider_config = model_registry.getProviderConfig(case.provider).?;
    try std.testing.expectEqualStrings(case.api, provider_config.api);
    try std.testing.expectEqualStrings(case.model_id, provider_config.default_model_id.?);
    const registered_model = model_registry.find(case.provider, case.model_id).?;
    try std.testing.expectEqualStrings(case.provider, registered_model.provider);
    try std.testing.expectEqualStrings(case.api, registered_model.api);
    try runAnthropicCapture(case);
}

test "provider smoke Xiaomi standalone captures Anthropic routing auth and metadata" {
    const cases = [_]struct {
        expectation: CaptureExpectation,
        expected_base_url: []const u8,
    }{
        .{
            .expectation = .{
                .provider = "xiaomi",
                .api = "anthropic-messages",
                .model_id = "mimo-v2.5-pro",
                .base_path = "/anthropic",
                .expected_request_line = "POST /anthropic/v1/messages HTTP/1.1",
                .expected_auth_header = "\r\nx-api-key: provider-smoke-key\r\n",
                .forbidden_auth_header = "\r\nauthorization:",
            },
            .expected_base_url = "https://api.xiaomimimo.com/anthropic",
        },
        .{
            .expectation = .{
                .provider = "xiaomi-token-plan-cn",
                .api = "anthropic-messages",
                .model_id = "mimo-v2.5-pro",
                .base_path = "/anthropic",
                .expected_request_line = "POST /anthropic/v1/messages HTTP/1.1",
                .expected_auth_header = "\r\nx-api-key: provider-smoke-key\r\n",
                .forbidden_auth_header = "\r\nauthorization:",
            },
            .expected_base_url = "https://token-plan-cn.xiaomimimo.com/anthropic",
        },
        .{
            .expectation = .{
                .provider = "xiaomi-token-plan-ams",
                .api = "anthropic-messages",
                .model_id = "mimo-v2.5-pro",
                .base_path = "/anthropic",
                .expected_request_line = "POST /anthropic/v1/messages HTTP/1.1",
                .expected_auth_header = "\r\nx-api-key: provider-smoke-key\r\n",
                .forbidden_auth_header = "\r\nauthorization:",
            },
            .expected_base_url = "https://token-plan-ams.xiaomimimo.com/anthropic",
        },
        .{
            .expectation = .{
                .provider = "xiaomi-token-plan-sgp",
                .api = "anthropic-messages",
                .model_id = "mimo-v2.5-pro",
                .base_path = "/anthropic",
                .expected_request_line = "POST /anthropic/v1/messages HTTP/1.1",
                .expected_auth_header = "\r\nx-api-key: provider-smoke-key\r\n",
                .forbidden_auth_header = "\r\nauthorization:",
            },
            .expected_base_url = "https://token-plan-sgp.xiaomimimo.com/anthropic",
        },
    };

    for (cases) |case| {
        const expectation = case.expectation;
        const provider_config = model_registry.getProviderConfig(expectation.provider).?;
        try std.testing.expectEqualStrings(expectation.api, provider_config.api);
        try std.testing.expectEqualStrings(expectation.model_id, provider_config.default_model_id.?);
        try std.testing.expectEqualStrings(case.expected_base_url, provider_config.base_url);
        const registered_model = model_registry.find(expectation.provider, expectation.model_id).?;
        try std.testing.expectEqualStrings(expectation.provider, registered_model.provider);
        try std.testing.expectEqualStrings(expectation.api, registered_model.api);
        try std.testing.expectEqualStrings(case.expected_base_url, registered_model.base_url);
        try runAnthropicCapture(expectation);
    }
}

test "ISS-090 provider smoke Cloudflare Workers AI and Gateway compat capture routing auth metadata" {
    const cases = [_]CaptureExpectation{
        .{
            .provider = "cloudflare-workers-ai",
            .api = "openai-completions",
            .model_id = "@cf/moonshotai/kimi-k2.6",
            .base_path = "/client/v4/accounts/smoke-account/ai/v1",
            .expected_request_line = "POST /client/v4/accounts/smoke-account/ai/v1/chat/completions HTTP/1.1",
            .expected_auth_header = "\r\nauthorization: bearer provider-smoke-key\r\n",
        },
        .{
            .provider = "cloudflare-ai-gateway",
            .api = "openai-completions",
            .model_id = "workers-ai/@cf/moonshotai/kimi-k2.6",
            .base_path = "/v1/smoke-account/smoke-gateway/compat",
            .expected_request_line = "POST /v1/smoke-account/smoke-gateway/compat/chat/completions HTTP/1.1",
            .expected_auth_header = "\r\ncf-aig-authorization: bearer provider-smoke-key\r\n",
            .forbidden_auth_header = "\r\nauthorization:",
        },
    };

    for (cases) |case| {
        const provider_config = model_registry.getProviderConfig(case.provider).?;
        try std.testing.expectEqualStrings(case.api, provider_config.api);
        try std.testing.expectEqualStrings(case.model_id, provider_config.default_model_id.?);
        const registered_model = model_registry.find(case.provider, case.model_id).?;
        try std.testing.expectEqualStrings(case.provider, registered_model.provider);
        try std.testing.expectEqualStrings(case.api, registered_model.api);
        try runOpenAICompatCapture(case);
    }
}

test "ISS-090 provider smoke Cloudflare placeholders substitute and fail explicitly" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("CLOUDFLARE_ACCOUNT_ID", "smoke-account");
    try env_map.put("CLOUDFLARE_GATEWAY_ID", "smoke-gateway");

    const workers_model = model_registry.find("cloudflare-workers-ai", "@cf/moonshotai/kimi-k2.6").?;
    const workers_url = try cloudflare.resolveCloudflareBaseUrlFromMap(allocator, workers_model, &env_map);
    defer allocator.free(workers_url);
    try std.testing.expectEqualStrings("https://api.cloudflare.com/client/v4/accounts/smoke-account/ai/v1", workers_url);

    const compat_model = model_registry.find("cloudflare-ai-gateway", "workers-ai/@cf/moonshotai/kimi-k2.6").?;
    const compat_url = try cloudflare.resolveCloudflareBaseUrlFromMap(allocator, compat_model, &env_map);
    defer allocator.free(compat_url);
    try std.testing.expectEqualStrings("https://gateway.ai.cloudflare.com/v1/smoke-account/smoke-gateway/compat", compat_url);

    const openai_model = model_registry.find("cloudflare-ai-gateway", "gpt-5.4").?;
    const openai_url = try cloudflare.resolveCloudflareBaseUrlFromMap(allocator, openai_model, &env_map);
    defer allocator.free(openai_url);
    try std.testing.expectEqualStrings("https://gateway.ai.cloudflare.com/v1/smoke-account/smoke-gateway/openai", openai_url);

    const anthropic_model = model_registry.find("cloudflare-ai-gateway", "claude-opus-4-7").?;
    const anthropic_url = try cloudflare.resolveCloudflareBaseUrlFromMap(allocator, anthropic_model, &env_map);
    defer allocator.free(anthropic_url);
    try std.testing.expectEqualStrings("https://gateway.ai.cloudflare.com/v1/smoke-account/smoke-gateway/anthropic", anthropic_url);

    var missing_env_map = std.process.Environ.Map.init(allocator);
    defer missing_env_map.deinit();
    try std.testing.expectError(error.MissingCloudflareAccountId, cloudflare.resolveCloudflareBaseUrlFromMap(allocator, workers_model, &missing_env_map));

    var missing_gateway_map = std.process.Environ.Map.init(allocator);
    defer missing_gateway_map.deinit();
    try missing_gateway_map.put("CLOUDFLARE_ACCOUNT_ID", "smoke-account");
    try std.testing.expectError(error.MissingCloudflareGatewayId, cloudflare.resolveCloudflareBaseUrlFromMap(allocator, compat_model, &missing_gateway_map));
}

test "ISS-090 provider smoke Cloudflare Gateway OpenAI Responses capture routing auth metadata" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    var server = try provider_error.TestCaptureServer.init(
        io,
        401,
        "Unauthorized",
        "",
        "{\"error\":\"provider smoke capture\"}",
    );
    try server.start();
    errdefer server.deinit();

    const base_url = try loopbackBaseUrl(allocator, &server, "/v1/smoke-account/smoke-gateway/openai");
    defer allocator.free(base_url);
    const model = smokeModel(.{
        .provider = "cloudflare-ai-gateway",
        .api = "openai-responses",
        .model_id = "gpt-5.4",
        .base_path = "",
        .expected_request_line = "",
        .expected_auth_header = "",
    }, base_url);

    var stream = try openai_responses.OpenAIResponsesProvider.stream(
        allocator,
        io,
        model,
        smokeContext(),
        .{ .api_key = "provider-smoke-key", .session_id = "provider-smoke-session" },
    );
    defer stream.deinit();
    try expectOnlyTerminalErrorMetadata(&stream, "openai-responses", "cloudflare-ai-gateway", "gpt-5.4");

    server.deinit();
    try std.testing.expect(!server.request_head_truncated);
    try assertCapturedRequest(
        allocator,
        server.requestHead(),
        "POST /v1/smoke-account/smoke-gateway/openai/responses HTTP/1.1",
        "\r\ncf-aig-authorization: bearer provider-smoke-key\r\n",
        "\r\nauthorization:",
    );
}

test "ISS-090 provider smoke Cloudflare Gateway Anthropic capture routing auth metadata" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;
    var server = try provider_error.TestCaptureServer.init(
        io,
        401,
        "Unauthorized",
        "",
        "{\"error\":\"provider smoke capture\"}",
    );
    try server.start();
    errdefer server.deinit();

    const base_url = try loopbackBaseUrl(allocator, &server, "/v1/smoke-account/smoke-gateway/anthropic");
    defer allocator.free(base_url);
    const model = smokeModel(.{
        .provider = "cloudflare-ai-gateway",
        .api = "anthropic-messages",
        .model_id = "claude-opus-4-7",
        .base_path = "",
        .expected_request_line = "",
        .expected_auth_header = "",
    }, base_url);

    var stream = try anthropic.AnthropicProvider.stream(
        allocator,
        io,
        model,
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer stream.deinit();
    try expectOnlyTerminalErrorMetadata(&stream, "anthropic-messages", "cloudflare-ai-gateway", "claude-opus-4-7");

    server.deinit();
    try std.testing.expect(!server.request_head_truncated);
    try assertCapturedRequest(
        allocator,
        server.requestHead(),
        "POST /v1/smoke-account/smoke-gateway/anthropic/v1/messages HTTP/1.1",
        "\r\ncf-aig-authorization: bearer provider-smoke-key\r\n",
        "\r\nx-api-key:",
    );
    const lower_request = try std.ascii.allocLowerString(allocator, server.requestHead());
    defer allocator.free(lower_request);
    try std.testing.expect(std.mem.indexOf(u8, lower_request, "\r\nauthorization:") == null);
}

fn expectProviderSetupFailure(comptime Provider: type, expectation: CaptureExpectation) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var stream = try Provider.stream(
        allocator,
        io,
        smokeModel(expectation, "http://127.0.0.1:1"),
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer stream.deinit();
    try expectOnlyTerminalErrorMetadata(&stream, expectation.api, expectation.provider, expectation.model_id);
}

test "provider smoke Moonshot Kimi Code and Cloudflare setup failures are terminal error events" {
    const openai_cases = [_]CaptureExpectation{
        .{ .provider = "moonshotai", .api = "openai-completions", .model_id = "kimi-k2.6", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "moonshotai-cn", .api = "openai-completions", .model_id = "kimi-k2.6", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "kimi-code-openai", .api = "openai-completions", .model_id = "kimi-for-coding", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "cloudflare-workers-ai", .api = "openai-completions", .model_id = "@cf/moonshotai/kimi-k2.6", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "cloudflare-ai-gateway", .api = "openai-completions", .model_id = "workers-ai/@cf/moonshotai/kimi-k2.6", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
    };
    for (openai_cases) |case| try expectProviderSetupFailure(openai.OpenAIProvider, case);

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var responses_stream = try openai_responses.OpenAIResponsesProvider.stream(
        allocator,
        io,
        smokeModel(.{ .provider = "cloudflare-ai-gateway", .api = "openai-responses", .model_id = "gpt-5.4", .base_path = "", .expected_request_line = "", .expected_auth_header = "" }, "http://127.0.0.1:1"),
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer responses_stream.deinit();
    try expectOnlyTerminalErrorMetadata(&responses_stream, "openai-responses", "cloudflare-ai-gateway", "gpt-5.4");

    var anthropic_stream = try anthropic.AnthropicProvider.stream(
        allocator,
        io,
        smokeModel(.{ .provider = "cloudflare-ai-gateway", .api = "anthropic-messages", .model_id = "claude-opus-4-7", .base_path = "", .expected_request_line = "", .expected_auth_header = "" }, "http://127.0.0.1:1"),
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer anthropic_stream.deinit();
    try expectOnlyTerminalErrorMetadata(&anthropic_stream, "anthropic-messages", "cloudflare-ai-gateway", "claude-opus-4-7");

    var kimi_code_stream = try anthropic.AnthropicProvider.stream(
        allocator,
        io,
        smokeModel(.{ .provider = "kimi-coding", .api = "anthropic-messages", .model_id = "kimi-for-coding", .base_path = "", .expected_request_line = "", .expected_auth_header = "" }, "http://127.0.0.1:1"),
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer kimi_code_stream.deinit();
    try expectOnlyTerminalErrorMetadata(&kimi_code_stream, "anthropic-messages", "kimi-coding", "kimi-for-coding");
}

test "provider smoke Xiaomi setup failures are terminal error events" {
    const cases = [_]CaptureExpectation{
        .{ .provider = "xiaomi", .api = "anthropic-messages", .model_id = "mimo-v2.5-pro", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "xiaomi-token-plan-cn", .api = "anthropic-messages", .model_id = "mimo-v2.5-pro", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "xiaomi-token-plan-ams", .api = "anthropic-messages", .model_id = "mimo-v2.5-pro", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
        .{ .provider = "xiaomi-token-plan-sgp", .api = "anthropic-messages", .model_id = "mimo-v2.5-pro", .base_path = "", .expected_request_line = "", .expected_auth_header = "" },
    };
    for (cases) |case| try expectProviderSetupFailure(anthropic.AnthropicProvider, case);
}

test "provider smoke Cloudflare Responses placeholder failure is terminal error event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const model = smokeModel(.{
        .provider = "cloudflare-ai-gateway",
        .api = "openai-responses",
        .model_id = "gpt-5.4",
        .base_path = "",
        .expected_request_line = "",
        .expected_auth_header = "",
    }, "https://gateway.ai.cloudflare.com/v1/{PROVIDER_SMOKE_CF_ABSENT_ACCOUNT}/{PROVIDER_SMOKE_CF_ABSENT_GATEWAY}/openai");

    var stream = try openai_responses.OpenAIResponsesProvider.stream(
        allocator,
        io,
        model,
        smokeContext(),
        .{ .api_key = "provider-smoke-key" },
    );
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.error_message != null);
    try std.testing.expectEqualStrings("EnvironmentVariableNotFound", event.error_message.?);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings("cloudflare-ai-gateway", event.message.?.provider);
    try std.testing.expectEqualStrings("gpt-5.4", event.message.?.model);
    try std.testing.expect(stream.next() == null);
}
