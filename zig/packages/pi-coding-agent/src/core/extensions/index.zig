pub const types = @import("types.zig");
pub const loader = @import("loader.zig");
pub const runner = @import("runner.zig");
pub const wrapper = @import("wrapper.zig");
pub const subagent_readiness = @import("subagent_readiness.zig");
pub const subagent_reserved_names = @import("subagent_reserved_names.zig");
pub const subagent_extension = @import("subagent_extension.zig");
pub const bounded_subagent_execution = @import("bounded_subagent_execution.zig");

pub const wrapToolDefinition = wrapper.wrapToolDefinition;
pub const wrapToolDefinitions = wrapper.wrapToolDefinitions;
pub const validateSubAgentReadinessEnvelope = subagent_readiness.validateSubAgentReadinessEnvelope;
pub const isSubAgentReservedName = subagent_reserved_names.isSubAgentReservedName;

test {
    _ = @import("types.zig");
    _ = @import("loader.zig");
    _ = @import("runner.zig");
    _ = @import("wrapper.zig");
    _ = @import("subagent_readiness.zig");
    _ = @import("subagent_reserved_names.zig");
    _ = @import("subagent_extension.zig");
    _ = @import("bounded_subagent_execution.zig");
}
