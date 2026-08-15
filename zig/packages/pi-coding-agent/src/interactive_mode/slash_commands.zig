const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const auth = @import("../auth/auth.zig");
const config_mod = @import("../config/config.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const session_advanced = @import("../sessions/session_advanced.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const common = @import("../tools/common.zig");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const currentSessionLabel = shared.currentSessionLabel;
const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
const configuredCompactionSettings = shared.configuredCompactionSettings;
const configuredRetrySettings = shared.configuredRetrySettings;
const normalizePathArgument = shared.normalizePathArgument;
const overrideApiKeyForProvider = shared.overrideApiKeyForProvider;
const blocksToText = formatting.blocksToText;
const formatAssistantMessage = formatting.formatAssistantMessage;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadAuthOverlay = overlays.loadAuthOverlay;
const loadSelectableModels = overlays.loadSelectableModels;
const loadSettingsOverlay = overlays.loadSettingsOverlay;
const loadSettingsEditorOverlay = overlays.loadSettingsEditorOverlay;
const loadSessionOverlay = overlays.loadSessionOverlay;
const loadModelOverlay = overlays.loadModelOverlay;
const loadModelOverlayWithSearch = overlays.loadModelOverlayWithSearch;
const loadThemeOverlay = overlays.loadThemeOverlay;
const loadScopedModelOverlay = overlays.loadScopedModelOverlay;
const loadTreeOverlay = overlays.loadTreeOverlay;
const loadForkOverlay = overlays.loadForkOverlay;
const AppState = rendering.AppState;
const rebuildAppStateFromSession = rendering.rebuildAppStateFromSession;
const updateAppFooterFromSession = rendering.updateAppFooterFromSession;
const session_lifecycle = @import("session_lifecycle.zig");
const createSeededSession = session_lifecycle.createSeededSession;
const switchSession = session_lifecycle.switchSession;
const formatSessionInfo = session_lifecycle.formatSessionInfo;
const loadForkOverlayOrStatus = session_lifecycle.loadForkOverlayOrStatus;
const forkCurrentSessionBeforeUserMessage = session_lifecycle.forkCurrentSessionBeforeUserMessage;
const resolveSessionPath = session_lifecycle.resolveSessionPath;

pub const HelpSlashCommand = struct {
    name: []const u8,
    description: []const u8,
    argument_hint: ?[]const u8 = null,
};

pub fn handleHelpSlashCommand(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    builtin_commands: []const HelpSlashCommand,
    prompt_templates: []const resources_mod.PromptTemplate,
    skills: []const resources_mod.Skill,
    enable_skill_commands: bool,
    keybindings: ?*const keybindings_mod.Keybindings,
) !void {
    const markdown = try buildHelpMarkdown(
        allocator,
        builtin_commands,
        prompt_templates,
        skills,
        enable_skill_commands,
        keybindings,
    );
    defer allocator.free(markdown);
    try app_state.appendMarkdown(markdown);
}

fn buildHelpMarkdown(
    allocator: std.mem.Allocator,
    builtin_commands: []const HelpSlashCommand,
    prompt_templates: []const resources_mod.PromptTemplate,
    skills: []const resources_mod.Skill,
    enable_skill_commands: bool,
    keybindings: ?*const keybindings_mod.Keybindings,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    try builder.appendSlice(allocator,
        \\# Help
        \\
        \\## Slash commands
        \\
        \\### Built-in
        \\
    );
    for (builtin_commands) |command| {
        try appendHelpCommandBullet(allocator, &builder, command.name, command.argument_hint, command.description, false);
    }

    if (prompt_templates.len > 0) {
        try builder.appendSlice(allocator,
            \\
            \\### Prompts
            \\
        );
        for (prompt_templates) |template| {
            try appendHelpCommandBullet(allocator, &builder, template.name, template.argument_hint, template.description, false);
        }
    }

    if (enable_skill_commands and skills.len > 0) {
        try builder.appendSlice(allocator,
            \\
            \\### Skills
            \\
        );
        for (skills) |skill| {
            try appendHelpCommandBullet(allocator, &builder, skill.name, null, skill.description, true);
        }
    }

    const hotkeys = try buildHotkeysMarkdownWithHeading(allocator, keybindings, "## Keyboard shortcuts");
    defer allocator.free(hotkeys);
    try builder.append(allocator, '\n');
    try builder.appendSlice(allocator, hotkeys);

    return try builder.toOwnedSlice(allocator);
}

fn appendHelpCommandBullet(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    name: []const u8,
    argument_hint: ?[]const u8,
    description: []const u8,
    skill_command: bool,
) !void {
    const prefix = if (skill_command) "/skill:" else "/";
    if (argument_hint) |hint| {
        const line = try std.fmt.allocPrint(allocator, "- `{s}{s} {s}` — {s}\n", .{ prefix, name, hint, description });
        defer allocator.free(line);
        try builder.appendSlice(allocator, line);
    } else {
        const line = try std.fmt.allocPrint(allocator, "- `{s}{s}` — {s}\n", .{ prefix, name, description });
        defer allocator.free(line);
        try builder.appendSlice(allocator, line);
    }
}

pub fn handleHotkeysSlashCommand(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    keybindings: ?*const keybindings_mod.Keybindings,
) !void {
    const markdown = try buildHotkeysMarkdown(allocator, keybindings);
    defer allocator.free(markdown);
    try app_state.appendMarkdown(markdown);
}

fn buildHotkeysMarkdown(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
) ![]u8 {
    return buildHotkeysMarkdownWithHeading(allocator, keybindings, "# Keyboard shortcuts");
}

fn buildHotkeysMarkdownWithHeading(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    heading: []const u8,
) ![]u8 {
    const interrupt = try appKeyLabel(allocator, keybindings, .interrupt);
    defer allocator.free(interrupt);
    const clear = try appKeyLabel(allocator, keybindings, .clear);
    defer allocator.free(clear);
    const exit = try appKeyLabel(allocator, keybindings, .exit);
    defer allocator.free(exit);
    const suspend_label = try appKeyLabel(allocator, keybindings, .app_suspend);
    defer allocator.free(suspend_label);
    const cycle_thinking = try appKeyLabel(allocator, keybindings, .thinking_cycle);
    defer allocator.free(cycle_thinking);
    const cycle_model_forward = try appKeyLabel(allocator, keybindings, .model_cycleForward);
    defer allocator.free(cycle_model_forward);
    const cycle_model_backward = try appKeyLabel(allocator, keybindings, .model_cycleBackward);
    defer allocator.free(cycle_model_backward);
    const select_model = try appKeyLabel(allocator, keybindings, .model_select);
    defer allocator.free(select_model);
    const expand_tools = try appKeyLabel(allocator, keybindings, .tools_expand);
    defer allocator.free(expand_tools);
    const toggle_thinking = try appKeyLabel(allocator, keybindings, .thinking_toggle);
    defer allocator.free(toggle_thinking);
    const external_editor = try appKeyLabel(allocator, keybindings, .editor_external);
    defer allocator.free(external_editor);
    const follow_up = try appKeyLabel(allocator, keybindings, .message_followUp);
    defer allocator.free(follow_up);
    const dequeue = try appKeyLabel(allocator, keybindings, .message_dequeue);
    defer allocator.free(dequeue);
    const paste_image = try appKeyLabel(allocator, keybindings, .clipboard_pasteImage);
    defer allocator.free(paste_image);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.print("{s}\n\n", .{heading});
    try writer.writer.writeAll(
        \\### Navigation
        \\
        \\- `Up` / `Down` / `Left` / `Right` — Move cursor / browse history (Up when editor is empty)
        \\- `Alt+Left` / `Alt+Right` — Move by word
        \\- `Home` — Start of line
        \\- `End` — End of line
        \\- `Ctrl+F` — Jump forward to character
        \\- `Ctrl+B` — Jump backward to character
        \\- `PgUp` / `PgDn` — Scroll by page
        \\
        \\### Editing
        \\
        \\- `Enter` — Send message
        \\- `Shift+Enter` — New line
        \\- `Ctrl+W` — Delete word backwards
        \\- `Alt+D` — Delete word forwards
        \\- `Ctrl+U` — Delete to start of line
        \\- `Ctrl+K` — Delete to end of line
        \\- `Ctrl+Y` — Paste the most-recently-deleted text
        \\- `Alt+Y` — Cycle through the deleted text after pasting
        \\- `Ctrl+_` — Undo
        \\
        \\### Other
        \\
        \\- `Tab` — Path completion / accept autocomplete
    );
    try writer.writer.print(
        \\- `{s}` — Cancel autocomplete / abort streaming
        \\- `{s}` — Clear editor (first) / exit (second)
        \\- `{s}` — Exit (when editor is empty)
        \\- `{s}` — Suspend to background
        \\- `{s}` — Cycle thinking level
        \\- `{s}` / `{s}` — Cycle models
        \\- `{s}` — Open model selector
        \\- `{s}` — Toggle tool output expansion
        \\- `{s}` — Toggle thinking block visibility
        \\- `{s}` — Edit message in external editor
        \\- `{s}` — Queue follow-up message
        \\- `{s}` — Restore queued messages
        \\- `{s}` — Paste image from clipboard
        \\- `/` — Slash commands
        \\- `!` — Run bash command
        \\- `!!` — Run bash command (excluded from context)
        \\
    , .{
        interrupt,
        clear,
        exit,
        suspend_label,
        cycle_thinking,
        cycle_model_forward,
        cycle_model_backward,
        select_model,
        expand_tools,
        toggle_thinking,
        external_editor,
        follow_up,
        dequeue,
        paste_image,
    });

    return try allocator.dupe(u8, writer.written());
}

fn appKeyLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
) ![]u8 {
    if (keybindings) |bindings| return bindings.primaryLabel(allocator, action);
    var defaults = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer defaults.deinit();
    return defaults.primaryLabel(allocator, action);
}

