const std = @import("std");
const provider_json = @import("provider_json.zig");

pub fn stringEnum(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    description: ?[]const u8,
    default_value: ?[]const u8,
) !std.json.Value {
    var object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = object });

    try putOwnedValue(allocator, &object, "type", .{ .string = try allocator.dupe(u8, "string") });

    var enum_values = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = enum_values });
    for (values) |value| {
        try appendOwnedValue(allocator, &enum_values, .{ .string = try allocator.dupe(u8, value) });
    }
    try putOwnedValue(allocator, &object, "enum", .{ .array = enum_values });

    if (description) |text| {
        try putOwnedValue(allocator, &object, "description", .{ .string = try allocator.dupe(u8, text) });
    }
    if (default_value) |value| {
        try putOwnedValue(allocator, &object, "default", .{ .string = try allocator.dupe(u8, value) });
    }

    return .{ .object = object };
}

fn putOwnedValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    errdefer provider_json.freeValue(allocator, value);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try object.put(allocator, owned_key, value);
}

fn appendOwnedValue(allocator: std.mem.Allocator, array: *std.json.Array, value: std.json.Value) !void {
    errdefer provider_json.freeValue(allocator, value);
    try array.append(value);
}

test "stringEnum creates provider-compatible enum schema" {
    const allocator = std.testing.allocator;
    const schema = try stringEnum(allocator, &[_][]const u8{ "add", "subtract" }, "operation", "add");
    defer provider_json.freeValue(allocator, schema);

    try std.testing.expectEqualStrings("string", schema.object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 2), schema.object.get("enum").?.array.items.len);
    try std.testing.expectEqualStrings("operation", schema.object.get("description").?.string);
    try std.testing.expectEqualStrings("add", schema.object.get("default").?.string);
}
