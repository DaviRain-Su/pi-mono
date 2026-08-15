const std = @import("std");
const ai = @import("ai");
const auth = @import("../auth/auth.zig");
const config_mod = @import("../config/config.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const session_manager_mod = @import("../sessions/session_manager.zig");
const tui = @import("tui");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const session_overlay_mod = @import("session_overlay.zig");
const model_overlay_mod = @import("model_overlay.zig");
const tree_overlay_mod = @import("tree_overlay.zig");
const settings_overlay_mod = @import("settings_overlay.zig");
const extension_dialog_mod = @import("extension_dialog.zig");
const overlay_table = @import("overlay_table.zig");
const settingsResources = shared.settingsResources;
const blocksToText = formatting.blocksToText;
const formatAssistantMessage = formatting.formatAssistantMessage;

pub const SelectorOverlay = union(enum) {
    info: InfoOverlay,
    settings: SettingsOverlay,
    settings_editor: SettingsEditorOverlay,
    session: SessionOverlay,
    model: ModelOverlay,
    scoped_models: ScopedModelsOverlay,
    theme: ThemeOverlay,
    tree: TreeOverlay,
    fork: ForkOverlay,
    auth: AuthOverlay,
    extension_dialog: ExtensionDialog,

    pub fn deinit(self: *SelectorOverlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*overlay| overlay.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn title(self: *const SelectorOverlay) []const u8 {
        return switch (self.*) {
            .info => self.info.title,
            .settings => "Settings",
            .settings_editor => self.settings_editor.title,
            .session => self.session.title,
            .model => self.model.title,
            .scoped_models => "Scoped model selector",
            .theme => "Theme selector",
            .tree => tree_overlay_mod.title(&self.tree),
            .fork => "Fork from Message",
            .auth => if (self.auth.mode == .login) "Login" else "Logout",
            .extension_dialog => self.extension_dialog.title,
        };
    }

    pub fn hint(self: *const SelectorOverlay) []const u8 {
        return switch (self.*) {
            .info => self.info.hint,
            .settings => self.settings.hint,
            .settings_editor => self.settings_editor.hint,
            .model => self.model.hint,
            .session => self.session.hint,
            .scoped_models => self.scoped_models.hint,
            .fork => "Up/Down move • Enter fork • Esc cancel",
            .tree => tree_overlay_mod.hint(&self.tree),
            .extension_dialog => self.extension_dialog.hint,
            else => "Up/Down move • Enter select • Esc cancel",
        };
    }
};

pub const ExtensionDialog = extension_dialog_mod.ExtensionDialog;

pub const InfoOverlay = struct {
    title: []u8,
    hint: []u8,
    items: []tui.SelectItem,
    list: tui.SelectList,

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 12 }, .{ .fill = 1 } },

    pub fn deinit(self: *InfoOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.hint);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub const SettingsEditorOverlay = struct {
    title: []u8,
    hint: []u8,
    path: []u8,
    editor: tui.Editor,

    pub fn deinit(self: *SettingsEditorOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.hint);
        allocator.free(self.path);
        self.editor.deinit();
        self.* = undefined;
    }
};

pub const SettingsOverlay = settings_overlay_mod.Overlay;
pub const SettingId = settings_overlay_mod.SettingId;
pub const SettingsMode = settings_overlay_mod.Mode;

pub const SessionChoice = session_overlay_mod.SessionChoice;
pub const SessionScope = session_overlay_mod.SessionScope;
pub const SessionSortMode = session_overlay_mod.SessionSortMode;
pub const SessionNameFilter = session_overlay_mod.SessionNameFilter;
pub const SessionOverlay = session_overlay_mod.SessionOverlay;

pub const ModelChoice = model_overlay_mod.ModelChoice;
pub const ModelScope = model_overlay_mod.ModelScope;
pub const ModelOverlay = model_overlay_mod.ModelOverlay;
pub const ScopedModelChoice = model_overlay_mod.ScopedModelChoice;
pub const ScopedModelsOverlay = model_overlay_mod.ScopedModelsOverlay;

pub const ThemeChoice = struct {
    name: []u8,
};

