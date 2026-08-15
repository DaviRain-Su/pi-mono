pub const ConfigSelectorOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
};

pub fn selectConfig(options: ConfigSelectorOptions) void {
    _ = options;
}

test "config selector facade accepts cwd and agent directory" {
    selectConfig(.{ .cwd = ".", .agent_dir = ".pi/agent" });
}
