const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const provider_config = @import("../providers/provider_config.zig");
const session_cwd = @import("../sessions/session_cwd.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const session_mod = @import("../sessions/session.zig");
const shared = @import("shared.zig");
const session_lifecycle = @import("session_lifecycle.zig");
const tool_registry = @import("../runtime/tool_registry.zig");
const system_prompt_mod = @import("../resources/system_prompt.zig");

const AppContext = shared.AppContext;
const MissingCwdMode = shared.MissingCwdMode;
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
const configuredCompactionSettings = shared.configuredCompactionSettings;
const configuredRetrySettings = shared.configuredRetrySettings;
const createSeededSession = session_lifecycle.createSeededSession;
const resolveSessionPath = session_lifecycle.resolveSessionPath;

/// Computes the session file path that `openInitialSessionWithMissingCwd`
/// would open for `options`, without resolving providers, models, or tools.
///
/// Returns the session file path on success (caller owns the returned slice
/// and must `allocator.free` it). Returns null when bootstrapping would
/// create a brand new session instead of opening one (no `--session`,
/// `--continue`, `--resume`, or `--fork` and `--no-session` not set; or
/// `--continue` / `--resume` requested but no recent session exists).
///
/// Used by lifecycle preflight callers so missing-cwd diagnostics can be
/// surfaced BEFORE provider auth / runtime / tool construction can fail.
pub fn resolveResumeSessionPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RunInteractiveModeOptions,
) !?[]const u8 {
    if (options.no_session) return null;

    if (options.fork) |session_ref| {
        return try resolveSessionPath(allocator, io, options.session_dir, options.cwd, session_ref);
    }
    if (options.session) |session_ref| {
        return try resolveSessionPath(allocator, io, options.session_dir, options.cwd, session_ref);
    }
    if (options.@"continue" or options.@"resume") {
        if (try session_manager_mod.findMostRecentSession(allocator, io, options.session_dir)) |recent| {
            // findMostRecentSession returns an allocator-owned slice; the
            // caller of resolveResumeSessionPath assumes ownership of the
            // returned slice via allocator.free.
            return recent;
        }
    }
    return null;
}

/// Returns an owned missing-cwd diagnostic when the session that
/// `options` would open has a stored cwd that no longer exists. Returns
/// null otherwise (including when no resume target is selected).
///
/// This is the canonical bootstrap-ordering preflight: the caller MUST
/// invoke it before resolving the provider config or building tools so
/// missing-cwd diagnostics always preempt provider/auth/tool failures
/// (matches TypeScript main.ts which checks the missing-cwd issue before
/// constructing the runtime).
pub fn preflightInteractiveMissingCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RunInteractiveModeOptions,
) !?session_cwd.OwnedMissingSessionCwdIssue {
    const session_path = (try resolveResumeSessionPath(allocator, io, options)) orelse return null;
    defer allocator.free(session_path);
    return try session_cwd.preflightMissingSessionCwd(allocator, io, session_path, options.cwd);
}

