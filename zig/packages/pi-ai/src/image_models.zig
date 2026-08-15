pub const registry = @import("image_model_registry.zig");
pub const generated = @import("image_models_generated.zig");

pub const ImageModelEntry = registry.ImageModelEntry;
pub const ImageModelRegistry = registry.ImageModelRegistry;
pub const STATIC_IMAGE_MODELS = generated.STATIC_IMAGE_MODELS;

test {
    _ = registry;
    _ = generated;
}
