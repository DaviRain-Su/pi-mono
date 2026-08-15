const std = @import("std");

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const ChangelogEntry = struct {
    major: u32,
    minor: u32,
    patch: u32,
    content: []u8,

    pub fn deinit(self: *ChangelogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn parseChangelog(allocator: std.mem.Allocator, io: std.Io, changelog_path: []const u8) ![]ChangelogEntry {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, changelog_path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(content);
    return parseChangelogContent(allocator, content);
}

pub fn parseChangelogContent(allocator: std.mem.Allocator, content: []const u8) ![]ChangelogEntry {
    var entries: std.ArrayList(ChangelogEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var current_version: ?Version = null;
    var current_lines: std.ArrayList(u8) = .empty;
    defer current_lines.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.startsWith(u8, line, "## ")) {
            if (current_version) |version| {
                if (current_lines.items.len > 0) {
                    try entries.append(allocator, .{
                        .major = version.major,
                        .minor = version.minor,
                        .patch = version.patch,
                        .content = try allocator.dupe(u8, std.mem.trim(u8, current_lines.items, " \t\r\n")),
                    });
                }
            }
            current_lines.clearRetainingCapacity();
            current_version = parseVersionHeader(line);
            if (current_version != null) try appendLine(allocator, &current_lines, line);
        } else if (current_version != null) {
            try appendLine(allocator, &current_lines, line);
        }
    }

    if (current_version) |version| {
        if (current_lines.items.len > 0) {
            try entries.append(allocator, .{
                .major = version.major,
                .minor = version.minor,
                .patch = version.patch,
                .content = try allocator.dupe(u8, std.mem.trim(u8, current_lines.items, " \t\r\n")),
            });
        }
    }

    return entries.toOwnedSlice(allocator);
}

fn appendLine(allocator: std.mem.Allocator, list: *std.ArrayList(u8), line: []const u8) !void {
    if (list.items.len > 0) try list.append(allocator, '\n');
    try list.appendSlice(allocator, line);
}

fn parseVersionHeader(line: []const u8) ?Version {
    var index: usize = 3;
    while (index < line.len and (line[index] == ' ' or line[index] == '[')) : (index += 1) {}
    const major = parseNumber(line, &index) orelse return null;
    if (index >= line.len or line[index] != '.') return null;
    index += 1;
    const minor = parseNumber(line, &index) orelse return null;
    if (index >= line.len or line[index] != '.') return null;
    index += 1;
    const patch = parseNumber(line, &index) orelse return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseNumber(text: []const u8, index: *usize) ?u32 {
    var value: u32 = 0;
    const start = index.*;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {
        value = value * 10 + @as(u32, text[index.*] - '0');
    }
    return if (index.* == start) null else value;
}

pub fn compareVersions(left: ChangelogEntry, right: ChangelogEntry) i32 {
    if (left.major != right.major) return @as(i32, @intCast(left.major)) - @as(i32, @intCast(right.major));
    if (left.minor != right.minor) return @as(i32, @intCast(left.minor)) - @as(i32, @intCast(right.minor));
    return @as(i32, @intCast(left.patch)) - @as(i32, @intCast(right.patch));
}

pub fn getNewEntries(allocator: std.mem.Allocator, entries: []const ChangelogEntry, last_version: []const u8) ![]ChangelogEntry {
    var index: usize = 0;
    const last = parseLooseVersion(last_version);
    var out: std.ArrayList(ChangelogEntry) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(allocator);
        out.deinit(allocator);
    }
    while (index < entries.len) : (index += 1) {
        if (compareVersions(entries[index], last) > 0) {
            try out.append(allocator, .{
                .major = entries[index].major,
                .minor = entries[index].minor,
                .patch = entries[index].patch,
                .content = try allocator.dupe(u8, entries[index].content),
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn parseLooseVersion(version: []const u8) ChangelogEntry {
    var it = std.mem.splitScalar(u8, version, '.');
    return .{
        .major = parseU32(it.next() orelse "") orelse 0,
        .minor = parseU32(it.next() orelse "") orelse 0,
        .patch = parseU32(it.next() orelse "") orelse 0,
        .content = "",
    };
}

fn parseU32(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

test "parseChangelogContent collects version sections" {
    const content =
        \\# Changelog
        \\## [1.2.3]
        \\### Fixed
        \\- bug
        \\## [1.2.2]
        \\old
    ;
    const entries = try parseChangelogContent(std.testing.allocator, content);
    defer {
        for (entries) |*entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u32, 1), entries[0].major);
    try std.testing.expectEqual(@as(u32, 2), entries[0].minor);
    try std.testing.expectEqual(@as(u32, 3), entries[0].patch);
    try std.testing.expect(std.mem.indexOf(u8, entries[0].content, "bug") != null);
}