pub const InteractiveBootstrap = struct {
    allocator: std.mem.Allocator,
    current_provider: provider_config.ResolvedProviderConfig,
    built_tools: tool_registry.BuiltTools,
    session: session_mod.AgentSession,
    owned_system_prompt: ?[]u8 = null,

    pub fn deinit(self: *InteractiveBootstrap) void {
        self.session.deinit();
        if (self.owned_system_prompt) |system_prompt| self.allocator.free(system_prompt);
        self.built_tools.deinit();
        self.current_provider.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn bootstrapInteractiveState(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    app_context: *AppContext,
) !InteractiveBootstrap {
    return bootstrapInteractiveStateWithMissingCwd(
        allocator,
        io,
        env_map,
        options,
        app_context,
        null,
    );
}

/// Like `bootstrapInteractiveState` but writes the detected missing-cwd issue
/// to `out_issue` (if non-null) when bootstrap fails because the stored
/// session cwd no longer exists. Owned strings inside the issue must be freed
/// with `freeMissingSessionCwdIssue`.
pub fn bootstrapInteractiveStateWithMissingCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    app_context: *AppContext,
    out_issue: ?*?OwnedMissingSessionCwdIssue,
) !InteractiveBootstrap {
    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        io,
        env_map,
        options.provider,
        options.model,
        options.api_key,
        configuredApiKeyForProvider(options.runtime_config, options.provider),
    );
    errdefer current_provider.deinit(allocator);

    var built_tools = try tool_registry.buildAgentToolsWithExtensionsSelection(allocator, app_context, options.selected_tools, .{
        .extensions = options.extensions,
        .env_map = env_map,
        .cwd = options.cwd,
        .io = io,
        .runtime_config = options.runtime_config,
        .include_builtin_tools = options.include_builtin_tools,
        .include_installed_wasm_tools = options.include_installed_wasm_tools,
        .resource_options = if (options.runtime_config) |runtime_config| .{
            .cwd = options.cwd,
            .agent_dir = runtime_config.agent_dir,
            .global = shared.settingsResources(runtime_config.global_settings),
            .project = shared.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        } else null,
    });
    errdefer built_tools.deinit();

    var effective_options = options;
    var owned_system_prompt: ?[]u8 = null;
    errdefer if (owned_system_prompt) |system_prompt| allocator.free(system_prompt);
    if (options.current_date.len > 0) {
        owned_system_prompt = try system_prompt_mod.buildSystemPrompt(allocator, .{
            .cwd = options.cwd,
            .current_date = options.current_date,
            .custom_prompt = options.custom_prompt,
            .append_prompts = options.append_prompts,
            .tool_selection = options.selected_tools,
            .active_tools = built_tools.items,
            .context_files = options.context_files,
            .skills = options.skills,
        });
        effective_options.system_prompt = owned_system_prompt.?;
    }

    var session = openInitialSessionWithMissingCwd(
        allocator,
        io,
        options.session_dir,
        effective_options,
        current_provider.model,
        current_provider.api_key,
        built_tools.items,
        out_issue,
    ) catch |err| return err;
    errdefer session.deinit();
    try session.setExtensionHosts(built_tools.extension_hosts, 1000);

    return .{
        .allocator = allocator,
        .current_provider = current_provider,
        .built_tools = built_tools,
        .session = session,
        .owned_system_prompt = owned_system_prompt,
    };
}

/// Re-exported owned snapshot of a `MissingSessionCwdIssue`. The canonical
/// type lives in `session_cwd.zig` so non-interactive callers (CLI, TS-RPC)
/// can produce/consume the diagnostic without depending on interactive_mode
/// internals.
pub const OwnedMissingSessionCwdIssue = session_cwd.OwnedMissingSessionCwdIssue;

const captureMissingSessionCwdIssue = session_cwd.captureOwnedMissingSessionCwdIssue;

pub fn openInitialSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
) !session_mod.AgentSession {
    return openInitialSessionWithMissingCwd(
        allocator,
        io,
        session_dir,
        options,
        model,
        api_key,
        tool_items,
        null,
    );
}

