const std = @import("std");

const ParsedVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: ?[]const u8 = null,
};

fn parsePackageVersion(version: []const u8) ?ParsedVersion {
    const trimmed = std.mem.trim(u8, version, " \t\r\n");
    const start: usize = if (trimmed.len > 0 and trimmed[0] == 'v') 1 else 0;
    var index = start;
    const major = parseNumber(trimmed, &index) orelse return null;
    if (index >= trimmed.len or trimmed[index] != '.') return null;
    index += 1;
    const minor = parseNumber(trimmed, &index) orelse return null;
    if (index >= trimmed.len or trimmed[index] != '.') return null;
    index += 1;
    const patch = parseNumber(trimmed, &index) orelse return null;
    var prerelease: ?[]const u8 = null;
    if (index < trimmed.len and trimmed[index] == '-') {
        index += 1;
        const pre_start = index;
        while (index < trimmed.len and trimmed[index] != '+') : (index += 1) {}
        prerelease = trimmed[pre_start..index];
    }
    if (index < trimmed.len and trimmed[index] == '+') index = trimmed.len;
    if (index != trimmed.len) return null;
    return .{ .major = major, .minor = minor, .patch = patch, .prerelease = prerelease };
}

fn parseNumber(text: []const u8, index: *usize) ?u32 {
    var value: u32 = 0;
    const start = index.*;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {
        value = value * 10 + @as(u32, text[index.*] - '0');
    }
    return if (index.* == start) null else value;
}

pub fn comparePackageVersions(left_version: []const u8, right_version: []const u8) ?i32 {
    const left = parsePackageVersion(left_version) orelse return null;
    const right = parsePackageVersion(right_version) orelse return null;
    if (left.major != right.major) return @as(i32, @intCast(left.major)) - @as(i32, @intCast(right.major));
    if (left.minor != right.minor) return @as(i32, @intCast(left.minor)) - @as(i32, @intCast(right.minor));
    if (left.patch != right.patch) return @as(i32, @intCast(left.patch)) - @as(i32, @intCast(right.patch));
    if (left.prerelease == null and right.prerelease == null) return 0;
    if (left.prerelease == null) return 1;
    if (right.prerelease == null) return -1;
    return switch (std.mem.order(u8, left.prerelease.?, right.prerelease.?)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn isNewerPackageVersion(candidate_version: []const u8, current_version: []const u8) bool {
    if (comparePackageVersions(candidate_version, current_version)) |comparison| return comparison > 0;
    return !std.mem.eql(u8, std.mem.trim(u8, candidate_version, " \t\r\n"), std.mem.trim(u8, current_version, " \t\r\n"));
}

test "version check compares semver-like versions" {
    try std.testing.expect((comparePackageVersions("v1.2.3", "1.2.2") orelse 0) > 0);
    try std.testing.expect((comparePackageVersions("1.2.3-beta", "1.2.3") orelse 0) < 0);
    try std.testing.expect(isNewerPackageVersion("dev", "old"));
}