pub const ThemeOverlay = struct {
    choices: []ThemeChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 2 }, .{ .fill = 1 } },

    pub fn deinit(self: *ThemeOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| allocator.free(choice.name);
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub const TreeChoice = tree_overlay_mod.Choice;
pub const TreeOverlay = tree_overlay_mod.Overlay;

pub const ForkChoice = struct {
    entry_id: []u8,
    text: []u8,
};

pub const ForkOverlay = struct {
    choices: []ForkChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 4 }, .{ .fill = 1 } },

    pub fn deinit(self: *ForkOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| {
            allocator.free(choice.entry_id);
            allocator.free(choice.text);
        }
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub const AuthOverlayMode = enum {
    login,
    logout,
};

pub const AuthChoice = struct {
    provider_id: []u8,
    provider_name: []u8,
    auth_type: auth.ProviderAuthType,
};

pub const AuthOverlay = struct {
    mode: AuthOverlayMode,
    choices: []AuthChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    // Table rendering data
    table_rows: []tui.TableRow = &.{},
    table_cells: []tui.TableCell = &.{},
    table_state: tui.TableState = .{},
    table_widths: []const tui.Constraint = &.{ .{ .length = 2 }, .{ .fill = 1 }, .{ .length = 18 } },

    pub fn deinit(self: *AuthOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| {
            allocator.free(choice.provider_id);
            allocator.free(choice.provider_name);
        }
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        overlay_table.freeTable(allocator, self.table_cells, self.table_rows);
        self.* = undefined;
    }
};

pub const AuthFlow = union(enum) {
    browser_redirect: PendingBrowserRedirect,
    copilot_device: auth.CopilotDeviceLogin,
    api_key: PendingApiKeyEntry,

    pub fn deinit(self: *AuthFlow, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .browser_redirect => |*value| value.deinit(allocator),
            .copilot_device => |*value| value.deinit(allocator),
            .api_key => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const PendingBrowserRedirect = struct {
    session: auth.BrowserLoginSession,
    callback_listener: ?*auth.OAuthCallbackListener = null,

    pub fn deinit(self: *PendingBrowserRedirect, allocator: std.mem.Allocator) void {
        if (self.callback_listener) |listener| listener.destroy();
        self.session.deinit(allocator);
        self.* = undefined;
    }
};

pub const PendingApiKeyEntry = struct {
    provider_id: []const u8,
    provider_name: []const u8,

    pub fn deinit(self: *PendingApiKeyEntry, _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

pub fn loadAuthOverlay(
    allocator: std.mem.Allocator,
    mode: AuthOverlayMode,
    providers: ?[]const auth.ProviderInfo,
) !SelectorOverlay {
    const source = providers orelse auth.SUPPORTED_PROVIDERS[0..];
    const choices = try allocator.alloc(AuthChoice, source.len);
    errdefer {
        for (choices) |choice| {
            allocator.free(choice.provider_id);
            allocator.free(choice.provider_name);
        }
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, source.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    if (source.len == 0) {
        return .{
            .auth = .{
                .mode = mode,
                .choices = choices,
                .items = items,
                .list = .{
                    .items = items,
                    .max_visible = 8,
                },
            },
        };
    }

    const table_cells = try allocator.alloc(tui.TableCell, source.len * 3);
    errdefer allocator.free(table_cells);
    const table_rows = try allocator.alloc(tui.TableRow, source.len);
    errdefer allocator.free(table_rows);

    for (source, 0..) |provider, index| {
        choices[index] = .{
            .provider_id = try allocator.dupe(u8, provider.id),
            .provider_name = try allocator.dupe(u8, provider.name),
            .auth_type = provider.auth_type,
        };
        items[index] = .{
            .value = try allocator.dupe(u8, provider.id),
            .label = try allocator.dupe(u8, provider.name),
            .description = try allocator.dupe(
                u8,
                switch (mode) {
                    .login => if (provider.auth_type == .oauth) "OAuth login" else "API key login",
                    .logout => if (provider.auth_type == .oauth) "Stored OAuth credentials" else "Stored API key",
                },
            ),
        };
        const cell_start = index * 3;
        table_cells[cell_start] = .{ .text = " " };
        table_cells[cell_start + 1] = .{ .text = provider.name };
        table_cells[cell_start + 2] = .{ .text = switch (mode) {
            .login => if (provider.auth_type == .oauth) "OAuth" else "API key",
            .logout => if (provider.auth_type == .oauth) "OAuth" else "API key",
        } };
        table_rows[index] = .{ .cells = table_cells[cell_start .. cell_start + 3] };
    }

    return .{
        .auth = .{
            .mode = mode,
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .max_visible = 8,
            },
            .table_cells = table_cells,
            .table_rows = table_rows,
            .table_state = .{},
        },
    };
}

pub fn loadSettingsEditorOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    theme: ?*const resources_mod.Theme,
) !SelectorOverlay {
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "settings.json" });
    errdefer allocator.free(settings_path);

    const initial_content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{\n}\n"),
        else => return err,
    };
    defer allocator.free(initial_content);

    var editor = tui.Editor.init(allocator);
    errdefer editor.deinit();
    editor.padding_x = 1;
    editor.autocomplete_max_visible = 8;
    editor.setEditorStyle(if (theme) |t| tui.styleFor(t, .editor) else .{});
    _ = try editor.handlePaste(initial_content);

    return .{
        .settings_editor = .{
            .title = try allocator.dupe(u8, "Settings"),
            .hint = try allocator.dupe(u8, "Edit settings.json • Ctrl+S save • Esc cancel"),
            .path = settings_path,
            .editor = editor,
        },
    };
}

pub fn loadSettingsOverlay(
    allocator: std.mem.Allocator,
    runtime_config: ?*const config_mod.RuntimeConfig,
    session: *const session_mod.AgentSession,
    themes: []const resources_mod.Theme,
    active_theme: ?*const resources_mod.Theme,
    supports_images: bool,
) !SelectorOverlay {
    return .{
        .settings = try settings_overlay_mod.load(allocator, runtime_config, session, themes, active_theme, supports_images),
    };
}

pub fn refreshSettingsOverlay(allocator: std.mem.Allocator, overlay: *SettingsOverlay) !void {
    return settings_overlay_mod.refresh(allocator, overlay);
}

pub fn updateSettingsSearch(allocator: std.mem.Allocator, overlay: *SettingsOverlay, next_search: []const u8) !void {
    return settings_overlay_mod.updateSearch(allocator, overlay, next_search);
}

pub fn enterSettingsMode(allocator: std.mem.Allocator, overlay: *SettingsOverlay, mode: SettingsMode) !void {
    return settings_overlay_mod.enterMode(allocator, overlay, mode);
}

pub fn exitSettingsSubmenu(allocator: std.mem.Allocator, overlay: *SettingsOverlay) !void {
    return settings_overlay_mod.exitSubmenu(allocator, overlay);
}

pub fn selectedSettingsChoice(overlay: *const SettingsOverlay) ?settings_overlay_mod.Choice {
    return settings_overlay_mod.selectedChoice(overlay);
}

pub fn loadHotkeysOverlay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
) !SelectorOverlay {
    var items = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        freeOwnedSelectItems(allocator, items.items);
        items.deinit(allocator);
    }

    const bindings = keybindings orelse {
        try appendInfoOverlayItem(allocator, &items, "Hotkeys", try allocator.dupe(u8, "Keybindings unavailable"));
        return try loadInfoOverlay(
            allocator,
            "Keyboard shortcuts",
            "Up/Down scroll • Enter close • Esc close",
            try items.toOwnedSlice(allocator),
            10,
        );
    };

    try appendHotkeyOverlayItem(allocator, &items, bindings, .interrupt, "Cancel autocomplete or abort streaming");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .clear, "Clear editor/display; press twice within 500ms to exit");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .exit, "Exit when editor is empty");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .app_suspend, "Suspend to background");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .model_cycleForward, "Cycle to next model");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .model_cycleBackward, "Cycle to previous model");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .model_select, "Open the model selector");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .session_resume, "Open the session selector");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .session_tree, "Open the session tree");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .session_fork, "Fork the current session");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .session_new, "Start a new session");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .message_followUp, "Queue follow-up message");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .message_dequeue, "Restore queued messages");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .tools_expand, "Toggle tool output expansion");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .thinking_cycle, "Cycle thinking level");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .thinking_toggle, "Toggle thinking block visibility");
    try appendInfoOverlayItem(allocator, &items, "Enter", try allocator.dupe(u8, "Submit the current prompt"));
    try appendInfoOverlayItem(allocator, &items, "Tab", try allocator.dupe(u8, "Accept the selected autocomplete entry"));
    try appendInfoOverlayItem(allocator, &items, "/", try allocator.dupe(u8, "Start a slash command"));
    try appendInfoOverlayItem(allocator, &items, "!", try allocator.dupe(u8, "Run a bash command"));
    try appendInfoOverlayItem(allocator, &items, "!!", try allocator.dupe(u8, "Run a bash command without adding output to context"));

    return try loadInfoOverlay(
        allocator,
        "Keyboard shortcuts",
        "Up/Down scroll • Enter close • Esc close",
        try items.toOwnedSlice(allocator),
        24,
    );
}

