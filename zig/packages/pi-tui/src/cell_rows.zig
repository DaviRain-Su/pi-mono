const std = @import("std");
const vaxis = @import("vaxis");

/// Copies plain text rows out of a vaxis screen (either `*vaxis.Screen` or
/// `*vaxis.AllocatingScreen`) into an allocator-owned slice of lines. Duck-typed:
/// any value exposing `height`, `width`, and `readCell(col, row)` works.
pub fn rowsToLinesAlloc(
    allocator: std.mem.Allocator,
    screen: anytype,
    width: usize,
    height: usize,
) std.mem.Allocator.Error![]const []const u8 {
    const row_count = @min(height, @as(usize, screen.height));
    const col_count = @min(width, @as(usize, screen.width));
    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    for (0..row_count) |row| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        for (0..col_count) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (cell.char.grapheme.len == 0) {
                try builder.append(allocator, ' ');
            } else {
                try builder.appendSlice(allocator, cell.char.grapheme);
            }
        }
        try lines.append(allocator, try builder.toOwnedSlice(allocator));
    }
    return lines.toOwnedSlice(allocator);
}

/// Thin wrapper preserved for call-site stability; delegates to `rowsToLinesAlloc`.
pub fn screenRowsToLinesAlloc(
    allocator: std.mem.Allocator,
    screen: *vaxis.Screen,
    width: usize,
    height: usize,
) std.mem.Allocator.Error![]const []const u8 {
    return rowsToLinesAlloc(allocator, screen, width, height);
}

/// Thin wrapper preserved for call-site stability; delegates to `rowsToLinesAlloc`.
pub fn allocatingScreenRowsToLinesAlloc(
    allocator: std.mem.Allocator,
    screen: *vaxis.AllocatingScreen,
    width: usize,
    height: usize,
) std.mem.Allocator.Error![]const []const u8 {
    return rowsToLinesAlloc(allocator, screen, width, height);
}
