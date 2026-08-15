const std = @import("std");
const resources_mod = @import("../resources/resources.zig");

pub fn cloneResourceDiagnostic(allocator: std.mem.Allocator, diagnostic: resources_mod.Diagnostic) !resources_mod.Diagnostic {
    return .{
        .kind = try allocator.dupe(u8, diagnostic.kind),
        .message = try allocator.dupe(u8, diagnostic.message),
        .path = if (diagnostic.path) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn makeResourceDiagnostic(allocator: std.mem.Allocator, kind: []const u8, message: []const u8, path: []const u8) !resources_mod.Diagnostic {
    const redacted_message = try resources_mod.redactDiagnosticValue(allocator, message);
    errdefer allocator.free(redacted_message);
    const redacted_path = try resources_mod.redactDiagnosticValue(allocator, path);
    errdefer allocator.free(redacted_path);
    return .{
        .kind = try allocator.dupe(u8, kind),
        .message = redacted_message,
        .path = redacted_path,
    };
}

/// Format `fmt`/`args` into a temporary message and push a Diagnostic into
/// `diagnostics`. Replaces the recurring three-line "allocPrint -> defer
/// free -> append makeResourceDiagnostic" pattern in startLocked* runtime
/// loaders (~11 sites in extension_runtime.zig).
pub fn appendFmtDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(resources_mod.Diagnostic),
    kind: []const u8,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try diagnostics.append(allocator, try makeResourceDiagnostic(allocator, kind, message, path));
}

pub fn runtimeContractCategory(_: anyerror) []const u8 {
    return "runtime_contract_failed";
}

pub fn deinitResourceDiagnosticsList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(resources_mod.Diagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
    diagnostics.deinit(allocator);
}
