const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const auth = @import("auth/auth.zig");
const config_mod = @import("config/config.zig");
const keybindings_mod = @import("shared/keybindings.zig");
const resources_mod = @import("resources/resources.zig");
const session_advanced = @import("sessions/session_advanced.zig");
const session_cwd_mod = @import("sessions/session_cwd.zig");
const missing_cwd_selector_mod = @import("sessions/missing_cwd_selector.zig");
const session_manager_mod = @import("sessions/session_manager.zig");
const provider_config = @import("providers/provider_config.zig");
const session_mod = @import("sessions/session.zig");
const common = @import("tools/common.zig");

const shared = @import("interactive_mode/shared.zig");
const formatting = @import("interactive_mode/formatting.zig");
const overlays = @import("interactive_mode/overlays.zig");
const rendering = @import("interactive_mode/rendering.zig");
const prompt_worker_mod = @import("interactive_mode/prompt_worker.zig");
const command_router = @import("interactive_mode/command_router.zig");
const slash_commands = @import("interactive_mode/slash_commands.zig");
const auth_flow_mod = @import("interactive_mode/auth_flow.zig");
const session_lifecycle = @import("interactive_mode/session_lifecycle.zig");
const input_dispatch = @import("interactive_mode/input_dispatch.zig");
const system_prompt_mod = @import("resources/system_prompt.zig");
const clipboard_image = @import("interactive_mode/clipboard_image.zig");
const tool_registry = @import("runtime/tool_registry.zig");
const interactive_hooks = @import("runtime/interactive_hooks.zig");
const ui_runtime = @import("runtime/ui_runtime.zig");
const session_bootstrap = @import("interactive_mode/session_bootstrap.zig");
const extension_ui_bridge = @import("interactive_mode/extension_ui_bridge.zig");

