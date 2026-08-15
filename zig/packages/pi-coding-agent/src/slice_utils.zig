const std = @import("std");

/// Frees a slice of allocator-owned slices, including the outer slice.
/// Accepts `[]const []const u8`, `[][]u8`, `[]const []u8`, etc., so the same
/// helper replaces several near-identical `freeStringList` / `freeStringArray`
/// copies that lived per-module before.
pub fn freeStringSlice(allocator: std.mem.Allocator, items: anytype) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

/// Optional variant: a no-op if the slice is null. Also accepts non-optional
/// slices for symmetry with `freeStringSlice`.
pub fn freeOptionalStringSlice(allocator: std.mem.Allocator, items: anytype) void {
    const T = @TypeOf(items);
    if (@typeInfo(T) == .optional) {
        const list = items orelse return;
        freeStringSlice(allocator, list);
    } else {
        freeStringSlice(allocator, items);
    }
}

test "freeStringSlice releases owned buffers" {
    const allocator = std.testing.allocator;
    var slice = try allocator.alloc([]u8, 2);
    slice[0] = try allocator.dupe(u8, "alpha");
    slice[1] = try allocator.dupe(u8, "beta");
    freeStringSlice(allocator, slice);
}

test "freeOptionalStringSlice handles null" {
    freeOptionalStringSlice(std.testing.allocator, @as(?[]const []const u8, null));
}

test "freeOptionalStringSlice frees when present" {
    const allocator = std.testing.allocator;
    var slice = try allocator.alloc([]const u8, 1);
    slice[0] = try allocator.dupe(u8, "x");
    freeOptionalStringSlice(allocator, @as(?[]const []const u8, slice));
}
