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

test "roles m0 thinking deltas append to a thinking chat item" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .assistant = template },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_start },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_delta, .delta = "internal " },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_delta, .delta = "reasoning" },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_end },
    });

    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqual(ChatKind.welcome, state.items.items[0].kind);
    try std.testing.expectEqual(ChatKind.thinking, state.items.items[1].kind);
    try std.testing.expectEqualStrings("internal reasoning", state.items.items[1].text);
    try std.testing.expect(state.last_streaming_thinking_index == null);
}

test "thinking m1 streaming thinking item records start and frozen frame" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 12_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_start },
    });
    try std.testing.expectEqual(ChatKind.thinking, state.items.items[1].kind);
    try std.testing.expectEqual(@as(?i64, 12_000), state.items.items[1].start_ms);
    try std.testing.expectEqual(@as(?usize, null), state.items.items[1].frozen_frame_index);

    clock.now_ms = 12_000 + @as(i64, @intCast(3 * tui.components.loader.DEFAULT_INTERVAL_MS));
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_end },
    });

    try std.testing.expectEqual(@as(?usize, 3), state.items.items[1].frozen_frame_index);
    try std.testing.expect(state.last_streaming_thinking_index == null);
}

test "thinking m1 spinner frame derives from injected render clock" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const frames = tui.components.loader.DEFAULT_SPINNER_FRAMES;
    for (frames, 0..) |frame, index| {
        var screen = try tui.vaxis.Screen.init(allocator, .{
            .rows = 2,
            .cols = 12,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer screen.deinit(allocator);

        const window = tui.draw.rootWindow(&screen);
        window.clear();
        const now_ms = 1_000 + @as(i64, @intCast(index * tui.components.loader.DEFAULT_INTERVAL_MS));
        _ = try drawChatItem(window, arena.allocator(), null, &theme, .{
            .kind = .thinking,
            .text = @constCast("abc"),
            .start_ms = 1_000,
        }, 0, now_ms, true);

        const glyph = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(frame, glyph.char.grapheme);
        try std.testing.expectEqual(styleForToken(&theme, .role_thinking_glyph), glyph.style);
        const spacer = screen.readCell(1, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(" ", spacer.char.grapheme);
        const body = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("a", body.char.grapheme);
        try std.testing.expectEqual(styleForToken(&theme, .role_thinking), body.style);
    }
}

test "thinking m1 frozen frame ignores later render clock" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var early_screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer early_screen.deinit(allocator);
    var late_screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer late_screen.deinit(allocator);

    const item = ChatItem{
        .kind = .thinking,
        .text = @constCast("done"),
        .start_ms = 5_000,
        .frozen_frame_index = 4,
    };

    const early_window = tui.draw.rootWindow(&early_screen);
    early_window.clear();
    _ = try drawChatItem(early_window, arena.allocator(), null, null, item, 0, 5_000, true);
    const early_glyph = early_screen.readCell(0, 0) orelse return error.TestUnexpectedResult;

    const late_window = tui.draw.rootWindow(&late_screen);
    late_window.clear();
    _ = try drawChatItem(late_window, arena.allocator(), null, null, item, 0, 15_000, true);
    const late_glyph = late_screen.readCell(0, 0) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(tui.components.loader.DEFAULT_SPINNER_FRAMES[4], early_glyph.char.grapheme);
    try std.testing.expectEqualStrings(early_glyph.char.grapheme, late_glyph.char.grapheme);
}

test "thinking m1 continuation rows are indented without repeating glyph" {
    const allocator = std.testing.allocator;

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 5,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    _ = try drawChatItem(window, arena.allocator(), null, null, .{
        .kind = .thinking,
        .text = @constCast("abcdef"),
        .start_ms = 0,
    }, 0, 0, true);

    const first_glyph = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(tui.components.loader.DEFAULT_SPINNER_FRAMES[0], first_glyph.char.grapheme);
    const continuation_col0 = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    const continuation_col1 = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    const continuation_text = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(continuation_col0.char.grapheme.len == 0 or std.mem.eql(u8, continuation_col0.char.grapheme, " "));
    try std.testing.expect(continuation_col1.char.grapheme.len == 0 or std.mem.eql(u8, continuation_col1.char.grapheme, " "));
    try std.testing.expectEqualStrings("d", continuation_text.char.grapheme);
}

test "thinking m1 finalized thinking renders identically across clocks" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendItemLocked(.thinking, "stable private thought");

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 1_000,
    };

    var first = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 60, 8);
    defer first.deinit(std.testing.allocator);
    const first_text = try tui.test_helpers.screenToString(&first);
    defer allocator.free(first_text);

    screen_component.now_ms = 20_000;
    var second = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 60, 8);
    defer second.deinit(std.testing.allocator);
    const second_text = try tui.test_helpers.screenToString(&second);
    defer allocator.free(second_text);

    try std.testing.expectEqualStrings(first_text, second_text);
}

