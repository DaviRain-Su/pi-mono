const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const session_advanced = @import("../sessions/session_advanced.zig");
const extension_registry = @import("../extensions/extension_registry.zig");
const common = @import("../tools/common.zig");
const bash_execution = @import("bash_execution.zig");
const user_bash_task_mod = @import("user_bash_task.zig");
const active_operation_rendering = @import("active_operation_rendering.zig");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const overlays = @import("overlays.zig");
const clipboard_paste_task = @import("clipboard_paste_task.zig");
const chat_items = @import("chat_items.zig");
const chat_rendering = @import("chat_rendering.zig");
const extension_ui = @import("extension_ui.zig");
const git_status = @import("git_status.zig");
const overlay_panel = @import("overlay_panel.zig");
const pending_editor_images_mod = @import("pending_editor_images.zig");
const prompt_rendering = @import("prompt_rendering.zig");
const render_text = @import("render_text.zig");
const slash_commands = @import("slash_commands.zig");
const currentSessionLabel = shared.currentSessionLabel;
const SelectorOverlay = overlays.SelectorOverlay;
const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
const ASSISTANT_THINKING_TEXT = "Thinking...";
const formatPrefixedBlocks = formatting.formatPrefixedBlocks;
const formatAssistantMessage = formatting.formatAssistantMessage;
const formatToolCall = formatting.formatToolCall;
const formatStreamingToolCall = formatting.formatStreamingToolCall;
const WHEEL_LINES_PER_NOTCH: usize = 3;

pub const ChatKind = chat_items.ChatKind;
pub const ChatItem = chat_items.ChatItem;

pub const PendingEditorImage = pending_editor_images_mod.PendingEditorImage;

pub const TerminalImageContext = struct {
    vx: *tui.vaxis.Vaxis,
    tty: *std.Io.Writer,
};

fn deleteTerminalImage(context: ?*anyopaque, image_id: u32) void {
    const terminal_image_context: *const TerminalImageContext = @ptrCast(@alignCast(context.?));
    terminal_image_context.vx.freeImage(terminal_image_context.tty, image_id);
}

fn terminalImageDeleteSink(context: *const TerminalImageContext) pending_editor_images_mod.DeleteImageSink {
    return .{
        .context = @constCast(context),
        .callback = deleteTerminalImage,
    };
}

pub const FooterUsageTotals = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost: f64 = 0,
};

pub const ExtensionWidgetPlacement = extension_ui.WidgetPlacement;
pub const ExtensionWidget = extension_ui.Widget;
pub const EXTENSION_WIDGET_TRUNCATION_MARKER = extension_ui.WIDGET_TRUNCATION_MARKER;

pub const SelectionRange = struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
};

pub const ChatRegion = struct {
    row_start: usize = 0,
    row_end: usize = 0,
    col_start: usize = 0,
    col_end: usize = 0,

    pub fn contains(self: ChatRegion, row: i16, col: i16) bool {
        if (row < 0 or col < 0) return false;
        const row_index: usize = @intCast(row);
        const col_index: usize = @intCast(col);
        return row_index >= self.row_start and
            row_index < self.row_end and
            col_index >= self.col_start and
            col_index < self.col_end;
    }
};

pub const RenderStateSnapshot = struct {
    items: []ChatItem = &.{},
    status: ?[]u8 = null,
    provider_label: ?[]u8 = null,
    provider_status: ?[]u8 = null,
    model_label: ?[]u8 = null,
    session_label: ?[]u8 = null,
    git_branch: ?[]u8 = null,
    usage_totals: FooterUsageTotals = .{},
    context_window: u32 = 0,
    context_percent: ?f64 = null,
    queued_steering: [][]u8 = &.{},
    queued_follow_up: [][]u8 = &.{},
    pending_editor_images: []PendingEditorImage = &.{},
    chat_scroll_offset: usize = 0,
    chat_visible_rows: usize = 0,
    chat_width: usize = 1,
    all_expanded: bool = false,
    hide_thinking_blocks: bool = false,
    hidden_thinking_label: []u8 = &.{},
    extension_header_lines: [][]u8 = &.{},
    extension_footer_lines: [][]u8 = &.{},
    extension_editor_label: ?[]u8 = null,
    extension_widgets: []ExtensionWidget = &.{},
    extension_footer_statuses: [][]u8 = &.{},
    working_message: ?[]u8 = null,
    working_visible: bool = true,
    active_operation: ?ActiveOperationSnapshot = null,
    recent_activity: ?[]u8 = null,

    pub fn deinit(self: *RenderStateSnapshot, allocator: std.mem.Allocator) void {
        for (self.items) |*item| chat_items.deinit(allocator, item);
        if (self.items.len > 0) allocator.free(self.items);
        if (self.status) |status| allocator.free(status);
        if (self.provider_label) |provider_label| allocator.free(provider_label);
        if (self.provider_status) |provider_status| allocator.free(provider_status);
        if (self.model_label) |model_label| allocator.free(model_label);
        if (self.session_label) |session_label| allocator.free(session_label);
        if (self.git_branch) |git_branch| allocator.free(git_branch);
        deinitOwnedStringList(allocator, self.queued_steering);
        deinitOwnedStringList(allocator, self.queued_follow_up);
        pending_editor_images_mod.deinitForRender(allocator, self.pending_editor_images);
        deinitOwnedStringList(allocator, self.extension_header_lines);
        deinitOwnedStringList(allocator, self.extension_footer_lines);
        if (self.extension_editor_label) |label| allocator.free(label);
        for (self.extension_widgets) |*widget| widget.deinit(allocator);
        if (self.extension_widgets.len > 0) allocator.free(self.extension_widgets);
        deinitOwnedStringList(allocator, self.extension_footer_statuses);
        if (self.working_message) |message| allocator.free(message);
        if (self.active_operation) |operation| allocator.free(operation.label);
        if (self.recent_activity) |activity| allocator.free(activity);
        self.* = undefined;
    }
};

pub const ActiveOperationKind = active_operation_rendering.ActiveOperationKind;
pub const ActiveOperationSnapshot = active_operation_rendering.ActiveOperationSnapshot;

const ActiveOperationState = struct {
    kind: ActiveOperationKind,
    label: []u8,
    start_ms: i64,
    delay_ms: u64 = 0,
    attempt: u32 = 0,
    max_attempts: u32 = 0,
};

const ActiveOperationOptions = struct {
    delay_ms: u64 = 0,
    attempt: u32 = 0,
    max_attempts: u32 = 0,
};

const ActiveToolUpdate = struct {
    tool_call_id: []u8,
    item_index: usize,
};

const StreamingToolCall = struct {
    content_index: ?u32,
    tool_call_id: ?[]u8 = null,
    item_index: usize,
};

const ClockNowMsFn = *const fn (?*anyopaque) i64;

pub const TimingState = struct {
    clock_context: ?*anyopaque = null,
    clock_now_ms_fn: ClockNowMsFn = systemNowMilliseconds,
    last_clear_action_ms: ?i64 = null,
    last_escape_action_ms: ?i64 = null,

    pub fn setClockForTesting(self: *TimingState, context: ?*anyopaque, now_ms_fn: ClockNowMsFn) void {
        self.timing.clock_context = context;
        self.timing.clock_now_ms_fn = now_ms_fn;
    }

    pub fn currentNowMs(self: *TimingState) i64 {
        return self.timing.clock_now_ms_fn(self.timing.clock_context);
    }

    pub fn takeLastClearActionMs(self: *TimingState) ?i64 {
        const result = self.timing.last_clear_action_ms;
        self.timing.last_clear_action_ms = null;
        return result;
    }

    pub fn setLastClearActionMs(self: *TimingState, timestamp_ms: i64) void {
        self.timing.last_clear_action_ms = timestamp_ms;
    }

    pub fn takeLastEscapeActionMs(self: *TimingState) ?i64 {
        const result = self.timing.last_escape_action_ms;
        self.timing.last_escape_action_ms = null;
        return result;
    }

    pub fn setLastEscapeActionMs(self: *TimingState, timestamp_ms: i64) void {
        self.timing.last_escape_action_ms = timestamp_ms;
    }
};

pub const ImageState = struct {
    store: pending_editor_images_mod.Store = .{},
    clipboard_paste: clipboard_paste_task.ClipboardPasteTask = undefined,

    pub fn appendPending(self: *ImageState, allocator: std.mem.Allocator, image: ai.ImageContent) !void {
        try self.store.appendPendingContent(allocator, image);
    }

    pub fn appendPendingOwned(self: *ImageState, allocator: std.mem.Allocator, image: PendingEditorImage) !void {
        try self.store.appendPendingOwned(allocator, image);
    }

    pub fn clearPending(self: *ImageState, allocator: std.mem.Allocator) void {
        self.store.clearPending(allocator);
    }

    pub fn clonePending(self: *ImageState, allocator: std.mem.Allocator) ![]ai.ImageContent {
        return try self.store.cloneContents(allocator);
    }

    pub fn retirePendingImage(self: *ImageState, allocator: std.mem.Allocator, image: *PendingEditorImage) void {
        self.store.retirePendingImage(allocator, image);
    }

    pub fn flushRetiredTerminalImages(self: *ImageState, terminal_image_context: TerminalImageContext) void {
        self.store.flushRetired(terminalImageDeleteSink(&terminal_image_context));
    }

    pub fn freeActiveTerminalImages(self: *ImageState, allocator: std.mem.Allocator, terminal_image_context: TerminalImageContext) void {
        self.store.freeActive(allocator, terminalImageDeleteSink(&terminal_image_context));
    }

    pub fn deinit(self: *ImageState, allocator: std.mem.Allocator) void {
        self.store.deinit(allocator);
        self.clipboard_paste.deinit();
    }
};

pub const QueueState = struct {
    steering: std.ArrayList([]u8) = .empty,
    follow_up: std.ArrayList([]u8) = .empty,

    pub fn appendMessage(self: *QueueState, allocator: std.mem.Allocator, mode: QueueDisplayMode, text: []const u8) !void {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        switch (mode) {
            .steering => try self.steering.append(allocator, owned),
            .follow_up => try self.follow_up.append(allocator, owned),
        }
    }

    pub fn clearMessages(self: *QueueState, allocator: std.mem.Allocator) void {
        for (self.steering.items) |item| allocator.free(item);
        self.steering.clearRetainingCapacity();
        for (self.follow_up.items) |item| allocator.free(item);
        self.follow_up.clearRetainingCapacity();
    }

    pub fn clearLocked(self: *QueueState, allocator: std.mem.Allocator) void {
        for (self.steering.items) |item| allocator.free(item);
        self.steering.clearRetainingCapacity();
        for (self.follow_up.items) |item| allocator.free(item);
        self.follow_up.clearRetainingCapacity();
    }

    pub fn removeMessageLocked(self: *QueueState, allocator: std.mem.Allocator, text: []const u8) void {
        for (self.steering.items, 0..) |item, index| {
            if (std.mem.eql(u8, item, text)) {
                _ = self.steering.orderedRemove(index);
                allocator.free(item);
                return;
            }
        }
        for (self.follow_up.items, 0..) |item, index| {
            if (std.mem.eql(u8, item, text)) {
                _ = self.follow_up.orderedRemove(index);
                allocator.free(item);
                return;
            }
        }
    }

    pub fn deinit(self: *QueueState, allocator: std.mem.Allocator) void {
        self.clearLocked(allocator);
        self.steering.deinit(allocator);
        self.follow_up.deinit(allocator);
    }
};

pub const ModelState = struct {
    scoped_model_override_active: bool = false,
    scoped_model_patterns: ?[][]u8 = null,

    pub fn currentPatterns(self: *const ModelState) ?[]const []const u8 {
        if (!self.scoped_model_override_active) return null;
        return self.scoped_model_patterns;
    }

    pub fn hasOverride(self: *const ModelState) bool {
        return self.scoped_model_override_active;
    }

    pub fn setOverride(self: *ModelState, allocator: std.mem.Allocator, patterns: ?[]const []const u8) !void {
        self.clearOverride(allocator);
        self.scoped_model_override_active = true;
        if (patterns) |source| {
            if (source.len > 0) {
                var cloned = try allocator.alloc([]u8, source.len);
                var initialized: usize = 0;
                errdefer {
                    for (cloned[0..initialized]) |item| allocator.free(item);
                    allocator.free(cloned);
                }
                for (source, 0..) |item, index| {
                    cloned[index] = try allocator.dupe(u8, item);
                    initialized += 1;
                }
                self.scoped_model_patterns = cloned;
            }
        }
    }

    pub fn clearOverride(self: *ModelState, allocator: std.mem.Allocator) void {
        if (self.scoped_model_patterns) |patterns| {
            for (patterns) |pattern| allocator.free(pattern);
            allocator.free(patterns);
        }
        self.scoped_model_patterns = null;
        self.scoped_model_override_active = false;
    }
};

pub const FooterState = struct {
    status: []u8 = &.{},
    provider_label: []u8 = &.{},
    provider_status: []u8 = &.{},
    model_label: []u8 = &.{},
    session_label: []u8 = &.{},
    git_branch: []u8 = &.{},
    usage_totals: FooterUsageTotals = .{},
    context_window: u32 = 0,
    context_tokens: ?u32 = null,
    context_percent: ?f64 = null,
    context_unknown: bool = false,
    working_message: []u8 = &.{},
    working_visible: bool = true,
    recent_activity: []u8 = &.{},
    terminal_progress_active: bool = false,
    terminal_progress_dirty: bool = false,

    pub fn deinit(self: *FooterState, allocator: std.mem.Allocator) void {
        allocator.free(self.footer.status);
        allocator.free(self.footer.provider_label);
        allocator.free(self.footer.provider_status);
        allocator.free(self.footer.model_label);
        allocator.free(self.footer.session_label);
        allocator.free(self.footer.git_branch);
        allocator.free(self.footer.working_message);
        allocator.free(self.footer.recent_activity);
    }
};

pub const StreamState = struct {
    all_expanded: bool = false,
    last_streaming_assistant_index: ?usize = null,
    last_streaming_thinking_index: ?usize = null,
    hide_thinking_blocks: bool = false,
    hidden_thinking_label: []u8 = &.{},
    tool_output_expanded: bool = false,

    pub fn toggleAllExpanded(self: *StreamState) void {
        self.stream.all_expanded = !self.stream.all_expanded;
        self.stream.tool_output_expanded = self.stream.all_expanded;
    }

    pub fn deinit(self: *StreamState, allocator: std.mem.Allocator) void {
        allocator.free(self.stream.hidden_thinking_label);
    }
};

pub const ToolState = struct {
    active_tool_updates: std.ArrayList(ActiveToolUpdate) = .empty,
    streaming_tool_calls: std.ArrayList(StreamingToolCall) = .empty,

    pub fn clearActiveToolUpdates(self: *ToolState, allocator: std.mem.Allocator) void {
        for (self.tool.active_tool_updates.items) |*update| {
            allocator.free(update.tool_call_id);
        }
        self.tool.active_tool_updates.clearRetainingCapacity();
    }

    pub fn clearStreamingToolCalls(self: *ToolState, allocator: std.mem.Allocator) void {
        for (self.tool.streaming_tool_calls.items) |*call| {
            if (call.tool_call_id) |id| allocator.free(id);
        }
        self.tool.streaming_tool_calls.clearRetainingCapacity();
    }

    pub fn deinit(self: *ToolState, allocator: std.mem.Allocator) void {
        self.clearActiveToolUpdates(allocator);
        self.tool.active_tool_updates.deinit(allocator);
        self.clearStreamingToolCalls(allocator);
        self.tool.streaming_tool_calls.deinit(allocator);
    }
};

pub const ExtensionState = struct {
    header_lines: [][]u8 = &.{},
    footer_lines: [][]u8 = &.{},
    editor_label: ?[]u8 = null,
    widgets: std.ArrayList(ExtensionWidget) = .empty,
    footer_statuses: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) ExtensionState {
        return .{
            .footer_statuses = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *ExtensionState, allocator: std.mem.Allocator) void {
        for (self.widgets.items) |*widget| widget.deinit(allocator);
        self.widgets.deinit(allocator);
    }
};

pub const OperationState = struct {
    active: ?ActiveOperationState = null,
    bash_task: user_bash_task_mod.UserBashTask = .{},

    pub fn deinit(self: *OperationState, allocator: std.mem.Allocator) void {
        self.bash_task.deinit(allocator);
    }
};

