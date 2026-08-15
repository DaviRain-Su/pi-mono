const std = @import("std");

pub const KeyId = []const u8;
pub const Keybinding = []const u8;

pub const KeybindingDefinition = struct {
    id: Keybinding,
    default_keys: []const KeyId,
    description: ?[]const u8 = null,
};

pub const KeybindingConflict = struct {
    key: KeyId,
    keybindings: []const Keybinding,
};

pub const TUI_KEYBINDINGS = [_]KeybindingDefinition{
    .{ .id = "tui.editor.cursorUp", .default_keys = &.{"up"}, .description = "Move cursor up" },
    .{ .id = "tui.editor.cursorDown", .default_keys = &.{"down"}, .description = "Move cursor down" },
    .{ .id = "tui.editor.cursorLeft", .default_keys = &.{ "left", "ctrl+b" }, .description = "Move cursor left" },
    .{ .id = "tui.editor.cursorRight", .default_keys = &.{ "right", "ctrl+f" }, .description = "Move cursor right" },
    .{ .id = "tui.editor.cursorWordLeft", .default_keys = &.{ "alt+left", "ctrl+left", "alt+b" }, .description = "Move cursor word left" },
    .{ .id = "tui.editor.cursorWordRight", .default_keys = &.{ "alt+right", "ctrl+right", "alt+f" }, .description = "Move cursor word right" },
    .{ .id = "tui.editor.cursorLineStart", .default_keys = &.{ "home", "ctrl+a" }, .description = "Move to line start" },
    .{ .id = "tui.editor.cursorLineEnd", .default_keys = &.{ "end", "ctrl+e" }, .description = "Move to line end" },
    .{ .id = "tui.editor.jumpForward", .default_keys = &.{"ctrl+]"}, .description = "Jump forward to character" },
    .{ .id = "tui.editor.jumpBackward", .default_keys = &.{"ctrl+alt+]"}, .description = "Jump backward to character" },
    .{ .id = "tui.editor.pageUp", .default_keys = &.{"pageUp"}, .description = "Page up" },
    .{ .id = "tui.editor.pageDown", .default_keys = &.{"pageDown"}, .description = "Page down" },
    .{ .id = "tui.editor.deleteCharBackward", .default_keys = &.{"backspace"}, .description = "Delete character backward" },
    .{ .id = "tui.editor.deleteCharForward", .default_keys = &.{ "delete", "ctrl+d" }, .description = "Delete character forward" },
    .{ .id = "tui.editor.deleteWordBackward", .default_keys = &.{ "ctrl+w", "alt+backspace" }, .description = "Delete word backward" },
    .{ .id = "tui.editor.deleteWordForward", .default_keys = &.{ "alt+d", "alt+delete" }, .description = "Delete word forward" },
    .{ .id = "tui.editor.deleteToLineStart", .default_keys = &.{"ctrl+u"}, .description = "Delete to line start" },
    .{ .id = "tui.editor.deleteToLineEnd", .default_keys = &.{"ctrl+k"}, .description = "Delete to line end" },
    .{ .id = "tui.editor.yank", .default_keys = &.{"ctrl+y"}, .description = "Yank" },
    .{ .id = "tui.editor.yankPop", .default_keys = &.{"alt+y"}, .description = "Yank pop" },
    .{ .id = "tui.editor.undo", .default_keys = &.{"ctrl+-"}, .description = "Undo" },
    .{ .id = "tui.input.newLine", .default_keys = &.{"shift+enter"}, .description = "Insert newline" },
    .{ .id = "tui.input.submit", .default_keys = &.{"enter"}, .description = "Submit input" },
    .{ .id = "tui.input.tab", .default_keys = &.{"tab"}, .description = "Tab / autocomplete" },
    .{ .id = "tui.input.copy", .default_keys = &.{"ctrl+c"}, .description = "Copy selection" },
    .{ .id = "tui.select.up", .default_keys = &.{"up"}, .description = "Move selection up" },
    .{ .id = "tui.select.down", .default_keys = &.{"down"}, .description = "Move selection down" },
    .{ .id = "tui.select.pageUp", .default_keys = &.{"pageUp"}, .description = "Selection page up" },
    .{ .id = "tui.select.pageDown", .default_keys = &.{"pageDown"}, .description = "Selection page down" },
    .{ .id = "tui.select.confirm", .default_keys = &.{"enter"}, .description = "Confirm selection" },
    .{ .id = "tui.select.cancel", .default_keys = &.{ "escape", "ctrl+c" }, .description = "Cancel selection" },
};

pub const UserBinding = struct {
    id: Keybinding,
    keys: []const KeyId,
};

