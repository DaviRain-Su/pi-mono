const std = @import("std");
const ai = @import("ai");

pub const ASSISTANT_PREFIX = "Pi:";

pub fn formatPrefixedBlocks(allocator: std.mem.Allocator, prefix: []const u8, blocks: []const ai.ContentBlock) ![]u8 {
    const body = try blocksToText(allocator, blocks);
    defer allocator.free(body);
    return if (body.len == 0)
        std.fmt.allocPrint(allocator, "{s}:", .{prefix})
    else
        std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, body });
}

pub fn formatAssistantMessage(allocator: std.mem.Allocator, message: ai.AssistantMessage) ![]u8 {
    const body = try blocksToTextWithoutThinking(allocator, message.content);
    defer allocator.free(body);
    const trimmed_body = std.mem.trim(u8, body, " \t\r\n");
    const should_render_stop = !assistantHasToolCalls(message) and
        (message.stop_reason == .error_reason or message.stop_reason == .aborted);
    if (!should_render_stop) {
        return allocator.dupe(u8, trimmed_body);
    }

    const stop_text = if (message.stop_reason == .error_reason)
        try std.fmt.allocPrint(allocator, "Error: {s}", .{message.error_message orelse "Unknown error"})
    else if (message.error_message) |error_message|
        try allocator.dupe(u8, if (std.mem.eql(u8, error_message, "Request was aborted")) "Operation aborted" else error_message)
    else
        try allocator.dupe(u8, "Operation aborted");
    defer allocator.free(stop_text);

    if (trimmed_body.len == 0) {
        return allocator.dupe(u8, stop_text);
    }
    return try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ trimmed_body, stop_text });
}

pub fn formatToolCall(allocator: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]u8 {
    if (std.mem.eql(u8, name, "bash")) return formatBashToolCall(allocator, args);
    if (std.mem.eql(u8, name, "read")) return formatReadToolCall(allocator, args);
    if (std.mem.eql(u8, name, "write")) return formatWriteToolCall(allocator, args);
    if (std.mem.eql(u8, name, "edit")) return formatEditToolCall(allocator, args);
    if (isGateLikeTool(name)) return formatGateToolCall(allocator, name, args);

    const json = try std.json.Stringify.valueAlloc(allocator, args, .{});
    defer allocator.free(json);
    return try std.fmt.allocPrint(allocator, "Tool {s}: {s}", .{ name, json });
}

fn formatBashToolCall(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const command = getStringArg(args, "command");
    const timeout = getIntegerArg(args, "timeout") orelse getIntegerArg(args, "timeout_seconds");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "$ ");
    if (command) |value| {
        if (value.len == 0) {
            try out.appendSlice(allocator, "...");
        } else {
            try out.appendSlice(allocator, value);
        }
    } else {
        try out.appendSlice(allocator, "[invalid arg]");
    }
    if (timeout) |seconds| {
        try appendPrint(&out, allocator, " (timeout {d}s)", .{seconds});
    }
    return try out.toOwnedSlice(allocator);
}

pub fn formatStreamingToolCall(allocator: std.mem.Allocator, name: ?[]const u8, args_fragment: []const u8) ![]u8 {
    if (name) |tool_name| {
        return try std.fmt.allocPrint(allocator, "Tool {s}: {s}", .{ tool_name, args_fragment });
    }
    return try std.fmt.allocPrint(allocator, "Tool call: {s}", .{args_fragment});
}

pub fn formatToolResult(
    allocator: std.mem.Allocator,
    name: []const u8,
    blocks: []const ai.ContentBlock,
    is_error: bool,
    details: ?std.json.Value,
) ![]u8 {
    return formatToolResultWithExpansion(allocator, name, blocks, is_error, details, true);
}

pub fn formatToolResultWithExpansion(
    allocator: std.mem.Allocator,
    name: []const u8,
    blocks: []const ai.ContentBlock,
    is_error: bool,
    details: ?std.json.Value,
    expanded: bool,
) ![]u8 {
    const body = try blocksToText(allocator, blocks);
    defer allocator.free(body);
    const prefix = if (isGateLikeTool(name) or (is_error and looksLikeGateMessage(body)))
        "Gate blocked"
    else if (is_error)
        "Tool error"
    else if (std.mem.eql(u8, name, "read"))
        "Read result"
    else if (std.mem.eql(u8, name, "write"))
        "Write result"
    else if (std.mem.eql(u8, name, "edit"))
        "Edit result"
    else
        "Tool result";
    const base = try if (body.len == 0)
        std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, name })
    else if ((std.mem.eql(u8, prefix, "Tool result") or std.mem.eql(u8, prefix, "Tool error")) and
        std.mem.indexOfScalar(u8, body, '\n') == null)
        std.fmt.allocPrint(allocator, "{s} {s}: {s}", .{ prefix, name, body })
    else
        std.fmt.allocPrint(allocator, "{s} {s}:\n{s}", .{ prefix, name, body });
    defer allocator.free(base);

    return try appendToolDetails(allocator, name, base, details, expanded);
}

