const std = @import("std");
const ai = @import("ai");
const common = @import("../tools/common.zig");
const oauth_callback_listener = @import("oauth_callback_listener.zig");

pub const OAuthCallbackListener = oauth_callback_listener.OAuthCallbackListener;
pub const OAuthCallbackProviderKind = oauth_callback_listener.ProviderKind;
pub const defaultOAuthCallbackPath = oauth_callback_listener.defaultCallbackPath;
pub const defaultOAuthCallbackPort = oauth_callback_listener.defaultCallbackPort;

// Public OAuth client ids for the providers that ship a hard-coded "public"
// OAuth application with the binary. These are also recorded on
// `ai.provider_info.PROVIDERS` (field `oauth_default_client_id`) so display
// names, default models, env vars, and OAuth client ids are all consolidated
// onto one canonical per-provider table. The runtime cross-check test
// `auth provider client ids agree with ai.provider_info.PROVIDERS` below
// asserts agreement between this file and provider_info; do not edit one
// without updating the other.
const DEFAULT_ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const DEFAULT_GITHUB_COPILOT_CLIENT_ID = "Iv1.b507a08c87ecfe98";
const DEFAULT_OPENAI_CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const DEFAULT_XAI_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828";

const ANTHROPIC_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const ANTHROPIC_TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const ANTHROPIC_REDIRECT_URI = "http://localhost:53692/callback";
const ANTHROPIC_SCOPES =
    "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

const OPENAI_CODEX_AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const OPENAI_CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token";
const OPENAI_CODEX_REDIRECT_URI = "http://localhost:1455/auth/callback";
const OPENAI_CODEX_SCOPES = "openid profile email offline_access";
const OPENAI_CODEX_ORIGINATOR = "pi";
const OPENAI_CODEX_AUTH_CLAIM = "https://api.openai.com/auth";

const XAI_AUTHORIZE_URL = "https://auth.x.ai/oauth2/authorize";
const XAI_TOKEN_URL = "https://auth.x.ai/oauth2/token";
const XAI_REDIRECT_URI = "http://127.0.0.1:56121/callback";
const XAI_SCOPES = "openid profile email offline_access grok-cli:access api:access";

const GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code";
const GITHUB_ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token";
const GITHUB_COPILOT_TOKEN_URL = "https://api.github.com/copilot_internal/v2/token";

const COPILOT_USER_AGENT = "GitHubCopilotChat/0.35.0";
const COPILOT_EDITOR_VERSION = "vscode/1.107.0";
const COPILOT_PLUGIN_VERSION = "copilot-chat/0.35.0";
const COPILOT_INTEGRATION_ID = "vscode-chat";
const OAUTH_CLIENT_CONFIG_FILE_NAME = "oauth-clients.json";
const AUTH_FILE_PERMISSIONS: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    std.Io.File.Permissions.fromMode(0o600)
else
    .default_file;
const AUTH_LOCK_SUFFIX = ".lock";
const AUTH_LOCK_RETRY_DELAY_MS: i64 = 20;
const AUTH_LOCK_MAX_ATTEMPTS: usize = 250;

const OAuthRefreshEndpoints = struct {
    anthropic_token_url: []const u8 = ANTHROPIC_TOKEN_URL,
    github_copilot_token_url: []const u8 = GITHUB_COPILOT_TOKEN_URL,
    openai_codex_token_url: []const u8 = OPENAI_CODEX_TOKEN_URL,
    xai_token_url: []const u8 = XAI_TOKEN_URL,
};

pub const OAuthClientCredentials = struct {
    client_id: []u8,
    client_secret: ?[]u8 = null,

    pub fn deinit(self: *OAuthClientCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        if (self.client_secret) |client_secret| allocator.free(client_secret);
        self.* = undefined;
    }
};

pub const ProviderAuthType = enum {
    oauth,
    api_key,
};

pub const ProviderInfo = struct {
    id: []const u8,
    name: []const u8,
    auth_type: ProviderAuthType,
};

pub const OAUTH_LOGIN_PROVIDERS = [_]ProviderInfo{
    .{ .id = "anthropic", .name = "Anthropic (Claude Pro/Max)", .auth_type = .oauth },
    .{ .id = "openai-codex", .name = "ChatGPT Plus/Pro (Codex Subscription)", .auth_type = .oauth },
    .{ .id = "xai-oauth", .name = "xAI Grok OAuth", .auth_type = .oauth },
    .{ .id = "github-copilot", .name = "GitHub Copilot", .auth_type = .oauth },
};

/// Build an API-key `ProviderInfo` row whose `name` is sourced from
/// `ai.provider_info.PROVIDERS` rather than hand-typed here. Falls back to the
/// provider id if no `provider_info` row exists (the comptime cross-check
/// below rejects that case at build time, so this is defensive only).
fn apiKeyLoginProvider(comptime id: []const u8) ProviderInfo {
    return .{
        .id = id,
        .name = ai.provider_info.displayNameFor(id) orelse id,
        .auth_type = .api_key,
    };
}

pub const API_KEY_LOGIN_PROVIDERS = [_]ProviderInfo{
    apiKeyLoginProvider("anthropic"),
    apiKeyLoginProvider("amazon-bedrock"),
    apiKeyLoginProvider("azure-openai-responses"),
    apiKeyLoginProvider("cerebras"),
    apiKeyLoginProvider("deepseek"),
    apiKeyLoginProvider("cloudflare-ai-gateway"),
    apiKeyLoginProvider("cloudflare-workers-ai"),
    apiKeyLoginProvider("fireworks"),
    apiKeyLoginProvider("google"),
    apiKeyLoginProvider("google-vertex"),
    apiKeyLoginProvider("groq"),
    apiKeyLoginProvider("huggingface"),
    apiKeyLoginProvider("kimi"),
    apiKeyLoginProvider("kimi-coding"),
    apiKeyLoginProvider("kimi-code-openai"),
    apiKeyLoginProvider("mistral"),
    apiKeyLoginProvider("minimax"),
    apiKeyLoginProvider("minimax-cn"),
    apiKeyLoginProvider("moonshotai"),
    apiKeyLoginProvider("moonshotai-cn"),
    apiKeyLoginProvider("opencode"),
    apiKeyLoginProvider("opencode-go"),
    apiKeyLoginProvider("openai"),
    apiKeyLoginProvider("openai-codex"),
    apiKeyLoginProvider("openai-responses"),
    apiKeyLoginProvider("openrouter"),
    apiKeyLoginProvider("together"),
    apiKeyLoginProvider("vercel-ai-gateway"),
    apiKeyLoginProvider("xai"),
    apiKeyLoginProvider("xiaomi"),
    apiKeyLoginProvider("xiaomi-token-plan-cn"),
    apiKeyLoginProvider("xiaomi-token-plan-ams"),
    apiKeyLoginProvider("xiaomi-token-plan-sgp"),
    apiKeyLoginProvider("zai"),
};

pub const SUPPORTED_PROVIDERS = OAUTH_LOGIN_PROVIDERS ++ API_KEY_LOGIN_PROVIDERS;

// Compile-time cross-check: every login-provider id (api-key, oauth, oauth
// registry) must have a corresponding row in ai.provider_info.PROVIDERS so
// downstream consumers can resolve display names and other metadata from a
// single source of truth.
comptime {
    for (API_KEY_LOGIN_PROVIDERS) |row| {
        if (ai.provider_info.providerInfoFor(row.id) == null) {
            @compileError("auth login-provider \"" ++ row.id ++ "\" has no provider_info row");
        }
    }
    for (OAUTH_LOGIN_PROVIDERS) |row| {
        if (ai.provider_info.providerInfoFor(row.id) == null) {
            @compileError("auth login-provider \"" ++ row.id ++ "\" has no provider_info row");
        }
    }
}

pub const OAuthCredential = struct {
    access: []u8,
    refresh: []u8,
    expires: i64,
    project_id: ?[]u8 = null,

    pub fn deinit(self: *OAuthCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.access);
        allocator.free(self.refresh);
        if (self.project_id) |project_id| allocator.free(project_id);
        self.* = undefined;
    }
};

