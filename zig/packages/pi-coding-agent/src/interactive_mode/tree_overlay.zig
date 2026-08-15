const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const session_mod = @import("../sessions/session.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const formatting = @import("formatting.zig");
const overlay_table = @import("overlay_table.zig");

const blocksToText = formatting.blocksToText;
const formatAssistantMessage = formatting.formatAssistantMessage;

pub const FilterMode = enum {
    default,
    no_tools,
    user_only,
    labeled_only,
    all,
};

pub const Choice = struct {
    entry_id: []u8,
};

const NodeKind = enum {
    user,
    assistant,
    tool_result,
    thinking_level_change,
    model_change,
    compaction,
    branch_summary,
    custom,
    custom_message,
    label,
    session_info,
    active_tools_change,
};

const NodeInfo = struct {
    id: []u8,
    parent_id: ?[]u8,
    timestamp: []u8,
    label: ?[]u8,
    label_timestamp: ?[]u8,
    display: []u8,
    searchable: []u8,
    kind: NodeKind,
    depth: usize,
    has_assistant_text: bool = true,

    fn deinit(self: *NodeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.parent_id) |parent_id| allocator.free(parent_id);
        allocator.free(self.timestamp);
        if (self.label) |label| allocator.free(label);
        if (self.label_timestamp) |timestamp| allocator.free(timestamp);
        allocator.free(self.display);
        allocator.free(self.searchable);
        self.* = undefined;
    }
};

pub const Mode = enum {
    tree,
    label,
    summary,
};

pub const Overlay = struct {
    choices: []Choice,
    items: []tui.SelectItem,
    list: tui.SelectList,
    nodes: []NodeInfo,
    search: []u8 = &.{},
    filter_mode: FilterMode = .default,
    folded_ids: [][]u8 = &.{},
    active_path_ids: [][]u8 = &.{},
    current_leaf_id: ?[]u8 = null,
    last_selected_id: ?[]u8 = null,
    show_label_timestamps: bool = false,
    mode: Mode = .tree,
    label_target_id: ?[]u8 = null,
    label_text: []u8 = &.{},
    summary_target_id: ?[]u8 = null,

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .fill = 1 }, .{ .length = 14 } },

    pub fn deinit(self: *Overlay, allocator: std.mem.Allocator) void {
        freeChoices(allocator, self.choices);
        freeOwnedSelectItems(allocator, self.items);
        for (self.nodes) |*node| node.deinit(allocator);
        allocator.free(self.nodes);
        if (self.search.len > 0) allocator.free(self.search);
        freeOwnedStrings(allocator, self.folded_ids);
        freeOwnedStrings(allocator, self.active_path_ids);
        if (self.current_leaf_id) |id| allocator.free(id);
        if (self.last_selected_id) |id| allocator.free(id);
        if (self.label_target_id) |id| allocator.free(id);
        if (self.label_text.len > 0) allocator.free(self.label_text);
        if (self.summary_target_id) |id| allocator.free(id);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
    initial_filter: FilterMode,
) !Overlay {
    return loadFromManager(allocator, session.session_manager, initial_filter);
}

pub fn loadFromManager(
    allocator: std.mem.Allocator,
    manager: *const session_manager_mod.SessionManager,
    initial_filter: FilterMode,
) !Overlay {
    const tree = try manager.getTree(allocator);
    defer {
        for (tree) |*node| node.deinit(allocator);
        allocator.free(tree);
    }

    var node_list = std.ArrayList(NodeInfo).empty;
    errdefer {
        for (node_list.items) |*node| node.deinit(allocator);
        node_list.deinit(allocator);
    }

    const current_leaf_id = manager.getLeafId();
    try appendTreeNodes(allocator, tree, current_leaf_id, 0, &node_list);

    const nodes = try node_list.toOwnedSlice(allocator);
    var nodes_owned = true;
    errdefer if (nodes_owned) {
        for (nodes) |*node| node.deinit(allocator);
        allocator.free(nodes);
    };
    const active_ids = try activePathIds(allocator, nodes, current_leaf_id);
    var active_ids_owned = true;
    errdefer if (active_ids_owned) freeOwnedStrings(allocator, active_ids);

    var overlay = Overlay{
        .choices = try allocator.alloc(Choice, 0),
        .items = try allocator.alloc(tui.SelectItem, 0),
        .list = .{ .items = &.{}, .max_visible = 12 },
        .nodes = nodes,
        .filter_mode = initial_filter,
        .current_leaf_id = if (current_leaf_id) |id| try allocator.dupe(u8, id) else null,
        .active_path_ids = active_ids,
    };
    nodes_owned = false;
    active_ids_owned = false;
    errdefer overlay.deinit(allocator);

    if (overlay.current_leaf_id) |id| overlay.last_selected_id = try allocator.dupe(u8, id);
    try refresh(allocator, &overlay);
    return overlay;
}

