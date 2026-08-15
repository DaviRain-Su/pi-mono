const std = @import("std");

pub fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

pub fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
    defer allocator.free(relative_dir);
    return try makeAbsoluteTestPath(allocator, relative_dir);
}

pub const CliExecutableResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *CliExecutableResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn hasAnsiEscape(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '\x1b') != null;
}

pub fn runCliExecutable(
    allocator: std.mem.Allocator,
    tmp: anytype,
    args: []const []const u8,
    env_entries: []const struct { []const u8, []const u8 },
) !CliExecutableResult {
    return runCliExecutableInner(allocator, tmp, args, null, env_entries);
}

pub fn runCliExecutableWithInput(
    allocator: std.mem.Allocator,
    tmp: anytype,
    args: []const []const u8,
    stdin_input: []const u8,
    env_entries: []const struct { []const u8, []const u8 },
) !CliExecutableResult {
    return runCliExecutableInner(allocator, tmp, args, stdin_input, env_entries);
}

fn runCliExecutableInner(
    allocator: std.mem.Allocator,
    tmp: anytype,
    args: []const []const u8,
    stdin_input: ?[]const u8,
    env_entries: []const struct { []const u8, []const u8 },
) !CliExecutableResult {
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const agent_dir = try makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const binary_path = try makeAbsoluteTestPath(allocator, "zig-out/bin/pi");
    defer allocator.free(binary_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, binary_path);
    try argv.appendSlice(allocator, args);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    for (env_entries) |entry| {
        try env_map.put(entry[0], entry[1]);
    }

    if (stdin_input) |input| {
        var child = try std.process.spawn(std.testing.io, .{
            .argv = argv.items,
            .cwd = .{ .path = project_dir },
            .environ_map = &env_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(std.testing.io);

        var stdin_file = child.stdin.?;
        child.stdin = null;
        try stdin_file.writeStreamingAll(std.testing.io, input);
        stdin_file.close(std.testing.io);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(allocator, std.testing.io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);
        while (multi_reader.fill(64, .none)) |_| {
            if (stdout_reader.buffered().len > 128 * 1024) return error.StreamTooLong;
            if (stderr_reader.buffered().len > 128 * 1024) return error.StreamTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        const term = try child.wait(std.testing.io);
        const stdout_slice = try multi_reader.toOwnedSlice(0);
        errdefer allocator.free(stdout_slice);
        const stderr_slice = try multi_reader.toOwnedSlice(1);
        errdefer allocator.free(stderr_slice);

        return .{
            .stdout = stdout_slice,
            .stderr = stderr_slice,
            .exit_code = exitCodeFromTerm(term),
        };
    }

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = &env_map,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exitCodeFromTerm(result.term),
    };
}

test "CLI executable harness maps non-exited terms to failure" {
    try std.testing.expectEqual(@as(u8, 7), exitCodeFromTerm(.{ .exited = 7 }));
    try std.testing.expectEqual(@as(u8, 1), exitCodeFromTerm(.{ .unknown = 9 }));
}
