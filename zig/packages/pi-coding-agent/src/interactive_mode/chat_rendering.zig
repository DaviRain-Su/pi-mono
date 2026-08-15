const std = @import("std");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");
const resources_mod = @import("../resources/resources.zig");
const chat_items = @import("chat_items.zig");
const formatting = @import("formatting.zig");

const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;

pub const ChatKind = chat_items.ChatKind;
pub const ChatItem = chat_items.ChatItem;

pub const ViewportMetrics = struct {
    rendered_height: usize,
    visible_height: usize,
};

const ItemLayout = struct {
    item_index: usize,
    rows: usize,
};

pub const SelectionRange = struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
};

/// Renders chat items into `window`, applying scroll offset without allocating
/// a full-size scratch screen. Only items that overlap the visible area are
/// rendered, avoiding expensive off-screen markdown processing.
pub fn drawViewport(
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
    selection: ?SelectionRange,
    selected_text_out: ?*std.ArrayList(u8),
) !ViewportMetrics {
    if (start_row >= window.height or height == 0) return .{ .rendered_height = 0, .visible_height = 0 };

    const visible_height = @min(height, @as(usize, window.height) - start_row);
    const width = @max(@as(usize, window.width), 1);

    // Compute total rendered height and per-item layout without rendering.
    var layout = try computeLayout(allocator, items, width, all_expanded);
    defer layout.deinit(allocator);

    const rendered_height = layout.total_rows;
    const max_offset = rendered_height -| visible_height;
    const offset = @min(chat_scroll_offset, max_offset);
    const src_start = max_offset -| offset;
    const dst = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(visible_height),
    });

    // Find the first item that overlaps the visible area.
    var item_row: usize = 0;
    var item_index: usize = 0;
    while (item_index < layout.entries.items.len) : (item_index += 1) {
        const entry_rows = layout.entries.items[item_index].rows;
        const item_end = item_row + entry_rows;
        if (item_end > src_start) break;
        item_row = item_end;
    }

    // Render visible items directly into the destination window.
    var dst_row: usize = 0;
    while (item_index < items.len and dst_row < visible_height) : (item_index += 1) {
        const entry_rows = if (item_index < layout.entries.items.len) layout.entries.items[item_index].rows else estimateItemRowsVisible(items[item_index], width, all_expanded);
        const draw_start = if (item_row < src_start) src_start - item_row else 0;
        const available = visible_height - dst_row;

        if (draw_start < entry_rows and available > 0) {
            const slice_height = @min(entry_rows - draw_start, available);
            try renderItemSlice(
                dst,
                allocator,
                keybindings,
                theme,
                items[item_index],
                dst_row,
                slice_height,
                draw_start,
                now_ms,
                all_expanded,
                width,
                selection,
                src_start,
            );
            dst_row += slice_height;
        }
        item_row += entry_rows;
    }

    // Extract selected text by re-rendering visible items into a scratch screen.
    if (selected_text_out) |text_out| {
        if (selection) |sel| {
            try extractSelectedTextFromItems(
                allocator,
                keybindings,
                theme,
                items,
                layout,
                width,
                now_ms,
                all_expanded,
                sel,
                text_out,
            );
        }
    }

    drawScrollIndicators(dst, theme, src_start, rendered_height, visible_height);
    return .{ .rendered_height = rendered_height, .visible_height = visible_height };
}

/// Pre-computed layout: total row count and per-item row counts.
/// Cached across render calls by the caller (AppState) to avoid re-computation
/// when content has not changed.
const Layout = struct {
    total_rows: usize,
    entries: std.ArrayList(ItemLayout),

    fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};

fn computeLayout(allocator: std.mem.Allocator, items: []const ChatItem, width: usize, all_expanded: bool) !Layout {
    var entries = try std.ArrayList(ItemLayout).initCapacity(allocator, items.len);
    var total: usize = 0;
    for (items, 0..) |item, i| {
        const rows = estimateItemRowsVisible(item, width, all_expanded);
        entries.appendAssumeCapacity(.{ .item_index = i, .rows = rows });
        total += rows;
    }
    return .{ .total_rows = total, .entries = entries };
}

