const std = @import("std");
const agent = @import("agent");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");

pub const DiagnosticCategory = extension_host.DiagnosticCategory;
pub const ExtensionUiRequest = extension_host.ExtensionUiRequest;
pub const ProcessJsonlOptions = extension_host.HostProcessOptions;
pub const Registry = extension_registry.Registry;
pub const RegistryCallback = *const fn (context: ?*anyopaque, registry: *const Registry) anyerror!void;

pub const RuntimeKind = enum {
    process_jsonl,

    pub fn jsonName(self: RuntimeKind) []const u8 {
        return switch (self) {
            .process_jsonl => "process_jsonl",
        };
    }
};

pub const RuntimeOptions = union(RuntimeKind) {
    process_jsonl: ProcessJsonlOptions,
};

pub const RuntimeSetupErrorEvent = struct {
    runtime_kind: RuntimeKind,
    extension_id: []const u8,
    error_name: []const u8,
    message: []const u8,
    stop_reason: []const u8 = "error_reason",
};

pub const RuntimeSetupEvent = union(enum) {
    ready: RuntimeAdapter,
    error_event: RuntimeSetupErrorEvent,
};

pub const RuntimeSetupEventStream = struct {
    event: ?RuntimeSetupEvent,

    pub fn next(self: *RuntimeSetupEventStream) ?RuntimeSetupEvent {
        const event = self.event orelse return null;
        self.event = null;
        return event;
    }

    pub fn deinit(self: *RuntimeSetupEventStream) void {
        if (self.event) |event| {
            switch (event) {
                .ready => |adapter| adapter.deinit(),
                .error_event => {},
            }
            self.event = null;
        }
    }
};

pub const RuntimeAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    kind: RuntimeKind,

    pub const VTable = struct {
        wait_for_ready: *const fn (*anyopaque, u64) anyerror!void,
        pending_count: *const fn (*anyopaque) usize,
        diagnostic_count: *const fn (*anyopaque) usize,
        diagnostic_category_count: *const fn (*anyopaque, DiagnosticCategory) usize,
        has_shutdown_complete: *const fn (*anyopaque) bool,
        registry_frames_applied: *const fn (*anyopaque) usize,
        has_registered_command: *const fn (*anyopaque, []const u8) bool,
        has_registered_hook: *const fn (*anyopaque, []const u8) bool,
        snapshot_registry_json: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        with_registry: *const fn (*anyopaque, ?*anyopaque, RegistryCallback) anyerror!void,
        apply_cli_flag_values: *const fn (*anyopaque, []const extension_registry.ParsedCliFlag) anyerror!void,
        agent_tool: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?agent.AgentTool,
        take_ui_requests: *const fn (*anyopaque, std.mem.Allocator) anyerror![]ExtensionUiRequest,
        send_extension_ui_response: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        send_extension_event_frame: *const fn (*anyopaque, []const u8) void,
        invoke_extension_event: *const fn (*anyopaque, std.mem.Allocator, []const u8, std.json.Value, u64) anyerror!?std.json.Value,
        shutdown: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn waitForReady(self: RuntimeAdapter, timeout_ms: u64) !void {
        try self.vtable.wait_for_ready(self.ptr, timeout_ms);
    }

    pub fn pendingCount(self: RuntimeAdapter) usize {
        return self.vtable.pending_count(self.ptr);
    }

    pub fn diagnosticCount(self: RuntimeAdapter) usize {
        return self.vtable.diagnostic_count(self.ptr);
    }

    pub fn diagnosticCategoryCount(self: RuntimeAdapter, category: DiagnosticCategory) usize {
        return self.vtable.diagnostic_category_count(self.ptr, category);
    }

    pub fn hasShutdownComplete(self: RuntimeAdapter) bool {
        return self.vtable.has_shutdown_complete(self.ptr);
    }

    pub fn registryFramesApplied(self: RuntimeAdapter) usize {
        return self.vtable.registry_frames_applied(self.ptr);
    }

    pub fn hasRegisteredCommand(self: RuntimeAdapter, name: []const u8) bool {
        return self.vtable.has_registered_command(self.ptr, name);
    }

    pub fn hasRegisteredHook(self: RuntimeAdapter, event_name: []const u8) bool {
        return self.vtable.has_registered_hook(self.ptr, event_name);
    }

    pub fn snapshotRegistryJson(self: RuntimeAdapter, allocator: std.mem.Allocator) ![]u8 {
        return try self.vtable.snapshot_registry_json(self.ptr, allocator);
    }

    pub fn withRegistry(self: RuntimeAdapter, context: ?*anyopaque, callback: RegistryCallback) !void {
        try self.vtable.with_registry(self.ptr, context, callback);
    }

    pub fn applyCliFlagValues(self: RuntimeAdapter, entries: []const extension_registry.ParsedCliFlag) !void {
        try self.vtable.apply_cli_flag_values(self.ptr, entries);
    }

    pub fn agentTool(self: RuntimeAdapter, allocator: std.mem.Allocator, name: []const u8) !?agent.AgentTool {
        return try self.vtable.agent_tool(self.ptr, allocator, name);
    }

    pub fn takeUiRequests(self: RuntimeAdapter, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
        return try self.vtable.take_ui_requests(self.ptr, allocator);
    }

    pub fn sendExtensionUiResponse(self: RuntimeAdapter, id: []const u8, payload_json: []const u8) !void {
        try self.vtable.send_extension_ui_response(self.ptr, id, payload_json);
    }

    pub fn sendExtensionEventFrame(self: RuntimeAdapter, frame_json: []const u8) void {
        self.vtable.send_extension_event_frame(self.ptr, frame_json);
    }

    pub fn invokeExtensionEvent(
        self: RuntimeAdapter,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        event: std.json.Value,
        timeout_ms: u64,
    ) !?std.json.Value {
        return try self.vtable.invoke_extension_event(self.ptr, allocator, event_name, event, timeout_ms);
    }

    pub fn shutdown(self: RuntimeAdapter) !void {
        try self.vtable.shutdown(self.ptr);
    }

    pub fn deinit(self: RuntimeAdapter) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const RuntimeAdapterDispatch = struct {
    process_jsonl: *const fn (std.mem.Allocator, std.Io, ProcessJsonlOptions) anyerror!RuntimeAdapter,
};

pub fn startRuntimeWithDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
    dispatch: RuntimeAdapterDispatch,
) !RuntimeSetupEventStream {
    const adapter = startRuntimeAdapterWithDispatch(allocator, io, options, dispatch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .event = .{ .error_event = .{
            .runtime_kind = .process_jsonl,
            .extension_id = runtimeSetupExtensionId(options),
            .error_name = @errorName(err),
            .message = "runtime setup failed before extension activation completed",
        } } },
    };
    return .{ .event = .{ .ready = adapter } };
}

pub fn streamRuntimeSetupWithDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
    dispatch: RuntimeAdapterDispatch,
) !RuntimeSetupEventStream {
    return try startRuntimeWithDispatch(allocator, io, options, dispatch);
}

pub fn startRuntimeAdapterWithDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeOptions,
    dispatch: RuntimeAdapterDispatch,
) !RuntimeAdapter {
    return switch (options) {
        .process_jsonl => |process_options| try dispatch.process_jsonl(allocator, io, process_options),
    };
}

fn runtimeSetupExtensionId(options: RuntimeOptions) []const u8 {
    return switch (options) {
        .process_jsonl => |process_options| process_options.extension_path orelse "process_jsonl",
    };
}
