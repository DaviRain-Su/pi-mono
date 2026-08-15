const std = @import("std");

/// JSON ObjectMap put helpers — duplicate the key and (for strings) the value,
/// so callers can pass borrowed slices safely.
///
/// These were originally added in `tools/common.zig`; they are promoted here so
/// non-tool modules (extensions, sessions, auth, modes) can use them without
/// importing tools/common and creating a cross-layer dependency.
/// `object` may be `*std.json.ObjectMap` or `**std.json.ObjectMap`
/// (callers freely write `&map` even when `map` is already a pointer).
inline fn mapPtr(object: anytype) *std.json.ObjectMap {
    const T = @TypeOf(object);
    const info = @typeInfo(T).pointer;
    return switch (@typeInfo(info.child)) {
        .pointer => object.*,
        else => object,
    };
}

pub fn putString(
    allocator: std.mem.Allocator,
    object: anytype,
    key: []const u8,
    value: []const u8,
) !void {
    try mapPtr(object).put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

pub fn putBool(
    allocator: std.mem.Allocator,
    object: anytype,
    key: []const u8,
    value: bool,
) !void {
    try mapPtr(object).put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

pub fn putInt(
    allocator: std.mem.Allocator,
    object: anytype,
    key: []const u8,
    value: i64,
) !void {
    try mapPtr(object).put(allocator, try allocator.dupe(u8, key), .{ .integer = value });
}

pub fn putFloat(
    allocator: std.mem.Allocator,
    object: anytype,
    key: []const u8,
    value: f64,
) !void {
    try mapPtr(object).put(allocator, try allocator.dupe(u8, key), .{ .float = value });
}

pub fn putNull(
    allocator: std.mem.Allocator,
    object: anytype,
    key: []const u8,
) !void {
    try mapPtr(object).put(allocator, try allocator.dupe(u8, key), .null);
}

pub fn putValue(
    allocator: std.mem.Allocator,
    object: anytype,
    key: []const u8,
    value: std.json.Value,
) !void {
    try mapPtr(object).put(allocator, try allocator.dupe(u8, key), value);
}

test "putString duplicates key and value" {
    var object = try std.json.ObjectMap.init(std.testing.allocator, &.{}, &.{});
    defer {
        const v: std.json.Value = .{ .object = object };
        const Cleanup = struct {
            fn free(alloc: std.mem.Allocator, val: std.json.Value) void {
                switch (val) {
                    .object => |obj_const| {
                        var obj = obj_const;
                        var it = obj.iterator();
                        while (it.next()) |entry| {
                            alloc.free(entry.key_ptr.*);
                            free(alloc, entry.value_ptr.*);
                        }
                        obj.deinit(alloc);
                    },
                    .string => |s| alloc.free(s),
                    else => {},
                }
            }
        };
        Cleanup.free(std.testing.allocator, v);
    }

    try putString(std.testing.allocator, &object, "k", "v");
    try putBool(std.testing.allocator, &object, "b", true);
    try putInt(std.testing.allocator, &object, "n", 42);

    try std.testing.expectEqualStrings("v", object.get("k").?.string);
    try std.testing.expectEqual(true, object.get("b").?.bool);
    try std.testing.expectEqual(@as(i64, 42), object.get("n").?.integer);
}
