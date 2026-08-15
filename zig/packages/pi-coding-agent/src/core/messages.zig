const std = @import("std");
const ai = @import("ai");

pub const COMPACTION_SUMMARY_PREFIX =
    \\The conversation history before this point was compacted into the following summary:
    \\
    \\<summary>
    \\
;
pub const COMPACTION_SUMMARY_SUFFIX =
    \\
    \\</summary>
;
pub const BRANCH_SUMMARY_PREFIX =
    \\The following is a summary of a branch that this conversation came back from:
    \\
    \\<summary>
    \\
;
pub const BRANCH_SUMMARY_SUFFIX = "</summary>";

pub const BashExecutionMessage = struct {
    command: []const u8,
    output: []const u8,
    exit_code: ?i32 = null,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
    timestamp: i64,
    exclude_from_context: bool = false,
};

pub const CustomMessage = struct {
    custom_type: []const u8,
    content: []const u8,
    display: bool,
    details: ?std.json.Value = null,
    timestamp: i64,
};

pub const BranchSummaryMessage = struct {
    summary: []const u8,
    from_id: []const u8,
    timestamp: i64,
};

pub const CompactionSummaryMessage = struct {
    summary: []const u8,
    tokens_before: u64,
    timestamp: i64,
};

pub fn bashExecutionToText(allocator: std.mem.Allocator, msg: BashExecutionMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("Ran `{s}`\n", .{msg.command});
    if (msg.output.len > 0) {
        try out.writer.print("```\n{s}\n```", .{msg.output});
    } else {
        try out.writer.writeAll("(no output)");
    }
    if (msg.cancelled) {
        try out.writer.writeAll("\n\n(command cancelled)");
    } else if (msg.exit_code) |code| {
        if (code != 0) try out.writer.print("\n\nCommand exited with code {d}", .{code});
    }
    if (msg.truncated) {
        if (msg.full_output_path) |path| try out.writer.print("\n\n[Output truncated. Full output: {s}]", .{path});
    }
    return out.toOwnedSlice();
}

pub fn createBranchSummaryMessage(summary: []const u8, from_id: []const u8, timestamp_ms: i64) BranchSummaryMessage {
    return .{ .summary = summary, .from_id = from_id, .timestamp = timestamp_ms };
}

pub fn createCompactionSummaryMessage(summary: []const u8, tokens_before: u64, timestamp_ms: i64) CompactionSummaryMessage {
    return .{ .summary = summary, .tokens_before = tokens_before, .timestamp = timestamp_ms };
}

pub fn createCustomMessage(
    custom_type: []const u8,
    content: []const u8,
    display: bool,
    details: ?std.json.Value,
    timestamp_ms: i64,
) CustomMessage {
    return .{ .custom_type = custom_type, .content = content, .display = display, .details = details, .timestamp = timestamp_ms };
}

pub fn branchSummaryToLlmText(allocator: std.mem.Allocator, msg: BranchSummaryMessage) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ BRANCH_SUMMARY_PREFIX, msg.summary, BRANCH_SUMMARY_SUFFIX });
}

pub fn compactionSummaryToLlmText(allocator: std.mem.Allocator, msg: CompactionSummaryMessage) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ COMPACTION_SUMMARY_PREFIX, msg.summary, COMPACTION_SUMMARY_SUFFIX });
}

pub fn userTextMessage(allocator: std.mem.Allocator, text: []const u8, timestamp_ms: i64) !ai.Message {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .user = .{ .content = blocks, .timestamp = timestamp_ms } };
}

test "bash execution converts to LLM text" {
    const text = try bashExecutionToText(std.testing.allocator, .{
        .command = "false",
        .output = "",
        .exit_code = 1,
        .timestamp = 1,
    });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Command exited with code 1") != null);
}
