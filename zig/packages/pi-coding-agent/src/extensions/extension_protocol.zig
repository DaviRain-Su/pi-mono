const std = @import("std");
const ai = @import("ai");
const string_utils = ai.shared.string_utils;
const common = @import("../tools/common.zig");
const enforcement = @import("enforcement.zig");
const extension_events = @import("extension_events.zig");
const extension_registry = @import("extension_registry.zig");

pub const DiagnosticCategory = enum {
    blank_frame,
    malformed_json,
    non_object_frame,
    unsupported_message_type,
    duplicate_ready,
    duplicate_pending_request,
    incomplete_frame,
    startup_failure,
    host_error,
    host_exit,
    host_stderr,

    pub fn jsonName(self: DiagnosticCategory) []const u8 {
        return switch (self) {
            .blank_frame => "blank_frame",
            .malformed_json => "malformed_json",
            .non_object_frame => "non_object_frame",
            .unsupported_message_type => "unsupported_message_type",
            .duplicate_ready => "duplicate_ready",
            .duplicate_pending_request => "duplicate_pending_request",
            .incomplete_frame => "incomplete_frame",
            .startup_failure => "startup_failure",
            .host_error => "host_error",
            .host_exit => "host_exit",
            .host_stderr => "host_stderr",
        };
    }
};

