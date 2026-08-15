const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const tui = @import("tui");
const overlay_table = @import("overlay_table.zig");

pub const SettingId = enum {
    none,
    autocompact,
    show_images,
    image_width_cells,
    auto_resize_images,
    block_images,
    skill_commands,
    show_hardware_cursor,
    editor_padding,
    autocomplete_max_visible,
    clear_on_shrink,
    terminal_progress,
    steering_mode,
    follow_up_mode,
    transport,
    hide_thinking,
    collapse_changelog,
    quiet_startup,
    install_telemetry,
    double_escape_action,
    tree_filter_mode,
    warnings,
    thinking,
    theme,
    raw_json,
};

pub const Mode = enum {
    main,
    thinking,
    theme,
    warnings,
};

pub const Choice = struct {
    id: SettingId,
    value: []u8,
};

pub const Overlay = struct {
    hint: []u8,
    choices: []Choice,
    items: []tui.SelectItem,
    list: tui.SelectList,
    search: []u8 = &.{},
    mode: Mode = .main,
    supports_images: bool = false,
    original_theme: []u8 = &.{},
    available_themes: [][]u8 = &.{},
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    session: *const session_mod.AgentSession,

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 24 }, .{ .fill = 1 } },

    pub fn deinit(self: *Overlay, allocator: std.mem.Allocator) void {
        allocator.free(self.hint);
        freeChoices(allocator, self.choices);
        freeOwnedSelectItems(allocator, self.items);
        if (self.search.len > 0) allocator.free(self.search);
        if (self.original_theme.len > 0) allocator.free(self.original_theme);
        for (self.available_themes) |theme| allocator.free(theme);
        allocator.free(self.available_themes);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    runtime_config: ?*const config_mod.RuntimeConfig,
    session: *const session_mod.AgentSession,
    themes: []const resources_mod.Theme,
    active_theme: ?*const resources_mod.Theme,
    supports_images: bool,
) !Overlay {
    var available_themes = try allocator.alloc([]u8, themes.len);
    errdefer {
        for (available_themes) |theme| allocator.free(theme);
        allocator.free(available_themes);
    }
    for (themes, 0..) |theme, index| {
        available_themes[index] = try allocator.dupe(u8, theme.name);
    }

    const active_name = if (active_theme) |theme| theme.name else if (runtime_config) |config| config.settings.theme orelse "dark" else "dark";
    var overlay = Overlay{
        .hint = try allocator.dupe(u8, ""),
        .choices = try allocator.alloc(Choice, 0),
        .items = try allocator.alloc(tui.SelectItem, 0),
        .list = .{ .items = &.{}, .max_visible = 12 },
        .supports_images = supports_images,
        .original_theme = try allocator.dupe(u8, active_name),
        .available_themes = available_themes,
        .runtime_config = runtime_config,
        .session = session,
    };
    errdefer overlay.deinit(allocator);
    try refresh(allocator, &overlay);
    return overlay;
}

pub fn refresh(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    freeChoices(allocator, overlay.choices);
    freeOwnedSelectItems(allocator, overlay.items);
    allocator.free(overlay.hint);

    var choices = std.ArrayList(Choice).empty;
    errdefer {
        for (choices.items) |*choice| allocator.free(choice.value);
        choices.deinit(allocator);
    }
    var items = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.value);
            allocator.free(item.label);
            if (item.description) |description| allocator.free(description);
        }
        items.deinit(allocator);
    }

    switch (overlay.mode) {
        .main => try appendMainRows(allocator, overlay, &choices, &items),
        .thinking => try appendThinkingRows(allocator, overlay, &choices, &items),
        .theme => try appendThemeRows(allocator, overlay, &choices, &items),
        .warnings => try appendWarningsRows(allocator, overlay, &choices, &items),
    }

    if (choices.items.len == 0) {
        try appendRawChoice(
            allocator,
            &choices,
            &items,
            .none,
            "none",
            "No matching settings",
            "No settings match the current search",
        );
    }

    overlay.choices = try choices.toOwnedSlice(allocator);
    overlay.items = try items.toOwnedSlice(allocator);
    overlay.list.items = overlay.items;
    overlay.list.selected_index = @min(overlay.list.selected_index, overlay.items.len - 1);
    overlay.list.max_visible = 12;
    overlay.hint = try formatHint(allocator, overlay);

    overlay_table.freeTable(allocator, overlay.table_cells, overlay.table_rows);
    const built = try overlay_table.buildLabelDescriptionTable(allocator, overlay.items);
    overlay.table_cells = built.cells;
    overlay.table_rows = built.rows;
}

