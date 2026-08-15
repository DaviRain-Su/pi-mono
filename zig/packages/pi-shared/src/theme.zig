const std = @import("std");
const dark_theme = @import("themes/dark.zig");
const light_theme = @import("themes/light.zig");
const codex_theme = @import("themes/codex.zig");

pub const ThemeColor = enum(u8) {
    primary,
    secondary,
    success,
    warning,
    @"error",
    background,
    foreground,
    border,
    muted,
    dim,
    thinking_text,
    selected_bg,
    user_message_bg,
    custom_message_bg,
    tool_pending_bg,
    tool_success_bg,
    tool_error_bg,
    border_accent,
    border_muted,
    markdown_heading,
    markdown_link,
    markdown_code,
    markdown_code_border,
    markdown_quote,
    markdown_quote_border,
    markdown_rule,
    markdown_list_bullet,
    tool_output,
};

pub const ThemeToken = enum(u8) {
    welcome,
    user,
    assistant,
    tool_call,
    tool_result,
    @"error",
    status,
    footer,
    prompt,
    box_border,
    text,
    editor,
    editor_cursor,
    select_selected,
    select_description,
    select_scroll,
    select_empty,
    markdown_text,
    markdown_heading,
    markdown_link,
    markdown_code,
    markdown_code_border,
    markdown_quote,
    markdown_quote_border,
    markdown_list_bullet,
    markdown_rule,
    overlay_title,
    overlay_hint,
    prompt_glyph,
    prompt_border,
    task_header,
    task_header_accent,
    task_header_separator,
    role_user,
    role_assistant,
    role_thinking,
    role_tool_call,
    role_tool_result,
    role_thinking_glyph,
    terminal_badge,
};

pub const StyleSpec = struct {
    fg: ?[]u8 = null,
    bg: ?[]u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn clone(self: StyleSpec, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .dim = self.dim,
            .italic = self.italic,
            .underline = self.underline,
        };
    }

    fn deinit(self: *StyleSpec, allocator: std.mem.Allocator) void {
        if (self.fg) |value| allocator.free(value);
        if (self.bg) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const ThemeColors = struct {
    primary: ?[]u8 = null,
    secondary: ?[]u8 = null,
    success: ?[]u8 = null,
    warning: ?[]u8 = null,
    @"error": ?[]u8 = null,
    background: ?[]u8 = null,
    foreground: ?[]u8 = null,
    border: ?[]u8 = null,
    muted: ?[]u8 = null,
    dim: ?[]u8 = null,
    thinking_text: ?[]u8 = null,
    selected_bg: ?[]u8 = null,
    user_message_bg: ?[]u8 = null,
    custom_message_bg: ?[]u8 = null,
    tool_pending_bg: ?[]u8 = null,
    tool_success_bg: ?[]u8 = null,
    tool_error_bg: ?[]u8 = null,
    border_accent: ?[]u8 = null,
    border_muted: ?[]u8 = null,
    markdown_heading: ?[]u8 = null,
    markdown_link: ?[]u8 = null,
    markdown_code: ?[]u8 = null,
    markdown_code_border: ?[]u8 = null,
    markdown_quote: ?[]u8 = null,
    markdown_quote_border: ?[]u8 = null,
    markdown_rule: ?[]u8 = null,
    markdown_list_bullet: ?[]u8 = null,
    tool_output: ?[]u8 = null,

    comptime {
        const color_fields = @typeInfo(ThemeColor).@"enum".fields;
        const colors_fields = @typeInfo(ThemeColors).@"struct".fields;
        if (colors_fields.len != color_fields.len) {
            @compileError("ThemeColors must have one field per ThemeColor tag");
        }
        for (color_fields, colors_fields) |ef, sf| {
            if (!std.mem.eql(u8, ef.name, sf.name)) {
                @compileError("ThemeColors field `" ++ sf.name ++ "` must match ThemeColor tag `" ++ ef.name ++ "`");
            }
        }
    }

    fn clone(self: ThemeColors, allocator: std.mem.Allocator) !ThemeColors {
        var result: ThemeColors = .{};
        errdefer result.deinit(allocator);
        inline for (@typeInfo(ThemeColors).@"struct".fields) |f| {
            if (@field(self, f.name)) |value| {
                @field(result, f.name) = try allocator.dupe(u8, value);
            }
        }
        return result;
    }

    fn deinit(self: *ThemeColors, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(ThemeColors).@"struct".fields) |f| {
            if (@field(self, f.name)) |value| allocator.free(value);
        }
        self.* = .{};
    }

    fn get(self: ThemeColors, color: ThemeColor) ?[]const u8 {
        switch (color) {
            inline else => |tag| return @field(self, @tagName(tag)),
        }
    }

    fn replace(self: *ThemeColors, allocator: std.mem.Allocator, color: ThemeColor, value: []const u8) !void {
        switch (color) {
            inline else => |tag| {
                const target = &@field(self, @tagName(tag));
                if (target.*) |existing| allocator.free(existing);
                target.* = try allocator.dupe(u8, value);
            },
        }
    }
};