pub const DiagnosticSeverity = enum {
    info,
    warning,
    @"error",

    pub fn jsonName(self: DiagnosticSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const Diagnostic = struct {
    category: DiagnosticCategory,
    severity: DiagnosticSeverity,
    message: []u8,

    pub fn clone(allocator: std.mem.Allocator, diagnostic: Diagnostic) !Diagnostic {
        return .{
            .category = diagnostic.category,
            .severity = diagnostic.severity,
            .message = try allocator.dupe(u8, diagnostic.message),
        };
    }

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ExtensionUiRequest = struct {
    id: []u8,
    method: []u8,
    response_required: bool = false,
    payload_json: []u8,

    pub fn clone(allocator: std.mem.Allocator, request: ExtensionUiRequest) !ExtensionUiRequest {
        return .{
            .id = try allocator.dupe(u8, request.id),
            .method = try allocator.dupe(u8, request.method),
            .response_required = request.response_required,
            .payload_json = try allocator.dupe(u8, request.payload_json),
        };
    }

    pub fn deinit(self: *ExtensionUiRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.method);
        allocator.free(self.payload_json);
        self.* = undefined;
    }
};

/// Live Bun JSONL `register_*`/`unregister_*` registration frame. The
/// host parser owns a deep-cloned copy of the JSON object payload so
/// the protocol state can apply it to the runtime registry on the
/// host's mutex-guarded thread without holding a reference to the
/// short-lived parser arena.
pub const RegistryFrame = struct {
    payload: std.json.Value,

    pub fn deinit(self: *RegistryFrame, allocator: std.mem.Allocator) void {
        common.deinitJsonValue(allocator, self.payload);
        self.* = undefined;
    }
};

pub const ToolExecutionResponse = struct {
    tool_call_id: []u8,
    content: []const ai.ContentBlock,
    details: ?std.json.Value = null,
    is_error: bool = false,

    pub fn clone(allocator: std.mem.Allocator, response: ToolExecutionResponse) !ToolExecutionResponse {
        return .{
            .tool_call_id = try allocator.dupe(u8, response.tool_call_id),
            .content = try cloneContentBlocks(allocator, response.content),
            .details = if (response.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .is_error = response.is_error,
        };
    }

    pub fn deinit(self: *ToolExecutionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        common.deinitContentBlocks(allocator, self.content);
        if (self.details) |details| common.deinitJsonValue(allocator, details);
        self.* = undefined;
    }
};

pub const ExtensionEventResponse = struct {
    event_id: []u8,
    result: ?std.json.Value = null,
    error_message: ?[]u8 = null,
    fatal: bool = false,

    pub fn clone(allocator: std.mem.Allocator, response: ExtensionEventResponse) !ExtensionEventResponse {
        return .{
            .event_id = try allocator.dupe(u8, response.event_id),
            .result = if (response.result) |result| try common.cloneJsonValue(allocator, result) else null,
            .error_message = if (response.error_message) |message| try allocator.dupe(u8, message) else null,
            .fatal = response.fatal,
        };
    }

    pub fn deinit(self: *ExtensionEventResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.event_id);
        if (self.result) |result| common.deinitJsonValue(allocator, result);
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }
};

pub const HostMessage = union(enum) {
    ready,
    diagnostic: Diagnostic,
    extension_ui_request: ExtensionUiRequest,
    shutdown_complete,
    error_message: Diagnostic,
    tool_response: ToolExecutionResponse,
    extension_event_response: ExtensionEventResponse,
    /// Live Bun-hosted register_tool / register_command /
    /// register_shortcut / register_flag / register_provider /
    /// unregister_provider frame. Routed through `ProtocolState` to
    /// `extension_registry.applyHostFrame` so the runtime registry
    /// reflects extension contributions in CLI / TS-RPC output.
    registry_frame: RegistryFrame,

    pub fn deinit(self: *HostMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .diagnostic => |*diagnostic| diagnostic.deinit(allocator),
            .extension_ui_request => |*request| request.deinit(allocator),
            .error_message => |*diagnostic| diagnostic.deinit(allocator),
            .tool_response => |*response| response.deinit(allocator),
            .extension_event_response => |*response| response.deinit(allocator),
            .registry_frame => |*frame| frame.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

/// Names of JSONL message types that carry registration data.
const REGISTRY_FRAME_TYPES = [_][]const u8{
    "register_tool",
    "register_command",
    "register_shortcut",
    "register_flag",
    "register_provider",
    "unregister_provider",
    "register_capability",
    "unregister_capability",
    "register_workflow",
    "unregister_workflow",
    "register_hook",
    "unregister_hook",
    "set_header",
    "clear_header",
    "set_footer",
    "clear_footer",
    "register_terminal_input",
    "unregister_terminal_input",
    "set_editor_component",
    "clear_editor_component",
    "set_widget",
    "clear_widget",
    "clear_ui_hooks_for_reload",
    "clear_extension_registrations",
    "resources_discover",
    "register_message_renderer",
    "unregister_message_renderer",
};

pub fn registryFrameTypeNames() []const []const u8 {
    return REGISTRY_FRAME_TYPES[0..];
}

pub fn diagnosticCategoryNames() []const []const u8 {
    return &.{
        "blank_frame",
        "malformed_json",
        "non_object_frame",
        "unsupported_message_type",
        "duplicate_ready",
        "duplicate_pending_request",
        "incomplete_frame",
        "startup_failure",
        "host_error",
        "host_exit",
        "host_stderr",
    };
}

fn isRegistryFrameType(type_name: []const u8) bool {
    inline for (REGISTRY_FRAME_TYPES) |candidate| {
        if (std.mem.eql(u8, type_name, candidate)) return true;
    }
    return false;
}

pub const JsonlFrameParser = struct {
    buffer: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *JsonlFrameParser, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn feed(self: *JsonlFrameParser, allocator: std.mem.Allocator, bytes: []const u8, sink: anytype) !void {
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.processLine(allocator, self.buffer.items, sink);
                self.buffer.clearRetainingCapacity();
            } else {
                try self.buffer.append(allocator, byte);
            }
        }
    }

    pub fn finish(self: *JsonlFrameParser, allocator: std.mem.Allocator, sink: anytype) !void {
        const trimmed = std.mem.trim(u8, self.buffer.items, " \t\r\n");
        if (trimmed.len != 0) {
            try sink.onDiagnostic(.{
                .category = .incomplete_frame,
                .severity = .@"error",
                .message = try allocator.dupe(u8, "host stdout ended with an incomplete JSONL frame"),
            });
        }
        self.buffer.clearRetainingCapacity();
    }

    fn processLine(self: *JsonlFrameParser, allocator: std.mem.Allocator, raw_line: []const u8, sink: anytype) !void {
        _ = self;
        const line = stripTrailingCarriageReturn(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            try sink.onDiagnostic(.{
                .category = .blank_frame,
                .severity = .warning,
                .message = try allocator.dupe(u8, "host emitted a blank JSONL frame"),
            });
            return;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            try sink.onDiagnostic(.{
                .category = .malformed_json,
                .severity = .@"error",
                .message = try allocator.dupe(u8, "host emitted malformed JSON"),
            });
            return;
        };
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |object| object,
            else => {
                try sink.onDiagnostic(.{
                    .category = .non_object_frame,
                    .severity = .@"error",
                    .message = try allocator.dupe(u8, "host frame must be a JSON object"),
                });
                return;
            },
        };

        var message = parseObjectMessage(allocator, object) catch |err| switch (err) {
            error.UnsupportedHostMessageType => {
                try sink.onDiagnostic(.{
                    .category = .unsupported_message_type,
                    .severity = .@"error",
                    .message = try allocator.dupe(u8, "host emitted an unsupported message type"),
                });
                return;
            },
            else => return err,
        };
        defer message.deinit(allocator);
        try sink.onMessage(message);
    }
};

pub const ProtocolState = struct {
    allocator: std.mem.Allocator,
    ready_seen: bool = false,
    shutdown_complete_seen: bool = false,
    pending_requests_closed: bool = false,
    pending_request_ids: std.StringHashMap(void),
    pending_extension_event_ids: std.StringHashMap(void),
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    ui_requests: std.ArrayList(ExtensionUiRequest) = .empty,
    tool_responses: std.ArrayList(ToolExecutionResponse) = .empty,
    extension_event_responses: std.ArrayList(ExtensionEventResponse) = .empty,
    /// Live runtime registry populated as register_* JSONL frames
    /// arrive over the host stdout protocol. Mirrors the TypeScript
    /// `runtime.extensionState.registry` shape so CLI / TS-RPC consumers
    /// can observe registered tools, commands, shortcuts, flags, and
    /// providers without depending on local sidecar manifests.
    registry: extension_registry.Registry,
    registry_policy: enforcement.Policy = .{},
    registry_principal: enforcement.Principal = .{
        .runtime_kind = "process_jsonl",
        .extension_id = "process_jsonl:unknown",
    },
    registry_accounting: enforcement.Accounting = .{},
    /// Total number of registry frames successfully applied. Useful for
    /// fixture tests that need to wait for the host to drain its
    /// register_* frames before snapshotting.
    registry_frames_applied: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ProtocolState {
        return .{
            .allocator = allocator,
            .pending_request_ids = std.StringHashMap(void).init(allocator),
            .pending_extension_event_ids = std.StringHashMap(void).init(allocator),
            .registry = extension_registry.Registry.init(allocator),
        };
    }

    pub fn initWithPolicy(
        allocator: std.mem.Allocator,
        policy: enforcement.Policy,
        principal: enforcement.Principal,
    ) ProtocolState {
        var state = ProtocolState.init(allocator);
        state.registry_policy = policy;
        state.registry_principal = principal;
        return state;
    }

    pub fn deinit(self: *ProtocolState) void {
        var pending_iterator = self.pending_request_ids.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_request_ids.deinit();
        var pending_extension_iterator = self.pending_extension_event_ids.iterator();
        while (pending_extension_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_extension_event_ids.deinit();

        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        for (self.ui_requests.items) |*request| request.deinit(self.allocator);
        self.ui_requests.deinit(self.allocator);
        for (self.tool_responses.items) |*response| response.deinit(self.allocator);
        self.tool_responses.deinit(self.allocator);
        for (self.extension_event_responses.items) |*response| response.deinit(self.allocator);
        self.extension_event_responses.deinit(self.allocator);
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn onMessage(self: *ProtocolState, message: HostMessage) !void {
        switch (message) {
            .ready => {
                if (self.ready_seen) {
                    try self.addDiagnostic(.duplicate_ready, .@"error", "host emitted duplicate readiness");
                    return;
                }
                self.ready_seen = true;
            },
            .diagnostic => |diagnostic| try self.diagnostics.append(self.allocator, try Diagnostic.clone(self.allocator, diagnostic)),
            .error_message => |diagnostic| try self.diagnostics.append(self.allocator, try Diagnostic.clone(self.allocator, diagnostic)),
            .tool_response => |response| try self.tool_responses.append(self.allocator, try ToolExecutionResponse.clone(self.allocator, response)),
            .extension_event_response => |response| {
                if (self.resolvePendingExtensionEventRequest(response.event_id)) {
                    try self.extension_event_responses.append(self.allocator, try ExtensionEventResponse.clone(self.allocator, response));
                } else {
                    try self.addDiagnostic(.host_error, .warning, "host emitted stale or unknown extension event response");
                }
            },
            .extension_ui_request => |request| {
                if (!self.ready_seen) {
                    try self.addDiagnostic(.host_error, .@"error", "host emitted UI request before readiness");
                    return;
                }
                if (self.pending_requests_closed) return;
                if (request.response_required) {
                    if (self.pending_request_ids.contains(request.id)) {
                        try self.addDiagnostic(.duplicate_pending_request, .@"error", "host emitted duplicate pending request id");
                        return;
                    }
                    try self.pending_request_ids.put(try self.allocator.dupe(u8, request.id), {});
                }
                try self.ui_requests.append(self.allocator, try ExtensionUiRequest.clone(self.allocator, request));
            },
            .shutdown_complete => self.shutdown_complete_seen = true,
            .registry_frame => |frame| {
                const outcome = try self.applyRegistryFrame(frame.payload);
                switch (outcome) {
                    .registered_tool,
                    .registered_command,
                    .registered_shortcut,
                    .registered_flag,
                    .registered_provider,
                    .unregistered_provider,
                    .registered_capability,
                    .unregistered_capability,
                    .registered_workflow,
                    .unregistered_workflow,
                    .registered_hook,
                    .unregistered_hook,
                    .set_header_hook,
                    .cleared_header_hook,
                    .set_footer_hook,
                    .cleared_footer_hook,
                    .registered_terminal_input,
                    .unregistered_terminal_input,
                    .set_editor_component_hook,
                    .cleared_editor_component_hook,
                    .set_widget_hook,
                    .cleared_widget_hook,
                    .cleared_ui_hooks_for_reload,
                    .cleared_extension_registrations,
                    .resources_discovered,
                    .registered_message_renderer,
                    .unregistered_message_renderer,
                    => self.registry_frames_applied += 1,
                    .none, .ignored_unsupported, .ignored_malformed, .ignored_collision => {},
                }
            },
        }
    }

    fn applyRegistryFrame(self: *ProtocolState, frame: std.json.Value) !extension_registry.FrameOutcome {
        const type_name = registryFrameType(frame);
        if (type_name) |name| {
            if (registryFrameOperation(name)) |operation| {
                const target = enforcement.OperationTarget{ .id = registryFrameTargetId(frame, name) };
                const decision = enforcement.decide(
                    self.registry_principal,
                    self.registry_policy,
                    operation,
                    target,
                    .call,
                    "process_jsonl/registry_frame",
                    .{},
                    &self.registry_accounting,
                );
                switch (decision) {
                    .allow => {},
                    .deny => |denial| {
                        try self.addRegistryDenialDiagnostic(denial);
                        return .none;
                    },
                }
            }
        }

        const outcome = extension_registry.applyHostFrame(&self.registry, frame) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.WriteFailed => return err,
            error.ReservedSubAgentName => .ignored_malformed,
        };
        switch (outcome) {
            .ignored_unsupported => try self.addUnsupportedRegistryFrameDiagnostic(type_name),
            .ignored_malformed => try self.addMalformedRegistryFrameDiagnostic(type_name),
            .ignored_collision => try self.addRegistryCollisionDiagnostic(),
            else => {},
        }
        return outcome;
    }

    fn addRegistryCollisionDiagnostic(self: *ProtocolState) !void {
        if (self.registry.collision_diagnostics.items.len == 0) {
            try self.addDiagnostic(.host_error, .warning, "registry collision rejected");
            return;
        }
        const diagnostic = self.registry.collision_diagnostics.items[self.registry.collision_diagnostics.items.len - 1];
        var message_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer message_buf.deinit();
        var object = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(self.allocator, .{ .object = object });
        try common.putString(self.allocator, &object, "category", "registry_collision");
        try common.putString(self.allocator, &object, "surface", diagnostic.surface);
        try common.putString(self.allocator, &object, "id", diagnostic.id);
        try common.putString(self.allocator, &object, "incumbentExtensionPath", diagnostic.incumbent_extension_path);
        try common.putString(self.allocator, &object, "rejectedExtensionPath", diagnostic.rejected_extension_path);
        try common.putString(self.allocator, &object, "message", diagnostic.message);
        const value: std.json.Value = .{ .object = object };
        defer common.deinitJsonValue(self.allocator, value);
        try std.json.Stringify.value(value, .{}, &message_buf.writer);
        try self.addDiagnostic(.host_error, .warning, message_buf.written());
    }

    pub fn onDiagnostic(self: *ProtocolState, diagnostic: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    pub fn clearPendingRequests(self: *ProtocolState) void {
        var pending_iterator = self.pending_request_ids.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_request_ids.clearRetainingCapacity();
    }

    pub fn closePendingRequests(self: *ProtocolState) void {
        self.clearPendingRequests();
        self.clearPendingExtensionEventRequests();
        self.pending_requests_closed = true;
    }

    pub fn pendingCount(self: *const ProtocolState) usize {
        return self.pending_request_ids.count();
    }

    pub fn diagnosticCategoryCount(self: *const ProtocolState, category: DiagnosticCategory) usize {
        var count: usize = 0;
        for (self.diagnostics.items) |diagnostic| {
            if (diagnostic.category == category) count += 1;
        }
        return count;
    }

    pub fn resolvePendingRequest(self: *ProtocolState, id: []const u8) bool {
        if (self.pending_request_ids.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
            return true;
        }
        return false;
    }

    pub fn addPendingExtensionEventRequest(self: *ProtocolState, id: []const u8) !void {
        if (self.pending_extension_event_ids.contains(id)) return;
        try self.pending_extension_event_ids.put(try self.allocator.dupe(u8, id), {});
    }

    pub fn resolvePendingExtensionEventRequest(self: *ProtocolState, id: []const u8) bool {
        if (self.pending_extension_event_ids.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
            return true;
        }
        return false;
    }

    pub fn clearPendingExtensionEventRequests(self: *ProtocolState) void {
        var pending_iterator = self.pending_extension_event_ids.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_extension_event_ids.clearRetainingCapacity();
    }

    pub fn takeToolResponse(self: *ProtocolState, tool_call_id: []const u8) ?ToolExecutionResponse {
        for (self.tool_responses.items, 0..) |response, index| {
            if (std.mem.eql(u8, response.tool_call_id, tool_call_id)) {
                return self.tool_responses.orderedRemove(index);
            }
        }
        return null;
    }

    pub fn removeToolResponses(self: *ProtocolState, tool_call_id: []const u8) void {
        var index: usize = 0;
        while (index < self.tool_responses.items.len) {
            if (std.mem.eql(u8, self.tool_responses.items[index].tool_call_id, tool_call_id)) {
                var response = self.tool_responses.orderedRemove(index);
                response.deinit(self.allocator);
                continue;
            }
            index += 1;
        }
    }

    pub fn takeExtensionEventResponse(self: *ProtocolState, event_id: []const u8) ?ExtensionEventResponse {
        for (self.extension_event_responses.items, 0..) |response, index| {
            if (std.mem.eql(u8, response.event_id, event_id)) {
                return self.extension_event_responses.orderedRemove(index);
            }
        }
        return null;
    }

    pub fn removeExtensionEventResponses(self: *ProtocolState, event_id: []const u8) void {
        _ = self.resolvePendingExtensionEventRequest(event_id);
        var index: usize = 0;
        while (index < self.extension_event_responses.items.len) {
            if (std.mem.eql(u8, self.extension_event_responses.items[index].event_id, event_id)) {
                var response = self.extension_event_responses.orderedRemove(index);
                response.deinit(self.allocator);
                continue;
            }
            index += 1;
        }
    }

    pub fn addDiagnostic(self: *ProtocolState, category: DiagnosticCategory, severity: DiagnosticSeverity, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .category = category,
            .severity = severity,
            .message = try self.allocator.dupe(u8, message),
        });
    }

    fn addRegistryDenialDiagnostic(self: *ProtocolState, denial: enforcement.DenyDecision) !void {
        var envelope: std.Io.Writer.Allocating = .init(self.allocator);
        defer envelope.deinit();
        try envelope.writer.writeAll("{\"schemaVersion\":\"diagnostic-envelope.v0\",\"severity\":\"error\",\"runtimeKind\":\"process_jsonl\",\"category\":");
        try std.json.Stringify.value(denial.category, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"capability\":");
        try std.json.Stringify.value(denial.capability.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"branch\":");
        try std.json.Stringify.value(denial.branch.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"phase\":");
        try std.json.Stringify.value(denial.phase.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"mode\":");
        try std.json.Stringify.value(denial.mode, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"principal\":{\"runtimeKind\":");
        try std.json.Stringify.value(denial.principal.runtime_kind, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"extensionId\":");
        try std.json.Stringify.value(denial.principal.extension_id, .{}, &envelope.writer);
        if (denial.principal.policy_lookup_key) |policy_lookup_key| {
            try envelope.writer.writeAll(",\"policyLookupKey\":");
            try std.json.Stringify.value(policy_lookup_key, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("},\"operation\":");
        try std.json.Stringify.value(denial.operation.jsonName(), .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"target\":{\"id\":");
        if (denial.target.id) |target_id| {
            try string_utils.writeRedactedDiagnosticString(&envelope.writer, target_id);
        } else {
            try envelope.writer.writeAll("null");
        }
        try envelope.writer.writeAll("},\"reason\":");
        try std.json.Stringify.value(denial.reason, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"extensionIdentity\":");
        try std.json.Stringify.value(denial.principal.extension_id, .{}, &envelope.writer);
        try envelope.writer.writeAll(",\"recoveryHint\":\"Grant the required extension capability or disable the registry frame.\",\"message\":\"process_jsonl registry frame denied by enforcement substrate\"}");
        try self.addDiagnostic(.host_error, .@"error", envelope.written());
    }

    fn addUnsupportedRegistryFrameDiagnostic(self: *ProtocolState, type_name: ?[]const u8) !void {
        var envelope: std.Io.Writer.Allocating = .init(self.allocator);
        defer envelope.deinit();
        try envelope.writer.writeAll("{\"schemaVersion\":\"diagnostic-envelope.v0\",\"severity\":\"error\",\"category\":\"unsupported_message_type\",\"phase\":\"call\",\"runtimeKind\":\"process_jsonl\",\"recoveryHint\":\"Remove the unsupported registry frame type or update the host protocol.\",\"message\":\"unsupported registry frame\"");
        if (type_name) |name| {
            try envelope.writer.writeAll(",\"actual\":");
            try std.json.Stringify.value(name, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("}");
        try self.addDiagnostic(.unsupported_message_type, .@"error", envelope.written());
    }

    fn addMalformedRegistryFrameDiagnostic(self: *ProtocolState, type_name: ?[]const u8) !void {
        var envelope: std.Io.Writer.Allocating = .init(self.allocator);
        defer envelope.deinit();
        try envelope.writer.writeAll("{\"schemaVersion\":\"diagnostic-envelope.v0\",\"severity\":\"error\",\"category\":\"malformed_registry_frame\",\"phase\":\"call\",\"runtimeKind\":\"process_jsonl\",\"recoveryHint\":\"Fix the malformed registry frame payload before retrying.\",\"message\":\"malformed registry frame\"");
        if (type_name) |name| {
            try envelope.writer.writeAll(",\"actual\":");
            try std.json.Stringify.value(name, .{}, &envelope.writer);
        }
        try envelope.writer.writeAll("}");
        try self.addDiagnostic(.host_error, .@"error", envelope.written());
    }
};

fn registryFrameType(frame: std.json.Value) ?[]const u8 {
    if (frame != .object) return null;
    const type_value = frame.object.get("type") orelse return null;
    return switch (type_value) {
        .string => |value| value,
        else => null,
    };
}

fn registryFrameOperation(type_name: []const u8) ?enforcement.Operation {
    if (std.mem.eql(u8, type_name, "register_provider") or
        std.mem.eql(u8, type_name, "unregister_provider"))
    {
        return .model_call;
    }
    if (std.mem.eql(u8, type_name, "resources_discover")) return .file_read;
    if (std.mem.eql(u8, type_name, "set_header") or
        std.mem.eql(u8, type_name, "clear_header") or
        std.mem.eql(u8, type_name, "set_footer") or
        std.mem.eql(u8, type_name, "clear_footer") or
        std.mem.eql(u8, type_name, "register_terminal_input") or
        std.mem.eql(u8, type_name, "unregister_terminal_input") or
        std.mem.eql(u8, type_name, "set_editor_component") or
        std.mem.eql(u8, type_name, "clear_editor_component") or
        std.mem.eql(u8, type_name, "set_widget") or
        std.mem.eql(u8, type_name, "clear_widget") or
        std.mem.eql(u8, type_name, "clear_ui_hooks_for_reload"))
    {
        return .ui_notify;
    }
    if (std.mem.eql(u8, type_name, "register_tool") or
        std.mem.eql(u8, type_name, "register_command") or
        std.mem.eql(u8, type_name, "register_shortcut") or
        std.mem.eql(u8, type_name, "register_flag") or
        std.mem.eql(u8, type_name, "register_capability") or
        std.mem.eql(u8, type_name, "unregister_capability") or
        std.mem.eql(u8, type_name, "register_workflow") or
        std.mem.eql(u8, type_name, "unregister_workflow") or
        std.mem.eql(u8, type_name, "register_hook") or
        std.mem.eql(u8, type_name, "unregister_hook") or
        std.mem.eql(u8, type_name, "clear_extension_registrations") or
        std.mem.eql(u8, type_name, "register_message_renderer") or
        std.mem.eql(u8, type_name, "unregister_message_renderer"))
    {
        return .tool_use;
    }
    return null;
}

fn registryFrameTargetId(frame: std.json.Value, type_name: []const u8) ?[]const u8 {
    if (frame != .object) return null;
    const object = frame.object;
    if (std.mem.eql(u8, type_name, "register_capability") or std.mem.eql(u8, type_name, "unregister_capability")) {
        return optionalString(object, "id");
    }
    if (std.mem.eql(u8, type_name, "register_shortcut")) return optionalString(object, "shortcut");
    if (std.mem.eql(u8, type_name, "register_message_renderer") or std.mem.eql(u8, type_name, "unregister_message_renderer")) {
        return optionalString(object, "customType");
    }
    if (std.mem.eql(u8, type_name, "set_widget") or std.mem.eql(u8, type_name, "clear_widget")) return optionalString(object, "key");
    return optionalString(object, "name") orelse optionalString(object, "extensionPath");
}

pub fn startupFailureDiagnostic(allocator: std.mem.Allocator) !Diagnostic {
    return .{
        .category = .startup_failure,
        .severity = .@"error",
        .message = try allocator.dupe(u8, "extension host failed to start"),
    };
}

pub const InitializeFrame = struct {
    marker: []const u8,
    cwd: []const u8,
    fixture: []const u8,
};

pub fn writeInitializeFrame(allocator: std.mem.Allocator, writer: *std.Io.Writer, frame: InitializeFrame) !void {
    try writer.writeAll("{\"type\":\"initialize\",\"marker\":");
    try writeJsonString(allocator, writer, frame.marker);
    try writer.writeAll(",\"cwd\":");
    try writeJsonString(allocator, writer, frame.cwd);
    try writer.writeAll(",\"fixture\":");
    try writeJsonString(allocator, writer, frame.fixture);
    try writer.writeAll("}\n");
}

pub fn writeExtensionUiResponseFrame(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: []const u8, payload_json: []const u8) !void {
    try writer.writeAll("{\"type\":\"extension_ui_response\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"payload\":");
    try writer.writeAll(payload_json);
    try writer.writeAll("}\n");
}

pub fn writeToolCallFrame(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
) !void {
    try writer.writeAll("{\"type\":\"tool_call\",\"toolCallId\":");
    try writeJsonString(allocator, writer, tool_call_id);
    try writer.writeAll(",\"toolName\":");
    try writeJsonString(allocator, writer, tool_name);
    try writer.writeAll(",\"input\":");
    try std.json.Stringify.value(args, .{}, writer);
    try writer.writeAll("}\n");
}

pub fn writeExtensionEventRequestFrame(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    event_id: []const u8,
    event: std.json.Value,
) !void {
    try writer.writeAll("{\"type\":\"extension_event\",\"eventId\":");
    try writeJsonString(allocator, writer, event_id);
    try writer.writeAll(",\"event\":");
    try std.json.Stringify.value(event, .{}, writer);
    try writer.writeAll("}\n");
}

pub fn writeShutdownFrame(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"type\":\"shutdown\"}\n");
}

fn parseObjectMessage(allocator: std.mem.Allocator, object: std.json.ObjectMap) !HostMessage {
    const type_name = optionalString(object, "type") orelse return error.UnsupportedHostMessageType;
    if (std.mem.eql(u8, type_name, "ready")) return .ready;
    if (std.mem.eql(u8, type_name, "shutdown_complete")) return .shutdown_complete;
    if (std.mem.eql(u8, type_name, "diagnostic")) {
        return .{ .diagnostic = try parseDiagnostic(allocator, object, .warning) };
    }
    if (std.mem.eql(u8, type_name, "error")) {
        return .{ .error_message = try parseDiagnostic(allocator, object, .@"error") };
    }
    if (std.mem.eql(u8, type_name, "tool_result")) {
        return .{ .tool_response = try parseToolResult(allocator, object, false) };
    }
    if (std.mem.eql(u8, type_name, "tool_error")) {
        return .{ .tool_response = try parseToolResult(allocator, object, true) };
    }
    if (std.mem.eql(u8, type_name, "extension_event_result") or std.mem.eql(u8, type_name, "hook_result")) {
        return .{ .extension_event_response = try parseExtensionEventResult(allocator, object, false) };
    }
    if (std.mem.eql(u8, type_name, "extension_event_error") or std.mem.eql(u8, type_name, "hook_error")) {
        return .{ .extension_event_response = try parseExtensionEventResult(allocator, object, true) };
    }
    if (std.mem.eql(u8, type_name, "extension_ui_request")) {
        const id = optionalString(object, "id") orelse return error.UnsupportedHostMessageType;
        const method = optionalString(object, "method") orelse return error.UnsupportedHostMessageType;
        const payload_json = try extensionUiPayloadJson(allocator, object);
        errdefer allocator.free(payload_json);
        return .{ .extension_ui_request = .{
            .id = try allocator.dupe(u8, id),
            .method = try allocator.dupe(u8, method),
            .response_required = optionalBool(object, "responseRequired") orelse false,
            .payload_json = payload_json,
        } };
    }
    if (isRegistryFrameType(type_name)) {
        const cloned = try common.cloneJsonValue(allocator, .{ .object = object });
        return .{ .registry_frame = .{ .payload = cloned } };
    }
    return error.UnsupportedHostMessageType;
}

fn parseExtensionEventResult(allocator: std.mem.Allocator, object: std.json.ObjectMap, default_is_error: bool) !ExtensionEventResponse {
    const event_id = optionalString(object, "eventId") orelse
        optionalString(object, "event_id") orelse
        optionalString(object, "id") orelse
        return error.UnsupportedHostMessageType;
    const result = if (object.get("result")) |value|
        try common.cloneJsonValue(allocator, value)
    else if (object.get("patch")) |value|
        try common.cloneJsonValue(allocator, value)
    else
        null;
    errdefer if (result) |result_value| common.deinitJsonValue(allocator, result_value);
    const message = optionalString(object, "message") orelse optionalString(object, "error");
    const fatal = (optionalBool(object, "fatal") orelse false) or hookErrorPolicyIsFatal(object);
    return .{
        .event_id = try allocator.dupe(u8, event_id),
        .result = result,
        .error_message = if (default_is_error or message != null)
            try allocator.dupe(u8, message orelse "extension hook error")
        else
            null,
        .fatal = fatal,
    };
}

fn parseToolResult(allocator: std.mem.Allocator, object: std.json.ObjectMap, default_is_error: bool) !ToolExecutionResponse {
    const tool_call_id = optionalString(object, "toolCallId") orelse
        optionalString(object, "callId") orelse
        optionalString(object, "id") orelse
        return error.UnsupportedHostMessageType;
    const result_object: ?std.json.ObjectMap = if (object.get("result")) |result| switch (result) {
        .object => |result_map| result_map,
        else => null,
    } else null;

    const content_value = if (result_object) |result| result.get("content") else object.get("content");
    const content = if (content_value) |value|
        try parseContentBlocks(allocator, value)
    else if (default_is_error)
        try common.makeTextContent(allocator, optionalString(object, "message") orelse "process_jsonl tool error")
    else
        return error.UnsupportedHostMessageType;
    errdefer common.deinitContentBlocks(allocator, content);

    const details_value = if (result_object) |result| result.get("details") else object.get("details");
    const details = if (details_value) |details|
        try common.cloneJsonValue(allocator, details)
    else if (default_is_error)
        try toolErrorDetails(allocator, object, result_object)
    else
        null;
    errdefer if (details) |details_value_owned| common.deinitJsonValue(allocator, details_value_owned);

    const is_error = optionalBool(object, "isError") orelse
        optionalBool(object, "is_error") orelse
        if (result_object) |result| optionalBool(result, "isError") orelse optionalBool(result, "is_error") orelse default_is_error else default_is_error;

    return .{
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
        .content = content,
        .details = details,
        .is_error = is_error,
    };
}

fn toolErrorDetails(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    result_object: ?std.json.ObjectMap,
) !std.json.Value {
    var details = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const details_value = std.json.Value{ .object = details };
        common.deinitJsonValue(allocator, details_value);
    }

    const code = optionalString(object, "code") orelse
        if (result_object) |result| optionalString(result, "code") else null;
    try details.put(
        allocator,
        try allocator.dupe(u8, "code"),
        .{ .string = try allocator.dupe(u8, code orelse "process_jsonl_tool_error") },
    );

    const message = optionalString(object, "message") orelse
        if (result_object) |result| optionalString(result, "message") else null;
    try details.put(
        allocator,
        try allocator.dupe(u8, "message"),
        .{ .string = try allocator.dupe(u8, message orelse "process_jsonl tool error") },
    );

    return .{ .object = details };
}

pub fn parseContentBlocks(allocator: std.mem.Allocator, value: std.json.Value) ![]const ai.ContentBlock {
    if (value != .array) return error.UnsupportedHostMessageType;
    const blocks = try allocator.alloc(ai.ContentBlock, value.array.items.len);
    errdefer allocator.free(blocks);
    for (value.array.items, 0..) |item, index| {
        blocks[index] = parseContentBlock(allocator, item) catch |err| {
            deinitContentBlockFields(allocator, blocks[0..index]);
            allocator.free(blocks);
            return err;
        };
    }
    return blocks;
}

fn parseContentBlock(allocator: std.mem.Allocator, value: std.json.Value) !ai.ContentBlock {
    if (value != .object) return error.UnsupportedHostMessageType;
    const block_type = optionalString(value.object, "type") orelse return error.UnsupportedHostMessageType;
    if (std.mem.eql(u8, block_type, "text")) {
        const text = optionalString(value.object, "text") orelse return error.UnsupportedHostMessageType;
        return .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    }
    if (std.mem.eql(u8, block_type, "image")) {
        const data = optionalString(value.object, "data") orelse return error.UnsupportedHostMessageType;
        const mime_type = optionalString(value.object, "mimeType") orelse
            optionalString(value.object, "mime_type") orelse
            return error.UnsupportedHostMessageType;
        const data_dup = try allocator.dupe(u8, data);
        errdefer allocator.free(data_dup);
        return .{ .image = .{
            .data = data_dup,
            .mime_type = try allocator.dupe(u8, mime_type),
        } };
    }
    return error.UnsupportedHostMessageType;
}

fn cloneContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]const ai.ContentBlock {
    const cloned = try allocator.alloc(ai.ContentBlock, blocks.len);
    errdefer allocator.free(cloned);
    for (blocks, 0..) |block, index| {
        cloned[index] = cloneContentBlock(allocator, block) catch |err| {
            deinitContentBlockFields(allocator, cloned[0..index]);
            allocator.free(cloned);
            return err;
        };
    }
    return cloned;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |text| .{ .text = .{
            .text = try allocator.dupe(u8, text.text),
            .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
        .image => |image| .{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| .{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .thinking_signature = if (thinking.thinking_signature) |signature| try allocator.dupe(u8, signature) else null,
            .signature = if (thinking.signature) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
        .tool_call => |tool_call| .{ .tool_call = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try common.cloneJsonValue(allocator, tool_call.arguments),
            .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
        } },
    };
}

fn deinitContentBlockFields(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) void {
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
            .tool_call => |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                if (tool_call.thought_signature) |signature| allocator.free(signature);
                common.deinitJsonValue(allocator, tool_call.arguments);
            },
        }
    }
}

fn extensionUiPayloadJson(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    if (object.get("payload")) |payload| {
        if (payload == .object) {
            return try std.json.Stringify.valueAlloc(allocator, payload, .{});
        }
    }

    var payload = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const payload_value = std.json.Value{ .object = payload };
        common.deinitJsonValue(allocator, payload_value);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type") or
            std.mem.eql(u8, entry.key_ptr.*, "id") or
            std.mem.eql(u8, entry.key_ptr.*, "method") or
            std.mem.eql(u8, entry.key_ptr.*, "responseRequired"))
        {
            continue;
        }
        try common.putValue(allocator, &payload, entry.key_ptr.*, try common.cloneJsonValue(allocator, entry.value_ptr.*));
    }
    const payload_value = std.json.Value{ .object = payload };
    defer {
        common.deinitJsonValue(allocator, payload_value);
    }
    return try std.json.Stringify.valueAlloc(allocator, payload_value, .{});
}

