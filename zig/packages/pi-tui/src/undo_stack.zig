const std = @import("std");

pub fn UndoStack(comptime State: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        stack: std.ArrayList(State) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn push(self: *Self, state: State) !void {
            try self.stack.append(self.allocator, state);
        }

        pub fn pushClone(self: *Self, state: State, cloneFn: *const fn (std.mem.Allocator, State) anyerror!State) !void {
            try self.stack.append(self.allocator, try cloneFn(self.allocator, state));
        }

        pub fn pop(self: *Self) ?State {
            return self.stack.pop();
        }

        pub fn clear(self: *Self) void {
            self.stack.clearRetainingCapacity();
        }

        pub fn len(self: *const Self) usize {
            return self.stack.items.len;
        }
    };
}

test "UndoStack pushes and pops snapshots" {
    var stack = UndoStack(usize).init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(1);
    try stack.push(2);
    try std.testing.expectEqual(@as(usize, 2), stack.len());
    try std.testing.expectEqual(@as(usize, 2), stack.pop().?);
    stack.clear();
    try std.testing.expectEqual(@as(usize, 0), stack.len());
}