pub const Theme = struct {
    name: []u8,
    colors: ThemeColors = .{},
    styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = defaultThemeStyles(),

    pub fn initDefault(allocator: std.mem.Allocator) !Theme {
        return initNamed(allocator, "dark", dark_theme.palette());
    }

    pub fn initLight(allocator: std.mem.Allocator) !Theme {
        return initNamed(allocator, "light", light_theme.palette());
    }

    pub fn initCodex(allocator: std.mem.Allocator) !Theme {
        var theme = try initNamed(allocator, "codex", codex_theme.palette());
        errdefer theme.deinit(allocator);
        try theme.setDerivedStyle(allocator, .prompt_glyph, .{ .fg = theme.colors.get(.primary), .bold = true });
        try theme.setDerivedStyle(allocator, .task_header_accent, .{ .fg = theme.colors.get(.primary), .bold = true });
        try theme.setDerivedStyle(allocator, .terminal_badge, .{ .fg = theme.colors.get(.primary), .bold = true });
        return theme;
    }

    pub fn clone(self: Theme, allocator: std.mem.Allocator) !Theme {
        var styles = defaultThemeStyles();
        for (&styles, self.styles) |*target, source| {
            target.* = try source.clone(allocator);
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .colors = try self.colors.clone(allocator),
            .styles = styles,
        };
    }

    pub fn deinit(self: *Theme, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.colors.deinit(allocator);
        for (&self.styles) |*style| style.deinit(allocator);
        self.* = undefined;
    }

    pub fn applyAlloc(self: *const Theme, allocator: std.mem.Allocator, token: ThemeToken, text: []const u8) ![]u8 {
        _ = self;
        _ = token;
        return allocator.dupe(u8, text);
    }

    pub fn setColor(self: *Theme, allocator: std.mem.Allocator, color: ThemeColor, value: []const u8) !void {
        try self.colors.replace(allocator, color, value);
    }

    pub fn applyDerivedStyles(self: *Theme, allocator: std.mem.Allocator) !void {
        for (&self.styles) |*style| style.deinit(allocator);
        self.styles = defaultThemeStyles();

        inline for (DERIVED_STYLE_TABLE) |spec| {
            try self.setDerivedStyle(allocator, spec.token, .{
                .fg = self.resolveDerivedColor(spec.fg, spec.fg_fallback),
                .bg = self.resolveDerivedColor(spec.bg, spec.bg_fallback),
                .bold = spec.bold,
                .italic = spec.italic,
                .underline = spec.underline,
            });
        }
    }

    fn resolveDerivedColor(
        self: *const Theme,
        comptime primary: ?ThemeColor,
        comptime fallback: ?ThemeColor,
    ) ?[]const u8 {
        if (primary) |color| {
            if (self.colors.get(color)) |value| return value;
        }
        if (fallback) |color| {
            if (self.colors.get(color)) |value| return value;
        }
        return null;
    }

    fn setDerivedStyle(self: *Theme, allocator: std.mem.Allocator, token: ThemeToken, style: StyleTemplate) !void {
        const index = @intFromEnum(token);
        self.styles[index].deinit(allocator);
        self.styles[index] = try style.owned(allocator);
    }
};

