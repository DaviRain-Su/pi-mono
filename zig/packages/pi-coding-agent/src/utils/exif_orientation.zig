const std = @import("std");

pub fn getExifOrientation(bytes: []const u8) u8 {
    var tiff_offset: ?usize = null;

    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        tiff_offset = findJpegTiffOffset(bytes);
    } else if (bytes.len >= 12 and
        std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP"))
    {
        tiff_offset = findWebpTiffOffset(bytes);
    }

    return if (tiff_offset) |offset| readOrientationFromTiff(bytes, offset) else 1;
}

fn readOrientationFromTiff(bytes: []const u8, tiff_start: usize) u8 {
    if (tiff_start + 8 > bytes.len) return 1;

    const byte_order = (@as(u16, bytes[tiff_start]) << 8) | bytes[tiff_start + 1];
    const little_endian = byte_order == 0x4949;
    const ifd_offset = read32(bytes, tiff_start + 4, little_endian) orelse return 1;
    const ifd_start = tiff_start + ifd_offset;
    if (ifd_start + 2 > bytes.len) return 1;

    const entry_count = read16(bytes, ifd_start, little_endian) orelse return 1;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        const entry_pos = ifd_start + 2 + index * 12;
        if (entry_pos + 12 > bytes.len) return 1;

        const tag = read16(bytes, entry_pos, little_endian) orelse return 1;
        if (tag == 0x0112) {
            const value = read16(bytes, entry_pos + 8, little_endian) orelse return 1;
            return if (value >= 1 and value <= 8) @intCast(value) else 1;
        }
    }

    return 1;
}

fn findJpegTiffOffset(bytes: []const u8) ?usize {
    var offset: usize = 2;
    while (offset < bytes.len - 1) {
        if (bytes[offset] != 0xff) return null;
        const marker = bytes[offset + 1];
        if (marker == 0xff) {
            offset += 1;
            continue;
        }

        if (marker == 0xe1) {
            if (offset + 4 >= bytes.len) return null;
            const segment_start = offset + 4;
            if (segment_start + 6 > bytes.len) return null;
            if (!hasExifHeader(bytes, segment_start)) return null;
            return segment_start + 6;
        }

        if (offset + 4 > bytes.len) return null;
        const length = (@as(usize, bytes[offset + 2]) << 8) | bytes[offset + 3];
        offset += 2 + length;
    }

    return null;
}

fn findWebpTiffOffset(bytes: []const u8) ?usize {
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const chunk_size = @as(usize, bytes[offset + 4]) |
            (@as(usize, bytes[offset + 5]) << 8) |
            (@as(usize, bytes[offset + 6]) << 16) |
            (@as(usize, bytes[offset + 7]) << 24);
        const data_start = offset + 8;

        if (std.mem.eql(u8, bytes[offset .. offset + 4], "EXIF")) {
            if (data_start + chunk_size > bytes.len) return null;
            return if (chunk_size >= 6 and hasExifHeader(bytes, data_start))
                data_start + 6
            else
                data_start;
        }

        offset = data_start + chunk_size + (chunk_size % 2);
    }

    return null;
}

fn hasExifHeader(bytes: []const u8, offset: usize) bool {
    return offset + 6 <= bytes.len and std.mem.eql(u8, bytes[offset .. offset + 6], "Exif\x00\x00");
}

fn read16(bytes: []const u8, pos: usize, little_endian: bool) ?u16 {
    if (pos + 2 > bytes.len) return null;
    if (little_endian) return @as(u16, bytes[pos]) | (@as(u16, bytes[pos + 1]) << 8);
    return (@as(u16, bytes[pos]) << 8) | bytes[pos + 1];
}

fn read32(bytes: []const u8, pos: usize, little_endian: bool) ?usize {
    if (pos + 4 > bytes.len) return null;
    if (little_endian) {
        return @as(usize, bytes[pos]) |
            (@as(usize, bytes[pos + 1]) << 8) |
            (@as(usize, bytes[pos + 2]) << 16) |
            (@as(usize, bytes[pos + 3]) << 24);
    }
    return (@as(usize, bytes[pos]) << 24) |
        (@as(usize, bytes[pos + 1]) << 16) |
        (@as(usize, bytes[pos + 2]) << 8) |
        bytes[pos + 3];
}

test "getExifOrientation returns default for non-exif data" {
    try std.testing.expectEqual(@as(u8, 1), getExifOrientation("not an image"));
}

test "getExifOrientation reads jpeg exif orientation" {
    const jpeg =
        "\xff\xd8" ++
        "\xff\xe1\x00\x20" ++
        "Exif\x00\x00" ++
        "II\x2a\x00\x08\x00\x00\x00" ++
        "\x01\x00" ++
        "\x12\x01\x03\x00\x01\x00\x00\x00\x06\x00\x00\x00" ++
        "\x00\x00\x00\x00";
    try std.testing.expectEqual(@as(u8, 6), getExifOrientation(jpeg));
}

test "getExifOrientation reads webp exif orientation" {
    const webp =
        "RIFF\x2a\x00\x00\x00WEBP" ++
        "EXIF\x16\x00\x00\x00" ++
        "II\x2a\x00\x08\x00\x00\x00" ++
        "\x01\x00" ++
        "\x12\x01\x03\x00\x01\x00\x00\x00\x08\x00\x00\x00" ++
        "\x00\x00\x00\x00";
    try std.testing.expectEqual(@as(u8, 8), getExifOrientation(webp));
}
