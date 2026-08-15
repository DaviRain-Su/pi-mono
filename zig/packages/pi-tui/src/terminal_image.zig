const std = @import("std");
const terminal_capabilities = @import("terminal_capabilities.zig");

pub const ImageProtocol = enum {
    kitty,
    iterm2,
};

pub const TerminalCapabilities = struct {
    images: ?ImageProtocol,
    true_color: bool,
    hyperlinks: bool,
};

pub const CellDimensions = struct {
    width_px: usize,
    height_px: usize,
};

pub const ImageDimensions = struct {
    width_px: usize,
    height_px: usize,
};

pub const ImageRenderPolicy = struct {
    enabled: bool = true,
    width_cells: usize = 60,
    preserve_aspect_ratio: bool = true,

    pub fn effectiveWidth(self: ImageRenderPolicy, available_width_cells: usize) usize {
        if (available_width_cells == 0) return 1;
        return @max(@as(usize, 1), if (self.enabled)
            @min(available_width_cells, self.width_cells)
        else
            available_width_cells);
    }
};

pub const ImageRenderOptions = struct {
    max_width_cells: ?usize = null,
    max_height_cells: ?usize = null,
    preserve_aspect_ratio: bool = true,
    image_id: ?u32 = null,
    move_cursor: bool = true,
};

pub const RenderedImage = struct {
    sequence: []u8,
    rows: usize,
    image_id: ?u32 = null,

    pub fn deinit(self: *RenderedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.sequence);
        self.* = undefined;
    }
};

var cell_dimensions: CellDimensions = .{ .width_px = 9, .height_px = 18 };

const KITTY_PREFIX = "\x1b_G";
const ITERM2_PREFIX = "\x1b]1337;File=";

pub fn getCellDimensions() CellDimensions {
    return cell_dimensions;
}

pub fn setCellDimensions(dims: CellDimensions) void {
    cell_dimensions = dims;
}

pub fn detectCapabilities(env_map: *const std.process.Environ.Map) TerminalCapabilities {
    const features = terminal_capabilities.detect(env_map, .{});
    return .{
        .images = if (features.image_protocol) |protocol| switch (protocol) {
            .kitty => .kitty,
            .iterm2 => .iterm2,
        } else null,
        .true_color = features.true_color,
        .hyperlinks = features.hyperlinks,
    };
}

pub fn isImageLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, KITTY_PREFIX) != null or
        std.mem.indexOf(u8, line, ITERM2_PREFIX) != null;
}

pub fn allocateImageId() u32 {
    const raw = std.crypto.random.int(u32);
    return if (raw == 0) 1 else raw;
}

pub const KittyEncodeOptions = struct {
    columns: ?usize = null,
    rows: ?usize = null,
    image_id: ?u32 = null,
    move_cursor: bool = true,
};

