const std = @import("std");
const keybinding_schema = @import("keybinding_schema.zig");

pub const Action = enum(u8) {
    interrupt,
    clear,
    exit,
    app_suspend,
    thinking_cycle,
    model_cycleForward,
    model_cycleBackward,
    model_select,
    tools_expand,
    thinking_toggle,
    session_toggleNamedFilter,
    editor_external,
    message_followUp,
    message_dequeue,
    chat_scrollToBottom,
    clipboard_pasteImage,
    session_new,
    session_tree,
    session_fork,
    session_resume,
    tree_foldOrUp,
    tree_unfoldOrDown,
    tree_editLabel,
    tree_toggleLabelTimestamp,
    session_togglePath,
    session_toggleSort,
    session_rename,
    session_delete,
    session_deleteNoninvasive,
    models_save,
    models_enableAll,
    models_clearAll,
    models_toggleProvider,
    models_reorderUp,
    models_reorderDown,
    tree_filter_default,
    tree_filter_noTools,
    tree_filter_userOnly,
    tree_filter_labeledOnly,
    tree_filter_all,
    tree_filter_cycleForward,
    tree_filter_cycleBackward,
};

pub const EditorAction = enum(u8) {
    cursor_up,
    cursor_down,
    cursor_left,
    cursor_right,
    cursor_word_left,
    cursor_word_right,
    cursor_line_start,
    cursor_line_end,
    jump_forward,
    jump_backward,
    page_up,
    page_down,
    delete_char_backward,
    delete_char_forward,
    delete_word_backward,
    delete_word_forward,
    delete_to_line_start,
    delete_to_line_end,
    yank,
    yank_pop,
    undo,
    input_new_line,
    input_submit,
    input_tab,
    input_copy,
    select_up,
    select_down,
    select_page_up,
    select_page_down,
    select_confirm,
    select_cancel,
};

pub const ACTION_COUNT = @typeInfo(Action).@"enum".fields.len;
pub const EDITOR_ACTION_COUNT = @typeInfo(EditorAction).@"enum".fields.len;

pub const KeySpec = keybinding_schema.KeySpec;
pub const parseKeySpec = keybinding_schema.parseKeySpec;
pub const altModifierDisplayName = keybinding_schema.altModifierDisplayName;

const BindingDefinition = struct {
    action: Action,
    id: []const u8,
    defaults: []const []const u8,
};

