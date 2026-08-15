const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const args_parser = @import("args_parser.zig");
const truncate = @import("truncate.zig");

const makeAbsoluteTestPath = common.makeAbsoluteTestPath;
const jsonObject = common.jsonObject;

const DEFAULT_LIMIT: usize = 1000;

pub const FindArgs = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    limit: ?usize = null,

    pub const json_int_constraints = .{
        .limit = .positive,
    };

    pub const json_field_docs = .{
        .pattern = "Glob pattern such as '*.ts' or 'src/**/*.zig'",
        .path = "Directory to search (defaults to cwd)",
        .limit = "Maximum number of files to return",
    };
};

pub const FindDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    result_limit_reached: ?usize = null,

    pub fn deinit(self: *FindDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const FindExecutionResult = struct {
    content: []const ai.ContentBlock,
    details: ?FindDetails = null,
    is_error: bool = false,

    pub fn deinit(self: *FindExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub const FindTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "find";
    pub const description =
        "Find files recursively with fd. Supports glob patterns, respects ignore rules, " ++
        "and returns paths relative to the searched directory.";

    pub fn init(cwd: []const u8, io: std.Io) FindTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        return common.schemaFromArgs(FindArgs, allocator);
    }

    pub fn execute(
        self: FindTool,
        allocator: std.mem.Allocator,
        args: FindArgs,
    ) !FindExecutionResult {
        if (args.pattern.len == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "Pattern must not be empty"),
                .is_error = true,
            };
        }

        const effective_limit = args.limit orelse DEFAULT_LIMIT;
        if (effective_limit == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "Limit must be greater than or equal to 1"),
                .is_error = true,
            };
        }

        const absolute_path = try common.resolvePath(allocator, self.cwd, args.path orelse ".");
        defer allocator.free(absolute_path);

        const path_stat = std.Io.Dir.statFile(.cwd(), self.io, absolute_path, .{}) catch |err| {
            const message = switch (err) {
                error.FileNotFound => try std.fmt.allocPrint(allocator, "Path not found: {s}", .{absolute_path}),
                else => try std.fmt.allocPrint(allocator, "Failed to access {s}: {s}", .{ absolute_path, @errorName(err) }),
            };
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        if (path_stat.kind != .directory) {
            const message = try std.fmt.allocPrint(allocator, "Not a directory: {s}", .{absolute_path});
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        }

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        const limit_text = try std.fmt.allocPrint(allocator, "{d}", .{effective_limit});
        defer allocator.free(limit_text);

        try argv.append(allocator, "fd");
        try argv.append(allocator, "--type");
        try argv.append(allocator, "f");
        try argv.append(allocator, "--glob");
        try argv.append(allocator, "--color=never");
        try argv.append(allocator, "--hidden");
        try argv.append(allocator, "--no-require-git");
        try argv.append(allocator, "--max-results");
        try argv.append(allocator, limit_text);

        const effective_pattern = if (std.mem.indexOfScalar(u8, args.pattern, '/')) |_| blk: {
            try argv.append(allocator, "--full-path");
            if (!std.mem.startsWith(u8, args.pattern, "/") and !std.mem.startsWith(u8, args.pattern, "**/") and !std.mem.eql(u8, args.pattern, "**")) {
                break :blk try std.fmt.allocPrint(allocator, "**/{s}", .{args.pattern});
            }
            break :blk try allocator.dupe(u8, args.pattern);
        } else try allocator.dupe(u8, args.pattern);
        defer allocator.free(effective_pattern);

        try argv.append(allocator, effective_pattern);
        try argv.append(allocator, ".");

        const run_result = std.process.run(allocator, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = absolute_path },
        }) catch |err| {
            const message = switch (err) {
                error.FileNotFound => "fd is not available",
                else => try std.fmt.allocPrint(allocator, "Failed to run fd: {s}", .{@errorName(err)}),
            };
            defer if (err != error.FileNotFound) allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        defer allocator.free(run_result.stdout);
        defer allocator.free(run_result.stderr);

        const exit_code = exitCodeFromTerm(run_result.term);
        if (exit_code != 0 and run_result.stdout.len == 0) {
            const stderr = std.mem.trim(u8, run_result.stderr, " \r\n\t");
            if (stderr.len > 0) {
                const message = try std.fmt.allocPrint(allocator, "fd failed: {s}", .{stderr});
                defer allocator.free(message);
                return .{
                    .content = try common.makeTextContent(allocator, message),
                    .is_error = true,
                };
            }
        }

        var results = std.ArrayList([]const u8).empty;
        defer {
            for (results.items) |item| allocator.free(item);
            results.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, run_result.stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = trimResultPath(line);
            if (trimmed.len == 0) continue;
            try results.append(allocator, try allocator.dupe(u8, trimmed));
        }

        if (results.items.len == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "No files found matching pattern"),
            };
        }

        std.sort.insertion([]const u8, results.items, {}, lessThanIgnoreCase);

        const raw_output = try std.mem.join(allocator, "\n", results.items);
        defer allocator.free(raw_output);

        var truncation_result = try truncate.truncateHead(allocator, raw_output, .{
            .max_lines = effective_limit,
            .max_bytes = truncate.DEFAULT_MAX_BYTES,
        });
        errdefer truncation_result.deinit(allocator);

        const result_limit_reached = results.items.len >= effective_limit;
        const notice = try buildNotice(allocator, truncation_result.truncated, result_limit_reached, effective_limit);
        defer if (notice.len > 0) allocator.free(notice);

        const final_output = if (notice.len > 0)
            try std.mem.concat(allocator, u8, &[_][]const u8{ truncation_result.content, notice })
        else
            try allocator.dupe(u8, truncation_result.content);
        defer allocator.free(final_output);

        var details: ?FindDetails = null;
        if (truncation_result.truncated or result_limit_reached) {
            details = .{
                .truncation = if (truncation_result.truncated) truncation_result else null,
                .result_limit_reached = if (result_limit_reached) effective_limit else null,
            };
            if (!truncation_result.truncated) truncation_result.deinit(allocator);
        } else {
            truncation_result.deinit(allocator);
        }

        return .{
            .content = try common.makeTextContent(allocator, final_output),
            .details = details,
        };
    }
};

