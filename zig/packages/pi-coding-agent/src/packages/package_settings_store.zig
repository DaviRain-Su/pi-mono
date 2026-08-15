const std = @import("std");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const package_sources = @import("package_sources.zig");

pub const ConfigKind = enum {
    extensions,
    skills,
    prompts,
    themes,

    pub fn fromString(value: []const u8) ?ConfigKind {
        if (std.mem.eql(u8, value, "extensions")) return .extensions;
        if (std.mem.eql(u8, value, "skills")) return .skills;
        if (std.mem.eql(u8, value, "prompts")) return .prompts;
        if (std.mem.eql(u8, value, "themes")) return .themes;
        return null;
    }

    pub fn settingsKey(self: ConfigKind) []const u8 {
        return switch (self) {
            .extensions => "extensions",
            .skills => "skills",
            .prompts => "prompts",
            .themes => "themes",
        };
    }
};

pub const WriteOptions = struct {
    fail_settings_write_for_testing: bool = false,
};

pub fn settingsPathForScope(
    allocator: std.mem.Allocator,
    options: anytype,
    local: bool,
) ![]u8 {
    if (local) {
        return std.fs.path.join(allocator, &[_][]const u8{ options.cwd, ".pi", "settings.json" });
    }
    return std.fs.path.join(allocator, &[_][]const u8{ options.agent_dir, "settings.json" });
}

pub fn loadSettingsObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
) !std.json.ObjectMap {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.ObjectMap.init(allocator, &.{}, &.{}),
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        // Treat malformed settings as empty to avoid wedging the CLI.
        return std.json.ObjectMap.init(allocator, &.{}, &.{});
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return std.json.ObjectMap.init(allocator, &.{}, &.{});
    }

    var clone = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup: std.json.Value = .{ .object = clone };
        common.deinitJsonValue(allocator, cleanup);
    }
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        try clone.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }
    return clone;
}

pub fn ensureKindArray(
    allocator: std.mem.Allocator,
    settings_object: *std.json.ObjectMap,
    kind: ConfigKind,
) !*std.json.Array {
    const key_str = kind.settingsKey();
    if (settings_object.getPtr(key_str)) |existing| {
        if (existing.* == .array) {
            return &existing.array;
        }
        const cleanup = existing.*;
        common.deinitJsonValue(allocator, cleanup);
        existing.* = .{ .array = std.json.Array.init(allocator) };
        return &existing.array;
    }
    const owned_key = try allocator.dupe(u8, key_str);
    errdefer allocator.free(owned_key);
    try settings_object.put(allocator, owned_key, .{ .array = std.json.Array.init(allocator) });
    return &settings_object.getPtr(key_str).?.array;
}

pub fn setConfigKindPattern(
    allocator: std.mem.Allocator,
    settings_object: *std.json.ObjectMap,
    kind: ConfigKind,
    pattern: []const u8,
    enabled: bool,
) !void {
    const array_ptr = try ensureKindArray(allocator, settings_object, kind);

    // Remove any previous +pattern/-pattern/!pattern/pattern entries
    // matching this exact pattern string. Mirrors the TS config selector
    // semantics where toggling replaces the previous decision.
    var idx: usize = 0;
    while (idx < array_ptr.items.len) {
        const item = array_ptr.items[idx];
        const matches = blk: {
            if (item != .string) break :blk false;
            const value = item.string;
            const stripped = if (value.len > 0 and (value[0] == '+' or value[0] == '-' or value[0] == '!'))
                value[1..]
            else
                value;
            break :blk std.mem.eql(u8, stripped, pattern);
        };
        if (matches) {
            const removed = array_ptr.orderedRemove(idx);
            common.deinitJsonValue(allocator, removed);
            continue;
        }
        idx += 1;
    }

    const prefix: u8 = if (enabled) '+' else '-';
    const new_entry = try std.fmt.allocPrint(allocator, "{c}{s}", .{ prefix, pattern });
    errdefer allocator.free(new_entry);
    try array_ptr.append(.{ .string = new_entry });
}

pub fn writeSettingsObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
    settings_object: std.json.ObjectMap,
    options: WriteOptions,
) !void {
    if (options.fail_settings_write_for_testing) return error.InjectedSettingsWriteFailure;
    try config_mod.validateExtensionPoliciesForSettingsWrite(allocator, settings_object, settings_path);
    const value: std.json.Value = .{ .object = settings_object };
    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

pub fn ensurePackagesArray(
    allocator: std.mem.Allocator,
    settings_object: *std.json.ObjectMap,
) !*std.json.Array {
    if (settings_object.getPtr("packages")) |existing| {
        if (existing.* == .array) {
            return &existing.array;
        }
        // Replace non-array `packages` with a fresh array; legacy
        // values are discarded silently, matching TS where an invalid
        // setting cannot prevent a fresh install.
        const cleanup = existing.*;
        common.deinitJsonValue(allocator, cleanup);
        existing.* = .{ .array = std.json.Array.init(allocator) };
        return &existing.array;
    }

    const key = try allocator.dupe(u8, "packages");
    errdefer allocator.free(key);
    try settings_object.put(allocator, key, .{ .array = std.json.Array.init(allocator) });
    return &settings_object.getPtr("packages").?.array;
}

pub fn findPackageIndex(
    allocator: std.mem.Allocator,
    array: std.json.Array,
    source: []const u8,
    is_project: bool,
    options: anytype,
) !?usize {
    for (array.items, 0..) |item, idx| {
        switch (item) {
            .string => |s| if (try package_sources.packageSourcesMatchForScope(allocator, s, source, is_project, options)) return idx,
            .object => |obj| {
                if (obj.get("source")) |value| {
                    if (value == .string) {
                        if (try package_sources.packageSourcesMatchForScope(allocator, value.string, source, is_project, options)) return idx;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn packageSourceFromItem(allocator: std.mem.Allocator, item: std.json.Value) ![]u8 {
    return switch (item) {
        .string => |source| allocator.dupe(u8, source),
        .object => |object| blk: {
            const value = object.get("source") orelse return error.InvalidPackageSource;
            if (value != .string) return error.InvalidPackageSource;
            break :blk allocator.dupe(u8, value.string);
        },
        else => error.InvalidPackageSource,
    };
}

pub fn collectScopePackages(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: anytype,
    local: bool,
) !std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStrings(allocator, &result);

    const settings_path = try settingsPathForScope(allocator, options, local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const cleanup: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, cleanup);
    }

    const packages_value = settings_object.get("packages") orelse return result;
    if (packages_value != .array) return result;

    for (packages_value.array.items) |item| {
        switch (item) {
            .string => |s| try result.append(allocator, try allocator.dupe(u8, s)),
            .object => |obj| {
                if (obj.get("source")) |value| {
                    if (value == .string) try result.append(allocator, try allocator.dupe(u8, value.string));
                }
            },
            else => {},
        }
    }
    return result;
}

pub fn freeOwnedStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |entry| allocator.free(entry);
    list.deinit(allocator);
}
