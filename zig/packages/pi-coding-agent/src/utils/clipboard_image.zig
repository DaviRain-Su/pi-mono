const std = @import("std");
const builtin = @import("builtin");

pub const ClipboardImage = struct {
    bytes: []u8,
    mime_type: []u8,

    pub fn deinit(self: *ClipboardImage, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

const supported_image_mime_types = [_][]const u8{ "image/png", "image/jpeg", "image/webp", "image/gif" };

pub fn isWaylandSession(env_map: *const std.process.Environ.Map) bool {
    if (env_map.get("WAYLAND_DISPLAY") != null) return true;
    if (env_map.get("XDG_SESSION_TYPE")) |value| return std.mem.eql(u8, value, "wayland");
    return false;
}

pub fn extensionForImageMimeType(mime_type: []const u8) ?[]const u8 {
    const base = baseMimeType(mime_type);
    if (std.ascii.eqlIgnoreCase(base, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(base, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(base, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(base, "image/gif")) return "gif";
    return null;
}

pub fn selectPreferredImageMimeType(mime_types: []const []const u8) ?[]const u8 {
    for (supported_image_mime_types) |preferred| {
        for (mime_types) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(baseMimeType(trimmed), preferred)) return trimmed;
        }
    }

    for (mime_types) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (startsWithIgnoreCase(baseMimeType(trimmed), "image/")) return trimmed;
    }

    return null;
}

pub fn isSupportedImageMimeType(mime_type: []const u8) bool {
    const base = baseMimeType(mime_type);
    for (supported_image_mime_types) |supported| {
        if (std.ascii.eqlIgnoreCase(base, supported)) return true;
    }
    return false;
}

pub fn readClipboardImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    if (env_map.get("TERMUX_VERSION") != null) return null;

    if (builtin.os.tag == .linux) {
        if (isWaylandSession(env_map)) {
            if (try readClipboardImageViaWlPaste(allocator, io)) |image| return image;
        }
        if (env_map.get("DISPLAY") != null or isWaylandSession(env_map)) {
            if (try readClipboardImageViaXclip(allocator, io)) |image| return image;
        }
    }

    return null;
}

fn readClipboardImageViaWlPaste(allocator: std.mem.Allocator, io: std.Io) !?ClipboardImage {
    const list = runCommand(allocator, io, &.{ "wl-paste", "--list-types" }) catch return null;
    defer allocator.free(list);
    if (list.len == 0) return null;

    var mime_list = std.ArrayList([]const u8).empty;
    defer mime_list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) try mime_list.append(allocator, trimmed);
    }

    const selected = selectPreferredImageMimeType(mime_list.items) orelse return null;
    const data = runCommand(allocator, io, &.{ "wl-paste", "--type", selected, "--no-newline" }) catch return null;
    errdefer allocator.free(data);
    if (data.len == 0) {
        allocator.free(data);
        return null;
    }

    const mime = try allocator.dupe(u8, baseMimeType(selected));
    errdefer allocator.free(mime);
    return .{ .bytes = data, .mime_type = mime };
}

fn readClipboardImageViaXclip(allocator: std.mem.Allocator, io: std.Io) !?ClipboardImage {
    var candidates = std.ArrayList([]const u8).empty;
    defer candidates.deinit(allocator);

    if (runCommand(allocator, io, &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" })) |targets| {
        defer allocator.free(targets);
        var lines = std.mem.splitScalar(u8, targets, '\n');
        var target_list = std.ArrayList([]const u8).empty;
        defer target_list.deinit(allocator);
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) try target_list.append(allocator, trimmed);
        }
        if (selectPreferredImageMimeType(target_list.items)) |preferred| try candidates.append(allocator, preferred);
    } else |_| {}

    for (supported_image_mime_types) |mime_type| try candidates.append(allocator, mime_type);

    for (candidates.items) |mime_type| {
        const data = runCommand(allocator, io, &.{ "xclip", "-selection", "clipboard", "-t", mime_type, "-o" }) catch continue;
        errdefer allocator.free(data);
        if (data.len == 0) {
            allocator.free(data);
            continue;
        }
        const mime = try allocator.dupe(u8, baseMimeType(mime_type));
        errdefer allocator.free(mime);
        return .{ .bytes = data, .mime_type = mime };
    }

    return null;
}

fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (exitCodeFromTerm(result.term) != 0) return error.CommandFailed;
    return result.stdout;
}

fn baseMimeType(mime_type: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, mime_type, ';') orelse mime_type.len;
    return std.mem.trim(u8, mime_type[0..semi], " \t\r\n");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

test "clipboard image detects wayland sessions" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try std.testing.expect(!isWaylandSession(&env_map));
    try env_map.put("XDG_SESSION_TYPE", "wayland");
    try std.testing.expect(isWaylandSession(&env_map));
}

test "clipboard image maps supported image extensions" {
    try std.testing.expectEqualStrings("png", extensionForImageMimeType("image/png").?);
    try std.testing.expectEqualStrings("jpg", extensionForImageMimeType("image/jpeg; charset=binary").?);
    try std.testing.expectEqual(null, extensionForImageMimeType("text/plain"));
}

test "clipboard image selects preferred mime type" {
    const values = [_][]const u8{ "image/bmp", " image/webp ", "image/png" };
    try std.testing.expectEqualStrings("image/png", selectPreferredImageMimeType(&values).?);
}
