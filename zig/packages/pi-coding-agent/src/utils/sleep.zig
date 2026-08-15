const std = @import("std");

pub fn sleep(io: std.Io, ms: i64, signal: ?*const std.atomic.Value(bool)) !void {
    if (signal) |abort_signal| {
        if (abort_signal.load(.seq_cst)) return error.Aborted;
    }
    var remaining = ms;
    while (remaining > 0) {
        if (signal) |abort_signal| {
            if (abort_signal.load(.seq_cst)) return error.Aborted;
        }
        const chunk = @min(remaining, 25);
        try std.Io.sleep(io, .fromMilliseconds(chunk), .awake);
        remaining -= chunk;
    }
}

test "sleep returns aborted before waiting" {
    var signal = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Aborted, sleep(std.testing.io, 1, &signal));
}
