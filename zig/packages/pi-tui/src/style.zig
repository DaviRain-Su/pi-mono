const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme.zig");

pub const ColorMode = enum {
    truecolor,
    @"256color",
};

pub fn styleFor(theme: *const theme_mod.Theme, token: theme_mod.ThemeToken) vaxis.Cell.Style {
    return styleFromSpec(theme.styles[@intFromEnum(token)]);
}

pub fn markdownStylesFor(theme: *const theme_mod.Theme) @import("vaxis-widgets").MarkdownStyles {
    return .{
        .text = styleFor(theme, .markdown_text),
        .heading = styleFor(theme, .markdown_heading),
        .rule = styleFor(theme, .markdown_rule),
        .quote = styleFor(theme, .markdown_quote),
        .quote_border = styleFor(theme, .markdown_quote_border),
        .list_bullet = styleFor(theme, .markdown_list_bullet),
        .code = styleFor(theme, .markdown_code),
        .code_border = styleFor(theme, .markdown_code_border),
        .link = styleFor(theme, .markdown_link),
    };
}

pub fn styleForWithColorMode(theme: *const theme_mod.Theme, token: theme_mod.ThemeToken, mode: ColorMode) vaxis.Cell.Style {
    return styleFromSpecWithColorMode(theme.styles[@intFromEnum(token)], mode);
}

pub fn styleFromSpec(spec: theme_mod.StyleSpec) vaxis.Cell.Style {
    return styleFromSpecWithColorMode(spec, detectColorMode(null));
}

pub fn styleFromSpecWithColorMode(spec: theme_mod.StyleSpec, mode: ColorMode) vaxis.Cell.Style {
    return .{
        .fg = parseColor(spec.fg, mode),
        .bg = parseColor(spec.bg, mode),
        .bold = spec.bold,
        .dim = spec.dim,
        .italic = spec.italic,
        .ul_style = if (spec.underline) .single else .off,
    };
}

pub fn detectColorMode(env_map: ?*const std.process.Environ.Map) ColorMode {
    if (envValue(env_map, "COLORTERM")) |colorterm| {
        if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit")) {
            return .truecolor;
        }
    }

    if (envValue(env_map, "WT_SESSION") != null) return .truecolor;

    const term = envValue(env_map, "TERM") orelse "";
    if (term.len == 0 or std.mem.eql(u8, term, "dumb") or std.mem.eql(u8, term, "linux")) {
        return .@"256color";
    }

    if (envValue(env_map, "TERM_PROGRAM")) |term_program| {
        if (std.mem.eql(u8, term_program, "Apple_Terminal")) return .@"256color";
    }

    if (std.mem.startsWith(u8, term, "screen")) return .@"256color";

    return .truecolor;
}

fn envValue(env_map: ?*const std.process.Environ.Map, comptime key: [:0]const u8) ?[]const u8 {
    const raw = if (env_map) |map| map.get(key) else cEnvValue(key);
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn cEnvValue(comptime key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

fn parseColor(value: ?[]const u8, mode: ColorMode) vaxis.Cell.Color {
    const color = value orelse return .default;
    if (parseNamedColor(color)) |named| {
        return .{ .index = named };
    }
    if (color.len == 7 and color[0] == '#') {
        const r = std.fmt.parseInt(u8, color[1..3], 16) catch return .default;
        const g = std.fmt.parseInt(u8, color[3..5], 16) catch return .default;
        const b = std.fmt.parseInt(u8, color[5..7], 16) catch return .default;
        return switch (mode) {
            .truecolor => .{ .rgb = .{ r, g, b } },
            .@"256color" => .{ .index = rgbTo256(r, g, b) },
        };
    }
    return .default;
}

fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    const cube_values = [_]u8{ 0, 95, 135, 175, 215, 255 };
    const gray_values = [_]u8{ 8, 18, 28, 38, 48, 58, 68, 78, 88, 98, 108, 118, 128, 138, 148, 158, 168, 178, 188, 198, 208, 218, 228, 238 };

    const r_index = closestIndex(&cube_values, r);
    const g_index = closestIndex(&cube_values, g);
    const b_index = closestIndex(&cube_values, b);
    const cube_r = cube_values[r_index];
    const cube_g = cube_values[g_index];
    const cube_b = cube_values[b_index];
    const cube_index: u8 = @intCast(16 + 36 * r_index + 6 * g_index + b_index);
    const cube_dist = colorDistance(r, g, b, cube_r, cube_g, cube_b);

    const gray_float = @round(0.299 * @as(f64, @floatFromInt(r)) + 0.587 * @as(f64, @floatFromInt(g)) + 0.114 * @as(f64, @floatFromInt(b)));
    const gray: u8 = @intFromFloat(gray_float);
    const gray_index_offset = closestIndex(&gray_values, gray);
    const gray_value = gray_values[gray_index_offset];
    const gray_index: u8 = @intCast(232 + gray_index_offset);
    const gray_dist = colorDistance(r, g, b, gray_value, gray_value, gray_value);

    const max_channel = @max(r, @max(g, b));
    const min_channel = @min(r, @min(g, b));
    if (max_channel - min_channel < 10 and gray_dist < cube_dist) {
        return gray_index;
    }

    return cube_index;
}

fn closestIndex(values: []const u8, value: u8) usize {
    var best_index: usize = 0;
    var best_distance: u8 = 255;
    for (values, 0..) |candidate, index| {
        const distance = if (value > candidate) value - candidate else candidate - value;
        if (distance < best_distance) {
            best_distance = distance;
            best_index = index;
        }
    }
    return best_index;
}

fn colorDistance(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) f64 {
    const dr = @as(f64, @floatFromInt(r1)) - @as(f64, @floatFromInt(r2));
    const dg = @as(f64, @floatFromInt(g1)) - @as(f64, @floatFromInt(g2));
    const db = @as(f64, @floatFromInt(b1)) - @as(f64, @floatFromInt(b2));
    return dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114;
}

const named_colors = std.StaticStringMap(u8).initComptime(.{
    .{ "black", 0 },
    .{ "red", 1 },
    .{ "green", 2 },
    .{ "yellow", 3 },
    .{ "blue", 4 },
    .{ "magenta", 5 },
    .{ "cyan", 6 },
    .{ "white", 7 },
});

pub fn parseNamedColor(value: []const u8) ?u8 {
    return named_colors.get(value);
}

test "styleFor maps representative theme tokens to vaxis styles" {
    var theme = try theme_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    const welcome = styleForWithColorMode(&theme, .welcome, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 181, 189, 104 } }, welcome.fg);
    try std.testing.expect(welcome.bold);

    const selected = styleForWithColorMode(&theme, .select_selected, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color.default, selected.fg);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 58, 58, 74 } }, selected.bg);
    try std.testing.expect(selected.bold);

    const link = styleForWithColorMode(&theme, .markdown_link, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 129, 162, 190 } }, link.fg);
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, link.ul_style);

    const empty = styleForWithColorMode(&theme, .select_empty, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 128, 128, 128 } }, empty.fg);
    try std.testing.expect(empty.italic);

    const prompt_glyph = styleForWithColorMode(&theme, .prompt_glyph, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 138, 190, 183 } }, prompt_glyph.fg);
    try std.testing.expect(prompt_glyph.bold);

    const prompt_border = styleForWithColorMode(&theme, .prompt_border, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 95, 135, 255 } }, prompt_border.fg);

    const terminal_badge = styleForWithColorMode(&theme, .terminal_badge, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 128, 128, 128 } }, terminal_badge.fg);
    try std.testing.expect(!terminal_badge.bold);
}

