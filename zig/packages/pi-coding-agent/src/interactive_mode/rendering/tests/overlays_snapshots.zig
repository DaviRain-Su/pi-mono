const c = @import("common.zig");

const std = c.std;
const ai = c.ai;
const agent = c.agent;
const tui = c.tui;
const keybindings_mod = c.keybindings_mod;
const resources_mod = c.resources_mod;
const session_mod = c.session_mod;
const extension_registry = c.extension_registry;
const common = c.common;
const overlays = c.overlays;
const rendering = c.rendering;
const AppState = c.AppState;
const ScreenComponent = c.ScreenComponent;
const BorrowedLinesComponent = c.BorrowedLinesComponent;
const BorrowedCellRow = c.BorrowedCellRow;
const OverlayPanelComponent = c.OverlayPanelComponent;
const ChatItem = c.ChatItem;
const ChatKind = c.ChatKind;
const formatting = c.formatting;
const ASSISTANT_PREFIX = c.ASSISTANT_PREFIX;
const ASSISTANT_THINKING_TEXT = c.ASSISTANT_THINKING_TEXT;
const EXTENSION_WIDGET_TRUNCATION_MARKER = c.EXTENSION_WIDGET_TRUNCATION_MARKER;
const ExtensionWidgetPlacement = c.ExtensionWidgetPlacement;
const formatTaskHeaderText = c.formatTaskHeaderText;
const formatFooterText = c.formatFooterText;
const formatFooterLine = c.formatFooterLine;
const formatFooterTextWithTerminal = c.formatFooterTextWithTerminal;
const renderScreenToLines = c.renderScreenToLines;
const renderChatItemInto = c.renderChatItemInto;
const freeLinesSlice = c.freeLinesSlice;
const styleForToken = c.styleForToken;
const chatToken = c.chatToken;
const previewThreshold = c.previewThreshold;
const drawChatItem = c.drawChatItem;
const drawChatItems = c.drawChatItems;
const drawChatViewport = c.drawChatViewport;
const estimateChatRows = c.estimateChatRows;
const estimateChatItemRowsVisible = c.estimateChatItemRowsVisible;
const overlayPanelMaxHeight = c.overlayPanelMaxHeight;
const overlayPanelOptions = c.overlayPanelOptions;
const SelectorOverlay = c.SelectorOverlay;
const render_text = c.render_text;
const promptEditorOffsetX = c.promptEditorOffsetX;
const WHEEL_LINES_PER_NOTCH = c.WHEEL_LINES_PER_NOTCH;
const InteractiveModeTestBackend = c.InteractiveModeTestBackend;
const renderScreenWithMockBackend = c.renderScreenWithMockBackend;
const renderScreenWithMockBackendAndOverlay = c.renderScreenWithMockBackendAndOverlay;
const renderedLinesContain = c.renderedLinesContain;
const countChatKind = c.countChatKind;
const FixedClock = c.FixedClock;

test "extension UI hooks render widgets editor footer and status lifecycle" {
    const allocator = std.testing.allocator;

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();
    const frames =
        \\{ "type": "set_header", "lines": ["ext header"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_footer", "lines": ["ext footer"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_editor_component", "label": "VimEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "above", "lines": ["above one", "above two"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "below", "lines": ["below one"], "placement": "belowEditor", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try extension_registry.applyHostFrameStream(&registry, frames);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.applyExtensionRegistryUi(&registry);
    try state.setExtensionFooterStatus("z-last", "last");
    try state.setExtensionFooterStatus("a-first", "first");

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("ext header", snapshot.extension_header_lines[0]);
    try std.testing.expectEqualStrings("VimEditor", snapshot.extension_editor_label.?);
    try std.testing.expectEqualStrings("first", snapshot.extension_footer_statuses[0]);
    try std.testing.expectEqualStrings("last", snapshot.extension_footer_statuses[1]);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 14,
    };

    const lines = try renderScreenToLines(allocator, &screen, 100);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(renderedLinesContain(lines, "ext header"));
    try std.testing.expect(renderedLinesContain(lines, "above one"));
    try std.testing.expect(renderedLinesContain(lines, "Extension editor: VimEditor"));
    try std.testing.expect(renderedLinesContain(lines, "below one"));
    try std.testing.expect(renderedLinesContain(lines, "ext footer"));
    try std.testing.expect(renderedLinesContain(lines, "first"));

    _ = registry.clearWidgetHook("above");
    _ = registry.clearFooterHook();
    _ = registry.clearEditorComponentHook();
    try state.applyExtensionRegistryUi(&registry);
    var cleared = try state.snapshotForRender(allocator);
    defer cleared.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), cleared.extension_widgets.len);
    try std.testing.expectEqual(@as(?[]u8, null), cleared.extension_editor_label);
    try std.testing.expectEqual(@as(usize, 0), cleared.extension_footer_lines.len);
}

