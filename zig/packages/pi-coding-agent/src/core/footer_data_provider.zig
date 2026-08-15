const std = @import("std");

pub const ExtensionStatus = struct {
    key: []const u8,
    text: []const u8,
};

pub const FooterDataProvider = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    available_provider_count: usize = 0,
    extension_statuses: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, cwd: []const u8) FooterDataProvider {
        return .{
            .allocator = allocator,
            .cwd = cwd,
            .extension_statuses = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FooterDataProvider) void {
        self.extension_statuses.deinit();
        self.* = undefined;
    }

    pub fn getGitBranch(self: FooterDataProvider) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn setExtensionStatus(self: *FooterDataProvider, key: []const u8, text: ?[]const u8) !void {
        if (text) |value| {
            try self.extension_statuses.put(key, value);
        } else {
            _ = self.extension_statuses.remove(key);
        }
    }

    pub fn clearExtensionStatuses(self: *FooterDataProvider) void {
        self.extension_statuses.clearRetainingCapacity();
    }

    pub fn getAvailableProviderCount(self: FooterDataProvider) usize {
        return self.available_provider_count;
    }

    pub fn setAvailableProviderCount(self: *FooterDataProvider, count: usize) void {
        self.available_provider_count = count;
    }

    pub fn setCwd(self: *FooterDataProvider, cwd: []const u8) void {
        self.cwd = cwd;
    }
};

test "footer data provider tracks provider count" {
    var provider = FooterDataProvider.init(std.testing.allocator, ".");
    defer provider.deinit();
    provider.setAvailableProviderCount(2);
    try std.testing.expectEqual(@as(usize, 2), provider.getAvailableProviderCount());
}
