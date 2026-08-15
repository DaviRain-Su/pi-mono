const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const context_files_mod = @import("../resources/context_files.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const tool_selection_mod = @import("../tool_selection.zig");

pub const ToolRuntime = struct {
    cwd: []const u8,
    io: std.Io,
};

pub const AppContext = struct {
    tool_runtime: ToolRuntime,
    kitty_protocol_active: bool = false,
    suspend_requested: bool = false,

    pub fn init(cwd: []const u8, io: std.Io) AppContext {
        return .{
            .tool_runtime = .{
                .cwd = cwd,
                .io = io,
            },
        };
    }
};

pub const ExtensionCommandSink = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, raw_command: []const u8) anyerror!bool,
};

const tui = @import("tui");
pub const ExtensionShortcutSink = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, key: tui.Key, modifiers: tui.keys.KeyModifiers) anyerror!bool,
};

/// Controls how a stored session cwd that no longer exists is handled when
/// resuming/forking/opening a persisted session.
///
/// `.fail` matches the non-interactive TypeScript path: fail before mutating
/// any runtime state and let the caller surface the diagnostic.
///
/// `.use_fallback` matches the post-prompt interactive path where the user
/// has agreed to continue in the launch cwd.
pub const MissingCwdMode = enum {
    fail,
    use_fallback,
};

pub const RunInteractiveModeOptions = struct {
    cwd: []const u8,
    system_prompt: []const u8,
    current_date: []const u8 = "",
    custom_prompt: ?[]const u8 = null,
    append_prompts: []const []const u8 = &.{},
    context_files: []const context_files_mod.ContextFile = &.{},
    session_dir: []const u8,
    provider: []const u8,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    thinking: agent.ThinkingLevel = .off,
    session: ?[]const u8 = null,
    @"continue": bool = false,
    @"resume": bool = false,
    fork: ?[]const u8 = null,
    no_session: bool = false,
    model_patterns: ?[]const []const u8 = null,
    selected_tools: tool_selection_mod.ToolSelection = .{},
    include_builtin_tools: bool = true,
    include_installed_wasm_tools: bool = true,
    initial_prompt: ?[]const u8 = null,
    initial_messages: []const []const u8 = &.{},
    initial_images: []const ai.ImageContent = &.{},
    prompt_templates: []const resources_mod.PromptTemplate = &.{},
    extensions: []const resources_mod.LoadedExtension = &.{},
    startup_cli_extensions: []const []const u8 = &.{},
    include_default_extensions: bool = true,
    skills: []const resources_mod.Skill = &.{},
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,
    terminal_name: []const u8 = "term",
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    offline: bool = false,
    verbose: bool = false,
    /// How to handle a stored session cwd that no longer exists when resuming
    /// or opening a persisted session. Defaults to `.fail` so non-interactive
    /// callers never silently fall back to the launch cwd.
    missing_cwd_mode: MissingCwdMode = .fail,
    /// True when the caller already prompted the user (via the early
    /// pre-`prepareCliRuntime` lifecycle preflight) and the user agreed to
    /// continue in the launch cwd. The interactive bootstrap then skips its
    /// own missing-cwd selector to avoid prompting twice.
    missing_cwd_already_confirmed: bool = false,
};