fn parseDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, default_severity: DiagnosticSeverity) !Diagnostic {
    return .{
        .category = parseCategory(optionalString(object, "category")) orelse .host_error,
        .severity = parseSeverity(optionalString(object, "severity")) orelse default_severity,
        .message = try allocator.dupe(u8, optionalString(object, "message") orelse "host diagnostic"),
    };
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn hookErrorPolicyIsFatal(object: std.json.ObjectMap) bool {
    const policy = optionalString(object, "errorPolicy") orelse
        optionalString(object, "error_policy") orelse
        optionalString(object, "onError") orelse
        optionalString(object, "on_error") orelse
        return false;
    return std.mem.eql(u8, policy, "fatal") or
        std.mem.eql(u8, policy, "abort") or
        std.mem.eql(u8, policy, "fail");
}

fn parseCategory(name: ?[]const u8) ?DiagnosticCategory {
    const text = name orelse return null;
    inline for (@typeInfo(DiagnosticCategory).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(DiagnosticCategory, field.name);
    }
    return null;
}

fn parseSeverity(name: ?[]const u8) ?DiagnosticSeverity {
    const text = name orelse return null;
    if (std.mem.eql(u8, text, "info")) return .info;
    if (std.mem.eql(u8, text, "warning")) return .warning;
    if (std.mem.eql(u8, text, "error")) return .@"error";
    return null;
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

const test_process_jsonl_principal: enforcement.Principal = .{
    .runtime_kind = "process_jsonl",
    .extension_id = "process_jsonl:test-fixture",
    .policy_lookup_key = "process_jsonl:test-fixture-policy",
};

fn protocolStateWithAllRegistryGrants(allocator: std.mem.Allocator) ProtocolState {
    return ProtocolState.initWithPolicy(
        allocator,
        .{ .approved_grants = enforcement.CANONICAL_GRANTS[0..] },
        test_process_jsonl_principal,
    );
}

test "M6 host protocol parses ordered JSONL frames" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"diagnostic\",\"category\":\"host_error\",\"severity\":\"warning\",\"message\":\"fixture warning\"}\n{\"type\":\"rea", &state);
    try parser.feed(allocator, "dy\"}\r\n{\"type\":\"extension_ui_request\",\"id\":\"a\",\"method\":\"select\",\"responseRequired\":true}\n{\"type\":\"extension_ui_request\",\"id\":\"b\",\"method\":\"notify\"}\n", &state);
    try parser.finish(allocator, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.ui_requests.items.len);
    try std.testing.expectEqualStrings("a", state.ui_requests.items[0].id);
    try std.testing.expectEqualStrings("b", state.ui_requests.items[1].id);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
}

