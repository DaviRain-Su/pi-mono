const std = @import("std");
const types = @import("types.zig");
const images_api_registry = @import("images_api_registry.zig");

pub const GenerateImagesError = error{
    NoImagesApiProvider,
};

fn resolveImagesApiProvider(api: types.ImagesApi) GenerateImagesError!images_api_registry.ImagesApiProvider {
    return images_api_registry.get(api) orelse GenerateImagesError.NoImagesApiProvider;
}

pub fn generateImages(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.ImagesModel,
    context: types.ImagesContext,
    options: ?types.ImagesOptions,
) !types.AssistantImages {
    const provider = try resolveImagesApiProvider(model.api);
    return try provider.generate_images(allocator, io, model, context, options);
}

test "generateImages resolves built-in images API provider" {
    images_api_registry.resetToBuiltIns();

    const model = types.ImagesModel{
        .id = "fixture",
        .name = "Fixture",
        .api = "openrouter-images",
        .provider = "openrouter",
        .base_url = "http://127.0.0.1:1",
        .input = &[_][]const u8{"text"},
        .output = &[_][]const u8{"image"},
    };
    const input = [_]types.ImagesInputContent{.{ .text = .{ .text = "hello" } }};
    const context = types.ImagesContext{ .input = &input };

    const result = try generateImages(std.testing.allocator, std.testing.io, model, context, .{ .api_key = "placeholder" });
    defer types.freeAssistantImages(std.testing.allocator, result);
    try std.testing.expectEqual(types.ImagesStopReason.@"error", result.stop_reason);
    try std.testing.expect(result.error_message != null);
}
