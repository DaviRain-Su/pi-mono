const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;
const string_utils = ai.shared.string_utils;
const agent = @import("agent");
const auth = @import("../auth/auth.zig");
const config_errors = @import("config_errors.zig");
const capability = @import("../extensions/capability.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const migrations = @import("migrations.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");

const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 16384;
const DEFAULT_RESERVE_TOKENS = 4096;
const DEFAULT_KEEP_RECENT_TOKENS = 20000;
const DEFAULT_MAX_RETRIES = 2;
const DEFAULT_BASE_DELAY_MS = 1000;

pub const ConfigError = config_errors.ConfigError;
pub const ConfigErrorSource = config_errors.Source;
pub const configErrorSourceName = config_errors.sourceName;

pub const DoubleEscapeAction = enum {
    fork,
    tree,
    none,
};

pub const QueueModeSetting = enum {
    all,
    one_at_a_time,
};

pub const TreeFilterMode = enum {
    default,
    no_tools,
    user_only,
    labeled_only,
    all,
};

const MAX_SAFE_INTEGER: u64 = 9007199254740991;

pub const ExtensionResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: ?[]const []const u8 = null,

    pub fn deinit(self: *ExtensionResourceLimits, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.tool_scopes);
        self.* = .{};
    }

    fn clone(self: ExtensionResourceLimits, allocator: std.mem.Allocator) !ExtensionResourceLimits {
        return .{
            .max_children = self.max_children,
            .depth = self.depth,
            .turns = self.turns,
            .timeout_ms = self.timeout_ms,
            .output_bytes = self.output_bytes,
            .output_lines = self.output_lines,
            .tool_scopes = try cloneStringList(allocator, self.tool_scopes),
        };
    }
};

pub const ExtensionPolicy = struct {
    approved_grants: ?[]const []const u8 = null,
    resource_limits: ?ExtensionResourceLimits = null,
    approved: ?bool = null,
    enabled: ?bool = null,
    required: ?bool = null,

    pub fn deinit(self: *ExtensionPolicy, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.approved_grants);
        if (self.resource_limits) |*limits| limits.deinit(allocator);
        self.* = .{};
    }

    fn clone(self: ExtensionPolicy, allocator: std.mem.Allocator) !ExtensionPolicy {
        var cloned = ExtensionPolicy{};
        errdefer cloned.deinit(allocator);
        cloned.approved_grants = try cloneStringList(allocator, self.approved_grants);
        cloned.resource_limits = if (self.resource_limits) |limits| try limits.clone(allocator) else null;
        cloned.approved = self.approved;
        cloned.enabled = self.enabled;
        cloned.required = self.required;
        return cloned;
    }
};

pub const ExtensionPolicyMap = std.StringHashMap(ExtensionPolicy);

pub const Settings = struct {
    default_provider: ?[]u8 = null,
    default_model: ?[]u8 = null,
    enabled_models: ?[]const []const u8 = null,
    default_thinking_level: ?agent.ThinkingLevel = null,
    transport: ?ai.types.Transport = null,
    steering_mode: ?QueueModeSetting = null,
    follow_up_mode: ?QueueModeSetting = null,
    theme: ?[]u8 = null,
    session_dir: ?[]u8 = null,
    hide_thinking_block: ?bool = null,
    quiet_startup: ?bool = null,
    collapse_changelog: ?bool = null,
    enable_install_telemetry: ?bool = null,
    enable_skill_commands: ?bool = null,
    show_hardware_cursor: ?bool = null,
    terminal_show_images: ?bool = null,
    terminal_image_width_cells: ?usize = null,
    terminal_clear_on_shrink: ?bool = null,
    terminal_show_progress: ?bool = null,
    editor_padding_x: ?usize = null,
    autocomplete_max_visible: ?usize = null,
    /// Mirrors TypeScript `settings.images.autoResize`. When null the
    /// runtime defaults to `true` (TS default) via
    /// `RuntimeConfig.imageAutoResize`.
    image_auto_resize: ?bool = null,
    image_block_images: ?bool = null,
    double_escape_action: ?DoubleEscapeAction = null,
    tree_filter_mode: ?TreeFilterMode = null,
    warning_anthropic_extra_usage: ?bool = null,
    branch_summary_skip_prompt: ?bool = null,
    compaction: ?session_mod.CompactionSettings = null,
    retry: ?session_mod.RetrySettings = null,
    packages: ?[]const resources_mod.PackageSourceConfig = null,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,
    extension_policies: ?ExtensionPolicyMap = null,

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.default_provider) |value| allocator.free(value);
        if (self.default_model) |value| allocator.free(value);
        freeStringList(allocator, self.enabled_models);
        if (self.theme) |value| allocator.free(value);
        if (self.session_dir) |value| allocator.free(value);
        freePackageSources(allocator, self.packages);
        freeStringList(allocator, self.extensions);
        freeStringList(allocator, self.skills);
        freeStringList(allocator, self.prompts);
        freeStringList(allocator, self.themes);
        deinitExtensionPolicyMap(allocator, self.extension_policies);
        self.* = .{};
    }

    fn clone(self: Settings, allocator: std.mem.Allocator) !Settings {
        return .{
            .default_provider = if (self.default_provider) |value| try allocator.dupe(u8, value) else null,
            .default_model = if (self.default_model) |value| try allocator.dupe(u8, value) else null,
            .enabled_models = try cloneStringList(allocator, self.enabled_models),
            .default_thinking_level = self.default_thinking_level,
            .transport = self.transport,
            .steering_mode = self.steering_mode,
            .follow_up_mode = self.follow_up_mode,
            .theme = if (self.theme) |value| try allocator.dupe(u8, value) else null,
            .session_dir = if (self.session_dir) |value| try allocator.dupe(u8, value) else null,
            .hide_thinking_block = self.hide_thinking_block,
            .quiet_startup = self.quiet_startup,
            .collapse_changelog = self.collapse_changelog,
            .enable_install_telemetry = self.enable_install_telemetry,
            .enable_skill_commands = self.enable_skill_commands,
            .show_hardware_cursor = self.show_hardware_cursor,
            .terminal_show_images = self.terminal_show_images,
            .terminal_image_width_cells = self.terminal_image_width_cells,
            .terminal_clear_on_shrink = self.terminal_clear_on_shrink,
            .terminal_show_progress = self.terminal_show_progress,
            .editor_padding_x = self.editor_padding_x,
            .autocomplete_max_visible = self.autocomplete_max_visible,
            .image_auto_resize = self.image_auto_resize,
            .image_block_images = self.image_block_images,
            .double_escape_action = self.double_escape_action,
            .tree_filter_mode = self.tree_filter_mode,
            .warning_anthropic_extra_usage = self.warning_anthropic_extra_usage,
            .branch_summary_skip_prompt = self.branch_summary_skip_prompt,
            .compaction = self.compaction,
            .retry = self.retry,
            .packages = try clonePackageSources(allocator, self.packages),
            .extensions = try cloneStringList(allocator, self.extensions),
            .skills = try cloneStringList(allocator, self.skills),
            .prompts = try cloneStringList(allocator, self.prompts),
            .themes = try cloneStringList(allocator, self.themes),
            .extension_policies = try cloneExtensionPolicyMap(allocator, self.extension_policies),
        };
    }
};

