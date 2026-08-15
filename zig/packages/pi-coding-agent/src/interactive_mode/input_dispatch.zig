const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const auth = @import("../auth/auth.zig");
const tui = @import("tui");
const config_mod = @import("../config/config.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const prompt_worker_mod = @import("prompt_worker.zig");
const slash_commands = @import("slash_commands.zig");
const command_router = @import("command_router.zig");
const input_resolution = @import("input_resolution.zig");
const overlay_input = @import("overlay_input.zig");
const auth_flow_mod = @import("auth_flow.zig");
const session_lifecycle = @import("session_lifecycle.zig");
const extension_dialog = @import("extension_dialog.zig");
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadSessionOverlay = overlays.loadSessionOverlay;
const loadModelOverlay = overlays.loadModelOverlay;
const loadSelectableModels = overlays.loadSelectableModels;
const loadTreeOverlay = overlays.loadTreeOverlay;
const AppState = rendering.AppState;
const PromptWorker = prompt_worker_mod.PromptWorker;
const parseSlashCommand = command_router.parseSlashCommand;
const handleSlashCommand = command_router.handleSlashCommand;
const saveSettingsEditorOverlay = slash_commands.saveSettingsEditorOverlay;
const handleSettingsOverlayKey = slash_commands.handleSettingsOverlayKey;
const switchSession = session_lifecycle.switchSession;
const switchModel = slash_commands.switchModel;
const handleNewSlashCommand = session_lifecycle.handleNewSlashCommand;
const loadForkOverlayOrStatus = session_lifecycle.loadForkOverlayOrStatus;
const forkCurrentSessionBeforeUserMessage = session_lifecycle.forkCurrentSessionBeforeUserMessage;
const applyThemeByName = slash_commands.applyThemeByName;
const navigateTree = session_lifecycle.navigateTree;
const beginLoginFlow = auth_flow_mod.beginLoginFlow;
const logoutProviderById = auth_flow_mod.logoutProviderById;
const cancelAuthFlow = auth_flow_mod.cancelAuthFlow;
const submitAuthFlowInput = auth_flow_mod.submitAuthFlowInput;
const BUILTIN_SLASH_COMMANDS = command_router.VISIBLE_BUILTIN_SLASH_COMMANDS;
const AppContext = shared.AppContext;
const ResolvedInputKey = input_resolution.ResolvedInputKey;

pub fn handleInputKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    var app_context = AppContext.init(options.cwd, io);
    try handleInputKeyWithModifiers(
        allocator,
        io,
        env_map,
        key,
        .{},
        session,
        current_provider,
        session_dir,
        options,
        tool_items,
        app_state,
        editor,
        overlay,
        auth_flow,
        prompt_worker,
        prompt_worker_active,
        subscriber,
        should_exit,
        &app_context,
        live_resources,
    );
}

pub fn handleInputKeyWithModifiers(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    app_context: *AppContext,
    live_resources: *LiveResources,
) !void {
    if (overlay.* != null) {
        try handleOverlayInput(
            allocator,
            io,
            env_map,
            key,
            modifiers,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            editor,
            overlay,
            auth_flow,
            prompt_worker_active,
            subscriber,
            should_exit,
            app_context,
            live_resources,
        );
        return;
    }

    if (auth_flow.* != null) {
        try handleAuthFlowInput(
            allocator,
            io,
            env_map,
            key,
            modifiers,
            session,
            current_provider,
            options,
            app_state,
            editor,
            auth_flow,
            prompt_worker_active,
            should_exit,
            live_resources,
        );
        return;
    }

    try handleNormalInput(
        allocator,
        io,
        env_map,
        key,
        modifiers,
        session,
        current_provider,
        session_dir,
        options,
        tool_items,
        app_state,
        editor,
        overlay,
        auth_flow,
        prompt_worker,
        prompt_worker_active,
        subscriber,
        should_exit,
        app_context,
        live_resources,
    );
}

