const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const agent = @import("agent");
const session_manager = @import("session_manager.zig");

pub const CompactionSettings = struct {
    enabled: bool = false,
    reserve_tokens: u32 = 4096,
    keep_recent_tokens: u32 = 20000,
};

pub const CompactionReason = enum {
    manual,
    threshold,
    overflow,
};

pub const CompactionLifecycleEvent = union(enum) {
    start: struct {
        reason: CompactionReason,
    },
    end: struct {
        reason: CompactionReason,
        result: ?CompactionResult = null,
        aborted: bool = false,
        will_retry: bool = false,
        error_message: ?[]const u8 = null,
    },
};

pub const CompactionLifecycleCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, event: CompactionLifecycleEvent) anyerror!void,
};

pub const CompactionResult = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u32,
};

pub const CompactionPreparation = struct {
    summary_start_index: usize,
    first_kept_entry_index: usize,
    tokens_before: u32,
};

pub fn findLastAssistantMessage(messages: []const agent.AgentMessage) ?ai.AssistantMessage {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| return assistant_message,
            else => {},
        }
    }
    return null;
}

pub fn isContextOverflow(message: ai.AssistantMessage, context_window: u32) bool {
    _ = context_window;
    if (message.stop_reason != .error_reason) return false;
    const error_message = message.error_message orelse return false;
    inline for ([_][]const u8{
        "overflow",
        "context length",
        "context window",
        "context limit",
        "maximum context",
        "max context",
        "too long",
        "exceeded model",
        "exceeds model",
    }) |needle| {
        if (string_utils.containsIgnoreCase(error_message, needle)) return true;
    }
    return false;
}

pub fn shouldAutoCompact(context_tokens: u32, context_window: u32, settings: CompactionSettings) bool {
    if (!settings.enabled or context_window == 0) return false;
    const threshold = if (context_window > settings.reserve_tokens) context_window - settings.reserve_tokens else 0;
    return context_tokens > threshold;
}

pub fn estimateContextTokens(messages: []const agent.AgentMessage) u32 {
    var total: u32 = 0;
    for (messages) |message| {
        total += estimateMessageTokens(message);
    }
    return total;
}

fn estimateMessageTokens(message: agent.AgentMessage) u32 {
    var chars: usize = 0;
    switch (message) {
        .user => |user_message| {
            for (user_message.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
                    .tool_call => |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    },
                }
            }
        },
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason) return 0;
            for (assistant_message.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
                    .tool_call => |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    },
                }
            }
            if (!ai.hasInlineToolCalls(assistant_message)) {
                if (assistant_message.tool_calls) |tool_calls| {
                    for (tool_calls) |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    }
                }
            }
        },
        .tool_result => |tool_result| {
            for (tool_result.content) |block| {
                switch (block) {
                    .text => |text| chars += text.text.len,
                    .image => chars += 4800,
                    .thinking => |thinking| chars += thinking.thinking.len,
                    .tool_call => |tool_call| {
                        chars += tool_call.name.len;
                        chars += jsonValueCharCount(tool_call.arguments);
                    },
                }
            }
        },
    }
    return @intCast((chars + 3) / 4);
}

fn jsonValueCharCount(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |bool_value| if (bool_value) 4 else 5,
        .integer => |integer| std.fmt.count("{}", .{integer}),
        .float => |float_value| std.fmt.count("{d}", .{float_value}),
        .number_string => |number_string| number_string.len,
        .string => |string| string.len,
        .array => |array| blk: {
            var total: usize = 2;
            for (array.items, 0..) |item, index| {
                if (index > 0) total += 1;
                total += jsonValueCharCount(item);
            }
            break :blk total;
        },
        .object => |object| blk: {
            var total: usize = 2;
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) total += 1;
                first = false;
                total += entry.key_ptr.*.len + jsonValueCharCount(entry.value_ptr.*) + 1;
            }
            break :blk total;
        },
    };
}

