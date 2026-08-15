const std = @import("std");
const builtin = @import("builtin");
const clipboard_util = @import("clipboard.zig");
const clipboard_image = @import("clipboard_image.zig");

pub const ClipboardModule = struct {
    pub fn setText(
        _: ClipboardModule,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        text: []const u8,
    ) !void {
        var result = try clipboard_util.copyToClipboard(allocator, io, env_map, text);
        defer result.deinit(allocator);
    }

    pub fn hasImage(_: ClipboardModule, allocator: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) bool {
        if (clipboard_image.readClipboardImage(allocator, io, env_map) catch null) |image| {
            var owned = image;
            owned.deinit(allocator);
            return true;
        }
        return false;
    }

    pub fn getImageBinary(
        _: ClipboardModule,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
    ) !?[]u8 {
        const image = (try clipboard_image.readClipboardImage(allocator, io, env_map)) orelse return null;
        defer allocator.free(image.mime_type);
        return image.bytes;
    }
};

pub fn hasDisplay(env_map: *const std.process.Environ.Map) bool {
    return builtin.os.tag != .linux or env_map.get("DISPLAY") != null or env_map.get("WAYLAND_DISPLAY") != null;
}

pub fn loadClipboard(env_map: *const std.process.Environ.Map) ?ClipboardModule {
    if (env_map.get("TERMUX_VERSION") != null) return null;
    if (!hasDisplay(env_map)) return null;
    return .{};
}

test "clipboard native load respects termux and display checks" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(null, loadClipboard(&env_map));
        try env_map.put("WAYLAND_DISPLAY", "wayland-0");
        try std.testing.expect(loadClipboard(&env_map) != null);
    } else {
        try std.testing.expect(loadClipboard(&env_map) != null);
    }

    try env_map.put("TERMUX_VERSION", "1");
    try std.testing.expectEqual(null, loadClipboard(&env_map));
}
