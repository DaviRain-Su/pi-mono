const std = @import("std");
const extension_runtime = @import("../../extensions/extension_runtime.zig");

pub const RuntimeAdapter = extension_runtime.RuntimeAdapter;

pub const ExtensionRunnerContext = struct {
    allocator: std.mem.Allocator,
};

pub const ExtensionRunner = struct {
    allocator: std.mem.Allocator,
    runtime: ?*RuntimeAdapter = null,

    pub fn init(allocator: std.mem.Allocator, runtime: ?*RuntimeAdapter) ExtensionRunner {
        return .{ .allocator = allocator, .runtime = runtime };
    }

    pub fn createContext(self: *ExtensionRunner) ExtensionRunnerContext {
        return .{ .allocator = self.allocator };
    }
};

test "extension runner creates tool context" {
    var runner = ExtensionRunner.init(std.testing.allocator, null);
    const context = runner.createContext();
    try std.testing.expectEqual(std.testing.allocator, context.allocator);
}
