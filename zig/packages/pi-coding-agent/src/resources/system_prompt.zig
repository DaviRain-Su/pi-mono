const std = @import("std");
const agent = @import("agent");
const context_files_mod = @import("context_files.zig");
const resources_mod = @import("resources.zig");
const tool_selection_mod = @import("../tool_selection.zig");

fn normalizePathForPrompt(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var has_backslash = false;
    for (path) |c| {
        if (c == '\\') {
            has_backslash = true;
            break;
        }
    }
    if (!has_backslash) return allocator.dupe(u8, path);
    const buf = try allocator.alloc(u8, path.len);
    for (path, 0..) |c, i| {
        buf[i] = if (c == '\\') '/' else c;
    }
    return buf;
}

const BUILTIN_TOOLS = [_]ToolInfo{
    .{ .name = "read", .description = "Read file contents" },
    .{ .name = "bash", .description = "Execute shell commands" },
    .{ .name = "edit", .description = "Edit files with exact text replacement" },
    .{ .name = "write", .description = "Write files and create parent directories" },
    .{ .name = "grep", .description = "Search file contents with ripgrep" },
    .{ .name = "find", .description = "Find files by glob pattern" },
    .{ .name = "ls", .description = "List directory contents" },
};

const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
};

pub const BuildSystemPromptOptions = struct {
    cwd: []const u8,
    current_date: []const u8,
    custom_prompt: ?[]const u8 = null,
    append_prompts: []const []const u8 = &.{},
    tool_selection: tool_selection_mod.ToolSelection = .{},
    /// Active tool metadata constructed for the session. When present this is
    /// authoritative for prompt-visible non-builtin tools, including
    /// extension descriptions and JSON schemas.
    active_tools: []const agent.AgentTool = &.{},
    /// Compatibility field for unit tests and legacy call sites. When set,
    /// it is interpreted as the normal allowlist with builtin tools enabled.
    selected_tools: ?[]const []const u8 = null,
    context_files: []const context_files_mod.ContextFile = &.{},
    skills: []const resources_mod.Skill = &.{},
};

pub fn buildSystemPrompt(allocator: std.mem.Allocator, options: BuildSystemPromptOptions) ![]u8 {
    const selection = effectiveToolSelection(options);
    var prompt = std.ArrayList(u8).empty;
    defer prompt.deinit(allocator);

    if (options.custom_prompt) |custom_prompt| {
        try prompt.appendSlice(allocator, custom_prompt);
    } else {
        try prompt.appendSlice(allocator, "You are an expert coding assistant operating inside pi, a coding agent harness.\n\n");
        try prompt.appendSlice(allocator, "Available tools:\n");
        try appendToolSection(allocator, &prompt, selection, options.active_tools);
        try prompt.appendSlice(allocator, "\n\nGuidelines:\n");
        try appendGuidelines(allocator, &prompt, selection);
    }

    for (options.append_prompts) |append_prompt| {
        try prompt.appendSlice(allocator, "\n\n");
        try prompt.appendSlice(allocator, append_prompt);
    }

    if (options.context_files.len > 0) {
        try appendContextFiles(allocator, &prompt, options.context_files);
    }

    if (hasTool(selection, "read") and options.skills.len > 0) {
        const skills_text = try resources_mod.formatSkillsForPrompt(allocator, options.skills);
        defer allocator.free(skills_text);
        if (skills_text.len > 0) {
            try prompt.appendSlice(allocator, skills_text);
        }
    }

    try prompt.appendSlice(allocator, "\n\nCurrent date: ");
    try prompt.appendSlice(allocator, options.current_date);
    try prompt.appendSlice(allocator, "\nCurrent working directory: ");
    if (@import("builtin").os.tag == .windows) {
        const normalized = try normalizePathForPrompt(allocator, options.cwd);
        defer allocator.free(normalized);
        try prompt.appendSlice(allocator, normalized);
    } else {
        try prompt.appendSlice(allocator, options.cwd);
    }

    return try prompt.toOwnedSlice(allocator);
}

fn appendToolSection(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    selection: tool_selection_mod.ToolSelection,
    active_tools: []const agent.AgentTool,
) !void {
    if (selection.allowlist) |tools| {
        var appended: usize = 0;
        for (tools) |tool_name| {
            if (findAllowedActiveTool(active_tools, tool_name, selection)) |active_tool| {
                if (appended > 0) try prompt.appendSlice(allocator, "\n");
                try appendActiveToolLine(allocator, prompt, active_tool);
                appended += 1;
                continue;
            }
            const info = findTool(tool_name);
            if (info != null and !selection.allowsBuiltin(tool_name)) continue;
            if (info == null and !selection.allowsExtension(tool_name)) continue;
            if (appended > 0) try prompt.appendSlice(allocator, "\n");
            try appendToolLine(allocator, prompt, info orelse ToolInfo{
                .name = tool_name,
                .description = "Custom tool available in this environment",
            });
            appended += 1;
        }
        if (appended == 0) {
            try prompt.appendSlice(allocator, "(none)");
        }
        return;
    }

    if (selection.disable_all) {
        try prompt.appendSlice(allocator, "(none)");
        return;
    }

    if (active_tools.len > 0) {
        var appended: usize = 0;
        for (active_tools) |tool| {
            if (!selectionAllowsActiveTool(selection, tool)) continue;
            if (appended > 0) try prompt.appendSlice(allocator, "\n");
            try appendActiveToolLine(allocator, prompt, tool);
            appended += 1;
        }
        if (appended == 0) {
            try prompt.appendSlice(allocator, "(none)");
        }
        return;
    }

    if (!selection.include_builtins) {
        try prompt.appendSlice(allocator, "(none)");
        return;
    }

    for (BUILTIN_TOOLS, 0..) |tool, index| {
        if (index > 0) try prompt.appendSlice(allocator, "\n");
        try appendToolLine(allocator, prompt, tool);
    }
}

