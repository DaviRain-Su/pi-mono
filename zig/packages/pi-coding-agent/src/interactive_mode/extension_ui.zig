const std = @import("std");
const extension_registry = @import("../extensions/extension_registry.zig");

pub const WidgetPlacement = enum {
    above_editor,
    below_editor,
};

pub const Widget = struct {
    key: []u8,
    lines: [][]u8,
    placement: WidgetPlacement,

    pub fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        deinitOwnedStringList(allocator, self.lines);
        self.* = undefined;
    }

    pub fn clone(allocator: std.mem.Allocator, source: Widget) !Widget {
        return .{
            .key = try allocator.dupe(u8, source.key),
            .lines = try cloneOwnedStringList(allocator, source.lines),
            .placement = source.placement,
        };
    }
};

const FooterStatusPair = struct {
    key: []const u8,
    value: []const u8,
};

pub fn setFooterStatus(
    allocator: std.mem.Allocator,
    statuses: *std.StringHashMap([]u8),
    key: []const u8,
    text: ?[]const u8,
) !void {
    if (key.len == 0) return;
    if (text) |value| {
        if (value.len == 0) {
            removeFooterStatus(allocator, statuses, key);
            return;
        }
        if (statuses.getEntry(key)) |entry| {
            const next_value = try allocator.dupe(u8, sanitizeSingleLineText(value));
            allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = next_value;
            return;
        }
        try statuses.put(
            try allocator.dupe(u8, key),
            try allocator.dupe(u8, sanitizeSingleLineText(value)),
        );
        return;
    }
    removeFooterStatus(allocator, statuses, key);
}

pub fn removeFooterStatus(
    allocator: std.mem.Allocator,
    statuses: *std.StringHashMap([]u8),
    key: []const u8,
) void {
    if (statuses.fetchRemove(key)) |removed| {
        allocator.free(removed.key);
        allocator.free(removed.value);
    }
}

pub fn clearFooterStatuses(allocator: std.mem.Allocator, statuses: *std.StringHashMap([]u8)) void {
    var iter = statuses.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    statuses.clearRetainingCapacity();
}

pub fn cloneRegistryWidget(
    allocator: std.mem.Allocator,
    widget: extension_registry.WidgetHook,
) !Widget {
    return .{
        .key = try allocator.dupe(u8, widget.key),
        .lines = try cloneWidgetLines(allocator, widget.lines),
        .placement = switch (widget.placement) {
            .above_editor => .above_editor,
            .below_editor => .below_editor,
        },
    };
}

pub fn cloneWidgets(allocator: std.mem.Allocator, widgets: []const Widget) ![]Widget {
    if (widgets.len == 0) return &.{};
    const cloned = try allocator.alloc(Widget, widgets.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*widget| widget.deinit(allocator);
        allocator.free(cloned);
    }
    for (widgets, 0..) |widget, index| {
        cloned[index] = try Widget.clone(allocator, widget);
        initialized += 1;
    }
    return cloned;
}

pub fn cloneFooterStatusesSorted(allocator: std.mem.Allocator, statuses: *const std.StringHashMap([]u8)) ![][]u8 {
    if (statuses.count() == 0) return &.{};
    var pairs = std.ArrayList(FooterStatusPair).empty;
    defer pairs.deinit(allocator);
    var iterator = @constCast(statuses).iterator();
    while (iterator.next()) |entry| {
        try pairs.append(allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* });
    }
    std.mem.sort(FooterStatusPair, pairs.items, {}, struct {
        fn lessThan(_: void, lhs: FooterStatusPair, rhs: FooterStatusPair) bool {
            return std.mem.lessThan(u8, lhs.key, rhs.key);
        }
    }.lessThan);
    var cloned = try allocator.alloc([]u8, pairs.items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }
    for (pairs.items, 0..) |pair, index| {
        cloned[index] = try allocator.dupe(u8, pair.value);
        initialized += 1;
    }
    return cloned;
}

pub fn sanitizeSingleLineText(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}

pub const MAX_WIDGET_LINES: usize = 10;
pub const WIDGET_TRUNCATION_MARKER = "... (widget truncated)";

pub fn cloneWidgetLines(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    if (items.len == 0) return try cloneConstStringList(allocator, &.{""});
    const truncated = items.len > MAX_WIDGET_LINES;
    const line_count = @min(items.len, MAX_WIDGET_LINES) + @as(usize, if (truncated) 1 else 0);
    const cloned = try allocator.alloc([]u8, line_count);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }
    for (items[0..@min(items.len, MAX_WIDGET_LINES)], 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    if (truncated) {
        cloned[initialized] = try allocator.dupe(u8, WIDGET_TRUNCATION_MARKER);
        initialized += 1;
    }
    return cloned;
}

fn cloneOwnedStringList(allocator: std.mem.Allocator, items: []const []u8) ![][]u8 {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc([]u8, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return cloned;
}

fn cloneConstStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    if (items.len == 0) return &.{};
    const cloned = try allocator.alloc([]u8, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }
    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return cloned;
}

fn deinitOwnedStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}
