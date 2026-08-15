const std = @import("std");

const windows_shell_commands = [_][]const u8{ "npm", "npx", "pnpm", "yarn", "yarnpkg", "corepack" };

pub fn shouldUseWindowsShell(command: []const u8, is_windows: bool) bool {
    if (!is_windows) return false;
    const base = std.fs.path.basename(command);
    var lower_buf: [256]u8 = undefined;
    const lower = if (base.len <= lower_buf.len) blk: {
        const out = lower_buf[0..base.len];
        for (base, 0..) |byte, index| out[index] = std.ascii.toLower(byte);
        break :blk out;
    } else base;
    if (std.mem.endsWith(u8, lower, ".cmd") or std.mem.endsWith(u8, lower, ".bat")) return true;
    for (windows_shell_commands) |name| {
        if (std.mem.eql(u8, lower, name)) return true;
    }
    return false;
}

test "child process detects windows shell commands" {
    try std.testing.expect(shouldUseWindowsShell("npm", true));
    try std.testing.expect(shouldUseWindowsShell("tool.cmd", true));
    try std.testing.expect(!shouldUseWindowsShell("npm", false));
}