/// Variant of `openInitialSession` that captures a missing-cwd issue into
/// `out_issue` when bootstrap fails because the stored session cwd does not
/// exist. The caller is responsible for calling `OwnedMissingSessionCwdIssue.deinit`.
pub fn openInitialSessionWithMissingCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
    out_issue: ?*?OwnedMissingSessionCwdIssue,
) !session_mod.AgentSession {
    const thinking_level = options.thinking;
    const compaction_settings = configuredCompactionSettings(options.runtime_config);
    const retry_settings = configuredRetrySettings(options.runtime_config);
    if (options.no_session) {
        return try session_mod.AgentSession.create(allocator, io, .{
            .cwd = options.cwd,
            .system_prompt = options.system_prompt,
            .model = model,
            .api_key = api_key,
            .thinking_level = thinking_level,
            .tools = tool_items,
            .compaction = compaction_settings,
            .retry = retry_settings,
        });
    }

    if (options.fork) |session_ref| {
        const session_path = try resolveSessionPath(allocator, io, session_dir, options.cwd, session_ref);
        defer allocator.free(session_path);

        var source_session = try openSessionAtPathCapturing(
            allocator,
            io,
            session_path,
            options,
            model,
            api_key,
            tool_items,
            out_issue,
        );
        defer source_session.deinit();

        return try createSeededSession(
            allocator,
            io,
            options.cwd,
            options.system_prompt,
            model,
            api_key,
            thinking_level,
            tool_items,
            compaction_settings,
            retry_settings,
            session_dir,
            source_session.agent.getMessages(),
        );
    }

    if (options.session) |session_ref| {
        const session_path = try resolveSessionPath(allocator, io, session_dir, options.cwd, session_ref);
        defer allocator.free(session_path);
        return try openSessionAtPathCapturing(
            allocator,
            io,
            session_path,
            options,
            model,
            api_key,
            tool_items,
            out_issue,
        );
    }

    if (options.@"continue" or options.@"resume") {
        if (try session_manager_mod.findMostRecentSession(allocator, io, session_dir)) |recent| {
            defer allocator.free(recent);
            return try openSessionAtPathCapturing(
                allocator,
                io,
                recent,
                options,
                model,
                api_key,
                tool_items,
                out_issue,
            );
        }
    }

    return try createSeededSession(
        allocator,
        io,
        options.cwd,
        options.system_prompt,
        model,
        api_key,
        thinking_level,
        tool_items,
        compaction_settings,
        retry_settings,
        session_dir,
        &.{},
    );
}

fn openSessionAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_path: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
) !session_mod.AgentSession {
    return openSessionAtPathCapturing(
        allocator,
        io,
        session_path,
        options,
        model,
        api_key,
        tool_items,
        null,
    );
}

fn openSessionAtPathCapturing(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_path: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
    out_issue: ?*?OwnedMissingSessionCwdIssue,
) !session_mod.AgentSession {
    // Open the persisted session without a cwd override so the stored cwd is
    // preserved when it is still valid. This matches TypeScript main.ts where
    // SessionManager opens with the stored cwd and only overrides after the
    // user explicitly agrees to continue in the launch cwd.
    var session = try session_mod.AgentSession.open(allocator, io, .{
        .session_file = session_path,
        .cwd_override = null,
        .system_prompt = options.system_prompt,
        .model = model,
        .api_key = api_key,
        .thinking_level = options.thinking,
        .tools = tool_items,
        .compaction = configuredCompactionSettings(options.runtime_config),
        .retry = configuredRetrySettings(options.runtime_config),
    });

    if (session_cwd.getMissingSessionCwdIssue(io, session.session_manager, options.cwd)) |issue| {
        switch (options.missing_cwd_mode) {
            .fail => {
                if (out_issue) |slot| {
                    slot.* = try captureMissingSessionCwdIssue(allocator, issue);
                }
                session.deinit();
                return error.MissingSessionCwd;
            },
            .use_fallback => {
                // The caller (interactive mode) has already prompted the user
                // and confirmed the fallback. Reopen with the launch cwd as an
                // explicit override so the in-memory cwd reflects the user
                // choice while preserving the stored session header metadata,
                // matching TS `SessionManager.open(file, sessionDir, cwd)`.
                session.deinit();
                var resumed = try session_mod.AgentSession.open(allocator, io, .{
                    .session_file = session_path,
                    .cwd_override = options.cwd,
                    .system_prompt = options.system_prompt,
                    .model = model,
                    .api_key = api_key,
                    .thinking_level = options.thinking,
                    .tools = tool_items,
                    .compaction = configuredCompactionSettings(options.runtime_config),
                    .retry = configuredRetrySettings(options.runtime_config),
                });
                errdefer resumed.deinit();
                return resumed;
            },
        }
    }
    return session;
}

