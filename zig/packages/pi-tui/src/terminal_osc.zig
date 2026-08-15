const std = @import("std");

pub fn osc9_4Progress(active: bool) []const u8 {
    return if (active) "\x1b]9;4;3\x07" else "\x1b]9;4;0;\x07";
}

pub fn osc133PromptStart() []const u8 {
    return "\x1b]133;A\x07";
}

pub fn osc133PromptEnd() []const u8 {
    return "\x1b]133;B\x07";
}

pub fn osc133CommandStart() []const u8 {
    return "\x1b]133;C\x07";
}

pub fn osc133CommandDone(status: u8) []const u8 {
    return switch (status) {
        0 => "\x1b]133;D;0\x07",
        1 => "\x1b]133;D;1\x07",
        else => "\x1b]133;D;1\x07",
    };
}

pub fn osc777NotifyAlloc(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "\x1b]777;notify;{s};{s}\x07", .{ title, body });
}

pub fn windowTitleAlloc(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "\x1b]0;{s}\x07", .{title});
}

test "osc9_4Progress returns active and cleared sequences" {
    try std.testing.expectEqualStrings("\x1b]9;4;3\x07", osc9_4Progress(true));
    try std.testing.expectEqualStrings("\x1b]9;4;0;\x07", osc9_4Progress(false));
}

test "osc133 helpers emit shell integration markers" {
    try std.testing.expectEqualStrings("\x1b]133;A\x07", osc133PromptStart());
    try std.testing.expectEqualStrings("\x1b]133;B\x07", osc133PromptEnd());
    try std.testing.expectEqualStrings("\x1b]133;C\x07", osc133CommandStart());
    try std.testing.expectEqualStrings("\x1b]133;D;0\x07", osc133CommandDone(0));
    try std.testing.expectEqualStrings("\x1b]133;D;1\x07", osc133CommandDone(1));
}

test "osc777NotifyAlloc formats Ghostty notification sequence" {
    const value = try osc777NotifyAlloc(std.testing.allocator, "pi", "done");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("\x1b]777;notify;pi;done\x07", value);
}
