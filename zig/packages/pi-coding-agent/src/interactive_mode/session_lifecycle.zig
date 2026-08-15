const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const config_mod = @import("../config/config.zig");
const provider_config = @import("../providers/provider_config.zig");
const session_mod = @import("../sessions/session.zig");
const session_advanced = @import("../sessions/session_advanced.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");

const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const currentSessionLabel = shared.currentSessionLabel;
const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
const configuredCompactionSettings = shared.configuredCompactionSettings;
const configuredRetrySettings = shared.configuredRetrySettings;
const overrideApiKeyForProvider = shared.overrideApiKeyForProvider;
const SelectorOverlay = overlays.SelectorOverlay;
const loadForkOverlay = overlays.loadForkOverlay;
const AppState = rendering.AppState;
const rebuildAppStateFromSession = rendering.rebuildAppStateFromSession;

pub fn createSeededSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    system_prompt: []const u8,
    model: ai.Model,
    api_key: ?[]const u8,
    thinking_level: agent.ThinkingLevel,
    tool_items: []const agent.AgentTool,
    compaction_settings: session_mod.CompactionSettings,
    retry_settings: session_mod.RetrySettings,
    session_dir: ?[]const u8,
    messages: []const agent.AgentMessage,
) !session_mod.AgentSession {
    var session = try session_mod.AgentSession.create(allocator, io, .{
        .cwd = cwd,
        .system_prompt = system_prompt,
        .model = model,
        .api_key = api_key,
        .thinking_level = thinking_level,
        .session_dir = session_dir,
        .tools = tool_items,
        .compaction = compaction_settings,
        .retry = retry_settings,
    });
    errdefer session.deinit();

    for (messages) |message| {
        _ = try session.session_manager.appendMessage(message);
    }
    try session.agent.setMessages(messages);

    return session;
}

pub fn switchSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_path: []const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    var candidate = try session_mod.AgentSession.open(allocator, io, .{
        .session_file = session_path,
        .cwd_override = options.cwd,
        .system_prompt = options.system_prompt,
        .tools = tool_items,
        .thinking_level = options.thinking,
        .compaction = configuredCompactionSettings(runtime_config),
        .retry = configuredRetrySettings(runtime_config),
    });
    errdefer candidate.deinit();

    var candidate_provider = provider_config.resolveProviderConfig(
        allocator,
        io,
        env_map,
        candidate.agent.getModel().provider,
        candidate.agent.getModel().id,
        overrideApiKeyForProvider(options, candidate.agent.getModel().provider),
        configuredApiKeyForProvider(runtime_config, candidate.agent.getModel().provider),
    ) catch |err| {
        try presentProviderSelectionError(
            allocator,
            app_state,
            provider_config.resolveProviderErrorMessage(err, candidate.agent.getModel().provider),
            "session switch failed",
        );
        return;
    };
    errdefer candidate_provider.deinit(allocator);

    candidate.setApiKey(candidate_provider.api_key);

    _ = session.agent.unsubscribe(subscriber);
    session.deinit();
    current_provider.deinit(allocator);

    session.* = candidate;
    current_provider.* = candidate_provider;
    try session.agent.subscribe(subscriber);

    try rebuildAppStateFromSession(allocator, session.io, app_state, session, current_provider);
}

pub fn handleNewSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    var candidate = try createSeededSession(
        allocator,
        io,
        options.cwd,
        options.system_prompt,
        current_provider.model,
        current_provider.api_key,
        session.agent.getThinkingLevel(),
        tool_items,
        configuredCompactionSettings(options.runtime_config),
        configuredRetrySettings(options.runtime_config),
        if (session.session_manager.getSessionDir().len > 0) session_dir else null,
        &.{},
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    try app_state.appendInfo("New session started");
}

