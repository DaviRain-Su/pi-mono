const std = @import("std");
const tui = @import("tui");
const session_cwd = @import("session_cwd.zig");

/// User decision returned by the missing-cwd TUI selector. Mirrors the
/// TypeScript ExtensionSelectorComponent options ["Continue", "Cancel"]
/// used in `promptForMissingSessionCwd` and `promptForMissingSessionCwd`
/// inside the interactive mode.
pub const MissingCwdChoice = enum {
    continue_in_fallback,
    cancel,
};

pub const MissingCwdItems = struct {
    pub const continue_label = "Continue";
    pub const cancel_label = "Cancel";

    /// Resolves a selected `SelectList` index back to a `MissingCwdChoice`.
    pub fn choiceFromIndex(index: usize) MissingCwdChoice {
        return if (index == 0) .continue_in_fallback else .cancel;
    }
};

pub const SelectorTitle = "Session cwd not found";
pub const SelectorHint = "Up/Down move • Enter select • Esc cancel";

/// Build the text body shown above the Continue/Cancel options. The body is
/// the same string that `formatMissingSessionCwdPrompt` produces so that
/// snapshot/tuistory tests can match it exactly.
pub fn formatBody(
    allocator: std.mem.Allocator,
    issue: session_cwd.MissingSessionCwdIssue,
) ![]u8 {
    return session_cwd.formatMissingSessionCwdPrompt(allocator, issue);
}

/// Build the two `SelectItem`s for the Continue/Cancel selector. Caller owns
/// the returned slice and is responsible for freeing each item's `value` and
/// `label` and the slice itself.
///
/// On any partial-allocation failure all previously-allocated bytes are
/// freed exactly once. Tracked via the `made` counter so error cleanup never
/// double-frees an item that was already adopted into `items`.
pub fn buildSelectItems(allocator: std.mem.Allocator) ![]tui.SelectItem {
    var items = try allocator.alloc(tui.SelectItem, 2);
    errdefer allocator.free(items);

    var made: usize = 0;
    errdefer freePartialSelectItems(allocator, items[0..made]);

    try appendSelectItem(allocator, items, &made, MissingCwdItems.continue_label);
    try appendSelectItem(allocator, items, &made, MissingCwdItems.cancel_label);

    return items;
}

/// Allocates a paired value/label for a single `SelectItem` and writes it
/// into `items[*made]`, advancing `made` only after both allocations succeed
/// and the item is fully owned by the slice. Any allocation failure inside
/// this helper is unwound locally so the caller's `errdefer
/// freePartialSelectItems` only frees fully-adopted items.
fn appendSelectItem(
    allocator: std.mem.Allocator,
    items: []tui.SelectItem,
    made: *usize,
    label: []const u8,
) !void {
    const value_buf = try allocator.dupe(u8, label);
    errdefer allocator.free(value_buf);
    const label_buf = try allocator.dupe(u8, label);
    items[made.*] = .{ .value = value_buf, .label = label_buf };
    made.* += 1;
}

/// Frees `items[0..made]` when partial-allocation cleanup runs. Mirrors the
/// `freeSelectItems` shape but only walks the prefix that was successfully
/// adopted into the slice.
fn freePartialSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.value));
        allocator.free(@constCast(item.label));
    }
}

/// Frees an array previously produced by `buildSelectItems`.
pub fn freeSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.value));
        allocator.free(@constCast(item.label));
    }
    allocator.free(items);
}