fn renderItemSlice(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    dst_row: usize,
    slice_height: usize,
    src_skip: usize,
    now_ms: i64,
    all_expanded: bool,
    width: usize,
    selection: ?SelectionRange,
    viewport_src_start: usize,
) !void {
    // Allocate a small scratch screen just for this item.
    const full_height = estimateItemRowsFull(item, width, true);
    const scratch_rows = @max(@as(usize, 1), @min(full_height, src_skip + slice_height + 1));
    var scratch = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(scratch_rows, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(width),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer scratch.deinit(allocator);

    const scratch_window = tui.draw.rootWindow(&scratch);
    scratch_window.clear();
    _ = try drawItem(scratch_window, allocator, keybindings, theme, item, 0, now_ms, all_expanded);

    const child = window.child(.{
        .y_off = @intCast(dst_row),
        .height = @intCast(slice_height),
    });
    const actual_src = @min(src_skip, @as(usize, scratch.height) -| 1);
    if (selection) |sel| {
        blitScreenRowsWithSelection(&scratch, child, actual_src, slice_height, sel, viewport_src_start + dst_row - actual_src);
    } else {
        blitScreenRows(&scratch, child, actual_src, slice_height);
    }
}

fn drawScrollIndicators(
    window: tui.vaxis.Window,
    theme: ?*const resources_mod.Theme,
    src_start: usize,
    rendered_height: usize,
    visible_height: usize,
) void {
    if (visible_height == 0 or window.width == 0) return;
    const style = styleForToken(theme, .status);
    if (src_start > 0) {
        drawScrollIndicator(window, 0, "↑ more", style);
    }
    if (src_start + visible_height < rendered_height) {
        drawScrollIndicator(window, visible_height - 1, "↓ more", style);
    }
}

fn drawScrollIndicator(
    window: tui.vaxis.Window,
    row: usize,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) void {
    if (row >= window.height) return;
    const text_width = tui.ansi.visibleWidth(text);
    const col = @as(usize, window.width) -| text_width;
    _ = window.printSegment(.{
        .text = text,
        .style = style,
    }, .{
        .wrap = .none,
        .row_offset = @intCast(row),
        .col_offset = @intCast(col),
    });
}

pub fn drawItems(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    now_ms: i64,
    all_expanded: bool,
) !tui.DrawSize {
    var row: usize = 0;
    for (items) |item| {
        if (row >= window.height) break;
        row += try drawItem(window, allocator, keybindings, theme, item, row, now_ms, all_expanded);
    }
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

pub fn drawItem(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    start_row: usize,
    now_ms: i64,
    all_expanded: bool,
) !usize {
    const remaining_height = @as(usize, window.height) -| start_row;
    if (remaining_height == 0) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(remaining_height),
    });
    if (!all_expanded) {
        if (previewThresholdForItem(item)) |threshold| {
            const full_height_hint = @max(@as(usize, 1), estimateItemRowsFull(item, @max(@as(usize, window.width), 1), true));
            var scratch = try tui.vaxis.Screen.init(allocator, .{
                .rows = @intCast(@min(full_height_hint, @as(usize, std.math.maxInt(u16)))),
                .cols = window.width,
                .x_pixel = 0,
                .y_pixel = 0,
            });
            defer scratch.deinit(allocator);

            const scratch_window = tui.draw.rootWindow(&scratch);
            scratch_window.clear();
            const rendered_height = @min(
                try drawItemFull(scratch_window, allocator, theme, item, 0, now_ms, true),
                @as(usize, scratch.height),
            );
            if (rendered_height > threshold) {
                const preview_rows = @min(threshold, remaining_height);
                blitScreenRows(&scratch, child, 0, preview_rows);
                if (threshold < remaining_height) {
                    try drawCollapseIndicator(child, allocator, keybindings, theme, item.kind, threshold, rendered_height - threshold);
                }
                return @min(threshold + 1, remaining_height);
            }
        }
    }

    return drawItemFull(child, allocator, theme, item, 0, now_ms, all_expanded);
}

fn drawItemFull(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    start_row: usize,
    now_ms: i64,
    all_expanded: bool,
) !usize {
    const remaining_height = @as(usize, window.height) -| start_row;
    if (remaining_height == 0) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(remaining_height),
    });
    const item_text = displayText(item, all_expanded);
    switch (item.kind) {
        .user => return drawUserItem(child, theme, item_text),
        .assistant => {
            var prefix_style = styleForToken(theme, .task_header_accent);
            prefix_style.bold = true;
            var row: usize = drawWrappedText(child, 0, ASSISTANT_PREFIX, prefix_style);
            if (std.mem.trim(u8, item_text, " \t\r\n").len == 0) return row;
            const markdown_window = child.child(.{
                .y_off = @intCast(row),
                .height = child.height - @as(u16, @intCast(row)),
            });
            const markdown = tui.Markdown{ .text = item_text, .styles = if (theme) |t| tui.markdownStylesFor(t) else .{} };
            const size = try markdown.draw(markdown_window, .{
                .window = markdown_window,
                .arena = allocator,
            });
            row += @as(usize, size.height);
            return row;
        },
        .markdown => {
            const markdown = tui.Markdown{ .text = item_text, .styles = if (theme) |t| tui.markdownStylesFor(t) else .{} };
            const size = try markdown.draw(child, .{
                .window = child,
                .arena = allocator,
            });
            return @as(usize, size.height);
        },
        .thinking => return drawThinkingItem(child, theme, item, now_ms),
        .tool_call, .tool_result, .bash_execution => return drawToolItem(child, allocator, theme, item, now_ms, all_expanded),
        else => return drawWrappedText(child, 0, item_text, styleForToken(theme, token(item.kind))),
    }
}

