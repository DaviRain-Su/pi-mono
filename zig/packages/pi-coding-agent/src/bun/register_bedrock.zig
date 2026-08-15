pub const registered = true;

test "bedrock registration facade is available" {
    const std = @import("std");
    try std.testing.expect(registered);
}
