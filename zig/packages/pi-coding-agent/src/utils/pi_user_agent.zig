const std = @import("std");

pub fn getPiUserAgent(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const builtin = @import("builtin");
    const os = @tagName(builtin.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    return std.fmt.allocPrint(allocator, "pi/{s} ({s}; zig; {s})", .{ version, os, arch });
}

test "pi user agent includes version" {
    const value = try getPiUserAgent(std.testing.allocator, "1.2.3");
    defer std.testing.allocator.free(value);
    try std.testing.expect(std.mem.startsWith(u8, value, "pi/1.2.3 ("));
}
