const std = @import("std");
const ai = @import("ai");
const tui = @import("tui");
const config_mod = @import("../config/config.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const session_mod = @import("../sessions/session.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const slash_commands = @import("slash_commands.zig");
const session_lifecycle = @import("session_lifecycle.zig");
const tree_overlay_mod = @import("tree_overlay.zig");

const AppState = rendering.AppState;
const SelectorOverlay = overlays.SelectorOverlay;
const navigateTree = session_lifecycle.navigateTree;
const persistEnabledModelSelection = slash_commands.persistEnabledModelSelection;
const toggleSessionOverlayScope = overlays.toggleSessionOverlayScope;
const toggleSessionOverlaySort = overlays.toggleSessionOverlaySort;
const toggleSessionOverlayNameFilter = overlays.toggleSessionOverlayNameFilter;
const toggleSessionOverlayPath = overlays.toggleSessionOverlayPath;
const updateSessionOverlaySearch = overlays.updateSessionOverlaySearch;
const moveSessionOverlaySelection = overlays.moveSessionOverlaySelection;
const beginSessionOverlayDelete = overlays.beginSessionOverlayDelete;
const confirmSessionOverlayDelete = overlays.confirmSessionOverlayDelete;
const cancelSessionOverlayDelete = overlays.cancelSessionOverlayDelete;
const enterSessionOverlayRename = overlays.enterSessionOverlayRename;
const cancelSessionOverlayRename = overlays.cancelSessionOverlayRename;
const confirmSessionOverlayRename = overlays.confirmSessionOverlayRename;
const updateSessionOverlayRenameText = overlays.updateSessionOverlayRenameText;
const toggleModelOverlayScope = overlays.toggleModelOverlayScope;
const updateModelOverlaySearch = overlays.updateModelOverlaySearch;
const updateScopedModelsSearch = overlays.updateScopedModelsSearch;
const toggleScopedModel = overlays.toggleScopedModel;
const enableScopedModels = overlays.enableScopedModels;
const clearScopedModels = overlays.clearScopedModels;
const toggleScopedProvider = overlays.toggleScopedProvider;
const reorderScopedModel = overlays.reorderScopedModel;

pub fn handleModelOverlayInteractiveKey(
    allocator: std.mem.Allocator,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    model_overlay: *overlays.ModelOverlay,
    keybindings: ?*const keybindings_mod.Keybindings,
) !bool {
    if (matchesEditorAction(keybindings, .input_tab, key, modifiers)) {
        try toggleModelOverlayScope(allocator, model_overlay);
        return true;
    }
    if (try updateSearchFromKey(allocator, model_overlay.search, key, modifiers)) |next_search| {
        defer allocator.free(next_search);
        try updateModelOverlaySearch(allocator, model_overlay, next_search);
        return true;
    }
    return false;
}

pub fn handleSessionOverlayInteractiveKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    session_overlay: *overlays.SessionOverlay,
    keybindings: ?*const keybindings_mod.Keybindings,
    app_state: *AppState,
) !bool {
    if (session_overlay.rename_mode) {
        if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
            try cancelSessionOverlayRename(allocator, session_overlay);
            return true;
        }
        if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
            try confirmSessionOverlayRename(allocator, io, session_overlay);
            try app_state.setStatus("Session renamed");
            return true;
        }
        if (try updateSearchFromKey(allocator, session_overlay.rename_text, key, modifiers)) |next_text| {
            defer allocator.free(next_text);
            try updateSessionOverlayRenameText(allocator, session_overlay, next_text);
            return true;
        }
        return true;
    }

    if (session_overlay.confirming_delete_path != null) {
        if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
            try cancelSessionOverlayDelete(allocator, session_overlay);
            return true;
        }
        if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
            try confirmSessionOverlayDelete(allocator, io, session_overlay);
            try app_state.setStatus("Session deleted");
            return true;
        }
        return true;
    }

    if (matchesEditorAction(keybindings, .input_tab, key, modifiers)) {
        try toggleSessionOverlayScope(allocator, session_overlay);
        return true;
    }
    if (matchesAction(keybindings, .session_toggleSort, key, modifiers)) {
        try toggleSessionOverlaySort(allocator, session_overlay);
        return true;
    }
    if (matchesAction(keybindings, .session_toggleNamedFilter, key, modifiers)) {
        try toggleSessionOverlayNameFilter(allocator, session_overlay);
        return true;
    }
    if (matchesAction(keybindings, .session_togglePath, key, modifiers)) {
        try toggleSessionOverlayPath(allocator, session_overlay);
        return true;
    }
    if (matchesAction(keybindings, .session_rename, key, modifiers)) {
        try enterSessionOverlayRename(allocator, session_overlay);
        return true;
    }
    if (matchesAction(keybindings, .session_delete, key, modifiers)) {
        beginSessionOverlayDelete(allocator, session_overlay) catch |err| switch (err) {
            error.CannotDeleteCurrentSession => try app_state.setStatus("Cannot delete the currently active session"),
            else => return err,
        };
        return true;
    }
    if (matchesAction(keybindings, .session_deleteNoninvasive, key, modifiers) and session_overlay.search.len == 0) {
        beginSessionOverlayDelete(allocator, session_overlay) catch |err| switch (err) {
            error.CannotDeleteCurrentSession => try app_state.setStatus("Cannot delete the currently active session"),
            else => return err,
        };
        return true;
    }

    if (matchesEditorAction(keybindings, .select_up, key, modifiers)) {
        moveSessionOverlaySelection(session_overlay, -1);
        return true;
    }
    if (matchesEditorAction(keybindings, .select_down, key, modifiers)) {
        moveSessionOverlaySelection(session_overlay, 1);
        return true;
    }
    if (matchesEditorAction(keybindings, .select_page_up, key, modifiers)) {
        moveSessionOverlaySelection(session_overlay, -@as(isize, @intCast(session_overlay.list.max_visible)));
        return true;
    }
    if (matchesEditorAction(keybindings, .select_page_down, key, modifiers)) {
        moveSessionOverlaySelection(session_overlay, @intCast(session_overlay.list.max_visible));
        return true;
    }

    if (try updateSearchFromKey(allocator, session_overlay.search, key, modifiers)) |next_search| {
        defer allocator.free(next_search);
        try updateSessionOverlaySearch(allocator, session_overlay, next_search);
        return true;
    }
    return false;
}

pub fn handleScopedModelsOverlayKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    scoped_overlay: *overlays.ScopedModelsOverlay,
    app_state: *AppState,
    runtime_config: ?*const config_mod.RuntimeConfig,
    keybindings: ?*const keybindings_mod.Keybindings,
    overlay: *?SelectorOverlay,
) !void {
    if (matchesEditorAction(keybindings, .select_up, key, modifiers)) {
        _ = scoped_overlay.list.handleKey(.up);
        return;
    }
    if (matchesEditorAction(keybindings, .select_down, key, modifiers)) {
        _ = scoped_overlay.list.handleKey(.down);
        return;
    }
    if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
        try toggleScopedModel(allocator, scoped_overlay);
        try applyScopedModelSelectionToRuntime(allocator, scoped_overlay, app_state);
        return;
    }
    if (matchesAction(keybindings, .models_enableAll, key, modifiers)) {
        try enableScopedModels(allocator, scoped_overlay);
        try applyScopedModelSelectionToRuntime(allocator, scoped_overlay, app_state);
        return;
    }
    if (matchesAction(keybindings, .models_clearAll, key, modifiers)) {
        try clearScopedModels(allocator, scoped_overlay);
        try applyScopedModelSelectionToRuntime(allocator, scoped_overlay, app_state);
        return;
    }
    if (matchesAction(keybindings, .models_toggleProvider, key, modifiers)) {
        try toggleScopedProvider(allocator, scoped_overlay);
        try applyScopedModelSelectionToRuntime(allocator, scoped_overlay, app_state);
        return;
    }
    if (matchesAction(keybindings, .models_reorderUp, key, modifiers)) {
        try reorderScopedModel(allocator, scoped_overlay, -1);
        try applyScopedModelSelectionToRuntime(allocator, scoped_overlay, app_state);
        return;
    }
    if (matchesAction(keybindings, .models_reorderDown, key, modifiers)) {
        try reorderScopedModel(allocator, scoped_overlay, 1);
        try applyScopedModelSelectionToRuntime(allocator, scoped_overlay, app_state);
        return;
    }
    if (matchesAction(keybindings, .models_save, key, modifiers)) {
        try persistEnabledModelSelection(allocator, io, runtime_config, scopedPatternsForRuntime(scoped_overlay));
        scoped_overlay.dirty = false;
        try overlays.refreshScopedModelsOverlay(allocator, scoped_overlay);
        try app_state.setStatus("Model selection saved to settings");
        return;
    }
    if (matchesAction(keybindings, .clear, key, modifiers)) {
        if (scoped_overlay.search.len > 0) {
            try updateScopedModelsSearch(allocator, scoped_overlay, "");
            return;
        }
        closeOverlay(allocator, overlay);
        return;
    }
    if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
        closeOverlay(allocator, overlay);
        return;
    }
    if (try updateSearchFromKey(allocator, scoped_overlay.search, key, modifiers)) |next_search| {
        defer allocator.free(next_search);
        try updateScopedModelsSearch(allocator, scoped_overlay, next_search);
        return;
    }
}

