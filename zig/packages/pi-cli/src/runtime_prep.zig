const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const agent = @import("agent");
const cli = @import("args.zig");
const bootstrap = @import("bootstrap.zig");
const model_resolver = @import("model_resolver.zig");
const config_mod = @import("coding_agent").config_impl;
const context_files_mod = @import("coding_agent").context_files;
const resources_mod = @import("coding_agent").resources;
const extension_runtime = @import("coding_agent").extension_runtime;
const coding_agent = @import("coding_agent");
const tool_adapters = @import("coding_agent").tool_adapters;
const tool_selection = @import("coding_agent").tool_selection;

pub const PreparedCliRuntime = struct {
    runtime_config: config_mod.RuntimeConfig,
    resource_bundle: resources_mod.ResourceBundle,
    context_files: []context_files_mod.ContextFile,
    system_prompt: []u8,
    current_date: []u8,
    session_dir: []u8,
    expanded_messages: []const []const u8,
    provider_name: []const u8,
    model_name: ?[]const u8,
    model_name_owned: bool = false,
    model_warning: ?[]u8 = null,
    model_error: ?[]u8 = null,
    thinking_level: agent.ThinkingLevel,
    extension_contributions: ?tool_adapters.ExtensionBootstrapContributions = null,

    pub fn deinit(self: *PreparedCliRuntime, allocator: std.mem.Allocator) void {
        if (self.extension_contributions) |*contributions| contributions.deinit();
        for (self.expanded_messages) |message| allocator.free(message);
        if (self.expanded_messages.len > 0) allocator.free(self.expanded_messages);
        if (self.model_name_owned and self.model_name != null) allocator.free(self.model_name.?);
        if (self.model_warning) |warning| allocator.free(warning);
        if (self.model_error) |message| allocator.free(message);
        allocator.free(self.session_dir);
        allocator.free(self.system_prompt);
        allocator.free(self.current_date);
        context_files_mod.deinitContextFiles(allocator, self.context_files);
        self.resource_bundle.deinit(allocator);
        self.runtime_config.deinit();
        self.* = undefined;
    }
};

pub fn prepareCliRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: *const cli.Args,
    selected_tools: tool_selection.ToolSelection,
) !PreparedCliRuntime {
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(
        allocator,
        io,
        env_map,
        cwd,
        runtimeConfigLoadOptions(options, env_map),
    );
    errdefer runtime_config.deinit();

    var resource_bundle = try resources_mod.loadResourceBundle(allocator, io, .{
        .cwd = cwd,
        .agent_dir = runtime_config.agent_dir,
        .global = settingsResources(runtime_config.global_settings),
        .project = settingsResources(runtime_config.project_settings),
        .cli_extensions = options.extensions orelse &.{},
        .cli_skills = options.skills orelse &.{},
        .cli_prompts = options.prompt_templates orelse &.{},
        .cli_themes = options.themes orelse &.{},
        .env_map = env_map,
        .include_default_extensions = !options.no_extensions,
        .include_default_skills = !options.no_skills,
        .include_default_prompts = !options.no_prompt_templates,
        .include_default_themes = !options.no_themes,
    });
    errdefer resource_bundle.deinit(allocator);

    var extension_contributions = try collectExtensionBootstrapContributions(
        allocator,
        io,
        env_map,
        cwd,
        &runtime_config,
        resource_bundle.extensions,
        selected_tools,
    );
    errdefer extension_contributions.deinit();

    if (extension_contributions.resource_discoveries.len > 0) {
        const discovered_bundle = try resources_mod.loadResourceBundle(allocator, io, .{
            .cwd = cwd,
            .agent_dir = runtime_config.agent_dir,
            .global = settingsResources(runtime_config.global_settings),
            .project = settingsResources(runtime_config.project_settings),
            .cli_extensions = options.extensions orelse &.{},
            .cli_skills = options.skills orelse &.{},
            .cli_prompts = options.prompt_templates orelse &.{},
            .cli_themes = options.themes orelse &.{},
            .env_map = env_map,
            .include_default_extensions = !options.no_extensions,
            .include_default_skills = !options.no_skills,
            .include_default_prompts = !options.no_prompt_templates,
            .include_default_themes = !options.no_themes,
            .extension_discoveries = extension_contributions.resource_discoveries,
        });
        resource_bundle.deinit(allocator);
        resource_bundle = discovered_bundle;
    }
    try appendProviderDiagnosticsToResourceBundle(allocator, &resource_bundle, extension_contributions.provider_diagnostics);

    const context_files = if (options.no_context_files)
        try allocator.dupe(context_files_mod.ContextFile, &.{})
    else
        try context_files_mod.loadContextFiles(allocator, io, cwd);
    errdefer context_files_mod.deinitContextFiles(allocator, context_files);

    const current_date = try currentDateString(allocator, io);
    errdefer allocator.free(current_date);

    const initial_model = try selectInitialModel(allocator, env_map, &runtime_config, options);
    const provider_name = initial_model.provider_name;
    const model_name = initial_model.model_name;
    const thinking_level = if (options.thinking) |level|
        mapThinkingLevel(level)
    else
        initial_model.thinking_level orelse runtime_config.settings.default_thinking_level orelse .off;

    const system_prompt = try coding_agent.buildSystemPrompt(allocator, .{
        .cwd = cwd,
        .current_date = current_date,
        .custom_prompt = options.system_prompt,
        .append_prompts = options.append_system_prompt orelse &.{},
        .tool_selection = selected_tools,
        .context_files = context_files,
        .skills = resource_bundle.skills,
    });
    errdefer allocator.free(system_prompt);

    const session_dir = if (options.session_dir) |value|
        try config_mod.expandPath(allocator, env_map, value, cwd)
    else
        try runtime_config.effectiveSessionDir(allocator, env_map, cwd);
    errdefer allocator.free(session_dir);

    const expanded_messages = try expandMessages(allocator, options.messages orelse &.{}, resource_bundle.prompt_templates);
    errdefer {
        for (expanded_messages) |message| allocator.free(message);
        if (expanded_messages.len > 0) allocator.free(expanded_messages);
    }

    return .{
        .runtime_config = runtime_config,
        .resource_bundle = resource_bundle,
        .context_files = context_files,
        .system_prompt = system_prompt,
        .current_date = current_date,
        .session_dir = session_dir,
        .expanded_messages = expanded_messages,
        .provider_name = provider_name,
        .model_name = model_name,
        .model_name_owned = initial_model.model_name_owned,
        .model_warning = initial_model.warning,
        .model_error = initial_model.error_message,
        .thinking_level = thinking_level,
        .extension_contributions = extension_contributions,
    };
}

