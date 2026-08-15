const std = @import("std");

pub const ShellConfig = struct {
    shell: []u8,
    args: []const []const u8,

    pub fn deinit(self: *ShellConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.shell);
        self.* = undefined;
    }
};

pub fn getShellConfig(allocator: std.mem.Allocator, io: std.Io, custom_shell_path: ?[]const u8) !ShellConfig {
    if (custom_shell_path) |path| {
        if (fileExists(io, path)) return .{ .shell = try allocator.dupe(u8, path), .args = &.{"-c"} };
        return error.CustomShellPathNotFound;
    }
    if (fileExists(io, "/bin/bash")) return .{ .shell = try allocator.dupe(u8, "/bin/bash"), .args = &.{"-c"} };
    return .{ .shell = try allocator.dupe(u8, "sh"), .args = &.{"-c"} };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn sanitizeBinaryOutput(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < str.len) {
        const len = std.unicode.utf8ByteSequenceLength(str[index]) catch {
            index += 1;
            continue;
        };
        if (index + len > str.len) break;
        const slice = str[index .. index + len];
        const code = std.unicode.utf8Decode(slice) catch {
            index += len;
            continue;
        };
        if (code == '\t' or code == '\n' or code == '\r') {
            try out.appendSlice(allocator, slice);
        } else if (code > 0x1f and !(code >= 0xfff9 and code <= 0xfffb)) {
            try out.appendSlice(allocator, slice);
        }
        index += len;
    }
    return out.toOwnedSlice(allocator);
}

test "shell sanitizes binary output" {
    const sanitized = try sanitizeBinaryOutput(std.testing.allocator, "a\x00b\nc");
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("ab\nc", sanitized);
}