test "M6 host protocol contains malformed unsupported duplicate and incomplete frames" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "   \nnot-json\n[]\n{\"type\":\"unknown\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"ready\"}\n{\"type\":\"ready\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"dup\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"dup\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\"", &state);
    try parser.finish(allocator, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 7), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.blank_frame, state.diagnostics.items[0].category);
    try std.testing.expectEqual(DiagnosticCategory.malformed_json, state.diagnostics.items[1].category);
    try std.testing.expectEqual(DiagnosticCategory.non_object_frame, state.diagnostics.items[2].category);
    try std.testing.expectEqual(DiagnosticCategory.unsupported_message_type, state.diagnostics.items[3].category);
    try std.testing.expectEqual(DiagnosticCategory.duplicate_ready, state.diagnostics.items[4].category);
    try std.testing.expectEqual(DiagnosticCategory.duplicate_pending_request, state.diagnostics.items[5].category);
    try std.testing.expectEqual(DiagnosticCategory.incomplete_frame, state.diagnostics.items[6].category);
}

test "ProtocolState handles resources_discover only through registry frames" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\",42],\"promptPaths\":[\"fixture/prompts\",false],\"themePaths\":[\"fixture/themes\",null],\"extensionPath\":\"fixture/extension.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 0), state.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.resource_discoveries.items.len);

    const discovery = state.registry.resource_discoveries.items[0];
    try std.testing.expectEqualStrings("fixture/extension.ts", discovery.extension_path);
    try std.testing.expectEqual(@as(usize, 1), discovery.skill_paths.items.len);
    try std.testing.expectEqualStrings("fixture/skills", discovery.skill_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), discovery.prompt_paths.items.len);
    try std.testing.expectEqualStrings("fixture/prompts", discovery.prompt_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), discovery.theme_paths.items.len);
    try std.testing.expectEqualStrings("fixture/themes", discovery.theme_paths.items[0]);
}