const DEFINITIONS = [_]BindingDefinition{
    .{ .action = .interrupt, .id = "app.interrupt", .defaults = &.{"escape"} },
    .{ .action = .clear, .id = "app.clear", .defaults = &.{"ctrl+c"} },
    .{ .action = .exit, .id = "app.exit", .defaults = &.{"ctrl+d"} },
    .{ .action = .app_suspend, .id = "app.suspend", .defaults = &.{"ctrl+z"} },
    .{ .action = .thinking_cycle, .id = "app.thinking.cycle", .defaults = &.{"shift+tab"} },
    .{ .action = .model_cycleForward, .id = "app.model.cycleForward", .defaults = &.{"ctrl+p"} },
    .{ .action = .model_cycleBackward, .id = "app.model.cycleBackward", .defaults = &.{"shift+ctrl+p"} },
    .{ .action = .model_select, .id = "app.model.select", .defaults = &.{"ctrl+l"} },
    .{ .action = .tools_expand, .id = "app.tools.expand", .defaults = &.{"ctrl+o"} },
    .{ .action = .thinking_toggle, .id = "app.thinking.toggle", .defaults = &.{"ctrl+t"} },
    .{ .action = .session_toggleNamedFilter, .id = "app.session.toggleNamedFilter", .defaults = &.{"ctrl+n"} },
    .{ .action = .editor_external, .id = "app.editor.external", .defaults = &.{"ctrl+g"} },
    .{ .action = .message_followUp, .id = "app.message.followUp", .defaults = &.{"alt+enter"} },
    .{ .action = .message_dequeue, .id = "app.message.dequeue", .defaults = &.{"alt+up"} },
    .{ .action = .chat_scrollToBottom, .id = "app.chat.scrollToBottom", .defaults = &.{"ctrl+end"} },
    .{ .action = .clipboard_pasteImage, .id = "app.clipboard.pasteImage", .defaults = &.{"ctrl+v"} },
    .{ .action = .session_new, .id = "app.session.new", .defaults = &.{} },
    .{ .action = .session_tree, .id = "app.session.tree", .defaults = &.{} },
    .{ .action = .session_fork, .id = "app.session.fork", .defaults = &.{} },
    .{ .action = .session_resume, .id = "app.session.resume", .defaults = &.{} },
    .{ .action = .tree_foldOrUp, .id = "app.tree.foldOrUp", .defaults = &.{ "ctrl+left", "alt+left" } },
    .{ .action = .tree_unfoldOrDown, .id = "app.tree.unfoldOrDown", .defaults = &.{ "ctrl+right", "alt+right" } },
    .{ .action = .tree_editLabel, .id = "app.tree.editLabel", .defaults = &.{"shift+l"} },
    .{ .action = .tree_toggleLabelTimestamp, .id = "app.tree.toggleLabelTimestamp", .defaults = &.{"shift+t"} },
    .{ .action = .session_togglePath, .id = "app.session.togglePath", .defaults = &.{"ctrl+p"} },
    .{ .action = .session_toggleSort, .id = "app.session.toggleSort", .defaults = &.{"ctrl+s"} },
    .{ .action = .session_rename, .id = "app.session.rename", .defaults = &.{"ctrl+r"} },
    .{ .action = .session_delete, .id = "app.session.delete", .defaults = &.{"ctrl+d"} },
    .{ .action = .session_deleteNoninvasive, .id = "app.session.deleteNoninvasive", .defaults = &.{"ctrl+backspace"} },
    .{ .action = .models_save, .id = "app.models.save", .defaults = &.{"ctrl+s"} },
    .{ .action = .models_enableAll, .id = "app.models.enableAll", .defaults = &.{"ctrl+a"} },
    .{ .action = .models_clearAll, .id = "app.models.clearAll", .defaults = &.{"ctrl+x"} },
    .{ .action = .models_toggleProvider, .id = "app.models.toggleProvider", .defaults = &.{"ctrl+p"} },
    .{ .action = .models_reorderUp, .id = "app.models.reorderUp", .defaults = &.{"alt+up"} },
    .{ .action = .models_reorderDown, .id = "app.models.reorderDown", .defaults = &.{"alt+down"} },
    .{ .action = .tree_filter_default, .id = "app.tree.filter.default", .defaults = &.{"ctrl+d"} },
    .{ .action = .tree_filter_noTools, .id = "app.tree.filter.noTools", .defaults = &.{"ctrl+t"} },
    .{ .action = .tree_filter_userOnly, .id = "app.tree.filter.userOnly", .defaults = &.{"ctrl+u"} },
    .{ .action = .tree_filter_labeledOnly, .id = "app.tree.filter.labeledOnly", .defaults = &.{"ctrl+l"} },
    .{ .action = .tree_filter_all, .id = "app.tree.filter.all", .defaults = &.{"ctrl+a"} },
    .{ .action = .tree_filter_cycleForward, .id = "app.tree.filter.cycleForward", .defaults = &.{"ctrl+o"} },
    .{ .action = .tree_filter_cycleBackward, .id = "app.tree.filter.cycleBackward", .defaults = &.{"shift+ctrl+o"} },
};

comptime {
    assertDefinitionsCoverActions(Action, DEFINITIONS);
}

