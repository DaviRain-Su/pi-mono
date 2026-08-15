const std = @import("std");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");

pub const ResolvedInputKey = union(enum) {
    app_action: keybindings_mod.Action,
    editor_action: keybindings_mod.EditorAction,
    submit_enter,
    suppress_legacy_app_default,
    suppress_legacy_editor_default,
    pass_to_editor,
};

pub const ResolutionMode = enum {
    normal,
    autocomplete,
};

pub fn resolveInputKey(
    keybindings: ?*const keybindings_mod.Keybindings,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    mode: ResolutionMode,
) ResolvedInputKey {
    switch (mode) {
        .autocomplete => {
            if (resolveEditorAction(keybindings, key, modifiers)) |editor_action| {
                return .{ .editor_action = editor_action };
            }
            if (keybindings != null and keybindings_mod.defaultEditorActionForKeyWithModifiers(key, modifiers) != null) {
                return .suppress_legacy_editor_default;
            }
            return .pass_to_editor;
        },
        .normal => {
            if (resolveParsedAppAction(keybindings, key, modifiers)) |action| {
                return .{ .app_action = action };
            }
            if (keybindings != null and isLegacyParsedAppActionKey(key, modifiers)) {
                return .suppress_legacy_app_default;
            }
            if (resolveEditorAction(keybindings, key, modifiers)) |editor_action| {
                return .{ .editor_action = editor_action };
            }
            if (keybindings != null and keybindings_mod.defaultEditorActionForKeyWithModifiers(key, modifiers) != null) {
                return .suppress_legacy_editor_default;
            }
            if (key == .enter and !modifiers.hasAny()) {
                return .submit_enter;
            }
            return .pass_to_editor;
        },
    }
}

pub fn resolveEditorAction(
    keybindings: ?*const keybindings_mod.Keybindings,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) ?keybindings_mod.EditorAction {
    if (keybindings) |bindings| return bindings.editorActionForKeyWithModifiers(key, modifiers);
    return keybindings_mod.defaultEditorActionForKeyWithModifiers(key, modifiers);
}

pub fn resolveAppAction(keybindings: ?*const keybindings_mod.Keybindings, key: tui.Key) ?keybindings_mod.Action {
    if (keybindings) |bindings| return bindings.actionForKey(key);
    return legacyAppActionForKey(key);
}

pub fn resolveParsedAppAction(
    keybindings: ?*const keybindings_mod.Keybindings,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) ?keybindings_mod.Action {
    if (keybindings) |bindings| return bindings.actionForKeyWithModifiers(key, modifiers);
    return legacyParsedAppActionForKey(key, modifiers);
}

pub fn legacyAppActionForKey(key: tui.Key) ?keybindings_mod.Action {
    return legacyParsedAppActionForKey(key, .{});
}

pub fn legacyParsedAppActionForKey(
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) ?keybindings_mod.Action {
    if (modifiers.alt and !modifiers.shift and !modifiers.ctrl and !modifiers.super) {
        return switch (key) {
            .enter => .message_followUp,
            .up => .message_dequeue,
            else => null,
        };
    }

    if (modifiers.shift and !modifiers.alt and !modifiers.ctrl and !modifiers.super) {
        return switch (key) {
            .shift_tab => .thinking_cycle,
            else => null,
        };
    }

    if (modifiers.shift and modifiers.ctrl and !modifiers.alt and !modifiers.super) {
        return switch (key) {
            .ctrl => |ctrl| switch (ctrl) {
                'p' => .model_cycleBackward,
                else => null,
            },
            else => null,
        };
    }

    if (modifiers.hasAny()) return null;

    return switch (key) {
        .ctrl => |ctrl| switch (ctrl) {
            'c' => .clear,
            'd' => .exit,
            'l' => .model_select,
            'o' => .tools_expand,
            't' => .thinking_toggle,
            'n' => .session_toggleNamedFilter,
            'g' => .editor_external,
            'v' => .clipboard_pasteImage,
            'z' => .app_suspend,
            'p' => .model_cycleForward,
            else => null,
        },
        .escape => .interrupt,
        .shift_tab => .thinking_cycle,
        else => null,
    };
}

pub fn isLegacyAppActionKey(key: tui.Key) bool {
    return legacyAppActionForKey(key) != null;
}

pub fn isLegacyParsedAppActionKey(key: tui.Key, modifiers: tui.keys.KeyModifiers) bool {
    return legacyParsedAppActionForKey(key, modifiers) != null;
}

test "input resolver uses configured app binding and suppresses rebound legacy default" {
    const allocator = std.testing.allocator;
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.clear, &.{.{ .ctrl = 'x' }});

    try std.testing.expectEqual(
        ResolvedInputKey{ .app_action = .clear },
        resolveInputKey(&keybindings, .{ .ctrl = 'x' }, .{}, .normal),
    );
    try std.testing.expectEqual(
        ResolvedInputKey.suppress_legacy_app_default,
        resolveInputKey(&keybindings, .{ .ctrl = 'c' }, .{}, .normal),
    );
}

test "input resolver uses configured editor binding and suppresses rebound legacy default" {
    const allocator = std.testing.allocator;
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setEditorBinding(.cursor_left, &.{.{ .ctrl = 'h' }});

    try std.testing.expectEqual(
        ResolvedInputKey{ .editor_action = .cursor_left },
        resolveInputKey(&keybindings, .{ .ctrl = 'h' }, .{}, .normal),
    );
    try std.testing.expectEqual(
        ResolvedInputKey.suppress_legacy_editor_default,
        resolveInputKey(&keybindings, .left, .{}, .normal),
    );
}

test "input resolver preserves app-before-editor priority in normal mode" {
    const allocator = std.testing.allocator;
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.clear, &.{.{ .ctrl = 'x' }});
    try keybindings.setEditorBinding(.input_submit, &.{.{ .ctrl = 'x' }});

    try std.testing.expectEqual(
        ResolvedInputKey{ .app_action = .clear },
        resolveInputKey(&keybindings, .{ .ctrl = 'x' }, .{}, .normal),
    );
}

test "input resolver preserves editor priority while autocomplete is open" {
    const allocator = std.testing.allocator;
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.clear, &.{.{ .ctrl = 'x' }});
    try keybindings.setEditorBinding(.select_confirm, &.{.{ .ctrl = 'x' }});

    try std.testing.expectEqual(
        ResolvedInputKey{ .editor_action = .select_confirm },
        resolveInputKey(&keybindings, .{ .ctrl = 'x' }, .{}, .autocomplete),
    );
}
