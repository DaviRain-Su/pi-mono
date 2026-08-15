const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const args_parser = @import("args_parser.zig");
const mutation_queue = @import("file_mutation_queue.zig");

const makeAbsoluteTestPath = common.makeAbsoluteTestPath;
const jsonObject = common.jsonObject;

pub const WriteArgs = struct {
    path: []const u8,
    content: []const u8,

    pub const json_field_docs = .{
        .path = "Path to the file to write (absolute or relative to cwd)",
        .content = "Content to write to the file",
    };
};

pub const WriteExecutionResult = struct {
    content: []const ai.ContentBlock,
    is_error: bool = false,

    pub fn deinit(self: *WriteExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        self.* = undefined;
    }
};

pub const WriteTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "write";
    pub const description =
        "Write content to a file. Creates the file if it does not exist, overwrites it if it does, " ++
        "and automatically creates parent directories.";

    pub fn init(cwd: []const u8, io: std.Io) WriteTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        return common.schemaFromArgs(WriteArgs, allocator);
    }

    pub fn execute(
        self: WriteTool,
        allocator: std.mem.Allocator,
        args: WriteArgs,
    ) !WriteExecutionResult {
        const absolute_path = try common.resolvePath(allocator, self.cwd, args.path);
        defer allocator.free(absolute_path);

        var mutation_guard = try mutation_queue.acquire(self.io, allocator, absolute_path);
        defer mutation_guard.release();

        common.writeFileAbsolute(self.io, absolute_path, args.content, true) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Failed to write {s}: {s}", .{ args.path, @errorName(err) });
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };

        const message = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ args.content.len, args.path });
        defer allocator.free(message);
        return .{
            .content = try common.makeTextContent(allocator, message),
        };
    }
};

pub fn parseArguments(args: std.json.Value) !WriteArgs {
    return args_parser.parseArgsFromJson(WriteArgs, std.heap.page_allocator, args);
}

const QueuedWriteThreadContext = struct {
    path: []const u8,
    content: []const u8,
    success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *QueuedWriteThreadContext) void {
        var result = WriteTool.init(".", std.testing.io).execute(std.heap.page_allocator, .{
            .path = self.path,
            .content = self.content,
        }) catch unreachable;
        defer result.deinit(std.heap.page_allocator);
        self.success.store(!result.is_error, .seq_cst);
    }
};

test "write tool creates a new file with the requested content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "nested",
        "created.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try WriteTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .content = "hello from write",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Successfully wrote"));

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("hello from write", written);
}

test "write tool overwrites an existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "existing.txt",
        .data = "before",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "existing.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try WriteTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .content = "after",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("after", written);
}

test "write tool waits for an earlier queued mutation before replacing the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "queued.txt",
        .data = "before",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "queued.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var held_guard = try mutation_queue.acquire(std.testing.io, std.testing.allocator, absolute_path);

    var context = QueuedWriteThreadContext{
        .path = absolute_path,
        .content = "after",
    };
    const thread = try std.Thread.spawn(.{}, QueuedWriteThreadContext.run, .{&context});

    try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);

    const before_release = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before_release);
    try std.testing.expectEqualStrings("before", before_release);

    held_guard.release();

    thread.join();

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(context.success.load(.seq_cst));
    try std.testing.expectEqualStrings("after", written);
}

test "write tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "write tool auto-creates nested parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "a",
        "b",
        "c",
        "deep.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    const tool = WriteTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .content = "deeply nested",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);

    const read_back = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, relative_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualStrings("deeply nested", read_back);
}

test "write tool overwrites existing content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "overwrite.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    const tool = WriteTool.init(cwd, std.testing.io);

    // Write initial content
    var result1 = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .content = "initial",
    });
    result1.deinit(std.testing.allocator);

    // Overwrite
    var result2 = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .content = "replaced",
    });
    result2.deinit(std.testing.allocator);

    const read_back = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, relative_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualStrings("replaced", read_back);
}

test "write tool handles empty content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "empty.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    const tool = WriteTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .content = "",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);

    const read_back = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, relative_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualStrings("", read_back);
}