fn handleOverlayInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    app_context: *AppContext,
    live_resources: *LiveResources,
) !void {
    var overlay_value = &overlay.*.?;

    if (resolveParsedAppAction(live_resources.keybindings, key, modifiers)) |action| {
        if (action == .exit) {
            should_exit.* = true;
            if (prompt_worker_active.*) { _ = session.agent.abort(); }
            return;
        }
    }

    if (std.meta.activeTag(overlay_value.*) == .settings_editor) {
        switch (key) {
            .escape => {
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
            .ctrl => |ctrl| {
                if (ctrl == 's') {
                    try saveSettingsEditorOverlay(
                        allocator,
                        io,
                        env_map,
                        session,
                        options,
                        app_state,
                        editor,
                        overlay,
                        live_resources,
                    );
                    return;
                }
            },
            else => {},
        }

        _ = try overlay_value.settings_editor.editor.handleKey(key);
        return;
    }

    if (std.meta.activeTag(overlay_value.*) == .settings) {
        try handleSettingsOverlayKey(
            allocator,
            io,
            env_map,
            key,
            session,
            options,
            app_state,
            editor,
            overlay,
            live_resources,
        );
        return;
    }

    if (std.meta.activeTag(overlay_value.*) == .model) {
        if (try overlay_input.handleModelOverlayInteractiveKey(allocator, key, modifiers, &overlay_value.model, live_resources.keybindings)) {
            return;
        }
    }

    if (std.meta.activeTag(overlay_value.*) == .session) {
        if (try overlay_input.handleSessionOverlayInteractiveKey(
            allocator,
            io,
            key,
            modifiers,
            &overlay_value.session,
            live_resources.keybindings,
            app_state,
        )) {
            return;
        }
    }

    if (std.meta.activeTag(overlay_value.*) == .scoped_models) {
        try overlay_input.handleScopedModelsOverlayKey(
            allocator,
            io,
            key,
            modifiers,
            &overlay_value.scoped_models,
            app_state,
            live_resources.runtime_config,
            live_resources.keybindings,
            overlay,
        );
        return;
    }

    if (std.meta.activeTag(overlay_value.*) == .tree) {
        if (try overlay_input.handleTreeOverlayInteractiveKey(
            allocator,
            key,
            modifiers,
            &overlay_value.tree,
            session,
            app_state,
            editor,
            live_resources.runtime_config,
            live_resources.keybindings,
            overlay,
        )) {
            return;
        }
    }

    if (std.meta.activeTag(overlay_value.*) == .extension_dialog) {
        if (resolveParsedAppAction(live_resources.keybindings, key, modifiers)) |action| {
            if (action == .tools_expand) {
                try handleAppAction(
                    allocator,
                    io,
                    env_map,
                    action,
                    session,
                    current_provider,
                    session_dir,
                    options,
                    live_resources.runtime_config,
                    app_state,
                    overlay,
                    editor,
                    prompt_worker_active,
                    tool_items,
                    subscriber,
                    should_exit,
                    app_context,
                );
                return;
            }
        }
        try extension_dialog.handleDialogKey(
            allocator,
            &overlay_value.extension_dialog,
            key,
            modifiers,
            live_resources.keybindings,
        );
        return;
    }

    switch (key) {
        .escape => {
            overlay_value.deinit(allocator);
            overlay.* = null;
            return;
        },
        else => {},
    }

    const overlay_list = switch (overlay_value.*) {
        .info => &overlay_value.info.list,
        .settings => &overlay_value.settings.list,
        .session => &overlay_value.session.list,
        .model => &overlay_value.model.list,
        .scoped_models => &overlay_value.scoped_models.list,
        .theme => &overlay_value.theme.list,
        .tree => &overlay_value.tree.list,
        .fork => &overlay_value.fork.list,
        .auth => &overlay_value.auth.list,
        .extension_dialog => unreachable,
        else => unreachable,
    };
    const result = overlay_list.handleKey(key);
    switch (result) {
        .handled, .ignored => return,
        .dismissed => {
            overlay_value.deinit(allocator);
            overlay.* = null;
            return;
        },
        .confirmed => |index| {
            switch (overlay_value.*) {
                .info => {},
                .session => |session_overlay| {
                    if (session_overlay.choices[index].path.len == 0) {
                        try app_state.setStatus("No sessions found");
                        overlay_value.deinit(allocator);
                        overlay.* = null;
                        return;
                    }
                    try switchSession(
                        allocator,
                        io,
                        env_map,
                        session,
                        current_provider,
                        session_overlay.choices[index].path,
                        options,
                        live_resources.runtime_config,
                        tool_items,
                        app_state,
                        subscriber,
                    );
                },
                .model => |model_overlay| {
                    if (index >= model_overlay.choices.len or
                        model_overlay.choices[index].provider.len == 0 or
                        model_overlay.choices[index].model_id.len == 0)
                    {
                        try app_state.setStatus("No matching models");
                        overlay_value.deinit(allocator);
                        overlay.* = null;
                        return;
                    }
                    try switchModel(
                        allocator,
                        env_map,
                        session,
                        current_provider,
                        model_overlay.choices[index].provider,
                        model_overlay.choices[index].model_id,
                        options,
                        live_resources.runtime_config,
                        app_state,
                    );
                },
                .theme => |theme_overlay| {
                    try applyThemeByName(
                        allocator,
                        io,
                        env_map,
                        options.cwd,
                        theme_overlay.choices[index].name,
                        app_state,
                        live_resources,
                    );
                },
                .tree => |tree_overlay| {
                    if (tree_overlay.choices[index].entry_id.len == 0) {
                        try app_state.setStatus("No tree entries available");
                    } else {
                        try navigateTree(allocator, session, tree_overlay.choices[index].entry_id, app_state, editor, .{});
                    }
                },
                .fork => |fork_overlay| {
                    if (fork_overlay.choices[index].entry_id.len == 0) {
                        try app_state.setStatus("No messages to fork from");
                    } else {
                        try forkCurrentSessionBeforeUserMessage(
                            allocator,
                            io,
                            session,
                            current_provider,
                            session_dir,
                            tool_items,
                            fork_overlay.choices[index].entry_id,
                            app_state,
                            editor,
                            subscriber,
                        );
                    }
                },
                .auth => |auth_overlay| switch (auth_overlay.mode) {
                    .login => try beginLoginFlow(
                        allocator,
                        io,
                        env_map,
                        auth_overlay.choices[index].provider_id,
                        auth_overlay.choices[index].auth_type,
                        app_state,
                        auth_flow,
                    ),
                    .logout => try logoutProviderById(
                        allocator,
                        io,
                        env_map,
                        session,
                        current_provider,
                        auth_overlay.choices[index].provider_id,
                        options,
                        app_state,
                        live_resources,
                    ),
                },
                .extension_dialog => unreachable,
                else => unreachable,
            }
            overlay_value.deinit(allocator);
            overlay.* = null;
            return;
        },
    }
}

fn handleAuthFlowInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    auth_flow: *?AuthFlow,
    prompt_worker_active: *bool,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (resolveParsedAppAction(live_resources.keybindings, key, modifiers)) |action| {
        if (action == .exit) {
            should_exit.* = true;
            if (prompt_worker_active.*) { _ = session.agent.abort(); }
            return;
        }
    }

    switch (key) {
        .escape => {
            cancelAuthFlow(allocator, auth_flow, app_state) catch {};
            clearEditor(app_state, editor);
            return;
        },
        .enter => {
            if (editor.isShowingAutocomplete()) {
                _ = try editor.handleKey(key);
                return;
            }
            const expanded_text = try editor.expandedTextAlloc(allocator);
            defer allocator.free(expanded_text);
            const trimmed = std.mem.trim(u8, expanded_text, " \t\r\n");
            submitAuthFlowInput(
                allocator,
                io,
                env_map,
                trimmed,
                session,
                current_provider,
                options,
                app_state,
                editor,
                auth_flow,
                live_resources,
            ) catch |err| {
                const auth_message = try auth.formatAuthenticationError(allocator, err);
                defer if (auth_message) |formatted| allocator.free(formatted);
                const message = try std.fmt.allocPrint(
                    allocator,
                    "Authentication failed: {s}",
                    .{if (auth_message) |formatted| formatted else @errorName(err)},
                );
                defer allocator.free(message);
                try app_state.appendError(message);
            };
            return;
        },
        else => {},
    }

    const handled_auth = try editor.handleKey(key);
    switch (handled_auth) {
        .exit => {
            should_exit.* = true;
            if (prompt_worker_active.*) { _ = session.agent.abort(); }
        },
        else => {},
    }
}

fn handleNormalInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    app_context: *AppContext,
    live_resources: *LiveResources,
) !void {
    if (editor.isShowingAutocomplete()) {
        switch (input_resolution.resolveInputKey(live_resources.keybindings, key, modifiers, .autocomplete)) {
            .editor_action => |editor_action| {
                try handleEditorAction(
                    allocator,
                    io,
                    env_map,
                    editor_action,
                    session,
                    current_provider,
                    session_dir,
                    options,
                    tool_items,
                    app_state,
                    editor,
                    overlay,
                    auth_flow,
                    prompt_worker,
                    prompt_worker_active,
                    subscriber,
                    should_exit,
                    live_resources,
                );
                return;
            },
            .suppress_legacy_editor_default => return,
            .pass_to_editor => {},
            .app_action, .submit_enter, .suppress_legacy_app_default => unreachable,
        }
    }

    if (key == .escape and editor.isShowingAutocomplete()) {
        _ = try editor.handleKey(key);
        return;
    }

    try executeResolvedInputKey(
        allocator,
        io,
        env_map,
        input_resolution.resolveInputKey(live_resources.keybindings, key, modifiers, .normal),
        key,
        session,
        current_provider,
        session_dir,
        options,
        tool_items,
        app_state,
        editor,
        overlay,
        auth_flow,
        prompt_worker,
        prompt_worker_active,
        subscriber,
        should_exit,
        app_context,
        live_resources,
    );
}

