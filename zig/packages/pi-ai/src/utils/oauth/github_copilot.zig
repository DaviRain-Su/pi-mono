const std = @import("std");
const common = @import("common.zig");
const types = @import("types.zig");

const CLIENT_ID = "Iv1.b507a08c87ecfe98";
const COPILOT_USER_AGENT = "GitHubCopilotChat/0.35.0";
const COPILOT_EDITOR_VERSION = "vscode/1.107.0";
const COPILOT_PLUGIN_VERSION = "copilot-chat/0.35.0";
const COPILOT_INTEGRATION_ID = "vscode-chat";
const INITIAL_POLL_INTERVAL_MULTIPLIER = 1.2;
const SLOW_DOWN_POLL_INTERVAL_MULTIPLIER = 1.4;

pub const githubCopilotOAuthProvider = types.OAuthProviderInterface{
    .id = "github-copilot",
    .name = "GitHub Copilot",
    .login = loginGitHubCopilot,
    .refreshToken = refreshGitHubCopilotToken,
    .getApiKey = getApiKey,
};

pub fn normalizeDomain(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const without_scheme = if (std.mem.indexOf(u8, trimmed, "://")) |scheme_end|
        trimmed[scheme_end + 3 ..]
    else
        trimmed;
    const end = std.mem.indexOfAny(u8, without_scheme, "/?#") orelse without_scheme.len;
    return if (end == 0) null else without_scheme[0..end];
}

pub fn getGitHubCopilotBaseUrl(allocator: std.mem.Allocator, token: ?[]const u8, enterprise_domain: ?[]const u8) ![]u8 {
    if (token) |value| {
        if (std.mem.indexOf(u8, value, "proxy-ep=")) |start| {
            const host_start = start + "proxy-ep=".len;
            const host_end = std.mem.indexOfScalarPos(u8, value, host_start, ';') orelse value.len;
            const proxy_host = value[host_start..host_end];
            const api_host = if (std.mem.startsWith(u8, proxy_host, "proxy."))
                proxy_host["proxy.".len..]
            else
                proxy_host;
            return std.fmt.allocPrint(allocator, "https://api.{s}", .{api_host});
        }
    }
    if (enterprise_domain) |domain| return std.fmt.allocPrint(allocator, "https://copilot-api.{s}", .{domain});
    return allocator.dupe(u8, "https://api.individual.githubcopilot.com");
}

pub fn loginGitHubCopilot(allocator: std.mem.Allocator, callbacks: types.OAuthLoginCallbacks) !types.OAuthCredentials {
    const io = common.defaultIo();
    const input = callbacks.onPrompt(.{
        .message = "GitHub Enterprise URL/domain (blank for github.com)",
        .placeholder = "company.ghe.com",
        .allow_empty = true,
    });
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const enterprise_domain = if (trimmed.len > 0) normalizeDomain(input) orelse return error.InvalidDomain else null;
    const domain = enterprise_domain orelse "github.com";

    var device = try startDeviceFlow(allocator, io, domain);
    defer device.deinit(allocator);
    const instructions = try std.fmt.allocPrint(allocator, "Enter code: {s}", .{device.user_code});
    defer allocator.free(instructions);
    callbacks.onAuth(.{ .url = device.verification_uri, .instructions = instructions });

    const github_access_token = try pollForGitHubAccessToken(allocator, io, domain, device);
    defer allocator.free(github_access_token);
    if (callbacks.onProgress) |progress| progress("Refreshing GitHub Copilot token...");
    return try refreshGitHubCopilotTokenForDomain(allocator, io, github_access_token, enterprise_domain);
}

pub fn refreshGitHubCopilotToken(allocator: std.mem.Allocator, credentials: types.OAuthCredentials) !types.OAuthCredentials {
    return try refreshGitHubCopilotTokenForDomain(allocator, common.defaultIo(), credentials.refresh, credentials.enterprise_url);
}

fn getApiKey(credentials: types.OAuthCredentials) []const u8 {
    return credentials.access;
}

test "github copilot oauth helpers normalize domains" {
    try std.testing.expectEqualStrings("github.example.com", normalizeDomain("https://github.example.com/path").?);
    try std.testing.expectEqualStrings("github.com", normalizeDomain("github.com").?);
    const base_url = try getGitHubCopilotBaseUrl(std.testing.allocator, "tid=x;proxy-ep=proxy.individual.githubcopilot.com;", null);
    defer std.testing.allocator.free(base_url);
    try std.testing.expectEqualStrings("https://api.individual.githubcopilot.com", base_url);
}

const DeviceFlow = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    interval_seconds: i64,
    expires_at_ms: i64,

    fn deinit(self: *DeviceFlow, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
    }
};

fn startDeviceFlow(allocator: std.mem.Allocator, io: std.Io, domain: []const u8) !DeviceFlow {
    const urls = try getUrls(allocator, domain);
    defer urls.deinit(allocator);
    const body = try common.buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = CLIENT_ID },
        .{ .name = "scope", .value = "read:user" },
    });
    defer allocator.free(body);
    var headers = try common.initCopilotHeaders(allocator);
    defer common.deinitHeaders(allocator, &headers);

    const response_body = try common.postForm(allocator, io, urls.device_code_url, body, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;
    const device_code = common.objectString(parsed.value.object, "device_code") orelse return error.InvalidAuthResponse;
    const user_code = common.objectString(parsed.value.object, "user_code") orelse return error.InvalidAuthResponse;
    const verification_uri = common.objectString(parsed.value.object, "verification_uri") orelse return error.InvalidAuthResponse;
    const interval = common.objectInt(parsed.value.object, "interval") orelse return error.InvalidAuthResponse;
    const expires_in = common.objectInt(parsed.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .device_code = try allocator.dupe(u8, device_code),
        .user_code = try allocator.dupe(u8, user_code),
        .verification_uri = try allocator.dupe(u8, verification_uri),
        .interval_seconds = interval,
        .expires_at_ms = common.currentTimeMs(io) + expires_in * std.time.ms_per_s,
    };
}