pub const StoredCredential = union(enum) {
    api_key: []u8,
    oauth: OAuthCredential,

    pub fn deinit(self: *StoredCredential, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .api_key => |value| allocator.free(value),
            .oauth => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const CredentialSource = enum {
    stored,
    runtime,
    environment,
};

pub const ResolvedApiKey = struct {
    api_key: []const u8,
    source: CredentialSource,
    owned_api_key: ?[]u8 = null,
};

pub const BrowserLoginKind = enum {
    anthropic,
    openai_codex,
    xai_oauth,
};

pub const BrowserLoginSession = struct {
    kind: BrowserLoginKind,
    provider_id: []const u8,
    provider_name: []const u8,
    oauth_client: OAuthClientCredentials,
    auth_url: []u8,
    verifier: []u8,
    state: []u8,

    pub fn deinit(self: *BrowserLoginSession, allocator: std.mem.Allocator) void {
        self.oauth_client.deinit(allocator);
        allocator.free(self.auth_url);
        allocator.free(self.verifier);
        allocator.free(self.state);
        self.* = undefined;
    }
};

pub const CopilotDeviceLogin = struct {
    provider_id: []const u8 = "github-copilot",
    provider_name: []const u8 = "GitHub Copilot",
    oauth_client: OAuthClientCredentials,
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    interval_seconds: u32,
    expires_at_ms: i64,

    pub fn deinit(self: *CopilotDeviceLogin, allocator: std.mem.Allocator) void {
        self.oauth_client.deinit(allocator);
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
        self.* = undefined;
    }
};

pub const CopilotPollResult = union(enum) {
    pending: []u8,
    completed: OAuthCredential,

    pub fn deinit(self: *CopilotPollResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pending => |value| allocator.free(value),
            .completed => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn findSupportedProvider(provider_id: []const u8) ?ProviderInfo {
    for (SUPPORTED_PROVIDERS) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

pub fn findSupportedProviderByAuthType(provider_id: []const u8, auth_type: ProviderAuthType) ?ProviderInfo {
    for (SUPPORTED_PROVIDERS) |provider| {
        if (provider.auth_type == auth_type and std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

pub fn getApiKeyProviderDisplayName(provider_id: []const u8) []const u8 {
    return ai.provider_info.displayNameFor(provider_id) orelse provider_id;
}

/// Per-provider auth specials lifted out of scattered `std.mem.eql` chains.
/// Each row encodes every aspect that the auth helpers consult on a per-provider
/// basis. Aspects with no row default to `null`/`false` and the call sites pick a
/// shared default.
const AuthProviderInfo = struct {
    id: []const u8,
    /// Built-in public OAuth client id; when set, no on-disk client config is required.
    default_public_client_id: ?[]const u8 = null,
    /// Alternate root-object key in `oauth-clients.json` (e.g. "github" for
    /// `github-copilot`).
    oauth_config_alias_key: ?[]const u8 = null,
    /// JSON snippet shown when client config is missing.
    oauth_config_snippet: ?[]const u8 = null,
    /// When true, the OAuth state parameter is a random hex value instead of
    /// being derived from the PKCE verifier.
    uses_hex_oauth_state: bool = false,
};

const ANTHROPIC_OAUTH_SNIPPET =
    \\{
    \\  "anthropic": {
    \\    "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    \\  }
    \\}
;

const GITHUB_COPILOT_OAUTH_SNIPPET =
    \\{
    \\  "github-copilot": {
    \\    "client_id": "YOUR_GITHUB_CLIENT_ID"
    \\  }
    \\}
;

const AUTH_PROVIDERS = [_]AuthProviderInfo{
    .{
        .id = "anthropic",
        .default_public_client_id = DEFAULT_ANTHROPIC_CLIENT_ID,
        .oauth_config_snippet = ANTHROPIC_OAUTH_SNIPPET,
    },
    .{
        .id = "github-copilot",
        .default_public_client_id = DEFAULT_GITHUB_COPILOT_CLIENT_ID,
        .oauth_config_alias_key = "github",
        .oauth_config_snippet = GITHUB_COPILOT_OAUTH_SNIPPET,
    },
    .{
        .id = "openai-codex",
        .default_public_client_id = DEFAULT_OPENAI_CODEX_CLIENT_ID,
        .uses_hex_oauth_state = true,
    },
    .{
        .id = "xai-oauth",
        .default_public_client_id = DEFAULT_XAI_CLIENT_ID,
        .uses_hex_oauth_state = true,
    },
};

fn authInfoFor(id: []const u8) ?*const AuthProviderInfo {
    for (&AUTH_PROVIDERS) |*info| {
        if (std.mem.eql(u8, info.id, id)) return info;
    }
    return null;
}

pub fn isApiKeyLoginProvider(
    provider_id: []const u8,
    oauth_provider_ids: []const []const u8,
    built_in_provider_ids: ?[]const []const u8,
) bool {
    for (API_KEY_LOGIN_PROVIDERS) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return true;
    }

    if (built_in_provider_ids) |provider_ids| {
        for (provider_ids) |candidate| {
            if (std.mem.eql(u8, candidate, provider_id)) return false;
        }
    } else {
        for (ai.model_registry.builtInProviderConfigs()) |provider| {
            if (std.mem.eql(u8, provider.provider, provider_id)) return false;
        }
    }

    for (oauth_provider_ids) |candidate| {
        if (std.mem.eql(u8, candidate, provider_id)) return false;
    }
    return true;
}

/// Compile-time OAuth provider descriptor used to dispatch browser-login
/// start requests without a hand-maintained if-chain.
const OAuthLoginProvider = struct {
    id: []const u8,
    kind: BrowserLoginKind,
    authorize_url: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    /// Extra query-string parameters appended to the authorization URL.
    extra_params: []const u8 = "",
    include_nonce: bool = false,
    /// When set, the initial `code=true` parameter is added.
    has_code_param: bool = false,
    require_client_secret: bool = false,
};

const OAUTH_LOGIN_PROVIDERS_REGISTRY = [_]OAuthLoginProvider{
    .{
        .id = "anthropic",
        .kind = .anthropic,
        .authorize_url = ANTHROPIC_AUTHORIZE_URL,
        .redirect_uri = ANTHROPIC_REDIRECT_URI,
        .scope = ANTHROPIC_SCOPES,
        .has_code_param = true,
    },
    .{
        .id = "openai-codex",
        .kind = .openai_codex,
        .authorize_url = OPENAI_CODEX_AUTHORIZE_URL,
        .redirect_uri = OPENAI_CODEX_REDIRECT_URI,
        .scope = OPENAI_CODEX_SCOPES,
        .extra_params = "&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=" ++ OPENAI_CODEX_ORIGINATOR,
    },
    .{
        .id = "xai-oauth",
        .kind = .xai_oauth,
        .authorize_url = XAI_AUTHORIZE_URL,
        .redirect_uri = XAI_REDIRECT_URI,
        .scope = XAI_SCOPES,
        .extra_params = "&plan=generic&referrer=hermes-agent",
        .include_nonce = true,
    },
};

// Compile-time cross-check: every OAuth registry id must have a row in
// ai.provider_info.PROVIDERS.
comptime {
    for (OAUTH_LOGIN_PROVIDERS_REGISTRY) |row| {
        if (ai.provider_info.providerInfoFor(row.id) == null) {
            @compileError("auth OAuth registry id \"" ++ row.id ++ "\" has no provider_info row");
        }
    }
}

pub fn startBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
) !BrowserLoginSession {
    for (OAUTH_LOGIN_PROVIDERS_REGISTRY) |desc| {
        if (std.mem.eql(u8, provider_id, desc.id)) {
            return startBrowserLoginForDescriptor(allocator, io, env_map, desc);
        }
    }
    return error.UnsupportedProvider;
}

pub fn startAnthropicBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !BrowserLoginSession {
    return startBrowserLoginForDescriptor(allocator, io, env_map, OAUTH_LOGIN_PROVIDERS_REGISTRY[0]);
}

pub fn startOpenAICodexBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !BrowserLoginSession {
    return startBrowserLoginForDescriptor(allocator, io, env_map, OAUTH_LOGIN_PROVIDERS_REGISTRY[1]);
}

pub fn startXAIBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !BrowserLoginSession {
    return startBrowserLoginForDescriptor(allocator, io, env_map, OAUTH_LOGIN_PROVIDERS_REGISTRY[2]);
}

fn startBrowserLoginForDescriptor(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    desc: OAuthLoginProvider,
) !BrowserLoginSession {
    const provider = findSupportedProvider(desc.id) orelse return error.UnsupportedProvider;
    const verifier = try generatePkceVerifier(allocator, io);
    errdefer allocator.free(verifier);

    const auth_info = authInfoFor(desc.id);
    const state = if (auth_info != null and auth_info.?.uses_hex_oauth_state)
        try generateOpenAICodexState(allocator, io)
    else
        try allocator.dupe(u8, verifier);
    errdefer allocator.free(state);

    const challenge = try generatePkceChallenge(allocator, verifier);
    defer allocator.free(challenge);

    var oauth_client = try loadOAuthClientCredentials(allocator, io, env_map, desc.id, desc.require_client_secret);
    errdefer oauth_client.deinit(allocator);

    const encoded_client_id = try formEncode(allocator, oauth_client.client_id);
    defer allocator.free(encoded_client_id);

    const encoded_redirect_uri = try formEncode(allocator, desc.redirect_uri);
    defer allocator.free(encoded_redirect_uri);

    const scope_text = try allocator.dupe(u8, desc.scope);
    defer allocator.free(scope_text);

    const encoded_scope = try formEncode(allocator, scope_text);
    defer allocator.free(encoded_scope);

    const encoded_challenge = try formEncode(allocator, challenge);
    defer allocator.free(encoded_challenge);

    const encoded_state = try formEncode(allocator, state);
    defer allocator.free(encoded_state);

    const nonce_param = if (desc.include_nonce)
        try std.fmt.allocPrint(allocator, "&nonce={s}", .{encoded_state})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(nonce_param);

    const code_param = if (desc.has_code_param) "code=true&" else "";
    const base_url = try std.fmt.allocPrint(
        allocator,
        "{s}?{s}client_id={s}&response_type=code&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}{s}{s}",
        .{
            desc.authorize_url,
            code_param,
            encoded_client_id,
            encoded_redirect_uri,
            encoded_scope,
            encoded_challenge,
            encoded_state,
            nonce_param,
            desc.extra_params,
        },
    );
    defer allocator.free(base_url);

    return .{
        .kind = desc.kind,
        .provider_id = provider.id,
        .provider_name = provider.name,
        .oauth_client = oauth_client,
        .auth_url = try allocator.dupe(u8, base_url),
        .verifier = verifier,
        .state = state,
    };
}

pub fn completeBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !StoredCredential {
    return switch (session.kind) {
        .anthropic => .{ .oauth = try exchangeAnthropicAuthorizationCode(allocator, io, session, input) },
        .openai_codex => .{ .oauth = try exchangeOpenAICodexAuthorizationCode(allocator, io, session, input) },
        .xai_oauth => .{ .oauth = try exchangeXAIAuthorizationCode(allocator, io, session, input) },
    };
}

pub fn startGitHubCopilotLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !CopilotDeviceLogin {
    const provider = findSupportedProvider("github-copilot").?;
    var oauth_client = try loadOAuthClientCredentials(allocator, io, env_map, provider.id, false);
    errdefer oauth_client.deinit(allocator);
    const body = try buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = oauth_client.client_id },
        .{ .name = "scope", .value = "read:user" },
    });
    defer allocator.free(body);

    var headers = try initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "User-Agent", .value = COPILOT_USER_AGENT },
    });
    defer deinitHeaders(allocator, &headers);

    const response_body = try postForm(allocator, io, GITHUB_DEVICE_CODE_URL, body, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    const device_code = getObjectString(parsed.value.object, "device_code") orelse return error.InvalidAuthResponse;
    const user_code = getObjectString(parsed.value.object, "user_code") orelse return error.InvalidAuthResponse;
    const verification_uri = getObjectString(parsed.value.object, "verification_uri") orelse return error.InvalidAuthResponse;
    const interval = getObjectInt(parsed.value.object, "interval") orelse return error.InvalidAuthResponse;
    const expires_in = getObjectInt(parsed.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .provider_id = provider.id,
        .provider_name = provider.name,
        .oauth_client = oauth_client,
        .device_code = try allocator.dupe(u8, device_code),
        .user_code = try allocator.dupe(u8, user_code),
        .verification_uri = try allocator.dupe(u8, verification_uri),
        .interval_seconds = @intCast(interval),
        .expires_at_ms = currentTimeMs(io) + expires_in * std.time.ms_per_s,
    };
}

pub fn pollGitHubCopilotLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const CopilotDeviceLogin,
) !CopilotPollResult {
    if (currentTimeMs(io) >= session.expires_at_ms) return error.AuthenticationExpired;

    const body = try buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = session.oauth_client.client_id },
        .{ .name = "device_code", .value = session.device_code },
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
    });
    defer allocator.free(body);

    var headers = try initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "User-Agent", .value = COPILOT_USER_AGENT },
    });
    defer deinitHeaders(allocator, &headers);

    const response_body = try postForm(allocator, io, GITHUB_ACCESS_TOKEN_URL, body, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    if (getObjectString(parsed.value.object, "access_token")) |github_access_token| {
        return .{
            .completed = try refreshGitHubCopilotToken(allocator, io, github_access_token),
        };
    }

    const error_name = getObjectString(parsed.value.object, "error") orelse return error.InvalidAuthResponse;
    if (std.mem.eql(u8, error_name, "authorization_pending")) {
        return .{ .pending = try allocator.dupe(u8, "Authorization still pending. Finish login in the browser, then press Enter again.") };
    }
    if (std.mem.eql(u8, error_name, "slow_down")) {
        return .{ .pending = try allocator.dupe(u8, "GitHub asked to slow down polling. Wait a few seconds, then press Enter again.") };
    }
    if (std.mem.eql(u8, error_name, "expired_token")) return error.AuthenticationExpired;
    if (std.mem.eql(u8, error_name, "access_denied")) return error.AuthenticationDenied;
    return error.InvalidAuthResponse;
}

pub fn buildApiKeyFromStoredEntry(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    object: std.json.ObjectMap,
) !?[]u8 {
    const type_value = getObjectString(object, "type");
    if (type_value) |value| {
        if (std.mem.eql(u8, value, "api_key")) {
            const key = getObjectString(object, "key") orelse return null;
            return try allocator.dupe(u8, key);
        }
        if (std.mem.eql(u8, value, "oauth")) {
            const access = getObjectString(object, "access") orelse getObjectString(object, "access_token") orelse return null;
            _ = provider_id;
            return try allocator.dupe(u8, access);
        }
    }

    if (getObjectString(object, "key")) |key| return try allocator.dupe(u8, key);
    return null;
}