fn appendTreeNodes(
    allocator: std.mem.Allocator,
    nodes: []const session_manager_mod.SessionTreeNode,
    current_leaf_id: ?[]const u8,
    depth: usize,
    out: *std.ArrayList(NodeInfo),
) !void {
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        for (nodes) |node| {
            const active = subtreeContains(node, current_leaf_id);
            if ((pass == 0) != active) continue;
            try out.append(allocator, try nodeInfoFromSessionNode(allocator, node, depth));
            try appendTreeNodes(allocator, node.children, current_leaf_id, depth + 1, out);
        }
    }
}

fn subtreeContains(node: session_manager_mod.SessionTreeNode, needle: ?[]const u8) bool {
    const id = needle orelse return false;
    if (std.mem.eql(u8, node.entry.id(), id)) return true;
    for (node.children) |child| {
        if (subtreeContains(child, id)) return true;
    }
    return false;
}

fn nodeInfoFromSessionNode(
    allocator: std.mem.Allocator,
    node: session_manager_mod.SessionTreeNode,
    depth: usize,
) !NodeInfo {
    const entry = node.entry.*;
    const display = try summarizeEntry(allocator, entry);
    errdefer allocator.free(display);
    const searchable = try searchableText(allocator, node, display);
    errdefer allocator.free(searchable);

    return .{
        .id = try allocator.dupe(u8, entry.id()),
        .parent_id = if (entry.parentId()) |parent_id| try allocator.dupe(u8, parent_id) else null,
        .timestamp = try allocator.dupe(u8, entry.timestamp()),
        .label = if (node.label) |label| try allocator.dupe(u8, label) else null,
        .label_timestamp = if (node.label_timestamp) |timestamp| try allocator.dupe(u8, timestamp) else null,
        .display = display,
        .searchable = searchable,
        .kind = kindOfEntry(entry),
        .depth = depth,
        .has_assistant_text = assistantEntryHasText(entry),
    };
}

fn kindOfEntry(entry: session_manager_mod.SessionEntry) NodeKind {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => .user,
            .assistant => .assistant,
            .tool_result => .tool_result,
        },
        .thinking_level_change => .thinking_level_change,
        .model_change => .model_change,
        .compaction => .compaction,
        .branch_summary => .branch_summary,
        .custom => .custom,
        .custom_message => .custom_message,
        .label => .label,
        .active_tools_change => .active_tools_change,
        .session_info => .session_info,
    };
}

fn assistantEntryHasText(entry: session_manager_mod.SessionEntry) bool {
    if (entry != .message or entry.message.message != .assistant) return true;
    for (entry.message.message.assistant.content) |block| {
        if (block == .text and std.mem.trim(u8, block.text.text, " \t\r\n").len > 0) return true;
    }
    return entry.message.message.assistant.stop_reason != .stop and entry.message.message.assistant.stop_reason != .tool_use;
}

