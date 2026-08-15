const std = @import("std");
const common = @import("../tools/common.zig");

pub const EventHandler = *const fn (context: ?*anyopaque, data: std.json.Value) anyerror!void;

const HandlerEntry = struct {
    channel: []u8,
    handler: EventHandler,
    context: ?*anyopaque = null,
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayList(HandlerEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventBus) void {
        self.clear();
        self.handlers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn on(self: *EventBus, channel: []const u8, context: ?*anyopaque, handler: EventHandler) !void {
        try self.handlers.append(self.allocator, .{
            .channel = try self.allocator.dupe(u8, channel),
            .handler = handler,
            .context = context,
        });
    }

    pub fn off(self: *EventBus, channel: []const u8, handler: EventHandler) void {
        var index: usize = self.handlers.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.handlers.items[index];
            if (std.mem.eql(u8, entry.channel, channel) and entry.handler == handler) {
                self.allocator.free(entry.channel);
                _ = self.handlers.orderedRemove(index);
            }
        }
    }

    pub fn emit(self: *EventBus, channel: []const u8, data: std.json.Value) void {
        for (self.handlers.items) |entry| {
            if (!std.mem.eql(u8, entry.channel, channel)) continue;
            entry.handler(entry.context, data) catch {};
        }
    }

    pub fn emitOwned(self: *EventBus, channel: []const u8, data: std.json.Value) void {
        defer common.deinitJsonValue(self.allocator, data);
        self.emit(channel, data);
    }

    pub fn clear(self: *EventBus) void {
        for (self.handlers.items) |entry| {
            self.allocator.free(entry.channel);
        }
        self.handlers.clearRetainingCapacity();
    }
};

pub fn createEventBus(allocator: std.mem.Allocator) EventBus {
    return EventBus.init(allocator);
}

test "event bus emits and unsubscribes channel handlers" {
    const Handler = struct {
        fn onEvent(context: ?*anyopaque, data: std.json.Value) !void {
            const seen: *usize = @ptrCast(@alignCast(context.?));
            if (data == .integer) seen.* += @intCast(data.integer);
        }
    };
    var bus = createEventBus(std.testing.allocator);
    defer bus.deinit();
    var seen: usize = 0;
    try bus.on("x", &seen, Handler.onEvent);
    bus.emit("x", .{ .integer = 2 });
    try std.testing.expectEqual(@as(usize, 2), seen);
    bus.off("x", Handler.onEvent);
    bus.emit("x", .{ .integer = 2 });
    try std.testing.expectEqual(@as(usize, 2), seen);
}