test "color mode detection mirrors limited terminal fallbacks" {
    var linux_env = std.process.Environ.Map.init(std.testing.allocator);
    defer linux_env.deinit();
    try linux_env.put("TERM", "linux");
    try std.testing.expectEqual(ColorMode.@"256color", detectColorMode(&linux_env));

    var dumb_env = std.process.Environ.Map.init(std.testing.allocator);
    defer dumb_env.deinit();
    try dumb_env.put("TERM", "dumb");
    try std.testing.expectEqual(ColorMode.@"256color", detectColorMode(&dumb_env));

    var apple_env = std.process.Environ.Map.init(std.testing.allocator);
    defer apple_env.deinit();
    try apple_env.put("TERM", "xterm-256color");
    try apple_env.put("TERM_PROGRAM", "Apple_Terminal");
    try std.testing.expectEqual(ColorMode.@"256color", detectColorMode(&apple_env));

    var screen_env = std.process.Environ.Map.init(std.testing.allocator);
    defer screen_env.deinit();
    try screen_env.put("TERM", "screen-256color");
    try std.testing.expectEqual(ColorMode.@"256color", detectColorMode(&screen_env));

    var truecolor_env = std.process.Environ.Map.init(std.testing.allocator);
    defer truecolor_env.deinit();
    try truecolor_env.put("TERM", "linux");
    try truecolor_env.put("COLORTERM", "truecolor");
    try std.testing.expectEqual(ColorMode.truecolor, detectColorMode(&truecolor_env));

    var wt_env = std.process.Environ.Map.init(std.testing.allocator);
    defer wt_env.deinit();
    try wt_env.put("TERM", "linux");
    try wt_env.put("WT_SESSION", "1");
    try std.testing.expectEqual(ColorMode.truecolor, detectColorMode(&wt_env));
}

test "hex colors downgrade to xterm 256 indexes in limited color mode" {
    const truecolor = styleFromSpecWithColorMode(.{ .fg = @constCast("#8ab4ff"[0..]), .bg = @constCast("#0b1020"[0..]) }, .truecolor);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 138, 180, 255 } }, truecolor.fg);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 11, 16, 32 } }, truecolor.bg);

    const downgraded = styleFromSpecWithColorMode(.{ .fg = @constCast("#8ab4ff"[0..]), .bg = @constCast("#0b1020"[0..]) }, .@"256color");
    try std.testing.expectEqual(vaxis.Cell.Color{ .index = 111 }, downgraded.fg);
    try std.testing.expectEqual(vaxis.Cell.Color{ .index = 16 }, downgraded.bg);

    const named = styleFromSpecWithColorMode(.{ .fg = @constCast("cyan"[0..]) }, .@"256color");
    try std.testing.expectEqual(vaxis.Cell.Color{ .index = 6 }, named.fg);
}