fn executeResolvedInputKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    resolved: ResolvedInputKey,
    key: tui.Key,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    app_context: *AppContext,
    live_resources: *LiveResources,
) !void {
    switch (resolved) {
        .app_action => |action| {
            if (action == .clipboard_pasteImage) {
                try handlePasteImageAction(allocator, io, env_map, app_state);
                return;
            }
            try handleAppAction(
                allocator,
                io,
                env_map,
                action,
                session,
                current_provider,
                session_dir,
                options,
                live_resources.runtime_config,
                app_state,
                overlay,
                editor,
                prompt_worker_active,
                tool_items,
                subscriber,
                should_exit,
                app_context,
            );
        },
        .editor_action => |editor_action| try handleEditorAction(
            allocator,
            io,
            env_map,
            editor_action,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            editor,
            overlay,
            auth_flow,
            prompt_worker,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        ),
        .submit_enter => try submitEditorIfNotEmpty(
            allocator,
            io,
            env_map,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            editor,
            overlay,
            auth_flow,
            prompt_worker,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        ),
        .suppress_legacy_app_default,
        .suppress_legacy_editor_default,
        => return,
        .pass_to_editor => {
            const handled = try editor.handleKey(key);
            switch (handled) {
                .interrupt => try handleInterruptAction(
                    allocator,
                    session,
                    app_state,
                    editor,
                    overlay,
                    prompt_worker_active,
                    live_resources.runtime_config,
                ),
                .exit => {
                    should_exit.* = true;
                    if (prompt_worker_active.*) { _ = session.agent.abort(); }
                },
                else => {},
            }
        },
    }
}

fn effectiveScopedModelPatterns(
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

pub fn submitEditorText(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    trimmed: []const u8,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (parseBashShortcut(trimmed)) |bash_shortcut| {
        if (bash_shortcut.command.len == 0) return;
        if (prompt_worker_active.*) {
            try app_state.setStatus("wait for the current response to finish before running bash");
            return;
        }
        if (app_state.isBashExecutionActive()) {
            try app_state.setStatus("A bash command is already running. Press Esc to cancel it first.");
            return;
        }
        session.emitUserBashEvent(bash_shortcut.command, bash_shortcut.exclude_from_context) catch {};
        if (!(try app_state.startBashExecution(allocator, session, bash_shortcut.command, bash_shortcut.exclude_from_context))) {
            try app_state.setStatus("A bash command is already running. Press Esc to cancel it first.");
            return;
        }
        try editor.addToHistory(trimmed);
        clearEditor(app_state, editor);
        return;
    }

    if (parseSlashCommand(trimmed)) |command| {
        if (selectorSlashBlockStatus(command.kind)) |status| {
            if (selectorInteractionBlocked(session, prompt_worker_active)) {
                try app_state.setStatus(status);
                return;
            }
        }
        try handleSlashCommand(
            allocator,
            io,
            env_map,
            command,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            overlay,
            auth_flow,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        );
        clearEditor(app_state, editor);
        return;
    }

    const skill_expanded = try resources_mod.expandSkillCommand(allocator, io, trimmed, live_resources.skills);
    defer allocator.free(skill_expanded);
    const expanded = try resources_mod.expandPromptTemplate(allocator, skill_expanded, live_resources.prompt_templates);
    defer allocator.free(expanded);

    if (trimmed.len > 0 and trimmed[0] == '/' and
        std.mem.eql(u8, skill_expanded, trimmed) and
        std.mem.eql(u8, expanded, trimmed))
    {
        if (try live_resources.dispatchExtensionCommand(trimmed)) {
            clearEditor(app_state, editor);
            try app_state.setStatus("extension command dispatched");
            return;
        }
        const message = try std.fmt.allocPrint(allocator, "Unknown slash command: {s}", .{trimmed});
        defer allocator.free(message);
        clearEditor(app_state, editor);
        try app_state.appendError(message);
        return;
    }

    if (prompt_worker_active.*) {
        if (session.isStreaming() or session.isCompacting() or session.isRetrying()) {
            try queueEditorText(
                allocator,
                io,
                trimmed,
                session,
                app_state,
                editor,
                .steering,
                if (session.isCompacting())
                    "queued steering message for after compaction"
                else if (session.isRetrying())
                    "queued steering message for after retry"
                else
                    "queued steering message",
                live_resources.prompt_templates,
                live_resources.skills,
            );
            return;
        }
        try app_state.setStatus("response in progress");
        return;
    }

    const prompt_images = try app_state.clonePendingEditorImages(allocator);
    defer prompt_worker_mod.deinitImageContents(allocator, prompt_images);

    try prompt_worker.start(allocator, session, app_state, expanded, prompt_images);
    prompt_worker_active.* = true;
    app_state.setToolOutputExpanded(false);
    try editor.addToHistory(trimmed);
    clearEditor(app_state, editor);
    try app_state.setStatus("thinking");
}

fn selectorInteractionBlocked(session: *const session_mod.AgentSession, prompt_worker_active: *const bool) bool {
    return prompt_worker_active.* or session.isStreaming() or session.isCompacting() or session.isRetrying();
}

fn selectorSlashBlockStatus(kind: command_router.SlashCommandKind) ?[]const u8 {
    return switch (kind) {
        .settings => "wait for the current response to finish before opening settings",
        .model => "wait for the current response to finish before switching models",
        .tree => "wait for the current response to finish before opening the session tree",
        .@"resume" => "wait for the current response to finish before switching sessions",
        else => null,
    };
}

const BashShortcut = struct {
    command: []const u8,
    exclude_from_context: bool,
};

fn parseBashShortcut(trimmed: []const u8) ?BashShortcut {
    if (trimmed.len == 0 or trimmed[0] != '!') return null;
    if (std.mem.startsWith(u8, trimmed, "!!")) {
        return .{
            .command = std.mem.trim(u8, trimmed[2..], " \t\r\n"),
            .exclude_from_context = true,
        };
    }
    return .{
        .command = std.mem.trim(u8, trimmed[1..], " \t\r\n"),
        .exclude_from_context = false,
    };
}

fn queueEditorText(
    allocator: std.mem.Allocator,
    io: std.Io,
    trimmed: []const u8,
    session: *session_mod.AgentSession,
    app_state: *AppState,
    editor: *tui.Editor,
    mode: rendering.QueueDisplayMode,
    status_text: []const u8,
    prompt_templates: []const resources_mod.PromptTemplate,
    skills: []const resources_mod.Skill,
) !void {
    const skill_expanded = try resources_mod.expandSkillCommand(allocator, io, trimmed, skills);
    defer allocator.free(skill_expanded);
    const expanded = try resources_mod.expandPromptTemplate(allocator, skill_expanded, prompt_templates);
    defer allocator.free(expanded);

    const prompt_images = try app_state.clonePendingEditorImages(allocator);
    defer prompt_worker_mod.deinitImageContents(allocator, prompt_images);

    switch (mode) {
        .steering => try session.steer(expanded, prompt_images),
        .follow_up => try session.followUp(expanded, prompt_images),
    }

    try editor.addToHistory(trimmed);
    try app_state.appendQueuedMessage(mode, expanded);
    clearEditor(app_state, editor);
    try app_state.setStatus(status_text);
}

fn handleFollowUpAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (editor.isShowingAutocomplete()) {
        _ = try editor.handleKey(.enter);
        return;
    }

    const expanded_text = try editor.expandedTextAlloc(allocator);
    defer allocator.free(expanded_text);
    const trimmed = std.mem.trim(u8, expanded_text, " \t\r\n");
    if (trimmed.len == 0) return;

    if (parseSlashCommand(trimmed) != null or trimmed[0] == '/') {
        try submitEditorText(
            allocator,
            io,
            env_map,
            trimmed,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            editor,
            overlay,
            auth_flow,
            prompt_worker,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        );
        return;
    }

    if (prompt_worker_active.* and (session.isStreaming() or session.isCompacting() or session.isRetrying())) {
        try queueEditorText(
            allocator,
            io,
            trimmed,
            session,
            app_state,
            editor,
            .follow_up,
            if (session.isCompacting())
                "queued follow-up for after compaction"
            else if (session.isRetrying())
                "queued follow-up for after retry"
            else
                "queued follow-up message",
            live_resources.prompt_templates,
            live_resources.skills,
        );
        return;
    }

    try submitEditorText(
        allocator,
        io,
        env_map,
        trimmed,
        session,
        current_provider,
        session_dir,
        options,
        tool_items,
        app_state,
        editor,
        overlay,
        auth_flow,
        prompt_worker,
        prompt_worker_active,
        subscriber,
        should_exit,
        live_resources,
    );
}