pub fn loadInfoOverlay(
    allocator: std.mem.Allocator,
    title: []const u8,
    hint: []const u8,
    items: []tui.SelectItem,
    max_visible: usize,
) !SelectorOverlay {
    const table_cells = try allocator.alloc(tui.TableCell, items.len * 2);
    const table_rows = try allocator.alloc(tui.TableRow, items.len);
    for (items, 0..) |item, i| {
        table_cells[i * 2] = .{ .text = item.label };
        table_cells[i * 2 + 1] = .{ .text = item.description orelse "" };
        table_rows[i] = .{ .cells = table_cells[i * 2 .. i * 2 + 2] };
    }

    return .{
        .info = .{
            .title = try allocator.dupe(u8, title),
            .hint = try allocator.dupe(u8, hint),
            .items = items,
            .list = .{
                .items = items,
                .max_visible = max_visible,
            },
            .table_cells = table_cells,
            .table_rows = table_rows,
            .table_state = .{},
        },
    };
}

pub fn appendInfoOverlayItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(tui.SelectItem),
    label: []const u8,
    description: []u8,
) !void {
    errdefer allocator.free(description);
    const value = try allocator.dupe(u8, label);
    errdefer allocator.free(value);
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    try items.append(allocator, .{
        .value = value,
        .label = owned_label,
        .description = description,
    });
}

pub fn appendHotkeyOverlayItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(tui.SelectItem),
    keybindings: *const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    description: []const u8,
) !void {
    const label = try keybindings.primaryLabel(allocator, action);
    errdefer allocator.free(label);
    const value = try allocator.dupe(u8, label);
    errdefer allocator.free(value);
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);
    try items.append(allocator, .{
        .value = value,
        .label = label,
        .description = owned_description,
    });
}

pub const freeOwnedSelectItems = overlay_table.freeOwnedSelectItems;

pub fn loadSessionOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    current_session_path: ?[]const u8,
) !SelectorOverlay {
    return .{ .session = try session_overlay_mod.load(allocator, io, session_dir, current_session_path) };
}

pub fn refreshSessionOverlay(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.refresh(allocator, overlay);
}

pub fn toggleSessionOverlayScope(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.toggleScope(allocator, overlay);
}

pub fn toggleSessionOverlaySort(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.toggleSort(allocator, overlay);
}

pub fn toggleSessionOverlayNameFilter(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.toggleNameFilter(allocator, overlay);
}

pub fn toggleSessionOverlayPath(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.togglePath(allocator, overlay);
}

pub fn updateSessionOverlaySearch(allocator: std.mem.Allocator, overlay: *SessionOverlay, next_search: []const u8) !void {
    return session_overlay_mod.updateSearch(allocator, overlay, next_search);
}

