const std = @import("std");

pub const KillRing = struct {
    allocator: std.mem.Allocator,
    ring: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) KillRing {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KillRing) void {
        for (self.ring.items) |entry| self.allocator.free(entry);
        self.ring.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *KillRing, text: []const u8, opts: PushOptions) !void {
        if (text.len == 0) return;

        if (opts.accumulate and self.ring.items.len > 0) {
            const last = self.ring.pop().?;
            defer self.allocator.free(last);

            const combined = if (opts.prepend)
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ text, last })
            else
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ last, text });
            try self.ring.append(self.allocator, combined);
            return;
        }

        try self.ring.append(self.allocator, try self.allocator.dupe(u8, text));
    }

    pub fn peek(self: *const KillRing) ?[]const u8 {
        if (self.ring.items.len == 0) return null;
        return self.ring.items[self.ring.items.len - 1];
    }

    pub fn rotate(self: *KillRing) !void {
        if (self.ring.items.len <= 1) return;
        const last = self.ring.pop().?;
        try self.ring.insert(self.allocator, 0, last);
    }

    pub fn len(self: *const KillRing) usize {
        return self.ring.items.len;
    }
};

pub const PushOptions = struct {
    prepend: bool,
    accumulate: bool = false,
};

test "KillRing accumulates and rotates entries" {
    var ring = KillRing.init(std.testing.allocator);
    defer ring.deinit();

    try ring.push("a", .{ .prepend = false });
    try ring.push("b", .{ .prepend = false, .accumulate = true });
    try std.testing.expectEqualStrings("ab", ring.peek().?);
    try ring.push("c", .{ .prepend = false });
    try std.testing.expectEqual(@as(usize, 2), ring.len());
    try ring.rotate();
    try std.testing.expectEqualStrings("ab", ring.peek().?);
}
