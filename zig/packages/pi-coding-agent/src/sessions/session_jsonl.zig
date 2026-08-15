const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const common = @import("../tools/common.zig");

pub const CURRENT_SESSION_VERSION: u32 = 3;

pub const SessionHeader = struct {
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session: ?[]const u8 = null,
};

pub const SessionMessageEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    message: agent.AgentMessage,
};

pub const ThinkingLevelChangeEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    thinking_level: agent.ThinkingLevel,
};

pub const ModelChangeEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    provider: []const u8,
    model_id: []const u8,
};

pub const CompactionEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u32,
    message: agent.AgentMessage,
};

pub const BranchSummaryEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    from_id: []const u8,
    summary: []const u8,
    details: ?std.json.Value = null,
    from_hook: ?bool = null,
};

pub const CustomEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    custom_type: []const u8,
    data: ?std.json.Value = null,
};

pub const CustomMessageContent = union(enum) {
    text: []const u8,
    blocks: []const ai.ContentBlock,

    pub fn deinit(self: *CustomMessageContent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| allocator.free(text),
            .blocks => |blocks| common.deinitContentBlocks(allocator, blocks),
        }
        self.* = undefined;
    }
};

pub const CustomMessageEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    custom_type: []const u8,
    content: CustomMessageContent,
    details: ?std.json.Value = null,
    display: bool,
};

pub const LabelEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    target_id: []const u8,
    label: ?[]const u8,
};

pub const SessionInfoEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    name: ?[]const u8,
};

pub const ActiveToolsChangeEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    active_tool_names: [][]const u8,
};

pub const SessionEntry = union(enum) {
    message: SessionMessageEntry,
    thinking_level_change: ThinkingLevelChangeEntry,
    model_change: ModelChangeEntry,
    active_tools_change: ActiveToolsChangeEntry,
    compaction: CompactionEntry,
    branch_summary: BranchSummaryEntry,
    custom: CustomEntry,
    custom_message: CustomMessageEntry,
    label: LabelEntry,
    session_info: SessionInfoEntry,

    pub fn id(self: *const SessionEntry) []const u8 {
        return switch (self.*) {
            .message => |entry| entry.id,
            .thinking_level_change => |entry| entry.id,
            .model_change => |entry| entry.id,
            .active_tools_change => |entry| entry.id,
            .compaction => |entry| entry.id,
            .branch_summary => |entry| entry.id,
            .custom => |entry| entry.id,
            .custom_message => |entry| entry.id,
            .label => |entry| entry.id,
            .session_info => |entry| entry.id,
        };
    }

    pub fn parentId(self: *const SessionEntry) ?[]const u8 {
        return switch (self.*) {
            .message => |entry| entry.parent_id,
            .thinking_level_change => |entry| entry.parent_id,
            .model_change => |entry| entry.parent_id,
            .active_tools_change => |entry| entry.parent_id,
            .compaction => |entry| entry.parent_id,
            .branch_summary => |entry| entry.parent_id,
            .custom => |entry| entry.parent_id,
            .custom_message => |entry| entry.parent_id,
            .label => |entry| entry.parent_id,
            .session_info => |entry| entry.parent_id,
        };
    }

    pub fn timestamp(self: *const SessionEntry) []const u8 {
        return switch (self.*) {
            .message => |entry| entry.timestamp,
            .thinking_level_change => |entry| entry.timestamp,
            .model_change => |entry| entry.timestamp,
            .active_tools_change => |entry| entry.timestamp,
            .compaction => |entry| entry.timestamp,
            .branch_summary => |entry| entry.timestamp,
            .custom => |entry| entry.timestamp,
            .custom_message => |entry| entry.timestamp,
            .label => |entry| entry.timestamp,
            .session_info => |entry| entry.timestamp,
        };
    }
};

/// Auto-generated tag enum for `SessionEntry`. The enum tag names are the
/// canonical on-wire `type` strings shared with the TS implementation
/// (e.g. `"message"`, `"thinking_level_change"`). Both the parser and the
/// writer derive their string identifiers from `@tagName`, so adding a new
/// `SessionEntry` variant produces a compile-time error in `parseEntryLine`'s
/// exhaustive switch and the on-wire string stays in sync automatically.
pub const SessionEntryTag = std.meta.Tag(SessionEntry);

pub fn deinitHeader(allocator: std.mem.Allocator, header: *SessionHeader) void {
    allocator.free(header.id);
    allocator.free(header.timestamp);
    allocator.free(header.cwd);
    if (header.parent_session) |path| allocator.free(path);
}

