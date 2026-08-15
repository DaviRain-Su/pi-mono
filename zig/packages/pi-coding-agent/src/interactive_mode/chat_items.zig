const std = @import("std");

pub const ChatKind = enum {
    welcome,
    info,
    @"error",
    markdown,
    user,
    assistant,
    thinking,
    tool_call,
    tool_result,
    bash_execution,
};

pub const ChatItem = struct {
    kind: ChatKind,
    text: []u8,
    expanded_text: ?[]u8 = null,
    start_ms: ?i64 = null,
    frozen_frame_index: ?usize = null,
};

pub fn clone(allocator: std.mem.Allocator, items: []const ChatItem) ![]ChatItem {
    const cloned = try allocator.alloc(ChatItem, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*item| deinit(allocator, item);
        allocator.free(cloned);
    }

    for (items, 0..) |item, index| {
        const expanded_text = if (item.expanded_text) |value| try allocator.dupe(u8, value) else null;
        errdefer if (expanded_text) |value| allocator.free(value);
        cloned[index] = .{
            .kind = item.kind,
            .text = try allocator.dupe(u8, item.text),
            .expanded_text = expanded_text,
            .start_ms = item.start_ms,
            .frozen_frame_index = item.frozen_frame_index,
        };
        initialized += 1;
    }
    return cloned;
}

pub fn deinit(allocator: std.mem.Allocator, item: *ChatItem) void {
    allocator.free(item.text);
    if (item.expanded_text) |expanded_text| allocator.free(expanded_text);
    item.* = undefined;
}
