const std = @import("std");

const ANSI_COLORS: []const []const u8 = &.{
    "#000000", "#800000", "#008000", "#808000",
    "#000080", "#800080", "#008080", "#c0c0c0",
    "#808080", "#ff0000", "#00ff00", "#ffff00",
    "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
};

const TextStyle = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn hasStyle(self: TextStyle) bool {
        return self.fg != null or self.bg != null or self.bold or self.dim or self.italic or self.underline;
    }
};

pub fn color256ToHex(allocator: std.mem.Allocator, index: u8) ![]u8 {
    if (index < 16) return allocator.dupe(u8, ANSI_COLORS[index]);
    if (index < 232) {
        const cube_index = index - 16;
        const r = cube_index / 36;
        const g = (cube_index % 36) / 6;
        const b = cube_index % 6;
        return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ colorCubeComponent(r), colorCubeComponent(g), colorCubeComponent(b) });
    }
    const gray: u8 = 8 + (index - 232) * 10;
    return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ gray, gray, gray });
}

pub fn ansiToHtml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var style = TextStyle{};
    var owned_colors = std.ArrayList([]u8).empty;
    defer {
        for (owned_colors.items) |color| allocator.free(color);
        owned_colors.deinit(allocator);
    }
    var in_span = false;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "\x1b[")) {
            const rest = text[index + 2 ..];
            const end = std.mem.indexOfScalar(u8, rest, 'm') orelse {
                try writeEscapedHtml(&out.writer, text[index .. index + 1]);
                index += 1;
                continue;
            };
            if (in_span) {
                try out.writer.writeAll("</span>");
                in_span = false;
            }
            try applySgrParams(allocator, rest[0..end], &style, &owned_colors);
            if (style.hasStyle()) {
                try out.writer.writeAll("<span style=\"");
                try writeInlineCss(&out.writer, style);
                try out.writer.writeAll("\">");
                in_span = true;
            }
            index += 2 + end + 1;
            continue;
        }
        try writeEscapedHtml(&out.writer, text[index .. index + 1]);
        index += 1;
    }
    if (in_span) try out.writer.writeAll("</span>");
    return out.toOwnedSlice();
}

pub fn ansiLinesToHtml(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (lines) |line| {
        const html = try ansiToHtml(allocator, line);
        defer allocator.free(html);
        try out.writer.writeAll("<div class=\"ansi-line\">");
        if (html.len == 0) try out.writer.writeAll("&nbsp;") else try out.writer.writeAll(html);
        try out.writer.writeAll("</div>");
    }
    return out.toOwnedSlice();
}

fn applySgrParams(allocator: std.mem.Allocator, raw_params: []const u8, style: *TextStyle, owned_colors: *std.ArrayList([]u8)) !void {
    var values = std.ArrayList(u16).empty;
    defer values.deinit(allocator);
    if (raw_params.len == 0) {
        try values.append(allocator, 0);
    } else {
        var parts = std.mem.splitScalar(u8, raw_params, ';');
        while (parts.next()) |part| {
            try values.append(allocator, std.fmt.parseInt(u16, part, 10) catch 0);
        }
    }

    var i: usize = 0;
    while (i < values.items.len) : (i += 1) {
        const code = values.items[i];
        switch (code) {
            0 => style.* = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.underline = true,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.underline = false,
            30...37 => style.fg = ANSI_COLORS[code - 30],
            39 => style.fg = null,
            40...47 => style.bg = ANSI_COLORS[code - 40],
            49 => style.bg = null,
            90...97 => style.fg = ANSI_COLORS[code - 90 + 8],
            100...107 => style.bg = ANSI_COLORS[code - 100 + 8],
            38, 48 => {
                if (i + 2 < values.items.len and values.items[i + 1] == 5) {
                    const color = try color256ToHex(allocator, @intCast(@min(values.items[i + 2], 255)));
                    try owned_colors.append(allocator, color);
                    if (code == 38) style.fg = color else style.bg = color;
                    i += 2;
                } else if (i + 4 < values.items.len and values.items[i + 1] == 2) {
                    const color = try std.fmt.allocPrint(allocator, "rgb({d},{d},{d})", .{ values.items[i + 2], values.items[i + 3], values.items[i + 4] });
                    try owned_colors.append(allocator, color);
                    if (code == 38) style.fg = color else style.bg = color;
                    i += 4;
                }
            },
            else => {},
        }
    }
}

fn writeInlineCss(writer: *std.Io.Writer, style: TextStyle) !void {
    var need_separator = false;
    if (style.fg) |fg| try writeCssPart(writer, &need_separator, "color", fg);
    if (style.bg) |bg| try writeCssPart(writer, &need_separator, "background-color", bg);
    if (style.bold) try writeCssPart(writer, &need_separator, "font-weight", "bold");
    if (style.dim) try writeCssPart(writer, &need_separator, "opacity", "0.6");
    if (style.italic) try writeCssPart(writer, &need_separator, "font-style", "italic");
    if (style.underline) try writeCssPart(writer, &need_separator, "text-decoration", "underline");
}

fn writeCssPart(writer: *std.Io.Writer, need_separator: *bool, key: []const u8, value: []const u8) !void {
    if (need_separator.*) try writer.writeAll(";");
    try writer.print("{s}:{s}", .{ key, value });
    need_separator.* = true;
}

fn writeEscapedHtml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#039;"),
        else => try writer.writeByte(byte),
    };
}

fn colorCubeComponent(n: u8) u8 {
    return if (n == 0) 0 else 55 + n * 40;
}

test "ansiToHtml converts colors and escapes text" {
    const html = try ansiToHtml(std.testing.allocator, "\x1b[31;1m<&>\x1b[0m");
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<span style=\"color:#800000;font-weight:bold\">&lt;&amp;&gt;</span>", html);
}