test "ProtocolState keeps UI request edge cases stable" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"pre-ready\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try std.testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.host_error, state.diagnostics.items[0].category);
    try std.testing.expectEqual(@as(usize, 0), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());

    const ready_and_requests =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"notify\",\"method\":\"notification\",\"responseRequired\":false}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n";
    try parser.feed(allocator, ready_and_requests, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 2), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.duplicate_pending_request, state.diagnostics.items[1].category);
    try std.testing.expectEqual(@as(usize, 2), state.ui_requests.items.len);
    try std.testing.expectEqualStrings("notify", state.ui_requests.items[0].id);
    try std.testing.expect(!state.ui_requests.items[0].response_required);
    try std.testing.expectEqualStrings("pending", state.ui_requests.items[1].id);
    try std.testing.expect(state.ui_requests.items[1].response_required);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try std.testing.expect(!state.resolvePendingRequest("unknown"));

    state.closePendingRequests();
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"after-close\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try std.testing.expectEqual(@as(usize, 2), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    try std.testing.expect(!state.resolvePendingRequest("pending"));
}

test "process_jsonl protocol parses correlated tool results and errors" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"tool_result\",\"toolCallId\":\"call-1\",\"content\":[{\"type\":\"text\",\"text\":\"first\"}],\"details\":{\"ok\":true}}\n" ++
        "{\"type\":\"tool_error\",\"toolCallId\":\"call-1\",\"message\":\"failed\"}\n" ++
        "{\"type\":\"tool_result\",\"callId\":\"call-2\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"second\"}],\"isError\":false}}\n";
    try parser.feed(allocator, frames, &state);

    var first = state.takeToolResponse("call-1").?;
    defer first.deinit(allocator);
    try std.testing.expect(!first.is_error);
    try std.testing.expectEqualStrings("first", first.content[0].text.text);
    try std.testing.expectEqual(true, first.details.?.object.get("ok").?.bool);

    var repeated = state.takeToolResponse("call-1").?;
    defer repeated.deinit(allocator);
    try std.testing.expect(repeated.is_error);
    try std.testing.expectEqualStrings("failed", repeated.content[0].text.text);
    try std.testing.expectEqualStrings("process_jsonl_tool_error", repeated.details.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("failed", repeated.details.?.object.get("message").?.string);

    var second = state.takeToolResponse("call-2").?;
    defer second.deinit(allocator);
    try std.testing.expect(!second.is_error);
    try std.testing.expectEqualStrings("second", second.content[0].text.text);
    try std.testing.expect(state.takeToolResponse("call-2") == null);
}