pub const ChatScrollState = struct {
    items: std.ArrayList(ChatItem) = .empty,
    visible_start_index: usize = 0,
    scroll_offset: usize = 0,
    scroll_max_offset: usize = 0,
    total_rows: usize = 0,
    visible_rows: usize = 0,
    width: usize = 1,
    region: ChatRegion = .{},
    scroll_indicator_row: ?usize = null,

    pub fn deinit(self: *ChatScrollState, allocator: std.mem.Allocator) void {
        for (self.chat.items.items) |*item| chat_items.deinit(allocator, item);
        self.chat.items.deinit(allocator);
    }
};

pub const SelectionState = struct {
    active: bool = false,
    start_row: usize = 0,
    start_col: usize = 0,
    end_row: usize = 0,
    end_col: usize = 0,

    pub fn startLocked(self: *SelectionState, region: ChatRegion, row: i16, col: i16) void {
        if (!region.contains(row, col)) return;
        const abs_row: usize = @intCast(row);
        const abs_col: usize = @intCast(col);
        self.active = true;
        self.start_row = abs_row;
        self.start_col = abs_col;
        self.end_row = abs_row;
        self.end_col = abs_col;
    }

    pub fn updateEndLocked(self: *SelectionState, row: i16, col: i16) void {
        self.end_row = @intCast(row);
        self.end_col = @intCast(col);
    }

    pub fn getRange(self: *const SelectionState) ?SelectionRange {
        if (!self.active) return null;
        const start_row = @min(self.start_row, self.end_row);
        const end_row = @max(self.start_row, self.end_row);
        var start_col = self.start_col;
        var end_col = self.end_col;
        if (self.start_row > self.end_row) {
            start_col = self.end_col;
            end_col = self.start_col;
        } else if (self.start_row == self.end_row) {
            start_col = @min(self.start_col, self.end_col);
            end_col = @max(self.start_col, self.end_col);
        }
        return .{
            .start_row = start_row,
            .start_col = start_col,
            .end_row = end_row,
            .end_col = end_col,
        };
    }

    pub fn has(self: *const SelectionState) bool {
        return self.active;
    }

    pub fn clear(self: *SelectionState) void {
        self.active = false;
    }
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    chat: ChatScrollState = .{},
    selection: SelectionState = .{},
    footer: FooterState = .{},
    stream: StreamState = .{},
    queue: QueueState = .{},
    image: ImageState = .{},
    tool: ToolState = .{},
    extension: ExtensionState,
    operation: OperationState = .{},
    model: ModelState = .{},
    timing: TimingState = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .allocator = allocator,
            .io = io,
            .extension = ExtensionState.init(allocator),
            .image = .{ .clipboard_paste = .{ .io = io } },
        };
        errdefer state.deinit();
        state.footer.status = try allocator.dupe(u8, "idle");
        state.footer.provider_label = try allocator.dupe(u8, "unknown");
        state.footer.provider_status = try allocator.dupe(u8, "needs auth");
        state.footer.model_label = try allocator.dupe(u8, "unknown");
        state.footer.session_label = try allocator.dupe(u8, "new");
        state.footer.git_branch = try allocator.dupe(u8, "");
        state.stream.hidden_thinking_label = try allocator.dupe(u8, ASSISTANT_THINKING_TEXT);
        state.footer.working_message = try allocator.dupe(u8, "Working...");
        state.footer.recent_activity = try allocator.dupe(u8, "");
        try state.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.clearExtensionUiHooksLocked();
        self.clearActiveOperationLocked();
        self.extension.widgets.deinit(self.allocator);
        extension_ui.clearFooterStatuses(self.allocator, &self.extension.footer_statuses);
        self.extension.footer_statuses.deinit();
        self.operation.bash_task.deinit(self.allocator);
        self.model.clearOverride(self.allocator);
        self.image.deinit(self.allocator);
        self.clearActiveToolUpdatesLocked();
        self.tool.active_tool_updates.deinit(self.allocator);
        self.clearStreamingToolCallsLocked();
        self.tool.streaming_tool_calls.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        for (self.chat.items.items) |*item| chat_items.deinit(self.allocator, item);
        self.chat.items.deinit(self.allocator);
        self.allocator.free(self.footer.status);
        self.allocator.free(self.footer.provider_label);
        self.allocator.free(self.footer.provider_status);
        self.allocator.free(self.footer.model_label);
        self.allocator.free(self.footer.session_label);
        self.allocator.free(self.footer.git_branch);
        self.allocator.free(self.stream.hidden_thinking_label);
        self.allocator.free(self.footer.working_message);
        self.allocator.free(self.footer.recent_activity);
        self.* = undefined;
    }

    pub fn appendPendingEditorImage(self: *AppState, image: ai.ImageContent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.image.appendPending(self.allocator, image);
    }

    pub fn clearPendingEditorImages(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearPendingEditorImagesLocked();
    }

    pub fn startClipboardPaste(self: *AppState, env_map: *const std.process.Environ.Map) !void {
        if (!(try self.image.clipboard_paste.start(env_map))) {
            try self.setStatus("clipboard image paste already in progress");
            return;
        }
        try self.setStatus("pasting clipboard image...");
    }

    pub fn pollClipboardPaste(self: *AppState, terminal_image_context: ?TerminalImageContext) !void {
        var result = self.image.clipboard_paste.poll() orelse return;
        defer clipboard_paste_task.deinitResult(&result);

        switch (result) {
            .success => |image| {
                var pending = PendingEditorImage{
                    .data = try self.allocator.dupe(u8, image.data),
                    .mime_type = try self.allocator.dupe(u8, image.mime_type),
                    .kitty_image = try self.transmitKittyImage(image, terminal_image_context),
                };
                var appended = false;
                errdefer if (!appended) pending_editor_images_mod.deinit(self.allocator, &pending);

                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    try self.image.appendPendingOwned(self.allocator, pending);
                    appended = true;
                }
                try self.setStatus("clipboard image pasted");
            },
            .empty => try self.setStatus("clipboard does not contain an image"),
            .unsupported => try self.setStatus("clipboard image format is not supported (use PNG, JPEG, WebP, or GIF)"),
            .failure => try self.setStatus("clipboard image paste failed"),
            .none => {},
        }
    }

    pub fn clipboardPasteInProgress(self: *const AppState) bool {
        return self.image.clipboard_paste.isActive();
    }

    pub fn scopedModelPatterns(self: *const AppState) ?[]const []const u8 {
        if (!self.model.scoped_model_override_active) return null;
        return self.model.scoped_model_patterns;
    }

    pub fn hasScopedModelOverride(self: *const AppState) bool {
        return self.model.scoped_model_override_active;
    }

    pub fn setScopedModelOverride(self: *AppState, patterns: ?[]const []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearScopedModelOverrideLocked();
        self.model.scoped_model_override_active = true;
        if (patterns) |source| {
            if (source.len > 0) {
                var cloned = try self.allocator.alloc([]u8, source.len);
                var initialized: usize = 0;
                errdefer {
                    for (cloned[0..initialized]) |item| self.allocator.free(item);
                    self.allocator.free(cloned);
                }
                for (source, 0..) |item, index| {
                    cloned[index] = try self.allocator.dupe(u8, item);
                    initialized += 1;
                }
                self.model.scoped_model_patterns = cloned;
            }
        }
    }

    fn clearScopedModelOverrideLocked(self: *AppState) void {
        if (self.model.scoped_model_patterns) |patterns| {
            deinitOwnedStringList(self.allocator, patterns);
            self.model.scoped_model_patterns = null;
        }
        self.model.scoped_model_override_active = false;
    }

    pub fn startBashExecution(
        self: *AppState,
        allocator: std.mem.Allocator,
        session: *session_mod.AgentSession,
        command: []const u8,
        exclude_from_context: bool,
    ) !bool {
        return try self.operation.bash_task.start(allocator, session, bashTaskHooks(self), command, exclude_from_context);
    }

    pub fn isBashExecutionActive(self: *const AppState) bool {
        return self.operation.bash_task.isActive();
    }

    pub fn cancelBashExecution(self: *AppState) bool {
        return self.operation.bash_task.abort();
    }

    pub fn pollBashExecution(self: *AppState, allocator: std.mem.Allocator) bool {
        return self.operation.bash_task.poll(allocator);
    }

    pub fn setClockForTesting(self: *AppState, context: ?*anyopaque, now_ms_fn: ClockNowMsFn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.timing.clock_context = context;
        self.timing.clock_now_ms_fn = now_ms_fn;
    }

    pub fn clonePendingEditorImages(self: *AppState, allocator: std.mem.Allocator) ![]ai.ImageContent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return try self.image.clonePending(allocator);
    }

    pub fn flushRetiredTerminalImages(self: *AppState, terminal_image_context: TerminalImageContext) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.flushRetiredTerminalImagesLocked(terminal_image_context);
    }

    pub fn freeActiveTerminalImages(self: *AppState, terminal_image_context: TerminalImageContext) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.image.freeActiveTerminalImages(self.allocator, terminal_image_context);
    }
    pub fn snapshotForRender(self: *AppState, allocator: std.mem.Allocator) !RenderStateSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var snapshot = RenderStateSnapshot{
            .usage_totals = self.footer.usage_totals,
            .context_window = self.footer.context_window,
            .context_percent = self.footer.context_percent,
            .chat_scroll_offset = self.chat.scroll_offset,
            .chat_visible_rows = self.chat.visible_rows,
            .chat_width = self.chat.width,
            .all_expanded = self.stream.all_expanded,
            .hide_thinking_blocks = self.stream.hide_thinking_blocks,
        };
        errdefer snapshot.deinit(allocator);

        snapshot.status = try allocator.dupe(u8, self.footer.status);
        snapshot.provider_label = try allocator.dupe(u8, self.footer.provider_label);
        snapshot.provider_status = try allocator.dupe(u8, self.footer.provider_status);
        snapshot.model_label = try allocator.dupe(u8, self.footer.model_label);
        snapshot.session_label = try allocator.dupe(u8, self.footer.session_label);
        snapshot.git_branch = try allocator.dupe(u8, self.footer.git_branch);

        const start_index = @min(self.chat.visible_start_index, self.chat.items.items.len);
        snapshot.items = try chat_items.clone(allocator, self.chat.items.items[start_index..]);
        snapshot.queued_steering = try cloneOwnedStringList(allocator, self.queue.steering.items);
        snapshot.queued_follow_up = try cloneOwnedStringList(allocator, self.queue.follow_up.items);
        snapshot.pending_editor_images = try pending_editor_images_mod.cloneForRender(allocator, self.image.store.pending_editor_images.items);
        snapshot.extension_header_lines = try cloneOwnedStringList(allocator, self.extension.header_lines);
        snapshot.extension_footer_lines = try cloneOwnedStringList(allocator, self.extension.footer_lines);
        snapshot.extension_editor_label = if (self.extension.editor_label) |label| try allocator.dupe(u8, label) else null;
        snapshot.extension_widgets = try extension_ui.cloneWidgets(allocator, self.extension.widgets.items);
        snapshot.extension_footer_statuses = try extension_ui.cloneFooterStatusesSorted(allocator, &self.extension.footer_statuses);
        snapshot.working_message = if (self.footer.working_message.len > 0) try allocator.dupe(u8, self.footer.working_message) else null;
        snapshot.working_visible = self.footer.working_visible;
        snapshot.recent_activity = if (self.footer.recent_activity.len > 0) try allocator.dupe(u8, self.footer.recent_activity) else null;
        if (self.operation.active) |operation| {
            snapshot.active_operation = .{
                .kind = operation.kind,
                .label = try allocator.dupe(u8, operation.label),
                .start_ms = operation.start_ms,
                .delay_ms = operation.delay_ms,
                .attempt = operation.attempt,
                .max_attempts = operation.max_attempts,
            };
        }
        return snapshot;
    }

    pub fn clearDisplay(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat.visible_start_index = self.chat.items.items.len;
        self.chat.scroll_offset = 0;
        self.chat.total_rows = 0;
        self.replaceLabelLocked(&self.footer.status, "display cleared") catch {};
    }

    pub fn handleChatMouseWheel(self: *AppState, wheel: tui.keys.MouseWheelInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.chat.region.contains(wheel.row, wheel.col)) return;
        switch (wheel.direction) {
            .up => {
                if (self.chat.scroll_offset >= self.chat.scroll_max_offset and
                    self.revealOlderChatItemsLocked(WHEEL_LINES_PER_NOTCH))
                {
                    return;
                }
                self.chat.scroll_offset = @min(
                    self.chat.scroll_offset +| WHEEL_LINES_PER_NOTCH,
                    self.chat.scroll_max_offset,
                );
            },
            .down => self.chat.scroll_offset = self.chat.scroll_offset -| WHEEL_LINES_PER_NOTCH,
        }
    }

    pub fn chatScrollPageUp(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const page_size = self.chatScrollPageSizeLocked();
        if (self.chat.scroll_offset >= self.chat.scroll_max_offset and
            self.revealOlderChatItemsLocked(page_size))
        {
            return;
        }
        self.chat.scroll_offset = @min(
            self.chat.scroll_offset +| page_size,
            self.chat.scroll_max_offset,
        );
    }

    pub fn chatScrollPageDown(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat.scroll_offset = self.chat.scroll_offset -| self.chatScrollPageSizeLocked();
    }

    pub fn chatScrollToBottom(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat.scroll_offset = 0;
    }

    pub fn handleMouseClick(self: *AppState, click: tui.keys.MouseClickInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.chat.scroll_indicator_row) |indicator_row| {
            if (click.row == @as(i16, @intCast(indicator_row))) {
                self.chat.scroll_offset = 0;
                return;
            }
        }
        self.selection.startLocked(self.chat.region, click.row, click.col);
    }

    pub fn handleMouseDrag(self: *AppState, drag: tui.keys.MouseDragInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.selection.has()) return;
        self.selection.updateEndLocked(drag.row, drag.col);
    }

    pub fn handleMouseRelease(self: *AppState, release: tui.keys.MouseReleaseInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.selection.has()) return;
        self.selection.updateEndLocked(release.row, release.col);
        self.selection.clear();
    }

    fn startSelectionLocked(self: *AppState, row: i16, col: i16) void {
        if (!self.chat.region.contains(row, col)) return;
        const abs_row: usize = @intCast(row);
        const abs_col: usize = @intCast(col);
        const rel_row = abs_row - self.chat.region.row_start;
        const max_offset = self.chat.total_rows -| self.chat.visible_rows;
        const offset = @min(self.chat.scroll_offset, max_offset);
        const src_row = (max_offset -| offset) + rel_row;
        self.selection.active = true;
        self.selection.start_row = src_row;
        self.selection.start_col = abs_col;
        self.selection.end_row = src_row;
        self.selection.end_col = abs_col;
    }

    fn updateSelectionEndLocked(self: *AppState, row: i16, col: i16) void {
        const abs_row: usize = if (row < 0) 0 else @intCast(row);
        const abs_col: usize = if (col < 0) 0 else @intCast(col);
        const rel_row = if (abs_row >= self.chat.region.row_start)
            abs_row - self.chat.region.row_start
        else
            0;
        const max_offset = self.chat.total_rows -| self.chat.visible_rows;
        const offset = @min(self.chat.scroll_offset, max_offset);
        const src_row = (max_offset -| offset) + rel_row;
        self.selection.end_row = @min(src_row, self.chat.total_rows -| 1);
        self.selection.end_col = abs_col;
    }

    pub fn getSelectionRange(self: *const AppState) ?SelectionRange {
        if (self.selection.start_row == self.selection.end_row and
            self.selection.start_col == self.selection.end_col) return null;
        var start_row = self.selection.start_row;
        var start_col = self.selection.start_col;
        var end_row = self.selection.end_row;
        var end_col = self.selection.end_col;
        if (end_row < start_row or (end_row == start_row and end_col < start_col)) {
            const tmp_r = start_row;
            const tmp_c = start_col;
            start_row = end_row;
            start_col = end_col;
            end_row = tmp_r;
            end_col = tmp_c;
        }
        return .{
            .start_row = start_row,
            .start_col = start_col,
            .end_row = end_row,
            .end_col = end_col,
        };
    }

    pub fn hasSelection(self: *const AppState) bool {
        return self.selection.start_row != self.selection.end_row or
            self.selection.start_col != self.selection.end_col;
    }

    pub fn clearSelection(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.selection.active = false;
        self.selection.start_row = 0;
        self.selection.start_col = 0;
        self.selection.end_row = 0;
        self.selection.end_col = 0;
    }

    fn chatScrollPageSizeLocked(self: *const AppState) usize {
        return @max(self.chat.visible_rows -| 1, 1);
    }

    fn revealOlderChatItemsLocked(self: *AppState, min_rows: usize) bool {
        const item_count = self.chat.items.items.len;
        const old_start = @min(self.chat.visible_start_index, item_count);
        if (old_start == 0) {
            self.chat.visible_start_index = 0;
            return false;
        }

        const width = @max(self.chat.width, 1);
        const target_rows = @max(min_rows, 1);
        const old_total_rows = estimateChatRows(self.chat.items.items[old_start..], width, self.stream.all_expanded);

        var new_start = old_start;
        var revealed_item_rows: usize = 0;
        while (new_start > 0 and revealed_item_rows < target_rows) {
            new_start -= 1;
            revealed_item_rows +|= estimateChatItemRowsVisible(self.chat.items.items[new_start], width, self.stream.all_expanded);
        }
        if (new_start == old_start) return false;

        const new_total_rows = estimateChatRows(self.chat.items.items[new_start..], width, self.stream.all_expanded);
        const revealed_rows = new_total_rows -| old_total_rows;
        self.chat.visible_start_index = new_start;
        self.chat.total_rows = new_total_rows;
        self.chat.scroll_max_offset = self.chat.total_rows -| self.chat.visible_rows;
        self.chat.scroll_offset = @min(self.chat.scroll_offset +| revealed_rows, self.chat.scroll_max_offset);
        return true;
    }

    pub fn chatScrollToTail(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat.scroll_offset = 0;
    }

    pub fn chatScrollClamp(self: *AppState, max_offset: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat.scroll_offset = @min(self.chat.scroll_offset, max_offset);
        self.chat.scroll_max_offset = max_offset;
    }

    pub fn toggleAllExpanded(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const was_at_tail = self.chat.scroll_offset == 0;
        self.stream.all_expanded = !self.stream.all_expanded;
        self.stream.tool_output_expanded = self.stream.all_expanded;
        const start_index = @min(self.chat.visible_start_index, self.chat.items.items.len);
        const total_rows = estimateChatRows(self.chat.items.items[start_index..], @max(self.chat.width, 1), self.stream.all_expanded);
        const max_offset = total_rows -| self.chat.visible_rows;
        self.chat.total_rows = total_rows;
        self.chat.scroll_max_offset = max_offset;
        self.chat.scroll_offset = if (was_at_tail) 0 else @min(self.chat.scroll_offset, max_offset);
    }

    pub fn updateChatScrollLayout(
        self: *AppState,
        total_chat_rows: usize,
        visible_rows: usize,
        row_start: usize,
        width: usize,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const max_offset = total_chat_rows -| visible_rows;
        const was_at_tail = self.chat.scroll_offset == 0;
        if (!was_at_tail and total_chat_rows > self.chat.total_rows) {
            self.chat.scroll_offset +|= total_chat_rows - self.chat.total_rows;
        }
        self.chat.total_rows = total_chat_rows;
        self.chat.scroll_max_offset = max_offset;
        self.chat.scroll_offset = @min(self.chat.scroll_offset, max_offset);
        self.chat.visible_rows = visible_rows;
        self.chat.width = @max(width, 1);
        self.chat.region = .{
            .row_start = row_start,
            .row_end = row_start + visible_rows,
            .col_start = 0,
            .col_end = width,
        };
    }

    pub fn appendQueuedMessage(self: *AppState, mode: QueueDisplayMode, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.queue.appendMessage(self.allocator, mode, text);
    }

    pub fn clearQueuedMessages(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.clearLocked(self.allocator);
    }

    pub fn setToolOutputExpanded(self: *AppState, expanded: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stream.tool_output_expanded = expanded;
        self.stream.all_expanded = expanded;
    }

    pub fn toggleThinkingBlockVisibility(self: *AppState) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.stream.hide_thinking_blocks = !self.stream.hide_thinking_blocks;
        try self.applyThinkingBlockVisibilityLocked();
        return self.stream.hide_thinking_blocks;
    }

    pub fn setThinkingBlockVisibility(self: *AppState, hidden: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.stream.hide_thinking_blocks = hidden;
        try self.applyThinkingBlockVisibilityLocked();
    }

    pub fn setHiddenThinkingLabel(self: *AppState, label: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.replaceLabelLocked(&self.stream.hidden_thinking_label, if (label.len > 0) label else ASSISTANT_THINKING_TEXT);
        if (self.stream.hide_thinking_blocks) {
            try self.applyThinkingBlockVisibilityLocked();
        }
    }

    pub fn currentNowMs(self: *AppState) i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.currentNowMsLocked();
    }

    pub fn takeLastClearActionMs(self: *AppState) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const value = self.timing.last_clear_action_ms;
        self.timing.last_clear_action_ms = null;
        return value;
    }

    pub fn setLastClearActionMs(self: *AppState, timestamp_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.timing.last_clear_action_ms = timestamp_ms;
    }

    pub fn takeLastEscapeActionMs(self: *AppState) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const value = self.timing.last_escape_action_ms;
        self.timing.last_escape_action_ms = null;
        return value;
    }

    pub fn setLastEscapeActionMs(self: *AppState, timestamp_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.timing.last_escape_action_ms = timestamp_ms;
    }

    pub fn setFooter(self: *AppState, model_label: []const u8, session_label: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.footer.model_label, model_label);
        try self.replaceLabelLocked(&self.footer.session_label, session_label);
    }

    pub fn setFooterDetails(
        self: *AppState,
        model: ai.Model,
        session_label: []const u8,
        git_branch: ?[]const u8,
        provider_label: []const u8,
        provider_status: []const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.footer.provider_label, provider_label);
        try self.replaceLabelLocked(&self.footer.provider_status, provider_status);
        try self.replaceLabelLocked(&self.footer.model_label, model.id);
        try self.replaceLabelLocked(&self.footer.session_label, session_label);
        try self.replaceLabelLocked(&self.footer.git_branch, git_branch orelse "");
        self.footer.context_window = model.context_window;
        self.recalculateContextPercentLocked();
    }

    pub fn setStatus(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.footer.status, text);
    }

    pub fn setExtensionFooterStatus(self: *AppState, key: []const u8, text: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.setExtensionFooterStatusLocked(key, text);
    }

    pub fn clearExtensionFooterStatus(self: *AppState, key: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.clearExtensionFooterStatusLocked(key);
    }

    fn setExtensionFooterStatusLocked(self: *AppState, key: []const u8, text: ?[]const u8) !void {
        return extension_ui.setFooterStatus(self.allocator, &self.extension.footer_statuses, key, text);
    }

    fn clearExtensionFooterStatusLocked(self: *AppState, key: []const u8) !void {
        if (key.len == 0) return;
        if (self.extension.footer_statuses.fetchRemove(key)) |removed| {
            const clears_current_status = std.mem.eql(u8, self.footer.status, removed.value);
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
            if (clears_current_status) try self.replaceLabelLocked(&self.footer.status, "idle");
        }
    }

    fn setActiveOperationLocked(
        self: *AppState,
        kind: ActiveOperationKind,
        label: []const u8,
        options: ActiveOperationOptions,
    ) !void {
        const owned_label = try self.allocator.dupe(u8, label);
        const start_ms = if (self.operation.active) |operation|
            if (operation.kind == kind and std.mem.eql(u8, operation.label, label)) operation.start_ms else self.currentNowMsLocked()
        else
            self.currentNowMsLocked();
        self.clearActiveOperationLocked();
        self.operation.active = .{
            .kind = kind,
            .label = owned_label,
            .start_ms = start_ms,
            .delay_ms = options.delay_ms,
            .attempt = options.attempt,
            .max_attempts = options.max_attempts,
        };
    }

    fn setRecentActivityLocked(self: *AppState, text: []const u8) !void {
        const owned_text = try self.allocator.dupe(u8, text);
        self.allocator.free(self.footer.recent_activity);
        self.footer.recent_activity = owned_text;
    }

    fn clearRecentActivityLocked(self: *AppState) !void {
        self.allocator.free(self.footer.recent_activity);
        self.footer.recent_activity = try self.allocator.dupe(u8, "");
    }

    fn clearActiveOperationLocked(self: *AppState) void {
        if (self.operation.active) |operation| {
            self.allocator.free(operation.label);
            self.operation.active = null;
        }
    }

    pub fn setWorkingMessage(self: *AppState, message: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.footer.working_message, message orelse "Working...");
    }

    pub fn setWorkingVisible(self: *AppState, visible: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.footer.working_visible = visible;
    }

    pub fn takeTerminalProgressUpdate(self: *AppState) ?bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.footer.terminal_progress_dirty) return null;
        self.footer.terminal_progress_dirty = false;
        return self.footer.terminal_progress_active;
    }

    pub fn markTerminalProgress(self: *AppState, active: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.markTerminalProgressLocked(active);
    }

    pub fn handleRetryLifecycleEvent(self: *AppState, event: session_mod.RetryLifecycleEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.markTerminalProgressLocked(false);
        switch (event) {
            .start => |start| {
                const seconds = (start.delay_ms + 999) / 1000;
                const status_text = try std.fmt.allocPrint(
                    self.allocator,
                    "Retrying ({d}/{d}) in {d}s... (Ctrl+C to cancel)",
                    .{ start.attempt, start.max_attempts, seconds },
                );
                defer self.allocator.free(status_text);
                try self.replaceLabelLocked(&self.footer.status, status_text);
                try self.setActiveOperationLocked(.retry, "retry", .{
                    .delay_ms = start.delay_ms,
                    .attempt = start.attempt,
                    .max_attempts = start.max_attempts,
                });
            },
            .end => |end| {
                self.clearActiveOperationLocked();
                if (end.success) {
                    try self.replaceLabelLocked(&self.footer.status, "retry succeeded");
                } else {
                    const status_text = try std.fmt.allocPrint(
                        self.allocator,
                        "Retry failed after {d} attempts: {s}",
                        .{ end.attempt, end.final_error orelse "Unknown error" },
                    );
                    defer self.allocator.free(status_text);
                    try self.replaceLabelLocked(&self.footer.status, status_text);
                }
            },
        }
    }

    pub fn handleCompactionLifecycleEvent(self: *AppState, event: session_mod.CompactionLifecycleEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event) {
            .start => |start| {
                self.markTerminalProgressLocked(true);
                const label = switch (start.reason) {
                    .manual => "Compacting context... (Ctrl+C to cancel)",
                    .threshold => "Auto-compacting... (Ctrl+C to cancel)",
                    .overflow => "Context overflow detected, auto-compacting... (Ctrl+C to cancel)",
                };
                try self.replaceLabelLocked(&self.footer.status, label);
                const active_label = switch (start.reason) {
                    .manual => "Compacting context...",
                    .threshold => "Auto-compacting...",
                    .overflow => "Context overflow detected, auto-compacting...",
                };
                try self.setActiveOperationLocked(.compaction, active_label, .{});
            },
            .end => |end| {
                self.markTerminalProgressLocked(false);
                self.clearActiveOperationLocked();
                if (end.aborted) {
                    try self.replaceLabelLocked(&self.footer.status, if (end.reason == .manual) "Compaction cancelled" else "Auto-compaction cancelled");
                } else if (end.error_message) |message| {
                    try self.replaceLabelLocked(&self.footer.status, message);
                } else if (end.result) |result| {
                    const status_text = try std.fmt.allocPrint(
                        self.allocator,
                        "Compacted context ({d} tokens)",
                        .{result.tokens_before},
                    );
                    defer self.allocator.free(status_text);
                    try self.replaceLabelLocked(&self.footer.status, status_text);
                } else {
                    try self.replaceLabelLocked(&self.footer.status, "compaction finished");
                }
            },
        }
    }

    pub fn clearExtensionUiHooks(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearExtensionUiHooksLocked();
    }

    pub fn applyExtensionRegistryUi(self: *AppState, registry: *const extension_registry.Registry) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.replaceExtensionLinesLocked(&self.extension.header_lines, if (registry.header_hook) |hook| hook.lines else &.{});
        try self.replaceExtensionLinesLocked(&self.extension.footer_lines, if (registry.footer_hook) |hook| hook.lines else &.{});

        const next_editor_label = if (registry.editor_component_hook) |hook| hook.label else null;
        if (self.extension.editor_label) |old| {
            self.allocator.free(old);
            self.extension.editor_label = null;
        }
        if (next_editor_label) |label| {
            self.extension.editor_label = try self.allocator.dupe(u8, label);
        }

        for (self.extension.widgets.items) |*widget| widget.deinit(self.allocator);
        self.extension.widgets.clearRetainingCapacity();
        for (registry.widgets.items) |widget| {
            try self.extension.widgets.append(self.allocator, try extension_ui.cloneRegistryWidget(self.allocator, widget));
        }
    }

    pub fn appendInfo(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.appendItemLocked(.info, text);
    }

    pub fn appendMarkdown(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.appendItemLocked(.markdown, text);
    }

    pub fn appendBashExecutionStart(
        self: *AppState,
        command: []const u8,
        exclude_from_context: bool,
    ) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const text = try bash_execution.formatBashExecutionDisplay(
            self.allocator,
            command,
            "",
            null,
            false,
            false,
            null,
            exclude_from_context,
            true,
        );
        defer self.allocator.free(text);

        try self.appendItemWithExpandedTextLocked(.bash_execution, text, null, null, null);
        try self.replaceLabelLocked(&self.footer.status, "running bash");
        try self.setActiveOperationLocked(.bash_execution, command, .{});
        return self.chat.items.items.len - 1;
    }

    fn updateBashExecution(
        self: *AppState,
        item_index: ?usize,
        command: []const u8,
        output: []const u8,
        exclude_from_context: bool,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const index = item_index orelse return;
        const text = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            null,
            false,
            false,
            null,
            exclude_from_context,
            true,
            false,
        );
        defer self.allocator.free(text);
        const expanded = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            null,
            false,
            false,
            null,
            exclude_from_context,
            true,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, text, expanded)) null else expanded;
        try self.replaceItemExpandedTextLocked(index, text, expanded_text);
        try self.replaceLabelLocked(&self.footer.status, "running bash");
        try self.setActiveOperationLocked(.bash_execution, command, .{});
    }

    pub fn finishBashExecution(
        self: *AppState,
        item_index: ?usize,
        command: []const u8,
        output: []const u8,
        exit_code: ?u8,
        cancelled: bool,
        truncated: bool,
        full_output_path: ?[]const u8,
        exclude_from_context: bool,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const text = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            exit_code,
            cancelled,
            truncated,
            full_output_path,
            exclude_from_context,
            false,
            false,
        );
        defer self.allocator.free(text);
        const expanded = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            exit_code,
            cancelled,
            truncated,
            full_output_path,
            exclude_from_context,
            false,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, text, expanded)) null else expanded;
        if (item_index) |index| {
            try self.replaceItemExpandedTextLocked(index, text, expanded_text);
        } else {
            try self.appendItemWithExpandedTextLocked(.bash_execution, text, expanded_text, null, null);
        }
        const activity = try std.fmt.allocPrint(self.allocator, "{s} bash", .{
            if (cancelled or exit_code == null or exit_code.? != 0) "Tool failed" else "Tool completed",
        });
        defer self.allocator.free(activity);
        try self.setRecentActivityLocked(activity);
        self.clearActiveOperationLocked();
        try self.replaceLabelLocked(&self.footer.status, "idle");
    }

    pub fn appendError(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.removeAssistantThinkingItemLocked();
        try self.appendItemLocked(.@"error", text);
        try self.replaceLabelLocked(&self.footer.status, text);
    }

    pub fn rebuildFromSession(
        self: *AppState,
        session: *const session_mod.AgentSession,
        git_branch: ?[]const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const messages = session.agent.getMessages();
        const stats = session_advanced.getSessionStats(session);

        for (self.chat.items.items) |*item| chat_items.deinit(self.allocator, item);
        self.chat.items.clearRetainingCapacity();
        self.chat.visible_start_index = 0;
        self.chat.scroll_offset = 0;
        self.chat.scroll_max_offset = 0;
        self.chat.total_rows = 0;
        self.chat.visible_rows = 0;
        self.chat.width = 1;
        self.chat.region = .{};
        self.stream.last_streaming_assistant_index = null;
        self.stream.last_streaming_thinking_index = null;
        self.clearPendingEditorImagesLocked();
        self.clearActiveToolUpdatesLocked();
        self.clearStreamingToolCallsLocked();
        self.queue.clearLocked(self.allocator);
        self.clearExtensionUiHooksLocked();
        self.clearActiveOperationLocked();
        self.markTerminalProgressLocked(false);

        try self.replaceLabelLocked(&self.footer.status, "idle");
        try self.replaceLabelLocked(&self.footer.model_label, session.agent.getModel().id);
        try self.replaceLabelLocked(&self.footer.session_label, currentSessionLabel(session));
        try self.replaceLabelLocked(&self.footer.git_branch, git_branch orelse "");
        self.footer.usage_totals = .{
            .input = stats.tokens.input,
            .output = stats.tokens.output,
            .cache_read = stats.tokens.cache_read,
            .cache_write = stats.tokens.cache_write,
            .cost = stats.cost,
        };
        self.footer.context_window = session.agent.getModel().context_window;
        self.footer.context_tokens = if (stats.context_usage) |usage| usage.tokens else null;
        self.footer.context_percent = if (stats.context_usage) |usage| usage.percent else null;
        self.footer.context_unknown = if (stats.context_usage) |usage| usage.percent == null else false;
        self.recalculateContextPercentLocked();
        try self.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");

        for (messages) |message| {
            switch (message) {
                .user => |user_message| {
                    const rendered = try formatPrefixedBlocks(self.allocator, "You", user_message.content);
                    defer self.allocator.free(rendered);
                    try self.appendItemLocked(.user, rendered);
                },
                .assistant => |assistant_message| {
                    try self.appendThinkingBlocksLocked(assistant_message.content);
                    const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                    defer self.allocator.free(rendered);
                    if (rendered.len > 0) {
                        try self.appendItemLocked(.assistant, rendered);
                    }
                    if (assistant_message.tool_calls) |tool_calls| {
                        for (tool_calls) |tool_call| {
                            const tool_text = try formatToolCall(self.allocator, tool_call.name, tool_call.arguments);
                            defer self.allocator.free(tool_text);
                            try self.appendItemLocked(.tool_call, tool_text);
                        }
                    }
                },
                .tool_result => |tool_result| {
                    try self.appendToolResultItemLocked(
                        tool_result.tool_name,
                        tool_result.content,
                        tool_result.is_error,
                        tool_result.details,
                    );
                },
            }
        }
    }

    pub fn handleAgentEvent(self: *AppState, event: agent.AgentEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event.event_type) {
            .agent_start => try self.handleAgentStartLocked(),
            .agent_end => try self.handleAgentEndLocked(),
            .message_start => try self.handleMessageStartLocked(event),
            .message_update => try self.handleMessageUpdateLocked(event),
            .message_end => try self.handleMessageEndLocked(event),
            .tool_execution_start => try self.handleToolExecutionStartLocked(event),
            .tool_execution_update => try self.handleToolExecutionUpdateLocked(event),
            .tool_execution_end => try self.handleToolExecutionEndLocked(event),
            else => {},
        }
    }

    fn handleAgentStartLocked(self: *AppState) !void {
        self.markTerminalProgressLocked(true);
        try self.clearRecentActivityLocked();
        try self.replaceLabelLocked(&self.footer.status, "thinking");
        try self.setActiveOperationLocked(.agent_wait, self.footer.working_message, .{});
    }

    fn handleAgentEndLocked(self: *AppState) !void {
        self.markTerminalProgressLocked(false);
        self.clearActiveOperationLocked();
        if (std.mem.eql(u8, self.footer.status, "streaming") or
            std.mem.eql(u8, self.footer.status, "thinking") or
            std.mem.eql(u8, self.footer.status, "working") or
            std.mem.startsWith(u8, self.footer.status, "working: "))
        {
            try self.replaceLabelLocked(&self.footer.status, "idle");
        }
    }

    fn handleMessageStartLocked(self: *AppState, event: agent.AgentEvent) !void {
        if (event.message) |message| switch (message) {
            .user => |user_message| {
                self.queue.removeMessageLocked(self.allocator, userMessageText(user_message));
                const rendered = try formatPrefixedBlocks(self.allocator, "You", user_message.content);
                defer self.allocator.free(rendered);
                try self.appendItemLocked(.user, rendered);
                if (std.mem.eql(u8, self.footer.status, "thinking")) {
                    try self.ensureAssistantThinkingItemLocked();
                }
            },
            .assistant => |assistant_message| {
                self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
                try self.replaceLabelLocked(&self.footer.status, "thinking");
            },
            else => {},
        };
    }

    /// Returns true if the assistant_message_event sub-dispatch fully handled
    /// the message_update event and the caller should return early.
    fn handleAssistantMessageEventLocked(
        self: *AppState,
        assistant_event: ai.AssistantMessageEvent,
    ) !bool {
        switch (assistant_event.event_type) {
            .thinking_start => {
                try self.replaceLabelLocked(&self.footer.status, "thinking");
                try self.ensureThinkingItemLocked();
                return true;
            },
            .thinking_delta => {
                try self.replaceLabelLocked(&self.footer.status, "thinking");
                try self.appendThinkingDeltaLocked(assistant_event.delta orelse assistant_event.content orelse "");
                return true;
            },
            .thinking_end => {
                try self.replaceLabelLocked(&self.footer.status, "thinking");
                self.freezeStreamingThinkingItemLocked();
                self.stream.last_streaming_thinking_index = null;
                return true;
            },
            .text_start, .text_delta, .text_end => {
                try self.replaceLabelLocked(&self.footer.status, "streaming");
                return false;
            },
            .toolcall_start => {
                try self.replaceLabelLocked(&self.footer.status, "streaming");
                _ = try self.ensureStreamingToolCallItemLocked(
                    assistant_event.content_index,
                    assistant_event.tool_call,
                );
                return true;
            },
            .toolcall_delta => {
                try self.replaceLabelLocked(&self.footer.status, "streaming");
                try self.appendStreamingToolCallDeltaLocked(
                    assistant_event.content_index,
                    assistant_event.tool_call,
                    assistant_event.delta orelse "",
                );
                return true;
            },
            .toolcall_end => {
                try self.replaceLabelLocked(&self.footer.status, "streaming");
                try self.finishStreamingToolCallLocked(
                    assistant_event.content_index,
                    assistant_event.tool_call,
                );
                return true;
            },
            else => return false,
        }
    }

    fn handleMessageUpdateLocked(self: *AppState, event: agent.AgentEvent) !void {
        if (event.assistant_message_event) |assistant_event| {
            if (try self.handleAssistantMessageEventLocked(assistant_event)) return;
        }
        if (event.message) |message| switch (message) {
            .assistant => |assistant_message| {
                self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
                const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                defer self.allocator.free(rendered);
                if (rendered.len == 0) {
                    if (self.stream.last_streaming_assistant_index) |_| return;
                    try self.ensureAssistantThinkingItemLocked();
                    return;
                }
                if (event.assistant_message_event == null) {
                    try self.replaceLabelLocked(&self.footer.status, "streaming");
                }
                const target_index = self.stream.last_streaming_assistant_index orelse blk: {
                    try self.appendItemLocked(.assistant, rendered);
                    self.stream.last_streaming_assistant_index = self.chat.items.items.len - 1;
                    break :blk self.stream.last_streaming_assistant_index.?;
                };
                try self.replaceItemTextLocked(target_index, rendered);
            },
            else => {},
        };
    }

    fn handleMessageEndLocked(self: *AppState, event: agent.AgentEvent) !void {
        if (event.message) |message| switch (message) {
            .user => {},
            .assistant => |assistant_message| {
                self.addUsageLocked(assistant_message.usage);
                self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
                const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                defer self.allocator.free(rendered);
                if (self.stream.last_streaming_assistant_index) |index| {
                    if (rendered.len == 0) {
                        self.removeItemLocked(index);
                    } else {
                        try self.replaceItemTextLocked(index, rendered);
                    }
                } else if (rendered.len > 0) {
                    try self.appendItemLocked(.assistant, rendered);
                }
                self.stream.last_streaming_assistant_index = null;
                self.freezeStreamingThinkingItemLocked();
                self.stream.last_streaming_thinking_index = null;

                switch (assistant_message.stop_reason) {
                    .stop, .length, .tool_use => {},
                    .aborted => try self.replaceLabelLocked(&self.footer.status, "interrupted"),
                    .error_reason => try self.replaceLabelLocked(
                        &self.footer.status,
                        assistant_message.error_message orelse "error",
                    ),
                }
            },
            .tool_result => {},
        };
    }

    fn handleToolExecutionStartLocked(self: *AppState, event: agent.AgentEvent) !void {
        const tool_name = event.tool_name orelse "tool";
        if (event.tool_call_id) |tool_call_id| {
            if (self.streamingToolCallItemIndexByIdLocked(tool_call_id) != null) {
                const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
                defer self.allocator.free(status_text);
                try self.replaceLabelLocked(&self.footer.status, status_text);
                try self.setActiveOperationLocked(.tool_execution, tool_name, .{});
                return;
            }
        }
        const args_value = event.args orelse .null;
        const rendered = try formatToolCall(self.allocator, tool_name, args_value);
        defer self.allocator.free(rendered);
        try self.appendItemLocked(.tool_call, rendered);
        const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
        defer self.allocator.free(status_text);
        try self.replaceLabelLocked(&self.footer.status, status_text);
        try self.setActiveOperationLocked(.tool_execution, tool_name, .{});
    }

    fn handleToolExecutionUpdateLocked(self: *AppState, event: agent.AgentEvent) !void {
        const tool_name = event.tool_name orelse "tool";
        const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
        defer self.allocator.free(status_text);
        if (event.tool_call_id) |tool_call_id| {
            if (event.partial_result) |partial_result| {
                if (self.activeToolUpdateIndexLocked(tool_call_id)) |index| {
                    try self.replaceToolResultItemLocked(
                        index,
                        tool_name,
                        partial_result.content,
                        false,
                        partial_result.details,
                    );
                } else {
                    try self.appendToolResultItemLocked(
                        tool_name,
                        partial_result.content,
                        false,
                        partial_result.details,
                    );
                    try self.setActiveToolUpdateLocked(tool_call_id, self.chat.items.items.len - 1);
                }
            }
        }
        try self.replaceLabelLocked(&self.footer.status, status_text);
        try self.setActiveOperationLocked(.tool_execution, tool_name, .{});
    }

    fn handleToolExecutionEndLocked(self: *AppState, event: agent.AgentEvent) !void {
        const tool_name = event.tool_name orelse "tool";
        const result = event.result orelse return;
        if (event.tool_call_id) |tool_call_id| {
            if (self.takeActiveToolUpdateIndexLocked(tool_call_id)) |index| {
                try self.replaceToolResultItemLocked(
                    index,
                    tool_name,
                    result.content,
                    event.is_error orelse false,
                    result.details,
                );
            } else {
                try self.appendToolResultItemLocked(
                    tool_name,
                    result.content,
                    event.is_error orelse false,
                    result.details,
                );
            }
        } else {
            try self.appendToolResultItemLocked(
                tool_name,
                result.content,
                event.is_error orelse false,
                result.details,
            );
        }
        const activity = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{
            if (event.is_error orelse false) "Tool failed" else "Tool completed",
            tool_name,
        });
        defer self.allocator.free(activity);
        try self.setRecentActivityLocked(activity);
        try self.replaceLabelLocked(&self.footer.status, "thinking");
        try self.setActiveOperationLocked(.agent_wait, self.footer.working_message, .{});
    }

    fn appendThinkingBlocksLocked(self: *AppState, blocks: []const ai.ContentBlock) !void {
        for (blocks) |block| switch (block) {
            .thinking => |thinking| if (thinking.thinking.len > 0) {
                try self.appendItemLocked(.thinking, thinking.thinking);
            },
            else => {},
        };
    }

    pub fn ensureThinkingItemLocked(self: *AppState) !void {
        self.removeAssistantThinkingItemLocked();
        if (self.stream.last_streaming_thinking_index) |index| {
            if (index < self.chat.items.items.len and self.chat.items.items[index].kind == .thinking) return;
        }

        try self.appendStreamingThinkingItemLocked("");
        self.stream.last_streaming_thinking_index = self.chat.items.items.len - 1;
    }

    fn freezeStreamingThinkingItemLocked(self: *AppState) void {
        const index = self.stream.last_streaming_thinking_index orelse return;
        if (index >= self.chat.items.items.len or self.chat.items.items[index].kind != .thinking) return;
        if (self.chat.items.items[index].frozen_frame_index != null) return;
        self.chat.items.items[index].frozen_frame_index = thinkingFrameIndex(self.chat.items.items[index], self.currentNowMsLocked());
    }

    pub fn appendThinkingDeltaLocked(self: *AppState, delta: []const u8) !void {
        if (delta.len == 0) {
            try self.ensureThinkingItemLocked();
            return;
        }
        try self.ensureThinkingItemLocked();
        const index = self.stream.last_streaming_thinking_index orelse return;
        try self.appendToItemTextLocked(index, delta);
    }

    fn ensureStreamingToolCallItemLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call: ?ai.ToolCall,
    ) !usize {
        if (tool_call) |call| {
            if (self.streamingToolCallItemIndexByIdLocked(call.id)) |index| return index;
        }
        if (content_index) |index_value| {
            if (self.streamingToolCallItemIndexByContentIndexLocked(index_value)) |index| return index;
        }

        const initial_text = if (tool_call) |call|
            try formatToolCall(self.allocator, call.name, call.arguments)
        else
            try formatStreamingToolCall(self.allocator, null, "");
        defer self.allocator.free(initial_text);

        try self.appendItemLocked(.tool_call, initial_text);
        const item_index = self.chat.items.items.len - 1;
        try self.tool.streaming_tool_calls.append(self.allocator, .{
            .content_index = content_index,
            .tool_call_id = if (tool_call) |call| try self.allocator.dupe(u8, call.id) else null,
            .item_index = item_index,
        });
        return item_index;
    }

    fn appendStreamingToolCallDeltaLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call: ?ai.ToolCall,
        delta: []const u8,
    ) !void {
        const index = try self.ensureStreamingToolCallItemLocked(content_index, tool_call);
        if (delta.len == 0) return;
        try self.appendToItemTextLocked(index, delta);
    }

    fn finishStreamingToolCallLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call: ?ai.ToolCall,
    ) !void {
        const call = tool_call orelse return;
        const index = try self.ensureStreamingToolCallItemLocked(content_index, call);
        const rendered = try formatToolCall(self.allocator, call.name, call.arguments);
        defer self.allocator.free(rendered);
        try self.replaceItemTextLocked(index, rendered);
        try self.setStreamingToolCallIdLocked(content_index, call.id, index);
    }

    pub fn ensureAssistantThinkingItemLocked(self: *AppState) !void {
        if (self.stream.last_streaming_assistant_index) |index| {
            if (index < self.chat.items.items.len and self.chat.items.items[index].kind == .assistant and self.chat.items.items[index].text.len == 0) {
                try self.replaceItemTextLocked(index, ASSISTANT_THINKING_TEXT);
            }
            return;
        }

        try self.appendItemLocked(.assistant, ASSISTANT_THINKING_TEXT);
        self.stream.last_streaming_assistant_index = self.chat.items.items.len - 1;
    }

    pub fn removeAssistantThinkingItemLocked(self: *AppState) void {
        self.stream.last_streaming_assistant_index = null;
        if (self.findAssistantThinkingItemLocked()) |index| {
            self.removeItemLocked(index);
        }
    }

    fn findAssistantThinkingItemLocked(self: *const AppState) ?usize {
        if (self.stream.last_streaming_assistant_index) |index| {
            if (index < self.chat.items.items.len) {
                const item = self.chat.items.items[index];
                if (item.kind == .assistant and std.mem.eql(u8, item.text, ASSISTANT_THINKING_TEXT)) return index;
            }
        }
        for (self.chat.items.items, 0..) |item, index| {
            if (item.kind == .assistant and std.mem.eql(u8, item.text, ASSISTANT_THINKING_TEXT)) return index;
        }
        return null;
    }

    pub fn appendItemLocked(self: *AppState, kind: ChatKind, text: []const u8) !void {
        const frozen_frame_index: ?usize = if (kind == .thinking) 0 else null;
        try self.appendItemWithExpandedTextLocked(kind, text, null, null, frozen_frame_index);
    }

    fn appendStreamingThinkingItemLocked(self: *AppState, text: []const u8) !void {
        try self.appendItemWithTimingLocked(.thinking, text, self.currentNowMsLocked(), null);
    }

    fn appendItemWithTimingLocked(
        self: *AppState,
        kind: ChatKind,
        text: []const u8,
        start_ms: ?i64,
        frozen_frame_index: ?usize,
    ) !void {
        try self.appendItemWithExpandedTextLocked(kind, text, null, start_ms, frozen_frame_index);
    }

    fn appendItemWithExpandedTextLocked(
        self: *AppState,
        kind: ChatKind,
        text: []const u8,
        expanded_text: ?[]const u8,
        start_ms: ?i64,
        frozen_frame_index: ?usize,
    ) !void {
        const was_at_tail = self.chat.scroll_offset == 0;
        const display_text = if (kind == .thinking and self.stream.hide_thinking_blocks) self.stream.hidden_thinking_label else text;
        const stored_expanded_text = if (kind == .thinking and self.stream.hide_thinking_blocks) text else expanded_text;
        const owned_text = try self.allocator.dupe(u8, display_text);
        errdefer self.allocator.free(owned_text);
        const owned_expanded_text = if (stored_expanded_text) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_expanded_text) |value| self.allocator.free(value);
        try self.chat.items.append(self.allocator, .{
            .kind = kind,
            .text = owned_text,
            .expanded_text = owned_expanded_text,
            .start_ms = start_ms,
            .frozen_frame_index = frozen_frame_index,
        });
        if (was_at_tail) self.chat.scroll_offset = 0;
    }

    fn appendToolResultItemLocked(
        self: *AppState,
        tool_name: []const u8,
        blocks: []const ai.ContentBlock,
        is_error: bool,
        details: ?std.json.Value,
    ) !void {
        const collapsed = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            false,
        );
        defer self.allocator.free(collapsed);
        const expanded = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, collapsed, expanded)) null else expanded;
        try self.appendItemWithExpandedTextLocked(.tool_result, collapsed, expanded_text, null, null);
    }

    fn currentNowMsLocked(self: *const AppState) i64 {
        return self.timing.clock_now_ms_fn(self.timing.clock_context);
    }

    pub fn appendToItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.chat.items.items.len or text.len == 0) return;
        const item = &self.chat.items.items[index];
        if (item.kind == .thinking) {
            if (item.expanded_text) |old_hidden_text| {
                const combined = try self.allocator.alloc(u8, old_hidden_text.len + text.len);
                @memcpy(combined[0..old_hidden_text.len], old_hidden_text);
                @memcpy(combined[old_hidden_text.len..], text);
                self.allocator.free(old_hidden_text);
                item.expanded_text = combined;
                return;
            }
        }
        const old = item.text;
        const combined = try self.allocator.alloc(u8, old.len + text.len);
        @memcpy(combined[0..old.len], old);
        @memcpy(combined[old.len..], text);
        self.allocator.free(old);
        item.text = combined;
    }

    pub fn replaceItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.chat.items.items.len) return;
        try self.replaceItemExpandedTextLocked(index, text, null);
    }

    fn replaceToolResultItemLocked(
        self: *AppState,
        index: usize,
        tool_name: []const u8,
        blocks: []const ai.ContentBlock,
        is_error: bool,
        details: ?std.json.Value,
    ) !void {
        const collapsed = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            false,
        );
        defer self.allocator.free(collapsed);
        const expanded = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, collapsed, expanded)) null else expanded;
        try self.replaceItemExpandedTextLocked(index, collapsed, expanded_text);
    }

    fn replaceItemExpandedTextLocked(self: *AppState, index: usize, text: []const u8, expanded_text: ?[]const u8) !void {
        if (index >= self.chat.items.items.len) return;
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_expanded_text = if (expanded_text) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_expanded_text) |value| self.allocator.free(value);

        self.allocator.free(self.chat.items.items[index].text);
        if (self.chat.items.items[index].expanded_text) |value| self.allocator.free(value);
        self.chat.items.items[index].text = owned_text;
        self.chat.items.items[index].expanded_text = owned_expanded_text;
    }

    pub fn removeItemLocked(self: *AppState, index: usize) void {
        if (index >= self.chat.items.items.len) return;
        chat_items.deinit(self.allocator, &self.chat.items.items[index]);
        _ = self.chat.items.orderedRemove(index);
        for (self.tool.active_tool_updates.items) |*entry| {
            if (entry.item_index > index) entry.item_index -= 1;
        }
        var streaming_index: usize = 0;
        while (streaming_index < self.tool.streaming_tool_calls.items.len) {
            const entry = &self.tool.streaming_tool_calls.items[streaming_index];
            if (entry.item_index == index) {
                if (entry.tool_call_id) |tool_call_id| self.allocator.free(tool_call_id);
                _ = self.tool.streaming_tool_calls.orderedRemove(streaming_index);
                continue;
            }
            if (entry.item_index > index) entry.item_index -= 1;
            streaming_index += 1;
        }
        adjustOptionalIndexAfterRemove(&self.stream.last_streaming_assistant_index, index);
        adjustOptionalIndexAfterRemove(&self.stream.last_streaming_thinking_index, index);
        if (self.chat.visible_start_index > self.chat.items.items.len) {
            self.chat.visible_start_index = self.chat.items.items.len;
        }
    }

    pub fn replaceLabelLocked(self: *AppState, field: *[]u8, text: []const u8) !void {
        self.allocator.free(field.*);
        field.* = try self.allocator.dupe(u8, text);
    }

    fn replaceExtensionLinesLocked(self: *AppState, field: *[][]u8, lines: []const []const u8) !void {
        deinitOwnedStringList(self.allocator, field.*);
        field.* = try cloneConstStringList(self.allocator, lines);
    }

    fn clearExtensionUiHooksLocked(self: *AppState) void {
        deinitOwnedStringList(self.allocator, self.extension.header_lines);
        self.extension.header_lines = &.{};
        deinitOwnedStringList(self.allocator, self.extension.footer_lines);
        self.extension.footer_lines = &.{};
        if (self.extension.editor_label) |label| self.allocator.free(label);
        self.extension.editor_label = null;
        for (self.extension.widgets.items) |*widget| widget.deinit(self.allocator);
        self.extension.widgets.clearRetainingCapacity();
        extension_ui.clearFooterStatuses(self.allocator, &self.extension.footer_statuses);
        self.footer.working_visible = true;
        self.replaceLabelLocked(&self.footer.working_message, "Working...") catch {};
    }

    fn applyThinkingBlockVisibilityLocked(self: *AppState) !void {
        for (self.chat.items.items) |*item| {
            if (item.kind != .thinking) continue;
            if (self.stream.hide_thinking_blocks) {
                if (item.expanded_text != null) {
                    self.allocator.free(item.text);
                    item.text = try self.allocator.dupe(u8, self.stream.hidden_thinking_label);
                    continue;
                }
                const original = item.text;
                item.text = try self.allocator.dupe(u8, self.stream.hidden_thinking_label);
                item.expanded_text = original;
            } else if (item.expanded_text) |original| {
                self.allocator.free(item.text);
                item.text = original;
                item.expanded_text = null;
            }
        }
    }

    pub fn addUsageLocked(self: *AppState, usage: ai.Usage) void {
        self.footer.usage_totals.input +|= usage.input;
        self.footer.usage_totals.output +|= usage.output;
        self.footer.usage_totals.cache_read +|= usage.cache_read;
        self.footer.usage_totals.cache_write +|= usage.cache_write;
        self.footer.usage_totals.cost += usage.cost.total;
    }

    pub fn updateContextUsageLocked(self: *AppState, tokens: ?u32) void {
        if (tokens == null) {
            self.footer.context_unknown = true;
        } else {
            self.footer.context_unknown = false;
        }
        self.footer.context_tokens = tokens;
        self.recalculateContextPercentLocked();
    }

    pub fn recalculateContextPercentLocked(self: *AppState) void {
        if (self.footer.context_window == 0) {
            self.footer.context_percent = null;
            self.footer.context_tokens = null;
            self.footer.context_unknown = false;
            return;
        }

        if (self.footer.context_unknown) {
            self.footer.context_percent = null;
            return;
        }

        if (self.footer.context_tokens) |tokens| {
            self.footer.context_percent =
                (@as(f64, @floatFromInt(tokens)) / @as(f64, @floatFromInt(self.footer.context_window))) * 100.0;
            return;
        }

        self.footer.context_tokens = 0;
        self.footer.context_percent = 0.0;
    }

    fn clearPendingEditorImagesLocked(self: *AppState) void {
        self.image.clearPending(self.allocator);
    }

    fn retirePendingEditorImageLocked(self: *AppState, image: *PendingEditorImage) void {
        self.image.retirePendingImage(self.allocator, image);
    }

    fn flushRetiredTerminalImagesLocked(self: *AppState, terminal_image_context: TerminalImageContext) void {
        self.image.flushRetiredTerminalImages(terminal_image_context);
    }

    fn transmitKittyImage(
        self: *AppState,
        image: ai.ImageContent,
        terminal_image_context: ?TerminalImageContext,
    ) !?tui.components.image.KittyImage {
        const context = terminal_image_context orelse return null;
        if (!context.vx.caps.kitty_graphics) return null;

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(image.data) catch return null;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);
        std.base64.standard.Decoder.decode(decoded, image.data) catch return null;

        const transmitted = context.vx.loadImage(self.allocator, context.tty, .{ .mem = decoded }) catch return null;
        return tui.components.image.KittyImage.fromVaxisImage(transmitted);
    }

    fn clearActiveToolUpdatesLocked(self: *AppState) void {
        for (self.tool.active_tool_updates.items) |entry| self.allocator.free(entry.tool_call_id);
        self.tool.active_tool_updates.clearRetainingCapacity();
    }

    fn clearStreamingToolCallsLocked(self: *AppState) void {
        for (self.tool.streaming_tool_calls.items) |entry| {
            if (entry.tool_call_id) |tool_call_id| self.allocator.free(tool_call_id);
        }
        self.tool.streaming_tool_calls.clearRetainingCapacity();
    }

    fn streamingToolCallItemIndexByIdLocked(self: *AppState, tool_call_id: []const u8) ?usize {
        for (self.tool.streaming_tool_calls.items) |entry| {
            const entry_id = entry.tool_call_id orelse continue;
            if (std.mem.eql(u8, entry_id, tool_call_id)) return entry.item_index;
        }
        return null;
    }

    fn streamingToolCallItemIndexByContentIndexLocked(self: *AppState, content_index: u32) ?usize {
        for (self.tool.streaming_tool_calls.items) |entry| {
            if (entry.content_index == content_index) return entry.item_index;
        }
        return null;
    }

    fn setStreamingToolCallIdLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call_id: []const u8,
        item_index: usize,
    ) !void {
        for (self.tool.streaming_tool_calls.items) |*entry| {
            const content_matches = if (content_index) |value|
                entry.content_index != null and entry.content_index.? == value
            else
                false;
            const id_matches = if (entry.tool_call_id) |entry_id|
                std.mem.eql(u8, entry_id, tool_call_id)
            else
                false;
            if (!content_matches and !id_matches) continue;

            if (entry.tool_call_id) |entry_id| {
                if (!std.mem.eql(u8, entry_id, tool_call_id)) {
                    self.allocator.free(entry_id);
                    entry.tool_call_id = try self.allocator.dupe(u8, tool_call_id);
                }
            } else {
                entry.tool_call_id = try self.allocator.dupe(u8, tool_call_id);
            }
            entry.item_index = item_index;
            return;
        }

        try self.tool.streaming_tool_calls.append(self.allocator, .{
            .content_index = content_index,
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .item_index = item_index,
        });
    }

    fn activeToolUpdateIndexLocked(self: *AppState, tool_call_id: []const u8) ?usize {
        for (self.tool.active_tool_updates.items) |entry| {
            if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) return entry.item_index;
        }
        return null;
    }

    fn setActiveToolUpdateLocked(self: *AppState, tool_call_id: []const u8, item_index: usize) !void {
        for (self.tool.active_tool_updates.items) |*entry| {
            if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) {
                entry.item_index = item_index;
                return;
            }
        }
        try self.tool.active_tool_updates.append(self.allocator, .{
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .item_index = item_index,
        });
    }

    fn takeActiveToolUpdateIndexLocked(self: *AppState, tool_call_id: []const u8) ?usize {
        for (self.tool.active_tool_updates.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.tool_call_id, tool_call_id)) continue;
            const item_index = entry.item_index;
            self.allocator.free(entry.tool_call_id);
            _ = self.tool.active_tool_updates.orderedRemove(index);
            return item_index;
        }
        return null;
    }

    fn markTerminalProgressLocked(self: *AppState, active: bool) void {
        if (self.footer.terminal_progress_active == active and self.footer.terminal_progress_dirty) return;
        if (self.footer.terminal_progress_active != active or !self.footer.terminal_progress_dirty) {
            self.footer.terminal_progress_active = active;
            self.footer.terminal_progress_dirty = true;
        }
    }
};

