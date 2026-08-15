const std = @import("std");
const common = @import("../tools/common.zig");
const file_helpers = @import("../resources/file_helpers.zig");

pub const DefaultProjectTrust = enum {
    ask,
    always,
    never,

    pub fn parse(value: []const u8) ?DefaultProjectTrust {
        if (std.mem.eql(u8, value, "ask")) return .ask;
        if (std.mem.eql(u8, value, "always")) return .always;
        if (std.mem.eql(u8, value, "never")) return .never;
        return null;
    }
};

pub const ProjectTrustDecision = enum {
    trusted,
    untrusted,
};

pub const ProjectTrustStoreEntry = struct {
    path: []const u8,
    trusted: bool,
};

pub const ProjectTrustUpdate = struct {
    path: []const u8,
    decision: ?bool,
};

pub const ResolveProjectTrustedOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    override: ?bool = null,
    default_project_trust: DefaultProjectTrust = .ask,
    has_ui: bool = false,
};

const TRUST_REQUIRING_PROJECT_CONFIG_RESOURCES = [_][]const u8{
    "settings.json",
    "extensions",
    "skills",
    "prompts",
    "themes",
    "SYSTEM.md",
    "APPEND_SYSTEM.md",
};

pub fn normalizeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{cwd});
}

pub fn getProjectTrustParentPath(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const trust_path = try normalizeCwd(allocator, cwd);
    errdefer allocator.free(trust_path);
    const parent_dir = std.fs.path.dirname(trust_path) orelse {
        allocator.free(trust_path);
        return null;
    };
    if (std.mem.eql(u8, parent_dir, trust_path)) {
        allocator.free(trust_path);
        return null;
    }
    const owned_parent = try allocator.dupe(u8, parent_dir);
    allocator.free(trust_path);
    return owned_parent;
}

pub fn hasTrustRequiringProjectResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !bool {
    const home_dir = if (env_map.get("HOME")) |home|
        try normalizeCwd(allocator, home)
    else
        null;
    defer if (home_dir) |home| allocator.free(home);
    const user_agents_skills_dir = if (home_dir) |home|
        try std.fs.path.join(allocator, &.{ home, ".agents", "skills" })
    else
        null;
    defer if (user_agents_skills_dir) |path| allocator.free(path);

    var current_dir = try normalizeCwd(allocator, cwd);
    defer allocator.free(current_dir);

    const config_dir = try std.fs.path.join(allocator, &.{ current_dir, ".pi" });
    defer allocator.free(config_dir);
    for (TRUST_REQUIRING_PROJECT_CONFIG_RESOURCES) |entry| {
        const path = try std.fs.path.join(allocator, &.{ config_dir, entry });
        defer allocator.free(path);
        if (file_helpers.pathExists(io, path)) return true;
    }

    while (true) {
        const agents_skills_dir = try std.fs.path.join(allocator, &.{ current_dir, ".agents", "skills" });
        defer allocator.free(agents_skills_dir);
        const is_user_dir = if (user_agents_skills_dir) |user_dir|
            std.mem.eql(u8, agents_skills_dir, user_dir)
        else
            false;
        if (!is_user_dir and file_helpers.pathExists(io, agents_skills_dir)) return true;
        if (home_dir) |home| {
            if (std.mem.eql(u8, current_dir, home)) return false;
        }

        const parent_dir = std.fs.path.dirname(current_dir) orelse return false;
        if (std.mem.eql(u8, parent_dir, current_dir)) return false;
        const next_dir = try allocator.dupe(u8, parent_dir);
        allocator.free(current_dir);
        current_dir = next_dir;
    }
}

pub fn peekDefaultProjectTrust(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
) DefaultProjectTrust {
    const settings_path = std.fs.path.join(allocator, &.{ agent_dir, "settings.json" }) catch return .ask;
    defer allocator.free(settings_path);
    const content = file_helpers.readOptionalFile(allocator, io, settings_path) catch return .ask;
    const settings_content = content orelse return .ask;
    defer allocator.free(settings_content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_content, .{}) catch return .ask;
    defer parsed.deinit();
    if (parsed.value != .object) return .ask;
    const value = parsed.value.object.get("defaultProjectTrust") orelse return .ask;
    if (value != .string) return .ask;
    return DefaultProjectTrust.parse(value.string) orelse .ask;
}

pub fn resolveProjectTrusted(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: ResolveProjectTrustedOptions,
) !bool {
    if (options.override) |value| return value;
    if (!try hasTrustRequiringProjectResources(allocator, io, env_map, options.cwd)) return true;

    var store = ProjectTrustStore.init(allocator, io, options.agent_dir);
    if (try store.get(options.cwd)) |decision| return decision;

    return switch (options.default_project_trust) {
        .always => true,
        .never => false,
        .ask => if (options.has_ui) false else false,
    };
}