test "roles m0 rebuildFromSession preserves thinking before assistant text" {
    const allocator = std.testing.allocator;

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .model = ai.model_registry.find("faux", "faux-1").?,
    });
    defer session.deinit();

    const blocks = [_]ai.ContentBlock{
        .{ .thinking = .{ .thinking = "private chain" } },
        .{ .text = .{ .text = "public answer" } },
    };
    const messages = [_]agent.AgentMessage{.{ .assistant = .{
        .content = &blocks,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    } }};
    try session.agent.setMessages(&messages);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.rebuildFromSession(&session, null);

    try std.testing.expect(state.items.items.len >= 3);
    try std.testing.expectEqual(ChatKind.welcome, state.items.items[0].kind);
    try std.testing.expectEqual(ChatKind.thinking, state.items.items[1].kind);
    try std.testing.expectEqualStrings("private chain", state.items.items[1].text);
    try std.testing.expectEqual(ChatKind.assistant, state.items.items[2].kind);
    try std.testing.expectEqualStrings("public answer", state.items.items[2].text);
}

test "thinking visibility toggle hides and restores thinking without dropping chat state" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendItemLocked(.thinking, "private chain");
    try state.appendItemLocked(.assistant, "public answer");
    try state.appendQueuedMessage(.follow_up, "queued draft");

    const hidden = try state.toggleThinkingBlockVisibility();
    try std.testing.expect(hidden);
    try std.testing.expect(state.hide_thinking_blocks);
    try std.testing.expectEqualStrings(ASSISTANT_THINKING_TEXT, state.items.items[1].text);
    try std.testing.expectEqualStrings("private chain", state.items.items[1].expanded_text.?);
    try std.testing.expectEqualStrings("public answer", state.items.items[2].text);
    try std.testing.expectEqual(@as(usize, 1), state.queued_follow_up.items.len);

    state.last_streaming_thinking_index = 1;
    try state.appendThinkingDeltaLocked(" continued");
    try std.testing.expectEqualStrings(ASSISTANT_THINKING_TEXT, state.items.items[1].text);
    try std.testing.expectEqualStrings("private chain continued", state.items.items[1].expanded_text.?);

    const visible = try state.toggleThinkingBlockVisibility();
    try std.testing.expect(!visible);
    try std.testing.expect(!state.hide_thinking_blocks);
    try std.testing.expectEqualStrings("private chain continued", state.items.items[1].text);
    try std.testing.expect(state.items.items[1].expanded_text == null);
    try std.testing.expectEqualStrings("public answer", state.items.items[2].text);
    try std.testing.expectEqual(@as(usize, 1), state.queued_follow_up.items.len);
}

test "roles m0 chatToken maps visible roles to role tokens" {
    try std.testing.expectEqual(resources_mod.ThemeToken.role_user, chatToken(.user));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_assistant, chatToken(.assistant));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_thinking, chatToken(.thinking));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_tool_call, chatToken(.tool_call));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_tool_result, chatToken(.tool_result));
}