test "bootstrapInteractiveState resolves provider builds tools and opens a session" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const root_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "workspace" });
    defer allocator.free(root_dir);
    const session_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "workspace", "sessions" });
    defer allocator.free(session_dir);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };

    var app_context = AppContext.init(root_dir, std.testing.io);
    var bootstrap = try bootstrapInteractiveState(allocator, std.testing.io, &env_map, options, &app_context);
    defer bootstrap.deinit();

    try std.testing.expect(bootstrap.built_tools.items.len > 0);
    try std.testing.expectEqualStrings("faux", bootstrap.current_provider.model.provider);
    try std.testing.expect(bootstrap.session.session_manager.getSessionFile() != null);
}

test "openInitialSession honors no_session without creating a session file" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .no_session = true,
    };

    var session = try openInitialSession(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
    );
    defer session.deinit();

    try std.testing.expect(session.session_manager.getSessionFile() == null);
}

test "openInitialSession resumes the most recent session when continue is enabled" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var source_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer source_session.deinit();
    const source_session_file = try allocator.dupe(u8, source_session.session_manager.getSessionFile().?);
    defer allocator.free(source_session_file);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
    };

    var resumed = try openInitialSession(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
    );
    defer resumed.deinit();

    try std.testing.expectEqualStrings(source_session_file, resumed.session_manager.getSessionFile().?);
}

test "openInitialSession preserves stored cwd when it still exists" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var seed_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer seed_session.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
    };
    var resumed = try openInitialSession(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
    );
    defer resumed.deinit();

    // The stored cwd is preserved over the launch cwd because the stored
    // location still exists on disk.
    try std.testing.expectEqualStrings(stored_cwd, resumed.session_manager.getCwd());
    try std.testing.expectEqualStrings(stored_cwd, resumed.cwd);
}

test "openInitialSessionWithMissingCwd reports missing-cwd issue and refuses to mutate session" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var seed_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    const session_file = try allocator.dupe(u8, seed_session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    seed_session.deinit();
    // Read the file before the test to compare bytes after the failed open.
    const before_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before_bytes);

    // Delete the stored cwd so the session has a missing-cwd issue.
    try tmp.dir.deleteTree(std.testing.io, "stored");

    const options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
        .missing_cwd_mode = .fail,
    };
    var captured: ?OwnedMissingSessionCwdIssue = null;
    defer if (captured) |*value| value.deinit(allocator);

    const result = openInitialSessionWithMissingCwd(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
        &captured,
    );
    try std.testing.expectError(error.MissingSessionCwd, result);

    const issue = captured orelse return error.TestUnexpectedNullIssue;
    try std.testing.expectEqualStrings(stored_cwd, issue.session_cwd);
    try std.testing.expectEqualStrings(launch_cwd, issue.fallback_cwd);
    try std.testing.expect(issue.session_file != null);
    try std.testing.expectEqualStrings(session_file, issue.session_file.?);

    // Session file must remain byte-identical after a rejected non-interactive
    // open.
    const after_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after_bytes);
    try std.testing.expectEqualSlices(u8, before_bytes, after_bytes);
}

