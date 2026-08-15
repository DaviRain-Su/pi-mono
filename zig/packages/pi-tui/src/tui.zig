const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("vaxis-widgets").draw;
const terminal_mod = @import("terminal.zig");

pub const OverlayAnchor = enum {
    center,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    top_center,
    bottom_center,
    left_center,
    right_center,
};

pub const OverlayMargin = struct {
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    left: usize = 0,
};

pub const OverlayAnimationKind = enum {
    none,
    slide_from_top,
    slide_from_bottom,
    slide_from_left,
    slide_from_right,
};

pub const OverlayAnimation = struct {
    kind: OverlayAnimationKind = .none,
    progress: f32 = 1.0,
};

pub const OverlayOptions = struct {
    width: ?usize = null,
    max_height: ?usize = null,
    anchor: OverlayAnchor = .center,
    offset_x: isize = 0,
    offset_y: isize = 0,
    row: ?usize = null,
    col: ?usize = null,
    margin: OverlayMargin = .{},
    animation: OverlayAnimation = .{},
};

pub const RenderStats = struct {
    changed_line_count: usize = 0,
    frame_bytes: usize = 0,
    synchronized_output: bool = false,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    terminal: *terminal_mod.Terminal,
    previous_size: ?terminal_mod.Size = null,
    draw_overlays: std.ArrayList(DrawOverlayEntry) = .empty,
    next_overlay_id: usize = 1,
    last_render_stats: RenderStats = .{},
    dirty: bool = true,
    measure_screen: ?vaxis.Screen = null,

    pub fn init(allocator: std.mem.Allocator, terminal: *terminal_mod.Terminal) Renderer {
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .dirty = true,
        };
    }

    pub fn markDirty(self: *Renderer) void {
        self.dirty = true;
    }

    pub fn getLastRenderStats(self: *const Renderer) RenderStats {
        return self.last_render_stats;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.measure_screen) |*ms| ms.deinit(self.allocator);
        self.draw_overlays.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn showDrawOverlay(self: *Renderer, component: draw_mod.Component, options: OverlayOptions) !usize {
        const id = self.next_overlay_id;
        self.next_overlay_id += 1;
        try self.draw_overlays.append(self.allocator, .{
            .id = id,
            .component = component,
            .options = options,
        });
        self.markDirty();
        return id;
    }

    pub fn removeOverlay(self: *Renderer, id: usize) bool {
        for (self.draw_overlays.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.draw_overlays.orderedRemove(index);
            self.markDirty();
            return true;
        }
        return false;
    }

    pub fn dismissTopOverlay(self: *Renderer) bool {
        if (self.draw_overlays.items.len == 0) return false;
        _ = self.draw_overlays.pop();
        self.markDirty();
        return true;
    }

    pub fn updateDrawOverlay(self: *Renderer, id: usize, component: draw_mod.Component, options: OverlayOptions) bool {
        for (self.draw_overlays.items) |*entry| {
            if (entry.id != id) continue;
            entry.component = component;
            entry.options = options;
            self.markDirty();
            return true;
        }
        return false;
    }

    pub fn hasOverlays(self: *const Renderer) bool {
        return self.draw_overlays.items.len > 0;
    }

    pub fn renderToVaxis(self: *Renderer, root: draw_mod.Component, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
        const size = try self.terminal.refreshSize();
        const size_changed = if (self.previous_size) |previous|
            previous.width != size.width or previous.height != size.height
        else
            true;

        if (!self.dirty and !size_changed) return;
        self.dirty = false;

        const resized = try ensureVaxisSize(self.allocator, vx, tty, size);
        if (resized or size_changed) {
            vx.queueRefresh();
        }

        var frame_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();

        const window = vx.window();
        window.clear();
        _ = try root.draw(window, .{
            .window = window,
            .arena = frame_allocator,
        });
        try self.compositeDrawOverlays(size, window, frame_allocator);
        try vx.render(tty);

        self.last_render_stats = .{};
        self.previous_size = size;
    }

    fn compositeDrawOverlays(
        self: *Renderer,
        size: terminal_mod.Size,
        root_window: vaxis.Window,
        frame_allocator: std.mem.Allocator,
    ) !void {
        if (self.draw_overlays.items.len == 0) return;

        for (self.draw_overlays.items) |entry| {
            const width = resolveOverlayWidth(entry.options, size.width);
            const max_height = entry.options.max_height orelse size.height;
            const measurement_height = @max(@as(usize, 1), @min(max_height, size.height));

            const need_cols: u16 = @intCast(@max(width, 1));
            const need_rows: u16 = @intCast(measurement_height);

            const have_cols = if (self.measure_screen) |ms| ms.width else 0;
            const have_rows = if (self.measure_screen) |ms| ms.height else 0;

            if (need_cols > have_cols or need_rows > have_rows) {
                if (self.measure_screen) |*ms| ms.deinit(self.allocator);
                self.measure_screen = try vaxis.Screen.init(self.allocator, .{
                    .rows = need_rows,
                    .cols = need_cols,
                    .x_pixel = 0,
                    .y_pixel = 0,
                });
            }

            const ms = &self.measure_screen.?;
            const base_cell: vaxis.Cell = .{};
            @memset(ms.buf, base_cell);

            const measure_window = draw_mod.rootWindow(ms);
            measure_window.clear();
            const measured_size = try entry.component.draw(measure_window, .{
                .window = measure_window,
                .arena = frame_allocator,
            });
            const overlay_height = @min(@max(@as(usize, measured_size.height), 1), measurement_height);
            const layout = resolveOverlayLayout(entry.options, width, overlay_height, size);
            const overlay_window = root_window.child(.{
                .x_off = @intCast(layout.col),
                .y_off = @intCast(layout.row),
                .width = @intCast(@min(width, size.width -| layout.col)),
                .height = @intCast(@min(overlay_height, size.height -| layout.row)),
            });
            _ = try entry.component.draw(overlay_window, .{
                .window = overlay_window,
                .arena = frame_allocator,
            });
        }
    }
};

