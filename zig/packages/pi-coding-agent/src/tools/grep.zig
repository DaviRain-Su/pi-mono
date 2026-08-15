const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const args_parser = @import("args_parser.zig");
const truncate = @import("truncate.zig");

const makeAbsoluteTestPath = common.makeAbsoluteTestPath;
const jsonObject = common.jsonObject;

const DEFAULT_LIMIT: usize = 100;

pub const GrepArgs = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
    ignore_case: bool = false,
    literal: bool = false,
    context: usize = 0,
    limit: ?usize = null,

    pub const json_aliases = .{
        .glob = .{ "glob", "glob_pattern" },
        .ignore_case = .{ "ignoreCase", "ignore_case" },
    };

    pub const json_int_constraints = .{
        .limit = .positive,
    };

    pub const json_schema_names = .{
        .ignore_case = "ignoreCase",
    };

    pub const json_field_docs = .{
        .pattern = "Search pattern (regex or literal string)",
        .path = "File or directory to search (defaults to cwd)",
        .glob = "Optional glob filter such as '*.ts' or 'src/**/*.zig'",
        .ignore_case = "Case-insensitive search",
        .literal = "Treat pattern as a literal string instead of a regex",
        .context = "Number of context lines to include before and after each match",
        .limit = "Maximum number of matches to return",
    };
};

pub const GrepDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    match_limit_reached: ?usize = null,

    pub fn deinit(self: *GrepDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const GrepExecutionResult = struct {
    content: []const ai.ContentBlock,
    details: ?GrepDetails = null,
    is_error: bool = false,

    pub fn deinit(self: *GrepExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub const GrepTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "grep";
    pub const description =
        "Search file contents with ripgrep. Returns matching lines with file paths and line numbers, " ++
        "supports optional glob filters, literal mode, case-insensitive mode, and context lines.";

    pub fn init(cwd: []const u8, io: std.Io) GrepTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        return common.schemaFromArgs(GrepArgs, allocator);
    }

    pub fn execute(
        self: GrepTool,
        allocator: std.mem.Allocator,
        args: GrepArgs,
    ) !GrepExecutionResult {
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

        const process_cwd = if (path_stat.kind == .directory)
            absolute_path
        else
            std.fs.path.dirname(absolute_path) orelse ".";
        const target = if (path_stat.kind == .directory)
            "."
        else
            std.fs.path.basename(absolute_path);

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, "rg");
        try argv.append(allocator, "--json");
        try argv.append(allocator, "--line-number");
        try argv.append(allocator, "--color=never");
        try argv.append(allocator, "--hidden");
        if (args.ignore_case) try argv.append(allocator, "--ignore-case");
        if (args.literal) try argv.append(allocator, "--fixed-strings");
        if (args.glob) |glob| {
            try argv.append(allocator, "--glob");
            try argv.append(allocator, glob);
        }
        try argv.append(allocator, args.pattern);
        try argv.append(allocator, target);

        const run_result = std.process.run(allocator, self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = process_cwd },
        }) catch |err| {
            const message = switch (err) {
                error.FileNotFound => "ripgrep (rg) is not available",
                else => try std.fmt.allocPrint(allocator, "Failed to run ripgrep: {s}", .{@errorName(err)}),
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
        if (exit_code != 0 and exit_code != 1) {
            const stderr = std.mem.trim(u8, run_result.stderr, " \r\n\t");
            const message = if (stderr.len > 0)
                try std.fmt.allocPrint(allocator, "ripgrep failed: {s}", .{stderr})
            else
                try std.fmt.allocPrint(allocator, "ripgrep exited with code {d}", .{exit_code});
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        }

        var matches = std.ArrayList(Match).empty;
        defer deinitMatches(allocator, &matches);

        var lines = std.mem.splitScalar(u8, run_result.stdout, '\n');
        var match_limit_reached = false;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (matches.items.len >= effective_limit) {
                match_limit_reached = true;
                break;
            }

            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            const value = parsed.value;
            if (value != .object) continue;
            const event_type = getStringField(value.object, "type") orelse continue;
            if (!std.mem.eql(u8, event_type, "match")) continue;

            const data = value.object.get("data") orelse continue;
            if (data != .object) continue;

            const path_value = data.object.get("path") orelse continue;
            if (path_value != .object) continue;
            const relative_path = getStringField(path_value.object, "text") orelse continue;

            const line_number_value = data.object.get("line_number") orelse continue;
            const line_number = switch (line_number_value) {
                .integer => |integer| if (integer > 0) @as(usize, @intCast(integer)) else continue,
                else => continue,
            };

            var match_line: []const u8 = "";
            if (data.object.get("lines")) |lines_value| {
                if (lines_value == .object) {
                    match_line = getStringField(lines_value.object, "text") orelse "";
                }
            }

            try matches.append(allocator, .{
                .path = try allocator.dupe(u8, relative_path),
                .line_number = line_number,
                .line_text = try allocator.dupe(u8, trimLineEnding(match_line)),
            });
        }

        if (matches.items.len == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "No matches found"),
            };
        }

        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        for (matches.items) |match| {
            if (args.context == 0) {
                try appendOutputLine(
                    allocator,
                    &output,
                    try std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ match.path, match.line_number, match.line_text }),
                );
            } else {
                try appendContextBlock(allocator, self.io, &output, process_cwd, match, args.context);
            }
        }

        const raw_output = try output.toOwnedSlice(allocator);
        defer allocator.free(raw_output);

        var truncation_result = try truncate.truncateHead(allocator, raw_output, .{
            .max_lines = truncate.DEFAULT_MAX_LINES,
            .max_bytes = truncate.DEFAULT_MAX_BYTES,
        });
        errdefer truncation_result.deinit(allocator);

        const notice = try buildNotice(allocator, truncation_result.truncated, match_limit_reached, effective_limit);
        defer if (notice.len > 0) allocator.free(notice);

        const final_output = if (notice.len > 0)
            try std.mem.concat(allocator, u8, &[_][]const u8{ truncation_result.content, notice })
        else
            try allocator.dupe(u8, truncation_result.content);
        defer allocator.free(final_output);

        var details: ?GrepDetails = null;
        if (truncation_result.truncated or match_limit_reached) {
            details = .{
                .truncation = if (truncation_result.truncated) truncation_result else null,
                .match_limit_reached = if (match_limit_reached) effective_limit else null,
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

const Match = struct {
    path: []const u8,
    line_number: usize,
    line_text: []const u8,
};

pub fn parseArguments(args: std.json.Value) !GrepArgs {
    return args_parser.parseArgsFromJson(GrepArgs, std.heap.page_allocator, args);
}

fn appendContextBlock(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    process_cwd: []const u8,
    match: Match,
    context_lines: usize,
) !void {
    const absolute_file_path = try std.fs.path.resolve(allocator, &[_][]const u8{ process_cwd, match.path });
    defer allocator.free(absolute_file_path);

    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, absolute_file_path, allocator, .unlimited) catch {
        try appendOutputLine(
            allocator,
            output,
            try std.fmt.allocPrint(allocator, "{s}:{d}: (unable to read file)", .{ match.path, match.line_number }),
        );
        return;
    };
    defer allocator.free(bytes);

    var file_lines = std.ArrayList([]const u8).empty;
    defer file_lines.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (iterator.next()) |line| {
        try file_lines.append(allocator, trimLineEnding(line));
    }

    const start = if (match.line_number > context_lines) match.line_number - context_lines else 1;
    const end = @min(match.line_number + context_lines, file_lines.items.len);

    for (start..end + 1) |line_number| {
        const separator = if (line_number == match.line_number) ":" else "-";
        const formatted = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{d}{s} {s}",
            .{ match.path, separator, line_number, separator, file_lines.items[line_number - 1] },
        );
        try appendOutputLine(allocator, output, formatted);
    }
}