fn summarizeEntry(allocator: std.mem.Allocator, entry: session_manager_mod.SessionEntry) ![]u8 {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| blk: {
                const text = try blocksToText(allocator, user_message.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "user: {s}", .{trimSummaryText(text)});
            },
            .assistant => |assistant_message| blk: {
                const text = try formatAssistantMessage(allocator, assistant_message);
                defer allocator.free(text);
                const trimmed = trimSummaryText(text);
                break :blk if (trimmed.len > 0)
                    std.fmt.allocPrint(allocator, "assistant: {s}", .{trimmed})
                else
                    allocator.dupe(u8, "assistant: (no content)");
            },
            .tool_result => |tool_result| blk: {
                const text = try blocksToText(allocator, tool_result.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ tool_result.tool_name, trimSummaryText(text) });
            },
        },
        .thinking_level_change => |thinking_entry| std.fmt.allocPrint(allocator, "[thinking: {s}]", .{@tagName(thinking_entry.thinking_level)}),
        .model_change => |model_entry| std.fmt.allocPrint(allocator, "[model: {s}/{s}]", .{ model_entry.provider, model_entry.model_id }),
        .compaction => |compaction_entry| std.fmt.allocPrint(allocator, "[compaction: {d}k tokens]", .{compaction_entry.tokens_before / 1000}),
        .branch_summary => |branch_summary_entry| std.fmt.allocPrint(allocator, "[branch summary]: {s}", .{trimSummaryText(branch_summary_entry.summary)}),
        .custom => |custom_entry| std.fmt.allocPrint(allocator, "[custom: {s}]", .{custom_entry.custom_type}),
        .custom_message => |custom_message_entry| blk: {
            const text = switch (custom_message_entry.content) {
                .text => |value| try allocator.dupe(u8, value),
                .blocks => |blocks| try blocksToText(allocator, blocks),
            };
            defer allocator.free(text);
            break :blk std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ custom_message_entry.custom_type, trimSummaryText(text) });
        },
        .label => |label_entry| if (label_entry.label) |label|
            std.fmt.allocPrint(allocator, "[label: {s}]", .{label})
        else
            allocator.dupe(u8, "[label: (cleared)]"),
        .session_info => |session_info_entry| if (session_info_entry.name) |name|
            std.fmt.allocPrint(allocator, "session name: {s}", .{name})
        else
            allocator.dupe(u8, "session name cleared"),
        .active_tools_change => |tools_entry| blk: {
            if (tools_entry.active_tool_names.len == 0) break :blk allocator.dupe(u8, "[tools: (none)]");
            var parts = std.ArrayList(u8).empty;
            defer parts.deinit(allocator);
            try parts.appendSlice(allocator, "[tools: ");
            for (tools_entry.active_tool_names, 0..) |name, i| {
                if (i > 0) try parts.appendSlice(allocator, ", ");
                try parts.appendSlice(allocator, name);
            }
            try parts.append(allocator, ']');
            break :blk try parts.toOwnedSlice(allocator);
        },
    };
}

fn searchableText(
    allocator: std.mem.Allocator,
    node: session_manager_mod.SessionTreeNode,
    display: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll(display);
    if (node.label) |label| try writer.writer.print(" {s}", .{label});
    try writer.writer.print(" {s}", .{@tagName(kindOfEntry(node.entry.*))});
    return try allocator.dupe(u8, writer.written());
}

