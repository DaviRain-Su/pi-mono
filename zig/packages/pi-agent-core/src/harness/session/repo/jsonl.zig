const shared = @import("shared.zig");

pub const JsonlSessionRepo = struct {
    root_dir: []const u8,
};

pub fn recordForPath(id: []const u8, path: []const u8) shared.SessionRecord {
    return .{ .id = id, .path = path };
}