pub fn buildApiKeyFromStoredEntryRefreshing(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    auth_path: []const u8,
    provider_id: []const u8,
    object: std.json.ObjectMap,
) !?[]u8 {
    return buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        env_map,
        auth_path,
        provider_id,
        object,
        .{},
    );
}

fn buildApiKeyFromStoredEntryWithRefreshEndpoints(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    auth_path: ?[]const u8,
    provider_id: []const u8,
    object: std.json.ObjectMap,
    endpoints: OAuthRefreshEndpoints,
) !?[]u8 {
    const type_value = getObjectString(object, "type");
    if (type_value) |value| {
        if (std.mem.eql(u8, value, "api_key")) {
            const key = getObjectString(object, "key") orelse return null;
            return try allocator.dupe(u8, key);
        }
        if (std.mem.eql(u8, value, "oauth")) {
            var credential = (try parseStoredOAuthCredential(allocator, provider_id, object)) orelse return null;
            defer credential.deinit(allocator);

            if (getObjectInt(object, "expires")) |expires| {
                if (currentTimeMs(io) >= expires) {
                    if (credential.refresh.len == 0) return null;
                    var refreshed = refreshOAuthCredentialWithEndpoints(
                        allocator,
                        io,
                        env_map,
                        provider_id,
                        &credential,
                        endpoints,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => return null,
                    };
                    defer refreshed.deinit(allocator);

                    if (auth_path) |path| {
                        const stored = StoredCredential{ .oauth = refreshed };
                        try upsertStoredCredential(allocator, io, path, provider_id, &stored);
                    }

                    return try buildApiKeyFromOAuthCredential(allocator, provider_id, &refreshed);
                }
            }

            return try buildApiKeyFromOAuthCredential(allocator, provider_id, &credential);
        }
    }

    if (getObjectString(object, "key")) |key| return try allocator.dupe(u8, key);
    return null;
}

// Shell command execution for "!" prefix support.
// Uses a module-level cache for the current process.
var command_result_cache: ?std.StringHashMap(?[]u8) = null;

pub fn clearCommandResultCache() void {
    if (command_result_cache) |*cache| {
        var values = cache.valueIterator();
        while (values.next()) |value_ptr| {
            if (value_ptr.*) |value| cache.allocator.free(value);
        }
        cache.deinit();
        command_result_cache = null;
    }
}

fn getOrInitCommandCache(allocator: std.mem.Allocator) *std.StringHashMap(?[]u8) {
    if (command_result_cache == null) {
        command_result_cache = std.StringHashMap(?[]u8).init(allocator);
    }
    return &command_result_cache.?;
}

fn executeShellCommand(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !?[]u8 {
    const cache = getOrInitCommandCache(allocator);

    // Check cache first
    if (cache.get(command)) |cached| {
        if (cached) |c| return try allocator.dupe(u8, c);
        return null;
    }

    // Execute command via /bin/sh -c <command>
    const builtin = @import("builtin");
    const shell: []const u8 = if (builtin.os.tag == .windows) "bash" else "/bin/sh";
    const argv = [_][]const u8{ shell, "-c", command };
    const run_result = std.process.run(allocator, io, .{
        .argv = argv[0..],
        .stdout_limit = .limited(8192),
    }) catch {
        try cache.put(command, null);
        return null;
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    var result: ?[]u8 = null;
    if (run_result.term == .exited and run_result.term.exited == 0) {
        const trimmed = std.mem.trim(u8, run_result.stdout, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            result = allocator.dupe(u8, trimmed) catch return null;
        }
    }

    // Cache a copy; caller gets the original. The cache copy persists for the
    // process lifetime and is never freed (module-level singleton).
    if (result) |r| {
        const cached_copy = allocator.dupe(u8, r) catch null;
        try cache.put(command, cached_copy);
        if (cached_copy) |_| return r;
        // If we couldn't allocate a cache copy, still return the result uncached.
        return r;
    }
    try cache.put(command, null);
    return null;
}

pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    runtime_override: ?[]const u8,
    stored_api_key: ?[]const u8,
) !?ResolvedApiKey {
    // Check for "!" prefix - execute as shell command
    if (runtime_override) |value| {
        if (std.mem.trim(u8, value, &std.ascii.whitespace).len > 0) {
            if (value[0] == '!') {
                const result = executeShellCommand(allocator, io, value[1..]) catch return null;
                if (result) |cmd_result| {
                    return .{
                        .api_key = cmd_result,
                        .source = .runtime,
                        .owned_api_key = cmd_result,
                    };
                }
                return null;
            }
            return .{
                .api_key = value,
                .source = .runtime,
            };
        }
    }

    // Check for "!" prefix in stored API key
    if (stored_api_key) |value| {
        if (std.mem.trim(u8, value, &std.ascii.whitespace).len > 0) {
            if (value[0] == '!') {
                const result = executeShellCommand(allocator, io, value[1..]) catch return null;
                if (result) |cmd_result| {
                    return .{
                        .api_key = cmd_result,
                        .source = .stored,
                        .owned_api_key = cmd_result,
                    };
                }
                return null;
            }
            return .{
                .api_key = value,
                .source = .stored,
            };
        }
    }

    const env_api_key = try ai.env_api_keys.getEnvApiKeyFromMap(allocator, env_map, provider_id);
    if (env_api_key) |value| {
        return .{
            .api_key = value,
            .source = .environment,
            .owned_api_key = value,
        };
    }

    return null;
}

pub fn readStoredCredentialsObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
) !std.json.Value {
    var lock = try AuthFileLock.acquire(allocator, io, auth_path);
    defer lock.release(io);
    return readAuthFileObjectUnlocked(allocator, io, auth_path);
}

pub fn listStoredProviders(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
) ![]ProviderInfo {
    const stored = try readStoredCredentialsObject(allocator, io, auth_path);
    defer common.deinitJsonValue(allocator, stored);
    if (stored != .object) return allocator.alloc(ProviderInfo, 0);

    var providers = std.ArrayList(ProviderInfo).empty;
    errdefer providers.deinit(allocator);

    var iterator = stored.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const auth_type = storedCredentialAuthType(entry.value_ptr.object) orelse continue;
        const provider = findSupportedProviderByAuthType(entry.key_ptr.*, auth_type) orelse continue;
        try providers.append(allocator, provider);
    }

    return try providers.toOwnedSlice(allocator);
}

pub fn upsertStoredCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider_id: []const u8,
    credential: *const StoredCredential,
) !void {
    var lock = try AuthFileLock.acquire(allocator, io, auth_path);
    defer lock.release(io);

    const existing = try readAuthFileObjectUnlocked(allocator, io, auth_path);
    defer common.deinitJsonValue(allocator, existing);

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    if (existing == .object) {
        var iterator = existing.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, provider_id)) continue;
            try next_object.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try common.cloneJsonValue(allocator, entry.value_ptr.*),
            );
        }
    }

    try common.putValue(allocator, &next_object, provider_id, try credentialToJson(allocator, credential));
    try writeAuthObjectUnlocked(allocator, io, auth_path, next_object);
}

pub fn removeStoredCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider_id: []const u8,
) !bool {
    var lock = try AuthFileLock.acquire(allocator, io, auth_path);
    defer lock.release(io);

    const existing = try readAuthFileObjectUnlocked(allocator, io, auth_path);
    defer common.deinitJsonValue(allocator, existing);
    if (existing != .object) return false;

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    var removed = false;
    var iterator = existing.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, provider_id)) {
            removed = true;
            continue;
        }
        try next_object.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }

    if (!removed) {
        const cleanup_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, cleanup_value);
        return false;
    }

    try writeAuthObjectUnlocked(allocator, io, auth_path, next_object);
    return true;
}

const EncodedField = struct {
    name: []const u8,
    value: []const u8,
};

const AuthorizationInput = struct {
    code: ?[]u8 = null,
    state: ?[]u8 = null,

    fn deinit(self: *const AuthorizationInput, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
    }
};

fn credentialToJson(allocator: std.mem.Allocator, credential: *const StoredCredential) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    switch (credential.*) {
        .api_key => |key| {
            try common.putString(allocator, &object, "type", "api_key");
            try common.putString(allocator, &object, "key", key);
        },
        .oauth => |oauth| {
            try common.putString(allocator, &object, "type", "oauth");
            try common.putString(allocator, &object, "access", oauth.access);
            try common.putString(allocator, &object, "refresh", oauth.refresh);
            try common.putInt(allocator, &object, "expires", oauth.expires);
            if (oauth.project_id) |project_id| {
                try common.putString(allocator, &object, "projectId", project_id);
            }
        },
    }

    return .{ .object = object };
}

fn storedCredentialAuthType(object: std.json.ObjectMap) ?ProviderAuthType {
    if (getObjectString(object, "type")) |value| {
        if (std.mem.eql(u8, value, "oauth")) return .oauth;
        if (std.mem.eql(u8, value, "api_key")) return .api_key;
    }
    if (getObjectString(object, "key") != null) return .api_key;
    return null;
}

const AuthFileLock = struct {
    allocator: std.mem.Allocator,
    lock_path: []u8,

    fn acquire(allocator: std.mem.Allocator, io: std.Io, auth_path: []const u8) !AuthFileLock {
        try ensureAuthStorageParentDir(io, auth_path);

        const lock_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ auth_path, AUTH_LOCK_SUFFIX });
        errdefer allocator.free(lock_path);

        if (std.fs.path.dirname(lock_path)) |parent_dir| {
            try std.Io.Dir.createDirPath(.cwd(), io, parent_dir);
        }

        var attempt: usize = 0;
        while (attempt < AUTH_LOCK_MAX_ATTEMPTS) : (attempt += 1) {
            std.Io.Dir.createDir(.cwd(), io, lock_path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    _ = io.sleep(.fromMilliseconds(AUTH_LOCK_RETRY_DELAY_MS), .awake) catch {};
                    continue;
                },
                else => return err,
            };

            return .{
                .allocator = allocator,
                .lock_path = lock_path,
            };
        }

        return error.AuthStorageLockTimeout;
    }

    fn release(self: *AuthFileLock, io: std.Io) void {
        std.Io.Dir.deleteDir(.cwd(), io, self.lock_path) catch {};
        self.allocator.free(self.lock_path);
    }
};

fn ensureAuthStorageParentDir(io: std.Io, auth_path: []const u8) !void {
    const parent_dir = std.fs.path.dirname(auth_path) orelse return;
    try std.Io.Dir.createDirPath(.cwd(), io, parent_dir);
}

fn readAuthFileObjectUnlocked(allocator: std.mem.Allocator, io: std.Io, auth_path: []const u8) !std.json.Value {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, auth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        else => return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    }

    return try common.cloneJsonValue(allocator, parsed.value);
}

