pub const std = @import("std");
pub const ai = @import("ai");
pub const agent = @import("agent");
pub const tui = @import("tui");
pub const keybindings_mod = @import("../../../shared/keybindings.zig");
pub const resources_mod = @import("../../../resources/resources.zig");
pub const session_mod = @import("../../../sessions/session.zig");
pub const extension_registry = @import("../../../extensions/extension_registry.zig");
pub const common = @import("../../../tools/common.zig");
pub const overlays = @import("../../overlays.zig");
pub const rendering = @import("../../rendering.zig");

pub const AppState = rendering.AppState;
pub const ScreenComponent = rendering.ScreenComponent;
pub const BorrowedLinesComponent = rendering.BorrowedLinesComponent;
pub const BorrowedCellRow = rendering.BorrowedCellRow;
pub const OverlayPanelComponent = rendering.OverlayPanelComponent;
pub const ChatItem = rendering.ChatItem;
pub const ChatKind = rendering.ChatKind;
pub const formatting = @import("../../formatting.zig");
pub const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
pub const ASSISTANT_THINKING_TEXT = "Thinking...";
pub const EXTENSION_WIDGET_TRUNCATION_MARKER = rendering.EXTENSION_WIDGET_TRUNCATION_MARKER;
pub const ExtensionWidgetPlacement = rendering.ExtensionWidgetPlacement;
pub const formatTaskHeaderText = rendering.formatTaskHeaderText;
pub const formatFooterText = rendering.formatFooterText;
pub const formatFooterLine = rendering.formatFooterLine;
pub const formatFooterTextWithTerminal = rendering.formatFooterTextWithTerminal;
pub const renderScreenToLines = rendering.renderScreenToLines;
pub const renderChatItemInto = rendering.renderChatItemInto;
pub const freeLinesSlice = rendering.freeLinesSlice;
pub const styleForToken = rendering.styleForToken;
pub const chatToken = rendering.chatToken;
pub const previewThreshold = rendering.previewThreshold;
pub const drawChatItem = rendering.drawChatItem;
pub const drawChatItems = rendering.drawChatItems;
pub const drawChatViewport = rendering.drawChatViewport;
pub const estimateChatRows = rendering.estimateChatRows;
pub const estimateChatItemRowsVisible = rendering.estimateChatItemRowsVisible;
pub const overlayPanelMaxHeight = rendering.overlayPanelMaxHeight;
pub const overlayPanelOptions = rendering.overlayPanelOptions;
pub const SelectorOverlay = overlays.SelectorOverlay;
pub const render_text = @import("../../render_text.zig");
pub const promptEditorOffsetX = render_text.promptEditorOffsetX;
pub const WHEEL_LINES_PER_NOTCH: usize = 3;

pub const InteractiveModeTestBackend = struct {
    size: tui.Size,
    entered_raw: bool = false,
    restored: bool = false,
    writes: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.writes.items) |entry| allocator.free(entry);
        self.writes.deinit(allocator);
    }

    pub fn backend(self: *@This()) tui.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    pub fn enterRawMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.entered_raw = true;
    }

    pub fn restoreMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.restored = true;
    }

    pub fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    }

    pub fn getSize(ptr: *anyopaque) !tui.Size {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

pub fn renderScreenWithMockBackend(
    allocator: std.mem.Allocator,
    screen: *const ScreenComponent,
    backend: *InteractiveModeTestBackend,
) ![]const []const u8 {
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var rendered = try tui.test_helpers.renderToScreen(screen.drawComponent(), backend.size.width, backend.size.height);
    defer rendered.deinit(std.testing.allocator);

    return tui.cell_rows.allocatingScreenRowsToLinesAlloc(allocator, &rendered, backend.size.width, backend.size.height);
}

pub fn renderScreenWithMockBackendAndOverlay(
    allocator: std.mem.Allocator,
    screen: *const ScreenComponent,
    overlay: *SelectorOverlay,
    backend: *InteractiveModeTestBackend,
) ![]const []const u8 {
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const panel = OverlayPanelComponent{
        .overlay = overlay,
        .max_height = overlayPanelMaxHeight(screen.height),
    };
    _ = try renderer.showDrawOverlay(panel.drawComponent(), overlayPanelOptions(backend.size, 1.0));

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var vx = try tui.vaxis.init(std.testing.io, allocator, &env_map, .{});
    defer vx.deinit(allocator, &writer.writer);

    try renderer.renderToVaxis(screen.drawComponent(), &vx, &writer.writer);

    return tui.cell_rows.allocatingScreenRowsToLinesAlloc(allocator, &vx.screen_last, backend.size.width, backend.size.height);
}

pub fn renderedLinesContain(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

pub fn countChatKind(items: []const ChatItem, kind: ChatKind) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind == kind) count += 1;
    }
    return count;
}

pub const FixedClock = struct {
    now_ms: i64,

    fn now(context: ?*anyopaque) i64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.now_ms;
    }
};