pub fn switchModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    provider_name: []const u8,
    model_id: []const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
) !void {
    var next_provider = provider_config.resolveProviderConfig(
        allocator,
        session.io,
        env_map,
        provider_name,
        model_id,
        overrideApiKeyForProvider(options, provider_name),
        configuredApiKeyForProvider(runtime_config, provider_name),
    ) catch |err| {
        try presentProviderSelectionError(
            allocator,
            app_state,
            provider_config.resolveProviderErrorMessage(err, provider_name),
            "model switch failed",
        );
        return;
    };
    errdefer next_provider.deinit(allocator);

    current_provider.deinit(allocator);
    current_provider.* = next_provider;
    try session.setModel(next_provider.model);
    try persistDefaultModelSelection(allocator, session.io, runtime_config, next_provider.model.provider, next_provider.model.id);
    session.setApiKey(next_provider.api_key);
    try updateAppFooterFromSession(allocator, session.io, app_state, session, current_provider);
    const status = try std.fmt.allocPrint(allocator, "Model: {s}", .{next_provider.model.id});
    defer allocator.free(status);
    try app_state.setStatus(status);
}

fn persistDefaultModelSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: ?*const config_mod.RuntimeConfig,
    provider: []const u8,
    model_id: []const u8,
) !void {
    const config = runtime_config orelse return;
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ config.agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    const existing = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| allocator.free(bytes);

    var parsed = if (existing) |bytes|
        std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
            try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{})
    else
        try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        parsed.deinit();
        parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    }

    try putJsonString(allocator, &parsed.value.object, "defaultProvider", provider);
    try putJsonString(allocator, &parsed.value.object, "defaultModel", model_id);

    const serialized = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

pub fn persistEnabledModelSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: ?*const config_mod.RuntimeConfig,
    patterns: ?[]const []const u8,
) !void {
    const config = runtime_config orelse return;
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ config.agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    const existing = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| allocator.free(bytes);

    var parsed = if (existing) |bytes|
        std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
            try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{})
    else
        try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        parsed.deinit();
        parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    }

    if (patterns) |values| {
        var array = std.json.Array.init(allocator);
        errdefer array.deinit();
        for (values) |pattern| {
            try array.append(.{ .string = pattern });
        }
        if (parsed.value.object.getPtr("enabledModels")) |existing_value| {
            existing_value.* = .{ .array = array };
        } else {
            try parsed.value.object.put(allocator, "enabledModels", .{ .array = array });
        }
    } else {
        if (parsed.value.object.getPtr("enabledModels")) |existing_value| {
            existing_value.* = .null;
        } else {
            try parsed.value.object.put(allocator, "enabledModels", .null);
        }
    }

    const serialized = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

fn putJsonString(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    if (object.getPtr(key)) |existing_value| {
        existing_value.* = .{ .string = value };
        return;
    }

    try object.put(allocator, key, .{ .string = value });
}

fn presentProviderSelectionError(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    detail: []const u8,
    status: []const u8,
) !void {
    _ = status;
    const owned = try allocator.dupe(u8, detail);
    defer allocator.free(owned);
    try app_state.appendError(owned);
}

pub fn handleModelSlashCommand(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
) !void {
    const scoped_patterns = currentScopedModelPatterns(app_state, options, runtime_config);
    const search = argument orelse {
        overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel(), current_provider, scoped_patterns, runtime_config);
        return;
    };

    const available = try loadSelectableModels(allocator, env_map, session.agent.getModel(), current_provider, scoped_patterns, runtime_config);
    defer allocator.free(available);

    if (findExactModelEntry(available, search)) |entry| {
        try switchModel(
            allocator,
            env_map,
            session,
            current_provider,
            entry.provider,
            entry.model_id,
            options,
            runtime_config,
            app_state,
        );
        return;
    }

    overlay.* = try loadModelOverlayWithSearch(allocator, env_map, session.agent.getModel(), current_provider, scoped_patterns, runtime_config, search);
}

fn findExactModelEntry(
    available: []const provider_config.AvailableModel,
    search: []const u8,
) ?provider_config.AvailableModel {
    var matched: ?provider_config.AvailableModel = null;
    for (available) |entry| {
        if (!entry.available) continue;
        if (!modelEntryMatchesReference(entry, search)) continue;
        if (matched != null) return null;
        matched = entry;
    }
    return matched;
}

fn modelEntryMatchesReference(entry: provider_config.AvailableModel, search: []const u8) bool {
    const trimmed = std.mem.trim(u8, search, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, entry.model_id)) return true;
    if (entry.display_name.len > 0 and std.ascii.eqlIgnoreCase(trimmed, entry.display_name)) return true;
    if (providerModelReferenceMatches(entry.provider, entry.model_id, trimmed)) return true;

    const slash_index = std.mem.indexOfScalar(u8, trimmed, '/') orelse return false;
    const provider = std.mem.trim(u8, trimmed[0..slash_index], " \t\r\n");
    const model_id = std.mem.trim(u8, trimmed[slash_index + 1 ..], " \t\r\n");
    return provider.len > 0 and model_id.len > 0 and
        std.ascii.eqlIgnoreCase(provider, entry.provider) and
        std.ascii.eqlIgnoreCase(model_id, entry.model_id);
}

fn providerModelReferenceMatches(provider: []const u8, model_id: []const u8, search: []const u8) bool {
    const slash_index = std.mem.indexOfScalar(u8, search, '/') orelse return false;
    const provider_part = std.mem.trim(u8, search[0..slash_index], " \t\r\n");
    const model_part = std.mem.trim(u8, search[slash_index + 1 ..], " \t\r\n");
    return provider_part.len > 0 and model_part.len > 0 and
        std.ascii.eqlIgnoreCase(provider_part, provider) and
        std.ascii.eqlIgnoreCase(model_part, model_id);
}

pub fn handleThemeSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    argument: ?[]const u8,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    try live_resources.ensureOwnedBundle(allocator, io, env_map, cwd);

    if (argument) |raw_name| {
        try applyThemeByName(allocator, io, env_map, cwd, raw_name, app_state, live_resources);
        return;
    }

    const bundle = &live_resources.owned_resource_bundle.?;
    overlay.* = try loadThemeOverlay(allocator, bundle.themes, live_resources.theme);
}

pub fn applyThemeByName(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    raw_name: []const u8,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    const theme_name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (theme_name.len == 0) {
        try app_state.appendError("Usage: /theme <name>");
        return;
    }

    const resolved_theme_name = canonicalThemeName(theme_name);
    live_resources.applyTheme(allocator, io, env_map, cwd, resolved_theme_name) catch |err| switch (err) {
        error.ThemeNotFound => {
            const message = try std.fmt.allocPrint(allocator, "Unknown theme `{s}`", .{theme_name});
            defer allocator.free(message);
            try app_state.appendError(message);
            return;
        },
        else => return err,
    };

    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("theme switched for this session");
        return;
    };
    try persistGlobalThemeSelection(allocator, io, runtime_config, resolved_theme_name);
    try replaceRuntimeSettingsTheme(allocator, &live_resources.owned_runtime_config.?, resolved_theme_name);

    const active_theme_name = if (live_resources.theme) |theme| theme.name else theme_name;
    const message = try std.fmt.allocPrint(allocator, "Theme switched to {s}", .{active_theme_name});
    defer allocator.free(message);
    try app_state.setStatus(message);
}

fn canonicalThemeName(theme_name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(theme_name, "night")) return "dark";
    if (std.ascii.eqlIgnoreCase(theme_name, "day")) return "light";
    return theme_name;
}

