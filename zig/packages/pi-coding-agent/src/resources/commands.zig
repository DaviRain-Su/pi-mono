const std = @import("std");
const resource_types = @import("types.zig");
const frontmatter = @import("frontmatter.zig");
const file_helpers = @import("file_helpers.zig");

const Skill = resource_types.Skill;
const PromptTemplate = resource_types.PromptTemplate;
const parseFrontmatter = frontmatter.parseFrontmatter;
const readOptionalFile = file_helpers.readOptionalFile;

pub fn formatSkillsForPrompt(allocator: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var visible_count: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible_count += 1;
    }
    if (visible_count == 0) return allocator.dupe(u8, "");

    try builder.appendSlice(allocator, "\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try builder.appendSlice(allocator, "Use the read tool to load a skill's file when the task matches its description.\n");
    try builder.appendSlice(allocator, "When a skill file references a relative path, resolve it against the skill directory and use that absolute path in tool commands.\n\n");
    try builder.appendSlice(allocator, "<available_skills>\n");

    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try builder.appendSlice(allocator, "  <skill>\n");
        const escaped_name = try escapeXmlAlloc(allocator, skill.name);
        defer allocator.free(escaped_name);
        const name_line = try std.fmt.allocPrint(allocator, "    <name>{s}</name>\n", .{escaped_name});
        defer allocator.free(name_line);
        try builder.appendSlice(allocator, name_line);
        const escaped_description = try escapeXmlAlloc(allocator, skill.description);
        defer allocator.free(escaped_description);
        const description_line = try std.fmt.allocPrint(allocator, "    <description>{s}</description>\n", .{escaped_description});
        defer allocator.free(description_line);
        try builder.appendSlice(allocator, description_line);
        const escaped_location = try escapeXmlAlloc(allocator, skill.file_path);
        defer allocator.free(escaped_location);
        const location_line = try std.fmt.allocPrint(allocator, "    <location>{s}</location>\n", .{escaped_location});
        defer allocator.free(location_line);
        try builder.appendSlice(allocator, location_line);
        try builder.appendSlice(allocator, "  </skill>\n");
    }
    try builder.appendSlice(allocator, "</available_skills>");
    return try builder.toOwnedSlice(allocator);
}

pub fn parseCommandArgs(allocator: std.mem.Allocator, args_string: []const u8) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    errdefer args.deinit(allocator);
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);
    var in_quote: ?u8 = null;

    for (args_string) |char| {
        if (in_quote) |quote| {
            if (char == quote) {
                in_quote = null;
            } else {
                try current.append(allocator, char);
            }
            continue;
        }

        // Mirror TS fix(coding-agent) #4553: split on any whitespace, not
        // just space/tab — multi-line prompt template args should also
        // tokenize at newline/CR boundaries.
        if (char == '"' or char == '\'') {
            in_quote = char;
        } else if (std.ascii.isWhitespace(char)) {
            if (current.items.len > 0) {
                try args.append(allocator, try current.toOwnedSlice(allocator));
                current = .empty;
            }
        } else {
            try current.append(allocator, char);
        }
    }

    if (current.items.len > 0) {
        try args.append(allocator, try current.toOwnedSlice(allocator));
    }

    return try args.toOwnedSlice(allocator);
}

pub const freeParsedArgs = @import("../slice_utils.zig").freeStringSlice;

pub fn substituteArgs(allocator: std.mem.Allocator, content: []const u8, args: []const []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] != '$') {
            try builder.append(allocator, content[i]);
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, content[i..], "$ARGUMENTS")) {
            try appendJoinedArgs(allocator, &builder, args, 0, null);
            i += "$ARGUMENTS".len;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "$@")) {
            try appendJoinedArgs(allocator, &builder, args, 0, null);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "${@:")) {
            if (parseSlicePlaceholder(content[i..])) |placeholder| {
                try appendJoinedArgs(allocator, &builder, args, placeholder.start_index, placeholder.length);
                i += placeholder.consumed_len;
                continue;
            }
        }

        if (i + 1 < content.len and std.ascii.isDigit(content[i + 1])) {
            var end = i + 1;
            while (end < content.len and std.ascii.isDigit(content[end])) : (end += 1) {}
            const index = try std.fmt.parseInt(usize, content[i + 1 .. end], 10);
            if (index > 0 and index <= args.len) {
                try builder.appendSlice(allocator, args[index - 1]);
            }
            i = end;
            continue;
        }

        try builder.append(allocator, '$');
        i += 1;
    }

    return try builder.toOwnedSlice(allocator);
}

