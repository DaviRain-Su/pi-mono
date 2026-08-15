const std = @import("std");

pub const ExecOptions = struct {
    timeout_ms: ?u64 = null,
    cwd: ?[]const u8 = null,
};

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    killed: bool = false,

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn execCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    options: ExecOptions,
) !ExecResult {
    _ = options.timeout_ms;
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = command;
    for (args, 0..) |arg, index| argv[index + 1] = arg;

    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = argv,
        .cwd = .{ .path = options.cwd orelse cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = switch (result.term) {
            .exited => |code| code,
            else => 1,
        },
        .killed = switch (result.term) {
            .signal, .stopped, .unknown => true,
            else => false,
        },
    };
}

test "exec result owns captured buffers" {
    var result = ExecResult{
        .stdout = try std.testing.allocator.dupe(u8, "out"),
        .stderr = try std.testing.allocator.dupe(u8, "err"),
        .code = 0,
    };
    result.deinit(std.testing.allocator);
}
