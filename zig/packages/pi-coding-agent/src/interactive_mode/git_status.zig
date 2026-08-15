const std = @import("std");

pub fn resolveGitBranch(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    const repo_root = try findGitRoot(allocator, io, cwd) orelse return null;
    defer allocator.free(repo_root);

    const git_path = try std.fs.path.join(allocator, &[_][]const u8{ repo_root, ".git" });
    defer allocator.free(git_path);

    const git_dir = try resolveGitDirectory(allocator, io, repo_root, git_path) orelse return null;
    defer allocator.free(git_dir);

    const head_path = try std.fs.path.join(allocator, &[_][]const u8{ git_dir, "HEAD" });
    defer allocator.free(head_path);

    const head = std.Io.Dir.readFileAlloc(.cwd(), io, head_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(head);

    return parseGitHeadBranch(allocator, head);
}

pub fn findGitRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const git_path = try std.fs.path.join(allocator, &[_][]const u8{ current, ".git" });
        defer allocator.free(git_path);

        const stat = std.Io.Dir.statFile(.cwd(), io, git_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat != null) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }

        const owned_parent = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned_parent;
    }
}

pub fn resolveGitDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    git_path: []const u8,
) !?[]u8 {
    const stat = std.Io.Dir.statFile(.cwd(), io, git_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    if (stat.kind == .directory) return try allocator.dupe(u8, git_path);
    if (stat.kind != .file) return null;

    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, git_path, allocator, .limited(4096));
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const gitdir = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (std.fs.path.isAbsolute(gitdir)) return try allocator.dupe(u8, gitdir);
    return try std.fs.path.resolve(allocator, &[_][]const u8{ repo_root, gitdir });
}

pub fn parseGitHeadBranch(allocator: std.mem.Allocator, head_contents: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, head_contents, " \t\r\n");
    const prefix = "ref:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const ref_name = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref_name, heads_prefix)) {
        return try allocator.dupe(u8, ref_name[heads_prefix.len..]);
    }
    return try allocator.dupe(u8, std.fs.path.basename(ref_name));
}
