const std = @import("std");

pub fn isSandboxEnvKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "AWS_PROFILE") or
        std.mem.eql(u8, key, "AWS_REGION") or
        std.mem.startsWith(u8, key, "AWS_");
}

test "restore sandbox env recognizes AWS keys" {
    try std.testing.expect(isSandboxEnvKey("AWS_REGION"));
}