pub fn prepareCompaction(
    branch_entries: []const *const session_manager.SessionEntry,
    keep_recent_tokens: u32,
) ?CompactionPreparation {
    if (branch_entries.len == 0) return null;

    var latest_compaction_index: ?usize = null;
    for (branch_entries, 0..) |entry, index| {
        if (entry.* == .compaction) latest_compaction_index = index;
    }

    const summary_start_index = if (latest_compaction_index) |index| index + 1 else 0;
    if (summary_start_index >= branch_entries.len) return null;

    var tokens_before: u32 = 0;
    var first_visible_index: ?usize = null;
    for (branch_entries[summary_start_index..], summary_start_index..) |entry, index| {
        const entry_tokens = visibleEntryTokens(entry.*);
        if (entry_tokens == 0) continue;
        if (first_visible_index == null) first_visible_index = index;
        tokens_before += entry_tokens;
    }

    const first_visible = first_visible_index orelse return null;
    if (tokens_before <= keep_recent_tokens) return null;

    var kept_tokens: u32 = 0;
    var first_kept_entry_index = first_visible;
    var index = branch_entries.len;
    while (index > summary_start_index) {
        index -= 1;
        const entry_tokens = visibleEntryTokens(branch_entries[index].*);
        if (entry_tokens == 0) continue;
        kept_tokens += entry_tokens;
        first_kept_entry_index = index;
        if (kept_tokens >= keep_recent_tokens) break;
    }

    if (first_kept_entry_index <= first_visible) return null;

    return .{
        .summary_start_index = summary_start_index,
        .first_kept_entry_index = first_kept_entry_index,
        .tokens_before = tokens_before,
    };
}

pub fn prepareManualCompaction(branch_entries: []const *const session_manager.SessionEntry) ?CompactionPreparation {
    if (branch_entries.len == 0) return null;

    var latest_compaction_index: ?usize = null;
    for (branch_entries, 0..) |entry, index| {
        if (entry.* == .compaction) latest_compaction_index = index;
    }

    const summary_start_index = if (latest_compaction_index) |index| index + 1 else 0;
    if (summary_start_index >= branch_entries.len) return null;

    var visible_count: usize = 0;
    var last_visible_index: ?usize = null;
    var tokens_before: u32 = 0;
    for (branch_entries[summary_start_index..], summary_start_index..) |entry, index| {
        const entry_tokens = visibleEntryTokens(entry.*);
        if (entry_tokens == 0) continue;
        visible_count += 1;
        last_visible_index = index;
        tokens_before += entry_tokens;
    }

    if (visible_count < 2 or last_visible_index == null) return null;

    return .{
        .summary_start_index = summary_start_index,
        .first_kept_entry_index = last_visible_index.?,
        .tokens_before = tokens_before,
    };
}

fn visibleEntryTokens(entry: session_manager.SessionEntry) u32 {
    return switch (entry) {
        .message => |message_entry| estimateMessageTokens(message_entry.message),
        else => 0,
    };
}

pub fn buildCompactionSummary(
    allocator: std.mem.Allocator,
    branch_entries: []const *const session_manager.SessionEntry,
    start_index: usize,
    end_index: usize,
    custom_instructions: ?[]const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("Earlier conversation summary:");
    if (custom_instructions) |instructions| {
        try writer.writer.print("\nFocus: {s}", .{instructions});
    }

    var wrote_line = false;
    for (branch_entries[start_index..end_index]) |entry| {
        if (entry.* != .message) continue;
        switch (entry.message.message) {
            .user => |user_message| {
                const text = summarizeBlocks(user_message.content);
                if (text.len == 0) continue;
                try writer.writer.print("\n- user: {s}", .{text});
                wrote_line = true;
            },
            .assistant => |assistant_message| {
                if (assistant_message.stop_reason == .error_reason or assistant_message.stop_reason == .aborted) continue;
                const text = summarizeAssistant(assistant_message);
                if (text.len == 0) continue;
                try writer.writer.print("\n- assistant: {s}", .{text});
                wrote_line = true;
            },
            .tool_result => |tool_result| {
                const text = summarizeBlocks(tool_result.content);
                if (text.len == 0) continue;
                try writer.writer.print("\n- tool {s}: {s}", .{ tool_result.tool_name, text });
                wrote_line = true;
            },
        }
    }

    if (!wrote_line) {
        try writer.writer.writeAll("\n- Session history was compacted to keep recent context available.");
    }

    return try allocator.dupe(u8, writer.written());
}

fn summarizeAssistant(message: ai.AssistantMessage) []const u8 {
    const text = summarizeBlocks(message.content);
    if (text.len > 0) return text;
    if (message.tool_calls) |tool_calls| {
        if (tool_calls.len > 0) return tool_calls[0].name;
    }
    return "";
}

fn summarizeBlocks(blocks: []const ai.ContentBlock) []const u8 {
    for (blocks) |block| {
        switch (block) {
            .text => |text| if (text.text.len > 0) return trimSummary(text.text),
            .thinking => |thinking| if (thinking.thinking.len > 0) return trimSummary(thinking.thinking),
            else => {},
        }
    }
    return "";
}

fn trimSummary(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \n\r\t");
    return if (trimmed.len > 120) trimmed[0..120] else trimmed;
}