pub fn moveSessionOverlaySelection(overlay: *SessionOverlay, delta: isize) void {
    session_overlay_mod.moveSelection(overlay, delta);
}

pub fn beginSessionOverlayDelete(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.beginDelete(allocator, overlay);
}

pub fn confirmSessionOverlayDelete(allocator: std.mem.Allocator, io: std.Io, overlay: *SessionOverlay) !void {
    return session_overlay_mod.confirmDelete(allocator, io, overlay);
}

pub fn cancelSessionOverlayDelete(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.cancelDelete(allocator, overlay);
}

pub fn enterSessionOverlayRename(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.enterRename(allocator, overlay);
}

pub fn cancelSessionOverlayRename(allocator: std.mem.Allocator, overlay: *SessionOverlay) !void {
    return session_overlay_mod.cancelRename(allocator, overlay);
}

pub fn confirmSessionOverlayRename(allocator: std.mem.Allocator, io: std.Io, overlay: *SessionOverlay) !void {
    return session_overlay_mod.confirmRename(allocator, io, overlay);
}

pub fn updateSessionOverlayRenameText(allocator: std.mem.Allocator, overlay: *SessionOverlay, next_text: []const u8) !void {
    return session_overlay_mod.updateRenameText(allocator, overlay, next_text);
}

pub fn loadModelOverlay(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !SelectorOverlay {
    return loadModelOverlayWithSearch(allocator, env_map, current_model, current_provider, model_patterns, runtime_config, null);
}

pub fn loadModelOverlayWithSearch(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
    initial_search: ?[]const u8,
) !SelectorOverlay {
    return .{ .model = try model_overlay_mod.loadWithSearch(allocator, env_map, current_model, current_provider, model_patterns, runtime_config, initial_search) };
}

pub fn refreshModelOverlay(allocator: std.mem.Allocator, overlay: *ModelOverlay) !void {
    return model_overlay_mod.refresh(allocator, overlay);
}

pub fn toggleModelOverlayScope(allocator: std.mem.Allocator, overlay: *ModelOverlay) !void {
    return model_overlay_mod.toggleScope(allocator, overlay);
}

pub fn updateModelOverlaySearch(allocator: std.mem.Allocator, overlay: *ModelOverlay, next_search: []const u8) !void {
    return model_overlay_mod.updateSearch(allocator, overlay, next_search);
}

pub fn loadThemeOverlay(
    allocator: std.mem.Allocator,
    themes: []const resources_mod.Theme,
    active_theme: ?*const resources_mod.Theme,
) !SelectorOverlay {
    const choices = try allocator.alloc(ThemeChoice, themes.len);
    errdefer {
        for (choices) |choice| allocator.free(choice.name);
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, themes.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    const active_name = if (active_theme) |theme| theme.name else "";
    var selected_index: usize = 0;
    for (themes, 0..) |theme, index| {
        const is_active = std.mem.eql(u8, theme.name, active_name);
        choices[index] = .{
            .name = try allocator.dupe(u8, theme.name),
        };
        items[index] = .{
            .value = try allocator.dupe(u8, theme.name),
            .label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ if (is_active) "✓" else " ", theme.name }),
            .description = try allocator.dupe(u8, if (is_active) "active theme" else "available theme"),
        };
        if (is_active) selected_index = index;
    }

    const table_cells = try allocator.alloc(tui.TableCell, themes.len * 2);
    errdefer allocator.free(table_cells);
    const table_rows = try allocator.alloc(tui.TableRow, themes.len);
    errdefer allocator.free(table_rows);

    for (themes, 0..) |theme, index| {
        const is_active = std.mem.eql(u8, theme.name, active_name);
        const cell_start = index * 2;
        table_cells[cell_start] = .{ .text = if (is_active) "✓" else " " };
        table_cells[cell_start + 1] = .{ .text = theme.name };
        table_rows[index] = .{ .cells = table_cells[cell_start .. cell_start + 2] };
    }

    return .{
        .theme = .{
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
            .table_cells = table_cells,
            .table_rows = table_rows,
            .table_state = .{ .selected_index = selected_index },
        },
    };
}

