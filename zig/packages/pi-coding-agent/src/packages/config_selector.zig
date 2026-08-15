const std = @import("std");
const common = @import("../tools/common.zig");
const package_settings_store = @import("package_settings_store.zig");
const tui_mod = @import("tui");

pub const ConfigKind = package_settings_store.ConfigKind;

// ---------------------------------------------------------------------
// Config Selector: interactive TUI for bare `pi config` on a TTY.
// The state machine (ConfigSelectorState) is kept separate from the
// vaxis draw/input loop so automated tests can exercise key handling
// without spawning a real terminal.
// ---------------------------------------------------------------------

/// A single toggleable entry loaded from a settings.json kind array.
pub const ConfigSelectorEntry = struct {
    kind: ConfigKind,
    /// Pattern without +/- prefix; owned by the allocator.
    pattern: []u8,
    /// Current enabled state: +pattern = true, -/! pattern = false.
    enabled: bool,
    /// Set to true when the user toggles this entry in the selector.
    changed: bool = false,

    fn deinit(self: *ConfigSelectorEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }
};

/// Pure state machine for the interactive config selector. Contains no
/// vaxis types so tests can drive it without starting a terminal.
pub const ConfigSelectorState = struct {
    entries: std.ArrayList(ConfigSelectorEntry),
    selected: usize = 0,

    pub fn deinit(self: *ConfigSelectorState, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.entries = .empty;
        self.selected = 0;
    }

    /// Move cursor up (wraps around).
    pub fn moveUp(self: *ConfigSelectorState) void {
        if (self.entries.items.len == 0) return;
        if (self.selected == 0) {
            self.selected = self.entries.items.len - 1;
        } else {
            self.selected -= 1;
        }
    }

    /// Move cursor down (wraps around).
    pub fn moveDown(self: *ConfigSelectorState) void {
        if (self.entries.items.len == 0) return;
        self.selected = (self.selected + 1) % self.entries.items.len;
    }

    /// Toggle the enabled state of the currently selected entry.
    pub fn toggleSelected(self: *ConfigSelectorState) void {
        if (self.selected >= self.entries.items.len) return;
        const entry = &self.entries.items[self.selected];
        entry.enabled = !entry.enabled;
        entry.changed = true;
    }

    /// Returns true if any entry was toggled since the state was loaded.
    pub fn hasChanges(self: *const ConfigSelectorState) bool {
        for (self.entries.items) |entry| {
            if (entry.changed) return true;
        }
        return false;
    }
};

/// Load all toggleable entries from settings.json for a single scope.
/// Each array entry in extensions/skills/prompts/themes becomes a
/// ConfigSelectorEntry with its current +/- enabled state.
pub fn loadSelectorState(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
) !ConfigSelectorState {
    var state = ConfigSelectorState{ .entries = .empty };
    errdefer state.deinit(allocator);

    var settings_object = try package_settings_store.loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const kinds = [_]ConfigKind{ .extensions, .skills, .prompts, .themes };
    for (kinds) |kind| {
        const key = kind.settingsKey();
        const value = settings_object.get(key) orelse continue;
        if (value != .array) continue;
        for (value.array.items) |item| {
            if (item != .string) continue;
            const raw = item.string;
            if (raw.len == 0) continue;
            const has_prefix = raw[0] == '+' or raw[0] == '-' or raw[0] == '!';
            const enabled = !has_prefix or raw[0] == '+';
            const pat = if (has_prefix) raw[1..] else raw;
            if (pat.len == 0) continue;
            const pattern_owned = try allocator.dupe(u8, pat);
            errdefer allocator.free(pattern_owned);
            try state.entries.append(allocator, .{
                .kind = kind,
                .pattern = pattern_owned,
                .enabled = enabled,
            });
        }
    }
    return state;
}

/// Write all changed entries from the selector state back to settings.json.
/// Mirrors the --toggle semantics: remove old +/-/! entry for the same
/// pattern, then append the new +/- entry.
/// Does nothing when no entries were changed (file is left untouched).
pub fn saveSelectorState(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
    state: *const ConfigSelectorState,
) !void {
    if (!state.hasChanges()) return;
    var settings_object = try package_settings_store.loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    for (state.entries.items) |entry| {
        if (!entry.changed) continue;
        try package_settings_store.setConfigKindPattern(allocator, &settings_object, entry.kind, entry.pattern, entry.enabled);
    }

    try package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, .{});
}

/// Options for the interactive config selector TUI runner.
pub const ConfigSelectorRunOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    settings_path: []const u8,
};