/// Drives a one-shot TUI Continue/Cancel selector for a missing stored cwd.
/// Returns `.continue_in_fallback` when the user confirms the launch cwd as
/// the fallback, `.cancel` otherwise (Escape, Ctrl+C, or selecting Cancel).
///
/// This function takes ownership of starting/stopping the terminal and
/// vaxis input loop so callers can invoke it before the main interactive
/// mode initializes.
pub fn runMissingCwdSelector(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    issue: session_cwd.MissingSessionCwdIssue,
) !MissingCwdChoice {
    const body = try formatBody(allocator, issue);
    defer allocator.free(body);

    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);

    var list: tui.SelectList = .{ .items = items, .max_visible = 2 };

    var terminal = tui.Terminal.initNative(.{ .io = io, .env_map = env_map });
    try terminal.start();
    defer terminal.stop();

    var input_loop = try terminal.initInputLoop(allocator, io, env_map);
    defer input_loop.deinit();
    input_loop.vaxis_state.queryTerminal(input_loop.loop.tty.writer(), .fromMilliseconds(250)) catch {};

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    var screen = MissingCwdScreen{
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
                        .confirmed => |index| return MissingCwdItems.choiceFromIndex(index),
                        .cancelled => return .cancel,
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

const SelectorOutcome = union(enum) {
    pending,
    confirmed: usize,
    cancelled,
};

/// Translates a key event into a selector outcome. Pulled out so unit tests
/// can exercise the key contract without spinning up a real terminal.
pub fn handleSelectorKey(list: *tui.SelectList, key: tui.Key) SelectorOutcome {
    switch (list.handleKey(key)) {
        .handled => return .pending,
        .ignored => return .pending,
        .dismissed => return .cancelled,
        .confirmed => |index| {
            const choice = MissingCwdItems.choiceFromIndex(index);
            return switch (choice) {
                .continue_in_fallback => .{ .confirmed = index },
                .cancel => .cancelled,
            };
        },
    }
}

/// Minimal screen component that renders the selector centered on the
/// terminal. Vendored locally instead of reusing the larger
/// `OverlayPanelComponent` because the missing-cwd prompt runs before the
/// rest of the interactive mode and does not require chat/footer layout.
pub const MissingCwdScreen = struct {
    title: []const u8,
    body: []const u8,
    hint: []const u8,
    list: *tui.SelectList,
    height: usize = 24,
    theme: ?*const tui.Theme = null,

    pub fn drawComponent(self: *const MissingCwdScreen) tui.DrawComponent {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const MissingCwdScreen = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    pub fn draw(
        self: *const MissingCwdScreen,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        window.clear();
        if (window.width < 2 or window.height < 4) {
            return .{ .width = window.width, .height = window.height };
        }

        var row: u16 = 0;
        row = drawWrappedLine(window, row, self.title);
        row = drawWrappedLines(window, row, self.body);
        row += 1;
        row = drawWrappedLine(window, row, self.hint);

        if (row < window.height) {
            const list_window = window.child(.{
                .y_off = row,
                .height = window.height -| row,
            });
            const list_size = try self.list.draw(list_window, .{
                .window = list_window,
                .arena = ctx.arena,
            });
            row += list_size.height;
        }

        return .{ .width = window.width, .height = row };
    }
};

fn drawWrappedLine(window: tui.vaxis.Window, row: u16, text: []const u8) u16 {
    if (row >= window.height) return row;
    const line_window = window.child(.{ .y_off = row, .height = 1 });
    _ = line_window.printSegment(.{ .text = text }, .{ .wrap = .none });
    return row + 1;
}

fn drawWrappedLines(window: tui.vaxis.Window, row_in: u16, text: []const u8) u16 {
    var row: u16 = row_in;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |chunk| {
        if (row >= window.height) return row;
        const line_window = window.child(.{ .y_off = row, .height = 1 });
        _ = line_window.printSegment(.{ .text = chunk }, .{ .wrap = .none });
        row += 1;
    }
    return row;
}

test "buildSelectItems exposes Continue and Cancel options" {
    const allocator = std.testing.allocator;
    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("Continue", items[0].label);
    try std.testing.expectEqualStrings("Continue", items[0].value);
    try std.testing.expectEqualStrings("Cancel", items[1].label);
    try std.testing.expectEqualStrings("Cancel", items[1].value);
}

test "buildSelectItems releases partial allocations on OOM at every allocation index" {
    // Walk the allocation index across the full buildSelectItems call so any
    // single failure point still unwinds cleanly. Each iteration uses
    // FailingAllocator on top of std.testing.allocator so the testing
    // allocator's leak detector catches a missed free.
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();
        if (buildSelectItems(failing_allocator)) |items| {
            // The call succeeded before the configured failure index, so the
            // test simply observes a clean run and frees the result.
            freeSelectItems(failing_allocator, items);
        } else |err| switch (err) {
            error.OutOfMemory => {
                // Success path: errdefer chain ran without leaking.
            },
        }
    }
}

test "choiceFromIndex maps zero to continue and non-zero to cancel" {
    try std.testing.expectEqual(MissingCwdChoice.continue_in_fallback, MissingCwdItems.choiceFromIndex(0));
    try std.testing.expectEqual(MissingCwdChoice.cancel, MissingCwdItems.choiceFromIndex(1));
}

test "handleSelectorKey enter on Continue confirms continue" {
    const allocator = std.testing.allocator;
    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);
    var list: tui.SelectList = .{ .items = items, .max_visible = 2, .selected_index = 0 };
    const outcome = handleSelectorKey(&list, .enter);
    try std.testing.expect(outcome == .confirmed);
    try std.testing.expectEqual(@as(usize, 0), outcome.confirmed);
}

test "handleSelectorKey enter on Cancel maps to cancelled" {
    const allocator = std.testing.allocator;
    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);
    var list: tui.SelectList = .{ .items = items, .max_visible = 2, .selected_index = 1 };
    const outcome = handleSelectorKey(&list, .enter);
    try std.testing.expectEqual(SelectorOutcome.cancelled, outcome);
}

test "handleSelectorKey escape returns cancelled" {
    const allocator = std.testing.allocator;
    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);
    var list: tui.SelectList = .{ .items = items, .max_visible = 2 };
    const outcome = handleSelectorKey(&list, .escape);
    try std.testing.expectEqual(SelectorOutcome.cancelled, outcome);
}

test "handleSelectorKey ctrl+c returns cancelled" {
    const allocator = std.testing.allocator;
    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);
    var list: tui.SelectList = .{ .items = items, .max_visible = 2 };
    const outcome = handleSelectorKey(&list, .{ .ctrl = 'c' });
    try std.testing.expectEqual(SelectorOutcome.cancelled, outcome);
}

test "handleSelectorKey down moves to Cancel without confirming" {
    const allocator = std.testing.allocator;
    const items = try buildSelectItems(allocator);
    defer freeSelectItems(allocator, items);
    var list: tui.SelectList = .{ .items = items, .max_visible = 2 };
    const outcome = handleSelectorKey(&list, .down);
    try std.testing.expectEqual(SelectorOutcome.pending, outcome);
    try std.testing.expectEqual(@as(usize, 1), list.selected_index);
}

test "formatBody mirrors the missing-cwd prompt" {
    const allocator = std.testing.allocator;
    const issue = session_cwd.MissingSessionCwdIssue{
        .session_file = "/tmp/sessions/abc.jsonl",
        .session_cwd = "/tmp/missing",
        .fallback_cwd = "/tmp/current",
    };
    const body = try formatBody(allocator, issue);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "cwd from session file does not exist\n/tmp/missing\n\ncontinue in current cwd\n/tmp/current",
        body,
    );
}