const EDITOR_DEFINITIONS = [_]struct {
    action: EditorAction,
    id: []const u8,
    defaults: []const []const u8,
}{
    .{ .action = .cursor_up, .id = "tui.editor.cursorUp", .defaults = &.{"up"} },
    .{ .action = .cursor_down, .id = "tui.editor.cursorDown", .defaults = &.{"down"} },
    .{ .action = .cursor_left, .id = "tui.editor.cursorLeft", .defaults = &.{ "left", "ctrl+b" } },
    .{ .action = .cursor_right, .id = "tui.editor.cursorRight", .defaults = &.{ "right", "ctrl+f" } },
    .{ .action = .cursor_word_left, .id = "tui.editor.cursorWordLeft", .defaults = &.{ "alt+left", "ctrl+left", "alt+b" } },
    .{ .action = .cursor_word_right, .id = "tui.editor.cursorWordRight", .defaults = &.{ "alt+right", "ctrl+right", "alt+f" } },
    .{ .action = .cursor_line_start, .id = "tui.editor.cursorLineStart", .defaults = &.{ "home", "ctrl+a" } },
    .{ .action = .cursor_line_end, .id = "tui.editor.cursorLineEnd", .defaults = &.{ "end", "ctrl+e" } },
    .{ .action = .jump_forward, .id = "tui.editor.jumpForward", .defaults = &.{"ctrl+]"} },
    .{ .action = .jump_backward, .id = "tui.editor.jumpBackward", .defaults = &.{"ctrl+alt+]"} },
    .{ .action = .page_up, .id = "tui.editor.pageUp", .defaults = &.{"pageUp"} },
    .{ .action = .page_down, .id = "tui.editor.pageDown", .defaults = &.{"pageDown"} },
    .{ .action = .delete_char_backward, .id = "tui.editor.deleteCharBackward", .defaults = &.{"backspace"} },
    .{ .action = .delete_char_forward, .id = "tui.editor.deleteCharForward", .defaults = &.{ "delete", "ctrl+d" } },
    .{ .action = .delete_word_backward, .id = "tui.editor.deleteWordBackward", .defaults = &.{ "ctrl+w", "alt+backspace" } },
    .{ .action = .delete_word_forward, .id = "tui.editor.deleteWordForward", .defaults = &.{ "alt+d", "alt+delete" } },
    .{ .action = .delete_to_line_start, .id = "tui.editor.deleteToLineStart", .defaults = &.{"ctrl+u"} },
    .{ .action = .delete_to_line_end, .id = "tui.editor.deleteToLineEnd", .defaults = &.{"ctrl+k"} },
    .{ .action = .yank, .id = "tui.editor.yank", .defaults = &.{"ctrl+y"} },
    .{ .action = .yank_pop, .id = "tui.editor.yankPop", .defaults = &.{"alt+y"} },
    .{ .action = .undo, .id = "tui.editor.undo", .defaults = &.{"ctrl+-"} },
    .{ .action = .input_new_line, .id = "tui.input.newLine", .defaults = &.{"shift+enter"} },
    .{ .action = .input_submit, .id = "tui.input.submit", .defaults = &.{"enter"} },
    .{ .action = .input_tab, .id = "tui.input.tab", .defaults = &.{"tab"} },
    .{ .action = .input_copy, .id = "tui.input.copy", .defaults = &.{"ctrl+c"} },
    .{ .action = .select_up, .id = "tui.select.up", .defaults = &.{"up"} },
    .{ .action = .select_down, .id = "tui.select.down", .defaults = &.{"down"} },
    .{ .action = .select_page_up, .id = "tui.select.pageUp", .defaults = &.{"pageUp"} },
    .{ .action = .select_page_down, .id = "tui.select.pageDown", .defaults = &.{"pageDown"} },
    .{ .action = .select_confirm, .id = "tui.select.confirm", .defaults = &.{"enter"} },
    .{ .action = .select_cancel, .id = "tui.select.cancel", .defaults = &.{ "escape", "ctrl+c" } },
};

comptime {
    assertDefinitionsCoverActions(EditorAction, EDITOR_DEFINITIONS);
}

const AllowedDefaultCollision = struct {
    key: []const u8,
    first_id: []const u8,
    second_id: []const u8,
};

