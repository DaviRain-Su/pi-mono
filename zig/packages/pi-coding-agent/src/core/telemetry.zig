const std = @import("std");

pub fn isTruthyEnvFlag(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "yes");
}

pub const SettingsTelemetryProvider = struct {
    enable_install_telemetry: bool = false,

    pub fn getEnableInstallTelemetry(self: SettingsTelemetryProvider) bool {
        return self.enable_install_telemetry;
    }
};

pub fn isInstallTelemetryEnabled(settings: SettingsTelemetryProvider, telemetry_env: ?[]const u8) bool {
    if (telemetry_env != null) return isTruthyEnvFlag(telemetry_env);
    return settings.getEnableInstallTelemetry();
}

test "telemetry env flag overrides settings" {
    try std.testing.expect(isInstallTelemetryEnabled(.{}, "yes"));
    try std.testing.expect(!isInstallTelemetryEnabled(.{ .enable_install_telemetry = true }, "0"));
}
