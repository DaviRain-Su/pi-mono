pub const generated = @import("image_models_generated.zig");
pub const STATIC_IMAGE_MODELS = generated.STATIC_IMAGE_MODELS;

test {
    _ = @import("image_models_generated.zig");
}