fn drawUserItem(window: tui.vaxis.Window, theme: ?*const resources_mod.Theme, text: []const u8) usize {
    const prefix = "You:";
    if (!std.mem.startsWith(u8, text, prefix)) {
        return drawWrappedText(window, 0, text, styleForToken(theme, .text));
    }

    var prefix_style = styleForToken(theme, .task_header_accent);
    prefix_style.bold = true;
    _ = window.printSegment(.{
        .text = prefix,
        .style = prefix_style,
    }, .{ .wrap = .none });

    const body = if (text.len > prefix.len and text[prefix.len] == ' ') text[prefix.len + 1 ..] else text[prefix.len..];
    if (body.len == 0) return 1;

    const body_window = if (window.width > prefix.len + 1)
        window.child(.{
            .x_off = @intCast(prefix.len + 1),
            .width = window.width - @as(u16, @intCast(prefix.len + 1)),
        })
    else
        window;
    return @max(@as(usize, 1), drawWrappedText(body_window, 0, body, styleForToken(theme, .text)));
}

fn displayText(item: ChatItem, all_expanded: bool) []const u8 {
    if (all_expanded and (item.kind == .tool_result or item.kind == .bash_execution)) {
        if (item.expanded_text) |expanded_text| return expanded_text;
    }
    return item.text;
}

pub fn previewThreshold(kind: ChatKind) ?usize {
    return switch (kind) {
        .thinking => 1,
        .tool_result => 3,
        .assistant, .markdown => null,
        .welcome, .info, .@"error", .user, .tool_call, .bash_execution => null,
    };
}

fn previewThresholdForItem(item: ChatItem) ?usize {
    return switch (item.kind) {
        .tool_result => if (item.expanded_text != null) previewThreshold(item.kind) else null,
        else => previewThreshold(item.kind),
    };
}

const ToolVisualState = enum {
    pending,
    success,
    @"error",
};

const ToolBodyKind = enum {
    none,
    text,
    terminal,
    diff,
};

const ParsedToolItem = struct {
    label: []const u8,
    title: []const u8,
    body: []const u8,
    details: []const u8,
    body_kind: ToolBodyKind,
};

fn drawToolItem(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
    all_expanded: bool,
) !usize {
    _ = now_ms;
    if (window.height == 0 or window.width == 0) return 0;

    const item_text = displayText(item, all_expanded);
    const state = toolVisualState(item.kind, item_text);
    const parsed = parseToolItem(item.kind, item_text);

    const marker = switch (item.kind) {
        .bash_execution => switch (state) {
            .pending => "*",
            .success => "+",
            .@"error" => "!",
        },
        .tool_result => if (state == .@"error") "!" else "+",
        .tool_call => ">",
        else => unreachable,
    };

    const title_style = toolTitleStyle(theme, item.kind, state);
    const body_style = toolBodyStyle(theme, item.kind, state);
    const detail_style = toolDetailStyle(theme, state);

    var row: usize = 0;
    if (row < window.height) {
        const header_window = window.child(.{
            .y_off = @intCast(row),
            .height = 1,
        });
        const tags = [_]tui.Tag{
            .{
                .label = parsed.label,
                .style = title_style,
            },
            .{
                .label = toolStateLabel(item.kind, state),
                .style = detail_style,
            },
        };
        const tag_group = tui.TagGroup{ .tags = &tags };
        const tag_size = try tag_group.draw(header_window, .{
            .window = header_window,
            .arena = allocator,
        });

        if (parsed.title.len > 0 and @as(usize, header_window.width) > @as(usize, tag_size.width) + 2) {
            const title_window = header_window.child(.{
                .x_off = @intCast(@as(usize, tag_size.width) + 1),
                .width = header_window.width - tag_size.width - 1,
            });
            const title_text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ marker, parsed.title });
            row += drawWrappedText(title_window, 0, title_text, title_style);
        } else {
            row += 1;
        }
    }

    if (parsed.body.len > 0 and row < window.height) {
        const remaining = @as(usize, window.height) - row;
        const body_height = if (parsed.details.len > 0 and remaining > 1) remaining - 1 else remaining;
        row += try drawToolBody(window, allocator, theme, parsed, row, body_height, body_style);
    }

    if (parsed.details.len > 0 and row < window.height) {
        const details_window = if (window.width > 4)
            window.child(.{
                .x_off = 2,
                .width = window.width - 2,
                .y_off = @intCast(row),
                .height = window.height - @as(u16, @intCast(row)),
            })
        else
            window.child(.{
                .y_off = @intCast(row),
                .height = window.height - @as(u16, @intCast(row)),
            });
        const details_text = try std.fmt.allocPrint(allocator, "Details: {s}", .{parsed.details});
        row += drawWrappedText(details_window, 0, details_text, detail_style);
    }

    return @max(@as(usize, 1), row);
}

