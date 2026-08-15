const std = @import("std");

pub const package_name = "@earendil-works/pi-coding-agent";

pub const SelfUpdatePackageManager = enum { npm, pnpm, yarn, bun };

pub const LatestSelfUpdateRelease = struct {
    version: []const u8,
    package_name: ?[]const u8 = null,
};

pub const ExecuteResult = struct {
    exit_code: u8,
};

pub const ExecuteOptions = struct {
    /// When non-null, used instead of detecting npm/bun for self-update.
    /// Slice of argv strings; the first element is the executable.
    /// Set to an empty slice to simulate "no package manager found".
    self_update_command_override: ?[]const []const u8 = null,
    /// Package manager semantics to apply to `self_update_command_override`.
    /// Tests use shell/true/false command prefixes while still exercising
    /// npm/pnpm/yarn/bun uninstall/install argument planning.
    self_update_method_override: SelfUpdatePackageManager = .npm,
    /// Deterministic latest-release metadata for self-update planning. When
    /// null, latest metadata is treated as unavailable and self-update runs
    /// with the current package name, matching the TS fallback path.
    self_update_latest_release_override: ?LatestSelfUpdateRelease = null,
    /// Optional probe incremented only when latest-release metadata is
    /// consulted. Used by focused tests to prove --force skips the fetch path.
    self_update_latest_release_probe: ?*usize = null,
    /// Current package version used for deterministic self-update planning.
    current_version: []const u8 = "0.1.0",
};

pub const ParsedPackageVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: ?[]const u8 = null,
};

pub fn parsePackageVersion(version: []const u8) ?ParsedPackageVersion {
    const trimmed = std.mem.trim(u8, version, " \t\r\n");
    const without_prefix = if (std.mem.startsWith(u8, trimmed, "v")) trimmed[1..] else trimmed;
    const build_index = std.mem.indexOfScalar(u8, without_prefix, '+') orelse without_prefix.len;
    const without_build = without_prefix[0..build_index];
    const prerelease_index = std.mem.indexOfScalar(u8, without_build, '-');
    const core = if (prerelease_index) |index| without_build[0..index] else without_build;
    const prerelease = if (prerelease_index) |index| without_build[index + 1 ..] else null;

    var parts = std.mem.splitScalar(u8, core, '.');
    const major_text = parts.next() orelse return null;
    const minor_text = parts.next() orelse return null;
    const patch_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (major_text.len == 0 or minor_text.len == 0 or patch_text.len == 0) return null;

    return .{
        .major = std.fmt.parseInt(u64, major_text, 10) catch return null,
        .minor = std.fmt.parseInt(u64, minor_text, 10) catch return null,
        .patch = std.fmt.parseInt(u64, patch_text, 10) catch return null,
        .prerelease = if (prerelease) |value| if (value.len == 0) null else value else null,
    };
}