pub const RuntimeConfig = struct {
    allocator: std.mem.Allocator,
    agent_dir: []u8,
    settings: Settings,
    global_settings: Settings,
    project_settings: Settings,
    auth_tokens: std.StringHashMap([]const u8),
    provider_api_keys: std.StringHashMap([]const u8),
    keybindings: keybindings_mod.Keybindings,
    errors: []ConfigError = &.{},

    pub fn deinit(self: *RuntimeConfig) void {
        self.allocator.free(self.agent_dir);
        self.settings.deinit(self.allocator);
        self.global_settings.deinit(self.allocator);
        self.project_settings.deinit(self.allocator);
        deinitStringMap(self.allocator, &self.auth_tokens);
        deinitStringMap(self.allocator, &self.provider_api_keys);
        self.keybindings.deinit();
        config_errors.deinitSlice(self.allocator, self.errors);
        self.* = undefined;
    }

    /// Mirrors TS `settingsManager.getImageAutoResize()`: defaults to `true`
    /// when the merged `images.autoResize` is unset.
    pub fn imageAutoResize(self: *const RuntimeConfig) bool {
        return self.settings.image_auto_resize orelse true;
    }

    pub fn blockImages(self: *const RuntimeConfig) bool {
        return self.settings.image_block_images orelse false;
    }

    pub fn showImages(self: *const RuntimeConfig) bool {
        return self.settings.terminal_show_images orelse true;
    }

    pub fn imageWidthCells(self: *const RuntimeConfig) usize {
        return self.settings.terminal_image_width_cells orelse 60;
    }

    pub fn clearOnShrink(self: *const RuntimeConfig) bool {
        return self.settings.terminal_clear_on_shrink orelse false;
    }

    pub fn showTerminalProgress(self: *const RuntimeConfig) bool {
        return self.settings.terminal_show_progress orelse false;
    }

    pub fn enableSkillCommands(self: *const RuntimeConfig) bool {
        return self.settings.enable_skill_commands orelse true;
    }

    pub fn hideThinkingBlock(self: *const RuntimeConfig) bool {
        return self.settings.hide_thinking_block orelse false;
    }

    pub fn collapseChangelog(self: *const RuntimeConfig) bool {
        return self.settings.collapse_changelog orelse false;
    }

    pub fn quietStartup(self: *const RuntimeConfig) bool {
        return self.settings.quiet_startup orelse false;
    }

    pub fn enableInstallTelemetry(self: *const RuntimeConfig) bool {
        return self.settings.enable_install_telemetry orelse true;
    }

    pub fn showHardwareCursor(self: *const RuntimeConfig) bool {
        return self.settings.show_hardware_cursor orelse false;
    }

    pub fn transport(self: *const RuntimeConfig) ai.types.Transport {
        return self.settings.transport orelse .auto;
    }

    pub fn steeringMode(self: *const RuntimeConfig) QueueModeSetting {
        return self.settings.steering_mode orelse .one_at_a_time;
    }

    pub fn followUpMode(self: *const RuntimeConfig) QueueModeSetting {
        return self.settings.follow_up_mode orelse .one_at_a_time;
    }

    /// Mirrors TS `settingsManager.getDoubleEscapeAction()`: defaults to
    /// opening the session tree on a double Escape when unset.
    pub fn doubleEscapeAction(self: *const RuntimeConfig) DoubleEscapeAction {
        return self.settings.double_escape_action orelse .tree;
    }

    pub fn treeFilterMode(self: *const RuntimeConfig) TreeFilterMode {
        return self.settings.tree_filter_mode orelse .default;
    }

    pub fn warningAnthropicExtraUsage(self: *const RuntimeConfig) bool {
        return self.settings.warning_anthropic_extra_usage orelse true;
    }

    pub fn branchSummarySkipPrompt(self: *const RuntimeConfig) bool {
        return self.settings.branch_summary_skip_prompt orelse false;
    }

    pub fn lookupApiKey(self: *const RuntimeConfig, provider: []const u8) ?[]const u8 {
        if (self.auth_tokens.get(provider)) |value| {
            if (isNonEmptyCredentialValue(value)) return value;
        }
        if (self.provider_api_keys.get(provider)) |value| {
            if (isNonEmptyCredentialValue(value)) return value;
        }
        return null;
    }

    pub fn getExtensionPolicy(self: *const RuntimeConfig, identity_key: []const u8) ?ExtensionPolicy {
        var policies = self.settings.extension_policies orelse return null;
        var iterator = policies.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, identity_key)) return entry.value_ptr.*;
        }
        return null;
    }

    /// Resolves the runtime session directory using the same precedence as
    /// the M10 missing-cwd preflight (`runtime_prep.resolvePreflightSessionDir`)
    /// and TypeScript `main.ts`:
    ///
    ///   1. `$PI_CODING_AGENT_SESSION_DIR` env var (TS `ENV_SESSION_DIR`)
    ///   2. `settings.json` `sessionDir` from merged global/project settings
    ///   3. Default `<cwd>/.pi/sessions`
    ///
    /// `--session-dir` overrides this entirely and is applied by the caller
    /// before `effectiveSessionDir` runs, so it is not re-checked here.
    /// Aligning the env-var precedence with the preflight ensures the
    /// missing-cwd diagnostic always refers to the same session directory
    /// the runtime will later open.
    pub fn effectiveSessionDir(self: *const RuntimeConfig, allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, cwd: []const u8) ![]u8 {
        if (env_map.get("PI_CODING_AGENT_SESSION_DIR")) |value| {
            if (value.len > 0) {
                return expandPath(allocator, env_map, value, cwd);
            }
        }
        if (self.settings.session_dir) |value| {
            return expandPath(allocator, env_map, value, cwd);
        }
        return std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    }
};

pub const RuntimeConfigLoadOptions = struct {
    discover_models: bool = true,
};

pub fn loadRuntimeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !RuntimeConfig {
    return loadRuntimeConfigWithOptions(allocator, io, env_map, cwd, .{
        .discover_models = !isTruthyEnvFlag(env_map.get("PI_OFFLINE")),
    });
}

pub fn loadRuntimeConfigWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: RuntimeConfigLoadOptions,
) !RuntimeConfig {
    const agent_dir = try resolveAgentDir(allocator, env_map);
    errdefer allocator.free(agent_dir);
    try migrations.run(allocator, io, agent_dir);

    const global_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    const models_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "models.json" });
    defer allocator.free(models_path);
    const keybindings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "keybindings.json" });
    defer allocator.free(keybindings_path);

    ai.model_registry.clearDefault();

    var errors = std.ArrayList(ConfigError).empty;
    errdefer config_errors.deinitList(allocator, &errors);

    var global_settings = try loadSettingsFile(allocator, io, global_settings_path, &errors, .settings);
    errdefer global_settings.deinit(allocator);
    var project_settings = try loadSettingsFile(allocator, io, project_settings_path, &errors, .settings);
    errdefer project_settings.deinit(allocator);
    var settings = try mergeSettings(allocator, global_settings, project_settings);
    errdefer settings.deinit(allocator);

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitStringMap(allocator, &auth_tokens);
    try loadAuthTokens(allocator, io, env_map, auth_path, &auth_tokens);
    try loadLegacySettingsApiKeys(allocator, io, global_settings_path, &auth_tokens, &errors);

    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitStringMap(allocator, &provider_api_keys);
    try loadModelsConfig(allocator, io, models_path, &provider_api_keys, options.discover_models, &errors);

    var keybindings = try keybindings_mod.loadFromFile(allocator, io, keybindings_path);
    errdefer keybindings.deinit();

    const owned_errors = try errors.toOwnedSlice(allocator);
    errdefer config_errors.deinitSlice(allocator, owned_errors);

    return .{
        .allocator = allocator,
        .agent_dir = agent_dir,
        .settings = settings,
        .global_settings = global_settings,
        .project_settings = project_settings,
        .auth_tokens = auth_tokens,
        .provider_api_keys = provider_api_keys,
        .keybindings = keybindings,
        .errors = owned_errors,
    };
}

fn isTruthyEnvFlag(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(text, "1") or
        std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on");
}

fn loadMergedSettings(allocator: std.mem.Allocator, io: std.Io, global_path: []const u8, project_path: []const u8) !Settings {
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var global = try loadSettingsFile(allocator, io, global_path, &errors, .settings);
    defer global.deinit(allocator);
    var project = try loadSettingsFile(allocator, io, project_path, &errors, .settings);
    defer project.deinit(allocator);
    return mergeSettings(allocator, global, project);
}

/// Loads the merged global+project settings only; used by the M10
/// missing-cwd lifecycle preflight to resolve the effective session
/// directory before `prepareCliRuntime` performs heavier work that could
/// fail and preempt the diagnostic. Caller owns the returned `Settings` and
/// must call `Settings.deinit`.
pub fn loadMergedSettingsForPreflight(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !Settings {
    const agent_dir = try resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    const global_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    return loadMergedSettings(allocator, io, global_settings_path, project_settings_path);
}

fn loadSettingsFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
) !Settings {
    const result = Settings{};
    const content = try readOptionalFile(allocator, io, path);
    defer if (content) |value| allocator.free(value);
    if (content == null) return result;

    return parseSettingsContent(allocator, path, content.?, errors, source);
}

/// Kinds covering every simple settings field that the table-driven parser
/// and merger need to know about. Irregular fields (`compaction`, `retry`,
/// `packages`, `extensionPolicies`) are handled out-of-band.
const SettingFieldKind = enum {
    string_alloc,
    bool_field,
    positive_usize,
    non_negative_usize,
    thinking_level,
    transport,
    queue_mode,
    double_escape_action,
    tree_filter_mode,
    string_list,
};

const SettingFieldSpec = struct {
    json_key: []const u8,
    field: []const u8,
    kind: SettingFieldKind,
};

const SettingGroupSpec = struct {
    json_key: []const u8,
    fields: []const SettingFieldSpec,
};

