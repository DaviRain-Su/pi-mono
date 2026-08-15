const std = @import("std");

pub fn shortHash(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;
    for (input) |byte| {
        h1 = (h1 ^ @as(u32, byte)) *% 2654435761;
        h2 = (h2 ^ @as(u32, byte)) *% 1597334677;
    }
    h1 = ((h1 ^ (h1 >> 16)) *% 2246822507) ^ ((h2 ^ (h2 >> 13)) *% 3266489909);
    h2 = ((h2 ^ (h2 >> 16)) *% 2246822507) ^ ((h1 ^ (h1 >> 13)) *% 3266489909);

    const high = try base36Alloc(allocator, h2);
    defer allocator.free(high);
    const low = try base36Alloc(allocator, h1);
    defer allocator.free(low);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ high, low });
}

fn base36Alloc(allocator: std.mem.Allocator, value: u32) ![]u8 {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
    if (value == 0) return allocator.dupe(u8, "0");

    var buffer: [16]u8 = undefined;
    var index = buffer.len;
    var remaining = value;
    while (remaining > 0) {
        index -= 1;
        buffer[index] = alphabet[remaining % 36];
        remaining /= 36;
    }
    return allocator.dupe(u8, buffer[index..]);
}

test "shortHash is deterministic" {
    const allocator = std.testing.allocator;
    const first = try shortHash(allocator, "hello");
    defer allocator.free(first);
    const second = try shortHash(allocator, "hello");
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqualStrings("1h6qa0qrowduu", first);
    try std.testing.expect(first.len > 0);
}