const APP_ALLOWED_DEFAULT_COLLISIONS = [_]AllowedDefaultCollision{
    .{ .key = "ctrl+p", .first_id = "app.model.cycleForward", .second_id = "app.session.togglePath" },
    .{ .key = "ctrl+p", .first_id = "app.model.cycleForward", .second_id = "app.models.toggleProvider" },
    .{ .key = "ctrl+p", .first_id = "app.session.togglePath", .second_id = "app.models.toggleProvider" },
    .{ .key = "ctrl+d", .first_id = "app.exit", .second_id = "app.session.delete" },
    .{ .key = "ctrl+d", .first_id = "app.exit", .second_id = "app.tree.filter.default" },
    .{ .key = "ctrl+d", .first_id = "app.session.delete", .second_id = "app.tree.filter.default" },
    .{ .key = "ctrl+s", .first_id = "app.session.toggleSort", .second_id = "app.models.save" },
    .{ .key = "alt+up", .first_id = "app.message.dequeue", .second_id = "app.models.reorderUp" },
    .{ .key = "ctrl+t", .first_id = "app.thinking.toggle", .second_id = "app.tree.filter.noTools" },
    .{ .key = "ctrl+l", .first_id = "app.model.select", .second_id = "app.tree.filter.labeledOnly" },
    .{ .key = "ctrl+a", .first_id = "app.models.enableAll", .second_id = "app.tree.filter.all" },
    .{ .key = "ctrl+o", .first_id = "app.tools.expand", .second_id = "app.tree.filter.cycleForward" },
};

const EDITOR_ALLOWED_DEFAULT_COLLISIONS = [_]AllowedDefaultCollision{
    .{ .key = "up", .first_id = "tui.editor.cursorUp", .second_id = "tui.select.up" },
    .{ .key = "down", .first_id = "tui.editor.cursorDown", .second_id = "tui.select.down" },
    .{ .key = "pageUp", .first_id = "tui.editor.pageUp", .second_id = "tui.select.pageUp" },
    .{ .key = "pageDown", .first_id = "tui.editor.pageDown", .second_id = "tui.select.pageDown" },
    .{ .key = "enter", .first_id = "tui.input.submit", .second_id = "tui.select.confirm" },
    .{ .key = "ctrl+c", .first_id = "tui.input.copy", .second_id = "tui.select.cancel" },
};

comptime {
    assertNoUnexpectedDefaultCollisions(DEFINITIONS, APP_ALLOWED_DEFAULT_COLLISIONS);
    assertNoUnexpectedDefaultCollisions(EDITOR_DEFINITIONS, EDITOR_ALLOWED_DEFAULT_COLLISIONS);
}

