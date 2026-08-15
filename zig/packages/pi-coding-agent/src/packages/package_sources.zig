const std = @import("std");

pub const LocalPathMode = enum { input, settings };

pub const GitSourceInfo = struct {
    repo: []u8,
    host: []u8,
    path: []u8,
    ref: ?[]u8 = null,

    pub fn deinit(self: *GitSourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.ref) |value| allocator.free(value);
        self.* = undefined;
    }
};

const GitRefSplit = struct {
    repo_part: []const u8,
    ref: ?[]const u8,
};

pub fn isNpmSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "npm:");
}

pub fn isGitSource(source: []const u8) bool {
    if (std.mem.startsWith(u8, source, "git:")) return true;
    if (std.mem.startsWith(u8, source, "https://")) return true;
    if (std.mem.startsWith(u8, source, "http://")) return true;
    if (std.mem.startsWith(u8, source, "ssh://")) return true;
    if (std.mem.startsWith(u8, source, "git://")) return true;
    return false;
}

pub fn isLocalSource(source: []const u8) bool {
    return !isNpmSource(source) and !isGitSource(source);
}

/// Strips the npm: prefix and version specifier to get the package name.
/// e.g. "npm:@scope/pkg@1.0.0" → "@scope/pkg", "npm:my-pkg" → "my-pkg"
pub fn npmPackageName(spec: []const u8) []const u8 {
    if (spec.len == 0) return spec;
    if (spec[0] == '@') {
        const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash_index| {
            if (at_index > slash_index) return spec[0..at_index];
        }
        return spec;
    }
    const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
    return spec[0..at_index];
}

/// Returns the normalized form of a git source for hashing.
pub fn normalizeGitSource(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "git:")) return source["git:".len..];
    return source;
}

fn trimGitSuffix(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".git")) return path[0 .. path.len - ".git".len];
    return path;
}

fn splitRef(source: []const u8) GitRefSplit {
    if (std.mem.startsWith(u8, source, "git@")) {
        const colon = std.mem.indexOfScalar(u8, source, ':') orelse return .{ .repo_part = source, .ref = null };
        const after_colon = source[colon + 1 ..];
        const at = std.mem.indexOfScalar(u8, after_colon, '@') orelse return .{ .repo_part = source, .ref = null };
        if (at == 0 or at + 1 >= after_colon.len) return .{ .repo_part = source, .ref = null };
        return .{
            .repo_part = source[0 .. colon + 1 + at],
            .ref = after_colon[at + 1 ..],
        };
    }

    if (std.mem.indexOf(u8, source, "://")) |_| {
        const scheme_end = std.mem.indexOf(u8, source, "://").? + "://".len;
        const path_start = std.mem.indexOfScalarPos(u8, source, scheme_end, '/') orelse return .{ .repo_part = source, .ref = null };
        const path = source[path_start + 1 ..];
        const at = std.mem.indexOfScalar(u8, path, '@') orelse return .{ .repo_part = source, .ref = null };
        if (at == 0 or at + 1 >= path.len) return .{ .repo_part = source, .ref = null };
        return .{
            .repo_part = source[0 .. path_start + 1 + at],
            .ref = path[at + 1 ..],
        };
    }

    const slash = std.mem.indexOfScalar(u8, source, '/') orelse return .{ .repo_part = source, .ref = null };
    const path = source[slash + 1 ..];
    const at = std.mem.indexOfScalar(u8, path, '@') orelse return .{ .repo_part = source, .ref = null };
    if (at == 0 or at + 1 >= path.len) return .{ .repo_part = source, .ref = null };
    return .{
        .repo_part = source[0 .. slash + 1 + at],
        .ref = path[at + 1 ..],
    };
}