fn persistGlobalThemeSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    theme_name: []const u8,
) !void {
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (content) |value| allocator.free(value);

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const next_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, next_value);
    }

    if (content) |settings_content| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_content, .{}) catch null;
        defer if (parsed) |*value| value.deinit();
        if (parsed) |parsed_value| {
            if (parsed_value.value == .object) {
                var iterator = parsed_value.value.object.iterator();
                while (iterator.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "theme")) continue;
                    try next_object.put(
                        allocator,
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try common.cloneJsonValue(allocator, entry.value_ptr.*),
                    );
                }
            }
        }
    }

    try next_object.put(
        allocator,
        try allocator.dupe(u8, "theme"),
        .{ .string = try allocator.dupe(u8, theme_name) },
    );

    const next_value: std.json.Value = .{ .object = next_object };
    defer common.deinitJsonValue(allocator, next_value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, next_value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

fn replaceRuntimeSettingsTheme(
    allocator: std.mem.Allocator,
    runtime_config: *config_mod.RuntimeConfig,
    theme_name: []const u8,
) !void {
    const next_global = try allocator.dupe(u8, theme_name);
    errdefer allocator.free(next_global);
    const next_effective = try allocator.dupe(u8, theme_name);
    errdefer allocator.free(next_effective);

    if (runtime_config.global_settings.theme) |old| allocator.free(old);
    runtime_config.global_settings.theme = next_global;
    if (runtime_config.settings.theme) |old| allocator.free(old);
    runtime_config.settings.theme = next_effective;
}

pub fn handleScopedModelsSlashCommand(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
) !void {
    const scoped_patterns = currentScopedModelPatterns(app_state, options, runtime_config);
    overlay.* = loadScopedModelOverlay(
        allocator,
        env_map,
        session.agent.getModel(),
        current_provider,
        scoped_patterns,
        runtime_config,
    ) catch |err| switch (err) {
        error.NoScopedModelsAvailable => {
            try app_state.setStatus("No models available to configure.");
            return;
        },
        else => return err,
    };
}

fn currentScopedModelPatterns(
    app_state: *const AppState,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
) ?[]const []const u8 {
    if (app_state.hasScopedModelOverride()) return app_state.scopedModelPatterns();
    if (runtime_config) |config| {
        if (config.settings.enabled_models) |patterns| {
            if (patterns.len > 0) return patterns;
        }
    }
    return options.model_patterns;
}

pub fn handleSessionSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    app_state: *AppState,
) !void {
    const info = try formatSessionInfo(allocator, session);
    defer allocator.free(info);
    try app_state.appendInfo(info);
}

pub const ChangelogView = enum {
    full,
    condensed,
};

pub fn handleChangelogSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const view = parseChangelogView(argument) catch {
        try app_state.appendError("Usage: /changelog [full|condensed]");
        return;
    };

    const markdown = buildChangelogMarkdown(allocator, io, session.cwd, view) catch |err| switch (err) {
        error.FileNotFound => {
            try app_state.appendError("CHANGELOG.md not found");
            return;
        },
        else => return err,
    };
    defer allocator.free(markdown);

    try app_state.appendMarkdown(markdown);

    const status = try std.fmt.allocPrint(allocator, "showing {s} changelog", .{@tagName(view)});
    defer allocator.free(status);
    try app_state.setStatus(status);
}

pub fn parseChangelogView(argument: ?[]const u8) !ChangelogView {
    const raw = argument orelse return .full;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, value, "full")) return .full;
    if (std.mem.eql(u8, value, "condensed")) return .condensed;
    return error.InvalidChangelogView;
}

pub fn buildChangelogMarkdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    view: ChangelogView,
) ![]u8 {
    const changelog_path = try resolveChangelogPath(allocator, io, cwd) orelse return error.FileNotFound;
    defer allocator.free(changelog_path);

    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, changelog_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(content);

    switch (view) {
        .full => return allocator.dupe(u8, content),
        .condensed => {
            if (extractLatestVersionSection(content)) |section| {
                return allocator.dupe(u8, section);
            }
            return allocator.dupe(u8, content);
        },
    }
}

pub fn resolveChangelogPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const package_candidate = try std.fs.path.join(allocator, &[_][]const u8{ current, "packages/coding-agent/CHANGELOG.md" });
        if (pathExists(io, package_candidate)) {
            allocator.free(current);
            return package_candidate;
        }
        allocator.free(package_candidate);

        const local_candidate = try std.fs.path.join(allocator, &[_][]const u8{ current, "CHANGELOG.md" });
        if (pathExists(io, local_candidate)) {
            allocator.free(current);
            return local_candidate;
        }
        allocator.free(local_candidate);

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    allocator.free(current);

    const source_dir = std.fs.path.dirname(@src().file) orelse ".";
    const fallback = try std.fs.path.resolve(allocator, &[_][]const u8{
        source_dir,
        "../../../../packages/coding-agent/CHANGELOG.md",
    });
    if (pathExists(io, fallback)) return fallback;
    allocator.free(fallback);
    return null;
}

pub fn findNearestRelativeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    relative_path: []const u8,
) !?[]u8 {
    var current = try allocator.dupe(u8, start_dir);
    errdefer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &[_][]const u8{ current, relative_path });
        if (pathExists(io, candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

pub fn extractLatestVersionSection(content: []const u8) ?[]const u8 {
    var offset: usize = 0;
    var current_start: ?usize = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const line_start = offset;
        offset += line.len + 1;
        const trimmed = trimCarriageReturn(line);
        if (!isVersionHeading(trimmed)) continue;

        if (current_start) |start| {
            return trimTrailingNewlines(content[start..line_start]);
        }
        current_start = line_start;
    }

    if (current_start) |start| {
        return trimTrailingNewlines(content[start..]);
    }
    return null;
}

pub fn isVersionHeading(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "## ")) return false;

    var index: usize = 3;
    while (index < line.len and line[index] == ' ') : (index += 1) {}
    if (index < line.len and line[index] == '[') index += 1;

    const first_len = consumeDigits(line, index);
    if (first_len == 0) return false;
    index += first_len;
    if (index >= line.len or line[index] != '.') return false;
    index += 1;

    const second_len = consumeDigits(line, index);
    if (second_len == 0) return false;
    index += second_len;
    if (index >= line.len or line[index] != '.') return false;
    index += 1;

    const third_len = consumeDigits(line, index);
    if (third_len == 0) return false;
    index += third_len;

    if (index < line.len and line[index] == ']') index += 1;
    return true;
}

fn consumeDigits(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    return index - start;
}

fn trimCarriageReturn(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];
    return text;
}

fn trimTrailingNewlines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    return text[0..end];
}

pub fn handleNameSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const name = argument orelse {
        const current_name = session.session_manager.getSessionName() orelse {
            try app_state.appendInfo("Usage: /name <name>");
            return;
        };
        const message = try std.fmt.allocPrint(allocator, "Session name: {s}", .{current_name});
        defer allocator.free(message);
        try app_state.appendInfo(message);
        return;
    };

    _ = try session.session_manager.appendSessionInfo(name);
    try app_state.setFooter(session.agent.getModel().id, currentSessionLabel(session));

    const message = try std.fmt.allocPrint(allocator, "Session name set: {s}", .{currentSessionLabel(session)});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn handleLabelSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const target_id = resolveCurrentLabelTargetId(session) orelse {
        try app_state.setStatus("No current session entry to label");
        return;
    };

    _ = try session.session_manager.appendLabelChange(target_id, argument);

    if (session.session_manager.getLabel(target_id)) |label| {
        const message = try std.fmt.allocPrint(allocator, "Label set: {s}", .{label});
        defer allocator.free(message);
        try app_state.appendInfo(message);
        try app_state.setStatus("label updated");
        return;
    }

    try app_state.appendInfo("Label cleared");
    try app_state.setStatus("label cleared");
}

pub fn resolveCurrentLabelTargetId(session: *const session_mod.AgentSession) ?[]const u8 {
    var target_id = session.session_manager.getLeafId() orelse return null;
    var remaining = session.session_manager.getEntries().len + 1;
    while (remaining > 0) : (remaining -= 1) {
        const entry = session.session_manager.getEntry(target_id) orelse return null;
        switch (entry.*) {
            .label => |label_entry| target_id = label_entry.target_id,
            else => return target_id,
        }
    }
    return null;
}

pub fn handleCompactSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const result = session.compact(argument) catch |err| switch (err) {
        error.NothingToCompact => {
            try app_state.setStatus("Nothing to compact yet");
            return;
        },
        else => return err,
    };

    const info = try std.fmt.allocPrint(
        allocator,
        "Compacted session history. Summary preserved {d} tokens before entry {s}.",
        .{ result.tokens_before, result.first_kept_entry_id },
    );
    defer allocator.free(info);
    try rebuildAppStateFromSession(allocator, session.io, app_state, session, null);
    try app_state.appendInfo(info);
}

