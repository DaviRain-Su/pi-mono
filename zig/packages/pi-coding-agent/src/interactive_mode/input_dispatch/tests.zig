const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const tui = @import("tui");
const config_mod = @import("../../config/config.zig");
const keybindings_mod = @import("../../shared/keybindings.zig");
const provider_config = @import("../../providers/provider_config.zig");
const resources_mod = @import("../../resources/resources.zig");
const session_mod = @import("../../sessions/session.zig");
const shared = @import("../shared.zig");
const overlays = @import("../overlays.zig");
const rendering = @import("../rendering.zig");
const prompt_worker_mod = @import("../prompt_worker.zig");
const extension_dialog = @import("../extension_dialog.zig");
const input_dispatch = @import("../input_dispatch.zig");

const AppContext = shared.AppContext;
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const AppState = rendering.AppState;
const PromptWorker = prompt_worker_mod.PromptWorker;
const handleProtocolEvent = input_dispatch.testing.handleProtocolEvent;
const cycleThinkingLevel = input_dispatch.testing.cycleThinkingLevel;
const legacyAppActionForKey = input_dispatch.legacyAppActionForKey;
const handleInputKeyWithModifiers = input_dispatch.handleInputKeyWithModifiers;
const submitEditorText = input_dispatch.submitEditorText;
const dispatchInputEvent = input_dispatch.dispatchInputEvent;
const loadEditorAutocompleteItemsWithResources = input_dispatch.loadEditorAutocompleteItemsWithResources;
const freeOwnedSelectItems = input_dispatch.freeOwnedSelectItems;

test "protocol events update kitty state through app context" {
    var app_context = AppContext.init("/tmp", std.testing.io);
    try std.testing.expect(!app_context.kitty_protocol_active);

    handleProtocolEvent(&app_context, .{ .kitty_keyboard = 31 });

    try std.testing.expect(app_context.kitty_protocol_active);
}

test "legacy app actions include clipboard image paste" {
    try std.testing.expectEqual(keybindings_mod.Action.clipboard_pasteImage, legacyAppActionForKey(.{ .ctrl = 'v' }).?);
    try std.testing.expectEqual(keybindings_mod.Action.editor_external, legacyAppActionForKey(.{ .ctrl = 'g' }).?);
    try std.testing.expect(legacyAppActionForKey(.{ .ctrl = 'r' }) == null);
}

test "thinking cycle skips xhigh unless the active model supports it" {
    const allocator = std.testing.allocator;

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .model = ai.model_registry.find("anthropic", "claude-sonnet-4-5").?,
    });
    defer session.deinit();
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try cycleThinkingLevel(&session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.minimal, session.agent.getThinkingLevel());
    try cycleThinkingLevel(&session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.low, session.agent.getThinkingLevel());
    try cycleThinkingLevel(&session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.medium, session.agent.getThinkingLevel());
    try cycleThinkingLevel(&session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.high, session.agent.getThinkingLevel());
    try cycleThinkingLevel(&session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.off, session.agent.getThinkingLevel());
    try std.testing.expectEqualStrings("Thinking level: off", state.footer.status);

    var xhigh_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .model = ai.model_registry.find("openai", "gpt-5.5").?,
        .thinking_level = .high,
    });
    defer xhigh_session.deinit();
    try cycleThinkingLevel(&xhigh_session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.xhigh, xhigh_session.agent.getThinkingLevel());
}

test "thinking cycle reports unsupported model without changing level" {
    const allocator = std.testing.allocator;

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .model = ai.model_registry.find("faux", "faux-1").?,
    });
    defer session.deinit();
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try cycleThinkingLevel(&session, &state);
    try std.testing.expectEqual(agent.ThinkingLevel.off, session.agent.getThinkingLevel());
    try std.testing.expectEqualStrings("Current model does not support thinking", state.footer.status);
}

fn ignoreAgentEvent(_: ?*anyopaque, _: agent.AgentEvent) anyerror!void {}

test "configured app keybindings drive clear exit and suspend while old defaults stop" {
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

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("draft");

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.clear, &.{.{ .ctrl = 'x' }});
    try keybindings.setBinding(.exit, &.{.{ .ctrl = 'q' }});
    try keybindings.setBinding(.app_suspend, &.{.{ .ctrl = 'y' }});

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp",
        .system_prompt = "sys",
        .session_dir = "/tmp/pi-input-dispatch-test-sessions",
        .provider = "faux",
        .keybindings = &keybindings,
    };
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var auth_flow: ?AuthFlow = null;
    defer if (auth_flow) |*value| value.deinit(allocator);
    var prompt_worker: PromptWorker = undefined;
    var prompt_worker_active = false;
    var should_exit = false;
    var app_context = AppContext.init(options.cwd, std.testing.io);
    const subscriber = agent.AgentSubscriber{ .callback = ignoreAgentEvent };

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'c' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expectEqualStrings("draft", editor.text());
    try std.testing.expect(!should_exit);

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'x' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expect(!should_exit);

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'x' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expect(should_exit);

    should_exit = false;
    _ = try editor.handlePaste("keep");

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'd' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expectEqualStrings("keep", editor.text());
    try std.testing.expect(!should_exit);

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'q' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expectEqualStrings("keep", editor.text());
    try std.testing.expect(!should_exit);

    editor.reset();
    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'q' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expect(should_exit);

    app_context.suspend_requested = false;
    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'z' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expect(!app_context.suspend_requested);

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'y' },
        .{},
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &app_context,
        &live_resources,
    );
    try std.testing.expect(app_context.suspend_requested);
}

