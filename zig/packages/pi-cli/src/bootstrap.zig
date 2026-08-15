const std = @import("std");
const cli = @import("args.zig");
const tool_selection = @import("coding_agent").tool_selection;

pub const AppMode = enum {
    interactive,
    print,
    json,
    rpc,
    ts_rpc,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) cli.ParseArgsError!cli.Args {
    return cli.parseArgs(allocator, argv);
}

pub fn parseErrorMessage(err: cli.ParseArgsError) []const u8 {
    return switch (err) {
        error.MissingOptionValue => "Missing value for option",
        error.InvalidMode => "Invalid mode. Expected one of: text, json, rpc, json-rpc, ts-rpc",
        error.InvalidThinkingLevel => "Invalid thinking level. Expected one of: off, minimal, low, medium, high, xhigh",
        error.UnknownOption => "Unknown option",
        error.OutOfMemory => "Out of memory while parsing CLI arguments",
    };
}

pub fn resolveAppMode(mode: cli.Mode, print_requested: bool, stdin_is_tty: bool) AppMode {
    return switch (mode) {
        .rpc => .rpc,
        .ts_rpc => .ts_rpc,
        .json => .json,
        .text => if (print_requested or !stdin_is_tty) .print else .interactive,
    };
}

pub fn effectiveToolSelection(options: *const cli.Args) tool_selection.ToolSelection {
    return tool_selection.ToolSelection.fromCli(options.no_tools, options.no_builtin_tools, options.tools);
}

pub fn offlineModeEnabled(options: *const cli.Args, env_map: *const std.process.Environ.Map) bool {
    return options.offline or isTruthyEnvFlag(env_map.get("PI_OFFLINE"));
}

pub fn startupNetworkOperationsEnabled(options: *const cli.Args, env_map: *const std.process.Environ.Map) bool {
    return !offlineModeEnabled(options, env_map);
}

fn isTruthyEnvFlag(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(text, "1") or
        std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on");
}

test "resolveAppMode keeps TUI default" {
    try std.testing.expectEqual(AppMode.interactive, resolveAppMode(.text, false, true));
    try std.testing.expectEqual(AppMode.print, resolveAppMode(.text, false, false));
    try std.testing.expectEqual(AppMode.print, resolveAppMode(.text, true, true));
}