const DerivedStyleSpec = struct {
    token: ThemeToken,
    fg: ?ThemeColor = null,
    fg_fallback: ?ThemeColor = null,
    bg: ?ThemeColor = null,
    bg_fallback: ?ThemeColor = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

const DERIVED_STYLE_TABLE: []const DerivedStyleSpec = &.{
    .{ .token = .welcome, .fg = .success, .bold = true },
    .{ .token = .user, .bg = .user_message_bg },
    .{ .token = .assistant },
    .{ .token = .tool_call, .bg = .tool_pending_bg },
    .{ .token = .tool_result, .fg = .tool_output, .fg_fallback = .muted, .bg = .tool_success_bg },
    .{ .token = .@"error", .fg = .@"error", .bold = true },
    .{ .token = .status, .fg = .muted },
    .{ .token = .footer, .fg = .muted },
    .{ .token = .prompt, .fg = .primary, .bold = true },
    .{ .token = .box_border, .fg = .border },
    .{ .token = .text },
    .{ .token = .editor },
    .{ .token = .editor_cursor, .fg = .background, .bg = .primary, .bold = true },
    .{ .token = .select_selected, .bg = .selected_bg, .bg_fallback = .primary, .bold = true },
    .{ .token = .select_description, .fg = .muted },
    .{ .token = .select_scroll, .fg = .muted },
    .{ .token = .select_empty, .fg = .muted, .italic = true },
    .{ .token = .markdown_text },
    .{ .token = .markdown_heading, .fg = .markdown_heading, .fg_fallback = .warning, .bold = true },
    .{ .token = .markdown_link, .fg = .markdown_link, .fg_fallback = .secondary, .underline = true },
    .{ .token = .markdown_code, .fg = .markdown_code, .fg_fallback = .primary },
    .{ .token = .markdown_code_border, .fg = .markdown_code_border, .fg_fallback = .muted },
    .{ .token = .markdown_quote, .fg = .markdown_quote, .fg_fallback = .muted, .italic = true },
    .{ .token = .markdown_quote_border, .fg = .markdown_quote_border, .fg_fallback = .muted },
    .{ .token = .markdown_list_bullet, .fg = .markdown_list_bullet, .fg_fallback = .primary },
    .{ .token = .markdown_rule, .fg = .markdown_rule, .fg_fallback = .muted },
    .{ .token = .overlay_title, .fg = .primary, .bold = true },
    .{ .token = .overlay_hint, .fg = .muted },
    .{ .token = .prompt_glyph, .fg = .primary, .bold = true },
    .{ .token = .prompt_border, .fg = .border },
    .{ .token = .task_header, .fg = .muted },
    .{ .token = .task_header_accent, .fg = .primary, .bold = true },
    .{ .token = .task_header_separator, .fg = .border_muted, .fg_fallback = .border },
    .{ .token = .role_user, .bg = .user_message_bg },
    .{ .token = .role_assistant },
    .{ .token = .role_thinking, .fg = .thinking_text, .fg_fallback = .muted, .italic = true },
    .{ .token = .role_tool_call, .bg = .tool_pending_bg },
    .{ .token = .role_tool_result, .fg = .tool_output, .fg_fallback = .muted, .bg = .tool_success_bg },
    .{ .token = .role_thinking_glyph, .fg = .thinking_text, .fg_fallback = .muted, .italic = true },
    .{ .token = .terminal_badge, .fg = .muted },
};

comptime {
    const fields = @typeInfo(ThemeToken).@"enum".fields;
    std.debug.assert(DERIVED_STYLE_TABLE.len == fields.len);
    var seen = [_]bool{false} ** fields.len;
    for (DERIVED_STYLE_TABLE) |spec| {
        const idx = @intFromEnum(spec.token);
        std.debug.assert(!seen[idx]);
        seen[idx] = true;
    }
}

fn defaultThemeStyles() [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec {
    var styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = undefined;
    for (&styles) |*style| style.* = .{};
    return styles;
}

const StyleTemplate = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,

    fn owned(self: StyleTemplate, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
            .dim = self.dim,
        };
    }
};

pub const PaletteTemplate = struct {
    primary: []const u8,
    secondary: []const u8,
    success: []const u8,
    warning: []const u8,
    @"error": []const u8,
    background: []const u8,
    foreground: []const u8,
    border: []const u8,
    muted: []const u8,
    dim: ?[]const u8 = null,
    thinking_text: ?[]const u8 = null,
    selected_bg: ?[]const u8 = null,
    user_message_bg: ?[]const u8 = null,
    custom_message_bg: ?[]const u8 = null,
    tool_pending_bg: ?[]const u8 = null,
    tool_success_bg: ?[]const u8 = null,
    tool_error_bg: ?[]const u8 = null,
    border_accent: ?[]const u8 = null,
    border_muted: ?[]const u8 = null,
    markdown_heading: ?[]const u8 = null,
    markdown_link: ?[]const u8 = null,
    markdown_code: ?[]const u8 = null,
    markdown_code_border: ?[]const u8 = null,
    markdown_quote: ?[]const u8 = null,
    markdown_quote_border: ?[]const u8 = null,
    markdown_rule: ?[]const u8 = null,
    markdown_list_bullet: ?[]const u8 = null,
    tool_output: ?[]const u8 = null,
};

