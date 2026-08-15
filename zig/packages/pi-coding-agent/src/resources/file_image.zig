//! M14 file image processing parity.
//!
//! Mirrors `packages/coding-agent/src/utils/{image-resize,exif-orientation}.ts`
//! by exposing an injectable processor hook + EXIF/dimension helpers. The
//! default processor performs identity passthrough when an image already fits
//! within the configured limits AND has trivial EXIF orientation; otherwise it
//! returns null so the caller can emit the deterministic omission message.
//! Tests inject a deterministic stub processor to exercise the full
//! resize/JPEG-fallback/dimension-note/omission paths without depending on a
//! native image-processing library (mirroring the TypeScript behaviour when
//! Photon is unavailable).

const std = @import("std");
const ai = @import("ai");

pub const DEFAULT_MAX_WIDTH: u32 = 2000;
pub const DEFAULT_MAX_HEIGHT: u32 = 2000;
pub const DEFAULT_MAX_BYTES: usize = (45 * 1024 * 1024) / 10; // 4.5 MB
pub const DEFAULT_JPEG_QUALITY: u8 = 80;

/// Deterministic user-visible omission message; matches TypeScript
/// `processFileArguments` exactly so cross-language fixture tests can compare.
pub const OMISSION_MESSAGE: []const u8 =
    "[Image omitted: could not be resized below the inline image size limit.]";

pub const ImageProcessOptions = struct {
    max_width: u32 = DEFAULT_MAX_WIDTH,
    max_height: u32 = DEFAULT_MAX_HEIGHT,
    max_bytes: usize = DEFAULT_MAX_BYTES,
    jpeg_quality: u8 = DEFAULT_JPEG_QUALITY,
};

/// Result returned from a successful image normalization. Lifetimes: the
/// caller owns `data` and `mime_type` and must free them via `deinit`.
pub const ProcessedImage = struct {
    data_b64: []u8,
    mime_type: []u8,
    original_width: u32,
    original_height: u32,
    width: u32,
    height: u32,
    was_resized: bool,

    pub fn deinit(self: *ProcessedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data_b64);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

pub const ImageDims = struct {
    width: u32,
    height: u32,
};

/// Detect a supported image MIME type from a magic-byte prefix. Returns null
/// when the bytes are not a supported image format.
pub fn detectImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return "image/gif";
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}

// ---------------------------------------------------------------------------
// Dimension extraction
// ---------------------------------------------------------------------------

/// Returns image pixel dimensions parsed from supported image headers. Returns
/// null if the image format is not recognized or the header is truncated.
pub fn getImageDimensions(bytes: []const u8) ?ImageDims {
    const mime = detectImageMime(bytes) orelse return null;
    if (std.mem.eql(u8, mime, "image/png")) return getPngDimensions(bytes);
    if (std.mem.eql(u8, mime, "image/jpeg")) return getJpegDimensions(bytes);
    if (std.mem.eql(u8, mime, "image/webp")) return getWebpDimensions(bytes);
    if (std.mem.eql(u8, mime, "image/gif")) return getGifDimensions(bytes);
    return null;
}

fn read16Be(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]);
}

fn read32Be(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

fn read16Le(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read24Le(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 3 > bytes.len) return null;
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16);
}

