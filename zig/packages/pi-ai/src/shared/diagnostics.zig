const std = @import("std");
const provider_json = @import("provider_json.zig");
const types = @import("../types.zig");

pub fn formatThrownError(err: anyerror) []const u8 {
    return @errorName(err);
}

pub fn extractDiagnosticError(allocator: std.mem.Allocator, err: anyerror) !types.DiagnosticErrorInfo {
    return .{
        .name = try allocator.dupe(u8, "Error"),
        .message = try allocator.dupe(u8, @errorName(err)),
    };
}

pub fn createAssistantMessageDiagnostic(
    allocator: std.mem.Allocator,
    diagnostic_type: []const u8,
    err: anyerror,
    details: ?std.json.Value,
) !types.AssistantMessageDiagnostic {
    return .{
        .type = try allocator.dupe(u8, diagnostic_type),
        .timestamp = 0,
        .error_info = try extractDiagnosticError(allocator, err),
        .details = if (details) |value| try provider_json.cloneValue(allocator, value) else null,
    };
}

pub fn appendAssistantMessageDiagnostic(
    allocator: std.mem.Allocator,
    message: *types.AssistantMessage,
    diagnostic: types.AssistantMessageDiagnostic,
) !void {
    const existing = message.diagnostics orelse &[_]types.AssistantMessageDiagnostic{};
    const next = try allocator.alloc(types.AssistantMessageDiagnostic, existing.len + 1);
    @memcpy(next[0..existing.len], existing);
    next[existing.len] = diagnostic;
    if (message.diagnostics) |owned_existing| allocator.free(owned_existing);
    message.diagnostics = next;
}

test "create and append assistant message diagnostic" {
    const allocator = std.testing.allocator;
    var message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .timestamp = 1,
    };
    defer types.freeAssistantMessage(allocator, message);

    const diagnostic = try createAssistantMessageDiagnostic(allocator, "provider_error", error.ConnectionRefused, null);
    try appendAssistantMessageDiagnostic(allocator, &message, diagnostic);

    try std.testing.expectEqual(@as(usize, 1), message.diagnostics.?.len);
    try std.testing.expectEqualStrings("provider_error", message.diagnostics.?[0].type);
    try std.testing.expectEqualStrings("ConnectionRefused", message.diagnostics.?[0].error_info.?.message);
}
