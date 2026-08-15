const std = @import("std");
const resource_types = @import("types.zig");

const Diagnostic = resource_types.Diagnostic;

pub fn makeDiagnostic(allocator: std.mem.Allocator, kind: []const u8, message: []const u8, path: []const u8) !Diagnostic {
    const redacted_message = try redactDiagnosticValue(allocator, message);
    errdefer allocator.free(redacted_message);
    const redacted_path = try redactDiagnosticValue(allocator, path);
    errdefer allocator.free(redacted_path);
    return .{
        .kind = try allocator.dupe(u8, kind),
        .message = redacted_message,
        .path = redacted_path,
    };
}

pub fn redactDiagnosticValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (startsWithIgnoreCase(value[index..], "Bearer ")) {
            try out.writer.writeAll("Bearer [REDACTED]");
            index = skipUntilDelimiter(value, index + "Bearer ".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "api_key=")) {
            try out.writer.writeAll("api_key=[REDACTED]");
            index = skipUntilDelimiter(value, index + "api_key=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "access_token=")) {
            try out.writer.writeAll("access_token=[REDACTED]");
            index = skipUntilDelimiter(value, index + "access_token=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "token=")) {
            try out.writer.writeAll("token=[REDACTED]");
            index = skipUntilDelimiter(value, index + "token=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "x-api-key:")) {
            try out.writer.writeAll("x-api-key: [REDACTED]");
            index = skipUntilDelimiter(value, index + "x-api-key:".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "sk-")) {
            try out.writer.writeAll("[REDACTED]");
            index = skipUntilDelimiter(value, index);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "secret")) {
            try out.writer.writeAll("[REDACTED]");
            index += "secret".len;
            continue;
        }
        try out.writer.writeByte(value[index]);
        index += 1;
    }
    return out.toOwnedSlice();
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn skipUntilDelimiter(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            ' ', '\t', '\r', '\n', '&', '"', '\'', ',', ')' => return index,
            else => {},
        }
    }
    return index;
}

pub fn cloneDiagnostic(allocator: std.mem.Allocator, diagnostic: Diagnostic) !Diagnostic {
    return .{
        .kind = try allocator.dupe(u8, diagnostic.kind),
        .message = try allocator.dupe(u8, diagnostic.message),
        .path = if (diagnostic.path) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn deinitDiagnosticsList(allocator: std.mem.Allocator, items: *std.ArrayList(Diagnostic)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}