test "process_jsonl protocol accepts only pending extension event responses" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"ready\"}\n", &state);
    try state.addPendingExtensionEventRequest("event-1-message_end");
    try parser.feed(allocator, "{\"type\":\"extension_event_result\",\"eventId\":\"event-1-message_end\",\"result\":{\"ok\":true}}\n", &state);

    var accepted = state.takeExtensionEventResponse("event-1-message_end").?;
    defer accepted.deinit(allocator);
    try std.testing.expectEqualStrings("event-1-message_end", accepted.event_id);
    try std.testing.expectEqual(true, accepted.result.?.object.get("ok").?.bool);

    try parser.feed(allocator, "{\"type\":\"extension_event_result\",\"eventId\":\"event-1-message_end\",\"result\":{\"late\":true}}\n", &state);
    try std.testing.expect(state.takeExtensionEventResponse("event-1-message_end") == null);
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqualStrings("host emitted stale or unknown extension event response", state.diagnostics.items[0].message);
}

test "ProtocolState registry_frames_applied counts only accepted registry outcomes" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"ready\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 0), state.registry_frames_applied);

    try parser.feed(allocator, "{\"type\":\"register_tool\",\"name\":\"tool\",\"label\":\"Tool\",\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);

    try parser.feed(allocator, "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 2), state.registry_frames_applied);

    try parser.feed(allocator, "{\"type\":\"clear_extension_registrations\",\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 0), state.registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.registry.resource_discoveries.items.len);

    try parser.feed(allocator, "{\"type\":\"register_tool\",\"label\":\"missing name\",\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"clear_extension_registrations\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"unsupported\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"notify\",\"method\":\"notification\",\"responseRequired\":false}\n", &state);
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);

    var unsupported = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"unsupported_registry_frame\"}", .{});
    defer unsupported.deinit();
    try state.onMessage(.{ .registry_frame = .{ .payload = unsupported.value } });
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);

    var none = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"extension_ui_request\",\"id\":\"record-only\"}", .{});
    defer none.deinit();
    try state.onMessage(.{ .registry_frame = .{ .payload = none.value } });
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.ui_request_ids.items.len);
    try std.testing.expectEqualStrings("record-only", state.registry.ui_request_ids.items[0]);
}

test "process_jsonl registry frames default-deny before mutation" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"denied-tool\",\"label\":\"Denied\",\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_provider\",\"name\":\"denied-provider\",\"displayName\":\"Denied\",\"models\":[{\"id\":\"denied-model\"}],\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"extensionPath\":\"fixture/denied.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 0), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 0), state.registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.registry.resource_discoveries.items.len);
    try std.testing.expectEqual(@as(usize, 3), state.diagnosticCategoryCount(.host_error));
    for (state.diagnostics.items) |diagnostic| {
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"category\":\"denied_capability\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"principal\":{\"runtimeKind\":\"process_jsonl\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"mode\":\"process_jsonl/registry_frame\"") != null);
    }
}

