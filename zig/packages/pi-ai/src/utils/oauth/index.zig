const std = @import("std");

pub const pkce = @import("../../oauth/pkce.zig");
pub const types = @import("../../oauth/types.zig");
pub const common = @import("common.zig");
pub const anthropic = @import("anthropic.zig");
pub const github_copilot = @import("github_copilot.zig");
pub const openai_codex = @import("openai_codex.zig");
pub const xai = @import("xai.zig");
pub const oauth_page = @import("oauth_page.zig");

pub const anthropicOAuthProvider = anthropic.anthropicOAuthProvider;
pub const githubCopilotOAuthProvider = github_copilot.githubCopilotOAuthProvider;
pub const openaiCodexOAuthProvider = openai_codex.openaiCodexOAuthProvider;
pub const xaiOAuthProvider = xai.xaiOAuthProvider;

const BUILT_IN_OAUTH_PROVIDERS = [_]types.OAuthProviderInterface{
    anthropicOAuthProvider,
    githubCopilotOAuthProvider,
    openaiCodexOAuthProvider,
    xaiOAuthProvider,
};

pub fn getOAuthProvider(id: types.OAuthProviderId) ?types.OAuthProviderInterface {
    for (BUILT_IN_OAUTH_PROVIDERS) |provider| {
        if (std.mem.eql(u8, provider.id, id)) return provider;
    }
    return null;
}

pub fn getOAuthProviders() []const types.OAuthProviderInterface {
    return &BUILT_IN_OAUTH_PROVIDERS;
}

test {
    _ = pkce;
    _ = types;
    _ = common;
    _ = anthropic;
    _ = github_copilot;
    _ = openai_codex;
    _ = xai;
    _ = oauth_page;
    try std.testing.expect(getOAuthProvider("anthropic") != null);
    try std.testing.expect(getOAuthProvider("xai-oauth") != null);
}
