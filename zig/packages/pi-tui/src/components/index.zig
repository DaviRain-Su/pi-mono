pub const autocomplete = @import("autocomplete.zig");
pub const box = @import("box.zig").module;
pub const cancellable_loader = @import("cancellable_loader.zig").module;
pub const editor = @import("editor.zig").module;
pub const image = @import("image.zig").module;
pub const input = @import("input.zig").module;
pub const loader = @import("loader.zig").module;
pub const markdown = @import("markdown.zig").module;
pub const select_list = @import("select_list.zig").module;
pub const settings_list = @import("settings_list.zig").module;
pub const spacer = @import("spacer.zig").module;
pub const text = @import("text.zig").module;
pub const truncated_text = @import("truncated_text.zig").module;

test {
    _ = autocomplete;
    _ = box;
    _ = cancellable_loader;
    _ = editor;
    _ = image;
    _ = input;
    _ = loader;
    _ = markdown;
    _ = select_list;
    _ = settings_list;
    _ = spacer;
    _ = text;
    _ = truncated_text;
}