test "roles m0 drawChatItem applies role styles to representative cells" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 8,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const items = [_]ChatItem{
        .{ .kind = .user, .text = @constCast("You: hello") },
        .{ .kind = .assistant, .text = @constCast("answer") },
        .{ .kind = .thinking, .text = @constCast("private") },
        .{ .kind = .tool_call, .text = @constCast("Tool: bash") },
        .{ .kind = .tool_result, .text = @constCast("output") },
    };

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    _ = try drawChatItems(window, arena.allocator(), null, &theme, &items, 0, true);

    const user = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    const assistant = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    const thinking = screen.readCell(2, 3) orelse return error.TestUnexpectedResult;
    const tool_call = screen.readCell(0, 4) orelse return error.TestUnexpectedResult;
    const tool_result = screen.readCell(0, 5) orelse return error.TestUnexpectedResult;

    var expected_user = styleForToken(&theme, .task_header_accent);
    expected_user.bold = true;
    var expected_assistant = styleForToken(&theme, .task_header_accent);
    expected_assistant.bold = true;
    try std.testing.expectEqual(expected_user, user.style);
    try std.testing.expectEqual(expected_assistant, assistant.style);
    try std.testing.expectEqual(styleForToken(&theme, .role_thinking), thinking.style);
    var expected_tool_call = styleForToken(&theme, .role_tool_call);
    expected_tool_call.bold = true;
    var expected_tool_result = styleForToken(&theme, .role_tool_result);
    expected_tool_result.bold = true;
    try std.testing.expectEqual(expected_tool_call, tool_call.style);
    try std.testing.expectEqual(expected_tool_result, tool_result.style);
}

test "collapse m2 app state defaults and snapshots all_expanded" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try std.testing.expect(!state.all_expanded);
    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expect(!snapshot.all_expanded);
}

test "collapse m2 preview thresholds match collapsible chat kinds" {
    try std.testing.expectEqual(@as(?usize, 1), previewThreshold(.thinking));
    try std.testing.expectEqual(@as(?usize, 3), previewThreshold(.tool_result));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.assistant));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.markdown));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.welcome));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.info));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.@"error"));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.user));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.tool_call));
}

test "collapse m2 indicator renders with hidden row count and distinct style" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    const text =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
        \\seven
        \\eight
        \\nine
        \\ten
    ;
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 4,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, arena.allocator(), &keybindings, &theme, .{
        .kind = .thinking,
        .text = @constCast(text),
        .frozen_frame_index = 0,
    }, 0, 0, false);

    try std.testing.expectEqual(@as(usize, 2), rendered);
    const body = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
    const indicator = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    const indicator_plus = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    const indicator_count = screen.readCell(3, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("…", indicator.char.grapheme);
    try std.testing.expectEqualStrings("+", indicator_plus.char.grapheme);
    try std.testing.expectEqualStrings("9", indicator_count.char.grapheme);
    try std.testing.expect(!std.meta.eql(body.style, indicator.style));
}

test "collapse m2 items at or under threshold render without indicator" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, arena.allocator(), &keybindings, null, .{
        .kind = .tool_result,
        .text = @constCast("Tool result bash: ok"),
    }, 0, 0, false);

    try std.testing.expectEqual(@as(usize, 1), rendered);
    const lines = try tui.cell_rows.screenRowsToLinesAlloc(allocator, &screen, 80, rendered);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(!renderedLinesContain(lines, "to expand"));
}

test "collapse m2 tool result without hidden expansion renders full content" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 8,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, arena.allocator(), &keybindings, null, .{
        .kind = .tool_result,
        .text = @constCast("Tool result web_search:\nline one\nline two\nline three\nline four"),
    }, 0, 0, false);

    try std.testing.expect(rendered >= 5);
    const lines = try tui.cell_rows.screenRowsToLinesAlloc(allocator, &screen, 80, rendered);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(renderedLinesContain(lines, "line four"));
    try std.testing.expect(!renderedLinesContain(lines, "to expand"));
}

test "execution panel preserves recent tool activity after completion" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "web_search",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "search result" } }},
        },
        .is_error = false,
    });
    try state.handleAgentEvent(.{ .event_type = .agent_end });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
    };

    const lines = try renderScreenToLines(allocator, &screen_component, 100);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(renderedLinesContain(lines, "Activity"));
    try std.testing.expect(renderedLinesContain(lines, "Tool completed web_search"));
}