fn bashTaskHooks(state: *AppState) user_bash_task_mod.Hooks {
    return .{
        .allocator = state.allocator,
        .io = state.io,
        .context = state,
        .append_start = bashAppendStartHook,
        .update = bashUpdateHook,
        .finish = bashFinishHook,
        .set_status = bashSetStatusHook,
        .append_error = bashAppendErrorHook,
    };
}

fn bashAppendStartHook(context: *anyopaque, command: []const u8, exclude_from_context: bool) anyerror!usize {
    const state: *AppState = @ptrCast(@alignCast(context));
    return state.appendBashExecutionStart(command, exclude_from_context);
}

fn bashUpdateHook(
    context: *anyopaque,
    item_index: ?usize,
    command: []const u8,
    output: []const u8,
    exclude_from_context: bool,
) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.updateBashExecution(item_index, command, output, exclude_from_context);
}

fn bashFinishHook(
    context: *anyopaque,
    item_index: ?usize,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    exclude_from_context: bool,
) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.finishBashExecution(
        item_index,
        command,
        output,
        exit_code,
        cancelled,
        truncated,
        full_output_path,
        exclude_from_context,
    );
}

fn bashSetStatusHook(context: *anyopaque, text: []const u8) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.setStatus(text);
}

fn bashAppendErrorHook(context: *anyopaque, text: []const u8) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.appendError(text);
}

