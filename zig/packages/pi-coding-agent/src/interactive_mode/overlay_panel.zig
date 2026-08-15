const std = @import("std");
const tui = @import("tui");

pub fn maxHeight(height: usize) usize {
    return if (height > 4) height - 4 else @max(height, 3);
}

pub fn width(available_width: usize) usize {
    if (available_width <= 24) return @max(available_width -| 2, 12);
    return std.math.clamp((available_width * 2) / 3, @as(usize, 24), @min(available_width -| 2, @as(usize, 96)));
}

pub fn animationProgress(now_ms: i64, opened_at_ms: ?i64) f32 {
    const opened = opened_at_ms orelse return 1.0;
    const elapsed_ms = @max(now_ms - opened, 0);
    const duration_ms: f32 = 140.0;
    const progress = @as(f32, @floatFromInt(elapsed_ms)) / duration_ms;
    return std.math.clamp(progress, 0.0, 1.0);
}

pub fn nowMilliseconds() i64 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(now.usec)), std.time.us_per_ms);
}

pub fn options(size: tui.Size, progress: f32) tui.OverlayOptions {
    return .{
        .width = width(size.width),
        .max_height = maxHeight(size.height),
        .anchor = .center,
        .margin = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .animation = .{
            .kind = .slide_from_top,
            .progress = progress,
        },
    };
}