pub fn refresh(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    rememberSelection(allocator, overlay) catch {};
    freeChoices(allocator, overlay.choices);
    freeOwnedSelectItems(allocator, overlay.items);

    switch (overlay.mode) {
        .label => return refreshLabelMode(allocator, overlay),
        .summary => return refreshSummaryMode(allocator, overlay),
        .tree => {},
    }

    var visible = std.ArrayList(usize).empty;
    defer visible.deinit(allocator);
    for (overlay.nodes, 0..) |node, index| {
        if (!nodePassesFilter(overlay, node)) continue;
        if (hasFoldedAncestor(overlay, node)) continue;
        try visible.append(allocator, index);
    }

    if (visible.items.len == 0) {
        overlay.choices = try allocator.alloc(Choice, 1);
        overlay.items = try allocator.alloc(tui.SelectItem, 1);
        overlay.choices[0] = .{ .entry_id = try allocator.dupe(u8, "") };
        overlay.items[0] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No entries found"),
            .description = try statusDescription(allocator, overlay, 0, 0),
        };
        overlay.list.items = overlay.items;
        overlay.list.selected_index = 0;
        try rebuildTableData(allocator, overlay);
        return;
    }

    const selected_id = overlay.last_selected_id orelse overlay.current_leaf_id;
    const selected_visible_index = nearestVisibleIndex(overlay, visible.items, selected_id);

    overlay.choices = try allocator.alloc(Choice, visible.items.len);
    errdefer freeChoices(allocator, overlay.choices);
    overlay.items = try allocator.alloc(tui.SelectItem, visible.items.len);
    errdefer freeOwnedSelectItems(allocator, overlay.items);

    for (visible.items, 0..) |node_index, row| {
        const node = overlay.nodes[node_index];
        overlay.choices[row] = .{ .entry_id = try allocator.dupe(u8, node.id) };
        overlay.items[row] = .{
            .value = try allocator.dupe(u8, node.id),
            .label = try formatNodeLabel(allocator, overlay, node),
            .description = try statusDescription(allocator, overlay, row + 1, visible.items.len),
        };
    }

    overlay.list.items = overlay.items;
    overlay.list.selected_index = selected_visible_index;
    overlay.list.max_visible = 12;
    try rebuildTableData(allocator, overlay);
}

fn rebuildTableData(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    overlay_table.freeTable(allocator, overlay.table_cells, overlay.table_rows);
    const built = try overlay_table.buildLabelDescriptionTable(allocator, overlay.items);
    overlay.table_cells = built.cells;
    overlay.table_rows = built.rows;
}

fn refreshLabelMode(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    overlay.choices = try allocator.alloc(Choice, 1);
    overlay.items = try allocator.alloc(tui.SelectItem, 1);
    overlay.choices[0] = .{ .entry_id = try allocator.dupe(u8, overlay.label_target_id orelse "") };
    overlay.items[0] = .{
        .value = try allocator.dupe(u8, "label"),
        .label = try std.fmt.allocPrint(allocator, "Label (empty to remove): {s}", .{overlay.label_text}),
        .description = try allocator.dupe(u8, "Enter save • Esc cancel"),
    };
    overlay.list.items = overlay.items;
    overlay.list.selected_index = 0;
    overlay.list.max_visible = 1;
    try rebuildTableData(allocator, overlay);
}

fn refreshSummaryMode(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    const labels = [_][]const u8{ "No summary", "Summarize", "Summarize with custom prompt" };
    overlay.choices = try allocator.alloc(Choice, labels.len);
    overlay.items = try allocator.alloc(tui.SelectItem, labels.len);
    for (labels, 0..) |label, index| {
        overlay.choices[index] = .{ .entry_id = try allocator.dupe(u8, overlay.summary_target_id orelse "") };
        overlay.items[index] = .{
            .value = try allocator.dupe(u8, label),
            .label = try allocator.dupe(u8, label),
            .description = try allocator.dupe(u8, "Choose branch summary behavior"),
        };
    }
    overlay.list.items = overlay.items;
    overlay.list.selected_index = 0;
    overlay.list.max_visible = labels.len;
    try rebuildTableData(allocator, overlay);
}

fn nodePassesFilter(overlay: *const Overlay, node: NodeInfo) bool {
    const is_current = if (overlay.current_leaf_id) |leaf_id| std.mem.eql(u8, leaf_id, node.id) else false;
    if (node.kind == .assistant and !node.has_assistant_text and !is_current) return false;

    const passes_mode = switch (overlay.filter_mode) {
        .default => !isBookkeeping(node.kind),
        .no_tools => !isBookkeeping(node.kind) and node.kind != .tool_result,
        .user_only => node.kind == .user,
        .labeled_only => node.label != null,
        .all => true,
    };
    if (!passes_mode) return false;
    if (overlay.search.len == 0) return true;

    var tokens = std.mem.tokenizeAny(u8, overlay.search, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.ascii.indexOfIgnoreCase(node.searchable, token) == null) return false;
    }
    return true;
}

