const std = @import("std");
const tui = @import("tui");

/// Frees previously-allocated table cells and rows if non-empty.
/// Safe to call when nothing has been allocated yet.
pub fn freeTable(allocator: std.mem.Allocator, cells: []tui.TableCell, rows: []tui.TableRow) void {
    if (cells.len > 0) allocator.free(cells);
    if (rows.len > 0) allocator.free(rows);
}

/// Frees an owned slice of SelectItems, including each item's value/label/description strings.
pub fn freeOwnedSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.value));
        allocator.free(@constCast(item.label));
        if (item.description) |description| allocator.free(@constCast(description));
    }
    allocator.free(items);
}

/// Frees an owned slice of allocated strings (alias for slice_utils.freeStringSlice).
pub const freeOwnedStrings = @import("../slice_utils.zig").freeStringSlice;

/// Allocates a 2-column [label, description] table from select items.
/// Cell text borrows directly from items; do not free items before the table.
pub fn buildLabelDescriptionTable(
    allocator: std.mem.Allocator,
    items: []const tui.SelectItem,
) !struct { cells: []tui.TableCell, rows: []tui.TableRow } {
    const cells = try allocator.alloc(tui.TableCell, items.len * 2);
    errdefer allocator.free(cells);
    const rows = try allocator.alloc(tui.TableRow, items.len);
    errdefer allocator.free(rows);

    for (items, 0..) |item, i| {
        cells[i * 2] = .{ .text = item.label };
        cells[i * 2 + 1] = .{ .text = item.description orelse "" };
        rows[i] = .{ .cells = cells[i * 2 .. i * 2 + 2] };
    }

    return .{ .cells = cells, .rows = rows };
}

test "freeTable handles empty slices" {
    freeTable(std.testing.allocator, &.{}, &.{});
}

test "freeOwnedStrings releases entries and slice" {
    const allocator = std.testing.allocator;
    var strings = try allocator.alloc([]u8, 2);
    strings[0] = try allocator.dupe(u8, "hello");
    strings[1] = try allocator.dupe(u8, "world");
    freeOwnedStrings(allocator, strings);
}

test "buildLabelDescriptionTable maps items to two-column rows" {
    const items = [_]tui.SelectItem{
        .{ .value = "a", .label = "Alpha", .description = "first" },
        .{ .value = "b", .label = "Beta", .description = null },
    };
    const built = try buildLabelDescriptionTable(std.testing.allocator, &items);
    defer freeTable(std.testing.allocator, built.cells, built.rows);

    try std.testing.expectEqual(@as(usize, 4), built.cells.len);
    try std.testing.expectEqual(@as(usize, 2), built.rows.len);
    try std.testing.expectEqualStrings("Alpha", built.cells[0].text);
    try std.testing.expectEqualStrings("first", built.cells[1].text);
    try std.testing.expectEqualStrings("Beta", built.cells[2].text);
    try std.testing.expectEqualStrings("", built.cells[3].text);
    try std.testing.expectEqual(@as(usize, 2), built.rows[1].cells.len);
}
