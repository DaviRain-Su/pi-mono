const std = @import("std");
const resource_types = @import("types.zig");

const Theme = resource_types.Theme;

fn envThemeName(env_map: ?*const std.process.Environ.Map) ?[]const u8 {
    const raw = if (env_map) |map| map.get("PI_THEME") else return null;
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

pub fn resolveThemeIndex(
    themes: []const Theme,
    env_map: ?*const std.process.Environ.Map,
    runtime_theme: ?[]const u8,
    project_theme: ?[]const u8,
    global_theme: ?[]const u8,
) usize {
    const candidates = [_]?[]const u8{
        envThemeName(env_map),
        runtime_theme,
        project_theme,
        global_theme,
        detectDefaultThemeName(env_map),
    };
    for (candidates) |candidate| {
        if (findThemeIndex(themes, candidate)) |index| return index;
    }
    return 0;
}

fn detectDefaultThemeName(env_map: ?*const std.process.Environ.Map) []const u8 {
    const colorfgbg = resourceEnvValue(env_map, "COLORFGBG");
    const value = colorfgbg orelse return "dark";

    var parts = std.mem.splitScalar(u8, value, ';');
    _ = parts.next() orelse return "dark";
    const bg_text = parts.next() orelse return "dark";
    const bg = std.fmt.parseInt(u8, std.mem.trim(u8, bg_text, " \t\r\n"), 10) catch return "dark";
    return if (bg < 8) "dark" else "light";
}

pub fn resourceEnvValue(env_map: ?*const std.process.Environ.Map, comptime key: [:0]const u8) ?[]const u8 {
    const raw = if (env_map) |map| map.get(key) else cEnvValue(key);
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn cEnvValue(comptime key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

pub fn detectTerminalName(allocator: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) ![]u8 {
    const map = env_map orelse return try allocator.dupe(u8, "term");

    if (nonEmptyEnv(map, "TMUX") != null) return try allocator.dupe(u8, "tmux");

    if (nonEmptyEnv(map, "TERM_PROGRAM")) |term_program| {
        if (std.ascii.eqlIgnoreCase(term_program, "Apple_Terminal")) return try allocator.dupe(u8, "terminal");
        if (std.ascii.eqlIgnoreCase(term_program, "iTerm.app")) return try allocator.dupe(u8, "iterm");
        if (std.ascii.eqlIgnoreCase(term_program, "Ghostty")) return try allocator.dupe(u8, "ghostty");
        if (std.ascii.eqlIgnoreCase(term_program, "WezTerm")) return try allocator.dupe(u8, "wezterm");
        if (std.ascii.eqlIgnoreCase(term_program, "vscode")) return try allocator.dupe(u8, "vscode");
        if (std.ascii.eqlIgnoreCase(term_program, "Hyper")) return try allocator.dupe(u8, "hyper");
        if (std.ascii.eqlIgnoreCase(term_program, "tabby")) return try allocator.dupe(u8, "tabby");
        if (std.ascii.eqlIgnoreCase(term_program, "kitty")) return try allocator.dupe(u8, "kitty");
        if (std.ascii.eqlIgnoreCase(term_program, "Alacritty")) return try allocator.dupe(u8, "alacritty");

        const lower = try allocator.alloc(u8, term_program.len);
        return std.ascii.lowerString(lower, term_program);
    }

    if (nonEmptyEnv(map, "KITTY_WINDOW_ID") != null) return try allocator.dupe(u8, "kitty");
    if (nonEmptyEnv(map, "ALACRITTY_LOG") != null) return try allocator.dupe(u8, "alacritty");
    if (nonEmptyEnv(map, "WT_SESSION") != null) return try allocator.dupe(u8, "wt");

    if (nonEmptyEnv(map, "ConEmuANSI")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "ON")) return try allocator.dupe(u8, "conemu");
    }
    if (nonEmptyEnv(map, "TERMINAL_EMULATOR")) |value| {
        if (std.mem.startsWith(u8, value, "JetBrains")) return try allocator.dupe(u8, "jetbrains");
    }

    if (nonEmptyEnv(map, "TERM")) |term| {
        if (std.mem.startsWith(u8, term, "alacritty")) return try allocator.dupe(u8, "alacritty");
        if (std.mem.startsWith(u8, term, "xterm-kitty")) return try allocator.dupe(u8, "kitty");
        if (std.mem.startsWith(u8, term, "screen")) return try allocator.dupe(u8, "screen");
        if (std.mem.startsWith(u8, term, "tmux")) return try allocator.dupe(u8, "tmux");
        if (std.mem.startsWith(u8, term, "xterm")) return try allocator.dupe(u8, "xterm");
    }

    return try allocator.dupe(u8, "term");
}

fn nonEmptyEnv(env_map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env_map.get(key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

pub fn findThemeIndex(themes: []const Theme, name: ?[]const u8) ?usize {
    const theme_name = name orelse return null;
    for (themes, 0..) |theme, index| {
        if (std.mem.eql(u8, theme.name, theme_name)) return index;
    }
    return null;
}
