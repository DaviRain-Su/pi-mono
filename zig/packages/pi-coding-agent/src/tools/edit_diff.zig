const std = @import("std");
const common = @import("common.zig");

const utf8_bom = "\xEF\xBB\xBF";

pub const LineEnding = enum {
    lf,
    crlf,
};

pub const FuzzyMatchResult = struct {
    found: bool,
    index: usize,
    match_length: usize,
    used_fuzzy_match: bool,
    content_for_replacement: []u8,

    pub fn deinit(self: *FuzzyMatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content_for_replacement);
        self.* = undefined;
    }
};

pub const Edit = struct {
    old_text: []const u8,
    new_text: []const u8,
};

const MatchedEdit = struct {
    edit_index: usize,
    match_index: usize,
    match_length: usize,
    new_text: []const u8,
};

pub const AppliedEditsResult = struct {
    base_content: []u8,
    new_content: []u8,

    pub fn deinit(self: *AppliedEditsResult, allocator: std.mem.Allocator) void {
        allocator.free(self.base_content);
        allocator.free(self.new_content);
        self.* = undefined;
    }
};

pub const DiffStringResult = struct {
    diff: []u8,
    first_changed_line: ?usize,

    pub fn deinit(self: *DiffStringResult, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const EditDiffResult = union(enum) {
    success: DiffStringResult,
    err: []u8,

    pub fn deinit(self: *EditDiffResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*result| result.deinit(allocator),
            .err => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub const StrippedBom = struct {
    bom: []const u8,
    text: []const u8,
};

pub fn detectLineEnding(content: []const u8) LineEnding {
    const crlf_idx = std.mem.indexOf(u8, content, "\r\n");
    const lf_idx = std.mem.indexOfScalar(u8, content, '\n');
    if (lf_idx == null) return .lf;
    if (crlf_idx == null) return .lf;
    return if (crlf_idx.? < lf_idx.?) .crlf else .lf;
}

pub fn normalizeToLf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const without_crlf = try std.mem.replaceOwned(u8, allocator, text, "\r\n", "\n");
    errdefer allocator.free(without_crlf);
    const normalized = try std.mem.replaceOwned(u8, allocator, without_crlf, "\r", "\n");
    allocator.free(without_crlf);
    return normalized;
}

pub fn restoreLineEndings(allocator: std.mem.Allocator, text: []const u8, ending: LineEnding) ![]u8 {
    return switch (ending) {
        .lf => allocator.dupe(u8, text),
        .crlf => std.mem.replaceOwned(u8, allocator, text, "\n", "\r\n"),
    };
}

pub fn stripBom(content: []const u8) StrippedBom {
    if (std.mem.startsWith(u8, content, utf8_bom)) {
        return .{
            .bom = content[0..utf8_bom.len],
            .text = content[utf8_bom.len..],
        };
    }
    return .{ .bom = "", .text = content };
}

pub fn normalizeForFuzzyMatch(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (index == text.len or text[index] == '\n') {
            var line_end = index;
            while (line_end > line_start and isAsciiWhitespaceExceptNewline(text[line_end - 1])) {
                line_end -= 1;
            }
            try appendNormalizedUnicode(allocator, &out, text[line_start..line_end]);
            if (index < text.len) try out.append(allocator, '\n');
            line_start = index + 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn isAsciiWhitespaceExceptNewline(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

fn appendNormalizedUnicode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            try out.append(allocator, byte);
            index += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.append(allocator, byte);
            index += 1;
            continue;
        };
        if (index + len > text.len) {
            try out.appendSlice(allocator, text[index..]);
            break;
        }

        const slice = text[index .. index + len];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            try out.appendSlice(allocator, slice);
            index += len;
            continue;
        };

        switch (codepoint) {
            0x2018, 0x2019, 0x201a, 0x201b => try out.append(allocator, '\''),
            0x201c, 0x201d, 0x201e, 0x201f => try out.append(allocator, '"'),
            0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => try out.append(allocator, '-'),
            0x00a0, 0x2002...0x200a, 0x202f, 0x205f, 0x3000 => try out.append(allocator, ' '),
            else => try out.appendSlice(allocator, slice),
        }
        index += len;
    }
}

pub fn fuzzyFindText(allocator: std.mem.Allocator, content: []const u8, old_text: []const u8) !FuzzyMatchResult {
    if (std.mem.indexOf(u8, content, old_text)) |exact_index| {
        return .{
            .found = true,
            .index = exact_index,
            .match_length = old_text.len,
            .used_fuzzy_match = false,
            .content_for_replacement = try allocator.dupe(u8, content),
        };
    }

    const fuzzy_content = try normalizeForFuzzyMatch(allocator, content);
    errdefer allocator.free(fuzzy_content);
    const fuzzy_old_text = try normalizeForFuzzyMatch(allocator, old_text);
    defer allocator.free(fuzzy_old_text);

    const fuzzy_index = std.mem.indexOf(u8, fuzzy_content, fuzzy_old_text) orelse {
        allocator.free(fuzzy_content);
        return .{
            .found = false,
            .index = 0,
            .match_length = 0,
            .used_fuzzy_match = false,
            .content_for_replacement = try allocator.dupe(u8, content),
        };
    };

    return .{
        .found = true,
        .index = fuzzy_index,
        .match_length = fuzzy_old_text.len,
        .used_fuzzy_match = true,
        .content_for_replacement = fuzzy_content,
    };
}

pub fn applyEditsToNormalizedContent(
    allocator: std.mem.Allocator,
    normalized_content: []const u8,
    edits: []const Edit,
    path: []const u8,
) !AppliedEditsResult {
    var normalized_edits = try allocator.alloc(Edit, edits.len);
    defer {
        for (normalized_edits) |edit| {
            allocator.free(edit.old_text);
            allocator.free(edit.new_text);
        }
        allocator.free(normalized_edits);
    }

    for (edits, 0..) |edit, index| {
        normalized_edits[index] = .{
            .old_text = try normalizeToLf(allocator, edit.old_text),
            .new_text = try normalizeToLf(allocator, edit.new_text),
        };
    }

    for (normalized_edits, 0..) |edit, index| {
        if (edit.old_text.len == 0) return getEmptyOldTextError(path, index, normalized_edits.len);
    }

    var use_fuzzy = false;
    for (normalized_edits) |edit| {
        var initial_match = try fuzzyFindText(allocator, normalized_content, edit.old_text);
        defer initial_match.deinit(allocator);
        if (initial_match.used_fuzzy_match) use_fuzzy = true;
    }

    const base_content = if (use_fuzzy)
        try normalizeForFuzzyMatch(allocator, normalized_content)
    else
        try allocator.dupe(u8, normalized_content);
    errdefer allocator.free(base_content);

    var matched = std.ArrayList(MatchedEdit).empty;
    defer matched.deinit(allocator);

    for (normalized_edits, 0..) |edit, index| {
        var match_result = try fuzzyFindText(allocator, base_content, edit.old_text);
        defer match_result.deinit(allocator);
        if (!match_result.found) return getNotFoundError(path, index, normalized_edits.len);

        const occurrences = try countOccurrences(allocator, base_content, edit.old_text);
        if (occurrences > 1) return getDuplicateError(path, index, normalized_edits.len, occurrences);

        try matched.append(allocator, .{
            .edit_index = index,
            .match_index = match_result.index,
            .match_length = match_result.match_length,
            .new_text = edit.new_text,
        });
    }

    std.mem.sort(MatchedEdit, matched.items, {}, struct {
        fn lessThan(_: void, lhs: MatchedEdit, rhs: MatchedEdit) bool {
            return lhs.match_index < rhs.match_index;
        }
    }.lessThan);

    for (matched.items[1..], 1..) |current, sorted_index| {
        const previous = matched.items[sorted_index - 1];
        if (previous.match_index + previous.match_length > current.match_index) {
            return error.OverlappingEdits;
        }
    }

    var new_content = try allocator.dupe(u8, base_content);
    errdefer allocator.free(new_content);
    var index = matched.items.len;
    while (index > 0) {
        index -= 1;
        const edit = matched.items[index];
        const next = try std.mem.concat(allocator, u8, &.{
            new_content[0..edit.match_index],
            edit.new_text,
            new_content[edit.match_index + edit.match_length ..],
        });
        allocator.free(new_content);
        new_content = next;
    }

    if (std.mem.eql(u8, base_content, new_content)) return getNoChangeError(path, normalized_edits.len);

    return .{
        .base_content = base_content,
        .new_content = new_content,
    };
}

fn countOccurrences(allocator: std.mem.Allocator, content: []const u8, old_text: []const u8) !usize {
    const fuzzy_content = try normalizeForFuzzyMatch(allocator, content);
    defer allocator.free(fuzzy_content);
    const fuzzy_old_text = try normalizeForFuzzyMatch(allocator, old_text);
    defer allocator.free(fuzzy_old_text);
    if (fuzzy_old_text.len == 0) return 0;

    var count: usize = 0;
    var offset: usize = 0;
    while (offset <= fuzzy_content.len) {
        const found = std.mem.indexOf(u8, fuzzy_content[offset..], fuzzy_old_text) orelse break;
        count += 1;
        offset += found + fuzzy_old_text.len;
    }
    return count;
}

fn getNotFoundError(_: []const u8, _: usize, _: usize) error{TextNotFound} {
    return error.TextNotFound;
}

fn getDuplicateError(_: []const u8, _: usize, _: usize, _: usize) error{DuplicateText} {
    return error.DuplicateText;
}

fn getEmptyOldTextError(_: []const u8, _: usize, _: usize) error{EmptyOldText} {
    return error.EmptyOldText;
}

fn getNoChangeError(_: []const u8, _: usize) error{NoChange} {
    return error.NoChange;
}

const DiffLine = struct {
    kind: enum { context, added, removed },
    text: []const u8,
};

pub fn generateDiffString(
    allocator: std.mem.Allocator,
    old_content: []const u8,
    new_content: []const u8,
    context_lines: usize,
) !DiffStringResult {
    var old_lines = try splitLines(allocator, old_content);
    defer old_lines.deinit(allocator);
    var new_lines = try splitLines(allocator, new_content);
    defer new_lines.deinit(allocator);

    var diff_lines = try buildLineDiff(allocator, old_lines.items, new_lines.items);
    defer diff_lines.deinit(allocator);

    const max_line_num = @max(old_lines.items.len, new_lines.items.len);
    const line_num_width = decimalWidth(max_line_num);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var old_line_num: usize = 1;
    var new_line_num: usize = 1;
    var last_was_change = false;
    var first_changed_line: ?usize = null;

    var part_index: usize = 0;
    while (part_index < diff_lines.items.len) {
        const start = part_index;
        const kind = diff_lines.items[start].kind;
        while (part_index < diff_lines.items.len and diff_lines.items[part_index].kind == kind) : (part_index += 1) {}
        const part = diff_lines.items[start..part_index];

        if (kind == .added or kind == .removed) {
            if (first_changed_line == null) first_changed_line = new_line_num;
            for (part) |line| {
                if (kind == .added) {
                    try appendNumberedLine(allocator, &output, '+', new_line_num, line_num_width, line.text);
                    new_line_num += 1;
                } else {
                    try appendNumberedLine(allocator, &output, '-', old_line_num, line_num_width, line.text);
                    old_line_num += 1;
                }
            }
            last_was_change = true;
            continue;
        }

        const next_part_is_change = part_index < diff_lines.items.len and diff_lines.items[part_index].kind != .context;
        const has_leading_change = last_was_change;
        const has_trailing_change = next_part_is_change;
        if (has_leading_change and has_trailing_change) {
            if (part.len <= context_lines * 2) {
                for (part) |line| {
                    try appendNumberedLine(allocator, &output, ' ', old_line_num, line_num_width, line.text);
                    old_line_num += 1;
                    new_line_num += 1;
                }
            } else {
                for (part[0..context_lines]) |line| {
                    try appendNumberedLine(allocator, &output, ' ', old_line_num, line_num_width, line.text);
                    old_line_num += 1;
                    new_line_num += 1;
                }
                const skipped = part.len - context_lines * 2;
                try appendEllipsis(allocator, &output, line_num_width);
                old_line_num += skipped;
                new_line_num += skipped;
                for (part[part.len - context_lines ..]) |line| {
                    try appendNumberedLine(allocator, &output, ' ', old_line_num, line_num_width, line.text);
                    old_line_num += 1;
                    new_line_num += 1;
                }
            }
        } else if (has_leading_change) {
            const shown_count = @min(context_lines, part.len);
            for (part[0..shown_count]) |line| {
                try appendNumberedLine(allocator, &output, ' ', old_line_num, line_num_width, line.text);
                old_line_num += 1;
                new_line_num += 1;
            }
            const skipped = part.len - shown_count;
            if (skipped > 0) {
                try appendEllipsis(allocator, &output, line_num_width);
                old_line_num += skipped;
                new_line_num += skipped;
            }
        } else if (has_trailing_change) {
            const skipped = if (part.len > context_lines) part.len - context_lines else 0;
            if (skipped > 0) {
                try appendEllipsis(allocator, &output, line_num_width);
                old_line_num += skipped;
                new_line_num += skipped;
            }
            for (part[skipped..]) |line| {
                try appendNumberedLine(allocator, &output, ' ', old_line_num, line_num_width, line.text);
                old_line_num += 1;
                new_line_num += 1;
            }
        } else {
            old_line_num += part.len;
            new_line_num += part.len;
        }
        last_was_change = false;
    }

    return .{
        .diff = try output.toOwnedSlice(allocator),
        .first_changed_line = first_changed_line,
    };
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, line);
    }
    if (lines.items.len != 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines;
}

const DiffLineList = struct {
    items: []DiffLine,

    fn deinit(self: *DiffLineList, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

fn buildLineDiff(allocator: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) !DiffLineList {
    const width = new_lines.len + 1;
    const table = try allocator.alloc(usize, (old_lines.len + 1) * (new_lines.len + 1));
    defer allocator.free(table);
    @memset(table, 0);

    var old_index = old_lines.len;
    while (old_index > 0) {
        old_index -= 1;
        var new_index = new_lines.len;
        while (new_index > 0) {
            new_index -= 1;
            const cell = old_index * width + new_index;
            if (std.mem.eql(u8, old_lines[old_index], new_lines[new_index])) {
                table[cell] = table[(old_index + 1) * width + new_index + 1] + 1;
            } else {
                table[cell] = @max(table[(old_index + 1) * width + new_index], table[old_index * width + new_index + 1]);
            }
        }
    }

    var lines: std.ArrayList(DiffLine) = .empty;
    errdefer lines.deinit(allocator);

    var i: usize = 0;
    var j: usize = 0;
    while (i < old_lines.len and j < new_lines.len) {
        if (std.mem.eql(u8, old_lines[i], new_lines[j])) {
            try lines.append(allocator, .{ .kind = .context, .text = old_lines[i] });
            i += 1;
            j += 1;
        } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
            try lines.append(allocator, .{ .kind = .removed, .text = old_lines[i] });
            i += 1;
        } else {
            try lines.append(allocator, .{ .kind = .added, .text = new_lines[j] });
            j += 1;
        }
    }
    while (i < old_lines.len) : (i += 1) {
        try lines.append(allocator, .{ .kind = .removed, .text = old_lines[i] });
    }
    while (j < new_lines.len) : (j += 1) {
        try lines.append(allocator, .{ .kind = .added, .text = new_lines[j] });
    }

    return .{ .items = try lines.toOwnedSlice(allocator) };
}

fn decimalWidth(value: usize) usize {
    var width: usize = 1;
    var remaining = value;
    while (remaining >= 10) : (remaining /= 10) width += 1;
    return width;
}

fn appendNumberedLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    prefix: u8,
    line_number: usize,
    width: usize,
    text: []const u8,
) !void {
    if (output.items.len != 0) try output.append(allocator, '\n');
    try output.append(allocator, prefix);
    var number_buffer: [32]u8 = undefined;
    const number = try std.fmt.bufPrint(&number_buffer, "{d}", .{line_number});
    var padding = width - number.len;
    while (padding > 0) : (padding -= 1) try output.append(allocator, ' ');
    try output.appendSlice(allocator, number);
    try output.append(allocator, ' ');
    try output.appendSlice(allocator, text);
}

fn appendEllipsis(allocator: std.mem.Allocator, output: *std.ArrayList(u8), width: usize) !void {
    if (output.items.len != 0) try output.append(allocator, '\n');
    try output.append(allocator, ' ');
    var padding = width;
    while (padding > 0) : (padding -= 1) try output.append(allocator, ' ');
    try output.appendSlice(allocator, " ...");
}

pub fn computeEditsDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    edits: []const Edit,
    cwd: []const u8,
) !EditDiffResult {
    const absolute_path = try common.resolvePath(allocator, cwd, path);
    defer allocator.free(absolute_path);

    const raw_content = std.Io.Dir.readFileAlloc(.cwd(), io, absolute_path, allocator, .unlimited) catch |err| {
        return .{ .err = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. Error code: {s}.", .{ path, @errorName(err) }) };
    };
    defer allocator.free(raw_content);

    const stripped = stripBom(raw_content);
    const normalized_content = try normalizeToLf(allocator, stripped.text);
    defer allocator.free(normalized_content);

    var applied = applyEditsToNormalizedContent(allocator, normalized_content, edits, path) catch |err| {
        return .{ .err = try editErrorMessage(allocator, err, path, edits.len) };
    };
    defer applied.deinit(allocator);

    return .{ .success = try generateDiffString(allocator, applied.base_content, applied.new_content, 4) };
}

pub fn computeEditDiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    cwd: []const u8,
) !EditDiffResult {
    return computeEditsDiff(allocator, io, path, &.{.{ .old_text = old_text, .new_text = new_text }}, cwd);
}