pub fn parseGitSource(allocator: std.mem.Allocator, source: []const u8) !?GitSourceInfo {
    const without_prefix = if (std.mem.startsWith(u8, source, "git:")) source["git:".len..] else source;
    if (!std.mem.startsWith(u8, source, "git:") and
        !(std.mem.startsWith(u8, without_prefix, "https://") or
            std.mem.startsWith(u8, without_prefix, "http://") or
            std.mem.startsWith(u8, without_prefix, "ssh://") or
            std.mem.startsWith(u8, without_prefix, "git://")))
    {
        return null;
    }

    const split = splitRef(without_prefix);
    const repo_part = split.repo_part;
    const ref_owned = if (split.ref) |value| try allocator.dupe(u8, value) else null;
    errdefer if (ref_owned) |value| allocator.free(value);

    var repo_owned: []u8 = undefined;
    var host_slice: []const u8 = undefined;
    var path_slice: []const u8 = undefined;

    if (std.mem.startsWith(u8, repo_part, "git@")) {
        const colon = std.mem.indexOfScalar(u8, repo_part, ':') orelse return null;
        host_slice = repo_part["git@".len..colon];
        path_slice = repo_part[colon + 1 ..];
        repo_owned = try allocator.dupe(u8, repo_part);
    } else if (std.mem.indexOf(u8, repo_part, "://")) |_| {
        const scheme_end = std.mem.indexOf(u8, repo_part, "://").? + "://".len;
        const path_start = std.mem.indexOfScalarPos(u8, repo_part, scheme_end, '/') orelse return null;
        host_slice = repo_part[scheme_end..path_start];
        if (std.mem.indexOfScalar(u8, host_slice, '@')) |at| host_slice = host_slice[at + 1 ..];
        path_slice = repo_part[path_start + 1 ..];
        repo_owned = try allocator.dupe(u8, repo_part);
    } else {
        const slash = std.mem.indexOfScalar(u8, repo_part, '/') orelse return null;
        host_slice = repo_part[0..slash];
        path_slice = repo_part[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, host_slice, '.') == null and !std.mem.eql(u8, host_slice, "localhost")) return null;
        repo_owned = try std.fmt.allocPrint(allocator, "https://{s}", .{repo_part});
    }
    errdefer allocator.free(repo_owned);

    const normalized_path = trimGitSuffix(std.mem.trim(u8, path_slice, "/"));
    if (host_slice.len == 0 or normalized_path.len == 0 or std.mem.indexOfScalar(u8, normalized_path, '/') == null) return null;

    return .{
        .repo = repo_owned,
        .host = try allocator.dupe(u8, host_slice),
        .path = try allocator.dupe(u8, normalized_path),
        .ref = ref_owned,
    };
}

pub fn npmInstallRoot(allocator: std.mem.Allocator, options: anytype, is_project: bool) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &.{ options.cwd, ".pi", "packages", "npm" });
    return std.fs.path.join(allocator, &.{ options.agent_dir, "packages", "npm" });
}

pub fn gitInstallRoot(allocator: std.mem.Allocator, options: anytype, is_project: bool) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &.{ options.cwd, ".pi", "packages", "git" });
    return std.fs.path.join(allocator, &.{ options.agent_dir, "packages", "git" });
}

pub fn gitInstallPath(allocator: std.mem.Allocator, options: anytype, source: []const u8, is_project: bool) ![]u8 {
    const root = try gitInstallRoot(allocator, options, is_project);
    defer allocator.free(root);
    const normalized = std.mem.trim(u8, normalizeGitSource(source), " ");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
    defer allocator.free(hex);
    return std.fs.path.join(allocator, &.{ root, hex });
}

