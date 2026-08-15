const std = @import("std");
const pkce = @import("../../oauth/pkce.zig");
const common = @import("common.zig");
const types = @import("types.zig");

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const REDIRECT_URI = "http://localhost:53692/callback";
const SCOPES = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

pub const anthropicOAuthProvider = types.OAuthProviderInterface{
    .id = "anthropic",
    .name = "Anthropic (Claude Pro/Max)",
    .login = loginAnthropic,
    .uses_callback_server = true,
    .refreshToken = refreshAnthropicToken,
    .getApiKey = getApiKey,
};

pub fn loginAnthropic(allocator: std.mem.Allocator, callbacks: types.OAuthLoginCallbacks) !types.OAuthCredentials {
    const io = common.defaultIo();
    const pair = try pkce.generatePKCE(allocator);
    defer pair.deinit(allocator);

    const auth_url = try buildAuthorizeUrl(allocator, pair.challenge, pair.verifier);
    defer allocator.free(auth_url);
    callbacks.onAuth(.{
        .url = auth_url,
        .instructions = "Complete login in your browser. If the browser is on another machine, paste the final redirect URL here.",
    });

    const input = if (callbacks.onManualCodeInput) |manual|
        manual()
    else
        callbacks.onPrompt(.{
            .message = "Paste the authorization code or full redirect URL:",
            .placeholder = REDIRECT_URI,
        });
    var parsed = try common.parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);

    const code = parsed.code orelse return error.MissingAuthorizationCode;
    const state = parsed.state orelse pair.verifier;
    if (!std.mem.eql(u8, state, pair.verifier)) return error.InvalidOAuthState;

    if (callbacks.onProgress) |progress| progress("Exchanging authorization code for tokens...");
    return try exchangeAuthorizationCode(allocator, io, code, state, pair.verifier, REDIRECT_URI);
}

pub fn refreshAnthropicToken(allocator: std.mem.Allocator, credentials: types.OAuthCredentials) !types.OAuthCredentials {
    _ = credentials.access;
    return try refreshAnthropicTokenWithUrl(allocator, common.defaultIo(), credentials.refresh, TOKEN_URL);
}

fn getApiKey(credentials: types.OAuthCredentials) []const u8 {
    return credentials.access;
}

pub fn refreshAnthropicTokenWithUrl(allocator: std.mem.Allocator, io: std.Io, refresh_token: []const u8, token_url: []const u8) !types.OAuthCredentials {
    const body = try common.tokenJsonBody(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "refresh_token", .value = refresh_token },
    });
    defer allocator.free(body);

    const response_body = try common.postJson(allocator, io, token_url, body, null);
    defer allocator.free(response_body);
    return try common.parseTokenResponse(allocator, io, response_body, true);
}

fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
) !types.OAuthCredentials {
    const body = try common.tokenJsonBody(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "code", .value = code },
        .{ .name = "state", .value = state },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "code_verifier", .value = verifier },
    });
    defer allocator.free(body);

    const response_body = try common.postJson(allocator, io, TOKEN_URL, body, null);
    defer allocator.free(response_body);
    return try common.parseTokenResponse(allocator, io, response_body, true);
}

fn buildAuthorizeUrl(allocator: std.mem.Allocator, challenge: []const u8, state: []const u8) ![]u8 {
    const query = try common.buildFormBody(allocator, &.{
        .{ .name = "code", .value = "true" },
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "response_type", .value = "code" },
        .{ .name = "redirect_uri", .value = REDIRECT_URI },
        .{ .name = "scope", .value = SCOPES },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = state },
    });
    defer allocator.free(query);
    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ AUTHORIZE_URL, query });
}

test "anthropic oauth provider returns access token as api key" {
    const credentials = types.OAuthCredentials{ .refresh = "r", .access = "a", .expires = 1 };
    try std.testing.expectEqualStrings("a", anthropicOAuthProvider.getApiKey(credentials));
}

test "anthropic oauth builds authorize URL" {
    const url = try buildAuthorizeUrl(std.testing.allocator, "challenge", "state");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "https://claude.ai/oauth/authorize?") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=challenge") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state") != null);
}
