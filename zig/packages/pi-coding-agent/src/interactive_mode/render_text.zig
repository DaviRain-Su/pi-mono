const std = @import("std");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");
const resources_mod = @import("../resources/resources.zig");

pub const INPUT_PROMPT_PREFIX = "> ";
pub const COMPACT_INPUT_PROMPT_PREFIX = "Input: ";
pub const TOP_PANEL_HEIGHT: usize = 3;
pub const COLLAPSED_TOP_PANEL_HEIGHT: usize = 1;
pub const PROMPT_BOX_HEIGHT: usize = 3;
pub const PROMPT_BORDER_TOP_ROWS: usize = 1;
pub const PROMPT_GLYPH_WIDTH: usize = 2;
pub const PROMPT_EDITOR_WIDTH_OVERHEAD: usize = 4;

pub const LayoutMode = enum {
    full,
    medium,
    narrow,
    mini,
    compact,
};

pub fn layoutMode(width: usize) LayoutMode {
    if (width >= 100) return .full;
    if (width >= 80) return .medium;
    if (width >= 60) return .narrow;
    if (width >= 40) return .mini;
    return .compact;
}

pub fn taskPanelHeightForWidth(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium => TOP_PANEL_HEIGHT,
        .narrow => COLLAPSED_TOP_PANEL_HEIGHT,
        .mini, .compact => 0,
    };
}

pub fn hintsHeightForWidth(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => 1,
        .mini, .compact => 0,
    };
}

pub fn promptPrefixForWidth(width: usize) []const u8 {
    return switch (layoutMode(width)) {
        .compact => COMPACT_INPUT_PROMPT_PREFIX,
        else => INPUT_PROMPT_PREFIX,
    };
}

pub fn promptEditorWidth(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => @max(@as(usize, 1), width -| PROMPT_EDITOR_WIDTH_OVERHEAD),
        .mini => @max(@as(usize, 1), width -| PROMPT_GLYPH_WIDTH),
        .compact => @max(@as(usize, 1), width -| tui.ansi.visibleWidth(COMPACT_INPUT_PROMPT_PREFIX)),
    };
}

pub fn promptEditorOffsetX(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => @min(width, PROMPT_BORDER_TOP_ROWS + PROMPT_GLYPH_WIDTH),
        .mini => @min(width, PROMPT_GLYPH_WIDTH),
        .compact => @min(width, tui.ansi.visibleWidth(COMPACT_INPUT_PROMPT_PREFIX)),
    };
}

pub fn promptEditorOffsetY(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => PROMPT_BORDER_TOP_ROWS,
        .mini, .compact => 0,
    };
}

