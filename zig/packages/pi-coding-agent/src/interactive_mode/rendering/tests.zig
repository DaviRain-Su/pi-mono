const common_tests = @import("tests/common.zig");
const layout_footer_tests = @import("tests/layout_footer.zig");
const scrolling_tests = @import("tests/scrolling.zig");
const chat_items_tests = @import("tests/chat_items.zig");
const overlays_snapshots_tests = @import("tests/overlays_snapshots.zig");

pub const InteractiveModeTestBackend = common_tests.InteractiveModeTestBackend;
pub const renderScreenWithMockBackend = common_tests.renderScreenWithMockBackend;
pub const renderScreenWithMockBackendAndOverlay = common_tests.renderScreenWithMockBackendAndOverlay;
pub const renderedLinesContain = common_tests.renderedLinesContain;
