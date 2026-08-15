//! Mirror of packages/coding-agent/src/core/extensions/subagent-extension.ts.
//!
//! Zig has no equivalent of the TS `ExtensionAPI` plugin model
//! (`pi.registerTool` / `pi.registerCommand` / `pi.appendEntry`), so the
//! TS `createSubAgentExtension(options)` factory does not have a direct
//! Zig analog. Instead this module exposes:
//!
//! - The substrate **constants** (entry/tool/command names).
//! - All the **pure helpers** that compose a sub-agent delegation
//!   invocation envelope, narrow resource limits against policy, parse
//!   the `/sub-agent` JSON command payload, format the result for the
//!   tool-result surface, and find a replay-eligible result inside a
//!   list of session entries.
//! - An **orchestrator** `executeDelegation` that composes
//!   `bounded_subagent_execution.executeBoundedSubAgentTask` with
//!   admission (capability-grant check), policy-derived diagnostics,
//!   store callbacks for `findResult`/`appendInvocation`/`appendResult`,
//!   and the optional custom delegation host.
//!
//! Whichever Zig extension surface eventually grows native sub-agent
//! tool/command registration calls into `executeDelegation` directly.

const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;
const bounded = @import("bounded_subagent_execution.zig");
const subagent_readiness = @import("extension_events.zig");
const extension_policy = @import("../core/extension_policy.zig");
const source_info_mod = @import("../core/source_info.zig");
const session_jsonl = @import("../sessions/session_jsonl.zig");
const reserved = @import("subagent_reserved_names.zig");

// =============================================================================
// Substrate constants (mirror TS export names exactly).
// =============================================================================

pub const SUB_AGENT_READINESS_ENTRY = "sub_agent.readiness";
pub const SUB_AGENT_DELEGATION_RESULT_ENTRY = "sub_agent.delegation.result";
pub const SUB_AGENT_STATUS_MESSAGE = "sub_agent.status";
pub const SUB_AGENT_DELEGATION_TOOL = "sub_agent.delegate";
pub const SUB_AGENT_DELEGATION_COMMAND = "sub-agent";

pub const SubAgentDelegationCapability = enum { agent_delegate };

// =============================================================================
// Pure helpers: resource limit narrowing.
// =============================================================================

/// TS narrowNumericLimit: when both policy and request bound a numeric
/// field, take the smaller; otherwise take whichever is set.
pub fn narrowNumericLimit(policy_limit: ?u64, request_limit: ?u64) ?u64 {
    if (policy_limit == null and request_limit == null) return null;
    if (policy_limit == null) return request_limit;
    if (request_limit == null) return policy_limit;
    return @min(policy_limit.?, request_limit.?);
}

