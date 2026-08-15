const std = @import("std");

pub const TerminalFlavor = enum {
    ghostty,
    kitty,
    wezterm,
    iterm,
    vscode,
    alacritty,
    unknown,
};

pub const ImageProtocol = enum {
    kitty,
    iterm2,
};

pub const KeyboardProtocolReason = enum {
    none,
    ghostty_ime,
};

pub const TerminalEnvParts = struct {
    term_program: []const u8 = "",
    term: []const u8 = "",
    color_term: []const u8 = "",
    ghostty_resources_dir_present: bool = false,
    tmux_present: bool = false,
    kitty_window_id_present: bool = false,
    wezterm_pane_present: bool = false,
    iterm_session_id_present: bool = false,
    pi_enable_mouse: ?[]const u8 = null,
};

pub const TerminalIdentity = struct {
    flavor: TerminalFlavor,
    inside_tmux_or_screen: bool,

    pub fn detect(env_map: *const std.process.Environ.Map) TerminalIdentity {
        return detectIdentity(.{
            .term_program = envValue(env_map, "TERM_PROGRAM"),
            .term = envValue(env_map, "TERM"),
            .ghostty_resources_dir_present = env_map.get("GHOSTTY_RESOURCES_DIR") != null,
            .tmux_present = env_map.get("TMUX") != null,
            .kitty_window_id_present = env_map.get("KITTY_WINDOW_ID") != null,
            .wezterm_pane_present = env_map.get("WEZTERM_PANE") != null,
            .iterm_session_id_present = env_map.get("ITERM_SESSION_ID") != null,
        });
    }
};

pub const DetectOptions = struct {
    allow_tmux_images: bool = false,
    allow_tmux_hyperlinks: bool = false,
};

pub const TerminalFeatures = struct {
    flavor: TerminalFlavor,
    inside_tmux_or_screen: bool,
    image_protocol: ?ImageProtocol,
    keyboard_protocol_allowed: bool,
    keyboard_protocol_reason: KeyboardProtocolReason = .none,
    true_color: bool,
    hyperlinks: bool,
    mouse_reporting: bool,
    osc_9_4_progress: bool,
    osc_133_semantic_zones: bool,
    osc_777_notify: bool,
};

pub fn detect(env_map: *const std.process.Environ.Map, options: DetectOptions) TerminalFeatures {
    return detectFromParts(.{
        .term_program = envValue(env_map, "TERM_PROGRAM"),
        .term = envValue(env_map, "TERM"),
        .color_term = envValue(env_map, "COLORTERM"),
        .ghostty_resources_dir_present = env_map.get("GHOSTTY_RESOURCES_DIR") != null,
        .tmux_present = env_map.get("TMUX") != null,
        .kitty_window_id_present = env_map.get("KITTY_WINDOW_ID") != null,
        .wezterm_pane_present = env_map.get("WEZTERM_PANE") != null,
        .iterm_session_id_present = env_map.get("ITERM_SESSION_ID") != null,
        .pi_enable_mouse = env_map.get("PI_ENABLE_MOUSE"),
    }, options);
}

pub fn detectCurrentProcess(options: DetectOptions) TerminalFeatures {
    return detectFromParts(.{
        .term_program = getenv("TERM_PROGRAM"),
        .term = getenv("TERM"),
        .color_term = getenv("COLORTERM"),
        .ghostty_resources_dir_present = getenv("GHOSTTY_RESOURCES_DIR").len > 0,
        .tmux_present = getenv("TMUX").len > 0,
        .kitty_window_id_present = getenv("KITTY_WINDOW_ID").len > 0,
        .wezterm_pane_present = getenv("WEZTERM_PANE").len > 0,
        .iterm_session_id_present = getenv("ITERM_SESSION_ID").len > 0,
        .pi_enable_mouse = blk: {
            const value = getenv("PI_ENABLE_MOUSE");
            break :blk if (value.len == 0) null else value;
        },
    }, options);
}

pub fn detectFromParts(parts: TerminalEnvParts, options: DetectOptions) TerminalFeatures {
    const identity = detectIdentity(parts);
    const true_color = std.ascii.eqlIgnoreCase(parts.color_term, "truecolor") or std.ascii.eqlIgnoreCase(parts.color_term, "24bit") or switch (identity.flavor) {
        .ghostty, .kitty, .wezterm, .iterm, .vscode, .alacritty => true,
        .unknown => false,
    };
    const keyboard_allowed = identity.flavor != .ghostty;

    const image_protocol: ?ImageProtocol = if (identity.inside_tmux_or_screen and !options.allow_tmux_images)
        null
    else switch (identity.flavor) {
        .ghostty, .kitty, .wezterm => .kitty,
        .iterm => .iterm2,
        .vscode, .alacritty, .unknown => null,
    };

    const hyperlinks = if (identity.inside_tmux_or_screen and !options.allow_tmux_hyperlinks)
        false
    else switch (identity.flavor) {
        .ghostty, .kitty, .wezterm, .iterm, .vscode, .alacritty => true,
        .unknown => false,
    };

    return .{
        .flavor = identity.flavor,
        .inside_tmux_or_screen = identity.inside_tmux_or_screen,
        .image_protocol = image_protocol,
        .keyboard_protocol_allowed = keyboard_allowed,
        .keyboard_protocol_reason = if (keyboard_allowed) .none else .ghostty_ime,
        .true_color = true_color,
        .hyperlinks = hyperlinks,
        .mouse_reporting = detectMouseReporting(parts.pi_enable_mouse),
        .osc_9_4_progress = identity.flavor == .ghostty,
        .osc_133_semantic_zones = switch (identity.flavor) {
            .ghostty, .kitty, .wezterm, .iterm => true,
            .vscode, .alacritty, .unknown => false,
        },
        .osc_777_notify = switch (identity.flavor) {
            .ghostty, .wezterm, .iterm => true,
            .kitty, .vscode, .alacritty, .unknown => false,
        },
    };
}

