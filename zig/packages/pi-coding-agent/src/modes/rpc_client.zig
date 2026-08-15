const std = @import("std");

pub const RpcClientOptions = struct {
    cli_path: []const u8 = "pi",
    cwd: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

pub const RpcClient = struct {
    options: RpcClientOptions = .{},

    pub fn init(options: RpcClientOptions) RpcClient {
        return .{ .options = options };
    }

    pub fn buildArgv(self: *const RpcClient, allocator: std.mem.Allocator) ![]const []const u8 {
        return buildRpcArgv(allocator, self.options);
    }
};

pub fn buildRpcArgv(allocator: std.mem.Allocator, options: RpcClientOptions) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(allocator);

    try argv.append(allocator, options.cli_path);
    try argv.append(allocator, "--mode");
    try argv.append(allocator, "rpc");

    if (options.provider) |provider| {
        try argv.append(allocator, "--provider");
        try argv.append(allocator, provider);
    }
    if (options.model) |model| {
        try argv.append(allocator, "--model");
        try argv.append(allocator, model);
    }
    try argv.appendSlice(allocator, options.args);

    return try argv.toOwnedSlice(allocator);
}

test "buildRpcArgv matches TypeScript rpc client startup mode" {
    const argv = try buildRpcArgv(std.testing.allocator, .{
        .cli_path = "dist/cli.js",
        .provider = "faux",
        .model = "faux-model",
        .args = &.{"--no-session"},
    });
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqualStrings("dist/cli.js", argv[0]);
    try std.testing.expectEqualStrings("--mode", argv[1]);
    try std.testing.expectEqualStrings("rpc", argv[2]);
    try std.testing.expectEqualStrings("--provider", argv[3]);
    try std.testing.expectEqualStrings("faux", argv[4]);
    try std.testing.expectEqualStrings("--model", argv[5]);
    try std.testing.expectEqualStrings("faux-model", argv[6]);
    try std.testing.expectEqualStrings("--no-session", argv[7]);
}
