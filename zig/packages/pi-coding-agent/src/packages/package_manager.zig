const std = @import("std");
const common = @import("../tools/common.zig");
const package_command_parser = @import("package_command_parser.zig");
const package_process_runner = @import("package_process_runner.zig");
const package_settings_store = @import("package_settings_store.zig");
const package_sources = @import("package_sources.zig");
const self_update = @import("self_update.zig");

/// TypeScript/process extension package manager.
///
/// Zig no longer owns wasm/native extension runtimes, trust locks, or policy
/// manifests. The package manager remains because TypeScript extensions still
/// need the original pi package workflow: install a local/npm/git package,
/// persist it in settings, list configured packages, remove entries, and refresh
/// npm/git installs. Package contents are loaded later by the resource resolver.
pub const PackageCommand = package_command_parser.PackageCommand;
pub const ConfigKind = package_settings_store.ConfigKind;
const collectScopePackages = package_settings_store.collectScopePackages;
const computeInstalledPath = package_sources.computeInstalledPath;
const ensurePackagesArray = package_settings_store.ensurePackagesArray;
const executeGitInstall = package_process_runner.executeGitInstall;
const executeGitUpdate = package_process_runner.executeGitUpdate;
const executeNpmInstall = package_process_runner.executeNpmInstall;
const executeNpmUpdate = package_process_runner.executeNpmUpdate;
const findPackageIndex = package_settings_store.findPackageIndex;
const isGitSource = package_sources.isGitSource;
const isLocalSource = package_sources.isLocalSource;
const isNpmSource = package_sources.isNpmSource;
const loadSettingsObject = package_settings_store.loadSettingsObject;
const normalizePackageSourceForSettings = package_sources.normalizePackageSourceForSettings;
const npmPackageName = package_sources.npmPackageName;
const packageSourcesMatchForScope = package_sources.packageSourcesMatchForScope;
const packageSourceFromItem = package_settings_store.packageSourceFromItem;
const parseGitSource = package_sources.parseGitSource;
const settingsPathForScope = package_settings_store.settingsPathForScope;

pub const ConfigToggleAction = package_command_parser.ConfigToggleAction;
pub const ConfigOptions = package_command_parser.ConfigOptions;
pub const UpdateTarget = package_command_parser.UpdateTarget;
pub const ParsedCommand = package_command_parser.ParsedCommand;
pub const ParseError = package_command_parser.ParseError;
pub const isPackageCommand = package_command_parser.isPackageCommand;
pub const parsePackageCommand = package_command_parser.parsePackageCommand;
pub const packageCommandName = package_command_parser.packageCommandName;
pub const packageCommandUsage = package_command_parser.packageCommandUsage;

pub const ExecuteOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    npm_command_override: ?[]const []const u8 = null,
    git_command_override: ?[]const []const u8 = null,
    self_update_command_override: ?[]const []const u8 = null,
    self_update_method_override: SelfUpdatePackageManager = .npm,
    self_update_latest_release_override: ?LatestSelfUpdateRelease = null,
    self_update_latest_release_probe: ?*usize = null,
    current_version: []const u8 = "0.1.0",
    stdout_is_tty: bool = false,
    env_map: ?*const std.process.Environ.Map = null,
    fail_settings_write_for_testing: bool = false,
    fail_lockfile_write_for_testing: bool = false,
    fail_policy_write_for_testing: bool = false,
};

pub const SelfUpdatePackageManager = self_update.SelfUpdatePackageManager;
pub const LatestSelfUpdateRelease = self_update.LatestSelfUpdateRelease;
pub const ExecuteResult = self_update.ExecuteResult;