fn writeAuthObjectUnlocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    object: std.json.ObjectMap,
) !void {
    const value: std.json.Value = .{ .object = object };
    defer common.deinitJsonValue(allocator, value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);

    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, auth_path, .{
        .permissions = AUTH_FILE_PERMISSIONS,
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(serialized);
    try writer.flush();
    try atomic_file.replace(io);
}

pub fn formatOAuthClientConfigError(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    err: anyerror,
) !?[]u8 {
    const handled = switch (err) {
        error.MissingOAuthConfigFile, error.InvalidOAuthConfigFile, error.MissingOAuthClientConfig, error.MissingOAuthClientId, error.MissingOAuthClientSecret => true,
        else => false,
    };
    if (!handled) return null;

    const provider = findSupportedProvider(provider_id) orelse return null;
    const oauth_path = try resolveOAuthClientConfigPath(allocator, env_map);
    defer allocator.free(oauth_path);
    const snippet = oauthConfigSnippet(provider_id);

    const reason = switch (err) {
        error.MissingOAuthConfigFile => "OAuth client credentials are not configured.",
        error.InvalidOAuthConfigFile => "The OAuth client config file is not valid JSON.",
        error.MissingOAuthClientConfig => "This provider is missing from the OAuth client config file.",
        error.MissingOAuthClientId => "The provider config is missing client_id.",
        error.MissingOAuthClientSecret => "The provider config is missing client_secret.",
        else => unreachable,
    };

    return try std.fmt.allocPrint(
        allocator,
        "{s} Create {s} with an entry for {s}, for example:\n{s}\n\nThis file stores OAuth client application credentials only. Stored OAuth tokens remain in auth.json; legacy oauth.json is ignored for client config.",
        .{ reason, oauth_path, provider.name, snippet },
    );
}

pub fn formatAuthenticationError(allocator: std.mem.Allocator, err: anyerror) !?[]u8 {
    const message = switch (err) {
        error.InvalidAuthorizationInput => "Paste the full redirect URL or authorization code from the browser callback.",
        error.MissingAuthorizationCode => "The callback URL is missing the `code` parameter. Paste the full redirect URL.",
        error.InvalidOAuthState => "The callback URL belongs to a different login attempt. Run /login again and paste the newest redirect URL.",
        error.MissingProjectId => "Enter a Google Cloud project ID after the redirect URL is accepted.",
        error.InvalidAuthResponse => "OAuth token exchange returned an unexpected response.",
        error.MissingAccessToken => "OAuth token exchange succeeded but did not return an access token.",
        error.MissingRefreshToken => "OAuth token exchange succeeded but did not return a refresh token.",
        error.InvalidJwt, error.InvalidJwtPayload, error.MissingAccountId => "OAuth token exchange succeeded but did not return a valid ChatGPT account token.",
        error.HttpRequestFailed => "OAuth token exchange failed. Verify the client credentials and try /login again.",
        error.Timeout => "OAuth token exchange timed out. Try /login again.",
        error.ConnectionRefused, error.ConnectionReset, error.NetworkUnreachable, error.UnknownHost, error.TlsFailure => "Could not reach the OAuth provider during token exchange.",
        else => return null,
    };
    return try allocator.dupe(u8, message);
}

fn loadOAuthClientCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    require_client_secret: bool,
) !OAuthClientCredentials {
    if (defaultPublicOAuthClientId(provider_id)) |client_id| {
        if (require_client_secret) return error.MissingOAuthClientSecret;
        return .{
            .client_id = try allocator.dupe(u8, client_id),
            .client_secret = null,
        };
    }

    const oauth_path = try resolveOAuthClientConfigPath(allocator, env_map);
    defer allocator.free(oauth_path);

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, oauth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingOAuthConfigFile,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidOAuthConfigFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthConfigFile;

    const provider_object = findOAuthProviderObject(parsed.value.object, provider_id) orelse return error.MissingOAuthClientConfig;
    const configured_client_id = getObjectStringAny(provider_object, &.{ "client_id", "clientId" });
    const client_secret = getObjectStringAny(provider_object, &.{ "client_secret", "clientSecret" });
    if (require_client_secret and client_secret == null) return error.MissingOAuthClientSecret;

    return .{
        .client_id = try resolveOAuthClientId(allocator, provider_id, configured_client_id),
        .client_secret = if (client_secret) |value| try allocator.dupe(u8, value) else null,
    };
}

fn resolveOAuthClientId(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    configured_client_id: ?[]const u8,
) ![]u8 {
    if (defaultPublicOAuthClientId(provider_id)) |client_id| {
        return allocator.dupe(u8, client_id);
    }

    const trimmed = std.mem.trim(u8, configured_client_id orelse "", &std.ascii.whitespace);
    if (trimmed.len == 0) return error.MissingOAuthClientId;

    return allocator.dupe(u8, trimmed);
}

fn defaultPublicOAuthClientId(provider_id: []const u8) ?[]const u8 {
    const info = authInfoFor(provider_id) orelse return null;
    return info.default_public_client_id;
}

fn isValidAnthropicClientId(value: []const u8) bool {
    const uuid = if (std.mem.startsWith(u8, value, "urn:uuid:")) value["urn:uuid:".len..] else value;
    if (uuid.len != 36) return false;

    for (uuid, 0..) |char, index| {
        switch (index) {
            8, 13, 18, 23 => {
                if (char != '-') return false;
            },
            else => {
                if (!std.ascii.isHex(char)) return false;
            },
        }
    }

    return true;
}

fn resolveOAuthClientConfigPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    const agent_dir = try resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ agent_dir, OAUTH_CLIENT_CONFIG_FILE_NAME });
}

fn resolveAgentDir(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("PI_CODING_AGENT_DIR")) |value| {
        return expandLeadingHome(allocator, env_map, value);
    }

    const base_dir = if (env_map.get("PI_CONFIG_DIR")) |value|
        try expandLeadingHome(allocator, env_map, value)
    else if (env_map.get("HOME")) |home|
        try std.fs.path.join(allocator, &[_][]const u8{ home, ".pi" })
    else
        try allocator.dupe(u8, ".pi");
    defer allocator.free(base_dir);

    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, "agent" });
}

fn expandLeadingHome(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, value: []const u8) ![]u8 {
    const home = env_map.get("HOME") orelse return allocator.dupe(u8, value);
    if (std.mem.eql(u8, value, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, value, "~/")) return std.fs.path.join(allocator, &[_][]const u8{ home, value[2..] });
    return allocator.dupe(u8, value);
}

fn findOAuthProviderObject(root: std.json.ObjectMap, provider_id: []const u8) ?std.json.ObjectMap {
    if (root.get(provider_id)) |value| {
        if (value == .object) return value.object;
    }

    if (authInfoFor(provider_id)) |info| {
        if (info.oauth_config_alias_key) |alias| {
            if (root.get(alias)) |value| {
                if (value == .object) return value.object;
            }
        }
    }

    return null;
}

fn oauthConfigSnippet(provider_id: []const u8) []const u8 {
    if (authInfoFor(provider_id)) |info| {
        if (info.oauth_config_snippet) |snippet| return snippet;
    }
    return ANTHROPIC_OAUTH_SNIPPET;
}

fn exchangeAnthropicAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !OAuthCredential {
    const parsed = try parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);

    const state = parsed.state orelse return error.InvalidOAuthState;
    if (!std.mem.eql(u8, state, session.state)) return error.InvalidOAuthState;

    const code = parsed.code orelse return error.MissingAuthorizationCode;

    const json_body = try buildAnthropicTokenExchangeBody(allocator, session, code);
    defer allocator.free(json_body);

    const response_body = try postJson(allocator, io, ANTHROPIC_TOKEN_URL, json_body, null);
    defer allocator.free(response_body);

    var parsed_response = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed_response.deinit();
    if (parsed_response.value != .object) return error.InvalidAuthResponse;

    const access_token = getObjectString(parsed_response.value.object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = getObjectString(parsed_response.value.object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = getObjectInt(parsed_response.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .access = try allocator.dupe(u8, access_token),
        .refresh = try allocator.dupe(u8, refresh_token),
        .expires = computeExpiresAtMs(expires_in, io),
    };
}

fn writeJsonStringField(writer: *std.Io.Writer, first: *bool, comptime name: []const u8, value: []const u8) !void {
    if (first.*) {
        first.* = false;
    } else {
        try writer.writeByte(',');
    }
    try writer.print("\"{s}\":", .{name});
    try std.json.Stringify.value(value, .{}, writer);
}

fn buildAnthropicTokenExchangeBody(
    allocator: std.mem.Allocator,
    session: *const BrowserLoginSession,
    code: []const u8,
) ![]u8 {
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_writer.deinit();

    const writer = &body_writer.writer;
    try writer.writeByte('{');
    var first = true;
    try writeJsonStringField(writer, &first, "grant_type", "authorization_code");
    try writeJsonStringField(writer, &first, "client_id", session.oauth_client.client_id);
    try writeJsonStringField(writer, &first, "code", code);
    try writeJsonStringField(writer, &first, "state", session.verifier);
    try writeJsonStringField(writer, &first, "redirect_uri", ANTHROPIC_REDIRECT_URI);
    try writeJsonStringField(writer, &first, "code_verifier", session.verifier);
    try writer.writeByte('}');

    return try body_writer.toOwnedSlice();
}

fn exchangeOpenAICodexAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !OAuthCredential {
    return exchangeOpenAICodexAuthorizationCodeWithTokenUrl(allocator, io, session, input, OPENAI_CODEX_TOKEN_URL);
}

fn exchangeOpenAICodexAuthorizationCodeWithTokenUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
    token_url: []const u8,
) !OAuthCredential {
    if (session.kind != .openai_codex) return error.UnsupportedProvider;
    const parsed = try parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);

    if (parsed.state) |state| {
        if (!std.mem.eql(u8, state, session.state)) return error.InvalidOAuthState;
    }

    const code = parsed.code orelse return error.MissingAuthorizationCode;
    const body = try buildOpenAICodexTokenExchangeBody(allocator, session, code);
    defer allocator.free(body);

    const response_body = try postForm(allocator, io, token_url, body, null);
    defer allocator.free(response_body);

    var parsed_response = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed_response.deinit();
    if (parsed_response.value != .object) return error.InvalidAuthResponse;

    const access_token = getObjectString(parsed_response.value.object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = getObjectString(parsed_response.value.object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = getObjectInt(parsed_response.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    const account_id = try extractOpenAICodexAccountId(allocator, access_token);
    defer allocator.free(account_id);

    return .{
        .access = try allocator.dupe(u8, access_token),
        .refresh = try allocator.dupe(u8, refresh_token),
        .expires = computeExpiresAtMs(expires_in, io),
    };
}

fn buildOpenAICodexTokenExchangeBody(
    allocator: std.mem.Allocator,
    session: *const BrowserLoginSession,
    code: []const u8,
) ![]u8 {
    return buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "client_id", .value = session.oauth_client.client_id },
        .{ .name = "code", .value = code },
        .{ .name = "code_verifier", .value = session.verifier },
        .{ .name = "redirect_uri", .value = OPENAI_CODEX_REDIRECT_URI },
    });
}

fn exchangeXAIAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !OAuthCredential {
    return exchangeXAIAuthorizationCodeWithTokenUrl(allocator, io, session, input, XAI_TOKEN_URL);
}

fn exchangeXAIAuthorizationCodeWithTokenUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
    token_url: []const u8,
) !OAuthCredential {
    if (session.kind != .xai_oauth) return error.UnsupportedProvider;
    const parsed = try parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);

    if (parsed.state) |state| {
        if (!std.mem.eql(u8, state, session.state)) return error.InvalidOAuthState;
    }

    const code = parsed.code orelse return error.MissingAuthorizationCode;
    const body = try buildXAITokenExchangeBody(allocator, session, code);
    defer allocator.free(body);

    const response_body = try postForm(allocator, io, token_url, body, null);
    defer allocator.free(response_body);
    return try parseOAuthRefreshResponse(allocator, io, response_body, .exact);
}