fn adjustOptionalIndexAfterRemove(index: *?usize, removed_index: usize) void {
    const current = index.* orelse return;
    if (current == removed_index) {
        index.* = null;
    } else if (current > removed_index) {
        index.* = current - 1;
    }
}

pub const QueueDisplayMode = enum {
    steering,
    follow_up,
};

pub const ScreenComponent = struct {
    state: *AppState,
    editor: *tui.Editor,
    height: usize = 24,
    now_ms: i64 = 0,
    overlay: ?*SelectorOverlay = null,
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,
    terminal_name: []const u8 = "term",
    image_render_policy: tui.terminal_image.ImageRenderPolicy = .{},
    after_snapshot_hook: ?RenderHook = null,

    pub fn drawComponent(self: *const ScreenComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const ScreenComponent = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    pub fn draw(
        self: *const ScreenComponent,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        self.editor.setEditorStyle(if (self.theme) |t| tui.styleFor(t, .editor) else .{});
        window.clear();

        var snapshot = try self.state.snapshotForRender(ctx.arena);

        if (self.after_snapshot_hook) |hook| hook.run();

        const layout = try computeScreenLayout(
            ctx.arena,
            self,
            &snapshot,
            @max(@as(usize, window.width), 1),
            @max(@as(usize, window.height), 1),
        );

        var row: usize = 0;
        if (layout.task_panel_height > 0 and row < window.height) {
            const panel_window = window.child(.{
                .y_off = @intCast(row),
                .height = @intCast(@min(layout.task_panel_height, @as(usize, window.height) - row)),
            });
            _ = try drawTaskPanel(panel_window, .{
                .window = panel_window,
                .arena = ctx.arena,
            }, self.keybindings, self.theme, &snapshot, self.now_ms);
        }
        row += layout.task_panel_height;

        if (layout.extension_header_height > 0 and row < window.height) {
            row += drawExtensionHeaderLines(window, row, snapshot.extension_header_lines, self.theme);
        }

        row = try self.drawChatSection(window, ctx.arena, &snapshot, layout, row);
        row = drawScrollIndicatorSection(self, window, layout.width, row, &snapshot);
        row = try drawQueuedSection(window, ctx.arena, self.keybindings, self.theme, &snapshot, layout.queued_height, row);
        row = try drawExecutionSection(window, ctx.arena, self.keybindings, self.theme, &snapshot, self.now_ms, layout.execution_height, row);
        row = try self.drawPromptSection(window, ctx.arena, &snapshot, layout, row);
        row = try self.drawAutocompleteSection(window, ctx.arena, layout, row);
        row = try drawContextGaugeSection(window, ctx.arena, self.theme, &snapshot, layout.context_gauge_height, row);

        if (row < window.height) {
            try drawFooterWithTerminal(window, row, layout.footer_text, self.terminal_name, self.theme, ctx.arena);
        }
        row += 1;

        return .{
            .width = window.width,
            .height = @intCast(@min(row, @as(usize, window.height))),
        };
    }

    fn drawChatSection(
        self: *const ScreenComponent,
        window: tui.vaxis.Window,
        allocator: std.mem.Allocator,
        snapshot: *const RenderStateSnapshot,
        layout: ScreenLayout,
        row: usize,
    ) !usize {
        const sel_range = currentSelectionRange(self.state);
        var selected_text = std.ArrayList(u8).empty;
        defer selected_text.deinit(allocator);

        const chat_metrics = try drawChatViewport(
            allocator,
            self.keybindings,
            self.theme,
            snapshot.items,
            window,
            row,
            layout.chat_capacity,
            snapshot.chat_scroll_offset,
            self.now_ms,
            snapshot.all_expanded,
            sel_range,
            if (sel_range != null) &selected_text else null,
        );
        if (!self.state.selection.active and self.state.hasSelection() and selected_text.items.len > 0) {
            copySelectedText(allocator, self.state.io, selected_text.items);
            self.state.clearSelection();
        }
        self.state.updateChatScrollLayout(chat_metrics.rendered_height, chat_metrics.visible_height, row, layout.width);
        return row + layout.chat_capacity;
    }

    fn drawPromptSection(
        self: *const ScreenComponent,
        window: tui.vaxis.Window,
        allocator: std.mem.Allocator,
        snapshot: *const RenderStateSnapshot,
        layout: ScreenLayout,
        row: usize,
    ) !usize {
        var next_row = row;
        const prompt_start_row = next_row + layout.extension_above_height + layout.extension_editor_height;

        if (layout.extension_above_height > 0 and next_row < window.height) {
            next_row += drawExtensionWidgetLines(window, next_row, snapshot.extension_widgets, .above_editor, self.theme);
        }
        if (snapshot.extension_editor_label) |label| {
            if (next_row < window.height) {
                const editor_label = try std.fmt.allocPrint(allocator, "Extension editor: {s}", .{label});
                drawFittedLine(window, next_row, editor_label, styleForToken(self.theme, .status));
            }
            next_row += 1;
        }
        if (next_row < window.height) {
            const prompt_window = window.child(.{
                .y_off = @intCast(next_row),
                .height = @intCast(@min(layout.core_prompt_height, @as(usize, window.height) - next_row)),
            });
            _ = try drawPromptLines(
                prompt_window,
                .{ .window = prompt_window, .arena = allocator },
                self.theme,
                self.editor,
                snapshot.pending_editor_images,
                self.image_render_policy,
            );
        }
        next_row += layout.core_prompt_height;
        if (layout.extension_below_height > 0 and next_row < window.height) {
            next_row += drawExtensionWidgetLines(window, next_row, snapshot.extension_widgets, .below_editor, self.theme);
        }

        if (prompt_start_row + layout.editor_y < window.height and @as(usize, window.width) > layout.editor_x) {
            const editor_window = window.child(.{
                .x_off = @intCast(layout.editor_x),
                .y_off = @intCast(prompt_start_row + layout.editor_y),
                .width = @intCast(layout.editor_window_width),
                .height = 1,
            });
            _ = try self.editor.draw(editor_window, .{
                .window = editor_window,
                .arena = allocator,
            });
        }
        return next_row;
    }

    fn drawAutocompleteSection(
        self: *const ScreenComponent,
        window: tui.vaxis.Window,
        allocator: std.mem.Allocator,
        layout: ScreenLayout,
        row: usize,
    ) !usize {
        if (layout.autocomplete_height == 0 or row >= window.height) return row;
        const autocomplete_window = window.child(.{
            .x_off = @intCast(layout.editor_x),
            .y_off = @intCast(row),
            .width = @intCast(layout.editor_window_width),
            .height = @intCast(@min(layout.autocomplete_height, @as(usize, window.height) - row)),
        });
        _ = try self.editor.drawAutocomplete(autocomplete_window, .{
            .window = autocomplete_window,
            .arena = allocator,
        });
        return row + layout.autocomplete_height;
    }
};

const ScreenLayout = struct {
    width: usize,
    footer_text: []u8,
    extension_header_height: usize,
    extension_above_height: usize,
    extension_editor_height: usize,
    extension_below_height: usize,
    core_prompt_height: usize,
    queued_height: usize,
    execution_height: usize,
    context_gauge_height: usize,
    autocomplete_height: usize,
    task_panel_height: usize,
    chat_capacity: usize,
    editor_window_width: usize,
    editor_x: usize,
    editor_y: usize,
};

fn computeScreenLayout(
    allocator: std.mem.Allocator,
    screen: *const ScreenComponent,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    window_height: usize,
) !ScreenLayout {
    const footer_text = if (snapshot.extension_footer_lines.len > 0)
        try formatExtensionFooterLineWithTerminal(allocator, null, snapshot, screen.terminal_name, width)
    else if (showExecutionPanel(snapshot))
        try formatFooterText(allocator, snapshot, width)
    else
        try formatFooterTextForDisplay(allocator, screen.keybindings, snapshot, width, screen.now_ms);

    const extension_header_height = snapshot.extension_header_lines.len;
    const extension_above_height = extensionWidgetLineCount(snapshot.extension_widgets, .above_editor);
    const extension_editor_height: usize = if (snapshot.extension_editor_label != null) 1 else 0;
    const extension_below_height = extensionWidgetLineCount(snapshot.extension_widgets, .below_editor);
    const core_prompt_height = try measurePromptHeight(
        allocator,
        screen.theme,
        screen.editor,
        snapshot.pending_editor_images,
        screen.image_render_policy,
        width,
    );
    const prompt_height = core_prompt_height + extension_above_height + extension_editor_height + extension_below_height;
    const queued_height = try measureQueuedMessagesHeight(allocator, screen.keybindings, screen.theme, snapshot, width);
    const execution_height = try measureExecutionPanelHeight(allocator, screen.keybindings, snapshot, width, screen.now_ms);
    const context_gauge_height = measureContextGaugeHeight(snapshot, width);
    const autocomplete_height = try measureAutocompleteHeight(allocator, screen.theme, screen.editor, width);
    const task_panel_height = taskPanelHeightForWidth(width);
    const scroll_indicator_height: usize = if (snapshot.chat_scroll_offset > 0) 1 else 0;
    const reserved_lines: usize = task_panel_height +
        extension_header_height +
        prompt_height +
        queued_height +
        execution_height +
        context_gauge_height +
        1 +
        autocomplete_height +
        scroll_indicator_height;
    const chat_capacity = if (window_height > reserved_lines) window_height - reserved_lines else 1;
    const editor_window_width = promptEditorWidth(width);
    const editor_x = promptEditorOffsetX(width);

    return .{
        .width = width,
        .footer_text = footer_text,
        .extension_header_height = extension_header_height,
        .extension_above_height = extension_above_height,
        .extension_editor_height = extension_editor_height,
        .extension_below_height = extension_below_height,
        .core_prompt_height = core_prompt_height,
        .queued_height = queued_height,
        .execution_height = execution_height,
        .context_gauge_height = context_gauge_height,
        .autocomplete_height = autocomplete_height,
        .task_panel_height = task_panel_height,
        .chat_capacity = chat_capacity,
        .editor_window_width = editor_window_width,
        .editor_x = editor_x,
        .editor_y = promptEditorOffsetY(width),
    };
}

fn currentSelectionRange(state: *const AppState) ?chat_rendering.SelectionRange {
    if (!state.hasSelection()) return null;
    const selection_range = state.getSelectionRange() orelse return null;
    return .{
        .start_row = selection_range.start_row,
        .start_col = selection_range.start_col,
        .end_row = selection_range.end_row,
        .end_col = selection_range.end_col,
    };
}

fn drawScrollIndicatorSection(
    screen: *const ScreenComponent,
    window: tui.vaxis.Window,
    width: usize,
    row: usize,
    snapshot: *const RenderStateSnapshot,
) usize {
    if (snapshot.chat_scroll_offset == 0 or row >= window.height) {
        screen.state.chat.scroll_indicator_row = null;
        return row;
    }

    screen.state.chat.scroll_indicator_row = row;
    const indicator_text = " \xe2\x86\x91 scrolled  \xe2\x86\x93 Jump to bottom (Ctrl+End) ";
    const indicator_style = styleForToken(screen.theme, .status);
    const indicator_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    indicator_window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = indicator_style,
    });
    const text_width = std.unicode.utf8CountCodepoints(indicator_text) catch indicator_text.len;
    const x_center: usize = if (width > text_width) (width - text_width) / 2 else 0;
    _ = indicator_window.printSegment(.{
        .text = indicator_text,
        .style = indicator_style,
    }, .{ .col_offset = @intCast(x_center), .wrap = .none });
    return row + 1;
}