test "assistant provider error after tool result renders concrete message" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "web_search",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "Sources:\n- result" } }},
        },
        .is_error = false,
    });

    const assistant_blocks = [_]ai.ContentBlock{.{ .text = .{ .text = "Sources:\n- result" } }};
    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .assistant = .{
            .content = &assistant_blocks,
            .api = "anthropic-messages",
            .provider = "kimi-coding",
            .model = "kimi-for-coding",
            .usage = ai.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "Provider stop_reason: sensitive",
            .timestamp = 0,
        } },
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
    };

    const lines = try renderScreenToLines(allocator, &screen_component, 100);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(renderedLinesContain(lines, "Error: Provider stop_reason: sensitive"));
    try std.testing.expect(!renderedLinesContain(lines, "Unknown error"));
}

test "tool expansion rerenders existing bash details immediately" {
    const allocator = std.testing.allocator;

    const detail_value = try std.json.parseFromSlice(std.json.Value, allocator, "{\"exit_code\":0,\"timed_out\":false}", .{});
    defer detail_value.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text =
            \\line one
            \\line two
            \\line three
            \\line four
            } }},
            .details = detail_value.value,
        },
        .is_error = false,
    });

    try std.testing.expect(!state.all_expanded);
    try std.testing.expectEqualStrings("Tool result bash:\nline one\nline two\nline three\nline four", state.items.items[1].text);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].expanded_text.?, "Details:") != null);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
    };

    const collapsed_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, collapsed_lines);
    try std.testing.expect(!renderedLinesContain(collapsed_lines, "Details:"));
    try std.testing.expect(renderedLinesContain(collapsed_lines, "to expand"));

    state.toggleAllExpanded();
    const expanded_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, expanded_lines);
    try std.testing.expect(renderedLinesContain(expanded_lines, "Details:"));
    try std.testing.expect(renderedLinesContain(expanded_lines, "\"exit_code\":0"));
}

test "tool expansion rerenders existing user bash tail preview immediately" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    for (0..25) |index| {
        const line = try std.fmt.allocPrint(allocator, "line {d}\n", .{index + 1});
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }

    const item_index = try state.appendBashExecutionStart("seq 25", true);
    try state.finishBashExecution(item_index, "seq 25", output.items, 0, false, false, null, true);

    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "... 6 more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "line 5\n") == null);
    try std.testing.expect(state.items.items[1].expanded_text != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].expanded_text.?, "line 1") != null);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 16,
    };

    const collapsed_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, collapsed_lines);
    try std.testing.expect(renderedLinesContain(collapsed_lines, "line 25"));
    try std.testing.expect(!renderedLinesContain(collapsed_lines, "line 5"));

    state.toggleAllExpanded();
    const expanded_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, expanded_lines);
    try std.testing.expect(renderedLinesContain(expanded_lines, "line 1"));
}

test "agent message_start synchronizes queued display before rendering user message" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendQueuedMessage(.steering, "queued steer");

    const blocks = [_]ai.ContentBlock{.{ .text = .{ .text = "queued steer" } }};
    const user_message = ai.UserMessage{
        .role = "user",
        .content = &blocks,
        .timestamp = 1,
    };
    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .user = user_message },
    });

    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqual(@as(usize, 0), state.queued_steering.items.len);
    try std.testing.expectEqualStrings("You: queued steer", state.items.items[state.items.items.len - 1].text);
    const user_count_after_start = countChatKind(state.items.items, .user);
    state.mutex.unlock(state.io);

    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = user_message },
    });

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqual(user_count_after_start, countChatKind(state.items.items, .user));
}

