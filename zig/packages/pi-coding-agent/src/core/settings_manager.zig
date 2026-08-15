const std = @import("std");
const extension_policy = @import("extension_policy.zig");

pub const CompactionSettings = struct {
    enabled: ?bool = null,
    reserve_tokens: ?u64 = null,
    keep_recent_tokens: ?u64 = null,
};

pub const RetrySettings = struct {
    enabled: ?bool = null,
    max_retries: ?u64 = null,
    base_delay_ms: ?u64 = null,
};

pub const Settings = struct {
    default_provider: ?[]const u8 = null,
    default_model: ?[]const u8 = null,
    default_thinking_level: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    compaction: CompactionSettings = .{},
    retry: RetrySettings = .{},
    enable_install_telemetry: bool = true,
    extension_policies: ?extension_policy.ExtensionPolicy = null,
};

pub const SettingsManager = struct {
    settings: Settings = .{},

    pub fn init(settings: Settings) SettingsManager {
        return .{ .settings = settings };
    }

    pub fn getEnableInstallTelemetry(self: SettingsManager) bool {
        return self.settings.enable_install_telemetry;
    }

    pub fn getDefaultProvider(self: SettingsManager) ?[]const u8 {
        return self.settings.default_provider;
    }

    pub fn getDefaultModel(self: SettingsManager) ?[]const u8 {
        return self.settings.default_model;
    }
};

pub fn deepMergeSettings(base: Settings, overrides: Settings) Settings {
    var result = base;
    if (overrides.default_provider) |value| result.default_provider = value;
    if (overrides.default_model) |value| result.default_model = value;
    if (overrides.default_thinking_level) |value| result.default_thinking_level = value;
    if (overrides.theme) |value| result.theme = value;
    if (overrides.compaction.enabled != null) result.compaction.enabled = overrides.compaction.enabled;
    if (overrides.compaction.reserve_tokens != null) result.compaction.reserve_tokens = overrides.compaction.reserve_tokens;
    if (overrides.compaction.keep_recent_tokens != null) result.compaction.keep_recent_tokens = overrides.compaction.keep_recent_tokens;
    if (overrides.retry.enabled != null) result.retry.enabled = overrides.retry.enabled;
    if (overrides.retry.max_retries != null) result.retry.max_retries = overrides.retry.max_retries;
    if (overrides.retry.base_delay_ms != null) result.retry.base_delay_ms = overrides.retry.base_delay_ms;
    result.enable_install_telemetry = overrides.enable_install_telemetry;
    return result;
}

test "settings manager reads telemetry flag" {
    const manager = SettingsManager.init(.{ .enable_install_telemetry = false });
    try std.testing.expect(!manager.getEnableInstallTelemetry());
}