fn drawToolBody(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    parsed: ParsedToolItem,
    start_row: usize,
    max_height: usize,
    style: tui.vaxis.Cell.Style,
) !usize {
    if (max_height == 0) return 0;
    const body_window = if (window.width > 2)
        window.child(.{
            .x_off = 2,
            .width = window.width - 2,
            .y_off = @intCast(start_row),
            .height = @intCast(@min(max_height, @as(usize, window.height) - start_row)),
        })
    else
        window.child(.{
            .y_off = @intCast(start_row),
            .height = @intCast(@min(max_height, @as(usize, window.height) - start_row)),
        });

    return switch (parsed.body_kind) {
        .none => 0,
        .text => drawWrappedText(body_window, 0, parsed.body, style),
        .terminal => try drawTerminalPanelBody(body_window, allocator, parsed.body, style),
        .diff => try drawDiffViewerBody(body_window, allocator, theme, parsed.body),
    };
}

fn drawTerminalPanelBody(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) !usize {
    const lines = try buildTerminalLines(allocator, text, style);
    const panel = tui.TerminalPanel{
        .lines = lines,
        .style = style,
    };
    const size = try panel.draw(window, .{
        .window = window,
        .arena = allocator,
    });
    return @as(usize, size.height);
}

fn buildTerminalLines(
    allocator: std.mem.Allocator,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) ![]tui.TerminalLine {
    if (text.len == 0) return &.{};
    const line_count = countLogicalLines(text);
    const lines = try allocator.alloc(tui.TerminalLine, line_count);
    var split = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (split.next()) |line| : (index += 1) {
        lines[index] = .{
            .text = line,
            .style = style,
        };
    }
    return lines;
}

fn drawDiffViewerBody(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
) !usize {
    const lines = try buildDiffLines(allocator, text);
    const viewer = tui.DiffViewer{
        .lines = lines,
        .show_line_numbers = false,
        .line_number_width = 0,
        .gutter_width = 1,
        .header_style = diffHeaderStyle(theme),
        .added_style = diffAddedStyle(theme),
        .removed_style = diffRemovedStyle(theme),
        .added_bg = diffAddedBackground(theme),
        .removed_bg = diffRemovedBackground(theme),
        .context_style = styleForToken(theme, .text),
    };
    const size = try viewer.draw(window, .{
        .window = window,
        .arena = allocator,
    });
    return @as(usize, size.height);
}

fn buildDiffLines(allocator: std.mem.Allocator, text: []const u8) ![]tui.DiffLine {
    if (text.len == 0) return &.{};
    const line_count = countLogicalLines(text);
    const lines = try allocator.alloc(tui.DiffLine, line_count);
    var split = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (split.next()) |line| : (index += 1) {
        if (std.mem.startsWith(u8, line, "+")) {
            lines[index] = .{ .text = line[1..], .line_type = .added };
        } else if (std.mem.startsWith(u8, line, "-")) {
            lines[index] = .{ .text = line[1..], .line_type = .removed };
        } else if (std.mem.startsWith(u8, line, "@@") or
            std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "--- "))
        {
            lines[index] = .{ .text = line, .line_type = .header };
        } else {
            lines[index] = .{ .text = line, .line_type = .context };
        }
    }
    return lines;
}

fn parseToolItem(kind: ChatKind, text: []const u8) ParsedToolItem {
    const split = splitFirstLine(text);
    return switch (kind) {
        .bash_execution => parseBashExecutionItem(split),
        .tool_call => parseToolCallItem(split),
        .tool_result => parseToolResultItem(split),
        else => .{
            .label = "tool",
            .title = split.title,
            .body = split.body,
            .details = "",
            .body_kind = if (split.body.len > 0) .text else .none,
        },
    };
}

fn parseBashExecutionItem(split: LineSplit) ParsedToolItem {
    const details = splitToolDetails(split.body);
    return .{
        .label = "bash",
        .title = trimBashCommand(split.title),
        .body = details.body,
        .details = details.details,
        .body_kind = if (details.body.len > 0) .terminal else .none,
    };
}