fn makeInputDispatchTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_path = if (name.len == 0)
        try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path })
    else
        try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, name });
    defer allocator.free(relative_path);
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn waitForBashCompletion(app_state: *AppState, allocator: std.mem.Allocator) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (app_state.pollBashExecution(allocator)) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    }
    return error.BashCompletionTimeout;
}

const BashSubmitHarness = struct {
    allocator: std.mem.Allocator,
    env_map: std.process.Environ.Map,
    current_provider: provider_config.ResolvedProviderConfig,
    session: session_mod.AgentSession,
    state: AppState,
    editor: tui.Editor,
    options: RunInteractiveModeOptions,
    live_resources: LiveResources,
    overlay: ?SelectorOverlay = null,
    auth_flow: ?AuthFlow = null,
    prompt_worker: PromptWorker = undefined,
    prompt_worker_active: bool = false,
    should_exit: bool = false,
    subscriber: agent.AgentSubscriber = .{ .callback = ignoreAgentEvent },

    fn init(allocator: std.mem.Allocator, cwd: []const u8, session_dir: []const u8) !BashSubmitHarness {
        var env_map = std.process.Environ.Map.init(allocator);
        errdefer env_map.deinit();

        var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
        errdefer current_provider.deinit(allocator);

        var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
            .cwd = cwd,
            .system_prompt = "sys",
            .model = current_provider.model,
            .api_key = current_provider.api_key,
            .session_dir = session_dir,
        });
        errdefer session.deinit();

        var state = try AppState.init(allocator, std.testing.io);
        errdefer state.deinit();

        var editor = tui.Editor.init(allocator);
        errdefer editor.deinit();

        const options = RunInteractiveModeOptions{
            .cwd = cwd,
            .system_prompt = "sys",
            .session_dir = session_dir,
            .provider = "faux",
        };
        const live_resources = LiveResources.init(options);

        return .{
            .allocator = allocator,
            .env_map = env_map,
            .current_provider = current_provider,
            .session = session,
            .state = state,
            .editor = editor,
            .options = options,
            .live_resources = live_resources,
        };
    }

    fn deinit(self: *BashSubmitHarness) void {
        if (self.overlay) |*value| value.deinit(self.allocator);
        if (self.auth_flow) |*value| value.deinit(self.allocator);
        self.live_resources.deinit(self.allocator);
        self.editor.deinit();
        self.state.deinit();
        self.session.deinit();
        self.current_provider.deinit(self.allocator);
        self.env_map.deinit();
    }

    fn submit(self: *BashSubmitHarness, text: []const u8) !void {
        self.editor.reset();
        _ = try self.editor.handlePaste(text);
        try submitEditorText(
            self.allocator,
            std.testing.io,
            &self.env_map,
            std.mem.trim(u8, self.editor.text(), " \t\r\n"),
            &self.session,
            &self.current_provider,
            self.options.session_dir,
            self.options,
            &.{},
            &self.state,
            &self.editor,
            &self.overlay,
            &self.auth_flow,
            &self.prompt_worker,
            &self.prompt_worker_active,
            self.subscriber,
            &self.should_exit,
            &self.live_resources,
        );
    }

    fn press(self: *BashSubmitHarness, key: tui.Key, modifiers: tui.keys.KeyModifiers) !void {
        var app_context = AppContext.init(self.options.cwd, std.testing.io);
        try handleInputKeyWithModifiers(
            self.allocator,
            std.testing.io,
            &self.env_map,
            key,
            modifiers,
            &self.session,
            &self.current_provider,
            self.options.session_dir,
            self.options,
            &.{},
            &self.state,
            &self.editor,
            &self.overlay,
            &self.auth_flow,
            &self.prompt_worker,
            &self.prompt_worker_active,
            self.subscriber,
            &self.should_exit,
            &app_context,
            &self.live_resources,
        );
    }
};

fn makeExtensionChoiceDialog(allocator: std.mem.Allocator, kind: extension_dialog.DialogKind) !extension_dialog.ExtensionDialog {
    const first_value = if (kind == .confirm) "yes" else "alpha";
    const second_value = if (kind == .confirm) "no" else "beta";
    const first_label = if (kind == .confirm) "Yes" else "Alpha";
    const second_label = if (kind == .confirm) "No" else "Beta";

    var choices = try allocator.alloc([]u8, 2);
    var choices_initialized: usize = 0;
    errdefer {
        for (choices[0..choices_initialized]) |choice| allocator.free(choice);
        allocator.free(choices);
    }
    choices[0] = try allocator.dupe(u8, first_value);
    choices_initialized = 1;
    choices[1] = try allocator.dupe(u8, second_value);
    choices_initialized = 2;

    var items = try allocator.alloc(tui.SelectItem, 2);
    var items_initialized: usize = 0;
    errdefer {
        for (items[0..items_initialized]) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }
    items[0] = try makeExtensionDialogTestItem(allocator, first_value, first_label);
    items_initialized = 1;
    items[1] = try makeExtensionDialogTestItem(allocator, second_value, second_label);
    items_initialized = 2;

    return .{
        .id = try allocator.dupe(u8, "dialog-1"),
        .kind = kind,
        .title = try allocator.dupe(u8, if (kind == .confirm) "Confirm" else "Pick"),
        .hint = try allocator.dupe(u8, "Up/Down move • Enter select • Esc cancel"),
        .choices = choices,
        .items = items,
        .list = .{ .items = items, .max_visible = 2 },
        .editor = tui.Editor.init(allocator),
    };
}

