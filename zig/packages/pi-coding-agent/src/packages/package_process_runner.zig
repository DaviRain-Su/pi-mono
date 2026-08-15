const std = @import("std");
const common = @import("../tools/common.zig");
const package_sources = @import("package_sources.zig");

const PackageTool = enum { npm, git };

fn commandPrefix(options: anytype, kind: PackageTool) []const []const u8 {
    return switch (kind) {
        .npm => options.npm_command_override orelse &.{"npm"},
        .git => options.git_command_override orelse &.{"git"},
    };
}

pub fn runExternalCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
    stderr: *std.Io.Writer,
) !bool {
    var argv = try allocator.alloc([]const u8, prefix.len + args.len);
    defer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);

    var display: std.ArrayList(u8) = .empty;
    defer display.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try display.append(allocator, ' ');
        try display.appendSlice(allocator, arg);
    }

    const result = (if (cwd) |path|
        std.process.run(allocator, io, .{
            .argv = argv,
            .cwd = .{ .path = path },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        })
    else
        std.process.run(allocator, io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        })) catch |err| {
        try stderr.print("Error: Failed to run {s}: {s}\n", .{ display.items, @errorName(err) });
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return true;
            try stderr.print("Error: {s} exited with code {d}\n", .{ display.items, code });
            if (result.stderr.len > 0) try stderr.print("{s}", .{result.stderr});
            return false;
        },
        .signal => |signal| {
            try stderr.print("Error: {s} terminated by signal {d}\n", .{ display.items, signal });
            return false;
        },
        else => {
            try stderr.print("Error: {s} terminated abnormally\n", .{display.items});
            return false;
        },
    }
}

fn ensureNpmProject(allocator: std.mem.Allocator, io: std.Io, install_root: []const u8) !void {
    try std.Io.Dir.createDirPath(.cwd(), io, install_root);

    const gitignore_path = try std.fs.path.join(allocator, &.{ install_root, ".gitignore" });
    defer allocator.free(gitignore_path);
    const gitignore_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, gitignore_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!gitignore_exists) try common.writeFileAbsolute(io, gitignore_path, "*\n!.gitignore\n", true);

    const package_json_path = try std.fs.path.join(allocator, &.{ install_root, "package.json" });
    defer allocator.free(package_json_path);
    const package_json_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, package_json_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!package_json_exists) try common.writeFileAbsolute(io, package_json_path, "{\n  \"name\": \"pi-extensions\",\n  \"private\": true\n}\n", true);
}

pub fn executeNpmInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: anytype,
    stderr: *std.Io.Writer,
) !bool {
    const spec = std.mem.trim(u8, source["npm:".len..], " ");
    const prefix = commandPrefix(options, .npm);
    const install_root = try package_sources.npmInstallRoot(allocator, options, is_project);
    defer allocator.free(install_root);
    try ensureNpmProject(allocator, io, install_root);
    return runExternalCommand(allocator, io, prefix, &.{ "install", spec, "--prefix", install_root }, null, stderr);
}

pub fn executeNpmUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: anytype,
    stderr: *std.Io.Writer,
) !bool {
    const spec = std.mem.trim(u8, source["npm:".len..], " ");
    const pkg_name = package_sources.npmPackageName(spec);
    const latest_spec = try std.fmt.allocPrint(allocator, "{s}@latest", .{pkg_name});
    defer allocator.free(latest_spec);
    const prefix = commandPrefix(options, .npm);
    const install_root = try package_sources.npmInstallRoot(allocator, options, is_project);
    defer allocator.free(install_root);
    try ensureNpmProject(allocator, io, install_root);
    return runExternalCommand(allocator, io, prefix, &.{ "install", latest_spec, "--prefix", install_root }, null, stderr);
}

pub fn executeGitInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: anytype,
    stderr: *std.Io.Writer,
) !bool {
    var info = (try package_sources.parseGitSource(allocator, source)) orelse {
        try stderr.print("Error: Unsupported git source: {s}\n", .{source});
        return false;
    };
    defer info.deinit(allocator);

    const target_dir = try package_sources.gitInstallPath(allocator, options, source, is_project);
    defer allocator.free(target_dir);
    const target_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, target_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (target_exists) return true;

    const root = try package_sources.gitInstallRoot(allocator, options, is_project);
    defer allocator.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);
    const gitignore_path = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    defer allocator.free(gitignore_path);
    const gitignore_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, gitignore_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!gitignore_exists) try common.writeFileAbsolute(io, gitignore_path, "*\n!.gitignore\n", true);

    const parent = std.fs.path.dirname(target_dir) orelse root;
    try std.Io.Dir.createDirPath(.cwd(), io, parent);
    const prefix = commandPrefix(options, .git);
    if (!try runExternalCommand(allocator, io, prefix, &.{ "clone", info.repo, target_dir }, null, stderr)) return false;
    if (info.ref) |ref| {
        if (!try runExternalCommand(allocator, io, prefix, &.{ "checkout", ref }, target_dir, stderr)) return false;
    }
    return true;
}

pub fn executeGitUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: anytype,
    stderr: *std.Io.Writer,
) !bool {
    var info = (try package_sources.parseGitSource(allocator, source)) orelse return true;
    defer info.deinit(allocator);
    if (info.ref != null) return true;

    const target_dir = try package_sources.gitInstallPath(allocator, options, source, is_project);
    defer allocator.free(target_dir);
    const target_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, target_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (!target_exists) return executeGitInstall(allocator, io, source, is_project, options, stderr);

    const prefix = commandPrefix(options, .git);
    return runExternalCommand(allocator, io, prefix, &.{ "pull", "--ff-only" }, target_dir, stderr);
}