fn read32Le(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn getPngDimensions(bytes: []const u8) ?ImageDims {
    // PNG IHDR is at offset 8 (signature) + 4 (length) + 4 (type "IHDR")
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const width = read32Be(bytes, 16) orelse return null;
    const height = read32Be(bytes, 20) orelse return null;
    return .{ .width = width, .height = height };
}

fn getJpegDimensions(bytes: []const u8) ?ImageDims {
    var offset: usize = 2;
    while (offset + 1 < bytes.len) {
        if (bytes[offset] != 0xff) return null;
        const marker = bytes[offset + 1];
        if (marker == 0xff) {
            offset += 1;
            continue;
        }
        // Markers without a payload.
        if (marker == 0xd8 or marker == 0xd9 or
            (marker >= 0xd0 and marker <= 0xd7) or marker == 0x01)
        {
            offset += 2;
            continue;
        }
        // Start-of-Frame markers carry width/height. Excludes 0xC4/0xC8/0xCC
        // which are DHT/JPG/DAC, not SOF.
        if (marker >= 0xc0 and marker <= 0xcf and
            marker != 0xc4 and marker != 0xc8 and marker != 0xcc)
        {
            if (offset + 9 > bytes.len) return null;
            const height = read16Be(bytes, offset + 5) orelse return null;
            const width = read16Be(bytes, offset + 7) orelse return null;
            return .{ .width = width, .height = height };
        }
        const length = read16Be(bytes, offset + 2) orelse return null;
        if (length < 2) return null;
        offset += 2 + length;
    }
    return null;
}

fn getWebpDimensions(bytes: []const u8) ?ImageDims {
    if (bytes.len < 30) return null;
    // VP8L header: "RIFF....WEBPVP8L"
    if (std.mem.eql(u8, bytes[12..16], "VP8L")) {
        // Bytes 21..24 contain width-1 (14 bits) | height-1 (14 bits) packed LE.
        if (bytes.len < 25) return null;
        const packed_value = read32Le(bytes, 21) orelse return null;
        const width = (packed_value & 0x3FFF) + 1;
        const height = ((packed_value >> 14) & 0x3FFF) + 1;
        return .{ .width = width, .height = height };
    }
    if (std.mem.eql(u8, bytes[12..16], "VP8 ")) {
        // VP8: Width and height at offset 26 (after frame tag), each u16 LE & 0x3FFF.
        if (bytes.len < 30) return null;
        const w_raw = read16Le(bytes, 26) orelse return null;
        const h_raw = read16Le(bytes, 28) orelse return null;
        return .{ .width = w_raw & 0x3FFF, .height = h_raw & 0x3FFF };
    }
    if (std.mem.eql(u8, bytes[12..16], "VP8X")) {
        // Extended: width-1 and height-1 stored as u24 LE at offset 24/27.
        if (bytes.len < 30) return null;
        const w_raw = read24Le(bytes, 24) orelse return null;
        const h_raw = read24Le(bytes, 27) orelse return null;
        return .{ .width = w_raw + 1, .height = h_raw + 1 };
    }
    return null;
}

fn getGifDimensions(bytes: []const u8) ?ImageDims {
    if (bytes.len < 10) return null;
    const w = read16Le(bytes, 6) orelse return null;
    const h = read16Le(bytes, 8) orelse return null;
    return .{ .width = w, .height = h };
}

// ---------------------------------------------------------------------------
// EXIF orientation
// ---------------------------------------------------------------------------

fn hasExifHeader(bytes: []const u8, offset: usize) bool {
    if (offset + 6 > bytes.len) return false;
    return bytes[offset] == 0x45 and
        bytes[offset + 1] == 0x78 and
        bytes[offset + 2] == 0x69 and
        bytes[offset + 3] == 0x66 and
        bytes[offset + 4] == 0x00 and
        bytes[offset + 5] == 0x00;
}

fn readOrientationFromTiff(bytes: []const u8, tiff_start: usize) u8 {
    if (tiff_start + 8 > bytes.len) return 1;
    const byte_order = (@as(u16, bytes[tiff_start]) << 8) | @as(u16, bytes[tiff_start + 1]);
    const le = byte_order == 0x4949;

    const read16 = struct {
        fn call(b: []const u8, pos: usize, little: bool) ?u16 {
            if (little) return read16Le(b, pos);
            return read16Be(b, pos);
        }
    }.call;

    const read32 = struct {
        fn call(b: []const u8, pos: usize, little: bool) ?u32 {
            if (little) return read32Le(b, pos);
            return read32Be(b, pos);
        }
    }.call;

    const ifd_offset = read32(bytes, tiff_start + 4, le) orelse return 1;
    const ifd_start = tiff_start + ifd_offset;
    if (ifd_start + 2 > bytes.len) return 1;
    const entry_count = read16(bytes, ifd_start, le) orelse return 1;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry_pos = ifd_start + 2 + i * 12;
        if (entry_pos + 12 > bytes.len) return 1;
        const tag = read16(bytes, entry_pos, le) orelse return 1;
        if (tag == 0x0112) {
            const value = read16(bytes, entry_pos + 8, le) orelse return 1;
            if (value >= 1 and value <= 8) return @intCast(value);
            return 1;
        }
    }
    return 1;
}