test "session rebuild clears stale streaming queue extension and progress state" {
    const allocator = std.testing.allocator;

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();
    const frames =
        \\{ "type": "set_header", "lines": ["stale header"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_footer", "lines": ["stale footer"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_editor_component", "label": "StaleEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "stale", "lines": ["stale widget"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try extension_registry.applyHostFrameStream(&registry, frames);

    const model = ai.model_registry.find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .model = model,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.applyExtensionRegistryUi(&registry);
    try state.setExtensionFooterStatus("stale", "status");
    try state.appendQueuedMessage(.follow_up, "queued draft");
    try state.appendMarkdown("stale streaming text");
    state.markTerminalProgress(true);

    try state.rebuildFromSession(&session, null);

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.queued_follow_up.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_header_lines.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_footer_lines.len);
    try std.testing.expectEqual(@as(?[]u8, null), snapshot.extension_editor_label);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_widgets.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_footer_statuses.len);
    try std.testing.expectEqual(false, state.takeTerminalProgressUpdate().?);
}

test "compaction and retry lifecycle update status and terminal progress state" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.handleCompactionLifecycleEvent(.{ .start = .{ .reason = .threshold } });
    try std.testing.expectEqual(true, state.takeTerminalProgressUpdate().?);
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("Auto-compacting... (Ctrl+C to cancel)", state.status);
    state.mutex.unlock(state.io);

    try state.handleCompactionLifecycleEvent(.{ .end = .{
        .reason = .threshold,
        .result = .{
            .summary = "summary",
            .first_kept_entry_id = "entry-1",
            .tokens_before = 42,
        },
    } });
    try std.testing.expectEqual(false, state.takeTerminalProgressUpdate().?);
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("Compacted context (42 tokens)", state.status);
    state.mutex.unlock(state.io);

    try state.handleRetryLifecycleEvent(.{ .start = .{
        .attempt = 1,
        .max_attempts = 2,
        .delay_ms = 1500,
        .error_message = "rate limit",
    } });
    try std.testing.expectEqual(false, state.takeTerminalProgressUpdate().?);
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("Retrying (1/2) in 2s... (Ctrl+C to cancel)", state.status);
    state.mutex.unlock(state.io);
}

test "active operation indicator animates agent wait and clears on agent end" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 1_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    try state.handleAgentEvent(.{ .event_type = .agent_start });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 1_000,
    };

    const first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, first);
    try std.testing.expect(renderedLinesContain(first, "Working... 0s elapsed"));
    try std.testing.expect(renderedLinesContain(first, "Esc to interrupt"));
    try std.testing.expect(renderedLinesContain(first, "⠋ Working"));

    const item_count = state.items.items.len;
    screen.now_ms = 1_000 + @as(i64, @intCast(tui.components.loader.DEFAULT_INTERVAL_MS));
    const second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, second);
    try std.testing.expectEqual(item_count, state.items.items.len);
    try std.testing.expect(renderedLinesContain(second, "⠙ Working"));

    try state.handleAgentEvent(.{ .event_type = .agent_end });
    const completed = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, completed);
    try std.testing.expect(!renderedLinesContain(completed, "Working..."));
    try std.testing.expect(renderedLinesContain(completed, "Status: idle"));
}

test "active operation indicator identifies running tool without appending animation rows" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 5_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-active",
        .tool_name = "read",
        .args = .null,
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 5_000,
    };

    const first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, first);
    try std.testing.expect(renderedLinesContain(first, "Running read 0s elapsed"));
    try std.testing.expect(renderedLinesContain(first, "⠋ Running read"));

    const item_count = state.items.items.len;
    screen.now_ms = 5_000 + @as(i64, @intCast(tui.components.loader.DEFAULT_INTERVAL_MS));
    const second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, second);
    try std.testing.expectEqual(item_count, state.items.items.len);
    try std.testing.expect(renderedLinesContain(second, "⠙ Running read"));
}

