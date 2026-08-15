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

test "chat scroll wheel updates offset only inside chat region and clamps" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    state.updateChatScrollLayout(30, 10, 3, 80);
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
    try std.testing.expectEqual(@as(usize, 20), state.chat_scroll_max_offset);

    state.handleChatMouseWheel(.{ .direction = .up, .row = 0, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.handleChatMouseWheel(.{ .direction = .up, .row = 23, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 3), state.chat_scroll_offset);

    for (0..10) |_| state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 20), state.chat_scroll_offset);

    state.handleChatMouseWheel(.{ .direction = .down, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 17), state.chat_scroll_offset);
    for (0..10) |_| state.handleChatMouseWheel(.{ .direction = .down, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.chatScrollPageUp();
    try std.testing.expectEqual(@as(usize, 9), state.chat_scroll_offset);
    state.chatScrollPageUp();
    state.chatScrollPageUp();
    try std.testing.expectEqual(@as(usize, 20), state.chat_scroll_offset);
    state.chatScrollPageDown();
    try std.testing.expectEqual(@as(usize, 11), state.chat_scroll_offset);
    state.chatScrollPageDown();
    state.chatScrollPageDown();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
}

test "chat scroll tail clear auto-follow append preservation and resize clamp state" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    state.updateChatScrollLayout(30, 10, 3, 80);
    state.chat_scroll_offset = 12;
    state.chatScrollToTail();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    try state.appendItemLocked(.info, "new tail item");
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.chat_scroll_offset = 8;
    try state.appendItemLocked(.info, "preserve reader position");
    try std.testing.expectEqual(@as(usize, 8), state.chat_scroll_offset);

    state.updateChatScrollLayout(35, 10, 3, 80);
    try std.testing.expectEqual(@as(usize, 13), state.chat_scroll_offset);

    state.updateChatScrollLayout(30, 25, 3, 80);
    try std.testing.expectEqual(@as(usize, 5), state.chat_scroll_offset);

    state.chat_scroll_offset = 0;
    state.updateChatScrollLayout(40, 25, 3, 80);
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.clearDisplay();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.updateChatScrollLayout(5, 10, 3, 80);
    state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
}

test "chat scroll page up at top reveals older hidden items and preserves anchor" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    for (0..10) |index| {
        const text = try std.fmt.allocPrint(allocator, "item {d}", .{index});
        defer allocator.free(text);
        try state.appendItemLocked(.info, text);
    }

    state.visible_start_index = 5;
    const old_total_rows = estimateChatRows(state.items.items[state.visible_start_index..], 80, state.all_expanded);
    state.updateChatScrollLayout(old_total_rows, 4, 3, 80);
    state.chat_scroll_offset = state.chat_scroll_max_offset;
    const old_offset = state.chat_scroll_offset;

    state.chatScrollPageUp();

    try std.testing.expectEqual(@as(usize, 2), state.visible_start_index);
    try std.testing.expectEqual(old_offset + 3, state.chat_scroll_offset);
    try std.testing.expectEqual(state.chat_scroll_max_offset, state.chat_scroll_offset);
}

test "chat scroll wheel at top reveals one notch of older hidden items and preserves anchor" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    for (0..5) |index| {
        const text = try std.fmt.allocPrint(allocator, "item {d}", .{index});
        defer allocator.free(text);
        try state.appendItemLocked(.info, text);
    }

    state.visible_start_index = 4;
    const old_total_rows = estimateChatRows(state.items.items[state.visible_start_index..], 80, state.all_expanded);
    state.updateChatScrollLayout(old_total_rows, 2, 3, 80);
    state.chat_scroll_offset = state.chat_scroll_max_offset;
    const old_offset = state.chat_scroll_offset;

    state.handleChatMouseWheel(.{ .direction = .up, .row = 3, .col = 10 });

    try std.testing.expectEqual(@as(usize, 1), state.visible_start_index);
    try std.testing.expectEqual(old_offset + WHEEL_LINES_PER_NOTCH, state.chat_scroll_offset);
    try std.testing.expectEqual(state.chat_scroll_max_offset, state.chat_scroll_offset);
}

test "chat scroll page up at oldest history is a no-op at top" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    for (0..5) |index| {
        const text = try std.fmt.allocPrint(allocator, "item {d}", .{index});
        defer allocator.free(text);
        try state.appendItemLocked(.info, text);
    }

    state.visible_start_index = 0;
    const old_total_rows = estimateChatRows(state.items.items, 80, state.all_expanded);
    state.updateChatScrollLayout(old_total_rows, 2, 3, 80);
    state.chat_scroll_offset = state.chat_scroll_max_offset;
    const old_offset = state.chat_scroll_offset;

    state.chatScrollPageUp();

    try std.testing.expectEqual(@as(usize, 0), state.visible_start_index);
    try std.testing.expectEqual(old_offset, state.chat_scroll_offset);
    try std.testing.expectEqual(old_total_rows -| @as(usize, 2), state.chat_scroll_max_offset);
}

test "drawChatViewport honors scroll offset and overlays overflow indicators" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var items: [30]ChatItem = undefined;
    for (&items, 0..) |*item, index| {
        item.* = .{
            .kind = .info,
            .text = try std.fmt.allocPrint(allocator, "row {d:0>2}", .{index}),
        };
    }
    defer {
        for (&items) |item| allocator.free(item.text);
    }

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 12,
        .cols = 40,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);
    const window = tui.draw.rootWindow(&screen);
    window.clear();

    const metrics = try drawChatViewport(arena.allocator(), null, null, items[0..], window, 0, 12, 5, 0, true, null, null);
    try std.testing.expectEqual(@as(usize, 30), metrics.rendered_height);
    try std.testing.expectEqual(@as(usize, 12), metrics.visible_height);

    var rendered = try tui.vaxis.AllocatingScreen.init(allocator, 40, 12);
    defer rendered.deinit(allocator);
    for (0..12) |row| {
        for (0..40) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            rendered.writeCell(@intCast(col), @intCast(row), cell);
        }
    }

    const text = try tui.test_helpers.screenToString(&rendered);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "row 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "row 24") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "↑ more") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "↓ more") != null);
}