pub const ClipboardCopyFn = *const fn (context: ?*anyopaque, io: std.Io, text: []const u8) anyerror!void;
pub const Osc52WriteFn = *const fn (context: ?*anyopaque, io: std.Io, bytes: []const u8) anyerror!void;

pub var clipboard_copy_context: ?*anyopaque = null;
pub var clipboard_copy_fn: ClipboardCopyFn = defaultCopyTextToClipboard;
pub var osc52_write_context: ?*anyopaque = null;
pub var osc52_write_fn: Osc52WriteFn = defaultWriteOsc52;
pub var copy_temp_file_override: ?[]const u8 = null;
pub fn handleSettingsSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *const session_mod.AgentSession,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Settings editor is unavailable in this session");
        return;
    };
    if (argument) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "raw") or std.ascii.eqlIgnoreCase(trimmed, "json")) {
            overlay.* = try loadSettingsEditorOverlay(allocator, io, runtime_config, live_resources.theme);
            return;
        }
    }
    try live_resources.ensureOwnedBundle(allocator, io, env_map, options.cwd);
    const themes = if (live_resources.owned_resource_bundle) |*bundle| bundle.themes else &.{};
    overlay.* = try loadSettingsOverlay(allocator, runtime_config, session, themes, live_resources.theme, false);
}

pub fn handleSettingsOverlayKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    session: *session_mod.AgentSession,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    var overlay_value = overlay.* orelse return;
    if (std.meta.activeTag(overlay_value) != .settings) return;
    const settings = &overlay_value.settings;

    switch (key) {
        .escape => {
            if (settings.mode == .theme) {
                applyThemeByName(allocator, io, env_map, options.cwd, settings.original_theme, app_state, live_resources) catch {};
                try overlays.exitSettingsSubmenu(allocator, settings);
                overlay.* = overlay_value;
                return;
            }
            if (settings.mode != .main) {
                try overlays.exitSettingsSubmenu(allocator, settings);
                overlay.* = overlay_value;
                return;
            }
            overlay_value.deinit(allocator);
            overlay.* = null;
            return;
        },
        .backspace => {
            if (settings.mode == .main and settings.search.len > 0) {
                try overlays.updateSettingsSearch(allocator, settings, settings.search[0 .. settings.search.len - 1]);
            }
            overlay.* = overlay_value;
            return;
        },
        .up, .down => {
            _ = settings.list.handleKey(key);
            if (settings.mode == .theme) {
                if (overlays.selectedSettingsChoice(settings)) |choice| {
                    applyThemeByName(allocator, io, env_map, options.cwd, choice.value, app_state, live_resources) catch {};
                }
            }
            overlay.* = overlay_value;
            return;
        },
        .enter => {
            try activateSettingsChoice(allocator, io, env_map, session, options, app_state, editor, &overlay_value, overlay, live_resources);
            return;
        },
        .printable => |printable| {
            const text = printable.slice();
            if (std.mem.eql(u8, text, " ")) {
                try activateSettingsChoice(allocator, io, env_map, session, options, app_state, editor, &overlay_value, overlay, live_resources);
                return;
            }
            if (settings.mode == .main and (std.mem.eql(u8, text, "r") or std.mem.eql(u8, text, "R"))) {
                const runtime_config = live_resources.runtime_config orelse {
                    try app_state.setStatus("Settings editor is unavailable in this session");
                    overlay.* = overlay_value;
                    return;
                };
                overlay_value.deinit(allocator);
                overlay.* = try loadSettingsEditorOverlay(allocator, io, runtime_config, live_resources.theme);
                return;
            }
            if (settings.mode == .main) {
                const next_search = try std.fmt.allocPrint(allocator, "{s}{s}", .{ settings.search, text });
                defer allocator.free(next_search);
                try overlays.updateSettingsSearch(allocator, settings, next_search);
            }
            overlay.* = overlay_value;
            return;
        },
        else => {
            _ = settings.list.handleKey(key);
            overlay.* = overlay_value;
            return;
        },
    }
}

fn activateSettingsChoice(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay_value: *SelectorOverlay,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    const settings = &overlay_value.settings;
    const choice = overlays.selectedSettingsChoice(settings) orelse return;
    switch (settings.mode) {
        .main => switch (choice.id) {
            .none => return,
            .raw_json => {
                const runtime_config = live_resources.runtime_config orelse {
                    try app_state.setStatus("Settings editor is unavailable in this session");
                    return;
                };
                overlay_value.deinit(allocator);
                overlay.* = try loadSettingsEditorOverlay(allocator, io, runtime_config, live_resources.theme);
                return;
            },
            .thinking => try overlays.enterSettingsMode(allocator, settings, .thinking),
            .theme => try overlays.enterSettingsMode(allocator, settings, .theme),
            .warnings => try overlays.enterSettingsMode(allocator, settings, .warnings),
            else => try cycleStructuredSetting(allocator, io, env_map, session, options, app_state, editor, settings, choice, live_resources),
        },
        .thinking => {
            const next = parseThinkingLevelName(choice.value) orelse return;
            try session.setThinkingLevel(next);
            try app_state.setStatus("thinking level updated");
            try overlays.exitSettingsSubmenu(allocator, settings);
        },
        .theme => {
            try persistStructuredSetting(allocator, io, env_map, options, .theme, choice.value, app_state, live_resources);
            try app_state.setStatus("theme updated");
            try overlays.exitSettingsSubmenu(allocator, settings);
        },
        .warnings => {
            const next_value = if (std.mem.eql(u8, choice.value, "true")) "false" else "true";
            try persistStructuredSetting(allocator, io, env_map, options, .warnings, next_value, app_state, live_resources);
            try overlays.refreshSettingsOverlay(allocator, settings);
        },
    }
    settings.runtime_config = live_resources.runtime_config;
    overlay.* = overlay_value.*;
}

fn cycleStructuredSetting(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    settings: *overlays.SettingsOverlay,
    choice: @import("settings_overlay.zig").Choice,
    live_resources: *LiveResources,
) !void {
    const next_value = try nextSettingsValue(allocator, choice.id, choice.value);
    defer allocator.free(next_value);
    try persistStructuredSetting(allocator, io, env_map, options, choice.id, next_value, app_state, live_resources);
    try applyStructuredSettingSideEffect(session, app_state, editor, choice.id, next_value, live_resources);
    settings.runtime_config = live_resources.runtime_config;
    try overlays.refreshSettingsOverlay(allocator, settings);
}

fn nextSettingsValue(allocator: std.mem.Allocator, id: overlays.SettingId, current: []const u8) ![]u8 {
    return switch (id) {
        .autocompact,
        .show_images,
        .auto_resize_images,
        .block_images,
        .skill_commands,
        .show_hardware_cursor,
        .clear_on_shrink,
        .terminal_progress,
        .hide_thinking,
        .collapse_changelog,
        .quiet_startup,
        .install_telemetry,
        => allocator.dupe(u8, if (std.mem.eql(u8, current, "true")) "false" else "true"),
        .image_width_cells => nextFromList(allocator, &.{ "60", "80", "120" }, current),
        .editor_padding => nextFromList(allocator, &.{ "0", "1", "2", "3" }, current),
        .autocomplete_max_visible => nextFromList(allocator, &.{ "3", "5", "7", "10", "15", "20" }, current),
        .steering_mode, .follow_up_mode => nextFromList(allocator, &.{ "one-at-a-time", "all" }, current),
        .transport => nextFromList(allocator, &.{ "sse", "websocket", "websocket-cached", "auto" }, current),
        .double_escape_action => nextFromList(allocator, &.{ "tree", "fork", "none" }, current),
        .tree_filter_mode => nextFromList(allocator, &.{ "default", "no-tools", "user-only", "labeled-only", "all" }, current),
        else => allocator.dupe(u8, current),
    };
}

fn nextFromList(allocator: std.mem.Allocator, values: []const []const u8, current: []const u8) ![]u8 {
    var next_index: usize = 0;
    for (values, 0..) |value, index| {
        if (std.mem.eql(u8, value, current)) {
            next_index = (index + 1) % values.len;
            break;
        }
    }
    return allocator.dupe(u8, values[next_index]);
}

fn persistStructuredSetting(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    id: overlays.SettingId,
    value: []const u8,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Settings are unavailable in this session");
        return;
    };
    var settings_json = loadSettingsJsonValue(allocator, io, runtime_config.agent_dir) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Invalid settings.json: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    };
    defer common.deinitJsonValue(allocator, settings_json);
    if (settings_json != .object) {
        try app_state.appendError("Invalid settings.json: top-level value must be an object");
        return;
    }

    try updateSettingsJsonValue(allocator, &settings_json.object, id, value);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const serialized = try std.json.Stringify.valueAlloc(allocator, settings_json, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);

    const diagnostics = try live_resources.reload(allocator, io, env_map, options.cwd);
    try appendResourceDiagnostics(allocator, app_state, diagnostics);
}

