const std = @import("std");

pub fn canonicalizePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return allocator.dupe(u8, path);
    defer dir.close(io);
    return allocator.dupe(u8, path);
}

pub fn isLocalPath(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const non_local = [_][]const u8{ "npm:", "git:", "github:", "http:", "https:", "ssh:" };
    for (non_local) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return false;
    }
    return true;
}

pub fn getCwdRelativePath(allocator: std.mem.Allocator, file_path: []const u8, cwd: []const u8) !?[]u8 {
    const absolute_cwd = try std.fs.path.resolve(allocator, &.{cwd});
    defer allocator.free(absolute_cwd);
    const absolute_path = try std.fs.path.resolve(allocator, &.{ absolute_cwd, file_path });
    defer allocator.free(absolute_path);
    const relative = try std.fs.path.relative(allocator, absolute_cwd, absolute_path);
    errdefer allocator.free(relative);
    if (std.mem.eql(u8, relative, "") or std.mem.eql(u8, relative, ".")) {
        allocator.free(relative);
        return try allocator.dupe(u8, ".");
    }
    if (std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../") or std.fs.path.isAbsolute(relative)) {
        allocator.free(relative);
        return null;
    }
    return relative;
}

pub fn formatPathRelativeToCwdOrAbsolute(allocator: std.mem.Allocator, file_path: []const u8, cwd: []const u8) ![]u8 {
    if (try getCwdRelativePath(allocator, file_path, cwd)) |relative| return normalizeSeparatorsInPlace(relative);
    const absolute = try std.fs.path.resolve(allocator, &.{ cwd, file_path });
    return normalizeSeparatorsInPlace(absolute);
}

fn normalizeSeparatorsInPlace(path: []u8) []u8 {
    for (path) |*byte| {
        if (byte.* == std.fs.path.sep) byte.* = '/';
    }
    return path;
}

test "paths detect local sources" {
    try std.testing.expect(isLocalPath("./local"));
    try std.testing.expect(isLocalPath("bare-name"));
    try std.testing.expect(!isLocalPath("npm:pkg"));
    try std.testing.expect(!isLocalPath("https://example.com"));
}
