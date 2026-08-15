const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const args_parser = @import("args_parser.zig");
const truncate = @import("truncate.zig");

const makeAbsoluteTestPath = common.makeAbsoluteTestPath;
const jsonObject = common.jsonObject;

pub const ReadArgs = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,

    pub const json_int_constraints = .{
        .offset = .positive,
        .limit = .positive,
    };

    pub const json_field_docs = .{
        .path = "Path to the file to read (absolute or relative to cwd)",
        .offset = "1-indexed line number to start reading from",
        .limit = "Maximum number of lines to read",
    };
};

pub const ReadDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    mime_type: ?[]const u8 = null,

    pub fn deinit(self: *ReadDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadExecutionResult = struct {
    content: []const ai.ContentBlock,
    details: ?ReadDetails = null,
    is_error: bool = false,

    pub fn deinit(self: *ReadExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "read";
    pub const description =
        "Read the contents of a file with optional 1-indexed line offset and line limit. " ++
        "Text output is truncated to 2000 lines or 50KB, and supported image files are returned as image blocks.";

    pub fn init(cwd: []const u8, io: std.Io) ReadTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        return common.schemaFromArgs(ReadArgs, allocator);
    }

    pub fn execute(
        self: ReadTool,
        allocator: std.mem.Allocator,
        args: ReadArgs,
    ) !ReadExecutionResult {
        const absolute_path = try common.resolvePath(allocator, self.cwd, args.path);
        defer allocator.free(absolute_path);

        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.io, absolute_path, allocator, .unlimited) catch |err| {
            const message = switch (err) {
                error.FileNotFound => try std.fmt.allocPrint(allocator, "File not found: {s}", .{absolute_path}),
                else => try std.fmt.allocPrint(allocator, "Failed to read {s}: {s}", .{ absolute_path, @errorName(err) }),
            };
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        defer allocator.free(bytes);

        if (detectImageMime(bytes)) |mime_type| {
            return try buildImageResult(allocator, bytes, mime_type);
        }

        return try buildTextResult(allocator, bytes, args);
    }
};

pub fn parseArguments(args: std.json.Value) !ReadArgs {
    return args_parser.parseArgsFromJson(ReadArgs, std.heap.page_allocator, args);
}

fn buildImageResult(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    mime_type: []const u8,
) !ReadExecutionResult {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    const blocks = try allocator.alloc(ai.ContentBlock, 2);
    const mime_copy = try allocator.dupe(u8, mime_type);
    errdefer allocator.free(mime_copy);

    const note = try std.fmt.allocPrint(allocator, "Read image file [{s}]", .{mime_type});
    errdefer allocator.free(note);

    blocks[0] = .{ .text = .{ .text = note } };
    blocks[1] = .{ .image = .{
        .data = encoded,
        .mime_type = mime_copy,
    } };

    return .{
        .content = blocks,
        .details = .{ .mime_type = mime_type },
    };
}

fn buildTextResult(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    args: ReadArgs,
) !ReadExecutionResult {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (iterator.next()) |line| {
        try lines.append(allocator, line);
    }

    const line_offset = args.offset orelse 1;
    if (line_offset == 0) {
        return .{
            .content = try common.makeTextContent(allocator, "Offset must be greater than or equal to 1"),
            .is_error = true,
        };
    }
    if (args.limit) |limit| {
        if (limit == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "Limit must be greater than or equal to 1"),
                .is_error = true,
            };
        }
    }

    if (line_offset > lines.items.len) {
        const message = try std.fmt.allocPrint(
            allocator,
            "Offset {d} is beyond end of file ({d} lines total)",
            .{ line_offset, lines.items.len },
        );
        defer allocator.free(message);
        return .{
            .content = try common.makeTextContent(allocator, message),
            .is_error = true,
        };
    }

    const start_index = line_offset - 1;
    const end_index = if (args.limit) |limit|
        @min(start_index + limit, lines.items.len)
    else
        lines.items.len;

    const selected_text = try std.mem.join(allocator, "\n", lines.items[start_index..end_index]);
    defer allocator.free(selected_text);

    var truncation_result = try truncate.truncateHead(allocator, selected_text, .{});
    errdefer truncation_result.deinit(allocator);

    var output_text: []u8 = undefined;
    var details: ?ReadDetails = null;

    if (truncation_result.first_line_exceeds_limit) {
        const size = try formatSize(allocator, lines.items[start_index].len);
        defer allocator.free(size);
        output_text = try std.fmt.allocPrint(
            allocator,
            "[Line {d} is {s}, which exceeds the 50KB read limit. Use bash for targeted output.]",
            .{ line_offset, size },
        );
        details = .{ .truncation = truncation_result };
    } else if (truncation_result.truncated) {
        const end_line = line_offset + truncation_result.output_lines - 1;
        const next_offset = end_line + 1;
        const continuation = if (truncation_result.truncated_by.? == .lines)
            try std.fmt.allocPrint(
                allocator,
                "\n\n[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]",
                .{ line_offset, end_line, lines.items.len, next_offset },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "\n\n[Showing lines {d}-{d} of {d} (50KB limit). Use offset={d} to continue.]",
                .{ line_offset, end_line, lines.items.len, next_offset },
            );
        defer allocator.free(continuation);

        output_text = try std.mem.concat(allocator, u8, &[_][]const u8{ truncation_result.content, continuation });
        details = .{ .truncation = truncation_result };
    } else if (args.limit != null and end_index < lines.items.len) {
        const remaining = lines.items.len - end_index;
        const next_offset = end_index + 1;
        const note = try std.fmt.allocPrint(
            allocator,
            "\n\n[{d} more lines in file. Use offset={d} to continue.]",
            .{ remaining, next_offset },
        );
        defer allocator.free(note);
        output_text = try std.mem.concat(allocator, u8, &[_][]const u8{ truncation_result.content, note });
        truncation_result.deinit(allocator);
    } else {
        output_text = try allocator.dupe(u8, truncation_result.content);
        truncation_result.deinit(allocator);
    }
    defer allocator.free(output_text);

    return .{
        .content = try common.makeTextContent(allocator, output_text),
        .details = details,
    };
}