fn findJpegTiffOffset(bytes: []const u8) ?usize {
    var offset: usize = 2;
    while (offset + 1 < bytes.len) {
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
        const length = read16Be(bytes, offset + 2) orelse return null;
        offset += 2 + length;
    }
    return null;
}

fn findWebpTiffOffset(bytes: []const u8) ?usize {
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const chunk_id = bytes[offset .. offset + 4];
        const chunk_size = read32Le(bytes, offset + 4) orelse return null;
        const data_start = offset + 8;
        if (std.mem.eql(u8, chunk_id, "EXIF")) {
            if (data_start + chunk_size > bytes.len) return null;
            const tiff_start = if (chunk_size >= 6 and hasExifHeader(bytes, data_start))
                data_start + 6
            else
                data_start;
            return tiff_start;
        }
        // RIFF chunks are padded to even size.
        const stride = chunk_size + (chunk_size % 2);
        offset = data_start + stride;
    }
    return null;
}

/// Returns EXIF orientation in [1..8]. Returns 1 (no rotation) for any image
/// without EXIF metadata or with malformed/unsupported metadata.
pub fn getExifOrientation(bytes: []const u8) u8 {
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        const tiff = findJpegTiffOffset(bytes) orelse return 1;
        return readOrientationFromTiff(bytes, tiff);
    }
    if (bytes.len >= 12 and
        bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46 and
        bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50)
    {
        const tiff = findWebpTiffOffset(bytes) orelse return 1;
        return readOrientationFromTiff(bytes, tiff);
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Injectable processor + default
// ---------------------------------------------------------------------------

pub const ProcessImageInput = struct {
    bytes: []const u8,
    mime_type: []const u8,
    options: ImageProcessOptions,
};

/// Returns null when the image cannot be normalized within the configured
/// limits. Mirrors the TS behaviour when Photon is unavailable.
pub const ImageProcessorFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: ProcessImageInput,
) anyerror!?ProcessedImage;

pub var image_processor_context: ?*anyopaque = null;
pub var image_processor_fn: ImageProcessorFn = defaultProcessImage;

pub fn processImage(
    allocator: std.mem.Allocator,
    input: ProcessImageInput,
) !?ProcessedImage {
    return image_processor_fn(image_processor_context, allocator, input);
}

/// Default processor: identity passthrough only. Returns null for any image
/// that needs orientation rewrite, dimension reduction, or byte recompression
/// because the Zig build does not embed a native image-processing library
/// (matches TS `resizeImage` returning null when Photon is unavailable). Tests
/// install a deterministic stub processor via `image_processor_fn`.
pub fn defaultProcessImage(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: ProcessImageInput,
) !?ProcessedImage {
    const dims = getImageDimensions(input.bytes) orelse return null;
    const orientation = getExifOrientation(input.bytes);

    if (orientation != 1) return null;
    if (dims.width > input.options.max_width) return null;
    if (dims.height > input.options.max_height) return null;

    const encoded_size = std.base64.standard.Encoder.calcSize(input.bytes.len);
    if (encoded_size >= input.options.max_bytes) return null;

    const data = try allocator.alloc(u8, encoded_size);
    errdefer allocator.free(data);
    _ = std.base64.standard.Encoder.encode(data, input.bytes);

    const mime = try allocator.dupe(u8, input.mime_type);
    return .{
        .data_b64 = data,
        .mime_type = mime,
        .original_width = dims.width,
        .original_height = dims.height,
        .width = dims.width,
        .height = dims.height,
        .was_resized = false,
    };
}

