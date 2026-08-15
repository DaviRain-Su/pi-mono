const std = @import("std");

pub const Source = enum {
    settings,
    legacy_settings,
    models,
    register_provider,
    register_model,
    discovery,
    set_default_model,
    skill,
    prompt,
    theme,
};

pub const ConfigError = struct {
    source: Source,
    path: []u8,
    message: []u8,

    pub fn deinit(self: *ConfigError, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn sourceName(source: Source) []const u8 {
    return switch (source) {
        .settings => "settings",
        .legacy_settings => "legacy_settings",
        .models => "models",
        .register_provider => "register_provider",
        .register_model => "register_model",
        .discovery => "discovery",
        .set_default_model => "set_default_model",
        .skill => "skill",
        .prompt => "prompt",
        .theme => "theme",
    };
}

pub fn appendError(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(ConfigError),
    source: Source,
    path: []const u8,
    err: anyerror,
) !void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    try appendMessage(allocator, errors, source, path, @errorName(err));
}

pub fn appendMessage(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(ConfigError),
    source: Source,
    path: []const u8,
    message: []const u8,
) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try errors.append(allocator, .{
        .source = source,
        .path = owned_path,
        .message = owned_message,
    });
}

pub fn deinitSlice(allocator: std.mem.Allocator, errors: []ConfigError) void {
    for (errors) |*item| item.deinit(allocator);
    if (errors.len > 0) allocator.free(errors);
}

pub fn deinitList(allocator: std.mem.Allocator, errors: *std.ArrayList(ConfigError)) void {
    for (errors.items) |*item| item.deinit(allocator);
    errors.deinit(allocator);
}

test "ConfigError source enum covers route A M0 sources" {
    inline for (@typeInfo(Source).@"enum".fields) |field| {
        const source: Source = @enumFromInt(field.value);
        try std.testing.expect(sourceName(source).len > 0);
    }
}