pub fn loadScopedModelOverlay(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    enabled_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !SelectorOverlay {
    return .{ .scoped_models = try model_overlay_mod.loadScoped(allocator, env_map, current_model, current_provider, enabled_patterns, runtime_config) };
}

pub fn refreshScopedModelsOverlay(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    return model_overlay_mod.refreshScoped(allocator, overlay);
}

pub fn updateScopedModelsSearch(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay, next_search: []const u8) !void {
    return model_overlay_mod.updateScopedSearch(allocator, overlay, next_search);
}

pub fn toggleScopedModel(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    return model_overlay_mod.toggleScopedModel(allocator, overlay);
}

pub fn enableScopedModels(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    return model_overlay_mod.enableScopedModels(allocator, overlay);
}

pub fn clearScopedModels(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    return model_overlay_mod.clearScopedModels(allocator, overlay);
}

pub fn toggleScopedProvider(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay) !void {
    return model_overlay_mod.toggleScopedProvider(allocator, overlay);
}

pub fn reorderScopedModel(allocator: std.mem.Allocator, overlay: *ScopedModelsOverlay, delta: isize) !void {
    return model_overlay_mod.reorderScopedModel(allocator, overlay, delta);
}

pub fn loadSelectableModels(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) ![]provider_config.AvailableModel {
    return model_overlay_mod.loadSelectableModels(allocator, env_map, current_model, current_provider, model_patterns, runtime_config);
}

fn indexOfString(items: []const []const u8, needle: []const u8) ?usize {
    return model_overlay_mod.indexOfString(items, needle);
}

pub fn modelSupportsInput(input_types: []const []const u8, expected: []const u8) bool {
    for (input_types) |input_type| {
        if (std.ascii.eqlIgnoreCase(input_type, expected)) return true;
    }
    return false;
}

pub fn loadTreeOverlay(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
) !SelectorOverlay {
    return .{
        .tree = try tree_overlay_mod.load(allocator, session, .default),
    };
}

pub fn loadForkOverlay(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
) !SelectorOverlay {
    var choice_list = std.ArrayList(ForkChoice).empty;
    errdefer {
        for (choice_list.items) |choice| {
            allocator.free(choice.entry_id);
            allocator.free(choice.text);
        }
        choice_list.deinit(allocator);
    }

    var item_list = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        for (item_list.items) |item| {
            allocator.free(item.value);
            allocator.free(item.label);
            if (item.description) |description| allocator.free(description);
        }
        item_list.deinit(allocator);
    }

    for (session.session_manager.getEntries()) |entry| {
        if (entry != .message) continue;
        if (entry.message.message != .user) continue;

        const text = try blocksToText(allocator, entry.message.message.user.content);
        defer allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) continue;

        const label = try std.fmt.allocPrint(allocator, "{s}", .{trimSummaryText(trimmed)});
        errdefer allocator.free(label);
        const description = try std.fmt.allocPrint(allocator, "Message {d} of forkable history", .{choice_list.items.len + 1});
        errdefer allocator.free(description);

        try choice_list.append(allocator, .{
            .entry_id = try allocator.dupe(u8, entry.message.id),
            .text = try allocator.dupe(u8, trimmed),
        });
        try item_list.append(allocator, .{
            .value = try allocator.dupe(u8, entry.message.id),
            .label = label,
            .description = description,
        });
    }

    if (choice_list.items.len == 0) return error.NoMessagesToFork;

    const choices = try choice_list.toOwnedSlice(allocator);
    errdefer {
        for (choices) |choice| {
            allocator.free(choice.entry_id);
            allocator.free(choice.text);
        }
        allocator.free(choices);
    }
    const items = try item_list.toOwnedSlice(allocator);
    errdefer freeOwnedSelectItems(allocator, items);

    const table_cells = try allocator.alloc(tui.TableCell, items.len * 2);
    errdefer allocator.free(table_cells);
    const table_rows = try allocator.alloc(tui.TableRow, items.len);
    errdefer allocator.free(table_rows);

    for (items, 0..) |item, index| {
        const cell_start = index * 2;
        table_cells[cell_start] = .{ .text = item.description.? };
        table_cells[cell_start + 1] = .{ .text = item.label };
        table_rows[index] = .{ .cells = table_cells[cell_start .. cell_start + 2] };
    }

    return .{
        .fork = .{
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = items.len - 1,
                .max_visible = 10,
            },
            .table_cells = table_cells,
            .table_rows = table_rows,
            .table_state = .{ .selected_index = items.len - 1 },
        },
    };
}

pub fn appendTreeNodes(
    allocator: std.mem.Allocator,
    nodes: []const session_manager_mod.SessionTreeNode,
    depth: usize,
    current_leaf_id: ?[]const u8,
    choices: *std.ArrayList(TreeChoice),
    items: *std.ArrayList(tui.SelectItem),
    selected_index: *usize,
) !void {
    for (nodes) |node| {
        const prefix = try indentationPrefix(allocator, depth);
        defer allocator.free(prefix);
        const summary = try summarizeSessionEntry(allocator, node.entry.*);
        defer allocator.free(summary);
        const label = if (node.label) |entry_label|
            try std.fmt.allocPrint(allocator, "{s}[{s}] {s}", .{ prefix, entry_label, summary })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, summary });
        defer allocator.free(label);

        try choices.append(allocator, .{ .entry_id = try allocator.dupe(u8, node.entry.id()) });
        try items.append(allocator, .{
            .value = try allocator.dupe(u8, node.entry.id()),
            .label = try allocator.dupe(u8, label),
            .description = try allocator.dupe(u8, node.entry.timestamp()),
        });
        if (current_leaf_id) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, node.entry.id())) {
                selected_index.* = items.items.len - 1;
            }
        }

        try appendTreeNodes(allocator, node.children, depth + 1, current_leaf_id, choices, items, selected_index);
    }
}

pub fn indentationPrefix(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    const prefix = try allocator.alloc(u8, depth * 2);
    @memset(prefix, ' ');
    return prefix;
}

