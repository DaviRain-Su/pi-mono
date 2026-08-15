const std = @import("std");
const tui = @import("tui");
const resources_mod = @import("../resources/resources.zig");
const pending_editor_images_mod = @import("pending_editor_images.zig");
const render_text = @import("render_text.zig");

pub const PendingEditorImage = pending_editor_images_mod.PendingEditorImage;

const PROMPT_BOX_HEIGHT = render_text.PROMPT_BOX_HEIGHT;
const PROMPT_GLYPH_WIDTH = render_text.PROMPT_GLYPH_WIDTH;
const layoutMode = render_text.layoutMode;
const promptPrefixForWidth = render_text.promptPrefixForWidth;
const promptEditorWidth = render_text.promptEditorWidth;
const promptEditorOffsetX = render_text.promptEditorOffsetX;

pub fn measureHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
    policy: tui.terminal_image.ImageRenderPolicy,
    width: usize,
) !usize {
    _ = allocator;
    _ = theme;
    _ = editor;
    const editor_width = policy.effectiveWidth(promptEditorWidth(width));
    const prompt_rows: usize = switch (layoutMode(width)) {
        .full, .medium, .narrow => PROMPT_BOX_HEIGHT,
        .mini, .compact => 1,
    };
    return prompt_rows + pendingImagesRenderHeight(pending_images, editor_width, policy);
}

pub fn drawLines(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
    policy: tui.terminal_image.ImageRenderPolicy,
) !tui.DrawSize {
    const prompt_style = styleForToken(theme, .prompt);
    const glyph_style = styleForToken(theme, .prompt_glyph);
    const border_style = styleForToken(theme, .prompt_border);
    const width = @as(usize, window.width);
    const mode = layoutMode(width);
    const editor_width = promptEditorWidth(width);
    const image_width = policy.effectiveWidth(editor_width);
    const prompt_rows: usize = switch (mode) {
        .full, .medium, .narrow => PROMPT_BOX_HEIGHT,
        .mini, .compact => 1,
    };
    const prompt_height = @min(prompt_rows, @as(usize, window.height));
    const prompt_inner = if (mode != .mini and mode != .compact and window.width >= 2 and window.height >= 2)
        window.child(.{
            .height = @intCast(prompt_height),
            .border = .{
                .where = .all,
                .style = border_style,
                .glyphs = .single_rounded,
            },
        })
    else
        window.child(.{ .height = @intCast(prompt_height) });
    prompt_inner.clear();

    const full_editor_height = try measureEditorHeight(ctx.arena, theme, editor, editor_width);
    const has_overflow = mode != .mini and mode != .compact and full_editor_height > @as(usize, @max(prompt_inner.height, 1));

    if (prompt_inner.height > 0) {
        const prefix = promptPrefixForWidth(width);
        const prefix_rows = if (mode == .mini or mode == .compact) @as(usize, 1) else @as(usize, prompt_inner.height);
        for (0..prefix_rows) |line_index| {
            _ = prompt_inner.printSegment(.{
                .text = prefix,
                .style = glyph_style,
            }, .{
                .wrap = .none,
                .row_offset = @intCast(line_index),
            });
        }
    }

    const editor_x = if (mode == .mini or mode == .compact) promptEditorOffsetX(width) else PROMPT_GLYPH_WIDTH;
    if (@as(usize, prompt_inner.width) > editor_x) {
        const editor_window = prompt_inner.child(.{
            .x_off = @intCast(editor_x),
            .width = @intCast(editor_width),
            .height = @max(prompt_inner.height, 1),
        });
        _ = try editor.draw(editor_window, .{
            .window = editor_window,
            .arena = ctx.arena,
        });
    }

    if (has_overflow and window.height >= PROMPT_BOX_HEIGHT and window.width > 8) {
        const indicator = "↓ more";
        const indicator_width = tui.ansi.visibleWidth(indicator);
        const indicator_col = @max(@as(usize, 1), @as(usize, window.width) -| (indicator_width + 2));
        _ = window.printSegment(.{
            .text = indicator,
            .style = glyph_style,
        }, .{
            .wrap = .none,
            .row_offset = @intCast(PROMPT_BOX_HEIGHT - 1),
            .col_offset = @intCast(indicator_col),
        });
    }

    const prefix_width = promptEditorOffsetX(@as(usize, window.width));
    const blank_prefix = try ctx.arena.alloc(u8, prefix_width);
    @memset(blank_prefix, ' ');
    var image_row: usize = 0;
    for (pending_images, 0..) |image, index| {
        const row_count = pendingImageRenderHeight(image, image_width, policy);
        if (prompt_rows + image_row >= window.height) break;

        const continuation_window = window.child(.{
            .x_off = 0,
            .y_off = @intCast(prompt_rows + image_row),
            .height = @intCast(@min(row_count, @as(usize, window.height) -| (prompt_rows + image_row))),
        });

        if (policy.enabled) {
            if (image.kitty_image) |kitty| {
                const image_window = continuation_window.child(.{
                    .x_off = @intCast(prefix_width),
                    .width = @intCast(image_width),
                    .height = @intCast(@min(row_count, @as(usize, continuation_window.height))),
                });
                const image_component = tui.Image{
                    .mime_type = image.mime_type,
                    .kitty_image = kitty,
                    .max_width_cells = image_width,
                    .max_height_cells = row_count,
                };
                _ = try image_component.drawComponent().draw(image_window, .{
                    .window = image_window,
                    .arena = ctx.arena,
                });
            } else {
                const placeholder = try std.fmt.allocPrint(ctx.arena, "{s}[image {d}: {s}]", .{ blank_prefix, index + 1, image.mime_type });
                drawFittedLine(continuation_window, 0, placeholder, prompt_style);
            }
        } else {
            const placeholder = try std.fmt.allocPrint(ctx.arena, "{s}[image {d}: {s}]", .{ blank_prefix, index + 1, image.mime_type });
            drawFittedLine(continuation_window, 0, placeholder, prompt_style);
        }

        image_row += row_count;
    }
    return .{
        .width = window.width,
        .height = @intCast(@min(prompt_rows + image_row, @as(usize, window.height))),
    };
}