const TOP_LEVEL_SETTINGS: []const SettingFieldSpec = &.{
    .{ .json_key = "defaultProvider", .field = "default_provider", .kind = .string_alloc },
    .{ .json_key = "defaultModel", .field = "default_model", .kind = .string_alloc },
    .{ .json_key = "enabledModels", .field = "enabled_models", .kind = .string_list },
    .{ .json_key = "defaultThinkingLevel", .field = "default_thinking_level", .kind = .thinking_level },
    .{ .json_key = "transport", .field = "transport", .kind = .transport },
    .{ .json_key = "steeringMode", .field = "steering_mode", .kind = .queue_mode },
    .{ .json_key = "followUpMode", .field = "follow_up_mode", .kind = .queue_mode },
    .{ .json_key = "theme", .field = "theme", .kind = .string_alloc },
    .{ .json_key = "sessionDir", .field = "session_dir", .kind = .string_alloc },
    .{ .json_key = "hideThinkingBlock", .field = "hide_thinking_block", .kind = .bool_field },
    .{ .json_key = "quietStartup", .field = "quiet_startup", .kind = .bool_field },
    .{ .json_key = "collapseChangelog", .field = "collapse_changelog", .kind = .bool_field },
    .{ .json_key = "enableInstallTelemetry", .field = "enable_install_telemetry", .kind = .bool_field },
    .{ .json_key = "enableSkillCommands", .field = "enable_skill_commands", .kind = .bool_field },
    .{ .json_key = "showHardwareCursor", .field = "show_hardware_cursor", .kind = .bool_field },
    .{ .json_key = "editorPaddingX", .field = "editor_padding_x", .kind = .non_negative_usize },
    .{ .json_key = "autocompleteMaxVisible", .field = "autocomplete_max_visible", .kind = .positive_usize },
    .{ .json_key = "doubleEscapeAction", .field = "double_escape_action", .kind = .double_escape_action },
    .{ .json_key = "treeFilterMode", .field = "tree_filter_mode", .kind = .tree_filter_mode },
    .{ .json_key = "extensions", .field = "extensions", .kind = .string_list },
    .{ .json_key = "skills", .field = "skills", .kind = .string_list },
    .{ .json_key = "prompts", .field = "prompts", .kind = .string_list },
    .{ .json_key = "themes", .field = "themes", .kind = .string_list },
};

const TERMINAL_FIELDS: []const SettingFieldSpec = &.{
    .{ .json_key = "showImages", .field = "terminal_show_images", .kind = .bool_field },
    .{ .json_key = "imageWidthCells", .field = "terminal_image_width_cells", .kind = .positive_usize },
    .{ .json_key = "clearOnShrink", .field = "terminal_clear_on_shrink", .kind = .bool_field },
    .{ .json_key = "showTerminalProgress", .field = "terminal_show_progress", .kind = .bool_field },
};

const IMAGES_FIELDS: []const SettingFieldSpec = &.{
    .{ .json_key = "autoResize", .field = "image_auto_resize", .kind = .bool_field },
    .{ .json_key = "blockImages", .field = "image_block_images", .kind = .bool_field },
};

const WARNINGS_FIELDS: []const SettingFieldSpec = &.{
    .{ .json_key = "anthropicExtraUsage", .field = "warning_anthropic_extra_usage", .kind = .bool_field },
};

const BRANCH_SUMMARY_FIELDS: []const SettingFieldSpec = &.{
    .{ .json_key = "skipPrompt", .field = "branch_summary_skip_prompt", .kind = .bool_field },
};

const NESTED_SETTINGS: []const SettingGroupSpec = &.{
    .{ .json_key = "terminal", .fields = TERMINAL_FIELDS },
    .{ .json_key = "images", .fields = IMAGES_FIELDS },
    .{ .json_key = "warnings", .fields = WARNINGS_FIELDS },
    .{ .json_key = "branchSummary", .fields = BRANCH_SUMMARY_FIELDS },
};

comptime {
    for (TOP_LEVEL_SETTINGS) |spec| {
        if (!@hasField(Settings, spec.field)) @compileError("invalid Settings field name: " ++ spec.field);
    }
    for (NESTED_SETTINGS) |group| {
        for (group.fields) |spec| {
            if (!@hasField(Settings, spec.field)) @compileError("invalid Settings field name: " ++ spec.field);
        }
    }
}

/// Apply a single spec to `settings` from a JSON value that is already
/// known to exist (caller has already done `object.get(key)`).
/// Wrong-typed values are silently ignored to preserve the prior chain's
/// behavior — for example a string under `hideThinkingBlock` leaves the
/// field at its default rather than emitting a diagnostic.
fn applySettingFromJson(
    comptime spec: SettingFieldSpec,
    allocator: std.mem.Allocator,
    value: std.json.Value,
    settings: *Settings,
) !void {
    switch (spec.kind) {
        .string_alloc => {
            if (value == .string) {
                @field(settings, spec.field) = try allocator.dupe(u8, value.string);
            }
        },
        .bool_field => {
            if (value == .bool) @field(settings, spec.field) = value.bool;
        },
        .positive_usize => {
            @field(settings, spec.field) = parsePositiveUsize(value);
        },
        .non_negative_usize => {
            @field(settings, spec.field) = parseNonNegativeUsize(value);
        },
        .thinking_level => {
            if (value == .string) @field(settings, spec.field) = parseThinkingLevel(value.string);
        },
        .transport => {
            if (value == .string) @field(settings, spec.field) = parseTransport(value.string);
        },
        .queue_mode => {
            if (value == .string) @field(settings, spec.field) = parseQueueModeSetting(value.string);
        },
        .double_escape_action => {
            if (value == .string) @field(settings, spec.field) = parseDoubleEscapeAction(value.string);
        },
        .tree_filter_mode => {
            if (value == .string) @field(settings, spec.field) = parseTreeFilterMode(value.string);
        },
        .string_list => {
            @field(settings, spec.field) = try parseStringList(allocator, value);
        },
    }
}

fn parseSettingsContent(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
) !Settings {
    var result = Settings{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, source, path, err);
        return result;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try config_errors.appendMessage(allocator, errors, source, path, "expected JSON object");
        return result;
    }

    inline for (TOP_LEVEL_SETTINGS) |spec| {
        if (parsed.value.object.get(spec.json_key)) |value| {
            try applySettingFromJson(spec, allocator, value, &result);
        }
    }

    inline for (NESTED_SETTINGS) |group| {
        if (parsed.value.object.get(group.json_key)) |group_value| {
            if (group_value == .object) {
                inline for (group.fields) |spec| {
                    if (group_value.object.get(spec.json_key)) |value| {
                        try applySettingFromJson(spec, allocator, value, &result);
                    }
                }
            }
        }
    }

    if (parsed.value.object.get("compaction")) |value| {
        result.compaction = parseCompactionSettings(value);
    }
    if (parsed.value.object.get("retry")) |value| {
        result.retry = parseRetrySettings(value);
    }
    result.packages = try parsePackageSources(allocator, parsed.value.object.get("packages"));
    result.extension_policies = try parseExtensionPolicyMap(
        allocator,
        parsed.value.object.get("extensionPolicies"),
        errors,
        source,
        path,
    );
    return result;
}

/// Merge a single spec from `overrides` into `merged`. The semantics mirror
/// the prior per-field chain: optional scalars copy when set, strings are
/// duplicated, and string lists are wholly replaced when present on the
/// override (including empty-list overrides).
fn mergeSettingFromOverride(
    comptime spec: SettingFieldSpec,
    allocator: std.mem.Allocator,
    overrides: Settings,
    merged: *Settings,
) !void {
    switch (spec.kind) {
        .string_alloc => {
            if (@field(overrides, spec.field)) |value| {
                if (@field(merged, spec.field)) |existing| allocator.free(existing);
                @field(merged, spec.field) = try allocator.dupe(u8, value);
            }
        },
        .string_list => {
            if (@field(overrides, spec.field) != null) {
                freeStringList(allocator, @field(merged, spec.field));
                @field(merged, spec.field) = try cloneStringList(allocator, @field(overrides, spec.field));
            }
        },
        else => {
            if (@field(overrides, spec.field)) |value| @field(merged, spec.field) = value;
        },
    }
}