fn handleDequeueAction(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    app_state: *AppState,
    editor: *tui.Editor,
) !void {
    var cleared = try session.clearQueue(allocator);
    defer cleared.deinit(allocator);

    if (cleared.count() == 0) {
        try app_state.setStatus("No queued messages to restore");
        return;
    }

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var appended_any = false;
    for (cleared.steering) |queued| {
        if (queued.text.len > 0) {
            if (appended_any) try builder.appendSlice(allocator, "\n\n");
            try builder.appendSlice(allocator, queued.text);
            appended_any = true;
        }
        for (queued.images) |image| {
            try app_state.appendPendingEditorImage(.{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            });
        }
    }
    for (cleared.follow_up) |queued| {
        if (queued.text.len > 0) {
            if (appended_any) try builder.appendSlice(allocator, "\n\n");
            try builder.appendSlice(allocator, queued.text);
            appended_any = true;
        }
        for (queued.images) |image| {
            try app_state.appendPendingEditorImage(.{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            });
        }
    }

    const current_text = editor.text();
    if (current_text.len > 0) {
        if (appended_any) try builder.appendSlice(allocator, "\n\n");
        try builder.appendSlice(allocator, current_text);
    }

    editor.reset();
    _ = try editor.handlePaste(builder.items);
    app_state.clearQueuedMessages();
    const message = try std.fmt.allocPrint(
        allocator,
        "Restored {d} queued message{s} to the editor",
        .{ cleared.count(), if (cleared.count() == 1) "" else "s" },
    );
    defer allocator.free(message);
    try app_state.setStatus(message);
}

fn handlePasteImageAction(
    _: std.mem.Allocator,
    _: std.Io,
    env_map: *const std.process.Environ.Map,
    app_state: *AppState,
) !void {
    try app_state.startClipboardPaste(env_map);
}

pub fn clearEditor(app_state: *AppState, editor: *tui.Editor) void {
    editor.reset();
    app_state.clearPendingEditorImages();
}

pub fn loadEditorAutocompleteItems(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]tui.SelectItem {
    return loadEditorAutocompleteItemsWithResources(allocator, io, cwd, &.{}, &.{}, false);
}

pub fn loadEditorAutocompleteItemsWithResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    prompt_templates: []const resources_mod.PromptTemplate,
    skills: []const resources_mod.Skill,
    enable_skill_commands: bool,
) ![]tui.SelectItem {
    var dir = try std.Io.Dir.openDirAbsolute(io, cwd, .{ .iterate = true });
    defer dir.close(io);

    var items = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        freeOwnedSelectItems(allocator, items.items);
        items.deinit(allocator);
    }

    for (BUILTIN_SLASH_COMMANDS) |command| {
        const value = if (command.argument_hint != null)
            try std.fmt.allocPrint(allocator, "/{s} ", .{command.name})
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
        errdefer allocator.free(value);
        const label = if (command.argument_hint) |argument_hint|
            try std.fmt.allocPrint(allocator, "/{s} {s}", .{ command.name, argument_hint })
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, command.description);
        errdefer allocator.free(description);

        try items.append(allocator, .{
            .value = value,
            .label = label,
            .description = description,
        });
    }

    for (prompt_templates) |template| {
        const value = try std.fmt.allocPrint(allocator, "/{s} ", .{template.name});
        errdefer allocator.free(value);
        const label = if (template.argument_hint) |argument_hint|
            try std.fmt.allocPrint(allocator, "/{s} {s}", .{ template.name, argument_hint })
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{template.name});
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, template.description);
        errdefer allocator.free(description);

        try items.append(allocator, .{
            .value = value,
            .label = label,
            .description = description,
        });
    }

    if (enable_skill_commands) {
        for (skills) |skill| {
            const value = try std.fmt.allocPrint(allocator, "/skill:{s} ", .{skill.name});
            errdefer allocator.free(value);
            const label = try std.fmt.allocPrint(allocator, "/skill:{s}", .{skill.name});
            errdefer allocator.free(label);
            const description = try allocator.dupe(u8, skill.description);
            errdefer allocator.free(description);

            try items.append(allocator, .{
                .value = value,
                .label = label,
                .description = description,
            });
        }
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        const is_directory = entry.kind == .directory;
        const display = if (is_directory)
            try std.fmt.allocPrint(allocator, "{s}/", .{entry.name})
        else
            try allocator.dupe(u8, entry.name);
        errdefer allocator.free(display);
        const label = try allocator.dupe(u8, display);
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, if (is_directory) "directory" else "file");
        errdefer allocator.free(description);

        try items.append(allocator, .{
            .value = display,
            .label = label,
            .description = description,
        });
    }

    std.mem.sort(tui.SelectItem, items.items, {}, struct {
        fn lessThan(_: void, lhs: tui.SelectItem, rhs: tui.SelectItem) bool {
            const lhs_slash = std.mem.startsWith(u8, lhs.value, "/");
            const rhs_slash = std.mem.startsWith(u8, rhs.value, "/");
            if (lhs_slash != rhs_slash) return lhs_slash;
            const lhs_dir = std.mem.endsWith(u8, lhs.value, "/");
            const rhs_dir = std.mem.endsWith(u8, rhs.value, "/");
            if (lhs_dir != rhs_dir) return lhs_dir;
            return std.mem.order(u8, lhs.label, rhs.label) == .lt;
        }
    }.lessThan);

    return try items.toOwnedSlice(allocator);
}

pub const freeOwnedSelectItems = @import("overlay_table.zig").freeOwnedSelectItems;