const DrawOverlayEntry = struct {
    id: usize,
    component: draw_mod.Component,
    options: OverlayOptions,
};

const OverlayLayout = struct {
    row: usize,
    col: usize,
};

fn ensureVaxisSize(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    size: terminal_mod.Size,
) !bool {
    const cols: u16 = @intCast(@min(size.width, @as(usize, std.math.maxInt(u16))));
    const rows: u16 = @intCast(@min(size.height, @as(usize, std.math.maxInt(u16))));
    if (vx.screen.width == cols and vx.screen.height == rows) return false;

    try vx.resize(allocator, tty, .{
        .rows = rows,
        .cols = cols,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    return true;
}

fn resolveOverlayWidth(options: OverlayOptions, terminal_width: usize) usize {
    const margin = options.margin;
    const available_width = @max(terminal_width, margin.left + margin.right + 1) - margin.left - margin.right;
    const preferred = options.width orelse available_width;
    return @max(@as(usize, 1), @min(preferred, available_width));
}

fn resolveOverlayLayout(
    options: OverlayOptions,
    overlay_width: usize,
    overlay_height: usize,
    size: terminal_mod.Size,
) OverlayLayout {
    const margin = options.margin;
    const available_width = @max(size.width, margin.left + margin.right + 1) - margin.left - margin.right;
    const available_height = @max(size.height, margin.top + margin.bottom + 1) - margin.top - margin.bottom;

    const width = @min(overlay_width, available_width);
    const height = @min(overlay_height, available_height);

    const max_col = margin.left + available_width - width;
    const max_row = margin.top + available_height - height;

    const anchor_col = switch (options.anchor) {
        .top_left, .left_center, .bottom_left => margin.left,
        .top_right, .right_center, .bottom_right => max_col,
        .center, .top_center, .bottom_center => margin.left + (available_width - width) / 2,
    };
    const anchor_row = switch (options.anchor) {
        .top_left, .top_center, .top_right => margin.top,
        .bottom_left, .bottom_center, .bottom_right => max_row,
        .center, .left_center, .right_center => margin.top + (available_height - height) / 2,
    };

    const base_col = options.col orelse anchor_col;
    const base_row = options.row orelse anchor_row;

    return .{
        .row = animatedRow(
            clampPosition(base_row, options.offset_y, margin.top, max_row),
            margin.top,
            max_row,
            options.animation,
        ),
        .col = animatedCol(
            clampPosition(base_col, options.offset_x, margin.left, max_col),
            margin.left,
            max_col,
            options.animation,
        ),
    };
}

fn clampPosition(base: usize, offset: isize, min_value: usize, max_value: usize) usize {
    const shifted = @as(isize, @intCast(base)) + offset;
    const clamped = std.math.clamp(shifted, @as(isize, @intCast(min_value)), @as(isize, @intCast(max_value)));
    return @intCast(clamped);
}

fn animatedRow(base_row: usize, min_row: usize, max_row: usize, animation: OverlayAnimation) usize {
    const progress = animationProgress(animation.progress);
    return switch (animation.kind) {
        .slide_from_top => interpolatePosition(min_row, base_row, progress),
        .slide_from_bottom => interpolatePosition(max_row, base_row, progress),
        else => base_row,
    };
}

fn animatedCol(base_col: usize, min_col: usize, max_col: usize, animation: OverlayAnimation) usize {
    const progress = animationProgress(animation.progress);
    return switch (animation.kind) {
        .slide_from_left => interpolatePosition(min_col, base_col, progress),
        .slide_from_right => interpolatePosition(max_col, base_col, progress),
        else => base_col,
    };
}

fn interpolatePosition(start: usize, end: usize, progress: f32) usize {
    if (start == end) return end;
    const distance = @as(f32, @floatFromInt(if (end >= start) end - start else start - end));
    const delta = @as(usize, @intFromFloat(@round(distance * progress)));
    return if (end >= start) start + delta else start - @min(start, delta);
}

fn animationProgress(progress: f32) f32 {
    return std.math.clamp(progress, 0.0, 1.0);
}

const TestMockBackend = struct {
    size: terminal_mod.Size,
    writes: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.writes.items) |entry| alloc.free(entry);
        self.writes.deinit(alloc);
    }

    fn backend(self: *@This()) terminal_mod.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    fn enterRawMode(_: *anyopaque) !void {}
    fn restoreMode(_: *anyopaque) !void {}

    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    }

    fn getSize(ptr: *anyopaque) !terminal_mod.Size {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

const TestDrawComponent = struct {
    const sentinel: u8 = 0;

    pub fn component() draw_mod.Component {
        return .{
            .ptr = &sentinel,
            .drawFn = draw,
        };
    }

    fn draw(_: *const anyopaque, window: vaxis.Window, ctx: draw_mod.DrawContext) !draw_mod.Size {
        _ = ctx;
        window.writeCell(1, 1, .{
            .char = .{
                .grapheme = "Z",
                .width = 1,
            },
        });
        return .{
            .width = 1,
            .height = 1,
        };
    }
};

const TestDrawOverlayComponent = struct {
    const sentinel: u8 = 0;

    pub fn component() draw_mod.Component {
        return .{
            .ptr = &sentinel,
            .drawFn = draw,
        };
    }

    fn draw(_: *const anyopaque, window: vaxis.Window, ctx: draw_mod.DrawContext) !draw_mod.Size {
        _ = ctx;
        window.writeCell(0, 0, .{
            .char = .{
                .grapheme = "M",
                .width = 1,
            },
        });
        return .{
            .width = window.width,
            .height = 2,
        };
    }
};

test "overlay animation slides from top before reaching its anchor" {
    const size = terminal_mod.Size{ .width = 20, .height = 10 };
    const start = resolveOverlayLayout(.{
        .width = 8,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 0.0 },
    }, 8, 3, size);
    const mid = resolveOverlayLayout(.{
        .width = 8,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 0.5 },
    }, 8, 3, size);
    const end = resolveOverlayLayout(.{
        .width = 8,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 1.0 },
    }, 8, 3, size);

    try std.testing.expectEqual(@as(usize, 0), start.row);
    try std.testing.expect(mid.row > start.row);
    try std.testing.expectEqual(end.row, resolveOverlayLayout(.{ .width = 8, .anchor = .center }, 8, 3, size).row);
}