fn mergeSettings(allocator: std.mem.Allocator, base: Settings, overrides: Settings) !Settings {
    var merged = try base.clone(allocator);
    errdefer merged.deinit(allocator);

    inline for (TOP_LEVEL_SETTINGS) |spec| {
        try mergeSettingFromOverride(spec, allocator, overrides, &merged);
    }
    inline for (NESTED_SETTINGS) |group| {
        inline for (group.fields) |spec| {
            try mergeSettingFromOverride(spec, allocator, overrides, &merged);
        }
    }

    merged.compaction = mergeCompaction(base.compaction, overrides.compaction);
    merged.retry = mergeRetry(base.retry, overrides.retry);
    if (overrides.packages != null) {
        freePackageSources(allocator, merged.packages);
        merged.packages = try clonePackageSources(allocator, overrides.packages);
    }
    if (overrides.extension_policies != null) {
        const replacement = try mergeExtensionPolicyMaps(allocator, merged.extension_policies, overrides.extension_policies);
        deinitExtensionPolicyMap(allocator, merged.extension_policies);
        merged.extension_policies = replacement;
    }
    return merged;
}

fn mergeCompaction(base: ?session_mod.CompactionSettings, overrides: ?session_mod.CompactionSettings) ?session_mod.CompactionSettings {
    if (base == null and overrides == null) return null;
    var merged = base orelse session_mod.CompactionSettings{};
    if (overrides) |value| {
        merged.enabled = value.enabled;
        merged.reserve_tokens = value.reserve_tokens;
        merged.keep_recent_tokens = value.keep_recent_tokens;
    }
    return merged;
}

fn mergeRetry(base: ?session_mod.RetrySettings, overrides: ?session_mod.RetrySettings) ?session_mod.RetrySettings {
    if (base == null and overrides == null) return null;
    var merged = base orelse session_mod.RetrySettings{};
    if (overrides) |value| {
        merged.enabled = value.enabled;
        merged.max_retries = value.max_retries;
        merged.base_delay_ms = value.base_delay_ms;
    }
    return merged;
}

pub fn validateExtensionPoliciesForSettingsWrite(
    allocator: std.mem.Allocator,
    settings_object: std.json.ObjectMap,
    settings_path: []const u8,
) !void {
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var parsed = try parseExtensionPolicyMap(
        allocator,
        settings_object.get("extensionPolicies"),
        &errors,
        .settings,
        settings_path,
    );
    if (parsed) |*policies| deinitExtensionPolicyMapRequired(allocator, policies);
    if (errors.items.len > 0) return error.InvalidExtensionPolicies;
}

fn parseExtensionPolicyMap(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    path: []const u8,
) !?ExtensionPolicyMap {
    const map_value = value orelse return null;
    if (map_value != .object) {
        try appendPolicyMessage(allocator, errors, source, path, "$.extensionPolicies: expected object");
        return null;
    }

    var policies = ExtensionPolicyMap.init(allocator);
    errdefer deinitExtensionPolicyMapRequired(allocator, &policies);

    var iterator = map_value.object.iterator();
    while (iterator.next()) |entry| {
        const identity = entry.key_ptr.*;
        const policy_path = try extensionPolicyEntryPath(allocator, identity);
        defer allocator.free(policy_path);
        if (identity.len == 0) {
            const message = try std.fmt.allocPrint(allocator, "{s}: extension identity must not be empty", .{policy_path});
            defer allocator.free(message);
            try appendPolicyMessage(allocator, errors, source, path, message);
            continue;
        }
        var policy = (try parseExtensionPolicyShape(allocator, entry.value_ptr.*, errors, source, path, policy_path)) orelse continue;
        errdefer policy.deinit(allocator);
        const owned_identity = try allocator.dupe(u8, identity);
        errdefer allocator.free(owned_identity);
        if (try policies.fetchPut(owned_identity, policy)) |previous| {
            allocator.free(owned_identity);
            var previous_policy = previous.value;
            previous_policy.deinit(allocator);
        }
    }

    return policies;
}

fn parseExtensionPolicyShape(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
) !?ExtensionPolicy {
    if (value != .object) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}: expected object", .{policy_path});
        return null;
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (!isPolicyField(entry.key_ptr.*)) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: unsupported policy field", .{ policy_path, entry.key_ptr.* });
            return null;
        }
    }

    var policy = ExtensionPolicy{};
    errdefer policy.deinit(allocator);
    if (value.object.get("approvedGrants")) |approved_grants| {
        policy.approved_grants = (try parseApprovedGrants(allocator, approved_grants, errors, source, settings_path, policy_path)) orelse return null;
    }
    if (value.object.get("resourceLimits")) |resource_limits| {
        policy.resource_limits = (try parseResourceLimits(allocator, resource_limits, errors, source, settings_path, policy_path)) orelse {
            policy.deinit(allocator);
            return null;
        };
    }
    if (!try parseAndAssignPolicyBool(allocator, value.object.get("approved"), errors, source, settings_path, policy_path, "approved", &policy.approved)) return null;
    if (!try parseAndAssignPolicyBool(allocator, value.object.get("enabled"), errors, source, settings_path, policy_path, "enabled", &policy.enabled)) return null;
    if (!try parseAndAssignPolicyBool(allocator, value.object.get("required"), errors, source, settings_path, policy_path, "required", &policy.required)) return null;
    return policy;
}

fn parseAndAssignPolicyBool(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
    field_name: []const u8,
    target: *?bool,
) !bool {
    const field = value orelse return true;
    if (field != .bool) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: expected boolean", .{ policy_path, field_name });
        return false;
    }
    target.* = field.bool;
    return true;
}

fn parseApprovedGrants(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
) !?[]const []const u8 {
    if (value != .array) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.approvedGrants: expected array", .{policy_path});
        return null;
    }
    var grants = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringArrayList(allocator, &grants);
    for (value.array.items, 0..) |grant_value, index| {
        if (grant_value != .string) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.approvedGrants[{d}]: expected string", .{ policy_path, index });
            deinitOwnedStringArrayList(allocator, &grants);
            return null;
        }
        if (!isCanonicalExtensionGrant(grant_value.string)) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.approvedGrants[{d}]: unknown grant \"{s}\"", .{ policy_path, index, grant_value.string });
            deinitOwnedStringArrayList(allocator, &grants);
            return null;
        }
        try appendOwnedString(allocator, &grants, grant_value.string);
    }
    return try grants.toOwnedSlice(allocator);
}

fn deinitOwnedStringArrayList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn parseResourceLimits(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
) !?ExtensionResourceLimits {
    const limits_path = try std.fmt.allocPrint(allocator, "{s}.resourceLimits", .{policy_path});
    defer allocator.free(limits_path);
    if (value != .object) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}: expected object", .{limits_path});
        return null;
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (!isResourceLimitField(entry.key_ptr.*)) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: unsupported resource limit", .{ limits_path, entry.key_ptr.* });
            return null;
        }
    }

    var limits = ExtensionResourceLimits{};
    errdefer limits.deinit(allocator);
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("maxChildren"), errors, source, settings_path, limits_path, "maxChildren", &limits.max_children)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("depth"), errors, source, settings_path, limits_path, "depth", &limits.depth)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("turns"), errors, source, settings_path, limits_path, "turns", &limits.turns)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("timeoutMs"), errors, source, settings_path, limits_path, "timeoutMs", &limits.timeout_ms)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("outputBytes"), errors, source, settings_path, limits_path, "outputBytes", &limits.output_bytes)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("outputLines"), errors, source, settings_path, limits_path, "outputLines", &limits.output_lines)) return null;
    switch (try parseOptionalToolScopes(allocator, value.object.get("toolScopes"), errors, source, settings_path, limits_path)) {
        .absent => {},
        .invalid => return null,
        .value => |scopes| limits.tool_scopes = scopes,
    }
    return limits;
}

/// Generic tri-state for optional config fields: absent, invalid, or a parsed value.
pub fn OptionalField(comptime T: type) type {
    return union(enum) {
        absent,
        invalid,
        value: T,
    };
}

const OptionalResourceLimitInteger = OptionalField(u64);

fn parseAndAssignResourceLimitInteger(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    limits_path: []const u8,
    field_name: []const u8,
    target: *?u64,
) !bool {
    switch (try parseOptionalResourceLimitInteger(allocator, value, errors, source, settings_path, limits_path, field_name)) {
        .absent => return true,
        .invalid => return false,
        .value => |field| {
            target.* = field;
            return true;
        },
    }
}

fn parseOptionalResourceLimitInteger(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    limits_path: []const u8,
    field_name: []const u8,
) !OptionalResourceLimitInteger {
    const field = value orelse return .absent;
    if (field != .integer or field.integer < 0 or @as(u64, @intCast(field.integer)) > MAX_SAFE_INTEGER) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: expected non-negative integer", .{ limits_path, field_name });
        return .invalid;
    }
    return .{ .value = @intCast(field.integer) };
}

