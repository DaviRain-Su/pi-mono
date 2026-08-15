const std = @import("std");
const cli_mod = @import("cli");
const cli = cli_mod.args;
const bootstrap = cli_mod.bootstrap;
const cli_config_selector = cli_mod.config_selector;
const package_command_dispatch = cli_mod.package_command_dispatch;
const cli_preflight = cli_mod.preflight;
const extension_cli = cli_mod.extension_cli;
const file_processor = cli_mod.file_processor;
const initial_message = cli_mod.initial_message;
const input_prep = cli_mod.input_prep;
const list_models = cli_mod.list_models;
const runtime_prep = cli_mod.runtime_prep;
const run_mode_dispatch = cli_mod.run_mode_dispatch;
const session_picker = cli_mod.session_picker;
const output = cli_mod.output;
const coding_agent = @import("coding_agent");
const auth = coding_agent.auth;

const builtin = @import("builtin");
const Main = @This();

const VERSION = "0.1.0";

const CliStdin = input_prep.CliStdin;
const offlineModeEnabled = bootstrap.offlineModeEnabled;
const startupNetworkOperationsEnabled = bootstrap.startupNetworkOperationsEnabled;

test {
    _ = cli_config_selector;
    _ = file_processor;
    _ = initial_message;
    _ = list_models;
    _ = session_picker;
    _ = @import("main_tests.zig");
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(init.gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        try argv.append(init.gpa, arg);
    }

    const exit_code = try runCliWithInput(init.gpa, init.io, init.environ_map, argv.items, null, null, stdout, stderr);
    try output.flushWriters(stdout, stderr);
    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var stdin_input = CliStdin{};
    return runCliWithInput(allocator, io, env_map, argv, cwd_override, &stdin_input, stdout, stderr);
}