pub fn executePackageCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    if (command.help) {
        try writePackageCommandHelp(stdout, command.command);
        return .{ .exit_code = 0 };
    }

    if (command.parse_error) |message| {
        try stderr.print("Error: {s}\nUsage: {s}\n", .{ message, packageCommandUsage(command.command) });
        return .{ .exit_code = 1 };
    }

    return switch (command.command) {
        .install => executeInstall(allocator, io, command, options, stdout, stderr),
        .remove => executeRemove(allocator, io, command, options, stdout, stderr),
        .list => executeList(allocator, io, options, stdout),
        .config => executeConfig(allocator, io, command, options, stdout),
        .update => executeUpdate(allocator, io, command, options, stdout, stderr),
    };
}

fn executeInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    const source = command.source orelse unreachable;

    if (!isLocalSource(source)) {
        const installed = if (isNpmSource(source))
            try executeNpmInstall(allocator, io, source, command.local, options, stderr)
        else
            try executeGitInstall(allocator, io, source, command.local, options, stderr);
        if (!installed) return .{ .exit_code = 1 };
    }

    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const packages_array = try ensurePackagesArray(allocator, &settings_object);
    const existing_index = try findPackageIndex(allocator, packages_array.*, source, command.local, options);
    if (existing_index != null) {
        try stdout.print("Already installed: {s}\n", .{source});
        return .{ .exit_code = 0 };
    }

    const persisted_source = try normalizePackageSourceForSettings(allocator, source, command.local, options.cwd, options.agent_dir);
    errdefer allocator.free(persisted_source);
    try packages_array.append(.{ .string = persisted_source });
    try package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, settingsWriteOptions(options));
    try stdout.print("Installed {s}\n", .{source});
    return .{ .exit_code = 0 };
}

fn executeRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    const source = command.source orelse unreachable;
    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const packages_value = settings_object.getPtr("packages");
    if (packages_value == null or packages_value.?.* != .array) {
        try stderr.print("Error: No matching package found for {s}\n", .{source});
        return .{ .exit_code = 1 };
    }

    const matched_index = try findPackageIndex(allocator, packages_value.?.array, source, command.local, options) orelse {
        try stderr.print("Error: No matching package found for {s}\n", .{source});
        return .{ .exit_code = 1 };
    };

    const removed = packages_value.?.array.orderedRemove(matched_index);
    common.deinitJsonValue(allocator, removed);
    try package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, settingsWriteOptions(options));
    try stdout.print("Removed {s}\n", .{source});
    return .{ .exit_code = 0 };
}

fn executeUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    const target = command.update_target orelse .all;
    return switch (target) {
        .self => self_update.executeSelfUpdate(allocator, io, command.force, selfUpdateOptions(options), stdout, stderr),
        .all => blk: {
            const extensions_result = try executeExtensionUpdates(allocator, io, options, null, stderr);
            if (extensions_result.exit_code != 0) break :blk extensions_result;
            try stdout.writeAll("Updated packages\n");
            if (command.update_self) {
                break :blk try self_update.executeSelfUpdate(allocator, io, command.force, selfUpdateOptions(options), stdout, stderr);
            }
            break :blk ExecuteResult{ .exit_code = 0 };
        },
        .extensions => blk: {
            const extensions_result = try executeExtensionUpdates(allocator, io, options, null, stderr);
            if (extensions_result.exit_code != 0) break :blk extensions_result;
            try stdout.writeAll("Updated packages\n");
            break :blk ExecuteResult{ .exit_code = 0 };
        },
        .source => |source| blk: {
            const extensions_result = try executeExtensionUpdates(allocator, io, options, source, stderr);
            if (extensions_result.exit_code != 0) break :blk extensions_result;
            try stdout.print("Updated {s}\n", .{source});
            break :blk ExecuteResult{ .exit_code = 0 };
        },
    };
}

const UpdateSource = struct {
    source: []u8,
    is_project: bool,

    fn deinit(self: *UpdateSource, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }
};

fn freeUpdateSources(allocator: std.mem.Allocator, list: *std.ArrayList(UpdateSource)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
}