pub fn updateSearch(allocator: std.mem.Allocator, overlay: *Overlay, next_search: []const u8) !void {
    if (overlay.mode != .main) return;
    const owned = try allocator.dupe(u8, next_search);
    if (overlay.search.len > 0) allocator.free(overlay.search);
    overlay.search = owned;
    overlay.list.selected_index = 0;
    try refresh(allocator, overlay);
}

pub fn enterMode(allocator: std.mem.Allocator, overlay: *Overlay, mode: Mode) !void {
    overlay.mode = mode;
    overlay.list.selected_index = 0;
    try refresh(allocator, overlay);
}

pub fn exitSubmenu(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    overlay.mode = .main;
    overlay.list.selected_index = 0;
    try refresh(allocator, overlay);
}

pub fn selectedChoice(overlay: *const Overlay) ?Choice {
    if (overlay.choices.len == 0) return null;
    return overlay.choices[overlay.list.selectedIndex()];
}

pub fn selectedId(overlay: *const Overlay) SettingId {
    return if (selectedChoice(overlay)) |choice| choice.id else .none;
}

fn appendMainRows(
    allocator: std.mem.Allocator,
    overlay: *const Overlay,
    choices: *std.ArrayList(Choice),
    items: *std.ArrayList(tui.SelectItem),
) !void {
    const runtime = overlay.runtime_config;
    try appendSettingRow(allocator, overlay, choices, items, .autocompact, "Auto-compact", "Automatically compact context when it gets too large", boolValue(if (runtime) |config| (config.settings.compaction orelse session_mod.CompactionSettings{}).enabled else overlay.session.compaction_settings.enabled));
    if (overlay.supports_images) {
        try appendSettingRow(allocator, overlay, choices, items, .show_images, "Show images", "Render images inline in terminal", boolValue(if (runtime) |config| config.showImages() else true));
        const image_width = try valueAlloc(allocator, "{d}", .{if (runtime) |config| config.imageWidthCells() else 60});
        defer allocator.free(image_width);
        try appendSettingRow(allocator, overlay, choices, items, .image_width_cells, "Image width", "Preferred inline image width in terminal cells", image_width);
    }
    try appendSettingRow(allocator, overlay, choices, items, .auto_resize_images, "Auto-resize images", "Resize large images to 2000x2000 max for better model compatibility", boolValue(if (runtime) |config| config.imageAutoResize() else true));
    try appendSettingRow(allocator, overlay, choices, items, .block_images, "Block images", "Prevent images from being sent to LLM providers", boolValue(if (runtime) |config| config.blockImages() else false));
    try appendSettingRow(allocator, overlay, choices, items, .skill_commands, "Skill commands", "Register skills as /skill:name commands", boolValue(if (runtime) |config| config.enableSkillCommands() else true));
    try appendSettingRow(allocator, overlay, choices, items, .show_hardware_cursor, "Show hardware cursor", "Show the terminal cursor while still positioning it for IME support", boolValue(if (runtime) |config| config.showHardwareCursor() else false));
    const editor_padding = try valueAlloc(allocator, "{d}", .{if (runtime) |config| config.settings.editor_padding_x orelse 0 else 0});
    defer allocator.free(editor_padding);
    try appendSettingRow(allocator, overlay, choices, items, .editor_padding, "Editor padding", "Horizontal padding for input editor (0-3)", editor_padding);
    const autocomplete_max = try valueAlloc(allocator, "{d}", .{if (runtime) |config| config.settings.autocomplete_max_visible orelse 5 else 5});
    defer allocator.free(autocomplete_max);
    try appendSettingRow(allocator, overlay, choices, items, .autocomplete_max_visible, "Autocomplete max items", "Max visible items in autocomplete dropdown (3-20)", autocomplete_max);
    try appendSettingRow(allocator, overlay, choices, items, .clear_on_shrink, "Clear on shrink", "Clear empty rows when content shrinks (may cause flicker)", boolValue(if (runtime) |config| config.clearOnShrink() else false));
    try appendSettingRow(allocator, overlay, choices, items, .terminal_progress, "Terminal progress", "Show OSC 9;4 progress indicators in the terminal tab bar", boolValue(if (runtime) |config| config.showTerminalProgress() else false));
    try appendSettingRow(allocator, overlay, choices, items, .steering_mode, "Steering mode", "Enter while streaming queues steering messages", queueModeName(overlay.session.agent.steering_queue.mode));
    try appendSettingRow(allocator, overlay, choices, items, .follow_up_mode, "Follow-up mode", "Alt+Enter queues follow-up messages until agent stops", queueModeName(overlay.session.agent.follow_up_queue.mode));
    try appendSettingRow(allocator, overlay, choices, items, .transport, "Transport", "Preferred transport for providers that support multiple transports", transportName(if (runtime) |config| config.transport() else .auto));
    try appendSettingRow(allocator, overlay, choices, items, .hide_thinking, "Hide thinking", "Hide thinking blocks in assistant responses", boolValue(if (runtime) |config| config.hideThinkingBlock() else false));
    try appendSettingRow(allocator, overlay, choices, items, .collapse_changelog, "Collapse changelog", "Show condensed changelog after updates", boolValue(if (runtime) |config| config.collapseChangelog() else false));
    try appendSettingRow(allocator, overlay, choices, items, .quiet_startup, "Quiet startup", "Disable verbose printing at startup", boolValue(if (runtime) |config| config.quietStartup() else false));
    try appendSettingRow(allocator, overlay, choices, items, .install_telemetry, "Install telemetry", "Send an anonymous version/update ping after changelog-detected updates", boolValue(if (runtime) |config| config.enableInstallTelemetry() else true));
    try appendSettingRow(allocator, overlay, choices, items, .double_escape_action, "Double-escape action", "Action when pressing Escape twice with empty editor", doubleEscapeName(if (runtime) |config| config.doubleEscapeAction() else .tree));
    try appendSettingRow(allocator, overlay, choices, items, .tree_filter_mode, "Tree filter mode", "Default filter when opening /tree", treeFilterName(if (runtime) |config| config.treeFilterMode() else .default));
    try appendSettingRow(allocator, overlay, choices, items, .warnings, "Warnings", "Enable or disable individual warnings", "configure");
    try appendSettingRow(allocator, overlay, choices, items, .thinking, "Thinking level", "Reasoning depth for thinking-capable models", thinkingName(overlay.session.agent.getThinkingLevel()));
    const current_theme = if (runtime) |config| config.settings.theme orelse overlay.original_theme else overlay.original_theme;
    try appendSettingRow(allocator, overlay, choices, items, .theme, "Theme", "Color theme for the interface", current_theme);
    try appendSettingRow(allocator, overlay, choices, items, .raw_json, "Advanced raw JSON", "Open the safe settings.json editor with validation and cancel-on-error", "open");
}

