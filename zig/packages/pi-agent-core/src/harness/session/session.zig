pub const HarnessSession = struct {
    id: []const u8,
    title: ?[]const u8 = null,
};

pub fn sessionTitle(session: HarnessSession) []const u8 {
    return session.title orelse session.id;
}