fn buildXAITokenExchangeBody(
    allocator: std.mem.Allocator,
    session: *const BrowserLoginSession,
    code: []const u8,
) ![]u8 {
    return buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "client_id", .value = session.oauth_client.client_id },
        .{ .name = "code", .value = code },
        .{ .name = "code_verifier", .value = session.verifier },
        .{ .name = "redirect_uri", .value = XAI_REDIRECT_URI },
    });
}

fn refreshGitHubCopilotToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    github_access_token: []const u8,
) !OAuthCredential {
    return refreshGitHubCopilotTokenWithUrl(allocator, io, github_access_token, GITHUB_COPILOT_TOKEN_URL);
}

fn refreshGitHubCopilotTokenWithUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    github_access_token: []const u8,
    token_url: []const u8,
) !OAuthCredential {
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{github_access_token});
    defer allocator.free(authorization);

    var headers = try initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = authorization },
        .{ .name = "User-Agent", .value = COPILOT_USER_AGENT },
        .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION },
        .{ .name = "Editor-Plugin-Version", .value = COPILOT_PLUGIN_VERSION },
        .{ .name = "Copilot-Integration-Id", .value = COPILOT_INTEGRATION_ID },
    });
    defer deinitHeaders(allocator, &headers);

    const response_body = try getRequest(allocator, io, token_url, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    const token = getObjectString(parsed.value.object, "token") orelse return error.MissingAccessToken;
    const expires_at = getObjectInt(parsed.value.object, "expires_at") orelse return error.InvalidAuthResponse;

    return .{
        .access = try allocator.dupe(u8, token),
        .refresh = try allocator.dupe(u8, github_access_token),
        .expires = expires_at * std.time.ms_per_s - 5 * std.time.ms_per_min,
    };
}

fn refreshOAuthCredentialWithEndpoints(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    credential: *const OAuthCredential,
    endpoints: OAuthRefreshEndpoints,
) !OAuthCredential {
    if (std.mem.eql(u8, provider_id, "anthropic")) {
        return refreshAnthropicStoredTokenWithUrl(allocator, io, credential.refresh, endpoints.anthropic_token_url);
    }
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return refreshGitHubCopilotTokenWithUrl(allocator, io, credential.refresh, endpoints.github_copilot_token_url);
    }
    if (std.mem.eql(u8, provider_id, "openai-codex")) {
        return refreshOpenAICodexStoredTokenWithUrl(allocator, io, credential.refresh, endpoints.openai_codex_token_url);
    }
    if (std.mem.eql(u8, provider_id, "xai-oauth")) {
        return refreshXAIStoredTokenWithUrl(allocator, io, credential.refresh, endpoints.xai_token_url);
    }
    _ = env_map;
    return error.UnsupportedProvider;
}

fn refreshAnthropicStoredTokenWithUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    refresh_token: []const u8,
    token_url: []const u8,
) !OAuthCredential {
    var payload = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer {
        const cleanup_value: std.json.Value = .{ .object = payload };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    try common.putString(allocator, &payload, "grant_type", "refresh_token");
    try common.putString(allocator, &payload, "client_id", DEFAULT_ANTHROPIC_CLIENT_ID);
    try common.putString(allocator, &payload, "refresh_token", refresh_token);

    const payload_value: std.json.Value = .{ .object = payload };
    const json_body = try std.json.Stringify.valueAlloc(allocator, payload_value, .{});
    defer allocator.free(json_body);

    const response_body = try postJson(allocator, io, token_url, json_body, null);
    defer allocator.free(response_body);
    return parseOAuthRefreshResponse(allocator, io, response_body, .with_skew);
}

fn refreshOpenAICodexStoredTokenWithUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    refresh_token: []const u8,
    token_url: []const u8,
) !OAuthCredential {
    const body = try buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = DEFAULT_OPENAI_CODEX_CLIENT_ID },
    });
    defer allocator.free(body);

    const response_body = try postForm(allocator, io, token_url, body, null);
    defer allocator.free(response_body);
    var credential = try parseOAuthRefreshResponse(allocator, io, response_body, .exact);
    errdefer credential.deinit(allocator);

    const account_id = try extractOpenAICodexAccountId(allocator, credential.access);
    defer allocator.free(account_id);
    return credential;
}

fn refreshXAIStoredTokenWithUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    refresh_token: []const u8,
    token_url: []const u8,
) !OAuthCredential {
    const body = try buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = DEFAULT_XAI_CLIENT_ID },
    });
    defer allocator.free(body);

    const response_body = try postForm(allocator, io, token_url, body, null);
    defer allocator.free(response_body);
    return parseOAuthRefreshResponse(allocator, io, response_body, .exact);
}

const RefreshExpiryMode = enum {
    with_skew,
    exact,
};

fn parseOAuthRefreshResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    response_body: []const u8,
    expiry_mode: RefreshExpiryMode,
) !OAuthCredential {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    const access_token = getObjectString(parsed.value.object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = getObjectString(parsed.value.object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = getObjectInt(parsed.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    const expires = switch (expiry_mode) {
        .with_skew => computeExpiresAtMs(expires_in, io),
        .exact => currentTimeMs(io) + expires_in * std.time.ms_per_s,
    };

    return .{
        .access = try allocator.dupe(u8, access_token),
        .refresh = try allocator.dupe(u8, refresh_token),
        .expires = expires,
    };
}

fn parseAuthorizationInput(allocator: std.mem.Allocator, input: []const u8) !AuthorizationInput {
    const trimmed = std.mem.trim(u8, input, " \t\r\n\"'");
    if (trimmed.len == 0) return error.InvalidAuthorizationInput;

    if (std.mem.indexOfScalar(u8, trimmed, '#')) |separator| {
        if (std.mem.indexOfScalar(u8, trimmed, '?') == null and std.mem.indexOf(u8, trimmed, "code=") == null) {
            return .{
                .code = try allocator.dupe(u8, trimmed[0..separator]),
                .state = try allocator.dupe(u8, trimmed[separator + 1 ..]),
            };
        }
    }

    if (std.mem.indexOfScalar(u8, trimmed, '?')) |query_index| {
        return extractAuthorizationFromQuery(allocator, trimmed[query_index + 1 ..]);
    }

    if (std.mem.indexOf(u8, trimmed, "code=")) |_| {
        return extractAuthorizationFromQuery(allocator, trimmed);
    }

    return .{ .code = try allocator.dupe(u8, trimmed) };
}

fn extractAuthorizationFromQuery(allocator: std.mem.Allocator, query: ?[]const u8) !AuthorizationInput {
    const query_text = query orelse return error.InvalidAuthorizationInput;
    const fragment_trimmed = if (std.mem.indexOfScalar(u8, query_text, '#')) |fragment_index|
        query_text[0..fragment_index]
    else
        query_text;
    var result = AuthorizationInput{};
    errdefer result.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, fragment_trimmed, '&');
    while (iterator.next()) |part| {
        const equals_index = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const name = part[0..equals_index];
        const value = try percentDecodeAlloc(allocator, part[equals_index + 1 ..]);
        errdefer allocator.free(value);
        if (std.mem.eql(u8, name, "code")) {
            if (result.code) |existing| allocator.free(existing);
            result.code = value;
        } else if (std.mem.eql(u8, name, "state")) {
            if (result.state) |existing| allocator.free(existing);
            result.state = value;
        } else {
            allocator.free(value);
        }
    }

    if (result.code == null) return error.MissingAuthorizationCode;
    return result;
}

fn getRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: ?*std.StringHashMap([]const u8),
) ![]u8 {
    var client = try ai.http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = client.request(.{
        .method = .GET,
        .url = url,
        .headers = if (headers) |value| value.* else null,
    }) catch |err| return mapHttpError(err);
    defer response.deinit();
    return try allocator.dupe(u8, response.body);
}

fn postJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    extra_headers: ?*std.StringHashMap([]const u8),
) ![]u8 {
    var headers = try initHeaders(allocator, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    });
    defer deinitHeaders(allocator, &headers);
    if (extra_headers) |value| try cloneHeadersInto(allocator, &headers, value);

    var client = try ai.http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = client.request(.{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = body,
    }) catch |err| return mapHttpError(err);
    defer response.deinit();

    return try allocator.dupe(u8, response.body);
}

fn postForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    extra_headers: ?*std.StringHashMap([]const u8),
) ![]u8 {
    var headers = try initHeaders(allocator, &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
    });
    defer deinitHeaders(allocator, &headers);
    if (extra_headers) |value| try cloneHeadersInto(allocator, &headers, value);

    var client = try ai.http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = client.request(.{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = body,
    }) catch |err| return mapHttpError(err);
    defer response.deinit();

    return try allocator.dupe(u8, response.body);
}

fn initHeaders(allocator: std.mem.Allocator, pairs: []const struct { name: []const u8, value: []const u8 }) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitHeaders(allocator, &headers);
    for (pairs) |pair| {
        try headers.put(try allocator.dupe(u8, pair.name), try allocator.dupe(u8, pair.value));
    }
    return headers;
}

fn cloneHeadersInto(
    allocator: std.mem.Allocator,
    dest: *std.StringHashMap([]const u8),
    source: *std.StringHashMap([]const u8),
) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try dest.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
    }
}

fn deinitHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn buildFormBody(allocator: std.mem.Allocator, fields: []const EncodedField) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    for (fields, 0..) |field, index| {
        if (index > 0) try list.append(allocator, '&');
        const encoded_name = try formEncode(allocator, field.name);
        defer allocator.free(encoded_name);
        const encoded_value = try formEncode(allocator, field.value);
        defer allocator.free(encoded_value);
        try list.appendSlice(allocator, encoded_name);
        try list.append(allocator, '=');
        try list.appendSlice(allocator, encoded_value);
    }

    return try list.toOwnedSlice(allocator);
}

fn generatePkceVerifier(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(currentTimeMs(io)));
    prng.random().bytes(&bytes);
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &bytes);
    return encoded;
}

fn generateOpenAICodexState(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const encoded = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, encoded[0..]);
}

fn generatePkceChallenge(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(digest.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &digest);
    return encoded;
}

fn computeExpiresAtMs(expires_in_seconds: i64, io: std.Io) i64 {
    return currentTimeMs(io) + expires_in_seconds * std.time.ms_per_s - 5 * std.time.ms_per_min;
}

fn currentTimeMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

fn parseStoredOAuthCredential(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    object: std.json.ObjectMap,
) !?OAuthCredential {
    const access = getObjectStringAny(object, &[_][]const u8{ "access", "access_token" }) orelse return null;
    const refresh = getObjectStringAny(object, &[_][]const u8{ "refresh", "refresh_token" }) orelse "";
    const expires = getObjectInt(object, "expires") orelse 0;
    _ = provider_id;

    return .{
        .access = try allocator.dupe(u8, access),
        .refresh = try allocator.dupe(u8, refresh),
        .expires = expires,
        .project_id = null,
    };
}

fn buildApiKeyFromOAuthCredential(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    credential: *const OAuthCredential,
) ![]u8 {
    _ = provider_id;
    return try allocator.dupe(u8, credential.access);
}