pub const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
pub const LiveResources = shared.LiveResources;
pub const ToolRuntime = shared.ToolRuntime;
pub const AppContext = shared.AppContext;
pub const currentSessionLabel = shared.currentSessionLabel;
pub const configuredCredentials = shared.configuredCredentials;
pub const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
pub const configuredCompactionSettings = shared.configuredCompactionSettings;
pub const configuredRetrySettings = shared.configuredRetrySettings;
pub const settingsResources = shared.settingsResources;
pub const normalizePathArgument = shared.normalizePathArgument;
pub const overrideApiKeyForProvider = shared.overrideApiKeyForProvider;
pub const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
pub const formatPrefixedBlocks = formatting.formatPrefixedBlocks;
pub const formatAssistantMessage = formatting.formatAssistantMessage;
pub const formatToolCall = formatting.formatToolCall;
pub const formatToolResult = formatting.formatToolResult;
pub const blocksToText = formatting.blocksToText;
pub const SelectorOverlay = overlays.SelectorOverlay;
pub const InfoOverlay = overlays.InfoOverlay;
pub const SettingsEditorOverlay = overlays.SettingsEditorOverlay;
pub const SessionChoice = overlays.SessionChoice;
pub const SessionOverlay = overlays.SessionOverlay;
pub const ModelChoice = overlays.ModelChoice;
pub const ModelOverlay = overlays.ModelOverlay;
pub const TreeChoice = overlays.TreeChoice;
pub const TreeOverlay = overlays.TreeOverlay;
pub const AuthOverlayMode = overlays.AuthOverlayMode;
pub const AuthChoice = overlays.AuthChoice;
pub const AuthOverlay = overlays.AuthOverlay;
pub const AuthFlow = overlays.AuthFlow;
pub const PendingBrowserRedirect = overlays.PendingBrowserRedirect;
pub const PendingGoogleProject = overlays.PendingGoogleProject;
pub const PendingApiKeyEntry = overlays.PendingApiKeyEntry;
pub const isApiKeyLoginProvider = auth.isApiKeyLoginProvider;
pub const getApiKeyProviderDisplayName = auth.getApiKeyProviderDisplayName;
pub const loadAuthOverlay = overlays.loadAuthOverlay;
pub const loadSettingsEditorOverlay = overlays.loadSettingsEditorOverlay;
pub const loadHotkeysOverlay = overlays.loadHotkeysOverlay;
pub const loadInfoOverlay = overlays.loadInfoOverlay;
pub const appendInfoOverlayItem = overlays.appendInfoOverlayItem;
pub const appendHotkeyOverlayItem = overlays.appendHotkeyOverlayItem;
pub const loadSessionOverlay = overlays.loadSessionOverlay;
pub const loadModelOverlay = overlays.loadModelOverlay;
pub const loadModelOverlayWithSearch = overlays.loadModelOverlayWithSearch;
pub const loadScopedModelOverlay = overlays.loadScopedModelOverlay;
pub const loadSelectableModels = overlays.loadSelectableModels;
pub const modelSupportsInput = overlays.modelSupportsInput;
pub const loadTreeOverlay = overlays.loadTreeOverlay;
pub const appendTreeNodes = overlays.appendTreeNodes;
pub const indentationPrefix = overlays.indentationPrefix;
pub const summarizeSessionEntry = overlays.summarizeSessionEntry;
pub const trimSummaryText = overlays.trimSummaryText;
pub const SessionOverlayEntries = overlays.SessionOverlayEntries;
pub const listSessions = overlays.listSessions;
pub const loadSessionDisplayName = overlays.loadSessionDisplayName;
pub const ChatKind = rendering.ChatKind;
pub const ChatItem = rendering.ChatItem;
pub const FooterUsageTotals = rendering.FooterUsageTotals;
pub const AppState = rendering.AppState;
pub const ScreenComponent = rendering.ScreenComponent;
pub const BorrowedLinesComponent = rendering.BorrowedLinesComponent;
pub const OverlayPanelComponent = rendering.OverlayPanelComponent;
pub const overlayPanelMaxHeight = rendering.overlayPanelMaxHeight;
pub const overlayPanelWidth = rendering.overlayPanelWidth;
pub const overlayAnimationProgress = rendering.overlayAnimationProgress;
pub const nowMilliseconds = rendering.nowMilliseconds;
pub const overlayPanelOptions = rendering.overlayPanelOptions;
pub const rebuildAppStateFromSession = rendering.rebuildAppStateFromSession;
pub const updateAppFooterFromSession = rendering.updateAppFooterFromSession;
pub const assistantContextTokens = rendering.assistantContextTokens;
pub const resolveGitBranch = rendering.resolveGitBranch;
pub const findGitRoot = rendering.findGitRoot;
pub const resolveGitDirectory = rendering.resolveGitDirectory;
pub const parseGitHeadBranch = rendering.parseGitHeadBranch;
pub const parseEnvSize = rendering.parseEnvSize;
pub const freeLinesSlice = rendering.freeLinesSlice;
pub const INPUT_PROMPT_PREFIX = rendering.INPUT_PROMPT_PREFIX;
pub const formatFooterLine = rendering.formatFooterLine;
pub const appendFooterPart = rendering.appendFooterPart;
pub const formatCompactTokenCount = rendering.formatCompactTokenCount;
pub const formatHintsLine = rendering.formatHintsLine;
pub const actionLabel = rendering.actionLabel;
pub const themeChatItem = rendering.themeChatItem;
pub const renderChatItemInto = rendering.renderChatItemInto;
pub const renderAssistantChatItemInto = rendering.renderAssistantChatItemInto;
pub const applyThemeAlloc = rendering.applyThemeAlloc;
pub const fitLine = rendering.fitLine;
pub const handleAppAgentEvent = rendering.handleAppAgentEvent;
pub const handleAppRetryLifecycleEvent = rendering.handleAppRetryLifecycleEvent;
pub const handleAppCompactionLifecycleEvent = rendering.handleAppCompactionLifecycleEvent;
pub const InteractiveModeTestBackend = rendering.InteractiveModeTestBackend;
pub const renderScreenWithMockBackend = rendering.renderScreenWithMockBackend;
pub const renderScreenWithMockBackendAndOverlay = rendering.renderScreenWithMockBackendAndOverlay;
pub const renderedLinesContain = rendering.renderedLinesContain;
pub const PromptWorker = prompt_worker_mod.PromptWorker;
pub const cloneImageContents = prompt_worker_mod.cloneImageContents;
pub const deinitImageContents = prompt_worker_mod.deinitImageContents;
pub const BuiltTools = tool_registry.BuiltTools;
pub const ToolBuildOptions = tool_registry.ToolBuildOptions;
pub const buildAgentTools = tool_registry.buildAgentTools;
pub const buildAgentToolsWithOptions = tool_registry.buildAgentToolsWithOptions;
pub const buildAgentToolsWithSelection = tool_registry.buildAgentToolsWithSelection;
pub const buildAgentToolsWithExtensions = tool_registry.buildAgentToolsWithExtensions;
pub const buildAgentToolsWithExtensionsSelection = tool_registry.buildAgentToolsWithExtensionsSelection;
pub const writeStartupDiagnostics = tool_registry.writeStartupDiagnostics;
pub const InteractiveBootstrap = session_bootstrap.InteractiveBootstrap;
pub const bootstrapInteractiveState = session_bootstrap.bootstrapInteractiveState;
pub const bootstrapInteractiveStateWithMissingCwd = session_bootstrap.bootstrapInteractiveStateWithMissingCwd;
pub const openInitialSession = session_bootstrap.openInitialSession;
pub const openInitialSessionWithMissingCwd = session_bootstrap.openInitialSessionWithMissingCwd;
pub const OwnedMissingSessionCwdIssue = session_bootstrap.OwnedMissingSessionCwdIssue;
pub const resolveResumeSessionPath = session_bootstrap.resolveResumeSessionPath;
pub const preflightInteractiveMissingCwd = session_bootstrap.preflightInteractiveMissingCwd;
pub const SlashCommandKind = command_router.SlashCommandKind;
pub const SlashCommand = command_router.SlashCommand;
pub const BuiltinSlashCommand = command_router.BuiltinSlashCommand;
pub const BUILTIN_SLASH_COMMANDS = command_router.BUILTIN_SLASH_COMMANDS;
pub const VISIBLE_BUILTIN_SLASH_COMMANDS = command_router.VISIBLE_BUILTIN_SLASH_COMMANDS;
pub const createSeededSession = session_lifecycle.createSeededSession;
pub const parseSlashCommand = command_router.parseSlashCommand;
pub const handleSlashCommand = command_router.handleSlashCommand;
pub const switchSession = session_lifecycle.switchSession;
pub const switchModel = slash_commands.switchModel;
pub const handleModelSlashCommand = slash_commands.handleModelSlashCommand;
pub const handleScopedModelsSlashCommand = slash_commands.handleScopedModelsSlashCommand;
pub const handleSessionSlashCommand = slash_commands.handleSessionSlashCommand;
pub const ChangelogView = slash_commands.ChangelogView;
pub const handleChangelogSlashCommand = slash_commands.handleChangelogSlashCommand;
pub const parseChangelogView = slash_commands.parseChangelogView;
pub const buildChangelogMarkdown = slash_commands.buildChangelogMarkdown;
pub const resolveChangelogPath = slash_commands.resolveChangelogPath;
pub const extractLatestVersionSection = slash_commands.extractLatestVersionSection;
pub const handleNameSlashCommand = slash_commands.handleNameSlashCommand;
pub const handleLabelSlashCommand = slash_commands.handleLabelSlashCommand;
pub const resolveCurrentLabelTargetId = slash_commands.resolveCurrentLabelTargetId;
pub const handleCompactSlashCommand = slash_commands.handleCompactSlashCommand;

