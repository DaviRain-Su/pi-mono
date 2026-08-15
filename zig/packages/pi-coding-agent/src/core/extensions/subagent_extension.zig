const readiness = @import("subagent_readiness.zig");
const reserved = @import("subagent_reserved_names.zig");

pub const SUB_AGENT_READINESS_ENTRY = "sub_agent.readiness";
pub const SUB_AGENT_DELEGATION_RESULT_ENTRY = "sub_agent.delegation.result";
pub const SUB_AGENT_STATUS_MESSAGE = "sub_agent.status";
pub const SUB_AGENT_DELEGATION_TOOL = "sub_agent.delegate";
pub const SUB_AGENT_DELEGATION_COMMAND = "sub-agent";
pub const SUB_AGENT_DELEGATION_CAPABILITY = "agent.delegate";

pub const validateSubAgentReadinessEnvelope = readiness.validateSubAgentReadinessEnvelope;
pub const validateSubAgentTaskInvocationEnvelope = readiness.validateSubAgentTaskInvocationEnvelope;
pub const validateSubAgentTaskResultEnvelope = readiness.validateSubAgentTaskResultEnvelope;
pub const markSubAgentExtensionFactory = reserved.markSubAgentExtensionFactory;
pub const isSubAgentExtensionFactory = reserved.isSubAgentExtensionFactory;
pub const isSubAgentReservedName = reserved.isSubAgentReservedName;
pub const assertSubAgentReservedNameAllowed = reserved.assertSubAgentReservedNameAllowed;

test "sub-agent extension constants match registered surfaces" {
    try @import("std").testing.expect(isSubAgentReservedName(SUB_AGENT_DELEGATION_TOOL));
}
