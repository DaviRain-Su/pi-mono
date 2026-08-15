const std = @import("std");

pub const SUB_AGENT_RESERVED_PREFIX = "sub_agent.";
pub const SUB_AGENT_RESERVED_NAMES = [_][]const u8{
    "sub_agent.readiness",
    "sub_agent.delegation.result",
    "sub_agent.status",
    "sub_agent.delegate",
};

pub const SubAgentReservedNameError = error{SubAgentReservedNameDenied};

pub const SubAgentExtensionFactory = struct {
    is_sub_agent_factory: bool = false,
};

pub fn markSubAgentExtensionFactory(factory: *SubAgentExtensionFactory) *SubAgentExtensionFactory {
    factory.is_sub_agent_factory = true;
    return factory;
}

pub fn isSubAgentExtensionFactory(factory: *const SubAgentExtensionFactory) bool {
    return factory.is_sub_agent_factory;
}

pub fn isSubAgentReservedName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, SUB_AGENT_RESERVED_PREFIX)) return true;
    inline for (SUB_AGENT_RESERVED_NAMES) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

pub fn assertSubAgentReservedNameAllowed(
    name: []const u8,
    owner_is_sub_agent_factory: bool,
    operation: []const u8,
) SubAgentReservedNameError!void {
    _ = operation;
    if (!owner_is_sub_agent_factory and isSubAgentReservedName(name)) return error.SubAgentReservedNameDenied;
}

test "sub-agent reserved names use prefix contract" {
    try std.testing.expect(isSubAgentReservedName("sub_agent.delegate"));
    try std.testing.expect(isSubAgentReservedName("sub_agent.custom"));
    try std.testing.expect(!isSubAgentReservedName("agent.delegate"));
}

test "sub-agent factory marker authorizes reserved names" {
    var factory: SubAgentExtensionFactory = .{};
    try std.testing.expect(!isSubAgentExtensionFactory(&factory));
    _ = markSubAgentExtensionFactory(&factory);
    try std.testing.expect(isSubAgentExtensionFactory(&factory));

    try std.testing.expectError(
        error.SubAgentReservedNameDenied,
        assertSubAgentReservedNameAllowed("sub_agent.delegate", false, "register"),
    );
    try assertSubAgentReservedNameAllowed("sub_agent.delegate", true, "register");
}