fn parseToolCallItem(split: LineSplit) ParsedToolItem {
    const body_kind: ToolBodyKind = if (looksLikeDiffBody(split.body))
        .diff
    else if (split.body.len > 0)
        .text
    else
        .none;
    if (std.mem.startsWith(u8, split.title, "$ ")) {
        return .{
            .label = "bash",
            .title = trimBashCommand(split.title),
            .body = split.body,
            .details = "",
            .body_kind = if (split.body.len > 0) .terminal else .none,
        };
    }
    if (std.mem.startsWith(u8, split.title, "Read ")) {
        return .{ .label = "read", .title = split.title, .body = split.body, .details = "", .body_kind = body_kind };
    }
    if (std.mem.startsWith(u8, split.title, "Write ")) {
        return .{ .label = "write", .title = split.title, .body = split.body, .details = "", .body_kind = body_kind };
    }
    if (std.mem.startsWith(u8, split.title, "Edit ")) {
        return .{ .label = "edit", .title = split.title, .body = split.body, .details = "", .body_kind = body_kind };
    }
    if (std.mem.startsWith(u8, split.title, "Gate ")) {
        return .{ .label = "gate", .title = split.title, .body = split.body, .details = "", .body_kind = body_kind };
    }
    return .{ .label = "tool", .title = split.title, .body = split.body, .details = "", .body_kind = body_kind };
}

fn parseToolResultItem(split: LineSplit) ParsedToolItem {
    const prefix_labels = [_]struct { prefix: []const u8, title: []const u8 }{
        .{ .prefix = "Tool result ", .title = "completed" },
        .{ .prefix = "Tool error ", .title = "failed" },
        .{ .prefix = "Gate blocked ", .title = "blocked" },
        .{ .prefix = "Read result ", .title = "completed" },
        .{ .prefix = "Write result ", .title = "completed" },
        .{ .prefix = "Edit result ", .title = "completed" },
    };
    for (prefix_labels) |entry| {
        if (!std.mem.startsWith(u8, split.title, entry.prefix)) continue;
        const remainder = split.title[entry.prefix.len..];
        const tool_name, const inline_summary = splitToolNameAndSummary(remainder);
        const details = splitToolDetails(split.body);
        const body_kind: ToolBodyKind = if (std.mem.eql(u8, tool_name, "bash"))
            if (details.body.len > 0) ToolBodyKind.terminal else .none
        else if (details.body.len > 0)
            ToolBodyKind.text
        else
            .none;
        return .{
            .label = if (tool_name.len > 0) tool_name else "result",
            .title = if (inline_summary.len > 0) inline_summary else entry.title,
            .body = details.body,
            .details = details.details,
            .body_kind = body_kind,
        };
    }
    return .{
        .label = "result",
        .title = split.title,
        .body = split.body,
        .details = "",
        .body_kind = if (split.body.len > 0) .text else .none,
    };
}

const ToolDetailsSplit = struct {
    body: []const u8,
    details: []const u8,
};

fn splitToolDetails(text: []const u8) ToolDetailsSplit {
    const marker = "\nDetails: ";
    if (std.mem.indexOf(u8, text, marker)) |index| {
        return .{
            .body = text[0..index],
            .details = text[index + marker.len ..],
        };
    }
    if (std.mem.startsWith(u8, text, "Details: ")) {
        return .{
            .body = "",
            .details = text["Details: ".len..],
        };
    }
    return .{ .body = text, .details = "" };
}

fn trimBashCommand(title: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, title, "$ "))
        title[2..]
    else
        title;
}

fn splitToolNameAndSummary(remainder: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, remainder, ':')) |colon_index| {
        const tool_name = std.mem.trim(u8, remainder[0..colon_index], " ");
        const summary = std.mem.trim(u8, remainder[colon_index + 1 ..], " ");
        return .{ tool_name, summary };
    }
    return .{ std.mem.trim(u8, remainder, " "), "" };
}

fn looksLikeDiffBody(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "+++ new") != null or
        std.mem.indexOf(u8, text, "@@ edit") != null or
        std.mem.indexOf(u8, text, "--- old") != null;
}

fn countLogicalLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn toolVisualState(kind: ChatKind, text: []const u8) ToolVisualState {
    return switch (kind) {
        .tool_call => .pending,
        .tool_result => if (std.mem.startsWith(u8, text, "Tool error ") or
            std.mem.startsWith(u8, text, "Gate blocked "))
            .@"error"
        else
            .success,
        .bash_execution => if (std.mem.indexOf(u8, text, "Running... (") != null)
            .pending
        else if (std.mem.indexOf(u8, text, "\n(cancelled)") != null or
            std.mem.indexOf(u8, text, "\n(exit ") != null)
            .@"error"
        else
            .success,
        else => .success,
    };
}

fn toolTitleStyle(
    theme: ?*const resources_mod.Theme,
    kind: ChatKind,
    state: ToolVisualState,
) tui.vaxis.Cell.Style {
    var style = switch (state) {
        .pending => styleForToken(theme, .role_tool_call),
        .success => if (kind == .bash_execution) styleForToken(theme, .role_tool_result) else styleForToken(theme, .role_tool_result),
        .@"error" => styleForToken(theme, .@"error"),
    };
    style.bold = true;
    return style;
}

