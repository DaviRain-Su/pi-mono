const std = @import("std");

const RequiredExternalTool = struct {
    names: []const []const u8,
    display_name: []const u8,
    reason: []const u8,
};

const required_external_tools = [_]RequiredExternalTool{
    .{
        .names = &[_][]const u8{"rg"},
        .display_name = "ripgrep (rg)",
        .reason = "required by the coding-agent grep tool",
    },
    .{
        .names = &[_][]const u8{"fd"},
        .display_name = "fd",
        .reason = "required by the coding-agent find tool",
    },
};

const ParityExecutableRunOptions = struct {
    name: []const u8,
    root_source_path: []const u8,
    step_name: []const u8,
    step_description: []const u8,
};

const ParityScriptStepOptions = struct {
    script_path: []const u8,
    step_name: []const u8,
    step_description: []const u8,
    command_depends_on_external_tools: bool = false,
    command_depends_on_install: bool = false,
    step_depends_on_external_tools: bool = false,
};

const ProviderParitySuiteOptions = struct {
    executable_name: []const u8,
    executable_root_source_path: []const u8,
    run_step_name: []const u8,
    run_step_description: []const u8,
    script_path: []const u8,
    test_step_name: []const u8,
    test_step_description: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const external_tool_check_step = addExternalToolCheckStep(b);
    const types_dep = b.dependency("pi_types", .{
        .target = target,
        .optimize = optimize,
    });
    const shared_dep = b.dependency("pi_shared", .{
        .target = target,
        .optimize = optimize,
    });
    const ai_dep = b.dependency("pi_ai", .{
        .target = target,
        .optimize = optimize,
    });
    const agent_dep = b.dependency("pi_agent_core", .{
        .target = target,
        .optimize = optimize,
    });
    const tui_dep = b.dependency("pi_tui", .{
        .target = target,
        .optimize = optimize,
    });
    const coding_dep = b.dependency("pi_coding_agent", .{
        .target = target,
        .optimize = optimize,
    });
    const cli_dep = b.dependency("pi_cli", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const types_mod = types_dep.module("pi-types");
    const shared_mod = shared_dep.module("shared");
    const ai_mod = ai_dep.module("ai");
    const agent_mod = agent_dep.module("agent");
    const tui_mod = tui_dep.module("tui");
    const coding_agent_mod = coding_dep.module("coding_agent");
    const cli_mod = cli_dep.module("cli");
    const zigimg_mod = zigimg_dep.module("zigimg");
    const version = b.option([]const u8, "version", "Application version") orelse "0.16.0";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", build_options);
    mod.addImport("pi-types", types_mod);
    mod.addImport("ai", ai_mod);
    mod.addImport("agent", agent_mod);
    mod.addImport("shared", shared_mod);
    mod.addImport("tui", tui_mod);
    mod.addImport("coding_agent", coding_agent_mod);
    mod.addImport("cli", cli_mod);
    mod.addImport("zigimg", zigimg_mod);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "pi",
        .root_module = mod,
    });
    b.installArtifact(exe);
    b.getInstallStep().dependOn(external_tool_check_step);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(external_tool_check_step);
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(external_tool_check_step);

    const tidy_fail_on_warning = b.option(
        bool,
        "tidy-fail-on-warning",
        "Make `zig build test-tidy` fail when tidy warnings are reported",
    ) orelse false;
    const coding_agent_test_filters = b.option(
        []const []const u8,
        "coding-agent-test-filter",
        "Only run coding-agent tests whose names contain this filter",
    ) orelse &.{};
    const tidy_mod = b.createModule(.{
        .root_source_file = b.path("test/tidy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tidy_exe = b.addExecutable(.{
        .name = "zig-tidy",
        .root_module = tidy_mod,
    });
    const run_tidy = b.addRunArtifact(tidy_exe);
    if (tidy_fail_on_warning) run_tidy.addArg("--fail-on-warning");
    if (b.args) |args| run_tidy.addArgs(args);
    const tidy_tests = b.addTest(.{
        .root_module = tidy_mod,
    });
    const run_tidy_tests = b.addRunArtifact(tidy_tests);
    const tidy_step = b.step("test-tidy", "Run Zig source tidy guardrails");
    tidy_step.dependOn(&run_tidy_tests.step);
    tidy_step.dependOn(&run_tidy.step);

    const import_boundaries = addParityScriptStep(b, external_tool_check_step, .{
        .script_path = "test/import-boundaries.sh",
        .step_name = "test-import-boundaries",
        .step_description = "Run Zig import boundary guardrails",
        .command_depends_on_external_tools = true,
        .step_depends_on_external_tools = true,
    });
    tidy_step.dependOn(&import_boundaries.step);
    test_step.dependOn(&import_boundaries.step);

    const ts_rpc_parity = addParityScriptStep(b, external_tool_check_step, .{
        .script_path = "test/ts-rpc-parity.sh",
        .step_name = "test-ts-rpc-parity",
        .step_description = "Run TS-vs-Zig ts-rpc exact-byte parity harness",
        .command_depends_on_install = true,
        .step_depends_on_external_tools = true,
    });
    test_step.dependOn(&ts_rpc_parity.step);

    const provider_parity_suites = [_]ProviderParitySuiteOptions{
        .{
            .executable_name = "openai-chat-parity",
            .executable_root_source_path = "test/openai_chat_parity.zig",
            .run_step_name = "run-openai-chat-parity",
            .run_step_description = "Run Zig OpenAI Chat fixture parity comparator",
            .script_path = "test/openai-chat-parity.sh",
            .test_step_name = "test-openai-chat-parity",
            .test_step_description = "Run OpenAI Chat TypeScript-vs-Zig semantic request parity harness",
        },
        .{
            .executable_name = "openai-responses-parity",
            .executable_root_source_path = "test/openai_responses_parity.zig",
            .run_step_name = "run-openai-responses-parity",
            .run_step_description = "Run Zig OpenAI Responses fixture parity comparator",
            .script_path = "test/openai-responses-parity.sh",
            .test_step_name = "test-openai-responses-parity",
            .test_step_description = "Run OpenAI Responses TypeScript-vs-Zig semantic request parity harness",
        },
        .{
            .executable_name = "bedrock-parity",
            .executable_root_source_path = "test/bedrock_parity.zig",
            .run_step_name = "run-bedrock-parity",
            .run_step_description = "Run Zig Bedrock fixture parity comparator",
            .script_path = "test/bedrock-parity.sh",
            .test_step_name = "test-bedrock-parity",
            .test_step_description = "Run Bedrock TypeScript-vs-Zig semantic request and stream parity harness",
        },
    };
    for (provider_parity_suites) |provider_parity_suite| {
        addProviderParitySuite(b, target, optimize, ai_mod, external_tool_check_step, provider_parity_suite);
    }

    const shared_tests = b.addTest(.{
        .root_module = shared_mod,
    });
    const run_shared_tests = b.addRunArtifact(shared_tests);
    test_step.dependOn(&run_shared_tests.step);

    const shared_test_step = b.step("test-shared", "Run shared utility unit tests only");
    shared_test_step.dependOn(&run_shared_tests.step);

    const ai_tests = b.addTest(.{
        .root_module = ai_mod,
    });
    const run_ai_tests = b.addRunArtifact(ai_tests);
    test_step.dependOn(&run_ai_tests.step);

    const ai_test_step = b.step("test-ai", "Run AI unit tests only");
    ai_test_step.dependOn(external_tool_check_step);
    ai_test_step.dependOn(&run_ai_tests.step);

    const agent_tests = b.addTest(.{
        .root_module = agent_mod,
    });
    const run_agent_tests = b.addRunArtifact(agent_tests);
    test_step.dependOn(&run_agent_tests.step);

    const agent_test_step = b.step("test-agent", "Run agent unit tests only");
    agent_test_step.dependOn(external_tool_check_step);
    agent_test_step.dependOn(&run_agent_tests.step);

    const coding_agent_tests = b.addTest(.{
        .root_module = coding_agent_mod,
        .filters = coding_agent_test_filters,
    });
    const run_coding_agent_tests = b.addRunArtifact(coding_agent_tests);
    run_coding_agent_tests.setCwd(b.path("."));
    test_step.dependOn(&run_coding_agent_tests.step);

    const coding_agent_test_step = b.step("test-coding-agent", "Run coding-agent unit tests only");
    coding_agent_test_step.dependOn(external_tool_check_step);
    coding_agent_test_step.dependOn(&run_coding_agent_tests.step);
    agent_test_step.dependOn(&run_coding_agent_tests.step);

    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_mod.addImport("pi-types", types_mod);
    main_test_mod.addImport("ai", ai_mod);
    main_test_mod.addImport("agent", agent_mod);
    main_test_mod.addImport("shared", shared_mod);
    main_test_mod.addImport("tui", tui_mod);
    main_test_mod.addImport("coding_agent", coding_agent_mod);
    main_test_mod.addImport("cli", cli_mod);
    main_test_mod.addImport("zigimg", zigimg_mod);
    main_test_mod.addOptions("build_options", build_options);

    const main_tests = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    run_main_tests.step.dependOn(b.getInstallStep());
    run_main_tests.step.dependOn(&run_coding_agent_tests.step);
    run_main_tests.step.dependOn(&ts_rpc_parity.step);
    test_step.dependOn(&run_main_tests.step);

    if (target.result.os.tag != .windows) {
        const tui_extra_paths = getExtraToolPaths(b.allocator);
        defer freeExtraToolPaths(b.allocator, tui_extra_paths);
        const tuistory_available = (b.findProgram(&.{"tuistory"}, tui_extra_paths) catch null) != null;
        if (tuistory_available) {
            const cross_area_tests = b.addSystemCommand(&.{"bash"});
            cross_area_tests.addFileArg(b.path("test/cross-area-flows.sh"));
            cross_area_tests.step.dependOn(b.getInstallStep());

            const cross_area_test_step = b.step("test-cross-area", "Run compiled-binary cross-area integration tests");
            cross_area_test_step.dependOn(external_tool_check_step);
            cross_area_test_step.dependOn(&cross_area_tests.step);

            const vaxis_m8_tests = b.addSystemCommand(&.{"bash"});
            vaxis_m8_tests.addFileArg(b.path("test/vaxis-m8-e2e.sh"));
            vaxis_m8_tests.step.dependOn(b.getInstallStep());

            const vaxis_m8_test_step = b.step("test-vaxis-m8-e2e", "Run vaxis M8 tuistory integration tests");
            vaxis_m8_test_step.dependOn(external_tool_check_step);
            vaxis_m8_test_step.dependOn(&vaxis_m8_tests.step);

            const missing_cwd_tests = b.addSystemCommand(&.{"bash"});
            missing_cwd_tests.addFileArg(b.path("test/missing-cwd-selector.sh"));
            missing_cwd_tests.step.dependOn(b.getInstallStep());

            const missing_cwd_test_step = b.step("test-missing-cwd-selector", "Run missing-cwd TUI selector tuistory tests");
            missing_cwd_test_step.dependOn(external_tool_check_step);
            missing_cwd_test_step.dependOn(&missing_cwd_tests.step);
        } else {
            addTuistoryBlockedStep(b, "test-cross-area", "Run compiled-binary cross-area integration tests");
            addTuistoryBlockedStep(b, "test-vaxis-m8-e2e", "Run vaxis M8 tuistory integration tests");
            addTuistoryBlockedStep(b, "test-missing-cwd-selector", "Run missing-cwd TUI selector tuistory tests");
        }
    } else {
        _ = b.step("test-cross-area", "Skipped on Windows target");
        _ = b.step("test-vaxis-m8-e2e", "Skipped on Windows target");
        _ = b.step("test-missing-cwd-selector", "Skipped on Windows target");
    }

    const coding_agent_rendering_mod = b.createModule(.{
        .root_source_file = b.path("packages/pi-coding-agent/src/tests/interactive_mode_rendering_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    coding_agent_rendering_mod.addImport("ai", ai_mod);
    coding_agent_rendering_mod.addImport("agent", agent_mod);
    coding_agent_rendering_mod.addImport("shared", shared_mod);
    coding_agent_rendering_mod.addImport("tui", tui_mod);
    coding_agent_rendering_mod.addImport("coding_agent", coding_agent_mod);
    coding_agent_rendering_mod.addImport("zigimg", zigimg_mod);

    const coding_agent_rendering_tests = b.addTest(.{
        .root_module = coding_agent_rendering_mod,
    });
    const run_coding_agent_rendering_tests = b.addRunArtifact(coding_agent_rendering_tests);
    test_step.dependOn(&run_coding_agent_rendering_tests.step);
    coding_agent_test_step.dependOn(&run_coding_agent_rendering_tests.step);

    const coding_agent_rendering_test_step = b.step("test-coding-agent-rendering", "Run coding-agent rendering tests only");
    coding_agent_rendering_test_step.dependOn(&run_coding_agent_rendering_tests.step);

    const tui_tests = b.addTest(.{
        .root_module = tui_mod,
    });
    const run_tui_tests = b.addRunArtifact(tui_tests);
    test_step.dependOn(&run_tui_tests.step);

    const tui_test_step = b.step("test-tui", "Run TUI unit tests only");
    tui_test_step.dependOn(external_tool_check_step);
    tui_test_step.dependOn(&run_tui_tests.step);
}

fn getExtraToolPaths(allocator: std.mem.Allocator) []const []const u8 {
    const home = std.process.Environ.getAlloc(.{ .block = .empty }, allocator, "HOME") catch return &[_][]const u8{};
    defer allocator.free(home);
    const pi_bin = std.fs.path.join(allocator, &.{ home, ".pi", "agent", "bin" }) catch return &[_][]const u8{};
    const paths = allocator.alloc([]const u8, 1) catch return &[_][]const u8{};
    paths[0] = pi_bin;
    return paths;
}

fn freeExtraToolPaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    if (paths.len > 0) allocator.free(paths[0]);
    allocator.free(paths);
}

fn addExternalToolCheckStep(b: *std.Build) *std.Build.Step {
    const step = b.step(
        "check-external-tools",
        "Verify required external CLI tools are available in PATH",
    );

    var missing_tools = std.ArrayList([]const u8).empty;
    defer missing_tools.deinit(b.allocator);

    const extra_paths = getExtraToolPaths(b.allocator);
    defer freeExtraToolPaths(b.allocator, extra_paths);

    for (required_external_tools) |tool| {
        _ = b.findProgram(tool.names, extra_paths) catch |err| switch (err) {
            error.FileNotFound => missing_tools.append(
                b.allocator,
                b.fmt("- {s}: {s}", .{ tool.display_name, tool.reason }),
            ) catch @panic("OOM"),
        };
    }

    if (missing_tools.items.len > 0) {
        const missing_summary = std.mem.join(b.allocator, "\n", missing_tools.items) catch @panic("OOM");
        const fail_step = b.addFail(b.fmt(
            "Missing required external tools:\n{s}\n\n" ++
                "Install them and ensure `rg` and `fd` are on PATH before running `zig build` or `zig build test`.\n" ++
                "Debian/Ubuntu: `sudo apt install ripgrep fd-find`, then ensure `fd` points to `fdfind` (for example, `sudo ln -sf \"$(command -v fdfind)\" /usr/local/bin/fd`).\n" ++
                "macOS/Homebrew: `brew install ripgrep fd`.\n" ++
                "Note: the required binary name is `fd`.",
            .{missing_summary},
        ));
        step.dependOn(&fail_step.step);
    }

    return step;
}

fn addTuistoryBlockedStep(b: *std.Build, step_name: []const u8, step_description: []const u8) void {
    const blocked = b.addSystemCommand(&.{
        "sh",
        "-c",
        "echo 'blocked-by-tuistory: TUI integration validator skipped because tuistory is not installed'",
    });
    const step = b.step(step_name, step_description);
    step.dependOn(&blocked.step);
}

fn addParityExecutableRunStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ai_mod: *std.Build.Module,
    external_tool_check_step: *std.Build.Step,
    options: ParityExecutableRunOptions,
) void {
    const parity_exe_mod = b.createModule(.{
        .root_source_file = b.path(options.root_source_path),
        .target = target,
        .optimize = optimize,
    });
    parity_exe_mod.addImport("ai", ai_mod);

    const parity_exe = b.addExecutable(.{
        .name = options.name,
        .root_module = parity_exe_mod,
    });
    const run_parity_exe = b.addRunArtifact(parity_exe);
    const run_parity_step = b.step(options.step_name, options.step_description);
    run_parity_step.dependOn(external_tool_check_step);
    run_parity_step.dependOn(&run_parity_exe.step);
}

fn addParityScriptStep(
    b: *std.Build,
    external_tool_check_step: *std.Build.Step,
    options: ParityScriptStepOptions,
) *std.Build.Step.Run {
    const parity_script = b.addSystemCommand(&.{"bash"});
    parity_script.addFileArg(b.path(options.script_path));
    if (options.command_depends_on_external_tools) {
        parity_script.step.dependOn(external_tool_check_step);
    }
    if (options.command_depends_on_install) {
        parity_script.step.dependOn(b.getInstallStep());
    }

    const parity_step = b.step(options.step_name, options.step_description);
    if (options.step_depends_on_external_tools) {
        parity_step.dependOn(external_tool_check_step);
    }
    parity_step.dependOn(&parity_script.step);

    return parity_script;
}

fn addProviderParitySuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ai_mod: *std.Build.Module,
    external_tool_check_step: *std.Build.Step,
    options: ProviderParitySuiteOptions,
) void {
    addParityExecutableRunStep(b, target, optimize, ai_mod, external_tool_check_step, .{
        .name = options.executable_name,
        .root_source_path = options.executable_root_source_path,
        .step_name = options.run_step_name,
        .step_description = options.run_step_description,
    });
    _ = addParityScriptStep(b, external_tool_check_step, .{
        .script_path = options.script_path,
        .step_name = options.test_step_name,
        .step_description = options.test_step_description,
        .command_depends_on_external_tools = true,
    });
}
