const std = @import("std");
const cli_args = @import("args.zig");
const runtime_prep = @import("runtime_prep.zig");
const coding_agent = @import("coding_agent");

pub const MissingSessionCwdPreflightContext = struct {
    cwd: []const u8,
    session_dir: []const u8,
    system_prompt: []const u8 = "",
    provider: []const u8 = "faux",
    session: ?[]const u8 = null,
    @"continue": bool = false,
    @"resume": bool = false,
    fork: ?[]const u8 = null,
    no_session: bool = false,
};

pub const MissingSessionCwdPreflightOutcome = struct {
    exit_code: ?u8 = null,
    continue_confirmed: bool = false,
};

pub fn resolvePreRuntimeSessionDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: *const cli_args.Args,
) ![]u8 {
    return try runtime_prep.resolvePreflightSessionDir(
        allocator,
        io,
        env_map,
        cwd,
        options,
    );
}

pub fn preRuntimeContext(
    cwd: []const u8,
    session_dir: []const u8,
    options: *const cli_args.Args,
) MissingSessionCwdPreflightContext {
    return .{
        .cwd = cwd,
        .session_dir = session_dir,
        // The pre-runtime preflight only inspects session files / stored cwd.
        // The system prompt and provider values are placeholders and are not
        // used by preflight resolution.
        .system_prompt = "",
        .provider = "faux",
        .session = options.session,
        .@"continue" = options.@"continue",
        .@"resume" = options.@"resume",
        .fork = options.fork,
        .no_session = options.no_session,
    };
}

pub fn preparedContext(
    cwd: []const u8,
    session_dir: []const u8,
    system_prompt: []const u8,
    provider: []const u8,
    options: *const cli_args.Args,
) MissingSessionCwdPreflightContext {
    return .{
        .cwd = cwd,
        .session_dir = session_dir,
        .system_prompt = system_prompt,
        .provider = provider,
        .session = options.session,
        .@"continue" = options.@"continue",
        .@"resume" = options.@"resume",
        .fork = options.fork,
        .no_session = options.no_session,
    };
}

pub fn runMissingSessionCwdPreflight(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    context: MissingSessionCwdPreflightContext,
    interactive: bool,
    stderr: *std.Io.Writer,
) !MissingSessionCwdPreflightOutcome {
    const preflight_options = runInteractiveOptionsFromContext(context);
    if (try coding_agent.interactive_mode.preflightInteractiveMissingCwd(
        allocator,
        io,
        preflight_options,
    )) |captured_preflight| {
        var captured_preflight_mut = captured_preflight;
        defer captured_preflight_mut.deinit(allocator);

        if (!interactive) {
            try writeMissingSessionCwdError(allocator, captured_preflight_mut.issue(), stderr);
            try stderr.flush();
            return .{ .exit_code = 1 };
        }

        const choice = try coding_agent.runMissingCwdSelector(
            allocator,
            io,
            env_map,
            captured_preflight_mut.issue(),
        );
        switch (choice) {
            .cancel => {
                try stderr.writeAll("Resume cancelled\n");
                try stderr.flush();
                return .{ .exit_code = 0 };
            },
            .continue_in_fallback => {
                return .{ .continue_confirmed = true };
            },
        }
    }

    return .{};
}

pub fn writeMissingSessionCwdError(
    allocator: std.mem.Allocator,
    issue: coding_agent.MissingSessionCwdIssue,
    stderr: *std.Io.Writer,
) !void {
    const message = try coding_agent.formatMissingSessionCwdError(allocator, issue);
    defer allocator.free(message);
    try stderr.print("Error: {s}\n", .{message});
}

pub fn writeMissingSessionCwdFallbackError(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("Error: stored session working directory does not exist\n");
}

fn runInteractiveOptionsFromContext(
    context: MissingSessionCwdPreflightContext,
) coding_agent.RunInteractiveModeOptions {
    return .{
        .cwd = context.cwd,
        .system_prompt = context.system_prompt,
        .session_dir = context.session_dir,
        .provider = context.provider,
        .session = context.session,
        .@"continue" = context.@"continue",
        .@"resume" = context.@"resume",
        .fork = context.fork,
        .no_session = context.no_session,
    };
}

test "writeMissingSessionCwdError keeps deterministic CLI diagnostic format" {
    const allocator = std.testing.allocator;
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try writeMissingSessionCwdError(
        allocator,
        .{
            .session_file = "/tmp/sessions/abc.jsonl",
            .session_cwd = "/tmp/missing",
            .fallback_cwd = "/tmp/current",
        },
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "Error: Stored session working directory does not exist: /tmp/missing\nSession file: /tmp/sessions/abc.jsonl\nCurrent working directory: /tmp/current\n",
        stderr_capture.writer.buffered(),
    );
}