pub const LiveResources = struct {
    pub const ReloadExtensionToolsSink = struct {
        context: ?*anyopaque = null,
        callback: *const fn (
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            env_map: *const std.process.Environ.Map,
            cwd: []const u8,
            session: *session_mod.AgentSession,
            live_resources: *LiveResources,
        ) anyerror!void,
    };

    runtime_config: ?*const config_mod.RuntimeConfig,
    keybindings: ?*const keybindings_mod.Keybindings,
    prompt_templates: []const resources_mod.PromptTemplate,
    skills: []const resources_mod.Skill,
    theme: ?*const resources_mod.Theme,
    terminal_name: []const u8,
    extension_command_sink: ?ExtensionCommandSink = null,
    extension_shortcut_sink: ?ExtensionShortcutSink = null,
    reload_extension_tools_sink: ?ReloadExtensionToolsSink = null,
    startup_cli_extensions: []const []const u8,
    include_default_extensions: bool,
    runtime_theme_name: ?[]u8 = null,
    owned_runtime_config: ?config_mod.RuntimeConfig = null,
    owned_resource_bundle: ?resources_mod.ResourceBundle = null,

    pub fn init(options: RunInteractiveModeOptions) LiveResources {
        return .{
            .runtime_config = options.runtime_config,
            .keybindings = options.keybindings,
            .prompt_templates = options.prompt_templates,
            .skills = options.skills,
            .theme = options.theme,
            .terminal_name = if (options.terminal_name.len > 0) options.terminal_name else "term",
            .startup_cli_extensions = options.startup_cli_extensions,
            .include_default_extensions = options.include_default_extensions,
        };
    }

    pub fn dispatchExtensionCommand(self: *LiveResources, raw_command: []const u8) !bool {
        const sink = self.extension_command_sink orelse return false;
        return try sink.callback(sink.context, raw_command);
    }

    pub fn dispatchExtensionShortcut(self: *LiveResources, key: tui.Key, modifiers: tui.keys.KeyModifiers) !bool {
        const sink = self.extension_shortcut_sink orelse return false;
        return try sink.callback(sink.context, key, modifiers);
    }

    pub fn deinit(self: *LiveResources, allocator: std.mem.Allocator) void {
        self.deinitOwnedResources(allocator);
        if (self.runtime_theme_name) |name| {
            allocator.free(name);
            self.runtime_theme_name = null;
        }
    }

    fn deinitOwnedResources(self: *LiveResources, allocator: std.mem.Allocator) void {
        if (self.owned_resource_bundle) |*bundle| {
            bundle.deinit(allocator);
            self.owned_resource_bundle = null;
        }
        if (self.owned_runtime_config) |*runtime_config| {
            runtime_config.deinit();
            self.owned_runtime_config = null;
        }
    }

    pub fn ensureOwnedBundle(
        self: *LiveResources,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
    ) !void {
        if (self.owned_resource_bundle != null and self.owned_runtime_config != null) return;
        _ = try self.reload(allocator, io, env_map, cwd);
    }

    pub fn applyTheme(
        self: *LiveResources,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
        theme_name: []const u8,
    ) !void {
        try self.ensureOwnedBundle(allocator, io, env_map, cwd);
        const bundle = &self.owned_resource_bundle.?;
        if (resources_mod.findThemeIndex(bundle.themes, theme_name) == null) return error.ThemeNotFound;

        try self.setRuntimeThemeName(allocator, theme_name);
        bundle.selected_theme_index = self.resolveSelectedThemeIndex(env_map);
        self.theme = bundle.selectedTheme();
    }

    pub fn reload(
        self: *LiveResources,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
    ) ![]const resources_mod.Diagnostic {
        const runtime_theme_copy = if (self.runtime_theme_name) |name|
            try allocator.dupe(u8, name)
        else
            null;
        errdefer if (runtime_theme_copy) |name| allocator.free(name);

        var next_runtime = try config_mod.loadRuntimeConfig(allocator, io, env_map, cwd);
        errdefer next_runtime.deinit();

        var next_bundle = try resources_mod.loadResourceBundle(allocator, io, .{
            .cwd = cwd,
            .agent_dir = next_runtime.agent_dir,
            .global = settingsResources(next_runtime.global_settings),
            .project = settingsResources(next_runtime.project_settings),
            .cli_extensions = self.startup_cli_extensions,
            .runtime_theme = runtime_theme_copy,
            .env_map = env_map,
            .include_default_extensions = self.include_default_extensions,
        });
        errdefer next_bundle.deinit(allocator);

        self.deinitOwnedResources(allocator);
        if (self.runtime_theme_name) |name| allocator.free(name);
        self.runtime_theme_name = runtime_theme_copy;
        self.owned_runtime_config = next_runtime;
        self.owned_resource_bundle = next_bundle;
        self.runtime_config = &self.owned_runtime_config.?;
        self.keybindings = &self.owned_runtime_config.?.keybindings;
        self.prompt_templates = self.owned_resource_bundle.?.prompt_templates;
        self.skills = self.owned_resource_bundle.?.skills;
        self.theme = self.owned_resource_bundle.?.selectedTheme();
        self.terminal_name = self.owned_resource_bundle.?.terminal_name;
        return self.owned_resource_bundle.?.diagnostics;
    }

    fn setRuntimeThemeName(
        self: *LiveResources,
        allocator: std.mem.Allocator,
        theme_name: []const u8,
    ) !void {
        const next = try allocator.dupe(u8, theme_name);
        if (self.runtime_theme_name) |old| allocator.free(old);
        self.runtime_theme_name = next;
    }

    fn resolveSelectedThemeIndex(
        self: *const LiveResources,
        env_map: *const std.process.Environ.Map,
    ) usize {
        const bundle = &self.owned_resource_bundle.?;
        const runtime_config = &self.owned_runtime_config.?;
        return resources_mod.resolveThemeIndex(
            bundle.themes,
            env_map,
            self.runtime_theme_name,
            runtime_config.project_settings.theme,
            runtime_config.global_settings.theme,
        );
    }
};

pub fn currentSessionLabel(session: *const session_mod.AgentSession) []const u8 {
    if (session.session_manager.getSessionName()) |name| return name;
    return if (session.session_manager.getSessionFile()) |path|
        std.fs.path.basename(path)
    else
        session.session_manager.getSessionId();
}

pub fn configuredCredentials(runtime_config: ?*const config_mod.RuntimeConfig) provider_config.ConfiguredCredentials {
    if (runtime_config) |value| {
        return .{
            .auth_tokens = &value.auth_tokens,
            .provider_api_keys = &value.provider_api_keys,
        };
    }
    return .{};
}

pub fn configuredApiKeyForProvider(runtime_config: ?*const config_mod.RuntimeConfig, provider_name: []const u8) ?[]const u8 {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.lookupApiKey(provider_name);
    }
    return null;
}

pub fn configuredCompactionSettings(runtime_config: ?*const config_mod.RuntimeConfig) session_mod.CompactionSettings {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.settings.compaction orelse .{};
    }
    return .{};
}

pub fn configuredRetrySettings(runtime_config: ?*const config_mod.RuntimeConfig) session_mod.RetrySettings {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.settings.retry orelse .{};
    }
    return .{};
}

pub fn settingsResources(settings: config_mod.Settings) resources_mod.SettingsResources {
    return .{
        .packages = settings.packages,
        .extensions = settings.extensions,
        .skills = settings.skills,
        .prompts = settings.prompts,
        .themes = settings.themes,
        .theme = settings.theme,
    };
}

pub fn normalizePathArgument(argument: []const u8) []const u8 {
    if (argument.len >= 2) {
        const first = argument[0];
        const last = argument[argument.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return argument[1 .. argument.len - 1];
        }
    }
    return argument;
}

pub fn overrideApiKeyForProvider(options: RunInteractiveModeOptions, provider_name: []const u8) ?[]const u8 {
    if (options.api_key) |api_key| {
        if (std.mem.eql(u8, provider_name, options.provider)) return api_key;
    }
    return null;
}
