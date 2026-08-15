const std = @import("std");
const tui = @import("tui");
const core = @import("shared").keybindings_core;
const keybinding_matcher = @import("keybinding_matcher.zig");

pub const Action = core.Action;
pub const EditorAction = core.EditorAction;
pub const KeySpec = core.KeySpec;
pub const ACTION_COUNT = core.ACTION_COUNT;
pub const EDITOR_ACTION_COUNT = core.EDITOR_ACTION_COUNT;
pub const parseKeySpec = core.parseKeySpec;
pub const altModifierDisplayName = core.altModifierDisplayName;
pub const actionId = core.actionId;
pub const editorActionId = core.editorActionId;
pub const keySpecMatches = keybinding_matcher.keySpecMatches;

const MatchContext = struct {
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
};

fn matchContext(spec: KeySpec, context: MatchContext) bool {
    return keySpecMatches(spec, context.key, context.modifiers);
}

pub const Keybindings = struct {
    core: core.Keybindings,

    pub fn initDefaults(allocator: std.mem.Allocator) !Keybindings {
        return .{ .core = try core.Keybindings.initDefaults(allocator) };
    }

    pub fn deinit(self: *Keybindings) void {
        self.core.deinit();
        self.* = undefined;
    }

    pub fn setBinding(self: *Keybindings, action: Action, specs: []const KeySpec) !void {
        try self.core.setBinding(action, specs);
    }

    pub fn setEditorBinding(self: *Keybindings, action: EditorAction, specs: []const KeySpec) !void {
        try self.core.setEditorBinding(action, specs);
    }

    pub fn actionForKey(self: *const Keybindings, key: tui.Key) ?Action {
        return self.actionForKeyWithModifiers(key, .{});
    }

    pub fn actionForKeyWithModifiers(
        self: *const Keybindings,
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
    ) ?Action {
        return self.core.actionForMatch(MatchContext{ .key = key, .modifiers = modifiers }, matchContext);
    }

    pub fn editorActionForKeyWithModifiers(
        self: *const Keybindings,
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
    ) ?EditorAction {
        return self.core.editorActionForMatch(MatchContext{ .key = key, .modifiers = modifiers }, matchContext);
    }

    pub fn matchesAction(
        self: *const Keybindings,
        action: Action,
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
    ) bool {
        return self.core.matchesActionForMatch(action, MatchContext{ .key = key, .modifiers = modifiers }, matchContext);
    }

    pub fn matchesEditorAction(
        self: *const Keybindings,
        action: EditorAction,
        key: tui.Key,
        modifiers: tui.keys.KeyModifiers,
    ) bool {
        return self.core.matchesEditorActionForMatch(action, MatchContext{ .key = key, .modifiers = modifiers }, matchContext);
    }

    pub fn bindingForAction(self: *const Keybindings, action: Action) []const KeySpec {
        return self.core.bindingForAction(action);
    }

    pub fn bindingForEditorAction(self: *const Keybindings, action: EditorAction) []const KeySpec {
        return self.core.bindingForEditorAction(action);
    }

    pub fn primaryLabel(self: *const Keybindings, allocator: std.mem.Allocator, action: Action) ![]u8 {
        return self.core.primaryLabel(allocator, action);
    }
};

pub fn defaultEditorActionForKeyWithModifiers(
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) ?EditorAction {
    return core.defaultEditorActionForMatch(MatchContext{ .key = key, .modifiers = modifiers }, matchContext);
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Keybindings {
    return .{ .core = try core.loadFromFile(allocator, io, path) };
}

test "keybinding facade resolves app defaults through TUI matcher" {
    const allocator = std.testing.allocator;
    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();

    try std.testing.expectEqual(Action.interrupt, defaults.actionForKey(.escape).?);
    try std.testing.expectEqual(Action.clear, defaults.actionForKey(.{ .ctrl = 'c' }).?);
    try std.testing.expectEqual(Action.exit, defaults.actionForKey(.{ .ctrl = 'd' }).?);
    try std.testing.expectEqual(Action.model_cycleBackward, defaults.actionForKeyWithModifiers(.{ .ctrl = 'p' }, .{ .shift = true }).?);
    try std.testing.expectEqual(Action.tree_editLabel, defaults.actionForKeyWithModifiers(
        .{ .printable = tui.keys.PrintableKey.fromSlice("L") },
        .{ .shift = true },
    ).?);
}

test "keybinding facade resolves editor defaults through TUI matcher" {
    try std.testing.expectEqual(EditorAction.input_submit, defaultEditorActionForKeyWithModifiers(.enter, .{}).?);
    try std.testing.expectEqual(EditorAction.input_new_line, defaultEditorActionForKeyWithModifiers(.enter, .{ .shift = true }).?);
    try std.testing.expectEqual(EditorAction.cursor_word_left, defaultEditorActionForKeyWithModifiers(.left, .{ .alt = true }).?);
}

test "keybinding facade loadFromFile preserves existing API" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "app.clear": "ctrl+x",
        \\  "tui.input.submit": "ctrl+j"
        \\}
        ,
    });

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "keybindings.json" });
    defer allocator.free(config_path);

    var loaded = try loadFromFile(allocator, std.testing.io, config_path);
    defer loaded.deinit();

    try std.testing.expectEqual(Action.clear, loaded.actionForKey(.{ .ctrl = 'x' }).?);
    try std.testing.expect(loaded.actionForKey(.{ .ctrl = 'c' }) == null);
    try std.testing.expectEqual(EditorAction.input_submit, loaded.editorActionForKeyWithModifiers(.{ .ctrl = 'j' }, .{}).?);
}

test "keybinding facade exposes labels and bindings" {
    const allocator = std.testing.allocator;
    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();

    try std.testing.expectEqualDeep(KeySpec{ .ctrl = 'c' }, defaults.bindingForAction(.clear)[0]);
    const label = try defaults.primaryLabel(allocator, .clear);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("Ctrl+C", label);
}
