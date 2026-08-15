const std = @import("std");

/// Returns true if `haystack` contains `needle`, comparing ASCII characters
/// case-insensitively.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Returns true when `value` matches any known sensitive key pattern
/// (authorization, bearer, api_key, token, secret, etc.).
pub fn isSensitiveDiagnosticString(value: []const u8) bool {
    const needles = [_][]const u8{
        "authorization",
        "bearer",
        "api_key",
        "apikey",
        "token",
        "oauth",
        "password",
        "secret",
        "credential",
        "sk-",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(value, needle)) return true;
    }
    return false;
}

/// Writes `value` to `writer` as a JSON string, replacing it with
/// "[REDACTED]" when it matches a sensitive pattern.
pub fn writeRedactedDiagnosticString(writer: *std.Io.Writer, value: []const u8) !void {
    if (isSensitiveDiagnosticString(value)) {
        try std.json.Stringify.value("[REDACTED]", .{}, writer);
    } else {
        try std.json.Stringify.value(value, .{}, writer);
    }
}

/// Allocates a lowercased copy of `input`.
pub fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, input.len);
    for (input, 0..) |byte, index| {
        output[index] = std.ascii.toLower(byte);
    }
    return output;
}

test "asciiLowerAlloc produces lowercase copy" {
    const allocator = std.testing.allocator;
    const result = try asciiLowerAlloc(allocator, "Hello WORLD 123");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world 123", result);
}

test "containsIgnoreCase matches substrings case-insensitively" {
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("Hello World", "WORLD"));
    try std.testing.expect(containsIgnoreCase("Hello World", "lo wo"));
    try std.testing.expect(containsIgnoreCase("abc", ""));
    try std.testing.expect(!containsIgnoreCase("abc", "d"));
    try std.testing.expect(!containsIgnoreCase("", "a"));
    try std.testing.expect(!containsIgnoreCase("ab", "abc"));
}

test "isSensitiveDiagnosticString detects known sensitive patterns" {
    try std.testing.expect(isSensitiveDiagnosticString("Authorization: Bearer sk-123"));
    try std.testing.expect(isSensitiveDiagnosticString("my_api_key=xxx"));
    try std.testing.expect(isSensitiveDiagnosticString("x-apikey: val"));
    try std.testing.expect(isSensitiveDiagnosticString("access_token=abc"));
    try std.testing.expect(isSensitiveDiagnosticString("OAUTH_STATE=xyz"));
    try std.testing.expect(isSensitiveDiagnosticString("password=secret"));
    try std.testing.expect(isSensitiveDiagnosticString("client_secret=xxx"));
    try std.testing.expect(isSensitiveDiagnosticString("credential=abc"));
    try std.testing.expect(isSensitiveDiagnosticString("sk-live-abc123"));
    try std.testing.expect(!isSensitiveDiagnosticString("model=gpt-4"));
    try std.testing.expect(!isSensitiveDiagnosticString("content-type: json"));
    try std.testing.expect(!isSensitiveDiagnosticString("hello world"));
}
