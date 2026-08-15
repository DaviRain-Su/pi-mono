const std = @import("std");

/// Creates an empty JSON object map using the provider-owned allocation shape.
pub fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
}

/// Creates an owned empty JSON object value.
pub fn emptyObjectValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try initObject(allocator) };
}

/// Deep-clones a JSON value into `allocator`.
///
/// The returned value owns duplicated strings, number strings, object keys, and
/// nested array/object storage. Release it with `freeValue`.
pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |boolean| .{ .bool = boolean },
        .integer => |integer| .{ .integer = integer },
        .float => |float| .{ .float = float },
        .number_string => |number_string| .{ .number_string = try allocator.dupe(u8, number_string) },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer {
                for (cloned.items) |item| freeValue(allocator, item);
                cloned.deinit();
            }
            for (array.items) |item| {
                {
                    const cloned_item = try cloneValue(allocator, item);
                    errdefer freeValue(allocator, cloned_item);
                    try cloned.append(cloned_item);
                }
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = try initObject(allocator);
            errdefer {
                var iterator = cloned.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeValue(allocator, entry.value_ptr.*);
                }
                cloned.deinit(allocator);
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const cloned_value = try cloneValue(allocator, entry.value_ptr.*);
                    errdefer freeValue(allocator, cloned_value);
                    try cloned.put(allocator, key, cloned_value);
                }
            }
            break :blk .{ .object = cloned };
        },
    };
}

/// Releases values returned by `cloneValue`, `emptyObjectValue`, or builders
/// that use the same owned JSON-value convention.
pub fn freeValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |string| allocator.free(string),
        .number_string => |number_string| allocator.free(number_string),
        .array => |array| {
            for (array.items) |item| freeValue(allocator, item);
            var mutable = array;
            mutable.deinit();
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            var mutable = object;
            mutable.deinit(allocator);
        },
        else => {},
    }
}

test "initObject creates usable owned empty object map" {
    const allocator = std.testing.allocator;
    var object = try initObject(allocator);
    defer freeValue(allocator, .{ .object = object });

    try object.put(allocator, try allocator.dupe(u8, "ok"), .{ .bool = true });
    try std.testing.expectEqual(@as(u32, 1), object.count());
    try std.testing.expectEqual(true, object.get("ok").?.bool);
}