fn isBookkeeping(kind: NodeKind) bool {
    return switch (kind) {
        .label, .custom, .model_change, .thinking_level_change => true,
        else => false,
    };
}

fn hasFoldedAncestor(overlay: *const Overlay, node: NodeInfo) bool {
    var parent = node.parent_id;
    while (parent) |parent_id| {
        if (containsString(overlay.folded_ids, parent_id)) return true;
        const parent_node = nodeById(overlay, parent_id) orelse return false;
        parent = parent_node.parent_id;
    }
    return false;
}

fn nearestVisibleIndex(overlay: *const Overlay, visible: []const usize, preferred_id: ?[]const u8) usize {
    var current = preferred_id;
    while (current) |id| {
        for (visible, 0..) |node_index, row| {
            if (std.mem.eql(u8, overlay.nodes[node_index].id, id)) return row;
        }
        const node = nodeById(overlay, id) orelse break;
        current = node.parent_id;
    }
    return visible.len - 1;
}

fn formatNodeLabel(allocator: std.mem.Allocator, overlay: *const Overlay, node: NodeInfo) ![]u8 {
    const prefix = try indentationPrefix(allocator, node.depth);
    defer allocator.free(prefix);
    const fold_marker = if (containsString(overlay.folded_ids, node.id))
        "⊞ "
    else if (hasVisibleChildren(overlay, node.id))
        "⊟ "
    else
        "";
    const active = if (containsString(overlay.active_path_ids, node.id)) "• " else "";
    const label = if (node.label) |value| try std.fmt.allocPrint(allocator, "[{s}] ", .{value}) else try allocator.dupe(u8, "");
    defer allocator.free(label);
    const timestamp = if (overlay.show_label_timestamps and node.label != null and node.label_timestamp != null)
        try formatLabelTimestamp(allocator, node.label_timestamp.?)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(timestamp);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}{s}", .{
        prefix,
        fold_marker,
        active,
        label,
        timestamp,
        node.display,
    });
}

fn indentationPrefix(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    if (depth == 0) return allocator.dupe(u8, "");
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var index: usize = 0;
    while (index < depth) : (index += 1) {
        if (index + 1 == depth) {
            try prefix.appendSlice(allocator, "└─ ");
        } else {
            try prefix.appendSlice(allocator, "   ");
        }
    }
    return try prefix.toOwnedSlice(allocator);
}

fn statusDescription(allocator: std.mem.Allocator, overlay: *const Overlay, index: usize, total: usize) ![]u8 {
    const filter = filterLabel(overlay.filter_mode);
    if (overlay.search.len > 0) {
        return std.fmt.allocPrint(allocator, "({d}/{d}) [{s}] search: {s}", .{ index, total, filter, overlay.search });
    }
    return std.fmt.allocPrint(allocator, "({d}/{d}) [{s}]{s}", .{
        index,
        total,
        filter,
        if (overlay.show_label_timestamps) " [+label time]" else "",
    });
}

fn filterLabel(mode: FilterMode) []const u8 {
    return switch (mode) {
        .default => "default",
        .no_tools => "no-tools",
        .user_only => "user",
        .labeled_only => "labeled",
        .all => "all",
    };
}

pub fn hint(overlay: *const Overlay) []const u8 {
    return switch (overlay.mode) {
        .tree => "Search/type • Up/Down move • Left/Right page • Ctrl/Alt+Left fold/up • Ctrl/Alt+Right unfold/down • Shift+L label • Shift+T label time • Ctrl+O filter • Enter select • Esc clear/cancel",
        .label => "Enter save • Esc cancel",
        .summary => "Summarize branch? Enter choose • Esc back to tree",
    };
}

pub fn title(overlay: *const Overlay) []const u8 {
    return switch (overlay.mode) {
        .tree => "Session Tree",
        .label => "Edit Tree Label",
        .summary => "Summarize branch?",
    };
}