pub fn formatFooterLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: anytype,
    width: usize,
) ![]u8 {
    const fitted = try formatFooterText(allocator, snapshot, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn formatFooterLineWithTerminal(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: anytype,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    const fitted = try formatFooterTextWithTerminal(allocator, snapshot, terminal_name, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn formatTaskHeaderText(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    width: usize,
) ![]u8 {
    return formatTaskHeaderTextForMode(allocator, snapshot, width, layoutMode(width));
}

pub fn formatTaskHeaderTextForMode(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    width: usize,
    mode: LayoutMode,
) ![]u8 {
    const session_label = nonEmptyOr(snapshot.session_label, "(unsaved)");
    const status_label = nonEmptyOr(snapshot.status, "idle");
    const model_label = nonEmptyOr(snapshot.model_label, "unknown");
    const provider_label = nonEmptyOr(snapshot.provider_label, "unknown");

    const title = try std.fmt.allocPrint(allocator, "pi · {s}", .{session_label});
    defer allocator.free(title);

    const single_line_status = try sanitizeSingleLineStatusAlloc(allocator, status_label);
    defer allocator.free(single_line_status);
    if (mode == .narrow) return try fitLine(allocator, title, width);

    const meta = switch (mode) {
        .full => try std.fmt.allocPrint(
            allocator,
            "Status: {s} · Model: {s} · Provider: {s}",
            .{ single_line_status, model_label, provider_label },
        ),
        .medium => try std.fmt.allocPrint(
            allocator,
            "Status: {s} · Model: {s}",
            .{ single_line_status, model_label },
        ),
        else => try std.fmt.allocPrint(
            allocator,
            "Status: {s} · Model: {s}",
            .{ single_line_status, model_label },
        ),
    };
    defer allocator.free(meta);

    const title_width = tui.ansi.visibleWidth(title);
    const meta_width = tui.ansi.visibleWidth(meta);
    if (width > 0 and title_width + 1 + meta_width <= width) {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        try builder.appendSlice(allocator, title);
        const padding = width - title_width - meta_width;
        try builder.appendNTimes(allocator, ' ', padding);
        try builder.appendSlice(allocator, meta);
        return builder.toOwnedSlice(allocator);
    }

    const combined = try std.fmt.allocPrint(allocator, "{s} · {s}", .{ title, meta });
    defer allocator.free(combined);
    return try fitLine(allocator, combined, width);
}

fn nonEmptyOr(value: ?[]const u8, fallback: []const u8) []const u8 {
    const text = value orelse return fallback;
    return if (text.len > 0) text else fallback;
}

fn fieldText(snapshot: anytype, comptime field_name: []const u8) ?[]const u8 {
    const Snapshot = @typeInfo(@TypeOf(snapshot)).pointer.child;
    if (!@hasField(Snapshot, field_name)) return null;
    const value = @field(snapshot, field_name);
    if (@TypeOf(value) == ?[]u8 or @TypeOf(value) == ?[]const u8) return value;
    return if (value.len > 0) value else null;
}

pub fn formatFooterText(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    width: usize,
) ![]u8 {
    switch (layoutMode(width)) {
        .mini => return formatMiniFooterText(allocator, snapshot, width),
        .compact => return formatCompactFooterText(allocator, snapshot, width),
        else => {},
    }

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var needs_separator = false;
    if (fieldText(snapshot, "git_branch")) |git_branch| {
        if (git_branch.len > 0) {
            const branch_text = try std.fmt.allocPrint(allocator, "Branch: {s}", .{git_branch});
            defer allocator.free(branch_text);
            try appendFooterPart(allocator, &builder, &needs_separator, branch_text);
        }
    }
    const compact_session_label = try truncateVisibleTextAlloc(allocator, nonEmptyOr(fieldText(snapshot, "session_label"), "new"), 16);
    defer allocator.free(compact_session_label);
    const session_text = try std.fmt.allocPrint(allocator, "Session: {s}", .{compact_session_label});
    defer allocator.free(session_text);
    try appendFooterPart(allocator, &builder, &needs_separator, session_text);

    if (snapshot.queued_steering.len > 0 or snapshot.queued_follow_up.len > 0) {
        const queue_text = try formatQueueSummary(allocator, snapshot.queued_steering.len, snapshot.queued_follow_up.len);
        defer allocator.free(queue_text);
        try appendFooterPart(allocator, &builder, &needs_separator, queue_text);
    }

    if (snapshot.usage_totals.input > 0) {
        const input_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.input);
        defer allocator.free(input_text);
        const input_part = try std.fmt.allocPrint(allocator, "↑{s}", .{input_text});
        defer allocator.free(input_part);
        try appendFooterPart(allocator, &builder, &needs_separator, input_part);
    }
    if (snapshot.usage_totals.output > 0) {
        const output_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.output);
        defer allocator.free(output_text);
        const output_part = try std.fmt.allocPrint(allocator, "↓{s}", .{output_text});
        defer allocator.free(output_part);
        try appendFooterPart(allocator, &builder, &needs_separator, output_part);
    }

    if (snapshot.usage_totals.cache_read > 0) {
        const cache_read_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.cache_read);
        defer allocator.free(cache_read_text);
        const cache_read_part = try std.fmt.allocPrint(allocator, "R{s}", .{cache_read_text});
        defer allocator.free(cache_read_part);
        try appendFooterPart(allocator, &builder, &needs_separator, cache_read_part);
    }
    if (snapshot.usage_totals.cache_write > 0) {
        const cache_write_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.cache_write);
        defer allocator.free(cache_write_text);
        const cache_write_part = try std.fmt.allocPrint(allocator, "W{s}", .{cache_write_text});
        defer allocator.free(cache_write_part);
        try appendFooterPart(allocator, &builder, &needs_separator, cache_write_part);
    }
    if (snapshot.usage_totals.cost > 0) {
        const cost_text = try std.fmt.allocPrint(allocator, "${d:.3}", .{snapshot.usage_totals.cost});
        defer allocator.free(cost_text);
        try appendFooterPart(allocator, &builder, &needs_separator, cost_text);
    }
    const has_usage_totals = snapshot.usage_totals.input > 0 or
        snapshot.usage_totals.output > 0 or
        snapshot.usage_totals.cache_read > 0 or
        snapshot.usage_totals.cache_write > 0 or
        snapshot.usage_totals.cost > 0;
    const show_context = snapshot.context_window > 0 and (has_usage_totals or snapshot.context_percent == null or snapshot.context_percent.? > 0.0);
    if (show_context) {
        const window_text = try formatCompactTokenCount(allocator, snapshot.context_window);
        defer allocator.free(window_text);
        const context_text = if (snapshot.context_percent) |percent|
            try std.fmt.allocPrint(allocator, "ctx {d:.1}%/{s}", .{ percent, window_text })
        else
            try std.fmt.allocPrint(allocator, "ctx ?/{s}", .{window_text});
        defer allocator.free(context_text);
        try appendFooterPart(allocator, &builder, &needs_separator, context_text);
    }

    const Snapshot = @typeInfo(@TypeOf(snapshot)).pointer.child;
    if (@hasField(Snapshot, "extension_footer_statuses")) {
        for (@field(snapshot, "extension_footer_statuses")) |status| {
            if (status.len > 0) {
                try appendFooterPart(allocator, &builder, &needs_separator, status);
            }
        }
    }

    return try fitLine(allocator, builder.items, width);
}

