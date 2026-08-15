const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const args_parser = @import("args_parser.zig");
const truncate = @import("truncate.zig");

const makeAbsoluteTestPath = common.makeAbsoluteTestPath;
const jsonObject = common.jsonObject;

const DEFAULT_LIMIT: usize = 500;

pub const LsArgs = struct {
    path: ?[]const u8 = null,
    limit: ?usize = null,

    pub const json_int_constraints = .{
        .limit = .positive,
    };

    pub const json_field_docs = .{
        .path = "Directory to list (defaults to cwd)",
        .limit = "Maximum number of directory entries to return",
    };
};

pub const LsDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    entry_limit_reached: ?usize = null,

    pub fn deinit(self: *LsDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const LsExecutionResult = struct {
    content: []const ai.ContentBlock,
    details: ?LsDetails = null,
    is_error: bool = false,

    pub fn deinit(self: *LsExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub const LsTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "ls";
    pub const description =
        "List directory contents, including dotfiles, with entry type and file size. " ++
        "Directories are suffixed with '/'.";

    pub fn init(cwd: []const u8, io: std.Io) LsTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        return common.schemaFromArgs(LsArgs, allocator);
    }

    pub fn execute(
        self: LsTool,
        allocator: std.mem.Allocator,
        args: LsArgs,
    ) !LsExecutionResult {
        const effective_limit = args.limit orelse DEFAULT_LIMIT;
        if (effective_limit == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "Limit must be greater than or equal to 1"),
                .is_error = true,
            };
        }

        const absolute_path = try common.resolvePath(allocator, self.cwd, args.path orelse ".");
        defer allocator.free(absolute_path);

        const dir_stat = std.Io.Dir.statFile(.cwd(), self.io, absolute_path, .{}) catch |err| {
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
        if (dir_stat.kind != .directory) {
            const message = try std.fmt.allocPrint(allocator, "Not a directory: {s}", .{absolute_path});
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        }

        var dir = std.Io.Dir.openDirAbsolute(self.io, absolute_path, .{ .iterate = true }) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Cannot open directory {s}: {s}", .{ absolute_path, @errorName(err) });
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        defer dir.close(self.io);

        var iterator = dir.iterate();
        var entries = std.ArrayList(ListedEntry).empty;
        defer deinitEntries(allocator, &entries);

        var entry_limit_reached = false;
        while (try iterator.next(self.io)) |entry| {
            if (entries.items.len >= effective_limit) {
                entry_limit_reached = true;
                break;
            }

            const entry_name = try allocator.dupe(u8, entry.name);
            const entry_stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                allocator.free(entry_name);
                continue;
            };

            try entries.append(allocator, .{
                .name = entry_name,
                .kind = entry.kind,
                .size = entry_stat.size,
            });
        }

        if (entries.items.len == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "(empty directory)"),
            };
        }

        std.sort.insertion(ListedEntry, entries.items, {}, lessThanEntryIgnoreCase);

        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        for (entries.items) |entry| {
            const size_text = try formatEntrySize(allocator, entry.kind, entry.size);
            defer allocator.free(size_text);

            const display_name = if (entry.kind == .directory)
                try std.fmt.allocPrint(allocator, "{s}/", .{entry.name})
            else
                try allocator.dupe(u8, entry.name);
            defer allocator.free(display_name);

            const line = try std.fmt.allocPrint(
                allocator,
                "{s}\t{s}\t{s}",
                .{ kindLabel(entry.kind), size_text, display_name },
            );
            defer allocator.free(line);

            if (output.items.len > 0) try output.append(allocator, '\n');
            try output.appendSlice(allocator, line);
        }

        const raw_output = try output.toOwnedSlice(allocator);
        defer allocator.free(raw_output);

        var truncation_result = try truncate.truncateHead(allocator, raw_output, .{
            .max_lines = effective_limit,
            .max_bytes = truncate.DEFAULT_MAX_BYTES,
        });
        errdefer truncation_result.deinit(allocator);

        const notice = try buildNotice(allocator, truncation_result.truncated, entry_limit_reached, effective_limit);
        defer if (notice.len > 0) allocator.free(notice);

        const final_output = if (notice.len > 0)
            try std.mem.concat(allocator, u8, &[_][]const u8{ truncation_result.content, notice })
        else
            try allocator.dupe(u8, truncation_result.content);
        defer allocator.free(final_output);

        var details: ?LsDetails = null;
        if (truncation_result.truncated or entry_limit_reached) {
            details = .{
                .truncation = if (truncation_result.truncated) truncation_result else null,
                .entry_limit_reached = if (entry_limit_reached) effective_limit else null,
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

const ListedEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    size: u64,
};

pub fn parseArguments(args: std.json.Value) !LsArgs {
    return args_parser.parseArgsFromJson(LsArgs, std.heap.page_allocator, args);
}

fn buildNotice(
    allocator: std.mem.Allocator,
    was_truncated: bool,
    entry_limit_reached: bool,
    effective_limit: usize,
) ![]u8 {
    if (!was_truncated and !entry_limit_reached) return allocator.dupe(u8, "");

    var notices = std.ArrayList([]const u8).empty;
    defer notices.deinit(allocator);

    if (entry_limit_reached) {
        try notices.append(allocator, try std.fmt.allocPrint(
            allocator,
            "{d} entries limit reached. Use limit={d} for more",
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

fn deinitEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(ListedEntry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

fn formatEntrySize(
    allocator: std.mem.Allocator,
    kind: std.Io.File.Kind,
    size: u64,
) ![]u8 {
    return switch (kind) {
        .file => formatSize(allocator, size),
        else => allocator.dupe(u8, "-"),
    };
}

fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d}B", .{bytes});
    if (bytes < 1024 * 1024) {
        return std.fmt.allocPrint(allocator, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    }
    return std.fmt.allocPrint(allocator, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
}

fn kindLabel(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .directory => "dir",
        .file => "file",
        .sym_link => "link",
        else => "other",
    };
}

fn lessThanEntryIgnoreCase(_: void, lhs: ListedEntry, rhs: ListedEntry) bool {
    var index: usize = 0;
    while (index < lhs.name.len and index < rhs.name.len) : (index += 1) {
        const left = std.ascii.toLower(lhs.name[index]);
        const right = std.ascii.toLower(rhs.name[index]);
        if (left < right) return true;
        if (left > right) return false;
    }
    return lhs.name.len < rhs.name.len;
}

test "ls tool lists directory contents with types and sizes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "alpha.txt",
        .data = "hello",
    });

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(relative_dir);
    const absolute_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(absolute_dir);

    var result = try LsTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_dir,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "file\t5B\talpha.txt"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "dir\t-\tnested/"));
}

test "ls tool validates optional arguments" {
    var object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "limit"), .{ .integer = 0 });
    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "ls tool errors when the path is not a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain.txt",
        .data = "hello",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "plain.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try LsTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Not a directory"));
}
