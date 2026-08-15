const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const mutation_queue = @import("file_mutation_queue.zig");
const write_mod = @import("write.zig");

const parseOptionalString = common.parseOptionalString;
const schemaProperty = common.schemaProperty;
const makeAbsoluteTestPath = common.makeAbsoluteTestPath;
const jsonObject = common.jsonObject;

const utf8_bom = "\xEF\xBB\xBF";

pub const Edit = struct {
    old_text: []const u8,
    new_text: []const u8,
};

pub const EditArgs = struct {
    path: []const u8,
    edits: []const Edit,
};

pub const ParsedEditArgs = struct {
    path: []const u8,
    edits: []const Edit,

    pub fn deinit(self: *ParsedEditArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.edits);
        self.* = undefined;
    }

    pub fn toArgs(self: ParsedEditArgs) EditArgs {
        return .{
            .path = self.path,
            .edits = self.edits,
        };
    }
};

pub const EditExecutionResult = struct {
    content: []const ai.ContentBlock,
    is_error: bool = false,

    pub fn deinit(self: *EditExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        self.* = undefined;
    }
};

pub const EditTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "edit";
    pub const description =
        "Edit a single file using one or more exact text replacements. Each search text must match exactly one location in the original file, and edits must not overlap.";

    /// Edit args contain a nested edits slice that must be allocated by the
    /// caller-provided `parseArguments`, so it cannot use the reflection-only
    /// generic adapter.
    pub const use_default_adapter = false;

    pub fn init(cwd: []const u8, io: std.Io) EditTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        var properties = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer {
            const value = std.json.Value{ .object = properties };
            common.deinitJsonValue(allocator, value);
        }

        try common.putValue(allocator, &properties, "path", try schemaProperty(
            allocator,
            "string",
            "Path to the file to edit (absolute or relative to cwd)",
        ));
        try common.putValue(allocator, &properties, "edits", try schemaArrayProperty(
            allocator,
            "One or more exact text replacements. Each oldText is matched against the original file, not incrementally after earlier edits.",
            try editSchemaEntry(allocator),
        ));
        try common.putValue(allocator, &properties, "oldText", try schemaProperty(
            allocator,
            "string",
            "Legacy single-edit search text. It must match exactly one location in the file.",
        ));
        try common.putValue(allocator, &properties, "newText", try schemaProperty(
            allocator,
            "string",
            "Legacy single-edit replacement text.",
        ));

        var required = std.json.Array.init(allocator);
        try required.append(.{ .string = try allocator.dupe(u8, "path") });

        var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &root, "type", "object");
        try common.putValue(allocator, &root, "properties", .{ .object = properties });
        try common.putValue(allocator, &root, "required", .{ .array = required });
        return .{ .object = root };
    }

    pub fn execute(
        self: EditTool,
        allocator: std.mem.Allocator,
        args: EditArgs,
    ) !EditExecutionResult {
        if (args.edits.len == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "Edit tool input is invalid. edits must contain at least one replacement."),
                .is_error = true,
            };
        }

        const absolute_path = try common.resolvePath(allocator, self.cwd, args.path);
        defer allocator.free(absolute_path);

        var mutation_guard = try mutation_queue.acquire(self.io, allocator, absolute_path);
        defer mutation_guard.release();

        const raw_content = std.Io.Dir.readFileAlloc(.cwd(), self.io, absolute_path, allocator, .unlimited) catch |err| {
            const message = switch (err) {
                error.FileNotFound => try std.fmt.allocPrint(allocator, "File not found: {s}", .{args.path}),
                else => try std.fmt.allocPrint(allocator, "Failed to read {s}: {s}", .{ args.path, @errorName(err) }),
            };
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        defer allocator.free(raw_content);

        const stripped = stripBom(raw_content);
        const original_line_ending = detectLineEnding(stripped.text);

        const normalized_content = try normalizeToLf(allocator, stripped.text);
        defer allocator.free(normalized_content);

        var normalized_edits = try allocator.alloc(Edit, args.edits.len);
        defer {
            for (normalized_edits) |edit| {
                allocator.free(edit.old_text);
                allocator.free(edit.new_text);
            }
            allocator.free(normalized_edits);
        }

        for (args.edits, 0..) |edit, index| {
            normalized_edits[index] = .{
                .old_text = try normalizeToLf(allocator, edit.old_text),
                .new_text = try normalizeToLf(allocator, edit.new_text),
            };
        }

        var validation = try validateEdits(allocator, normalized_content, normalized_edits, args.path);
        defer validation.deinit(allocator);

        if (validation.has_failure) {
            const message = if (args.edits.len == 1)
                try allocator.dupe(u8, validation.firstFailureMessage().?)
            else
                try formatBatchFailureMessage(allocator, args.path, validation.statuses);
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        }

        const replaced = try applyValidatedEdits(allocator, normalized_content, validation.matched_edits);
        defer allocator.free(replaced);

        const restored = try restoreLineEndings(allocator, replaced, original_line_ending);
        defer allocator.free(restored);

        const final_content = if (stripped.bom.len == 0)
            try allocator.dupe(u8, restored)
        else
            try std.mem.concat(allocator, u8, &[_][]const u8{ stripped.bom, restored });
        defer allocator.free(final_content);

        common.writeFileAbsolute(self.io, absolute_path, final_content, false) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Failed to write {s}: {s}", .{ args.path, @errorName(err) });
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };

        const message = if (args.edits.len == 1)
            try std.fmt.allocPrint(allocator, "Successfully replaced text in {s}", .{args.path})
        else
            try std.fmt.allocPrint(allocator, "Successfully replaced {d} block(s) in {s}", .{ args.edits.len, args.path });
        defer allocator.free(message);
        return .{
            .content = try common.makeTextContent(allocator, message),
        };
    }
};