/// Run the interactive config selector TUI. Initializes a vaxis terminal,
/// renders the selector, processes keyboard input, and persists changes on
/// Enter. Exits cleanly on Esc or q without writing changes.
pub fn runConfigSelector(opts: ConfigSelectorRunOptions) !void {
    var state = try loadSelectorState(opts.allocator, opts.io, opts.settings_path);
    defer state.deinit(opts.allocator);

    var terminal = tui_mod.Terminal.initNative(.{
        .io = opts.io,
        .env_map = opts.env_map,
    });
    try terminal.start();
    defer terminal.stop();

    var input_loop = try terminal.initInputLoop(opts.allocator, opts.io, opts.env_map);
    defer input_loop.deinit();
    input_loop.vaxis_state.queryTerminal(input_loop.loop.tty.writer(), .fromMilliseconds(250)) catch {};

    var renderer = tui_mod.Renderer.init(opts.allocator, &terminal);
    defer renderer.deinit();

    var should_quit = false;
    var should_save = false;

    while (!should_quit) {
        const screen = ConfigSelectorScreen{ .state = &state };
        try renderer.renderToVaxis(
            screen.drawComponent(),
            input_loop.vaxis_state,
            input_loop.loop.tty.writer(),
        );

        var got_input = false;
        while (try input_loop.tryInputEvent()) |event| {
            defer event.deinit(opts.allocator);
            got_input = true;
            switch (event.parsed.event) {
                .key => |key| switch (key) {
                    .up => state.moveUp(),
                    .down => state.moveDown(),
                    .enter => {
                        should_save = true;
                        should_quit = true;
                    },
                    .escape => should_quit = true,
                    .ctrl => |c| if (c == 'c') {
                        should_quit = true;
                    },
                    .printable => |pk| {
                        const s = pk.slice();
                        if (std.mem.eql(u8, s, " ")) {
                            state.toggleSelected();
                        } else if (std.mem.eql(u8, s, "q")) {
                            should_quit = true;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        if (!got_input) {
            std.Io.sleep(opts.io, .fromMilliseconds(50), .awake) catch {};
        }
    }

    if (should_save and state.hasChanges()) {
        try saveSelectorState(opts.allocator, opts.io, opts.settings_path, &state);
    }
}

/// Vaxis draw component for the config selector screen.
const ConfigSelectorScreen = struct {
    state: *const ConfigSelectorState,

    pub fn drawComponent(self: *const ConfigSelectorScreen) tui_mod.DrawComponent {
        return .{ .ptr = self, .drawFn = drawOpaque };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui_mod.vaxis.Window,
        ctx: tui_mod.DrawContext,
    ) std.mem.Allocator.Error!tui_mod.DrawSize {
        _ = ctx;
        const self: *const ConfigSelectorScreen = @ptrCast(@alignCast(ptr));
        return self.draw(window);
    }

    pub fn draw(
        self: *const ConfigSelectorScreen,
        window: tui_mod.vaxis.Window,
    ) std.mem.Allocator.Error!tui_mod.DrawSize {
        window.clear();
        var row: u16 = 0;

        row = drawSelectorLine(window, row, "Config Selector");
        row = drawSelectorLine(window, row, "Up/Down navigate  Space toggle  Enter save  Esc/q cancel");
        if (row < window.height) row += 1; // blank line

        const entries = self.state.entries.items;
        if (entries.len == 0) {
            row = drawSelectorLine(window, row, "  No entries in settings. Use --toggle to add entries.");
        } else {
            // Compute scroll offset to keep selected entry visible.
            const header_rows: usize = row;
            const visible: usize = if (window.height > header_rows) window.height - header_rows else 0;
            const scroll: usize = blk: {
                if (visible == 0) break :blk 0;
                const sel = self.state.selected;
                const half = visible / 2;
                if (sel < half) break :blk 0;
                const max_s = if (entries.len > visible) entries.len - visible else 0;
                break :blk @min(sel - half, max_s);
            };

            for (entries, 0..) |entry, i| {
                if (i < scroll) continue;
                if (row >= window.height) break;
                const cursor: []const u8 = if (i == self.state.selected) "> " else "  ";
                const checkbox: []const u8 = if (entry.enabled) "[x]" else "[ ]";
                const kind_label = entry.kind.settingsKey();
                var item_buf: [256]u8 = undefined;
                const item_line = std.fmt.bufPrint(
                    &item_buf,
                    "{s}{s} {s}: {s}",
                    .{ cursor, checkbox, kind_label, entry.pattern },
                ) catch entry.pattern;
                row = drawSelectorLine(window, row, item_line);
            }
        }

        return .{ .width = window.width, .height = row };
    }
};

fn drawSelectorLine(window: tui_mod.vaxis.Window, row: u16, text: []const u8) u16 {
    if (row >= window.height) return row;
    const line_win = window.child(.{ .y_off = row, .height = 1 });
    _ = line_win.printSegment(.{ .text = text }, .{ .wrap = .none });
    return row + 1;
}