fn loadSettingsJsonValue(allocator: std.mem.Allocator, io: std.Io, agent_dir: []const u8) !std.json.Value {
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        else => return err,
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    return common.cloneJsonValue(allocator, parsed.value);
}

fn updateSettingsJsonValue(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    id: overlays.SettingId,
    value: []const u8,
) !void {
    switch (id) {
        .autocompact => try putNestedBool(allocator, object, "compaction", "enabled", parseBoolText(value)),
        .show_images => try putNestedBool(allocator, object, "terminal", "showImages", parseBoolText(value)),
        .image_width_cells => try putNestedInteger(allocator, object, "terminal", "imageWidthCells", try parseUsizeText(value)),
        .auto_resize_images => try putNestedBool(allocator, object, "images", "autoResize", parseBoolText(value)),
        .block_images => try putNestedBool(allocator, object, "images", "blockImages", parseBoolText(value)),
        .skill_commands => try putBool(allocator, object, "enableSkillCommands", parseBoolText(value)),
        .show_hardware_cursor => try putBool(allocator, object, "showHardwareCursor", parseBoolText(value)),
        .editor_padding => try putInteger(allocator, object, "editorPaddingX", try parseUsizeText(value)),
        .autocomplete_max_visible => try putInteger(allocator, object, "autocompleteMaxVisible", try parseUsizeText(value)),
        .clear_on_shrink => try putNestedBool(allocator, object, "terminal", "clearOnShrink", parseBoolText(value)),
        .terminal_progress => try putNestedBool(allocator, object, "terminal", "showTerminalProgress", parseBoolText(value)),
        .steering_mode => try putString(allocator, object, "steeringMode", value),
        .follow_up_mode => try putString(allocator, object, "followUpMode", value),
        .transport => try putString(allocator, object, "transport", value),
        .hide_thinking => try putBool(allocator, object, "hideThinkingBlock", parseBoolText(value)),
        .collapse_changelog => try putBool(allocator, object, "collapseChangelog", parseBoolText(value)),
        .quiet_startup => try putBool(allocator, object, "quietStartup", parseBoolText(value)),
        .install_telemetry => try putBool(allocator, object, "enableInstallTelemetry", parseBoolText(value)),
        .double_escape_action => try putString(allocator, object, "doubleEscapeAction", value),
        .tree_filter_mode => try putString(allocator, object, "treeFilterMode", value),
        .theme => try putString(allocator, object, "theme", value),
        .warnings => try putNestedBool(allocator, object, "warnings", "anthropicExtraUsage", parseBoolText(value)),
        else => {},
    }
}

fn applyStructuredSettingSideEffect(
    session: *session_mod.AgentSession,
    app_state: *AppState,
    editor: *tui.Editor,
    id: overlays.SettingId,
    value: []const u8,
    live_resources: *LiveResources,
) !void {
    switch (id) {
        .autocompact => session.compaction_settings = configuredCompactionSettings(live_resources.runtime_config),
        .steering_mode => session.agent.steering_queue.mode = parseQueueMode(value),
        .follow_up_mode => session.agent.follow_up_queue.mode = parseQueueMode(value),
        .hide_thinking => try app_state.setThinkingBlockVisibility(parseBoolText(value)),
        .editor_padding, .autocomplete_max_visible => configurePrimaryEditor(editor, live_resources.runtime_config),
        else => {},
    }
    try app_state.setStatus("setting updated");
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try putOwnedValue(allocator, object, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try putOwnedValue(allocator, object, key, .{ .bool = value });
}

fn putInteger(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: usize) !void {
    try putOwnedValue(allocator, object, key, .{ .integer = @intCast(value) });
}

fn putNestedBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, nested_key: []const u8, value: bool) !void {
    const nested = try ensureNestedObject(allocator, object, key);
    try putBool(allocator, nested, nested_key, value);
}

fn putNestedInteger(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, nested_key: []const u8, value: usize) !void {
    const nested = try ensureNestedObject(allocator, object, key);
    try putInteger(allocator, nested, nested_key, value);
}

fn ensureNestedObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    if (object.getPtr(key)) |existing| {
        if (existing.* != .object) {
            common.deinitJsonValue(allocator, existing.*);
            existing.* = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
        }
        return &existing.object;
    }
    try common.putValue(allocator, &object, key, .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) });
    return &object.getPtr(key).?.object;
}

fn putOwnedValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    if (object.getPtr(key)) |existing| {
        common.deinitJsonValue(allocator, existing.*);
        existing.* = value;
        return;
    }
    try common.putValue(allocator, &object, key, value);
}

fn parseBoolText(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

fn parseUsizeText(value: []const u8) !usize {
    return try std.fmt.parseInt(usize, value, 10);
}

fn parseQueueMode(value: []const u8) agent.QueueMode {
    return if (std.mem.eql(u8, value, "all")) .all else .one_at_a_time;
}

fn parseThinkingLevelName(value: []const u8) ?agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

pub fn handleImportSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    const raw_path = argument orelse {
        try app_state.appendError("Usage: /import <path.jsonl>");
        return;
    };

    const session_path = try common.resolvePath(allocator, options.cwd, normalizePathArgument(raw_path));
    defer allocator.free(session_path);

    switchSession(
        allocator,
        io,
        env_map,
        session,
        current_provider,
        session_path,
        options,
        runtime_config,
        tool_items,
        app_state,
        subscriber,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            const message = try std.fmt.allocPrint(allocator, "Failed to import session: file not found: {s}", .{session_path});
            defer allocator.free(message);
            try app_state.appendError(message);
            return;
        },
        else => return err,
    };

    const message = try std.fmt.allocPrint(allocator, "Session imported from {s}", .{session_path});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub const CopyScope = enum {
    last,
    all,
    visible,
};

pub fn parseCopyScope(argument: ?[]const u8) !CopyScope {
    const raw = argument orelse return .last;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return .last;
    if (std.ascii.eqlIgnoreCase(value, "last")) return .last;
    if (std.ascii.eqlIgnoreCase(value, "all")) return .all;
    if (std.ascii.eqlIgnoreCase(value, "visible")) return .visible;
    return error.InvalidCopyScope;
}

pub fn handleCopySlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    app_state: *AppState,
    argument: ?[]const u8,
) !void {
    const scope = parseCopyScope(argument) catch {
        try app_state.appendError("Usage: /copy [last|all|visible]");
        return;
    };

    const text = switch (scope) {
        .last => lastAssistantTextAlloc(allocator, session) orelse {
            try app_state.appendError("No assistant messages to copy yet.");
            return;
        },
        .all => try sessionTranscriptTextAlloc(allocator, session),
        .visible => try rendering.visibleChatTextAlloc(allocator, app_state),
    };
    defer allocator.free(text);

    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        try app_state.appendError(switch (scope) {
            .last => "No assistant messages to copy yet.",
            .all => "No transcript content to copy yet.",
            .visible => "No visible chat content to copy yet.",
        });
        return;
    }

    var outcome = copyTextToClipboardWithFallback(allocator, io, text) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Failed to copy {s}: {s}", .{ copyScopeStatusNoun(scope), @errorName(err) });
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    };
    defer outcome.deinit(allocator);

    const base_message = switch (scope) {
        .last => "Copied last assistant message",
        .all => "Copied full session transcript",
        .visible => "Copied visible chat viewport",
    };
    switch (outcome) {
        .clipboard => {
            const message = try std.fmt.allocPrint(allocator, "{s} to clipboard", .{base_message});
            defer allocator.free(message);
            try app_state.appendInfo(message);
            try app_state.setStatus("copied");
        },
        .osc52 => {
            const message = try std.fmt.allocPrint(allocator, "{s} via OSC 52 clipboard fallback", .{base_message});
            defer allocator.free(message);
            try app_state.appendInfo(message);
            try app_state.setStatus("copied via OSC 52");
        },
        .temp_file => |path| {
            const message = try std.fmt.allocPrint(allocator, "{s} to temp file: {s}", .{ base_message, path });
            defer allocator.free(message);
            try app_state.appendInfo(message);
            const status = try std.fmt.allocPrint(allocator, "copy saved to {s}", .{path});
            defer allocator.free(status);
            try app_state.setStatus(status);
        },
    }
}

fn copyScopeStatusNoun(scope: CopyScope) []const u8 {
    return switch (scope) {
        .last => "assistant message",
        .all => "session transcript",
        .visible => "visible chat",
    };
}

pub const DEFAULT_SHARE_VIEWER_URL: []const u8 = "https://pi.dev/session/";
pub const DEFAULT_SHARE_TMP_FILE: []const u8 = "/tmp/session.html";