pub fn parseArguments(allocator: std.mem.Allocator, args: std.json.Value) !ParsedEditArgs {
    if (args != .object) return error.InvalidToolArguments;

    var edits = std.ArrayList(Edit).empty;
    errdefer edits.deinit(allocator);

    if (args.object.get("edits")) |edits_value| {
        if (edits_value != .array) return error.InvalidToolArguments;
        for (edits_value.array.items) |edit_value| {
            if (edit_value != .object) return error.InvalidToolArguments;
            try edits.append(allocator, .{
                .old_text = try parseRequiredStringEither(edit_value.object, "oldText", "old_text"),
                .new_text = try parseRequiredStringEither(edit_value.object, "newText", "new_text"),
            });
        }
    }

    const legacy_old = try parseOptionalStringEither(args.object, "oldText", "old_text");
    const legacy_new = try parseOptionalStringEither(args.object, "newText", "new_text");
    if ((legacy_old == null) != (legacy_new == null)) return error.InvalidToolArguments;
    if (legacy_old) |old_text| {
        try edits.append(allocator, .{
            .old_text = old_text,
            .new_text = legacy_new.?,
        });
    }

    if (edits.items.len == 0) return error.InvalidToolArguments;

    return .{
        .path = try parseRequiredString(args.object, "path"),
        .edits = try edits.toOwnedSlice(allocator),
    };
}

const StrippedBom = struct {
    bom: []const u8,
    text: []const u8,
};

const LineEnding = enum {
    lf,
    crlf,
    cr,
};

const EditStatus = struct {
    matched: bool = false,
    message: ?[]u8 = null,
};

const MatchedEdit = struct {
    edit_index: usize,
    match_index: usize,
    match_length: usize,
    new_text: []const u8,
};

const ValidationResult = struct {
    statuses: []EditStatus,
    matched_edits: []MatchedEdit,
    has_failure: bool,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        for (self.statuses) |status| {
            if (status.message) |message| allocator.free(message);
        }
        allocator.free(self.statuses);
        allocator.free(self.matched_edits);
        self.* = undefined;
    }

    fn firstFailureMessage(self: ValidationResult) ?[]const u8 {
        for (self.statuses) |status| {
            if (status.message) |message| return message;
        }
        return null;
    }
};

fn stripBom(text: []const u8) StrippedBom {
    if (std.mem.startsWith(u8, text, utf8_bom)) {
        return .{
            .bom = text[0..utf8_bom.len],
            .text = text[utf8_bom.len..],
        };
    }
    return .{
        .bom = "",
        .text = text,
    };
}

fn detectLineEnding(text: []const u8) LineEnding {
    if (std.mem.indexOf(u8, text, "\r\n") != null) return .crlf;
    if (std.mem.indexOfScalar(u8, text, '\r') != null) return .cr;
    return .lf;
}