fn runCliWithInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    provided_stdin: ?*CliStdin,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    defer auth.clearCommandResultCache();
    if (try package_command_dispatch.dispatchPackageCommand(
        allocator,
        io,
        env_map,
        argv,
        cwd_override,
        stdout,
        stderr,
    )) |exit_code| {
        return exit_code;
    }

    if (try cli_mod.auth_command_dispatch.dispatchAuthCommand(
        allocator,
        io,
        env_map,
        argv,
        stdout,
        stderr,
    )) |exit_code| {
        return exit_code;
    }

    var options = bootstrap.parseArgs(allocator, argv) catch |err| {
        try stderr.print("Error: {s}\n\n", .{bootstrap.parseErrorMessage(err)});
        try output.printUsage(allocator, VERSION, stdout);
        return 1;
    };
    defer options.deinit(allocator);

    var prepared_extensions = extension_cli.PreparedExtensionCli.init(allocator);
    defer prepared_extensions.deinit();
    try prepared_extensions.loadFlagSidecars(io, options.extensions);

    if (options.help) {
        const help_flags = try prepared_extensions.snapshotHelpFlags(allocator);
        defer allocator.free(help_flags);
        const help_flag_diagnostics = try prepared_extensions.snapshotHelpDiagnostics(allocator);
        defer allocator.free(help_flag_diagnostics);
        try output.printUsageWithExtensionDiagnostics(allocator, VERSION, help_flags, help_flag_diagnostics, stdout);
        return 0;
    }

    if (options.version) {
        try output.printVersion(allocator, VERSION, stdout);
        return 0;
    }

    if (extension_cli.shouldRunRegistryDump(env_map, options.extensions)) {
        if (!try prepared_extensions.applyUnknownFlagsForRegistryDump(options.unknown_flags, stderr)) return 1;
        const paths = options.extensions.?;
        return try extension_cli.runExtensionRegistryDump(
            allocator,
            io,
            env_map,
            paths,
            prepared_extensions.rejectedFlagDiagnostics(),
            prepared_extensions.parsedCliFlagValues(),
            cwd_override,
            stdout,
            stderr,
        );
    }

    if (!try prepared_extensions.applyUnknownFlags(options.unknown_flags, stderr)) return 1;

    var effective_env_map = try prepareEffectiveEnvMap(allocator, env_map, &options);
    defer effective_env_map.deinit();

    if (options.@"export") |session_file| {
        const output_path = if (options.messages) |messages| if (messages.len > 0) messages[0] else null else null;
        return output.runSessionExport(allocator, io, &effective_env_map, cwd_override, session_file, output_path, stdout, stderr) catch |err| {
            try stderr.print("Error: {s}\n", .{output.exportErrorMessage(err)});
            return 1;
        };
    }

    var detected_stdin = if (provided_stdin) |stdin_override|
        CliStdin{
            .is_tty = stdin_override.is_tty,
            .content = stdin_override.content,
            .owns_content = false,
        }
    else
        try input_prep.detectCliStdin(allocator, io, options.mode);
    defer if (provided_stdin == null) detected_stdin.deinit(allocator);

    if (options.list_models) {
        return try output.printModelList(
            allocator,
            io,
            &effective_env_map,
            options.list_models_search,
            startupNetworkOperationsEnabled(&options, &effective_env_map),
            stdout,
        );
    }

    if (options.fork != null and
        (options.session != null or options.@"continue" or options.@"resume" or options.no_session))
    {
        try stderr.writeAll("Error: --fork cannot be combined with --session, --continue, --resume, or --no-session\n");
        return 1;
    }

    if ((options.mode == .rpc or options.mode == .ts_rpc) and options.messages != null) {
        try stderr.writeAll("Error: Prompt arguments are not supported in RPC mode\n");
        return 1;
    }

    if ((options.mode == .rpc or options.mode == .ts_rpc) and options.file_args != null) {
        try stderr.writeAll("Error: @file arguments are not supported in RPC mode\n");
        return 1;
    }

    const app_mode = bootstrap.resolveAppMode(options.mode, options.print, detected_stdin.is_tty);
    const selected_tools = bootstrap.effectiveToolSelection(&options);
    const cwd = if (cwd_override) |override| blk: {
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    // M10 lifecycle ordering: surface a missing stored-cwd diagnostic BEFORE
    // `prepareCliRuntime` runs. `prepareCliRuntime` loads runtime config,
    // resource bundles, context files, the system prompt, and may select an
    // initial provider/model. Any of those steps can fail (invalid settings,
    // bad context files, unknown provider, etc.) and would otherwise
    // preempt the missing-cwd diagnostic that the user actually needs to
    // see. Mirrors TS `main.ts` ordering, which checks
    // `getMissingSessionCwdIssue` before constructing the runtime.
    //
    // The interactive path additionally prompts the user via the same
    // Continue/Cancel selector that the post-bootstrap guard uses; on
    // Continue we set `missing_cwd_already_confirmed` so the deeper
    // bootstrap path does not prompt twice.
    var preflight_continue_confirmed = false;
    {
        const preflight_session_dir = try cli_preflight.resolvePreRuntimeSessionDir(
            allocator,
            io,
            &effective_env_map,
            cwd,
            &options,
        );
        defer allocator.free(preflight_session_dir);

        const preflight_result = try cli_preflight.runMissingSessionCwdPreflight(
            allocator,
            io,
            &effective_env_map,
            cli_preflight.preRuntimeContext(cwd, preflight_session_dir, &options),
            app_mode == .interactive,
            stderr,
        );
        if (preflight_result.exit_code) |exit_code| return exit_code;
        preflight_continue_confirmed = preflight_result.continue_confirmed;
    }

    var prepared = try runtime_prep.prepareCliRuntime(
        allocator,
        io,
        &effective_env_map,
        cwd,
        &options,
        selected_tools,
        app_mode == .interactive,
    );
    defer prepared.deinit(allocator);
    try output.writeResourceDiagnostics(stderr, prepared.resource_bundle.diagnostics);

    var initial_input = input_prep.prepareInitialInput(
        allocator,
        io,
        &effective_env_map,
        cwd,
        options.file_args,
        prepared.expanded_messages,
        detected_stdin.content,
        stderr,
        .{ .auto_resize_images = prepared.runtime_config.imageAutoResize() },
    ) catch |err| switch (err) {
        error.CliInputFailed => return 1,
        else => return err,
    };
    defer initial_input.deinit(allocator);

    return try run_mode_dispatch.dispatchRunMode(
        allocator,
        io,
        &effective_env_map,
        &options,
        &prepared,
        &initial_input,
        .{
            .cwd = cwd,
            .app_mode = app_mode,
            .selected_tools = selected_tools,
            .preflight_continue_confirmed = preflight_continue_confirmed,
            .version = VERSION,
        },
        stdout,
        stderr,
    );
}

fn prepareEffectiveEnvMap(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    options: *const cli.Args,
) !std.process.Environ.Map {
    var effective_env_map = try env_map.clone(allocator);
    errdefer effective_env_map.deinit();

    if (offlineModeEnabled(options, env_map)) {
        try effective_env_map.put("PI_OFFLINE", "1");
        try effective_env_map.put("PI_SKIP_VERSION_CHECK", "1");
    }

    return effective_env_map;
}

pub const testing = if (builtin.is_test) struct {
    pub const version = VERSION;
    pub const CliStdin = input_prep.CliStdin;

    pub fn runCliWithInput(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        argv: []const []const u8,
        cwd_override: ?[]const u8,
        provided_stdin: ?*input_prep.CliStdin,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !u8 {
        return Main.runCliWithInput(
            allocator,
            io,
            env_map,
            argv,
            cwd_override,
            provided_stdin,
            stdout,
            stderr,
        );
    }

    pub fn prepareEffectiveEnvMap(
        allocator: std.mem.Allocator,
        env_map: *const std.process.Environ.Map,
        options: *const cli.Args,
    ) !std.process.Environ.Map {
        return Main.prepareEffectiveEnvMap(allocator, env_map, options);
    }
} else struct {};