pub fn updateSearch(allocator: std.mem.Allocator, overlay: *Overlay, next_search: []const u8) !void {
    const owned = try allocator.dupe(u8, next_search);
    if (overlay.search.len > 0) allocator.free(overlay.search);
    overlay.search = owned;
    try clearFolded(allocator, overlay);
    try refresh(allocator, overlay);
}

pub fn setFilterMode(allocator: std.mem.Allocator, overlay: *Overlay, mode: FilterMode) !void {
    overlay.filter_mode = mode;
    try clearFolded(allocator, overlay);
    try refresh(allocator, overlay);
}

pub fn cycleFilter(allocator: std.mem.Allocator, overlay: *Overlay, delta: isize) !void {
    const modes = [_]FilterMode{ .default, .no_tools, .user_only, .labeled_only, .all };
    const current = indexOfFilterMode(&modes, overlay.filter_mode);
    const next_index = @mod(@as(isize, @intCast(current)) + delta, @as(isize, @intCast(modes.len)));
    try setFilterMode(allocator, overlay, modes[@intCast(next_index)]);
}

fn indexOfFilterMode(modes: []const FilterMode, needle: FilterMode) usize {
    for (modes, 0..) |mode, index| {
        if (mode == needle) return index;
    }
    return 0;
}

pub fn moveSelection(allocator: std.mem.Allocator, overlay: *Overlay, delta: isize, wrap: bool) !void {
    _ = allocator;
    if (overlay.items.len == 0) {
        overlay.list.selected_index = 0;
        return;
    }
    const current: isize = @intCast(overlay.list.selectedIndex());
    const max_index: isize = @intCast(overlay.items.len - 1);
    const next = current + delta;
    overlay.list.selected_index = if (wrap)
        @intCast(@mod(next, max_index + 1))
    else
        @intCast(std.math.clamp(next, 0, max_index));
}

pub fn selectedEntryId(overlay: *const Overlay) ?[]const u8 {
    if (overlay.choices.len == 0) return null;
    const index = overlay.list.selectedIndex();
    if (index >= overlay.choices.len) return null;
    const id = overlay.choices[index].entry_id;
    return if (id.len == 0) null else id;
}

pub fn beginLabelMode(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    const id = selectedEntryId(overlay) orelse return;
    const node = nodeById(overlay, id) orelse return;
    if (overlay.label_target_id) |old| allocator.free(old);
    overlay.label_target_id = try allocator.dupe(u8, id);
    if (overlay.label_text.len > 0) allocator.free(overlay.label_text);
    overlay.label_text = if (node.label) |label| try allocator.dupe(u8, label) else try allocator.dupe(u8, "");
    overlay.mode = .label;
    try refresh(allocator, overlay);
}

pub fn updateLabelText(allocator: std.mem.Allocator, overlay: *Overlay, next_text: []const u8) !void {
    const owned = try allocator.dupe(u8, next_text);
    if (overlay.label_text.len > 0) allocator.free(overlay.label_text);
    overlay.label_text = owned;
    try refresh(allocator, overlay);
}

pub fn cancelLabelMode(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    overlay.mode = .tree;
    try refresh(allocator, overlay);
}

pub fn applyLabelToNode(allocator: std.mem.Allocator, overlay: *Overlay, entry_id: []const u8, label: ?[]const u8, timestamp: ?[]const u8) !void {
    const trimmed = if (label) |value| std.mem.trim(u8, value, &std.ascii.whitespace) else "";
    for (overlay.nodes) |*node| {
        if (!std.mem.eql(u8, node.id, entry_id)) continue;
        if (node.label) |old| allocator.free(old);
        if (node.label_timestamp) |old| allocator.free(old);
        node.label = if (trimmed.len > 0) try allocator.dupe(u8, trimmed) else null;
        node.label_timestamp = if (trimmed.len > 0) try allocator.dupe(u8, timestamp orelse node.timestamp) else null;
        break;
    }
    overlay.mode = .tree;
    try refresh(allocator, overlay);
}