fn normalizeToLf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const without_crlf = try std.mem.replaceOwned(u8, allocator, text, "\r\n", "\n");
    errdefer allocator.free(without_crlf);
    const normalized = try std.mem.replaceOwned(u8, allocator, without_crlf, "\r", "\n");
    allocator.free(without_crlf);
    return normalized;
}

fn restoreLineEndings(
    allocator: std.mem.Allocator,
    text: []const u8,
    line_ending: LineEnding,
) ![]u8 {
    return switch (line_ending) {
        .lf => allocator.dupe(u8, text),
        .crlf => std.mem.replaceOwned(u8, allocator, text, "\n", "\r\n"),
        .cr => std.mem.replaceOwned(u8, allocator, text, "\n", "\r"),
    };
}

fn parseRequiredStringEither(object: std.json.ObjectMap, primary: []const u8, alternate: []const u8) ![]const u8 {
    if (try common.parseOptionalString(object, primary)) |value| return value;
    return (try common.parseOptionalString(object, alternate)) orelse error.InvalidToolArguments;
}

fn parseOptionalStringEither(object: std.json.ObjectMap, primary: []const u8, alternate: []const u8) !?[]const u8 {
    if (try common.parseOptionalString(object, primary)) |value| return value;
    return try common.parseOptionalString(object, alternate);
}

fn parseRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try common.parseOptionalString(object, key)) orelse error.InvalidToolArguments;
}

fn editSchemaEntry(allocator: std.mem.Allocator) !std.json.Value {
    return common.objectSchema(allocator, &.{
        .{
            .name = "oldText",
            .type_name = "string",
            .description = "Exact text to replace. It must match exactly one location in the original file.",
            .required = true,
        },
        .{
            .name = "newText",
            .type_name = "string",
            .description = "Replacement text for the matched block.",
            .required = true,
        },
    });
}

const schemaArrayProperty = common.schemaArrayProperty;

const QueuedEditThreadContext = struct {
    path: []const u8,
    success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *QueuedEditThreadContext) void {
        var result = EditTool.init(".", std.testing.io).execute(std.heap.page_allocator, .{
            .path = self.path,
            .edits = &[_]Edit{.{
                .old_text = "original",
                .new_text = "edited",
            }},
        }) catch unreachable;
        defer result.deinit(std.heap.page_allocator);
        self.success.store(!result.is_error, .seq_cst);
    }
};

const QueuedWriteThreadContext = struct {
    path: []const u8,
    success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *QueuedWriteThreadContext) void {
        var result = write_mod.WriteTool.init(".", std.testing.io).execute(std.heap.page_allocator, .{
            .path = self.path,
            .content = "replacement\n",
        }) catch unreachable;
        defer result.deinit(std.heap.page_allocator);
        self.success.store(!result.is_error, .seq_cst);
    }
};

fn validateEdits(
    allocator: std.mem.Allocator,
    normalized_content: []const u8,
    edits: []const Edit,
    path: []const u8,
) !ValidationResult {
    var statuses = try allocator.alloc(EditStatus, edits.len);
    errdefer allocator.free(statuses);
    for (statuses) |*status| status.* = .{};

    var matched = std.ArrayList(MatchedEdit).empty;
    errdefer matched.deinit(allocator);

    var has_failure = false;
    for (edits, 0..) |edit, index| {
        if (edit.old_text.len == 0) {
            statuses[index].message = if (edits.len == 1)
                try allocator.dupe(u8, "Search text must not be empty")
            else
                try allocator.dupe(u8, "search text must not be empty");
            has_failure = true;
            continue;
        }

        const match_count = std.mem.count(u8, normalized_content, edit.old_text);
        if (match_count == 0) {
            statuses[index].message = if (edits.len == 1)
                try std.fmt.allocPrint(allocator, "Search text not found in {s}", .{path})
            else
                try allocator.dupe(u8, "search text not found");
            has_failure = true;
            continue;
        }
        if (match_count > 1) {
            statuses[index].message = if (edits.len == 1)
                try std.fmt.allocPrint(allocator, "Search text matched multiple locations in {s}", .{path})
            else
                try allocator.dupe(u8, "search text matched multiple locations");
            has_failure = true;
            continue;
        }

        statuses[index].matched = true;
        try matched.append(allocator, .{
            .edit_index = index,
            .match_index = std.mem.indexOf(u8, normalized_content, edit.old_text).?,
            .match_length = edit.old_text.len,
            .new_text = edit.new_text,
        });
    }

    std.mem.sort(MatchedEdit, matched.items, {}, struct {
        fn lessThan(_: void, lhs: MatchedEdit, rhs: MatchedEdit) bool {
            return lhs.match_index < rhs.match_index;
        }
    }.lessThan);

    if (matched.items.len > 1) {
        for (matched.items[1..], 1..) |current, sorted_index| {
            const previous = matched.items[sorted_index - 1];
            if (previous.match_index + previous.match_length > current.match_index) {
                statuses[current.edit_index].matched = false;
                statuses[current.edit_index].message = try std.fmt.allocPrint(
                    allocator,
                    "overlaps with edits[{d}]",
                    .{previous.edit_index},
                );
                has_failure = true;
            }
        }
    }

    return .{
        .statuses = statuses,
        .matched_edits = try matched.toOwnedSlice(allocator),
        .has_failure = has_failure,
    };
}

