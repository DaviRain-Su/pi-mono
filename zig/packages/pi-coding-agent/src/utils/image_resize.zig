const std = @import("std");
const zigimg = @import("zigimg");
const image_convert = @import("image_convert.zig");

pub const ImageContent = struct {
    data: []const u8,
    mime_type: ?[]const u8 = null,
};

pub const ImageResizeOptions = struct {
    max_width: usize = 2000,
    max_height: usize = 2000,
    max_bytes: usize = @as(usize, @intFromFloat(4.5 * 1024 * 1024)),
    jpeg_quality: u8 = 80,
};

pub const ResizedImage = struct {
    data: []u8,
    mime_type: []u8,
    original_width: usize,
    original_height: usize,
    width: usize,
    height: usize,
    was_resized: bool,

    pub fn deinit(self: *ResizedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

const EncodedCandidate = struct {
    data: []u8,
    mime_type: []const u8,

    fn deinit(self: *EncodedCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub fn resizeImage(allocator: std.mem.Allocator, img: ImageContent, options: ImageResizeOptions) !?ResizedImage {
    const input_bytes = image_convert.decodeBase64(allocator, img.data) catch return null;
    defer allocator.free(input_bytes);

    var image = image_convert.loadOrientedImage(allocator, input_bytes) catch return null;
    defer image.deinit(allocator);

    const original_width = image.width;
    const original_height = image.height;
    const mime_type = img.mime_type orelse "image/png";

    if (original_width <= options.max_width and original_height <= options.max_height and img.data.len < options.max_bytes) {
        return .{
            .data = try allocator.dupe(u8, img.data),
            .mime_type = try allocator.dupe(u8, mime_type),
            .original_width = original_width,
            .original_height = original_height,
            .width = original_width,
            .height = original_height,
            .was_resized = false,
        };
    }

    var target_width = original_width;
    var target_height = original_height;
    if (target_width > options.max_width) {
        target_height = divRound(target_height * options.max_width, target_width);
        target_width = options.max_width;
    }
    if (target_height > options.max_height) {
        target_width = divRound(target_width * options.max_height, target_height);
        target_height = options.max_height;
    }
    target_width = @max(target_width, 1);
    target_height = @max(target_height, 1);

    const qualities = [_]u8{ options.jpeg_quality, 85, 70, 55, 40 };
    var current_width = target_width;
    var current_height = target_height;

    while (true) {
        var resized = try resizeNearest(allocator, image, current_width, current_height);
        defer resized.deinit(allocator);

        var candidates = std.ArrayList(EncodedCandidate).empty;
        defer {
            for (candidates.items) |*candidate| candidate.deinit(allocator);
            candidates.deinit(allocator);
        }

        if (try encodeCandidate(allocator, resized, .png, 80)) |candidate| try candidates.append(allocator, candidate);
        for (qualities) |quality| {
            if (try encodeCandidate(allocator, resized, .jpeg, quality)) |candidate| try candidates.append(allocator, candidate);
        }

        for (candidates.items, 0..) |candidate, index| {
            if (candidate.data.len < options.max_bytes) {
                const owned = candidates.items[index];
                candidates.orderedRemove(index);
                return .{
                    .data = owned.data,
                    .mime_type = try allocator.dupe(u8, owned.mime_type),
                    .original_width = original_width,
                    .original_height = original_height,
                    .width = current_width,
                    .height = current_height,
                    .was_resized = true,
                };
            }
        }

        if (current_width == 1 and current_height == 1) break;
        const next_width = if (current_width == 1) 1 else @max(1, current_width * 3 / 4);
        const next_height = if (current_height == 1) 1 else @max(1, current_height * 3 / 4);
        if (next_width == current_width and next_height == current_height) break;
        current_width = next_width;
        current_height = next_height;
    }

    return null;
}

pub fn formatDimensionNote(allocator: std.mem.Allocator, result: ResizedImage) !?[]u8 {
    if (!result.was_resized) return null;
    const scale = @as(f64, @floatFromInt(result.original_width)) / @as(f64, @floatFromInt(result.width));
    return try std.fmt.allocPrint(
        allocator,
        "[Image: original {d}x{d}, displayed at {d}x{d}. Multiply coordinates by {d:.2} to map to original image.]",
        .{ result.original_width, result.original_height, result.width, result.height, scale },
    );
}

fn encodeCandidate(allocator: std.mem.Allocator, image: zigimg.Image, format: image_convert.EncodeFormat, quality: u8) !?EncodedCandidate {
    const bytes = image_convert.encodeImage(allocator, image, format, quality) catch return null;
    defer allocator.free(bytes);
    return .{
        .data = try image_convert.encodeBase64(allocator, bytes),
        .mime_type = switch (format) {
            .png => "image/png",
            .jpeg => "image/jpeg",
        },
    };
}

fn resizeNearest(allocator: std.mem.Allocator, source: zigimg.Image, width: usize, height: usize) !zigimg.Image {
    if (std.meta.activeTag(source.pixels) != .rgba32) return error.UnsupportedImagePixelFormat;

    var output = try zigimg.Image.create(allocator, width, height, .rgba32);
    errdefer output.deinit(allocator);

    const src = source.pixels.rgba32;
    const dst = output.pixels.rgba32;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const src_y = @min(source.height - 1, y * source.height / height);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const src_x = @min(source.width - 1, x * source.width / width);
            dst[y * width + x] = src[src_y * source.width + src_x];
        }
    }

    return output;
}

fn divRound(numerator: usize, denominator: usize) usize {
    return (numerator + denominator / 2) / denominator;
}

test "formatDimensionNote returns undefined for unchanged images" {
    var result = ResizedImage{
        .data = try std.testing.allocator.dupe(u8, "x"),
        .mime_type = try std.testing.allocator.dupe(u8, "image/png"),
        .original_width = 1,
        .original_height = 1,
        .width = 1,
        .height = 1,
        .was_resized = false,
    };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(null, try formatDimensionNote(std.testing.allocator, result));
}

test "formatDimensionNote describes coordinate scale" {
    var result = ResizedImage{
        .data = try std.testing.allocator.dupe(u8, "x"),
        .mime_type = try std.testing.allocator.dupe(u8, "image/png"),
        .original_width = 200,
        .original_height = 100,
        .width = 100,
        .height = 50,
        .was_resized = true,
    };
    defer result.deinit(std.testing.allocator);
    const note = (try formatDimensionNote(std.testing.allocator, result)).?;
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings("[Image: original 200x100, displayed at 100x50. Multiply coordinates by 2.00 to map to original image.]", note);
}