pub const ShareGhResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    /// True only when the binary was missing on PATH (gh not installed).
    not_found: bool = false,

    pub fn deinit(self: *ShareGhResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
    }
};

pub const ShareGhRunFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!ShareGhResult;

pub var share_gh_run_context: ?*anyopaque = null;
pub var share_gh_run_fn: ShareGhRunFn = defaultShareGhRun;
pub var share_tmp_file_override: ?[]const u8 = null;

pub fn defaultShareGhRun(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!ShareGhResult {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => return ShareGhResult{
            .exit_code = 127,
            .stdout = try allocator.alloc(u8, 0),
            .stderr = try allocator.alloc(u8, 0),
            .not_found = true,
        },
        else => return err,
    };
    return ShareGhResult{
        .exit_code = exitCodeFromChildTerm(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
        .not_found = false,
    };
}

fn shareTmpFilePath() []const u8 {
    return share_tmp_file_override orelse DEFAULT_SHARE_TMP_FILE;
}

fn parseGistIdFromOutput(stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| {
        const id = trimmed[slash + 1 ..];
        if (id.len == 0) return null;
        // Reject empty/whitespace and anything that does not look like an id.
        for (id) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
        }
        return id;
    }
    return null;
}

fn shareViewerUrl(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    gist_id: []const u8,
) ![]u8 {
    const base_raw = env_map.get("PI_SHARE_VIEWER_URL");
    const base = if (base_raw) |value|
        std.mem.trim(u8, value, " \t\r\n")
    else
        "";
    const effective = if (base.len > 0) base else DEFAULT_SHARE_VIEWER_URL;
    return std.fmt.allocPrint(allocator, "{s}#{s}", .{ effective, gist_id });
}

pub fn handleShareSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    app_state: *AppState,
) !void {
    if (session.agent.getMessages().len == 0) {
        try app_state.appendError("No session messages to share yet.");
        return;
    }

    // 1) Check that gh is installed and authenticated.
    var auth_result = share_gh_run_fn(
        share_gh_run_context,
        allocator,
        io,
        &[_][]const u8{ "gh", "auth", "status" },
    ) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Failed to invoke gh: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    };
    defer auth_result.deinit(allocator);

    if (auth_result.not_found) {
        // gh is not installed - fall back to copying session markdown to clipboard
        const text = buildShareText(allocator, session) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to build share text: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            try app_state.appendError(msg);
            try app_state.setStatus("share failed");
            return;
        };
        defer allocator.free(text);
        copyTextToClipboard(io, text) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Session markdown copy failed: {s}. Install gh from https://cli.github.com/ for gist sharing.", .{@errorName(err)});
            defer allocator.free(msg);
            try app_state.appendError(msg);
            try app_state.setStatus("share failed");
            return;
        };
        try app_state.appendInfo("Session markdown copied to clipboard (install gh CLI from https://cli.github.com/ for gist sharing)");
        try app_state.setStatus("copied");
        return;
    }
    if (auth_result.exit_code != 0) {
        try app_state.appendError("GitHub CLI is not logged in. Run 'gh auth login' first.");
        try app_state.setStatus("share failed");
        return;
    }

    // 2) Export the session to a temporary HTML file.
    const tmp_file = shareTmpFilePath();
    const exported_path = session_advanced.exportToHtml(allocator, io, session, tmp_file) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Failed to export session: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    };
    defer allocator.free(exported_path);

    var cleanup_done = false;
    defer if (!cleanup_done) {
        std.Io.Dir.deleteFileAbsolute(io, exported_path) catch {};
    };

    // 3) Create a secret gist.
    var gist_result = share_gh_run_fn(
        share_gh_run_context,
        allocator,
        io,
        &[_][]const u8{ "gh", "gist", "create", "--public=false", exported_path },
    ) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, exported_path) catch {};
        cleanup_done = true;
        const message = try std.fmt.allocPrint(allocator, "Failed to create gist: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    };
    defer gist_result.deinit(allocator);

    // Always clean the temp file once gh has run.
    std.Io.Dir.deleteFileAbsolute(io, exported_path) catch {};
    cleanup_done = true;

    if (gist_result.not_found) {
        try app_state.appendError("GitHub CLI (gh) is not installed. Install it from https://cli.github.com/");
        try app_state.setStatus("share failed");
        return;
    }
    if (gist_result.exit_code != 0) {
        const stderr_trimmed = std.mem.trim(u8, gist_result.stderr, " \t\r\n");
        const detail = if (stderr_trimmed.len > 0) stderr_trimmed else "Unknown error";
        const message = try std.fmt.allocPrint(allocator, "Failed to create gist: {s}", .{detail});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    }

    const gist_url = std.mem.trim(u8, gist_result.stdout, " \t\r\n");
    const gist_id = parseGistIdFromOutput(gist_url) orelse {
        try app_state.appendError("Failed to parse gist ID from gh output");
        try app_state.setStatus("share failed");
        return;
    };

    const preview_url = try shareViewerUrl(allocator, env_map, gist_id);
    defer allocator.free(preview_url);

    const message = try std.fmt.allocPrint(allocator, "Share URL: {s}\nGist: {s}", .{ preview_url, gist_url });
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("shared");
}

pub fn copyTextToClipboard(io: std.Io, text: []const u8) !void {
    try clipboard_copy_fn(clipboard_copy_context, io, text);
}

pub const ClipboardCopyOutcome = union(enum) {
    clipboard,
    osc52,
    temp_file: []u8,

    pub fn deinit(self: *ClipboardCopyOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .temp_file => |path| allocator.free(path),
            .clipboard, .osc52 => {},
        }
        self.* = undefined;
    }
};

const MAX_OSC52_ENCODED_LENGTH: usize = 100_000;

pub fn copyTextToClipboardWithFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
) !ClipboardCopyOutcome {
    const platform_copied = blk: {
        copyTextToClipboard(io, text) catch break :blk false;
        break :blk true;
    };
    const remote = isRemoteSession();
    if (platform_copied and !remote) return .clipboard;

    if (emitOsc52(allocator, io, text)) {
        return .osc52;
    } else |_| {
        if (platform_copied) return .clipboard;
    }

    const path = try writeCopyFallbackTempFile(allocator, io, text);
    return .{ .temp_file = path };
}

fn isRemoteSession() bool {
    return std.c.getenv("SSH_CONNECTION") != null or
        std.c.getenv("SSH_CLIENT") != null or
        std.c.getenv("MOSH_CONNECTION") != null;
}

fn emitOsc52(allocator: std.mem.Allocator, io: std.Io, text: []const u8) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(text.len);
    if (encoded_len > MAX_OSC52_ENCODED_LENGTH) return error.Osc52PayloadTooLarge;
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, text);

    var sequence = std.ArrayList(u8).empty;
    defer sequence.deinit(allocator);
    try sequence.appendSlice(allocator, "\x1b]52;c;");
    try sequence.appendSlice(allocator, encoded);
    try sequence.append(allocator, 0x07);
    try osc52_write_fn(osc52_write_context, io, sequence.items);
}

fn defaultWriteOsc52(_: ?*anyopaque, io: std.Io, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.writeAll(bytes);
    try stdout.flush();
}

fn writeCopyFallbackTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
) ![]u8 {
    if (copy_temp_file_override) |path| {
        try common.writeFileAbsolute(io, path, text, true);
        return try allocator.dupe(u8, path);
    }

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const path = try std.fmt.allocPrint(
            allocator,
            "/tmp/pi-copy-{d}-{d}.txt",
            .{ agent.nowMilliseconds(), attempts },
        );
        errdefer allocator.free(path);

        if (std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true })) |file| {
            var owned = file;
            defer owned.close(io);
            var buffer: [1024]u8 = undefined;
            var writer = owned.writer(io, &buffer);
            try writer.interface.writeAll(text);
            try writer.flush();
            return path;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        }
    }
    return error.CopyFallbackTempFileFailed;
}

pub fn defaultCopyTextToClipboard(_: ?*anyopaque, io: std.Io, text: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try runClipboardCommand(io, &[_][]const u8{"pbcopy"}, text),
        .windows => try runClipboardCommand(io, &[_][]const u8{"clip"}, text),
        else => {
            runClipboardCommand(io, &[_][]const u8{"wl-copy"}, text) catch {
                runClipboardCommand(io, &[_][]const u8{ "xclip", "-selection", "clipboard" }, text) catch {
                    try runClipboardCommand(io, &[_][]const u8{ "xsel", "--clipboard", "--input" }, text);
                };
            };
        },
    }
}

pub fn runClipboardCommand(io: std.Io, argv: []const []const u8, text: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        if (child.id != null) child.kill(io);
    }

    const stdin_file = child.stdin.?;
    child.stdin = null;

    var buffer: [1024]u8 = undefined;
    var writer = stdin_file.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.flush();
    stdin_file.close(io);

    const term = try child.wait(io);
    if (exitCodeFromChildTerm(term) != 0) return error.ClipboardCommandFailed;
}