const ReloadExtensionToolsContext = struct {
    bootstrap: *session_bootstrap.InteractiveBootstrap,
    app_context: *AppContext,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
};

fn reloadExtensionToolsForInteractiveMode(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    session: *session_mod.AgentSession,
    live_resources: *LiveResources,
) !void {
    const reload_context: *ReloadExtensionToolsContext = @ptrCast(@alignCast(context.?));
    const extensions = if (live_resources.owned_resource_bundle) |*bundle| bundle.extensions else &.{};
    try tool_registry.replaceAgentToolsForReload(
        allocator,
        reload_context.app_context,
        session,
        &reload_context.bootstrap.built_tools,
        reload_context.options.selected_tools,
        .{
            .extensions = extensions,
            .env_map = env_map,
            .cwd = cwd,
            .io = io,
            .runtime_config = live_resources.runtime_config,
        },
    );

    if (reload_context.options.current_date.len > 0) {
        const next_system_prompt = try system_prompt_mod.buildSystemPrompt(allocator, .{
            .cwd = cwd,
            .current_date = reload_context.options.current_date,
            .custom_prompt = reload_context.options.custom_prompt,
            .append_prompts = reload_context.options.append_prompts,
            .tool_selection = reload_context.options.selected_tools,
            .active_tools = reload_context.bootstrap.built_tools.items,
            .context_files = reload_context.options.context_files,
            .skills = live_resources.skills,
        });
        errdefer allocator.free(next_system_prompt);
        if (reload_context.bootstrap.owned_system_prompt) |previous| allocator.free(previous);
        reload_context.bootstrap.owned_system_prompt = next_system_prompt;
        session.agent.setSystemPrompt(next_system_prompt);
    } else {
        session.agent.setSystemPrompt(reload_context.options.system_prompt);
    }

    for (reload_context.bootstrap.built_tools.startup_diagnostics) |diagnostic| {
        if (!shouldShowExtensionLifecycleDiagnosticInAppState(diagnostic, reload_context.options.verbose)) continue;
        const message = try std.fmt.allocPrint(allocator, "Reload {s}", .{diagnostic.message});
        defer allocator.free(message);
        switch (diagnostic.severity) {
            .info => try reload_context.app_state.appendInfo(message),
            .warning, .@"error" => try reload_context.app_state.appendError(message),
        }
    }
}

fn appendExtensionStartupDiagnosticsToAppState(
    allocator: std.mem.Allocator,
    diagnostics: []const tool_registry.ExtensionStartupDiagnostic,
    app_state: *AppState,
    show_optional: bool,
) !void {
    for (diagnostics) |diagnostic| {
        if (!shouldShowExtensionLifecycleDiagnosticInAppState(diagnostic, show_optional)) continue;
        const message = try std.fmt.allocPrint(allocator, "Startup {s}", .{diagnostic.message});
        defer allocator.free(message);
        switch (diagnostic.severity) {
            .info => try app_state.appendInfo(message),
            .warning, .@"error" => try app_state.appendError(message),
        }
    }
}

fn shouldShowExtensionLifecycleDiagnosticInAppState(
    diagnostic: tool_registry.ExtensionStartupDiagnostic,
    show_optional: bool,
) bool {
    return show_optional or diagnostic.required or diagnostic.severity == .@"error";
}