fn makeExtensionDialogTestItem(
    allocator: std.mem.Allocator,
    value: []const u8,
    label: []const u8,
) !tui.SelectItem {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    return .{
        .value = owned_value,
        .label = owned_label,
    };
}

test "extension dialog keeps tools expand key available through app keybindings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.tools_expand, &.{.{ .ctrl = '9' }});
    harness.live_resources.keybindings = &custom_keybindings;

    try harness.state.appendItemLocked(.tool_result, "tool result output");
    harness.state.setToolOutputExpanded(false);
    harness.overlay = .{ .extension_dialog = try makeExtensionChoiceDialog(allocator, .select) };

    try harness.press(.{ .ctrl = '9' }, .{});
    try std.testing.expect(harness.state.stream.all_expanded);
    try std.testing.expect(harness.state.stream.tool_output_expanded);
    try std.testing.expect(harness.overlay != null);
    try std.testing.expectEqual(.extension_dialog, std.meta.activeTag(harness.overlay.?));
    try std.testing.expect(harness.overlay.?.extension_dialog.resolved_payload_json == null);
    try std.testing.expectEqual(@as(usize, 0), harness.overlay.?.extension_dialog.list.selectedIndex());

    try harness.press(.down, .{});
    try std.testing.expectEqual(@as(usize, 1), harness.overlay.?.extension_dialog.list.selectedIndex());
    try harness.press(.enter, .{});
    try std.testing.expectEqualStrings("{\"value\":\"beta\"}", harness.overlay.?.extension_dialog.resolved_payload_json.?);

    if (harness.overlay) |*value| {
        value.deinit(allocator);
        harness.overlay = null;
    }

    harness.overlay = .{ .extension_dialog = try makeExtensionChoiceDialog(allocator, .confirm) };
    try harness.press(.escape, .{});
    try std.testing.expectEqualStrings("{\"cancelled\":true}", harness.overlay.?.extension_dialog.resolved_payload_json.?);
}

test "configured editor keybindings drive movement and submit while old defaults stop" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setEditorBinding(.cursor_left, &.{.{ .ctrl = 'h' }});
    try custom_keybindings.setEditorBinding(.input_submit, &.{.{ .ctrl = 'j' }});
    try custom_keybindings.setEditorBinding(.input_new_line, &.{.{ .ctrl = '9' }});
    harness.live_resources.keybindings = &custom_keybindings;

    _ = try harness.editor.handlePaste("ab");
    try harness.press(.left, .{});
    try harness.press(.{ .printable = tui.keys.PrintableKey.fromSlice("X") }, .{});
    try std.testing.expectEqualStrings("abX", harness.editor.text());

    harness.editor.reset();
    _ = try harness.editor.handlePaste("ab");
    try harness.press(.{ .ctrl = 'h' }, .{});
    try harness.press(.{ .printable = tui.keys.PrintableKey.fromSlice("X") }, .{});
    try std.testing.expectEqualStrings("aXb", harness.editor.text());

    harness.editor.reset();
    _ = try harness.editor.handlePaste("line");
    try harness.press(.enter, .{});
    try std.testing.expectEqualStrings("line", harness.editor.text());
    try harness.press(.{ .ctrl = '9' }, .{});
    try std.testing.expectEqualStrings("line\n", harness.editor.text());

    harness.editor.reset();
    _ = try harness.editor.handlePaste("/hotkeys");
    try harness.press(.enter, .{});
    try std.testing.expectEqualStrings("/hotkeys", harness.editor.text());
    try harness.press(.{ .ctrl = 'j' }, .{});
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expect(harness.state.chat.items.items.len > 0);
}

test "empty prompt page bindings scroll chat history instead of editor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    harness.state.updateChatScrollLayout(40, 10, 0, 80);
    try harness.press(.page_up, .{});
    try std.testing.expectEqual(@as(usize, 9), harness.state.chat.scroll_offset);
    try harness.press(.page_down, .{});
    try std.testing.expectEqual(@as(usize, 0), harness.state.chat.scroll_offset);

    _ = try harness.editor.handlePaste("l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7");
    harness.state.chat.scroll_offset = 10;
    try harness.press(.page_up, .{});
    try std.testing.expectEqual(@as(usize, 10), harness.state.chat.scroll_offset);
    const cursor = harness.editor.cursorPosition();
    try std.testing.expectEqual(@as(usize, 2), cursor.line);
    try std.testing.expectEqual(@as(usize, 2), cursor.column);
}

test "chat history page scroll uses configured page bindings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setEditorBinding(.page_up, &.{.{ .alt = 'u' }});
    try custom_keybindings.setEditorBinding(.page_down, &.{.{ .alt = 'd' }});
    harness.live_resources.keybindings = &custom_keybindings;

    harness.state.updateChatScrollLayout(40, 10, 0, 80);
    try harness.press(.page_up, .{});
    try std.testing.expectEqual(@as(usize, 0), harness.state.chat.scroll_offset);

    try harness.press(.{ .printable = tui.keys.PrintableKey.fromSlice("u") }, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 9), harness.state.chat.scroll_offset);
    try harness.press(.{ .printable = tui.keys.PrintableKey.fromSlice("d") }, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 0), harness.state.chat.scroll_offset);
}