/// TS narrowToolScopes: intersection when both sides bound the set;
/// otherwise return whichever is set. Returned slice is allocator-owned;
/// caller frees with `allocator.free`.
pub fn narrowToolScopes(
    allocator: std.mem.Allocator,
    policy_scopes: ?[]const []const u8,
    request_scopes: ?[]const []const u8,
) !?[][]const u8 {
    if (policy_scopes == null and request_scopes == null) return null;
    if (policy_scopes == null) {
        const src = request_scopes.?;
        return try allocator.dupe([]const u8, src);
    }
    if (request_scopes == null) {
        const src = policy_scopes.?;
        return try allocator.dupe([]const u8, src);
    }
    // Intersection: keep policy_scopes entries that appear in request_scopes.
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (policy_scopes.?) |scope| {
        for (request_scopes.?) |req| {
            if (std.mem.eql(u8, scope, req)) {
                try out.append(allocator, scope);
                break;
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Mirror TS narrowResourceLimits: returns a JSON object containing
/// only the fields that are set after narrowing (or null when neither
/// side bounded anything). Caller owns the returned value and must free
/// with `provider_json.freeValue`.
pub fn narrowResourceLimitsJson(
    allocator: std.mem.Allocator,
    policy_limits: ?extension_policy.ExtensionResourceLimits,
    request_limits_value: ?std.json.Value,
) !?std.json.Value {
    const request_limits = parseRequestLimitsValue(request_limits_value);
    if (policy_limits == null and request_limits == null) return null;

    var out = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = out });

    if (narrowNumericLimit(if (policy_limits) |p| p.max_children else null, if (request_limits) |r| r.max_children else null)) |v| {
        try putInt(allocator, &out, "maxChildren", v);
    }
    if (narrowNumericLimit(if (policy_limits) |p| p.depth else null, if (request_limits) |r| r.depth else null)) |v| {
        try putInt(allocator, &out, "depth", v);
    }
    if (narrowNumericLimit(if (policy_limits) |p| p.turns else null, if (request_limits) |r| r.turns else null)) |v| {
        try putInt(allocator, &out, "turns", v);
    }
    if (narrowNumericLimit(if (policy_limits) |p| p.timeout_ms else null, if (request_limits) |r| r.timeout_ms else null)) |v| {
        try putInt(allocator, &out, "timeoutMs", v);
    }
    if (narrowNumericLimit(if (policy_limits) |p| p.output_bytes else null, if (request_limits) |r| r.output_bytes else null)) |v| {
        try putInt(allocator, &out, "outputBytes", v);
    }
    if (narrowNumericLimit(if (policy_limits) |p| p.output_lines else null, if (request_limits) |r| r.output_lines else null)) |v| {
        try putInt(allocator, &out, "outputLines", v);
    }
    const policy_scopes_opt: ?[]const []const u8 = if (policy_limits) |p|
        if (p.tool_scopes.len > 0) p.tool_scopes else null
    else
        null;
    const request_scopes_borrowed = try collectRequestToolScopes(allocator, request_limits_value);
    defer if (request_scopes_borrowed) |s| allocator.free(s);
    const request_scopes_opt: ?[]const []const u8 = request_scopes_borrowed;
    if (try narrowToolScopes(allocator, policy_scopes_opt, request_scopes_opt)) |scopes| {
        defer allocator.free(scopes);
        var arr = std.json.Array.init(allocator);
        errdefer provider_json.freeValue(allocator, .{ .array = arr });
        for (scopes) |scope| {
            try arr.append(.{ .string = try allocator.dupe(u8, scope) });
        }
        try out.put(allocator, try allocator.dupe(u8, "toolScopes"), .{ .array = arr });
    }
    return .{ .object = out };
}

const RequestLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: ?[]const []const u8 = null,
};

fn parseRequestLimitsValue(value: ?std.json.Value) ?RequestLimits {
    const v = value orelse return null;
    if (v != .object) return null;
    var limits = RequestLimits{};
    if (v.object.get("maxChildren")) |fv| if (fv == .integer and fv.integer >= 0) {
        limits.max_children = @intCast(fv.integer);
    };
    if (v.object.get("depth")) |fv| if (fv == .integer and fv.integer >= 0) {
        limits.depth = @intCast(fv.integer);
    };
    if (v.object.get("turns")) |fv| if (fv == .integer and fv.integer >= 0) {
        limits.turns = @intCast(fv.integer);
    };
    if (v.object.get("timeoutMs")) |fv| if (fv == .integer and fv.integer >= 0) {
        limits.timeout_ms = @intCast(fv.integer);
    };
    if (v.object.get("outputBytes")) |fv| if (fv == .integer and fv.integer >= 0) {
        limits.output_bytes = @intCast(fv.integer);
    };
    if (v.object.get("outputLines")) |fv| if (fv == .integer and fv.integer >= 0) {
        limits.output_lines = @intCast(fv.integer);
    };
    // toolScopes are read directly from the JSON tree inside
    // narrowResourceLimitsJson (avoids an allocation here just to
    // propagate borrowed-string slices).
    return limits;
}

/// Allocate a flat slice of borrowed strings reflecting
/// `request.limits.toolScopes`. Returns null when the field is absent;
/// returns an empty slice (allocator-owned) when the array is present
/// but empty. Caller frees with `allocator.free`. String contents are
/// borrowed from the JSON value and must outlive the returned slice.
fn collectRequestToolScopes(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !?[]const []const u8 {
    const v = value orelse return null;
    if (v != .object) return null;
    const scopes = v.object.get("toolScopes") orelse return null;
    if (scopes != .array) return null;
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (scopes.array.items) |item| {
        if (item == .string) try out.append(allocator, item.string);
    }
    return try out.toOwnedSlice(allocator);
}

// =============================================================================
// Diagnostic detail objects.
// =============================================================================

/// Mirror TS sourceDiagnosticDetails. Caller owns the returned value.
pub fn sourceDiagnosticDetails(
    allocator: std.mem.Allocator,
    info: source_info_mod.SourceInfo,
) !std.json.Value {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStr(allocator, &obj, "scope", scopeName(info.scope));
    try putStr(allocator, &obj, "source", info.source);
    try putStr(allocator, &obj, "origin", originName(info.origin));
    try putStr(allocator, &obj, "path", info.path);
    if (info.base_dir) |dir| try putStr(allocator, &obj, "baseDir", dir);
    return .{ .object = obj };
}

/// Mirror TS policyDiagnosticDetails. Caller owns the returned value.
pub fn policyDiagnosticDetails(
    allocator: std.mem.Allocator,
    identity: extension_policy.CanonicalExtensionIdentity,
    extension_kind: ?[]const u8, // TS includes both runtimeKind and a separate "kind"; Zig identity only has runtime_kind.
    info: ?source_info_mod.SourceInfo,
) !std.json.Value {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });

    try putStr(allocator, &obj, "extensionIdentity", identity.key);
    if (extension_kind) |k| try putStr(allocator, &obj, "extensionKind", k);
    try putStr(allocator, &obj, "extensionDisplayName", identity.display_name);
    try putStr(allocator, &obj, "runtimeKind", runtimeKindName(identity.runtime_kind));

    var principal = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = principal });
    try putStr(allocator, &principal, "runtimeKind", runtimeKindName(identity.runtime_kind));
    try putStr(allocator, &principal, "extensionId", identity.key);
    if (extension_kind) |k| try putStr(allocator, &principal, "extensionKind", k);
    try putStr(allocator, &principal, "displayName", identity.display_name);
    try obj.put(allocator, try allocator.dupe(u8, "principal"), .{ .object = principal });

    var target = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = target });
    try putStr(allocator, &target, "id", SUB_AGENT_DELEGATION_TOOL);
    try obj.put(allocator, try allocator.dupe(u8, "target"), .{ .object = target });

    if (info) |i| {
        const src = try sourceDiagnosticDetails(allocator, i);
        try obj.put(allocator, try allocator.dupe(u8, "source"), src);
    }
    return .{ .object = obj };
}

