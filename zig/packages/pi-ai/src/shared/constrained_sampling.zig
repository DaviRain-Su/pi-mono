const std = @import("std");
const types = @import("../types.zig");
const provider_json = @import("provider_json.zig");

pub const StrictJsonSchemaError = error{
    UnsupportedStrictJsonSchema,
};

const unsupported_keys = [_][]const u8{
    "$ref",
    "$defs",
    "definitions",
    "allOf",
    "oneOf",
    "patternProperties",
    "dependentSchemas",
    "dependencies",
    "unevaluatedProperties",
    "propertyNames",
    "contains",
    "prefixItems",
    "not",
    "if",
    "then",
    "else",
};

fn isJsonSchemaObject(value: std.json.Value) bool {
    return value == .object;
}

fn schemaTypeIncludes(schema: std.json.Value, type_name: []const u8) bool {
    if (schema != .object) return false;
    const type_value = schema.object.get("type") orelse return false;
    if (type_value == .string) return std.mem.eql(u8, type_value.string, type_name);
    if (type_value == .array) {
        for (type_value.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, type_name)) return true;
        }
    }
    return false;
}

fn isStructuredSchema(schema: std.json.Value) bool {
    if (!isJsonSchemaObject(schema)) return false;
    if (schemaTypeIncludes(schema, "object") or schemaTypeIncludes(schema, "array")) return true;
    return schema.object.get("properties") != null or schema.object.get("items") != null;
}

fn schemaAllowsNull(schema: std.json.Value) bool {
    if (!isJsonSchemaObject(schema)) return false;
    if (schemaTypeIncludes(schema, "null")) return true;
    if (schema.object.get("const")) |const_value| {
        if (const_value == .null) return true;
    }
    if (schema.object.get("enum")) |enum_value| {
        if (enum_value == .array) {
            for (enum_value.array.items) |item| {
                if (item == .null) return true;
            }
        }
    }
    if (schema.object.get("anyOf")) |any_of| {
        if (any_of == .array) {
            for (any_of.array.items) |variant| {
                if (schemaAllowsNull(variant)) return true;
            }
        }
    }
    return false;
}

fn rejectUnsupportedKeys(schema: std.json.ObjectMap) StrictJsonSchemaError!void {
    for (unsupported_keys) |key| {
        if (schema.get(key) != null) return error.UnsupportedStrictJsonSchema;
    }
}

fn makeJsonSchemaNodeStrict(allocator: std.mem.Allocator, schema: *std.json.Value) !void {
    if (!isJsonSchemaObject(schema.*)) return error.UnsupportedStrictJsonSchema;
    try rejectUnsupportedKeys(schema.object);

    if (schema.object.getPtr("anyOf")) |any_of| {
        if (any_of.* != .array or any_of.array.items.len == 0) return error.UnsupportedStrictJsonSchema;
        for (any_of.array.items) |*variant| {
            if (isStructuredSchema(variant.*)) return error.UnsupportedStrictJsonSchema;
            try makeJsonSchemaNodeStrict(allocator, variant);
        }
    }

    if (schema.object.getPtr("items")) |items| {
        if (items.* == .array) return error.UnsupportedStrictJsonSchema;
        try makeJsonSchemaNodeStrict(allocator, items);
    }

    const is_object_schema = schemaTypeIncludes(schema.*, "object");
    if (schema.object.get("properties") != null and !is_object_schema) {
        return error.UnsupportedStrictJsonSchema;
    }
    if (!is_object_schema) return;

    if (schema.object.get("additionalProperties")) |additional| {
        if (additional != .bool or additional.bool != false) return error.UnsupportedStrictJsonSchema;
    }
    if (schema.object.get("properties")) |properties| {
        if (properties != .object) return error.UnsupportedStrictJsonSchema;
    }
    if (schema.object.get("required")) |required| {
        if (required != .array) return error.UnsupportedStrictJsonSchema;
        for (required.array.items) |item| {
            if (item != .string) return error.UnsupportedStrictJsonSchema;
        }
    }

    const properties_value = schema.object.getPtr("properties") orelse blk: {
        const empty = try provider_json.initObject(allocator);
        const key = try allocator.dupe(u8, "properties");
        errdefer allocator.free(key);
        try schema.object.put(allocator, key, .{ .object = empty });
        break :blk schema.object.getPtr("properties").?;
    };
    if (properties_value.* != .object) return error.UnsupportedStrictJsonSchema;

    var required_set = std.StringHashMap(void).init(allocator);
    defer required_set.deinit();
    if (schema.object.get("required")) |required| {
        for (required.array.items) |item| {
            try required_set.put(item.string, {});
        }
    }

    var property_names = std.ArrayList([]const u8).empty;
    defer property_names.deinit(allocator);
    var property_iterator = properties_value.object.iterator();
    while (property_iterator.next()) |entry| {
        try property_names.append(allocator, entry.key_ptr.*);
        if (required_set.contains(entry.key_ptr.*) == false and required_set.count() > 0) {
            // required may list unknown keys; check after collecting names
        }
    }
    var required_iterator = required_set.keyIterator();
    while (required_iterator.next()) |name| {
        if (properties_value.object.get(name.*) == null) return error.UnsupportedStrictJsonSchema;
    }

    var index: usize = 0;
    while (index < property_names.items.len) : (index += 1) {
        const key = property_names.items[index];
        const property = properties_value.object.getPtr(key) orelse continue;
        try makeJsonSchemaNodeStrict(allocator, property);
        if (!required_set.contains(key) and !schemaAllowsNull(property.*)) {
            var any_of = std.json.Array.init(allocator);
            errdefer provider_json.freeValue(allocator, .{ .array = any_of });
            try any_of.append(try provider_json.cloneValue(allocator, property.*));

            var null_object = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = null_object });
            try null_object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "null") });
            try any_of.append(.{ .object = null_object });

            var wrapper = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = wrapper });
            try wrapper.put(allocator, try allocator.dupe(u8, "anyOf"), .{ .array = any_of });
            provider_json.freeValue(allocator, property.*);
            property.* = .{ .object = wrapper };
        }
    }

    if (schema.object.getPtr("required")) |required| {
        provider_json.freeValue(allocator, required.*);
        required.* = try requiredArrayFromNames(allocator, property_names.items);
    } else {
        const key = try allocator.dupe(u8, "required");
        errdefer allocator.free(key);
        try schema.object.put(allocator, key, try requiredArrayFromNames(allocator, property_names.items));
    }

    if (schema.object.getPtr("additionalProperties")) |additional| {
        additional.* = .{ .bool = false };
    } else {
        const key = try allocator.dupe(u8, "additionalProperties");
        errdefer allocator.free(key);
        try schema.object.put(allocator, key, .{ .bool = false });
    }
}