test "dispatch input event resolves message actions from configured bindings only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.message_followUp, &.{.{ .ctrl = 'r' }});
    try custom_keybindings.setBinding(.message_dequeue, &.{.{ .ctrl = 'e' }});
    harness.live_resources.keybindings = &custom_keybindings;

    var input_buffer = std.ArrayList(u8).empty;
    defer input_buffer.deinit(allocator);
    var app_context = AppContext.init(cwd, std.testing.io);

    _ = try harness.editor.handlePaste("/hotkeys");
    const items_before_old_default = harness.state.chat.items.items.len;
    try dispatchInputEvent(
        allocator,
        std.testing.io,
        &harness.env_map,
        .{ .event = .{ .key = .enter }, .consumed = 0, .modifiers = .{ .alt = true } },
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &input_buffer,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("/hotkeys", harness.editor.text());
    try std.testing.expectEqual(items_before_old_default, harness.state.chat.items.items.len);

    try dispatchInputEvent(
        allocator,
        std.testing.io,
        &harness.env_map,
        .{ .event = .{ .key = .{ .ctrl = 'r' } }, .consumed = 0 },
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &input_buffer,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expect(harness.state.chat.items.items.len > 0);

    try harness.session.followUp("queued", &.{});
    try harness.state.appendQueuedMessage(.follow_up, "queued");
    _ = try harness.editor.handlePaste("draft");

    try dispatchInputEvent(
        allocator,
        std.testing.io,
        &harness.env_map,
        .{ .event = .{ .key = .up }, .consumed = 0, .modifiers = .{ .alt = true } },
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &input_buffer,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("draft", harness.editor.text());
    try std.testing.expectEqual(@as(usize, 1), harness.state.queue.follow_up.items.len);

    try dispatchInputEvent(
        allocator,
        std.testing.io,
        &harness.env_map,
        .{ .event = .{ .key = .{ .ctrl = 'e' } }, .consumed = 0 },
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &input_buffer,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("queued\n\ndraft", harness.editor.text());
    try std.testing.expectEqual(@as(usize, 0), harness.state.queue.follow_up.items.len);
}

test "enter inserts newline after trailing backslash and shift enter inserts newline" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    _ = try harness.editor.handlePaste("line\\");
    try harness.press(.enter, .{});
    try std.testing.expectEqualStrings("line\n", harness.editor.text());
    try std.testing.expect(!harness.prompt_worker_active);

    try harness.press(.enter, .{ .shift = true });
    try std.testing.expectEqualStrings("line\n\n", harness.editor.text());
    try std.testing.expect(!harness.prompt_worker_active);
}

test "resource autocomplete includes prompt templates and skill commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);

    var template = resources_mod.PromptTemplate{
        .name = try allocator.dupe(u8, "fix"),
        .description = try allocator.dupe(u8, "Fix an issue"),
        .argument_hint = try allocator.dupe(u8, "<bug>"),
        .content = try allocator.dupe(u8, "Fix $ARGUMENTS"),
        .file_path = try allocator.dupe(u8, "/tmp/fix.md"),
        .source_info = .{
            .path = try allocator.dupe(u8, "/tmp/fix.md"),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = null,
        },
    };
    defer template.deinit(allocator);
    var skill = resources_mod.Skill{
        .name = try allocator.dupe(u8, "reviewer"),
        .description = try allocator.dupe(u8, "Review code"),
        .file_path = try allocator.dupe(u8, "/tmp/reviewer/SKILL.md"),
        .base_dir = try allocator.dupe(u8, "/tmp/reviewer"),
        .source_info = .{
            .path = try allocator.dupe(u8, "/tmp/reviewer/SKILL.md"),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = null,
        },
    };
    defer skill.deinit(allocator);

    const items = try loadEditorAutocompleteItemsWithResources(allocator, std.testing.io, cwd, &.{template}, &.{skill}, true);
    defer freeOwnedSelectItems(allocator, items);

    var saw_template = false;
    var saw_skill = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.value, "/fix ")) saw_template = true;
        if (std.mem.eql(u8, item.value, "/skill:reviewer ")) saw_skill = true;
    }
    try std.testing.expect(saw_template);
    try std.testing.expect(saw_skill);
}