pub fn deinitEntry(allocator: std.mem.Allocator, entry: *SessionEntry) void {
    switch (entry.*) {
        .message => |*message_entry| {
            allocator.free(message_entry.id);
            if (message_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(message_entry.timestamp);
            deinitMessage(allocator, &message_entry.message);
        },
        .thinking_level_change => |*thinking_entry| {
            allocator.free(thinking_entry.id);
            if (thinking_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(thinking_entry.timestamp);
        },
        .model_change => |*model_entry| {
            allocator.free(model_entry.id);
            if (model_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(model_entry.timestamp);
            allocator.free(model_entry.provider);
            allocator.free(model_entry.model_id);
        },
        .active_tools_change => |*tools_entry| {
            allocator.free(tools_entry.id);
            if (tools_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(tools_entry.timestamp);
            for (tools_entry.active_tool_names) |name| allocator.free(name);
            allocator.free(tools_entry.active_tool_names);
        },
        .compaction => |*compaction_entry| {
            allocator.free(compaction_entry.id);
            if (compaction_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(compaction_entry.timestamp);
            allocator.free(compaction_entry.first_kept_entry_id);
            deinitMessage(allocator, &compaction_entry.message);
        },
        .branch_summary => |*branch_summary_entry| {
            allocator.free(branch_summary_entry.id);
            if (branch_summary_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(branch_summary_entry.timestamp);
            allocator.free(branch_summary_entry.from_id);
            allocator.free(branch_summary_entry.summary);
            if (branch_summary_entry.details) |details| common.deinitJsonValue(allocator, details);
        },
        .custom => |*custom_entry| {
            allocator.free(custom_entry.id);
            if (custom_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(custom_entry.timestamp);
            allocator.free(custom_entry.custom_type);
            if (custom_entry.data) |data| common.deinitJsonValue(allocator, data);
        },
        .custom_message => |*custom_message_entry| {
            allocator.free(custom_message_entry.id);
            if (custom_message_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(custom_message_entry.timestamp);
            allocator.free(custom_message_entry.custom_type);
            custom_message_entry.content.deinit(allocator);
            if (custom_message_entry.details) |details| common.deinitJsonValue(allocator, details);
        },
        .label => |*label_entry| {
            allocator.free(label_entry.id);
            if (label_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(label_entry.timestamp);
            allocator.free(label_entry.target_id);
            if (label_entry.label) |label| allocator.free(label);
        },
        .session_info => |*session_info_entry| {
            allocator.free(session_info_entry.id);
            if (session_info_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(session_info_entry.timestamp);
            if (session_info_entry.name) |name| allocator.free(name);
        },
    }
}

fn cloneParentId(allocator: std.mem.Allocator, parent_id: ?[]const u8) !?[]const u8 {
    return if (parent_id) |value| try allocator.dupe(u8, value) else null;
}

pub fn cloneEntry(allocator: std.mem.Allocator, entry: SessionEntry) !SessionEntry {
    return switch (entry) {
        .message => |message_entry| .{ .message = .{
            .id = try allocator.dupe(u8, message_entry.id),
            .parent_id = try cloneParentId(allocator, message_entry.parent_id),
            .timestamp = try allocator.dupe(u8, message_entry.timestamp),
            .message = try cloneMessage(allocator, message_entry.message),
        } },
        .thinking_level_change => |thinking_entry| .{ .thinking_level_change = .{
            .id = try allocator.dupe(u8, thinking_entry.id),
            .parent_id = try cloneParentId(allocator, thinking_entry.parent_id),
            .timestamp = try allocator.dupe(u8, thinking_entry.timestamp),
            .thinking_level = thinking_entry.thinking_level,
        } },
        .model_change => |model_entry| .{ .model_change = .{
            .id = try allocator.dupe(u8, model_entry.id),
            .parent_id = try cloneParentId(allocator, model_entry.parent_id),
            .timestamp = try allocator.dupe(u8, model_entry.timestamp),
            .provider = try allocator.dupe(u8, model_entry.provider),
            .model_id = try allocator.dupe(u8, model_entry.model_id),
        } },
        .active_tools_change => |tools_entry| .{ .active_tools_change = .{
            .id = try allocator.dupe(u8, tools_entry.id),
            .parent_id = try cloneParentId(allocator, tools_entry.parent_id),
            .timestamp = try allocator.dupe(u8, tools_entry.timestamp),
            .active_tool_names = blk: {
                const names = try allocator.alloc([]const u8, tools_entry.active_tool_names.len);
                for (tools_entry.active_tool_names, 0..) |name, i| names[i] = try allocator.dupe(u8, name);
                break :blk names;
            },
        } },
        .compaction => |compaction_entry| .{ .compaction = .{
            .id = try allocator.dupe(u8, compaction_entry.id),
            .parent_id = try cloneParentId(allocator, compaction_entry.parent_id),
            .timestamp = try allocator.dupe(u8, compaction_entry.timestamp),
            .first_kept_entry_id = try allocator.dupe(u8, compaction_entry.first_kept_entry_id),
            .tokens_before = compaction_entry.tokens_before,
            .message = try cloneMessage(allocator, compaction_entry.message),
        } },
        .branch_summary => |branch_summary_entry| .{ .branch_summary = .{
            .id = try allocator.dupe(u8, branch_summary_entry.id),
            .parent_id = try cloneParentId(allocator, branch_summary_entry.parent_id),
            .timestamp = try allocator.dupe(u8, branch_summary_entry.timestamp),
            .from_id = try allocator.dupe(u8, branch_summary_entry.from_id),
            .summary = try allocator.dupe(u8, branch_summary_entry.summary),
            .details = if (branch_summary_entry.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .from_hook = branch_summary_entry.from_hook,
        } },
        .custom => |custom_entry| .{ .custom = .{
            .id = try allocator.dupe(u8, custom_entry.id),
            .parent_id = try cloneParentId(allocator, custom_entry.parent_id),
            .timestamp = try allocator.dupe(u8, custom_entry.timestamp),
            .custom_type = try allocator.dupe(u8, custom_entry.custom_type),
            .data = if (custom_entry.data) |data| try common.cloneJsonValue(allocator, data) else null,
        } },
        .custom_message => |custom_message_entry| .{ .custom_message = .{
            .id = try allocator.dupe(u8, custom_message_entry.id),
            .parent_id = try cloneParentId(allocator, custom_message_entry.parent_id),
            .timestamp = try allocator.dupe(u8, custom_message_entry.timestamp),
            .custom_type = try allocator.dupe(u8, custom_message_entry.custom_type),
            .content = try cloneCustomMessageContent(allocator, custom_message_entry.content),
            .details = if (custom_message_entry.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .display = custom_message_entry.display,
        } },
        .label => |label_entry| .{ .label = .{
            .id = try allocator.dupe(u8, label_entry.id),
            .parent_id = try cloneParentId(allocator, label_entry.parent_id),
            .timestamp = try allocator.dupe(u8, label_entry.timestamp),
            .target_id = try allocator.dupe(u8, label_entry.target_id),
            .label = if (label_entry.label) |label| try allocator.dupe(u8, label) else null,
        } },
        .session_info => |session_info_entry| .{ .session_info = .{
            .id = try allocator.dupe(u8, session_info_entry.id),
            .parent_id = try cloneParentId(allocator, session_info_entry.parent_id),
            .timestamp = try allocator.dupe(u8, session_info_entry.timestamp),
            .name = if (session_info_entry.name) |name| try allocator.dupe(u8, name) else null,
        } },
    };
}

pub fn cloneMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) !agent.AgentMessage {
    return switch (message) {
        .user => |user| .{ .user = .{
            .role = try allocator.dupe(u8, user.role),
            .content = try cloneContentBlocks(allocator, user.content),
            .timestamp = user.timestamp,
        } },
        .assistant => |assistant| .{ .assistant = .{
            .role = try allocator.dupe(u8, assistant.role),
            .content = try cloneContentBlocks(allocator, assistant.content),
            .tool_calls = if (assistant.tool_calls) |tool_calls| try cloneToolCalls(allocator, tool_calls) else null,
            .api = try allocator.dupe(u8, assistant.api),
            .provider = try allocator.dupe(u8, assistant.provider),
            .model = try allocator.dupe(u8, assistant.model),
            .response_id = if (assistant.response_id) |response_id| try allocator.dupe(u8, response_id) else null,
            .response_model = if (assistant.response_model) |response_model| try allocator.dupe(u8, response_model) else null,
            .usage = assistant.usage,
            .stop_reason = assistant.stop_reason,
            .error_message = if (assistant.error_message) |error_message| try allocator.dupe(u8, error_message) else null,
            .timestamp = assistant.timestamp,
        } },
        .tool_result => |tool_result| .{ .tool_result = .{
            .role = try allocator.dupe(u8, tool_result.role),
            .tool_call_id = try allocator.dupe(u8, tool_result.tool_call_id),
            .tool_name = try allocator.dupe(u8, tool_result.tool_name),
            .content = try cloneContentBlocks(allocator, tool_result.content),
            .details = if (tool_result.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .is_error = tool_result.is_error,
            .timestamp = tool_result.timestamp,
        } },
    };
}

pub fn deinitMessage(allocator: std.mem.Allocator, message: *agent.AgentMessage) void {
    switch (message.*) {
        .user => |*user| {
            allocator.free(user.role);
            common.deinitContentBlocks(allocator, user.content);
        },
        .assistant => |*assistant| {
            allocator.free(assistant.role);
            common.deinitContentBlocks(allocator, assistant.content);
            if (assistant.tool_calls) |tool_calls| deinitToolCalls(allocator, tool_calls);
            allocator.free(assistant.api);
            allocator.free(assistant.provider);
            allocator.free(assistant.model);
            if (assistant.response_id) |response_id| allocator.free(response_id);
            if (assistant.response_model) |response_model| allocator.free(response_model);
            if (assistant.error_message) |error_message| allocator.free(error_message);
        },
        .tool_result => |*tool_result| {
            allocator.free(tool_result.role);
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            common.deinitContentBlocks(allocator, tool_result.content);
            if (tool_result.details) |details| common.deinitJsonValue(allocator, details);
        },
    }
}

pub fn cloneCustomMessageContent(
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
) !CustomMessageContent {
    return switch (content) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .blocks => |blocks| .{ .blocks = try cloneContentBlocks(allocator, blocks) },
    };
}

pub fn createCompactionSummaryMessage(
    allocator: std.mem.Allocator,
    summary: []const u8,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.fmt.allocPrint(allocator, "[compaction]\n{s}", .{summary}) } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

pub fn getCompactionSummary(entry: CompactionEntry) ![]const u8 {
    return switch (entry.message) {
        .user => |user| blk: {
            if (user.content.len == 0 or user.content[0] != .text) return error.InvalidSessionEntry;
            const text = user.content[0].text.text;
            const prefix = "[compaction]\n";
            if (std.mem.startsWith(u8, text, prefix)) {
                break :blk text[prefix.len..];
            }
            break :blk text;
        },
        else => error.InvalidSessionEntry,
    };
}

pub fn cloneContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]const ai.ContentBlock {
    const cloned = try allocator.alloc(ai.ContentBlock, blocks.len);
    for (blocks, 0..) |block, index| {
        cloned[index] = cloneContentBlock(allocator, block) catch |err| {
            var cleanup_index: usize = 0;
            while (cleanup_index < index) : (cleanup_index += 1) {
                switch (cloned[cleanup_index]) {
                    .text => |text| allocator.free(text.text),
                    .image => |image| {
                        allocator.free(image.data);
                        allocator.free(image.mime_type);
                    },
                    .thinking => |thinking| {
                        allocator.free(thinking.thinking);
                        if (thinking.thinking_signature) |signature| allocator.free(signature);
                        if (thinking.signature) |signature| allocator.free(signature);
                    },
                    .tool_call => |tool_call| deinitToolCall(allocator, tool_call),
                }
            }
            allocator.free(cloned);
            return err;
        };
    }

    return cloned;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |text| ai.ContentBlock{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
        .image => |image| ai.ContentBlock{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| ai.ContentBlock{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .thinking_signature = if (ai.thinkingSignature(thinking)) |signature| try allocator.dupe(u8, signature) else null,
            .signature = if (ai.thinkingSignature(thinking)) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
        .tool_call => |tool_call| ai.ContentBlock{ .tool_call = try cloneToolCall(allocator, tool_call) },
    };
}

fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai.ToolCall) ![]const ai.ToolCall {
    const cloned = try allocator.alloc(ai.ToolCall, tool_calls.len);
    errdefer allocator.free(cloned);

    for (tool_calls, 0..) |tool_call, index| {
        cloned[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try common.cloneJsonValue(allocator, tool_call.arguments),
            .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
        };
    }

    return cloned;
}

fn deinitToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai.ToolCall) void {
    for (tool_calls) |tool_call| {
        deinitToolCall(allocator, tool_call);
    }
    allocator.free(tool_calls);
}

fn cloneToolCall(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !ai.ToolCall {
    return .{
        .id = try allocator.dupe(u8, tool_call.id),
        .name = try allocator.dupe(u8, tool_call.name),
        .arguments = try common.cloneJsonValue(allocator, tool_call.arguments),
        .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
    };
}

fn deinitToolCall(allocator: std.mem.Allocator, tool_call: ai.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    common.deinitJsonValue(allocator, tool_call.arguments);
}

pub fn headerToJsonValue(allocator: std.mem.Allocator, header: SessionHeader) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try common.putString(allocator, &object, "type", "session");
    try common.putInt(allocator, &object, "version", CURRENT_SESSION_VERSION);
    try common.putString(allocator, &object, "id", header.id);
    try common.putString(allocator, &object, "timestamp", header.timestamp);
    try common.putString(allocator, &object, "cwd", header.cwd);
    if (header.parent_session) |parent_session| {
        try common.putString(allocator, &object, "parentSession", parent_session);
    }
    return .{ .object = object };
}

pub fn entryToJsonValue(allocator: std.mem.Allocator, entry: SessionEntry) !std.json.Value {
    return switch (entry) {
        .message => |message_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.message), message_entry.id, message_entry.parent_id, message_entry.timestamp);
            try common.putValue(allocator, &object, "message", try messageToJsonValue(allocator, message_entry.message));
            break :blk .{ .object = object };
        },
        .thinking_level_change => |thinking_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.thinking_level_change), thinking_entry.id, thinking_entry.parent_id, thinking_entry.timestamp);
            try common.putString(allocator, &object, "thinkingLevel", thinkingLevelToString(thinking_entry.thinking_level));
            break :blk .{ .object = object };
        },
        .model_change => |model_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.model_change), model_entry.id, model_entry.parent_id, model_entry.timestamp);
            try common.putString(allocator, &object, "provider", model_entry.provider);
            try common.putString(allocator, &object, "modelId", model_entry.model_id);
            break :blk .{ .object = object };
        },
        .active_tools_change => |tools_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.active_tools_change), tools_entry.id, tools_entry.parent_id, tools_entry.timestamp);
            // Serialize active_tool_names as a JSON array of strings.
            var names_array = std.json.Array.init(allocator);
            for (tools_entry.active_tool_names) |name| {
                try names_array.append(.{ .string = name });
            }
            try object.put(allocator, try allocator.dupe(u8, "activeToolNames"), .{ .array = names_array });
            break :blk .{ .object = object };
        },
        .compaction => |compaction_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.compaction), compaction_entry.id, compaction_entry.parent_id, compaction_entry.timestamp);
            try object.put(
                allocator,
                try allocator.dupe(u8, "firstKeptEntryId"),
                .{ .string = try allocator.dupe(u8, compaction_entry.first_kept_entry_id) },
            );
            try common.putInt(allocator, &object, "tokensBefore", compaction_entry.tokens_before);
            try object.put(
                allocator,
                try allocator.dupe(u8, "summary"),
                .{ .string = try allocator.dupe(u8, try getCompactionSummary(compaction_entry)) },
            );
            break :blk .{ .object = object };
        },
        .branch_summary => |branch_summary_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.branch_summary), branch_summary_entry.id, branch_summary_entry.parent_id, branch_summary_entry.timestamp);
            try common.putString(allocator, &object, "fromId", branch_summary_entry.from_id);
            try common.putString(allocator, &object, "summary", branch_summary_entry.summary);
            if (branch_summary_entry.details) |details| {
                try common.putValue(allocator, &object, "details", try common.cloneJsonValue(allocator, details));
            }
            if (branch_summary_entry.from_hook) |from_hook| {
                try common.putBool(allocator, &object, "fromHook", from_hook);
            }
            break :blk .{ .object = object };
        },
        .custom => |custom_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.custom), custom_entry.id, custom_entry.parent_id, custom_entry.timestamp);
            try common.putString(allocator, &object, "customType", custom_entry.custom_type);
            if (custom_entry.data) |data| {
                try common.putValue(allocator, &object, "data", try common.cloneJsonValue(allocator, data));
            }
            break :blk .{ .object = object };
        },
        .custom_message => |custom_message_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.custom_message), custom_message_entry.id, custom_message_entry.parent_id, custom_message_entry.timestamp);
            try common.putString(allocator, &object, "customType", custom_message_entry.custom_type);
            try common.putValue(allocator, &object, "content", try customMessageContentToJsonValue(allocator, custom_message_entry.content));
            try common.putBool(allocator, &object, "display", custom_message_entry.display);
            if (custom_message_entry.details) |details| {
                try common.putValue(allocator, &object, "details", try common.cloneJsonValue(allocator, details));
            }
            break :blk .{ .object = object };
        },
        .label => |label_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.label), label_entry.id, label_entry.parent_id, label_entry.timestamp);
            try common.putString(allocator, &object, "targetId", label_entry.target_id);
            try object.put(
                allocator,
                try allocator.dupe(u8, "label"),
                if (label_entry.label) |label| .{ .string = try allocator.dupe(u8, label) } else .null,
            );
            break :blk .{ .object = object };
        },
        .session_info => |session_info_entry| blk: {
            var object = try baseEntryObject(allocator, @tagName(SessionEntryTag.session_info), session_info_entry.id, session_info_entry.parent_id, session_info_entry.timestamp);
            if (session_info_entry.name) |name| {
                try common.putString(allocator, &object, "name", name);
            } else {
                try common.putNull(allocator, &object, "name");
            }
            break :blk .{ .object = object };
        },
    };
}