pub fn beginSummaryPrompt(allocator: std.mem.Allocator, overlay: *Overlay, target_id: []const u8) !void {
    if (overlay.summary_target_id) |old| allocator.free(old);
    overlay.summary_target_id = try allocator.dupe(u8, target_id);
    overlay.mode = .summary;
    try refresh(allocator, overlay);
}

pub fn cancelSummaryPrompt(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    overlay.mode = .tree;
    try refresh(allocator, overlay);
}

pub fn toggleLabelTimestamps(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    overlay.show_label_timestamps = !overlay.show_label_timestamps;
    try refresh(allocator, overlay);
}

pub fn clearSearchAndFolds(allocator: std.mem.Allocator, overlay: *Overlay) !bool {
    if (overlay.search.len == 0 and overlay.folded_ids.len == 0) return false;
    if (overlay.search.len > 0) {
        allocator.free(overlay.search);
        overlay.search = try allocator.dupe(u8, "");
    }
    try clearFolded(allocator, overlay);
    try refresh(allocator, overlay);
    return true;
}

pub fn foldOrMoveUp(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    const id = selectedEntryId(overlay) orelse return;
    if (hasVisibleChildren(overlay, id) and !containsString(overlay.folded_ids, id)) {
        try appendOwnedString(allocator, &overlay.folded_ids, id);
        try refresh(allocator, overlay);
        return;
    }
    if (nodeById(overlay, id)) |node| {
        if (node.parent_id) |parent_id| setSelectionById(overlay, parent_id);
    }
}

pub fn unfoldOrMoveDown(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    const id = selectedEntryId(overlay) orelse return;
    if (containsString(overlay.folded_ids, id)) {
        try removeOwnedString(allocator, &overlay.folded_ids, id);
        try refresh(allocator, overlay);
        return;
    }
    for (overlay.nodes) |node| {
        if (node.parent_id) |parent_id| {
            if (std.mem.eql(u8, parent_id, id) and nodePassesFilter(overlay, node)) {
                setSelectionById(overlay, node.id);
                return;
            }
        }
    }
}

fn setSelectionById(overlay: *Overlay, id: []const u8) void {
    for (overlay.choices, 0..) |choice, index| {
        if (std.mem.eql(u8, choice.entry_id, id)) {
            overlay.list.selected_index = index;
            return;
        }
    }
}

fn rememberSelection(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    if (overlay.mode != .tree) return;
    const id = selectedEntryId(overlay) orelse return;
    if (overlay.last_selected_id) |old| allocator.free(old);
    overlay.last_selected_id = try allocator.dupe(u8, id);
}

fn hasVisibleChildren(overlay: *const Overlay, id: []const u8) bool {
    for (overlay.nodes) |node| {
        if (node.parent_id) |parent_id| {
            if (std.mem.eql(u8, parent_id, id) and nodePassesFilter(overlay, node) and !hasFoldedAncestor(overlay, node)) return true;
        }
    }
    return false;
}

fn nodeById(overlay: *const Overlay, id: []const u8) ?NodeInfo {
    for (overlay.nodes) |node| {
        if (std.mem.eql(u8, node.id, id)) return node;
    }
    return null;
}

fn activePathIds(allocator: std.mem.Allocator, nodes: []const NodeInfo, leaf_id: ?[]const u8) ![][]u8 {
    var ids = std.ArrayList([]u8).empty;
    errdefer freeOwnedStrings(allocator, ids.items);
    var current = leaf_id;
    while (current) |id| {
        try ids.append(allocator, try allocator.dupe(u8, id));
        var parent: ?[]const u8 = null;
        for (nodes) |node| {
            if (std.mem.eql(u8, node.id, id)) {
                parent = node.parent_id;
                break;
            }
        }
        current = parent;
    }
    return try ids.toOwnedSlice(allocator);
}

fn formatLabelTimestamp(allocator: std.mem.Allocator, timestamp: []const u8) ![]u8 {
    if (timestamp.len < 16) return std.fmt.allocPrint(allocator, "{s} ", .{timestamp});
    const year = timestamp[2..4];
    const month = trimLeadingZero(timestamp[5..7]);
    const day = trimLeadingZero(timestamp[8..10]);
    const hour = timestamp[11..13];
    const minute = timestamp[14..16];
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s} {s}:{s} ", .{ year, month, day, hour, minute });
}

