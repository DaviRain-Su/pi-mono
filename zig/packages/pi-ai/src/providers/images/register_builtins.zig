const std = @import("std");
const types = @import("../../types.zig");
const images_api_registry = @import("../../images_api_registry.zig");
const openrouter = @import("openrouter.zig");

const BuiltInImagesProvider = images_api_registry.ImagesApiProvider;

const BUILT_IN_APIS = [_]types.ImagesApi{
    "openrouter-images",
};

const BUILT_IN_PROVIDERS = [_]BuiltInImagesProvider{
    .{
        .api = "openrouter-images",
        .generate_images = openrouter.generateImagesOpenRouter,
    },
};

pub fn expectedBuiltInApis() []const types.ImagesApi {
    return BUILT_IN_APIS[0..];
}

pub fn expectedBuiltInApiCount() usize {
    return BUILT_IN_APIS.len;
}

pub fn builtInProviders() []const BuiltInImagesProvider {
    return BUILT_IN_PROVIDERS[0..];
}

test "register built-in image providers exposes OpenRouter" {
    try std.testing.expectEqual(@as(usize, 1), expectedBuiltInApiCount());
    try std.testing.expectEqualStrings("openrouter-images", expectedBuiltInApis()[0]);
    try std.testing.expectEqualStrings("openrouter-images", builtInProviders()[0].api);
}
