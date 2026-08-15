pub const module = @import("ai").model_registry;

pub const ModelRegistry = module.ModelRegistry;
pub const ModelSummary = module.ModelSummary;
pub const ModelDefinition = module.ModelDefinition;
pub const listSummaries = module.listSummaries;
pub const builtInProviderConfigs = module.builtInProviderConfigs;

test "model registry facade exposes summaries" {
    _ = ModelRegistry;
    _ = ModelSummary;
}