test "process_jsonl permission broker default-denies every mutating registry frame class" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"denied-tool\",\"label\":\"Denied\",\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_command\",\"name\":\"denied-command\",\"description\":\"Denied\",\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"denied-capability\",\"kind\":\"workflow\",\"title\":\"Denied\",\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_hook\",\"event\":\"message_end\",\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"set_widget\",\"key\":\"denied-widget\",\"lines\":[\"Denied\"],\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_provider\",\"name\":\"denied-provider\",\"displayName\":\"Denied\",\"models\":[{\"id\":\"denied-model\"}],\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"secret-renderer-token\",\"extensionPath\":\"fixture/denied.ts\"}\n" ++
        "{\"type\":\"register_workflow\",\"id\":\"denied-workflow\",\"description\":\"Denied\",\"toolName\":\"workflow.denied\",\"extensionPath\":\"fixture/denied.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 0), state.registry_frames_applied);
    const counts = extension_registry.registrySurfaceCounts(&state.registry);
    try std.testing.expectEqual(@as(usize, 0), counts.tools);
    try std.testing.expectEqual(@as(usize, 0), counts.commands);
    try std.testing.expectEqual(@as(usize, 0), counts.capabilities);
    try std.testing.expectEqual(@as(usize, 0), counts.providers);
    try std.testing.expectEqual(@as(usize, 0), counts.resource_discoveries);
    try std.testing.expectEqual(@as(usize, 0), counts.widgets);
    try std.testing.expectEqual(@as(usize, 0), counts.message_renderers);
    try std.testing.expect(!state.registry.hasHook("message_end"));
    try std.testing.expect(state.registry.workflowForToolName("workflow.denied") == null);
    try std.testing.expectEqual(@as(usize, 9), state.diagnosticCategoryCount(.host_error));
    for (state.diagnostics.items) |diagnostic| {
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"schemaVersion\":\"diagnostic-envelope.v0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"category\":\"denied_capability\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"operation\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"target\":{\"id\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "\"recoveryHint\":\"Grant the required extension capability or disable the registry frame.\"") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, state.diagnostics.items[7].message, "secret-renderer-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.diagnostics.items[7].message, "[REDACTED]") != null);
}

test "process_jsonl registry frames mutate only with matching grants" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    const approved = [_]enforcement.Grant{ .tool_use, .model_call, .file_read };
    var state = ProtocolState.initWithPolicy(
        allocator,
        .{ .approved_grants = approved[0..] },
        test_process_jsonl_principal,
    );
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"allowed-tool\",\"label\":\"Allowed\",\"extensionPath\":\"fixture/allowed.ts\"}\n" ++
        "{\"type\":\"register_provider\",\"name\":\"allowed-provider\",\"displayName\":\"Allowed\",\"models\":[{\"id\":\"allowed-model\"}],\"extensionPath\":\"fixture/allowed.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"extensionPath\":\"fixture/allowed.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.tools.items.len);
    try std.testing.expectEqualStrings("allowed-tool", state.registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), state.registry.providers.items.len);
    try std.testing.expectEqualStrings("allowed-provider", state.registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), state.registry.resource_discoveries.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.diagnostics.items.len);
}

test "process_jsonl registry collisions preserve incumbent and emit structured diagnostics" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"shared-capability\",\"kind\":\"workflow\",\"title\":\"First\",\"extensionPath\":\"fixture/first.ts\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"shared-capability\",\"kind\":\"workflow\",\"title\":\"Second\",\"extensionPath\":\"fixture/second.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.capabilities.items.len);
    try std.testing.expectEqualStrings("First", state.registry.capabilities.items[0].title);
    try std.testing.expectEqualStrings("fixture/first.ts", state.registry.capabilities.items[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), state.registry.collision_diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.host_error));
    try std.testing.expect(std.mem.indexOf(u8, state.diagnostics.items[0].message, "\"category\":\"registry_collision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.diagnostics.items[0].message, "\"surface\":\"capability\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.diagnostics.items[0].message, "\"incumbentExtensionPath\":\"fixture/first.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.diagnostics.items[0].message, "\"rejectedExtensionPath\":\"fixture/second.ts\"") != null);
}

test "process_jsonl unsupported registry frames are diagnostics without mutation" {
    const allocator = std.testing.allocator;
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    var unsupported = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"unsupported_registry_frame\",\"name\":\"noop\"}", .{});
    defer unsupported.deinit();
    try state.onMessage(.{ .registry_frame = .{ .payload = unsupported.value } });

    try std.testing.expectEqual(@as(usize, 0), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 0), extension_registry.registrySurfaceCounts(&state.registry).tools);
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.unsupported_message_type));
}

test "process_jsonl protocol rejects invalid subscriber readiness frames without state mutation" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const baseline_frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"stable-tool\",\"label\":\"Stable Tool\",\"extensionPath\":\"fixture/stable.ts\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{\"text\":\"stable\"}}\n";
    try parser.feed(allocator, baseline_frames, &state);
    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.diagnostics.items.len);

    const counts_before = extension_registry.registrySurfaceCounts(&state.registry);
    const registry_frames_before = state.registry_frames_applied;
    const pending_before = state.pendingCount();
    const ui_requests_before = state.ui_requests.items.len;

    const invalid_readiness_frames =
        "{\"type\":\"sub_agent_task_result\",\"taskId\":\"task-opaque\",\"runId\":\"run-opaque\",\"status\":\"complete\",\"readiness\":{\"agentId\":\"agent-opaque\"}}\n" ++
        "{\"type\":\"agent_start\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"requestedGrants\":[\"agent.spawn\"],\"limits\":{\"maxChildren\":0}}\n" ++
        "{\"type\":\"sub_agent_task_invocation\",\"taskId\":\n" ++
        "[{\"type\":\"sub_agent_task_result\",\"taskId\":\"array-is-not-object\"}]\n";
    try parser.feed(allocator, invalid_readiness_frames, &state);

    const counts_after = extension_registry.registrySurfaceCounts(&state.registry);
    try std.testing.expectEqual(registry_frames_before, state.registry_frames_applied);
    try std.testing.expectEqual(pending_before, state.pendingCount());
    try std.testing.expectEqual(ui_requests_before, state.ui_requests.items.len);
    try std.testing.expectEqual(counts_before.tools, counts_after.tools);
    try std.testing.expectEqual(counts_before.commands, counts_after.commands);
    try std.testing.expectEqual(counts_before.shortcuts, counts_after.shortcuts);
    try std.testing.expectEqual(counts_before.flags, counts_after.flags);
    try std.testing.expectEqual(counts_before.providers, counts_after.providers);
    try std.testing.expectEqual(counts_before.capabilities, counts_after.capabilities);
    try std.testing.expectEqual(counts_before.resource_discoveries, counts_after.resource_discoveries);
    try std.testing.expectEqual(counts_before.header_hooks, counts_after.header_hooks);
    try std.testing.expectEqual(counts_before.footer_hooks, counts_after.footer_hooks);
    try std.testing.expectEqual(counts_before.terminal_input_subscriptions, counts_after.terminal_input_subscriptions);
    try std.testing.expectEqual(counts_before.editor_component_hooks, counts_after.editor_component_hooks);
    try std.testing.expectEqual(counts_before.widgets, counts_after.widgets);
    try std.testing.expectEqual(counts_before.message_renderers, counts_after.message_renderers);
    try std.testing.expectEqual(counts_before.ui_request_ids, counts_after.ui_request_ids);

    try std.testing.expectEqual(@as(usize, 4), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.unsupported_message_type, state.diagnostics.items[0].category);
    try std.testing.expectEqual(DiagnosticCategory.unsupported_message_type, state.diagnostics.items[1].category);
    try std.testing.expectEqual(DiagnosticCategory.malformed_json, state.diagnostics.items[2].category);
    try std.testing.expectEqual(DiagnosticCategory.non_object_frame, state.diagnostics.items[3].category);
}