/// Legacy keybinding name → modern dotted ID migration table.
/// Matches TS KEYBINDING_NAME_MIGRATIONS (app-level entries only).
const LEGACY_MIGRATIONS = [_]struct { legacy: []const u8, modern: []const u8 }{
    .{ .legacy = "cursorUp", .modern = "tui.editor.cursorUp" },
    .{ .legacy = "cursorDown", .modern = "tui.editor.cursorDown" },
    .{ .legacy = "cursorLeft", .modern = "tui.editor.cursorLeft" },
    .{ .legacy = "cursorRight", .modern = "tui.editor.cursorRight" },
    .{ .legacy = "cursorWordLeft", .modern = "tui.editor.cursorWordLeft" },
    .{ .legacy = "cursorWordRight", .modern = "tui.editor.cursorWordRight" },
    .{ .legacy = "cursorLineStart", .modern = "tui.editor.cursorLineStart" },
    .{ .legacy = "cursorLineEnd", .modern = "tui.editor.cursorLineEnd" },
    .{ .legacy = "jumpForward", .modern = "tui.editor.jumpForward" },
    .{ .legacy = "jumpBackward", .modern = "tui.editor.jumpBackward" },
    .{ .legacy = "pageUp", .modern = "tui.editor.pageUp" },
    .{ .legacy = "pageDown", .modern = "tui.editor.pageDown" },
    .{ .legacy = "deleteCharBackward", .modern = "tui.editor.deleteCharBackward" },
    .{ .legacy = "deleteCharForward", .modern = "tui.editor.deleteCharForward" },
    .{ .legacy = "deleteWordBackward", .modern = "tui.editor.deleteWordBackward" },
    .{ .legacy = "deleteWordForward", .modern = "tui.editor.deleteWordForward" },
    .{ .legacy = "deleteToLineStart", .modern = "tui.editor.deleteToLineStart" },
    .{ .legacy = "deleteToLineEnd", .modern = "tui.editor.deleteToLineEnd" },
    .{ .legacy = "yank", .modern = "tui.editor.yank" },
    .{ .legacy = "yankPop", .modern = "tui.editor.yankPop" },
    .{ .legacy = "undo", .modern = "tui.editor.undo" },
    .{ .legacy = "newLine", .modern = "tui.input.newLine" },
    .{ .legacy = "submit", .modern = "tui.input.submit" },
    .{ .legacy = "tab", .modern = "tui.input.tab" },
    .{ .legacy = "copy", .modern = "tui.input.copy" },
    .{ .legacy = "selectUp", .modern = "tui.select.up" },
    .{ .legacy = "selectDown", .modern = "tui.select.down" },
    .{ .legacy = "selectPageUp", .modern = "tui.select.pageUp" },
    .{ .legacy = "selectPageDown", .modern = "tui.select.pageDown" },
    .{ .legacy = "selectConfirm", .modern = "tui.select.confirm" },
    .{ .legacy = "selectCancel", .modern = "tui.select.cancel" },
    .{ .legacy = "interrupt", .modern = "app.interrupt" },
    .{ .legacy = "clear", .modern = "app.clear" },
    .{ .legacy = "exit", .modern = "app.exit" },
    .{ .legacy = "suspend", .modern = "app.suspend" },
    .{ .legacy = "cycleThinkingLevel", .modern = "app.thinking.cycle" },
    .{ .legacy = "cycleModelForward", .modern = "app.model.cycleForward" },
    .{ .legacy = "cycleModelBackward", .modern = "app.model.cycleBackward" },
    .{ .legacy = "selectModel", .modern = "app.model.select" },
    .{ .legacy = "expandTools", .modern = "app.tools.expand" },
    .{ .legacy = "toggleThinking", .modern = "app.thinking.toggle" },
    .{ .legacy = "toggleSessionNamedFilter", .modern = "app.session.toggleNamedFilter" },
    .{ .legacy = "externalEditor", .modern = "app.editor.external" },
    .{ .legacy = "followUp", .modern = "app.message.followUp" },
    .{ .legacy = "dequeue", .modern = "app.message.dequeue" },
    .{ .legacy = "pasteImage", .modern = "app.clipboard.pasteImage" },
    .{ .legacy = "newSession", .modern = "app.session.new" },
    .{ .legacy = "tree", .modern = "app.session.tree" },
    .{ .legacy = "fork", .modern = "app.session.fork" },
    .{ .legacy = "resume", .modern = "app.session.resume" },
    .{ .legacy = "treeFoldOrUp", .modern = "app.tree.foldOrUp" },
    .{ .legacy = "treeUnfoldOrDown", .modern = "app.tree.unfoldOrDown" },
    .{ .legacy = "treeEditLabel", .modern = "app.tree.editLabel" },
    .{ .legacy = "treeToggleLabelTimestamp", .modern = "app.tree.toggleLabelTimestamp" },
    .{ .legacy = "toggleSessionPath", .modern = "app.session.togglePath" },
    .{ .legacy = "toggleSessionSort", .modern = "app.session.toggleSort" },
    .{ .legacy = "renameSession", .modern = "app.session.rename" },
    .{ .legacy = "deleteSession", .modern = "app.session.delete" },
    .{ .legacy = "deleteSessionNoninvasive", .modern = "app.session.deleteNoninvasive" },
};

