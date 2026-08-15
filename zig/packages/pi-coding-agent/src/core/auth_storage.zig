pub const auth = @import("../auth/auth.zig");

pub const ApiKeyCredential = struct {
    key: []const u8,
};

pub const OAuthCredential = auth.OAuthCredential;
pub const AuthCredential = auth.StoredCredential;
pub const AuthStatus = struct {
    configured: bool,
    source: ?auth.CredentialSource = null,
    label: ?[]const u8 = null,
};

pub const CredentialSource = auth.CredentialSource;
pub const readStoredCredentialsObject = auth.readStoredCredentialsObject;
pub const upsertStoredCredential = auth.upsertStoredCredential;
pub const removeStoredCredential = auth.removeStoredCredential;
pub const resolveApiKey = auth.resolveApiKey;

test "auth storage facade exposes stored credential helpers" {
    _ = readStoredCredentialsObject;
    _ = upsertStoredCredential;
    _ = resolveApiKey;
}
