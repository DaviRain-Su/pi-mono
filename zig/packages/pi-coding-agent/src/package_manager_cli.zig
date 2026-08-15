pub const package_manager = @import("packages/package_manager.zig");
pub const config_selector = @import("packages/config_selector.zig");
pub const command_parser = @import("packages/package_command_parser.zig");

pub const PackageManagerCommand = enum {
    install,
    remove,
    uninstall,
    update,
    list,
    config,
};

pub fn commandFromName(name: []const u8) ?PackageManagerCommand {
    const std = @import("std");
    if (std.mem.eql(u8, name, "install")) return .install;
    if (std.mem.eql(u8, name, "remove")) return .remove;
    if (std.mem.eql(u8, name, "uninstall")) return .uninstall;
    if (std.mem.eql(u8, name, "update")) return .update;
    if (std.mem.eql(u8, name, "list")) return .list;
    if (std.mem.eql(u8, name, "config")) return .config;
    return null;
}

test "package manager cli command aliases include uninstall" {
    const std = @import("std");
    try std.testing.expectEqual(PackageManagerCommand.uninstall, commandFromName("uninstall").?);
}