pub fn encodeKitty(allocator: std.mem.Allocator, base64_data: []const u8, options: KittyEncodeOptions) ![]u8 {
    const chunk_size = 4096;
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    try params.appendSlice(allocator, "a=T,f=100,q=2");
    if (!options.move_cursor) try params.appendSlice(allocator, ",C=1");
    if (options.columns) |columns| try appendFmt(allocator, &params, ",c={d}", .{columns});
    if (options.rows) |rows| try appendFmt(allocator, &params, ",r={d}", .{rows});
    if (options.image_id) |image_id| try appendFmt(allocator, &params, ",i={d}", .{image_id});

    if (base64_data.len <= chunk_size) {
        return std.fmt.allocPrint(allocator, "\x1b_G{s};{s}\x1b\\", .{ params.items, base64_data });
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;
    var is_first = true;
    while (offset < base64_data.len) {
        const end = @min(offset + chunk_size, base64_data.len);
        const chunk = base64_data[offset..end];
        const is_last = end >= base64_data.len;
        if (is_first) {
            try appendFmt(allocator, &out, "\x1b_G{s},m=1;{s}\x1b\\", .{ params.items, chunk });
            is_first = false;
        } else if (is_last) {
            try appendFmt(allocator, &out, "\x1b_Gm=0;{s}\x1b\\", .{chunk});
        } else {
            try appendFmt(allocator, &out, "\x1b_Gm=1;{s}\x1b\\", .{chunk});
        }
        offset = end;
    }
    return out.toOwnedSlice(allocator);
}

pub fn deleteKittyImage(allocator: std.mem.Allocator, image_id: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

pub fn deleteAllKittyImages(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "\x1b_Ga=d,d=A,q=2\x1b\\");
}

pub const ITerm2EncodeOptions = struct {
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    name: ?[]const u8 = null,
    preserve_aspect_ratio: bool = true,
    inline_image: bool = true,
};

pub fn encodeITerm2(allocator: std.mem.Allocator, base64_data: []const u8, options: ITerm2EncodeOptions) ![]u8 {
    var params = std.ArrayList(u8).empty;
    defer params.deinit(allocator);
    try appendFmt(allocator, &params, "inline={d}", .{if (options.inline_image) @as(u8, 1) else 0});
    if (options.width) |width| try appendFmt(allocator, &params, ";width={s}", .{width});
    if (options.height) |height| try appendFmt(allocator, &params, ";height={s}", .{height});
    if (options.name) |name| {
        const encoded_name = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(name.len));
        defer allocator.free(encoded_name);
        _ = std.base64.standard.Encoder.encode(encoded_name, name);
        try appendFmt(allocator, &params, ";name={s}", .{encoded_name});
    }
    if (!options.preserve_aspect_ratio) try params.appendSlice(allocator, ";preserveAspectRatio=0");
    return std.fmt.allocPrint(allocator, "\x1b]1337;File={s}:{s}\x07", .{ params.items, base64_data });
}

pub fn calculateImageRows(image_dimensions: ImageDimensions, target_width_cells: usize, dims: CellDimensions) usize {
    const target_width_px = target_width_cells * dims.width_px;
    const scaled_height_px = divCeil(image_dimensions.height_px * target_width_px, image_dimensions.width_px);
    return @max(1, divCeil(scaled_height_px, dims.height_px));
}

pub fn getImageDimensions(allocator: std.mem.Allocator, base64_data: []const u8, mime_type: []const u8) !?ImageDimensions {
    const bytes = std.base64.standard.Decoder.calcSizeForSlice(base64_data) catch return null;
    const decoded = try allocator.alloc(u8, bytes);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, base64_data) catch return null;

    if (std.mem.eql(u8, mime_type, "image/png")) return getPngDimensionsFromBytes(decoded);
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return getJpegDimensionsFromBytes(decoded);
    if (std.mem.eql(u8, mime_type, "image/gif")) return getGifDimensionsFromBytes(decoded);
    if (std.mem.eql(u8, mime_type, "image/webp")) return getWebpDimensionsFromBytes(decoded);
    return null;
}

pub fn renderImage(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    base64_data: []const u8,
    image_dimensions: ImageDimensions,
    options: ImageRenderOptions,
) !?RenderedImage {
    const caps = detectCapabilities(env_map);
    const protocol = caps.images orelse return null;
    const max_width = options.max_width_cells orelse 80;
    const rows = calculateImageRows(image_dimensions, max_width, getCellDimensions());
    return switch (protocol) {
        .kitty => .{
            .sequence = try encodeKitty(allocator, base64_data, .{
                .columns = max_width,
                .rows = rows,
                .image_id = options.image_id,
                .move_cursor = options.move_cursor,
            }),
            .rows = rows,
            .image_id = options.image_id,
        },
        .iterm2 => blk: {
            const width = try std.fmt.allocPrint(allocator, "{d}", .{max_width});
            defer allocator.free(width);
            break :blk .{
                .sequence = try encodeITerm2(allocator, base64_data, .{
                    .width = width,
                    .height = "auto",
                    .preserve_aspect_ratio = options.preserve_aspect_ratio,
                }),
                .rows = rows,
            };
        },
    };
}

pub fn hyperlink(allocator: std.mem.Allocator, text: []const u8, url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, text });
}