pub fn handleTreeOverlayInteractiveKey(
    allocator: std.mem.Allocator,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    tree_overlay: *overlays.TreeOverlay,
    session: *session_mod.AgentSession,
    app_state: *AppState,
    editor: *tui.Editor,
    runtime_config: ?*const config_mod.RuntimeConfig,
    keybindings: ?*const keybindings_mod.Keybindings,
    overlay: *?SelectorOverlay,
) !bool {
    if (tree_overlay.mode == .label) {
        if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
            try tree_overlay_mod.cancelLabelMode(allocator, tree_overlay);
            return true;
        }
        if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
            if (tree_overlay.label_target_id) |target_id| {
                const label = std.mem.trim(u8, tree_overlay.label_text, &std.ascii.whitespace);
                _ = try session.session_manager.appendLabelChange(target_id, if (label.len == 0) null else label);
                try tree_overlay_mod.applyLabelToNode(allocator, tree_overlay, target_id, if (label.len == 0) null else label, null);
                try app_state.setStatus(if (label.len == 0) "label cleared" else "label updated");
            }
            return true;
        }
        if (try updateSearchFromKey(allocator, tree_overlay.label_text, key, modifiers)) |next_text| {
            defer allocator.free(next_text);
            try tree_overlay_mod.updateLabelText(allocator, tree_overlay, next_text);
            return true;
        }
        return true;
    }

    if (tree_overlay.mode == .summary) {
        if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
            try tree_overlay_mod.cancelSummaryPrompt(allocator, tree_overlay);
            return true;
        }
        if (matchesEditorAction(keybindings, .select_up, key, modifiers)) {
            try tree_overlay_mod.moveSelection(allocator, tree_overlay, -1, true);
            return true;
        }
        if (matchesEditorAction(keybindings, .select_down, key, modifiers)) {
            try tree_overlay_mod.moveSelection(allocator, tree_overlay, 1, true);
            return true;
        }
        if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
            const target_id = tree_overlay.summary_target_id orelse return true;
            const summarize = tree_overlay.list.selectedIndex() != 0;
            const summary_text: ?[]const u8 = if (summarize)
                "Branch summary selected from the session tree."
            else
                null;
            try navigateTree(allocator, session, target_id, app_state, editor, .{
                .summarize = summarize,
                .summary_text = summary_text,
            });
            if (overlay.*) |*value| value.deinit(allocator);
            overlay.* = null;
            return true;
        }
        return true;
    }

    if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
        if (try tree_overlay_mod.clearSearchAndFolds(allocator, tree_overlay)) return true;
        return false;
    }
    if (matchesEditorAction(keybindings, .select_up, key, modifiers)) {
        try tree_overlay_mod.moveSelection(allocator, tree_overlay, -1, true);
        return true;
    }
    if (matchesEditorAction(keybindings, .select_down, key, modifiers)) {
        try tree_overlay_mod.moveSelection(allocator, tree_overlay, 1, true);
        return true;
    }
    if (matchesEditorAction(keybindings, .select_page_up, key, modifiers)) {
        try tree_overlay_mod.moveSelection(allocator, tree_overlay, -@as(isize, @intCast(tree_overlay.list.max_visible)), false);
        return true;
    }
    if (matchesEditorAction(keybindings, .select_page_down, key, modifiers)) {
        try tree_overlay_mod.moveSelection(allocator, tree_overlay, @intCast(tree_overlay.list.max_visible), false);
        return true;
    }
    if (matchesAction(keybindings, .tree_foldOrUp, key, modifiers)) {
        try tree_overlay_mod.foldOrMoveUp(allocator, tree_overlay);
        return true;
    }
    if (matchesAction(keybindings, .tree_unfoldOrDown, key, modifiers)) {
        try tree_overlay_mod.unfoldOrMoveDown(allocator, tree_overlay);
        return true;
    }
    if (matchesAction(keybindings, .tree_editLabel, key, modifiers)) {
        try tree_overlay_mod.beginLabelMode(allocator, tree_overlay);
        return true;
    }
    if (matchesAction(keybindings, .tree_toggleLabelTimestamp, key, modifiers)) {
        try tree_overlay_mod.toggleLabelTimestamps(allocator, tree_overlay);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_default, key, modifiers)) {
        try tree_overlay_mod.setFilterMode(allocator, tree_overlay, .default);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_noTools, key, modifiers)) {
        try tree_overlay_mod.setFilterMode(allocator, tree_overlay, if (tree_overlay.filter_mode == .no_tools) .default else .no_tools);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_userOnly, key, modifiers)) {
        try tree_overlay_mod.setFilterMode(allocator, tree_overlay, if (tree_overlay.filter_mode == .user_only) .default else .user_only);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_labeledOnly, key, modifiers)) {
        try tree_overlay_mod.setFilterMode(allocator, tree_overlay, if (tree_overlay.filter_mode == .labeled_only) .default else .labeled_only);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_all, key, modifiers)) {
        try tree_overlay_mod.setFilterMode(allocator, tree_overlay, if (tree_overlay.filter_mode == .all) .default else .all);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_cycleForward, key, modifiers)) {
        try tree_overlay_mod.cycleFilter(allocator, tree_overlay, 1);
        return true;
    }
    if (matchesAction(keybindings, .tree_filter_cycleBackward, key, modifiers)) {
        try tree_overlay_mod.cycleFilter(allocator, tree_overlay, -1);
        return true;
    }
    if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
        const target_id = tree_overlay_mod.selectedEntryId(tree_overlay) orelse {
            try app_state.setStatus("No tree entries available");
            return true;
        };
        if (tree_overlay.current_leaf_id) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, target_id)) {
                try app_state.setStatus("Already at this point");
                if (overlay.*) |*value| value.deinit(allocator);
                overlay.* = null;
                return true;
            }
        }
        const skip_prompt = if (runtime_config) |config| config.branchSummarySkipPrompt() else false;
        if (!skip_prompt) {
            try tree_overlay_mod.beginSummaryPrompt(allocator, tree_overlay, target_id);
            return true;
        }
        try navigateTree(allocator, session, target_id, app_state, editor, .{});
        if (overlay.*) |*value| value.deinit(allocator);
        overlay.* = null;
        return true;
    }
    if (try updateSearchFromKey(allocator, tree_overlay.search, key, modifiers)) |next_search| {
        defer allocator.free(next_search);
        try tree_overlay_mod.updateSearch(allocator, tree_overlay, next_search);
        return true;
    }
    return false;
}