pub const ProjectTrustStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, agent_dir: []const u8) ProjectTrustStore {
        return .{
            .allocator = allocator,
            .io = io,
            .agent_dir = agent_dir,
        };
    }

    pub fn trustPath(self: ProjectTrustStore) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.agent_dir, "trust.json" });
    }

    pub fn get(self: ProjectTrustStore, cwd: []const u8) !?bool {
        const path = try self.trustPath();
        defer self.allocator.free(path);
        var data = try readTrustFile(self.allocator, self.io, path);
        defer data.deinit();
        const normalized = try normalizeCwd(self.allocator, cwd);
        defer self.allocator.free(normalized);
        if (findNearestTrustEntry(data.map, normalized)) |entry| return entry.trusted;
        return null;
    }

    pub fn set(self: ProjectTrustStore, cwd: []const u8, decision: ?bool) !void {
        try self.setMany(&.{.{ .path = cwd, .decision = decision }});
    }

    pub fn setMany(self: ProjectTrustStore, updates: []const ProjectTrustUpdate) !void {
        const path = try self.trustPath();
        defer self.allocator.free(path);
        var data = try readTrustFile(self.allocator, self.io, path);
        defer data.deinit();

        for (updates) |update| {
            const key = try normalizeCwd(self.allocator, update.path);
            defer self.allocator.free(key);
            if (update.decision) |decision| {
                if (data.map.getPtr(key)) |existing| {
                    existing.* = decision;
                } else {
                    try data.map.put(try self.allocator.dupe(u8, key), decision);
                }
            } else if (data.map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }

        try writeTrustFile(self.allocator, self.io, path, data.map);
    }
};

const TrustFile = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(bool),

    fn deinit(self: *TrustFile) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
        self.* = undefined;
    }
};

fn findNearestTrustEntry(data: std.StringHashMap(bool), cwd: []const u8) ?ProjectTrustStoreEntry {
    var current_dir = cwd;
    while (true) {
        if (data.get(current_dir)) |decision| {
            return .{ .path = current_dir, .trusted = decision };
        }
        const parent_dir = std.fs.path.dirname(current_dir) orelse return null;
        if (std.mem.eql(u8, parent_dir, current_dir)) return null;
        current_dir = parent_dir;
    }
}

fn readTrustFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !TrustFile {
    var map = std.StringHashMap(bool).init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        map.deinit();
    }

    const content = file_helpers.readOptionalFile(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = allocator, .map = map },
        else => return err,
    };
    const file_content = content orelse return .{ .allocator = allocator, .map = map };
    defer allocator.free(file_content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, file_content, .{}) catch return error.InvalidTrustStore;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTrustStore;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const decision = switch (entry.value_ptr.*) {
            .bool => |value| value,
            .null => continue,
            else => return error.InvalidTrustStore,
        };
        try map.put(try allocator.dupe(u8, entry.key_ptr.*), decision);
    }
    return .{ .allocator = allocator, .map = map };
}

fn writeTrustFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    data: std.StringHashMap(bool),
) !void {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var it = data.iterator();
    while (it.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    for (keys.items) |key| {
        try common.putBool(allocator, &object, key, data.get(key).?);
    }

    const json_value = std.json.Value{ .object = object };
    defer common.deinitJsonValue(allocator, json_value);
    const serialized = try std.json.Stringify.valueAlloc(allocator, json_value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, path, serialized, true);
}

test "ProjectTrustStore stores decisions and inherits from parent directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "trusted-parent/project");

    const agent_dir = try makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const parent_dir = try makeTmpPath(allocator, tmp, "trusted-parent");
    defer allocator.free(parent_dir);
    const child_dir = try makeTmpPath(allocator, tmp, "trusted-parent/project");
    defer allocator.free(child_dir);

    const store = ProjectTrustStore.init(allocator, std.testing.io, agent_dir);
    try std.testing.expect(try store.get(child_dir) == null);
    try store.set(parent_dir, true);
    try std.testing.expectEqual(true, (try store.get(child_dir)).?);
    try store.set(child_dir, false);
    try std.testing.expectEqual(false, (try store.get(child_dir)).?);
    try store.set(child_dir, null);
    try std.testing.expectEqual(true, (try store.get(child_dir)).?);
}

test "hasTrustRequiringProjectResources detects project settings and agent skills" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pi/agent");
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const home_dir = try makeTmpPath(allocator, tmp, ".");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    try std.testing.expect(!try hasTrustRequiringProjectResources(allocator, std.testing.io, &env_map, home_dir));
    try std.testing.expect(!try hasTrustRequiringProjectResources(allocator, std.testing.io, &env_map, project_dir));

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".pi/settings.json",
        .data = "{}",
    });
    try std.testing.expect(try hasTrustRequiringProjectResources(allocator, std.testing.io, &env_map, home_dir));

    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data = "{}",
    });
    try std.testing.expect(try hasTrustRequiringProjectResources(allocator, std.testing.io, &env_map, project_dir));
}

test "resolveProjectTrusted honors override store and defaultProjectTrust" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data = "{}",
    });

    const agent_dir = try makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try std.testing.expect(try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .override = true,
        .default_project_trust = .never,
    }));
    try std.testing.expect(!try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .override = false,
        .default_project_trust = .always,
    }));
    try std.testing.expect(!try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .ask,
    }));
    try std.testing.expect(try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .always,
    }));

    const store = ProjectTrustStore.init(allocator, std.testing.io, agent_dir);
    try store.set(project_dir, true);
    try std.testing.expect(try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .never,
    }));
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const relative_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
    defer allocator.free(relative_path);
    return std.fs.path.resolve(allocator, &.{ cwd, relative_path });
}
