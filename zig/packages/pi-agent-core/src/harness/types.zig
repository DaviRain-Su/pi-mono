pub const HarnessRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const HarnessMessage = struct {
    role: HarnessRole,
    content: []const u8,
};

pub const HarnessDiagnostic = struct {
    kind: []const u8,
    message: []const u8,
};