fn extractOpenAICodexAccountId(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const payload_segment = parts.next() orelse return error.InvalidJwt;
    if (payload_segment.len == 0) return error.InvalidJwt;
    _ = parts.next() orelse return error.InvalidJwt;

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return error.InvalidJwtPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJwtPayload;
    const auth_value = parsed.value.object.get(OPENAI_CODEX_AUTH_CLAIM) orelse return error.MissingAccountId;
    if (auth_value != .object) return error.MissingAccountId;
    const account_id_value = auth_value.object.get("chatgpt_account_id") orelse return error.MissingAccountId;
    if (account_id_value != .string or account_id_value.string.len == 0) return error.MissingAccountId;
    return try allocator.dupe(u8, account_id_value.string);
}

fn getObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getObjectStringAny(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (getObjectString(object, key)) |value| return value;
    }
    return null;
}

fn getObjectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => value.integer,
        else => null,
    };
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        const char = encoded[index];
        if (char == '%' and index + 2 < encoded.len) {
            const hi = try parseHexNibble(encoded[index + 1]);
            const lo = try parseHexNibble(encoded[index + 2]);
            try output.append(allocator, (hi << 4) | lo);
            index += 2;
            continue;
        }
        if (char == '+') {
            try output.append(allocator, ' ');
            continue;
        }
        try output.append(allocator, char);
    }

    return try output.toOwnedSlice(allocator);
}

fn parseHexNibble(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidAuthorizationInput,
    };
}

fn formEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    for (raw) |char| {
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

fn mapHttpError(err: anyerror) anyerror {
    return switch (err) {
        ai.http_client.HttpError.ConnectionRefused => error.ConnectionRefused,
        ai.http_client.HttpError.ConnectionReset => error.ConnectionReset,
        ai.http_client.HttpError.Timeout => error.Timeout,
        ai.http_client.HttpError.RequestAborted => error.RequestAborted,
        ai.http_client.HttpError.InvalidUrl => error.InvalidUrl,
        ai.http_client.HttpError.UnknownHost => error.UnknownHost,
        ai.http_client.HttpError.TlsFailure => error.TlsFailure,
        ai.http_client.HttpError.TooManyRedirects => error.TooManyRedirects,
        ai.http_client.HttpError.NetworkUnreachable => error.NetworkUnreachable,
        ai.http_client.HttpError.ServerError => error.HttpRequestFailed,
        ai.http_client.HttpError.ClientError => error.HttpRequestFailed,
        ai.http_client.HttpError.UnexpectedRedirect => error.HttpRequestFailed,
        else => error.HttpRequestFailed,
    };
}

test "startAnthropicBrowserLogin builds a Claude OAuth URL" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var session = try startAnthropicBrowserLogin(allocator, std.testing.io, &env_map);
    defer session.deinit(allocator);

    try std.testing.expectEqual(BrowserLoginKind.anthropic, session.kind);
    try std.testing.expect(std.mem.startsWith(u8, session.auth_url, ANTHROPIC_AUTHORIZE_URL));
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "code_challenge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback") != null);
}

test "startOpenAICodexBrowserLogin builds TS-equivalent OAuth URL" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var session = try startOpenAICodexBrowserLogin(allocator, std.testing.io, &env_map);
    defer session.deinit(allocator);

    try std.testing.expectEqual(BrowserLoginKind.openai_codex, session.kind);
    try std.testing.expectEqualStrings("openai-codex", session.provider_id);
    try std.testing.expectEqualStrings("ChatGPT Plus/Pro (Codex Subscription)", session.provider_name);
    try std.testing.expectEqualStrings(DEFAULT_OPENAI_CODEX_CLIENT_ID, session.oauth_client.client_id);
    try std.testing.expect(session.oauth_client.client_secret == null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, OPENAI_CODEX_AUTHORIZE_URL) != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "scope=openid%20profile%20email%20offline_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "id_token_add_organizations=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "originator=pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, session.state) != null);
}

test "startXAIBrowserLogin builds TS-equivalent OAuth URL" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var session = try startXAIBrowserLogin(allocator, std.testing.io, &env_map);
    defer session.deinit(allocator);

    try std.testing.expectEqual(BrowserLoginKind.xai_oauth, session.kind);
    try std.testing.expectEqualStrings("xai-oauth", session.provider_id);
    try std.testing.expectEqualStrings("xAI Grok OAuth", session.provider_name);
    try std.testing.expectEqualStrings(DEFAULT_XAI_CLIENT_ID, session.oauth_client.client_id);
    try std.testing.expect(session.oauth_client.client_secret == null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, XAI_AUTHORIZE_URL) != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "response_type=code") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "client_id=b1a00492-073a-47ea-816f-4c329264a828") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A56121%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "scope=openid%20profile%20email%20offline_access%20grok-cli%3Aaccess%20api%3Aaccess") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "nonce=") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "plan=generic") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "referrer=hermes-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, session.state) != null);
}

test "loadOAuthClientCredentials uses public built-in client ids without oauth config" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var anthropic = try loadOAuthClientCredentials(allocator, std.testing.io, &env_map, "anthropic", false);
    defer anthropic.deinit(allocator);
    try std.testing.expectEqualStrings(DEFAULT_ANTHROPIC_CLIENT_ID, anthropic.client_id);
    try std.testing.expect(anthropic.client_secret == null);

    var copilot = try loadOAuthClientCredentials(allocator, std.testing.io, &env_map, "github-copilot", false);
    defer copilot.deinit(allocator);
    try std.testing.expectEqualStrings("Iv1.b507a08c87ecfe98", copilot.client_id);
    try std.testing.expect(copilot.client_secret == null);

    var codex = try loadOAuthClientCredentials(allocator, std.testing.io, &env_map, "openai-codex", false);
    defer codex.deinit(allocator);
    try std.testing.expectEqualStrings(DEFAULT_OPENAI_CODEX_CLIENT_ID, codex.client_id);
    try std.testing.expect(codex.client_secret == null);

    var xai = try loadOAuthClientCredentials(allocator, std.testing.io, &env_map, "xai-oauth", false);
    defer xai.deinit(allocator);
    try std.testing.expectEqualStrings(DEFAULT_XAI_CLIENT_ID, xai.client_id);
    try std.testing.expect(xai.client_secret == null);

    const copilot_body = try buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = copilot.client_id },
        .{ .name = "scope", .value = "read:user" },
    });
    defer allocator.free(copilot_body);
    try std.testing.expectEqualStrings("client_id=Iv1.b507a08c87ecfe98&scope=read%3Auser", copilot_body);
}

test "auth provider client ids agree with ai.provider_info.PROVIDERS" {
    // Cross-check: every AUTH_PROVIDERS row that hard-codes a public OAuth
    // client id must agree with the canonical value on
    // ai.provider_info.PROVIDERS. Conversely, every provider_info row that
    // carries an `oauth_default_client_id` must have a matching AUTH_PROVIDERS
    // row (so a new provider cannot silently get a public client id on only
    // one side of the consolidation).
    for (&AUTH_PROVIDERS) |info| {
        const info_id_default = ai.provider_info.oauthDefaultClientIdFor(info.id);
        if (info.default_public_client_id) |expected| {
            if (info_id_default == null) {
                std.debug.print(
                    "auth provider '{s}' has default_public_client_id but provider_info row has null oauth_default_client_id\n",
                    .{info.id},
                );
                return error.TestExpectedEqual;
            }
            try std.testing.expectEqualStrings(expected, info_id_default.?);
        } else {
            if (info_id_default) |unexpected| {
                std.debug.print(
                    "auth provider '{s}' has no default_public_client_id but provider_info row carries one ('{s}')\n",
                    .{ info.id, unexpected },
                );
                return error.TestExpectedEqual;
            }
        }
    }

    for (ai.provider_info.PROVIDERS) |info| {
        const id_default = info.oauth_default_client_id orelse continue;
        const auth_info = authInfoFor(info.id) orelse {
            std.debug.print(
                "provider_info row '{s}' carries oauth_default_client_id='{s}' but has no AUTH_PROVIDERS row\n",
                .{ info.id, id_default },
            );
            return error.TestExpectedEqual;
        };
        const auth_default = auth_info.default_public_client_id orelse {
            std.debug.print(
                "provider_info row '{s}' carries oauth_default_client_id='{s}' but AUTH_PROVIDERS row has null default_public_client_id\n",
                .{ info.id, id_default },
            );
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(id_default, auth_default);
    }
}

test "OpenAI Codex OAuth token exchange uses fake callback and local token endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var session = try startOpenAICodexBrowserLogin(allocator, io, &env_map);
    defer session.deinit(allocator);

    const body = try buildOpenAICodexTokenExchangeBody(allocator, &session, "code 123");
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=code%20123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code_verifier=") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);

    const access_token = try buildTestOpenAICodexAccessToken(allocator, "acc_test");
    defer allocator.free(access_token);
    const response = try std.fmt.allocPrint(
        allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh-token\",\"expires_in\":3600}}",
        .{access_token},
    );
    defer allocator.free(response);

    var server = try ai.provider_error.TestStatusServer.init(io, 200, "OK", "", response);
    defer server.deinit();
    try server.start();
    const token_url = try server.url(allocator);
    defer allocator.free(token_url);

    const callback = try std.fmt.allocPrint(
        allocator,
        "http://localhost:1455/auth/callback?code=fake-code&state={s}",
        .{session.state},
    );
    defer allocator.free(callback);

    var credential = try exchangeOpenAICodexAuthorizationCodeWithTokenUrl(allocator, io, &session, callback, token_url);
    defer credential.deinit(allocator);
    try std.testing.expectEqualStrings(access_token, credential.access);
    try std.testing.expectEqualStrings("refresh-token", credential.refresh);
    try std.testing.expect(credential.expires > 0);

    try std.testing.expectError(
        error.InvalidOAuthState,
        exchangeOpenAICodexAuthorizationCodeWithTokenUrl(
            allocator,
            io,
            &session,
            "http://localhost:1455/auth/callback?code=fake-code&state=wrong-state",
            token_url,
        ),
    );
}

test "xAI OAuth token exchange uses fake callback and local token endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var session = try startXAIBrowserLogin(allocator, io, &env_map);
    defer session.deinit(allocator);

    const body = try buildXAITokenExchangeBody(allocator, &session, "code 123");
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "client_id=b1a00492-073a-47ea-816f-4c329264a828") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=code%20123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code_verifier=") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "redirect_uri=http%3A%2F%2F127.0.0.1%3A56121%2Fcallback") != null);

    var server = try ai.provider_error.TestStatusServer.init(io, 200, "OK", "", "{\"access_token\":\"xai-access\",\"refresh_token\":\"xai-refresh\",\"expires_in\":3600}");
    defer server.deinit();
    try server.start();
    const token_url = try server.url(allocator);
    defer allocator.free(token_url);

    const callback = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:56121/callback?code=fake-code&state={s}",
        .{session.state},
    );
    defer allocator.free(callback);

    var credential = try exchangeXAIAuthorizationCodeWithTokenUrl(allocator, io, &session, callback, token_url);
    defer credential.deinit(allocator);
    try std.testing.expectEqualStrings("xai-access", credential.access);
    try std.testing.expectEqualStrings("xai-refresh", credential.refresh);
    try std.testing.expect(credential.expires > 0);

    try std.testing.expectError(
        error.InvalidOAuthState,
        exchangeXAIAuthorizationCodeWithTokenUrl(
            allocator,
            io,
            &session,
            "http://127.0.0.1:56121/callback?code=fake-code&state=wrong-state",
            token_url,
        ),
    );
}

