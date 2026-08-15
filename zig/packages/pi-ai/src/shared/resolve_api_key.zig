const std = @import("std");
const types = @import("../types.zig");
const event_stream = @import("../event_stream.zig");
const env_api_keys = @import("../env_api_keys.zig");

/// Result of API key resolution.  `owned` is non-null when the key was
/// obtained from the environment and must be freed by the caller.
pub const ResolvedApiKey = struct {
    key: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.owned) |o| allocator.free(o);
    }
};

/// Resolve the effective API key for a stream request.
///
/// Precedence:
///   1. `options.api_key` if non-null and non-empty (caller-owned, not freed here).
///   2. Environment variable lookup via `env_api_keys.getEnvApiKey`.
///
/// Returns `null` when no key is available.
pub fn resolveApiKey(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !?ResolvedApiKey {
    const provided = if (options) |o| o.api_key else null;
    if (provided) |key| {
        if (key.len > 0) return .{ .key = key };
    }

    const env_key = try env_api_keys.getEnvApiKey(allocator, model.provider);
    if (env_key) |ek| {
        if (ek.len > 0) return .{ .key = ek, .owned = ek };
        allocator.free(ek);
    }

    return null;
}

/// Push a deterministic, sanitized terminal error event when no API key
/// is available. Mirrors the TypeScript `No API key for provider:` diagnostic.
/// Must not leak environment values, credential-store paths, or bearer tokens.
pub fn pushMissingApiKeyError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
) !void {
    const error_message = try std.fmt.allocPrint(
        allocator,
        "No API key for provider: {s}",
        .{model.provider},
    );
    const message = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
}