/// Format dimension note matching TypeScript `formatDimensionNote` exactly.
/// Returns null when the image was not resized.
pub fn formatDimensionNote(allocator: std.mem.Allocator, image: ProcessedImage) !?[]u8 {
    if (!image.was_resized) return null;
    const original_w_f: f64 = @floatFromInt(image.original_width);
    const width_f: f64 = @floatFromInt(image.width);
    const scale = original_w_f / width_f;
    return try std.fmt.allocPrint(
        allocator,
        "[Image: original {d}x{d}, displayed at {d}x{d}. Multiply coordinates by {d:.2} to map to original image.]",
        .{ image.original_width, image.original_height, image.width, image.height, scale },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildPngHeader(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    // length (13) for IHDR
    bytes[8] = 0x00;
    bytes[9] = 0x00;
    bytes[10] = 0x00;
    bytes[11] = 0x0d;
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

test "detectImageMime identifies supported formats" {
    const png = buildPngHeader(2, 2);
    try testing.expectEqualStrings("image/png", detectImageMime(&png).?);
    const jpeg_prefix = [_]u8{ 0xff, 0xd8, 0xff };
    try testing.expectEqualStrings("image/jpeg", detectImageMime(&jpeg_prefix).?);
    const gif = "GIF89a..".*;
    try testing.expectEqualStrings("image/gif", detectImageMime(&gif).?);
    var webp: [16]u8 = undefined;
    @memcpy(webp[0..4], "RIFF");
    @memcpy(webp[4..8], &[_]u8{ 0, 0, 0, 0 });
    @memcpy(webp[8..12], "WEBP");
    @memcpy(webp[12..16], "VP8 ");
    try testing.expectEqualStrings("image/webp", detectImageMime(&webp).?);
    try testing.expectEqual(@as(?[]const u8, null), detectImageMime("hello"));
}

test "getImageDimensions reads PNG IHDR" {
    const png = buildPngHeader(1234, 567);
    const dims = getImageDimensions(&png).?;
    try testing.expectEqual(@as(u32, 1234), dims.width);
    try testing.expectEqual(@as(u32, 567), dims.height);
}

test "getImageDimensions reads JPEG SOF0" {
    var jpeg: [21]u8 = undefined;
    jpeg[0] = 0xff;
    jpeg[1] = 0xd8;
    // SOF0 marker
    jpeg[2] = 0xff;
    jpeg[3] = 0xc0;
    // length=11 (big-endian)
    jpeg[4] = 0x00;
    jpeg[5] = 0x0b;
    // sample precision
    jpeg[6] = 0x08;
    // height=480
    jpeg[7] = 0x01;
    jpeg[8] = 0xe0;
    // width=640
    jpeg[9] = 0x02;
    jpeg[10] = 0x80;
    // remainder of SOF body
    @memcpy(jpeg[11..21], &[_]u8{ 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01 });

    const dims = getImageDimensions(&jpeg).?;
    try testing.expectEqual(@as(u32, 640), dims.width);
    try testing.expectEqual(@as(u32, 480), dims.height);
}

test "getExifOrientation defaults to 1 for PNG and untagged JPEG" {
    const png = buildPngHeader(2, 2);
    try testing.expectEqual(@as(u8, 1), getExifOrientation(&png));
    var jpeg = [_]u8{ 0xff, 0xd8, 0xff, 0xd9 };
    try testing.expectEqual(@as(u8, 1), getExifOrientation(&jpeg));
}

test "getExifOrientation parses JPEG APP1 EXIF" {
    // Construct minimal JPEG: SOI, APP1 with EXIF + TIFF orientation=6.
    // APP1 segment layout:
    //   marker FF E1
    //   length (2 bytes, includes the length field itself)
    //   "Exif\0\0" (6 bytes)
    //   TIFF: byte order "II" (LE), magic 0x002a, IFD offset 0x00000008
    //   IFD: entry_count (1), one entry: tag=0x0112, type=3 (SHORT), count=1, value=6
    //   next-IFD-offset = 0
    var bytes: [42]u8 = undefined;
    bytes[0] = 0xff;
    bytes[1] = 0xd8;
    bytes[2] = 0xff;
    bytes[3] = 0xe1;
    // length = 40 (header excluded), big-endian
    bytes[4] = 0x00;
    bytes[5] = 0x28;
    // EXIF header
    bytes[6] = 'E';
    bytes[7] = 'x';
    bytes[8] = 'i';
    bytes[9] = 'f';
    bytes[10] = 0x00;
    bytes[11] = 0x00;
    // TIFF header (LE)
    bytes[12] = 'I';
    bytes[13] = 'I';
    bytes[14] = 0x2a;
    bytes[15] = 0x00;
    // IFD offset = 8
    bytes[16] = 0x08;
    bytes[17] = 0x00;
    bytes[18] = 0x00;
    bytes[19] = 0x00;
    // IFD: 1 entry
    bytes[20] = 0x01;
    bytes[21] = 0x00;
    // tag 0x0112
    bytes[22] = 0x12;
    bytes[23] = 0x01;
    // type 3 (SHORT)
    bytes[24] = 0x03;
    bytes[25] = 0x00;
    // count 1
    bytes[26] = 0x01;
    bytes[27] = 0x00;
    bytes[28] = 0x00;
    bytes[29] = 0x00;
    // value: orientation=6 (rotate 90 CW)
    bytes[30] = 0x06;
    bytes[31] = 0x00;
    bytes[32] = 0x00;
    bytes[33] = 0x00;
    // pad
    bytes[34] = 0x00;
    bytes[35] = 0x00;
    bytes[36] = 0x00;
    bytes[37] = 0x00;
    bytes[38] = 0xff;
    bytes[39] = 0xd9;
    bytes[40] = 0x00;
    bytes[41] = 0x00;
    try testing.expectEqual(@as(u8, 6), getExifOrientation(&bytes));
}

test "defaultProcessImage identity passthrough for in-limit PNG" {
    const png = buildPngHeader(100, 100);
    const result = (try defaultProcessImage(null, testing.allocator, .{
        .bytes = &png,
        .mime_type = "image/png",
        .options = .{ .max_width = 200, .max_height = 200, .max_bytes = 10_000, .jpeg_quality = 80 },
    })).?;
    var owned = result;
    defer owned.deinit(testing.allocator);
    try testing.expect(!owned.was_resized);
    try testing.expectEqual(@as(u32, 100), owned.width);
    try testing.expectEqualStrings("image/png", owned.mime_type);
}

test "defaultProcessImage returns null when over dimensions" {
    const png = buildPngHeader(500, 500);
    const result = try defaultProcessImage(null, testing.allocator, .{
        .bytes = &png,
        .mime_type = "image/png",
        .options = .{ .max_width = 100, .max_height = 100, .max_bytes = 10_000, .jpeg_quality = 80 },
    });
    try testing.expectEqual(@as(?ProcessedImage, null), result);
}

test "defaultProcessImage returns null when EXIF rotation is required" {
    var bytes: [42]u8 = undefined;
    bytes[0] = 0xff;
    bytes[1] = 0xd8;
    bytes[2] = 0xff;
    bytes[3] = 0xe1;
    bytes[4] = 0x00;
    bytes[5] = 0x28;
    bytes[6] = 'E';
    bytes[7] = 'x';
    bytes[8] = 'i';
    bytes[9] = 'f';
    bytes[10] = 0x00;
    bytes[11] = 0x00;
    bytes[12] = 'I';
    bytes[13] = 'I';
    bytes[14] = 0x2a;
    bytes[15] = 0x00;
    bytes[16] = 0x08;
    bytes[17] = 0x00;
    bytes[18] = 0x00;
    bytes[19] = 0x00;
    bytes[20] = 0x01;
    bytes[21] = 0x00;
    bytes[22] = 0x12;
    bytes[23] = 0x01;
    bytes[24] = 0x03;
    bytes[25] = 0x00;
    bytes[26] = 0x01;
    bytes[27] = 0x00;
    bytes[28] = 0x00;
    bytes[29] = 0x00;
    bytes[30] = 0x06;
    bytes[31] = 0x00;
    bytes[32] = 0x00;
    bytes[33] = 0x00;
    bytes[34] = 0x00;
    bytes[35] = 0x00;
    bytes[36] = 0x00;
    bytes[37] = 0x00;
    bytes[38] = 0xff;
    bytes[39] = 0xd9;
    bytes[40] = 0x00;
    bytes[41] = 0x00;
    const result = try defaultProcessImage(null, testing.allocator, .{
        .bytes = &bytes,
        .mime_type = "image/jpeg",
        .options = .{},
    });
    try testing.expectEqual(@as(?ProcessedImage, null), result);
}

test "formatDimensionNote returns null for non-resized images" {
    const image: ProcessedImage = .{
        .data_b64 = @constCast(""),
        .mime_type = @constCast("image/png"),
        .original_width = 100,
        .original_height = 100,
        .width = 100,
        .height = 100,
        .was_resized = false,
    };
    const note = try formatDimensionNote(testing.allocator, image);
    try testing.expectEqual(@as(?[]u8, null), note);
}

test "formatDimensionNote matches TS shape for resized images" {
    const image: ProcessedImage = .{
        .data_b64 = @constCast(""),
        .mime_type = @constCast("image/png"),
        .original_width = 2000,
        .original_height = 1000,
        .width = 1000,
        .height = 500,
        .was_resized = true,
    };
    const note = (try formatDimensionNote(testing.allocator, image)).?;
    defer testing.allocator.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "original 2000x1000") != null);
    try testing.expect(std.mem.indexOf(u8, note, "displayed at 1000x500") != null);
    try testing.expect(std.mem.indexOf(u8, note, "2.00") != null);
}

// =============================================================================
// VAL-M14 deterministic file image tests via injectable processor stub.
// =============================================================================

const StubProcessor = struct {
    response: ?ProcessedImage = null,
    last_input: ?StoredInput = null,
    invocation_count: u32 = 0,
    allocator: std.mem.Allocator,

    const StoredInput = struct {
        bytes: []u8,
        mime_type: []u8,
        options: ImageProcessOptions,

        fn deinit(self: *StoredInput, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            allocator.free(self.mime_type);
            self.* = undefined;
        }
    };

    fn run(
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        input: ProcessImageInput,
    ) anyerror!?ProcessedImage {
        const self: *StubProcessor = @ptrCast(@alignCast(ctx orelse return error.MissingStub));
        self.invocation_count += 1;
        if (self.last_input) |*prev| prev.deinit(self.allocator);
        self.last_input = .{
            .bytes = try self.allocator.dupe(u8, input.bytes),
            .mime_type = try self.allocator.dupe(u8, input.mime_type),
            .options = input.options,
        };
        if (self.response) |stored| {
            // Hand a fresh copy to the caller so their lifetime is independent.
            return ProcessedImage{
                .data_b64 = try allocator.dupe(u8, stored.data_b64),
                .mime_type = try allocator.dupe(u8, stored.mime_type),
                .original_width = stored.original_width,
                .original_height = stored.original_height,
                .width = stored.width,
                .height = stored.height,
                .was_resized = stored.was_resized,
            };
        }
        return null;
    }

    fn install(self: *StubProcessor) struct {
        prev_ctx: ?*anyopaque,
        prev_fn: ImageProcessorFn,
    } {
        const prev_ctx = image_processor_context;
        const prev_fn = image_processor_fn;
        image_processor_context = @ptrCast(self);
        image_processor_fn = run;
        return .{ .prev_ctx = prev_ctx, .prev_fn = prev_fn };
    }

    fn restore(prev: anytype) void {
        image_processor_context = prev.prev_ctx;
        image_processor_fn = prev.prev_fn;
    }

    fn deinit(self: *StubProcessor) void {
        if (self.last_input) |*prev| prev.deinit(self.allocator);
        if (self.response) |stored| {
            self.allocator.free(stored.data_b64);
            self.allocator.free(stored.mime_type);
        }
        self.* = undefined;
    }
};

test "VAL-M14-IMAGE-005 stub processor receives EXIF-tagged JPEG bytes" {
    const allocator = testing.allocator;
    var stub = StubProcessor{ .allocator = allocator, .response = .{
        .data_b64 = try allocator.dupe(u8, "AAAA"),
        .mime_type = try allocator.dupe(u8, "image/jpeg"),
        .original_width = 100,
        .original_height = 200,
        .width = 100,
        .height = 200,
        .was_resized = false,
    } };
    defer stub.deinit();
    const prev = stub.install();
    defer StubProcessor.restore(prev);

    var jpeg_with_exif: [42]u8 = undefined;
    jpeg_with_exif[0] = 0xff;
    jpeg_with_exif[1] = 0xd8;
    jpeg_with_exif[2] = 0xff;
    jpeg_with_exif[3] = 0xe1;
    jpeg_with_exif[4] = 0x00;
    jpeg_with_exif[5] = 0x28;
    @memcpy(jpeg_with_exif[6..12], "Exif\x00\x00");
    @memcpy(jpeg_with_exif[12..16], "II\x2a\x00");
    @memcpy(jpeg_with_exif[16..20], &[_]u8{ 0x08, 0x00, 0x00, 0x00 });
    jpeg_with_exif[20] = 0x01;
    jpeg_with_exif[21] = 0x00;
    jpeg_with_exif[22] = 0x12;
    jpeg_with_exif[23] = 0x01;
    jpeg_with_exif[24] = 0x03;
    jpeg_with_exif[25] = 0x00;
    @memcpy(jpeg_with_exif[26..30], &[_]u8{ 0x01, 0x00, 0x00, 0x00 });
    jpeg_with_exif[30] = 0x06; // orientation=6
    @memcpy(jpeg_with_exif[31..42], &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xd9, 0x00, 0x00 });

    // Sanity check: orientation parser sees the EXIF tag.
    try testing.expectEqual(@as(u8, 6), getExifOrientation(&jpeg_with_exif));

    var result = (try processImage(allocator, .{
        .bytes = &jpeg_with_exif,
        .mime_type = "image/jpeg",
        .options = .{},
    })).?;
    defer result.deinit(allocator);

    try testing.expectEqual(@as(u32, 1), stub.invocation_count);
    try testing.expectEqualSlices(u8, &jpeg_with_exif, stub.last_input.?.bytes);
    try testing.expectEqualStrings("image/jpeg", result.mime_type);
}