fn applyScopedModelSelectionToRuntime(
    allocator: std.mem.Allocator,
    scoped_overlay: *const overlays.ScopedModelsOverlay,
    app_state: *AppState,
) !void {
    try app_state.setScopedModelOverride(scopedPatternsForRuntime(scoped_overlay));
    if (scopedPatternsForRuntime(scoped_overlay)) |patterns| {
        const status = try std.fmt.allocPrint(allocator, "{d} scoped models enabled", .{patterns.len});
        defer allocator.free(status);
        try app_state.setStatus(status);
    } else {
        try app_state.setStatus("All models enabled");
    }
}

fn scopedPatternsForRuntime(scoped_overlay: *const overlays.ScopedModelsOverlay) ?[]const []const u8 {
    const ids = scoped_overlay.enabled_ids orelse return null;
    if (ids.len == 0 or ids.len == scoped_overlay.all_ids.len) return null;
    return ids;
}

fn closeOverlay(allocator: std.mem.Allocator, overlay: *?SelectorOverlay) void {
    if (overlay.*) |*value| {
        value.deinit(allocator);
        overlay.* = null;
    }
}

fn matchesAction(
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) bool {
    if (keybindings) |bindings| return bindings.matchesAction(action, key, modifiers);
    return false;
}

fn matchesEditorAction(
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.EditorAction,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) bool {
    if (keybindings) |bindings| return bindings.matchesEditorAction(action, key, modifiers);
    return keybindings_mod.defaultEditorActionForKeyWithModifiers(key, modifiers) == action;
}

