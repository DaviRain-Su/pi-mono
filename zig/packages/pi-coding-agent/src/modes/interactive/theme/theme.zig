pub const ThemeName = enum {
    light,
    dark,
    system,
};

pub const DEFAULT_THEME: ThemeName = .system;

pub fn parseThemeName(name: []const u8) ?ThemeName {
    const std = @import("std");
    if (std.mem.eql(u8, name, "light")) return .light;
    if (std.mem.eql(u8, name, "dark")) return .dark;
    if (std.mem.eql(u8, name, "system")) return .system;
    return null;
}

test "theme parser accepts system" {
    const std = @import("std");
    try std.testing.expectEqual(ThemeName.system, parseThemeName("system").?);
}