fn trimLeadingZero(value: []const u8) []const u8 {
    if (value.len == 2 and value[0] == '0') return value[1..];
    return value;
}

fn trimSummaryText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len > 72) trimmed[0..72] else trimmed;
}

fn containsString(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn appendOwnedString(allocator: std.mem.Allocator, target: *[][]u8, value: []const u8) !void {
    var next = try allocator.alloc([]u8, target.*.len + 1);
    for (target.*, 0..) |item, index| next[index] = item;
    next[target.*.len] = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = next;
}

fn removeOwnedString(allocator: std.mem.Allocator, target: *[][]u8, value: []const u8) !void {
    var count: usize = 0;
    for (target.*) |item| {
        if (!std.mem.eql(u8, item, value)) count += 1;
    }
    var next = try allocator.alloc([]u8, count);
    var out: usize = 0;
    for (target.*) |item| {
        if (std.mem.eql(u8, item, value)) {
            allocator.free(item);
            continue;
        }
        next[out] = item;
        out += 1;
    }
    allocator.free(target.*);
    target.* = next;
}

fn clearFolded(allocator: std.mem.Allocator, overlay: *Overlay) !void {
    freeOwnedStrings(allocator, overlay.folded_ids);
    overlay.folded_ids = try allocator.alloc([]u8, 0);
}

fn freeChoices(allocator: std.mem.Allocator, choices: []Choice) void {
    for (choices) |choice| allocator.free(choice.entry_id);
    allocator.free(choices);
}

const freeOwnedSelectItems = overlay_table.freeOwnedSelectItems;

const freeOwnedStrings = overlay_table.freeOwnedStrings;

fn makeTestTextMessage(allocator: std.mem.Allocator, role: []const u8, text: []const u8, timestamp: i64, model: ai.Model) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .role = try allocator.dupe(u8, "user"),
            .content = blocks,
            .timestamp = timestamp,
        } };
    }
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

test "tree overlay renders active path search filters folds and label timestamps" {
    const allocator = std.testing.allocator;
    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    var manager = try session_manager_mod.SessionManager.inMemory(allocator, std.testing.io, "/tmp/project");
    defer manager.deinit();

    var root = try makeTestTextMessage(allocator, "user", "root prompt", 1, model);
    defer session_manager_mod.deinitMessage(allocator, &root);
    const root_id = try manager.appendMessage(root);

    var main = try makeTestTextMessage(allocator, "assistant", "main branch", 2, model);
    defer session_manager_mod.deinitMessage(allocator, &main);
    _ = try manager.appendMessage(main);

    try manager.branch(root_id);
    var alternate = try makeTestTextMessage(allocator, "assistant", "alternate branch", 3, model);
    defer session_manager_mod.deinitMessage(allocator, &alternate);
    const alternate_id = try manager.appendMessage(alternate);
    _ = try manager.appendLabelChange(alternate_id, "bookmark");

    var overlay = try loadFromManager(allocator, &manager, .default);
    defer overlay.deinit(allocator);

    try std.testing.expect(overlay.items.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[overlay.list.selectedIndex()].label, "• ") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[overlay.list.selectedIndex()].label, "[bookmark]") != null);

    try updateSearch(allocator, &overlay, "alternate");
    try std.testing.expectEqual(@as(usize, 1), overlay.items.len);
    try std.testing.expectEqualStrings(alternate_id, overlay.choices[0].entry_id);

    try updateSearch(allocator, &overlay, "");
    try setFilterMode(allocator, &overlay, .user_only);
    try std.testing.expectEqual(@as(usize, 1), overlay.items.len);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[0].label, "root prompt") != null);

    try setFilterMode(allocator, &overlay, .labeled_only);
    try toggleLabelTimestamps(allocator, &overlay);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[0].label, "[bookmark]") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[0].description.?, "[labeled]") != null);
}