fn applyValidatedEdits(
    allocator: std.mem.Allocator,
    normalized_content: []const u8,
    matched_edits: []const MatchedEdit,
) ![]u8 {
    var replaced = try allocator.dupe(u8, normalized_content);
    errdefer allocator.free(replaced);

    var index = matched_edits.len;
    while (index > 0) {
        index -= 1;
        const edit = matched_edits[index];
        const next = try std.mem.concat(allocator, u8, &[_][]const u8{
            replaced[0..edit.match_index],
            edit.new_text,
            replaced[edit.match_index + edit.match_length ..],
        });
        allocator.free(replaced);
        replaced = next;
    }

    return replaced;
}

fn formatBatchFailureMessage(
    allocator: std.mem.Allocator,
    path: []const u8,
    statuses: []const EditStatus,
) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    const header = try std.fmt.allocPrint(
        allocator,
        "Failed to apply {d} edit(s) to {s}. No changes were written.",
        .{ statuses.len, path },
    );
    defer allocator.free(header);
    try buffer.appendSlice(allocator, header);

    for (statuses, 0..) |status, index| {
        const outcome = if (status.message) |message| message else "matched uniquely";
        const line = try std.fmt.allocPrint(allocator, "\n- edits[{d}]: {s}", .{ index, outcome });
        defer allocator.free(line);
        try buffer.appendSlice(allocator, line);
    }

    return buffer.toOwnedSlice(allocator);
}

test "edit tool replaces matching text in a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "before old text after",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .edits = &[_]Edit{.{
            .old_text = "old text",
            .new_text = "new text",
        }},
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("before new text after", written);
}

test "edit and write share the same queued mutation order for one file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "mixed.txt",
        .data = "original\n",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "mixed.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var held_guard = try mutation_queue.acquire(std.testing.io, std.testing.allocator, absolute_path);

    var edit_context = QueuedEditThreadContext{ .path = absolute_path };
    const edit_thread = try std.Thread.spawn(.{}, QueuedEditThreadContext.run, .{&edit_context});

    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);

    var write_context = QueuedWriteThreadContext{ .path = absolute_path };
    const write_thread = try std.Thread.spawn(.{}, QueuedWriteThreadContext.run, .{&write_context});

    held_guard.release();

    edit_thread.join();
    write_thread.join();

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    try std.testing.expect(edit_context.success.load(.seq_cst));
    try std.testing.expect(write_context.success.load(.seq_cst));
    try std.testing.expectEqualStrings("replacement\n", written);
}

test "edit tool returns an error when the search text is not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "before after",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .edits = &[_]Edit{.{
            .old_text = "missing text",
            .new_text = "new text",
        }},
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Search text not found"));
}

test "edit tool applies multiple edits atomically in one call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "first old\nsecond old\nthird old\n",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .edits = &[_]Edit{
            .{ .old_text = "first old", .new_text = "first new" },
            .{ .old_text = "third old", .new_text = "third new" },
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Successfully replaced 2 block(s)"));

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("first new\nsecond old\nthird new\n", written);
}