fn collectUpdateSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source_filter: ?[]const u8,
) !std.ArrayList(UpdateSource) {
    var result: std.ArrayList(UpdateSource) = .empty;
    errdefer freeUpdateSources(allocator, &result);

    inline for (.{ false, true }) |is_project| {
        var sources = try collectScopePackages(allocator, io, options, is_project);
        defer package_settings_store.freeOwnedStrings(allocator, &sources);
        for (sources.items) |entry| {
            if (source_filter) |filter| {
                if (!try packageSourcesMatchForScope(allocator, entry, filter, is_project, options)) continue;
            }
            try result.append(allocator, .{
                .source = try allocator.dupe(u8, entry),
                .is_project = is_project,
            });
        }
    }

    return result;
}

fn executeExtensionUpdates(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source_filter: ?[]const u8,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    var sources = try collectUpdateSources(allocator, io, options, source_filter);
    defer freeUpdateSources(allocator, &sources);

    if (source_filter) |source| {
        if (sources.items.len == 0) {
            if (try findSuggestedConfiguredSource(allocator, io, options, source)) |suggestion| {
                defer allocator.free(suggestion);
                try stderr.print("Error: No matching package found for {s}. Did you mean {s}?\n", .{ source, suggestion });
            } else {
                try stderr.print("Error: No matching package found for {s}\n", .{source});
            }
            return .{ .exit_code = 1 };
        }
    }

    for (sources.items) |entry| {
        const updated = if (isNpmSource(entry.source))
            try executeNpmUpdate(allocator, io, entry.source, entry.is_project, options, stderr)
        else if (isGitSource(entry.source))
            try executeGitUpdate(allocator, io, entry.source, entry.is_project, options, stderr)
        else
            true;
        if (!updated) return .{ .exit_code = 1 };
    }

    return .{ .exit_code = 0 };
}

fn findSuggestedConfiguredSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source: []const u8,
) !?[]u8 {
    var all_sources = try collectUpdateSources(allocator, io, options, null);
    defer freeUpdateSources(allocator, &all_sources);

    const trimmed = std.mem.trim(u8, source, " ");
    for (all_sources.items) |entry| {
        if (isNpmSource(entry.source)) {
            const spec = std.mem.trim(u8, entry.source["npm:".len..], " ");
            if (std.mem.eql(u8, trimmed, spec) or std.mem.eql(u8, trimmed, npmPackageName(spec))) {
                return try allocator.dupe(u8, entry.source);
            }
        } else if (isGitSource(entry.source)) {
            var info = (try parseGitSource(allocator, entry.source)) orelse continue;
            defer info.deinit(allocator);
            const shorthand = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ info.host, info.path });
            defer allocator.free(shorthand);
            if (std.mem.eql(u8, trimmed, shorthand)) return try allocator.dupe(u8, entry.source);
            if (info.ref) |ref| {
                const shorthand_with_ref = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ shorthand, ref });
                defer allocator.free(shorthand_with_ref);
                if (std.mem.eql(u8, trimmed, shorthand_with_ref)) return try allocator.dupe(u8, entry.source);
            }
        }
    }
    return null;
}

fn executeList(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
) !ExecuteResult {
    var user_entries = try collectListEntries(allocator, io, options, false);
    defer freeListEntries(allocator, &user_entries);
    var project_entries = try collectListEntries(allocator, io, options, true);
    defer freeListEntries(allocator, &project_entries);

    if (user_entries.items.len == 0 and project_entries.items.len == 0) {
        try stdout.writeAll("No packages installed.\n");
        return .{ .exit_code = 0 };
    }

    if (user_entries.items.len > 0) {
        try stdout.writeAll("User packages:\n");
        try writeListEntries(stdout, user_entries.items);
    }
    if (project_entries.items.len > 0) {
        if (user_entries.items.len > 0) try stdout.writeAll("\n");
        try stdout.writeAll("Project packages:\n");
        try writeListEntries(stdout, project_entries.items);
    }
    return .{ .exit_code = 0 };
}