// =============================================================================
// Cancellation / command-payload helpers.
// =============================================================================

/// Mirror TS normalizeCancellation: if the caller's abort flag is set,
/// merge the existing cancellation block with `state = "requested"` and
/// a `reason` fallback. Returns a JSON object (caller owns) or null if
/// nothing to emit.
pub fn normalizeCancellation(
    allocator: std.mem.Allocator,
    cancellation_value: ?std.json.Value,
    signal_aborted: bool,
    abort_reason: ?[]const u8,
) !?std.json.Value {
    if (!signal_aborted) {
        if (cancellation_value) |cv| return try provider_json.cloneValue(allocator, cv);
        return null;
    }
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });

    if (cancellation_value) |cv| if (cv == .object) {
        var iter = cv.object.iterator();
        while (iter.next()) |entry| {
            try obj.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try provider_json.cloneValue(allocator, entry.value_ptr.*),
            );
        }
    };
    // state = "requested" (overwrite any existing).
    if (obj.fetchOrderedRemove("state")) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try obj.put(allocator, try allocator.dupe(u8, "state"), .{ .string = try allocator.dupe(u8, "requested") });
    // reason = existing.reason || abort_reason || "abort signal requested"
    if (!obj.contains("reason")) {
        const r = abort_reason orelse "abort signal requested";
        try obj.put(allocator, try allocator.dupe(u8, "reason"), .{ .string = try allocator.dupe(u8, r) });
    }
    return .{ .object = obj };
}

/// Mirror TS parseCommandPayload: trim, error on empty, JSON.parse.
/// Returns std.json.Parsed — caller must `.deinit()` to free.
pub fn parseCommandPayload(
    allocator: std.mem.Allocator,
    args: []const u8,
) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return error.SubAgentCommandEmptyPayload;
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
}

