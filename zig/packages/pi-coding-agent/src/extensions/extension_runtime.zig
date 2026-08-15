const std = @import("std");
const agent = @import("agent");
const extension_host = @import("extension_host.zig");
const tools_common = @import("../tools/common.zig");
const lifecycle_support = @import("lifecycle_support.zig");
const policy_key_mod = @import("policy_key.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const policy_resource_helpers = @import("policy_resource_helpers.zig");
const process_runtime_adapter = @import("process_runtime_adapter.zig");

pub const typeScriptPolicyLookupKey = policy_key_mod.typeScriptPolicyLookupKey;
pub const TypeScriptPolicyLookupOptions = policy_key_mod.TypeScriptPolicyLookupOptions;

pub const DiagnosticCategory = runtime_adapter.DiagnosticCategory;
pub const ExtensionUiRequest = runtime_adapter.ExtensionUiRequest;
pub const HOST_MARKER_ENV = extension_host.HOST_MARKER_ENV;
pub const InitializeFrame = extension_host.InitializeFrame;
pub const ProcessJsonlOptions = runtime_adapter.ProcessJsonlOptions;
pub const Registry = runtime_adapter.Registry;
pub const RegistryCallback = runtime_adapter.RegistryCallback;
pub const RuntimeKind = runtime_adapter.RuntimeKind;
pub const RuntimeOptions = runtime_adapter.RuntimeOptions;
pub const RuntimeSetupErrorEvent = runtime_adapter.RuntimeSetupErrorEvent;
pub const RuntimeSetupEvent = runtime_adapter.RuntimeSetupEvent;
pub const RuntimeSetupEventStream = runtime_adapter.RuntimeSetupEventStream;
pub const RuntimeAdapter = runtime_adapter.RuntimeAdapter;

pub const default_extension_handler_timeout_ms = lifecycle_support.default_extension_handler_timeout_ms;
pub const LifecycleSupportRuntime = lifecycle_support.LifecycleSupportRuntime;
pub const LifecycleSupportEntry = lifecycle_support.LifecycleSupportEntry;
pub const lifecycleSupportMatrix = lifecycle_support.lifecycleSupportMatrix;

const runtime_adapter_dispatch = runtime_adapter.RuntimeAdapterDispatch{
    .process_jsonl = process_runtime_adapter.startProcessJsonl,
};

pub fn startRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
) !RuntimeSetupEventStream {
    return runtime_adapter.startRuntimeWithDispatch(allocator, io, options, runtime_adapter_dispatch);
}

pub fn streamRuntimeSetup(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
) !RuntimeSetupEventStream {
    return runtime_adapter.streamRuntimeSetupWithDispatch(allocator, io, options, runtime_adapter_dispatch);
}

pub fn startRuntimeAdapter(allocator: std.mem.Allocator, io: std.Io, options: RuntimeOptions) !RuntimeAdapter {
    return runtime_adapter.startRuntimeAdapterWithDispatch(allocator, io, options, runtime_adapter_dispatch);
}

pub fn deinitAgentTool(allocator: std.mem.Allocator, tool: *agent.AgentTool) void {
    tools_common.deinitJsonValue(allocator, tool.parameters);
    if (tool.deinit_execute_context) |deinit_context| deinit_context(allocator, tool.execute_context);
    tool.* = undefined;
}

pub const startProcessJsonl = process_runtime_adapter.startProcessJsonl;