pub fn summarizeSessionEntry(allocator: std.mem.Allocator, entry: session_manager_mod.SessionEntry) ![]u8 {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| blk: {
                const text = try blocksToText(allocator, user_message.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "user: {s}", .{trimSummaryText(text)});
            },
            .assistant => |assistant_message| blk: {
                const text = try formatAssistantMessage(allocator, assistant_message);
                defer allocator.free(text);
                break :blk allocator.dupe(u8, trimSummaryText(text));
            },
            .tool_result => |tool_result| blk: {
                const text = try blocksToText(allocator, tool_result.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "tool {s}: {s}", .{ tool_result.tool_name, trimSummaryText(text) });
            },
        },
        .thinking_level_change => |thinking_entry| std.fmt.allocPrint(allocator, "thinking: {s}", .{@tagName(thinking_entry.thinking_level)}),
        .model_change => |model_entry| std.fmt.allocPrint(allocator, "model: {s}/{s}", .{ model_entry.provider, model_entry.model_id }),
        .compaction => |compaction_entry| std.fmt.allocPrint(allocator, "compaction: {s}", .{trimSummaryText(try session_manager_mod.getCompactionSummary(compaction_entry))}),
        .branch_summary => |branch_summary_entry| std.fmt.allocPrint(allocator, "branch summary: {s}", .{trimSummaryText(branch_summary_entry.summary)}),
        .custom => |custom_entry| std.fmt.allocPrint(allocator, "custom: {s}", .{custom_entry.custom_type}),
        .custom_message => |custom_message_entry| blk: {
            const text = switch (custom_message_entry.content) {
                .text => |value| try allocator.dupe(u8, value),
                .blocks => |blocks| try blocksToText(allocator, blocks),
            };
            defer allocator.free(text);
            break :blk std.fmt.allocPrint(
                allocator,
                "[{s}]: {s}",
                .{ custom_message_entry.custom_type, trimSummaryText(text) },
            );
        },
        .label => |label_entry| if (label_entry.label) |label|
            std.fmt.allocPrint(allocator, "label: {s}", .{label})
        else
            allocator.dupe(u8, "label cleared"),
        .session_info => |session_info_entry| if (session_info_entry.name) |name|
            std.fmt.allocPrint(allocator, "session name: {s}", .{name})
        else
            allocator.dupe(u8, "session name cleared"),
    };
}

pub fn trimSummaryText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len > 72) trimmed[0..72] else trimmed;
}

pub const SessionOverlayEntries = struct {
    paths: []SessionChoice,
    items: []tui.SelectItem,
};

pub fn listSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SessionOverlayEntries {
    var dir = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const paths = try allocator.alloc(SessionChoice, 1);
            const items = try allocator.alloc(tui.SelectItem, 1);
            paths[0] = .{ .path = try allocator.dupe(u8, "") };
            items[0] = .{
                .value = try allocator.dupe(u8, "none"),
                .label = try allocator.dupe(u8, "No sessions found"),
                .description = null,
            };
            return .{ .paths = paths, .items = items };
        },
        else => return err,
    };
    defer dir.close(io);

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .gt;
        }
    }.lessThan);

    const count = if (names.items.len == 0) @as(usize, 1) else names.items.len;
    const paths = try allocator.alloc(SessionChoice, count);
    errdefer {
        for (paths) |path| allocator.free(path.path);
        allocator.free(paths);
    }
    const items = try allocator.alloc(tui.SelectItem, count);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    if (names.items.len == 0) {
        paths[0] = .{ .path = try allocator.dupe(u8, "") };
        items[0] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No sessions found"),
            .description = null,
        };
        return .{ .paths = paths, .items = items };
    }

    for (names.items, 0..) |name, index| {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ session_dir, name });
        const display_name = try loadSessionDisplayName(allocator, io, path, name);
        errdefer allocator.free(display_name);
        paths[index] = .{ .path = path };
        items[index] = .{
            .value = try allocator.dupe(u8, name),
            .label = display_name,
            .description = try allocator.dupe(u8, path),
        };
    }

    return .{ .paths = paths, .items = items };
}

pub fn loadSessionDisplayName(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_path: []const u8,
    fallback_name: []const u8,
) ![]u8 {
    var manager = session_manager_mod.SessionManager.open(allocator, io, session_path, null) catch {
        return allocator.dupe(u8, fallback_name);
    };
    defer manager.deinit();

    if (manager.getSessionName()) |name| return allocator.dupe(u8, name);
    return allocator.dupe(u8, fallback_name);
}

test "loadModelOverlay groups configured providers and omits missing-auth providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("openai", "gpt-5.4").?;
    var overlay = try loadModelOverlay(allocator, &env_map, current_model, null, null, null);
    defer overlay.deinit(allocator);

    try std.testing.expectEqual(@as(std.meta.Tag(SelectorOverlay), .model), std.meta.activeTag(overlay));

    var saw_anthropic = false;
    var saw_grouped_openai = false;
    var saw_grouped_anthropic = false;
    var saw_google = false;
    for (overlay.model.items) |item| {
        if (std.mem.startsWith(u8, item.label, "Anthropic / ")) {
            saw_grouped_anthropic = true;
        }
        if (std.mem.startsWith(u8, item.label, "Google Gemini / ")) {
            saw_google = true;
        }
        if (std.mem.startsWith(u8, item.label, "OpenAI / ")) {
            saw_grouped_openai = true;
        }
        if (std.mem.eql(u8, item.value, "claude-sonnet-4-5")) {
            saw_anthropic = true;
        }
    }

    try std.testing.expect(saw_anthropic);
    try std.testing.expect(saw_grouped_openai);
    try std.testing.expect(saw_grouped_anthropic);
    try std.testing.expect(!saw_google);
}