fn drawQueuedSection(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    queued_height: usize,
    row: usize,
) !usize {
    if (queued_height == 0 or row >= window.height) return row;
    const queued_window = window.child(.{
        .y_off = @intCast(row),
        .height = @intCast(@min(queued_height, @as(usize, window.height) - row)),
    });
    _ = try drawQueuedMessages(queued_window, .{
        .window = queued_window,
        .arena = allocator,
    }, keybindings, theme, snapshot);
    return row + queued_height;
}

fn drawExecutionSection(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    now_ms: i64,
    execution_height: usize,
    row: usize,
) !usize {
    if (execution_height == 0 or row >= window.height) return row;
    const execution_window = window.child(.{
        .y_off = @intCast(row),
        .height = @intCast(@min(execution_height, @as(usize, window.height) - row)),
    });
    const rendered = try drawExecutionPanel(
        execution_window,
        allocator,
        keybindings,
        theme,
        snapshot,
        now_ms,
    );
    return row + rendered;
}

fn drawContextGaugeSection(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    context_gauge_height: usize,
    row: usize,
) !usize {
    if (context_gauge_height == 0 or row >= window.height) return row;
    const gauge_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    const rendered = try drawContextGauge(gauge_window, allocator, theme, snapshot);
    return row + rendered;
}