fn appendToolDetails(
    allocator: std.mem.Allocator,
    name: []const u8,
    base: []const u8,
    details: ?std.json.Value,
    expanded: bool,
) ![]u8 {
    if (!expanded) return allocator.dupe(u8, base);
    if (!std.mem.eql(u8, name, "bash")) return allocator.dupe(u8, base);
    const details_value = details orelse return allocator.dupe(u8, base);
    const rendered_details = try std.json.Stringify.valueAlloc(allocator, details_value, .{});
    defer allocator.free(rendered_details);
    return try std.fmt.allocPrint(allocator, "{s}\nDetails: {s}", .{ base, rendered_details });
}

fn formatReadToolCall(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const path = getStringArg(args, "path") orelse "(missing path)";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendPrint(&out, allocator, "Read {s}", .{path});
    if (getIntegerArg(args, "offset")) |offset| {
        try appendPrint(&out, allocator, " from line {d}", .{offset});
    }
    if (getIntegerArg(args, "limit")) |limit| {
        try appendPrint(&out, allocator, " limit {d}", .{limit});
    }
    return try out.toOwnedSlice(allocator);
}

fn formatWriteToolCall(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const path = getStringArg(args, "path") orelse "(missing path)";
    const content = getStringArg(args, "content") orelse "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendPrint(&out, allocator, "Write {s}\n+++ new\n", .{path});
    try appendPrefixedPreview(&out, allocator, "+", content);
    return try out.toOwnedSlice(allocator);
}

fn formatEditToolCall(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const path = getStringArg(args, "path") orelse "(missing path)";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendPrint(&out, allocator, "Edit {s}", .{path});
    var rendered_edit = false;

    if (args == .object) {
        if (args.object.get("edits")) |edits_value| {
            if (edits_value == .array) {
                for (edits_value.array.items, 0..) |edit_value, index| {
                    if (edit_value != .object) continue;
                    const old_text = getObjectString(edit_value.object, "oldText") orelse getObjectString(edit_value.object, "old_text") orelse "";
                    const new_text = getObjectString(edit_value.object, "newText") orelse getObjectString(edit_value.object, "new_text") orelse "";
                    try appendEditPreview(&out, allocator, index + 1, old_text, new_text);
                    rendered_edit = true;
                }
            }
        }

        const legacy_old = getObjectString(args.object, "oldText") orelse getObjectString(args.object, "old_text");
        const legacy_new = getObjectString(args.object, "newText") orelse getObjectString(args.object, "new_text");
        if (legacy_old != null or legacy_new != null) {
            try appendEditPreview(&out, allocator, 1, legacy_old orelse "", legacy_new orelse "");
            rendered_edit = true;
        }
    }

    if (!rendered_edit) {
        try out.appendSlice(allocator, "\n(no edit preview)");
    }
    return try out.toOwnedSlice(allocator);
}

fn formatGateToolCall(allocator: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, args, .{});
    defer allocator.free(json);
    return try std.fmt.allocPrint(allocator, "Gate {s}: {s}", .{ name, json });
}

fn appendEditPreview(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    index: usize,
    old_text: []const u8,
    new_text: []const u8,
) !void {
    try appendPrint(out, allocator, "\n@@ edit {d} @@\n--- old\n", .{index});
    try appendPrefixedPreview(out, allocator, "-", old_text);
    try out.appendSlice(allocator, "+++ new\n");
    try appendPrefixedPreview(out, allocator, "+", new_text);
}

fn appendPrefixedPreview(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    prefix: []const u8,
    text: []const u8,
) !void {
    if (text.len == 0) {
        try appendPrint(out, allocator, "{s}(empty)\n", .{prefix});
        return;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try appendPrint(out, allocator, "{s}{s}\n", .{ prefix, line });
    }
}

fn appendPrint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn getStringArg(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    return getObjectString(value.object, key);
}

fn getIntegerArg(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const raw = value.object.get(key) orelse return null;
    return switch (raw) {
        .integer => |integer| integer,
        else => null,
    };
}

test "tool result formatting preserves long previews for renderer collapse" {
    const allocator = std.testing.allocator;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    for (0..50) |index| {
        try appendPrint(&body, allocator, "line {d}\n", .{index + 1});
    }

    const blocks = [_]ai.ContentBlock{.{ .text = .{ .text = body.items } }};
    const formatted = try formatToolResultWithExpansion(allocator, "bash", &blocks, false, null, false);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "line 50") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "truncated preview") == null);
}

fn getObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .string => |string| string,
        else => null,
    };
}

fn isGateLikeTool(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "gate") != null or
        std.mem.indexOf(u8, name, "permission") != null or
        std.mem.indexOf(u8, name, "approval") != null;
}