const LEGACY_MIGRATION_MAP = std.StaticStringMap([]const u8).initComptime(blk: {
    var entries: [LEGACY_MIGRATIONS.len]struct { []const u8, []const u8 } = undefined;
    for (LEGACY_MIGRATIONS, 0..) |migration, index| {
        entries[index] = .{ migration.legacy, migration.modern };
    }
    break :blk entries;
});

comptime {
    assertLegacyMigrationTable();
}

pub const Keybindings = struct {
    allocator: std.mem.Allocator,
    bindings: [ACTION_COUNT][]KeySpec,
    editor_bindings: [EDITOR_ACTION_COUNT][]KeySpec,

    pub fn initDefaults(allocator: std.mem.Allocator) !Keybindings {
        var result = Keybindings{
            .allocator = allocator,
            .bindings = undefined,
            .editor_bindings = undefined,
        };
        errdefer result.deinit();

        for (DEFINITIONS, 0..) |definition, index| {
            result.bindings[index] = try parseBindingList(allocator, definition.defaults);
        }
        for (EDITOR_DEFINITIONS, 0..) |definition, index| {
            result.editor_bindings[index] = try parseBindingList(allocator, definition.defaults);
        }
        return result;
    }

    pub fn deinit(self: *Keybindings) void {
        for (&self.bindings) |*binding| {
            self.allocator.free(binding.*);
        }
        for (&self.editor_bindings) |*binding| {
            self.allocator.free(binding.*);
        }
        self.* = undefined;
    }

    pub fn setBinding(self: *Keybindings, action: Action, specs: []const KeySpec) !void {
        const index = @intFromEnum(action);
        const owned = try self.allocator.dupe(KeySpec, specs);
        self.allocator.free(self.bindings[index]);
        self.bindings[index] = owned;
    }

    pub fn setEditorBinding(self: *Keybindings, action: EditorAction, specs: []const KeySpec) !void {
        const index = @intFromEnum(action);
        const owned = try self.allocator.dupe(KeySpec, specs);
        self.allocator.free(self.editor_bindings[index]);
        self.editor_bindings[index] = owned;
    }

    pub fn actionForMatch(self: *const Keybindings, context: anytype, matcher: anytype) ?Action {
        for (DEFINITIONS, 0..) |definition, index| {
            for (self.bindings[index]) |spec| {
                if (matcher(spec, context)) return definition.action;
            }
        }
        return null;
    }

    pub fn editorActionForMatch(self: *const Keybindings, context: anytype, matcher: anytype) ?EditorAction {
        for (EDITOR_DEFINITIONS, 0..) |definition, index| {
            for (self.editor_bindings[index]) |spec| {
                if (matcher(spec, context)) return definition.action;
            }
        }
        return null;
    }

    pub fn matchesActionForMatch(self: *const Keybindings, action: Action, context: anytype, matcher: anytype) bool {
        const binding = self.bindings[@intFromEnum(action)];
        for (binding) |spec| {
            if (matcher(spec, context)) return true;
        }
        return false;
    }

    pub fn matchesEditorActionForMatch(self: *const Keybindings, action: EditorAction, context: anytype, matcher: anytype) bool {
        const binding = self.editor_bindings[@intFromEnum(action)];
        for (binding) |spec| {
            if (matcher(spec, context)) return true;
        }
        return false;
    }

    pub fn bindingForAction(self: *const Keybindings, action: Action) []const KeySpec {
        return self.bindings[@intFromEnum(action)];
    }

    pub fn bindingForEditorAction(self: *const Keybindings, action: EditorAction) []const KeySpec {
        return self.editor_bindings[@intFromEnum(action)];
    }

    pub fn primaryLabel(self: *const Keybindings, allocator: std.mem.Allocator, action: Action) ![]u8 {
        const binding = self.bindings[@intFromEnum(action)];
        if (binding.len == 0) return allocator.dupe(u8, "Unbound");
        return binding[0].format(allocator);
    }
};