pub fn renderScreenToLines(allocator: std.mem.Allocator, screen: *const ScreenComponent, width: usize) ![]const []const u8 {
    var vscreen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@max(screen.height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer vscreen.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const window = tui.draw.rootWindow(&vscreen);
    window.clear();
    _ = try screen.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    for (0..screen.height) |row| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        var col: usize = 0;
        while (col < width) {
            const cell = vscreen.readCell(@intCast(col), @intCast(row)) orelse break;
            if (cell.char.grapheme.len > 0) {
                try builder.appendSlice(allocator, cell.char.grapheme);
                col += if (cell.char.width > 0) @as(usize, cell.char.width) else 1;
            } else {
                try builder.append(allocator, ' ');
                col += 1;
            }
        }
        try lines.append(allocator, try builder.toOwnedSlice(allocator));
    }
    return lines.toOwnedSlice(allocator);
}

pub fn styleForToken(theme: ?*const resources_mod.Theme, token: resources_mod.ThemeToken) tui.vaxis.Cell.Style {
    return if (theme) |active_theme| tui.styleFor(active_theme, token) else .{};
}

fn copySelectedText(allocator: std.mem.Allocator, io: std.Io, text: []const u8) void {
    if (text.len == 0) return;
    const owned = allocator.dupe(u8, text) catch return;
    defer allocator.free(owned);
    slash_commands.copyTextToClipboard(io, owned) catch {};
}

fn drawFittedLine(
    window: tui.vaxis.Window,
    row: usize,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) void {
    if (row >= window.height) return;
    const line_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    line_window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
    _ = line_window.printSegment(.{
        .text = text,
        .style = style,
    }, .{ .wrap = .none });
}

fn extensionWidgetLineCount(widgets: []const ExtensionWidget, placement: ExtensionWidgetPlacement) usize {
    var count: usize = 0;
    for (widgets) |widget| {
        if (widget.placement != placement) continue;
        count += @max(widget.lines.len, 1);
    }
    return count;
}

fn drawExtensionHeaderLines(
    window: tui.vaxis.Window,
    start_row: usize,
    lines: []const []const u8,
    theme: ?*const resources_mod.Theme,
) usize {
    var row = start_row;
    for (lines) |line| {
        if (row >= window.height) return row - start_row;
        drawFittedLine(window, row, line, styleForToken(theme, .status));
        row += 1;
    }
    return row - start_row;
}

fn drawExtensionWidgetLines(
    window: tui.vaxis.Window,
    start_row: usize,
    widgets: []const ExtensionWidget,
    placement: ExtensionWidgetPlacement,
    theme: ?*const resources_mod.Theme,
) usize {
    var row = start_row;
    for (widgets) |widget| {
        if (widget.placement != placement) continue;
        for (widget.lines) |line| {
            if (row >= window.height) return row - start_row;
            drawFittedLine(window, row, line, styleForToken(theme, .status));
            row += 1;
        }
    }
    return row - start_row;
}

fn drawFooterWithTerminal(
    window: tui.vaxis.Window,
    row: usize,
    footer_text: []const u8,
    terminal_name: []const u8,
    theme: ?*const resources_mod.Theme,
    allocator: std.mem.Allocator,
) !void {
    if (row >= window.height) return;
    const footer_style = styleForToken(theme, .footer);
    const badge_style = styleForToken(theme, .terminal_badge);
    const line_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    line_window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = footer_style,
    });

    const available_width = @as(usize, line_window.width);
    const badge = if (layoutMode(available_width) == .mini or layoutMode(available_width) == .compact)
        try allocator.dupe(u8, "")
    else
        try formatTerminalBadge(allocator, terminal_name);
    const badge_width = tui.ansi.visibleWidth(badge);
    const footer_width = if (available_width > badge_width + 1) available_width - badge_width - 1 else available_width;
    const compact_footer_text = std.mem.trimEnd(u8, footer_text, " ");
    const fitted_footer = try fitLine(allocator, compact_footer_text, footer_width);

    _ = line_window.printSegment(.{
        .text = fitted_footer,
        .style = footer_style,
    }, .{ .wrap = .none });

    if (badge_width > 0 and available_width > badge_width + 1) {
        _ = line_window.printSegment(.{
            .text = badge,
            .style = badge_style,
        }, .{
            .wrap = .none,
            .col_offset = @intCast(available_width - badge_width),
        });
    }
}

fn showExecutionPanel(snapshot: *const RenderStateSnapshot) bool {
    return snapshot.active_operation != null or snapshot.recent_activity != null;
}

fn measureExecutionPanelHeight(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    now_ms: i64,
) !usize {
    if (!showExecutionPanel(snapshot)) return 0;
    const text = (try formatExecutionPanelText(allocator, keybindings, snapshot, width, now_ms)) orelse return 0;
    defer allocator.free(text);
    return if (text.len > 0) 1 else 0;
}