// =============================================================================
// Replay lookup against session entries.
// =============================================================================

/// Walk session entries in reverse looking for the most recent
/// `sub_agent.delegation.result` CustomEntry whose
/// (agentId, runId, taskId, sessionId) matches `invocation`. Returns a
/// clone of the matching `data` (caller owns; free with
/// `provider_json.freeValue`) or null.
pub fn findRecordedDelegationResult(
    allocator: std.mem.Allocator,
    entries: []const session_jsonl.SessionEntry,
    invocation: std.json.Value,
) !?std.json.Value {
    if (invocation != .object) return null;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const entry = entries[i];
        if (entry != .custom) continue;
        const custom = entry.custom;
        if (!std.mem.eql(u8, custom.custom_type, SUB_AGENT_DELEGATION_RESULT_ENTRY)) continue;
        const data = custom.data orelse continue;
        if (data != .object) continue;
        // Cheap pre-check on correlation fields before paying for validation.
        if (!strEqOpt(invocation.object.get("agentId"), data.object.get("agentId"))) continue;
        if (!strEqOpt(invocation.object.get("runId"), data.object.get("runId"))) continue;
        if (!strEqOpt(invocation.object.get("taskId"), data.object.get("taskId"))) continue;
        if (!strEqOpt(invocation.object.get("sessionId"), data.object.get("sessionId"))) continue;
        // Validate before returning to mirror TS try/catch skip semantics.
        var validation = subagent_readiness.validateSubAgentTaskResultEnvelope(allocator, data.object) catch continue;
        defer validation.deinit(allocator);
        if (validation == .invalid) continue;
        return try provider_json.cloneValue(allocator, data);
    }
    return null;
}

// =============================================================================
// Tool-result helper.
// =============================================================================

pub const ToolResultBundle = struct {
    content_text: []u8, // owned, freed by deinit
    details: std.json.Value, // owned, freed by deinit

    pub fn deinit(self: *ToolResultBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.content_text);
        provider_json.freeValue(allocator, self.details);
        self.* = undefined;
    }
};

/// Mirror TS `toToolResult`: stringifies the result envelope into the
/// content-text slot and keeps the structured envelope in the details
/// slot. Caller owns both via `ToolResultBundle.deinit`.
pub fn toToolResult(allocator: std.mem.Allocator, result: std.json.Value) !ToolResultBundle {
    const json = try std.json.Stringify.valueAlloc(allocator, result, .{});
    errdefer allocator.free(json);
    const details_clone = try provider_json.cloneValue(allocator, result);
    return .{ .content_text = json, .details = details_clone };
}

// =============================================================================
// Invocation builder.
// =============================================================================