fn collectExtensionBootstrapContributions(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    runtime_config: *const config_mod.RuntimeConfig,
    extensions: []const resources_mod.LoadedExtension,
    selected_tools: tool_selection.ToolSelection,
) !tool_adapters.ExtensionBootstrapContributions {
    if (extensions.len == 0) {
        return .{ .allocator = allocator };
    }

    var app_context = coding_agent.interactive_mode.AppContext.init(cwd, io);
    var built_tools = try tool_adapters.buildAgentToolsWithExtensionsSelection(allocator, &app_context, selected_tools, .{
        .extensions = extensions,
        .env_map = env_map,
        .cwd = cwd,
        .io = io,
        .runtime_config = runtime_config,
        .start_without_tools = true,
    });
    defer built_tools.deinit();

    return try tool_adapters.registerExtensionProvidersAndCollectResources(allocator, &built_tools, extensions);
}

fn appendProviderDiagnosticsToResourceBundle(
    allocator: std.mem.Allocator,
    resource_bundle: *resources_mod.ResourceBundle,
    provider_diagnostics: []const tool_adapters.ProviderCollisionDiagnostic,
) !void {
    if (provider_diagnostics.len == 0) return;

    const existing_len = resource_bundle.diagnostics.len;
    const diagnostics = try allocator.alloc(resources_mod.Diagnostic, existing_len + provider_diagnostics.len);
    @memcpy(diagnostics[0..existing_len], resource_bundle.diagnostics);
    var initialized = existing_len;
    errdefer {
        for (diagnostics[existing_len..initialized]) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(diagnostics);
    }

    for (provider_diagnostics) |diagnostic| {
        diagnostics[initialized] = try providerCollisionResourceDiagnostic(allocator, diagnostic);
        initialized += 1;
    }

    allocator.free(resource_bundle.diagnostics);
    resource_bundle.diagnostics = diagnostics;
}

fn providerCollisionResourceDiagnostic(
    allocator: std.mem.Allocator,
    diagnostic: tool_adapters.ProviderCollisionDiagnostic,
) !resources_mod.Diagnostic {
    const kind = try allocator.dupe(u8, diagnostic.code);
    errdefer allocator.free(kind);
    const message = try std.fmt.allocPrint(
        allocator,
        "extension provider diagnostic code={s} severity={s} extensionId={s} source={s} providerId={s} conflictKind={s} conflictWith={s}: {s}",
        .{
            diagnostic.code,
            diagnostic.severity,
            diagnostic.source_path,
            diagnostic.source_path,
            diagnostic.provider_id,
            diagnostic.conflict_kind,
            diagnostic.conflict_with,
            diagnostic.message,
        },
    );
    errdefer allocator.free(message);
    const path = try allocator.dupe(u8, diagnostic.extension_path);
    return .{
        .kind = kind,
        .message = message,
        .path = path,
    };
}