fn detectIdentity(parts: TerminalEnvParts) TerminalIdentity {
    const inside_tmux_or_screen = parts.tmux_present or
        startsWithIgnoreCase(parts.term, "tmux") or
        startsWithIgnoreCase(parts.term, "screen");

    if (parts.ghostty_resources_dir_present or std.ascii.eqlIgnoreCase(parts.term_program, "ghostty") or containsIgnoreCase(parts.term, "ghostty")) {
        return .{ .flavor = .ghostty, .inside_tmux_or_screen = inside_tmux_or_screen };
    }
    if (parts.kitty_window_id_present or std.ascii.eqlIgnoreCase(parts.term_program, "kitty")) {
        return .{ .flavor = .kitty, .inside_tmux_or_screen = inside_tmux_or_screen };
    }
    if (parts.wezterm_pane_present or std.ascii.eqlIgnoreCase(parts.term_program, "wezterm")) {
        return .{ .flavor = .wezterm, .inside_tmux_or_screen = inside_tmux_or_screen };
    }
    if (parts.iterm_session_id_present or std.ascii.eqlIgnoreCase(parts.term_program, "iterm.app")) {
        return .{ .flavor = .iterm, .inside_tmux_or_screen = inside_tmux_or_screen };
    }
    if (std.ascii.eqlIgnoreCase(parts.term_program, "vscode")) {
        return .{ .flavor = .vscode, .inside_tmux_or_screen = inside_tmux_or_screen };
    }
    if (std.ascii.eqlIgnoreCase(parts.term_program, "alacritty")) {
        return .{ .flavor = .alacritty, .inside_tmux_or_screen = inside_tmux_or_screen };
    }
    return .{ .flavor = .unknown, .inside_tmux_or_screen = inside_tmux_or_screen };
}

fn detectMouseReporting(value: ?[]const u8) bool {
    const raw = value orelse return true;
    if (std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off"))
    {
        return false;
    }
    return true;
}

fn envValue(env_map: *const std.process.Environ.Map, key: []const u8) []const u8 {
    return env_map.get(key) orelse "";
}

fn getenv(name: [*:0]const u8) []const u8 {
    const value = std.c.getenv(name) orelse return "";
    return std.mem.span(value);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    return std.ascii.startsWithIgnoreCase(haystack, needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "detect ghostty direct terminal features" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TERM_PROGRAM", "Ghostty");
    try env_map.put("COLORTERM", "truecolor");

    const features = detect(&env_map, .{});
    try std.testing.expectEqual(TerminalFlavor.ghostty, features.flavor);
    try std.testing.expectEqual(@as(?ImageProtocol, .kitty), features.image_protocol);
    try std.testing.expect(!features.keyboard_protocol_allowed);
    try std.testing.expectEqual(KeyboardProtocolReason.ghostty_ime, features.keyboard_protocol_reason);
    try std.testing.expect(features.true_color);
    try std.testing.expect(features.hyperlinks);
    try std.testing.expect(features.osc_9_4_progress);
    try std.testing.expect(features.osc_133_semantic_zones);
    try std.testing.expect(features.osc_777_notify);
}

test "detect ghostty inside tmux downgrades images and hyperlinks" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TERM_PROGRAM", "Ghostty");
    try env_map.put("TMUX", "/tmp/tmux-1000/default,1234,0");

    const features = detect(&env_map, .{});
    try std.testing.expect(features.inside_tmux_or_screen);
    try std.testing.expectEqual(@as(?ImageProtocol, null), features.image_protocol);
    try std.testing.expect(!features.hyperlinks);
    try std.testing.expect(!features.keyboard_protocol_allowed);
}

test "detect kitty direct terminal features" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TERM_PROGRAM", "kitty");

    const features = detect(&env_map, .{});
    try std.testing.expectEqual(TerminalFlavor.kitty, features.flavor);
    try std.testing.expectEqual(@as(?ImageProtocol, .kitty), features.image_protocol);
    try std.testing.expect(features.keyboard_protocol_allowed);
    try std.testing.expect(features.hyperlinks);
}

test "detect mouse reporting honors PI_ENABLE_MOUSE false values" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PI_ENABLE_MOUSE", "off");

    const features = detect(&env_map, .{});
    try std.testing.expect(!features.mouse_reporting);
}