/// Build a `sub_agent_task_invocation` envelope (`std.json.Value`) from
/// the public input shape. Caller owns the returned value. Mirrors TS
/// `buildInvocation` but takes the request shape as a parsed JSON Value
/// (matching `subAgentDelegationInputSchema`'s field layout).
pub fn buildInvocation(
    allocator: std.mem.Allocator,
    params: std.json.Value,
    signal_aborted: bool,
    abort_reason: ?[]const u8,
    policy_limits: ?extension_policy.ExtensionResourceLimits,
    policy_details: ?std.json.Value,
) !std.json.Value {
    if (params != .object) return error.InvalidSubAgentEnvelope;

    var candidate = try provider_json.cloneValue(allocator, params);
    errdefer provider_json.freeValue(allocator, candidate);

    // type = "sub_agent_task_invocation"
    if (candidate.object.fetchOrderedRemove("type")) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try candidate.object.put(
        allocator,
        try allocator.dupe(u8, "type"),
        .{ .string = try allocator.dupe(u8, "sub_agent_task_invocation") },
    );

    // metadata: merge { ...params.metadata, policyDiagnostics: policy_details }
    {
        const existing_metadata = candidate.object.get("metadata");
        var metadata_obj = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = metadata_obj });
        if (existing_metadata) |mv| if (mv == .object) {
            var iter = mv.object.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "policyDiagnostics")) continue;
                try metadata_obj.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try provider_json.cloneValue(allocator, entry.value_ptr.*),
                );
            }
        };
        if (policy_details) |pd| {
            try metadata_obj.put(
                allocator,
                try allocator.dupe(u8, "policyDiagnostics"),
                try provider_json.cloneValue(allocator, pd),
            );
        }
        if (candidate.object.fetchOrderedRemove("metadata")) |kv_const| {
            allocator.free(kv_const.key);
            provider_json.freeValue(allocator, kv_const.value);
        }
        try candidate.object.put(allocator, try allocator.dupe(u8, "metadata"), .{ .object = metadata_obj });
    }

    // limits: narrowResourceLimitsJson(policy_limits, params.limits)
    const request_limits_value = candidate.object.get("limits");
    if (try narrowResourceLimitsJson(allocator, policy_limits, request_limits_value)) |narrowed| {
        if (candidate.object.fetchOrderedRemove("limits")) |kv_const| {
            allocator.free(kv_const.key);
            provider_json.freeValue(allocator, kv_const.value);
        }
        try candidate.object.put(allocator, try allocator.dupe(u8, "limits"), narrowed);
    }

    // cancellation: normalizeCancellation(params.cancellation, signal_aborted)
    const cancellation_value = candidate.object.get("cancellation");
    if (try normalizeCancellation(allocator, cancellation_value, signal_aborted, abort_reason)) |normalized| {
        if (candidate.object.fetchOrderedRemove("cancellation")) |kv_const| {
            allocator.free(kv_const.key);
            provider_json.freeValue(allocator, kv_const.value);
        }
        try candidate.object.put(allocator, try allocator.dupe(u8, "cancellation"), normalized);
    }

    return candidate;
}

// =============================================================================
// Orchestrator.
// =============================================================================

pub const DelegateFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    execution_context: *bounded.ExecutionContext,
) anyerror!std.json.Value;

pub const StoreAppendFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    envelope_type: []const u8, // "sub_agent.readiness" or "sub_agent.delegation.result"
    envelope: std.json.Value,
) anyerror!void;

pub const ReadinessPhase = enum { recorded, replayed };

pub const ReadinessEmitFn = *const fn (
    ctx: ?*anyopaque,
    envelope: std.json.Value,
    phase: ReadinessPhase,
) anyerror!void;

pub const DelegationOptions = struct {
    /// Policy is mandatory for the admission check to grant
    /// `agent.delegate`. If null, fallback_approved_capabilities must
    /// list `.agent_delegate` to allow the invocation through.
    policy: ?extension_policy.ExtensionPolicy = null,
    identity: extension_policy.CanonicalExtensionIdentity,
    extension_kind: ?[]const u8 = null,
    source_info: ?source_info_mod.SourceInfo = null,
    fallback_approved_capabilities: []const SubAgentDelegationCapability = &.{},

    /// Pluggable delegation host (defaults to bounded's built-in echo
    /// executor when null).
    delegate: ?DelegateFn = null,
    delegate_ctx: ?*anyopaque = null,

    /// Session entries used by the replay path's `findResult` callback.
    /// Pass `&.{}` if the integrator doesn't keep an indexed history.
    session_entries: []const session_jsonl.SessionEntry = &.{},

    /// Hook for persisting envelopes through the integrator's session
    /// log. The TS version calls `pi.appendEntry` here.
    append_entry: ?StoreAppendFn = null,
    append_entry_ctx: ?*anyopaque = null,

    /// Hook for emitting readiness observations (mirrors TS
    /// `ctx.emitSubAgentReadiness`).
    emit_readiness: ?ReadinessEmitFn = null,
    emit_readiness_ctx: ?*anyopaque = null,

    /// Cancellation / timeout — forwarded to bounded executor.
    abort_flag: ?*const std.atomic.Value(bool) = null,
    abort_reason: ?[]const u8 = null,
    deadline_ns: ?i128 = null,

    now_fn: ?*const fn () i64 = null,
};