pub const KeybindingsManager = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap([]const KeyId),
    conflicts: std.ArrayList(KeybindingConflict) = .empty,
    owned_slices: std.ArrayList([]const KeyId) = .empty,
    owned_conflict_lists: std.ArrayList([]const Keybinding) = .empty,

    pub fn init(allocator: std.mem.Allocator, user_bindings: []const UserBinding) !KeybindingsManager {
        var manager = KeybindingsManager{
            .allocator = allocator,
            .bindings = std.StringHashMap([]const KeyId).init(allocator),
        };
        errdefer manager.deinit();
        try manager.rebuild(user_bindings);
        return manager;
    }

    pub fn initDefaults(allocator: std.mem.Allocator) !KeybindingsManager {
        return init(allocator, &.{});
    }

    pub fn deinit(self: *KeybindingsManager) void {
        self.bindings.deinit();
        for (self.owned_slices.items) |slice| self.allocator.free(slice);
        self.owned_slices.deinit(self.allocator);
        for (self.owned_conflict_lists.items) |slice| self.allocator.free(slice);
        self.owned_conflict_lists.deinit(self.allocator);
        self.conflicts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn matches(self: *const KeybindingsManager, data: []const u8, keybinding: Keybinding) bool {
        const keys = self.bindings.get(keybinding) orelse return false;
        for (keys) |key| {
            if (matchesKey(data, key)) return true;
        }
        return false;
    }

    pub fn getKeys(self: *const KeybindingsManager, keybinding: Keybinding) []const KeyId {
        return self.bindings.get(keybinding) orelse &.{};
    }

    pub fn getDefinition(_: *const KeybindingsManager, keybinding: Keybinding) ?KeybindingDefinition {
        return definitionFor(keybinding);
    }

    pub fn getConflicts(self: *const KeybindingsManager) []const KeybindingConflict {
        return self.conflicts.items;
    }

    fn rebuild(self: *KeybindingsManager, user_bindings: []const UserBinding) !void {
        for (TUI_KEYBINDINGS) |definition| {
            const user = findUserBinding(user_bindings, definition.id);
            const keys = if (user) |binding| binding.keys else definition.default_keys;
            const normalized = try normalizeKeys(self.allocator, keys);
            try self.owned_slices.append(self.allocator, normalized);
            try self.bindings.put(definition.id, normalized);
        }

        for (user_bindings, 0..) |left, i| {
            if (definitionFor(left.id) == null) continue;
            for (user_bindings[i + 1 ..]) |right| {
                if (definitionFor(right.id) == null) continue;
                for (left.keys) |left_key| {
                    for (right.keys) |right_key| {
                        if (!std.mem.eql(u8, left_key, right_key)) continue;
                        const conflict_bindings = try self.allocator.dupe(Keybinding, &.{ left.id, right.id });
                        try self.owned_conflict_lists.append(self.allocator, conflict_bindings);
                        try self.conflicts.append(self.allocator, .{ .key = left_key, .keybindings = conflict_bindings });
                    }
                }
            }
        }
    }
};

pub fn definitionFor(keybinding: Keybinding) ?KeybindingDefinition {
    for (TUI_KEYBINDINGS) |definition| {
        if (std.mem.eql(u8, definition.id, keybinding)) return definition;
    }
    return null;
}

pub fn matchesKey(data: []const u8, key_id: KeyId) bool {
    if (std.mem.eql(u8, key_id, "enter")) return std.mem.eql(u8, data, "\r") or std.mem.eql(u8, data, "\n");
    if (std.mem.eql(u8, key_id, "tab")) return std.mem.eql(u8, data, "\t");
    if (std.mem.eql(u8, key_id, "escape")) return std.mem.eql(u8, data, "\x1b");
    if (std.mem.eql(u8, key_id, "backspace")) return std.mem.eql(u8, data, "\x7f") or std.mem.eql(u8, data, "\x08");
    if (std.mem.startsWith(u8, key_id, "ctrl+") and key_id.len == 6) {
        const c = std.ascii.toLower(key_id[5]);
        if (c >= 'a' and c <= 'z') return data.len == 1 and data[0] == c - 'a' + 1;
    }
    return std.mem.eql(u8, data, key_id);
}

fn findUserBinding(bindings: []const UserBinding, id: Keybinding) ?UserBinding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.id, id)) return binding;
    }
    return null;
}

fn normalizeKeys(allocator: std.mem.Allocator, keys: []const KeyId) ![]const KeyId {
    var out = std.ArrayList(KeyId).empty;
    errdefer out.deinit(allocator);
    for (keys) |key| {
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, key)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(allocator, key);
    }
    return out.toOwnedSlice(allocator);
}

test "KeybindingsManager matches defaults and reports user conflicts" {
    var manager = try KeybindingsManager.init(std.testing.allocator, &.{
        .{ .id = "tui.input.submit", .keys = &.{"ctrl+x"} },
        .{ .id = "tui.input.copy", .keys = &.{"ctrl+x"} },
    });
    defer manager.deinit();

    try std.testing.expect(manager.matches("\x18", "tui.input.submit"));
    try std.testing.expectEqual(@as(usize, 1), manager.getConflicts().len);
}
