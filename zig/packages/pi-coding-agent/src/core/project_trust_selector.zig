const std = @import("std");
const tui = @import("tui");
const project_trust = @import("project_trust.zig");
const missing_cwd_selector = @import("../sessions/missing_cwd_selector.zig");

pub const SelectorTitle = "Project trust";
pub const SelectorHint = "Up/Down move • Enter select • Esc cancel";

const SelectorOutcome = union(enum) {
    pending,
    confirmed: usize,
    cancelled,
};

pub fn formatBody(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return project_trust.formatProjectTrustPrompt(allocator, cwd);
}

pub fn buildSelectItems(
    allocator: std.mem.Allocator,
    options: []const project_trust.ProjectTrustOption,
) ![]tui.SelectItem {
    const items = try allocator.alloc(tui.SelectItem, options.len);
    errdefer allocator.free(items);

    var made: usize = 0;
    errdefer {
        for (items[0..made]) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
        }
    }

    for (options) |option| {
        const value_buf = try allocator.dupe(u8, option.label);
        errdefer allocator.free(value_buf);
        const label_buf = try allocator.dupe(u8, option.label);
        items[made] = .{ .value = value_buf, .label = label_buf };
        made += 1;
    }
    return items;
}

pub fn freeSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.value));
        allocator.free(@constCast(item.label));
    }
    allocator.free(items);
}

pub fn handleSelectorKey(list: *tui.SelectList, key: tui.Key) SelectorOutcome {
    return switch (list.handleKey(key)) {
        .handled, .ignored => .pending,
        .dismissed => .cancelled,
        .confirmed => |index| .{ .confirmed = index },
    };
}

/// One-shot TUI prompt used before runtime load. Returns the selected option
/// index, or null when the user cancels (Escape / Ctrl+C).
pub fn promptProjectTrustIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: []const project_trust.ProjectTrustOption,
) !?usize {
    const body = try formatBody(allocator, cwd);
    defer allocator.free(body);

    const items = try buildSelectItems(allocator, options);
    defer freeSelectItems(allocator, items);

    var list: tui.SelectList = .{ .items = items, .max_visible = options.len };

    var terminal = tui.Terminal.initNative(.{ .io = io, .env_map = env_map });
    try terminal.start();
    defer terminal.stop();

    var input_loop = try terminal.initInputLoop(allocator, io, env_map);
    defer input_loop.deinit();
    input_loop.vaxis_state.queryTerminal(input_loop.loop.tty.writer(), .fromMilliseconds(250)) catch {};

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    var screen = missing_cwd_selector.MissingCwdScreen{
        .title = SelectorTitle,
        .body = body,
        .hint = SelectorHint,
        .list = &list,
    };

    while (true) {
        const size = try terminal.refreshSize();
        screen.height = size.height;
        try renderer.renderToVaxis(
            screen.drawComponent(),
            input_loop.vaxis_state,
            input_loop.loop.tty.writer(),
        );

        var handled_input = false;
        while (try input_loop.tryInputEvent()) |event| {
            defer event.deinit(allocator);
            handled_input = true;
            switch (event.parsed.event) {
                .key => |key| {
                    switch (handleSelectorKey(&list, key)) {
                        .pending => {},
                        .confirmed => |index| return index,
                        .cancelled => return null,
                    }
                },
                else => {},
            }
        }

        if (!handled_input) {
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        }
    }
}

/// Prompts when needed and persists any store updates. Returns the session
/// trust decision. Cancel / no selection is treated as untrusted.
pub fn promptAndApplyProjectTrust(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
) !bool {
    const options = try project_trust.getProjectTrustOptions(allocator, cwd, true);
    defer project_trust.deinitProjectTrustOptions(allocator, options);
    const index = try promptProjectTrustIndex(allocator, io, env_map, cwd, options) orelse return false;
    if (index >= options.len) return false;
    const selected = options[index];
    if (selected.updates.len > 0) {
        const store = project_trust.ProjectTrustStore.init(allocator, io, agent_dir);
        try store.setMany(selected.updates);
    }
    return selected.trusted;
}

test "buildSelectItems mirrors getProjectTrustOptions labels" {
    const allocator = std.testing.allocator;
    const options = try project_trust.getProjectTrustOptions(allocator, "/parent/project", true);
    defer project_trust.deinitProjectTrustOptions(allocator, options);
    const items = try buildSelectItems(allocator, options);
    defer freeSelectItems(allocator, items);
    try std.testing.expectEqual(options.len, items.len);
    try std.testing.expectEqualStrings(options[0].label, items[0].label);
    try std.testing.expectEqualStrings(options[2].label, items[2].label);
}

test "handleSelectorKey confirms the highlighted option" {
    const allocator = std.testing.allocator;
    const options = try project_trust.getProjectTrustOptions(allocator, "/parent/project", false);
    defer project_trust.deinitProjectTrustOptions(allocator, options);
    const items = try buildSelectItems(allocator, options);
    defer freeSelectItems(allocator, items);
    var list: tui.SelectList = .{ .items = items, .max_visible = items.len };
    const confirmed = handleSelectorKey(&list, .enter);
    try std.testing.expectEqual(@as(usize, 0), confirmed.confirmed);
    const cancelled = handleSelectorKey(&list, .escape);
    try std.testing.expect(cancelled == .cancelled);
}
