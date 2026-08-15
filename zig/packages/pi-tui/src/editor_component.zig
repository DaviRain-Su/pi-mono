const std = @import("std");
const draw = @import("vaxis-widgets").draw;
const autocomplete = @import("autocomplete.zig");

pub const OnSubmit = *const fn (ctx: ?*anyopaque, text: []const u8) void;
pub const OnChange = *const fn (ctx: ?*anyopaque, text: []const u8) void;

pub const VTable = struct {
    draw_component: *const fn (ctx: *const anyopaque) draw.Component,
    get_text: *const fn (ctx: *const anyopaque) []const u8,
    set_text: *const fn (ctx: *anyopaque, text: []const u8) anyerror!void,
    handle_input: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    add_to_history: ?*const fn (ctx: *anyopaque, text: []const u8) anyerror!void = null,
    insert_text_at_cursor: ?*const fn (ctx: *anyopaque, text: []const u8) anyerror!void = null,
    get_expanded_text: ?*const fn (ctx: *const anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    set_autocomplete_provider: ?*const fn (ctx: *anyopaque, provider: autocomplete.AutocompleteProvider) anyerror!void = null,
    set_padding_x: ?*const fn (ctx: *anyopaque, padding: usize) void = null,
    set_autocomplete_max_visible: ?*const fn (ctx: *anyopaque, max_visible: usize) void = null,
};

pub const EditorComponent = struct {
    ptr: *anyopaque,
    const_ptr: *const anyopaque,
    vtable: *const VTable,
    callback_ctx: ?*anyopaque = null,
    on_submit: ?OnSubmit = null,
    on_change: ?OnChange = null,

    pub fn drawComponent(self: *const EditorComponent) draw.Component {
        return self.vtable.draw_component(self.const_ptr);
    }

    pub fn getText(self: *const EditorComponent) []const u8 {
        return self.vtable.get_text(self.const_ptr);
    }

    pub fn setText(self: *EditorComponent, text: []const u8) !void {
        try self.vtable.set_text(self.ptr, text);
        if (self.on_change) |callback| callback(self.callback_ctx, self.getText());
    }

    pub fn handleInput(self: *EditorComponent, data: []const u8) !void {
        try self.vtable.handle_input(self.ptr, data);
    }

    pub fn addToHistory(self: *EditorComponent, text: []const u8) !void {
        if (self.vtable.add_to_history) |callback| try callback(self.ptr, text);
    }

    pub fn insertTextAtCursor(self: *EditorComponent, text: []const u8) !void {
        if (self.vtable.insert_text_at_cursor) |callback| try callback(self.ptr, text);
    }

    pub fn getExpandedText(self: *const EditorComponent, allocator: std.mem.Allocator) ![]u8 {
        if (self.vtable.get_expanded_text) |callback| return try callback(self.const_ptr, allocator);
        return allocator.dupe(u8, self.getText());
    }

    pub fn setAutocompleteProvider(self: *EditorComponent, provider: autocomplete.AutocompleteProvider) !void {
        if (self.vtable.set_autocomplete_provider) |callback| try callback(self.ptr, provider);
    }

    pub fn setPaddingX(self: *EditorComponent, padding: usize) void {
        if (self.vtable.set_padding_x) |callback| callback(self.ptr, padding);
    }

    pub fn setAutocompleteMaxVisible(self: *EditorComponent, max_visible: usize) void {
        if (self.vtable.set_autocomplete_max_visible) |callback| callback(self.ptr, max_visible);
    }
};

test "EditorComponent type exposes optional editor surface" {
    _ = EditorComponent;
    _ = VTable;
}