const OptionalToolScopes = OptionalField([]const []const u8);

fn parseOptionalToolScopes(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    limits_path: []const u8,
) !OptionalToolScopes {
    const scopes_value = value orelse return .absent;
    if (scopes_value != .array) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.toolScopes: expected array", .{limits_path});
        return .invalid;
    }
    var scopes = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringArrayList(allocator, &scopes);
    for (scopes_value.array.items, 0..) |scope_value, index| {
        if (scope_value != .string) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.toolScopes[{d}]: expected string", .{ limits_path, index });
            deinitOwnedStringArrayList(allocator, &scopes);
            return .invalid;
        }
        if (scope_value.string.len == 0) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.toolScopes[{d}]: must not be empty", .{ limits_path, index });
            deinitOwnedStringArrayList(allocator, &scopes);
            return .invalid;
        }
        try appendOwnedString(allocator, &scopes, scope_value.string);
    }
    return .{ .value = try scopes.toOwnedSlice(allocator) };
}

fn mergeExtensionPolicyMaps(
    allocator: std.mem.Allocator,
    base: ?ExtensionPolicyMap,
    overrides: ?ExtensionPolicyMap,
) !?ExtensionPolicyMap {
    if (base == null and overrides == null) return null;

    var merged = (try cloneExtensionPolicyMap(allocator, base)) orelse ExtensionPolicyMap.init(allocator);
    errdefer deinitExtensionPolicyMapRequired(allocator, &merged);
    if (overrides == null) return merged;

    var override_map = overrides.?;
    var iterator = override_map.iterator();
    while (iterator.next()) |entry| {
        var policy = try mergeExtensionPolicy(allocator, merged.get(entry.key_ptr.*), entry.value_ptr.*);
        errdefer policy.deinit(allocator);
        const owned_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_key);
        if (try merged.fetchPut(owned_key, policy)) |previous| {
            allocator.free(owned_key);
            var previous_policy = previous.value;
            previous_policy.deinit(allocator);
        }
    }
    return merged;
}

fn mergeExtensionPolicy(
    allocator: std.mem.Allocator,
    base: ?ExtensionPolicy,
    override: ExtensionPolicy,
) !ExtensionPolicy {
    var merged = if (base) |policy| try policy.clone(allocator) else ExtensionPolicy{};
    errdefer merged.deinit(allocator);
    if (override.approved_grants != null) {
        const replacement = try cloneStringList(allocator, override.approved_grants);
        freeStringList(allocator, merged.approved_grants);
        merged.approved_grants = replacement;
    }
    if (override.resource_limits) |override_limits| {
        if (merged.resource_limits == null) merged.resource_limits = .{};
        if (override_limits.max_children) |field| merged.resource_limits.?.max_children = field;
        if (override_limits.depth) |field| merged.resource_limits.?.depth = field;
        if (override_limits.turns) |field| merged.resource_limits.?.turns = field;
        if (override_limits.timeout_ms) |field| merged.resource_limits.?.timeout_ms = field;
        if (override_limits.output_bytes) |field| merged.resource_limits.?.output_bytes = field;
        if (override_limits.output_lines) |field| merged.resource_limits.?.output_lines = field;
        if (override_limits.tool_scopes != null) {
            const replacement = try cloneStringList(allocator, override_limits.tool_scopes);
            freeStringList(allocator, merged.resource_limits.?.tool_scopes);
            merged.resource_limits.?.tool_scopes = replacement;
        }
    }
    if (override.approved != null) merged.approved = override.approved;
    if (override.enabled != null) merged.enabled = override.enabled;
    if (override.required != null) merged.required = override.required;
    return merged;
}

fn cloneExtensionPolicyMap(allocator: std.mem.Allocator, value: ?ExtensionPolicyMap) !?ExtensionPolicyMap {
    var source = value orelse return null;
    var cloned = ExtensionPolicyMap.init(allocator);
    errdefer deinitExtensionPolicyMapRequired(allocator, &cloned);
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        var policy = try entry.value_ptr.*.clone(allocator);
        errdefer policy.deinit(allocator);
        try cloned.put(key, policy);
    }
    return cloned;
}

fn deinitExtensionPolicyMap(allocator: std.mem.Allocator, value: ?ExtensionPolicyMap) void {
    var map = value orelse return;
    deinitExtensionPolicyMapRequired(allocator, &map);
}

fn deinitExtensionPolicyMapRequired(allocator: std.mem.Allocator, map: *ExtensionPolicyMap) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn extensionPolicyEntryPath(allocator: std.mem.Allocator, identity: []const u8) ![]u8 {
    const quoted = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = identity }, .{});
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator, "$.extensionPolicies[{s}]", .{quoted});
}

fn appendPolicyMessageFmt(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try appendPolicyMessage(allocator, errors, source, path, message);
}

fn appendPolicyMessage(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    path: []const u8,
    message: []const u8,
) !void {
    try config_errors.appendMessage(allocator, errors, source, path, message);
}

fn isPolicyField(value: []const u8) bool {
    return std.mem.eql(u8, value, "approvedGrants") or
        std.mem.eql(u8, value, "resourceLimits") or
        std.mem.eql(u8, value, "approved") or
        std.mem.eql(u8, value, "enabled") or
        std.mem.eql(u8, value, "required");
}

fn isResourceLimitField(value: []const u8) bool {
    return std.mem.eql(u8, value, "maxChildren") or
        std.mem.eql(u8, value, "depth") or
        std.mem.eql(u8, value, "turns") or
        std.mem.eql(u8, value, "timeoutMs") or
        std.mem.eql(u8, value, "outputBytes") or
        std.mem.eql(u8, value, "outputLines") or
        std.mem.eql(u8, value, "toolScopes");
}

fn isCanonicalExtensionGrant(value: []const u8) bool {
    for (capability.CANONICAL_CAPABILITIES) |canonical_capability| {
        if (std.mem.eql(u8, canonical_capability.jsonName(), value)) return true;
    }
    return false;
}

fn loadAuthTokens(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    path: []const u8,
    auth_tokens: *std.StringHashMap([]const u8),
) !void {
    const stored = try auth.readStoredCredentialsObject(allocator, io, path);
    defer provider_json.freeValue(allocator, stored);
    if (stored != .object) return;

    var iterator = stored.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const object = entry.value_ptr.object;
        if (auth.buildApiKeyFromStoredEntryRefreshing(allocator, io, env_map, path, entry.key_ptr.*, object) catch null) |api_key| {
            defer allocator.free(api_key);
            try putOwnedString(auth_tokens, allocator, entry.key_ptr.*, api_key);
        }
    }
}

fn loadLegacySettingsApiKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    auth_tokens: *std.StringHashMap([]const u8),
    errors: *std.ArrayList(ConfigError),
) !void {
    const content = try readOptionalFile(allocator, io, path);
    defer if (content) |value| allocator.free(value);
    if (content == null) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content.?, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, .legacy_settings, path, err);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const api_keys = parsed.value.object.get("apiKeys") orelse return;
    if (api_keys != .object) return;

    var iterator = api_keys.object.iterator();
    while (iterator.next()) |entry| {
        if (auth_tokens.contains(entry.key_ptr.*)) continue;
        if (entry.value_ptr.* != .string) continue;
        try putOwnedString(auth_tokens, allocator, entry.key_ptr.*, entry.value_ptr.string);
    }
}