comptime {
    // Lock the on-wire JSONL `type` strings to enum tag names so byte-parity
    // with the TS implementation cannot drift unnoticed if a tag is renamed.
    const expected = .{
        .{ SessionEntryTag.message, "message" },
        .{ SessionEntryTag.thinking_level_change, "thinking_level_change" },
        .{ SessionEntryTag.model_change, "model_change" },
        .{ SessionEntryTag.compaction, "compaction" },
        .{ SessionEntryTag.branch_summary, "branch_summary" },
        .{ SessionEntryTag.custom, "custom" },
        .{ SessionEntryTag.custom_message, "custom_message" },
        .{ SessionEntryTag.label, "label" },
        .{ SessionEntryTag.session_info, "session_info" },
    };
    for (expected) |pair| {
        if (!std.mem.eql(u8, @tagName(pair[0]), pair[1])) {
            @compileError("SessionEntryTag name drift: on-wire string parity broken for " ++ pair[1]);
        }
    }
}

pub fn stringifyHeaderLine(allocator: std.mem.Allocator, header: SessionHeader) ![]u8 {
    const json_value = try headerToJsonValue(allocator, header);
    defer common.deinitJsonValue(allocator, json_value);
    return std.json.Stringify.valueAlloc(allocator, json_value, .{});
}