/// Computes the expected on-disk install path for a package source.
/// For local sources, resolves relative paths from cwd.
/// For npm sources, returns the node_modules directory path.
/// For git sources, returns a SHA256-derived directory path.
/// Caller owns the returned slice.
pub fn computeInstalledPath(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    if (isLocalSource(source)) {
        return resolveLocalPathFromScopeBase(allocator, source, is_project, cwd, agent_dir);
    }
    if (std.mem.startsWith(u8, source, "npm:")) {
        const spec = std.mem.trim(u8, source["npm:".len..], " ");
        const pkg_name = npmPackageName(spec);
        const base = if (is_project)
            try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "npm", "node_modules" })
        else
            try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "npm", "node_modules" });
        defer allocator.free(base);
        return std.fs.path.join(allocator, &[_][]const u8{ base, pkg_name });
    }
    if (try parseGitSource(allocator, source)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        const options = .{ .cwd = cwd, .agent_dir = agent_dir };
        return gitInstallPath(allocator, options, source, is_project);
    }
    return allocator.dupe(u8, source);
}

pub fn localBaseDirForScope(
    allocator: std.mem.Allocator,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" });
    return allocator.dupe(u8, agent_dir);
}

pub fn expandHomePath(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (input.len == 0 or input[0] != '~') return null;
    if (input.len > 1 and input[1] != '/') return null;
    const home_ptr = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_ptr);
    if (input.len == 1) return try allocator.dupe(u8, home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, input[2..] });
}

pub fn resolveLocalPathFromCwd(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    source: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (try expandHomePath(allocator, trimmed)) |expanded| return expanded;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, trimmed });
}

pub fn resolveLocalPathFromScopeBase(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (try expandHomePath(allocator, trimmed)) |expanded| return expanded;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    const base_dir = try localBaseDirForScope(allocator, is_project, cwd, agent_dir);
    defer allocator.free(base_dir);
    return std.fs.path.resolve(allocator, &[_][]const u8{ base_dir, trimmed });
}

pub fn normalizePackageSourceForSettings(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    if (!isLocalSource(source)) return allocator.dupe(u8, source);

    const base_dir = try localBaseDirForScope(allocator, is_project, cwd, agent_dir);
    defer allocator.free(base_dir);
    const resolved = try resolveLocalPathFromCwd(allocator, cwd, source);
    defer allocator.free(resolved);
    const relative = try std.fs.path.relative(allocator, cwd, null, base_dir, resolved);
    if (relative.len == 0) {
        allocator.free(relative);
        return allocator.dupe(u8, ".");
    }
    return relative;
}

pub fn packageSourcesMatchForScope(
    allocator: std.mem.Allocator,
    configured_source: []const u8,
    input_source: []const u8,
    is_project: bool,
    options: anytype,
) !bool {
    if (std.mem.eql(u8, configured_source, input_source)) return true;
    if (isLocalSource(configured_source) and isLocalSource(input_source)) {
        const configured_path = try resolveLocalPathFromScopeBase(
            allocator,
            configured_source,
            is_project,
            options.cwd,
            options.agent_dir,
        );
        defer allocator.free(configured_path);
        const input_path = try resolveLocalPathFromCwd(allocator, options.cwd, input_source);
        defer allocator.free(input_path);
        const configured_identity = try realpathOrResolved(allocator, configured_path);
        defer allocator.free(configured_identity);
        const input_identity = try realpathOrResolved(allocator, input_path);
        defer allocator.free(input_identity);
        return std.mem.eql(u8, configured_identity, input_identity);
    }
    return false;
}

pub fn realpathOrResolved(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch allocator.dupe(u8, path);
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return allocator.dupe(u8, path);
    return allocator.dupe(u8, std.mem.span(resolved));
}

pub fn localProvenanceKeyForSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    options: anytype,
    mode: LocalPathMode,
) ![]u8 {
    const resolved = switch (mode) {
        .input => try resolveLocalPathFromCwd(allocator, options.cwd, source),
        .settings => try resolveLocalPathFromScopeBase(allocator, source, is_project, options.cwd, options.agent_dir),
    };
    defer allocator.free(resolved);
    const identity = try realpathOrResolved(allocator, resolved);
    defer allocator.free(identity);
    return std.fmt.allocPrint(allocator, "local:{s}", .{identity});
}