test "openInitialSessionWithMissingCwd applies fallback cwd when the user agreed to continue" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var seed_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    seed_session.deinit();
    try tmp.dir.deleteTree(std.testing.io, "stored");

    const options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
        .missing_cwd_mode = .use_fallback,
    };
    var captured: ?OwnedMissingSessionCwdIssue = null;
    defer if (captured) |*value| value.deinit(allocator);
    var resumed = try openInitialSessionWithMissingCwd(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
        &captured,
    );
    defer resumed.deinit();
    try std.testing.expect(captured == null);
    try std.testing.expectEqualStrings(launch_cwd, resumed.session_manager.getCwd());
    try std.testing.expectEqualStrings(launch_cwd, resumed.cwd);

    // The runtime uses the launch cwd, but the on-disk session header remains
    // the original stored metadata. TypeScript's cwd override changes the
    // SessionManager runtime cwd without rewriting the header line.
    const session_file_after = resumed.session_manager.getSessionFile().?;
    var on_disk_header = try session_manager_mod.readSessionHeader(allocator, std.testing.io, session_file_after);
    defer session_manager_mod.freeSessionHeader(allocator, &on_disk_header);
    try std.testing.expectEqualStrings(stored_cwd, on_disk_header.cwd);
}

test "preflightInteractiveMissingCwd reports missing stored cwd for --continue without provider/auth resolution" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var seed_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer seed_provider.deinit(allocator);
    var seed_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "sys",
        .model = seed_provider.model,
        .api_key = seed_provider.api_key,
        .session_dir = session_dir,
    });
    const session_file = try allocator.dupe(u8, seed_session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    seed_session.deinit();
    try tmp.dir.deleteTree(std.testing.io, "stored");

    // Crucially the preflight options name an unsupported provider so the
    // ordering bug would manifest as an UnknownProvider error from
    // resolveProviderConfig if the missing-cwd guard did not preempt it.
    const options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "definitely-not-a-real-provider",
        .@"continue" = true,
    };

    var captured = try preflightInteractiveMissingCwd(allocator, std.testing.io, options);
    defer if (captured) |*value| value.deinit(allocator);

    const issue = captured orelse return error.TestUnexpectedNullIssue;
    try std.testing.expectEqualStrings(stored_cwd, issue.session_cwd);
    try std.testing.expectEqualStrings(launch_cwd, issue.fallback_cwd);
    try std.testing.expect(issue.session_file != null);
    try std.testing.expectEqualStrings(session_file, issue.session_file.?);
}

test "preflightInteractiveMissingCwd returns null when stored cwd still exists" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const stored_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var seed_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer seed_provider.deinit(allocator);
    var seed_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = stored_cwd,
        .system_prompt = "sys",
        .model = seed_provider.model,
        .api_key = seed_provider.api_key,
        .session_dir = session_dir,
    });
    seed_session.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
    };
    const captured = try preflightInteractiveMissingCwd(allocator, std.testing.io, options);
    try std.testing.expect(captured == null);
}

test "preflightInteractiveMissingCwd returns null when no resume target is requested" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    const options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };
    const captured = try preflightInteractiveMissingCwd(allocator, std.testing.io, options);
    try std.testing.expect(captured == null);
}

test "resolveResumeSessionPath returns the most recent session for --continue" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    var seed_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer seed_provider.deinit(allocator);
    var seed_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = seed_provider.model,
        .api_key = seed_provider.api_key,
        .session_dir = session_dir,
    });
    const expected_session_file = try allocator.dupe(u8, seed_session.session_manager.getSessionFile().?);
    defer allocator.free(expected_session_file);
    seed_session.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
    };
    const resolved = try resolveResumeSessionPath(allocator, std.testing.io, options);
    defer if (resolved) |path| allocator.free(path);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings(expected_session_file, resolved.?);
}

test "resolveResumeSessionPath returns null for new sessions and --no-session" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const launch_cwd = try makeSessionBootstrapTestPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    const fresh_options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };
    const fresh = try resolveResumeSessionPath(allocator, std.testing.io, fresh_options);
    try std.testing.expect(fresh == null);

    const no_session_options = RunInteractiveModeOptions{
        .cwd = launch_cwd,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .no_session = true,
        .@"continue" = true,
    };
    const no_session = try resolveResumeSessionPath(allocator, std.testing.io, no_session_options);
    try std.testing.expect(no_session == null);
}

fn makeSessionBootstrapTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
