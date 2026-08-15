const std = @import("std");

pub const UNKNOWN_PROVIDER = "unknown";

pub fn getProviderLoginHelp(allocator: std.mem.Allocator, docs_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Use /login to log into a provider via OAuth or API key. See:\n  {s}/providers.md\n  {s}/models.md",
        .{ docs_path, docs_path },
    );
}

pub fn formatNoModelsAvailableMessage(allocator: std.mem.Allocator, docs_path: []const u8) ![]u8 {
    const help = try getProviderLoginHelp(allocator, docs_path);
    defer allocator.free(help);
    return std.fmt.allocPrint(allocator, "No models available. {s}", .{help});
}

pub fn formatNoModelSelectedMessage(allocator: std.mem.Allocator, docs_path: []const u8) ![]u8 {
    const help = try getProviderLoginHelp(allocator, docs_path);
    defer allocator.free(help);
    return std.fmt.allocPrint(allocator, "No model selected.\n\n{s}\n\nThen use /model to select a model.", .{help});
}

pub fn formatNoApiKeyFoundMessage(allocator: std.mem.Allocator, docs_path: []const u8, provider: []const u8) ![]u8 {
    const help = try getProviderLoginHelp(allocator, docs_path);
    defer allocator.free(help);
    const provider_display = if (std.mem.eql(u8, provider, UNKNOWN_PROVIDER)) "the selected model" else provider;
    return std.fmt.allocPrint(allocator, "No API key found for {s}.\n\n{s}", .{ provider_display, help });
}

test "auth guidance formats unknown provider message" {
    const message = try formatNoApiKeyFoundMessage(std.testing.allocator, "/docs", UNKNOWN_PROVIDER);
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "the selected model") != null);
}
