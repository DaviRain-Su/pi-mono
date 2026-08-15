pub const types = @import("../../oauth/types.zig");
pub const OAuthCredentials = types.OAuthCredentials;
pub const OAuthProviderId = types.OAuthProviderId;
pub const OAuthLoginCallbacks = types.OAuthLoginCallbacks;
pub const OAuthProviderInterface = types.OAuthProviderInterface;

test {
    _ = @import("../../oauth/types.zig");
}
