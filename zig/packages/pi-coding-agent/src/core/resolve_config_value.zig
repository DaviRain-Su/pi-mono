const std = @import("std");

const CommandCache = std.StringHashMap(?[]u8);

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    command_cache: CommandCache,

    pub fn init(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) Resolver {
        return .{
            .allocator = allocator,
            .env_map = env_map,
            .command_cache = CommandCache.init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        var iter = self.command_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| self.allocator.free(value);
        }
        self.command_cache.deinit();
        self.* = undefined;
    }

    pub fn resolveConfigValue(self: *Resolver, config: []const u8) !?[]const u8 {
        if (std.mem.startsWith(u8, config, "!")) return self.executeCommand(config);
        return self.env_map.get(config) orelse config;
    }

    pub fn resolveConfigValueUncached(self: *Resolver, config: []const u8) !?[]u8 {
        if (std.mem.startsWith(u8, config, "!")) return executeCommandUncached(self.allocator, config[1..]);
        if (self.env_map.get(config)) |value| return self.allocator.dupe(u8, value);
        return self.allocator.dupe(u8, config);
    }

    pub fn resolveConfigValueOrThrow(self: *Resolver, config: []const u8, description: []const u8) ![]u8 {
        if (try self.resolveConfigValueUncached(config)) |value| return value;
        if (std.mem.startsWith(u8, config, "!")) return error.CommandResolutionFailed;
        _ = description;
        return error.ConfigResolutionFailed;
    }

    pub fn clearConfigValueCache(self: *Resolver) void {
        var iter = self.command_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| self.allocator.free(value);
        }
        self.command_cache.clearRetainingCapacity();
    }

    fn executeCommand(self: *Resolver, command_config: []const u8) !?[]const u8 {
        if (self.command_cache.get(command_config)) |cached| return cached;
        const owned_key = try self.allocator.dupe(u8, command_config);
        errdefer self.allocator.free(owned_key);
        const value = try executeCommandUncached(self.allocator, command_config[1..]);
        errdefer if (value) |owned| self.allocator.free(owned);
        try self.command_cache.put(owned_key, value);
        return value;
    }
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub fn resolveHeadersAlloc(allocator: std.mem.Allocator, resolver: *Resolver, headers: []const Header) ![]Header {
    var out = std.ArrayList(Header).empty;
    errdefer {
        for (out.items) |header| allocator.free(header.value);
        out.deinit(allocator);
    }
    for (headers) |header| {
        if (try resolver.resolveConfigValue(header.value)) |resolved| {
            if (resolved.len == 0) continue;
            try out.append(allocator, .{ .key = header.key, .value = try allocator.dupe(u8, resolved) });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn executeCommandUncached(allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.io(), .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(0),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return null;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

test "resolver prefers environment values and literals" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TOKEN_ENV", "secret");

    var resolver = Resolver.init(std.testing.allocator, &env);
    defer resolver.deinit();

    try std.testing.expectEqualStrings("secret", (try resolver.resolveConfigValue("TOKEN_ENV")).?);
    try std.testing.expectEqualStrings("literal", (try resolver.resolveConfigValue("literal")).?);
}
