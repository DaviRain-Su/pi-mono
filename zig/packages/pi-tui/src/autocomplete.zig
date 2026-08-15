const std = @import("std");
const component_autocomplete = @import("components/autocomplete.zig");
const select_list = @import("vaxis-widgets").components.select_list;

pub const AutocompleteItem = struct {
    value: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const SlashCommand = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    argument_hint: ?[]const u8 = null,
};

pub const AutocompleteSuggestions = struct {
    items: []const AutocompleteItem,
    prefix: []const u8,
};

pub const ApplyCompletionResult = struct {
    lines: []const []const u8,
    cursor_line: usize,
    cursor_col: usize,
};

pub const AutocompleteProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_suggestions: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            lines: []const []const u8,
            cursor_line: usize,
            cursor_col: usize,
            force: bool,
        ) anyerror!?AutocompleteSuggestions,
        apply_completion: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            lines: []const []const u8,
            cursor_line: usize,
            cursor_col: usize,
            item: AutocompleteItem,
            prefix: []const u8,
        ) anyerror!ApplyCompletionResult,
        should_trigger_file_completion: ?*const fn (
            ptr: *anyopaque,
            lines: []const []const u8,
            cursor_line: usize,
            cursor_col: usize,
        ) bool = null,
    };
};

pub const Item = component_autocomplete.Item;
pub const Match = component_autocomplete.Match;
pub const fuzzyMatch = component_autocomplete.fuzzyMatch;
pub const fuzzyFilterAlloc = component_autocomplete.fuzzyFilterAlloc;

pub fn selectItemFromAutocompleteItem(allocator: std.mem.Allocator, item: AutocompleteItem) !select_list.SelectItem {
    return .{
        .value = try allocator.dupe(u8, item.value),
        .label = try allocator.dupe(u8, item.label),
        .description = if (item.description) |description| try allocator.dupe(u8, description) else null,
    };
}

test "autocomplete top-level module re-exports fuzzy helpers" {
    const match = fuzzyMatch("rd", "README.md");
    try std.testing.expect(match.matches);
}
