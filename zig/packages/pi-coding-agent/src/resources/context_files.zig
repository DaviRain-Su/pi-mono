const std = @import("std");

pub const ContextFile = struct {
    path: []const u8,
    content: []const u8,

    pub fn deinit(self: *ContextFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        self.* = undefined;
    }
};

const CONTEXT_FILENAMES = [_][]const u8{
    "AGENTS.md",
    "CLAUDE.md",
    "SYSTEM.md",
};

pub fn loadContextFiles(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]ContextFile {
    const project_root = try findProjectRoot(allocator, io, cwd);
    defer allocator.free(project_root);

    var files = std.ArrayList(ContextFile).empty;
    errdefer {
        for (files.items) |*file| file.deinit(allocator);
        files.deinit(allocator);
    }

    if (try loadContextFileFromDir(allocator, io, project_root)) |context_file| {
        try files.append(allocator, context_file);
    }

    if (!std.mem.eql(u8, project_root, cwd)) {
        if (try loadContextFileFromDir(allocator, io, cwd)) |context_file| {
            try files.append(allocator, context_file);
        }
    }

    return try files.toOwnedSlice(allocator);
}

pub fn deinitContextFiles(allocator: std.mem.Allocator, files: []ContextFile) void {
    for (files) |*file| file.deinit(allocator);
    allocator.free(files);
}

fn loadContextFileFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) !?ContextFile {
    for (CONTEXT_FILENAMES) |filename| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, filename });
        errdefer allocator.free(file_path);

        const content = try readOptionalFile(allocator, io, file_path);
        if (content) |bytes| {
            return .{
                .path = file_path,
                .content = bytes,
            };
        }

        allocator.free(file_path);
    }

    return null;
}

fn findProjectRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        if (try hasGitDirectory(allocator, io, current)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse return current;
        if (std.mem.eql(u8, parent, current)) {
            return current;
        }

        const owned_parent = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned_parent;
    }
}

fn hasGitDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !bool {
    const git_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, ".git" });
    defer allocator.free(git_path);

    _ = std.Io.Dir.statFile(.cwd(), io, git_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}

fn readOptionalFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, name });
    defer allocator.free(relative_path);
    return makeAbsoluteTestPath(allocator, relative_path);
}

test "loadContextFiles merges project root and cwd in order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/packages/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/CLAUDE.md",
        .data = "root claude instructions",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/packages/app/AGENTS.md",
        .data = "cwd agents instructions",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo/packages/app");
    defer allocator.free(cwd);

    const files = try loadContextFiles(allocator, std.testing.io, cwd);
    defer deinitContextFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0].path, "/repo/CLAUDE.md"));
    try std.testing.expectEqualStrings("root claude instructions", files[0].content);
    try std.testing.expect(std.mem.endsWith(u8, files[1].path, "/repo/packages/app/AGENTS.md"));
    try std.testing.expectEqualStrings("cwd agents instructions", files[1].content);
}

test "loadContextFiles falls back to SYSTEM.md when preferred files are absent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src/feature");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/SYSTEM.md",
        .data = "root system fallback",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/src/feature/SYSTEM.md",
        .data = "cwd system fallback",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo/src/feature");
    defer allocator.free(cwd);

    const files = try loadContextFiles(allocator, std.testing.io, cwd);
    defer deinitContextFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0].path, "/repo/SYSTEM.md"));
    try std.testing.expectEqualStrings("root system fallback", files[0].content);
    try std.testing.expect(std.mem.endsWith(u8, files[1].path, "/repo/src/feature/SYSTEM.md"));
    try std.testing.expectEqualStrings("cwd system fallback", files[1].content);
}
