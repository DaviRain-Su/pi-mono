const theme_mod = @import("../theme.zig");

pub fn palette() theme_mod.PaletteTemplate {
    return .{
        .primary = "#5a8080",
        .secondary = "#547da7",
        .success = "#588458",
        .warning = "#9a7326",
        .@"error" = "#aa5555",
        .background = "#ffffff",
        .foreground = "#000000",
        .border = "#547da7",
        .muted = "#6c6c6c",
        .dim = "#767676",
        .thinking_text = "#6c6c6c",
        .selected_bg = "#d0d0e0",
        .user_message_bg = "#e8e8e8",
        .custom_message_bg = "#ede7f6",
        .tool_pending_bg = "#e8e8f0",
        .tool_success_bg = "#e8f0e8",
        .tool_error_bg = "#f0e8e8",
        .border_accent = "#5a8080",
        .border_muted = "#b0b0b0",
        .markdown_heading = "#9a7326",
        .markdown_link = "#547da7",
        .markdown_code = "#5a8080",
        .markdown_code_border = "#6c6c6c",
        .markdown_quote = "#6c6c6c",
        .markdown_quote_border = "#6c6c6c",
        .markdown_rule = "#6c6c6c",
        .markdown_list_bullet = "#588458",
        .tool_output = "#6c6c6c",
    };
}