/// Strip `//` line comments, `/* */` block comments, and trailing commas
/// before `}` or `]` from a JSON document so user-supplied `models.json`
/// files can be annotated. String literals are preserved verbatim; only
/// comments and trailing commas outside of strings are touched.
///
/// Mirrors the TS `stripJsonComments` helper added in
/// `packages/coding-agent/src/core/model-registry.ts` (commit bb25a394).
/// Caller owns the returned slice.
fn stripJsonComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Pass 1: copy `input` to `no_comments`, dropping `//` line and `/* */`
    // block comments. String literals are copied through unchanged.
    var no_comments = std.ArrayList(u8).empty;
    errdefer no_comments.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"') {
            // Copy a string literal verbatim, respecting `\"` escapes.
            try no_comments.append(allocator, c);
            i += 1;
            while (i < input.len) {
                const sc = input[i];
                try no_comments.append(allocator, sc);
                i += 1;
                if (sc == '\\') {
                    if (i < input.len) {
                        try no_comments.append(allocator, input[i]);
                        i += 1;
                    }
                    continue;
                }
                if (sc == '"') break;
            }
            continue;
        }
        if (c == '/' and i + 1 < input.len) {
            const next = input[i + 1];
            if (next == '/') {
                // Line comment: drop preceding horizontal whitespace on the
                // same line, then skip until newline (newline itself preserved).
                while (no_comments.items.len > 0) {
                    const previous = no_comments.items[no_comments.items.len - 1];
                    if (previous != ' ' and previous != '\t') break;
                    no_comments.items.len -= 1;
                }
                i += 2;
                while (i < input.len and input[i] != '\n') : (i += 1) {}
                continue;
            }
            if (next == '*') {
                // Block comment: skip until matching `*/`.
                i += 2;
                while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) : (i += 1) {}
                if (i + 1 < input.len) i += 2 else i = input.len;
                continue;
            }
        }
        try no_comments.append(allocator, c);
        i += 1;
    }

    // Pass 2: strip trailing commas before `}` or `]`. Strings are skipped.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const cleaned = no_comments.items;
    var j: usize = 0;
    while (j < cleaned.len) {
        const c = cleaned[j];
        if (c == '"') {
            try out.append(allocator, c);
            j += 1;
            while (j < cleaned.len) {
                const sc = cleaned[j];
                try out.append(allocator, sc);
                j += 1;
                if (sc == '\\') {
                    if (j < cleaned.len) {
                        try out.append(allocator, cleaned[j]);
                        j += 1;
                    }
                    continue;
                }
                if (sc == '"') break;
            }
            continue;
        }
        if (c == ',') {
            // Look ahead past whitespace for `}` or `]`.
            var k: usize = j + 1;
            while (k < cleaned.len) : (k += 1) {
                switch (cleaned[k]) {
                    ' ', '\t', '\r', '\n' => continue,
                    else => break,
                }
            }
            if (k < cleaned.len and (cleaned[k] == '}' or cleaned[k] == ']')) {
                // Drop the comma; keep the trailing whitespace + closer
                // intact by simply advancing past the comma.
                j += 1;
                continue;
            }
        }
        try out.append(allocator, c);
        j += 1;
    }

    no_comments.deinit(allocator);
    return out.toOwnedSlice(allocator);
}

fn loadModelsConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    provider_api_keys: *std.StringHashMap([]const u8),
    discover_models: bool,
    errors: *std.ArrayList(ConfigError),
) !void {
    const registry = ai.model_registry.getDefault();
    const content = try readOptionalFile(allocator, io, path);
    defer if (content) |value| allocator.free(value);
    if (content == null) return;

    const stripped = stripJsonComments(allocator, content.?) catch |err| {
        try config_errors.appendError(allocator, errors, .models, path, err);
        return;
    };
    defer allocator.free(stripped);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripped, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, .models, path, err);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try config_errors.appendMessage(allocator, errors, .models, path, "expected JSON object");
        return;
    }

    const providers_value = parsed.value.object.get("providers") orelse return;
    if (providers_value != .object) return;

    var provider_iterator = providers_value.object.iterator();
    while (provider_iterator.next()) |provider_entry| {
        if (provider_entry.value_ptr.* != .object) continue;
        const provider_name = provider_entry.key_ptr.*;
        const provider_object = provider_entry.value_ptr.object;
        const existing_provider = registry.getProviderConfig(provider_name);

        const provider_api_key: ?[]const u8 = if (provider_object.get("apiKey")) |api_key_value|
            if (api_key_value == .string) api_key_value.string else null
        else
            null;
        if (provider_api_key) |api_key| {
            try putOwnedString(provider_api_keys, allocator, provider_name, api_key);
        }

        const provider_base_url = if (provider_object.get("baseUrl")) |base_url_value|
            if (base_url_value == .string) base_url_value.string else if (existing_provider) |descriptor| descriptor.base_url else null
        else if (existing_provider) |descriptor|
            descriptor.base_url
        else
            null;

        const provider_api = if (provider_object.get("api")) |api_value|
            if (api_value == .string) api_value.string else if (existing_provider) |descriptor| descriptor.api else null
        else if (existing_provider) |descriptor|
            descriptor.api
        else if (provider_base_url) |base_url|
            if (isLocalBaseUrl(base_url)) @as([]const u8, "openai-completions") else null
        else
            null;

        const models_value = provider_object.get("models");
        var first_model_id: ?[]const u8 = null;
        if (models_value) |value| {
            if (value == .array) {
                for (value.array.items) |model_value| {
                    if (model_value != .object) continue;
                    if (first_model_id == null) {
                        if (model_value.object.get("id")) |id_value| {
                            if (id_value == .string) first_model_id = id_value.string;
                        }
                    }
                }
            }
        }

        if (provider_api != null and provider_base_url != null) {
            ai.model_registry.registerProvider(.{
                .provider = provider_name,
                .api = provider_api.?,
                .base_url = provider_base_url.?,
                .default_model_id = first_model_id orelse if (existing_provider) |descriptor| descriptor.default_model_id else null,
            }) catch |err| try config_errors.appendError(allocator, errors, .register_provider, path, err);
        }

        const resolved_provider = ai.model_registry.getProviderConfig(provider_name);
        const discovery_config = parseModelDiscoveryConfig(provider_object.get("discoverModels") orelse provider_object.get("modelDiscovery"));
        if (shouldDiscoverProviderModels(discover_models, provider_base_url, models_value, discovery_config)) {
            if (resolved_provider) |provider| {
                _ = ai.model_discovery.discoverAndRegister(allocator, io, registry, provider, .{
                    .kind = discovery_config.kind,
                    .models_url = discovery_config.models_url,
                    .loaded_models_url = discovery_config.loaded_models_url,
                    .api_key = provider_api_key,
                }) catch |err| try config_errors.appendError(allocator, errors, .discovery, path, err);

                if (provider.default_model_id == null) {
                    if (registry.firstModelIdForProvider(provider_name)) |default_model_id| {
                        ai.model_registry.setProviderDefaultModel(provider_name, default_model_id) catch |err| try config_errors.appendError(allocator, errors, .set_default_model, path, err);
                    }
                }
            }
        }

        if (models_value) |value| {
            if (value == .array) {
                for (value.array.items) |model_value| {
                    if (model_value != .object) continue;
                    const model_object = model_value.object;
                    const id_value = model_object.get("id") orelse continue;
                    if (id_value != .string) continue;
                    const model_id = id_value.string;
                    const existing_model = registry.find(provider_name, model_id);
                    const api_name = if (model_object.get("api")) |api_value|
                        if (api_value == .string) api_value.string else if (existing_model) |model| model.api else if (resolved_provider) |descriptor| descriptor.api else continue
                    else if (existing_model) |model|
                        model.api
                    else if (resolved_provider) |descriptor| descriptor.api else continue;
                    const base_url = if (model_object.get("baseUrl")) |base_url_value|
                        if (base_url_value == .string) base_url_value.string else if (existing_model) |model| model.base_url else if (resolved_provider) |descriptor| descriptor.base_url else continue
                    else if (existing_model) |model|
                        model.base_url
                    else if (resolved_provider) |descriptor| descriptor.base_url else continue;

                    var headers = try parseHeaders(allocator, model_object.get("headers"));
                    const compat = if (model_object.get("compat")) |compat_value| try provider_json.cloneValue(allocator, compat_value) else null;

                    const input_types = try parseInputTypes(allocator, model_object.get("input"), existing_model);
                    defer allocator.free(input_types);

                    const register_result = ai.model_registry.registerModel(.{
                        .id = model_id,
                        .name = if (model_object.get("name")) |name_value|
                            if (name_value == .string) name_value.string else model_id
                        else if (existing_model) |model|
                            model.name
                        else
                            model_id,
                        .api = api_name,
                        .provider = provider_name,
                        .base_url = base_url,
                        .reasoning = if (model_object.get("reasoning")) |reasoning_value|
                            if (reasoning_value == .bool) reasoning_value.bool else existing_model != null and existing_model.?.reasoning
                        else if (existing_model) |model|
                            model.reasoning
                        else
                            false,
                        .thinking_level_map = parseThinkingLevelMap(model_object.get("thinkingLevelMap"), existing_model),
                        .tool_calling = parseBoolField(model_object.get("toolCalling") orelse model_object.get("tool_calling"), if (existing_model) |model| model.tool_calling else true),
                        .loaded = parseBoolField(model_object.get("loaded"), if (existing_model) |model| model.loaded else false),
                        .input_types = input_types,
                        .cost = parseCost(model_object.get("cost"), existing_model),
                        .context_window = parseU32Field(model_object.get("contextWindow"), if (existing_model) |model| model.context_window else DEFAULT_CONTEXT_WINDOW),
                        .max_tokens = blk: {
                            const default_max: u32 = if (existing_model) |model| model.max_tokens else DEFAULT_MAX_TOKENS;
                            break :blk parseU32Field(model_object.get("maxTokens"), default_max);
                        },
                        .headers = headers,
                        .compat = compat,
                    });

                    if (headers) |*map| deinitStringMap(allocator, map);
                    if (compat) |value_compat| provider_json.freeValue(allocator, value_compat);

                    register_result catch |err| try config_errors.appendError(allocator, errors, .register_model, path, err);
                }
            }
        }
    }
}

