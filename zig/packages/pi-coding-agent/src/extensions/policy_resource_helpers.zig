const std = @import("std");
const enforcement = @import("enforcement.zig");

fn narrowOptionalLimit(policy_limit: ?u64, descriptor_limit: ?u64) ?u64 {
    if (policy_limit) |policy_value| {
        if (descriptor_limit) |descriptor_value| return @min(policy_value, descriptor_value);
        return policy_value;
    }
    return descriptor_limit;
}

pub fn narrowEnforcementResourceLimits(base: *enforcement.ResourceLimits, policy: enforcement.ResourceLimits) void {
    base.max_children = narrowOptionalLimit(policy.max_children, base.max_children);
    base.depth = narrowOptionalLimit(policy.depth, base.depth);
    base.turns = narrowOptionalLimit(policy.turns, base.turns);
    base.timeout_ms = narrowOptionalLimit(policy.timeout_ms, base.timeout_ms);
    base.output_bytes = narrowOptionalLimit(policy.output_bytes, base.output_bytes);
    base.output_lines = narrowOptionalLimit(policy.output_lines, base.output_lines);
}

pub fn cloneEnforcementResourceLimits(
    allocator: std.mem.Allocator,
    limits: enforcement.ResourceLimits,
) !enforcement.ResourceLimits {
    const tool_scopes = try cloneConstStringList(allocator, limits.tool_scopes);
    errdefer freeConstStringList(allocator, tool_scopes);
    return .{
        .max_children = limits.max_children,
        .depth = limits.depth,
        .turns = limits.turns,
        .timeout_ms = limits.timeout_ms,
        .output_bytes = limits.output_bytes,
        .output_lines = limits.output_lines,
        .tool_scopes = tool_scopes,
    };
}

pub fn deinitEnforcementResourceLimits(allocator: std.mem.Allocator, limits: *enforcement.ResourceLimits) void {
    freeConstStringList(allocator, limits.tool_scopes);
    limits.* = .{};
}

fn cloneConstStringList(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        errdefer allocator.free(cloned[index]);
    }
    return cloned;
}

const freeConstStringList = @import("../slice_utils.zig").freeStringSlice;