comptime {
    for (@typeInfo(PaletteTemplate).@"struct".fields) |f| {
        if (!@hasField(ThemeColor, f.name)) {
            @compileError("PaletteTemplate field `" ++ f.name ++ "` has no matching ThemeColor tag");
        }
    }
}

fn initNamed(allocator: std.mem.Allocator, name: []const u8, palette: PaletteTemplate) !Theme {
    var theme = Theme{
        .name = try allocator.dupe(u8, name),
    };
    errdefer theme.deinit(allocator);

    inline for (@typeInfo(PaletteTemplate).@"struct".fields) |f| {
        const tag = @field(ThemeColor, f.name);
        const value = @field(palette, f.name);
        switch (@typeInfo(f.type)) {
            .optional => if (value) |v| try theme.setColor(allocator, tag, v),
            else => try theme.setColor(allocator, tag, value),
        }
    }
    try theme.applyDerivedStyles(allocator);
    return theme;
}

test "theme palette modules expose dark light and codex palettes" {
    const dark = dark_theme.palette();
    const light = light_theme.palette();
    const codex = codex_theme.palette();

    try std.testing.expectEqualStrings("#8abeb7", dark.primary);
    try std.testing.expectEqualStrings("#5a8080", light.primary);
    try std.testing.expectEqualStrings("#d18b50", codex.primary);
    try std.testing.expectEqualStrings("#0f1012", codex.background);
}

test "codex theme and new token fallbacks derive non-default styles" {
    var dark = try Theme.initDefault(std.testing.allocator);
    defer dark.deinit(std.testing.allocator);
    var codex = try Theme.initCodex(std.testing.allocator);
    defer codex.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("codex", codex.name);
    try std.testing.expectEqualStrings("#d18b50", codex.colors.primary.?);
    try std.testing.expectEqualStrings("#0f1012", codex.colors.background.?);
    try std.testing.expectEqualStrings("#d18b50", codex.styles[@intFromEnum(ThemeToken.prompt_glyph)].fg.?);
    try std.testing.expectEqualStrings("#d18b50", codex.styles[@intFromEnum(ThemeToken.task_header_accent)].fg.?);

    const fallback_tokens = [_]ThemeToken{
        .prompt_glyph,
        .prompt_border,
        .task_header,
        .task_header_accent,
        .task_header_separator,
        .role_user,
        .role_thinking,
        .role_tool_call,
        .role_tool_result,
        .role_thinking_glyph,
        .terminal_badge,
    };
    for (fallback_tokens) |token| {
        const spec = dark.styles[@intFromEnum(token)];
        try std.testing.expect(spec.fg != null or spec.bg != null or spec.bold or spec.dim or spec.italic or spec.underline);
    }

    const thinking = dark.styles[@intFromEnum(ThemeToken.role_thinking)];
    try std.testing.expect(thinking.italic);
    try std.testing.expectEqualStrings(dark.colors.muted.?, thinking.fg.?);

    const tool_result = dark.styles[@intFromEnum(ThemeToken.role_tool_result)];
    try std.testing.expect(tool_result.fg != null);
    try std.testing.expect(!std.mem.eql(u8, dark.colors.foreground.?, tool_result.fg.?));

    const text = dark.styles[@intFromEnum(ThemeToken.text)];
    try std.testing.expect(text.fg == null);
    try std.testing.expect(text.bg == null);

    const editor = dark.styles[@intFromEnum(ThemeToken.editor)];
    try std.testing.expect(editor.fg == null);
    try std.testing.expect(editor.bg == null);

    const selected = dark.styles[@intFromEnum(ThemeToken.select_selected)];
    try std.testing.expect(selected.fg == null);
    try std.testing.expectEqualStrings(dark.colors.selected_bg.?, selected.bg.?);
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
