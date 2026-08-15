const std = @import("std");

var stdout_taken_over = false;

pub fn takeOverStdout() void {
    stdout_taken_over = true;
}

pub fn restoreStdout() void {
    stdout_taken_over = false;
}

pub fn isStdoutTakenOver() bool {
    return stdout_taken_over;
}

pub fn writeRawStdout(text: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.writeAll(text);
    try stdout_writer.interface.flush();
}

pub fn flushRawStdout() !void {
    var stdout_buffer: [1]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.flush();
}

test "stdout takeover state is tracked" {
    restoreStdout();
    try std.testing.expect(!isStdoutTakenOver());
    takeOverStdout();
    try std.testing.expect(isStdoutTakenOver());
    restoreStdout();
    try std.testing.expect(!isStdoutTakenOver());
}
