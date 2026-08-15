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
    var args = try provider_json.cloneValue(allocator, tool_call.arguments);
    errdefer provider_json.freeValue(allocator, args);
    normalizeOptionalNulls(allocator, &args, tool.parameters);
    if (!valueMatchesSchema(args, tool.parameters)) {
        provider_json.freeValue(allocator, args);
        return ValidationError.ValidationFailed;
    }
    return args;
}

/// Drop optional JSON-null properties that the schema does not accept as null.
/// Port of TS `normalizeOptionalNulls` in `packages/ai/src/utils/validation.ts`.
fn normalizeOptionalNulls(allocator: std.mem.Allocator, value: *std.json.Value, schema: std.json.Value) void {
    if (schema != .object) return;
    switch (value.*) {
        .array => |*array| {
            const items_schema = schema.object.get("items") orelse return;
            if (items_schema == .array) {
                for (array.items, 0..) |*item, index| {
                    if (index >= items_schema.array.items.len) break;
                    normalizeOptionalNulls(allocator, item, items_schema.array.items[index]);
                }
            } else {
                for (array.items) |*item| normalizeOptionalNulls(allocator, item, items_schema);
            }
        },
        .object => |*object| {
            const properties = schema.object.get("properties") orelse return;
            if (properties != .object) return;

            var required = std.StringHashMap(void).init(allocator);
            defer required.deinit();
            if (schema.object.get("required")) |required_value| {
                if (required_value == .array) {
                    for (required_value.array.items) |item| {
                        if (item == .string) required.put(item.string, {}) catch {};
                    }
                }
            }

            var keys = std.ArrayList([]const u8).empty;
            defer keys.deinit(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                keys.append(allocator, entry.key_ptr.*) catch continue;
            }
            for (keys.items) |key| {
                const property_schema = properties.object.get(key) orelse continue;
                const field = object.getPtr(key) orelse continue;
                if (field.* == .null and !required.contains(key) and !schemaAllowsNull(property_schema)) {
                    if (object.fetchSwapRemove(key)) |kv| {
                        provider_json.freeValue(allocator, kv.value);
                        allocator.free(kv.key);
                    }
                } else {
                    normalizeOptionalNulls(allocator, field, property_schema);
                }
            }
        },
        else => {},
    }
}

fn schemaAllowsNull(schema: std.json.Value) bool {
    if (schema != .object) return false;
    if (schema.object.get("type")) |type_value| {
        if (type_value == .string and std.mem.eql(u8, type_value.string, "null")) return true;
        if (type_value == .array) {
            for (type_value.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "null")) return true;
            }
        }
    }
    if (schema.object.get("$ref")) |ref| {
        if (ref == .string) return true;
    }
    return false;
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

test "validateToolArguments omits optional nulls the schema rejects" {
    const allocator = std.testing.allocator;

    var city = try provider_json.initObject(allocator);
    try city.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "string") });
    var properties = try provider_json.initObject(allocator);
    try properties.put(allocator, try allocator.dupe(u8, "city"), .{ .object = city });
    var schema = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = schema });
    try schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = properties });

    var args = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = args });
    try args.put(allocator, try allocator.dupe(u8, "city"), .null);

    const tool = types.Tool{ .name = "lookup", .description = "Lookup", .parameters = .{ .object = schema } };
    const call = types.ToolCall{ .id = "1", .name = "lookup", .arguments = .{ .object = args } };
    const cloned = try validateToolArguments(allocator, tool, call);
    defer provider_json.freeValue(allocator, cloned);
    try std.testing.expect(cloned.object.get("city") == null);
}
