const std = @import("std");

pub const GitSource = struct {
    repo: []u8,
    host: []u8,
    path: []u8,
    ref: ?[]u8 = null,
    pinned: bool = false,

    pub fn deinit(self: *GitSource, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.ref) |value| allocator.free(value);
        self.* = undefined;
    }
};

const SplitRef = struct {
    repo: []const u8,
    ref: ?[]const u8 = null,
};

const ParsedRepo = struct {
    repo: []const u8,
    host: []const u8,
    path: []const u8,
};

pub fn parseGitUrl(allocator: std.mem.Allocator, source: []const u8) !?GitSource {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const has_git_prefix = std.mem.startsWith(u8, trimmed, "git:");
    const url = if (has_git_prefix) std.mem.trim(u8, trimmed[4..], " \t\r\n") else trimmed;

    if (!has_git_prefix and !hasExplicitProtocol(url)) return null;

    const split = splitRef(url);
    if (try parseHostedAlias(allocator, split)) |hosted| return hosted;
    if (try parseKnownHostedUrl(allocator, split)) |hosted| return hosted;
    return parseGenericGitUrl(allocator, url);
}

fn splitRef(url: []const u8) SplitRef {
    if (std.mem.startsWith(u8, url, "git@")) {
        if (std.mem.indexOfScalar(u8, url, ':')) |colon_index| {
            const path_with_ref = url[colon_index + 1 ..];
            if (std.mem.indexOfScalar(u8, path_with_ref, '@')) |ref_index| {
                const repo_path = path_with_ref[0..ref_index];
                const ref = path_with_ref[ref_index + 1 ..];
                if (repo_path.len > 0 and ref.len > 0) {
                    return .{ .repo = url[0 .. colon_index + 1 + ref_index], .ref = ref };
                }
            }
        }
        return .{ .repo = url };
    }

    if (std.mem.indexOf(u8, url, "://") != null) {
        return splitProtocolRef(url);
    }

    const slash_index = std.mem.indexOfScalar(u8, url, '/') orelse return .{ .repo = url };
    const path_with_ref = url[slash_index + 1 ..];
    const ref_index = std.mem.indexOfScalar(u8, path_with_ref, '@') orelse return .{ .repo = url };
    const repo_path = path_with_ref[0..ref_index];
    const ref = path_with_ref[ref_index + 1 ..];
    if (repo_path.len == 0 or ref.len == 0) return .{ .repo = url };
    return .{ .repo = url[0 .. slash_index + 1 + ref_index], .ref = ref };
}

fn splitProtocolRef(url: []const u8) SplitRef {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return .{ .repo = url };
    const after_scheme = url[scheme_end + 3 ..];
    const slash_offset = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return .{ .repo = url };
    const path_start = scheme_end + 3 + slash_offset + 1;
    const path = url[path_start..];
    const ref_offset = std.mem.indexOfScalar(u8, path, '@') orelse return .{ .repo = url };
    const repo_path = path[0..ref_offset];
    const ref = path[ref_offset + 1 ..];
    if (repo_path.len == 0 or ref.len == 0) return .{ .repo = url };
    return .{ .repo = url[0 .. path_start + ref_offset], .ref = ref };
}

fn parseGenericGitUrl(allocator: std.mem.Allocator, url: []const u8) !?GitSource {
    const split = splitRef(url);
    const parsed = parseRepoParts(split.repo) orelse return null;
    return makeSource(allocator, parsed.repo, parsed.host, parsed.path, split.ref);
}

fn parseRepoParts(repo: []const u8) ?ParsedRepo {
    if (std.mem.startsWith(u8, repo, "git@")) {
        const colon_index = std.mem.indexOfScalar(u8, repo, ':') orelse return null;
        return .{
            .repo = repo,
            .host = repo[4..colon_index],
            .path = normalizePath(repo[colon_index + 1 ..]),
        };
    }

    if (hasExplicitProtocol(repo)) {
        const scheme_end = std.mem.indexOf(u8, repo, "://") orelse return null;
        const rest = repo[scheme_end + 3 ..];
        const slash_offset = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const authority = rest[0..slash_offset];
        const raw_path = rest[slash_offset + 1 ..];
        var host = authority;
        if (std.mem.lastIndexOfScalar(u8, host, '@')) |at_index| host = host[at_index + 1 ..];
        if (std.mem.indexOfScalar(u8, host, ':')) |port_index| host = host[0..port_index];
        return .{ .repo = repo, .host = host, .path = normalizePath(raw_path) };
    }

    const slash_index = std.mem.indexOfScalar(u8, repo, '/') orelse return null;
    const host = repo[0..slash_index];
    if (!std.mem.eql(u8, host, "localhost") and std.mem.indexOfScalar(u8, host, '.') == null) return null;
    return .{ .repo = repo, .host = host, .path = normalizePath(repo[slash_index + 1 ..]) };
}