pub fn formatSessionInfo(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = session_advanced.getSessionStats(session);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("Session Info\n");
    if (session.session_manager.getSessionName()) |name| {
        try writer.writer.print("Name: {s}\n", .{name});
    }
    try writer.writer.print("File: {s}\n", .{stats.session_file orelse "in-memory"});
    try writer.writer.print("ID: {s}\n", .{stats.session_id});
    try writer.writer.print("Model: {s}/{s}\n", .{ session.agent.getModel().provider, session.agent.getModel().id });
    try writer.writer.print(
        "Messages: user={d}, assistant={d}, tool_calls={d}, tool_results={d}, total={d}\n",
        .{ stats.user_messages, stats.assistant_messages, stats.tool_calls, stats.tool_results, stats.total_messages },
    );
    try writer.writer.print(
        "Tokens: input={d}, output={d}, cache_read={d}, cache_write={d}, total={d}\n",
        .{ stats.tokens.input, stats.tokens.output, stats.tokens.cache_read, stats.tokens.cache_write, stats.tokens.total },
    );
    if (stats.context_usage) |usage| {
        try writer.writer.print(
            "Context: {d}/{d} tokens ({d:.1}%)\n",
            .{ usage.tokens orelse 0, usage.context_window, usage.percent orelse 0 },
        );
    }
    if (stats.cost > 0) {
        try writer.writer.print("Cost: {d:.4}\n", .{stats.cost});
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn cloneCurrentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    const messages = session.agent.getMessages();
    if (messages.len == 0) {
        try app_state.setStatus("Nothing to clone yet");
        return;
    }

    const leaf_id = session.session_manager.getLeafId() orelse {
        try app_state.setStatus("Nothing to clone yet");
        return;
    };

    var candidate = try createForkedSessionFromLeaf(
        allocator,
        io,
        session,
        current_provider,
        session_dir,
        tool_items,
        leaf_id,
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    const message = try std.fmt.allocPrint(allocator, "Cloned session to {s}", .{currentSessionLabel(session)});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn loadForkOverlayOrStatus(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
) !void {
    overlay.* = loadForkOverlay(allocator, session) catch |err| switch (err) {
        error.NoMessagesToFork => {
            try app_state.setStatus("No messages to fork from");
            return;
        },
        else => return err,
    };
}

pub fn forkCurrentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    const messages = session.agent.getMessages();
    const last_user_index = findLastUserMessageIndex(messages) orelse {
        try app_state.setStatus("No messages to fork from");
        return;
    };

    var candidate = try createDerivedSession(
        allocator,
        io,
        session,
        current_provider,
        session_dir,
        tool_items,
        messages[0 .. last_user_index + 1],
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    const message = try std.fmt.allocPrint(allocator, "Forked session at the latest user message into {s}", .{currentSessionLabel(session)});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn forkCurrentSessionBeforeUserMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    entry_id: []const u8,
    app_state: *AppState,
    editor: *tui.Editor,
    subscriber: agent.AgentSubscriber,
) !void {
    const selected_entry = session.session_manager.getEntry(entry_id) orelse {
        try app_state.setStatus("Invalid entry ID for forking");
        return;
    };
    if (selected_entry.* != .message or selected_entry.message.message != .user) {
        try app_state.setStatus("Invalid entry ID for forking");
        return;
    }

    const selected_text = try textBlocksConcat(allocator, selected_entry.message.message.user.content);
    defer allocator.free(selected_text);
    const target_leaf_id = selected_entry.message.parent_id;

    var candidate = try createForkedSessionFromLeaf(
        allocator,
        io,
        session,
        current_provider,
        session_dir,
        tool_items,
        target_leaf_id,
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    editor.reset();
    if (selected_text.len > 0) {
        _ = try editor.handlePaste(selected_text);
    }
    try app_state.setStatus("Forked to new session");
}

pub fn createForkedSessionFromLeaf(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    target_leaf_id: ?[]const u8,
) !session_mod.AgentSession {
    var manager = try allocator.create(session_manager_mod.SessionManager);
    errdefer allocator.destroy(manager);

    manager.* = if (target_leaf_id) |leaf_id|
        try source_session.session_manager.createBranchedSession(leaf_id)
    else if (source_session.session_manager.getSessionFile() != null and session_dir.len > 0)
        try session_manager_mod.SessionManager.createWithParent(
            allocator,
            io,
            source_session.cwd,
            session_dir,
            source_session.session_manager.getSessionFile(),
        )
    else
        try session_manager_mod.SessionManager.inMemory(allocator, io, source_session.cwd);

    const cwd = manager.getCwd();
    return session_mod.AgentSession.createWithManager(
        allocator,
        io,
        manager,
        .{
            .cwd = cwd,
            .system_prompt = source_session.system_prompt,
            .model = current_provider.model,
            .api_key = current_provider.api_key,
            .thinking_level = source_session.agent.getThinkingLevel(),
            .tools = tool_items,
            .compaction = source_session.compaction_settings,
            .retry = source_session.retry_settings,
        },
    ) catch |err| {
        manager.deinit();
        allocator.destroy(manager);
        return err;
    };
}

fn textBlocksConcat(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            else => {},
        }
    }
    const text = std.mem.trim(u8, out.items, " \t\r\n");
    const owned = try allocator.dupe(u8, text);
    out.deinit(allocator);
    return owned;
}

pub fn createDerivedSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    messages: []const agent.AgentMessage,
) !session_mod.AgentSession {
    var derived = try session_mod.AgentSession.create(allocator, io, .{
        .cwd = source_session.cwd,
        .system_prompt = source_session.system_prompt,
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .thinking_level = source_session.agent.getThinkingLevel(),
        .tools = tool_items,
        .session_dir = session_dir,
    });
    errdefer derived.deinit();

    for (messages) |message| {
        _ = try derived.session_manager.appendMessage(message);
    }
    try derived.agent.setMessages(messages);
    derived.agent.setModel(current_provider.model);
    derived.agent.setApiKey(current_provider.api_key);
    return derived;
}

pub fn replaceCurrentSession(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    candidate: *session_mod.AgentSession,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    _ = session.agent.unsubscribe(subscriber);
    session.deinit();
    session.* = candidate.*;
    candidate.* = undefined;
    try session.agent.subscribe(subscriber);
    try rebuildAppStateFromSession(allocator, session.io, app_state, session, null);
    try app_state.setStatus("idle");
}

pub fn navigateTree(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    entry_id: []const u8,
    app_state: *AppState,
    editor: *tui.Editor,
    options: session_mod.AgentSession.NavigateTreeOptions,
) !void {
    var result = try session.navigateTree(allocator, entry_id, options);
    defer result.deinit(allocator);
    try rebuildAppStateFromSession(allocator, session.io, app_state, session, null);
    if (result.editor_text) |text| {
        if (std.mem.trim(u8, editor.text(), " \t\r\n").len == 0 and text.len > 0) {
            editor.reset();
            _ = try editor.handlePaste(text);
        }
    }
    try app_state.setStatus(if (result.summary_entry_id != null) "session tree updated with branch summary" else "session tree updated");
}

pub fn findLastUserMessageIndex(messages: []const agent.AgentMessage) ?usize {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (messages[index] == .user) return index;
    }
    return null;
}

pub fn resolveSessionPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    cwd: []const u8,
    session_ref: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(session_ref) or std.mem.indexOfScalar(u8, session_ref, '/') != null) {
        return if (std.fs.path.isAbsolute(session_ref))
            allocator.dupe(u8, session_ref)
        else
            std.fs.path.resolve(allocator, &[_][]const u8{ cwd, session_ref });
    }

    var dir = try std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, session_ref)) continue;
        return try std.fs.path.join(allocator, &[_][]const u8{ session_dir, entry.name });
    }

    return error.FileNotFound;
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
