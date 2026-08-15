comptime {
    _ = @import("tests/wire_fixtures.zig");
    _ = @import("tests/direct_bash.zig");
    _ = @import("tests/session_lifecycle.zig");
    _ = @import("tests/extension_ui.zig");
    _ = @import("tests/command_context.zig");
    _ = @import("tests/wire_format_cleanup.zig");
}