/// Mirror TS createSubAgentExtension's inner `executeDelegation`
/// closure. Builds the invocation, runs bounded execution under
/// admission + store callbacks, and returns the result envelope
/// (caller owns; free with `provider_json.freeValue`).
pub fn executeDelegation(
    allocator: std.mem.Allocator,
    params: std.json.Value,
    options: DelegationOptions,
) !std.json.Value {
    const signal_aborted = options.abort_flag != null and options.abort_flag.?.load(.acquire);

    // policy_details = policyDiagnosticDetails(identity, source_info)
    var policy_details: ?std.json.Value = null;
    defer if (policy_details) |pd| provider_json.freeValue(allocator, pd);
    policy_details = try policyDiagnosticDetails(allocator, options.identity, options.extension_kind, options.source_info);

    const policy_limits = if (options.policy) |p| p.resource_limits else null;
    const invocation = try buildInvocation(allocator, params, signal_aborted, options.abort_reason, policy_limits, policy_details);
    defer provider_json.freeValue(allocator, invocation);

    var orchestrator_ctx = OrchestratorContext{
        .allocator = allocator,
        .options = options,
        .policy_details = policy_details,
    };
    const bounded_options = bounded.ExecutionOptions{
        .executor = if (options.delegate != null) defaultDelegateAdapter else null,
        .executor_ctx = @ptrCast(&orchestrator_ctx),
        .admission = admissionAdapter,
        .admission_ctx = @ptrCast(&orchestrator_ctx),
        .store = .{
            .find_result = findResultAdapter,
            .append_invocation = appendInvocationAdapter,
            .append_result = appendResultAdapter,
            .ctx = @ptrCast(&orchestrator_ctx),
        },
        .abort_flag = options.abort_flag,
        .abort_reason = options.abort_reason,
        .deadline_ns = options.deadline_ns,
        .now_fn = options.now_fn,
    };
    const result = try bounded.executeBoundedSubAgentTask(allocator, invocation, bounded_options);
    if (orchestrator_ctx.replayed_result) |replayed_clone| {
        defer provider_json.freeValue(allocator, replayed_clone);
        if (options.emit_readiness) |emit| {
            try emit(options.emit_readiness_ctx, replayed_clone, .replayed);
        }
    }
    return result;
}

const OrchestratorContext = struct {
    allocator: std.mem.Allocator,
    options: DelegationOptions,
    policy_details: ?std.json.Value,
    replayed_result: ?std.json.Value = null,
};

fn admissionAdapter(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
) anyerror!?bounded.AdmissionDenial {
    _ = invocation;
    const orch: *OrchestratorContext = @ptrCast(@alignCast(ctx.?));
    if (capabilityApproved(orch.options)) return null;
    // Build a denial with full diagnostic detail tree (mirrors TS).
    var details_obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = details_obj });
    try putStr(allocator, &details_obj, "category", "denied_capability");
    try putStr(allocator, &details_obj, "capability", "agent.delegate");
    try putStr(allocator, &details_obj, "operation", "agent.delegate");
    try putStr(allocator, &details_obj, "branch", "agent.delegate");
    try putStr(allocator, &details_obj, "phase", "call");
    try putStr(allocator, &details_obj, "mode", "zig/sub-agent-admission");
    try putStr(allocator, &details_obj, "reason", "grant is not approved");
    if (orch.policy_details) |pd| if (pd == .object) {
        var iter = pd.object.iterator();
        while (iter.next()) |entry| {
            try details_obj.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try provider_json.cloneValue(allocator, entry.value_ptr.*),
            );
        }
    };
    return bounded.AdmissionDenial{
        .reason = "denied_capability",
        .message = "grant is not approved",
        .details = .{ .object = details_obj },
    };
}

fn findResultAdapter(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
) anyerror!?std.json.Value {
    const orch: *OrchestratorContext = @ptrCast(@alignCast(ctx.?));
    if (orch.options.session_entries.len == 0) return null;
    const result_opt = try findRecordedDelegationResult(allocator, orch.options.session_entries, invocation);
    if (result_opt) |result| {
        // Cache a clone so executeDelegation can emit a replayed observation later.
        orch.replayed_result = try provider_json.cloneValue(allocator, result);
    }
    return result_opt;
}