pub fn exitCodeFromChildTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn lastAssistantTextAlloc(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ?[]u8 {
    const messages = session.agent.getMessages();
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| {
                const text = assistantBlocksToTextAlloc(allocator, assistant_message.content) catch return null;
                if (text.len == 0) {
                    allocator.free(text);
                    return null;
                }
                return text;
            },
            else => {},
        }
    }
    return null;
}

pub fn assistantBlocksToTextAlloc(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (text.text.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (thinking.thinking.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(thinking.thinking);
                wrote_any = true;
            },
            .image, .tool_call => {},
        }
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn buildShareText(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = session_advanced.getSessionStats(session);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.print("# Session {s}\n\n", .{stats.session_name orelse stats.session_id});
    try writer.writer.print("- Session ID: `{s}`\n", .{stats.session_id});
    try writer.writer.print("- Working directory: `{s}`\n", .{session.cwd});
    try writer.writer.print("- Model: `{s}` / `{s}`\n\n", .{ session.agent.getModel().provider, session.agent.getModel().id });
    try writer.writer.writeAll("## Transcript\n\n");

    for (session.agent.getMessages(), 0..) |message, index| {
        try writer.writer.print("### {d}. {s}\n\n", .{ index + 1, switch (message) {
            .user => "User",
            .assistant => "Assistant",
            .tool_result => "Tool Result",
        } });
        const markdown = try messageToShareMarkdown(allocator, message);
        defer allocator.free(markdown);
        if (markdown.len == 0) {
            try writer.writer.writeAll("_No text content_\n\n");
        } else {
            try writer.writer.print("{s}\n\n", .{markdown});
        }
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn messageToShareMarkdown(allocator: std.mem.Allocator, message: agent.AgentMessage) ![]u8 {
    return switch (message) {
        .user => |user_message| blocksToShareText(allocator, user_message.content),
        .assistant => |assistant_message| blk: {
            const text = try blocksToShareText(allocator, assistant_message.content);
            if (text.len > 0) break :blk text;
            const calls = try ai.collectAssistantToolCalls(allocator, assistant_message);
            defer allocator.free(calls);
            if (calls.len > 0) {
                var writer: std.Io.Writer.Allocating = .init(allocator);
                defer writer.deinit();
                for (calls, 0..) |tool_call, index| {
                    if (index > 0) try writer.writer.writeAll("\n");
                    const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
                    defer allocator.free(args);
                    try writer.writer.print("- `{s}` `{s}`\n```json\n{s}\n```", .{ tool_call.name, tool_call.id, args });
                }
                break :blk try allocator.dupe(u8, writer.written());
            }
            break :blk text;
        },
        .tool_result => |tool_result| blk: {
            const text = try blocksToShareText(allocator, tool_result.content);
            defer allocator.free(text);
            if (text.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "`{s}` returned no text content", .{tool_result.tool_name});
            }
            break :blk try std.fmt.allocPrint(allocator, "`{s}`\n\n{s}", .{ tool_result.tool_name, text });
        },
    };
}

pub fn blocksToShareText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (text.text.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (thinking.thinking.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("_Thinking:_ {s}", .{thinking.thinking});
                wrote_any = true;
            },
            .image => |image| {
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("![image](data:{s};base64,{s})", .{ image.mime_type, image.data });
                wrote_any = true;
            },
            .tool_call => |tool_call| {
                if (wrote_any) try writer.writer.writeAll("\n");
                const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
                defer allocator.free(args);
                try writer.writer.print("- `{s}` `{s}`\n```json\n{s}\n```", .{ tool_call.name, tool_call.id, args });
                wrote_any = true;
            },
        }
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn sessionTranscriptTextAlloc(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const branch = session.session_manager.getBranch(allocator, null) catch |err| switch (err) {
        error.EntryNotFound, error.InvalidSessionTree => null,
        else => return err,
    };
    if (branch) |entries| {
        defer allocator.free(entries);
        for (entries) |entry| {
            try appendTranscriptEntry(allocator, &writer, entry.*);
        }
    }

    if (writer.written().len == 0) {
        for (session.agent.getMessages()) |message| {
            try appendTranscriptMessage(allocator, &writer, message);
        }
    }

    return try allocator.dupe(u8, std.mem.trim(u8, writer.written(), "\n"));
}

fn appendTranscriptEntry(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer.Allocating,
    entry: session_manager_mod.SessionEntry,
) !void {
    switch (entry) {
        .message => |message_entry| try appendTranscriptMessage(allocator, writer, message_entry.message),
        .custom_message => |custom_message_entry| {
            if (!custom_message_entry.display) return;
            try appendTranscriptSeparator(writer);
            const title = if (std.mem.eql(u8, custom_message_entry.custom_type, "bashExecution"))
                "Bash"
            else
                custom_message_entry.custom_type;
            try writer.writer.print("### {s}\n\n", .{title});
            const text = try customMessageContentTextAlloc(allocator, custom_message_entry.content);
            defer allocator.free(text);
            try writer.writer.print("{s}\n\n", .{text});
        },
        .branch_summary => |branch_summary_entry| {
            try appendTranscriptSeparator(writer);
            try writer.writer.print("### Branch Summary\n\n{s}\n\n", .{branch_summary_entry.summary});
        },
        .thinking_level_change, .model_change, .active_tools_change, .compaction, .custom, .label, .session_info => {},
    }
}

fn appendTranscriptMessage(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer.Allocating,
    message: agent.AgentMessage,
) !void {
    try appendTranscriptSeparator(writer);
    try writer.writer.print("### {s}\n\n", .{switch (message) {
        .user => "User",
        .assistant => "Assistant",
        .tool_result => "Tool Result",
    }});
    const markdown = try messageToShareMarkdown(allocator, message);
    defer allocator.free(markdown);
    if (markdown.len == 0) {
        try writer.writer.writeAll("_No text content_\n\n");
    } else {
        try writer.writer.print("{s}\n\n", .{markdown});
    }
}

fn appendTranscriptSeparator(writer: *std.Io.Writer.Allocating) !void {
    if (writer.written().len > 0 and !std.mem.endsWith(u8, writer.written(), "\n\n")) {
        try writer.writer.writeAll("\n\n");
    }
}

fn customMessageContentTextAlloc(
    allocator: std.mem.Allocator,
    content: session_manager_mod.CustomMessageContent,
) ![]u8 {
    return switch (content) {
        .text => |text| allocator.dupe(u8, text),
        .blocks => |blocks| blocksToShareText(allocator, blocks),
    };
}

pub fn handleReloadSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    session: *session_mod.AgentSession,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    if (live_resources.runtime_config == null) {
        try app_state.setStatus("Reload is unavailable in this session");
        return;
    }

    const diagnostics = try live_resources.reload(allocator, io, env_map, cwd);
    try appendResourceDiagnostics(allocator, app_state, diagnostics);
    if (live_resources.reload_extension_tools_sink) |sink| {
        sink.callback(sink.context, allocator, io, env_map, cwd, session, live_resources) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try app_state.appendError("Reloaded resources, but extension tool refresh failed before diagnostics completed");
                try app_state.setStatus("Reloaded resources with extension diagnostics");
                return;
            },
        };
    }
    try app_state.setStatus("Reloaded keybindings, extensions, skills, prompts, and themes");
}

pub fn configurePrimaryEditor(editor: *tui.Editor, runtime_config: ?*const config_mod.RuntimeConfig) void {
    editor.padding_x = if (runtime_config) |runtime_config_value|
        runtime_config_value.settings.editor_padding_x orelse 0
    else
        0;
    editor.autocomplete_max_visible = if (runtime_config) |runtime_config_value|
        runtime_config_value.settings.autocomplete_max_visible orelse 5
    else
        5;
}

pub fn appendResourceDiagnostics(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    diagnostics: []const resources_mod.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const message = if (diagnostic.path) |path|
            try std.fmt.allocPrint(allocator, "{s}: {s} ({s})", .{ diagnostic.kind, diagnostic.message, path })
        else
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ diagnostic.kind, diagnostic.message });
        defer allocator.free(message);
        if (std.mem.eql(u8, diagnostic.kind, "warning")) {
            try app_state.appendError(message);
        } else {
            try app_state.appendInfo(message);
        }
    }
}