pub fn stringifyEntryLine(allocator: std.mem.Allocator, entry: SessionEntry) ![]u8 {
    const json_value = try entryToJsonValue(allocator, entry);
    defer common.deinitJsonValue(allocator, json_value);
    return std.json.Stringify.valueAlloc(allocator, json_value, .{});
}

fn baseEntryObject(
    allocator: std.mem.Allocator,
    entry_type: []const u8,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
) !std.json.ObjectMap {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try common.putString(allocator, &object, "type", entry_type);
    try common.putString(allocator, &object, "id", id);
    try object.put(
        allocator,
        try allocator.dupe(u8, "parentId"),
        if (parent_id) |value| .{ .string = try allocator.dupe(u8, value) } else .null,
    );
    try common.putString(allocator, &object, "timestamp", timestamp);
    return object;
}

fn messageToJsonValue(allocator: std.mem.Allocator, message: agent.AgentMessage) !std.json.Value {
    return switch (message) {
        .user => |user| blk: {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try common.putString(allocator, &object, "role", "user");
            if (user.content.len == 1 and user.content[0] == .text) {
                try common.putString(allocator, &object, "content", user.content[0].text.text);
            } else {
                try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, user.content, null));
            }
            try common.putInt(allocator, &object, "timestamp", user.timestamp);
            break :blk .{ .object = object };
        },
        .assistant => |assistant| blk: {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try common.putString(allocator, &object, "role", "assistant");
            try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, assistant.content, assistant.tool_calls));
            try common.putString(allocator, &object, "api", assistant.api);
            try common.putString(allocator, &object, "provider", assistant.provider);
            try common.putString(allocator, &object, "model", assistant.model);
            if (assistant.response_id) |response_id| {
                try common.putString(allocator, &object, "responseId", response_id);
            }
            if (assistant.response_model) |response_model| {
                try common.putString(allocator, &object, "responseModel", response_model);
            }
            try common.putValue(allocator, &object, "usage", try usageToJsonValue(allocator, assistant.usage));
            try common.putString(allocator, &object, "stopReason", stopReasonToString(assistant.stop_reason));
            if (assistant.error_message) |error_message| {
                try common.putString(allocator, &object, "errorMessage", error_message);
            }
            try common.putInt(allocator, &object, "timestamp", assistant.timestamp);
            break :blk .{ .object = object };
        },
        .tool_result => |tool_result| blk: {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try common.putString(allocator, &object, "role", "toolResult");
            try common.putString(allocator, &object, "toolCallId", tool_result.tool_call_id);
            try common.putString(allocator, &object, "toolName", tool_result.tool_name);
            try common.putValue(allocator, &object, "content", try contentBlocksToJsonValue(allocator, tool_result.content, null));
            if (tool_result.details) |details| {
                try common.putValue(allocator, &object, "details", try common.cloneJsonValue(allocator, details));
            }
            try common.putBool(allocator, &object, "isError", tool_result.is_error);
            try common.putInt(allocator, &object, "timestamp", tool_result.timestamp);
            break :blk .{ .object = object };
        },
    };
}

