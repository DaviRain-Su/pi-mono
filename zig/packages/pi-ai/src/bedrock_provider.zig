pub const provider = @import("providers/bedrock.zig");
pub const bedrockProviderModule = provider.BedrockProvider;

test {
    _ = provider;
}
