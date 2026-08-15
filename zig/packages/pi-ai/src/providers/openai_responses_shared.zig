pub const responses_api = @import("../shared/responses_api.zig");
pub const CurrentBlock = responses_api.CurrentBlock;
pub const deinitCurrentBlock = responses_api.deinitCurrentBlock;
pub const extractReasoningSummary = responses_api.extractReasoningSummary;
pub const finalizeCurrentBlock = responses_api.finalizeCurrentBlock;
pub const updateCurrentMessagePart = responses_api.updateCurrentMessagePart;

test {
    _ = @import("../shared/responses_api.zig");
}