fn pollForGitHubAccessToken(allocator: std.mem.Allocator, io: std.Io, domain: []const u8, device: DeviceFlow) ![]u8 {
    const urls = try getUrls(allocator, domain);
    defer urls.deinit(allocator);

    var interval_ms: i64 = @max(1000, device.interval_seconds * std.time.ms_per_s);
    var interval_multiplier: f64 = INITIAL_POLL_INTERVAL_MULTIPLIER;
    var slow_down_responses: usize = 0;

    while (common.currentTimeMs(io) < device.expires_at_ms) {
        const remaining_ms = device.expires_at_ms - common.currentTimeMs(io);
        const multiplied: i64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(interval_ms)) * interval_multiplier));
        const wait_ms = @min(multiplied, remaining_ms);
        std.Io.sleep(io, .fromMilliseconds(wait_ms), .awake) catch {};

        const body = try common.buildFormBody(allocator, &.{
            .{ .name = "client_id", .value = CLIENT_ID },
            .{ .name = "device_code", .value = device.device_code },
            .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
        });
        defer allocator.free(body);
        var headers = try common.initCopilotHeaders(allocator);
        defer common.deinitHeaders(allocator, &headers);

        const response_body = try common.postForm(allocator, io, urls.access_token_url, body, &headers);
        defer allocator.free(response_body);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAuthResponse;

        if (common.objectString(parsed.value.object, "access_token")) |token| {
            return try allocator.dupe(u8, token);
        }

        const error_name = common.objectString(parsed.value.object, "error") orelse return error.InvalidAuthResponse;
        if (std.mem.eql(u8, error_name, "authorization_pending")) continue;
        if (std.mem.eql(u8, error_name, "slow_down")) {
            slow_down_responses += 1;
            if (common.objectInt(parsed.value.object, "interval")) |new_interval| {
                if (new_interval > 0) interval_ms = new_interval * std.time.ms_per_s;
            } else {
                interval_ms = @max(1000, interval_ms + 5000);
            }
            interval_multiplier = SLOW_DOWN_POLL_INTERVAL_MULTIPLIER;
            continue;
        }
        if (std.mem.eql(u8, error_name, "expired_token")) return error.DeviceFlowTimeout;
        if (std.mem.eql(u8, error_name, "access_denied")) return error.LoginCancelled;
        return error.InvalidAuthResponse;
    }

    return if (slow_down_responses > 0) error.DeviceFlowSlowDown else error.DeviceFlowTimeout;
}

pub fn refreshGitHubCopilotTokenForDomain(allocator: std.mem.Allocator, io: std.Io, refresh_token: []const u8, enterprise_domain: ?[]const u8) !types.OAuthCredentials {
    const domain = enterprise_domain orelse "github.com";
    const urls = try getUrls(allocator, domain);
    defer urls.deinit(allocator);
    var headers = try common.initCopilotHeaders(allocator);
    defer common.deinitHeaders(allocator, &headers);
    try headers.put(try allocator.dupe(u8, "Authorization"), try std.fmt.allocPrint(allocator, "Bearer {s}", .{refresh_token}));

    var client = try @import("../../http_client.zig").HttpClient.init(allocator, io);
    defer client.deinit();
    const response = client.request(.{
        .method = .GET,
        .url = urls.copilot_token_url,
        .headers = headers,
    }) catch |err| return common.mapHttpError(err);
    defer response.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;
    const token = common.objectString(parsed.value.object, "token") orelse return error.MissingAccessToken;
    const expires_at = common.objectInt(parsed.value.object, "expires_at") orelse return error.InvalidAuthResponse;

    return .{
        .refresh = try allocator.dupe(u8, refresh_token),
        .access = try allocator.dupe(u8, token),
        .expires = expires_at * std.time.ms_per_s - 5 * std.time.ms_per_min,
        .enterprise_url = if (enterprise_domain) |value| try allocator.dupe(u8, value) else null,
    };
}

const CopilotUrls = struct {
    device_code_url: []u8,
    access_token_url: []u8,
    copilot_token_url: []u8,

    fn deinit(self: *const CopilotUrls, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code_url);
        allocator.free(self.access_token_url);
        allocator.free(self.copilot_token_url);
    }
};

fn getUrls(allocator: std.mem.Allocator, domain: []const u8) !CopilotUrls {
    return .{
        .device_code_url = try std.fmt.allocPrint(allocator, "https://{s}/login/device/code", .{domain}),
        .access_token_url = try std.fmt.allocPrint(allocator, "https://{s}/login/oauth/access_token", .{domain}),
        .copilot_token_url = try std.fmt.allocPrint(allocator, "https://api.{s}/copilot_internal/v2/token", .{domain}),
    };
}