fn appendToolLine(allocator: std.mem.Allocator, prompt: *std.ArrayList(u8), info: ToolInfo) !void {
    try prompt.appendSlice(allocator, "- ");
    try prompt.appendSlice(allocator, info.name);
    try prompt.appendSlice(allocator, ": ");
    try prompt.appendSlice(allocator, info.description);
}

fn appendActiveToolLine(allocator: std.mem.Allocator, prompt: *std.ArrayList(u8), tool: agent.AgentTool) !void {
    try appendToolLine(allocator, prompt, .{
        .name = tool.name,
        .description = tool.description,
    });
    if (tool.source != .builtin) {
        try prompt.appendSlice(allocator, "\n  schema: ");
        try appendJsonValue(allocator, prompt, tool.parameters);
    }
}

fn appendJsonValue(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    value: std.json.Value,
) !void {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    try std.json.Stringify.value(value, .{}, &buffer.writer);
    try prompt.appendSlice(allocator, buffer.written());
}

fn appendGuidelines(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    selection: tool_selection_mod.ToolSelection,
) !void {
    try prompt.appendSlice(allocator, "- Use the available tools when they help answer the user's request.\n");

    if (hasAnyTool(selection, &.{ "grep", "find", "ls" })) {
        try prompt.appendSlice(allocator, "- Prefer grep/find/ls over bash for repository exploration when those tools are available.\n");
    } else if (hasTool(selection, "bash")) {
        try prompt.appendSlice(allocator, "- Use bash for repository exploration when dedicated search tools are unavailable.\n");
    }

    try prompt.appendSlice(allocator, "- Be concise in your responses.\n");
    try prompt.appendSlice(allocator, "- Show file paths clearly when referring to project files.");
}

fn appendContextFiles(
    allocator: std.mem.Allocator,
    prompt: *std.ArrayList(u8),
    context_files: []const context_files_mod.ContextFile,
) !void {
    try prompt.appendSlice(allocator, "\n\n# Project Context\n\n");
    try prompt.appendSlice(allocator, "Project-specific instructions and guidelines:\n\n");
    for (context_files) |context_file| {
        try prompt.appendSlice(allocator, "## ");
        try prompt.appendSlice(allocator, context_file.path);
        try prompt.appendSlice(allocator, "\n\n");
        try prompt.appendSlice(allocator, context_file.content);
        try prompt.appendSlice(allocator, "\n\n");
    }
}

fn hasAnyTool(selection: tool_selection_mod.ToolSelection, names: []const []const u8) bool {
    for (names) |name| {
        if (hasTool(selection, name)) return true;
    }
    return false;
}

fn hasTool(selection: tool_selection_mod.ToolSelection, name: []const u8) bool {
    return selection.allowsBuiltin(name) and findTool(name) != null;
}

fn findTool(name: []const u8) ?ToolInfo {
    for (BUILTIN_TOOLS) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn findAllowedActiveTool(
    active_tools: []const agent.AgentTool,
    name: []const u8,
    selection: tool_selection_mod.ToolSelection,
) ?agent.AgentTool {
    for (active_tools) |tool| {
        if (std.mem.eql(u8, tool.name, name) and selectionAllowsActiveTool(selection, tool)) return tool;
    }
    return null;
}

fn selectionAllowsActiveTool(selection: tool_selection_mod.ToolSelection, tool: agent.AgentTool) bool {
    return switch (tool.source) {
        .builtin => selection.allowsBuiltin(tool.name),
        .extension, .custom => selection.allowsExtension(tool.name),
    };
}

fn effectiveToolSelection(options: BuildSystemPromptOptions) tool_selection_mod.ToolSelection {
    if (options.selected_tools) |selected_tools| {
        return tool_selection_mod.ToolSelection.fromAllowlist(selected_tools);
    }
    return options.tool_selection;
}

test "default system prompt includes tools, guidelines, date, and cwd" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Available tools:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read: Read file contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- bash: Execute shell commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- grep: Search file contents with ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Guidelines:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current date: 2026-04-24") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current working directory: /tmp/project") != null);
}