pub fn imageFallback(allocator: std.mem.Allocator, mime_type: []const u8, dimensions: ?ImageDimensions, filename: ?[]const u8) ![]u8 {
    if (dimensions) |dims| {
        if (filename) |name| {
            return std.fmt.allocPrint(allocator, "[Image: {s} [{s}] {d}x{d}]", .{ name, mime_type, dims.width_px, dims.height_px });
        }
        return std.fmt.allocPrint(allocator, "[Image: [{s}] {d}x{d}]", .{ mime_type, dims.width_px, dims.height_px });
    }
    if (filename) |name| return std.fmt.allocPrint(allocator, "[Image: {s} [{s}]]", .{ name, mime_type });
    return std.fmt.allocPrint(allocator, "[Image: [{s}]]", .{mime_type});
}

fn envValue(env_map: *const std.process.Environ.Map, key: []const u8) []const u8 {
    return env_map.get(key) orelse "";
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn appendFmt(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try list.appendSlice(allocator, text);
}

fn divCeil(numerator: usize, denominator: usize) usize {
    return (numerator + denominator - 1) / denominator;
}

fn read16Be(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn read16Le(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read24Le(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 3 > bytes.len) return null;
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16);
}

fn read32Be(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) | (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn read32Le(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}

fn getPngDimensionsFromBytes(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..4], "\x89PNG")) return null;
    return .{
        .width_px = read32Be(bytes, 16) orelse return null,
        .height_px = read32Be(bytes, 20) orelse return null,
    };
}

fn getJpegDimensionsFromBytes(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 2 or bytes[0] != 0xff or bytes[1] != 0xd8) return null;
    var offset: usize = 2;
    while (offset + 9 < bytes.len) {
        if (bytes[offset] != 0xff) {
            offset += 1;
            continue;
        }
        const marker = bytes[offset + 1];
        if (marker >= 0xc0 and marker <= 0xc2) {
            return .{
                .height_px = read16Be(bytes, offset + 5) orelse return null,
                .width_px = read16Be(bytes, offset + 7) orelse return null,
            };
        }
        const length = read16Be(bytes, offset + 2) orelse return null;
        if (length < 2) return null;
        offset += 2 + length;
    }
    return null;
}

fn getGifDimensionsFromBytes(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 10) return null;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and !std.mem.eql(u8, bytes[0..6], "GIF89a")) return null;
    return .{
        .width_px = read16Le(bytes, 6) orelse return null,
        .height_px = read16Le(bytes, 8) orelse return null,
    };
}

fn getWebpDimensionsFromBytes(bytes: []const u8) ?ImageDimensions {
    if (bytes.len < 30) return null;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WEBP")) return null;
    if (std.mem.eql(u8, bytes[12..16], "VP8 ")) {
        return .{
            .width_px = (read16Le(bytes, 26) orelse return null) & 0x3fff,
            .height_px = (read16Le(bytes, 28) orelse return null) & 0x3fff,
        };
    }
    if (std.mem.eql(u8, bytes[12..16], "VP8L")) {
        const bits = read32Le(bytes, 21) orelse return null;
        return .{
            .width_px = (bits & 0x3fff) + 1,
            .height_px = ((bits >> 14) & 0x3fff) + 1,
        };
    }
    if (std.mem.eql(u8, bytes[12..16], "VP8X")) {
        return .{
            .width_px = (read24Le(bytes, 24) orelse return null) + 1,
            .height_px = (read24Le(bytes, 27) orelse return null) + 1,
        };
    }
    return null;
}

test "encodeKitty emits chunked graphics sequence" {
    const encoded = try encodeKitty(std.testing.allocator, "abc", .{ .columns = 10, .rows = 2, .image_id = 7 });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\x1b_Ga=T,f=100,q=2,c=10,r=2,i=7;abc\x1b\\", encoded);
}

test "detectCapabilities disables images inside tmux" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "kitty");
    try env.put("TMUX", "/tmp/tmux");
    const caps = detectCapabilities(&env);
    try std.testing.expect(caps.images == null);
    try std.testing.expect(!caps.hyperlinks);
}