test "sub-agent readiness JSON wire validation accepts valid envelopes and rejects missing identifiers" {
    const allocator = std.testing.allocator;
    const valid_lines =
        "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\",\"input\":{\"text\":\"delegate\"},\"limits\":{\"maxChildren\":0},\"cancellation\":{\"state\":\"pending\"}}\n" ++
        "{\"type\":\"sub_agent_task_result\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\",\"status\":\"completed\",\"startedAt\":1,\"completedAt\":2,\"content\":{\"text\":\"done\"}}\n";

    var valid_parser = JsonlFrameParser{};
    defer valid_parser.deinit(allocator);
    var valid_state = ProtocolState.init(allocator);
    defer valid_state.deinit();
    try valid_parser.feed(allocator, valid_lines, &valid_state);
    try std.testing.expectEqual(@as(usize, 2), valid_state.diagnosticCategoryCount(.unsupported_message_type));

    var invocation = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"taskId\":\"task-opaque\",\"sessionId\":\"session-opaque\",\"input\":{\"text\":\"delegate\"},\"limits\":{\"maxChildren\":0},\"cancellation\":{\"state\":\"pending\"}}", .{});
    defer invocation.deinit();
    var invocation_validation = try extension_events.validateSubAgentReadinessEnvelope(allocator, invocation.value);
    defer invocation_validation.deinit(allocator);
    try std.testing.expect(invocation_validation == .valid);
    try std.testing.expectEqual(extension_events.SubAgentReadinessEnvelopeKind.task_invocation, invocation_validation.valid);

    var invalid_missing_id = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"sub_agent_task_invocation\",\"agentId\":\"agent-opaque\",\"runId\":\"run-opaque\",\"sessionId\":\"session-opaque\",\"input\":{}}", .{});
    defer invalid_missing_id.deinit();
    var invalid_validation = try extension_events.validateSubAgentReadinessEnvelope(allocator, invalid_missing_id.value);
    defer invalid_validation.deinit(allocator);
    try std.testing.expect(invalid_validation == .invalid);
    try std.testing.expectEqualStrings("$.taskId", invalid_validation.invalid.path);
    try std.testing.expectEqualStrings("missing required field", invalid_validation.invalid.message);
}

test "extension protocol ABI conformance helper covers diagnostics registry frames and UI lifecycle" {
    const frame_types = registryFrameTypeNames();
    try std.testing.expectEqual(@as(usize, 27), frame_types.len);
    try std.testing.expectEqualStrings("register_tool", frame_types[0]);
    try std.testing.expectEqualStrings("unregister_message_renderer", frame_types[frame_types.len - 1]);

    const diagnostic_names = diagnosticCategoryNames();
    try std.testing.expectEqual(@typeInfo(DiagnosticCategory).@"enum".fields.len, diagnostic_names.len);
    inline for (@typeInfo(DiagnosticCategory).@"enum".fields, 0..) |field, index| {
        const category: DiagnosticCategory = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(category.jsonName(), diagnostic_names[index]);
    }

    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"extension_ui_request\",\"id\":\"pre-ready\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"custom\",\"extensionPath\":\"fixture/protocol.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.duplicate_ready));
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.duplicate_pending_request));
    try std.testing.expectEqual(@as(usize, 1), state.registry.message_renderers.items.len);

    try std.testing.expect(state.resolvePendingRequest("pending"));
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    state.closePendingRequests();
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"after-close\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try std.testing.expectEqual(@as(usize, 1), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
}

test "M6 host protocol serializes deterministic Zig to host frames" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeInitializeFrame(allocator, &out.writer, .{
        .marker = "pi-m6-host-marker",
        .cwd = "/workspace",
        .fixture = "fixture-a",
    });
    try writeExtensionUiResponseFrame(allocator, &out.writer, "req-1", "{\"value\":\"ok\"}");
    try writeShutdownFrame(&out.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"initialize\",\"marker\":\"pi-m6-host-marker\",\"cwd\":\"/workspace\",\"fixture\":\"fixture-a\"}\n{\"type\":\"extension_ui_response\",\"id\":\"req-1\",\"payload\":{\"value\":\"ok\"}}\n{\"type\":\"shutdown\"}\n",
        out.written(),
    );
}

test "M11 host protocol applies live register_* JSONL frames into runtime registry" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"say-hello\",\"label\":\"Say Hello\",\"description\":\"Greets the world\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_command\",\"name\":\"say-hello\",\"description\":\"Slash command\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_shortcut\",\"shortcut\":\"ctrl+h\",\"command\":\"say-hello\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_flag\",\"name\":\"plan\",\"valueType\":\"boolean\",\"default\":true,\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_flag\",\"name\":\"model-alias\",\"valueType\":\"string\",\"default\":\"claude-haiku\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_provider\",\"name\":\"fake-provider\",\"displayName\":\"Fake\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"fake-1\",\"name\":\"Fake 1\"}],\"extensionPath\":\"fixture/extension.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 6), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.tools.items.len);
    try std.testing.expectEqualStrings("say-hello", state.registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), state.registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.registry.providers.items.len);

    // Default values resolve through getFlag when no CLI value is set.
    const plan_value = state.registry.getFlag("plan");
    try std.testing.expect(plan_value == .boolean and plan_value.boolean);
    const alias_value = state.registry.getFlag("model-alias");
    try std.testing.expect(alias_value == .string);
    try std.testing.expectEqualStrings("claude-haiku", alias_value.string);

    // Apply parsed CLI values; getFlag now reflects them over defaults.
    _ = try state.registry.setFlagValue("plan", .{ .boolean = true });
    _ = try state.registry.setFlagValue("model-alias", .{ .string = "claude-opus" });
    const alias_after = state.registry.getFlag("model-alias");
    try std.testing.expectEqualStrings("claude-opus", alias_after.string);
}

test "extension_host ProtocolState accepts live register_capability frame" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"cap-workflow\",\"kind\":\"workflow\",\"title\":\"Workflow\",\"description\":\"Runs workflow\",\"command\":\"workflow\",\"resourcePath\":\"skills/workflow\",\"extensionPath\":\"fixture/extension.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.capabilities.items.len);
    try std.testing.expectEqualStrings("cap-workflow", state.registry.capabilities.items[0].id);
    try std.testing.expectEqualStrings("workflow", state.registry.capabilities.items[0].kind);
    try std.testing.expectEqualStrings("Workflow", state.registry.capabilities.items[0].title);
}

test "extension_host ProtocolState applies clear_extension_registrations without clearing UI lifecycle" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = protocolStateWithAllRegistryGrants(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"target-tool\",\"label\":\"Target\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"other-tool\",\"label\":\"Other\",\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"target-capability\",\"kind\":\"workflow\",\"title\":\"Target\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"other-capability\",\"kind\":\"workflow\",\"title\":\"Other\",\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"target-message\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"other-message\",\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/target/skills\"],\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/other/skills\"],\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"set_header\",\"lines\":[\"Target header\"],\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"set_widget\",\"key\":\"target-widget\",\"lines\":[\"Target widget\"],\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"clear_extension_registrations\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"clear_extension_registrations\",\"extensionPath\":42}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 11), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.tools.items.len);
    try std.testing.expectEqualStrings("other-tool", state.registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), state.registry.capabilities.items.len);
    try std.testing.expectEqualStrings("other-capability", state.registry.capabilities.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), state.registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("other-message", state.registry.message_renderers.items[0].custom_type);
    try std.testing.expectEqual(@as(usize, 1), state.registry.resource_discoveries.items.len);
    try std.testing.expectEqualStrings("fixture/other.ts", state.registry.resource_discoveries.items[0].extension_path);
    try std.testing.expect(state.registry.header_hook != null);
    try std.testing.expectEqualStrings("fixture/target.ts", state.registry.header_hook.?.extension_path);
    try std.testing.expectEqual(@as(usize, 1), state.registry.widgets.items.len);
    try std.testing.expectEqualStrings("target-widget", state.registry.widgets.items[0].key);
}
