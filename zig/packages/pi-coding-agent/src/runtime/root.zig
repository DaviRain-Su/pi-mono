pub const tool_registry = @import("tool_registry.zig");
pub const hooks = @import("hooks.zig");
pub const interactive_hooks = @import("interactive_hooks.zig");
pub const ui_runtime = @import("ui_runtime.zig");

test {
    _ = @import("tool_registry.zig");
    _ = @import("hooks.zig");
    _ = @import("interactive_hooks.zig");
    _ = @import("ui_runtime.zig");
}