test "command pipeline expands skill before prompt template and unknown slash errors before queue" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const skill_dir = try makeInputDispatchTestPath(allocator, tmp, "skills/reviewer");
    defer allocator.free(skill_dir);
    const skill_path = try makeInputDispatchTestPath(allocator, tmp, "skills/reviewer/SKILL.md");
    defer allocator.free(skill_path);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, skill_dir);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = skill_path,
        .data =
        \\---
        \\name: reviewer
        \\description: Review code
        \\---
        \\Use the reviewer skill.
        \\
        ,
    });

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var skill = resources_mod.Skill{
        .name = try allocator.dupe(u8, "reviewer"),
        .description = try allocator.dupe(u8, "Review code"),
        .file_path = try allocator.dupe(u8, skill_path),
        .base_dir = try allocator.dupe(u8, skill_dir),
        .source_info = .{
            .path = try allocator.dupe(u8, skill_path),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = try allocator.dupe(u8, skill_dir),
        },
    };
    defer skill.deinit(allocator);
    var conflicting_template = resources_mod.PromptTemplate{
        .name = try allocator.dupe(u8, "skill:reviewer"),
        .description = try allocator.dupe(u8, "Conflicting template"),
        .content = try allocator.dupe(u8, "template fallback $ARGUMENTS"),
        .file_path = try allocator.dupe(u8, "/tmp/skill-reviewer.md"),
        .source_info = .{
            .path = try allocator.dupe(u8, "/tmp/skill-reviewer.md"),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = null,
        },
    };
    defer conflicting_template.deinit(allocator);
    harness.live_resources.skills = &.{skill};
    harness.live_resources.prompt_templates = &.{conflicting_template};

    harness.prompt_worker_active = true;
    harness.session.compaction_active.store(true, .seq_cst);
    defer harness.session.compaction_active.store(false, .seq_cst);

    try harness.submit("/skill:reviewer focus src");
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expectEqual(@as(usize, 1), harness.state.queue.steering.items.len);
    try std.testing.expect(std.mem.indexOf(u8, harness.state.queue.steering.items[0], "<skill name=\"reviewer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.state.queue.steering.items[0], "focus src") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.state.queue.steering.items[0], "template fallback") == null);

    try harness.submit("/definitely-unknown");
    try std.testing.expectEqual(@as(usize, 1), harness.state.queue.steering.items.len);
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expectEqualStrings("Unknown slash command: /definitely-unknown", harness.state.footer.status);
}

test "retry countdown preserves command entry queue and interrupt cancels retry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var template = resources_mod.PromptTemplate{
        .name = try allocator.dupe(u8, "fix"),
        .description = try allocator.dupe(u8, "Fix"),
        .content = try allocator.dupe(u8, "Fix $ARGUMENTS"),
        .file_path = try allocator.dupe(u8, "/tmp/fix.md"),
        .source_info = .{
            .path = try allocator.dupe(u8, "/tmp/fix.md"),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = null,
        },
    };
    defer template.deinit(allocator);
    harness.live_resources.prompt_templates = &.{template};

    harness.prompt_worker_active = true;
    harness.session.retry_delay_active.store(true, .seq_cst);
    defer harness.session.retry_delay_active.store(false, .seq_cst);

    try harness.submit("/fix retry path");
    try std.testing.expectEqualStrings("queued steering message for after retry", harness.state.footer.status);
    try std.testing.expectEqual(@as(usize, 1), harness.state.queue.steering.items.len);
    try std.testing.expectEqualStrings("Fix retry path", harness.state.queue.steering.items[0]);

    try harness.press(.escape, .{});
    try std.testing.expectEqualStrings("retry cancel requested", harness.state.footer.status);
}

const InputDispatchFixedClock = struct {
    value: i64,

    fn now(context: ?*anyopaque) i64 {
        const self: *InputDispatchFixedClock = @ptrCast(@alignCast(context.?));
        return self.value;
    }
};

test "double Escape follows settings action for tree and disabled states" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var clock = InputDispatchFixedClock{ .value = 1000 };
    harness.state.setClockForTesting(&clock, InputDispatchFixedClock.now);

    try harness.press(.escape, .{});
    try std.testing.expect(harness.overlay == null);
    clock.value += 100;
    try harness.press(.escape, .{});
    try std.testing.expect(harness.overlay != null);
    try std.testing.expectEqual(std.meta.Tag(SelectorOverlay).tree, std.meta.activeTag(harness.overlay.?));
    harness.overlay.?.deinit(allocator);
    harness.overlay = null;

    const agent_dir = try makeInputDispatchTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, agent_dir);
    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = settings_path,
        .data =
        \\{
        \\  "doubleEscapeAction": "none"
        \\}
        ,
    });
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    var runtime = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, cwd);
    defer runtime.deinit();
    try std.testing.expectEqual(config_mod.DoubleEscapeAction.none, runtime.doubleEscapeAction());
    harness.live_resources.runtime_config = &runtime;
    harness.state.setLastEscapeActionMs(0);
    clock.value = 2000;

    try harness.press(.escape, .{});
    clock.value += 100;
    try harness.press(.escape, .{});
    try std.testing.expect(harness.overlay == null);
}

test "settings command opens structured searchable rows and value changes persist with live editor effects" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const agent_dir = try makeInputDispatchTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, agent_dir);
    const initial_settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(initial_settings_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = initial_settings_path,
        .data =
        \\{
        \\  "defaultProvider": "faux"
        \\}
        ,
    });

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();
    try harness.env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &harness.env_map, cwd);
    defer runtime.deinit();
    harness.live_resources.runtime_config = &runtime;
    harness.live_resources.keybindings = &runtime.keybindings;

    try harness.submit("/settings");
    try std.testing.expect(harness.overlay != null);
    try std.testing.expectEqual(std.meta.Tag(SelectorOverlay).settings, std.meta.activeTag(harness.overlay.?));

    var saw_auto_compact = false;
    var saw_raw = false;
    for (harness.overlay.?.settings.items) |item| {
        if (std.mem.indexOf(u8, item.label, "Auto-compact") != null) saw_auto_compact = true;
        if (std.mem.indexOf(u8, item.label, "Advanced raw JSON") != null) saw_raw = true;
    }
    try std.testing.expect(saw_auto_compact);
    try std.testing.expect(saw_raw);

    try harness.press(.{ .printable = tui.keys.PrintableKey.fromSlice("theme") }, .{});
    try std.testing.expectEqual(@as(usize, 1), harness.overlay.?.settings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, harness.overlay.?.settings.items[0].label, "Theme") != null);

    try harness.press(.backspace, .{});
    try harness.press(.backspace, .{});
    try harness.press(.backspace, .{});
    try harness.press(.backspace, .{});
    try harness.press(.backspace, .{});

    for (harness.overlay.?.settings.items, 0..) |item, index| {
        if (std.mem.indexOf(u8, item.label, "Editor padding") != null) {
            harness.overlay.?.settings.list.selected_index = index;
            break;
        }
    }
    try harness.press(.enter, .{});
    try std.testing.expectEqual(@as(usize, 1), harness.editor.padding_x);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings_json = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(settings_json);
    try std.testing.expect(std.mem.indexOf(u8, settings_json, "\"defaultProvider\": \"faux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_json, "\"editorPaddingX\": 1") != null);
}