pub fn pollForInput() !bool {
    if (@import("builtin").os.tag == .windows) {
        const stdin_handle = std.Io.File.stdin().handle;
        const timeout: std.os.windows.LARGE_INTEGER = -@as(i64, 50) * 10000; // 50ms
        const status = std.os.windows.ntdll.NtWaitForSingleObject(stdin_handle, .FALSE, &timeout);
        return status == .SUCCESS;
    }
    var fds = [_]std.posix.pollfd{
        .{
            .fd = 0,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return (try std.posix.poll(fds[0..], 50)) > 0;
}

const InputDispatchEventContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    app_context: *AppContext,
    live_resources: *LiveResources,
};

pub fn dispatchInputEvent(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    parsed: tui.keys.ParsedInput,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    input_buffer: *std.ArrayList(u8),
    app_context: *AppContext,
    live_resources: *LiveResources,
) !void {
    var context = InputDispatchEventContext{
        .allocator = allocator,
        .io = io,
        .env_map = env_map,
        .session = session,
        .current_provider = current_provider,
        .session_dir = session_dir,
        .options = options,
        .tool_items = tool_items,
        .app_state = app_state,
        .editor = editor,
        .overlay = overlay,
        .auth_flow = auth_flow,
        .prompt_worker = prompt_worker,
        .prompt_worker_active = prompt_worker_active,
        .subscriber = subscriber,
        .should_exit = should_exit,
        .app_context = app_context,
        .live_resources = live_resources,
    };

    switch (parsed.event) {
        .key => |key| try dispatchKeyInputEvent(&context, parsed, key),
        .paste => |content| try dispatchPasteInputEvent(&context, content),
        .protocol => |protocol| handleProtocolEvent(context.app_context, protocol),
        .mouse_wheel => |wheel| {
            if (context.overlay.* == null and context.auth_flow.* == null) {
                context.app_state.handleChatMouseWheel(wheel);
            }
        },
        .mouse_click => |click| {
            if (context.overlay.* == null and context.auth_flow.* == null) {
                context.app_state.handleMouseClick(click);
            }
        },
        .mouse_drag => |drag| {
            if (context.overlay.* == null and context.auth_flow.* == null) {
                context.app_state.handleMouseDrag(drag);
            }
        },
        .mouse_release => |release| {
            if (context.overlay.* == null and context.auth_flow.* == null) {
                context.app_state.handleMouseRelease(release);
            }
        },
    }
    consumeInputBytes(input_buffer, parsed.consumed);
}

fn dispatchKeyInputEvent(
    context: *InputDispatchEventContext,
    parsed: tui.keys.ParsedInput,
    key: tui.Key,
) !void {
    const editor_len_before = context.editor.text().len;
    logKeyInputDebug(context, "before", parsed, key, editor_len_before, editor_len_before);

    if (parsed.event_type == .release) {
        logKeyInputDebug(context, "after", parsed, key, editor_len_before, context.editor.text().len);
        return;
    }

    if (try dispatchMainEditorShortcut(context, parsed, key, editor_len_before)) return;

    if (context.overlay.* == null and context.auth_flow.* == null) {
        if (try context.live_resources.dispatchExtensionShortcut(key, parsed.modifiers)) return;
    }

    try handleInputKeyWithModifiers(
        context.allocator,
        context.io,
        context.env_map,
        key,
        parsed.modifiers,
        context.session,
        context.current_provider,
        context.session_dir,
        context.options,
        context.tool_items,
        context.app_state,
        context.editor,
        context.overlay,
        context.auth_flow,
        context.prompt_worker,
        context.prompt_worker_active,
        context.subscriber,
        context.should_exit,
        context.app_context,
        context.live_resources,
    );
    logKeyInputDebug(context, "after", parsed, key, editor_len_before, context.editor.text().len);
}

fn dispatchPasteInputEvent(
    context: *InputDispatchEventContext,
    content: []const u8,
) !void {
    if (context.overlay.* != null) return;
    _ = try context.editor.handlePaste(content);
}

fn dispatchMainEditorShortcut(
    context: *InputDispatchEventContext,
    parsed: tui.keys.ParsedInput,
    key: tui.Key,
    editor_len_before: usize,
) !bool {
    if (context.overlay.* != null or context.auth_flow.* != null) return false;

    const action = resolveParsedAppAction(context.live_resources.keybindings, key, parsed.modifiers) orelse return false;
    switch (action) {
        .message_followUp => try handleFollowUpAction(
            context.allocator,
            context.io,
            context.env_map,
            context.session,
            context.current_provider,
            context.session_dir,
            context.options,
            context.tool_items,
            context.app_state,
            context.editor,
            context.overlay,
            context.auth_flow,
            context.prompt_worker,
            context.prompt_worker_active,
            context.subscriber,
            context.should_exit,
            context.live_resources,
        ),
        .message_dequeue => try handleDequeueAction(
            context.allocator,
            context.session,
            context.app_state,
            context.editor,
        ),
        .chat_scrollToBottom => context.app_state.chatScrollToBottom(),
        else => return false,
    }

    logKeyInputDebug(context, "after", parsed, key, editor_len_before, context.editor.text().len);
    return true;
}

fn logKeyInputDebug(
    context: *InputDispatchEventContext,
    phase: []const u8,
    parsed: tui.keys.ParsedInput,
    key: tui.Key,
    editor_len_before: usize,
    editor_len_after: usize,
) void {
    maybeLogInputDebug(
        context.allocator,
        context.io,
        context.env_map,
        phase,
        parsed,
        key,
        context.overlay,
        context.auth_flow,
        context.editor,
        editor_len_before,
        editor_len_after,
    );
}

fn maybeLogInputDebug(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    phase: []const u8,
    parsed: tui.keys.ParsedInput,
    key: tui.Key,
    overlay: *const ?SelectorOverlay,
    auth_flow: *const ?AuthFlow,
    editor: *const tui.Editor,
    editor_len_before: usize,
    editor_len_after: usize,
) void {
    const path = env_map.get("PI_INPUT_DEBUG_LOG") orelse return;
    if (std.mem.trim(u8, path, " \t\r\n").len == 0) return;
    writeInputDebugLine(
        allocator,
        io,
        path,
        phase,
        parsed,
        key,
        activeInputDebugTag(overlay, auth_flow, editor),
        editor_len_before,
        editor_len_after,
    ) catch {};
}

fn writeInputDebugLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    phase: []const u8,
    parsed: tui.keys.ParsedInput,
    key: tui.Key,
    active_tag: []const u8,
    editor_len_before: usize,
    editor_len_after: usize,
) !void {
    const line = try formatInputDebugLine(
        allocator,
        phase,
        parsed,
        key,
        active_tag,
        editor_len_before,
        editor_len_after,
    );
    defer allocator.free(line);

    var file = std.Io.Dir.createFile(.cwd(), io, path, .{ .truncate = false }) catch return;
    defer file.close(io);

    const offset = file.length(io) catch return;
    file.writePositionalAll(io, line, offset) catch return;
}

