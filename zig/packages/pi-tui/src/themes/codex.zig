const theme_mod = @import("../theme.zig");

pub fn palette() theme_mod.PaletteTemplate {
    return .{
        .primary = "#d18b50",
        .secondary = "#b25d3a",
        .success = "#7fb069",
        .warning = "#e6b566",
        .@"error" = "#d96459",
        .background = "#0f1012",
        .foreground = "#e8e2d9",
        .border = "#2a2622",
        .muted = "#7a716a",
    };
}
