pub const diagnostics = @import("../shared/diagnostics.zig");
pub const formatDiagnosticMessage = diagnostics.formatDiagnosticMessage;

test {
    _ = @import("../shared/diagnostics.zig");
}
