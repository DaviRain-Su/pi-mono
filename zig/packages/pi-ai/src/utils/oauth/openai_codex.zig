const std = @import("std");
const pkce = @import("../../oauth/pkce.zig");
const common = @import("common.zig");
const types = @import("types.zig");

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";
const REDIRECT_URI = "http://localhost:1455/auth/callback";
const SCOPE = "openid profile email offline_access";

pub const openaiCodexOAuthProvider = types.OAuthProviderInterface{
    .id = "openai-codex",
    .name = "ChatGPT Plus/Pro (Codex Subscription)",
    .login = loginOpenAICodex,
    .uses_callback_server = true,
    .refreshToken = refreshOpenAICodexToken,
    .getApiKey = getApiKey,
};

pub fn loginOpenAICodex(allocator: std.mem.Allocator, callbacks: types.OAuthLoginCallbacks) !types.OAuthCredentials {
    const io = common.defaultIo();
    const pair = try pkce.generatePKCE(allocator);
    defer pair.deinit(allocator);
    const state = try createState(allocator, io);
    defer allocator.free(state);

    const auth_url = try buildAuthorizeUrl(allocator, pair.challenge, state, "pi");
    defer allocator.free(auth_url);
    callbacks.onAuth(.{
        .url = auth_url,
        .instructions = "A browser window should open. Complete login to finish.",
    });

    const input = if (callbacks.onManualCodeInput) |manual|
        manual()
    else
        callbacks.onPrompt(.{
            .message = "Paste the authorization code (or full redirect URL):",
        });
    var parsed = try common.parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);
    if (parsed.state) |parsed_state| {
        if (!std.mem.eql(u8, parsed_state, state)) return error.InvalidOAuthState;
    }
    const code = parsed.code orelse return error.MissingAuthorizationCode;

    if (callbacks.onProgress) |progress| progress("Exchanging authorization code for tokens...");
    return try exchangeAuthorizationCode(allocator, io, code, pair.verifier, REDIRECT_URI);
}

pub fn refreshOpenAICodexToken(allocator: std.mem.Allocator, credentials: types.OAuthCredentials) !types.OAuthCredentials {
    _ = credentials.access;
    return try refreshOpenAICodexTokenWithUrl(allocator, common.defaultIo(), credentials.refresh, TOKEN_URL);
}

fn getApiKey(credentials: types.OAuthCredentials) []const u8 {
    return credentials.access;
}

test "openai codex oauth provider returns access token as api key" {
    const credentials = types.OAuthCredentials{ .refresh = "r", .access = "a", .expires = 1 };
    try std.testing.expectEqualStrings("a", openaiCodexOAuthProvider.getApiKey(credentials));
}

pub fn refreshOpenAICodexTokenWithUrl(allocator: std.mem.Allocator, io: std.Io, refresh_token: []const u8, token_url: []const u8) !types.OAuthCredentials {
    const body = try common.buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = CLIENT_ID },
    });
    defer allocator.free(body);

    const response_body = try common.postForm(allocator, io, token_url, body, null);
    defer allocator.free(response_body);
    var credential = try common.parseTokenResponse(allocator, io, response_body, false);
    errdefer credential.deinit(allocator);
    credential.account_id = try common.extractOpenAICodexAccountId(allocator, credential.access);
    return credential;
}

fn exchangeAuthorizationCode(allocator: std.mem.Allocator, io: std.Io, code: []const u8, verifier: []const u8, redirect_uri: []const u8) !types.OAuthCredentials {
    const body = try common.buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "code", .value = code },
        .{ .name = "code_verifier", .value = verifier },
        .{ .name = "redirect_uri", .value = redirect_uri },
    });
    defer allocator.free(body);

    const response_body = try common.postForm(allocator, io, TOKEN_URL, body, null);
    defer allocator.free(response_body);
    var credential = try common.parseTokenResponse(allocator, io, response_body, false);
    errdefer credential.deinit(allocator);
    credential.account_id = try common.extractOpenAICodexAccountId(allocator, credential.access);
    return credential;
}

fn createState(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const encoded = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, encoded[0..]);
}

fn buildAuthorizeUrl(allocator: std.mem.Allocator, challenge: []const u8, state: []const u8, originator: []const u8) ![]u8 {
    const query = try common.buildFormBody(allocator, &.{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "redirect_uri", .value = REDIRECT_URI },
        .{ .name = "scope", .value = SCOPE },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = state },
        .{ .name = "id_token_add_organizations", .value = "true" },
        .{ .name = "codex_cli_simplified_flow", .value = "true" },
        .{ .name = "originator", .value = originator },
    });
    defer allocator.free(query);
    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ AUTHORIZE_URL, query });
}

test "openai codex oauth builds authorize URL" {
    const url = try buildAuthorizeUrl(std.testing.allocator, "challenge", "state", "pi");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "https://auth.openai.com/oauth/authorize?") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "originator=pi") != null);
}