fn appendOutputLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    line: []u8,
) !void {
    defer allocator.free(line);
    if (output.items.len > 0) try output.append(allocator, '\n');
    try output.appendSlice(allocator, line);
}

fn buildNotice(
    allocator: std.mem.Allocator,
    was_truncated: bool,
    match_limit_reached: bool,
    effective_limit: usize,
) ![]u8 {
    if (!was_truncated and !match_limit_reached) return allocator.dupe(u8, "");

    var notices = std.ArrayList([]const u8).empty;
    defer notices.deinit(allocator);

    if (match_limit_reached) {
        try notices.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{d} matches limit reached. Use limit={d} for more",
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

fn deinitMatches(allocator: std.mem.Allocator, matches: *std.ArrayList(Match)) void {
    for (matches.items) |match| {
        allocator.free(match.path);
        allocator.free(match.line_text);
    }
    matches.deinit(allocator);
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn getStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn trimLineEnding(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, "\r\n");
}

test "grep tool searches files and returns matching lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "alpha.txt",
        .data = "one\nmatch here\nthree\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nested/beta.txt",
        .data = "zero\nanother match\n",
    });

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(relative_dir);
    const absolute_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(absolute_dir);

    var result = try GrepTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .pattern = "match",
        .path = absolute_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "alpha.txt:2: match here"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "beta.txt:2: another match"));
}

test "grep tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "grep tool validates positive limits" {
    var object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "pattern"), .{
        .string = try std.testing.allocator.dupe(u8, "hello"),
    });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "limit"), .{ .integer = 0 });

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}