fn updateSearchFromKey(
    allocator: std.mem.Allocator,
    current_search: []const u8,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) !?[]u8 {
    if (modifiers.ctrl or modifiers.alt or modifiers.super) return null;
    switch (key) {
        .printable => |printable| {
            const text = printable.slice();
            if (text.len == 0) return null;
            var next = try allocator.alloc(u8, current_search.len + text.len);
            @memcpy(next[0..current_search.len], current_search);
            @memcpy(next[current_search.len..], text);
            return next;
        },
        .backspace => {
            if (current_search.len == 0) return null;
            return try allocator.dupe(u8, current_search[0..previousSearchGraphemeStart(current_search)]);
        },
        else => return null,
    }
}

fn previousSearchGraphemeStart(text: []const u8) usize {
    var cursor: usize = 0;
    var previous: usize = 0;
    while (cursor < text.len) {
        previous = cursor;
        const cluster = tui.ansi.nextDisplayCluster(text, cursor);
        if (cluster.end >= text.len or cluster.end <= cursor) return previous;
        cursor = cluster.end;
    }
    return previous;
}

test "updateSearchFromKey appends Chinese printable text" {
    const allocator = std.testing.allocator;

    const next = (try updateSearchFromKey(allocator, "模型", .{
        .printable = tui.keys.PrintableKey.fromSlice("搜索"),
    }, .{})).?;
    defer allocator.free(next);

    try std.testing.expectEqualStrings("模型搜索", next);
}

test "updateSearchFromKey backspace removes full Chinese grapheme" {
    const allocator = std.testing.allocator;

    const next = (try updateSearchFromKey(allocator, "模型搜索", .backspace, .{})).?;
    defer allocator.free(next);

    try std.testing.expectEqualStrings("模型搜", next);
    try std.testing.expect(std.unicode.utf8ValidateSlice(next));
}

test "updateSearchFromKey backspace removes combining grapheme" {
    const allocator = std.testing.allocator;

    const next = (try updateSearchFromKey(allocator, "cafe\u{301}", .backspace, .{})).?;
    defer allocator.free(next);

    try std.testing.expectEqualStrings("caf", next);
    try std.testing.expect(std.unicode.utf8ValidateSlice(next));
}

test "model overlay input uses configured tab binding only" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("openai", "gpt-5.4").?;
    const scoped = [_][]const u8{"anthropic/claude-sonnet-4-5"};
    var overlay = try overlays.loadModelOverlay(allocator, &env_map, current_model, null, scoped[0..], null);
    defer overlay.deinit(allocator);

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setEditorBinding(.input_tab, &.{.{ .ctrl = 'm' }});

    try std.testing.expectEqual(overlays.ModelScope.scoped, overlay.model.scope);
    try std.testing.expect(!try handleModelOverlayInteractiveKey(allocator, .tab, .{}, &overlay.model, &custom_keybindings));
    try std.testing.expectEqual(overlays.ModelScope.scoped, overlay.model.scope);

    try std.testing.expect(try handleModelOverlayInteractiveKey(allocator, .{ .ctrl = 'm' }, .{}, &overlay.model, &custom_keybindings));
    try std.testing.expectEqual(overlays.ModelScope.all, overlay.model.scope);
}