fn looksLikeGateMessage(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "blocked") != null or
        std.mem.indexOf(u8, body, "denied") != null or
        std.mem.indexOf(u8, body, "permission") != null;
}

pub fn blocksToText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    return blocksToTextFiltered(allocator, blocks, true);
}

fn blocksToTextWithoutThinking(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    return blocksToTextFiltered(allocator, blocks, false);
}

fn blocksToTextFiltered(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock, include_thinking: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var appended = false;
    for (blocks) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (!include_thinking) continue;
                if (appended) try out.appendSlice(allocator, "\n");
                try out.appendSlice(allocator, thinking.thinking);
                appended = true;
            },
            .text => |text| {
                if (appended) try out.appendSlice(allocator, "\n");
                try out.appendSlice(allocator, text.text);
                appended = true;
            },
            .image => |image| {
                if (appended) try out.appendSlice(allocator, "\n");
                const note = try std.fmt.allocPrint(allocator, "[Image: [{s}]]", .{image.mime_type});
                defer allocator.free(note);
                try out.appendSlice(allocator, note);
                appended = true;
            },
            .tool_call => |tool_call| {
                if (appended) try out.appendSlice(allocator, "\n");
                try out.appendSlice(allocator, tool_call.name);
                appended = true;
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn assistantHasToolCalls(message: ai.AssistantMessage) bool {
    if (message.tool_calls) |tool_calls| {
        if (tool_calls.len > 0) return true;
    }
    for (message.content) |block| {
        if (block == .tool_call) return true;
    }
    return false;
}

test "formatAssistantMessage hides thinking blocks" {
    const allocator = std.testing.allocator;
    const blocks = [_]ai.ContentBlock{
        .{ .thinking = .{ .thinking = "internal reasoning" } },
        .{ .text = .{ .text = "visible answer" } },
    };
    const rendered = try formatAssistantMessage(allocator, .{
        .content = &blocks,
        .api = "openai-codex-responses",
        .provider = "openai-codex",
        .model = "gpt-5.5",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("visible answer", rendered);
}

test "formatAssistantMessage appends TS-equivalent abort and error text" {
    const allocator = std.testing.allocator;
    const text_blocks = [_]ai.ContentBlock{.{ .text = .{ .text = " partial answer \n" } }};
    const rendered_error = try formatAssistantMessage(allocator, .{
        .content = &text_blocks,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "boom",
        .timestamp = 0,
    });
    defer allocator.free(rendered_error);
    try std.testing.expectEqualStrings("partial answer\n\nError: boom", rendered_error);

    const rendered_abort = try formatAssistantMessage(allocator, .{
        .content = &[_]ai.ContentBlock{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .timestamp = 0,
    });
    defer allocator.free(rendered_abort);
    try std.testing.expectEqualStrings("Operation aborted", rendered_abort);
}

test "formatToolCall renders bash command like TS renderer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"command\":\"echo hi\",\"timeout\":2}", .{});
    defer parsed.deinit();

    const rendered = try formatToolCall(allocator, "bash", parsed.value);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("$ echo hi (timeout 2s)", rendered);
}

test "blocksToText renders deterministic image fallback" {
    const allocator = std.testing.allocator;
    const blocks = [_]ai.ContentBlock{.{ .image = .{ .mime_type = "image/png", .data = "abcd" } }};
    const rendered = try blocksToText(allocator, &blocks);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("[Image: [image/png]]", rendered);
}

test "formatToolCall renders read arguments as a concise status line" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"README.md\",\"offset\":2,\"limit\":5}", .{});
    defer parsed.deinit();

    const rendered = try formatToolCall(allocator, "read", parsed.value);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Read README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "from line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "{\"path\"") == null);
}

test "formatToolCall renders write and edit previews as comparisons" {
    const allocator = std.testing.allocator;
    const write_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"notes.txt\",\"content\":\"before\\nafter\"}", .{});
    defer write_args.deinit();

    const write_rendered = try formatToolCall(allocator, "write", write_args.value);
    defer allocator.free(write_rendered);
    try std.testing.expect(std.mem.indexOf(u8, write_rendered, "Write notes.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_rendered, "+++ new") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_rendered, "+before") != null);

    const edit_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"notes.txt\",\"oldText\":\"old line\",\"newText\":\"new line\"}", .{});
    defer edit_args.deinit();

    const edit_rendered = try formatToolCall(allocator, "edit", edit_args.value);
    defer allocator.free(edit_rendered);
    try std.testing.expect(std.mem.indexOf(u8, edit_rendered, "Edit notes.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_rendered, "--- old") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_rendered, "-old line") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_rendered, "+new line") != null);
}

test "formatToolResult highlights gate denials" {
    const allocator = std.testing.allocator;
    const blocks = [_]ai.ContentBlock{.{ .text = .{ .text = "permission denied by gate" } }};

    const rendered = try formatToolResult(allocator, "write", &blocks, true, null);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Gate blocked write") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "permission denied") != null);
}
