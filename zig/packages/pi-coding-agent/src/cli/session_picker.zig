pub const SessionPickMode = enum {
    @"resume",
    fork,
};

pub const SessionPickerOptions = struct {
    mode: SessionPickMode,
    session_dir: []const u8,
};

pub fn titleForMode(mode: SessionPickMode) []const u8 {
    return switch (mode) {
        .@"resume" => "Resume session",
        .fork => "Fork session",
    };
}

test "session picker titles match modes" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Fork session", titleForMode(.fork));
}
