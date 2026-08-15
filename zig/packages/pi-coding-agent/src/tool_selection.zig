const std = @import("std");

/// Normalized tool visibility controls shared by prompt construction and
/// agent-tool assembly. The CLI can independently disable all tools,
/// disable only builtins, and/or provide an allowlist; extension tools must
/// not be collapsed into the builtin-only case.
pub const ToolSelection = struct {
    allowlist: ?[]const []const u8 = null,
    denylist: ?[]const []const u8 = null,
    /// Settings `defaultTools`: initial built-in selection only. Ignored when
    /// `--tools` sets an allowlist or when CLI flags disable tools.
    default_builtins: ?[]const []const u8 = null,
    disable_all: bool = false,
    include_builtins: bool = true,

    pub fn fromCli(no_tools: bool, no_builtin_tools: bool, tools: ?[]const []const u8) ToolSelection {
        return fromCliEx(no_tools, no_builtin_tools, tools, null);
    }

    pub fn fromCliEx(
        no_tools: bool,
        no_builtin_tools: bool,
        tools: ?[]const []const u8,
        exclude_tools: ?[]const []const u8,
    ) ToolSelection {
        if (no_tools) {
            return .{
                .allowlist = tools,
                .denylist = exclude_tools,
                .disable_all = true,
                .include_builtins = false,
            };
        }
        return .{
            .allowlist = tools,
            .denylist = exclude_tools,
            .include_builtins = !no_builtin_tools,
        };
    }

    pub fn fromAllowlist(tools: ?[]const []const u8) ToolSelection {
        return .{ .allowlist = tools };
    }

    /// Apply settings `defaultTools` when the CLI did not override tool
    /// visibility. An empty list is preserved and means no built-ins start
    /// enabled; extension tools stay allowed.
    pub fn withDefaultBuiltins(self: ToolSelection, default_builtins: ?[]const []const u8) ToolSelection {
        if (self.allowlist != null or self.disable_all or !self.include_builtins) return self;
        var result = self;
        result.default_builtins = default_builtins;
        return result;
    }

    pub fn allowsBuiltin(self: ToolSelection, name: []const u8) bool {
        if (self.disable_all or !self.include_builtins) return false;
        if (isDenied(self.denylist, name)) return false;
        if (self.allowlist) |list| return containsName(list, name);
        if (self.default_builtins) |list| return containsName(list, name);
        return true;
    }

    pub fn allowsExtension(self: ToolSelection, name: []const u8) bool {
        if (self.disable_all) return false;
        return self.allowsName(name);
    }

    pub fn allowsName(self: ToolSelection, name: []const u8) bool {
        if (isDenied(self.denylist, name)) return false;
        const allowlist = self.allowlist orelse return true;
        return containsName(allowlist, name);
    }

    pub fn hasAllowlist(self: ToolSelection) bool {
        return self.allowlist != null;
    }
};

fn isDenied(denylist: ?[]const []const u8, name: []const u8) bool {
    const excluded = denylist orelse return false;
    return containsName(excluded, name);
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

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

test "ToolSelection denylist excludes names after allowlist" {
    const excluded = ToolSelection.fromCliEx(false, false, &.{ "read", "bash" }, &.{"bash"});
    try std.testing.expect(excluded.allowsBuiltin("read"));
    try std.testing.expect(!excluded.allowsBuiltin("bash"));

    const denylist_only = ToolSelection.fromCliEx(false, false, null, &.{"ask_question"});
    try std.testing.expect(denylist_only.allowsBuiltin("read"));
    try std.testing.expect(!denylist_only.allowsExtension("ask_question"));
}

test "ToolSelection defaultTools limits builtins and keeps extension tools" {
    const configured = ToolSelection.fromCliEx(false, false, null, null).withDefaultBuiltins(&.{ "grep", "find" });
    try std.testing.expect(configured.allowsBuiltin("grep"));
    try std.testing.expect(configured.allowsBuiltin("find"));
    try std.testing.expect(!configured.allowsBuiltin("read"));
    try std.testing.expect(configured.allowsExtension("sdk_tool"));

    const empty = ToolSelection.fromCliEx(false, false, null, null).withDefaultBuiltins(&.{});
    try std.testing.expect(!empty.allowsBuiltin("read"));
    try std.testing.expect(empty.allowsExtension("sdk_tool"));

    const excluded = ToolSelection.fromCliEx(false, false, null, &.{"grep"}).withDefaultBuiltins(&.{ "grep", "find" });
    try std.testing.expect(!excluded.allowsBuiltin("grep"));
    try std.testing.expect(excluded.allowsBuiltin("find"));

    const cli_allowlist = ToolSelection.fromCliEx(false, false, &.{"read"}, null).withDefaultBuiltins(&.{"grep"});
    try std.testing.expect(cli_allowlist.allowsBuiltin("read"));
    try std.testing.expect(!cli_allowlist.allowsBuiltin("grep"));

    const no_builtins = ToolSelection.fromCliEx(false, true, null, null).withDefaultBuiltins(&.{"grep"});
    try std.testing.expect(!no_builtins.allowsBuiltin("grep"));
    try std.testing.expect(no_builtins.allowsExtension("sdk_tool"));
}
