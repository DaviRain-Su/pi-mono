const std = @import("std");
const zigimg = @import("zigimg");
const exif_orientation = @import("exif_orientation.zig");

pub const ConvertedImage = struct {
    data: []u8,
    mime_type: []u8,

    pub fn deinit(self: *ConvertedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

pub fn convertToPng(allocator: std.mem.Allocator, base64_data: []const u8, mime_type: []const u8) !?ConvertedImage {
    if (std.ascii.eqlIgnoreCase(mime_type, "image/png")) {
        return .{
            .data = try allocator.dupe(u8, base64_data),
            .mime_type = try allocator.dupe(u8, mime_type),
        };
    }

    const bytes = decodeBase64(allocator, base64_data) catch return null;
    defer allocator.free(bytes);

    var image = loadOrientedImage(allocator, bytes) catch return null;
    defer image.deinit(allocator);

    const png_bytes = encodeImage(allocator, image, .png, 80) catch return null;
    defer allocator.free(png_bytes);
    const encoded = try encodeBase64(allocator, png_bytes);
    errdefer allocator.free(encoded);
    return .{
        .data = encoded,
        .mime_type = try allocator.dupe(u8, "image/png"),
    };
}

pub fn decodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(data);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, data);
    return bytes;
}

pub fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

pub fn loadOrientedImage(allocator: std.mem.Allocator, bytes: []const u8) !zigimg.Image {
    var image = try zigimg.Image.fromMemory(allocator, bytes);
    errdefer image.deinit(allocator);
    try image.convert(allocator, .rgba32);
    return try applyExifOrientation(allocator, image, exif_orientation.getExifOrientation(bytes));
}

pub fn applyExifOrientation(allocator: std.mem.Allocator, image: zigimg.Image, orientation: u8) !zigimg.Image {
    if (orientation <= 1 or orientation > 8) return image;

    var input = image;
    errdefer input.deinit(allocator);
    try input.convert(allocator, .rgba32);
    const src = input.pixels.rgba32;
    const src_width = input.width;
    const src_height = input.height;
    const rotate = orientation == 5 or orientation == 6 or orientation == 7 or orientation == 8;
    var output = try zigimg.Image.create(
        allocator,
        if (rotate) src_height else src_width,
        if (rotate) src_width else src_height,
        .rgba32,
    );
    errdefer output.deinit(allocator);
    const dst = output.pixels.rgba32;

    var y: usize = 0;
    while (y < src_height) : (y += 1) {
        var x: usize = 0;
        while (x < src_width) : (x += 1) {
            const src_index = y * src_width + x;
            const dst_index = switch (orientation) {
                2 => y * src_width + (src_width - 1 - x),
                3 => (src_height - 1 - y) * src_width + (src_width - 1 - x),
                4 => (src_height - 1 - y) * src_width + x,
                5 => (src_width - 1 - x) * src_height + (src_height - 1 - y),
                6 => x * src_height + (src_height - 1 - y),
                7 => x * src_height + y,
                8 => (src_width - 1 - x) * src_height + y,
                else => unreachable,
            };
            dst[dst_index] = src[src_index];
        }
    }

    input.deinit(allocator);
    return output;
}

pub const EncodeFormat = enum {
    png,
    jpeg,
};

pub fn encodeImage(allocator: std.mem.Allocator, image: zigimg.Image, format: EncodeFormat, jpeg_quality: u8) ![]u8 {
    var buffer_size = @max(image.rawBytes().len * 4 + 64 * 1024, 128 * 1024);
    const max_buffer_size: usize = 512 * 1024 * 1024;

    while (buffer_size <= max_buffer_size) : (buffer_size *= 2) {
        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);
        const written = image.writeToMemory(allocator, buffer, switch (format) {
            .png => .{ .png = .{} },
            .jpeg => .{ .jpeg = .{ .quality = jpeg_quality, .auto_convert = true } },
        }) catch {
            allocator.free(buffer);
            continue;
        };
        const out = try allocator.dupe(u8, written);
        allocator.free(buffer);
        return out;
    }

    return error.ImageEncodeTooLarge;
}

test "convertToPng returns png unchanged" {
    const png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==";
    var converted = (try convertToPng(std.testing.allocator, png_base64, "image/png")).?;
    defer converted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(png_base64, converted.data);
    try std.testing.expectEqualStrings("image/png", converted.mime_type);
}

test "base64 helpers round-trip" {
    const encoded = try encodeBase64(std.testing.allocator, "hello");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("aGVsbG8=", encoded);
    const decoded = try decodeBase64(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("hello", decoded);
}
