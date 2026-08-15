const std = @import("std");
const json = @import("pi-types").json;

pub const initObject = json.initObject;
pub const emptyObjectValue = json.emptyObjectValue;
pub const cloneValue = json.cloneValue;
pub const freeValue = json.freeValue;

test "initObject creates usable owned empty object map" {
    const allocator = std.testing.allocator;
    var object = try initObject(allocator);
    defer freeValue(allocator, .{ .object = object });

    try object.put(allocator, try allocator.dupe(u8, "ok"), .{ .bool = true });
    try std.testing.expectEqual(@as(u32, 1), object.count());
    try std.testing.expectEqual(true, object.get("ok").?.bool);
}

test "cloneValue deep-clones provider-owned JSON values" {
    const allocator = std.testing.allocator;

    var original_object = try initObject(allocator);
    defer freeValue(allocator, .{ .object = original_object });

    try original_object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, "alpha") });
    try original_object.put(allocator, try allocator.dupe(u8, "number"), .{ .number_string = try allocator.dupe(u8, "12.34") });

    var nested_object = try initObject(allocator);
    try nested_object.put(allocator, try allocator.dupe(u8, "flag"), .{ .bool = true });

    var array = std.json.Array.init(allocator);
    errdefer {
        for (array.items) |item| freeValue(allocator, item);
        array.deinit();
    }
    try array.append(.{ .integer = 42 });
    try array.append(.{ .object = nested_object });
    try original_object.put(allocator, try allocator.dupe(u8, "array"), .{ .array = array });

    var cloned = try cloneValue(allocator, .{ .object = original_object });
    defer freeValue(allocator, cloned);

    try std.testing.expect(cloned == .object);
    try std.testing.expectEqualStrings("alpha", cloned.object.get("text").?.string);
    try std.testing.expectEqualStrings("12.34", cloned.object.get("number").?.number_string);
    try std.testing.expectEqual(@as(i64, 42), cloned.object.get("array").?.array.items[0].integer);
    try std.testing.expectEqual(true, cloned.object.get("array").?.array.items[1].object.get("flag").?.bool);

    try std.testing.expect(cloned.object.get("text").?.string.ptr != original_object.get("text").?.string.ptr);
    try std.testing.expect(cloned.object.get("array").?.array.items.ptr != original_object.get("array").?.array.items.ptr);
}

test "cloneValue releases cloned array item when append fails" {
    const allocator = std.testing.allocator;

    var original_array = std.json.Array.init(allocator);
    defer freeValue(allocator, .{ .array = original_array });

    try original_array.append(.{ .string = try allocator.dupe(u8, "alpha") });
    try original_array.append(.{ .string = try allocator.dupe(u8, "beta") });

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();

        if (cloneValue(failing_allocator, .{ .array = original_array })) |cloned| {
            freeValue(failing_allocator, cloned);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
}
