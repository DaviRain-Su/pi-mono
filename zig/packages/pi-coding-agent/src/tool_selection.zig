const std = @import("std");

/// Normalized tool visibility controls shared by prompt construction and
/// agent-tool assembly. The CLI can independently disable all tools,
/// disable only builtins, and/or provide an allowlist; extension tools must
/// not be collapsed into the builtin-only case.
pub const ToolSelection = struct {
    allowlist: ?[]const []const u8 = null,
    disable_all: bool = false,
    include_builtins: bool = true,

    pub fn fromCli(no_tools: bool, no_builtin_tools: bool, tools: ?[]const []const u8) ToolSelection {
        if (no_tools) {
            return .{
                .allowlist = tools,
                .disable_all = true,
                .include_builtins = false,
            };
        }
        return .{
            .allowlist = tools,
            .include_builtins = !no_builtin_tools,
        };
    }

    pub fn fromAllowlist(tools: ?[]const []const u8) ToolSelection {
        return .{ .allowlist = tools };
    }

    pub fn allowsBuiltin(self: ToolSelection, name: []const u8) bool {
        if (self.disable_all or !self.include_builtins) return false;
        return self.allowsName(name);
    }

    pub fn allowsExtension(self: ToolSelection, name: []const u8) bool {
        if (self.disable_all) return false;
        return self.allowsName(name);
    }

    pub fn allowsName(self: ToolSelection, name: []const u8) bool {
        const allowlist = self.allowlist orelse return true;
        for (allowlist) |allowed| {
            if (std.mem.eql(u8, allowed, name)) return true;
        }
        return false;
    }

    pub fn hasAllowlist(self: ToolSelection) bool {
        return self.allowlist != null;
    }
};

test "ToolSelection distinguishes no-tools from no-builtin-tools" {
    const all_disabled = ToolSelection.fromCli(true, false, null);
    try std.testing.expect(!all_disabled.allowsBuiltin("read"));
    try std.testing.expect(!all_disabled.allowsExtension("ext-tool"));

    const builtins_disabled = ToolSelection.fromCli(false, true, null);
    try std.testing.expect(!builtins_disabled.allowsBuiltin("read"));
    try std.testing.expect(builtins_disabled.allowsExtension("ext-tool"));

    const allowlisted = ToolSelection.fromCli(false, false, &.{ "read", "ext-tool" });
    try std.testing.expect(allowlisted.allowsBuiltin("read"));
    try std.testing.expect(!allowlisted.allowsBuiltin("bash"));
    try std.testing.expect(allowlisted.allowsExtension("ext-tool"));
    try std.testing.expect(!allowlisted.allowsExtension("other-ext-tool"));
}