fn formatMiniFooterText(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    width: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var needs_separator = false;
    const model_label = nonEmptyOr(fieldText(snapshot, "model_label"), "unknown");
    const model_text = try std.fmt.allocPrint(allocator, "Model: {s}", .{model_label});
    defer allocator.free(model_text);
    try appendFooterPart(allocator, &builder, &needs_separator, model_text);

    if (snapshot.context_window > 0) {
        const window_text = try formatCompactTokenCount(allocator, snapshot.context_window);
        defer allocator.free(window_text);
        const context_text = if (snapshot.context_percent) |percent|
            try std.fmt.allocPrint(allocator, "ctx {d:.1}%/{s}", .{ percent, window_text })
        else
            try std.fmt.allocPrint(allocator, "ctx ?/{s}", .{window_text});
        defer allocator.free(context_text);
        try appendFooterPart(allocator, &builder, &needs_separator, context_text);
    }

    return try fitLine(allocator, builder.items, width);
}

fn formatCompactFooterText(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    width: usize,
) ![]u8 {
    const status_label = nonEmptyOr(fieldText(snapshot, "status"), "idle");
    const single_line_status = try sanitizeSingleLineStatusAlloc(allocator, status_label);
    defer allocator.free(single_line_status);
    const status_text = try std.fmt.allocPrint(allocator, "Status: {s}", .{single_line_status});
    defer allocator.free(status_text);
    return try fitLine(allocator, status_text, width);
}

pub fn formatFooterTextWithTerminal(
    allocator: std.mem.Allocator,
    snapshot: anytype,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (layoutMode(width) == .mini or layoutMode(width) == .compact) {
        return formatFooterText(allocator, snapshot, width);
    }

    const badge = try formatTerminalBadge(allocator, terminal_name);
    defer allocator.free(badge);
    const badge_width = tui.ansi.visibleWidth(badge);
    if (badge_width == 0 or width <= badge_width + 1) {
        return formatFooterText(allocator, snapshot, width);
    }

    const footer_width = width - badge_width - 1;
    const footer_text = try formatFooterText(allocator, snapshot, footer_width);
    defer allocator.free(footer_text);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, footer_text);
    const current_width = tui.ansi.visibleWidth(builder.items);
    if (width > current_width + badge_width) {
        try builder.appendNTimes(allocator, ' ', width - current_width - badge_width);
    }
    try builder.appendSlice(allocator, badge);
    return builder.toOwnedSlice(allocator);
}

pub fn formatTerminalBadge(allocator: std.mem.Allocator, terminal_name: []const u8) ![]u8 {
    const source = if (terminal_name.len > 0) terminal_name else "term";
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    for (source) |byte| {
        try builder.append(allocator, std.ascii.toUpper(byte));
    }
    return builder.toOwnedSlice(allocator);
}

pub fn appendFooterPart(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    needs_separator: *bool,
    text: []const u8,
) std.mem.Allocator.Error!void {
    if (needs_separator.*) try builder.appendSlice(allocator, " • ");
    try builder.appendSlice(allocator, text);
    needs_separator.* = true;
}

fn formatQueueSummary(allocator: std.mem.Allocator, steering_count: usize, follow_up_count: usize) ![]u8 {
    if (steering_count > 0 and follow_up_count > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Queue: {d} steering, {d} follow-up",
            .{ steering_count, follow_up_count },
        );
    }
    if (steering_count > 0) {
        return std.fmt.allocPrint(allocator, "Queue: {d} steering", .{steering_count});
    }
    return std.fmt.allocPrint(allocator, "Queue: {d} follow-up", .{follow_up_count});
}

pub fn formatCompactTokenCount(allocator: std.mem.Allocator, count: u64) ![]u8 {
    if (count < 1_000) return std.fmt.allocPrint(allocator, "{d}", .{count});
    if (count < 10_000) {
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}k",
            .{ count / 1_000, (count % 1_000) / 100 },
        );
    }
    if (count < 1_000_000) return std.fmt.allocPrint(allocator, "{d}k", .{(count + 500) / 1_000});
    if (count < 10_000_000) {
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}M",
            .{ count / 1_000_000, (count % 1_000_000) / 100_000 },
        );
    }
    return std.fmt.allocPrint(allocator, "{d}M", .{(count + 500_000) / 1_000_000});
}