test "idle selector cancellation preserves chat editor and metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const agent_dir = try makeInputDispatchTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, agent_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();
    try harness.env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &harness.env_map, cwd);
    defer runtime.deinit();
    harness.live_resources.runtime_config = &runtime;

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.session_resume, &.{.{ .ctrl_alt = 'r' }});
    try custom_keybindings.setBinding(.session_tree, &.{.{ .ctrl_alt = 't' }});
    harness.live_resources.keybindings = &custom_keybindings;

    try harness.state.appendInfo("chat marker before selectors");
    _ = try harness.editor.handlePaste("draft before selector");

    const initial_items_len = harness.state.chat.items.items.len;
    const initial_model_id = harness.session.agent.getModel().id;
    const initial_provider = harness.session.agent.getModel().provider;
    const initial_session_file = harness.session.session_manager.getSessionFile().?;
    const SelectorTag = std.meta.Tag(SelectorOverlay);
    const key_cases = [_]struct {
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
        tag: SelectorTag,
    }{
        .{ .key = .{ .ctrl = 'l' }, .modifiers = .{}, .tag = .model },
        .{ .key = .{ .ctrl = 'r' }, .modifiers = .{ .alt = true }, .tag = .session },
        .{ .key = .{ .ctrl = 't' }, .modifiers = .{ .alt = true }, .tag = .tree },
    };

    for (key_cases) |case| {
        try harness.press(case.key, case.modifiers);
        try std.testing.expect(harness.overlay != null);
        try std.testing.expectEqual(case.tag, std.meta.activeTag(harness.overlay.?));
        try harness.press(.escape, .{});
        try std.testing.expect(harness.overlay == null);
        try std.testing.expectEqualStrings("draft before selector", harness.editor.text());
        try std.testing.expectEqual(initial_items_len, harness.state.chat.items.items.len);
        try std.testing.expectEqualStrings(initial_provider, harness.session.agent.getModel().provider);
        try std.testing.expectEqualStrings(initial_model_id, harness.session.agent.getModel().id);
        try std.testing.expectEqualStrings(initial_session_file, harness.session.session_manager.getSessionFile().?);
    }

    try harness.submit("/settings");
    try std.testing.expect(harness.overlay != null);
    try std.testing.expectEqual(SelectorTag.settings, std.meta.activeTag(harness.overlay.?));
    const settings_open_items_len = harness.state.chat.items.items.len;
    try harness.press(.escape, .{});
    try std.testing.expect(harness.overlay == null);
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expectEqual(settings_open_items_len, harness.state.chat.items.items.len);
    try std.testing.expectEqual(initial_items_len, harness.state.chat.items.items.len);
    try std.testing.expectEqualStrings(initial_provider, harness.session.agent.getModel().provider);
    try std.testing.expectEqualStrings(initial_model_id, harness.session.agent.getModel().id);
    try std.testing.expectEqualStrings(initial_session_file, harness.session.session_manager.getSessionFile().?);
}