pub const handleLoginSlashCommand = auth_flow_mod.handleLoginSlashCommand;
pub const beginLoginFlow = auth_flow_mod.beginLoginFlow;
pub const cancelAuthFlow = auth_flow_mod.cancelAuthFlow;
pub const submitAuthFlowInput = auth_flow_mod.submitAuthFlowInput;
pub const persistLoginCredential = auth_flow_mod.persistLoginCredential;
pub const OpenBrowserFn = auth_flow_mod.OpenBrowserFn;
pub const openBrowserBestEffort = auth_flow_mod.openBrowserBestEffort;
pub const defaultOpenBrowserBestEffort = auth_flow_mod.defaultOpenBrowserBestEffort;
pub const ClipboardCopyFn = slash_commands.ClipboardCopyFn;
pub const BrowserOpenCapture = auth_flow_mod.BrowserOpenCapture;
pub const handleSettingsSlashCommand = slash_commands.handleSettingsSlashCommand;
pub const handleImportSlashCommand = slash_commands.handleImportSlashCommand;
pub const handleCopySlashCommand = slash_commands.handleCopySlashCommand;
pub const handleShareSlashCommand = slash_commands.handleShareSlashCommand;
pub const handleLogoutSlashCommand = auth_flow_mod.handleLogoutSlashCommand;
pub const logoutProviderById = auth_flow_mod.logoutProviderById;
pub const handleNewSlashCommand = session_lifecycle.handleNewSlashCommand;
pub const clearResolvedProviderApiKey = auth_flow_mod.clearResolvedProviderApiKey;
pub const copyTextToClipboard = slash_commands.copyTextToClipboard;
pub const defaultCopyTextToClipboard = slash_commands.defaultCopyTextToClipboard;
pub const runClipboardCommand = slash_commands.runClipboardCommand;
pub const exitCodeFromChildTerm = slash_commands.exitCodeFromChildTerm;
pub const lastAssistantTextAlloc = slash_commands.lastAssistantTextAlloc;
pub const assistantBlocksToTextAlloc = slash_commands.assistantBlocksToTextAlloc;
pub const buildShareText = slash_commands.buildShareText;
pub const messageToShareMarkdown = slash_commands.messageToShareMarkdown;
pub const blocksToShareText = slash_commands.blocksToShareText;
pub const removeStoredAuthToken = auth_flow_mod.removeStoredAuthToken;
pub const handleReloadSlashCommand = slash_commands.handleReloadSlashCommand;
pub const configurePrimaryEditor = slash_commands.configurePrimaryEditor;
pub const appendResourceDiagnostics = slash_commands.appendResourceDiagnostics;
pub const saveSettingsEditorOverlay = slash_commands.saveSettingsEditorOverlay;
pub const handleExportSlashCommand = slash_commands.handleExportSlashCommand;
pub const formatSessionInfo = session_lifecycle.formatSessionInfo;
pub const cloneCurrentSession = session_lifecycle.cloneCurrentSession;
pub const forkCurrentSession = session_lifecycle.forkCurrentSession;
pub const createDerivedSession = session_lifecycle.createDerivedSession;
pub const replaceCurrentSession = session_lifecycle.replaceCurrentSession;
pub const navigateTree = session_lifecycle.navigateTree;
pub const findLastUserMessageIndex = session_lifecycle.findLastUserMessageIndex;
pub const resolveSessionPath = session_lifecycle.resolveSessionPath;
pub const handleInputKey = input_dispatch.handleInputKey;
pub const handleInputKeyWithModifiers = input_dispatch.handleInputKeyWithModifiers;
pub const submitEditorText = input_dispatch.submitEditorText;
pub const clearEditor = input_dispatch.clearEditor;
pub const loadEditorAutocompleteItems = input_dispatch.loadEditorAutocompleteItems;
pub const loadEditorAutocompleteItemsWithResources = input_dispatch.loadEditorAutocompleteItemsWithResources;
pub const freeOwnedSelectItems = input_dispatch.freeOwnedSelectItems;
pub const pollForInput = input_dispatch.pollForInput;
pub const dispatchInputEvent = input_dispatch.dispatchInputEvent;
pub const consumeInputBytes = input_dispatch.consumeInputBytes;
pub const resolveAppAction = input_dispatch.resolveAppAction;
pub const legacyAppActionForKey = input_dispatch.legacyAppActionForKey;
pub const isLegacyAppActionKey = input_dispatch.isLegacyAppActionKey;
pub const handleAppAction = input_dispatch.handleAppAction;
pub const ExtensionUiBridge = extension_ui_bridge.Bridge;

