pub const ShellOutput = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: i32 = 0,
};

pub fn succeeded(output: ShellOutput) bool {
    return output.exit_code == 0;
}