test "loadOAuthClientCredentials falls back to public Anthropic client id for invalid configured values" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const oauth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth.json" });
    defer allocator.free(oauth_path);
    try common.writeFileAbsolute(
        std.testing.io,
        oauth_path,
        \\{
        \\  "anthropic": {
        \\    "client_id": "not-a-valid-uuid"
        \\  }
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var credentials = try loadOAuthClientCredentials(allocator, std.testing.io, &env_map, "anthropic", false);
    defer credentials.deinit(allocator);

    try std.testing.expectEqualStrings(DEFAULT_ANTHROPIC_CLIENT_ID, credentials.client_id);
}

test "buildAnthropicTokenExchangeBody owns no intermediate JSON object allocations" {
    const allocator = std.testing.allocator;

    var session = BrowserLoginSession{
        .kind = .anthropic,
        .provider_id = "anthropic",
        .provider_name = "Anthropic",
        .oauth_client = .{
            .client_id = try allocator.dupe(u8, "client-\"id"),
            .client_secret = null,
        },
        .auth_url = try allocator.dupe(u8, "https://example.test/auth"),
        .verifier = try allocator.dupe(u8, "verifier\\value"),
        .state = try allocator.dupe(u8, "state"),
    };
    defer session.deinit(allocator);

    const body = try buildAnthropicTokenExchangeBody(allocator, &session, "code\nvalue");
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(.object, std.meta.activeTag(parsed.value));
    try std.testing.expectEqualStrings("authorization_code", parsed.value.object.get("grant_type").?.string);
    try std.testing.expectEqualStrings("client-\"id", parsed.value.object.get("client_id").?.string);
    try std.testing.expectEqualStrings("code\nvalue", parsed.value.object.get("code").?.string);
    try std.testing.expectEqualStrings("verifier\\value", parsed.value.object.get("state").?.string);
    try std.testing.expectEqualStrings(ANTHROPIC_REDIRECT_URI, parsed.value.object.get("redirect_uri").?.string);
    try std.testing.expectEqualStrings("verifier\\value", parsed.value.object.get("code_verifier").?.string);
}

test "parseAuthorizationInput accepts full callback URLs with fragments and quotes" {
    const allocator = std.testing.allocator;

    var parsed = try parseAuthorizationInput(
        allocator,
        "\"http://localhost:53692/callback?code=4ujivk7vnGi64Hqicga0DG96C9YglzNJFgfYjrLHndQRK8gn&state=9geviroXK7Sa3j6MjojixMzGOWHRCvszOAKSbWCulSg#_=_\"",
    );
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("4ujivk7vnGi64Hqicga0DG96C9YglzNJFgfYjrLHndQRK8gn", parsed.code.?);
    try std.testing.expectEqualStrings("9geviroXK7Sa3j6MjojixMzGOWHRCvszOAKSbWCulSg", parsed.state.?);
}

test "formatOAuthClientConfigError references safe client config guidance" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    const message = (try formatOAuthClientConfigError(
        allocator,
        &env_map,
        "github-copilot",
        error.MissingOAuthClientId,
    )).?;
    defer allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "oauth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "oauth-clients.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "auth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "\"client_id\"") != null);
}

test "valid stored OAuth credentials resolve without refresh for supported families" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const future_expires = currentTimeMs(io) + std.time.ms_per_hour;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var anthropic = try makeOAuthTestObject(allocator, "anthropic-access", "anthropic-refresh", future_expires, null);
    defer deinitOAuthTestObject(allocator, &anthropic);
    const anthropic_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        null,
        "anthropic",
        anthropic,
        .{ .anthropic_token_url = "http://127.0.0.1:1" },
    )).?;
    defer allocator.free(anthropic_key);
    try std.testing.expectEqualStrings("anthropic-access", anthropic_key);

    var copilot = try makeOAuthTestObject(allocator, "copilot-access", "copilot-refresh", future_expires, null);
    defer deinitOAuthTestObject(allocator, &copilot);
    const copilot_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        null,
        "github-copilot",
        copilot,
        .{ .github_copilot_token_url = "http://127.0.0.1:1" },
    )).?;
    defer allocator.free(copilot_key);
    try std.testing.expectEqualStrings("copilot-access", copilot_key);

    var codex = try makeOAuthTestObject(allocator, "codex-access", "codex-refresh", future_expires, null);
    defer deinitOAuthTestObject(allocator, &codex);
    const codex_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        null,
        "openai-codex",
        codex,
        .{ .openai_codex_token_url = "http://127.0.0.1:1" },
    )).?;
    defer allocator.free(codex_key);
    try std.testing.expectEqualStrings("codex-access", codex_key);

    var xai = try makeOAuthTestObject(allocator, "xai-access", "xai-refresh", future_expires, null);
    defer deinitOAuthTestObject(allocator, &xai);
    const xai_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        null,
        "xai-oauth",
        xai,
        .{ .xai_token_url = "http://127.0.0.1:1" },
    )).?;
    defer allocator.free(xai_key);
    try std.testing.expectEqualStrings("xai-access", xai_key);
}

test "expired stored OAuth credentials refresh before use and persist refreshed tokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    var anthropic_server = try ai.provider_error.TestStatusServer.init(io, 200, "OK", "", "{\"access_token\":\"anthropic-new\",\"refresh_token\":\"anthropic-refresh-new\",\"expires_in\":3600}");
    defer anthropic_server.deinit();
    try anthropic_server.start();
    const anthropic_url = try anthropic_server.url(allocator);
    defer allocator.free(anthropic_url);
    var anthropic = try makeOAuthTestObject(allocator, "anthropic-old", "anthropic-refresh-old", 0, null);
    defer deinitOAuthTestObject(allocator, &anthropic);
    const anthropic_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        auth_path,
        "anthropic",
        anthropic,
        .{ .anthropic_token_url = anthropic_url },
    )).?;
    defer allocator.free(anthropic_key);
    try std.testing.expectEqualStrings("anthropic-new", anthropic_key);

    var copilot_server = try ai.provider_error.TestStatusServer.init(io, 200, "OK", "", "{\"token\":\"copilot-new\",\"expires_at\":4102444800}");
    defer copilot_server.deinit();
    try copilot_server.start();
    const copilot_url = try copilot_server.url(allocator);
    defer allocator.free(copilot_url);
    var copilot = try makeOAuthTestObject(allocator, "copilot-old", "copilot-refresh-old", 0, null);
    defer deinitOAuthTestObject(allocator, &copilot);
    const copilot_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        auth_path,
        "github-copilot",
        copilot,
        .{ .github_copilot_token_url = copilot_url },
    )).?;
    defer allocator.free(copilot_key);
    try std.testing.expectEqualStrings("copilot-new", copilot_key);

    const codex_access = try buildTestOpenAICodexAccessToken(allocator, "acc_refresh");
    defer allocator.free(codex_access);
    const codex_response = try std.fmt.allocPrint(
        allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"codex-refresh-new\",\"expires_in\":3600}}",
        .{codex_access},
    );
    defer allocator.free(codex_response);
    var codex_server = try ai.provider_error.TestStatusServer.init(io, 200, "OK", "", codex_response);
    defer codex_server.deinit();
    try codex_server.start();
    const codex_url = try codex_server.url(allocator);
    defer allocator.free(codex_url);
    var codex = try makeOAuthTestObject(allocator, "codex-old", "codex-refresh-old", 0, null);
    defer deinitOAuthTestObject(allocator, &codex);
    const codex_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        auth_path,
        "openai-codex",
        codex,
        .{ .openai_codex_token_url = codex_url },
    )).?;
    defer allocator.free(codex_key);
    try std.testing.expectEqualStrings(codex_access, codex_key);

    var xai_server = try ai.provider_error.TestStatusServer.init(io, 200, "OK", "", "{\"access_token\":\"xai-new\",\"refresh_token\":\"xai-refresh-new\",\"expires_in\":3600}");
    defer xai_server.deinit();
    try xai_server.start();
    const xai_url = try xai_server.url(allocator);
    defer allocator.free(xai_url);
    var xai = try makeOAuthTestObject(allocator, "xai-old", "xai-refresh-old", 0, null);
    defer deinitOAuthTestObject(allocator, &xai);
    const xai_key = (try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        io,
        &env_map,
        auth_path,
        "xai-oauth",
        xai,
        .{ .xai_token_url = xai_url },
    )).?;
    defer allocator.free(xai_key);
    try std.testing.expectEqualStrings("xai-new", xai_key);

    const persisted = try std.Io.Dir.readFileAlloc(.cwd(), io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "anthropic-new") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "copilot-new") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, codex_access) != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "xai-new") != null);
}

test "isApiKeyLoginProvider keeps built-in API key providers separate from OAuth-only providers" {
    const oauth_provider_ids = [_][]const u8{ "anthropic", "github-copilot", "xai-oauth", "custom-oauth" };
    const built_in_provider_ids = [_][]const u8{ "anthropic", "github-copilot", "xai-oauth", "amazon-bedrock", "openai" };

    try std.testing.expect(isApiKeyLoginProvider("anthropic", oauth_provider_ids[0..], built_in_provider_ids[0..]));
    try std.testing.expectEqualStrings("Anthropic", getApiKeyProviderDisplayName("anthropic"));
    try std.testing.expect(isApiKeyLoginProvider("openai", oauth_provider_ids[0..], built_in_provider_ids[0..]));
    try std.testing.expect(!isApiKeyLoginProvider("github-copilot", oauth_provider_ids[0..], built_in_provider_ids[0..]));
    try std.testing.expect(!isApiKeyLoginProvider("xai-oauth", oauth_provider_ids[0..], built_in_provider_ids[0..]));
    try std.testing.expect(isApiKeyLoginProvider("amazon-bedrock", oauth_provider_ids[0..], built_in_provider_ids[0..]));
    try std.testing.expect(!isApiKeyLoginProvider("custom-oauth", oauth_provider_ids[0..], built_in_provider_ids[0..]));
    try std.testing.expect(isApiKeyLoginProvider("custom-api", oauth_provider_ids[0..], built_in_provider_ids[0..]));
}

test "API key login metadata includes provider catalog parity providers" {
    const cases = [_]struct {
        provider: []const u8,
        display_name: []const u8,
    }{
        .{ .provider = "deepseek", .display_name = "DeepSeek" },
        .{ .provider = "moonshotai", .display_name = "Moonshot AI" },
        .{ .provider = "moonshotai-cn", .display_name = "Moonshot AI (China)" },
        .{ .provider = "cloudflare-workers-ai", .display_name = "Cloudflare Workers AI" },
        .{ .provider = "cloudflare-ai-gateway", .display_name = "Cloudflare AI Gateway" },
        .{ .provider = "together", .display_name = "Together AI" },
        .{ .provider = "zai", .display_name = "ZAI" },
        .{ .provider = "xiaomi", .display_name = "Xiaomi MiMo" },
        .{ .provider = "xiaomi-token-plan-cn", .display_name = "Xiaomi MiMo Token Plan (China)" },
        .{ .provider = "xiaomi-token-plan-ams", .display_name = "Xiaomi MiMo Token Plan (Amsterdam)" },
        .{ .provider = "xiaomi-token-plan-sgp", .display_name = "Xiaomi MiMo Token Plan (Singapore)" },
    };

    const oauth_provider_ids = [_][]const u8{ "anthropic", "github-copilot" };
    for (cases) |case| {
        try std.testing.expect(isApiKeyLoginProvider(case.provider, oauth_provider_ids[0..], null));
        try std.testing.expectEqualStrings(case.display_name, getApiKeyProviderDisplayName(case.provider));
        const provider = findSupportedProviderByAuthType(case.provider, .api_key).?;
        try std.testing.expectEqualStrings(case.display_name, provider.name);
    }
}

