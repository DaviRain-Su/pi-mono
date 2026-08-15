const std = @import("std");
const provider_json = @import("provider_json.zig");

/// Inserts `value` under a duplicated copy of `key` as a JSON bool. The duped
/// key is released on `put` failure to avoid a leak.
pub fn putBoolValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    const dup_key = try allocator.dupe(u8, key);
    errdefer allocator.free(dup_key);
    try object.put(allocator, dup_key, .{ .bool = value });
}

/// Inserts `value` under a duplicated copy of `key` as a JSON string. Both the
/// key and the string contents are duplicated into `allocator`; on failure
/// after one or both dupes succeed, the partial allocations are released.
pub fn putStringValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const dup_key = try allocator.dupe(u8, key);
    errdefer allocator.free(dup_key);
    const dup_value = try allocator.dupe(u8, value);
    errdefer allocator.free(dup_value);
    try object.put(allocator, dup_key, .{ .string = dup_value });
}

/// Inserts `value` under a duplicated copy of `key`. The caller transfers
/// ownership of `value` to `object`; if the key dupe or `put` fails the
/// helper frees both the (partially) duped key and the transferred value
/// (via `provider_json.freeValue`) so the caller does not need to track the
/// partial state. The value-free errdefer is registered before the key dupe
/// so an OOM on the key dupe still releases `value`.
pub fn putObjectValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    errdefer provider_json.freeValue(allocator, value);
    const dup_key = try allocator.dupe(u8, key);
    errdefer allocator.free(dup_key);
    try object.put(allocator, dup_key, value);
}

/// Inserts `value` under a duplicated copy of `key` as a JSON integer. `value`
/// can be any integer type that fits via `@intCast` into `i64`.
pub fn putIntegerValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: anytype) !void {
    const dup_key = try allocator.dupe(u8, key);
    errdefer allocator.free(dup_key);
    try object.put(allocator, dup_key, .{ .integer = @intCast(value) });
}

/// Inserts `value` under a duplicated copy of `key` as a JSON float.
pub fn putFloatValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: f64) !void {
    const dup_key = try allocator.dupe(u8, key);
    errdefer allocator.free(dup_key);
    try object.put(allocator, dup_key, .{ .float = value });
}

const testing = std.testing;

test "put helpers leak nothing on success" {
    const allocator = testing.allocator;
    var object = try provider_json.initObject(allocator);
    defer provider_json.freeValue(allocator, .{ .object = object });

    try putBoolValue(allocator, &object, "flag", true);
    try putStringValue(allocator, &object, "name", "alpha");
    try putIntegerValue(allocator, &object, "count", @as(u32, 7));
    try putFloatValue(allocator, &object, "ratio", 0.25);

    var nested = try provider_json.initObject(allocator);
    try putStringValue(allocator, &nested, "kind", "child");
    try putObjectValue(allocator, &object, "nested", .{ .object = nested });

    try testing.expectEqual(true, object.get("flag").?.bool);
    try testing.expectEqualStrings("alpha", object.get("name").?.string);
    try testing.expectEqual(@as(i64, 7), object.get("count").?.integer);
    try testing.expectEqual(@as(f64, 0.25), object.get("ratio").?.float);
    try testing.expectEqualStrings("child", object.get("nested").?.object.get("kind").?.string);
}

test "put helpers release partial allocations on OOM" {
    var fail_index: usize = 0;
    while (fail_index < 24) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();

        var object = provider_json.initObject(failing_allocator) catch continue;
        defer provider_json.freeValue(failing_allocator, .{ .object = object });

        _ = putBoolValue(failing_allocator, &object, "flag", true) catch {};
        _ = putStringValue(failing_allocator, &object, "name", "alpha") catch {};
        _ = putIntegerValue(failing_allocator, &object, "count", @as(u32, 7)) catch {};
        _ = putFloatValue(failing_allocator, &object, "ratio", 0.5) catch {};
    }
}

test "putObjectValue frees transferred value when put fails" {
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();

        var object = provider_json.initObject(failing_allocator) catch continue;
        defer provider_json.freeValue(failing_allocator, .{ .object = object });

        var nested = provider_json.initObject(failing_allocator) catch continue;
        // Try populating; on partial failure the nested object owns its keys.
        _ = putStringValue(failing_allocator, &nested, "kind", "child") catch {};

        // Transfer ownership; if this fails, the helper must free `nested`.
        _ = putObjectValue(failing_allocator, &object, "nested", .{ .object = nested }) catch {};
    }
}