pub fn refreshSystemPromptWithActiveTools(
    allocator: std.mem.Allocator,
    prepared: *PreparedCliRuntime,
    cwd: []const u8,
    options: *const cli.Args,
    selected_tools: tool_selection.ToolSelection,
    active_tools: []const agent.AgentTool,
) !void {
    const next_system_prompt = try coding_agent.buildSystemPrompt(allocator, .{
        .cwd = cwd,
        .current_date = prepared.current_date,
        .custom_prompt = options.system_prompt,
        .append_prompts = options.append_system_prompt orelse &.{},
        .tool_selection = selected_tools,
        .active_tools = active_tools,
        .context_files = prepared.context_files,
        .skills = prepared.resource_bundle.skills,
    });
    allocator.free(prepared.system_prompt);
    prepared.system_prompt = next_system_prompt;
}

pub fn runtimeConfigLoadOptions(
    options: *const cli.Args,
    env_map: *const std.process.Environ.Map,
) config_mod.RuntimeConfigLoadOptions {
    return .{
        .discover_models = bootstrap.startupNetworkOperationsEnabled(options, env_map),
    };
}

/// Resolves the effective session directory using the same precedence as
/// `prepareCliRuntime`, but without loading provider auth, model registries,
/// resource bundles, context files, or the system prompt. Used by the M10
/// missing-cwd preflight so the diagnostic always wins over downstream
/// runtime/provider/tool failures.
///
/// Precedence (matches TypeScript `main.ts`):
///   1. `--session-dir` CLI override
///   2. `$PI_CODING_AGENT_SESSION_DIR` env var (TS `ENV_SESSION_DIR`)
///   3. `settings.json` `sessionDir` from merged global/project settings
///   4. Default `<cwd>/.pi/sessions`
///
/// Settings load failures fall through to the default; the preflight is
/// best-effort and never blocks the heavier `prepareCliRuntime` failure
/// path.
pub fn resolvePreflightSessionDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: *const cli.Args,
) ![]u8 {
    if (options.session_dir) |value| {
        return try config_mod.expandPath(allocator, env_map, value, cwd);
    }
    if (env_map.get("PI_CODING_AGENT_SESSION_DIR")) |value| {
        if (value.len > 0) {
            return try config_mod.expandPath(allocator, env_map, value, cwd);
        }
    }
    if (config_mod.loadMergedSettingsForPreflight(allocator, io, env_map, cwd)) |maybe_settings| {
        var settings_value = maybe_settings;
        defer settings_value.deinit(allocator);
        if (settings_value.session_dir) |value| {
            return try config_mod.expandPath(allocator, env_map, value, cwd);
        }
    } else |_| {
        // Settings parse failure: fall through to the default. The heavier
        // prepareCliRuntime path will surface the same diagnostic later when
        // the user actually proceeds past the missing-cwd preflight.
    }
    return try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
}

const InitialModelSelection = struct {
    provider_name: []const u8,
    model_name: ?[]const u8,
    model_name_owned: bool = false,
    thinking_level: ?agent.ThinkingLevel = null,
    warning: ?[]u8 = null,
    error_message: ?[]u8 = null,
};

fn selectInitialModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    runtime_config: *const config_mod.RuntimeConfig,
    options: *const cli.Args,
) !InitialModelSelection {
    if (options.model) |cli_model| {
        var resolved = try model_resolver.resolveCliModel(allocator, options.provider, cli_model);
        errdefer resolved.deinit(allocator);

        if (resolved.error_message) |_| {
            return .{
                .provider_name = options.provider orelse runtime_config.settings.default_provider orelse "openai",
                .model_name = null,
                .warning = resolved.warning,
                .error_message = resolved.error_message,
            };
        }

        if (resolved.provider_name) |provider_name| {
            const owned_model_name = resolved.owned_model_name;
            resolved.owned_model_name = null;
            const warning = resolved.warning;
            resolved.warning = null;
            return .{
                .provider_name = provider_name,
                .model_name = if (owned_model_name) |owned| owned else resolved.model_name,
                .model_name_owned = owned_model_name != null,
                .thinking_level = if (resolved.thinking) |level| mapThinkingLevel(level) else null,
                .warning = warning,
            };
        }
    }

    // Try saved default from settings — but only if the model exists in the registry.
    // Mirrors TS findInitialModel step 3: modelRegistry.find(defaultProvider, defaultModelId).
    // If the default provider/model is not a registered built-in (e.g. a custom
    // provider like "ollama-cloud" that was configured via extensions), fall through
    // to findInitialDefaultModel which scans for any provider with credentials.
    if (options.provider != null or runtime_config.settings.default_provider != null) {
        const provider_name = options.provider orelse runtime_config.settings.default_provider.?;
        const model_id = runtime_config.settings.default_model orelse provider_name;
        const found = ai.model_registry.find(provider_name, model_id);
        if (found) |_| {
            return .{
                .provider_name = provider_name,
                .model_name = runtime_config.settings.default_model,
            };
        }
    }

    // If default_model is set but default_provider was not (or not found),
    // check if the model exists under "openai" in the registry.
    // Mirrors TS findInitialModel: no separate "default_model with openai" step —
    // if the default provider/model isn't found, fall through to credential scan.
    if (runtime_config.settings.default_model) |default_model| {
        const found = ai.model_registry.find("openai", default_model);
        if (found) |_| {
            return .{
                .provider_name = "openai",
                .model_name = default_model,
            };
        }
    }

    const model = try coding_agent.provider_config.findInitialDefaultModel(allocator, env_map, .{
        .auth_tokens = &runtime_config.auth_tokens,
        .provider_api_keys = &runtime_config.provider_api_keys,
    });
    if (model) |value| {
        return .{
            .provider_name = value.provider,
            .model_name = value.id,
        };
    }

    return .{
        .provider_name = "openai",
        .model_name = null,
    };
}

