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

pub const ProjectTrustOption = struct {
    label: []u8,
    trusted: bool,
    updates: []ProjectTrustUpdate,
    saved_path: ?[]u8,

    pub fn deinit(self: *ProjectTrustOption, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        for (self.updates) |update| allocator.free(update.path);
        allocator.free(self.updates);
        if (self.saved_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const OwnedTrustEntry = struct {
    path: []u8,
    trusted: bool,

    pub fn deinit(self: *OwnedTrustEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ExtensionTrustDecision = struct {
    trusted: bool,
    remember: bool = false,
};

pub const ExtensionTrustProbe = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, cwd: []const u8) anyerror!?ExtensionTrustDecision,
};

pub const ResolveProjectTrustedOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    override: ?bool = null,
    default_project_trust: DefaultProjectTrust = .ask,
    has_ui: bool = false,
    extension_probe: ?ExtensionTrustProbe = null,
};

pub const UNTRUSTED_PROJECT_WARNING =
    "This project is not trusted. Project .pi resources and packages are ignored. Use /trust to save a trust decision, then restart pi.";

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

pub fn formatProjectTrustPrompt(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Trust project folder?\n{s}\n\nThis allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.",
        .{cwd},
    );
}

pub fn formatSavedDecision(
    allocator: std.mem.Allocator,
    trust_path: []const u8,
    entry: ?OwnedTrustEntry,
) ![]u8 {
    const decision = entry orelse return allocator.dupe(u8, "Saved decision: none");
    const label: []const u8 = if (decision.trusted) "trusted" else "untrusted";
    if (!std.mem.eql(u8, decision.path, trust_path)) {
        return std.fmt.allocPrint(allocator, "Saved decision: {s} (inherited from {s})", .{ label, decision.path });
    }
    return std.fmt.allocPrint(allocator, "Saved decision: {s} ({s})", .{ label, decision.path });
}

pub fn isSavedTrustOption(option: ProjectTrustOption, entry: ?OwnedTrustEntry) bool {
    const saved = entry orelse return false;
    const saved_path = option.saved_path orelse return false;
    return saved.trusted == option.trusted and std.mem.eql(u8, saved.path, saved_path);
}

pub fn deinitProjectTrustOptions(allocator: std.mem.Allocator, options: []ProjectTrustOption) void {
    for (options) |*option| option.deinit(allocator);
    allocator.free(options);
}

pub fn getProjectTrustOptions(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    include_session_only: bool,
) ![]ProjectTrustOption {
    const trust_path = try normalizeCwd(allocator, cwd);
    defer allocator.free(trust_path);

    var list = std.ArrayList(ProjectTrustOption).empty;
    errdefer {
        for (list.items) |*option| option.deinit(allocator);
        list.deinit(allocator);
    }

    try list.append(allocator, try makeTrustOption(
        allocator,
        try allocator.dupe(u8, "Trust"),
        true,
        &.{.{ .path = trust_path, .decision = true }},
        trust_path,
    ));

    if (try getProjectTrustParentPath(allocator, cwd)) |parent_path| {
        defer allocator.free(parent_path);
        const label = try std.fmt.allocPrint(allocator, "Trust parent folder ({s})", .{parent_path});
        try list.append(allocator, try makeTrustOption(
            allocator,
            label,
            true,
            &.{
                .{ .path = parent_path, .decision = true },
                .{ .path = trust_path, .decision = null },
            },
            parent_path,
        ));
    }

    if (include_session_only) {
        try list.append(allocator, try makeTrustOption(
            allocator,
            try allocator.dupe(u8, "Trust (this session only)"),
            true,
            &.{},
            null,
        ));
    }

    try list.append(allocator, try makeTrustOption(
        allocator,
        try allocator.dupe(u8, "Do not trust"),
        false,
        &.{.{ .path = trust_path, .decision = false }},
        trust_path,
    ));

    if (include_session_only) {
        try list.append(allocator, try makeTrustOption(
            allocator,
            try allocator.dupe(u8, "Do not trust (this session only)"),
            false,
            &.{},
            null,
        ));
    }

    return list.toOwnedSlice(allocator);
}

fn makeTrustOption(
    allocator: std.mem.Allocator,
    label: []u8,
    trusted: bool,
    updates_in: []const ProjectTrustUpdate,
    saved_path: ?[]const u8,
) !ProjectTrustOption {
    errdefer allocator.free(label);

    const updates = try allocator.alloc(ProjectTrustUpdate, updates_in.len);
    errdefer allocator.free(updates);
    var made: usize = 0;
    errdefer {
        for (updates[0..made]) |update| allocator.free(update.path);
    }
    for (updates_in, 0..) |update, index| {
        updates[index] = .{
            .path = try allocator.dupe(u8, update.path),
            .decision = update.decision,
        };
        made += 1;
    }

    const owned_saved = if (saved_path) |path| try allocator.dupe(u8, path) else null;
    return .{
        .label = label,
        .trusted = trusted,
        .updates = updates,
        .saved_path = owned_saved,
    };
}

pub fn needsProjectTrustPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: ResolveProjectTrustedOptions,
) !bool {
    if (options.override != null) return false;
    if (!try hasTrustRequiringProjectResources(allocator, io, env_map, options.cwd)) return false;
    const store = ProjectTrustStore.init(allocator, io, options.agent_dir);
    if (try store.get(options.cwd) != null) return false;
    return options.default_project_trust == .ask;
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

    if (options.extension_probe) |probe| {
        if (try probe.func(probe.ctx, options.cwd)) |decision| {
            if (decision.remember) {
                const store = ProjectTrustStore.init(allocator, io, options.agent_dir);
                try store.set(options.cwd, decision.trusted);
            }
            return decision.trusted;
        }
    }

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
        var entry = try self.getEntry(cwd) orelse return null;
        defer entry.deinit(self.allocator);
        return entry.trusted;
    }

    pub fn getEntry(self: ProjectTrustStore, cwd: []const u8) !?OwnedTrustEntry {
        const path = try self.trustPath();
        defer self.allocator.free(path);
        var data = try readTrustFile(self.allocator, self.io, path);
        defer data.deinit();
        const normalized = try normalizeCwd(self.allocator, cwd);
        defer self.allocator.free(normalized);
        if (findNearestTrustEntry(data.map, normalized)) |entry| {
            return .{
                .path = try self.allocator.dupe(u8, entry.path),
                .trusted = entry.trusted,
            };
        }
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

fn extensionTrustYes(_: ?*anyopaque, _: []const u8) !?ExtensionTrustDecision {
    return .{ .trusted = true, .remember = true };
}

fn extensionTrustSkip(_: ?*anyopaque, _: []const u8) !?ExtensionTrustDecision {
    return null;
}

test "resolveProjectTrusted honors extension probe before the trust store" {
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

    const store = ProjectTrustStore.init(allocator, std.testing.io, agent_dir);
    try store.set(project_dir, false);

    try std.testing.expect(try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .never,
        .extension_probe = .{ .func = extensionTrustYes },
    }));
    try std.testing.expectEqual(true, (try store.get(project_dir)).?);

    try store.set(project_dir, false);
    try std.testing.expect(!try resolveProjectTrusted(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .always,
        .extension_probe = .{ .func = extensionTrustSkip },
    }));
}

