pub const simple_options = @import("../shared/simple_options.zig");
pub const buildBaseOptions = simple_options.buildBaseOptions;
pub const adjustMaxTokensForThinking = simple_options.adjustMaxTokensForThinking;

test {
    _ = @import("../shared/simple_options.zig");
}