fn expandMessages(
    allocator: std.mem.Allocator,
    messages: []const []const u8,
    prompt_templates: []const resources_mod.PromptTemplate,
) ![]const []const u8 {
    if (messages.len == 0) return &.{};

    const expanded = try allocator.alloc([]const u8, messages.len);
    errdefer allocator.free(expanded);
    var initialized: usize = 0;
    errdefer {
        for (expanded[0..initialized]) |message| allocator.free(message);
    }

    for (messages, 0..) |message, index| {
        expanded[index] = try resources_mod.expandPromptTemplate(allocator, message, prompt_templates);
        initialized += 1;
    }
    return expanded;
}

fn settingsResources(settings: config_mod.Settings) resources_mod.SettingsResources {
    return .{
        .packages = settings.packages,
        .extensions = settings.extensions,
        .skills = settings.skills,
        .prompts = settings.prompts,
        .themes = settings.themes,
        .theme = settings.theme,
    };
}

fn currentDateString(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const now_seconds: u64 = @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1 },
    );
}

fn mapThinkingLevel(level: cli.ThinkingLevel) agent.ThinkingLevel {
    return switch (level) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

test "runtimeConfigLoadOptions disables model discovery for offline CLI flag" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{"--offline"});
    defer args.deinit(allocator);

    const options = runtimeConfigLoadOptions(&args, &env_map);
    try std.testing.expect(!options.discover_models);
}

test "runtimeConfigLoadOptions disables model discovery for PI_OFFLINE" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_OFFLINE", "true");

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const options = runtimeConfigLoadOptions(&args, &env_map);
    try std.testing.expect(!options.discover_models);
}

test "runtimeConfigLoadOptions keeps model discovery enabled by default" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const options = runtimeConfigLoadOptions(&args, &env_map);
    try std.testing.expect(options.discover_models);
}

test "prepareCliRuntime resolves provider-prefixed CLI model and thinking suffix" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{ "--model", "faux/faux-1:high" });
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, "/tmp/project", &args, .{});
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("faux", prepared.provider_name);
    try std.testing.expectEqualStrings("faux-1", prepared.model_name.?);
    try std.testing.expectEqual(agent.ThinkingLevel.high, prepared.thinking_level);
    try std.testing.expect(prepared.model_error == null);
}

test "refreshSystemPromptWithActiveTools advertises no-builtin extension tools" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{"--no-builtin-tools"});
    defer args.deinit(allocator);

    const selected_tools = tool_selection.ToolSelection.fromCli(false, true, null);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, "/tmp/project", &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Available tools:\n(none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "- read: Read file contents") == null);

    var schema = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"]}",
        .{},
    );
    defer schema.deinit();
    const active_tool = agent.AgentTool{
        .name = "ext-echo",
        .description = "Process echo",
        .label = "Ext Echo",
        .parameters = schema.value,
    };

    try refreshSystemPromptWithActiveTools(
        allocator,
        &prepared,
        "/tmp/project",
        &args,
        selected_tools,
        &.{active_tool},
    );

    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "- ext-echo: Process echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "\"value\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "- read: Read file contents") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Available tools:\n(none)") == null);
}

test "prepareCliRuntime reports missing CLI model without provider" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{ "--model", "definitely-not-a-real-model" });
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, "/tmp/project", &args, .{});
    defer prepared.deinit(allocator);

    try std.testing.expect(prepared.model_error != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.model_error.?, "not found") != null);
}
