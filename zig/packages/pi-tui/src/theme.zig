const shared_theme = @import("shared").theme;

pub const ThemeColor = shared_theme.ThemeColor;
pub const ThemeToken = shared_theme.ThemeToken;
pub const StyleSpec = shared_theme.StyleSpec;
pub const ThemeColors = shared_theme.ThemeColors;
pub const Theme = shared_theme.Theme;
pub const PaletteTemplate = shared_theme.PaletteTemplate;
pub const parseNamedColor = shared_theme.parseNamedColor;

test "tui theme module re-exports shared theme helpers" {
    var theme = try Theme.initDefault(@import("std").testing.allocator);
    defer theme.deinit(@import("std").testing.allocator);
}