test "tree overlay page movement uses configured page bindings only" {
    const allocator = std.testing.allocator;

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setEditorBinding(.select_page_up, &.{.{ .ctrl = 'm' }});
    try custom_keybindings.setEditorBinding(.select_page_down, &.{});

    var tree_overlay = testTreeOverlay(5, 3);
    var session: session_mod.AgentSession = undefined;
    var app_state: AppState = undefined;
    var editor: tui.Editor = undefined;
    var overlay: ?SelectorOverlay = null;

    try std.testing.expect(!try handleTreeOverlayInteractiveKey(
        allocator,
        .left,
        .{},
        &tree_overlay,
        &session,
        &app_state,
        &editor,
        null,
        &custom_keybindings,
        &overlay,
    ));
    try std.testing.expectEqual(@as(usize, 5), tree_overlay.list.selectedIndex());

    try std.testing.expect(!try handleTreeOverlayInteractiveKey(
        allocator,
        .page_up,
        .{},
        &tree_overlay,
        &session,
        &app_state,
        &editor,
        null,
        &custom_keybindings,
        &overlay,
    ));
    try std.testing.expectEqual(@as(usize, 5), tree_overlay.list.selectedIndex());

    try std.testing.expect(try handleTreeOverlayInteractiveKey(
        allocator,
        .{ .ctrl = 'm' },
        .{},
        &tree_overlay,
        &session,
        &app_state,
        &editor,
        null,
        &custom_keybindings,
        &overlay,
    ));
    try std.testing.expectEqual(@as(usize, 2), tree_overlay.list.selectedIndex());

    try std.testing.expect(!try handleTreeOverlayInteractiveKey(
        allocator,
        .right,
        .{},
        &tree_overlay,
        &session,
        &app_state,
        &editor,
        null,
        &custom_keybindings,
        &overlay,
    ));
    try std.testing.expectEqual(@as(usize, 2), tree_overlay.list.selectedIndex());
}

test "tree overlay default page bindings still move by page" {
    const allocator = std.testing.allocator;

    var default_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer default_keybindings.deinit();

    var tree_overlay = testTreeOverlay(4, 3);
    var session: session_mod.AgentSession = undefined;
    var app_state: AppState = undefined;
    var editor: tui.Editor = undefined;
    var overlay: ?SelectorOverlay = null;

    try std.testing.expect(try handleTreeOverlayInteractiveKey(
        allocator,
        .page_up,
        .{},
        &tree_overlay,
        &session,
        &app_state,
        &editor,
        null,
        &default_keybindings,
        &overlay,
    ));
    try std.testing.expectEqual(@as(usize, 1), tree_overlay.list.selectedIndex());

    try std.testing.expect(try handleTreeOverlayInteractiveKey(
        allocator,
        .page_down,
        .{},
        &tree_overlay,
        &session,
        &app_state,
        &editor,
        null,
        &default_keybindings,
        &overlay,
    ));
    try std.testing.expectEqual(@as(usize, 4), tree_overlay.list.selectedIndex());
}