fn toolBodyStyle(
    theme: ?*const resources_mod.Theme,
    kind: ChatKind,
    state: ToolVisualState,
) tui.vaxis.Cell.Style {
    _ = kind;
    return switch (state) {
        .pending => styleForToken(theme, .role_tool_call),
        .success => styleForToken(theme, .role_tool_result),
        .@"error" => styleForToken(theme, .@"error"),
    };
}

fn toolDetailStyle(theme: ?*const resources_mod.Theme, state: ToolVisualState) tui.vaxis.Cell.Style {
    var style = switch (state) {
        .pending => styleForToken(theme, .status),
        .success => styleForToken(theme, .status),
        .@"error" => styleForToken(theme, .@"error"),
    };
    style.dim = true;
    return style;
}

fn diffHeaderStyle(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    var style = styleForToken(theme, .task_header_accent);
    style.bold = true;
    return style;
}

fn diffAddedStyle(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    return styleForToken(theme, .role_tool_result);
}

fn diffRemovedStyle(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    return styleForToken(theme, .@"error");
}

fn diffAddedBackground(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    return .{ .bg = diffAddedStyle(theme).bg };
}

fn diffRemovedBackground(theme: ?*const resources_mod.Theme) tui.vaxis.Cell.Style {
    return .{ .bg = diffRemovedStyle(theme).bg };
}

fn toolStateLabel(kind: ChatKind, state: ToolVisualState) []const u8 {
    return switch (kind) {
        .tool_call => "CALL",
        .tool_result => switch (state) {
            .pending => "waiting",
            .success => "completed",
            .@"error" => "failed",
        },
        .bash_execution => switch (state) {
            .pending => "running",
            .success => "completed",
            .@"error" => "failed",
        },
        else => "OK",
    };
}

const LineSplit = struct {
    title: []const u8,
    body: []const u8,
};

fn splitFirstLine(text: []const u8) LineSplit {
    const newline_index = std.mem.indexOfScalar(u8, text, '\n') orelse return .{
        .title = text,
        .body = "",
    };
    var body = text[newline_index + 1 ..];
    while (body.len > 0 and (body[0] == '\n' or body[0] == '\r')) {
        body = body[1..];
    }
    return .{
        .title = text[0..newline_index],
        .body = body,
    };
}

fn drawCollapseIndicator(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    kind: ChatKind,
    row: usize,
    hidden_rows: usize,
) !void {
    if (row >= window.height) return;
    const label = try actionLabel(allocator, keybindings, .tools_expand, "Ctrl+O");
    const text = try std.fmt.allocPrint(allocator, "… +{d} lines ({s} to expand)", .{ hidden_rows, label });
    _ = window.printSegment(.{
        .text = text,
        .style = collapseIndicatorStyle(theme, kind),
    }, .{
        .wrap = .none,
        .row_offset = @intCast(row),
    });
}

fn collapseIndicatorStyle(
    theme: ?*const resources_mod.Theme,
    kind: ChatKind,
) tui.vaxis.Cell.Style {
    var style = switch (kind) {
        .thinking => styleForToken(theme, .role_thinking),
        .tool_result => styleForToken(theme, .role_tool_result),
        .assistant, .markdown => styleForToken(theme, .markdown_text),
        else => styleForToken(theme, .status),
    };
    style.dim = true;
    if (kind == .assistant or kind == .markdown) {
        style.italic = true;
    }
    return style;
}

fn drawThinkingItem(
    window: tui.vaxis.Window,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
) usize {
    if (window.height == 0 or window.width == 0) return 0;

    const glyph_style = styleForToken(theme, .role_thinking_glyph);
    const text_style = styleForToken(theme, .role_thinking);
    const glyph = thinkingFrameGlyph(item, now_ms);
    window.writeCell(0, 0, .{
        .char = .{ .grapheme = glyph, .width = 1 },
        .style = glyph_style,
    });
    if (window.width > 1) {
        window.writeCell(1, 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = text_style,
        });
    }

    if (window.width <= 2 or item.text.len == 0) return 1;

    const text_window = window.child(.{
        .x_off = 2,
        .width = window.width - 2,
    });
    return @max(@as(usize, 1), drawWrappedText(text_window, 0, item.text, text_style));
}

fn thinkingFrameGlyph(item: ChatItem, now_ms: i64) []const u8 {
    var loader = tui.Loader{};
    loader.setFrameIndex(thinkingFrameIndex(item, now_ms));
    return loader.currentFrame();
}

pub fn thinkingFrameIndex(item: ChatItem, now_ms: i64) usize {
    if (item.frozen_frame_index) |index| return index;
    const start_ms = item.start_ms orelse now_ms;
    const elapsed_i64 = @max(now_ms - start_ms, 0);
    var loader = tui.Loader{};
    return loader.frameIndexForElapsed(@intCast(elapsed_i64));
}

