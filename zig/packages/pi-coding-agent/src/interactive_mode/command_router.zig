const std = @import("std");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const provider_config = @import("../providers/provider_config.zig");
const session_mod = @import("../sessions/session.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const auth_flow_mod = @import("auth_flow.zig");
const session_lifecycle = @import("session_lifecycle.zig");
const slash_commands = @import("slash_commands.zig");

const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadSessionOverlay = overlays.loadSessionOverlay;
const loadTreeOverlay = overlays.loadTreeOverlay;
const AppState = rendering.AppState;

pub const SlashCommandKind = enum {
    help,
    settings,
    model,
    theme,
    scoped_models,
    import,
    share,
    copy,
    name,
    hotkeys,
    label,
    session,
    changelog,
    tree,
    fork,
    clone,
    compact,
    login,
    logout,
    new,
    @"resume",
    reload,
    @"export",
    quit,
};

pub const SlashCommand = struct {
    kind: SlashCommandKind,
    argument: ?[]const u8 = null,
    raw: []const u8,
};

pub const BuiltinSlashCommand = struct {
    name: []const u8,
    description: []const u8,
    argument_hint: ?[]const u8 = null,
    kind: SlashCommandKind,
    /// Hidden entries participate in parsing and dispatch but are excluded from
    /// the autocomplete matrix, the `/help` listing, and the catalog
    /// "builtins" array. They exist so the table can remain the single source of
    /// truth for every `SlashCommandKind` variant while preserving the historical
    /// behavior of not advertising certain commands in primary UI surfaces.
    hidden: bool = false,
};

pub const BUILTIN_SLASH_COMMANDS = [_]BuiltinSlashCommand{
    .{ .kind = .help, .name = "help", .description = "Show slash commands and keyboard shortcuts" },
    .{ .kind = .settings, .name = "settings", .description = "Open settings menu" },
    .{ .kind = .model, .name = "model", .description = "Select model (opens selector UI)" },
    .{ .kind = .theme, .name = "theme", .description = "Switch color theme", .argument_hint = "[night|day]" },
    .{ .kind = .scoped_models, .name = "scoped-models", .description = "Enable/disable models for Ctrl+P cycling" },
    .{ .kind = .@"export", .name = "export", .description = "Export session (HTML default, or specify path: .html/.jsonl)" },
    .{ .kind = .import, .name = "import", .description = "Import and resume a session from a JSONL file" },
    .{ .kind = .share, .name = "share", .description = "Share session as a secret GitHub gist" },
    .{ .kind = .copy, .name = "copy", .description = "Copy transcript content to clipboard", .argument_hint = "[last|all|visible]" },
    .{ .kind = .name, .name = "name", .description = "Set session display name", .argument_hint = "<name>" },
    .{ .kind = .session, .name = "session", .description = "Show session info and stats" },
    .{ .kind = .changelog, .name = "changelog", .description = "Show changelog entries" },
    .{ .kind = .hotkeys, .name = "hotkeys", .description = "Show all keyboard shortcuts" },
    .{ .kind = .fork, .name = "fork", .description = "Create a new fork from a previous user message" },
    .{ .kind = .clone, .name = "clone", .description = "Duplicate the current session at the current position" },
    .{ .kind = .tree, .name = "tree", .description = "Navigate session tree (switch branches)" },
    .{ .kind = .login, .name = "login", .description = "Configure provider authentication" },
    .{ .kind = .logout, .name = "logout", .description = "Remove provider authentication" },
    .{ .kind = .new, .name = "new", .description = "Start a new session" },
    .{ .kind = .compact, .name = "compact", .description = "Manually compact the session context" },
    .{ .kind = .@"resume", .name = "resume", .description = "Resume a different session" },
    .{ .kind = .reload, .name = "reload", .description = "Reload keybindings, extensions, skills, prompts, and themes" },
    .{ .kind = .quit, .name = "quit", .description = "Quit pi" },
    // Hidden: dispatched via the parser/router but not advertised in autocomplete or /help.
    .{ .kind = .label, .name = "label", .description = "Label the current session entry", .hidden = true },
};

comptime {
    // Guarantee every SlashCommandKind variant appears in BUILTIN_SLASH_COMMANDS
    // exactly once. Prevents drift between the enum and the table.
    const fields = @typeInfo(SlashCommandKind).@"enum".fields;
    var seen = [_]bool{false} ** fields.len;
    for (BUILTIN_SLASH_COMMANDS) |entry| {
        const idx = @intFromEnum(entry.kind);
        if (seen[idx]) @compileError("duplicate BUILTIN_SLASH_COMMANDS entry for kind " ++ @tagName(entry.kind));
        seen[idx] = true;
    }
    for (fields, 0..) |field, idx| {
        if (!seen[idx]) @compileError("missing BUILTIN_SLASH_COMMANDS entry for SlashCommandKind." ++ field.name);
    }
}

const VISIBLE_BUILTIN_SLASH_COMMANDS_COUNT = blk: {
    var count: usize = 0;
    for (BUILTIN_SLASH_COMMANDS) |entry| {
        if (!entry.hidden) count += 1;
    }
    break :blk count;
};

/// Subset of BUILTIN_SLASH_COMMANDS without `.hidden` entries, in declaration
/// order. Used by autocomplete, `/help`, and the "builtins"
/// array so hidden commands stay reachable via the parser without appearing in
/// primary UI surfaces.
pub const VISIBLE_BUILTIN_SLASH_COMMANDS: [VISIBLE_BUILTIN_SLASH_COMMANDS_COUNT]BuiltinSlashCommand = blk: {
    var visible: [VISIBLE_BUILTIN_SLASH_COMMANDS_COUNT]BuiltinSlashCommand = undefined;
    var idx: usize = 0;
    for (BUILTIN_SLASH_COMMANDS) |entry| {
        if (entry.hidden) continue;
        visible[idx] = entry;
        idx += 1;
    }
    break :blk visible;
};

const SLASH_COMMAND_NAME_MAP = blk: {
    const KV = struct { []const u8, SlashCommandKind };
    var entries: [BUILTIN_SLASH_COMMANDS.len]KV = undefined;
    for (BUILTIN_SLASH_COMMANDS, 0..) |entry, i| {
        entries[i] = .{ entry.name, entry.kind };
    }
    break :blk std.StaticStringMap(SlashCommandKind).initComptime(entries);
};

pub fn parseSlashCommand(text: []const u8) ?SlashCommand {
    if (text.len < 2 or text[0] != '/') return null;

    const space_index = std.mem.indexOfAny(u8, text, " \t\r\n");
    const command_name = if (space_index) |index| text[1..index] else text[1..];
    const raw_argument = if (space_index) |index|
        std.mem.trim(u8, text[index + 1 ..], " \t\r\n")
    else
        "";
    const argument = if (raw_argument.len == 0) null else raw_argument;

    const kind = SLASH_COMMAND_NAME_MAP.get(command_name) orelse return null;
    return .{ .kind = kind, .argument = argument, .raw = text };
}

pub fn handleSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    command: SlashCommand,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (try handleImmediateSlashCommand(
        allocator,
        io,
        env_map,
        command,
        session,
        current_provider,
        options,
        app_state,
        overlay,
        live_resources,
    )) return;

    switch (command.kind) {
        .help, .settings, .model, .theme, .scoped_models, .share, .copy, .name, .hotkeys, .label, .session, .changelog => unreachable,
        .import => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before importing a session")) return;
            try slash_commands.handleImportSlashCommand(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                command.argument,
                options,
                live_resources.runtime_config,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .tree => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before opening the session tree")) return;
            overlay.* = try loadTreeOverlay(allocator, session);
        },
        .fork => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before forking the session")) return;
            try session_lifecycle.loadForkOverlayOrStatus(allocator, session, app_state, overlay);
        },
        .clone => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before cloning the session")) return;
            try session_lifecycle.cloneCurrentSession(
                allocator,
                io,
                session,
                current_provider,
                session_dir,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .compact => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before compacting the session")) return;
            try slash_commands.handleCompactSlashCommand(allocator, session, command.argument, app_state);
        },
        .login => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before logging in")) return;
            try auth_flow_mod.handleLoginSlashCommand(
                allocator,
                io,
                env_map,
                command.argument,
                app_state,
                overlay,
                auth_flow,
            );
        },
        .logout => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before logging out")) return;
            try auth_flow_mod.handleLogoutSlashCommand(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                command.argument,
                options,
                app_state,
                overlay,
                live_resources,
            );
        },
        .new => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before starting a new session")) return;
            try session_lifecycle.handleNewSlashCommand(
                allocator,
                io,
                session,
                current_provider,
                session_dir,
                options,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .@"resume" => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before switching sessions")) return;
            overlay.* = try loadSessionOverlay(allocator, io, session_dir, session.session_manager.getSessionFile());
        },
        .reload => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before reloading resources")) return;
            try slash_commands.handleReloadSlashCommand(allocator, io, env_map, options.cwd, session, app_state, live_resources);
        },
        .@"export" => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before exporting the session")) return;
            try slash_commands.handleExportSlashCommand(allocator, io, session, command.argument, app_state);
        },
        .quit => {
            should_exit.* = true;
            if (prompt_worker_active.*) session.agent.abort();
        },
    }
}

