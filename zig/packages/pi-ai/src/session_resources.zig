const std = @import("std");

pub const SessionResourceCleanup = *const fn (session_id: ?[]const u8) anyerror!void;

var cleanups: std.ArrayList(SessionResourceCleanup) = .empty;
var initialized = false;

fn ensureInit() void {
    if (initialized) return;
    cleanups = .empty;
    initialized = true;
}

pub fn registerSessionResourceCleanup(cleanup: SessionResourceCleanup) !void {
    ensureInit();
    for (cleanups.items) |existing| {
        if (existing == cleanup) return;
    }
    try cleanups.append(std.heap.page_allocator, cleanup);
}

pub fn unregisterSessionResourceCleanup(cleanup: SessionResourceCleanup) void {
    ensureInit();
    for (cleanups.items, 0..) |existing, index| {
        if (existing == cleanup) {
            _ = cleanups.orderedRemove(index);
            return;
        }
    }
}

pub fn cleanupSessionResources(session_id: ?[]const u8) !void {
    ensureInit();
    var first_error: ?anyerror = null;
    for (cleanups.items) |cleanup| {
        cleanup(session_id) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

pub fn resetForTesting() void {
    if (initialized) cleanups.deinit(std.heap.page_allocator);
    cleanups = .empty;
    initialized = false;
}

var cleanup_call_count: usize = 0;

fn fixtureCleanup(session_id: ?[]const u8) !void {
    if (session_id) |id| try std.testing.expectEqualStrings("session-1", id);
    cleanup_call_count += 1;
}

test "session resource cleanup registry runs and unregisters callbacks" {
    resetForTesting();
    defer resetForTesting();
    cleanup_call_count = 0;

    try registerSessionResourceCleanup(fixtureCleanup);
    try cleanupSessionResources("session-1");
    try std.testing.expectEqual(@as(usize, 1), cleanup_call_count);

    unregisterSessionResourceCleanup(fixtureCleanup);
    try cleanupSessionResources("session-1");
    try std.testing.expectEqual(@as(usize, 1), cleanup_call_count);
}