fn pendingImagesRenderHeight(
    images: []const PendingEditorImage,
    width: usize,
    policy: tui.terminal_image.ImageRenderPolicy,
) usize {
    var height: usize = 0;
    for (images) |image| height += pendingImageRenderHeight(image, width, policy);
    return height;
}

fn pendingImageRenderHeight(
    image: PendingEditorImage,
    width: usize,
    policy: tui.terminal_image.ImageRenderPolicy,
) usize {
    _ = width;
    return if (policy.enabled and image.kitty_image != null) 4 else 1;
}

fn measureEditorHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    width: usize,
) !usize {
    _ = theme;
    _ = allocator;
    const height_hint = @max(@as(usize, 1), estimateWrappedRows(editor.text(), width) + editor.padding_y * 2);
    return @min(height_hint, @as(usize, std.math.maxInt(u16)));
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

fn styleForToken(theme: ?*const resources_mod.Theme, token: resources_mod.ThemeToken) tui.vaxis.Cell.Style {
    return if (theme) |active_theme| tui.styleFor(active_theme, token) else .{};
}

test "drawLines places Kitty image cells for transmitted pending images" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 8,
        .cols = 80,
        .x_pixel = 320,
        .y_pixel = 128,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const pending = [_]PendingEditorImage{.{
        .data = "AQID",
        .mime_type = "image/png",
        .kitty_image = .{
            .id = 77,
            .width_px = 64,
            .height_px = 32,
        },
    }};

    _ = try drawLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &pending, .{});

    const image_col: u16 = @intCast(promptEditorOffsetX(80));
    const image_cell = screen.readCell(image_col, PROMPT_BOX_HEIGHT) orelse return error.TestUnexpectedResult;
    try std.testing.expect(image_cell.image != null);
    try std.testing.expectEqual(@as(u32, 77), image_cell.image.?.img_id);
}

test "drawLines renders bordered prompt with glyph prefix" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, &theme, &editor, &.{}, .{});

    const top_left = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╭", top_left.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .prompt_border), top_left.style);

    const bottom_left = screen.readCell(0, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╰", bottom_left.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .prompt_border), bottom_left.style);

    const glyph = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .prompt_glyph), glyph.style);

    const first_text = screen.readCell(3, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h", first_text.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .editor), first_text.style);
}

test "drawLines places cursor after border and glyph offset" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &.{}, .{});

    try std.testing.expect(screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 8), screen.cursor.col);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor.row);
}

test "measureHeight uses fixed border height and editor width overhead" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("a long prompt that would previously grow the prompt area");

    try std.testing.expectEqual(@as(usize, 76), promptEditorWidth(80));
    try std.testing.expectEqual(@as(usize, 3), try measureHeight(allocator, null, &editor, &.{}, .{}, 80));
}

test "drawLines shows overflow indicator on bottom border" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 60,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &.{}, .{});

    var rendered = try tui.vaxis.AllocatingScreen.init(allocator, 60, 3);
    defer rendered.deinit(allocator);
    for (0..3) |row| {
        for (0..60) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            rendered.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
    const text = try tui.test_helpers.screenToString(&rendered);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "↓ more") != null);
}

test "drawLines keeps CJK text visible inside bordered prompt" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("你好");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 100,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &.{}, .{});

    const first = screen.readCell(3, 1) orelse return error.TestUnexpectedResult;
    const second = screen.readCell(5, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("你", first.char.grapheme);
    try std.testing.expectEqualStrings("好", second.char.grapheme);
}