pub fn token(kind: ChatKind) resources_mod.ThemeToken {
    return switch (kind) {
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
    };
}

pub fn estimateRows(items: []const ChatItem, width: usize, all_expanded: bool) usize {
    var rows: usize = 1;
    for (items) |item| {
        rows += estimateItemRowsVisible(item, width, all_expanded);
    }
    return rows;
}

pub fn estimateItemRowsVisible(item: ChatItem, width: usize, all_expanded: bool) usize {
    const full_rows = estimateItemRowsFull(item, width, true);
    if (!all_expanded) {
        if (previewThresholdForItem(item)) |threshold| {
            if (full_rows > threshold) return threshold + 1;
        }
    }
    return estimateItemRowsFull(item, width, all_expanded);
}

fn estimateItemRowsFull(item: ChatItem, width: usize, all_expanded: bool) usize {
    const item_text = displayText(item, all_expanded);
    return switch (item.kind) {
        .assistant => 1 + estimateWrappedRows(item_text, width),
        .markdown => estimateWrappedRows(item_text, width),
        .thinking => if (width <= 2) 1 else @max(@as(usize, 1), estimateWrappedRows(item_text, width - 2)),
        .tool_call, .tool_result, .bash_execution => estimateToolRows(item.kind, item_text, width),
        else => estimateWrappedRows(item_text, width),
    };
}

fn estimateToolRows(kind: ChatKind, text: []const u8, width: usize) usize {
    if (width == 0) return 1;
    const parsed = parseToolItem(kind, text);
    var rows: usize = 1;
    switch (parsed.body_kind) {
        .none => {},
        .text => rows += estimateWrappedRows(parsed.body, @max(width -| 2, 1)),
        .terminal, .diff => rows += countLogicalLines(parsed.body),
    }
    if (parsed.details.len > 0) {
        rows += estimateWrappedRows(parsed.details, @max(width -| 2, 1));
    }
    return @max(rows, 1);
}

fn blitScreenRows(
    source: *tui.vaxis.Screen,
    dest: tui.vaxis.Window,
    source_start_row: usize,
    height: usize,
) void {
    const rows = @min(height, @as(usize, dest.height));
    const cols = @min(@as(usize, source.width), @as(usize, dest.width));
    for (0..rows) |row| {
        for (0..cols) |col| {
            const cell = source.readCell(@intCast(col), @intCast(source_start_row + row)) orelse continue;
            dest.writeCell(@intCast(col), @intCast(row), normalizeCellForBlit(cell));
        }
    }
}

fn normalizeCellForBlit(cell: tui.vaxis.Cell) tui.vaxis.Cell {
    if (cell.char.grapheme.len != 0) return cell;
    var normalized = cell;
    normalized.char = .{ .grapheme = " ", .width = 1 };
    return normalized;
}