pub fn actionId(action: Action) []const u8 {
    return DEFINITIONS[@intFromEnum(action)].id;
}

pub fn editorActionId(action: EditorAction) []const u8 {
    return EDITOR_DEFINITIONS[@intFromEnum(action)].id;
}

pub fn defaultEditorActionForMatch(context: anytype, matcher: anytype) ?EditorAction {
    for (EDITOR_DEFINITIONS) |definition| {
        for (definition.defaults) |raw| {
            const spec = parseKeySpec(raw) orelse continue;
            if (matcher(spec, context)) return definition.action;
        }
    }
    return null;
}
pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Keybindings {
    var keybindings = try Keybindings.initDefaults(allocator);
    errdefer keybindings.deinit();

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return keybindings,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return keybindings;
    defer parsed.deinit();

    if (parsed.value != .object) return keybindings;

    // Build a migration-resolved config: apply legacy name migrations.
    // Modern name takes precedence over legacy when both are present.
    var resolved = std.StringHashMap(std.json.Value).init(allocator);
    defer resolved.deinit();

    for (parsed.value.object.keys(), parsed.value.object.values()) |key, value| {
        // Check if this is a legacy name and find the modern equivalent.
        const modern_key = legacyToModern(key) orelse key;
        // If modern key is already present (from an explicit modern entry), skip the legacy one.
        if (std.mem.eql(u8, modern_key, key)) {
            // Not a legacy name, or no migration found: use as-is.
            try resolved.put(key, value);
        } else {
            // This is a legacy name. Only add if the modern name is not already present.
            if (!parsed.value.object.contains(modern_key)) {
                try resolved.put(modern_key, value);
            }
        }
    }

    for (DEFINITIONS) |definition| {
        const raw_binding = resolved.get(definition.id) orelse continue;
        const specs = parseBindingValue(allocator, raw_binding) catch continue;
        defer allocator.free(specs);
        try keybindings.setBinding(definition.action, specs);
    }
    for (EDITOR_DEFINITIONS) |definition| {
        const raw_binding = resolved.get(definition.id) orelse continue;
        const specs = parseBindingValue(allocator, raw_binding) catch continue;
        defer allocator.free(specs);
        try keybindings.setEditorBinding(definition.action, specs);
    }

    return keybindings;
}

fn legacyToModern(key: []const u8) ?[]const u8 {
    return LEGACY_MIGRATION_MAP.get(key);
}

fn assertDefinitionsCoverActions(comptime Enum: type, comptime definitions: anytype) void {
    @setEvalBranchQuota(100_000);
    const enum_fields = @typeInfo(Enum).@"enum".fields;
    if (definitions.len != enum_fields.len) {
        @compileError("keybinding definitions length must match action enum length");
    }

    inline for (definitions, 0..) |definition, index| {
        if (@as(usize, @intFromEnum(definition.action)) != index) {
            @compileError("keybinding definition action order must match enum order");
        }

        inline for (definition.defaults) |raw| {
            _ = parseKeySpec(raw) orelse @compileError("keybinding default must parse");
        }

        inline for (definitions, 0..) |other, other_index| {
            if (other_index <= index) continue;
            if (definition.action == other.action) {
                @compileError("duplicate keybinding action definition");
            }
            if (std.mem.eql(u8, definition.id, other.id)) {
                @compileError("duplicate keybinding definition id");
            }
        }
    }
}

fn assertNoUnexpectedDefaultCollisions(comptime definitions: anytype, comptime allowed_collisions: anytype) void {
    @setEvalBranchQuota(100_000);
    inline for (definitions, 0..) |definition, definition_index| {
        inline for (definition.defaults, 0..) |raw, default_index| {
            inline for (definitions, 0..) |other, other_definition_index| {
                inline for (other.defaults, 0..) |other_raw, other_default_index| {
                    if (other_definition_index < definition_index or
                        (other_definition_index == definition_index and other_default_index <= default_index))
                    {
                        continue;
                    }

                    if (std.ascii.eqlIgnoreCase(raw, other_raw) and
                        !defaultCollisionAllowed(allowed_collisions, raw, definition.id, other.id))
                    {
                        @compileError("unexpected duplicate keybinding default");
                    }
                }
            }
        }
    }
}

