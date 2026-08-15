const std = @import("std");
const ts_rpc_wire = @import("ts_rpc_wire.zig");

pub const RpcCommandType = enum {
    prompt,
    steer,
    follow_up,
    abort,
    new_session,
    get_state,
    set_model,
    cycle_model,
    get_available_models,
    set_thinking_level,
    cycle_thinking_level,
    set_steering_mode,
    set_follow_up_mode,
    compact,
    set_auto_compaction,
    set_auto_retry,
    abort_retry,
    bash,
    abort_bash,
    get_session_stats,
    export_html,
    switch_session,
    fork,
    clone,
    get_fork_messages,
    get_last_assistant_text,
    set_session_name,
    get_messages,
    get_commands,
};

pub const SteeringMode = enum {
    all,
    one_at_a_time,
};

pub fn commandTypeName(command_type: RpcCommandType) []const u8 {
    return switch (command_type) {
        .follow_up => "follow_up",
        .new_session => "new_session",
        .get_state => "get_state",
        .set_model => "set_model",
        .cycle_model => "cycle_model",
        .get_available_models => "get_available_models",
        .set_thinking_level => "set_thinking_level",
        .cycle_thinking_level => "cycle_thinking_level",
        .set_steering_mode => "set_steering_mode",
        .set_follow_up_mode => "set_follow_up_mode",
        .set_auto_compaction => "set_auto_compaction",
        .set_auto_retry => "set_auto_retry",
        .abort_retry => "abort_retry",
        .abort_bash => "abort_bash",
        .get_session_stats => "get_session_stats",
        .export_html => "export_html",
        .switch_session => "switch_session",
        .get_fork_messages => "get_fork_messages",
        .get_last_assistant_text => "get_last_assistant_text",
        .set_session_name => "set_session_name",
        .get_messages => "get_messages",
        .get_commands => "get_commands",
        else => @tagName(command_type),
    };
}

pub fn parseCommandType(name: []const u8) ?RpcCommandType {
    inline for (@typeInfo(RpcCommandType).@"enum".fields) |field| {
        const value: RpcCommandType = @enumFromInt(field.value);
        if (std.mem.eql(u8, name, commandTypeName(value))) return value;
    }
    return null;
}

pub fn isKnownCommandType(name: []const u8) bool {
    return ts_rpc_wire.isKnownCommandType(name);
}

test "rpc command type names match wire command list" {
    inline for (@typeInfo(RpcCommandType).@"enum".fields) |field| {
        const value: RpcCommandType = @enumFromInt(field.value);
        try std.testing.expect(isKnownCommandType(commandTypeName(value)));
    }
    try std.testing.expectEqual(RpcCommandType.follow_up, parseCommandType("follow_up").?);
}
