const std = @import("std");

pub fn oauthSuccessHtml(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return renderPage(allocator, "Authentication successful", "Authentication successful", message, null);
}

pub fn oauthErrorHtml(allocator: std.mem.Allocator, message: []const u8, details: ?[]const u8) ![]u8 {
    return renderPage(allocator, "Authentication failed", "Authentication failed", message, details);
}

fn renderPage(
    allocator: std.mem.Allocator,
    title: []const u8,
    heading: []const u8,
    message: []const u8,
    details: ?[]const u8,
) ![]u8 {
    const escaped_title = try escapeHtml(allocator, title);
    defer allocator.free(escaped_title);
    const escaped_heading = try escapeHtml(allocator, heading);
    defer allocator.free(escaped_heading);
    const escaped_message = try escapeHtml(allocator, message);
    defer allocator.free(escaped_message);
    const escaped_details = if (details) |value| try escapeHtml(allocator, value) else null;
    defer if (escaped_details) |value| allocator.free(value);

    return std.fmt.allocPrint(
        allocator,
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>{s}</title></head><body><main><h1>{s}</h1><p>{s}</p>{s}</main></body></html>",
        .{ escaped_title, escaped_heading, escaped_message, escaped_details orelse "" },
    );
}

fn escapeHtml(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "oauth page escapes html" {
    const html = try oauthErrorHtml(std.testing.allocator, "<bad>", "\"details\"");
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;bad&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;details&quot;") != null);
}