pub fn formatHintsLine(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    width: usize,
) ![]u8 {
    const fitted = try formatHintsText(allocator, keybindings, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .prompt, fitted);
}

pub fn formatHintsText(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    width: usize,
) ![]u8 {
    if (hintsHeightForWidth(width) == 0) return allocator.dupe(u8, "");

    const open_sessions = try actionLabel(allocator, keybindings, .session_resume, "Unbound");
    defer allocator.free(open_sessions);
    const open_models = try actionLabel(allocator, keybindings, .model_select, "Ctrl+L");
    defer allocator.free(open_models);
    const queue_label = try actionLabel(allocator, keybindings, .message_followUp, "Alt+Enter");
    defer allocator.free(queue_label);
    const queue_follow_up = try hintKeyLabel(allocator, queue_label);
    defer allocator.free(queue_follow_up);
    const dequeue_label = try actionLabel(allocator, keybindings, .message_dequeue, "Alt+Up");
    defer allocator.free(dequeue_label);
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Esc");
    defer allocator.free(interrupt);
    const clear = try actionLabel(allocator, keybindings, .clear, "Ctrl+C");
    defer allocator.free(clear);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);
    const suspend_label = try actionLabel(allocator, keybindings, .app_suspend, "Ctrl+Z");
    defer allocator.free(suspend_label);

    const line = switch (layoutMode(width)) {
        .full => try std.fmt.allocPrint(
            allocator,
            "⏎ send · {s} follow-up · {s} dequeue · {s} sessions · {s} models · {s} interrupt · {s}/{s} clear/exit · {s} suspend",
            .{ queue_follow_up, dequeue_label, open_sessions, open_models, interrupt, clear, exit, suspend_label },
        ),
        .medium => try std.fmt.allocPrint(
            allocator,
            "⏎ send · {s} queue · {s} dequeue · {s} sessions · {s} models",
            .{ queue_follow_up, dequeue_label, open_sessions, open_models },
        ),
        .narrow => try std.fmt.allocPrint(
            allocator,
            "⏎ send · {s} sessions · {s} models",
            .{ open_sessions, open_models },
        ),
        .mini, .compact => try allocator.dupe(u8, ""),
    };
    defer allocator.free(line);
    return try fitLine(allocator, line, width);
}

fn hintKeyLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    if (std.mem.eql(u8, label, "Enter")) return allocator.dupe(u8, "⏎");
    if (std.mem.eql(u8, label, "Alt+Enter")) return allocator.dupe(u8, "Alt+⏎");
    if (std.mem.eql(u8, label, "Option+Enter")) return allocator.dupe(u8, "Option+⏎");
    return allocator.dupe(u8, label);
}

pub fn actionLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    fallback: []const u8,
) ![]u8 {
    if (keybindings) |bindings| {
        return bindings.primaryLabel(allocator, action);
    }
    return allocator.dupe(u8, fallback);
}

pub fn applyThemeAlloc(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    text: []const u8,
) ![]u8 {
    if (theme) |selected_theme| {
        return selected_theme.applyAlloc(allocator, token, text);
    }
    return allocator.dupe(u8, text);
}

pub fn fitLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (tui.ansi.visibleWidth(text) <= width) return tui.ansi.padRightVisibleAlloc(allocator, text, width);

    const limit = if (width > 1) width - 1 else 0;
    const prefix = try tui.ansi.sliceVisibleAlloc(allocator, text, 0, limit);
    defer allocator.free(prefix);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, prefix);
    if (width > 0) try builder.append(allocator, '.');

    const fitted = try tui.ansi.padRightVisibleAlloc(allocator, builder.items, width);
    builder.deinit(allocator);
    return fitted;
}

fn sanitizeSingleLineStatusAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var previous_was_space = false;
    for (text) |char| {
        const is_whitespace = char == '\n' or char == '\r' or char == '\t';
        if (is_whitespace) {
            if (!previous_was_space) {
                try builder.append(allocator, ' ');
                previous_was_space = true;
            }
            continue;
        }
        try builder.append(allocator, char);
        previous_was_space = char == ' ';
    }

    if (builder.items.len > 0 and builder.items[builder.items.len - 1] == ' ') {
        _ = builder.pop();
    }
    return builder.toOwnedSlice(allocator);
}

fn truncateVisibleTextAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    if (tui.ansi.visibleWidth(text) <= max_width) return allocator.dupe(u8, text);

    const limit = if (max_width > 1) max_width - 1 else 0;
    const prefix = try tui.ansi.sliceVisibleAlloc(allocator, text, 0, limit);
    defer allocator.free(prefix);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, prefix);
    if (max_width > 0) try builder.append(allocator, '.');
    return builder.toOwnedSlice(allocator);
}