fn contentBlocksToJsonValue(
    allocator: std.mem.Allocator,
    content: []const ai.ContentBlock,
    tool_calls: ?[]const ai.ToolCall,
) !std.json.Value {
    var array = std.json.Array.init(allocator);

    for (content) |block| {
        var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        switch (block) {
            .text => |text| {
                try common.putString(allocator, &object, "type", "text");
                try common.putString(allocator, &object, "text", text.text);
                if (text.text_signature) |signature| {
                    try common.putString(allocator, &object, "textSignature", signature);
                }
            },
            .image => |image| {
                try common.putString(allocator, &object, "type", "image");
                try common.putString(allocator, &object, "data", image.data);
                try common.putString(allocator, &object, "mimeType", image.mime_type);
            },
            .thinking => |thinking| {
                try common.putString(allocator, &object, "type", "thinking");
                try common.putString(allocator, &object, "thinking", thinking.thinking);
                if (ai.thinkingSignature(thinking)) |signature| {
                    try common.putString(allocator, &object, "thinkingSignature", signature);
                }
                if (thinking.redacted) {
                    try common.putBool(allocator, &object, "redacted", true);
                }
            },
            .tool_call => |tool_call| {
                common.deinitJsonValue(allocator, .{ .object = object });
                try array.append(try toolCallToJsonValue(allocator, tool_call));
                continue;
            },
        }
        try array.append(.{ .object = object });
    }

    const inline_has_tool_calls = blk: {
        for (content) |block| {
            if (block == .tool_call) break :blk true;
        }
        break :blk false;
    };

    if (!inline_has_tool_calls) {
        if (tool_calls) |calls| {
            for (calls) |tool_call| {
                try array.append(try toolCallToJsonValue(allocator, tool_call));
            }
        }
    }

    return .{ .array = array };
}

fn toolCallToJsonValue(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putString(allocator, &object, "type", "toolCall");
    try common.putString(allocator, &object, "id", tool_call.id);
    try common.putString(allocator, &object, "name", tool_call.name);
    try common.putValue(allocator, &object, "arguments", try common.cloneJsonValue(allocator, tool_call.arguments));
    if (tool_call.thought_signature) |signature| {
        try common.putString(allocator, &object, "thoughtSignature", signature);
    }
    return .{ .object = object };
}

fn customMessageContentToJsonValue(
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
) !std.json.Value {
    return switch (content) {
        .text => |text| .{ .string = try allocator.dupe(u8, text) },
        .blocks => |blocks| try contentBlocksToJsonValue(allocator, blocks, null),
    };
}

fn usageToJsonValue(allocator: std.mem.Allocator, usage: ai.Usage) !std.json.Value {
    var cost_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try common.putFloat(allocator, &cost_object, "input", usage.cost.input);
    try common.putFloat(allocator, &cost_object, "output", usage.cost.output);
    try common.putFloat(allocator, &cost_object, "cacheRead", usage.cost.cache_read);
    try common.putFloat(allocator, &cost_object, "cacheWrite", usage.cost.cache_write);
    try common.putFloat(allocator, &cost_object, "total", usage.cost.total);

    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try common.putInt(allocator, &object, "input", usage.input);
    try common.putInt(allocator, &object, "output", usage.output);
    try common.putInt(allocator, &object, "cacheRead", usage.cache_read);
    try common.putInt(allocator, &object, "cacheWrite", usage.cache_write);
    try common.putInt(allocator, &object, "totalTokens", usage.total_tokens);
    try common.putValue(allocator, &object, "cost", .{ .object = cost_object });
    return .{ .object = object };
}

