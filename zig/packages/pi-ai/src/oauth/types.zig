const std = @import("std");

/// OAuth credentials for authenticated providers
pub const OAuthCredentials = struct {
    refresh: []const u8,
    access: []const u8,
    expires: i64,
    account_id: ?[]const u8 = null,
    enterprise_url: ?[]const u8 = null,

    pub fn deinit(self: *const OAuthCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.refresh);
        allocator.free(self.access);
        if (self.account_id) |account_id| allocator.free(account_id);
        if (self.enterprise_url) |enterprise_url| allocator.free(enterprise_url);
    }
};

/// OAuth provider identifier
pub const OAuthProviderId = []const u8;

/// Prompt for user input during OAuth flow
pub const OAuthPrompt = struct {
    message: []const u8,
    placeholder: ?[]const u8 = null,
    allow_empty: bool = false,
};

/// Authentication info returned to caller
pub const OAuthAuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,

    pub fn deinit(self: *const OAuthAuthInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.instructions) |instr| allocator.free(instr);
    }
};

/// Callbacks for OAuth login flow
pub const OAuthLoginCallbacks = struct {
    onAuth: *const fn (info: OAuthAuthInfo) void,
    onPrompt: *const fn (prompt: OAuthPrompt) []const u8,
    onProgress: ?*const fn (message: []const u8) void = null,
    onManualCodeInput: ?*const fn () []const u8 = null,
};

/// OAuth provider interface
pub const OAuthProviderInterface = struct {
    id: OAuthProviderId,
    name: []const u8,

    /// Run the login flow, return credentials to persist
    login: *const fn (
        allocator: std.mem.Allocator,
        callbacks: OAuthLoginCallbacks,
    ) anyerror!OAuthCredentials,

    /// Whether login uses a local callback server and supports manual code input
    uses_callback_server: bool = false,

    /// Refresh expired credentials, return updated credentials to persist
    refreshToken: *const fn (
        allocator: std.mem.Allocator,
        credentials: OAuthCredentials,
    ) anyerror!OAuthCredentials,

    /// Convert credentials to API key string for the provider
    getApiKey: *const fn (credentials: OAuthCredentials) []const u8,
};

/// OAuth errors
pub const OAuthError = error{
    LoginCancelled,
    InvalidResponse,
    DeviceFlowTimeout,
    DeviceFlowSlowDown,
    InvalidDomain,
    TokenRefreshFailed,
    NetworkError,
};

test "OAuth types basic" {
    const creds = OAuthCredentials{
        .refresh = "refresh_token",
        .access = "access_token",
        .expires = 1234567890,
    };
    try std.testing.expectEqualStrings("refresh_token", creds.refresh);
    try std.testing.expectEqualStrings("access_token", creds.access);
    try std.testing.expectEqual(@as(i64, 1234567890), creds.expires);
}