pub fn runInteractiveMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var app_context = AppContext.init(options.cwd, io);

    var missing_cwd_issue: ?session_bootstrap.OwnedMissingSessionCwdIssue = null;
    defer if (missing_cwd_issue) |*captured| captured.deinit(allocator);
    const bootstrap_or_exit = try bootstrapInteractiveStateOrPromptMissingCwd(
        allocator,
        io,
        env_map,
        options,
        &app_context,
        &missing_cwd_issue,
        stderr_writer,
    );
    var bootstrap = switch (bootstrap_or_exit) {
        .bootstrap => |state| state,
        .exit_code => |code| return code,
    };
    defer bootstrap.deinit();

    if (bootstrap.built_tools.required_startup_failed) {
        try tool_registry.writeStartupDiagnostics(stderr_writer, bootstrap.built_tools.startup_diagnostics);
        try stderr_writer.flush();
        return 1;
    }

    var app_state = try AppState.init(allocator, io);
    defer app_state.deinit();
    app_state.setToolOutputExpanded(options.verbose);
    try live_resources.ensureOwnedBundle(allocator, io, env_map, options.cwd);

    const subscriber = agent.AgentSubscriber{
        .context = &app_state,
        .callback = handleAppAgentEvent,
    };
    try bootstrap.session.agent.subscribe(subscriber);
    defer _ = bootstrap.session.agent.unsubscribe(subscriber);
    interactive_hooks.installSessionUiCallbacks(
        &bootstrap.session,
        .{ .context = &app_state, .callback = handleAppRetryLifecycleEvent },
        .{ .context = &app_state, .callback = handleAppCompactionLifecycleEvent },
    );
    defer interactive_hooks.clearSessionUiCallbacks(&bootstrap.session);

    try rebuildAppStateFromSession(allocator, io, &app_state, &bootstrap.session, &bootstrap.current_provider);
    try appendExtensionStartupDiagnosticsToAppState(allocator, bootstrap.built_tools.startup_diagnostics, &app_state, options.verbose);
    if (live_resources.runtime_config) |runtime_config| {
        try app_state.setThinkingBlockVisibility(runtime_config.hideThinkingBlock());
    }
    try appendConfigErrorStartupWarning(allocator, live_resources.runtime_config, &app_state);
    try appendVerboseStartupState(
        allocator,
        env_map,
        options,
        live_resources.keybindings,
        live_resources.runtime_config,
        &bootstrap.session,
        &bootstrap.current_provider,
        &app_state,
    );

    var terminal = tui.Terminal.initNative(.{
        .io = io,
        .env_map = env_map,
    });
    try terminal.start();
    defer terminal.stop();
    var last_terminal_title: ?[]u8 = null;
    defer if (last_terminal_title) |title| allocator.free(title);
    try ui_runtime.updateInteractiveTerminalTitle(allocator, &terminal, &bootstrap.session, &last_terminal_title);
    defer if (ui_runtime.showTerminalProgress(live_resources.runtime_config)) {
        ui_runtime.writeTerminalProgress(&terminal, false) catch {};
    };

    var input_loop = try terminal.initInputLoop(allocator, io, env_map);
    defer input_loop.deinit();
    input_loop.vaxis_state.queryTerminal(input_loop.loop.tty.writer(), .fromMilliseconds(250)) catch {};

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();
    defer app_state.freeActiveTerminalImages(.{
        .vx = input_loop.vaxis_state,
        .tty = input_loop.loop.tty.writer(),
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    configurePrimaryEditor(&editor, live_resources.runtime_config);
    const autocomplete_items = try loadEditorAutocompleteItemsWithResources(
        allocator,
        io,
        options.cwd,
        live_resources.prompt_templates,
        live_resources.skills,
        true,
    );
    defer freeOwnedSelectItems(allocator, autocomplete_items);
    try editor.setAutocompleteItems(autocomplete_items);

    var screen = ScreenComponent{
        .state = &app_state,
        .editor = &editor,
        .keybindings = live_resources.keybindings,
        .theme = live_resources.theme,
        .terminal_name = live_resources.terminal_name,
        .image_render_policy = if (live_resources.runtime_config) |config|
            .{ .enabled = config.showImages(), .width_cells = config.imageWidthCells() }
        else
            .{},
    };

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var overlay_panel: ?OverlayPanelComponent = null;
    var overlay_handle_id: ?usize = null;
    var overlay_opened_at_ms: ?i64 = null;
    var last_overlay_tag: ?std.meta.Tag(SelectorOverlay) = null;

    var auth_flow: ?AuthFlow = null;
    defer if (auth_flow) |*value| value.deinit(allocator);

    var extension_bridge = ExtensionUiBridge.init(allocator, io);
    defer extension_bridge.deinit();
    live_resources.extension_command_sink = extension_bridge.commandSink();
    live_resources.extension_shortcut_sink = extension_bridge.shortcutSink();
    var reload_tools_context = ReloadExtensionToolsContext{
        .bootstrap = &bootstrap,
        .app_context = &app_context,
        .options = options,
        .app_state = &app_state,
    };
    live_resources.reload_extension_tools_sink = .{
        .context = &reload_tools_context,
        .callback = reloadExtensionToolsForInteractiveMode,
    };

    var prompt_worker: PromptWorker = undefined;
    var prompt_worker_active = false;
    defer if (prompt_worker_active) {
        _ = bootstrap.session.agent.abort();
        prompt_worker.join(allocator);
    };

    if (options.initial_prompt) |initial_prompt| {
        if (initial_prompt.len > 0) {
            for (options.initial_messages) |message| {
                try bootstrap.session.followUp(message, &.{});
            }
            try prompt_worker.start(allocator, &bootstrap.session, &app_state, initial_prompt, options.initial_images);
            prompt_worker_active = true;
        }
    }

    var should_exit = false;
    var input_buffer = std.ArrayList(u8).empty;
    defer input_buffer.deinit(allocator);
    var semantic_command_active = prompt_worker_active;
    if (semantic_command_active) {
        try ui_runtime.writeCommandStartMarker(&terminal);
    } else {
        try ui_runtime.writePromptReadyMarkers(&terminal);
    }

    while (true) {
        if (prompt_worker_active and !prompt_worker.running.load(.seq_cst)) {
            prompt_worker.join(allocator);
            prompt_worker_active = false;
            app_state.setToolOutputExpanded(true);
            renderer.markDirty();
            if (semantic_command_active) {
                const success = bootstrap.session.agent.getErrorMessage() == null;
                try ui_runtime.writeCommandDoneAndPromptReady(&terminal, success);
                try ui_runtime.writeCompletionNotification(
                    allocator,
                    &terminal,
                    "pi",
                    if (success) "Response complete" else "Response finished with an error",
                );
                semantic_command_active = false;
            }
            if (should_exit) break;
        }
        interactive_hooks.installSessionUiCallbacks(
            &bootstrap.session,
            .{ .context = &app_state, .callback = handleAppRetryLifecycleEvent },
            .{ .context = &app_state, .callback = handleAppCompactionLifecycleEvent },
        );
        if (app_state.pollBashExecution(allocator)) renderer.markDirty();

        try app_state.pollClipboardPaste(.{
            .vx = input_loop.vaxis_state,
            .tty = input_loop.loop.tty.writer(),
        });
        app_state.flushRetiredTerminalImages(.{
            .vx = input_loop.vaxis_state,
            .tty = input_loop.loop.tty.writer(),
        });

        const now_ms = nowMilliseconds();
        try extension_bridge.service(
            env_map,
            options.cwd,
            &terminal,
            &editor,
            &overlay,
            &app_state,
            &live_resources,
            &bootstrap.session,
            now_ms,
        );

        auth_flow_mod.pollAuthFlowCallback(
            allocator,
            io,
            env_map,
            &bootstrap.session,
            &bootstrap.current_provider,
            options,
            &app_state,
            &editor,
            &auth_flow,
            &live_resources,
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

        if (app_state.takeTerminalProgressUpdate()) |active| {
            if (ui_runtime.showTerminalProgress(live_resources.runtime_config)) {
                try ui_runtime.writeTerminalProgress(&terminal, active);
            }
        }
        if (!semantic_command_active and prompt_worker_active) {
            try ui_runtime.writeCommandStartMarker(&terminal);
            semantic_command_active = true;
        }
        try ui_runtime.updateInteractiveTerminalTitle(allocator, &terminal, &bootstrap.session, &last_terminal_title);

        if (should_exit and !prompt_worker_active) break;

        const background_render_active = prompt_worker_active or app_state.operation.bash_task.isActive();
        if (background_render_active) {
            renderer.markDirty();
        }

        var handled_input = false;
        while (try input_loop.tryInputEvent()) |event| {
            defer event.deinit(allocator);
            handled_input = true;
            renderer.markDirty();
            try dispatchInputEvent(
                allocator,
                io,
                env_map,
                event.parsed,
                &bootstrap.session,
                &bootstrap.current_provider,
                options.session_dir,
                options,
                bootstrap.built_tools.items,
                &app_state,
                &editor,
                &overlay,
                &auth_flow,
                &prompt_worker,
                &prompt_worker_active,
                subscriber,
                &should_exit,
                &input_buffer,
                &app_context,
                &live_resources,
            );
            if (app_context.suspend_requested) break;
        }
        if (app_context.suspend_requested) {
            try suspendInteractiveTerminal(allocator, io, env_map, &terminal, &input_loop, &app_state);
            app_context.suspend_requested = false;
            continue;
        }

        // Rebind live resource pointers after input handling. Auth/logout/settings
        // flows may have called live_resources.reload() during dispatchInputEvent(),
        // freeing the previous ResourceBundle and its Theme instances.
        const size = try terminal.refreshSize();
        screen.height = size.height;
        screen.overlay = if (overlay) |*value| value else null;
        screen.keybindings = live_resources.keybindings;
        screen.theme = live_resources.theme;
        screen.terminal_name = live_resources.terminal_name;
        screen.image_render_policy = if (live_resources.runtime_config) |config|
            .{ .enabled = config.showImages(), .width_cells = config.imageWidthCells() }
        else
            .{};
        screen.now_ms = now_ms;

        if (overlay) |*overlay_value| {
            const overlay_tag = std.meta.activeTag(overlay_value.*);
            if (last_overlay_tag == null or last_overlay_tag.? != overlay_tag) {
                overlay_opened_at_ms = now_ms;
            }
            last_overlay_tag = overlay_tag;

            const progress = overlayAnimationProgress(now_ms, overlay_opened_at_ms);
            overlay_panel = .{
                .overlay = overlay_value,
                .theme = live_resources.theme,
                .max_height = overlayPanelMaxHeight(size.height),
            };

            const overlay_options = overlayPanelOptions(size, progress);
            if (overlay_handle_id) |existing_id| {
                _ = renderer.updateDrawOverlay(existing_id, overlay_panel.?.drawComponent(), overlay_options);
            } else {
                overlay_handle_id = try renderer.showDrawOverlay(overlay_panel.?.drawComponent(), overlay_options);
            }
        } else {
            last_overlay_tag = null;
            overlay_opened_at_ms = null;
            overlay_panel = null;
            if (overlay_handle_id) |existing_id| {
                _ = renderer.removeOverlay(existing_id);
                overlay_handle_id = null;
            }
        }

        try renderer.renderToVaxis(screen.drawComponent(), input_loop.vaxis_state, input_loop.loop.tty.writer());

        if (!handled_input) {
            const sleep_ms: i64 = if (background_render_active) 16 else 50;
            std.Io.sleep(io, .fromMilliseconds(sleep_ms), .awake) catch {};
        }
    }

    return 0;
}

fn suspendInteractiveTerminal(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    terminal: *tui.Terminal,
    input_loop: **tui.terminal.InputLoop,
    app_state: *AppState,
) !void {
    if (builtin.os.tag == .windows) {
        try app_state.setStatus("Suspend to background is not supported on Windows");
        return;
    }

    input_loop.*.deinit();
    terminal.stop();

    if (!builtin.is_test) {
        std.posix.kill(0, .TSTP) catch |err| {
            try terminal.start();
            input_loop.* = try terminal.initInputLoop(allocator, io, env_map);
            const message = try std.fmt.allocPrint(allocator, "Suspend failed: {s}", .{@errorName(err)});
            defer allocator.free(message);
            try app_state.setStatus(message);
            return;
        };
    }

    try terminal.start();
    input_loop.* = try terminal.initInputLoop(allocator, io, env_map);
    input_loop.*.vaxis_state.queryTerminal(input_loop.*.loop.tty.writer(), .fromMilliseconds(250)) catch {};
    try app_state.setStatus("resumed");
}

/// Result of bootstrap that may want to short-circuit interactive mode (for
/// example, after a cancelled missing-cwd prompt).
const BootstrapOrExit = union(enum) {
    bootstrap: session_bootstrap.InteractiveBootstrap,
    exit_code: u8,
};

/// Attempts to bootstrap the interactive session. If the stored session cwd
/// no longer exists, prompts the user through a TUI Continue/Cancel selector
/// matching the TypeScript ExtensionSelectorComponent behavior; on cancel,
/// returns an exit code; on continue, retries the bootstrap with
/// `missing_cwd_mode = .use_fallback`.
fn bootstrapInteractiveStateOrPromptMissingCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    app_context: *AppContext,
    out_issue: *?session_bootstrap.OwnedMissingSessionCwdIssue,
    stderr_writer: *std.Io.Writer,
) !BootstrapOrExit {
    // Lifecycle ordering: run the missing-cwd preflight BEFORE provider auth /
    // tool construction. This guarantees the Continue/Cancel TUI selector
    // appears even when provider auth or model configuration would otherwise
    // fail later in bootstrap. Matches TypeScript main.ts which checks the
    // missing-cwd issue before constructing the runtime.
    //
    // When the caller already prompted the user via the earlier
    // pre-`prepareCliRuntime` lifecycle preflight, skip prompting again.
    if (!options.missing_cwd_already_confirmed) {
        if (try session_bootstrap.preflightInteractiveMissingCwd(allocator, io, options)) |captured_preflight| {
            var captured_preflight_mut = captured_preflight;
            defer captured_preflight_mut.deinit(allocator);
            const choice = try promptInteractiveMissingSessionCwd(
                allocator,
                io,
                env_map,
                captured_preflight_mut.issue(),
            );
            if (choice == .cancel) {
                try stderr_writer.writeAll("Resume cancelled\n");
                try stderr_writer.flush();
                return .{ .exit_code = 0 };
            }
            var fallback_options = options;
            fallback_options.missing_cwd_mode = .use_fallback;
            const retry = session_bootstrap.bootstrapInteractiveState(
                allocator,
                io,
                env_map,
                fallback_options,
                app_context,
            );
            if (retry) |state| return .{ .bootstrap = state } else |retry_err| switch (retry_err) {
                error.MissingApiKey,
                error.UnknownProvider,
                error.InvalidFauxStopReason,
                error.InvalidFauxTokensPerSecond,
                error.InvalidFauxContextWindow,
                error.InvalidFauxToolArguments,
                => {
                    try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(retry_err, options.provider)});
                    try stderr_writer.flush();
                    return .{ .exit_code = 1 };
                },
                else => return retry_err,
            }
        }
    }

    const initial = session_bootstrap.bootstrapInteractiveStateWithMissingCwd(
        allocator,
        io,
        env_map,
        options,
        app_context,
        out_issue,
    );
    if (initial) |state| {
        return .{ .bootstrap = state };
    } else |err| switch (err) {
        error.MissingApiKey,
        error.UnknownProvider,
        error.InvalidFauxStopReason,
        error.InvalidFauxTokensPerSecond,
        error.InvalidFauxContextWindow,
        error.InvalidFauxToolArguments,
        => {
            try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(err, options.provider)});
            try stderr_writer.flush();
            return .{ .exit_code = 1 };
        },
        error.MissingSessionCwd => {
            // Defensive fallback: if the preflight missed (for example a
            // session whose stored cwd disappeared between preflight and
            // open), reuse the same TUI selector flow.
            const captured = out_issue.* orelse {
                try stderr_writer.writeAll("Error: stored session working directory does not exist\n");
                try stderr_writer.flush();
                return .{ .exit_code = 1 };
            };
            const choice = try promptInteractiveMissingSessionCwd(
                allocator,
                io,
                env_map,
                captured.issue(),
            );
            if (choice == .cancel) {
                try stderr_writer.writeAll("Resume cancelled\n");
                try stderr_writer.flush();
                return .{ .exit_code = 0 };
            }
            var fallback_options = options;
            fallback_options.missing_cwd_mode = .use_fallback;
            const retry = session_bootstrap.bootstrapInteractiveState(
                allocator,
                io,
                env_map,
                fallback_options,
                app_context,
            );
            if (retry) |state| return .{ .bootstrap = state } else |retry_err| switch (retry_err) {
                error.MissingApiKey,
                error.UnknownProvider,
                error.InvalidFauxStopReason,
                error.InvalidFauxTokensPerSecond,
                error.InvalidFauxContextWindow,
                error.InvalidFauxToolArguments,
                => {
                    try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(retry_err, options.provider)});
                    try stderr_writer.flush();
                    return .{ .exit_code = 1 };
                },
                else => return retry_err,
            }
        },
        else => return err,
    }
}