fn requiredArrayFromNames(allocator: std.mem.Allocator, names: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |item| provider_json.freeValue(allocator, item);
        array.deinit();
    }
    for (names) |name| {
        try array.append(.{ .string = try allocator.dupe(u8, name) });
    }
    return .{ .array = array };
}

/// Convert a tool schema to the strict subset expected by provider constrained sampling.
pub fn makeStrictJsonSchema(allocator: std.mem.Allocator, schema: std.json.Value) !std.json.Value {
    var cloned = try provider_json.cloneValue(allocator, schema);
    errdefer provider_json.freeValue(allocator, cloned);
    if (!isJsonSchemaObject(cloned)) return error.UnsupportedStrictJsonSchema;
    try makeJsonSchemaNodeStrict(allocator, &cloned);
    if (!schemaTypeIncludes(cloned, "object")) return error.UnsupportedStrictJsonSchema;
    return cloned;
}

pub fn getJsonSchemaToolParameters(
    allocator: std.mem.Allocator,
    tool: types.Tool,
    strict: bool,
) !std.json.Value {
    if (strict) return makeStrictJsonSchema(allocator, tool.parameters);
    return provider_json.cloneValue(allocator, tool.parameters);
}

test "makeStrictJsonSchema requires optional properties and forbids extras" {
    const allocator = std.testing.allocator;

    var properties = try provider_json.initObject(allocator);
    var city = try provider_json.initObject(allocator);
    try city.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "string") });
    try properties.put(allocator, try allocator.dupe(u8, "city"), .{ .object = city });

    var schema = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = schema });
    try schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = properties });

    const strict = try makeStrictJsonSchema(allocator, .{ .object = schema });
    defer provider_json.freeValue(allocator, strict);

    try std.testing.expectEqual(false, strict.object.get("additionalProperties").?.bool);
    const required = strict.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("city", required.items[0].string);
    const city_schema = strict.object.get("properties").?.object.get("city").?;
    try std.testing.expect(city_schema.object.get("anyOf") != null);
}

test "makeStrictJsonSchema rejects $ref" {
    const allocator = std.testing.allocator;
    var schema = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = schema });
    try schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try schema.put(allocator, try allocator.dupe(u8, "$ref"), .{ .string = try allocator.dupe(u8, "#/defs/x") });
    try std.testing.expectError(error.UnsupportedStrictJsonSchema, makeStrictJsonSchema(allocator, .{ .object = schema }));
}