test "active selector attempts preserve queued messages editor and chat" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const agent_dir = try makeInputDispatchTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, agent_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();
    try harness.env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &harness.env_map, cwd);
    defer runtime.deinit();
    harness.live_resources.runtime_config = &runtime;

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.session_resume, &.{.{ .ctrl_alt = 'r' }});
    try custom_keybindings.setBinding(.session_tree, &.{.{ .ctrl_alt = 't' }});
    harness.live_resources.keybindings = &custom_keybindings;

    try harness.state.appendInfo("chat marker before blocked selectors");
    try harness.session.steer("queued steering", &.{});
    try harness.session.followUp("queued follow-up", &.{});
    try harness.state.appendQueuedMessage(.steering, "queued steering");
    try harness.state.appendQueuedMessage(.follow_up, "queued follow-up");

    const initial_items_len = harness.state.chat.items.items.len;
    const initial_steering_len = harness.session.agent.steeringQueueLen();
    const initial_follow_up_len = harness.session.agent.followUpQueueLen();
    const initial_display_steering_len = harness.state.queue.steering.items.len;
    const initial_display_follow_up_len = harness.state.queue.follow_up.items.len;

    harness.session.agent.beginRun();
    harness.prompt_worker_active = true;
    _ = try harness.editor.handlePaste("draft during streaming");

    const key_cases = [_]struct {
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
        status: []const u8,
    }{
        .{ .key = .{ .ctrl = 'l' }, .modifiers = .{}, .status = "wait for the current response to finish before switching models" },
        .{ .key = .{ .ctrl = 'r' }, .modifiers = .{ .alt = true }, .status = "wait for the current response to finish before switching sessions" },
        .{ .key = .{ .ctrl = 't' }, .modifiers = .{ .alt = true }, .status = "wait for the current response to finish before opening the session tree" },
    };

    for (key_cases) |case| {
        try harness.press(case.key, case.modifiers);
        try std.testing.expect(harness.overlay == null);
        try std.testing.expectEqualStrings("draft during streaming", harness.editor.text());
        try std.testing.expectEqual(initial_items_len, harness.state.chat.items.items.len);
        try std.testing.expectEqual(initial_steering_len, harness.session.agent.steeringQueueLen());
        try std.testing.expectEqual(initial_follow_up_len, harness.session.agent.followUpQueueLen());
        try std.testing.expectEqual(initial_display_steering_len, harness.state.queue.steering.items.len);
        try std.testing.expectEqual(initial_display_follow_up_len, harness.state.queue.follow_up.items.len);
        try std.testing.expectEqualStrings(case.status, harness.state.footer.status);
    }

    const slash_cases = [_]struct {
        text: []const u8,
        status: []const u8,
    }{
        .{ .text = "/model", .status = "wait for the current response to finish before switching models" },
        .{ .text = "/resume", .status = "wait for the current response to finish before switching sessions" },
        .{ .text = "/tree", .status = "wait for the current response to finish before opening the session tree" },
        .{ .text = "/settings", .status = "wait for the current response to finish before opening settings" },
    };

    for (slash_cases) |case| {
        try harness.submit(case.text);
        try std.testing.expect(harness.overlay == null);
        try std.testing.expectEqualStrings(case.text, harness.editor.text());
        try std.testing.expectEqual(initial_items_len, harness.state.chat.items.items.len);
        try std.testing.expectEqual(initial_steering_len, harness.session.agent.steeringQueueLen());
        try std.testing.expectEqual(initial_follow_up_len, harness.session.agent.followUpQueueLen());
        try std.testing.expectEqual(initial_display_steering_len, harness.state.queue.steering.items.len);
        try std.testing.expectEqual(initial_display_follow_up_len, harness.state.queue.follow_up.items.len);
        try std.testing.expectEqualStrings(case.status, harness.state.footer.status);
    }

    harness.session.agent.finishRun();
    harness.prompt_worker_active = false;
    harness.session.compaction_active.store(true, .seq_cst);
    defer harness.session.compaction_active.store(false, .seq_cst);

    harness.editor.reset();
    _ = try harness.editor.handlePaste("draft during compaction");
    try harness.press(.{ .ctrl = 'l' }, .{});
    try std.testing.expect(harness.overlay == null);
    try std.testing.expectEqualStrings("draft during compaction", harness.editor.text());
    try std.testing.expectEqual(initial_items_len, harness.state.chat.items.items.len);
    try std.testing.expectEqual(initial_steering_len, harness.session.agent.steeringQueueLen());
    try std.testing.expectEqual(initial_follow_up_len, harness.session.agent.followUpQueueLen());
    try std.testing.expectEqual(initial_display_steering_len, harness.state.queue.steering.items.len);
    try std.testing.expectEqual(initial_display_follow_up_len, harness.state.queue.follow_up.items.len);
    try std.testing.expectEqualStrings("wait for the current response to finish before switching models", harness.state.footer.status);

    try harness.submit("/settings");
    try std.testing.expect(harness.overlay == null);
    try std.testing.expectEqualStrings("/settings", harness.editor.text());
    try std.testing.expectEqual(initial_items_len, harness.state.chat.items.items.len);
    try std.testing.expectEqual(initial_steering_len, harness.session.agent.steeringQueueLen());
    try std.testing.expectEqual(initial_follow_up_len, harness.session.agent.followUpQueueLen());
    try std.testing.expectEqual(initial_display_steering_len, harness.state.queue.steering.items.len);
    try std.testing.expectEqual(initial_display_follow_up_len, harness.state.queue.follow_up.items.len);
    try std.testing.expectEqualStrings("wait for the current response to finish before opening settings", harness.state.footer.status);
}

test "external editor action replaces prompt on success and preserves on failure or missing editor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    _ = try harness.editor.handlePaste("draft");
    try harness.press(.{ .ctrl = 'g' }, .{});
    try std.testing.expectEqualStrings("draft", harness.editor.text());
    try std.testing.expectEqualStrings("No editor configured. Set $VISUAL or $EDITOR environment variable.", harness.state.footer.status);

    const success_script = try makeInputDispatchTestPath(allocator, tmp, "success-editor.sh");
    defer allocator.free(success_script);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = success_script,
        .data =
        \\printf 'edited prompt\n' > "$1"
        \\
        ,
    });
    const success_cmd = try std.fmt.allocPrint(allocator, "/bin/sh {s}", .{success_script});
    defer allocator.free(success_cmd);
    try harness.env_map.put("EDITOR", success_cmd);

    try harness.press(.{ .ctrl = 'g' }, .{});
    try std.testing.expectEqualStrings("edited prompt", harness.editor.text());
    try std.testing.expectEqualStrings("Updated prompt from external editor", harness.state.footer.status);

    const failure_script = try makeInputDispatchTestPath(allocator, tmp, "failure-editor.sh");
    defer allocator.free(failure_script);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = failure_script,
        .data =
        \\printf 'corrupt prompt\n' > "$1"
        \\exit 7
        \\
        ,
    });
    const failure_cmd = try std.fmt.allocPrint(allocator, "/bin/sh {s}", .{failure_script});
    defer allocator.free(failure_cmd);
    try harness.env_map.put("EDITOR", failure_cmd);

    try harness.press(.{ .ctrl = 'g' }, .{});
    try std.testing.expectEqualStrings("edited prompt", harness.editor.text());
    try std.testing.expectEqualStrings("External editor exited with status 7; prompt unchanged", harness.state.footer.status);
}

