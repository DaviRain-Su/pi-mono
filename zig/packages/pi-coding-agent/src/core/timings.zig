const std = @import("std");

pub const TimingEntry = struct {
    label: []const u8,
    ms: i64,
};

pub const StartupTimings = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    entries: std.ArrayList(TimingEntry) = .empty,
    owned_labels: std.ArrayList([]u8) = .empty,
    last_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, enabled: bool) StartupTimings {
        return .{ .allocator = allocator, .enabled = enabled, .last_ms = nowMs() };
    }

    pub fn initFromEnv(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) StartupTimings {
        const enabled = if (env_map.get("PI_TIMING")) |value| std.mem.eql(u8, value, "1") else false;
        return init(allocator, enabled);
    }

    pub fn deinit(self: *StartupTimings) void {
        for (self.owned_labels.items) |label| self.allocator.free(label);
        self.owned_labels.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *StartupTimings) void {
        if (!self.enabled) return;
        self.entries.clearRetainingCapacity();
        self.last_ms = nowMs();
    }

    pub fn time(self: *StartupTimings, label: []const u8) !void {
        if (!self.enabled) return;
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const current = nowMs();
        try self.owned_labels.append(self.allocator, owned_label);
        try self.entries.append(self.allocator, .{ .label = owned_label, .ms = current - self.last_ms });
        self.last_ms = current;
    }

    pub fn totalMs(self: *const StartupTimings) i64 {
        var total: i64 = 0;
        for (self.entries.items) |entry| total += entry.ms;
        return total;
    }

    pub fn write(self: *const StartupTimings, writer: *std.Io.Writer) !void {
        if (!self.enabled or self.entries.items.len == 0) return;
        try writer.writeAll("\n--- Startup Timings ---\n");
        for (self.entries.items) |entry| try writer.print("  {s}: {d}ms\n", .{ entry.label, entry.ms });
        try writer.print("  TOTAL: {d}ms\n", .{self.totalMs()});
        try writer.writeAll("------------------------\n\n");
    }
};

fn nowMs() i64 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(now.usec)), std.time.us_per_ms);
}

test "timings collect entries only when enabled" {
    var timings = StartupTimings.init(std.testing.allocator, true);
    defer timings.deinit();
    try timings.time("init");
    try std.testing.expectEqual(@as(usize, 1), timings.entries.items.len);
}
