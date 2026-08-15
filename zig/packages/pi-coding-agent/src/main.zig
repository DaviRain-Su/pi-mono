pub const root = @import("root.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 1,
    runtime = 2,
};

test "main facade exposes root module" {
    _ = root;
}
