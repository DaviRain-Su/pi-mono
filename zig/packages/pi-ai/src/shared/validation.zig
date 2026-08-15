const std = @import("std");
const provider_json = @import("provider_json.zig");
const types = @import("../types.zig");

pub const ValidationError = error{
    ToolNotFound,
    ValidationFailed,
};

pub fn validateToolCall(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    tool_call: types.ToolCall,
) !std.json.Value {
    const tool = findTool(tools, tool_call.name) orelse return ValidationError.ToolNotFound;
    return validateToolArguments(allocator, tool, tool_call);
}

pub fn validateToolArguments(
    allocator: std.mem.Allocator,
    tool: types.Tool,
    tool_call: types.ToolCall,
) !std.json.Value {
    if (!std.mem.eql(u8, tool.name, tool_call.name)) return ValidationError.ToolNotFound;
    if (!valueMatchesSchema(tool_call.arguments, tool.parameters)) return ValidationError.ValidationFailed;
    return provider_json.cloneValue(allocator, tool_call.arguments);
}

fn findTool(tools: []const types.Tool, name: []const u8) ?types.Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn valueMatchesSchema(value: std.json.Value, schema: std.json.Value) bool {
    if (schema != .object) return true;
    const schema_type = schema.object.get("type") orelse return true;

    if (schema_type == .string) {
        if (std.mem.eql(u8, schema_type.string, "object")) return value == .object;
        if (std.mem.eql(u8, schema_type.string, "array")) return value == .array;
        if (std.mem.eql(u8, schema_type.string, "string")) return value == .string;
        if (std.mem.eql(u8, schema_type.string, "boolean")) return value == .bool;
        if (std.mem.eql(u8, schema_type.string, "integer")) return value == .integer;
        if (std.mem.eql(u8, schema_type.string, "number")) return value == .integer or value == .float or value == .number_string;
        if (std.mem.eql(u8, schema_type.string, "null")) return value == .null;
    }

    if (schema_type == .array) {
        for (schema_type.array.items) |item| {
            if (item == .string and primitiveTypeMatches(value, item.string)) return true;
        }
        return false;
    }

    return true;
}

fn primitiveTypeMatches(value: std.json.Value, type_name: []const u8) bool {
    if (std.mem.eql(u8, type_name, "object")) return value == .object;
    if (std.mem.eql(u8, type_name, "array")) return value == .array;
    if (std.mem.eql(u8, type_name, "string")) return value == .string;
    if (std.mem.eql(u8, type_name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, type_name, "integer")) return value == .integer;
    if (std.mem.eql(u8, type_name, "number")) return value == .integer or value == .float or value == .number_string;
    if (std.mem.eql(u8, type_name, "null")) return value == .null;
    return false;
}

test "validateToolCall finds tool and clones valid arguments" {
    const allocator = std.testing.allocator;
    var schema_object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = schema_object });
    try schema_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });

    const args_object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = args_object });

    const tool = types.Tool{ .name = "run", .description = "Run", .parameters = .{ .object = schema_object } };
    const call = types.ToolCall{ .id = "1", .name = "run", .arguments = .{ .object = args_object } };
    const cloned = try validateToolCall(allocator, &[_]types.Tool{tool}, call);
    defer provider_json.freeValue(allocator, cloned);
    try std.testing.expect(cloned == .object);
}
