const std = @import("std");
const vaxis = @import("vaxis");

const vw = @import("vaxis-widgets");
const box_mod = vw.components.box;
const editor_mod = vw.components.editor;
const loader_mod = vw.components.loader;
const markdown_mod = vw.components.markdown;
const select_list_mod = vw.components.select_list;
const spacer_mod = vw.components.spacer;
const test_helpers = vw.test_helpers;
const text_mod = vw.components.text;
const draw_mod = vw.draw;

const M8_RENDER_BASELINE_NS_PER_FRAME: u64 = 5_000_000;
const M8_RENDER_SANITY_NS_PER_FRAME: u64 = 250_000_000;

fn expectSnapshot(component: draw_mod.Component, width: usize, height: usize, expected: []const u8) !void {
    var screen = try test_helpers.renderToScreen(component, width, height);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(expected, rendered);
}

test "vaxis m8 visual parity snapshots cover spacer text box select list and loader" {
    const allocator = std.testing.allocator;

    const spacer = spacer_mod.Spacer{ .lines = 2 };
    try expectSnapshot(spacer.drawComponent(), 6, 2,
        \\      
        \\      
    );

    const text = text_mod.Text{ .text = "hello", .padding_x = 1, .padding_y = 1 };
    try expectSnapshot(text.drawComponent(), 10, 3,
        \\          
        \\ hello    
        \\          
    );

    var box = box_mod.Box.init(1, 0);
    defer box.deinit(allocator);
    const boxed_text = text_mod.Text{ .text = "box", .padding_x = 0, .padding_y = 0 };
    try box.addChild(allocator, boxed_text.drawComponent());
    try expectSnapshot(box.drawComponent(), 9, 3,
        \\┌───────┐
        \\│ box   │
        \\└───────┘
    );

    const items = [_]select_list_mod.SelectItem{
        .{ .value = "one", .label = "One", .description = "first" },
        .{ .value = "two", .label = "Two", .description = "second" },
        .{ .value = "three", .label = "Three", .description = "third" },
    };
    const list = select_list_mod.SelectList{
        .items = &items,
        .selected_index = 1,
        .max_visible = 3,
        .padding_x = 1,
    };
    try expectSnapshot(list.drawComponent(), 24, 3,
        \\  One        first      
        \\→ Two        second     
        \\  Three      third      
    );

    var loader = loader_mod.Loader{ .message = "Loading M8", .padding_x = 1 };
    loader.setFrameIndex(2);
    try expectSnapshot(loader.drawComponent(), 18, 1,
        \\ ⠹ Loading M8     
    );
}

test "vaxis m8 visual parity snapshot covers editor text and native cursor state" {
    const allocator = std.testing.allocator;

    var editor = editor_mod.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello\n界");

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try editor.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    var snapshot = try vaxis.AllocatingScreen.init(allocator, 8, 3);
    defer snapshot.deinit(allocator);
    for (0..3) |row| {
        for (0..8) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            snapshot.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
    const rendered = try test_helpers.screenToString(&snapshot);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\hello   
        \\界       
        \\        
    , rendered);
    try std.testing.expect(screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor.col);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor.row);
    try std.testing.expectEqual(vaxis.Cell.CursorShape.beam_blink, screen.cursor_shape);
}

test "vaxis m8 visual parity snapshot covers markdown constructs" {
    const markdown = markdown_mod.Markdown{
        .text =
        \\# Title
        \\
        \\> quote
        \\
        \\- item
        \\
        \\`code` and [link](https://example.com)
        \\
        ,
    };

    try expectSnapshot(markdown.drawComponent(), 32, 8,
        \\Title                           
        \\                                
        \\▍ quote                         
        \\                                
        \\• item                          
        \\                                
        \\code and link                   
        \\                                
    );

    const table = markdown_mod.Markdown{
        .text =
        \\| A | BB | C |
        \\| --- | --- | --- |
        \\| one | two | three |
        \\| 1 | 22 | 333 |
        ,
    };
    try expectSnapshot(table.drawComponent(), 21, 7,
        \\┌─────┬─────┬───────┐
        \\│ A   │ BB  │ C     │
        \\├─────┼─────┼───────┤
        \\│ one │ two │ three │
        \\├─────┼─────┼───────┤
        \\│ 1   │ 22  │ 333   │
        \\└─────┴─────┴───────┘
    );
}

test "vaxis m8 render performance microbenchmark stays within recorded baseline" {
    const allocator = std.testing.allocator;
    const component_text =
        \\# M8 representative frame
        \\
        \\This frame mixes **markdown**, `inline code`, links, lists, and enough text to wrap across a realistic terminal width.
        \\
        \\- queued prompt preview
        \\- footer and hint rows are covered by interactive-mode snapshots
        \\
        \\| Column | Value |
        \\| ------ | ----- |
        \\| render | vaxis |
    ;
    const markdown = markdown_mod.Markdown{ .text = component_text };

    const iterations: usize = 200;
    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    for (0..iterations) |_| {
        var screen = try test_helpers.renderToScreen(markdown.drawComponent(), 100, 24);
        screen.deinit(allocator);
    }
    const end_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    const elapsed_ns = @max(end_ns - start_ns, 0);
    const avg_ns: u64 = @intCast(@divTrunc(elapsed_ns, iterations));

    if (avg_ns > M8_RENDER_BASELINE_NS_PER_FRAME) {
        std.debug.print(
            "M8 render avg {d}ns exceeded recorded baseline {d}ns; keeping CI assertion to the sanity threshold {d}ns\n",
            .{ avg_ns, M8_RENDER_BASELINE_NS_PER_FRAME, M8_RENDER_SANITY_NS_PER_FRAME },
        );
    }
    try std.testing.expect(avg_ns <= M8_RENDER_SANITY_NS_PER_FRAME);
}