test "VAL-M14-IMAGE-006 stub processor surfaces dimension resize result" {
    const allocator = testing.allocator;
    var stub = StubProcessor{ .allocator = allocator, .response = .{
        .data_b64 = try allocator.dupe(u8, "ZZZ"),
        .mime_type = try allocator.dupe(u8, "image/png"),
        .original_width = 4000,
        .original_height = 3000,
        .width = 2000,
        .height = 1500,
        .was_resized = true,
    } };
    defer stub.deinit();
    const prev = stub.install();
    defer StubProcessor.restore(prev);

    const png = buildPngHeader(4000, 3000);
    var result = (try processImage(allocator, .{
        .bytes = &png,
        .mime_type = "image/png",
        .options = .{ .max_width = 2000, .max_height = 2000 },
    })).?;
    defer result.deinit(allocator);

    try testing.expect(result.was_resized);
    try testing.expectEqual(@as(u32, 2000), result.width);
    try testing.expectEqual(@as(u32, 1500), result.height);
    try testing.expectEqual(@as(u32, 4000), result.original_width);
    try testing.expectEqual(@as(u32, 3000), result.original_height);
    try testing.expectEqual(@as(u32, 2000), stub.last_input.?.options.max_width);
}

test "VAL-M14-IMAGE-007 stub processor reports JPEG fallback mime when over byte limit" {
    const allocator = testing.allocator;
    var stub = StubProcessor{ .allocator = allocator, .response = .{
        .data_b64 = try allocator.dupe(u8, "JPEG"),
        .mime_type = try allocator.dupe(u8, "image/jpeg"),
        .original_width = 1000,
        .original_height = 1000,
        .width = 800,
        .height = 800,
        .was_resized = true,
    } };
    defer stub.deinit();
    const prev = stub.install();
    defer StubProcessor.restore(prev);

    const png = buildPngHeader(1000, 1000);
    var result = (try processImage(allocator, .{
        .bytes = &png,
        .mime_type = "image/png",
        .options = .{ .max_bytes = 10_000 },
    })).?;
    defer result.deinit(allocator);

    try testing.expectEqualStrings("image/jpeg", result.mime_type);
    try testing.expect(result.was_resized);
    try testing.expectEqual(@as(usize, 10_000), stub.last_input.?.options.max_bytes);
}

test "VAL-M14-IMAGE-008 stub processor null result yields omission" {
    const allocator = testing.allocator;
    var stub = StubProcessor{ .allocator = allocator };
    defer stub.deinit();
    const prev = stub.install();
    defer StubProcessor.restore(prev);

    const png = buildPngHeader(8000, 8000);
    const result = try processImage(allocator, .{
        .bytes = &png,
        .mime_type = "image/png",
        .options = .{},
    });
    try testing.expectEqual(@as(?ProcessedImage, null), result);
    try testing.expectEqual(@as(u32, 1), stub.invocation_count);
}
