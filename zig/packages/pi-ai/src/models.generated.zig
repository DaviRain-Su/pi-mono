pub const generated = @import("models_generated.zig");
pub const STATIC_MODELS = generated.STATIC_MODELS;

test {
    _ = @import("models_generated.zig");
}
