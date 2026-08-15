const std = @import("std");
const agent = @import("agent");

pub const ToolDefinition = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    prepare_arguments: ?agent.types.PrepareArgumentsFn = null,
    execution_mode: ?agent.types.ToolExecutionMode = null,
    execute: ?agent.types.ExecuteToolFn = null,
    execute_context: ?*anyopaque = null,
    deinit_execute_context: ?agent.types.DeinitToolContextFn = null,
};

pub fn wrapToolDefinition(definition: ToolDefinition) agent.AgentTool {
    return .{
        .name = definition.name,
        .label = definition.label,
        .description = definition.description,
        .parameters = definition.parameters,
        .prepare_arguments = definition.prepare_arguments,
        .execution_mode = definition.execution_mode,
        .execute = definition.execute,
        .execute_context = definition.execute_context,
        .deinit_execute_context = definition.deinit_execute_context,
        .source = .extension,
    };
}

pub fn wrapToolDefinitions(allocator: std.mem.Allocator, definitions: []const ToolDefinition) ![]agent.AgentTool {
    const tools = try allocator.alloc(agent.AgentTool, definitions.len);
    for (definitions, tools) |definition, *tool| {
        tool.* = wrapToolDefinition(definition);
    }
    return tools;
}

pub fn createToolDefinitionFromAgentTool(tool: agent.AgentTool) ToolDefinition {
    return .{
        .name = tool.name,
        .label = tool.label,
        .description = tool.description,
        .parameters = tool.parameters,
        .prepare_arguments = tool.prepare_arguments,
        .execution_mode = tool.execution_mode,
        .execute = tool.execute,
        .execute_context = tool.execute_context,
        .deinit_execute_context = tool.deinit_execute_context,
    };
}

test "tool definition wrapper preserves tool metadata" {
    const definition = ToolDefinition{
        .name = "read",
        .label = "Read",
        .description = "Read file",
        .parameters = .{ .object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{}) },
    };
    defer @import("common.zig").deinitJsonValue(std.testing.allocator, definition.parameters);

    const tool = wrapToolDefinition(definition);
    try std.testing.expectEqualStrings("read", tool.name);
    try std.testing.expectEqualStrings("Read", tool.label);
    try std.testing.expectEqual(agent.types.AgentToolSource.extension, tool.source);
}