/// Prompts the user via the full TUI Continue/Cancel selector to either
/// continue resuming the session in the launch cwd or cancel. Returns the
/// resolved `MissingCwdChoice`. Mirrors the TypeScript
/// `promptForMissingSessionCwd` flow that uses an ExtensionSelectorComponent
/// with options ["Continue", "Cancel"] before any session mutation.
fn promptInteractiveMissingSessionCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    issue: session_cwd_mod.MissingSessionCwdIssue,
) !missing_cwd_selector_mod.MissingCwdChoice {
    return missing_cwd_selector_mod.runMissingCwdSelector(allocator, io, env_map, issue);
}

fn appendConfigErrorStartupWarning(
    allocator: std.mem.Allocator,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
) !void {
    const config = runtime_config orelse return;
    try appendConfigErrorsStartupWarning(allocator, config.errors, app_state);
}

fn appendConfigErrorsStartupWarning(
    allocator: std.mem.Allocator,
    errors: []const config_mod.ConfigError,
    app_state: *AppState,
) !void {
    if (errors.len == 0) return;
    const first = errors[0];
    const warning = try std.fmt.allocPrint(
        allocator,
        "Config error: {d} issue{s}; first source={s} path={s}: {s}",
        .{
            errors.len,
            if (errors.len == 1) "" else "s",
            config_mod.configErrorSourceName(first.source),
            first.path,
            first.message,
        },
    );
    defer allocator.free(warning);
    try app_state.appendInfo(warning);
}