pub fn saveSettingsEditorOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    var overlay_value = overlay.* orelse return;
    if (std.meta.activeTag(overlay_value) != .settings_editor) return;

    const expanded_text = try overlay_value.settings_editor.editor.expandedTextAlloc(allocator);
    defer allocator.free(expanded_text);
    const trimmed = std.mem.trim(u8, expanded_text, " \t\r\n");
    const serialized = if (trimmed.len == 0)
        "{\n}\n"
    else
        expanded_text;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, serialized, .{}) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Invalid settings.json: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try app_state.appendError("Invalid settings.json: top-level value must be an object");
        return;
    }

    try common.writeFileAbsolute(io, overlay_value.settings_editor.path, serialized, true);

    const diagnostics = try live_resources.reload(allocator, io, env_map, options.cwd);
    configurePrimaryEditor(editor, live_resources.runtime_config);
    if (live_resources.runtime_config) |runtime_config| {
        try app_state.setThinkingBlockVisibility(runtime_config.hideThinkingBlock());
    }
    session.compaction_settings = configuredCompactionSettings(live_resources.runtime_config);
    session.retry_settings = configuredRetrySettings(live_resources.runtime_config);

    const path_copy = try allocator.dupe(u8, overlay_value.settings_editor.path);
    defer allocator.free(path_copy);
    overlay_value.deinit(allocator);
    overlay.* = null;

    const message = try std.fmt.allocPrint(allocator, "Saved settings to {s}", .{path_copy});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("settings saved");
    try appendResourceDiagnostics(allocator, app_state, diagnostics);
}

pub fn handleExportSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const output_path = if (argument) |raw_path| normalizePathArgument(raw_path) else null;
    const exported_path = if (output_path) |path| blk: {
        if (std.mem.endsWith(u8, path, ".html")) {
            break :blk try session_advanced.exportToHtml(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".jsonl")) {
            break :blk try session_advanced.exportToJsonl(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".json")) {
            break :blk try session_advanced.exportToJson(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".md")) {
            break :blk try session_advanced.exportToMarkdown(allocator, io, session, path);
        }
        const message = try std.fmt.allocPrint(allocator, "Unsupported export path: {s}. Use .html, .jsonl, .json, or .md.", .{path});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    } else try session_advanced.exportToHtml(allocator, io, session, null);
    defer allocator.free(exported_path);

    const message = try std.fmt.allocPrint(allocator, "Session exported to {s}", .{exported_path});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("session exported");
}

fn ignoreSlashTestAgentEvent(_: ?*anyopaque, _: agent.AgentEvent) anyerror!void {}

test "fork selector lists user messages and fork branches before selected prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sessions", .default_dir);

    const tmp_root = try makeSlashTestTempPath(allocator, &tmp, null);
    defer allocator.free(tmp_root);
    const session_dir = try makeSlashTestTempPath(allocator, &tmp, "sessions");
    defer allocator.free(session_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = tmp_root,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    const original_session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(original_session_file);

    var first_user = try makeSlashTestUserMessage(allocator, "first prompt", 1);
    defer session_manager_mod.deinitMessage(allocator, &first_user);
    _ = try session.session_manager.appendMessage(first_user);

    var assistant = try makeSlashTestAssistantMessage(allocator, "first reply", current_provider.model, 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    _ = try session.session_manager.appendMessage(assistant);

    var second_user = try makeSlashTestUserMessage(allocator, "second prompt", 3);
    defer session_manager_mod.deinitMessage(allocator, &second_user);
    const second_user_id = try session.session_manager.appendMessage(second_user);
    const second_user_id_copy = try allocator.dupe(u8, second_user_id);
    defer allocator.free(second_user_id_copy);

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();
    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);

    try loadForkOverlayOrStatus(allocator, &session, &app_state, &overlay);
    try std.testing.expectEqual(@as(std.meta.Tag(SelectorOverlay), .fork), std.meta.activeTag(overlay.?));
    try std.testing.expectEqual(@as(usize, 2), overlay.?.fork.choices.len);
    try std.testing.expectEqualStrings("second prompt", overlay.?.fork.choices[1].text);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    const subscriber = agent.AgentSubscriber{ .callback = ignoreSlashTestAgentEvent };
    try forkCurrentSessionBeforeUserMessage(
        allocator,
        std.testing.io,
        &session,
        &current_provider,
        session_dir,
        &.{},
        second_user_id_copy,
        &app_state,
        &editor,
        subscriber,
    );

    try std.testing.expectEqualStrings("second prompt", editor.text());
    try std.testing.expectEqualStrings(original_session_file, session.session_manager.header.parent_session.?);
    try std.testing.expect(session.session_manager.getSessionFile() != null);
    try std.testing.expect(!std.mem.eql(u8, original_session_file, session.session_manager.getSessionFile().?));

    const messages = session.agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("first prompt", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("first reply", messages[1].assistant.content[0].text.text);

    var reopened = try session_mod.AgentSession.open(allocator, std.testing.io, .{
        .session_file = session.session_manager.getSessionFile().?,
        .cwd_override = tmp_root,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer reopened.deinit();
    try std.testing.expectEqualStrings(original_session_file, reopened.session_manager.header.parent_session.?);
    try std.testing.expectEqual(@as(usize, 2), reopened.agent.getMessages().len);
}

test "help markdown uses renderer-friendly bullets for commands resources and key shortcuts" {
    const allocator = std.testing.allocator;

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    const commands = [_]HelpSlashCommand{
        .{ .name = "help", .description = "Show slash commands and keyboard shortcuts" },
        .{ .name = "model", .description = "Select model (opens selector UI)" },
    };

    const prompt_templates = [_]resources_mod.PromptTemplate{.{
        .name = @constCast("review"),
        .description = @constCast("Run the review prompt"),
        .argument_hint = @constCast("<scope>"),
        .content = @constCast("Review {args}"),
        .file_path = @constCast("/tmp/review.md"),
        .source_info = .{
            .path = @constCast("/tmp/review.md"),
            .source = @constCast("test"),
            .scope = .temporary,
            .origin = .top_level,
        },
    }};
    const skills = [_]resources_mod.Skill{.{
        .name = @constCast("reviewer"),
        .description = @constCast("Review code"),
        .file_path = @constCast("/tmp/skills/reviewer/SKILL.md"),
        .base_dir = @constCast("/tmp/skills/reviewer"),
        .source_info = .{
            .path = @constCast("/tmp/skills/reviewer/SKILL.md"),
            .source = @constCast("test"),
            .scope = .temporary,
            .origin = .top_level,
        },
    }};
    const markdown = try buildHelpMarkdown(allocator, &commands, &prompt_templates, &skills, true, &keybindings);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Help") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Slash commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "### Built-in") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `/help` — Show slash commands and keyboard shortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `/model` — Select model (opens selector UI)") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "### Prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `/review <scope>` — Run the review prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "### Skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `/skill:reviewer` — Review code") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Keyboard shortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- `Ctrl+L` — Open model selector") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "| Command |") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "| Key |") == null);

    const rendered_markdown = tui.Markdown{ .text = markdown };
    var screen = try tui.test_helpers.renderToScreen(rendered_markdown.drawComponent(), 80, 32);
    defer screen.deinit(allocator);
    const rendered = try tui.test_helpers.screenToString(&screen);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "• /help — Show slash commands and keyboard shortcuts") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "| Command |") == null);
}

test "fork selector reports empty history without opening overlay" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();
    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);

    try loadForkOverlayOrStatus(allocator, &session, &app_state, &overlay);
    try std.testing.expect(overlay == null);
    try std.testing.expectEqualStrings("No messages to fork from", app_state.footer.status);
}

fn makeSlashTestTempPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: ?[]const u8) ![]u8 {
    const relative_path = if (name) |value|
        try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, value })
    else
        try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(relative_path);

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeSlashTestUserMessage(allocator: std.mem.Allocator, text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn makeSlashTestAssistantMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    model: ai.Model,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

test "switchModel shows provider-specific setup guidance when auth is missing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };

    try switchModel(
        allocator,
        &env_map,
        &session,
        &current_provider,
        "openai",
        "gpt-5.4",
        options,
        null,
        &app_state,
    );

    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    try std.testing.expect(std.mem.indexOf(u8, app_state.footer.status, "OPENAI_API_KEY") != null);
    try std.testing.expect(app_state.chat.items.items.len > 1);
    const error_text = app_state.chat.items.items[app_state.chat.items.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, error_text, "OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "/login openai") != null);
}

test "parseGistIdFromOutput extracts gist ID from URL" {
    try std.testing.expectEqualStrings("abc123", parseGistIdFromOutput("https://gist.github.com/user/abc123").?);
    try std.testing.expectEqualStrings("abc123", parseGistIdFromOutput("https://gist.github.com/user/abc123\n").?);
    try std.testing.expectEqualStrings("abc-def_123", parseGistIdFromOutput("https://gist.github.com/user/abc-def_123").?);
    try std.testing.expect(parseGistIdFromOutput("") == null);
    try std.testing.expect(parseGistIdFromOutput("   \n  ") == null);
    // ID with invalid characters should be rejected
    try std.testing.expect(parseGistIdFromOutput("https://gist.github.com/user/abc!def") == null);
}
