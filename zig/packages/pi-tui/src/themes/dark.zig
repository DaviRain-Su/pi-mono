const theme_mod = @import("../theme.zig");

pub fn palette() theme_mod.PaletteTemplate {
    return .{
        .primary = "#8abeb7",
        .secondary = "#81a2be",
        .success = "#b5bd68",
        .warning = "#ffff00",
        .@"error" = "#cc6666",
        .background = "#000000",
        .foreground = "#ffffff",
        .border = "#5f87ff",
        .muted = "#808080",
        .dim = "#666666",
        .thinking_text = "#808080",
        .selected_bg = "#3a3a4a",
        .user_message_bg = "#343541",
        .custom_message_bg = "#2d2838",
        .tool_pending_bg = "#282832",
        .tool_success_bg = "#283228",
        .tool_error_bg = "#3c2828",
        .border_accent = "#00d7ff",
        .border_muted = "#505050",
        .markdown_heading = "#f0c674",
        .markdown_link = "#81a2be",
        .markdown_code = "#8abeb7",
        .markdown_code_border = "#808080",
        .markdown_quote = "#808080",
        .markdown_quote_border = "#808080",
        .markdown_rule = "#808080",
        .markdown_list_bullet = "#8abeb7",
        .tool_output = "#808080",
    };
}
