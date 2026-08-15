const std = @import("std");
const types = @import("types.zig");
const image_models_generated = @import("image_models_generated.zig");

pub const ProviderConfig = image_models_generated.ProviderConfig;

pub fn getImageProviders() []const ProviderConfig {
    return image_models_generated.provider_configs[0..];
}

pub fn getImageModels(provider: []const u8) []const types.ImagesModel {
    const first_index = firstModelIndex(provider) orelse return &[_]types.ImagesModel{};
    var end_index = first_index;
    while (end_index < image_models_generated.models.len and
        std.mem.eql(u8, image_models_generated.models[end_index].provider, provider))
    {
        end_index += 1;
    }
    return image_models_generated.models[first_index..end_index];
}

pub fn getImageModel(provider: []const u8, model_id: []const u8) ?types.ImagesModel {
    for (image_models_generated.models) |model| {
        if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) {
            return model;
        }
    }
    return null;
}

pub fn getImageModelById(model_id: []const u8) ?types.ImagesModel {
    var found: ?types.ImagesModel = null;
    for (image_models_generated.models) |model| {
        if (!std.mem.eql(u8, model.id, model_id)) continue;
        if (found != null) return null;
        found = model;
    }
    return found;
}

fn firstModelIndex(provider: []const u8) ?usize {
    for (image_models_generated.models, 0..) |model, index| {
        if (std.mem.eql(u8, model.provider, provider)) return index;
    }
    return null;
}

test "image model registry exposes generated OpenRouter models" {
    try std.testing.expect(image_models_generated.provider_count > 0);
    try std.testing.expect(image_models_generated.model_count > 0);
    const model = getImageModel("openrouter", "openrouter/auto").?;
    try std.testing.expectEqualStrings("openrouter-images", model.api);
    try std.testing.expectEqualStrings("openrouter", model.provider);
    try std.testing.expect(getImageModels("openrouter").len > 0);
}
