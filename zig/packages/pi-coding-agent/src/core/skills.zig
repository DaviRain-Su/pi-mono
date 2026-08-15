const std = @import("std");
const frontmatter = @import("../utils/frontmatter.zig");
const source_info = @import("source_info.zig");

pub const MAX_NAME_LENGTH: usize = 64;
pub const MAX_DESCRIPTION_LENGTH: usize = 1024;

pub const ResourceDiagnostic = struct {
    kind: []const u8 = "warning",
    message: []const u8,
    path: ?[]const u8 = null,
};

pub const SkillFrontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    disable_model_invocation: bool = false,
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    file_path: []const u8,
    base_dir: []const u8,
    source_info: source_info.SourceInfo,
    disable_model_invocation: bool = false,
};

pub const LoadSkillsResult = struct {
    skills: []Skill = &.{},
    diagnostics: []ResourceDiagnostic = &.{},
};

pub const LoadSkillsFromDirOptions = struct {
    dir: []const u8,
    source: []const u8,
};

pub const LoadSkillsOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    skill_paths: []const []const u8 = &.{},
    include_defaults: bool = true,
};

pub fn validateName(allocator: std.mem.Allocator, name: []const u8) ![][]u8 {
    var errors: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, errors.items);
    if (name.len > MAX_NAME_LENGTH) {
        try errors.append(allocator, try std.fmt.allocPrint(allocator, "name exceeds {d} characters ({d})", .{ MAX_NAME_LENGTH, name.len }));
    }
    if (!isValidSkillNameCharacters(name)) {
        try errors.append(allocator, try allocator.dupe(u8, "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)"));
    }
    if (name.len > 0 and (name[0] == '-' or name[name.len - 1] == '-')) {
        try errors.append(allocator, try allocator.dupe(u8, "name must not start or end with a hyphen"));
    }
    if (std.mem.indexOf(u8, name, "--") != null) {
        try errors.append(allocator, try allocator.dupe(u8, "name must not contain consecutive hyphens"));
    }
    return errors.toOwnedSlice(allocator);
}

pub fn validateDescription(allocator: std.mem.Allocator, description: ?[]const u8) ![][]u8 {
    var errors: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, errors.items);
    const value = description orelse "";
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) {
        try errors.append(allocator, try allocator.dupe(u8, "description is required"));
    } else if (value.len > MAX_DESCRIPTION_LENGTH) {
        try errors.append(allocator, try std.fmt.allocPrint(allocator, "description exceeds {d} characters ({d})", .{ MAX_DESCRIPTION_LENGTH, value.len }));
    }
    return errors.toOwnedSlice(allocator);
}

pub fn loadSkillFromContent(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    base_dir: []const u8,
    parent_dir_name: []const u8,
    source: []const u8,
    content: []const u8,
) !struct { skill: ?Skill, diagnostics: []ResourceDiagnostic } {
    var parsed = try frontmatter.parseFrontmatter(allocator, content);
    defer parsed.deinit(allocator);
    const metadata = parseSkillFrontmatter(parsed.yaml_string orelse "");
    var diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    const desc_errors = try validateDescription(allocator, metadata.description);
    defer allocator.free(desc_errors);
    for (desc_errors) |message| try diagnostics.append(allocator, .{ .message = message, .path = file_path });

    const name = metadata.name orelse parent_dir_name;
    const name_errors = try validateName(allocator, name);
    defer allocator.free(name_errors);
    for (name_errors) |message| try diagnostics.append(allocator, .{ .message = message, .path = file_path });

    const description = metadata.description orelse "";
    if (std.mem.trim(u8, description, " \t\r\n").len == 0) {
        return .{ .skill = null, .diagnostics = try diagnostics.toOwnedSlice(allocator) };
    }
    const owned_file_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_file_path);
    const owned_base_dir = try allocator.dupe(u8, base_dir);
    errdefer allocator.free(owned_base_dir);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);

    return .{
        .skill = .{
            .name = owned_name,
            .description = owned_description,
            .file_path = owned_file_path,
            .base_dir = owned_base_dir,
            .source_info = createSkillSourceInfo(owned_file_path, owned_base_dir, source),
            .disable_model_invocation = metadata.disable_model_invocation,
        },
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn formatSkillsForPrompt(allocator: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var visible_count: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible_count += 1;
    }
    if (visible_count == 0) return allocator.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(
        "\n\nThe following skills provide specialized instructions for specific tasks.\n" ++
            "Use the read tool to load a skill's file when the task matches its description.\n" ++
            "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n" ++
            "<available_skills>",
    );
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try out.writer.writeAll("\n  <skill>\n    <name>");
        try escapeXml(&out.writer, skill.name);
        try out.writer.writeAll("</name>\n    <description>");
        try escapeXml(&out.writer, skill.description);
        try out.writer.writeAll("</description>\n    <location>");
        try escapeXml(&out.writer, skill.file_path);
        try out.writer.writeAll("</location>\n  </skill>");
    }
    try out.writer.writeAll("\n</available_skills>");
    return out.toOwnedSlice();
}

