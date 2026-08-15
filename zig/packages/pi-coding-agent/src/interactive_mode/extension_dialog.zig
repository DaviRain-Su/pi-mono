const std = @import("std");
const tui = @import("tui");
const json_format = @import("../shared/json_format.zig");
const keybindings_mod = @import("../shared/keybindings.zig");

const writeJsonString = json_format.writeJsonString;

pub const DialogKind = enum {
    select,
    confirm,
    input,
    editor,
};

pub const ExtensionDialog = struct {
    id: []u8,
    kind: DialogKind,
    title: []u8,
    hint: []u8,
    message: []u8 = &.{},
    choices: [][]u8 = &.{},
    items: []tui.SelectItem = &.{},
    list: tui.SelectList = .{ .items = &.{}, .max_visible = 8 },
    editor: tui.Editor,
    timeout_deadline_ms: ?i64 = null,
    resolved_payload_json: ?[]u8 = null,

    pub fn deinit(self: *ExtensionDialog, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.hint);
        if (self.message.len > 0) allocator.free(self.message);
        for (self.choices) |choice| allocator.free(choice);
        if (self.choices.len > 0) allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        if (self.items.len > 0) allocator.free(self.items);
        self.editor.deinit();
        if (self.resolved_payload_json) |payload| allocator.free(payload);
        self.* = undefined;
    }

    pub fn resolveCancel(self: *ExtensionDialog, allocator: std.mem.Allocator) !void {
        try self.setResolvedPayload(allocator, "{\"cancelled\":true}");
    }

    fn setResolvedPayload(self: *ExtensionDialog, allocator: std.mem.Allocator, payload: []const u8) !void {
        if (self.resolved_payload_json != null) return;
        self.resolved_payload_json = try allocator.dupe(u8, payload);
    }

    fn resolveChoice(self: *ExtensionDialog, allocator: std.mem.Allocator, index: usize) !void {
        switch (self.kind) {
            .select => {
                const value = if (index < self.choices.len) self.choices[index] else "";
                var out: std.Io.Writer.Allocating = .init(allocator);
                defer out.deinit();
                try out.writer.writeAll("{\"value\":");
                try writeJsonString(allocator, &out.writer, value);
                try out.writer.writeAll("}");
                try self.setResolvedPayload(allocator, out.written());
            },
            .confirm => {
                try self.setResolvedPayload(allocator, if (index == 0) "{\"confirmed\":true}" else "{\"confirmed\":false}");
            },
            else => {},
        }
    }

    fn resolveEditorText(self: *ExtensionDialog, allocator: std.mem.Allocator) !void {
        const expanded = try self.editor.expandedTextAlloc(allocator);
        defer allocator.free(expanded);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("{\"value\":");
        try writeJsonString(allocator, &out.writer, expanded);
        try out.writer.writeAll("}");
        try self.setResolvedPayload(allocator, out.written());
    }
};

pub fn handleDialogKey(
    allocator: std.mem.Allocator,
    dialog: *ExtensionDialog,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
    keybindings: ?*const keybindings_mod.Keybindings,
) !void {
    if (matchesEditorAction(keybindings, .select_cancel, key, modifiers)) {
        try dialog.resolveCancel(allocator);
        return;
    }

    switch (dialog.kind) {
        .select, .confirm => {
            if (matchesEditorAction(keybindings, .select_up, key, modifiers)) {
                _ = dialog.list.handleKey(.up);
                return;
            }
            if (matchesEditorAction(keybindings, .select_down, key, modifiers)) {
                _ = dialog.list.handleKey(.down);
                return;
            }
            if (matchesEditorAction(keybindings, .select_page_up, key, modifiers)) {
                const selected = dialog.list.selectedIndex();
                dialog.list.setSelectedIndex(if (selected > dialog.list.max_visible) selected - dialog.list.max_visible else 0);
                return;
            }
            if (matchesEditorAction(keybindings, .select_page_down, key, modifiers)) {
                dialog.list.setSelectedIndex(dialog.list.selectedIndex() + dialog.list.max_visible);
                return;
            }
            if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
                try dialog.resolveChoice(allocator, dialog.list.selectedIndex());
                return;
            }
        },
        .input, .editor => {
            if (matchesEditorAction(keybindings, .select_confirm, key, modifiers)) {
                try dialog.resolveEditorText(allocator);
                return;
            }
            _ = try dialog.editor.handleKey(key);
        },
    }
}

fn matchesEditorAction(
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.EditorAction,
    key: tui.Key,
    modifiers: tui.keys.KeyModifiers,
) bool {
    if (keybindings) |bindings| return bindings.matchesEditorAction(action, key, modifiers);
    if (!modifiers.hasAny()) {
        switch (action) {
            .select_up => if (key == .up) return true,
            .select_down => if (key == .down) return true,
            .select_page_up => if (key == .page_up) return true,
            .select_page_down => if (key == .page_down) return true,
            .select_confirm => if (key == .enter) return true,
            else => {},
        }
    }
    if (action == .select_cancel) {
        switch (key) {
            .escape => return true,
            .ctrl => |ctrl| if (ctrl == 'c') return true,
            else => {},
        }
    }
    return keybindings_mod.defaultEditorActionForKeyWithModifiers(key, modifiers) == action;
}
