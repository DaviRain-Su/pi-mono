const std = @import("std");
const types = @import("types.zig");
const image_builtins = @import("providers/images/register_builtins.zig");

pub const ImagesFunction = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.ImagesModel,
    context: types.ImagesContext,
    options: ?types.ImagesOptions,
) anyerror!types.AssistantImages;

pub const ImagesApiProvider = struct {
    api: types.ImagesApi,
    generate_images: ImagesFunction,
};

const STATIC_BUILTINS = blk: {
    const providers = image_builtins.builtInProviders();
    var entries: [providers.len]struct { []const u8, ImagesApiProvider } = undefined;
    for (providers, 0..) |provider, index| {
        entries[index] = .{ provider.api, provider };
    }
    break :blk std.StaticStringMap(ImagesApiProvider).initComptime(entries);
};

var overrides: std.StringHashMap(ImagesApiProvider) = undefined;
var initialized = false;

pub fn init() void {
    if (initialized) return;
    overrides = std.StringHashMap(ImagesApiProvider).init(std.heap.page_allocator);
    initialized = true;
}

pub fn register(provider: ImagesApiProvider) !void {
    init();
    try overrides.put(provider.api, provider);
}

pub fn get(api: types.ImagesApi) ?ImagesApiProvider {
    if (initialized) {
        if (overrides.get(api)) |provider| return provider;
    }
    return STATIC_BUILTINS.get(api);
}

pub fn getApiCount() usize {
    const static_count: usize = STATIC_BUILTINS.kvs.len;
    return static_count + if (initialized) overrides.count() else 0;
}

pub fn unregister(api: types.ImagesApi) void {
    if (!initialized) return;
    _ = overrides.remove(api);
}

pub fn clear() void {
    if (!initialized) return;
    overrides.clearAndFree();
}

pub fn resetForTesting() void {
    if (initialized) overrides.clearAndFree();
}

pub fn resetToBuiltIns() void {
    clear();
}

test "built-in images providers are accessible via static map" {
    resetForTesting();
    defer clear();

    try std.testing.expectEqual(image_builtins.expectedBuiltInApiCount(), STATIC_BUILTINS.kvs.len);
    for (image_builtins.expectedBuiltInApis()) |api| {
        try std.testing.expect(get(api) != null);
    }
}

test "built-in images providers survive clear" {
    resetForTesting();
    defer clear();

    clear();
    for (image_builtins.expectedBuiltInApis()) |api| {
        try std.testing.expect(get(api) != null);
    }
}