pub fn comparePackageVersions(left_version: []const u8, right_version: []const u8) ?i8 {
    const left = parsePackageVersion(left_version) orelse return null;
    const right = parsePackageVersion(right_version) orelse return null;
    if (left.major != right.major) return if (left.major > right.major) 1 else -1;
    if (left.minor != right.minor) return if (left.minor > right.minor) 1 else -1;
    if (left.patch != right.patch) return if (left.patch > right.patch) 1 else -1;
    if (left.prerelease == null and right.prerelease == null) return 0;
    if (left.prerelease == null) return 1;
    if (right.prerelease == null) return -1;
    return switch (std.mem.order(u8, left.prerelease.?, right.prerelease.?)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn isNewerPackageVersion(candidate_version: []const u8, current_version: []const u8) bool {
    if (comparePackageVersions(candidate_version, current_version)) |comparison| {
        return comparison > 0;
    }
    return !std.mem.eql(
        u8,
        std.mem.trim(u8, candidate_version, " \t\r\n"),
        std.mem.trim(u8, current_version, " \t\r\n"),
    );
}

/// Detect whether npm or bun is available in PATH and return the update
/// command argv as a heap-allocated slice of heap-allocated strings.
/// Returns null when no supported package manager is found.
/// Caller owns all allocations.
pub fn detectSelfUpdateCommand(allocator: std.mem.Allocator, io: std.Io) !?[][]u8 {
    const candidates = [_]struct { pm: []const u8, install_args: []const []const u8 }{
        .{ .pm = "npm", .install_args = &.{ "npm", "install", "-g", package_name } },
        .{ .pm = "bun", .install_args = &.{ "bun", "install", "-g", package_name } },
    };
    for (candidates) |candidate| {
        const which_result = std.process.run(allocator, io, .{
            .argv = &.{ "which", candidate.pm },
            .stdout_limit = .limited(256),
            .stderr_limit = .limited(256),
        }) catch continue;
        defer allocator.free(which_result.stdout);
        defer allocator.free(which_result.stderr);
        const found = switch (which_result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (found) {
            const argv = try allocator.alloc([]u8, candidate.install_args.len);
            errdefer allocator.free(argv);
            var i: usize = 0;
            errdefer for (argv[0..i]) |arg| allocator.free(arg);
            for (candidate.install_args) |arg| {
                argv[i] = try allocator.dupe(u8, arg);
                i += 1;
            }
            return argv;
        }
    }
    return null;
}

pub const SelfUpdatePlan = struct {
    package_name: []const u8,
    should_run: bool,
};

pub const SelfUpdateCommandStep = struct {
    argv: []const []const u8,
    display: []u8,

    pub fn deinit(self: *SelfUpdateCommandStep, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        allocator.free(self.display);
        self.* = undefined;
    }
};

pub const SelfUpdateCommand = struct {
    steps: []SelfUpdateCommandStep,
    display: []u8,

    pub fn deinit(self: *SelfUpdateCommand, allocator: std.mem.Allocator) void {
        for (self.steps) |*step| step.deinit(allocator);
        allocator.free(self.steps);
        allocator.free(self.display);
        self.* = undefined;
    }
};

fn appendDisplayArg(allocator: std.mem.Allocator, output: *std.ArrayList(u8), arg: []const u8) !void {
    if (std.mem.indexOfAny(u8, arg, " \t\r\n") == null) {
        try output.appendSlice(allocator, arg);
        return;
    }
    try output.append(allocator, '"');
    try output.appendSlice(allocator, arg);
    try output.append(allocator, '"');
}

fn makeSelfUpdateCommandStep(
    allocator: std.mem.Allocator,
    prefix: []const []const u8,
    args: []const []const u8,
) !SelfUpdateCommandStep {
    var argv = try allocator.alloc([]const u8, prefix.len + args.len);
    errdefer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);

    var display_buf: std.ArrayList(u8) = .empty;
    errdefer display_buf.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try display_buf.append(allocator, ' ');
        try appendDisplayArg(allocator, &display_buf, arg);
    }

    return .{
        .argv = argv,
        .display = try display_buf.toOwnedSlice(allocator),
    };
}

fn appendSelfUpdateInstallStep(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(SelfUpdateCommandStep),
    method: SelfUpdatePackageManager,
    prefix: []const []const u8,
    update_package_name: []const u8,
) !void {
    const step = switch (method) {
        .npm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "install", "-g", update_package_name }),
        .pnpm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "install", "-g", update_package_name }),
        .yarn => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "global", "add", update_package_name }),
        .bun => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "install", "-g", update_package_name }),
    };
    try steps.append(allocator, step);
}

fn appendSelfUpdateUninstallStep(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(SelfUpdateCommandStep),
    method: SelfUpdatePackageManager,
    prefix: []const []const u8,
    installed_package_name: []const u8,
) !void {
    const step = switch (method) {
        .npm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "uninstall", "-g", installed_package_name }),
        .pnpm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "remove", "-g", installed_package_name }),
        .yarn => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "global", "remove", installed_package_name }),
        .bun => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "uninstall", "-g", installed_package_name }),
    };
    try steps.append(allocator, step);
}