fn appendInvocationAdapter(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
) anyerror!void {
    const orch: *OrchestratorContext = @ptrCast(@alignCast(ctx.?));
    if (orch.options.append_entry) |append| {
        try append(orch.options.append_entry_ctx, allocator, SUB_AGENT_READINESS_ENTRY, invocation);
    }
    if (orch.options.emit_readiness) |emit| {
        try emit(orch.options.emit_readiness_ctx, invocation, .recorded);
    }
}

fn appendResultAdapter(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    result: std.json.Value,
) anyerror!void {
    const orch: *OrchestratorContext = @ptrCast(@alignCast(ctx.?));
    if (orch.options.append_entry) |append| {
        try append(orch.options.append_entry_ctx, allocator, SUB_AGENT_DELEGATION_RESULT_ENTRY, result);
    }
    if (orch.options.emit_readiness) |emit| {
        try emit(orch.options.emit_readiness_ctx, result, .recorded);
    }
}

fn defaultDelegateAdapter(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    execution_context: *bounded.ExecutionContext,
) anyerror!std.json.Value {
    const orch: *OrchestratorContext = @ptrCast(@alignCast(ctx.?));
    if (orch.options.delegate) |delegate| {
        return delegate(orch.options.delegate_ctx, allocator, invocation, execution_context);
    }
    return bounded.defaultBoundedSubAgentExecutor(null, allocator, invocation, execution_context);
}

fn capabilityApproved(options: DelegationOptions) bool {
    if (options.policy) |policy| {
        return extension_policy.hasExtensionGrant(policy, .agent_delegate);
    }
    for (options.fallback_approved_capabilities) |cap| {
        if (cap == .agent_delegate) return true;
    }
    return false;
}

// =============================================================================
// Small helpers.
// =============================================================================

fn putStr(allocator: std.mem.Allocator, dst: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try dst.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putInt(allocator: std.mem.Allocator, dst: *std.json.ObjectMap, key: []const u8, value: u64) !void {
    try dst.put(allocator, try allocator.dupe(u8, key), .{ .integer = @intCast(value) });
}

fn strEqOpt(a: ?std.json.Value, b: ?std.json.Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    if (a.? != .string or b.? != .string) return false;
    return std.mem.eql(u8, a.?.string, b.?.string);
}

fn scopeName(scope: source_info_mod.SourceScope) []const u8 {
    return @tagName(scope);
}

fn originName(origin: source_info_mod.SourceOrigin) []const u8 {
    return switch (origin) {
        .top_level => "top-level",
        .package => "package",
    };
}

fn runtimeKindName(kind: extension_policy.ExtensionPolicyRuntimeKind) []const u8 {
    return switch (kind) {
        .typescript => "typescript",
        .wasm => "wasm",
        .native => "native",
        .process_jsonl => "process-jsonl",
    };
}

// =============================================================================
// Tests.
// =============================================================================

const testing = std.testing;

test "narrowNumericLimit picks the smaller bound when both sides set" {
    try testing.expectEqual(@as(?u64, 3), narrowNumericLimit(3, 5));
    try testing.expectEqual(@as(?u64, 3), narrowNumericLimit(5, 3));
    try testing.expectEqual(@as(?u64, 7), narrowNumericLimit(7, null));
    try testing.expectEqual(@as(?u64, 9), narrowNumericLimit(null, 9));
    try testing.expectEqual(@as(?u64, null), narrowNumericLimit(null, null));
}

test "narrowToolScopes intersects both sides" {
    const allocator = testing.allocator;
    const policy = [_][]const u8{ "read", "write", "exec" };
    const request = [_][]const u8{ "write", "exec", "ping" };
    const got = (try narrowToolScopes(allocator, &policy, &request)).?;
    defer allocator.free(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("write", got[0]);
    try testing.expectEqualStrings("exec", got[1]);
}

test "parseCommandPayload errors on empty input" {
    const allocator = testing.allocator;
    try testing.expectError(error.SubAgentCommandEmptyPayload, parseCommandPayload(allocator, "   "));
}

test "parseCommandPayload parses JSON" {
    const allocator = testing.allocator;
    var parsed = try parseCommandPayload(allocator, "  {\"foo\": 1}  ");
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("foo").?.integer);
}

test "policyDiagnosticDetails emits identity + target + source" {
    const allocator = testing.allocator;
    const identity = extension_policy.CanonicalExtensionIdentity{
        .key = "ext-1",
        .runtime_kind = .typescript,
        .display_name = "Ext One",
    };
    const info = source_info_mod.SourceInfo{
        .path = "/tmp/ext/SKILL.md",
        .source = "local",
        .scope = .user,
        .origin = .top_level,
    };
    var v = try policyDiagnosticDetails(allocator, identity, "skill", info);
    defer provider_json.freeValue(allocator, v);
    try testing.expectEqualStrings("ext-1", v.object.get("extensionIdentity").?.string);
    try testing.expectEqualStrings("skill", v.object.get("extensionKind").?.string);
    try testing.expectEqualStrings("Ext One", v.object.get("extensionDisplayName").?.string);
    try testing.expectEqualStrings("typescript", v.object.get("runtimeKind").?.string);
    try testing.expectEqualStrings(SUB_AGENT_DELEGATION_TOOL, v.object.get("target").?.object.get("id").?.string);
    try testing.expectEqualStrings("local", v.object.get("source").?.object.get("source").?.string);
}

test "normalizeCancellation produces requested+reason when aborted" {
    const allocator = testing.allocator;
    var v_opt = try normalizeCancellation(allocator, null, true, "user-pressed-ctrl-c");
    defer if (v_opt) |v| provider_json.freeValue(allocator, v);
    try testing.expect(v_opt != null);
    try testing.expectEqualStrings("requested", v_opt.?.object.get("state").?.string);
    try testing.expectEqualStrings("user-pressed-ctrl-c", v_opt.?.object.get("reason").?.string);
}

test "normalizeCancellation passes through when not aborted" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"state\":\"pending\"}", .{});
    defer parsed.deinit();
    var v_opt = try normalizeCancellation(allocator, parsed.value, false, null);
    defer if (v_opt) |v| provider_json.freeValue(allocator, v);
    try testing.expect(v_opt != null);
    try testing.expectEqualStrings("pending", v_opt.?.object.get("state").?.string);
}