test "renderer can render a draw component through vaxis" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 6, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var vx = try vaxis.init(std.testing.io, allocator, &env_map, .{});
    defer vx.deinit(allocator, &writer.writer);

    try renderer.renderToVaxis(TestDrawComponent.component(), &vx, &writer.writer);

    const window = vx.window();
    const drawn_cell = window.readCell(1, 1).?;
    try std.testing.expectEqualStrings("Z", drawn_cell.char.grapheme);
}

test "renderer redraws after terminal resize without explicit dirty mark" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 6, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var vx = try vaxis.init(std.testing.io, allocator, &env_map, .{});
    defer vx.deinit(allocator, &writer.writer);

    try renderer.renderToVaxis(TestDrawComponent.component(), &vx, &writer.writer);
    const first_render_bytes = writer.written().len;

    try renderer.renderToVaxis(TestDrawComponent.component(), &vx, &writer.writer);
    try std.testing.expectEqual(first_render_bytes, writer.written().len);

    backend.size = .{ .width = 10, .height = 5 };
    try renderer.renderToVaxis(TestDrawComponent.component(), &vx, &writer.writer);

    try std.testing.expectEqual(@as(u16, 10), vx.screen.width);
    try std.testing.expectEqual(@as(u16, 5), vx.screen.height);
    try std.testing.expect(writer.written().len > first_render_bytes);
}

test "renderer composes draw overlays through child windows with animated offsets" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 14, .height = 6 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const overlay_id = try renderer.showDrawOverlay(TestDrawOverlayComponent.component(), .{
        .width = 6,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 0.0 },
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var vx = try vaxis.init(std.testing.io, allocator, &env_map, .{});
    defer vx.deinit(allocator, &writer.writer);

    try renderer.renderToVaxis(TestDrawComponent.component(), &vx, &writer.writer);
    var window = vx.window();
    try std.testing.expectEqualStrings("M", window.readCell(4, 0).?.char.grapheme);

    try std.testing.expect(renderer.updateDrawOverlay(overlay_id, TestDrawOverlayComponent.component(), .{
        .width = 6,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 1.0 },
    }));
    try renderer.renderToVaxis(TestDrawComponent.component(), &vx, &writer.writer);
    window = vx.window();
    try std.testing.expectEqualStrings("M", window.readCell(4, 2).?.char.grapheme);
}