test "custom system prompt replaces default and appends extra text" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .custom_prompt = "You are a terse assistant.",
        .append_prompts = &.{"Prefer short answers."},
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "You are a terse assistant.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Prefer short answers.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Available tools:") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current date: 2026-04-24") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current working directory: /tmp/project") != null);
}

test "system prompt appends repeatable extra text in order" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .custom_prompt = "Base prompt.",
        .append_prompts = &.{ "First appended chunk.", "Second appended chunk." },
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    const first_index_opt = std.mem.indexOf(u8, prompt, "First appended chunk.");
    const second_index_opt = std.mem.indexOf(u8, prompt, "Second appended chunk.");
    try std.testing.expect(first_index_opt != null);
    try std.testing.expect(second_index_opt != null);
    const first_index = first_index_opt.?;
    const second_index = second_index_opt.?;
    try std.testing.expect(first_index < second_index);
}

test "selected tools limit the visible tool list" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .selected_tools = &.{ "read", "ls" },
        .current_date = "2026-04-24",
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read: Read file contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- ls: List directory contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- bash: Execute shell commands") == null);
}

test "tool selection distinguishes no-tools and no-builtin-tools in prompt" {
    const allocator = std.testing.allocator;

    const colliding_extension_tool = agent.AgentTool{
        .name = "read",
        .description = "Extension read implementation",
        .label = "Extension Read",
        .parameters = .null,
        .source = .extension,
    };
    const builtin_read_tool = agent.AgentTool{
        .name = "read",
        .description = "Read file contents",
        .label = "read",
        .parameters = .null,
        .source = .builtin,
    };

    const no_tools_prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .tool_selection = tool_selection_mod.ToolSelection.fromCli(true, false, null),
        .active_tools = &.{colliding_extension_tool},
        .current_date = "2026-04-24",
    });
    defer allocator.free(no_tools_prompt);
    try std.testing.expect(std.mem.indexOf(u8, no_tools_prompt, "Available tools:\n(none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_tools_prompt, "- read: Read file contents") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_tools_prompt, "- read: Extension read implementation") == null);

    const no_builtin_prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .tool_selection = tool_selection_mod.ToolSelection.fromCli(false, true, &.{"ext-echo"}),
        .current_date = "2026-04-24",
    });
    defer allocator.free(no_builtin_prompt);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- ext-echo: Custom tool available in this environment") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_builtin_prompt, "- read: Read file contents") == null);

    const colliding_no_builtin_prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .tool_selection = tool_selection_mod.ToolSelection.fromCli(false, true, null),
        .active_tools = &.{ colliding_extension_tool, builtin_read_tool },
        .current_date = "2026-04-24",
    });
    defer allocator.free(colliding_no_builtin_prompt);
    try std.testing.expect(std.mem.indexOf(u8, colliding_no_builtin_prompt, "- read: Extension read implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, colliding_no_builtin_prompt, "schema: null") != null);
    try std.testing.expect(std.mem.indexOf(u8, colliding_no_builtin_prompt, "- read: Read file contents") == null);
    try std.testing.expect(std.mem.indexOf(u8, colliding_no_builtin_prompt, "Available tools:\n(none)") == null);

    const colliding_allowlist_prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .tool_selection = tool_selection_mod.ToolSelection.fromCli(false, true, &.{"read"}),
        .active_tools = &.{ colliding_extension_tool, builtin_read_tool },
        .current_date = "2026-04-24",
    });
    defer allocator.free(colliding_allowlist_prompt);
    try std.testing.expect(std.mem.indexOf(u8, colliding_allowlist_prompt, "- read: Extension read implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, colliding_allowlist_prompt, "- read: Read file contents") == null);
}

test "system prompt appends project context files and skills when read is available" {
    const allocator = std.testing.allocator;

    const context_files = [_]context_files_mod.ContextFile{
        .{
            .path = "/tmp/project/AGENTS.md",
            .content = "Use ripgrep first.",
        },
    };
    const skills = [_]resources_mod.Skill{
        .{
            .name = @constCast("reviewer"),
            .description = @constCast("Review changes for correctness"),
            .file_path = @constCast("/tmp/project/.pi/skills/reviewer/SKILL.md"),
            .base_dir = @constCast("/tmp/project/.pi/skills/reviewer"),
            .source_info = .{
                .path = @constCast("/tmp/project/.pi/skills/reviewer/SKILL.md"),
                .source = @constCast("local"),
                .scope = .project,
                .origin = .top_level,
                .base_dir = @constCast("/tmp/project/.pi/skills/reviewer"),
            },
        },
    };

    const prompt = try buildSystemPrompt(allocator, .{
        .cwd = "/tmp/project",
        .current_date = "2026-04-24",
        .selected_tools = &.{ "read", "ls" },
        .context_files = &context_files,
        .skills = &skills,
    });
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Project Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## /tmp/project/AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use ripgrep first.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<name>reviewer</name>") != null);
}