test "extension widgets replace by key and truncate after ten lines" {
    const allocator = std.testing.allocator;

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();
    const frames =
        \\{ "type": "set_widget", "key": "status", "lines": ["old"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "status", "lines": ["1","2","3","4","5","6","7","8","9","10","11"], "placement": "belowEditor", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try extension_registry.applyHostFrameStream(&registry, frames);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.applyExtensionRegistryUi(&registry);

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.extension_widgets.len);
    try std.testing.expectEqual(ExtensionWidgetPlacement.below_editor, snapshot.extension_widgets[0].placement);
    try std.testing.expectEqual(@as(usize, 11), snapshot.extension_widgets[0].lines.len);
    try std.testing.expectEqualStrings(EXTENSION_WIDGET_TRUNCATION_MARKER, snapshot.extension_widgets[0].lines[10]);
}

test "vaxis m8 visual parity snapshot covers chat rows footer and queue" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "m8-session.jsonl", "zig-implementation", "Faux", "env");
    try state.setStatus("streaming");
    try state.appendMarkdown("# M8 heading\n\n- list item\n\n`inline` code");
    try state.appendInfo("Tool read: {\"path\":\"note.txt\"}");
    try state.appendQueuedMessage(.steering, "queued during compaction");
    try state.appendQueuedMessage(.follow_up, "queued follow-up");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("pending prompt");

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 20,
        .keybindings = &keybindings,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 160, .height = 20 } };
    defer backend.deinit(allocator);

    const lines = try renderScreenWithMockBackend(allocator, &screen_component, &backend);
    defer freeLinesSlice(allocator, lines);

    try std.testing.expect(renderedLinesContain(lines, "M8 heading"));
    try std.testing.expect(renderedLinesContain(lines, "Tool read:"));
    try std.testing.expect(renderedLinesContain(lines, "Steering: queued during compaction"));
    try std.testing.expect(renderedLinesContain(lines, "Follow-up: queued follow-up"));
    try std.testing.expect(renderedLinesContain(lines, "> pending prompt"));
    try std.testing.expect(!renderedLinesContain(lines, "⏎ send · Alt+⏎ follow-up"));
    try std.testing.expect(!renderedLinesContain(lines, "Alt+Up dequeue"));
    try std.testing.expect(!renderedLinesContain(lines, "Ctrl+C/Ctrl+D clear/exit"));
    try std.testing.expect(renderedLinesContain(lines, "Faux"));
    try std.testing.expect(renderedLinesContain(lines, "Queue: 1 steering, 1 follow-up"));
    try std.testing.expect(renderedLinesContain(lines, "Model: faux-1"));
}

test "vaxis m8 visual parity snapshot covers codex layout at 100x30 and 60x20" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "codex-layout.jsonl", "zig-implementation", "Faux", "env");
    try state.setStatus("ready");
    try state.appendMarkdown("# Codex layout\n\n- visual parity");
    state.context_window = 128000;
    state.context_percent = 7.5;

    var theme = try resources_mod.Theme.initCodex(allocator);
    defer theme.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("codex prompt");

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 30,
        .theme = &theme,
        .terminal_name = "ghostty",
    };

    var screen_100 = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 30);
    defer screen_100.deinit(std.testing.allocator);
    const text_100 = try tui.test_helpers.screenToString(&screen_100);
    defer allocator.free(text_100);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "pi · codex-layout.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "Provider: Faux") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "> codex prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "GHOSTTY") != null);

    screen_component.height = 20;
    var screen_60 = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 60, 20);
    defer screen_60.deinit(std.testing.allocator);
    const text_60 = try tui.test_helpers.screenToString(&screen_60);
    defer allocator.free(text_60);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "pi · codex-layout.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "Provider:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "> codex prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "GHOSTTY") != null);
}

test "vaxis m8 visual parity snapshot covers overlay composition" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setStatus("overlay open");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 24,
        .keybindings = &keybindings,
    };

    var overlay = try overlays.loadHotkeysOverlay(allocator, &keybindings);
    defer overlay.deinit(allocator);

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 100, .height = 24 } };
    defer backend.deinit(allocator);

    const lines = try renderScreenWithMockBackendAndOverlay(allocator, &screen_component, &overlay, &backend);
    defer freeLinesSlice(allocator, lines);

    try std.testing.expect(renderedLinesContain(lines, "Keyboard shortcuts"));
    try std.testing.expect(renderedLinesContain(lines, "Ctrl+C"));
    try std.testing.expect(renderedLinesContain(lines, "Ctrl+L"));
}
