pub const root = @import("root.zig");

pub const TUI = root.tui;
pub const Component = root.DrawComponent;
pub const Box = root.Box;
pub const CancellableLoader = root.CancellableLoader;
pub const Editor = root.Editor;
pub const Image = root.Image;
pub const Input = root.Input;
pub const Loader = root.Loader;
pub const Markdown = root.Markdown;
pub const SelectList = root.SelectList;
pub const SettingsList = root.SettingsList;
pub const Spacer = root.Spacer;
pub const Text = root.Text;
pub const TruncatedText = root.TruncatedText;
pub const EditorComponent = root.EditorComponent;
pub const FuzzyMatch = root.FuzzyMatch;
pub const fuzzyMatch = root.fuzzyMatch;
pub const KeybindingsManager = root.KeybindingsManager;
pub const StdinBuffer = root.StdinBuffer;
pub const Terminal = root.Terminal;
pub const TerminalCapabilities = root.TerminalCapabilities;

test "index module mirrors root entrypoint" {
    _ = Text;
}
