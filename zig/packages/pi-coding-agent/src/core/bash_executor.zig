pub const bash = @import("../tools/bash.zig");
pub const truncate = @import("../tools/truncate.zig");

pub const BashResult = struct {
    output: []const u8,
    exit_code: ?i32 = null,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
};

test "bash executor facade imports builtin bash tool" {
    _ = bash;
}
