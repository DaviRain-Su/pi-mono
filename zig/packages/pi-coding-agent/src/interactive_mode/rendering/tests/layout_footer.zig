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

test "screen draw renders top task panel and shifts chat below it" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "demo-2026-04-27", null, "Faux", "env");
    try state.setStatus("ready");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 8);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 0, "╭", .{});
    try tui.test_helpers.expectCell(&screen, 0, 2, "╰", .{});

    const rendered = try tui.test_helpers.screenToString(&screen);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "pi · demo-2026-04-27") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Status: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Model: faux-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Provider: Faux") != null);

    const row_three = screen.readCell(0, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("W", row_three.char.grapheme);
}

test "task header owns status model provider while footer excludes them" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("openai", "gpt-5.4").?;
    try state.setFooterDetails(model, "session.jsonl", "zig-implementation", "OpenAI", "env");
    try state.setStatus("missing key\nset OPENAI_API_KEY");

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const header = try formatTaskHeaderText(allocator, &snapshot, 140);
    defer allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "pi · session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Status: missing key set OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Model: gpt-5.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Provider: OpenAI") != null);

    const footer = try formatFooterText(allocator, &snapshot, 140);
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Branch: zig-implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Session: session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
}

test "prompt m2 renders compact footer with terminal badge" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "demo-session.jsonl", "zig-implementation", "Faux", "env");
    state.usage_totals = .{
        .input = 1200,
        .output = 345,
    };
    state.context_window = 128000;
    state.context_percent = 12.5;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 14,
        .theme = &theme,
        .terminal_name = "ghostty",
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer screen.deinit(std.testing.allocator);

    const rendered = try tui.test_helpers.screenToString(&screen);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "⏎ send · Alt+⏎ follow-up") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Alt+Up dequeue") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Ctrl+L models") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "GHOSTTY") != null);

    const prompt_top = screen.readCell(0, 10) orelse return error.TestUnexpectedResult;
    const footer_first = screen.readCell(0, 13) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╭", prompt_top.char.grapheme);
    try std.testing.expectEqualStrings("B", footer_first.char.grapheme);

    const footer_session_label = try allocator.dupe(u8, "demo-session.jsonl");
    defer allocator.free(footer_session_label);
    const footer_git_branch = try allocator.dupe(u8, "zig-implementation");
    defer allocator.free(footer_git_branch);
    const footer = try formatFooterTextWithTerminal(allocator, &.{
        .session_label = footer_session_label,
        .git_branch = footer_git_branch,
        .usage_totals = .{ .input = 1200, .output = 345 },
        .context_window = 128000,
        .context_percent = 12.5,
    }, "ghostty", 100);
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Branch: zig-implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Session:") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↑1.2k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↓345") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 12.5%/128k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "GHOSTTY") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
}