test "bare bash shortcuts do not submit and Escape clears bash entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    try harness.submit("!");
    try std.testing.expectEqualStrings("!", harness.editor.text());
    try std.testing.expect(!harness.state.isBashExecutionActive());
    try std.testing.expectEqual(@as(usize, 0), harness.session.agent.getMessages().len);

    harness.editor.reset();
    _ = try harness.editor.handlePaste("!!");
    try submitEditorText(
        allocator,
        std.testing.io,
        &harness.env_map,
        std.mem.trim(u8, harness.editor.text(), " \t\r\n"),
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("!!", harness.editor.text());
    try std.testing.expectEqual(@as(usize, 0), harness.session.agent.getMessages().len);

    harness.editor.reset();
    _ = try harness.editor.handlePaste("! draft");
    var app_context = AppContext.init(cwd, std.testing.io);
    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &harness.env_map,
        .escape,
        .{},
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expectEqualStrings("bash entry cancelled", harness.state.footer.status);
}

test "configured interrupt clears bash entry and cancels running bash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.interrupt, &.{.{ .ctrl = 'x' }});
    harness.live_resources.keybindings = &custom_keybindings;

    var app_context = AppContext.init(cwd, std.testing.io);
    harness.editor.reset();
    _ = try harness.editor.handlePaste("! rebound");
    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &harness.env_map,
        .escape,
        .{},
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("! rebound", harness.editor.text());

    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &harness.env_map,
        .{ .ctrl = 'x' },
        .{},
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("", harness.editor.text());
    try std.testing.expectEqualStrings("bash entry cancelled", harness.state.footer.status);

    try harness.submit("! printf start; sleep 5; printf end");
    try std.testing.expect(harness.state.isBashExecutionActive());
    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &harness.env_map,
        .{ .ctrl = 'x' },
        .{},
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("bash cancel requested", harness.state.footer.status);
    try waitForBashCompletion(&harness.state, allocator);
    try std.testing.expect(!harness.state.isBashExecutionActive());
}

test "bash shortcuts persist included output and exclude double bang from context" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    try harness.submit("! printf BASH_INCLUDED_CONTEXT_42");
    try waitForBashCompletion(&harness.state, allocator);
    try harness.submit("!! printf BASH_EXCLUDED_CONTEXT_42");
    try waitForBashCompletion(&harness.state, allocator);

    try std.testing.expectEqual(@as(usize, 1), harness.session.agent.getMessages().len);
    try std.testing.expect(std.mem.indexOf(u8, harness.session.agent.getMessages()[0].user.content[0].text.text, "BASH_INCLUDED_CONTEXT_42") != null);

    var context = try harness.session.session_manager.buildSessionContext(allocator);
    defer context.deinit(allocator);
    var saw_included = false;
    var saw_excluded = false;
    for (context.messages) |message| {
        if (message == .user and message.user.content.len > 0 and message.user.content[0] == .text) {
            if (std.mem.indexOf(u8, message.user.content[0].text.text, "BASH_INCLUDED_CONTEXT_42") != null) saw_included = true;
            if (std.mem.indexOf(u8, message.user.content[0].text.text, "BASH_EXCLUDED_CONTEXT_42") != null) saw_excluded = true;
        }
    }
    try std.testing.expect(saw_included);
    try std.testing.expect(!saw_excluded);

    const session_file = harness.session.session_manager.getSessionFile().?;
    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"customType\":\"bashExecution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"excludeFromContext\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.state.chat.items.items[harness.state.chat.items.items.len - 1].text, "[excluded from context]") != null);
}

test "concurrent bash shortcut warns and Escape cancels running bash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeInputDispatchTestPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const session_dir = try makeInputDispatchTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, cwd);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, session_dir);

    var harness = try BashSubmitHarness.init(allocator, cwd, session_dir);
    defer harness.deinit();

    try harness.submit("! printf start; sleep 5; printf end");
    try std.testing.expect(harness.state.isBashExecutionActive());

    try harness.submit("! printf second");
    try std.testing.expectEqualStrings("A bash command is already running. Press Esc to cancel it first.", harness.state.footer.status);
    try std.testing.expectEqualStrings("! printf second", harness.editor.text());

    var app_context = AppContext.init(cwd, std.testing.io);
    try handleInputKeyWithModifiers(
        allocator,
        std.testing.io,
        &harness.env_map,
        .escape,
        .{},
        &harness.session,
        &harness.current_provider,
        harness.options.session_dir,
        harness.options,
        &.{},
        &harness.state,
        &harness.editor,
        &harness.overlay,
        &harness.auth_flow,
        &harness.prompt_worker,
        &harness.prompt_worker_active,
        harness.subscriber,
        &harness.should_exit,
        &app_context,
        &harness.live_resources,
    );
    try std.testing.expectEqualStrings("bash cancel requested", harness.state.footer.status);
    try waitForBashCompletion(&harness.state, allocator);
    try std.testing.expect(!harness.state.isBashExecutionActive());
    try std.testing.expect(std.mem.indexOf(u8, harness.state.chat.items.items[harness.state.chat.items.items.len - 1].text, "(cancelled)") != null);
}