test "active operation retry countdown and compaction elapsed render dynamically" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 10_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 10_000,
    };

    try state.handleRetryLifecycleEvent(.{ .start = .{
        .attempt = 2,
        .max_attempts = 4,
        .delay_ms = 2500,
        .error_message = "rate limit",
    } });

    const retry_first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, retry_first);
    try std.testing.expect(renderedLinesContain(retry_first, "Retrying (2/4) in 3s..."));
    try std.testing.expect(renderedLinesContain(retry_first, "Esc to cancel"));

    screen.now_ms = 11_100;
    const retry_second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, retry_second);
    try std.testing.expect(renderedLinesContain(retry_second, "Retrying (2/4) in 2s..."));

    try state.handleRetryLifecycleEvent(.{ .end = .{
        .success = true,
        .attempt = 2,
        .final_error = null,
    } });
    const retry_end = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, retry_end);
    try std.testing.expect(!renderedLinesContain(retry_end, "Retrying (2/4)"));

    clock.now_ms = 20_000;
    try state.handleCompactionLifecycleEvent(.{ .start = .{ .reason = .threshold } });
    screen.now_ms = 20_000;
    const compact_first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, compact_first);
    try std.testing.expect(renderedLinesContain(compact_first, "Auto-compacting... 0s elapsed"));
    try std.testing.expect(renderedLinesContain(compact_first, "Esc to cancel"));

    screen.now_ms = 21_000;
    const compact_second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, compact_second);
    try std.testing.expect(renderedLinesContain(compact_second, "Auto-compacting... 1s elapsed"));
}

test "collapse m2 estimateChatRows uses collapsed or expanded heights" {
    const text =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
        \\seven
        \\eight
        \\nine
        \\ten
    ;
    const item = ChatItem{ .kind = .thinking, .text = @constCast(text), .frozen_frame_index = 0 };
    try std.testing.expectEqual(@as(usize, 2), estimateChatItemRowsVisible(item, 80, false));
    try std.testing.expectEqual(@as(usize, 10), estimateChatItemRowsVisible(item, 80, true));
    try std.testing.expectEqual(@as(usize, 3), estimateChatRows(&.{item}, 80, false));
    try std.testing.expectEqual(@as(usize, 11), estimateChatRows(&.{item}, 80, true));
}

test "collapse m2 toggle preserves tail and clamps non-tail offset" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    for (state.items.items) |item| allocator.free(item.text);
    state.items.clearRetainingCapacity();

    const text =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
        \\seven
        \\eight
        \\nine
        \\ten
    ;
    try state.appendItemLocked(.thinking, text);
    state.chat_visible_rows = 2;
    state.chat_width = 80;

    state.chat_scroll_offset = 0;
    state.all_expanded = false;
    state.toggleAllExpanded();
    try std.testing.expect(state.all_expanded);
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.chat_scroll_offset = 20;
    state.chat_scroll_max_offset = 30;
    state.toggleAllExpanded();
    try std.testing.expect(!state.all_expanded);
    try std.testing.expectEqual(@as(usize, 1), state.chat_scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), state.chat_scroll_max_offset);
}

test "renderChatItemInto renders markdown chat items without assistant prefix" {
    const allocator = std.testing.allocator;

    const text = try allocator.dupe(u8,
        \\# Changelog
        \\- Added /changelog
    );
    defer allocator.free(text);

    const lines = try renderChatItemInto(allocator, 40, null, .{
        .kind = .markdown,
        .text = text,
    });
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expect(renderedLinesContain(lines, "Changelog"));
    try std.testing.expect(renderedLinesContain(lines, "• "));
    try std.testing.expect(!renderedLinesContain(lines, ASSISTANT_PREFIX));
}

test "app state replaces streaming tool updates with the final tool result" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const partial_blocks = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, partial_blocks);
    partial_blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "line 1\n\n[Running... 0.1s elapsed]") } };

    const final_blocks = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, final_blocks);
    final_blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "line 1\nline 2") } };

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .args = .null,
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .partial_result = .{
            .content = partial_blocks,
            .details = null,
        },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .result = .{
            .content = final_blocks,
            .details = null,
        },
        .is_error = false,
    });

    try std.testing.expectEqual(@as(usize, 3), state.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "Running...") == null);
    try std.testing.expectEqualStrings("thinking", state.status);
}