fn formatInputDebugLine(
    allocator: std.mem.Allocator,
    phase: []const u8,
    parsed: tui.keys.ParsedInput,
    key: tui.Key,
    active_tag: []const u8,
    editor_len_before: usize,
    editor_len_after: usize,
) ![]u8 {
    const key_kind = @tagName(std.meta.activeTag(key));
    return switch (key) {
        .printable => |printable| blk: {
            const hex = try inputDebugHexAlloc(allocator, printable.slice());
            defer allocator.free(hex);
            break :blk std.fmt.allocPrint(
                allocator,
                "phase={s} active={s} event=key event_type={s} key={s} modifiers=shift:{},alt:{},ctrl:{},super:{} consumed={d} editor_len_before={d} editor_len_after={d} printable_utf8=\"{f}\" printable_hex={s}\n",
                .{
                    phase,
                    active_tag,
                    @tagName(parsed.event_type),
                    key_kind,
                    parsed.modifiers.shift,
                    parsed.modifiers.alt,
                    parsed.modifiers.ctrl,
                    parsed.modifiers.super,
                    parsed.consumed,
                    editor_len_before,
                    editor_len_after,
                    std.zig.fmtString(printable.slice()),
                    hex,
                },
            );
        },
        .ctrl => |ctrl| blk: {
            const ctrl_text = [_]u8{ctrl};
            break :blk std.fmt.allocPrint(
                allocator,
                "phase={s} active={s} event=key event_type={s} key={s} modifiers=shift:{},alt:{},ctrl:{},super:{} consumed={d} editor_len_before={d} editor_len_after={d} ctrl_byte=0x{x:0>2} ctrl_char=\"{f}\"\n",
                .{
                    phase,
                    active_tag,
                    @tagName(parsed.event_type),
                    key_kind,
                    parsed.modifiers.shift,
                    parsed.modifiers.alt,
                    parsed.modifiers.ctrl,
                    parsed.modifiers.super,
                    parsed.consumed,
                    editor_len_before,
                    editor_len_after,
                    ctrl,
                    std.zig.fmtString(&ctrl_text),
                },
            );
        },
        else => std.fmt.allocPrint(
            allocator,
            "phase={s} active={s} event=key event_type={s} key={s} modifiers=shift:{},alt:{},ctrl:{},super:{} consumed={d} editor_len_before={d} editor_len_after={d}\n",
            .{
                phase,
                active_tag,
                @tagName(parsed.event_type),
                key_kind,
                parsed.modifiers.shift,
                parsed.modifiers.alt,
                parsed.modifiers.ctrl,
                parsed.modifiers.super,
                parsed.consumed,
                editor_len_before,
                editor_len_after,
            },
        ),
    };
}

fn inputDebugHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const charset = "0123456789abcdef";
    const hex = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        hex[index * 2] = charset[byte >> 4];
        hex[index * 2 + 1] = charset[byte & 0x0f];
    }
    return hex;
}

fn activeInputDebugTag(
    overlay: *const ?SelectorOverlay,
    auth_flow: *const ?AuthFlow,
    editor: *const tui.Editor,
) []const u8 {
    if (overlay.*) |overlay_value| return @tagName(std.meta.activeTag(overlay_value));
    if (auth_flow.* != null) return "auth_flow";
    if (editor.isShowingAutocomplete()) return "autocomplete";
    return "editor";
}

fn handleProtocolEvent(app_context: *AppContext, protocol: tui.keys.ProtocolEvent) void {
    switch (protocol) {
        .kitty_keyboard => app_context.kitty_protocol_active = true,
    }
}

pub fn consumeInputBytes(buffer: *std.ArrayList(u8), consumed: usize) void {
    if (consumed >= buffer.items.len) {
        buffer.clearRetainingCapacity();
        return;
    }
    std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - consumed], buffer.items[consumed..]);
    buffer.items.len -= consumed;
}

fn toTuiEditorAction(action: keybindings_mod.EditorAction) ?tui.components.editor.EditorAction {
    // Compile-time exhaustiveness: every keybindings_mod.EditorAction variant
    // (modulo the explicit opt-outs below) must have a matching tag in
    // tui.components.editor.EditorAction.
    comptime {
        const opt_outs = [_][]const u8{ "input_submit", "input_copy" };
        for (@typeInfo(keybindings_mod.EditorAction).@"enum".fields) |f| {
            var is_opt_out = false;
            for (opt_outs) |name| {
                if (std.mem.eql(u8, f.name, name)) {
                    is_opt_out = true;
                    break;
                }
            }
            if (!is_opt_out and !@hasField(tui.components.editor.EditorAction, f.name)) {
                @compileError("keybindings_mod.EditorAction." ++ f.name ++
                    " has no matching tui.components.editor.EditorAction tag");
            }
        }
    }
    return switch (action) {
        .input_submit, .input_copy => null,
        inline else => |a| @field(tui.components.editor.EditorAction, @tagName(a)),
    };
}

fn submitEditorIfNotEmpty(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (editor.isShowingAutocomplete()) {
        const selected = editor.selectedAutocompleteItem();
        _ = try editor.handleAction(.select_confirm);
        if (selected) |item| {
            if (std.mem.startsWith(u8, item.value, "/")) {
                try submitEditorIfNotEmpty(
                    allocator,
                    io,
                    env_map,
                    session,
                    current_provider,
                    session_dir,
                    options,
                    tool_items,
                    app_state,
                    editor,
                    overlay,
                    auth_flow,
                    prompt_worker,
                    prompt_worker_active,
                    subscriber,
                    should_exit,
                    live_resources,
                );
            }
        }
        return;
    }

    if (editor.cursorPrecededBy("\\")) {
        _ = try editor.handleAction(.delete_char_backward);
        _ = try editor.handleAction(.input_new_line);
        return;
    }

    const expanded_text = try editor.expandedTextAlloc(allocator);
    defer allocator.free(expanded_text);
    const trimmed = std.mem.trim(u8, expanded_text, " \t\r\n");
    if (trimmed.len == 0) return;
    try submitEditorText(
        allocator,
        io,
        env_map,
        trimmed,
        session,
        current_provider,
        session_dir,
        options,
        tool_items,
        app_state,
        editor,
        overlay,
        auth_flow,
        prompt_worker,
        prompt_worker_active,
        subscriber,
        should_exit,
        live_resources,
    );
}

fn handleEditorAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    action: keybindings_mod.EditorAction,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (shouldRouteEditorActionToChatScroll(action, editor)) {
        switch (action) {
            .page_up => app_state.chatScrollPageUp(),
            .page_down => app_state.chatScrollPageDown(),
            else => unreachable,
        }
        return;
    }

    switch (action) {
        .input_submit => try submitEditorIfNotEmpty(
            allocator,
            io,
            env_map,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            editor,
            overlay,
            auth_flow,
            prompt_worker,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        ),
        .input_copy => {},
        else => if (toTuiEditorAction(action)) |editor_action| {
            _ = try editor.handleAction(editor_action);
        },
    }
}