fn editErrorMessage(allocator: std.mem.Allocator, err: anyerror, path: []const u8, total_edits: usize) ![]u8 {
    return switch (err) {
        error.EmptyOldText => if (total_edits == 1)
            try std.fmt.allocPrint(allocator, "oldText must not be empty in {s}.", .{path})
        else
            try std.fmt.allocPrint(allocator, "An edit oldText must not be empty in {s}.", .{path}),
        error.TextNotFound => if (total_edits == 1)
            try std.fmt.allocPrint(allocator, "Could not find the exact text in {s}. The old text must match exactly including all whitespace and newlines.", .{path})
        else
            try std.fmt.allocPrint(allocator, "Could not find one or more edits in {s}. The oldText must match exactly including all whitespace and newlines.", .{path}),
        error.DuplicateText => if (total_edits == 1)
            try std.fmt.allocPrint(allocator, "Found multiple occurrences of the text in {s}. The text must be unique. Please provide more context to make it unique.", .{path})
        else
            try std.fmt.allocPrint(allocator, "Found multiple occurrences of an edit in {s}. Each oldText must be unique. Please provide more context to make it unique.", .{path}),
        error.NoChange => if (total_edits == 1)
            try std.fmt.allocPrint(allocator, "No changes made to {s}. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.", .{path})
        else
            try std.fmt.allocPrint(allocator, "No changes made to {s}. The replacements produced identical content.", .{path}),
        error.OverlappingEdits => try std.fmt.allocPrint(allocator, "Edits overlap in {s}. Merge them into one edit or target disjoint regions.", .{path}),
        else => try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
}

test "edit diff normalizes line endings and strips bom" {
    const allocator = std.testing.allocator;
    const raw = utf8_bom ++ "a\r\nb\r\n";
    const stripped = stripBom(raw);
    try std.testing.expectEqualStrings(utf8_bom, stripped.bom);
    const normalized = try normalizeToLf(allocator, stripped.text);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("a\nb\n", normalized);
    const restored = try restoreLineEndings(allocator, normalized, detectLineEnding(stripped.text));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("a\r\nb\r\n", restored);
}

test "edit diff fuzzy matching normalizes quotes dashes and spaces" {
    const allocator = std.testing.allocator;
    var match = try fuzzyFindText(allocator, "alpha \xe2\x80\x9cquoted\xe2\x80\x9d\xe2\x80\x94word\xc2\xa0 \n", "alpha \"quoted\"-word");
    defer match.deinit(allocator);
    try std.testing.expect(match.found);
    try std.testing.expect(match.used_fuzzy_match);
    try std.testing.expectEqualStrings("alpha \"quoted\"-word", match.content_for_replacement[match.index .. match.index + match.match_length]);
}

test "edit diff applies disjoint edits against original content" {
    const allocator = std.testing.allocator;
    var applied = try applyEditsToNormalizedContent(allocator, "first old\nsecond old\n", &.{
        .{ .old_text = "first old", .new_text = "first new" },
        .{ .old_text = "second old", .new_text = "second new" },
    }, "sample.txt");
    defer applied.deinit(allocator);
    try std.testing.expectEqualStrings("first new\nsecond new\n", applied.new_content);
}

test "edit diff generates numbered context diff" {
    const allocator = std.testing.allocator;
    var result = try generateDiffString(allocator, "a\nb\nc\n", "a\nB\nc\n", 1);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, 2), result.first_changed_line);
    try std.testing.expect(std.mem.indexOf(u8, result.diff, "-2 b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.diff, "+2 B") != null);
}
