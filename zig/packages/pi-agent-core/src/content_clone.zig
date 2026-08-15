const std = @import("std");
const pi_types = @import("pi-types");
const provider_json = pi_types.json;
const types = @import("types.zig");

/// Deep-clone an `AgentToolResult` content block slice.
pub fn cloneToolResult(
    result: types.AgentToolResult,
    allocator: std.mem.Allocator,
) !types.AgentToolResult {
    return .{
        .content = try cloneContentBlocks(allocator, result.content),
        .details = if (result.details) |details| try provider_json.cloneValue(allocator, details) else null,
        .is_error = result.is_error,
        .terminate = result.terminate,
    };
}

/// Deep-clone a slice of `pi_types.ContentBlock`. Caller must pair with `deinitContentBlocks`.
pub fn cloneContentBlocks(
    allocator: std.mem.Allocator,
    blocks: []const pi_types.ContentBlock,
) ![]const pi_types.ContentBlock {
    const cloned = try allocator.alloc(pi_types.ContentBlock, blocks.len);
    var initialized_len: usize = 0;
    errdefer {
        deinitContentBlocks(allocator, cloned[0..initialized_len]);
        allocator.free(cloned);
    }

    for (blocks, 0..) |block, index| {
        cloned[index] = try cloneContentBlock(allocator, block);
        initialized_len += 1;
    }

    return cloned;
}

/// Deep-clone a single `pi_types.ContentBlock`.
pub fn cloneContentBlock(allocator: std.mem.Allocator, block: pi_types.ContentBlock) !pi_types.ContentBlock {
    return switch (block) {
        .text => |text| blk: {
            const owned_text = try allocator.dupe(u8, text.text);
            errdefer allocator.free(owned_text);

            const text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null;
            errdefer if (text_signature) |signature| allocator.free(signature);

            break :blk .{
                .text = .{
                    .text = owned_text,
                    .text_signature = text_signature,
                },
            };
        },
        .image => |image| blk: {
            const data = try allocator.dupe(u8, image.data);
            errdefer allocator.free(data);

            const mime_type = try allocator.dupe(u8, image.mime_type);
            errdefer allocator.free(mime_type);

            break :blk .{
                .image = .{
                    .data = data,
                    .mime_type = mime_type,
                },
            };
        },
        .thinking => |thinking| blk: {
            const thinking_text = try allocator.dupe(u8, thinking.thinking);
            errdefer allocator.free(thinking_text);

            const source_signature = pi_types.thinkingSignature(thinking);
            const thinking_signature = if (source_signature) |signature| try allocator.dupe(u8, signature) else null;
            errdefer if (thinking_signature) |signature| allocator.free(signature);

            const signature = if (source_signature) |source| try allocator.dupe(u8, source) else null;
            errdefer if (signature) |owned_signature| allocator.free(owned_signature);

            break :blk .{
                .thinking = .{
                    .thinking = thinking_text,
                    .thinking_signature = thinking_signature,
                    .signature = signature,
                    .redacted = thinking.redacted,
                },
            };
        },
        .tool_call => |tool_call| .{ .tool_call = try cloneToolCall(allocator, tool_call) },
    };
}

/// Release resources owned by cloned content blocks.
pub fn deinitContentBlocks(
    allocator: std.mem.Allocator,
    blocks: []const pi_types.ContentBlock,
) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
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
}

/// Deep-clone an `pi_types.ToolCall`. Caller must pair with `deinitToolCall`.
pub fn cloneToolCall(allocator: std.mem.Allocator, tool_call: pi_types.ToolCall) !pi_types.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);

    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);

    const arguments = try provider_json.cloneValue(allocator, tool_call.arguments);
    errdefer provider_json.freeValue(allocator, arguments);

    const thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null;
    errdefer if (thought_signature) |signature| allocator.free(signature);

    const namespace = if (tool_call.namespace) |value| try allocator.dupe(u8, value) else null;
    errdefer if (namespace) |value| allocator.free(value);

    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
        .thought_signature = thought_signature,
        .namespace = namespace,
    };
}

/// Release resources owned by a cloned `pi_types.ToolCall`.
pub fn deinitToolCall(allocator: std.mem.Allocator, tool_call: pi_types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    if (tool_call.namespace) |namespace| allocator.free(namespace);
    provider_json.freeValue(allocator, tool_call.arguments);
}

/// Check if two content block slices point to the same memory.
pub fn sameContentBlocks(
    lhs: []const pi_types.ContentBlock,
    rhs: []const pi_types.ContentBlock,
) bool {
    return lhs.len == rhs.len and lhs.ptr == rhs.ptr;
}
