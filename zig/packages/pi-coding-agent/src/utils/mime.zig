const std = @import("std");

pub fn detectSupportedImageMimeTypeFromFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !?[]u8 {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, file_path, allocator, .limited(4100));
    defer allocator.free(bytes);
    const mime = detectSupportedImageMimeType(bytes) orelse return null;
    return try allocator.dupe(u8, mime);
}

const MagicEntry = struct {
    prefix: []const u8,
    mime: []const u8,
    // Optional secondary anchor (e.g. RIFF/WEBP container marker at offset 8).
    secondary: ?Secondary = null,

    const Secondary = struct {
        offset: usize,
        bytes: []const u8,
    };
};

const MAGIC_TABLE: []const MagicEntry = &.{
    .{ .prefix = "\x89PNG\r\n\x1a\n", .mime = "image/png" },
    .{ .prefix = "\xff\xd8\xff", .mime = "image/jpeg" },
    .{ .prefix = "GIF87a", .mime = "image/gif" },
    .{ .prefix = "GIF89a", .mime = "image/gif" },
    .{ .prefix = "RIFF", .mime = "image/webp", .secondary = .{ .offset = 8, .bytes = "WEBP" } },
};

pub fn detectSupportedImageMimeType(bytes: []const u8) ?[]const u8 {
    inline for (MAGIC_TABLE) |entry| {
        if (bytes.len >= entry.prefix.len and std.mem.eql(u8, bytes[0..entry.prefix.len], entry.prefix)) {
            if (entry.secondary) |sec| {
                const end = sec.offset + sec.bytes.len;
                if (bytes.len >= end and std.mem.eql(u8, bytes[sec.offset..end], sec.bytes)) return entry.mime;
            } else {
                return entry.mime;
            }
        }
    }
    return null;
}

test "mime detects supported image types" {
    try std.testing.expectEqualStrings("image/png", detectSupportedImageMimeType("\x89PNG\r\n\x1a\nabc").?);
    try std.testing.expectEqualStrings("image/jpeg", detectSupportedImageMimeType("\xff\xd8\xffabc").?);
    try std.testing.expectEqualStrings("image/gif", detectSupportedImageMimeType("GIF89aabc").?);
    try std.testing.expectEqualStrings("image/webp", detectSupportedImageMimeType("RIFFxxxxWEBP").?);
    try std.testing.expect(detectSupportedImageMimeType("text") == null);
}
