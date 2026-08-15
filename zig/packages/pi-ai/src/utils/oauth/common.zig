const std = @import("std");
const http_client = @import("../../http_client.zig");
const provider_json = @import("../../shared/provider_json.zig");
const types = @import("types.zig");

pub const EncodedField = struct {
    name: []const u8,
    value: []const u8,
};

pub const AuthorizationInput = struct {
    code: ?[]u8 = null,
    state: ?[]u8 = null,

    pub fn deinit(self: *const AuthorizationInput, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
    }
};

pub fn defaultIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn currentTimeMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

pub fn computeExpiresAtMs(expires_in_seconds: i64, io: std.Io, with_skew: bool) i64 {
    const skew: i64 = if (with_skew) 5 * std.time.ms_per_min else 0;
    return currentTimeMs(io) + expires_in_seconds * std.time.ms_per_s - skew;
}

pub fn cloneCredentials(allocator: std.mem.Allocator, credentials: types.OAuthCredentials) !types.OAuthCredentials {
    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = try allocator.dupe(u8, credentials.access),
        .expires = credentials.expires,
        .account_id = if (credentials.account_id) |value| try allocator.dupe(u8, value) else null,
        .enterprise_url = if (credentials.enterprise_url) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn parseAuthorizationInput(allocator: std.mem.Allocator, input: []const u8) !AuthorizationInput {
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

fn extractAuthorizationFromQuery(allocator: std.mem.Allocator, query_text: []const u8) !AuthorizationInput {
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

pub fn buildFormBody(allocator: std.mem.Allocator, fields: []const EncodedField) ![]u8 {
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

pub fn formEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
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

pub fn percentDecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
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

pub fn postJson(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8, extra_headers: ?*std.StringHashMap([]const u8)) ![]u8 {
    var headers = try initHeaders(allocator, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    });
    defer deinitHeaders(allocator, &headers);
    if (extra_headers) |value| try cloneHeadersInto(allocator, &headers, value);

    var client = try http_client.HttpClient.init(allocator, io);
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

pub fn postForm(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8, extra_headers: ?*std.StringHashMap([]const u8)) ![]u8 {
    var headers = try initHeaders(allocator, &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
    });
    defer deinitHeaders(allocator, &headers);
    if (extra_headers) |value| try cloneHeadersInto(allocator, &headers, value);

    var client = try http_client.HttpClient.init(allocator, io);
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

pub fn initHeaders(allocator: std.mem.Allocator, pairs: []const struct { name: []const u8, value: []const u8 }) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitHeaders(allocator, &headers);
    for (pairs) |pair| {
        try headers.put(try allocator.dupe(u8, pair.name), try allocator.dupe(u8, pair.value));
    }
    return headers;
}

pub fn initCopilotHeaders(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    return initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "GitHubCopilotChat/0.35.0" },
        .{ .name = "Editor-Version", .value = "vscode/1.107.0" },
        .{ .name = "Editor-Plugin-Version", .value = "copilot-chat/0.35.0" },
        .{ .name = "Copilot-Integration-Id", .value = "vscode-chat" },
    });
}

pub fn cloneHeadersInto(allocator: std.mem.Allocator, dest: *std.StringHashMap([]const u8), source: *std.StringHashMap([]const u8)) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try dest.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
    }
}

pub fn deinitHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

pub fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn objectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => value.integer,
        else => null,
    };
}

pub fn parseTokenResponse(allocator: std.mem.Allocator, io: std.Io, response_body: []const u8, with_skew: bool) !types.OAuthCredentials {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    const access_token = objectString(parsed.value.object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = objectString(parsed.value.object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = objectInt(parsed.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .access = try allocator.dupe(u8, access_token),
        .refresh = try allocator.dupe(u8, refresh_token),
        .expires = computeExpiresAtMs(expires_in, io, with_skew),
    };
}

pub fn tokenJsonBody(allocator: std.mem.Allocator, fields: []const EncodedField) ![]u8 {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer provider_json.freeValue(allocator, .{ .object = object });

    for (fields) |field| {
        try object.put(allocator, try allocator.dupe(u8, field.name), .{ .string = try allocator.dupe(u8, field.value) });
    }

    const value: std.json.Value = .{ .object = object };
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn extractOpenAICodexAccountId(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
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
    const auth_value = parsed.value.object.get("https://api.openai.com/auth") orelse return error.MissingAccountId;
    if (auth_value != .object) return error.MissingAccountId;
    const account_id_value = auth_value.object.get("chatgpt_account_id") orelse return error.MissingAccountId;
    if (account_id_value != .string or account_id_value.string.len == 0) return error.MissingAccountId;
    return try allocator.dupe(u8, account_id_value.string);
}

pub fn mapHttpError(err: anyerror) anyerror {
    return switch (err) {
        http_client.HttpError.ConnectionRefused => error.ConnectionRefused,
        http_client.HttpError.ConnectionReset => error.ConnectionReset,
        http_client.HttpError.Timeout => error.Timeout,
        http_client.HttpError.RequestAborted => error.RequestAborted,
        http_client.HttpError.InvalidUrl => error.InvalidUrl,
        http_client.HttpError.UnknownHost => error.UnknownHost,
        http_client.HttpError.TlsFailure => error.TlsFailure,
        http_client.HttpError.TooManyRedirects => error.TooManyRedirects,
        http_client.HttpError.NetworkUnreachable => error.NetworkUnreachable,
        else => error.HttpRequestFailed,
    };
}

test "oauth common parses authorization inputs" {
    var parsed = try parseAuthorizationInput(std.testing.allocator, "\"http://localhost/callback?code=abc%20123&state=xyz\"");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc 123", parsed.code.?);
    try std.testing.expectEqualStrings("xyz", parsed.state.?);

    var fragment = try parseAuthorizationInput(std.testing.allocator, "code-value#state-value");
    defer fragment.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code-value", fragment.code.?);
    try std.testing.expectEqualStrings("state-value", fragment.state.?);
}

test "oauth common builds form bodies" {
    const body = try buildFormBody(std.testing.allocator, &.{
        .{ .name = "a b", .value = "x+y" },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("a%20b=x%2By", body);
}