test "loadModelOverlay marks current provider models available for runtime api key overrides" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        std.testing.io,
        &env_map,
        "openai",
        "gpt-5.4",
        "runtime-openai-key",
        null,
    );
    defer current_provider.deinit(allocator);

    var overlay = try loadModelOverlay(allocator, &env_map, current_provider.model, &current_provider, null, null);
    defer overlay.deinit(allocator);

    var saw_runtime_status = false;
    var saw_second_openai_model = false;
    for (overlay.model.items) |item| {
        if (std.mem.eql(u8, item.value, "gpt-5.5")) saw_second_openai_model = true;
        if (std.mem.indexOf(u8, item.description.?, "--api-key") != null) saw_runtime_status = true;
    }

    try std.testing.expect(saw_second_openai_model);
    try std.testing.expect(saw_runtime_status);
}

test "model overlay starts scoped, toggles all scope, and filters search tokens" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("openai", "gpt-5.4").?;
    const scoped = [_][]const u8{"anthropic/claude-sonnet-4-5"};
    var overlay = try loadModelOverlay(allocator, &env_map, current_model, null, scoped[0..], null);
    defer overlay.deinit(allocator);

    try std.testing.expectEqual(ModelScope.scoped, overlay.model.scope);
    try std.testing.expect(overlay.model.scoped_models.len > 0);
    try std.testing.expect(overlay.model.choices.len >= 1);
    var saw_scoped_anthropic = false;
    for (overlay.model.choices) |choice| {
        if (std.mem.eql(u8, choice.provider, "anthropic")) saw_scoped_anthropic = true;
    }
    try std.testing.expect(saw_scoped_anthropic);
    try std.testing.expect(std.mem.indexOf(u8, overlay.model.hint, "Scope: scoped") != null);

    try toggleModelOverlayScope(allocator, &overlay.model);
    try std.testing.expectEqual(ModelScope.all, overlay.model.scope);
    try std.testing.expect(overlay.model.choices.len > 1);
    try std.testing.expect(std.mem.indexOf(u8, overlay.model.hint, "Scope: all") != null);

    try updateModelOverlaySearch(allocator, &overlay.model, "openai gpt-5.4");
    try std.testing.expect(overlay.model.choices.len >= 1);
    for (overlay.model.choices) |choice| {
        if (choice.provider.len == 0) continue;
        try std.testing.expect(std.mem.indexOf(u8, choice.provider, "openai") != null);
        try std.testing.expect(std.mem.indexOf(u8, choice.model_id, "gpt-5.4") != null);
    }
}

test "scoped models overlay toggles filtered bulk and reorders enabled ids" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("openai", "gpt-5.4").?;
    const enabled = [_][]const u8{
        "openai/gpt-5.4",
        "anthropic/claude-sonnet-4-5",
    };
    var overlay = try loadScopedModelOverlay(allocator, &env_map, current_model, null, enabled[0..], null);
    defer overlay.deinit(allocator);

    try std.testing.expectEqual(@as(std.meta.Tag(SelectorOverlay), .scoped_models), std.meta.activeTag(overlay));
    try std.testing.expect(overlay.scoped_models.enabled_ids != null);
    try std.testing.expectEqual(@as(usize, 2), overlay.scoped_models.enabled_ids.?.len);
    try std.testing.expectEqualStrings("openai/gpt-5.4", overlay.scoped_models.enabled_ids.?[0]);

    try reorderScopedModel(allocator, &overlay.scoped_models, 1);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4-5", overlay.scoped_models.enabled_ids.?[0]);
    try std.testing.expect(overlay.scoped_models.dirty);
    try std.testing.expect(std.mem.indexOf(u8, overlay.scoped_models.hint, "(unsaved)") != null);

    try updateScopedModelsSearch(allocator, &overlay.scoped_models, "claude");
    try clearScopedModels(allocator, &overlay.scoped_models);
    try std.testing.expect(overlay.scoped_models.enabled_ids != null);
    try std.testing.expect(indexOfString(overlay.scoped_models.enabled_ids.?, "anthropic/claude-sonnet-4-5") == null);
    try std.testing.expect(indexOfString(overlay.scoped_models.enabled_ids.?, "openai/gpt-5.4") != null);

    try enableScopedModels(allocator, &overlay.scoped_models);
    try std.testing.expect(overlay.scoped_models.enabled_ids != null);
    try std.testing.expect(indexOfString(overlay.scoped_models.enabled_ids.?, "anthropic/claude-sonnet-4-5") != null);
}