pub fn expandPromptTemplate(allocator: std.mem.Allocator, text: []const u8, templates: []const PromptTemplate) ![]u8 {
    if (text.len == 0 or text[0] != '/') return allocator.dupe(u8, text);
    // Mirror TS fix(coding-agent) #4553: split at the first whitespace (not
    // just ' ') so multi-line prompt template args after `/cmd\n...` are
    // parsed correctly, and skip the contiguous whitespace block before
    // the args body so `/cmd  arg` and `/cmd\n\targ` both work.
    var name_end: usize = text.len;
    for (text[1..], 1..) |ch, idx| {
        if (std.ascii.isWhitespace(ch)) {
            name_end = idx;
            break;
        }
    }
    const template_name = text[1..name_end];
    var args_start = name_end;
    while (args_start < text.len and std.ascii.isWhitespace(text[args_start])) : (args_start += 1) {}
    const args_string = text[args_start..];
    for (templates) |template| {
        if (!std.mem.eql(u8, template.name, template_name)) continue;
        const args = try parseCommandArgs(allocator, args_string);
        defer freeParsedArgs(allocator, args);
        return substituteArgs(allocator, template.content, args);
    }
    return allocator.dupe(u8, text);
}

pub fn expandSkillCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    skills: []const Skill,
) ![]u8 {
    if (!std.mem.startsWith(u8, text, "/skill:")) return allocator.dupe(u8, text);

    const space_index = std.mem.indexOfScalar(u8, text, ' ');
    const skill_name = if (space_index) |value| text["/skill:".len..value] else text["/skill:".len..];
    const args = if (space_index) |value| std.mem.trim(u8, text[value + 1 ..], " \t\r\n") else "";

    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, skill_name)) continue;

        const bytes = readOptionalFile(allocator, io, skill.file_path) catch {
            return allocator.dupe(u8, text);
        };
        defer if (bytes) |value| allocator.free(value);
        if (bytes == null) return allocator.dupe(u8, text);

        const parsed = parseFrontmatter(allocator, bytes.?) catch {
            return allocator.dupe(u8, text);
        };
        defer parsed.deinit(allocator);

        const body = std.mem.trim(u8, parsed.body, " \t\r\n");
        if (args.len > 0) {
            return std.fmt.allocPrint(
                allocator,
                "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>\n\n{s}",
                .{ skill.name, skill.file_path, skill.base_dir, body, args },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>",
            .{ skill.name, skill.file_path, skill.base_dir, body },
        );
    }

    return allocator.dupe(u8, text);
}

const SlicePlaceholder = struct {
    start_index: usize,
    length: ?usize,
    consumed_len: usize,
};

fn parseSlicePlaceholder(text: []const u8) ?SlicePlaceholder {
    var index: usize = "${@:".len;
    var end = index;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == index or end >= text.len) return null;
    const start_value = std.fmt.parseInt(usize, text[index..end], 10) catch return null;
    var length: ?usize = null;
    index = end;
    if (index < text.len and text[index] == ':') {
        index += 1;
        end = index;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        if (end == index) return null;
        length = std.fmt.parseInt(usize, text[index..end], 10) catch return null;
        index = end;
    }
    if (index >= text.len or text[index] != '}') return null;
    return .{
        .start_index = if (start_value == 0) 0 else start_value - 1,
        .length = length,
        .consumed_len = index + 1,
    };
}

fn appendJoinedArgs(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    args: []const []const u8,
    start_index: usize,
    length: ?usize,
) !void {
    const end_index = if (length) |value| @min(args.len, start_index + value) else args.len;
    for (args[start_index..end_index], 0..) |arg, index| {
        if (index > 0) try builder.append(allocator, ' ');
        try builder.appendSlice(allocator, arg);
    }
}

fn escapeXmlAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    for (text) |char| {
        switch (char) {
            '&' => try builder.appendSlice(allocator, "&amp;"),
            '<' => try builder.appendSlice(allocator, "&lt;"),
            '>' => try builder.appendSlice(allocator, "&gt;"),
            '"' => try builder.appendSlice(allocator, "&quot;"),
            '\'' => try builder.appendSlice(allocator, "&apos;"),
            else => try builder.append(allocator, char),
        }
    }
    return try builder.toOwnedSlice(allocator);
}