fn formatExecutionPanelText(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    now_ms: i64,
) !?[]u8 {
    const active_status = if (snapshot.active_operation != null)
        try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse return null
    else
        try allocator.dupe(u8, snapshot.recent_activity orelse return null);
    defer allocator.free(active_status);

    const badge_text = if (snapshot.active_operation) |operation| executionPanelBadgeText(operation.kind) else "DONE";
    const label_text = if (layoutMode(width) == .compact) "Run" else if (snapshot.active_operation != null) "Execution" else "Activity";
    const badge_width = tui.ansi.visibleWidth(badge_text);
    const label_width = tui.ansi.visibleWidth(label_text);
    const available_width = if (layoutMode(width) == .compact)
        width -| label_width -| 1
    else
        width -| label_width -| badge_width -| 3;
    return try fitLine(allocator, active_status, @max(@as(usize, 1), available_width));
}

fn drawExecutionPanel(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    now_ms: i64,
) !usize {
    if (window.height == 0 or window.width == 0) return 0;
    const text = (try formatExecutionPanelText(allocator, keybindings, snapshot, window.width, now_ms)) orelse return 0;
    const active_kind = if (snapshot.active_operation) |operation| operation.kind else null;
    const fill_style = if (active_kind) |kind| executionPanelFillStyle(theme, kind) else styleForToken(theme, .role_tool_result);
    const label_style = if (active_kind) |kind| executionPanelLabelStyle(theme, kind) else recentActivityLabelStyle(theme);
    const badge_style = if (active_kind) |kind| executionPanelBadgeStyle(theme, kind) else recentActivityBadgeStyle(theme);
    const label_text = if (layoutMode(window.width) == .compact) "Run" else if (active_kind != null) "Execution" else "Activity";
    const badge_text = if (active_kind) |kind| executionPanelBadgeText(kind) else "DONE";

    const bar = tui.StatusBar{
        .left = &.{
            .{ .text = label_text, .style = label_style },
            .{ .text = text, .style = fill_style },
        },
        .right = if (layoutMode(window.width) == .compact) &.{} else &.{
            .{ .text = badge_text, .style = badge_style },
        },
        .fill_style = fill_style,
        .separator = " ",
    };
    _ = try bar.draw(window.child(.{ .height = 1 }), .{
        .window = window,
        .arena = allocator,
    });
    return 1;
}

fn executionPanelFillStyle(
    theme: ?*const resources_mod.Theme,
    kind: ActiveOperationKind,
) tui.vaxis.Cell.Style {
    return switch (kind) {
        .retry, .agent_wait, .bash_execution, .tool_execution => styleForToken(theme, .role_tool_call),
        .compaction => styleForToken(theme, .role_tool_result),
    };
}

fn executionPanelLabelStyle(
    theme: ?*const resources_mod.Theme,
    kind: ActiveOperationKind,
) tui.vaxis.Cell.Style {
    var style = executionPanelFillStyle(theme, kind);
    const accent = styleForToken(theme, .task_header_accent);
    if (accent.fg != .default) style.fg = accent.fg;
    style.bold = true;
    return style;
}

fn executionPanelBadgeStyle(
    theme: ?*const resources_mod.Theme,
    kind: ActiveOperationKind,
) tui.vaxis.Cell.Style {
    var style = executionPanelFillStyle(theme, kind);
    style.bold = true;
    return style;
}

fn recentActivityLabelStyle(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    var style = styleForToken(theme, .role_tool_result);
    const accent = styleForToken(theme, .task_header_accent);
    if (accent.fg != .default) style.fg = accent.fg;
    style.bold = true;
    return style;
}

fn recentActivityBadgeStyle(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    var style = styleForToken(theme, .role_tool_result);
    style.bold = true;
    return style;
}

fn executionPanelBadgeText(kind: ActiveOperationKind) []const u8 {
    return switch (kind) {
        .retry => "RETRY",
        .compaction => "COMPACT",
        .bash_execution => "BASH",
        .tool_execution => "TOOL",
        .agent_wait => "RUN",
    };
}

fn showContextGauge(snapshot: *const RenderStateSnapshot, width: usize) bool {
    return width >= 120 and snapshot.context_window > 0 and snapshot.context_percent != null;
}

fn measureContextGaugeHeight(snapshot: *const RenderStateSnapshot, width: usize) usize {
    return if (showContextGauge(snapshot, width)) 1 else 0;
}

fn drawContextGauge(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
) !usize {
    if (!showContextGauge(snapshot, window.width) or window.height == 0 or window.width == 0) return 0;

    const percent = std.math.clamp(snapshot.context_percent.?, 0.0, 100.0);
    const ratio = percent / 100.0;
    const used_tokens = @as(u64, @intFromFloat(@round(@as(f64, @floatFromInt(snapshot.context_window)) * ratio)));
    const used_text = try formatCompactTokenCount(allocator, used_tokens);
    const total_text = try formatCompactTokenCount(allocator, snapshot.context_window);
    const label = try std.fmt.allocPrint(
        allocator,
        "Ctx {d:.1}% {s}/{s} ",
        .{ percent, used_text, total_text },
    );

    var filled_style = styleForToken(theme, contextGaugeToken(percent));
    filled_style.bold = true;
    var unfilled_style = styleForToken(theme, .status);
    unfilled_style.dim = true;

    const gauge = tui.LineGauge{
        .ratio = ratio,
        .label = label,
        .filled_style = filled_style,
        .unfilled_style = unfilled_style,
    };
    const size = try gauge.draw(window, .{
        .window = window,
        .arena = allocator,
    });
    return @as(usize, size.height);
}

fn contextGaugeToken(percent: f64) resources_mod.ThemeToken {
    if (percent >= 85.0) return .@"error";
    if (percent >= 60.0) return .task_header_accent;
    return .welcome;
}

fn drawTaskPanel(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    now_ms: i64,
) !tui.DrawSize {
    const outer_width = @as(usize, window.width);
    const requested_height = taskPanelHeightForWidth(outer_width);

    const panel_height = @min(requested_height, @as(usize, window.height));
    if (panel_height == 0) return .{ .width = window.width, .height = 0 };
    const border_style = styleForToken(theme, .task_header_separator);
    const content_style = styleForToken(theme, .task_header);
    const bordered = panel_height >= TOP_PANEL_HEIGHT and window.width >= 2 and window.height >= 2;
    const panel_inner = if (bordered)
        window.child(.{
            .height = @intCast(panel_height),
            .border = .{
                .where = .all,
                .style = border_style,
                .glyphs = .single_rounded,
            },
        })
    else
        window.child(.{ .height = @intCast(panel_height) });

    panel_inner.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = content_style,
    });

    if (panel_inner.width > 0 and panel_inner.height > 0) {
        const content_width = @as(usize, panel_inner.width);
        const content = if (showExecutionPanel(snapshot))
            try formatTaskHeaderTextForMode(
                ctx.arena,
                snapshot,
                content_width,
                layoutMode(outer_width),
            )
        else
            try formatTaskHeaderTextForDisplay(
                ctx.arena,
                keybindings,
                snapshot,
                content_width,
                layoutMode(outer_width),
                now_ms,
            );
        _ = panel_inner.printSegment(.{
            .text = content,
            .style = content_style,
        }, .{ .wrap = .none });
    }

    return .{
        .width = window.width,
        .height = @intCast(panel_height),
    };
}

fn drawWrappedText(
    window: tui.vaxis.Window,
    start_row: usize,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) usize {
    if (start_row >= window.height) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = window.height - @as(u16, @intCast(start_row)),
    });
    const result = child.printSegment(.{
        .text = text,
        .style = style,
    }, .{ .wrap = .grapheme });
    return renderedPrintHeight(result, text.len > 0, child.height);
}

fn renderedPrintHeight(result: tui.vaxis.Window.PrintResult, had_text: bool, max_height: u16) usize {
    if (!had_text) return 0;
    const height = @as(usize, result.row) + if (result.col > 0 or result.overflow) @as(usize, 1) else 0;
    return @min(@max(height, 1), @as(usize, max_height));
}

fn estimateWrappedRows(text: []const u8, width: usize) usize {
    const effective_width = @max(width, 1);
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| {
        const line_width = tui.ansi.visibleWidth(line);
        rows += @max(@as(usize, 1), (line_width + effective_width - 1) / effective_width);
    }
    return rows;
}

fn measurePromptHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
    policy: tui.terminal_image.ImageRenderPolicy,
    width: usize,
) !usize {
    return prompt_rendering.measureHeight(allocator, theme, editor, pending_images, policy, width);
}

fn drawPromptLines(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
    policy: tui.terminal_image.ImageRenderPolicy,
) !tui.DrawSize {
    return prompt_rendering.drawLines(window, ctx, theme, editor, pending_images, policy);
}

fn measureAutocompleteHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    width: usize,
) !usize {
    _ = theme;
    if (!editor.isShowingAutocomplete()) return 0;
    const height_hint = @max(@as(usize, 1), editor.autocomplete_max_visible);
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(height_hint),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const measure_window = tui.draw.rootWindow(&screen);
    measure_window.clear();
    const size = try editor.drawAutocomplete(measure_window, .{
        .window = measure_window,
        .arena = allocator,
    });
    return @as(usize, size.height);
}

fn measureQueuedMessagesHeight(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) !usize {
    if (snapshot.queued_steering.len == 0 and snapshot.queued_follow_up.len == 0) return 0;
    const height_hint = @max(@as(usize, 4), queuedEstimateRows(snapshot, width));
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(height_hint, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const measure_window = tui.draw.rootWindow(&screen);
    measure_window.clear();
    const size = try drawQueuedMessages(measure_window, .{
        .window = measure_window,
        .arena = allocator,
    }, keybindings, theme, snapshot);
    return @as(usize, size.height);
}

fn queuedEstimateRows(snapshot: *const RenderStateSnapshot, width: usize) usize {
    var rows: usize = 2;
    for (snapshot.queued_steering) |queued| rows += estimateWrappedRows(queued, width) + 1;
    for (snapshot.queued_follow_up) |queued| rows += estimateWrappedRows(queued, width) + 1;
    return rows;
}

fn drawQueuedMessages(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
) !tui.DrawSize {
    if (snapshot.queued_steering.len == 0 and snapshot.queued_follow_up.len == 0) {
        return .{ .width = window.width, .height = 0 };
    }

    const status_style = styleForToken(theme, .status);
    var row: usize = 1;
    for (snapshot.queued_steering) |queued| {
        const line = try std.fmt.allocPrint(ctx.arena, "Steering: {s}", .{queued});
        row += drawWrappedText(window, row, line, status_style);
    }
    for (snapshot.queued_follow_up) |queued| {
        const line = try std.fmt.allocPrint(ctx.arena, "Follow-up: {s}", .{queued});
        row += drawWrappedText(window, row, line, status_style);
    }
    const dequeue_label = try actionLabel(ctx.arena, keybindings, .message_dequeue, "Alt+Up");
    const hint = try std.fmt.allocPrint(ctx.arena, "↳ {s} to edit queued messages", .{dequeue_label});
    row += drawWrappedText(window, row, hint, status_style);
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

const ChatViewportMetrics = chat_rendering.ViewportMetrics;

pub fn drawChatViewport(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    window: tui.vaxis.Window,
    start_row: usize,
    height: usize,
    chat_scroll_offset: usize,
    now_ms: i64,
    all_expanded: bool,
    selection: ?chat_rendering.SelectionRange,
    selected_text_out: ?*std.ArrayList(u8),
) !ChatViewportMetrics {
    return chat_rendering.drawViewport(allocator, keybindings, theme, items, window, start_row, height, chat_scroll_offset, now_ms, all_expanded, selection, selected_text_out);
}

pub fn drawChatItems(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    now_ms: i64,
    all_expanded: bool,
) !tui.DrawSize {
    return chat_rendering.drawItems(window, allocator, keybindings, theme, items, now_ms, all_expanded);
}

pub fn drawChatItem(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    start_row: usize,
    now_ms: i64,
    all_expanded: bool,
) !usize {
    return chat_rendering.drawItem(window, allocator, keybindings, theme, item, start_row, now_ms, all_expanded);
}

pub fn previewThreshold(kind: ChatKind) ?usize {
    return chat_rendering.previewThreshold(kind);
}

fn thinkingFrameIndex(item: ChatItem, now_ms: i64) usize {
    return chat_rendering.thinkingFrameIndex(item, now_ms);
}

pub fn chatToken(kind: ChatKind) resources_mod.ThemeToken {
    return chat_rendering.token(kind);
}

pub fn estimateChatRows(items: []const ChatItem, width: usize, all_expanded: bool) usize {
    return chat_rendering.estimateRows(items, width, all_expanded);
}

pub fn estimateChatItemRowsVisible(item: ChatItem, width: usize, all_expanded: bool) usize {
    return chat_rendering.estimateItemRowsVisible(item, width, all_expanded);
}

const RenderHook = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) void,

    pub fn run(self: RenderHook) void {
        self.callback(self.context);
    }
};

const BorrowedLineListComponent = struct {
    lines: []const []u8,

    pub fn component(self: *const BorrowedLineListComponent) tui.draw.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.draw.DrawContext,
    ) std.mem.Allocator.Error!tui.draw.Size {
        const self: *const BorrowedLineListComponent = @ptrCast(@alignCast(ptr));
        const row_count = @min(self.lines.len, @as(usize, window.height));
        for (self.lines[0..row_count], 0..) |line, row_index| {
            const fitted = try fitLine(ctx.arena, line, window.width);
            defer ctx.arena.free(fitted);
            const row_window = window.child(.{
                .y_off = @intCast(row_index),
                .height = 1,
            });
            _ = row_window.printSegment(.{ .text = fitted }, .{ .wrap = .none });
        }
        return .{ .width = window.width, .height = @intCast(row_count) };
    }
};

pub const BorrowedCellRow = struct {
    cells: []const tui.vaxis.Cell,
};