test "prompt m5 applies breakpoint-specific layout collapse rules" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "m5-session.jsonl", "zig-implementation", "Faux", "env");
    try state.setStatus("ready");
    state.context_window = 128000;
    state.context_percent = 12.5;

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const header_100 = try formatTaskHeaderText(allocator, &snapshot, 100);
    defer allocator.free(header_100);
    try std.testing.expect(std.mem.indexOf(u8, header_100, "Provider: Faux") != null);

    const header_80 = try formatTaskHeaderText(allocator, &snapshot, 80);
    defer allocator.free(header_80);
    try std.testing.expect(std.mem.indexOf(u8, header_80, "Status: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_80, "Model: faux-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_80, "Provider:") == null);

    const header_60 = try formatTaskHeaderText(allocator, &snapshot, 60);
    defer allocator.free(header_60);
    try std.testing.expect(std.mem.indexOf(u8, header_60, "pi · m5-session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_60, "Status:") == null);

    const footer_50 = try formatFooterText(allocator, &snapshot, 50);
    defer allocator.free(footer_50);
    try std.testing.expect(std.mem.indexOf(u8, footer_50, "Model: faux-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer_50, "ctx 12.5%/128k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer_50, "Session:") == null);

    const footer_36 = try formatFooterText(allocator, &snapshot, 36);
    defer allocator.free(footer_36);
    try std.testing.expect(std.mem.indexOf(u8, footer_36, "Status: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer_36, "Model:") == null);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen_50 = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
        .terminal_name = "ghostty",
    };
    var rendered_50 = try tui.test_helpers.renderToScreen(screen_50.drawComponent(), 50, 12);
    defer rendered_50.deinit(std.testing.allocator);
    const text_50 = try tui.test_helpers.screenToString(&rendered_50);
    defer allocator.free(text_50);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "> hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "╭") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "⏎ send") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "Model: faux-1") != null);

    var rendered_36 = try tui.test_helpers.renderToScreen(screen_50.drawComponent(), 36, 12);
    defer rendered_36.deinit(std.testing.allocator);
    const text_36 = try tui.test_helpers.screenToString(&rendered_36);
    defer allocator.free(text_36);
    try std.testing.expect(std.mem.indexOf(u8, text_36, "Input: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_36, "Status: ready") != null);
}

test "screen draw re-reads theme after runtime switch without stale structural cells" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "demo-session.jsonl", "zig-implementation", "Faux", "env");

    var dark = try resources_mod.Theme.initDefault(allocator);
    defer dark.deinit(allocator);
    var codex = try resources_mod.Theme.initCodex(allocator);
    defer codex.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 14,
        .theme = &dark,
        .terminal_name = "ghostty",
    };

    var dark_screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer dark_screen.deinit(std.testing.allocator);
    const dark_glyph = dark_screen.readCell(1, 11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", dark_glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&dark, .prompt_glyph), dark_glyph.style);

    const dark_text = try tui.test_helpers.screenToString(&dark_screen);
    defer allocator.free(dark_text);

    screen_component.theme = &codex;
    var codex_screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer codex_screen.deinit(std.testing.allocator);
    const codex_glyph = codex_screen.readCell(1, 11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", codex_glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&codex, .prompt_glyph), codex_glyph.style);
    try std.testing.expect(!std.meta.eql(dark_glyph.style, codex_glyph.style));

    const codex_text = try tui.test_helpers.screenToString(&codex_screen);
    defer allocator.free(codex_text);
    try std.testing.expectEqualStrings(dark_text, codex_text);
}

test "formatFooterLine excludes provider auth status after task header split" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("openai", "gpt-5.4").?;
    try state.setFooterDetails(model, "session.jsonl", "zig-implementation", "OpenAI", "env");
    try state.setStatus("missing key\nset OPENAI_API_KEY");

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const footer = try formatFooterLine(allocator, null, &snapshot, 240);
    defer allocator.free(footer);

    try std.testing.expect(std.mem.indexOf(u8, footer, "Session: session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);
}

test "screen draw stacks autocomplete below the prompt editor child window" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]tui.SelectItem{
        .{ .value = "read", .label = "read" },
        .{ .value = "reload", .label = "reload" },
        .{ .value = "render", .label = "render" },
    });

    _ = try editor.handleKey(.{ .printable = tui.keys.PrintableKey.fromSlice("r") });
    _ = try editor.handleKey(.{ .printable = tui.keys.PrintableKey.fromSlice("e") });

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 11,
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 80, 11);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 4, "╭", .{});

    const selected = screen.readCell(@intCast(promptEditorOffsetX(80) + 2), 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("r", selected.char.grapheme);
    try std.testing.expect(!selected.style.reverse);
}

test "borrowed lines component draws stored cell rows without ansi strings" {
    const selected_style = tui.vaxis.Cell.Style{ .reverse = true };
    const first_row = [_]tui.vaxis.Cell{
        .{ .char = .{ .grapheme = "A", .width = 1 }, .style = selected_style },
        .{ .char = .{ .grapheme = "B", .width = 1 } },
    };
    const second_row = [_]tui.vaxis.Cell{
        .{ .char = .{ .grapheme = "C", .width = 1 } },
    };
    const borrowed = BorrowedLinesComponent{
        .rows = &[_]BorrowedCellRow{
            .{ .cells = &first_row },
            .{ .cells = &second_row },
        },
    };

    var screen = try tui.test_helpers.renderToScreen(borrowed.drawComponent(), 3, 2);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 0, "A", selected_style);
    try tui.test_helpers.expectCell(&screen, 1, 0, "B", .{});
    try tui.test_helpers.expectCell(&screen, 0, 1, "C", .{});
}
