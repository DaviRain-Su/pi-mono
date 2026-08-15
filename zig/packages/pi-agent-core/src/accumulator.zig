const std = @import("std");
const pi_types = @import("pi-types");
const types = @import("types.zig");
const content_clone = @import("content_clone.zig");
const agent_loop = @import("agent_loop.zig");

/// Accumulates partial content blocks (text, thinking, tool_call) from a
/// streaming assistant response. Deltas are applied in order; explicit
/// content indices may be sparse but must not be reused after end.
pub const PartialToolCallBlock = struct {
    arguments: std.ArrayList(u8) = .empty,
    final_tool_call: ?pi_types.ToolCall = null,

    pub fn deinit(self: *PartialToolCallBlock, allocator: std.mem.Allocator) void {
        self.arguments.deinit(allocator);
        if (self.final_tool_call) |tool_call| content_clone.deinitToolCall(allocator, tool_call);
        self.* = undefined;
    }

    pub fn appendDelta(self: *PartialToolCallBlock, allocator: std.mem.Allocator, delta: []const u8) !void {
        try self.arguments.appendSlice(allocator, delta);
    }

    pub fn setFinal(self: *PartialToolCallBlock, allocator: std.mem.Allocator, tool_call: pi_types.ToolCall) !void {
        const cloned = try content_clone.cloneToolCall(allocator, tool_call);
        if (self.final_tool_call) |existing| content_clone.deinitToolCall(allocator, existing);
        self.final_tool_call = cloned;
    }
};

const PartialContentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    tool_call: PartialToolCallBlock,

    fn deinit(self: *PartialContentBlock, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |*text| text.deinit(allocator),
            .thinking => |*thinking| thinking.deinit(allocator),
            .tool_call => |*tool_call| tool_call.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const PartialAssistantAccumulator = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(PartialContentBlock) = .empty,
    index_map: std.ArrayList(?usize) = .empty,
    ended_blocks: std.ArrayList(bool) = .empty,

    pub fn init(allocator: std.mem.Allocator) PartialAssistantAccumulator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PartialAssistantAccumulator) void {
        for (self.blocks.items) |*block| block.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.index_map.deinit(self.allocator);
        self.ended_blocks.deinit(self.allocator);
    }

    fn indexFor(
        self: *PartialAssistantAccumulator,
        event: pi_types.AssistantMessageEvent,
        allow_new_explicit_index: bool,
    ) !usize {
        if (event.content_index) |content_index| {
            const requested: usize = @intCast(content_index);
            if (requested < self.index_map.items.len) {
                if (self.index_map.items[requested]) |mapped| {
                    if (self.isEnded(mapped)) return types.AgentLoopError.PartialContentIndexReused;
                    return mapped;
                }
            }
            if (!allow_new_explicit_index) return types.AgentLoopError.PartialContentOutOfOrder;
            while (self.index_map.items.len <= requested) {
                try self.index_map.append(self.allocator, null);
            }
            const mapped = self.blocks.items.len;
            self.index_map.items[requested] = mapped;
            return mapped;
        }
        return if (self.blocks.items.len == 0) 0 else self.blocks.items.len - 1;
    }

    fn startIndex(self: *PartialAssistantAccumulator, event: pi_types.AssistantMessageEvent) !usize {
        if (event.content_index) |content_index| {
            const requested: usize = @intCast(content_index);
            if (requested < self.index_map.items.len) {
                if (self.index_map.items[requested]) |mapped| {
                    if (self.isEnded(mapped)) return types.AgentLoopError.PartialContentIndexReused;
                    return types.AgentLoopError.PartialContentOutOfOrder;
                }
            }
            while (self.index_map.items.len <= requested) {
                try self.index_map.append(self.allocator, null);
            }
            const mapped = self.blocks.items.len;
            self.index_map.items[requested] = mapped;
            return mapped;
        }
        return self.blocks.items.len;
    }

    fn isEnded(self: *PartialAssistantAccumulator, index: usize) bool {
        return index < self.ended_blocks.items.len and self.ended_blocks.items[index];
    }

    fn markEnded(self: *PartialAssistantAccumulator, index: usize) void {
        std.debug.assert(index < self.ended_blocks.items.len);
        self.ended_blocks.items[index] = true;
    }

    fn ensureIndex(self: *PartialAssistantAccumulator, index: usize) !void {
        while (self.blocks.items.len <= index) {
            try self.blocks.ensureUnusedCapacity(self.allocator, 1);
            try self.ended_blocks.ensureUnusedCapacity(self.allocator, 1);
            const next_index = self.blocks.items.len;
            self.blocks.items.len = next_index + 1;
            self.blocks.items[next_index] = .{ .text = .empty };
            self.ended_blocks.items.len = next_index + 1;
            self.ended_blocks.items[next_index] = false;
        }
    }

    fn FieldPayload(comptime tag: std.meta.Tag(PartialContentBlock)) type {
        return @FieldType(PartialContentBlock, @tagName(tag));
    }

    fn defaultPayload(comptime tag: std.meta.Tag(PartialContentBlock)) FieldPayload(tag) {
        return switch (tag) {
            .text, .thinking => .empty,
            .tool_call => .{},
        };
    }

    fn ensureKind(
        self: *PartialAssistantAccumulator,
        comptime tag: std.meta.Tag(PartialContentBlock),
        index: usize,
    ) !*FieldPayload(tag) {
        try self.ensureIndex(index);
        if (self.blocks.items[index] != tag) {
            self.blocks.items[index].deinit(self.allocator);
            self.blocks.items[index] = @unionInit(PartialContentBlock, @tagName(tag), defaultPayload(tag));
        }
        return &@field(self.blocks.items[index], @tagName(tag));
    }

    fn requireKind(
        self: *PartialAssistantAccumulator,
        comptime tag: std.meta.Tag(PartialContentBlock),
        index: usize,
    ) !*FieldPayload(tag) {
        try self.ensureIndex(index);
        if (self.blocks.items[index] != tag) {
            return types.AgentLoopError.PartialContentOutOfOrder;
        }
        return &@field(self.blocks.items[index], @tagName(tag));
    }

    pub fn applyEvent(self: *PartialAssistantAccumulator, event: pi_types.AssistantMessageEvent) !void {
        switch (event.event_type) {
            .text_start => {
                const index = try self.startIndex(event);
                const text = try self.ensureKind(.text, index);
                text.clearRetainingCapacity();
            },
            .text_delta => {
                const index = try self.indexFor(event, false);
                const text = try self.requireKind(.text, index);
                if (event.delta) |delta| try text.appendSlice(self.allocator, delta);
            },
            .text_end => {
                const index = try self.indexFor(event, false);
                const text = try self.requireKind(.text, index);
                text.clearRetainingCapacity();
                if (event.content) |content| try text.appendSlice(self.allocator, content);
                self.markEnded(index);
            },
            .thinking_start => {
                const index = try self.startIndex(event);
                const thinking = try self.ensureKind(.thinking, index);
                thinking.clearRetainingCapacity();
            },
            .thinking_delta => {
                const index = try self.indexFor(event, false);
                const thinking = try self.requireKind(.thinking, index);
                if (event.delta) |delta| try thinking.appendSlice(self.allocator, delta);
            },
            .thinking_end => {
                const index = try self.indexFor(event, false);
                const thinking = try self.requireKind(.thinking, index);
                thinking.clearRetainingCapacity();
                if (event.content) |content| try thinking.appendSlice(self.allocator, content);
                self.markEnded(index);
            },
            .toolcall_start => {
                const index = try self.startIndex(event);
                _ = try self.ensureKind(.tool_call, index);
            },
            .toolcall_delta => {
                const index = try self.indexFor(event, false);
                const tool_call = try self.requireKind(.tool_call, index);
                if (event.delta) |delta| try tool_call.appendDelta(self.allocator, delta);
            },
            .toolcall_end => {
                const index = try self.indexFor(event, false);
                const tool_call = try self.requireKind(.tool_call, index);
                if (event.tool_call) |final_tool_call| try tool_call.setFinal(self.allocator, final_tool_call);
                self.markEnded(index);
            },
            else => {},
        }
    }

    pub fn hasOnlyLeadingToolCall(self: *const PartialAssistantAccumulator) bool {
        return self.blocks.items.len == 1 and self.blocks.items[0] == .tool_call;
    }

    pub fn buildMessage(
        self: *PartialAssistantAccumulator,
        allocator: std.mem.Allocator,
        template: pi_types.AssistantMessage,
    ) !pi_types.AssistantMessage {
        var partial = template;
        var content_list = std.ArrayList(pi_types.ContentBlock).empty;
        errdefer {
            for (content_list.items) |item| {
                switch (item) {
                    .text => |text| allocator.free(text.text),
                    .thinking => |thinking| allocator.free(thinking.thinking),
                    .tool_call => |tool_call| content_clone.deinitToolCall(allocator, tool_call),
                    else => {},
                }
            }
            content_list.deinit(allocator);
        }

        for (self.blocks.items) |block| {
            switch (block) {
                .text => |text| {
                    try content_list.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, text.items) } });
                },
                .thinking => |thinking| {
                    try content_list.append(allocator, .{ .thinking = .{ .thinking = try allocator.dupe(u8, thinking.items), .signature = null, .redacted = false } });
                },
                .tool_call => |tool_call| {
                    try content_list.append(allocator, try buildPartialToolCallBlock(allocator, tool_call));
                },
            }
        }

        partial.content = try content_list.toOwnedSlice(allocator);
        partial.tool_calls = null;
        return partial;
    }
};

fn buildPartialToolCallBlock(
    allocator: std.mem.Allocator,
    tool_call: PartialToolCallBlock,
) !pi_types.ContentBlock {
    if (tool_call.final_tool_call) |final_tool_call| {
        return .{ .tool_call = final_tool_call };
    }

    const parsed = pi_types.json_parse.parseStreamingJson(allocator, tool_call.arguments.items) catch null;
    const arguments: std.json.Value = if (parsed) |value| switch (value.value) {
        .object => value.value,
        else => try emptyJsonObject(allocator),
    } else try emptyJsonObject(allocator);
    return .{ .tool_call = .{
        .id = "",
        .name = "",
        .arguments = arguments,
    } };
}

fn emptyJsonObject(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
}