pub const BorrowedLinesComponent = struct {
    rows: []const BorrowedCellRow,

    pub fn drawComponent(self: *const BorrowedLinesComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const BorrowedLinesComponent,
        window: tui.vaxis.Window,
        _: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        window.clear();
        const row_count = @min(self.rows.len, @as(usize, window.height));
        for (self.rows[0..row_count], 0..) |row, row_index| {
            const col_count = @min(row.cells.len, @as(usize, window.width));
            for (row.cells[0..col_count], 0..) |cell, col| {
                window.writeCell(@intCast(col), @intCast(row_index), cell);
            }
        }
        return .{
            .width = window.width,
            .height = @intCast(row_count),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const BorrowedLinesComponent = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

pub const OverlayPanelComponent = struct {
    overlay: *SelectorOverlay,
    theme: ?*const resources_mod.Theme = null,
    max_height: usize = 12,

    pub fn drawComponent(self: *const OverlayPanelComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    fn drawOverlayTable(
        overlay: anytype,
        list_window: tui.vaxis.Window,
        ctx: tui.DrawContext,
        theme: ?*const resources_mod.Theme,
        highlight_style: tui.vaxis.Cell.Style,
    ) std.mem.Allocator.Error!tui.DrawSize {
        _ = theme;
        overlay.table_state.selected_index = overlay.list.selectedIndex();
        var table = tui.Table{
            .rows = overlay.table_rows,
            .widths = overlay.table_widths,
            .row_highlight_style = highlight_style,
            .show_scrollbar = true,
        };
        return try table.draw(list_window, .{
            .window = list_window,
            .arena = ctx.arena,
        }, &overlay.table_state);
    }

    pub fn draw(
        self: *const OverlayPanelComponent,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        window.clear();
        const border_style = styleForToken(self.theme, .box_border);
        const bordered = if (window.width >= 2 and window.height >= 2)
            window.child(.{
                .border = .{
                    .where = .all,
                    .style = border_style,
                    .glyphs = .single_square,
                },
            })
        else
            window;
        bordered.clear();

        const content_window = bordered.child(.{
            .x_off = @intCast(@min(@as(usize, 2), @as(usize, bordered.width))),
            .y_off = @intCast(@min(@as(usize, 1), @as(usize, bordered.height))),
            .width = @intCast(@max(@as(usize, 1), @as(usize, bordered.width) -| 4)),
            .height = @intCast(@max(@as(usize, 1), @as(usize, bordered.height) -| 2)),
        });

        var row: usize = 0;
        drawFittedLine(content_window, row, self.overlay.title(), styleForToken(self.theme, .overlay_title));
        row += 2;
        drawFittedLine(content_window, row, self.overlay.hint(), styleForToken(self.theme, .overlay_hint));
        row += 2;

        switch (self.overlay.*) {
            .settings_editor => |*settings_editor| {
                settings_editor.editor.setEditorStyle(if (self.theme) |t| tui.styleFor(t, .editor) else .{});
                drawFittedLine(content_window, row, settings_editor.path, styleForToken(self.theme, .overlay_hint));
                row += 2;
                if (row < content_window.height) {
                    const editor_window = content_window.child(.{
                        .y_off = @intCast(row),
                        .height = content_window.height - @as(u16, @intCast(row)),
                    });
                    const size = try settings_editor.editor.draw(editor_window, .{
                        .window = editor_window,
                        .arena = ctx.arena,
                    });
                    row += @as(usize, size.height);
                }
            },
            .extension_dialog => |*dialog| {
                if (dialog.message.len > 0) {
                    drawFittedLine(content_window, row, dialog.message, styleForToken(self.theme, .text));
                    row += 2;
                }
                if (row < content_window.height) {
                    switch (dialog.kind) {
                        .select, .confirm => {
                            dialog.list.max_visible = @max(@as(usize, 1), @min(self.max_height, @as(usize, content_window.height) - row));
                            dialog.list.show_scrollbar = true;
                            const list_window = content_window.child(.{
                                .y_off = @intCast(row),
                                .height = content_window.height - @as(u16, @intCast(row)),
                            });
                            const size = try dialog.list.draw(list_window, .{
                                .window = list_window,
                                .arena = ctx.arena,
                            });
                            row += @as(usize, size.height);
                        },
                        .input, .editor => {
                            dialog.editor.setEditorStyle(if (self.theme) |t| tui.styleFor(t, .editor) else .{});
                            const editor_window = content_window.child(.{
                                .y_off = @intCast(row),
                                .height = content_window.height - @as(u16, @intCast(row)),
                            });
                            const size = try dialog.editor.draw(editor_window, .{
                                .window = editor_window,
                                .arena = ctx.arena,
                            });
                            row += @as(usize, size.height);
                        },
                    }
                }
            },
            else => {
                if (row < content_window.height) {
                    const has_table = switch (self.overlay.*) {
                        .info => |*o| o.table_rows.len > 0,
                        .settings => |*o| o.table_rows.len > 0,
                        .session => |*o| o.table_rows.len > 0,
                        .model => |*o| o.table_rows.len > 0,
                        .scoped_models => |*o| o.table_rows.len > 0,
                        .theme => |*o| o.table_rows.len > 0,
                        .tree => |*o| o.table_rows.len > 0,
                        .fork => |*o| o.table_rows.len > 0,
                        .auth => |*o| o.table_rows.len > 0,
                        else => false,
                    };
                    const list_window = content_window.child(.{
                        .y_off = @intCast(row),
                        .height = content_window.height - @as(u16, @intCast(row)),
                    });
                    if (has_table) {
                        const highlight_style = styleForToken(self.theme, .select_selected);
                        switch (self.overlay.*) {
                            .info => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .settings => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .session => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .model => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .scoped_models => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .theme => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .tree => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .fork => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .auth => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            else => unreachable,
                        }
                    } else {
                        const overlay_list = switch (self.overlay.*) {
                            .info => |*info_overlay| &info_overlay.list,
                            .settings => |*settings_overlay| &settings_overlay.list,
                            .session => |*session_overlay| &session_overlay.list,
                            .model => |*model_overlay| &model_overlay.list,
                            .scoped_models => |*scoped_models_overlay| &scoped_models_overlay.list,
                            .theme => |*theme_overlay| &theme_overlay.list,
                            .tree => |*tree_overlay| &tree_overlay.list,
                            .fork => |*fork_overlay| &fork_overlay.list,
                            .auth => |*auth_overlay| &auth_overlay.list,
                            else => unreachable,
                        };

                        overlay_list.max_visible = @max(@as(usize, 1), @min(self.max_height, @as(usize, content_window.height) - row));
                        const size = try overlay_list.draw(list_window, .{
                            .window = list_window,
                            .arena = ctx.arena,
                        });
                        row += @as(usize, size.height);
                    }
                }
            },
        }

        const chrome_height: usize = if (window.width >= 2 and window.height >= 2) 2 else 0;
        const total_height = @min(@as(usize, window.height), row + 2 + chrome_height);
        return .{
            .width = window.width,
            .height = @intCast(@max(@as(usize, 1), total_height)),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const OverlayPanelComponent = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

pub const overlayPanelMaxHeight = overlay_panel.maxHeight;
pub const overlayPanelWidth = overlay_panel.width;
pub const overlayAnimationProgress = overlay_panel.animationProgress;
pub const nowMilliseconds = overlay_panel.nowMilliseconds;
pub const overlayPanelOptions = overlay_panel.options;
pub const resolveGitBranch = git_status.resolveGitBranch;
pub const findGitRoot = git_status.findGitRoot;
pub const resolveGitDirectory = git_status.resolveGitDirectory;
pub const parseGitHeadBranch = git_status.parseGitHeadBranch;

fn systemNowMilliseconds(_: ?*anyopaque) i64 {
    return nowMilliseconds();
}

pub fn rebuildAppStateFromSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_state: *AppState,
    session: *const session_mod.AgentSession,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
) !void {
    const git_branch = try git_status.resolveGitBranch(allocator, io, session.cwd);
    defer if (git_branch) |branch| allocator.free(branch);
    try app_state.rebuildFromSession(session, git_branch);
    if (current_provider) |resolved_provider| {
        try app_state.setFooterDetails(
            session.agent.getModel(),
            currentSessionLabel(session),
            git_branch,
            provider_config.providerDisplayName(resolved_provider.model.provider),
            provider_config.providerAuthStatusLabel(resolved_provider.auth_status),
        );
    }
}

pub fn updateAppFooterFromSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_state: *AppState,
    session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
) !void {
    const git_branch = try git_status.resolveGitBranch(allocator, io, session.cwd);
    defer if (git_branch) |branch| allocator.free(branch);
    try app_state.setFooterDetails(
        session.agent.getModel(),
        currentSessionLabel(session),
        git_branch,
        provider_config.providerDisplayName(current_provider.model.provider),
        provider_config.providerAuthStatusLabel(current_provider.auth_status),
    );
}

pub fn assistantContextTokens(usage: ai.Usage) ?u32 {
    return usage.input +| usage.cache_read +| usage.cache_write;
}

pub fn parseEnvSize(value: ?[]const u8) ?usize {
    const text = value orelse return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

pub const freeLinesSlice = @import("../slice_utils.zig").freeStringSlice;

pub const INPUT_PROMPT_PREFIX = render_text.INPUT_PROMPT_PREFIX;
const TOP_PANEL_HEIGHT = render_text.TOP_PANEL_HEIGHT;
const PROMPT_BORDER_TOP_ROWS = render_text.PROMPT_BORDER_TOP_ROWS;
const LayoutMode = render_text.LayoutMode;
const layoutMode = render_text.layoutMode;
const taskPanelHeightForWidth = render_text.taskPanelHeightForWidth;
const hintsHeightForWidth = render_text.hintsHeightForWidth;
const promptEditorWidth = render_text.promptEditorWidth;
const promptEditorOffsetX = render_text.promptEditorOffsetX;
const promptEditorOffsetY = render_text.promptEditorOffsetY;
pub fn formatFooterLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    return render_text.formatFooterLine(allocator, theme, snapshot, width);
}

pub fn formatFooterLineWithTerminal(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    return render_text.formatFooterLineWithTerminal(allocator, theme, snapshot, terminal_name, width);
}

fn formatFooterLineWithTerminalForDisplay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
    now_ms: i64,
) ![]u8 {
    const active_status = try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse
        return render_text.formatFooterLineWithTerminal(allocator, theme, snapshot, terminal_name, width);
    defer allocator.free(active_status);

    var display_snapshot = snapshot.*;
    display_snapshot.status = active_status;
    return render_text.formatFooterLineWithTerminal(allocator, theme, &display_snapshot, terminal_name, width);
}

fn formatFooterTextForDisplay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    now_ms: i64,
) ![]u8 {
    const active_status = try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse
        return render_text.formatFooterText(allocator, snapshot, width);
    defer allocator.free(active_status);

    var display_snapshot = snapshot.*;
    display_snapshot.status = active_status;
    return render_text.formatFooterText(allocator, &display_snapshot, width);
}

pub fn formatExtensionFooterLineWithTerminal(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);
    if (snapshot.extension_footer_lines.len > 0) {
        try builder.appendSlice(allocator, snapshot.extension_footer_lines[0]);
    }
    for (snapshot.extension_footer_statuses) |status| {
        if (status.len == 0) continue;
        if (builder.items.len > 0) try builder.appendSlice(allocator, " • ");
        try builder.appendSlice(allocator, status);
    }
    if (builder.items.len == 0) {
        return render_text.formatFooterLineWithTerminal(allocator, theme, snapshot, terminal_name, width);
    }
    const fitted = try fitLine(allocator, builder.items, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn formatTaskHeaderText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    return render_text.formatTaskHeaderText(allocator, snapshot, width);
}

fn formatTaskHeaderTextForMode(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    mode: LayoutMode,
) ![]u8 {
    return render_text.formatTaskHeaderTextForMode(allocator, snapshot, width, mode);
}

fn formatTaskHeaderTextForDisplay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    mode: LayoutMode,
    now_ms: i64,
) ![]u8 {
    const active_status = try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse
        return render_text.formatTaskHeaderTextForMode(allocator, snapshot, width, mode);
    defer allocator.free(active_status);

    var display_snapshot = snapshot.*;
    display_snapshot.status = active_status;
    return render_text.formatTaskHeaderTextForMode(allocator, &display_snapshot, width, mode);
}

pub fn formatFooterText(allocator: std.mem.Allocator, snapshot: *const RenderStateSnapshot, width: usize) ![]u8 {
    return render_text.formatFooterText(allocator, snapshot, width);
}

pub fn formatFooterTextWithTerminal(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    return render_text.formatFooterTextWithTerminal(allocator, snapshot, terminal_name, width);
}

pub fn appendFooterPart(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    needs_separator: *bool,
    text: []const u8,
) std.mem.Allocator.Error!void {
    return render_text.appendFooterPart(allocator, builder, needs_separator, text);
}

pub fn formatCompactTokenCount(allocator: std.mem.Allocator, count: u64) ![]u8 {
    return render_text.formatCompactTokenCount(allocator, count);
}

pub fn formatHintsLine(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    width: usize,
) ![]u8 {
    return render_text.formatHintsLine(allocator, keybindings, theme, width);
}

pub fn formatHintsText(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    width: usize,
) ![]u8 {
    return render_text.formatHintsText(allocator, keybindings, width);
}

pub fn actionLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    fallback: []const u8,
) ![]u8 {
    return render_text.actionLabel(allocator, keybindings, action, fallback);
}

pub fn applyThemeAlloc(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    text: []const u8,
) ![]u8 {
    return render_text.applyThemeAlloc(allocator, theme, token, text);
}

pub fn fitLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    return render_text.fitLine(allocator, text, width);
}

fn formatTerminalBadge(allocator: std.mem.Allocator, terminal_name: []const u8) ![]u8 {
    return render_text.formatTerminalBadge(allocator, terminal_name);
}
pub fn themeChatItem(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
) ![]u8 {
    return try applyThemeAlloc(allocator, theme, switch (item.kind) {
        .welcome => .welcome,
        .info => .status,
        .@"error" => .@"error",
        .markdown => .markdown_text,
        .user => .role_user,
        .assistant => .role_assistant,
        .thinking => .role_thinking,
        .tool_call => .role_tool_call,
        .tool_result => .role_tool_result,
        .bash_execution => .role_tool_result,
    }, item.text);
}

pub fn renderChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
) ![]const []const u8 {
    return renderChatItemIntoAt(allocator, width, theme, item, 0);
}

pub fn renderChatItemIntoAt(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
) ![]const []const u8 {
    return renderChatItemIntoWithOptions(allocator, width, null, theme, item, now_ms, true);
}

pub fn visibleChatTextAlloc(
    allocator: std.mem.Allocator,
    app_state: *AppState,
) ![]u8 {
    var snapshot = try app_state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const width = @max(snapshot.chat_width, 1);
    var all_lines = std.ArrayList([]const u8).empty;
    defer {
        for (all_lines.items) |line| allocator.free(line);
        all_lines.deinit(allocator);
    }
    for (snapshot.items) |item| {
        const lines = try renderChatItemIntoWithOptions(
            allocator,
            width,
            null,
            null,
            item,
            0,
            snapshot.all_expanded,
        );
        errdefer {
            for (lines) |line| allocator.free(line);
            allocator.free(lines);
        }
        try all_lines.appendSlice(allocator, lines);
        allocator.free(lines);
    }

    const visible_rows = if (snapshot.chat_visible_rows == 0) all_lines.items.len else snapshot.chat_visible_rows;
    const max_offset = all_lines.items.len -| visible_rows;
    const offset = @min(snapshot.chat_scroll_offset, max_offset);
    const start = max_offset -| offset;
    const end = @min(start + visible_rows, all_lines.items.len);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (all_lines.items[start..end], 0..) |line, index| {
        if (index > 0) try writer.writer.writeAll("\n");
        try writer.writer.writeAll(std.mem.trim(u8, line, " "));
    }
    return try allocator.dupe(u8, std.mem.trim(u8, writer.written(), "\n"));
}

fn renderChatItemIntoWithOptions(
    allocator: std.mem.Allocator,
    width: usize,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
    all_expanded: bool,
) ![]const []const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_allocator = arena.allocator();

    const height_hint = @max(@as(usize, 1), estimateChatRows(&.{item}, width, all_expanded));
    var screen = try tui.vaxis.Screen.init(scratch_allocator, .{
        .rows = @intCast(@min(height_hint, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(scratch_allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, scratch_allocator, keybindings, theme, item, 0, now_ms, all_expanded);
    return tui.cell_rows.screenRowsToLinesAlloc(allocator, &screen, width, rendered);
}

pub fn renderAssistantChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
) ![]const []const u8 {
    return renderChatItemInto(allocator, width, theme, .{ .kind = .assistant, .text = @constCast(text) });
}

pub fn renderMarkdownChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
) ![]const []const u8 {
    return renderChatItemInto(allocator, width, theme, .{ .kind = .markdown, .text = @constCast(text) });
}

pub fn handleAppAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleAgentEvent(event);
}

pub fn handleAppRetryLifecycleEvent(context: ?*anyopaque, event: session_mod.RetryLifecycleEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleRetryLifecycleEvent(event);
}

pub fn handleAppCompactionLifecycleEvent(context: ?*anyopaque, event: session_mod.CompactionLifecycleEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleCompactionLifecycleEvent(event);
}

fn removeQueuedTextFromList(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]u8),
    text: []const u8,
) bool {
    for (items.items, 0..) |queued_text, index| {
        if (std.mem.eql(u8, queued_text, text)) {
            allocator.free(queued_text);
            _ = items.orderedRemove(index);
            return true;
        }
    }
    return false;
}

fn userMessageText(message: ai.types.UserMessage) []const u8 {
    for (message.content) |block| {
        switch (block) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return "";
}

fn cloneOwnedStringList(allocator: std.mem.Allocator, items: []const []u8) ![][]u8 {
    if (items.len == 0) return &.{};

    const cloned = try allocator.alloc([]u8, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }

    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return cloned;
}

fn cloneConstStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    if (items.len == 0) return &.{};

    const cloned = try allocator.alloc([]u8, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }

    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return cloned;
}

const deinitOwnedStringList = @import("../slice_utils.zig").freeStringSlice;

const rendering_tests = @import("rendering/tests.zig");
pub const InteractiveModeTestBackend = rendering_tests.InteractiveModeTestBackend;
pub const renderScreenWithMockBackend = rendering_tests.renderScreenWithMockBackend;
pub const renderScreenWithMockBackendAndOverlay = rendering_tests.renderScreenWithMockBackendAndOverlay;
pub const renderedLinesContain = rendering_tests.renderedLinesContain;

test {
    _ = rendering_tests;
}