pub fn parseArguments(args: std.json.Value) !FindArgs {
    return args_parser.parseArgsFromJson(FindArgs, std.heap.page_allocator, args);
}

fn buildNotice(
    allocator: std.mem.Allocator,
    was_truncated: bool,
    result_limit_reached: bool,
    effective_limit: usize,
) ![]u8 {
    if (!was_truncated and !result_limit_reached) return allocator.dupe(u8, "");

    var notices = std.ArrayList([]const u8).empty;
    defer notices.deinit(allocator);

    if (result_limit_reached) {
        try notices.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{d} results limit reached. Use limit={d} for more",
            .{ effective_limit, effective_limit * 2 },
        ));
    }
    if (was_truncated) {
        try notices.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{d}KB output limit reached",
            .{truncate.DEFAULT_MAX_BYTES / 1024},
        ));
    }

    defer for (notices.items) |item| allocator.free(item);

    const joined = try std.mem.join(allocator, ". ", notices.items);
    defer allocator.free(joined);
    return try std.fmt.allocPrint(allocator, "\n\n[{s}]", .{joined});
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn lessThanIgnoreCase(_: void, lhs: []const u8, rhs: []const u8) bool {
    var index: usize = 0;
    while (index < lhs.len and index < rhs.len) : (index += 1) {
        const left = std.ascii.toLower(lhs[index]);
        const right = std.ascii.toLower(rhs[index]);
        if (left < right) return true;
        if (left > right) return false;
    }
    return lhs.len < rhs.len;
}

fn trimResultPath(line: []const u8) []const u8 {
    const without_newline = std.mem.trim(u8, line, "\r\n");
    return if (std.mem.startsWith(u8, without_newline, "./"))
        without_newline[2..]
    else
        without_newline;
}

test "find tool recursively finds matching files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "alpha.ts",
        .data = "export const alpha = true;\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nested/beta.ts",
        .data = "export const beta = true;\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nested/gamma.txt",
        .data = "ignore me\n",
    });

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(relative_dir);
    const absolute_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(absolute_dir);

    var result = try FindTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .pattern = "*.ts",
        .path = absolute_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "alpha.ts"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "nested/beta.ts"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "gamma.txt"));
}

test "find tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "find tool validates positive limits" {
    var object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "pattern"), .{
        .string = try std.testing.allocator.dupe(u8, "*.zig"),
    });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "limit"), .{ .integer = 0 });

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}
