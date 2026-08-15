pub const default_extension_handler_timeout_ms: u64 = 5000;

pub const LifecycleSupportRuntime = enum {
    typescript,
    process_jsonl,
};

pub const LifecycleSupportEntry = struct {
    runtime: LifecycleSupportRuntime,
    event_names: []const []const u8,
    payload_fields: []const []const u8,
    reasons: []const []const u8,
    result_types: []const []const u8,
    timeout_source: []const u8,
    timeout_default_ms: u64,
    timeout_override: []const u8,
    abort_supported: bool,
    late_results: []const u8,
    shutdown_supported: bool,
    shutdown_exactly_once: bool,
    unsupported_diagnostics: bool,
};

const lifecycle_reason_names = [_][]const u8{ "startup", "reload", "new", "resume", "fork" };
const lifecycle_result_types = [_][]const u8{ "none", "cancellable", "resources" };
const lifecycle_payload_fields = [_][]const u8{ "type", "reason", "previousSessionFile", "targetSessionFile", "cwd", "signal" };
const lifecycle_all_event_names = [_][]const u8{
    "resources_discover",
    "session_start",
    "session_before_switch",
    "session_before_fork",
    "session_before_compact",
    "session_compact",
    "session_shutdown",
    "session_before_tree",
    "session_tree",
    "before_agent_start",
    "agent_start",
    "agent_end",
    "sub_agent_readiness",
    "turn_start",
    "turn_end",
    "message_start",
    "message_update",
    "message_end",
    "tool_execution_start",
    "tool_execution_update",
    "tool_execution_end",
    "tool_call",
    "tool_result",
    "user_bash",
    "context",
    "before_provider_request",
    "after_provider_response",
    "model_select",
    "thinking_level_select",
    "input",
};

pub fn lifecycleSupportMatrix() []const LifecycleSupportEntry {
    return &.{
        .{
            .runtime = .typescript,
            .event_names = &lifecycle_all_event_names,
            .payload_fields = &lifecycle_payload_fields,
            .reasons = &lifecycle_reason_names,
            .result_types = &lifecycle_result_types,
            .timeout_source = "lifecycle-handler-timeout-ms",
            .timeout_default_ms = default_extension_handler_timeout_ms,
            .timeout_override = "ExtensionRunnerOptions.handlerTimeoutMs",
            .abort_supported = true,
            .late_results = "ignored",
            .shutdown_supported = true,
            .shutdown_exactly_once = true,
            .unsupported_diagnostics = true,
        },
        .{
            .runtime = .process_jsonl,
            .event_names = &lifecycle_all_event_names,
            .payload_fields = &lifecycle_payload_fields,
            .reasons = &lifecycle_reason_names,
            .result_types = &lifecycle_result_types,
            .timeout_source = "lifecycle-handler-timeout-ms",
            .timeout_default_ms = default_extension_handler_timeout_ms,
            .timeout_override = "runtime host options",
            .abort_supported = false,
            .late_results = "ignored",
            .shutdown_supported = true,
            .shutdown_exactly_once = true,
            .unsupported_diagnostics = true,
        },
    };
}
