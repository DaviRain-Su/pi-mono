const std = @import("std");
const types = @import("../types.zig");

/// AI provider abort signals are caller-owned cross-thread cancellation flags.
/// Use one ordering everywhere the AI stream/provider/runtime contract observes
/// them so pre-provider checks, HTTP runtime checks, and provider-local helpers
/// classify cancellation consistently.
pub fn isRequested(signal: ?*const std.atomic.Value(bool)) bool {
    const abort_signal = signal orelse return false;
    return abort_signal.load(.seq_cst);
}

pub fn isRequestedFromOptions(options: ?types.StreamOptions) bool {
    const stream_options = options orelse return false;
    return isRequested(stream_options.signal);
}

test "AI abort signal helper uses one contract for raw signals and stream options" {
    var signal = std.atomic.Value(bool).init(false);
    try std.testing.expect(!isRequested(null));
    try std.testing.expect(!isRequested(&signal));
    try std.testing.expect(!isRequestedFromOptions(.{ .signal = &signal }));

    signal.store(true, .seq_cst);
    try std.testing.expect(isRequested(&signal));
    try std.testing.expect(isRequestedFromOptions(.{ .signal = &signal }));
}