fn appendThinkingRows(
    allocator: std.mem.Allocator,
    overlay: *Overlay,
    choices: *std.ArrayList(Choice),
    items: *std.ArrayList(tui.SelectItem),
) !void {
    const current = overlay.session.agent.getThinkingLevel();
    inline for (.{ agent.ThinkingLevel.off, .minimal, .low, .medium, .high, .xhigh }) |level| {
        const name = thinkingName(level);
        const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ if (level == current) "✓" else " ", name });
        defer allocator.free(label);
        try appendRawChoice(allocator, choices, items, .thinking, name, label, thinkingDescription(level));
        if (level == current) overlay.list.selected_index = choices.items.len - 1;
    }
}

fn appendThemeRows(
    allocator: std.mem.Allocator,
    overlay: *Overlay,
    choices: *std.ArrayList(Choice),
    items: *std.ArrayList(tui.SelectItem),
) !void {
    const current = if (overlay.runtime_config) |config| config.settings.theme orelse overlay.original_theme else overlay.original_theme;
    if (overlay.available_themes.len == 0) {
        try appendRawChoice(allocator, choices, items, .theme, current, current, "current theme");
        return;
    }
    for (overlay.available_themes) |theme| {
        const active = std.mem.eql(u8, theme, current);
        const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ if (active) "✓" else " ", theme });
        defer allocator.free(label);
        try appendRawChoice(allocator, choices, items, .theme, theme, label, if (active) "active theme" else "available theme");
        if (active) overlay.list.selected_index = choices.items.len - 1;
    }
}

fn appendWarningsRows(
    allocator: std.mem.Allocator,
    overlay: *const Overlay,
    choices: *std.ArrayList(Choice),
    items: *std.ArrayList(tui.SelectItem),
) !void {
    const enabled = if (overlay.runtime_config) |config| config.warningAnthropicExtraUsage() else true;
    const label = try valueAlloc(allocator, "Anthropic extra usage  {s}", .{boolValue(enabled)});
    defer allocator.free(label);
    try appendRawChoice(
        allocator,
        choices,
        items,
        .warnings,
        boolValue(enabled),
        label,
        "Warn when Anthropic subscription auth may use paid extra usage",
    );
}

fn appendSettingRow(
    allocator: std.mem.Allocator,
    overlay: *const Overlay,
    choices: *std.ArrayList(Choice),
    items: *std.ArrayList(tui.SelectItem),
    id: SettingId,
    label: []const u8,
    description: []const u8,
    current_value: []const u8,
) !void {
    if (!matchesSearch(label, description, current_value, overlay.search)) return;
    const row_label = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ label, current_value });
    defer allocator.free(row_label);
    try appendRawChoice(allocator, choices, items, id, current_value, row_label, description);
}