test "session overlay search grammar filters regex phrases and named sessions" {
    const allocator = std.testing.allocator;

    const sessions = try allocator.alloc(session_manager_mod.SessionSearchInfo, 4);
    sessions[0] = try testSessionSearchInfo(allocator, "alpha", "/tmp/alpha.jsonl", "Real Name", "Brave node\n\n   cve");
    sessions[1] = try testSessionSearchInfo(allocator, "beta", "/tmp/beta.jsonl", "   ", "bravery node other");
    sessions[2] = try testSessionSearchInfo(allocator, "gamma", "/tmp/gamma.jsonl", null, "node cve");
    sessions[3] = try testSessionSearchInfo(allocator, "delta", "/tmp/delta.jsonl", "Named Two", "unrelated");

    const all_sessions = try session_overlay_mod.cloneSessionSearchInfos(allocator, sessions);
    var overlay = SessionOverlay{
        .title = try allocator.dupe(u8, ""),
        .hint = try allocator.dupe(u8, ""),
        .choices = try allocator.alloc(SessionChoice, 0),
        .items = try allocator.alloc(tui.SelectItem, 0),
        .list = .{ .items = &.{}, .max_visible = 12 },
        .current_sessions = sessions,
        .all_sessions = all_sessions,
    };
    defer overlay.deinit(allocator);

    try refreshSessionOverlay(allocator, &overlay);
    try updateSessionOverlaySearch(allocator, &overlay, "\"node cve\"");
    try std.testing.expectEqual(@as(usize, 2), nonEmptySessionChoiceCount(&overlay));

    try updateSessionOverlaySearch(allocator, &overlay, "re:\\bbrave\\b");
    try std.testing.expectEqual(@as(usize, 1), nonEmptySessionChoiceCount(&overlay));
    try std.testing.expect(sessionOverlayContainsLabel(&overlay, "Real Name"));

    try updateSessionOverlaySearch(allocator, &overlay, "re:(");
    try std.testing.expectEqual(@as(usize, 0), nonEmptySessionChoiceCount(&overlay));
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[0].label, "No sessions") != null);

    try updateSessionOverlaySearch(allocator, &overlay, "");
    try toggleSessionOverlayNameFilter(allocator, &overlay);
    try std.testing.expectEqual(@as(usize, 2), nonEmptySessionChoiceCount(&overlay));
    try std.testing.expect(std.mem.indexOf(u8, overlay.hint, "Name: Named") != null);
}

test "session overlay threads current path aliases clamps and mutates safely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sessions", .default_dir);

    const relative_session_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer allocator.free(relative_session_dir);
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const session_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_session_dir });
    defer allocator.free(session_dir);

    var parent = try session_manager_mod.SessionManager.create(allocator, std.testing.io, "/tmp/project", session_dir);
    _ = try parent.appendSessionInfo("Parent");
    const parent_path = try allocator.dupe(u8, parent.getSessionFile().?);
    defer allocator.free(parent_path);
    parent.deinit();

    var child = try session_manager_mod.SessionManager.createWithParent(allocator, std.testing.io, "/tmp/project", session_dir, parent_path);
    _ = try child.appendSessionInfo("Child");
    const child_path = try allocator.dupe(u8, child.getSessionFile().?);
    defer allocator.free(child_path);
    child.deinit();

    var selector = try loadSessionOverlay(allocator, std.testing.io, session_dir, parent_path);
    defer selector.deinit(allocator);
    const overlay = &selector.session;

    try std.testing.expectEqual(@as(usize, 2), nonEmptySessionChoiceCount(overlay));
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[0].description.?, "current") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay.items[1].label, "└─") != null);

    overlay.list.selected_index = 0;
    moveSessionOverlaySelection(overlay, -1);
    try std.testing.expectEqual(@as(usize, 0), overlay.list.selected_index);
    moveSessionOverlaySelection(overlay, 99);
    try std.testing.expectEqual(@as(usize, 1), overlay.list.selected_index);

    overlay.list.selected_index = 0;
    beginSessionOverlayDelete(allocator, overlay) catch |err| {
        try std.testing.expectEqual(error.CannotDeleteCurrentSession, err);
    };
    try std.testing.expectEqual(@as(?[]u8, null), overlay.confirming_delete_path);

    overlay.list.selected_index = 1;
    try enterSessionOverlayRename(allocator, overlay);
    try std.testing.expect(overlay.rename_mode);
    try updateSessionOverlayRenameText(allocator, overlay, "  Renamed Child  ");
    try confirmSessionOverlayRename(allocator, std.testing.io, overlay);
    var reopened_child = try session_manager_mod.SessionManager.open(allocator, std.testing.io, child_path, null);
    defer reopened_child.deinit();
    try std.testing.expectEqualStrings("Renamed Child", reopened_child.getSessionName().?);

    overlay.list.selected_index = 1;
    try beginSessionOverlayDelete(allocator, overlay);
    try confirmSessionOverlayDelete(allocator, std.testing.io, overlay);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(std.testing.io, child_path, .{}));
}

fn testSessionSearchInfo(
    allocator: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    name: ?[]const u8,
    text: []const u8,
) !session_manager_mod.SessionSearchInfo {
    return .{
        .path = try allocator.dupe(u8, path),
        .id = try allocator.dupe(u8, id),
        .cwd = try allocator.dupe(u8, "/tmp/project"),
        .name = if (name) |value| try allocator.dupe(u8, value) else null,
        .parent_session = null,
        .created_timestamp = try allocator.dupe(u8, "2026-01-01T00:00:00.000Z"),
        .modified_timestamp = try allocator.dupe(u8, "2026-01-01T00:00:00.000Z"),
        .message_count = 1,
        .first_message = try allocator.dupe(u8, text),
        .all_messages_text = try allocator.dupe(u8, text),
        .search_text = try std.fmt.allocPrint(allocator, "{s} {s} {s} /tmp/project", .{ id, name orelse "", text }),
    };
}

fn nonEmptySessionChoiceCount(overlay: *const SessionOverlay) usize {
    var count: usize = 0;
    for (overlay.choices) |choice| {
        if (choice.path.len > 0) count += 1;
    }
    return count;
}

fn sessionOverlayContainsLabel(overlay: *const SessionOverlay, needle: []const u8) bool {
    for (overlay.items) |item| {
        if (std.mem.indexOf(u8, item.label, needle) != null) return true;
    }
    return false;
}
