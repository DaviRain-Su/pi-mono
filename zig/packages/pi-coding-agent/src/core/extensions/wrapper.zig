const std = @import("std");
const agent = @import("agent");
const tool_definition_wrapper = @import("../../tools/tool_definition_wrapper.zig");

pub const ToolDefinition = tool_definition_wrapper.ToolDefinition;
pub const wrapToolDefinition = tool_definition_wrapper.wrapToolDefinition;
pub const wrapToolDefinitions = tool_definition_wrapper.wrapToolDefinitions;
pub const createToolDefinitionFromAgentTool = tool_definition_wrapper.createToolDefinitionFromAgentTool;

pub const RegisteredTool = struct {
    definition: ToolDefinition,
};

pub fn wrapRegisteredTool(registered_tool: RegisteredTool) agent.AgentTool {
    return wrapToolDefinition(registered_tool.definition);
}

pub fn wrapRegisteredTools(allocator: std.mem.Allocator, registered_tools: []const RegisteredTool) ![]agent.AgentTool {
    const tools = try allocator.alloc(agent.AgentTool, registered_tools.len);
    errdefer allocator.free(tools);
    for (registered_tools, tools) |registered_tool, *tool| {
        tool.* = wrapRegisteredTool(registered_tool);
    }
    return tools;
}

test "registered tool wrapper marks extension source" {
    const allocator = std.testing.allocator;
    const parameters = std.json.Value{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    defer @import("../../tools/common.zig").deinitJsonValue(allocator, parameters);

    const tool = wrapRegisteredTool(.{ .definition = .{
        .name = "x",
        .label = "X",
        .description = "desc",
        .parameters = parameters,
    } });
    try std.testing.expectEqual(agent.types.AgentToolSource.extension, tool.source);
}