fn shouldRouteEditorActionToChatScroll(action: keybindings_mod.EditorAction, editor: *const tui.Editor) bool {
    if (editor.isShowingAutocomplete()) return false;
    if (editor.text().len != 0) return false;
    return action == .page_up or action == .page_down;
}

pub fn resolveAppAction(keybindings: ?*const keybindings_mod.Keybindings, key: tui.Key) ?keybindings_mod.Action {
    return input_resolution.resolveAppAction(keybindings, key);
}

pub fn resolveParsedAppAction(
    keybindings: ?*const keybindings_mod.Keybindings,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) ?keybindings_mod.Action {
    return input_resolution.resolveParsedAppAction(keybindings, key, modifiers);
}

pub fn legacyAppActionForKey(key: tui.Key) ?keybindings_mod.Action {
    return input_resolution.legacyAppActionForKey(key);
}

pub fn legacyParsedAppActionForKey(
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) ?keybindings_mod.Action {
    return input_resolution.legacyParsedAppActionForKey(key, modifiers);
}

pub fn isLegacyAppActionKey(key: tui.Key) bool {
    return input_resolution.isLegacyAppActionKey(key);
}

pub fn isLegacyParsedAppActionKey(key: tui.Key, modifiers: tui.keys.KeyModifiers) bool {
    return input_resolution.isLegacyParsedAppActionKey(key, modifiers);
}

const CLEAR_DOUBLE_PRESS_WINDOW_MS: i64 = 500;
const ESCAPE_DOUBLE_PRESS_WINDOW_MS: i64 = 500;

fn handleInterruptAction(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    prompt_worker_active: *bool,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !void {
    if (session.isRetrying()) {
        session.abortRetry();
        try app_state.setStatus("retry cancel requested");
    } else if (prompt_worker_active.*) {
        _ = session.agent.abort();
        try app_state.setStatus("interrupt requested");
    } else if (app_state.cancelBashExecution()) {
        try app_state.setStatus("bash cancel requested");
    } else if (parseBashShortcut(std.mem.trim(u8, editor.text(), " \t\r\n")) != null) {
        clearEditor(app_state, editor);
        try app_state.setStatus("bash entry cancelled");
    } else if (std.mem.trim(u8, editor.text(), " \t\r\n").len == 0) {
        try handleDoubleEscapeAction(allocator, session, app_state, overlay, runtime_config);
    }
}

fn handleDoubleEscapeAction(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !void {
    const action = if (runtime_config) |config| config.doubleEscapeAction() else config_mod.DoubleEscapeAction.tree;
    if (action == .none) return;

    const now_ms = app_state.currentNowMs();
    if (app_state.takeLastEscapeActionMs()) |last_ms| {
        if (now_ms - last_ms < ESCAPE_DOUBLE_PRESS_WINDOW_MS) {
            switch (action) {
                .tree => overlay.* = try loadTreeOverlay(allocator, session),
                .fork => try loadForkOverlayOrStatus(allocator, session, app_state, overlay),
                .none => {},
            }
            return;
        }
    }
    app_state.setLastEscapeActionMs(now_ms);
}

fn handleClearAction(
    app_state: *AppState,
    editor: *tui.Editor,
    session: *session_mod.AgentSession,
    prompt_worker_active: *bool,
    should_exit: *bool,
) !void {
    const now_ms = app_state.currentNowMs();
    if (app_state.takeLastClearActionMs()) |last_ms| {
        if (now_ms - last_ms < CLEAR_DOUBLE_PRESS_WINDOW_MS) {
            should_exit.* = true;
            if (prompt_worker_active.*) { _ = session.agent.abort(); }
            return;
        }
    }

    clearEditor(app_state, editor);
    app_state.clearDisplay();
    app_state.setLastClearActionMs(now_ms);
}

fn cycleThinkingLevel(session: *session_mod.AgentSession, app_state: *AppState) !void {
    if (!session.agent.getModel().reasoning) {
        try app_state.setStatus("Current model does not support thinking");
        return;
    }

    const next = nextSupportedThinkingLevel(session.agent.getModel(), session.agent.getThinkingLevel());
    try session.setThinkingLevel(next);
    try app_state.setStatus(switch (next) {
        .off => "Thinking level: off",
        .minimal => "Thinking level: minimal",
        .low => "Thinking level: low",
        .medium => "Thinking level: medium",
        .high => "Thinking level: high",
        .xhigh => "Thinking level: xhigh",
    });
}

fn nextSupportedThinkingLevel(model: ai.Model, current: agent.ThinkingLevel) agent.ThinkingLevel {
    const levels = [_]agent.ThinkingLevel{ .off, .minimal, .low, .medium, .high, .xhigh };
    const current_index = for (levels, 0..) |level, index| {
        if (level == current) break index;
    } else 0;

    for (1..levels.len + 1) |offset| {
        const candidate = levels[(current_index + offset) % levels.len];
        if (thinkingLevelSupported(model, candidate)) return candidate;
    }
    return .off;
}

fn thinkingLevelSupported(model: ai.Model, level: agent.ThinkingLevel) bool {
    return ai.model_registry.thinkingLevelSupported(model, agentThinkingLevelToModel(level));
}

fn agentThinkingLevelToModel(level: agent.ThinkingLevel) ai.types.ModelThinkingLevel {
    return switch (level) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

const ModelCycleDirection = enum { forward, backward };

fn cycleModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    direction: ModelCycleDirection,
) !void {
    const available = try loadSelectableModels(allocator, env_map, session.agent.getModel(), current_provider, model_patterns, runtime_config);
    defer allocator.free(available);

    var selectable_count: usize = 0;
    var current_selectable_index: ?usize = null;
    for (available) |entry| {
        if (!entry.available) continue;
        if (std.mem.eql(u8, entry.provider, session.agent.getModel().provider) and
            std.mem.eql(u8, entry.model_id, session.agent.getModel().id))
        {
            current_selectable_index = selectable_count;
        }
        selectable_count += 1;
    }

    if (selectable_count <= 1) {
        try app_state.setStatus(if (model_patterns != null) "Only one model in scope" else "Only one model available");
        return;
    }

    const current_index = current_selectable_index orelse 0;
    const target_selectable_index = switch (direction) {
        .forward => (current_index + 1) % selectable_count,
        .backward => if (current_index == 0) selectable_count - 1 else current_index - 1,
    };

    var selectable_index: usize = 0;
    for (available) |entry| {
        if (!entry.available) continue;
        if (selectable_index == target_selectable_index) {
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
            const status = try std.fmt.allocPrint(
                allocator,
                "Switched to {s}",
                .{if (entry.display_name.len > 0) entry.display_name else entry.model_id},
            );
            defer allocator.free(status);
            try app_state.setStatus(status);
            return;
        }
        selectable_index += 1;
    }
}

fn openExternalEditor(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    app_state: *AppState,
    editor: *tui.Editor,
) !void {
    const editor_cmd = env_map.get("VISUAL") orelse env_map.get("EDITOR") orelse {
        try app_state.setStatus("No editor configured. Set $VISUAL or $EDITOR environment variable.");
        return;
    };
    const trimmed_editor_cmd = std.mem.trim(u8, editor_cmd, " \t\r\n");
    if (trimmed_editor_cmd.len == 0) {
        try app_state.setStatus("No editor configured. Set $VISUAL or $EDITOR environment variable.");
        return;
    }

    const tmp_dir = env_map.get("TMPDIR") orelse "/tmp";
    const tmp_name = try std.fmt.allocPrint(
        allocator,
        "pi-editor-{d}.pi.md",
        .{app_state.currentNowMs()},
    );
    defer allocator.free(tmp_name);
    const tmp_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_dir, tmp_name });
    defer allocator.free(tmp_path);
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = tmp_path,
        .data = editor.text(),
    });

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    var parts = std.mem.tokenizeScalar(u8, trimmed_editor_cmd, ' ');
    while (parts.next()) |part| {
        try argv.append(allocator, part);
    }
    if (argv.items.len == 0) {
        try app_state.setStatus("No editor configured. Set $VISUAL or $EDITOR environment variable.");
        return;
    }
    try argv.append(allocator, tmp_path);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    const exit_code = exitCodeFromChildTerm(term);
    if (exit_code == 0) {
        const edited = try std.Io.Dir.readFileAlloc(.cwd(), io, tmp_path, allocator, .limited(1024 * 1024));
        defer allocator.free(edited);
        const replacement = stripSingleTrailingNewline(edited);
        try editor.setText(replacement);
        try app_state.setStatus("Updated prompt from external editor");
    } else {
        const message = try std.fmt.allocPrint(allocator, "External editor exited with status {d}; prompt unchanged", .{exit_code});
        defer allocator.free(message);
        try app_state.setStatus(message);
    }
}