test "resolveApiKey prefers runtime overrides over stored and environment credentials" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "env-openai-key");

    const resolved = (try resolveApiKey(
        allocator,
        std.testing.io,
        &env_map,
        "openai",
        "runtime-openai-key",
        "stored-openai-key",
    )).?;
    defer if (resolved.owned_api_key) |value| allocator.free(value);

    try std.testing.expectEqual(CredentialSource.runtime, resolved.source);
    try std.testing.expectEqualStrings("runtime-openai-key", resolved.api_key);
    try std.testing.expect(resolved.owned_api_key == null);
}

test "resolveApiKey falls back to stored then environment credentials" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "env-openai-key");

    const stored = (try resolveApiKey(allocator, std.testing.io, &env_map, "openai", null, "stored-openai-key")).?;
    defer if (stored.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.stored, stored.source);
    try std.testing.expectEqualStrings("stored-openai-key", stored.api_key);

    const env_only = (try resolveApiKey(allocator, std.testing.io, &env_map, "openai", "   ", null)).?;
    defer if (env_only.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.environment, env_only.source);
    try std.testing.expectEqualStrings("env-openai-key", env_only.api_key);
    try std.testing.expect(env_only.owned_api_key != null);
}

test "resolveApiKey executes shell command credentials" {
    const allocator = std.testing.allocator;
    defer clearCommandResultCache();

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const resolved = (try resolveApiKey(
        allocator,
        std.testing.io,
        &env_map,
        "openai",
        null,
        "!printf %s shell-openai-key",
    )).?;
    defer if (resolved.owned_api_key) |value| allocator.free(value);

    try std.testing.expectEqual(CredentialSource.stored, resolved.source);
    try std.testing.expectEqualStrings("shell-openai-key", resolved.api_key);
    try std.testing.expect(resolved.owned_api_key != null);
}

test "resolveApiKey matches TypeScript environment fallback order for auth families" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("COPILOT_GITHUB_TOKEN", "copilot-token");
    try env_map.put("GH_TOKEN", "gh-token");
    try env_map.put("GITHUB_TOKEN", "github-token");
    try env_map.put("ANTHROPIC_OAUTH_TOKEN", "anthropic-oauth-token");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-api-key");
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("GEMINI_API_KEY", "google-key");

    const copilot = (try resolveApiKey(allocator, std.testing.io, &env_map, "github-copilot", null, null)).?;
    defer if (copilot.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.environment, copilot.source);
    try std.testing.expectEqualStrings("copilot-token", copilot.api_key);

    const anthropic = (try resolveApiKey(allocator, std.testing.io, &env_map, "anthropic", null, null)).?;
    defer if (anthropic.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.environment, anthropic.source);
    try std.testing.expectEqualStrings("anthropic-oauth-token", anthropic.api_key);

    const codex = (try resolveApiKey(allocator, std.testing.io, &env_map, "openai-codex", null, null)).?;
    defer if (codex.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.environment, codex.source);
    try std.testing.expectEqualStrings("openai-key", codex.api_key);

    const google = (try resolveApiKey(allocator, std.testing.io, &env_map, "google", null, null)).?;
    defer if (google.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.environment, google.source);
    try std.testing.expectEqualStrings("google-key", google.api_key);

    var expired = try makeOAuthTestObject(allocator, "expired-access", "expired-refresh", 0, null);
    defer deinitOAuthTestObject(allocator, &expired);
    const failed_stored = try buildApiKeyFromStoredEntryWithRefreshEndpoints(
        allocator,
        std.testing.io,
        &env_map,
        null,
        "anthropic",
        expired,
        .{ .anthropic_token_url = "http://127.0.0.1:1" },
    );
    try std.testing.expect(failed_stored == null);

    const fallback = (try resolveApiKey(allocator, std.testing.io, &env_map, "anthropic", null, null)).?;
    defer if (fallback.owned_api_key) |value| allocator.free(value);
    try std.testing.expectEqual(CredentialSource.environment, fallback.source);
    try std.testing.expectEqualStrings("anthropic-oauth-token", fallback.api_key);
}

test "upsertStoredCredential and listStoredProviders persist oauth state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const auth_path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "agent",
        "auth.json",
    });
    defer allocator.free(auth_path);

    var credential = StoredCredential{
        .oauth = .{
            .access = try allocator.dupe(u8, "access-token"),
            .refresh = try allocator.dupe(u8, "refresh-token"),
            .expires = 1234,
            .project_id = try allocator.dupe(u8, "project-1"),
        },
    };
    defer credential.deinit(allocator);

    try upsertStoredCredential(allocator, std.testing.io, auth_path, "anthropic", &credential);
    const providers = try listStoredProviders(allocator, std.testing.io, auth_path);
    defer allocator.free(providers);

    try std.testing.expectEqual(@as(usize, 1), providers.len);
    try std.testing.expectEqualStrings("anthropic", providers[0].id);
    const stat = try std.Io.Dir.statFile(.cwd(), std.testing.io, auth_path, .{});
    if (@hasDecl(@TypeOf(stat.permissions), "toMode")) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "listStoredProviders includes built-in API key credentials" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const auth_path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "agent",
        "auth.json",
    });
    defer allocator.free(auth_path);

    var credential = StoredCredential{
        .api_key = try allocator.dupe(u8, "openai-key"),
    };
    defer credential.deinit(allocator);

    try upsertStoredCredential(allocator, std.testing.io, auth_path, "openai", &credential);
    const providers = try listStoredProviders(allocator, std.testing.io, auth_path);
    defer allocator.free(providers);

    try std.testing.expectEqual(@as(usize, 1), providers.len);
    try std.testing.expectEqualStrings("openai", providers[0].id);
    try std.testing.expectEqualStrings("OpenAI", providers[0].name);
    try std.testing.expectEqual(ProviderAuthType.api_key, providers[0].auth_type);
}

test "stored OpenAI Codex OAuth credentials are distinct from OpenAI API key credentials" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const auth_path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "agent",
        "auth.json",
    });
    defer allocator.free(auth_path);

    var openai_key = StoredCredential{
        .api_key = try allocator.dupe(u8, "openai-api-key"),
    };
    defer openai_key.deinit(allocator);
    try upsertStoredCredential(allocator, std.testing.io, auth_path, "openai", &openai_key);

    var codex_oauth = StoredCredential{
        .oauth = .{
            .access = try allocator.dupe(u8, "codex-access-token"),
            .refresh = try allocator.dupe(u8, "codex-refresh-token"),
            .expires = 1234,
        },
    };
    defer codex_oauth.deinit(allocator);
    try upsertStoredCredential(allocator, std.testing.io, auth_path, "openai-codex", &codex_oauth);

    const providers = try listStoredProviders(allocator, std.testing.io, auth_path);
    defer allocator.free(providers);

    var saw_openai_api_key = false;
    var saw_codex_oauth = false;
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, "openai")) {
            saw_openai_api_key = true;
            try std.testing.expectEqual(ProviderAuthType.api_key, provider.auth_type);
            try std.testing.expectEqualStrings("OpenAI", provider.name);
        }
        if (std.mem.eql(u8, provider.id, "openai-codex")) {
            saw_codex_oauth = true;
            try std.testing.expectEqual(ProviderAuthType.oauth, provider.auth_type);
            try std.testing.expectEqualStrings("ChatGPT Plus/Pro (Codex Subscription)", provider.name);
        }
    }
    try std.testing.expect(saw_openai_api_key);
    try std.testing.expect(saw_codex_oauth);

    const saved = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"openai-api-key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"openai-codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"codex-access-token\"") != null);
}

test "auth storage lock serializes concurrent writes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const auth_path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "agent",
        "auth.json",
    });
    defer allocator.free(auth_path);
    const started_path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "started.txt",
    });
    defer allocator.free(started_path);

    var lock = try AuthFileLock.acquire(allocator, std.testing.io, auth_path);
    var lock_held = true;
    defer if (lock_held) lock.release(std.testing.io);

    const thread = try std.Thread.spawn(.{}, persistCredentialInThread, .{PersistCredentialThreadArgs{
        .auth_path = auth_path,
        .started_path = started_path,
    }});
    var thread_joined = false;
    defer if (!thread_joined) thread.join();

    var saw_start = false;
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, started_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                _ = std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
                continue;
            },
            else => return err,
        };
        saw_start = true;
        break;
    }
    try std.testing.expect(saw_start);

    const blocked_content = std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (blocked_content) |value| allocator.free(value);
    try std.testing.expect(blocked_content == null);

    lock.release(std.testing.io);
    lock_held = false;
    thread.join();
    thread_joined = true;

    const persisted = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"thread-key\"") != null);
}

const PersistCredentialThreadArgs = struct {
    auth_path: []const u8,
    started_path: []const u8,
};

fn persistCredentialInThread(args: PersistCredentialThreadArgs) !void {
    const allocator = std.heap.page_allocator;

    try common.writeFileAbsolute(std.testing.io, args.started_path, "started", true);

    var credential = StoredCredential{
        .api_key = try allocator.dupe(u8, "thread-key"),
    };
    defer credential.deinit(allocator);

    try upsertStoredCredential(allocator, std.testing.io, args.auth_path, "anthropic", &credential);
}

fn buildTestOpenAICodexAccessToken(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const header = "{\"alg\":\"none\",\"typ\":\"JWT\"}";
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"{s}\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{ OPENAI_CODEX_AUTH_CLAIM, account_id },
    );
    defer allocator.free(payload);

    const encoded_header = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(header.len));
    defer allocator.free(encoded_header);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded_header, header);

    const encoded_payload = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer allocator.free(encoded_payload);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded_payload, payload);

    return std.fmt.allocPrint(allocator, "{s}.{s}.signature", .{ encoded_header, encoded_payload });
}

fn makeOAuthTestObject(
    allocator: std.mem.Allocator,
    access: []const u8,
    refresh: []const u8,
    expires: i64,
    project_id: ?[]const u8,
) !std.json.ObjectMap {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    try common.putString(allocator, &object, "type", "oauth");
    try common.putString(allocator, &object, "access", access);
    try common.putString(allocator, &object, "refresh", refresh);
    try common.putInt(allocator, &object, "expires", expires);
    if (project_id) |value| {
        try common.putString(allocator, &object, "projectId", value);
    }
    return object;
}

fn deinitOAuthTestObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap) void {
    const cleanup_value: std.json.Value = .{ .object = object.* };
    common.deinitJsonValue(allocator, cleanup_value);
    object.* = undefined;
}

fn makeAuthTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    if (name.len == 0) {
        return std.fs.path.resolve(allocator, &[_][]const u8{
            cwd,
            ".zig-cache",
            "tmp",
            &tmp.sub_path,
        });
    }

    return std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
}
