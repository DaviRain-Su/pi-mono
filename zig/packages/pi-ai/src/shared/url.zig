const std = @import("std");

/// Trim trailing whitespace and forward slashes from base_url, then append the
/// comptime `suffix` verbatim. Returns an owned slice the caller must free.
pub fn buildUrl(
    comptime suffix: []const u8,
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    const trimmed = trimTrailing(base_url);
    return std.fmt.allocPrint(allocator, "{s}" ++ suffix, .{trimmed});
}

/// Like `buildUrl`, but centralizes the SDK-compatible `/v1` normalization
/// heuristic. If the trimmed base_url already ends with `/v1`, the suffix is
/// appended verbatim. Otherwise, `/v1` is inserted before the suffix.
pub fn buildUrlV1Normalized(
    comptime suffix: []const u8,
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    const trimmed = trimTrailing(base_url);
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.allocPrint(allocator, "{s}" ++ suffix, .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "{s}/v1" ++ suffix, .{trimmed});
}

/// Format variant for callers that need a runtime/dynamic suffix (for example,
/// providers whose suffix embeds a model id). The base_url is trimmed of
/// trailing whitespace and slashes; everything else is delegated to the
/// supplied comptime `fmt` string, which must begin with `{s}` to receive the
/// trimmed base_url.
pub fn buildUrlFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    base_url: []const u8,
    args: anytype,
) ![]u8 {
    const trimmed = trimTrailing(base_url);
    return std.fmt.allocPrint(allocator, fmt, .{trimmed} ++ args);
}

fn trimTrailing(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

test "buildUrl appends suffix without normalization" {
    const allocator = std.testing.allocator;
    const url = try buildUrl("/chat/completions", allocator, "https://api.example.com/v1");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.example.com/v1/chat/completions", url);
}

test "buildUrl trims trailing slash" {
    const allocator = std.testing.allocator;
    const url = try buildUrl("/responses", allocator, "https://proxy.example.test/custom/v1/");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://proxy.example.test/custom/v1/responses", url);
}

test "buildUrlV1Normalized appends suffix when base ends with /v1" {
    const allocator = std.testing.allocator;
    const url = try buildUrlV1Normalized("/messages", allocator, "https://api.anthropic.com/v1");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "buildUrlV1Normalized inserts /v1 when base does not end with /v1" {
    const allocator = std.testing.allocator;
    const url = try buildUrlV1Normalized("/messages", allocator, "https://api.kimi.com/coding");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1/messages", url);
}

test "buildUrlV1Normalized trims trailing slashes before checking /v1" {
    const allocator = std.testing.allocator;
    const url = try buildUrlV1Normalized("/messages", allocator, "https://api.anthropic.com/v1/");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
}

test "buildUrlFmt embeds runtime arguments after trimmed base_url" {
    const allocator = std.testing.allocator;
    const url = try buildUrlFmt(
        allocator,
        "{s}/models/{s}:streamGenerateContent?alt=sse",
        "https://generativelanguage.googleapis.com/v1beta/",
        .{"gemini-2.5-pro"},
    );
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse",
        url,
    );
}

test "buildUrlFmt with empty args appends suffix" {
    const allocator = std.testing.allocator;
    const url = try buildUrlFmt(
        allocator,
        "{s}/responses",
        "https://proxy.example.test/custom/v1/",
        .{},
    );
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://proxy.example.test/custom/v1/responses", url);
}