const ParsedModelDiscoveryConfig = struct {
    explicit: bool = false,
    enabled: bool = true,
    kind: ai.model_discovery.DiscoveryKind = .auto,
    models_url: ?[]const u8 = null,
    loaded_models_url: ?[]const u8 = null,
};

fn parseModelDiscoveryConfig(value: ?std.json.Value) ParsedModelDiscoveryConfig {
    const discovery_value = value orelse return .{};
    switch (discovery_value) {
        .bool => |enabled| return .{ .explicit = true, .enabled = enabled },
        .string => |kind| return .{ .explicit = true, .kind = parseDiscoveryKind(kind) },
        .object => |object| {
            return .{
                .explicit = true,
                .enabled = parseBoolField(object.get("enabled"), true),
                .kind = parseDiscoveryKind(getStringField(object, "kind") orelse getStringField(object, "type") orelse "auto"),
                .models_url = getStringField(object, "modelsUrl") orelse getStringField(object, "models_url") orelse getStringField(object, "url"),
                .loaded_models_url = getStringField(object, "loadedModelsUrl") orelse getStringField(object, "loaded_models_url") orelse getStringField(object, "loadedUrl") orelse getStringField(object, "loaded_url"),
            };
        },
        else => return .{ .explicit = true, .enabled = false },
    }
}

fn shouldDiscoverProviderModels(
    startup_network_enabled: bool,
    provider_base_url: ?[]const u8,
    models_value: ?std.json.Value,
    config: ParsedModelDiscoveryConfig,
) bool {
    if (!startup_network_enabled) return false;
    const base_url = provider_base_url orelse return false;
    if (config.explicit) return config.enabled;
    if (modelsValueHasEntries(models_value)) return false;
    return isLocalBaseUrl(base_url);
}

fn modelsValueHasEntries(value: ?std.json.Value) bool {
    const models_value = value orelse return false;
    return models_value == .array and models_value.array.items.len > 0;
}

fn parseDiscoveryKind(value: []const u8) ai.model_discovery.DiscoveryKind {
    if (std.ascii.eqlIgnoreCase(value, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(value, "openai-compatible")) return .openai;
    if (std.ascii.eqlIgnoreCase(value, "ollama")) return .ollama;
    if (std.ascii.eqlIgnoreCase(value, "pi")) return .pi;
    return .auto;
}

fn isLocalBaseUrl(value: []const u8) bool {
    return string_utils.containsIgnoreCase(value, "localhost") or
        string_utils.containsIgnoreCase(value, "127.0.0.1") or
        string_utils.containsIgnoreCase(value, "0.0.0.0") or
        string_utils.containsIgnoreCase(value, "[::1]");
}

fn getStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn parseBoolField(value: ?std.json.Value, default_value: bool) bool {
    const field = value orelse return default_value;
    return switch (field) {
        .bool => |boolean| boolean,
        .integer => |integer| integer != 0,
        .string => |text| parseBoolText(text) orelse default_value,
        else => default_value,
    };
}

fn parseBoolText(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on") or
        std.mem.eql(u8, text, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "off") or
        std.mem.eql(u8, text, "0"))
    {
        return false;
    }
    return null;
}

fn parseInputTypes(allocator: std.mem.Allocator, value: ?std.json.Value, existing_model: ?ai.Model) ![]const []const u8 {
    if (value) |input_value| {
        if (input_value == .array) {
            var items = std.ArrayList([]const u8).empty;
            defer items.deinit(allocator);
            for (input_value.array.items) |item| {
                if (item != .string) continue;
                try items.append(allocator, item.string);
            }
            if (items.items.len > 0) return items.toOwnedSlice(allocator);
        }
    }

    if (existing_model) |model| {
        return allocator.dupe([]const u8, model.input_types);
    }

    return allocator.dupe([]const u8, &.{"text"});
}

fn parseThinkingLevelMap(value: ?std.json.Value, existing_model: ?ai.Model) ?ai.types.ModelThinkingLevelMap {
    const map_value = value orelse return if (existing_model) |model| model.thinking_level_map else null;
    if (map_value != .object) return if (existing_model) |model| model.thinking_level_map else null;

    var map = if (existing_model) |model| model.thinking_level_map orelse ai.types.ModelThinkingLevelMap{} else ai.types.ModelThinkingLevelMap{};
    if (parseThinkingLevelMapping(map_value.object.get("off"))) |mapping| map.off = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("minimal"))) |mapping| map.minimal = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("low"))) |mapping| map.low = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("medium"))) |mapping| map.medium = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("high"))) |mapping| map.high = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("xhigh"))) |mapping| map.xhigh = mapping;
    return map;
}

fn parseThinkingLevelMapping(value: ?std.json.Value) ?ai.types.ThinkingLevelMapping {
    const mapping = value orelse return null;
    return switch (mapping) {
        .null => .unsupported,
        .string => |text| .{ .mapped = text },
        else => null,
    };
}

fn parseHeaders(allocator: std.mem.Allocator, value: ?std.json.Value) !?std.StringHashMap([]const u8) {
    const headers_value = value orelse return null;
    if (headers_value != .object) return null;

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitStringMap(allocator, &headers);

    var iterator = headers_value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try putOwnedString(&headers, allocator, entry.key_ptr.*, entry.value_ptr.string);
    }
    return headers;
}

fn parseCost(value: ?std.json.Value, existing_model: ?ai.Model) ai.ModelCost {
    var cost = if (existing_model) |model| model.cost else ai.ModelCost{};
    const cost_value = value orelse return cost;
    if (cost_value != .object) return cost;

    if (cost_value.object.get("input")) |field| cost.input = parseF64Field(field, cost.input);
    if (cost_value.object.get("output")) |field| cost.output = parseF64Field(field, cost.output);
    if (cost_value.object.get("cacheRead")) |field| cost.cache_read = parseF64Field(field, cost.cache_read);
    if (cost_value.object.get("cacheWrite")) |field| cost.cache_write = parseF64Field(field, cost.cache_write);
    return cost;
}

fn parseCompactionSettings(value: std.json.Value) ?session_mod.CompactionSettings {
    if (value != .object) return null;
    return .{
        .enabled = if (value.object.get("enabled")) |field| if (field == .bool) field.bool else false else false,
        .reserve_tokens = blk: {
            const default_reserve: u32 = DEFAULT_RESERVE_TOKENS;
            break :blk parseU32Field(value.object.get("reserveTokens"), default_reserve);
        },
        .keep_recent_tokens = blk: {
            const default_keep: u32 = DEFAULT_KEEP_RECENT_TOKENS;
            break :blk parseU32Field(value.object.get("keepRecentTokens"), default_keep);
        },
    };
}

fn parseRetrySettings(value: std.json.Value) ?session_mod.RetrySettings {
    if (value != .object) return null;
    return .{
        .enabled = if (value.object.get("enabled")) |field| if (field == .bool) field.bool else false else false,
        .max_retries = parseU32Field(value.object.get("maxRetries"), DEFAULT_MAX_RETRIES),
        .base_delay_ms = parseU64Field(value.object.get("baseDelayMs"), DEFAULT_BASE_DELAY_MS),
    };
}

fn parseThinkingLevel(value: []const u8) ?agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn parseTransport(value: []const u8) ?ai.types.Transport {
    if (std.mem.eql(u8, value, "sse")) return .sse;
    if (std.mem.eql(u8, value, "websocket")) return .websocket;
    if (std.mem.eql(u8, value, "websocket-cached")) return .websocket_cached;
    if (std.mem.eql(u8, value, "auto")) return .auto;
    return null;
}

fn parseQueueModeSetting(value: []const u8) ?QueueModeSetting {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "one-at-a-time")) return .one_at_a_time;
    return null;
}

fn parseDoubleEscapeAction(value: []const u8) ?DoubleEscapeAction {
    if (std.mem.eql(u8, value, "fork")) return .fork;
    if (std.mem.eql(u8, value, "tree")) return .tree;
    if (std.mem.eql(u8, value, "none")) return .none;
    return null;
}

