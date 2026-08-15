const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");

/// Workers AI direct endpoint.
pub const CLOUDFLARE_WORKERS_AI_BASE_URL = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1";

/// AI Gateway Unified API. https://developers.cloudflare.com/ai-gateway/usage/unified-api/
pub const CLOUDFLARE_AI_GATEWAY_COMPAT_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat";

/// AI Gateway -> OpenAI passthrough. Used until /compat supports /v1/responses.
pub const CLOUDFLARE_AI_GATEWAY_OPENAI_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai";

/// AI Gateway -> Anthropic passthrough.
pub const CLOUDFLARE_AI_GATEWAY_ANTHROPIC_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/anthropic";

/// Check if the provider is a Cloudflare provider.
pub fn isCloudflareProvider(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "cloudflare-workers-ai") or
        std.mem.eql(u8, provider, "cloudflare-ai-gateway");
}

/// One-liner for the verbatim block every provider's streamProduction
/// repeats:
/// ```zig
/// const resolved_base_url: ?[]const u8 = if (cloudflare.isCloudflareProvider(model.provider))
///     try cloudflare.resolveCloudflareBaseUrl(allocator, model)
/// else
///     null;
/// defer if (resolved_base_url) |b| allocator.free(b);
/// // ... use `resolved_base_url orelse model.base_url`
/// ```
/// Returns null for non-Cloudflare providers (caller falls back to
/// `model.base_url`); returns an owned URL slice for Cloudflare providers
/// that the caller must `free` once the request is built.
pub fn resolveBaseUrlOrNull(allocator: std.mem.Allocator, model: types.Model) !?[]const u8 {
    if (!isCloudflareProvider(model.provider)) return null;
    return try resolveCloudflareBaseUrl(allocator, model);
}

/// Substitute `{VAR}` placeholders in a model's base_url using the provided env map.
/// Always returns an owned slice that the caller must free.
/// Returns a Cloudflare-specific error if a required Cloudflare env var is missing or empty.
/// Unknown placeholders return error.EnvironmentVariableNotFound.
pub fn resolveCloudflareBaseUrlFromMap(
    allocator: std.mem.Allocator,
    model: types.Model,
    env_map: *const std.process.Environ.Map,
) ![]const u8 {
    const url = model.base_url;
    if (std.mem.indexOf(u8, url, "{") == null) {
        return try allocator.dupe(u8, url);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < url.len) {
        if (url[i] == '{') {
            const start = i + 1;
            i = start;
            while (i < url.len and url[i] != '}') : (i += 1) {}
            if (i >= url.len) {
                return error.InvalidPlaceholder;
            }
            const var_name = url[start..i];
            i += 1; // skip '}'

            const env_value = env_map.get(var_name) orelse {
                return missingCloudflarePlaceholderError(var_name);
            };
            if (env_value.len == 0) {
                return missingCloudflarePlaceholderError(var_name);
            }
            try result.appendSlice(allocator, env_value);
        } else {
            try result.append(allocator, url[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Substitute `{VAR}` placeholders in a model's base_url from the process environment.
/// Always returns an owned slice that the caller must free.
/// Returns a Cloudflare-specific error if a required Cloudflare env var is missing or empty.
/// Unknown placeholders return error.EnvironmentVariableNotFound.
pub fn resolveCloudflareBaseUrl(
    allocator: std.mem.Allocator,
    model: types.Model,
) ![]const u8 {
    const env = currentProcessEnviron();
    var env_map = try env.createMap(allocator);
    defer env_map.deinit();
    return resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
}

const ERROR_MAP = std.StaticStringMap(anyerror).initComptime(.{
    .{ "CLOUDFLARE_ACCOUNT_ID", error.MissingCloudflareAccountId },
    .{ "CLOUDFLARE_GATEWAY_ID", error.MissingCloudflareGatewayId },
});

fn missingCloudflarePlaceholderError(var_name: []const u8) anyerror {
    return ERROR_MAP.get(var_name) orelse error.EnvironmentVariableNotFound;
}

fn currentProcessEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .{ .use_global = true } },
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
}

test "cloudflare isCloudflareProvider recognizes cloudflare providers" {
    try std.testing.expect(isCloudflareProvider("cloudflare-workers-ai"));
    try std.testing.expect(isCloudflareProvider("cloudflare-ai-gateway"));
    try std.testing.expect(!isCloudflareProvider("openai"));
    try std.testing.expect(!isCloudflareProvider("anthropic"));
    try std.testing.expect(!isCloudflareProvider(""));
}

test "cloudflare resolveCloudflareBaseUrl no placeholders returns unchanged" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = "openai-completions",
        .provider = "cloudflare-workers-ai",
        .base_url = "https://example.com/v1",
        .input_types = &[_][]const u8{},
        .context_window = 131072,
        .max_tokens = 8192,
    };

    const url = try resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://example.com/v1", url);
}

test "cloudflare resolveCloudflareBaseUrl substitutes env vars" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("CLOUDFLARE_ACCOUNT_ID", "abc123");

    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = "openai-completions",
        .provider = "cloudflare-workers-ai",
        .base_url = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
        .input_types = &[_][]const u8{},
        .context_window = 131072,
        .max_tokens = 8192,
    };

    const url = try resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1",
        url,
    );
}

test "cloudflare resolveCloudflareBaseUrl substitutes multiple env vars" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("CLOUDFLARE_ACCOUNT_ID", "acc456");
    try env_map.put("CLOUDFLARE_GATEWAY_ID", "gw789");

    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = "openai-completions",
        .provider = "cloudflare-ai-gateway",
        .base_url = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai",
        .input_types = &[_][]const u8{},
        .context_window = 131072,
        .max_tokens = 8192,
    };

    const url = try resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gateway.ai.cloudflare.com/v1/acc456/gw789/openai",
        url,
    );
}

test "cloudflare resolveCloudflareBaseUrl missing env var returns error" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    // CLOUDFLARE_ACCOUNT_ID not set

    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = "openai-completions",
        .provider = "cloudflare-workers-ai",
        .base_url = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
        .input_types = &[_][]const u8{},
        .context_window = 131072,
        .max_tokens = 8192,
    };

    const result = resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
    try std.testing.expectError(error.MissingCloudflareAccountId, result);
}

test "cloudflare resolveCloudflareBaseUrl empty env var returns error" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("CLOUDFLARE_ACCOUNT_ID", "");

    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = "openai-completions",
        .provider = "cloudflare-workers-ai",
        .base_url = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1",
        .input_types = &[_][]const u8{},
        .context_window = 131072,
        .max_tokens = 8192,
    };

    const result = resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
    try std.testing.expectError(error.MissingCloudflareAccountId, result);
}

test "cloudflare resolveCloudflareBaseUrl missing gateway env var returns error" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("CLOUDFLARE_ACCOUNT_ID", "abc123");
    // CLOUDFLARE_GATEWAY_ID not set

    const model = types.Model{
        .id = "test",
        .name = "Test",
        .api = "openai-completions",
        .provider = "cloudflare-ai-gateway",
        .base_url = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai",
        .input_types = &[_][]const u8{},
        .context_window = 131072,
        .max_tokens = 8192,
    };

    const result = resolveCloudflareBaseUrlFromMap(allocator, model, &env_map);
    try std.testing.expectError(error.MissingCloudflareGatewayId, result);
}
