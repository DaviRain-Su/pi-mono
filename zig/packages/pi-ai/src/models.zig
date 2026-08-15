pub const registry = @import("model_registry.zig");
pub const generated = @import("models_generated.zig");

pub const ModelRegistry = registry.ModelRegistry;
pub const STATIC_MODELS = generated.STATIC_MODELS;
pub const calculateCost = registry.calculateCost;
pub const clampThinkingLevel = registry.clampThinkingLevel;

test {
    _ = registry;
    _ = generated;
}