pub fn parseHeaderLine(allocator: std.mem.Allocator, line: []const u8) !SessionHeader {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const object = try requireObject(parsed.value);
    const entry_type = try getRequiredString(object, "type");
    if (!std.mem.eql(u8, entry_type, "session")) return error.InvalidSessionFile;

    return .{
        .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
        .timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp")),
        .cwd = try allocator.dupe(u8, try getRequiredString(object, "cwd")),
        .parent_session = if (getOptionalString(object, "parentSession")) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn parseEntryLine(allocator: std.mem.Allocator, line: []const u8) !SessionEntry {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const object = try requireObject(parsed.value);
    const entry_type = try getRequiredString(object, "type");

    const tag = std.meta.stringToEnum(SessionEntryTag, entry_type) orelse
        return error.UnsupportedSessionEntryType;

    return switch (tag) {
        .message => parseMessageEntry(allocator, object),
        .thinking_level_change => parseThinkingLevelChangeEntry(allocator, object),
        .model_change => parseModelChangeEntry(allocator, object),
        .active_tools_change => parseActiveToolsChangeEntry(allocator, object),
        .compaction => parseCompactionEntry(allocator, object),
        .branch_summary => parseBranchSummaryEntry(allocator, object),
        .custom => parseCustomEntry(allocator, object),
        .custom_message => parseCustomMessageEntry(allocator, object),
        .label => parseLabelEntry(allocator, object),
        .session_info => parseSessionInfoEntry(allocator, object),
    };
}

const ParsedEntryBase = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,

    fn deinit(self: *ParsedEntryBase, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.parent_id) |parent_id| allocator.free(parent_id);
        allocator.free(self.timestamp);
    }
};

fn parseEntryBase(allocator: std.mem.Allocator, object: std.json.ObjectMap) !ParsedEntryBase {
    const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
    errdefer allocator.free(id);
    const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
    errdefer if (parent_id) |value| allocator.free(value);
    const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
    errdefer allocator.free(timestamp);
    return .{ .id = id, .parent_id = parent_id, .timestamp = timestamp };
}

fn parseMessageEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    var message = try parseMessageValue(allocator, object.get("message") orelse return error.InvalidSessionEntry);
    errdefer deinitMessage(allocator, &message);
    return .{ .message = .{ .id = base.id, .parent_id = base.parent_id, .timestamp = base.timestamp, .message = message } };
}

fn parseThinkingLevelChangeEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    return .{ .thinking_level_change = .{
        .id = base.id,
        .parent_id = base.parent_id,
        .timestamp = base.timestamp,
        .thinking_level = try parseThinkingLevel(try getRequiredString(object, "thinkingLevel")),
    } };
}

fn parseModelChangeEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const provider = try allocator.dupe(u8, try getRequiredString(object, "provider"));
    errdefer allocator.free(provider);
    const model_id = try allocator.dupe(u8, try getRequiredString(object, "modelId"));
    errdefer allocator.free(model_id);
    return .{ .model_change = .{ .id = base.id, .parent_id = base.parent_id, .timestamp = base.timestamp, .provider = provider, .model_id = model_id } };
}

fn parseActiveToolsChangeEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const names_value = object.get("activeToolNames") orelse return error.InvalidSessionEntry;
    if (names_value != .array) return error.InvalidSessionEntry;
    var names_list = std.ArrayList([]const u8).empty;
    errdefer {
        for (names_list.items) |name| allocator.free(name);
        names_list.deinit(allocator);
    }
    for (names_value.array.items) |item| {
        if (item != .string) return error.InvalidSessionEntry;
        try names_list.append(allocator, try allocator.dupe(u8, item.string));
    }
    const names = try names_list.toOwnedSlice(allocator);
    return .{ .active_tools_change = .{ .id = base.id, .parent_id = base.parent_id, .timestamp = base.timestamp, .active_tool_names = names } };
}

fn parseCompactionEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    const summary = try getRequiredString(object, "summary");
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const first_kept_entry_id = try allocator.dupe(u8, try getRequiredString(object, "firstKeptEntryId"));
    errdefer allocator.free(first_kept_entry_id);
    var message = try createCompactionSummaryMessage(allocator, summary, 0);
    errdefer deinitMessage(allocator, &message);
    return .{ .compaction = .{
        .id = base.id,
        .parent_id = base.parent_id,
        .timestamp = base.timestamp,
        .first_kept_entry_id = first_kept_entry_id,
        .tokens_before = @intCast(try getRequiredInteger(object, "tokensBefore")),
        .message = message,
    } };
}

fn parseBranchSummaryEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const from_id = try allocator.dupe(u8, try getRequiredString(object, "fromId"));
    errdefer allocator.free(from_id);
    const summary = try allocator.dupe(u8, try getRequiredString(object, "summary"));
    errdefer allocator.free(summary);
    const details = if (object.get("details")) |value| try common.cloneJsonValue(allocator, value) else null;
    errdefer if (details) |value| common.deinitJsonValue(allocator, value);
    return .{ .branch_summary = .{
        .id = base.id,
        .parent_id = base.parent_id,
        .timestamp = base.timestamp,
        .from_id = from_id,
        .summary = summary,
        .details = details,
        .from_hook = getOptionalBool(object, "fromHook"),
    } };
}

fn parseCustomEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const custom_type = try allocator.dupe(u8, try getRequiredString(object, "customType"));
    errdefer allocator.free(custom_type);
    const data = if (object.get("data")) |value| try common.cloneJsonValue(allocator, value) else null;
    errdefer if (data) |value| common.deinitJsonValue(allocator, value);
    return .{ .custom = .{ .id = base.id, .parent_id = base.parent_id, .timestamp = base.timestamp, .custom_type = custom_type, .data = data } };
}

fn parseCustomMessageEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const custom_type = try allocator.dupe(u8, try getRequiredString(object, "customType"));
    errdefer allocator.free(custom_type);
    const content = try parseCustomMessageContentValue(allocator, object.get("content") orelse return error.InvalidSessionEntry);
    errdefer {
        var cleanup_content = content;
        cleanup_content.deinit(allocator);
    }
    const details = if (object.get("details")) |value| try common.cloneJsonValue(allocator, value) else null;
    errdefer if (details) |value| common.deinitJsonValue(allocator, value);
    return .{ .custom_message = .{
        .id = base.id,
        .parent_id = base.parent_id,
        .timestamp = base.timestamp,
        .custom_type = custom_type,
        .content = content,
        .details = details,
        .display = try getRequiredBool(object, "display"),
    } };
}

