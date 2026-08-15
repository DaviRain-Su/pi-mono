const std = @import("std");

pub fn resolvePath(allocator: std.mem.Allocator, base_dir: []const u8, input: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(input)) return allocator.dupe(u8, input);
    return std.fs.path.resolve(allocator, &[_][]const u8{ base_dir, input });
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

pub fn readOptionalFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