test "app state replaces repeated partial tool updates and final error styling text" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const first_partial = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, first_partial);
    first_partial[0] = .{ .text = .{ .text = try allocator.dupe(u8, "partial one") } };

    const second_partial = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, second_partial);
    second_partial[0] = .{ .text = .{ .text = try allocator.dupe(u8, "partial two") } };

    const final_blocks = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, final_blocks);
    final_blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "final failure") } };

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-repeat",
        .tool_name = "write",
        .partial_result = .{
            .content = first_partial,
            .details = null,
        },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-repeat",
        .tool_name = "write",
        .partial_result = .{
            .content = second_partial,
            .details = null,
        },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_call_id = "tool-repeat",
        .tool_name = "write",
        .result = .{
            .content = final_blocks,
            .details = null,
        },
        .is_error = true,
    });

    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "partial one") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "partial two") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Tool error write") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "final failure") != null);
}

test "route-a m1 streams tool-call arguments and dedupes execution start" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var args_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try common.putString(allocator, &args_object, "command", "echo hi");
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = .{ .object = args_object },
    };

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_start, .content_index = 0 },
    });
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqual(ChatKind.tool_call, state.items.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Tool call:") != null);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_delta, .content_index = 0, .delta = "{\"command\":" },
    });
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "{\"command\":") != null);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_delta, .content_index = 0, .delta = "\"echo hi\"}" },
    });
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "\"echo hi\"}") != null);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_end, .content_index = 0, .tool_call = tool_call },
    });
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "$ echo hi") != null);

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .args = .{ .object = args_object },
    });
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqual(ChatKind.tool_call, state.items.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.status, "working: bash") != null);
}

test "screen rendering releases app state lock before expensive rendering work" {
    const allocator = std.heap.page_allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setStatus("snapshot status");
    try state.appendInfo("streaming output");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("rendered prompt");

    const HookContext = struct {
        snapshot_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release_render: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        setter_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn afterSnapshot(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.snapshot_ready.store(true, .seq_cst);
            while (!self.release_render.load(.seq_cst)) {
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
            }
        }
    };

    const RenderThreadContext = struct {
        allocator: std.mem.Allocator,
        screen: *const ScreenComponent,
        lines: []const []const u8 = &.{},
        render_error: ?std.mem.Allocator.Error = null,

        fn run(self: *@This()) void {
            self.lines = renderScreenToLines(self.allocator, self.screen, 120) catch |err| {
                self.render_error = err;
                return;
            };
        }
    };

    const SetterThreadContext = struct {
        state: *AppState,
        finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.state.setStatus("updated while rendering") catch return;
            self.finished.store(true, .seq_cst);
        }
    };

    var hook_context = HookContext{};
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 10,
        .after_snapshot_hook = .{
            .context = &hook_context,
            .callback = HookContext.afterSnapshot,
        },
    };

    var render_context = RenderThreadContext{
        .allocator = allocator,
        .screen = &screen,
    };
    const render_thread = try std.Thread.spawn(.{}, RenderThreadContext.run, .{&render_context});

    var snapshot_ready = false;
    for (0..100) |_| {
        if (hook_context.snapshot_ready.load(.seq_cst)) {
            snapshot_ready = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(snapshot_ready);

    var setter_context = SetterThreadContext{
        .state = &state,
        .finished = &hook_context.setter_finished,
    };
    const setter_thread = try std.Thread.spawn(.{}, SetterThreadContext.run, .{&setter_context});

    var setter_finished_before_release = false;
    for (0..100) |_| {
        if (hook_context.setter_finished.load(.seq_cst)) {
            setter_finished_before_release = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }

    hook_context.release_render.store(true, .seq_cst);
    render_thread.join();
    setter_thread.join();

    try std.testing.expect(setter_finished_before_release);
    try std.testing.expectEqual(@as(?std.mem.Allocator.Error, null), render_context.render_error);
    defer freeLinesSlice(allocator, render_context.lines);
    try std.testing.expect(renderedLinesContain(render_context.lines, "Status: snapshot status"));
    try std.testing.expect(!renderedLinesContain(render_context.lines, "updated while rendering"));
}