fn parseLabelEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const target_id = try allocator.dupe(u8, try getRequiredString(object, "targetId"));
    errdefer allocator.free(target_id);
    const label = if (getOptionalString(object, "label")) |value| try allocator.dupe(u8, value) else null;
    errdefer if (label) |value| allocator.free(value);
    return .{ .label = .{ .id = base.id, .parent_id = base.parent_id, .timestamp = base.timestamp, .target_id = target_id, .label = label } };
}

fn parseSessionInfoEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap) !SessionEntry {
    var base = try parseEntryBase(allocator, object);
    errdefer base.deinit(allocator);
    const name = if (getOptionalString(object, "name")) |value| try allocator.dupe(u8, value) else null;
    errdefer if (name) |value| allocator.free(value);
    return .{ .session_info = .{ .id = base.id, .parent_id = base.parent_id, .timestamp = base.timestamp, .name = name } };
}

fn parseMessageValue(allocator: std.mem.Allocator, value: std.json.Value) !agent.AgentMessage {
    const object = try requireObject(value);
    const role = try getRequiredString(object, "role");

    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .role = try allocator.dupe(u8, "user"),
            .content = try parseUserContentValue(allocator, object.get("content") orelse return error.InvalidSessionMessage),
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    if (std.mem.eql(u8, role, "assistant")) {
        const parsed_content = try parseAssistantContentValue(allocator, object.get("content") orelse return error.InvalidSessionMessage);
        return .{ .assistant = .{
            .role = try allocator.dupe(u8, "assistant"),
            .content = parsed_content.content,
            .tool_calls = parsed_content.tool_calls,
            .api = try allocator.dupe(u8, try getRequiredString(object, "api")),
            .provider = try allocator.dupe(u8, try getRequiredString(object, "provider")),
            .model = try allocator.dupe(u8, try getRequiredString(object, "model")),
            .response_id = if (getOptionalString(object, "responseId")) |response_id| try allocator.dupe(u8, response_id) else null,
            .response_model = if (getOptionalString(object, "responseModel")) |response_model| try allocator.dupe(u8, response_model) else null,
            .usage = try parseUsageValue(object.get("usage") orelse return error.InvalidSessionMessage),
            .stop_reason = try parseStopReason(try getRequiredString(object, "stopReason")),
            .error_message = if (getOptionalString(object, "errorMessage")) |error_message| try allocator.dupe(u8, error_message) else null,
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    if (std.mem.eql(u8, role, "toolResult")) {
        return .{ .tool_result = .{
            .role = try allocator.dupe(u8, "toolResult"),
            .tool_call_id = try allocator.dupe(u8, try getRequiredString(object, "toolCallId")),
            .tool_name = try allocator.dupe(u8, try getRequiredString(object, "toolName")),
            .content = try parseGenericContentValue(allocator, object.get("content") orelse return error.InvalidSessionMessage),
            .details = if (object.get("details")) |details| try common.cloneJsonValue(allocator, details) else null,
            .is_error = getOptionalBool(object, "isError") orelse false,
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    return error.UnsupportedSessionMessageRole;
}

fn parseCustomMessageContentValue(allocator: std.mem.Allocator, value: std.json.Value) !CustomMessageContent {
    return switch (value) {
        .string => |text| .{ .text = try allocator.dupe(u8, text) },
        .array => .{ .blocks = try parseGenericContentValue(allocator, value) },
        else => error.InvalidSessionEntry,
    };
}

fn parseUserContentValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const ai.ContentBlock {
    return switch (value) {
        .string => |text| blk: {
            const blocks = try allocator.alloc(ai.ContentBlock, 1);
            blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
            break :blk blocks;
        },
        .array => try parseGenericContentValue(allocator, value),
        else => error.InvalidSessionMessage,
    };
}

fn parseAssistantContentValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !struct { content: []const ai.ContentBlock, tool_calls: ?[]const ai.ToolCall } {
    const array = try requireArray(value);

    var content = std.ArrayList(ai.ContentBlock).empty;
    errdefer {
        const owned = content.toOwnedSlice(allocator) catch &[_]ai.ContentBlock{};
        if (owned.len > 0) common.deinitContentBlocks(allocator, owned);
    }

    var tool_calls = std.ArrayList(ai.ToolCall).empty;
    errdefer {
        const owned = tool_calls.toOwnedSlice(allocator) catch &[_]ai.ToolCall{};
        if (owned.len > 0) deinitToolCalls(allocator, owned);
    }

    for (array.items) |item| {
        const object = try requireObject(item);
        const item_type = try getRequiredString(object, "type");

        if (std.mem.eql(u8, item_type, "toolCall")) {
            const tool_call = ai.ToolCall{
                .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
                .name = try allocator.dupe(u8, try getRequiredString(object, "name")),
                .arguments = try common.cloneJsonValue(allocator, object.get("arguments") orelse .null),
                .thought_signature = if (getOptionalString(object, "thoughtSignature")) |signature| try allocator.dupe(u8, signature) else null,
            };
            try content.append(allocator, .{ .tool_call = try cloneToolCall(allocator, tool_call) });
            try tool_calls.append(allocator, tool_call);
            continue;
        }

        try content.append(allocator, try parseContentBlockObject(allocator, object));
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .tool_calls = if (tool_calls.items.len == 0) null else try tool_calls.toOwnedSlice(allocator),
    };
}

fn parseGenericContentValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const ai.ContentBlock {
    const array = try requireArray(value);
    const blocks = try allocator.alloc(ai.ContentBlock, array.items.len);
    errdefer allocator.free(blocks);

    for (array.items, 0..) |item, index| {
        blocks[index] = try parseContentBlockObject(allocator, try requireObject(item));
    }

    return blocks;
}

fn parseContentBlockObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !ai.ContentBlock {
    const item_type = try getRequiredString(object, "type");

    if (std.mem.eql(u8, item_type, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, try getRequiredString(object, "text")),
            .text_signature = if (getOptionalString(object, "textSignature")) |signature| try allocator.dupe(u8, signature) else null,
        } };
    }

    if (std.mem.eql(u8, item_type, "image")) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, try getRequiredString(object, "data")),
            .mime_type = try allocator.dupe(u8, try getRequiredString(object, "mimeType")),
        } };
    }

    if (std.mem.eql(u8, item_type, "thinking")) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, try getRequiredString(object, "thinking")),
            .thinking_signature = if (getOptionalString(object, "thinkingSignature") orelse getOptionalString(object, "signature")) |signature| try allocator.dupe(u8, signature) else null,
            .signature = if (getOptionalString(object, "thinkingSignature") orelse getOptionalString(object, "signature")) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = getOptionalBool(object, "redacted") orelse false,
        } };
    }

    return error.UnsupportedContentType;
}

