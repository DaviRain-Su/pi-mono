const std = @import("std");
const pkce = @import("../../oauth/pkce.zig");
const common = @import("common.zig");
const types = @import("types.zig");

const CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828";
const AUTHORIZE_URL = "https://auth.x.ai/oauth2/authorize";
const TOKEN_URL = "https://auth.x.ai/oauth2/token";
const REDIRECT_URI = "http://127.0.0.1:56121/callback";
const SCOPE = "openid profile email offline_access grok-cli:access api:access";

pub const xaiOAuthProvider = types.OAuthProviderInterface{
    .id = "xai-oauth",
    .name = "xAI Grok OAuth",
    .login = loginXAI,
    .uses_callback_server = true,
    .refreshToken = refreshXAIToken,
    .getApiKey = getApiKey,
};

pub fn loginXAI(allocator: std.mem.Allocator, callbacks: types.OAuthLoginCallbacks) !types.OAuthCredentials {
    const io = common.defaultIo();
    const pair = try pkce.generatePKCE(allocator);
    defer pair.deinit(allocator);
    const state = try createState(allocator, io);
    defer allocator.free(state);
    const nonce = try createState(allocator, io);
    defer allocator.free(nonce);

    const auth_url = try buildAuthorizeUrl(allocator, pair.challenge, state, nonce);
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

pub fn refreshXAIToken(allocator: std.mem.Allocator, credentials: types.OAuthCredentials) !types.OAuthCredentials {
    _ = credentials.access;
    return try refreshXAITokenWithUrl(allocator, common.defaultIo(), credentials.refresh, TOKEN_URL);
}

fn getApiKey(credentials: types.OAuthCredentials) []const u8 {
    return credentials.access;
}

test "xai oauth provider returns access token as api key" {
    const credentials = types.OAuthCredentials{ .refresh = "r", .access = "a", .expires = 1 };
    try std.testing.expectEqualStrings("a", xaiOAuthProvider.getApiKey(credentials));
}

pub fn refreshXAITokenWithUrl(allocator: std.mem.Allocator, io: std.Io, refresh_token: []const u8, token_url: []const u8) !types.OAuthCredentials {
    const body = try common.buildFormBody(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = CLIENT_ID },
    });
    defer allocator.free(body);

    const response_body = try common.postForm(allocator, io, token_url, body, null);
    defer allocator.free(response_body);
    return try common.parseTokenResponse(allocator, io, response_body, false);
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
    return try common.parseTokenResponse(allocator, io, response_body, false);
}

fn createState(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const encoded = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, encoded[0..]);
}

fn buildAuthorizeUrl(allocator: std.mem.Allocator, challenge: []const u8, state: []const u8, nonce: []const u8) ![]u8 {
    const query = try common.buildFormBody(allocator, &.{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "redirect_uri", .value = REDIRECT_URI },
        .{ .name = "scope", .value = SCOPE },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = state },
        .{ .name = "nonce", .value = nonce },
        .{ .name = "plan", .value = "generic" },
        .{ .name = "referrer", .value = "hermes-agent" },
    });
    defer allocator.free(query);
    return std.fmt.allocPrint(allocator, "{s}?{s}", .{ AUTHORIZE_URL, query });
}

test "xai oauth builds authorize URL" {
    const url = try buildAuthorizeUrl(std.testing.allocator, "challenge", "state", "nonce");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "https://auth.x.ai/oauth2/authorize?") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=b1a00492-073a-47ea-816f-4c329264a828") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A56121%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=openid%20profile%20email%20offline_access%20grok-cli%3Aaccess%20api%3Aaccess") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "nonce=nonce") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "plan=generic") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "referrer=hermes-agent") != null);
}