fn appendRawChoice(
    allocator: std.mem.Allocator,
    choices: *std.ArrayList(Choice),
    items: *std.ArrayList(tui.SelectItem),
    id: SettingId,
    value: []const u8,
    label: []const u8,
    description: []const u8,
) !void {
    try choices.append(allocator, .{
        .id = id,
        .value = try allocator.dupe(u8, value),
    });
    try items.append(allocator, .{
        .value = try allocator.dupe(u8, @tagName(id)),
        .label = try allocator.dupe(u8, label),
        .description = try allocator.dupe(u8, description),
    });
}

fn matchesSearch(label: []const u8, description: []const u8, value: []const u8, search: []const u8) bool {
    if (search.len == 0) return true;
    return asciiContains(label, search) or asciiContains(description, search) or asciiContains(value, search);
}

fn asciiContains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn formatHint(allocator: std.mem.Allocator, overlay: *const Overlay) ![]u8 {
    return switch (overlay.mode) {
        .main => if (overlay.search.len > 0)
            std.fmt.allocPrint(allocator, "Search: {s} • Type to search • Enter/Space change/open • r raw JSON • Esc cancel", .{overlay.search})
        else
            allocator.dupe(u8, "Type to search • Enter/Space change/open • r raw JSON • Esc cancel"),
        .thinking => allocator.dupe(u8, "Up/Down move • Enter select • Esc back"),
        .theme => allocator.dupe(u8, "Up/Down preview • Enter select • Esc cancel preview"),
        .warnings => allocator.dupe(u8, "Enter/Space toggle • Esc back"),
    };
}

fn valueAlloc(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return try std.fmt.allocPrint(allocator, fmt, args);
}

fn boolValue(value: bool) []const u8 {
    return if (value) "true" else "false";
}

pub fn queueModeName(mode: agent.QueueMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

pub fn transportName(value: ai.types.Transport) []const u8 {
    return switch (value) {
        .sse => "sse",
        .websocket => "websocket",
        .websocket_cached => "websocket-cached",
        .auto => "auto",
    };
}

pub fn thinkingName(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn thinkingDescription(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "No reasoning",
        .minimal => "Very brief reasoning (~1k tokens)",
        .low => "Light reasoning (~2k tokens)",
        .medium => "Moderate reasoning (~8k tokens)",
        .high => "Deep reasoning (~16k tokens)",
        .xhigh => "Maximum reasoning (~32k tokens)",
    };
}

pub fn doubleEscapeName(action: config_mod.DoubleEscapeAction) []const u8 {
    return switch (action) {
        .fork => "fork",
        .tree => "tree",
        .none => "none",
    };
}

pub fn treeFilterName(mode: config_mod.TreeFilterMode) []const u8 {
    return switch (mode) {
        .default => "default",
        .no_tools => "no-tools",
        .user_only => "user-only",
        .labeled_only => "labeled-only",
        .all => "all",
    };
}

fn freeChoices(allocator: std.mem.Allocator, choices: []Choice) void {
    for (choices) |choice| allocator.free(choice.value);
    allocator.free(choices);
}

pub const freeOwnedSelectItems = overlay_table.freeOwnedSelectItems;

test "settings overlay lists structured searchable rows and capability dependent images" {
    const allocator = std.testing.allocator;
    const provider = ai.Model{
        .id = "fixture",
        .name = "Fixture",
        .api = "faux",
        .provider = "faux",
        .base_url = "https://example.invalid",
        .input_types = &.{"text"},
        .context_window = 1024,
        .max_tokens = 128,
    };
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .model = provider,
    });
    defer session.deinit();

    var overlay = try load(allocator, null, &session, &.{}, null, true);
    defer overlay.deinit(allocator);

    var saw_theme = false;
    var saw_images = false;
    var saw_raw = false;
    for (overlay.items) |item| {
        if (std.mem.indexOf(u8, item.label, "Theme") != null) saw_theme = true;
        if (std.mem.indexOf(u8, item.label, "Show images") != null) saw_images = true;
        if (std.mem.indexOf(u8, item.label, "Advanced raw JSON") != null) saw_raw = true;
    }
    try std.testing.expect(saw_theme);
    try std.testing.expect(saw_images);
    try std.testing.expect(saw_raw);

    try updateSearch(allocator, &overlay, "theme");
    try std.testing.expectEqual(@as(usize, 1), overlay.items.len);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[0].label, "Theme") != null);
}