fn parseUsageValue(value: std.json.Value) !ai.Usage {
    const object = try requireObject(value);
    const cost_value = object.get("cost");
    const cost = if (cost_value) |raw_cost| try parseUsageCost(raw_cost) else ai.types.UsageCost.init();

    return .{
        .input = try getRequiredU32(object, "input"),
        .output = try getRequiredU32(object, "output"),
        .cache_read = try getRequiredU32(object, "cacheRead"),
        .cache_write = try getRequiredU32(object, "cacheWrite"),
        .total_tokens = try getRequiredU32(object, "totalTokens"),
        .cost = cost,
    };
}

fn parseUsageCost(value: std.json.Value) !ai.types.UsageCost {
    const object = try requireObject(value);
    return .{
        .input = getNumber(object, "input") orelse 0,
        .output = getNumber(object, "output") orelse 0,
        .cache_read = getNumber(object, "cacheRead") orelse 0,
        .cache_write = getNumber(object, "cacheWrite") orelse 0,
        .total = getNumber(object, "total") orelse 0,
    };
}

fn thinkingLevelToString(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn parseThinkingLevel(value: []const u8) !agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return error.InvalidThinkingLevel;
}

fn stopReasonToString(reason: ai.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn parseStopReason(value: []const u8) !ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "toolUse") or std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "error") or std.mem.eql(u8, value, "error_reason")) return .error_reason;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return error.InvalidStopReason;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidSessionFile,
    };
}

fn requireArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidSessionFile,
    };
}

fn getRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidField,
    };
}

fn getRequiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| integer,
        else => error.InvalidField,
    };
}

fn getOptionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        .null => null,
        else => null,
    };
}

fn getOptionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => null,
    };
}

fn getRequiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => error.InvalidField,
    };
}

fn getRequiredI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| @intCast(integer),
        else => error.InvalidField,
    };
}

fn getRequiredU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse return error.InvalidField,
        else => error.InvalidField,
    };
}

fn getNumber(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float_value| float_value,
        else => null,
    };
}

test "session JSONL codec round trips representative lines byte-for-byte" {
    const allocator = std.testing.allocator;

    const header_line = "{\"type\":\"session\",\"version\":3,\"id\":\"session-1\",\"timestamp\":\"100\",\"cwd\":\"/tmp/project\",\"parentSession\":\"/tmp/parent.jsonl\"}";
    var header = try parseHeaderLine(allocator, header_line);
    defer deinitHeader(allocator, &header);
    const encoded_header = try stringifyHeaderLine(allocator, header);
    defer allocator.free(encoded_header);
    try std.testing.expectEqualStrings(header_line, encoded_header);

    const lines = [_][]const u8{
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"101\",\"message\":{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":1}}",
        "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"102\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"world\"},{\"type\":\"toolCall\",\"id\":\"tool-1\",\"name\":\"bash\",\"arguments\":{\"cmd\":\"echo hi\"},\"thoughtSignature\":\"sig\"}],\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"faux-session\",\"responseId\":\"resp-1\",\"responseModel\":\"faux-response\",\"usage\":{\"input\":1,\"output\":2,\"cacheRead\":3,\"cacheWrite\":4,\"totalTokens\":10,\"cost\":{\"input\":0.1,\"output\":0.2,\"cacheRead\":0.3,\"cacheWrite\":0.4,\"total\":1}},\"stopReason\":\"toolUse\",\"timestamp\":2}}",
        "{\"type\":\"message\",\"id\":\"t1\",\"parentId\":\"a1\",\"timestamp\":\"103\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"tool-1\",\"toolName\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"details\":{\"exitCode\":0},\"isError\":false,\"timestamp\":3}}",
        "{\"type\":\"thinking_level_change\",\"id\":\"th1\",\"parentId\":\"t1\",\"timestamp\":\"104\",\"thinkingLevel\":\"high\"}",
        "{\"type\":\"model_change\",\"id\":\"m1\",\"parentId\":\"th1\",\"timestamp\":\"105\",\"provider\":\"faux\",\"modelId\":\"faux-session\"}",
        "{\"type\":\"compaction\",\"id\":\"c1\",\"parentId\":\"m1\",\"timestamp\":\"106\",\"firstKeptEntryId\":\"u1\",\"tokensBefore\":42,\"summary\":\"summary text\"}",
        "{\"type\":\"branch_summary\",\"id\":\"b1\",\"parentId\":\"c1\",\"timestamp\":\"107\",\"fromId\":\"a1\",\"summary\":\"branch text\",\"details\":{\"files\":[\"a.txt\"]},\"fromHook\":true}",
        "{\"type\":\"custom\",\"id\":\"x1\",\"parentId\":\"b1\",\"timestamp\":\"108\",\"customType\":\"ext.state\",\"data\":{\"state\":\"warm\"}}",
        "{\"type\":\"custom_message\",\"id\":\"cm1\",\"parentId\":\"x1\",\"timestamp\":\"109\",\"customType\":\"bashExecution\",\"content\":\"visible output\",\"display\":true,\"details\":{\"excludeFromContext\":true}}",
        "{\"type\":\"label\",\"id\":\"l1\",\"parentId\":\"cm1\",\"timestamp\":\"110\",\"targetId\":\"u1\",\"label\":\"bookmark\"}",
        "{\"type\":\"session_info\",\"id\":\"s1\",\"parentId\":\"l1\",\"timestamp\":\"111\",\"name\":\"Night Shift\"}",
    };

    for (lines) |line| {
        var entry = try parseEntryLine(allocator, line);
        defer deinitEntry(allocator, &entry);
        const encoded = try stringifyEntryLine(allocator, entry);
        defer allocator.free(encoded);
        try std.testing.expectEqualStrings(line, encoded);
    }
}
