const std = @import("std");
const ai = @import("ai");
const clipboard_image = @import("clipboard_image.zig");

const PROGRESS_MIN_MS: i64 = 120;

pub const Result = union(enum) {
    none,
    success: ai.ImageContent,
    empty,
    unsupported,
    failure,
};

pub const ClipboardPasteTask = struct {
    io: std.Io,
    env_map: ?*const std.process.Environ.Map = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result_mutex: std.Io.Mutex = .init,
    result: Result = .none,
    started_at_ms: i64 = 0,

    pub fn start(self: *ClipboardPasteTask, env_map: *const std.process.Environ.Map) !bool {
        if (self.thread != null) return false;
        self.env_map = env_map;
        self.started_at_ms = nowMilliseconds();
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return true;
    }

    pub fn poll(self: *ClipboardPasteTask) ?Result {
        if (self.thread == null) return null;
        if (self.running.load(.seq_cst)) return null;
        if (nowMilliseconds() - self.started_at_ms < PROGRESS_MIN_MS) return null;

        if (self.thread) |thread| thread.join();
        self.thread = null;

        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);

        const result = self.result;
        self.result = .none;
        return result;
    }

    pub fn isActive(self: *const ClipboardPasteTask) bool {
        return self.thread != null;
    }

    pub fn deinit(self: *ClipboardPasteTask) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.running.store(false, .seq_cst);

        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        deinitResult(&self.result);
        self.result = .none;
    }

    fn run(self: *ClipboardPasteTask) void {
        defer self.running.store(false, .seq_cst);

        const allocator = std.heap.page_allocator;
        const env_map = self.env_map orelse {
            self.storeResult(.failure);
            return;
        };

        const read_result = clipboard_image.readClipboardImage(allocator, self.io, env_map) catch {
            self.storeResult(.failure);
            return;
        };
        switch (read_result) {
            .image => |raw_image| {
                var image = raw_image;
                defer image.deinit(allocator);

                const encoded = clipboard_image.encodeImageContent(allocator, image) catch {
                    self.storeResult(.failure);
                    return;
                };
                self.storeResult(.{ .success = encoded });
            },
            .unsupported => self.storeResult(.unsupported),
            .none => self.storeResult(.empty),
        }
    }

    fn storeResult(self: *ClipboardPasteTask, result: Result) void {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        deinitResult(&self.result);
        self.result = result;
    }
};

pub fn deinitResult(result: *Result) void {
    switch (result.*) {
        .success => |*image| clipboard_image.deinitImageContent(std.heap.page_allocator, image),
        else => {},
    }
    result.* = .none;
}

fn nowMilliseconds() i64 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(now.usec)), std.time.us_per_ms);
}