test "edit tool reports batch failure without writing partial changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "first old\nsecond old\nthird old\n",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .edits = &[_]Edit{
            .{ .old_text = "first old", .new_text = "first new" },
            .{ .old_text = "missing text", .new_text = "unused" },
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "No changes were written"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "edits[0]: matched uniquely"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "edits[1]: search text not found"));

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("first old\nsecond old\nthird old\n", written);
}

test "edit tool reports overlapping edits without writing changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "abcdefg",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .edits = &[_]Edit{
            .{ .old_text = "abcd", .new_text = "ABCD" },
            .{ .old_text = "cdef", .new_text = "CDEF" },
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "No changes were written"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "edits[1]: overlaps with edits[0]"));

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("abcdefg", written);
}

test "edit tool parses edits arrays and appends legacy single-edit arguments" {
    var object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    var edits = std.json.Array.init(std.testing.allocator);
    var first_edit = try jsonObject(std.testing.allocator);
    try first_edit.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "oldText"), .{ .string = try std.testing.allocator.dupe(u8, "first old") });
    try first_edit.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "newText"), .{ .string = try std.testing.allocator.dupe(u8, "first new") });
    try edits.append(.{ .object = first_edit });

    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "path"), .{ .string = try std.testing.allocator.dupe(u8, "editable.txt") });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "edits"), .{ .array = edits });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "oldText"), .{ .string = try std.testing.allocator.dupe(u8, "legacy old") });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "newText"), .{ .string = try std.testing.allocator.dupe(u8, "legacy new") });

    var parsed = try parseArguments(std.testing.allocator, .{ .object = object });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("editable.txt", parsed.path);
    try std.testing.expectEqual(@as(usize, 2), parsed.edits.len);
    try std.testing.expectEqualStrings("first old", parsed.edits[0].old_text);
    try std.testing.expectEqualStrings("first new", parsed.edits[0].new_text);
    try std.testing.expectEqualStrings("legacy old", parsed.edits[1].old_text);
    try std.testing.expectEqualStrings("legacy new", parsed.edits[1].new_text);
}

test "edit tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(std.testing.allocator, .{ .object = object }));
}

test "edit tool preserves UTF-8 BOM on round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "bom.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    // Write file with BOM
    const bom = "\xEF\xBB\xBF";
    const initial = bom ++ "hello world";
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = relative_path, .data = initial });

    const tool = EditTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .edits = &[_]Edit{.{
            .old_text = "hello",
            .new_text = "goodbye",
        }},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);

    // Verify BOM is preserved
    const updated = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, relative_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(updated);
    try std.testing.expect(std.mem.startsWith(u8, updated, bom));
    try std.testing.expect(std.mem.indexOf(u8, updated, "goodbye world") != null);
}

test "edit tool preserves CRLF line endings on round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "crlf.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    // Write file with CRLF line endings
    const initial = "line one\r\nline two\r\nline three";
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = relative_path, .data = initial });

    const tool = EditTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .edits = &[_]Edit{.{
            .old_text = "line two",
            .new_text = "LINE TWO",
        }},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);

    // Verify CRLF preserved
    const updated = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, relative_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "LINE TWO") != null);
    // No bare LF should exist outside CRLF pairs
    try std.testing.expect(std.mem.indexOf(u8, updated, "\n\r") == null); // no LF-CR inversions
}

test "edit tool reports error for empty edits array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "noedits.txt",
    });
    defer std.testing.allocator.free(relative_path);

    const cwd = try makeAbsoluteTestPath(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd);

    const tool = EditTool.init(cwd, std.testing.io);
    var result = try tool.execute(std.testing.allocator, .{
        .path = relative_path,
        .edits = &[_]Edit{},
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "at least one") != null);
}

test "detectLineEnding identifies CR-only line endings" {
    try std.testing.expectEqual(LineEnding.cr, detectLineEnding("line one\rline two"));
    try std.testing.expectEqual(LineEnding.crlf, detectLineEnding("line one\r\nline two"));
    try std.testing.expectEqual(LineEnding.lf, detectLineEnding("line one\nline two"));
    try std.testing.expectEqual(LineEnding.lf, detectLineEnding("no line endings"));
    // CRLF takes precedence over lone CR
    try std.testing.expectEqual(LineEnding.crlf, detectLineEnding("\r\n\r"));
}