test "executeDelegation denies invocation when grant not approved" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "agentId": "a", "runId": "r", "taskId": "t", "sessionId": "s",
        \\  "input": { "prompt": "hi" }
        \\}
    , .{});
    defer parsed.deinit();

    var result = try executeDelegation(allocator, parsed.value, .{
        .identity = .{
            .key = "ext-deny",
            .runtime_kind = .typescript,
            .display_name = "Ext Deny",
        },
    });
    defer provider_json.freeValue(allocator, result);
    try testing.expectEqualStrings("failed", result.object.get("status").?.string);
    const err_obj = result.object.get("error").?.object;
    try testing.expectEqualStrings("denied_capability", err_obj.get("reason").?.string);
    try testing.expectEqualStrings("grant is not approved", err_obj.get("message").?.string);
}

test "executeDelegation allows invocation when fallback grants agent.delegate" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "agentId": "a", "runId": "r", "taskId": "t", "sessionId": "s",
        \\  "input": { "prompt": "hi" }
        \\}
    , .{});
    defer parsed.deinit();

    var result = try executeDelegation(allocator, parsed.value, .{
        .identity = .{
            .key = "ext-allow",
            .runtime_kind = .typescript,
            .display_name = "Ext Allow",
        },
        .fallback_approved_capabilities = &.{.agent_delegate},
    });
    defer provider_json.freeValue(allocator, result);
    try testing.expectEqualStrings("completed", result.object.get("status").?.string);
    // policyDiagnostics propagated into the invocation envelope but the
    // result is the bounded executor's success envelope.
    const content = result.object.get("content").?.array;
    try testing.expect(content.items.len >= 1);
}

test "toToolResult stringifies envelope and clones details" {
    const allocator = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"status\":\"completed\"}", .{});
    defer parsed.deinit();
    var bundle = try toToolResult(allocator, parsed.value);
    defer bundle.deinit(allocator);
    try testing.expect(std.mem.indexOf(u8, bundle.content_text, "completed") != null);
    try testing.expectEqualStrings("completed", bundle.details.object.get("status").?.string);
}