fn parseHostedAlias(allocator: std.mem.Allocator, split: SplitRef) !?GitSource {
    const colon_index = std.mem.indexOfScalar(u8, split.repo, ':') orelse return null;
    if (std.mem.indexOf(u8, split.repo, "://") != null or std.mem.startsWith(u8, split.repo, "git@")) return null;

    const alias = split.repo[0..colon_index];
    const domain = hostedAliasDomain(alias) orelse return null;
    const path_ref = splitFragment(split.repo[colon_index + 1 ..]);
    const path = normalizePath(path_ref.repo);
    if (!isValidRepoPath(path)) return null;

    const repo = try std.fmt.allocPrint(allocator, "https://{s}", .{split.repo});
    errdefer allocator.free(repo);
    return try makeSourceOwnedRepo(allocator, repo, domain, path, split.ref orelse path_ref.ref);
}

fn parseKnownHostedUrl(allocator: std.mem.Allocator, split: SplitRef) !?GitSource {
    if (!hasExplicitProtocol(split.repo)) return null;
    const repo_ref = splitFragment(split.repo);
    const parsed = parseRepoParts(repo_ref.repo) orelse return null;
    if (!isKnownHostedDomain(parsed.host)) return null;
    return makeSource(allocator, split.repo, parsed.host, parsed.path, split.ref orelse repo_ref.ref);
}

fn hostedAliasDomain(alias: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, alias, "github")) return "github.com";
    if (std.mem.eql(u8, alias, "gitlab")) return "gitlab.com";
    if (std.mem.eql(u8, alias, "bitbucket")) return "bitbucket.org";
    return null;
}

fn isKnownHostedDomain(host: []const u8) bool {
    return std.mem.eql(u8, host, "github.com") or
        std.mem.eql(u8, host, "gitlab.com") or
        std.mem.eql(u8, host, "bitbucket.org");
}

fn splitFragment(value: []const u8) SplitRef {
    const fragment_index = std.mem.indexOfScalar(u8, value, '#') orelse return .{ .repo = value };
    const ref = value[fragment_index + 1 ..];
    if (ref.len == 0) return .{ .repo = value };
    return .{ .repo = value[0..fragment_index], .ref = ref };
}

fn makeSource(allocator: std.mem.Allocator, repo: []const u8, host: []const u8, path: []const u8, ref: ?[]const u8) !?GitSource {
    if (host.len == 0 or !isValidRepoPath(path)) return null;
    const repo_value = if (hasExplicitProtocol(repo) or std.mem.startsWith(u8, repo, "git@"))
        try allocator.dupe(u8, repo)
    else
        try std.fmt.allocPrint(allocator, "https://{s}", .{repo});
    errdefer allocator.free(repo_value);
    return try makeSourceOwnedRepo(allocator, repo_value, host, path, ref);
}

fn makeSourceOwnedRepo(allocator: std.mem.Allocator, repo: []u8, host: []const u8, path: []const u8, ref: ?[]const u8) !GitSource {
    errdefer allocator.free(repo);
    const host_value = try allocator.dupe(u8, host);
    errdefer allocator.free(host_value);
    const path_value = try allocator.dupe(u8, path);
    errdefer allocator.free(path_value);
    const ref_value = if (ref) |value| try allocator.dupe(u8, value) else null;
    errdefer if (ref_value) |value| allocator.free(value);

    return .{
        .repo = repo,
        .host = host_value,
        .path = path_value,
        .ref = ref_value,
        .pinned = ref != null,
    };
}

fn normalizePath(path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < path.len and path[start] == '/') : (start += 1) {}
    var out = path[start..];
    if (std.mem.endsWith(u8, out, ".git")) out = out[0 .. out.len - 4];
    return out;
}

fn isValidRepoPath(path: []const u8) bool {
    if (path.len == 0) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    const owner = parts.next() orelse return false;
    const project = parts.next() orelse return false;
    return owner.len > 0 and project.len > 0;
}

fn hasExplicitProtocol(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "ssh://") or
        std.mem.startsWith(u8, value, "git://");
}

test "parseGitUrl rejects shorthand without git prefix" {
    const parsed = try parseGitUrl(std.testing.allocator, "github.com/owner/repo");
    try std.testing.expectEqual(null, parsed);
}

test "parseGitUrl parses https with ref suffix" {
    var parsed = (try parseGitUrl(std.testing.allocator, "https://github.com/owner/repo@main")).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://github.com/owner/repo", parsed.repo);
    try std.testing.expectEqualStrings("github.com", parsed.host);
    try std.testing.expectEqualStrings("owner/repo", parsed.path);
    try std.testing.expectEqualStrings("main", parsed.ref.?);
    try std.testing.expect(parsed.pinned);
}

test "parseGitUrl parses scp-like refs" {
    var parsed = (try parseGitUrl(std.testing.allocator, "git:git@github.com:owner/repo.git@v1")).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("git@github.com:owner/repo.git", parsed.repo);
    try std.testing.expectEqualStrings("github.com", parsed.host);
    try std.testing.expectEqualStrings("owner/repo", parsed.path);
    try std.testing.expectEqualStrings("v1", parsed.ref.?);
}

test "parseGitUrl parses hosted aliases" {
    var parsed = (try parseGitUrl(std.testing.allocator, "git:github:owner/repo#main")).?;
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://github:owner/repo#main", parsed.repo);
    try std.testing.expectEqualStrings("github.com", parsed.host);
    try std.testing.expectEqualStrings("owner/repo", parsed.path);
    try std.testing.expectEqualStrings("main", parsed.ref.?);
    try std.testing.expect(parsed.pinned);
}
