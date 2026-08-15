const std = @import("std");

const narrow_no_break_space = "\xE2\x80\xAF";
const right_single_quote = "\xE2\x80\x99";

pub fn expandPath(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
    const without_at = if (std.mem.startsWith(u8, path, "@")) path[1..] else path;
    const normalized = try normalizeUnicodeSpaces(allocator, without_at);
    defer allocator.free(normalized);

    if (std.mem.eql(u8, normalized, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, normalized, "~/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, normalized[1..] });
    }
    return allocator.dupe(u8, normalized);
}

pub fn resolveToCwd(allocator: std.mem.Allocator, path: []const u8, cwd: []const u8, home: []const u8) ![]u8 {
    const expanded = try expandPath(allocator, path, home);
    defer allocator.free(expanded);
    if (std.fs.path.isAbsolute(expanded)) return allocator.dupe(u8, expanded);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, expanded });
}

pub fn resolveReadPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    cwd: []const u8,
    home: []const u8,
) ![]u8 {
    const resolved = try resolveToCwd(allocator, path, cwd, home);
    errdefer allocator.free(resolved);
    if (fileExists(io, resolved)) return resolved;

    const am_pm_variant = try macOSScreenshotPathVariant(allocator, resolved);
    defer allocator.free(am_pm_variant);
    if (!std.mem.eql(u8, am_pm_variant, resolved) and fileExists(io, am_pm_variant)) {
        allocator.free(resolved);
        return allocator.dupe(u8, am_pm_variant);
    }

    const curly_variant = try curlyQuoteVariant(allocator, resolved);
    defer allocator.free(curly_variant);
    if (!std.mem.eql(u8, curly_variant, resolved) and fileExists(io, curly_variant)) {
        allocator.free(resolved);
        return allocator.dupe(u8, curly_variant);
    }

    return resolved;
}

fn normalizeUnicodeSpaces(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < path.len) {
        if (unicodeSpaceLengthAt(path, index)) |len| {
            try out.append(allocator, ' ');
            index += len;
            continue;
        }
        try out.append(allocator, path[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn unicodeSpaceLengthAt(bytes: []const u8, index: usize) ?usize {
    if (bytes[index] == 0xC2 and index + 1 < bytes.len and bytes[index + 1] == 0xA0) return 2;
    if (bytes[index] == 0xE2 and index + 2 < bytes.len) {
        if (bytes[index + 1] == 0x80 and bytes[index + 2] >= 0x80 and bytes[index + 2] <= 0x8A) return 3;
        if (bytes[index + 1] == 0x80 and bytes[index + 2] == 0xAF) return 3;
        if (bytes[index + 1] == 0x81 and bytes[index + 2] == 0x9F) return 3;
    }
    if (bytes[index] == 0xE3 and index + 2 < bytes.len and bytes[index + 1] == 0x80 and bytes[index + 2] == 0x80) return 3;
    return null;
}

fn macOSScreenshotPathVariant(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < path.len) {
        if (index + 4 <= path.len and path[index] == ' ' and
            (std.ascii.eqlIgnoreCase(path[index + 1 .. index + 3], "AM") or
                std.ascii.eqlIgnoreCase(path[index + 1 .. index + 3], "PM")) and
            path[index + 3] == '.')
        {
            try out.appendSlice(allocator, narrow_no_break_space);
            try out.appendSlice(allocator, path[index + 1 .. index + 4]);
            index += 4;
            continue;
        }
        try out.append(allocator, path[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn curlyQuoteVariant(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (path) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, right_single_quote);
        } else {
            try out.append(allocator, byte);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "expandPath handles at-prefix and home expansion" {
    const allocator = std.testing.allocator;
    const path = try expandPath(allocator, "@~/file.txt", "/home/user");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/file.txt", path);
}

test "resolveToCwd resolves relative paths" {
    const allocator = std.testing.allocator;
    const path = try resolveToCwd(allocator, "src/main.zig", "/repo", "/home/user");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/repo/src/main.zig", path);
}