test "getProjectTrustOptions includes parent and session-only choices" {
    const allocator = std.testing.allocator;
    const options = try getProjectTrustOptions(allocator, "/parent/project", true);
    defer deinitProjectTrustOptions(allocator, options);

    try std.testing.expectEqual(@as(usize, 5), options.len);
    try std.testing.expectEqualStrings("Trust", options[0].label);
    try std.testing.expect(options[0].trusted);
    try std.testing.expectEqual(@as(usize, 1), options[0].updates.len);
    try std.testing.expectEqual(true, options[0].updates[0].decision.?);

    try std.testing.expect(std.mem.startsWith(u8, options[1].label, "Trust parent folder ("));
    try std.testing.expect(options[1].trusted);
    try std.testing.expectEqual(@as(usize, 2), options[1].updates.len);
    try std.testing.expectEqual(true, options[1].updates[0].decision.?);
    try std.testing.expect(options[1].updates[1].decision == null);

    try std.testing.expectEqualStrings("Trust (this session only)", options[2].label);
    try std.testing.expect(options[2].trusted);
    try std.testing.expectEqual(@as(usize, 0), options[2].updates.len);
    try std.testing.expect(options[2].saved_path == null);

    try std.testing.expectEqualStrings("Do not trust", options[3].label);
    try std.testing.expect(!options[3].trusted);
    try std.testing.expectEqualStrings("Do not trust (this session only)", options[4].label);
    try std.testing.expect(!options[4].trusted);
    try std.testing.expectEqual(@as(usize, 0), options[4].updates.len);
}

test "getProjectTrustOptions omits session-only choices by default" {
    const allocator = std.testing.allocator;
    const options = try getProjectTrustOptions(allocator, "/parent/project", false);
    defer deinitProjectTrustOptions(allocator, options);
    try std.testing.expectEqual(@as(usize, 3), options.len);
    try std.testing.expectEqualStrings("Trust", options[0].label);
    try std.testing.expect(std.mem.startsWith(u8, options[1].label, "Trust parent folder ("));
    try std.testing.expectEqualStrings("Do not trust", options[2].label);
}

test "formatSavedDecision labels inherited ancestor decisions" {
    const allocator = std.testing.allocator;
    const none = try formatSavedDecision(allocator, "/parent/project", null);
    defer allocator.free(none);
    try std.testing.expectEqualStrings("Saved decision: none", none);

    var inherited = OwnedTrustEntry{
        .path = try allocator.dupe(u8, "/parent"),
        .trusted = true,
    };
    defer inherited.deinit(allocator);
    const inherited_text = try formatSavedDecision(allocator, "/parent/project", inherited);
    defer allocator.free(inherited_text);
    try std.testing.expectEqualStrings("Saved decision: trusted (inherited from /parent)", inherited_text);

    var local = OwnedTrustEntry{
        .path = try allocator.dupe(u8, "/parent/project"),
        .trusted = false,
    };
    defer local.deinit(allocator);
    const local_text = try formatSavedDecision(allocator, "/parent/project", local);
    defer allocator.free(local_text);
    try std.testing.expectEqualStrings("Saved decision: untrusted (/parent/project)", local_text);
}

test "needsProjectTrustPrompt is true only for ask with resources and no store entry" {
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

    try std.testing.expect(try needsProjectTrustPrompt(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .ask,
    }));
    try std.testing.expect(!try needsProjectTrustPrompt(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .override = true,
        .default_project_trust = .ask,
    }));
    try std.testing.expect(!try needsProjectTrustPrompt(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .always,
    }));

    const store = ProjectTrustStore.init(allocator, std.testing.io, agent_dir);
    try store.set(project_dir, false);
    try std.testing.expect(!try needsProjectTrustPrompt(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .default_project_trust = .ask,
    }));
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const relative_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
    defer allocator.free(relative_path);
    return std.fs.path.resolve(allocator, &.{ cwd, relative_path });
}