fn appendVerboseStartupState(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    keybindings: ?*const keybindings_mod.Keybindings,
    runtime_config: ?*const config_mod.RuntimeConfig,
    session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
    app_state: *AppState,
) !void {
    if (!options.verbose) return;

    const banner = try buildVerboseStartupBanner(allocator, keybindings);
    defer allocator.free(banner);
    try app_state.appendInfo(banner);

    const scoped_listing = try buildVerboseScopedModelsListing(
        allocator,
        env_map,
        session.agent.getModel(),
        current_provider,
        options.model_patterns,
        runtime_config,
    );
    defer if (scoped_listing) |text| allocator.free(text);
    if (scoped_listing) |text| {
        try app_state.appendInfo(text);
    }
}

fn buildVerboseStartupBanner(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
) ![]u8 {
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Esc");
    defer allocator.free(interrupt);
    const clear = try actionLabel(allocator, keybindings, .clear, "Ctrl+C");
    defer allocator.free(clear);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);
    const suspend_label = try actionLabel(allocator, keybindings, .app_suspend, "Ctrl+Z");
    defer allocator.free(suspend_label);
    const cycle_forward = try actionLabel(allocator, keybindings, .model_cycleForward, "Ctrl+P");
    defer allocator.free(cycle_forward);
    const cycle_backward = try actionLabel(allocator, keybindings, .model_cycleBackward, "Shift+Ctrl+P");
    defer allocator.free(cycle_backward);
    const open_models = try actionLabel(allocator, keybindings, .model_select, "Ctrl+L");
    defer allocator.free(open_models);
    const resume_session = try actionLabel(allocator, keybindings, .session_resume, "Unbound");
    defer allocator.free(resume_session);
    const tree_session = try actionLabel(allocator, keybindings, .session_tree, "Unbound");
    defer allocator.free(tree_session);
    const fork_session = try actionLabel(allocator, keybindings, .session_fork, "Unbound");
    defer allocator.free(fork_session);
    const new_session = try actionLabel(allocator, keybindings, .session_new, "Unbound");
    defer allocator.free(new_session);
    const follow_up = try actionLabel(allocator, keybindings, .message_followUp, "Alt+Enter");
    defer allocator.free(follow_up);
    const dequeue = try actionLabel(allocator, keybindings, .message_dequeue, "Alt+Up");
    defer allocator.free(dequeue);
    const tools_expand = try actionLabel(allocator, keybindings, .tools_expand, "Ctrl+O");
    defer allocator.free(tools_expand);
    const thinking_cycle = try actionLabel(allocator, keybindings, .thinking_cycle, "Shift+Tab");
    defer allocator.free(thinking_cycle);
    const thinking_toggle = try actionLabel(allocator, keybindings, .thinking_toggle, "Ctrl+T");
    defer allocator.free(thinking_toggle);
    const paste_image = try actionLabel(allocator, keybindings, .clipboard_pasteImage, "Ctrl+V");
    defer allocator.free(paste_image);

    return std.fmt.allocPrint(
        allocator,
        "Pi interactive mode (verbose startup)\n{s} interrupt • {s} clear ({s} twice exits) • {s} exit when empty • {s} suspend • {s}/{s} cycle models • {s} models • {s} resume • {s} tree • {s} fork • {s} new • {s} follow-up • {s} dequeue • {s} tools • {s} thinking level • {s} thinking visibility • {s} paste image • / commands • ! bash • !! bash no context",
        .{ interrupt, clear, clear, exit, suspend_label, cycle_forward, cycle_backward, open_models, resume_session, tree_session, fork_session, new_session, follow_up, dequeue, tools_expand, thinking_cycle, thinking_toggle, paste_image },
    );
}