fn parseSkillFrontmatter(yaml: []const u8) SkillFrontmatter {
    var result: SkillFrontmatter = .{};
    var lines = std.mem.splitScalar(u8, yaml, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = trimYamlScalar(trimmed[colon + 1 ..]);
            if (std.mem.eql(u8, key, "name")) {
                result.name = value;
            } else if (std.mem.eql(u8, key, "description")) {
                result.description = value;
            } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
                result.disable_model_invocation = std.mem.eql(u8, value, "true");
            }
        }
    }
    return result;
}

fn trimYamlScalar(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            trimmed = trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

fn createSkillSourceInfo(file_path: []const u8, base_dir: []const u8, source: []const u8) source_info.SourceInfo {
    if (std.mem.eql(u8, source, "user")) {
        return source_info.createSyntheticSourceInfo(file_path, .{ .source = "local", .scope = .user, .base_dir = base_dir });
    }
    if (std.mem.eql(u8, source, "project")) {
        return source_info.createSyntheticSourceInfo(file_path, .{ .source = "local", .scope = .project, .base_dir = base_dir });
    }
    if (std.mem.eql(u8, source, "path")) {
        return source_info.createSyntheticSourceInfo(file_path, .{ .source = "local", .base_dir = base_dir });
    }
    return source_info.createSyntheticSourceInfo(file_path, .{ .source = source, .base_dir = base_dir });
}

fn isValidSkillNameCharacters(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if ((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-') continue;
        return false;
    }
    return true;
}

fn escapeXml(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(byte),
        }
    }
}

pub const freeStringList = @import("../slice_utils.zig").freeStringSlice;

pub fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: []ResourceDiagnostic) void {
    for (diagnostics) |diagnostic| allocator.free(diagnostic.message);
    allocator.free(diagnostics);
}

pub fn deinitSkill(allocator: std.mem.Allocator, skill: *Skill) void {
    allocator.free(skill.name);
    allocator.free(skill.description);
    allocator.free(skill.file_path);
    allocator.free(skill.base_dir);
    skill.* = undefined;
}

test "validateName reports invalid skill names" {
    const allocator = std.testing.allocator;
    const errors = try validateName(allocator, "Bad--Name");
    defer freeStringList(allocator, errors);
    try std.testing.expect(errors.len >= 2);
}

test "formatSkillsForPrompt emits XML and hides disabled skills" {
    const allocator = std.testing.allocator;
    const skills = [_]Skill{
        .{
            .name = "one",
            .description = "A <skill>",
            .file_path = "/tmp/one/SKILL.md",
            .base_dir = "/tmp/one",
            .source_info = source_info.createSyntheticSourceInfo("/tmp/one/SKILL.md", .{ .source = "test" }),
        },
        .{
            .name = "two",
            .description = "Hidden",
            .file_path = "/tmp/two/SKILL.md",
            .base_dir = "/tmp/two",
            .source_info = source_info.createSyntheticSourceInfo("/tmp/two/SKILL.md", .{ .source = "test" }),
            .disable_model_invocation = true,
        },
    };
    const prompt = try formatSkillsForPrompt(allocator, &skills);
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "&lt;skill&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Hidden") == null);
}