fn parseTreeFilterMode(value: []const u8) ?TreeFilterMode {
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "no-tools")) return .no_tools;
    if (std.mem.eql(u8, value, "user-only")) return .user_only;
    if (std.mem.eql(u8, value, "labeled-only")) return .labeled_only;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

fn parseNonNegativeUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn parsePositiveUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |number| if (number > 0) @intCast(number) else null,
        else => null,
    };
}

fn parseU32Field(value: ?std.json.Value, default_value: u32) u32 {
    if (value) |field| {
        if (field == .integer and field.integer >= 0) return @intCast(field.integer);
    }
    return default_value;
}

fn parseU64Field(value: ?std.json.Value, default_value: u64) u64 {
    if (value) |field| {
        if (field == .integer and field.integer >= 0) return @intCast(field.integer);
    }
    return default_value;
}

fn parseF64Field(value: std.json.Value, default_value: f64) f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => default_value,
    };
}

fn parseStringList(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const list_value = value orelse return null;
    if (list_value != .array) return null;

    var items = std.ArrayList([]const u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    for (list_value.array.items) |item| {
        if (item != .string) continue;
        try appendOwnedString(allocator, &items, item.string);
    }

    return try items.toOwnedSlice(allocator);
}

fn appendOwnedString(allocator: std.mem.Allocator, items: *std.ArrayList([]const u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try items.append(allocator, owned);
}

fn parsePackageSources(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const resources_mod.PackageSourceConfig {
    const packages_value = value orelse return null;
    if (packages_value != .array) return null;

    var items = std.ArrayList(resources_mod.PackageSourceConfig).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for (packages_value.array.items) |item| {
        switch (item) {
            .string => |source| try items.append(allocator, .{
                .source = try allocator.dupe(u8, source),
            }),
            .object => |object| {
                const source_value = object.get("source") orelse continue;
                if (source_value != .string) continue;
                try items.append(allocator, .{
                    .source = try allocator.dupe(u8, source_value.string),
                    .extensions = try parseStringList(allocator, object.get("extensions")),
                    .skills = try parseStringList(allocator, object.get("skills")),
                    .prompts = try parseStringList(allocator, object.get("prompts")),
                    .themes = try parseStringList(allocator, object.get("themes")),
                });
            },
            else => {},
        }
    }

    return try items.toOwnedSlice(allocator);
}

fn clonePackageSources(
    allocator: std.mem.Allocator,
    value: ?[]const resources_mod.PackageSourceConfig,
) !?[]const resources_mod.PackageSourceConfig {
    const packages = value orelse return null;
    var items = std.ArrayList(resources_mod.PackageSourceConfig).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    for (packages) |package_source| {
        try items.append(allocator, try package_source.clone(allocator));
    }
    return try items.toOwnedSlice(allocator);
}

fn freePackageSources(allocator: std.mem.Allocator, value: ?[]const resources_mod.PackageSourceConfig) void {
    const packages = value orelse return;
    for (packages) |item_const| {
        var item = item_const;
        item.deinit(allocator);
    }
    allocator.free(packages);
}

fn cloneStringList(allocator: std.mem.Allocator, value: ?[]const []const u8) !?[]const []const u8 {
    const items = value orelse return null;
    var cloned = std.ArrayList([]const u8).empty;
    errdefer {
        for (cloned.items) |item| allocator.free(item);
        cloned.deinit(allocator);
    }
    for (items) |item| {
        const cloned_item = try allocator.dupe(u8, item);
        cloned.append(allocator, cloned_item) catch |err| {
            allocator.free(cloned_item);
            return err;
        };
    }
    return try cloned.toOwnedSlice(allocator);
}

const freeStringList = @import("../slice_utils.zig").freeOptionalStringSlice;

pub fn resolveAgentDir(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("PI_CODING_AGENT_DIR")) |value| {
        return expandLeadingHome(allocator, env_map, value);
    }

    const base_dir = if (env_map.get("PI_CONFIG_DIR")) |value|
        try expandLeadingHome(allocator, env_map, value)
    else if (env_map.get("HOME")) |home|
        try std.fs.path.join(allocator, &[_][]const u8{ home, ".pi" })
    else if (env_map.get("USERPROFILE")) |userprofile|
        try std.fs.path.join(allocator, &[_][]const u8{ userprofile, ".pi" })
    else
        try allocator.dupe(u8, ".pi");
    defer allocator.free(base_dir);

    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, "agent" });
}

pub fn expandPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, value: []const u8, cwd: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    if (std.mem.startsWith(u8, value, "~/") or std.mem.eql(u8, value, "~")) {
        return expandLeadingHome(allocator, env_map, value);
    }
    return std.fs.path.join(allocator, &[_][]const u8{ cwd, value });
}

fn expandLeadingHome(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, value: []const u8) ![]u8 {
    const home = env_map.get("HOME") orelse env_map.get("USERPROFILE") orelse return allocator.dupe(u8, value);
    if (std.mem.eql(u8, value, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, value, "~/")) return std.fs.path.join(allocator, &[_][]const u8{ home, value[2..] });
    return allocator.dupe(u8, value);
}

fn readOptionalFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn isNonEmptyCredentialValue(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0;
}

fn putOwnedString(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (try map.fetchPut(owned_key, owned_value)) |previous| {
        allocator.free(previous.key);
        allocator.free(previous.value);
    }
}

fn deinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

pub const testing = struct {
    pub const TestingOptionalToolScopes = OptionalToolScopes;

    pub fn callStripJsonComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        return stripJsonComments(allocator, input);
    }

    pub fn callMergeExtensionPolicy(
        allocator: std.mem.Allocator,
        base: ?ExtensionPolicy,
        policy_override: ExtensionPolicy,
    ) !ExtensionPolicy {
        return mergeExtensionPolicy(allocator, base, policy_override);
    }

    pub fn callMergeExtensionPolicyMaps(
        allocator: std.mem.Allocator,
        base: ?ExtensionPolicyMap,
        overrides: ?ExtensionPolicyMap,
    ) !?ExtensionPolicyMap {
        return mergeExtensionPolicyMaps(allocator, base, overrides);
    }

    pub fn callCloneStringList(allocator: std.mem.Allocator, value: ?[]const []const u8) !?[]const []const u8 {
        return cloneStringList(allocator, value);
    }

    pub fn callDeinitExtensionPolicyMapRequired(allocator: std.mem.Allocator, map: *ExtensionPolicyMap) void {
        return deinitExtensionPolicyMapRequired(allocator, map);
    }

    pub fn callCloneExtensionPolicyMap(allocator: std.mem.Allocator, value: ?ExtensionPolicyMap) !?ExtensionPolicyMap {
        return cloneExtensionPolicyMap(allocator, value);
    }

    pub fn callParseApprovedGrants(
        allocator: std.mem.Allocator,
        value: std.json.Value,
        errors: *std.ArrayList(ConfigError),
        source: ConfigErrorSource,
        settings_path: []const u8,
        policy_path: []const u8,
    ) !?[]const []const u8 {
        return parseApprovedGrants(allocator, value, errors, source, settings_path, policy_path);
    }

    pub fn callParseOptionalToolScopes(
        allocator: std.mem.Allocator,
        value: ?std.json.Value,
        errors: *std.ArrayList(ConfigError),
        source: ConfigErrorSource,
        settings_path: []const u8,
        limits_path: []const u8,
    ) !TestingOptionalToolScopes {
        return parseOptionalToolScopes(allocator, value, errors, source, settings_path, limits_path);
    }

    pub fn callParseStringList(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
        return parseStringList(allocator, value);
    }

    pub fn callFreeStringList(allocator: std.mem.Allocator, value: ?[]const []const u8) void {
        return freeStringList(allocator, value);
    }

    pub fn callParseSettingsContent(
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
        errors: *std.ArrayList(ConfigError),
        source: ConfigErrorSource,
    ) !Settings {
        return parseSettingsContent(allocator, path, content, errors, source);
    }

    pub fn callLoadLegacySettingsApiKeys(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        auth_tokens: *std.StringHashMap([]const u8),
        errors: *std.ArrayList(ConfigError),
    ) !void {
        return loadLegacySettingsApiKeys(allocator, io, path, auth_tokens, errors);
    }

    pub fn callLoadModelsConfig(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        provider_api_keys: *std.StringHashMap([]const u8),
        discover_models: bool,
        errors: *std.ArrayList(ConfigError),
    ) !void {
        return loadModelsConfig(allocator, io, path, provider_api_keys, discover_models, errors);
    }

    pub fn callDeinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
        return deinitStringMap(allocator, map);
    }
};

test {
    _ = @import("config/tests.zig");
}