fn buildVerboseScopedModelsListing(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: *const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !?[]u8 {
    _ = model_patterns orelse return null;

    const scoped_models = try loadSelectableModels(
        allocator,
        env_map,
        current_model,
        current_provider,
        model_patterns,
        runtime_config,
    );
    defer allocator.free(scoped_models);
    if (scoped_models.len == 0) return null;

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    try builder.appendSlice(allocator, "Scoped models (Ctrl+P / /scoped-models): ");
    for (scoped_models, 0..) |entry, index| {
        if (index != 0) try builder.appendSlice(allocator, ", ");
        const label = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.provider, entry.model_id });
        defer allocator.free(label);
        try builder.appendSlice(allocator, label);
    }

    return try builder.toOwnedSlice(allocator);
}

pub const testing = struct {
    pub const ReloadExtensionToolsContextForTesting = ReloadExtensionToolsContext;

    pub fn callReloadExtensionToolsForInteractiveMode(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
        session: *session_mod.AgentSession,
        live_resources: *LiveResources,
    ) !void {
        return reloadExtensionToolsForInteractiveMode(context, allocator, io, env_map, cwd, session, live_resources);
    }

    pub fn callWriteTerminalProgress(terminal: *tui.Terminal, active: bool) !void {
        return ui_runtime.writeTerminalProgress(terminal, active);
    }

    pub fn callUpdateInteractiveTerminalTitle(
        allocator: std.mem.Allocator,
        terminal: *tui.Terminal,
        session: *const session_mod.AgentSession,
        last_title: *?[]u8,
    ) !void {
        return ui_runtime.updateInteractiveTerminalTitle(allocator, terminal, session, last_title);
    }

    pub fn callAppendConfigErrorsStartupWarning(
        allocator: std.mem.Allocator,
        errors: []const config_mod.ConfigError,
        app_state: *AppState,
    ) !void {
        return appendConfigErrorsStartupWarning(allocator, errors, app_state);
    }

    pub fn callAppendExtensionStartupDiagnosticsToAppState(
        allocator: std.mem.Allocator,
        diagnostics: []const tool_registry.ExtensionStartupDiagnostic,
        app_state: *AppState,
        show_optional: bool,
    ) !void {
        return appendExtensionStartupDiagnosticsToAppState(allocator, diagnostics, app_state, show_optional);
    }

    pub fn callAppendVerboseStartupState(
        allocator: std.mem.Allocator,
        env_map: *const std.process.Environ.Map,
        options: RunInteractiveModeOptions,
        keybindings: ?*const keybindings_mod.Keybindings,
        runtime_config: ?*const config_mod.RuntimeConfig,
        session: *const session_mod.AgentSession,
        current_provider: *const provider_config.ResolvedProviderConfig,
        app_state: *AppState,
    ) !void {
        return appendVerboseStartupState(allocator, env_map, options, keybindings, runtime_config, session, current_provider, app_state);
    }
};

test {
    _ = @import("interactive_mode/tests.zig");
}