test "scoped models clear search uses configured clear action only" {
    const allocator = std.testing.allocator;

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.clear, &.{.{ .ctrl = 'y' }});
    try custom_keybindings.setEditorBinding(.select_cancel, &.{.escape});

    var selector = try testScopedModelsSelector(allocator);
    defer if (selector) |*active| active.deinit(allocator);
    try updateScopedModelsSearch(allocator, &selector.?.scoped_models, "claude");

    if (selector) |*active| {
        try handleScopedModelsOverlayKey(
            allocator,
            std.testing.io,
            .{ .ctrl = 'c' },
            .{},
            &active.scoped_models,
            &app_state,
            null,
            &custom_keybindings,
            &selector,
        );
    }
    try std.testing.expect(selector != null);
    try std.testing.expectEqualStrings("claude", selector.?.scoped_models.search);

    if (selector) |*active| {
        try handleScopedModelsOverlayKey(
            allocator,
            std.testing.io,
            .{ .ctrl = 'y' },
            .{},
            &active.scoped_models,
            &app_state,
            null,
            &custom_keybindings,
            &selector,
        );
    }
    try std.testing.expect(selector != null);
    try std.testing.expectEqualStrings("", selector.?.scoped_models.search);
}

test "scoped models cancel closes via configured cancel action with search" {
    const allocator = std.testing.allocator;

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();
    try custom_keybindings.setBinding(.clear, &.{.{ .ctrl = 'y' }});
    try custom_keybindings.setEditorBinding(.select_cancel, &.{.escape});

    var selector = try testScopedModelsSelector(allocator);
    errdefer if (selector) |*active| active.deinit(allocator);
    try updateScopedModelsSearch(allocator, &selector.?.scoped_models, "claude");

    if (selector) |*active| {
        try handleScopedModelsOverlayKey(
            allocator,
            std.testing.io,
            .escape,
            .{},
            &active.scoped_models,
            &app_state,
            null,
            &custom_keybindings,
            &selector,
        );
    }
    try std.testing.expect(selector == null);
}

test "scoped models default ctrl-c clears search before closing" {
    const allocator = std.testing.allocator;

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();

    var default_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer default_keybindings.deinit();

    var selector = try testScopedModelsSelector(allocator);
    defer if (selector) |*active| active.deinit(allocator);
    try updateScopedModelsSearch(allocator, &selector.?.scoped_models, "claude");

    if (selector) |*active| {
        try handleScopedModelsOverlayKey(
            allocator,
            std.testing.io,
            .{ .ctrl = 'c' },
            .{},
            &active.scoped_models,
            &app_state,
            null,
            &default_keybindings,
            &selector,
        );
    }
    try std.testing.expect(selector != null);
    try std.testing.expectEqualStrings("", selector.?.scoped_models.search);

    if (selector) |*active| {
        try handleScopedModelsOverlayKey(
            allocator,
            std.testing.io,
            .{ .ctrl = 'c' },
            .{},
            &active.scoped_models,
            &app_state,
            null,
            &default_keybindings,
            &selector,
        );
    }
    try std.testing.expect(selector == null);
}

fn testTreeOverlay(selected_index: usize, max_visible: usize) overlays.TreeOverlay {
    const items = struct {
        var values = [_]tui.SelectItem{
            .{ .value = "0", .label = "0", .description = null },
            .{ .value = "1", .label = "1", .description = null },
            .{ .value = "2", .label = "2", .description = null },
            .{ .value = "3", .label = "3", .description = null },
            .{ .value = "4", .label = "4", .description = null },
            .{ .value = "5", .label = "5", .description = null },
        };
    };
    const choices = struct {
        var values = [_]overlays.TreeChoice{
            .{ .entry_id = @constCast("0") },
            .{ .entry_id = @constCast("1") },
            .{ .entry_id = @constCast("2") },
            .{ .entry_id = @constCast("3") },
            .{ .entry_id = @constCast("4") },
            .{ .entry_id = @constCast("5") },
        };
    };
    return .{
        .choices = choices.values[0..],
        .items = items.values[0..],
        .list = .{
            .items = items.values[0..],
            .max_visible = max_visible,
            .selected_index = selected_index,
        },
        .nodes = &.{},
    };
}

fn testScopedModelsSelector(allocator: std.mem.Allocator) !?SelectorOverlay {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("openai", "gpt-5.4").?;
    const enabled = [_][]const u8{
        "openai/gpt-5.4",
        "anthropic/claude-sonnet-4-5",
    };
    return try overlays.loadScopedModelOverlay(allocator, &env_map, current_model, null, enabled[0..], null);
}
