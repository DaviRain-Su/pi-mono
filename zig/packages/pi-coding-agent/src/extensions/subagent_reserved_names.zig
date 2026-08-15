//! Mirror of packages/coding-agent/src/core/extensions/subagent-reserved-names.ts.
//!
//! The TS implementation brands ExtensionFactory functions with a JS Symbol
//! (`Symbol.for("pi.subAgentExtensionFactory")`) so an unrelated extension
//! cannot register tools/commands/entries under the reserved
//! `sub_agent.*` substrate namespace. Zig has no Symbol concept and the
//! extension API is structured around RuntimeAdapter+Registry rather than
//! user-passed factories, so the brand half of the contract is realized as
//! an explicit `owner_allowed: bool` flag plumbed through the call site
//! (the official Zig sub-agent extension passes `true`; everyone else
//! passes `false` and gets rejected at the guard).

const std = @import("std");

pub const SUB_AGENT_RESERVED_PREFIX = "sub_agent.";

pub const SUB_AGENT_RESERVED_NAMES = [_][]const u8{
    "sub_agent.delegate",
    "sub_agent.readiness",
    "sub_agent.delegation.result",
    "sub_agent.status",
    "sub_agent_readiness",
    "sub-agent",
    "/sub-agent",
};

/// Match the TS Set: any of the literal names OR anything starting with
/// `sub_agent.`. The startsWith check covers the literal `sub_agent.*`
/// entries above and any future `sub_agent.<new>` additions.
pub fn isSubAgentReservedName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, SUB_AGENT_RESERVED_PREFIX)) return true;
    for (SUB_AGENT_RESERVED_NAMES) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

pub const SubAgentReservedError = error{ReservedSubAgentName};

/// Returns `error.ReservedSubAgentName` when `name` is a reserved
/// sub-agent substrate name AND `owner_allowed` is false. The official
/// Zig sub-agent extension passes `owner_allowed=true` when it
/// registers `sub_agent.delegate` etc.; any other extension trying to
/// claim those names is rejected. `operation` and `name` are used to
/// produce the error message via `formatReservedSubAgentError`.
pub fn assertSubAgentReservedNameAllowed(
    name: []const u8,
    owner_allowed: bool,
    operation: []const u8,
) SubAgentReservedError!void {
    _ = operation;
    if (!isSubAgentReservedName(name) or owner_allowed) return;
    return error.ReservedSubAgentName;
}

/// Build the human-readable message that mirrors the TS Error string
/// `Cannot {operation} reserved sub-agent substrate name "{name}" from
/// an unrelated extension.`. Caller owns the returned bytes.
pub fn formatReservedSubAgentError(
    allocator: std.mem.Allocator,
    name: []const u8,
    operation: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Cannot {s} reserved sub-agent substrate name \"{s}\" from an unrelated extension.",
        .{ operation, name },
    );
}

test "isSubAgentReservedName matches literal names" {
    try std.testing.expect(isSubAgentReservedName("sub_agent.delegate"));
    try std.testing.expect(isSubAgentReservedName("sub_agent.readiness"));
    try std.testing.expect(isSubAgentReservedName("sub_agent.delegation.result"));
    try std.testing.expect(isSubAgentReservedName("sub_agent.status"));
    try std.testing.expect(isSubAgentReservedName("sub_agent_readiness"));
    try std.testing.expect(isSubAgentReservedName("sub-agent"));
    try std.testing.expect(isSubAgentReservedName("/sub-agent"));
}

test "isSubAgentReservedName matches the sub_agent. prefix" {
    try std.testing.expect(isSubAgentReservedName("sub_agent.new_tool"));
    try std.testing.expect(isSubAgentReservedName("sub_agent."));
}

test "isSubAgentReservedName does not match unrelated names" {
    try std.testing.expect(!isSubAgentReservedName("delegate"));
    try std.testing.expect(!isSubAgentReservedName("subagent"));
    try std.testing.expect(!isSubAgentReservedName("agent.delegate"));
    try std.testing.expect(!isSubAgentReservedName(""));
}

test "assertSubAgentReservedNameAllowed permits non-reserved names" {
    try assertSubAgentReservedNameAllowed("my_tool", false, "register");
    try assertSubAgentReservedNameAllowed("", false, "register");
}

test "assertSubAgentReservedNameAllowed permits reserved names when owner_allowed" {
    try assertSubAgentReservedNameAllowed("sub_agent.delegate", true, "register");
    try assertSubAgentReservedNameAllowed("/sub-agent", true, "register");
}

test "assertSubAgentReservedNameAllowed rejects reserved names without owner_allowed" {
    try std.testing.expectError(
        error.ReservedSubAgentName,
        assertSubAgentReservedNameAllowed("sub_agent.delegate", false, "register"),
    );
    try std.testing.expectError(
        error.ReservedSubAgentName,
        assertSubAgentReservedNameAllowed("sub_agent.future_thing", false, "claim"),
    );
}

test "formatReservedSubAgentError matches TS message shape" {
    const allocator = std.testing.allocator;
    const msg = try formatReservedSubAgentError(allocator, "sub_agent.delegate", "register");
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "Cannot register reserved sub-agent substrate name \"sub_agent.delegate\" from an unrelated extension.",
        msg,
    );
}
