const std = @import("std");

pub const FS_WATCH_RETRY_DELAY_MS: u64 = 5000;
const WATCH_POLL_DELAY_NS: u64 = 250 * std.time.ns_per_ms;

pub const WatchEvent = enum {
    change,
    rename,
};

pub const WatchListener = *const fn (ctx: ?*anyopaque, event: WatchEvent, path: []const u8) void;
pub const ErrorHandler = *const fn (ctx: ?*anyopaque) void;

pub const FSWatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    listener: WatchListener,
    listener_ctx: ?*anyopaque,
    on_error: ErrorHandler,
    error_ctx: ?*anyopaque,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn close(self: *FSWatcher) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

const StatSnapshot = struct {
    exists: bool,
    mtime: std.Io.Timestamp = .zero,
    size: u64 = 0,

    fn eql(left: StatSnapshot, right: StatSnapshot) bool {
        return left.exists == right.exists and
            left.mtime.nanoseconds == right.mtime.nanoseconds and
            left.size == right.size;
    }
};

pub fn closeWatcher(watcher: ?*FSWatcher) void {
    if (watcher) |value| value.close();
}

pub fn watchWithErrorHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    listener: WatchListener,
    listener_ctx: ?*anyopaque,
    on_error: ErrorHandler,
    error_ctx: ?*anyopaque,
) ?*FSWatcher {
    const initial = snapshot(io, path) catch {
        on_error(error_ctx);
        return null;
    };
    if (!initial.exists) {
        on_error(error_ctx);
        return null;
    }

    const watcher = allocator.create(FSWatcher) catch {
        on_error(error_ctx);
        return null;
    };
    watcher.* = .{
        .allocator = allocator,
        .io = io,
        .path = allocator.dupe(u8, path) catch {
            allocator.destroy(watcher);
            on_error(error_ctx);
            return null;
        },
        .listener = listener,
        .listener_ctx = listener_ctx,
        .on_error = on_error,
        .error_ctx = error_ctx,
    };
    watcher.thread = std.Thread.spawn(.{}, watcherMain, .{watcher}) catch {
        allocator.free(watcher.path);
        allocator.destroy(watcher);
        on_error(error_ctx);
        return null;
    };
    return watcher;
}

fn watcherMain(watcher: *FSWatcher) void {
    var previous = snapshot(watcher.io, watcher.path) catch {
        watcher.on_error(watcher.error_ctx);
        return;
    };

    while (!watcher.stop.load(.acquire)) {
        std.Io.sleep(watcher.io, .fromNanoseconds(@intCast(WATCH_POLL_DELAY_NS)), .awake) catch return;
        const current = snapshot(watcher.io, watcher.path) catch {
            watcher.on_error(watcher.error_ctx);
            return;
        };
        if (!previous.eql(current)) {
            const event: WatchEvent = if (previous.exists == current.exists) .change else .rename;
            watcher.listener(watcher.listener_ctx, event, watcher.path);
            previous = current;
        }
    }
}

fn snapshot(io: std.Io, path: []const u8) !StatSnapshot {
    const stat = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .exists = false },
        else => return err,
    };
    return .{
        .exists = true,
        .mtime = stat.mtime,
        .size = stat.size,
    };
}

fn testListener(ctx: ?*anyopaque, _: WatchEvent, _: []const u8) void {
    const count: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx.?));
    _ = count.fetchAdd(1, .monotonic);
}

fn testError(ctx: ?*anyopaque) void {
    const count: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx.?));
    _ = count.fetchAdd(1, .monotonic);
}

test "watchWithErrorHandler returns null and calls error handler for missing parent" {
    var errors = std.atomic.Value(usize).init(0);
    const watcher = watchWithErrorHandler(
        std.testing.allocator,
        std.testing.io,
        "/definitely/missing/pi-watch-target",
        testListener,
        null,
        testError,
        &errors,
    );
    try std.testing.expectEqual(null, watcher);
    try std.testing.expectEqual(@as(usize, 1), errors.load(.monotonic));
}