fn detectImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return "image/gif";
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}

fn formatSize(allocator: std.mem.Allocator, bytes: usize) ![]u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d}B", .{bytes});
    if (bytes < 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    return std.fmt.allocPrint(allocator, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
}

test "read tool returns full file contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "plain.txt",
        .data = "Hello\nWorld",
    });

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "plain.txt" });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try ReadTool.init(".", std.testing.io).execute(std.testing.allocator, .{ .path = absolute_path });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings("Hello\nWorld", result.content[0].text.text);
}

test "read tool returns requested line range for offset and limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var content = std.ArrayList(u8).empty;
    defer content.deinit(std.testing.allocator);

    for (1..21) |index| {
        if (index > 1) try content.append(std.testing.allocator, '\n');
        const line = try std.fmt.allocPrint(std.testing.allocator, "Line {d}", .{index});
        defer std.testing.allocator.free(line);
        try content.appendSlice(std.testing.allocator, line);
    }

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lines.txt",
        .data = content.items,
    });

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "lines.txt" });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try ReadTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .offset = 5,
        .limit = 10,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(
        "Line 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\nLine 12\nLine 13\nLine 14\n\n[6 more lines in file. Use offset=15 to continue.]",
        result.content[0].text.text,
    );
}

test "read tool detects images and returns an image block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==";
    const png_bytes = try std.testing.allocator.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(png_base64) catch unreachable);
    defer std.testing.allocator.free(png_bytes);
    try std.base64.standard.Decoder.decode(png_bytes, png_base64);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "image.dat",
        .data = png_bytes,
    });

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "image.dat" });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try ReadTool.init(".", std.testing.io).execute(std.testing.allocator, .{ .path = absolute_path });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 2), result.content.len);
    try std.testing.expectEqualStrings("Read image file [image/png]", result.content[0].text.text);
    try std.testing.expectEqualStrings("image/png", result.content[1].image.mime_type);
    try std.testing.expect(result.content[1].image.data.len > 0);
}

test "read tool returns a clear error for missing files" {
    var result = try ReadTool.init(".", std.testing.io).execute(std.testing.allocator, .{ .path = "/definitely/missing/file.txt" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "File not found"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "/definitely/missing/file.txt"));
}

test "read tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "read tool validates positive offset and limit" {
    var object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "path"), .{
        .string = try std.testing.allocator.dupe(u8, "file.txt"),
    });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "offset"), .{ .integer = 0 });
    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));

    var limit_object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = limit_object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try limit_object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "path"), .{
        .string = try std.testing.allocator.dupe(u8, "file.txt"),
    });
    try limit_object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "limit"), .{ .integer = 0 });
    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = limit_object }));
}

test "detectImageMime identifies PNG JPEG GIF and WEBP" {
    // PNG magic bytes
    try std.testing.expectEqualStrings("image/png", detectImageMime("\x89PNG\r\n\x1a\nrest").?);
    // JPEG magic bytes
    try std.testing.expectEqualStrings("image/jpeg", detectImageMime("\xff\xd8\xffmore").?);
    // GIF87a
    try std.testing.expectEqualStrings("image/gif", detectImageMime("GIF87a123456").?);
    // GIF89a
    try std.testing.expectEqualStrings("image/gif", detectImageMime("GIF89a123456").?);
    // WEBP
    try std.testing.expectEqualStrings("image/webp", detectImageMime("RIFF????WEBP").?);
    // Not an image
    try std.testing.expect(detectImageMime("plain text") == null);
    // Too short for PNG
    try std.testing.expect(detectImageMime("\x89PNG\r\n") == null);
}

test "read tool returns offset-beyond-end error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "short.txt",
    });
    defer std.testing.allocator.free(relative_path);

    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = relative_path, .data = "line1\nline2\n" });

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    const tool = ReadTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .offset = 100,
        .limit = null,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "beyond end") != null);
}

test "read tool offset and limit select correct range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "ranged.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const data = "line1\nline2\nline3\nline4\nline5\n";
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = relative_path, .data = data });

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    const tool = ReadTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .offset = 2,
        .limit = 2,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "line3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "line1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "line4") == null);
}

test "formatSize formats bytes correctly" {
    const allocator = std.testing.allocator;

    const b = try formatSize(allocator, 512);
    defer allocator.free(b);
    try std.testing.expectEqualStrings("512B", b);

    const kb = try formatSize(allocator, 1536);
    defer allocator.free(kb);
    try std.testing.expectEqualStrings("1.5KB", kb);

    const mb = try formatSize(allocator, 2 * 1024 * 1024);
    defer allocator.free(mb);
    try std.testing.expectEqualStrings("2.0MB", mb);
}