fn stripSingleTrailingNewline(content: []const u8) []const u8 {
    if (content.len > 0 and content[content.len - 1] == '\n') return content[0 .. content.len - 1];
    return content;
}

fn exitCodeFromChildTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn handleAppAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    action: keybindings_mod.Action,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    editor: *tui.Editor,
    prompt_worker_active: *bool,
    tool_items: []const agent.AgentTool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    app_context: *AppContext,
) !void {
    switch (action) {
        .interrupt => try handleInterruptAction(
            allocator,
            session,
            app_state,
            editor,
            overlay,
            prompt_worker_active,
            runtime_config,
        ),
        .exit => {
            if (editor.text().len == 0) {
                should_exit.* = true;
                if (prompt_worker_active.*) { _ = session.agent.abort(); }
                return;
            }
            _ = try editor.handleKey(.delete);
        },
        .clear => try handleClearAction(app_state, editor, session, prompt_worker_active, should_exit),
        .app_suspend => app_context.suspend_requested = true,
        .tools_expand => app_state.toggleAllExpanded(),
        .thinking_cycle => try cycleThinkingLevel(session, app_state),
        .thinking_toggle => {
            const hidden = try app_state.toggleThinkingBlockVisibility();
            try app_state.setStatus(if (hidden) "Thinking blocks: hidden" else "Thinking blocks: visible");
        },
        .editor_external => try openExternalEditor(allocator, io, env_map, app_state, editor),
        .model_cycleForward => try cycleModel(
            allocator,
            env_map,
            session,
            current_provider,
            effectiveScopedModelPatterns(app_state, options, runtime_config),
            options,
            runtime_config,
            app_state,
            .forward,
        ),
        .model_cycleBackward => try cycleModel(
            allocator,
            env_map,
            session,
            current_provider,
            effectiveScopedModelPatterns(app_state, options, runtime_config),
            options,
            runtime_config,
            app_state,
            .backward,
        ),
        .session_new => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before starting a new session");
                return;
            }
            try handleNewSlashCommand(
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
        .session_tree => {
            if (selectorInteractionBlocked(session, prompt_worker_active)) {
                try app_state.setStatus("wait for the current response to finish before opening the session tree");
                return;
            }
            overlay.* = try loadTreeOverlay(allocator, session);
        },
        .session_fork => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before forking the session");
                return;
            }
            try loadForkOverlayOrStatus(allocator, session, app_state, overlay);
        },
        .session_resume => {
            if (selectorInteractionBlocked(session, prompt_worker_active)) {
                try app_state.setStatus("wait for the current response to finish before switching sessions");
                return;
            }
            overlay.* = try loadSessionOverlay(allocator, io, session_dir, session.session_manager.getSessionFile());
        },
        .model_select => {
            if (selectorInteractionBlocked(session, prompt_worker_active)) {
                try app_state.setStatus("wait for the current response to finish before switching models");
                return;
            }
            overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel(), current_provider, effectiveScopedModelPatterns(app_state, options, runtime_config), runtime_config);
        },
        // These actions are executed by dispatchInputEvent so they can consume the exact
        // parsed byte sequence. They remain explicit here to keep Action dispatch
        // coverage exhaustive when the enum changes.
        .message_followUp, .message_dequeue => {},
        // Clipboard image paste is handled before the app dispatcher because it
        // depends only on environment/clipboard state, not session execution state.
        .clipboard_pasteImage => {},
        .chat_scrollToBottom => app_state.chatScrollToBottom(),
        // Overlay-scoped actions are resolved and executed only by their overlay
        // dispatchers. Any Action variant whose tag name starts with one of the
        // overlay prefixes (`tree_`, `session_`, `models_`) and is not explicitly
        // dispatched above is a no-op here. The comptime guard ensures new Action
        // variants without a known overlay prefix surface as a compile error
        // rather than silently falling through.
        inline else => |tag| {
            if (comptime !isOverlayScopedActionTag(tag)) {
                @compileError("Unhandled Action variant in handleAppAction: " ++ @tagName(tag));
            }
        },
    }
}

/// Returns true when the Action tag name starts with one of the overlay
/// prefixes whose actions are dispatched exclusively by overlay handlers
/// (`tree_*`, `session_*`, `models_*`).
///
/// `session_*` variants that ARE dispatched by the main editor (e.g.,
/// `session_new`, `session_tree`, `session_fork`, `session_resume`) are
/// matched by explicit cases earlier in the `handleAppAction` switch and
/// never reach the `inline else` branch that calls this predicate.
fn isOverlayScopedActionTag(comptime tag: keybindings_mod.Action) bool {
    const name = @tagName(tag);
    return std.mem.startsWith(u8, name, "tree_") or
        std.mem.startsWith(u8, name, "session_") or
        std.mem.startsWith(u8, name, "models_");
}

pub const testing = struct {
    pub const handleProtocolEvent = inputDispatchTestingHandleProtocolEvent;
    pub const cycleThinkingLevel = inputDispatchTestingCycleThinkingLevel;
};

fn inputDispatchTestingHandleProtocolEvent(app_context: *AppContext, protocol: tui.keys.ProtocolEvent) void {
    handleProtocolEvent(app_context, protocol);
}

fn inputDispatchTestingCycleThinkingLevel(session: *session_mod.AgentSession, app_state: *AppState) !void {
    try cycleThinkingLevel(session, app_state);
}

test {
    _ = @import("input_dispatch/tests.zig");
}