fn handleImmediateSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    command: SlashCommand,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !bool {
    switch (command.kind) {
        .help => {
            const help_commands = try allocator.alloc(slash_commands.HelpSlashCommand, VISIBLE_BUILTIN_SLASH_COMMANDS.len);
            defer allocator.free(help_commands);
            for (VISIBLE_BUILTIN_SLASH_COMMANDS, 0..) |builtin, index| {
                help_commands[index] = .{
                    .name = builtin.name,
                    .description = builtin.description,
                    .argument_hint = builtin.argument_hint,
                };
            }
            try slash_commands.handleHelpSlashCommand(
                allocator,
                app_state,
                help_commands,
                live_resources.prompt_templates,
                live_resources.skills,
                if (live_resources.runtime_config) |runtime_config| runtime_config.enableSkillCommands() else true,
                live_resources.keybindings,
            );
        },
        .settings => try slash_commands.handleSettingsSlashCommand(allocator, io, env_map, session, command.argument, options, app_state, overlay, live_resources),
        .model => try slash_commands.handleModelSlashCommand(allocator, env_map, session, current_provider, command.argument, options, live_resources.runtime_config, app_state, overlay),
        .theme => try slash_commands.handleThemeSlashCommand(allocator, io, env_map, options.cwd, command.argument, app_state, overlay, live_resources),
        .scoped_models => try slash_commands.handleScopedModelsSlashCommand(allocator, env_map, session, current_provider, options, live_resources.runtime_config, app_state, overlay),
        .share => try slash_commands.handleShareSlashCommand(allocator, io, env_map, session, app_state),
        .copy => try slash_commands.handleCopySlashCommand(allocator, io, session, app_state, command.argument),
        .name => try slash_commands.handleNameSlashCommand(allocator, session, command.argument, app_state),
        .hotkeys => try slash_commands.handleHotkeysSlashCommand(allocator, app_state, live_resources.keybindings),
        .label => try slash_commands.handleLabelSlashCommand(allocator, session, command.argument, app_state),
        .session => try slash_commands.handleSessionSlashCommand(allocator, session, app_state),
        .changelog => try slash_commands.handleChangelogSlashCommand(allocator, io, session, command.argument, app_state),
        else => return false,
    }
    return true;
}

fn blockDuringActivePrompt(prompt_worker_active: *const bool, app_state: *AppState, status: []const u8) !bool {
    if (!prompt_worker_active.*) return false;
    try app_state.setStatus(status);
    return true;
}

test "built-in slash command autocomplete matrix keeps help before TypeScript order" {
    const expected = [_][]const u8{
        "help",
        "settings",
        "model",
        "theme",
        "scoped-models",
        "export",
        "import",
        "share",
        "copy",
        "name",
        "session",
        "changelog",
        "hotkeys",
        "fork",
        "clone",
        "tree",
        "login",
        "logout",
        "new",
        "compact",
        "resume",
        "reload",
        "quit",
    };

    try std.testing.expectEqual(expected.len, VISIBLE_BUILTIN_SLASH_COMMANDS.len);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, VISIBLE_BUILTIN_SLASH_COMMANDS[index].name);
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "/{s}", .{name});
        try std.testing.expect(parseSlashCommand(text) != null);
    }
    // Hidden entries are dispatched by the parser but excluded from the visible matrix.
    try std.testing.expect(parseSlashCommand("/label bookmark") != null);
}