fn defaultCollisionAllowed(
    comptime allowed_collisions: anytype,
    comptime key: []const u8,
    comptime first_id: []const u8,
    comptime second_id: []const u8,
) bool {
    inline for (allowed_collisions) |allowed| {
        _ = parseKeySpec(allowed.key) orelse @compileError("allowed keybinding collision key must parse");
        const ids_match =
            (std.mem.eql(u8, first_id, allowed.first_id) and std.mem.eql(u8, second_id, allowed.second_id)) or
            (std.mem.eql(u8, first_id, allowed.second_id) and std.mem.eql(u8, second_id, allowed.first_id));
        if (ids_match and std.ascii.eqlIgnoreCase(key, allowed.key)) return true;
    }
    return false;
}

fn assertLegacyMigrationTable() void {
    @setEvalBranchQuota(100_000);
    inline for (LEGACY_MIGRATIONS, 0..) |migration, index| {
        if (!bindingIdExists(migration.modern)) {
            @compileError("legacy keybinding migration target must be a known binding id");
        }
        inline for (LEGACY_MIGRATIONS, 0..) |other, other_index| {
            if (other_index <= index) continue;
            if (std.mem.eql(u8, migration.legacy, other.legacy)) {
                @compileError("duplicate legacy keybinding migration");
            }
        }
    }
}

fn bindingIdExists(comptime id: []const u8) bool {
    inline for (DEFINITIONS) |definition| {
        if (std.mem.eql(u8, id, definition.id)) return true;
    }
    inline for (EDITOR_DEFINITIONS) |definition| {
        if (std.mem.eql(u8, id, definition.id)) return true;
    }
    return false;
}

fn parseBindingValue(allocator: std.mem.Allocator, value: std.json.Value) ![]KeySpec {
    return switch (value) {
        .string => |binding| parseBindingList(allocator, &.{binding}),
        .array => |items| blk: {
            var values = std.ArrayList([]const u8).empty;
            defer values.deinit(allocator);

            for (items.items) |item| {
                if (item != .string) continue;
                try values.append(allocator, item.string);
            }
            break :blk parseBindingList(allocator, values.items);
        },
        else => allocator.dupe(KeySpec, &.{}),
    };
}

fn parseBindingList(allocator: std.mem.Allocator, entries: []const []const u8) ![]KeySpec {
    var specs = std.ArrayList(KeySpec).empty;
    defer specs.deinit(allocator);

    for (entries) |entry| {
        const spec = parseKeySpec(entry) orelse continue;
        try specs.append(allocator, spec);
    }

    return specs.toOwnedSlice(allocator);
}

test "keybinding core loads defaults and labels without TUI" {
    const allocator = std.testing.allocator;
    var defaults = try Keybindings.initDefaults(allocator);
    defer defaults.deinit();

    try std.testing.expectEqual(ACTION_COUNT, defaults.bindings.len);
    try std.testing.expectEqual(EDITOR_ACTION_COUNT, defaults.editor_bindings.len);
    try std.testing.expectEqualStrings("app.clear", actionId(.clear));
    try std.testing.expectEqualStrings("tui.input.submit", editorActionId(.input_submit));

    const label = try defaults.primaryLabel(allocator, .clear);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("Ctrl+C", label);
}

test "keybinding core loadFromFile overrides bindings" {
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

    try std.testing.expectEqualDeep(KeySpec{ .ctrl = 'x' }, loaded.bindingForAction(.clear)[0]);
    try std.testing.expectEqualDeep(KeySpec{ .ctrl = 'j' }, loaded.bindingForEditorAction(.input_submit)[0]);
}