pub fn makeSelfUpdateCommand(
    allocator: std.mem.Allocator,
    method: SelfUpdatePackageManager,
    prefix: []const []const u8,
    update_package_name: []const u8,
) !SelfUpdateCommand {
    var steps: std.ArrayList(SelfUpdateCommandStep) = .empty;
    errdefer {
        for (steps.items) |*step| step.deinit(allocator);
        steps.deinit(allocator);
    }

    if (!std.mem.eql(u8, update_package_name, package_name)) {
        try appendSelfUpdateUninstallStep(allocator, &steps, method, prefix, package_name);
    }
    try appendSelfUpdateInstallStep(allocator, &steps, method, prefix, update_package_name);

    const owned_steps = try steps.toOwnedSlice(allocator);
    errdefer {
        for (owned_steps) |*step| step.deinit(allocator);
        allocator.free(owned_steps);
    }

    var display_buf: std.ArrayList(u8) = .empty;
    errdefer display_buf.deinit(allocator);
    for (owned_steps, 0..) |step, index| {
        if (index > 0) try display_buf.appendSlice(allocator, " && ");
        try display_buf.appendSlice(allocator, step.display);
    }

    return .{
        .steps = owned_steps,
        .display = try display_buf.toOwnedSlice(allocator),
    };
}

pub fn getSelfUpdatePlan(force: bool, options: ExecuteOptions) SelfUpdatePlan {
    if (force) {
        return .{ .package_name = package_name, .should_run = true };
    }

    if (options.self_update_latest_release_probe) |probe| {
        probe.* += 1;
    }

    const release = options.self_update_latest_release_override orelse
        return .{ .package_name = package_name, .should_run = true };
    const release_package_name = if (release.package_name) |name| blk: {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else package_name;
    } else package_name;

    if (!std.mem.eql(u8, release_package_name, package_name) or
        isNewerPackageVersion(release.version, options.current_version))
    {
        return .{ .package_name = release_package_name, .should_run = true };
    }

    return .{ .package_name = package_name, .should_run = false };
}

pub fn executeSelfUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    force: bool,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    // Resolve argv: use test override when present. Without an override,
    // native Zig builds cannot safely prove the executable is managed by a
    // writable global package manager the way the TypeScript Node entrypoint
    // can, so surface the same user-facing unsupported diagnostic instead of
    // running an unsafe global install command.
    const command_prefix: []const []const u8 = if (options.self_update_command_override) |override| blk: {
        if (override.len == 0) {
            // Empty override means "no package manager found".
            try stderr.print(
                "error: pi cannot self-update this installation.\nRun: npm install -g {s}\n",
                .{package_name},
            );
            return .{ .exit_code = 1 };
        }
        break :blk override;
    } else {
        try stderr.print(
            "error: pi cannot self-update this installation.\nUpdate {s} using the package manager, wrapper, or source checkout that provides this installation.\n",
            .{package_name},
        );
        return .{ .exit_code = 1 };
    };

    const plan = getSelfUpdatePlan(force, options);
    if (!plan.should_run) {
        try stdout.print("pi is already up to date (v{s})\n", .{options.current_version});
        return .{ .exit_code = 0 };
    }

    var command = try makeSelfUpdateCommand(
        allocator,
        options.self_update_method_override,
        command_prefix,
        plan.package_name,
    );
    defer command.deinit(allocator);

    // Spawn the update command and collect output.
    for (command.steps) |step| {
        const result = std.process.run(allocator, io, .{
            .argv = step.argv,
        }) catch |err| {
            try stderr.print(
                "Error: Failed to spawn update command: {s}\nIf this keeps failing, run this command yourself: {s}\n",
                .{ @errorName(err), command.display },
            );
            return .{ .exit_code = 1 };
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    try stderr.print(
                        "Error: {s} exited with {d}\nIf this keeps failing, run this command yourself: {s}\n",
                        .{ step.display, code, command.display },
                    );
                    return .{ .exit_code = 1 };
                }
            },
            .signal => |sig| {
                try stderr.print(
                    "Error: {s} terminated by signal {d}\nIf this keeps failing, run this command yourself: {s}\n",
                    .{ step.display, sig, command.display },
                );
                return .{ .exit_code = 1 };
            },
            else => {
                try stderr.print(
                    "Error: {s} terminated abnormally\nIf this keeps failing, run this command yourself: {s}\n",
                    .{ step.display, command.display },
                );
                return .{ .exit_code = 1 };
            },
        }
    }

    try stdout.print("Updated pi\n", .{});
    return .{ .exit_code = 0 };
}
