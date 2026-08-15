const std = @import("std");
const builtin = @import("builtin");

const AUTHENTICATED_SENTINEL = "<authenticated>";

pub fn getEnvApiKey(allocator: std.mem.Allocator, provider: []const u8) !?[]u8 {
    const env = currentProcessEnviron();
    var env_map = try env.createMap(allocator);
    defer env_map.deinit();
    return try getEnvApiKeyFromMap(allocator, &env_map, provider);
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

pub fn getEnvApiKeyFromMap(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
) !?[]u8 {
    if (@import("provider_info.zig").envVarsFor(provider)) |env_vars| {
        return try firstEnvValue(allocator, env_map, env_vars);
    }

    // Bespoke auth resolution: this provider's env-var semantics don't reduce to a flat ordered list (see ProviderInfo.env_vars doc). Reason: ADC file probe + project/location AND-conjunction + sentinel return.
    if (std.mem.eql(u8, provider, "google-vertex")) {
        if (env_map.get("GOOGLE_CLOUD_API_KEY")) |api_key| {
            if (isNonEmptyCredentialValue(api_key)) return try allocator.dupe(u8, api_key);
        }

        const has_credentials = hasVertexAdcCredentials(allocator, env_map);
        const has_project = envMapHasNonEmpty(env_map, "GOOGLE_CLOUD_PROJECT") or envMapHasNonEmpty(env_map, "GCLOUD_PROJECT");
        const has_location = envMapHasNonEmpty(env_map, "GOOGLE_CLOUD_LOCATION");
        if (has_credentials and has_project and has_location) {
            return try allocator.dupe(u8, AUTHENTICATED_SENTINEL);
        }
    }

    // Bespoke auth resolution: this provider's env-var semantics don't reduce to a flat ordered list (see ProviderInfo.env_vars doc). Reason: AND-conjunction across heterogeneous AWS env vars + sentinel return.
    if (std.mem.eql(u8, provider, "amazon-bedrock")) {
        const has_standard_keys = envMapHasNonEmpty(env_map, "AWS_ACCESS_KEY_ID") and envMapHasNonEmpty(env_map, "AWS_SECRET_ACCESS_KEY");
        const has_alt_auth = envMapHasNonEmpty(env_map, "AWS_PROFILE") or
            envMapHasNonEmpty(env_map, "AWS_BEARER_TOKEN_BEDROCK") or
            envMapHasNonEmpty(env_map, "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") or
            envMapHasNonEmpty(env_map, "AWS_CONTAINER_CREDENTIALS_FULL_URI") or
            envMapHasNonEmpty(env_map, "AWS_WEB_IDENTITY_TOKEN_FILE");
        if (has_standard_keys or has_alt_auth) {
            return try allocator.dupe(u8, AUTHENTICATED_SENTINEL);
        }
    }

    const env_var = resolveEnvVar(provider) orelse return null;
    if (env_map.get(env_var)) |value| {
        if (isNonEmptyCredentialValue(value)) return try allocator.dupe(u8, value);
    }

    return null;
}

fn firstEnvValue(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    keys: []const []const u8,
) !?[]u8 {
    for (keys) |key| {
        if (env_map.get(key)) |value| {
            if (isNonEmptyCredentialValue(value)) return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn envMapHasNonEmpty(env_map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env_map.get(key) orelse return false;
    return isNonEmptyCredentialValue(value);
}

fn isNonEmptyCredentialValue(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0;
}

fn hasVertexAdcCredentials(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) bool {
    if (env_map.get("GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        const trimmed = std.mem.trim(u8, path, &std.ascii.whitespace);
        if (trimmed.len > 0) return pathExists(allocator, trimmed);
    }

    const home = env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse return false;
    const trimmed_home = std.mem.trim(u8, home, &std.ascii.whitespace);
    if (trimmed_home.len == 0) return false;

    const default_path = std.fs.path.join(allocator, &[_][]const u8{
        trimmed_home,
        ".config",
        "gcloud",
        "application_default_credentials.json",
    }) catch return false;
    defer allocator.free(default_path);

    return pathExists(allocator, default_path);
}

fn pathExists(_: std.mem.Allocator, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

fn resolveEnvVar(provider: []const u8) ?[]const u8 {
    return @import("provider_info.zig").envVarFor(provider);
}

test "resolveEnvVar returns previously-known single-key mappings" {
    const KnownMapping = struct { provider: []const u8, env_var: []const u8 };
    const known = [_]KnownMapping{
        .{ .provider = "openai", .env_var = "OPENAI_API_KEY" },
        .{ .provider = "ant-ling", .env_var = "ANT_LING_API_KEY" },
        .{ .provider = "openai-responses", .env_var = "OPENAI_API_KEY" },
        .{ .provider = "openai-codex", .env_var = "OPENAI_API_KEY" },
        .{ .provider = "azure-openai-responses", .env_var = "AZURE_OPENAI_API_KEY" },
        .{ .provider = "deepseek", .env_var = "DEEPSEEK_API_KEY" },
        .{ .provider = "google", .env_var = "GEMINI_API_KEY" },
        .{ .provider = "groq", .env_var = "GROQ_API_KEY" },
        .{ .provider = "cerebras", .env_var = "CEREBRAS_API_KEY" },
        .{ .provider = "xai", .env_var = "XAI_API_KEY" },
        .{ .provider = "openrouter", .env_var = "OPENROUTER_API_KEY" },
        .{ .provider = "vercel-ai-gateway", .env_var = "AI_GATEWAY_API_KEY" },
        .{ .provider = "zai", .env_var = "ZAI_API_KEY" },
        .{ .provider = "zai-coding-cn", .env_var = "ZAI_CODING_CN_API_KEY" },
        .{ .provider = "mistral", .env_var = "MISTRAL_API_KEY" },
        .{ .provider = "minimax", .env_var = "MINIMAX_API_KEY" },
        .{ .provider = "minimax-cn", .env_var = "MINIMAX_CN_API_KEY" },
        .{ .provider = "moonshotai", .env_var = "MOONSHOT_API_KEY" },
        .{ .provider = "moonshotai-cn", .env_var = "MOONSHOT_API_KEY" },
        .{ .provider = "huggingface", .env_var = "HF_TOKEN" },
        .{ .provider = "nvidia", .env_var = "NVIDIA_API_KEY" },
        .{ .provider = "fireworks", .env_var = "FIREWORKS_API_KEY" },
        .{ .provider = "together", .env_var = "TOGETHER_API_KEY" },
        .{ .provider = "opencode", .env_var = "OPENCODE_API_KEY" },
        .{ .provider = "opencode-go", .env_var = "OPENCODE_API_KEY" },
        .{ .provider = "kimi", .env_var = "MOONSHOT_API_KEY" },
        .{ .provider = "kimi-coding", .env_var = "KIMI_API_KEY" },
        .{ .provider = "kimi-code-openai", .env_var = "KIMI_API_KEY" },
        .{ .provider = "cloudflare-workers-ai", .env_var = "CLOUDFLARE_API_KEY" },
        .{ .provider = "cloudflare-ai-gateway", .env_var = "CLOUDFLARE_API_KEY" },
        .{ .provider = "xiaomi", .env_var = "XIAOMI_API_KEY" },
        .{ .provider = "xiaomi-token-plan-cn", .env_var = "XIAOMI_TOKEN_PLAN_CN_API_KEY" },
        .{ .provider = "xiaomi-token-plan-ams", .env_var = "XIAOMI_TOKEN_PLAN_AMS_API_KEY" },
        .{ .provider = "xiaomi-token-plan-sgp", .env_var = "XIAOMI_TOKEN_PLAN_SGP_API_KEY" },
    };

    for (known) |entry| {
        const resolved = resolveEnvVar(entry.provider) orelse {
            std.debug.print("missing env var for provider: {s}\n", .{entry.provider});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(entry.env_var, resolved);
    }

    const multi_cred = [_][]const u8{
        "amazon-bedrock",
        "anthropic",
        "github-copilot",
        "xai-oauth",
        "google-vertex",
    };
    for (multi_cred) |provider| {
        try std.testing.expectEqual(@as(?[]const u8, null), resolveEnvVar(provider));
    }
}

test "getEnvApiKey resolves known providers and returns null when missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "adc.json", .data = "{}" });
    const adc_path = try makeEnvApiKeyTestPath(allocator, tmp, "adc.json");
    defer allocator.free(adc_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("AZURE_OPENAI_API_KEY", "azure-key");
    try env_map.put("DEEPSEEK_API_KEY", "deepseek-key");
    try env_map.put("GEMINI_API_KEY", "gemini-key");
    try env_map.put("GROQ_API_KEY", "groq-key");
    try env_map.put("CEREBRAS_API_KEY", "cerebras-key");
    try env_map.put("XAI_API_KEY", "xai-key");
    try env_map.put("OPENROUTER_API_KEY", "openrouter-key");
    try env_map.put("AI_GATEWAY_API_KEY", "gateway-key");
    try env_map.put("ZAI_API_KEY", "zai-key");
    try env_map.put("MISTRAL_API_KEY", "mistral-key");
    try env_map.put("MINIMAX_API_KEY", "minimax-key");
    try env_map.put("MINIMAX_CN_API_KEY", "minimax-cn-key");
    try env_map.put("HF_TOKEN", "hf-key");
    try env_map.put("FIREWORKS_API_KEY", "fireworks-key");
    try env_map.put("TOGETHER_API_KEY", "together-key");
    try env_map.put("OPENCODE_API_KEY", "opencode-key");
    try env_map.put("MOONSHOT_API_KEY", "moonshot-key");
    try env_map.put("KIMI_API_KEY", "kimi-key");
    try env_map.put("CLOUDFLARE_API_KEY", "cloudflare-key");
    try env_map.put("XIAOMI_API_KEY", "xiaomi-key");
    try env_map.put("XIAOMI_TOKEN_PLAN_CN_API_KEY", "xiaomi-cn-key");
    try env_map.put("XIAOMI_TOKEN_PLAN_AMS_API_KEY", "xiaomi-ams-key");
    try env_map.put("XIAOMI_TOKEN_PLAN_SGP_API_KEY", "xiaomi-sgp-key");
    try env_map.put("COPILOT_GITHUB_TOKEN", "copilot-token");
    try env_map.put("GH_TOKEN", "gh-token");
    try env_map.put("GITHUB_TOKEN", "github-token");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-api-key");
    try env_map.put("ANTHROPIC_OAUTH_TOKEN", "anthropic-oauth-token");
    try env_map.put("AWS_PROFILE", "default");
    try env_map.put("GOOGLE_CLOUD_PROJECT", "project-1");
    try env_map.put("GOOGLE_CLOUD_LOCATION", "us-central1");
    try env_map.put("GOOGLE_APPLICATION_CREDENTIALS", adc_path);

    const mapped_cases = [_]struct {
        provider: []const u8,
        expected: []const u8,
    }{
        .{ .provider = "openai", .expected = "openai-key" },
        .{ .provider = "openai-responses", .expected = "openai-key" },
        .{ .provider = "openai-codex", .expected = "openai-key" },
        .{ .provider = "azure-openai-responses", .expected = "azure-key" },
        .{ .provider = "deepseek", .expected = "deepseek-key" },
        .{ .provider = "google", .expected = "gemini-key" },
        .{ .provider = "groq", .expected = "groq-key" },
        .{ .provider = "cerebras", .expected = "cerebras-key" },
        .{ .provider = "xai", .expected = "xai-key" },
        .{ .provider = "openrouter", .expected = "openrouter-key" },
        .{ .provider = "vercel-ai-gateway", .expected = "gateway-key" },
        .{ .provider = "zai", .expected = "zai-key" },
        .{ .provider = "mistral", .expected = "mistral-key" },
        .{ .provider = "minimax", .expected = "minimax-key" },
        .{ .provider = "minimax-cn", .expected = "minimax-cn-key" },
        .{ .provider = "moonshotai", .expected = "moonshot-key" },
        .{ .provider = "moonshotai-cn", .expected = "moonshot-key" },
        .{ .provider = "huggingface", .expected = "hf-key" },
        .{ .provider = "fireworks", .expected = "fireworks-key" },
        .{ .provider = "together", .expected = "together-key" },
        .{ .provider = "opencode", .expected = "opencode-key" },
        .{ .provider = "opencode-go", .expected = "opencode-key" },
        .{ .provider = "kimi", .expected = "moonshot-key" },
        .{ .provider = "kimi-coding", .expected = "kimi-key" },
        .{ .provider = "kimi-code-openai", .expected = "kimi-key" },
        .{ .provider = "cloudflare-workers-ai", .expected = "cloudflare-key" },
        .{ .provider = "cloudflare-ai-gateway", .expected = "cloudflare-key" },
        .{ .provider = "xiaomi", .expected = "xiaomi-key" },
        .{ .provider = "xiaomi-token-plan-cn", .expected = "xiaomi-cn-key" },
        .{ .provider = "xiaomi-token-plan-ams", .expected = "xiaomi-ams-key" },
        .{ .provider = "xiaomi-token-plan-sgp", .expected = "xiaomi-sgp-key" },
        .{ .provider = "github-copilot", .expected = "copilot-token" },
        .{ .provider = "anthropic", .expected = "anthropic-oauth-token" },
        .{ .provider = "amazon-bedrock", .expected = AUTHENTICATED_SENTINEL },
        .{ .provider = "google-vertex", .expected = AUTHENTICATED_SENTINEL },
    };

    for (mapped_cases) |case| {
        const value = try getEnvApiKeyFromMap(allocator, &env_map, case.provider);
        defer if (value) |resolved| allocator.free(resolved);
        try std.testing.expect(value != null);
        try std.testing.expectEqualStrings(case.expected, value.?);
    }

    try env_map.put("GOOGLE_CLOUD_API_KEY", "vertex-api-key");
    const vertex_api_key = try getEnvApiKeyFromMap(allocator, &env_map, "google-vertex");
    defer if (vertex_api_key) |resolved| allocator.free(resolved);
    try std.testing.expectEqualStrings("vertex-api-key", vertex_api_key.?);

    const missing_cases = [_][]const u8{
        "google-antigravity",
        "faux",
        "missing-provider",
    };

    for (missing_cases) |provider| {
        const missing = try getEnvApiKeyFromMap(allocator, &env_map, provider);
        defer if (missing) |resolved| allocator.free(resolved);
        try std.testing.expect(missing == null);
    }
}

test "getEnvApiKey ignores blank credential values" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("OPENAI_API_KEY", "");
    try env_map.put("MOONSHOT_API_KEY", "\t ");
    try env_map.put("CLOUDFLARE_API_KEY", "\n");
    try env_map.put("TOGETHER_API_KEY", "\n");
    try env_map.put("XIAOMI_API_KEY", " ");
    try env_map.put("XIAOMI_TOKEN_PLAN_CN_API_KEY", "\r\n");
    try env_map.put("XIAOMI_TOKEN_PLAN_AMS_API_KEY", "\t");
    try env_map.put("XIAOMI_TOKEN_PLAN_SGP_API_KEY", "  ");
    try env_map.put("KIMI_API_KEY", "   ");
    try env_map.put("ANTHROPIC_OAUTH_TOKEN", "");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");
    try env_map.put("AWS_PROFILE", "");
    try env_map.put("GOOGLE_APPLICATION_CREDENTIALS", " ");
    try env_map.put("GOOGLE_CLOUD_PROJECT", "project-1");
    try env_map.put("GOOGLE_CLOUD_LOCATION", "us-central1");

    const openai = try getEnvApiKeyFromMap(allocator, &env_map, "openai");
    defer if (openai) |value| allocator.free(value);
    try std.testing.expect(openai == null);

    const kimi_coding = try getEnvApiKeyFromMap(allocator, &env_map, "kimi-coding");
    defer if (kimi_coding) |value| allocator.free(value);
    try std.testing.expect(kimi_coding == null);

    const kimi_code_openai = try getEnvApiKeyFromMap(allocator, &env_map, "kimi-code-openai");
    defer if (kimi_code_openai) |value| allocator.free(value);
    try std.testing.expect(kimi_code_openai == null);

    const blank_provider_cases = [_][]const u8{
        "moonshotai",
        "moonshotai-cn",
        "cloudflare-workers-ai",
        "cloudflare-ai-gateway",
        "together",
        "xiaomi",
        "xiaomi-token-plan-cn",
        "xiaomi-token-plan-ams",
        "xiaomi-token-plan-sgp",
    };
    for (blank_provider_cases) |provider| {
        const value = try getEnvApiKeyFromMap(allocator, &env_map, provider);
        defer if (value) |resolved| allocator.free(resolved);
        try std.testing.expect(value == null);
    }

    const anthropic = try getEnvApiKeyFromMap(allocator, &env_map, "anthropic");
    defer if (anthropic) |value| allocator.free(value);
    try std.testing.expectEqualStrings("anthropic-key", anthropic.?);

    const bedrock = try getEnvApiKeyFromMap(allocator, &env_map, "amazon-bedrock");
    defer if (bedrock) |value| allocator.free(value);
    try std.testing.expect(bedrock == null);

    const vertex = try getEnvApiKeyFromMap(allocator, &env_map, "google-vertex");
    defer if (vertex) |value| allocator.free(value);
    try std.testing.expect(vertex == null);
}

test "getEnvApiKey requires existing Vertex ADC credential file" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("GOOGLE_CLOUD_PROJECT", "project-1");
    try env_map.put("GOOGLE_CLOUD_LOCATION", "us-central1");
    try env_map.put("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/pi-missing-adc-for-env-api-key-test.json");

    const missing = try getEnvApiKeyFromMap(allocator, &env_map, "google-vertex");
    defer if (missing) |value| allocator.free(value);
    try std.testing.expect(missing == null);
}

test "getEnvApiKey uses default Vertex ADC path under HOME" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.config/gcloud");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.config/gcloud/application_default_credentials.json",
        .data = "{}",
    });
    const home_path = try makeEnvApiKeyTestPath(allocator, tmp, "home");
    defer allocator.free(home_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("HOME", home_path);
    try env_map.put("GOOGLE_CLOUD_PROJECT", "project-1");
    try env_map.put("GOOGLE_CLOUD_LOCATION", "us-central1");

    const value = try getEnvApiKeyFromMap(allocator, &env_map, "google-vertex");
    defer if (value) |resolved| allocator.free(resolved);
    try std.testing.expectEqualStrings(AUTHENTICATED_SENTINEL, value.?);
}

test "getEnvApiKey honors ordered env-var fallback for anthropic and github-copilot" {
    const allocator = std.testing.allocator;

    // anthropic: ANTHROPIC_OAUTH_TOKEN wins over ANTHROPIC_API_KEY when both set.
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("ANTHROPIC_OAUTH_TOKEN", "oauth-token");
        try env_map.put("ANTHROPIC_API_KEY", "api-key");

        const value = try getEnvApiKeyFromMap(allocator, &env_map, "anthropic");
        defer if (value) |resolved| allocator.free(resolved);
        try std.testing.expectEqualStrings("oauth-token", value.?);
    }

    // anthropic: falls through to ANTHROPIC_API_KEY when OAUTH token absent.
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("ANTHROPIC_API_KEY", "api-key-only");

        const value = try getEnvApiKeyFromMap(allocator, &env_map, "anthropic");
        defer if (value) |resolved| allocator.free(resolved);
        try std.testing.expectEqualStrings("api-key-only", value.?);
    }

    // github-copilot: COPILOT_GITHUB_TOKEN is the only accepted env var.
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("COPILOT_GITHUB_TOKEN", "copilot");

        const value = try getEnvApiKeyFromMap(allocator, &env_map, "github-copilot");
        defer if (value) |resolved| allocator.free(resolved);
        try std.testing.expectEqualStrings("copilot", value.?);
    }

    // github-copilot: generic GH_TOKEN is ignored.
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("GH_TOKEN", "gh");

        const value = try getEnvApiKeyFromMap(allocator, &env_map, "github-copilot");
        try std.testing.expect(value == null);
    }

    // github-copilot: generic GITHUB_TOKEN is ignored.
    {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put("GITHUB_TOKEN", "github-only");

        const value = try getEnvApiKeyFromMap(allocator, &env_map, "github-copilot");
        try std.testing.expect(value == null);
    }
}

fn makeEnvApiKeyTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