const ListEntry = struct {
    source: []u8,
    installed_path: []u8,

    fn deinit(self: *ListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.installed_path);
        self.* = undefined;
    }
};

fn freeListEntries(allocator: std.mem.Allocator, list: *std.ArrayList(ListEntry)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
}

fn collectListEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    is_project: bool,
) !std.ArrayList(ListEntry) {
    var result: std.ArrayList(ListEntry) = .empty;
    errdefer freeListEntries(allocator, &result);

    const settings_path = try settingsPathForScope(allocator, options, is_project);
    defer allocator.free(settings_path);
    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const packages = settings_object.get("packages") orelse return result;
    if (packages != .array) return result;
    for (packages.array.items) |item| {
        const source = packageSourceFromItem(allocator, item) catch continue;
        errdefer allocator.free(source);
        const installed_path = try computeInstalledPath(allocator, source, is_project, options.cwd, options.agent_dir);
        errdefer allocator.free(installed_path);
        try result.append(allocator, .{ .source = source, .installed_path = installed_path });
    }
    return result;
}

fn writeListEntries(stdout: *std.Io.Writer, entries: []const ListEntry) !void {
    for (entries) |entry| {
        try stdout.print("  {s}\n    {s}\n", .{ entry.source, entry.installed_path });
    }
}

fn executeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
) !ExecuteResult {
    const config_options = command.config_options;
    const kind = config_options.toggle_kind orelse {
        try stdout.writeAll("Usage: pi config [--toggle <kind> <pattern> --enable|--disable] [-l]\n");
        return .{ .exit_code = 0 };
    };
    const pattern = config_options.toggle_pattern orelse {
        try stdout.writeAll("Usage: pi config [--toggle <kind> <pattern> --enable|--disable] [-l]\n");
        return .{ .exit_code = 0 };
    };

    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);
    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const enabled = config_options.toggle_action == .enable;
    try package_settings_store.setConfigKindPattern(allocator, &settings_object, kind, pattern, enabled);
    try package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, settingsWriteOptions(options));
    try stdout.print("{s} {s} for {s}\n", .{ if (enabled) "Enabled" else "Disabled", pattern, kind.settingsKey() });
    return .{ .exit_code = 0 };
}

fn settingsWriteOptions(options: ExecuteOptions) package_settings_store.WriteOptions {
    return .{ .fail_settings_write_for_testing = options.fail_settings_write_for_testing };
}

fn selfUpdateOptions(options: ExecuteOptions) self_update.ExecuteOptions {
    return .{
        .self_update_command_override = options.self_update_command_override,
        .self_update_method_override = options.self_update_method_override,
        .self_update_latest_release_override = options.self_update_latest_release_override,
        .self_update_latest_release_probe = options.self_update_latest_release_probe,
        .current_version = options.current_version,
    };
}

fn writePackageCommandHelp(stdout: *std.Io.Writer, command: PackageCommand) !void {
    switch (command) {
        .install => try stdout.writeAll(
            \\Usage:
            \\  pi install <source> [-l]
            \\
            \\Install a TypeScript extension package and add it to settings.
            \\
            \\Sources:
            \\  ./path               Local package directory
            \\  npm:<package[@ver]>  NPM package
            \\  git:<url>            Git repository
            \\
        ),
        .remove => try stdout.writeAll(
            \\Usage:
            \\  pi remove <source> [-l]
            \\
            \\Remove a configured TypeScript extension package from settings.
            \\
        ),
        .update => try stdout.writeAll(
            \\Usage:
            \\  pi update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]
            \\
            \\Refresh configured TypeScript extension packages. Local packages are already live.
            \\
        ),
        .list => try stdout.writeAll(
            \\Usage:
            \\  pi list
            \\
            \\List configured TypeScript extension packages.
            \\
        ),
        .config => try stdout.writeAll(
            \\Usage:
            \\  pi config [--toggle <kind> <pattern> --enable|--disable] [-l]
            \\
            \\Toggle package resource filters in settings.
            \\
        ),
    }
}