fn blitScreenRowsWithSelection(
    source: *tui.vaxis.Screen,
    dest: tui.vaxis.Window,
    source_start_row: usize,
    height: usize,
    selection: SelectionRange,
    dest_abs_row_start: usize,
) void {
    const rows = @min(height, @as(usize, dest.height));
    const cols = @min(@as(usize, source.width), @as(usize, dest.width));
    for (0..rows) |row| {
        const abs_row = source_start_row + row;
        for (0..cols) |col| {
            var cell = source.readCell(@intCast(col), @intCast(abs_row)) orelse continue;
            cell = normalizeCellForBlit(cell);
            const dest_abs_row = dest_abs_row_start + row;
            if (isCellSelected(dest_abs_row, col, selection)) {
                const fg = cell.style.fg;
                cell.style.fg = switch (cell.style.bg) {
                    .default => .{ .rgb = .{ 200, 200, 200 } },
                    else => cell.style.bg,
                };
                cell.style.bg = switch (fg) {
                    .default => .{ .rgb = .{ 50, 50, 50 } },
                    else => fg,
                };
            }
            dest.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
}

fn extractSelectedTextFromItems(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    layout: Layout,
    width: usize,
    now_ms: i64,
    all_expanded: bool,
    selection: SelectionRange,
    output: *std.ArrayList(u8),
) !void {
    // Find all items that overlap the selection range (not just the visible viewport).
    var item_row: usize = 0;
    for (items, 0..) |item, item_index| {
        const entry_rows = if (item_index < layout.entries.items.len) layout.entries.items[item_index].rows else estimateItemRowsVisible(item, width, all_expanded);
        const item_end = item_row + entry_rows;

        // Skip items entirely above or below the selection.
        if (item_end <= selection.start_row) {
            item_row = item_end;
            continue;
        }
        if (item_row > selection.end_row) break;

        // Use a generous scratch screen size for text extraction.
        // estimateItemRowsFull underestimates markdown content (code blocks, headings, etc.),
        // so the scratch screen needs extra room to avoid truncation.
        const item_text = displayText(item, all_expanded);
        const source_lines = countNewlines(item_text) + 1;
        const generous_rows = @max(entry_rows, source_lines * 2 + 8);
        var item_scratch = try tui.vaxis.Screen.init(allocator, .{
            .rows = @intCast(@min(generous_rows, @as(usize, std.math.maxInt(u16)))),
            .cols = @intCast(@min(width, @as(usize, std.math.maxInt(u16)))),
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer item_scratch.deinit(allocator);

        const item_window = tui.draw.rootWindow(&item_scratch);
        item_window.clear();
        _ = try drawItem(item_window, allocator, keybindings, theme, item, 0, now_ms, all_expanded);

        // Extract selected rows from this item's scratch screen.
        const sel_start_in_item = if (selection.start_row > item_row) selection.start_row - item_row else 0;
        const sel_end_in_item = if (selection.end_row < item_end) selection.end_row - item_row + 1 else entry_rows;
        const cols = @min(@as(usize, item_scratch.width), @as(usize, width));
        var trailing_space: usize = 0;
        var skip_next: bool = false;
        for (sel_start_in_item..sel_end_in_item) |local_row| {
            if (local_row >= @as(usize, item_scratch.height)) break;
            const abs_row = item_row + local_row;
            const col_start: usize = if (abs_row == selection.start_row) selection.start_col else 0;
            const col_end: usize = if (abs_row == selection.end_row) @min(selection.end_col, cols) else cols;
            for (col_start..col_end) |col| {
                const cell = item_scratch.readCell(@intCast(col), @intCast(local_row)) orelse continue;
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                const grapheme = cell.char.grapheme;
                if (cell.char.width > 1) {
                    for (0..trailing_space) |_| try output.append(allocator, ' ');
                    trailing_space = 0;
                    try output.appendSlice(allocator, grapheme);
                    skip_next = true;
                } else if (grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ')) {
                    trailing_space += 1;
                } else {
                    for (0..trailing_space) |_| try output.append(allocator, ' ');
                    trailing_space = 0;
                    try output.appendSlice(allocator, grapheme);
                }
            }
            if (abs_row < selection.end_row) {
                try output.append(allocator, '\n');
                trailing_space = 0;
            }
        }
        item_row = item_end;
    }
}

fn isCellSelected(row: usize, col: usize, sel: SelectionRange) bool {
    if (row < sel.start_row or row > sel.end_row) return false;
    if (row == sel.start_row and row == sel.end_row) return col >= sel.start_col and col < sel.end_col;
    if (row == sel.start_row) return col >= sel.start_col;
    if (row == sel.end_row) return col < sel.end_col;
    return true;
}

fn extractSelectedText(
    allocator: std.mem.Allocator,
    source: *tui.vaxis.Screen,
    source_start_row: usize,
    visible_height: usize,
    selection: SelectionRange,
    output: *std.ArrayList(u8),
) !void {
    const cols = source.width;
    const rows = @min(visible_height, @as(usize, source.height));
    for (0..rows) |row| {
        const abs_row = source_start_row + row;
        if (abs_row < selection.start_row or abs_row > selection.end_row) continue;
        const col_start: usize = if (abs_row == selection.start_row) selection.start_col else 0;
        const col_end: usize = if (abs_row == selection.end_row) @min(selection.end_col, @as(usize, cols)) else @as(usize, cols);
        var trailing_space: usize = 0;
        var skip_next: bool = false;
        for (col_start..col_end) |col| {
            const cell = source.readCell(@intCast(col), @intCast(abs_row)) orelse continue;
            if (skip_next) {
                skip_next = false;
                continue;
            }
            const grapheme = cell.char.grapheme;
            if (cell.char.width > 1) {
                for (0..trailing_space) |_| try output.append(allocator, ' ');
                trailing_space = 0;
                try output.appendSlice(allocator, grapheme);
                skip_next = true;
            } else if (grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ')) {
                trailing_space += 1;
            } else {
                for (0..trailing_space) |_| try output.append(allocator, ' ');
                trailing_space = 0;
                try output.appendSlice(allocator, grapheme);
            }
        }
        if (abs_row < selection.end_row) try output.append(allocator, '\n');
    }
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

pub fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
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

fn styleForToken(theme: ?*const resources_mod.Theme, theme_token: resources_mod.ThemeToken) tui.vaxis.Cell.Style {
    return if (theme) |active_theme| tui.styleFor(active_theme, theme_token) else .{};
}

fn actionLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    fallback: []const u8,
) ![]u8 {
    const active = keybindings orelse return allocator.dupe(u8, fallback);
    return active.primaryLabel(allocator, action) catch allocator.dupe(u8, fallback);
}
