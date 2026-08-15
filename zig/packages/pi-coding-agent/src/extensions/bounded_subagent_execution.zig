//! Mirror of packages/coding-agent/src/core/extensions/bounded-subagent-execution.ts.
//!
//! Executes a sub-agent task invocation under resource limits (turns,
//! depth, output bytes/lines, tool scopes, deadline) and returns a
//! `sub_agent_task_result` envelope. Envelopes flow as `std.json.Value`
//! trees so they round-trip through the existing
//! `extension_events.validateSubAgentTask{Invocation,Result}Envelope`
//! validators unchanged.
//!
//! Async semantics differ from TS:
//! - **cancellation**: TS uses `AbortSignal`; Zig accepts an
//!   `?*const std.atomic.Value(bool)` flag the caller flips to request
//!   cancellation. The executor checks before/after dispatch.
//! - **timeout**: TS uses `setTimeout`; Zig accepts an absolute
//!   `deadline_ns` (nanoseconds since `std.time.nanoTimestamp` epoch);
//!   any boundary observed after the deadline flips the result into a
//!   `resource_limit_exceeded: timeoutMs` failure.
//! - **tools/admission/store/executor**: function pointers with an
//!   `*anyopaque` ctx slot — Zig's closure substitute.
//!
//! The TS Promise.race "first of execution / timeout / cancellation"
//! collapses to a synchronous executor call wrapped in pre- and
//! post-checks. This is sufficient for the Zig agent loop's
//! single-threaded execution model and matches how every other tool
//! handler in zig/src/coding_agent runs.

const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;
const subagent_readiness = @import("extension_events.zig");

pub const ToolResult = struct {
    ok: bool,
    output: ?std.json.Value = null,
    error_info: ?ErrorInfo = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        if (self.output) |value| provider_json.freeValue(allocator, value);
        if (self.error_info) |*info| info.deinit(allocator);
        self.* = undefined;
    }
};

pub const ErrorInfo = struct {
    reason: []const u8, // borrowed (caller manages lifetime)
    message: []const u8, // borrowed
    details: ?std.json.Value = null, // owned when present

    pub fn deinit(self: *ErrorInfo, allocator: std.mem.Allocator) void {
        if (self.details) |value| provider_json.freeValue(allocator, value);
        self.* = undefined;
    }
};

pub const AdmissionDenial = struct {
    reason: []const u8,
    message: []const u8,
    details: ?std.json.Value = null,
};

pub const ToolHandlerFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: std.json.Value,
) anyerror!std.json.Value;

pub const ToolEntry = struct {
    name: []const u8,
    handler: ToolHandlerFn,
    ctx: ?*anyopaque = null,
};

pub const ExecutorFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    context: *ExecutionContext,
) anyerror!std.json.Value;

pub const AdmissionFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
) anyerror!?AdmissionDenial;

pub const FindResultFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
) anyerror!?std.json.Value;

pub const AppendInvocationFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
) anyerror!void;

pub const AppendResultFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    result: std.json.Value,
) anyerror!void;

pub const Store = struct {
    find_result: ?FindResultFn = null,
    append_invocation: ?AppendInvocationFn = null,
    append_result: ?AppendResultFn = null,
    ctx: ?*anyopaque = null,
};

pub const ExecutionOptions = struct {
    executor: ?ExecutorFn = null,
    executor_ctx: ?*anyopaque = null,
    admission: ?AdmissionFn = null,
    admission_ctx: ?*anyopaque = null,
    store: Store = .{},
    tools: []const ToolEntry = &.{},
    abort_flag: ?*const std.atomic.Value(bool) = null,
    abort_reason: ?[]const u8 = null,
    deadline_ns: ?i128 = null,
    now_fn: ?*const fn () i64 = null,
};

pub const ExecutionContext = struct {
    invocation: std.json.Value,
    runtime: *RuntimeAccounting,
    tools: []const ToolEntry,
    abort_flag: ?*const std.atomic.Value(bool),
    deadline_ns: ?i128,

    /// Returns true if cancellation has been requested OR the deadline
    /// has elapsed. Executors should poll this between expensive steps.
    pub fn aborted(self: ExecutionContext) bool {
        if (self.abort_flag) |flag| if (flag.load(.acquire)) return true;
        if (self.deadline_ns) |deadline| if (std.time.nanoTimestamp() >= deadline) return true;
        return false;
    }

    /// Mirror of TS `context.consumeTurn`: increment turn counter and
    /// return error.ResourceLimitTurns if the new value would exceed
    /// `limits.turns`.
    pub fn consumeTurn(self: ExecutionContext, count: u32) ResourceLimitError!void {
        const next = self.runtime.turns + count;
        if (readLimitU64(self.invocation, "turns")) |limit| {
            if (next > limit) {
                self.runtime.turns = @intCast(limit);
                return error.ResourceLimitTurns;
            }
        }
        self.runtime.turns = next;
    }

    pub fn runTool(
        self: ExecutionContext,
        allocator: std.mem.Allocator,
        name: []const u8,
        input: std.json.Value,
    ) anyerror!ToolResult {
        if (toolScopesDenies(self.invocation, name)) {
            self.runtime.denied_tool = name;
            return .{
                .ok = false,
                .error_info = .{
                    .reason = "resource_limit_exceeded",
                    .message = "resource limit exceeded: toolScopes",
                    .details = try buildToolDenialDetails(allocator, name, self.invocation),
                },
            };
        }
        for (self.tools) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            const output = try entry.handler(entry.ctx, allocator, input);
            return .{ .ok = true, .output = output };
        }
        return .{ .ok = true, .output = null };
    }
};

pub const RuntimeAccounting = struct {
    turns: u32 = 0,
    children_started: u32 = 1,
    denied_tool: ?[]const u8 = null,
};

pub const ResourceLimitError = error{
    ResourceLimitTurns,
    ResourceLimitMaxChildren,
    ResourceLimitOutputBytes,
    ResourceLimitOutputLines,
    ResourceLimitTimeout,
    ResourceLimitDepth,
    ResourceLimitToolScopes,
};

const LimitName = enum {
    turns,
    maxChildren,
    outputBytes,
    outputLines,
    timeoutMs,
    depth,
    toolScopes,

    pub fn asString(self: LimitName) []const u8 {
        return @tagName(self);
    }
};

fn limitFromError(err: ResourceLimitError) LimitName {
    return switch (err) {
        error.ResourceLimitTurns => .turns,
        error.ResourceLimitMaxChildren => .maxChildren,
        error.ResourceLimitOutputBytes => .outputBytes,
        error.ResourceLimitOutputLines => .outputLines,
        error.ResourceLimitTimeout => .timeoutMs,
        error.ResourceLimitDepth => .depth,
        error.ResourceLimitToolScopes => .toolScopes,
    };
}

// =============================================================================
// Public API.
// =============================================================================

/// Execute a sub-agent task invocation under resource limits. Returns
/// a `sub_agent_task_result` envelope (`std.json.Value`); the caller
/// owns the returned value and must free with `provider_json.freeValue`.
///
/// `input` must be a JSON value the existing
/// `validateSubAgentTaskInvocationEnvelope` accepts. Invalid envelopes
/// surface as `error.InvalidSubAgentEnvelope` (caller can convert that
/// to a failed result if needed; the TS version throws).
pub fn executeBoundedSubAgentTask(
    allocator: std.mem.Allocator,
    input: std.json.Value,
    options: ExecutionOptions,
) !std.json.Value {
    const invocation_object = switch (input) {
        .object => |o| o,
        else => return error.InvalidSubAgentEnvelope,
    };
    var invocation_validation = try subagent_readiness.validateSubAgentTaskInvocationEnvelope(allocator, invocation_object);
    defer invocation_validation.deinit(allocator);
    if (invocation_validation == .invalid) return error.InvalidSubAgentEnvelope;

    // Replay: if the store already has a result keyed by the
    // (agentId, runId, taskId, sessionId) tuple, return it.
    if (options.store.find_result) |find_result| {
        const replayed_opt = try find_result(options.store.ctx, allocator, input);
        if (replayed_opt) |replayed| {
            if (replayKeyMatches(input, replayed)) return replayed;
            // Mismatched replay key — discard and fall through.
            provider_json.freeValue(allocator, replayed);
        }
    }

    // Pre-existing cancellation: TS checks cancellation.state ==
    // "requested" OR signal.aborted; Zig checks the cancellation field
    // and the abort flag.
    const pre_cancelled = isCancellationRequested(input) or
        (options.abort_flag != null and options.abort_flag.?.load(.acquire));
    if (pre_cancelled) {
        const propagated = try propagateCancellation(allocator, input, options.abort_reason);
        defer provider_json.freeValue(allocator, propagated);
        if (options.store.append_invocation) |append_invocation| {
            try append_invocation(options.store.ctx, allocator, propagated);
        }
        const summary = try zeroResourceSummary(allocator, input);
        const result = try buildCancelledResult(allocator, propagated, options.now_fn, summary);
        if (options.store.append_result) |append_result| {
            try append_result(options.store.ctx, allocator, result);
        }
        return result;
    }

    if (options.store.append_invocation) |append_invocation| {
        try append_invocation(options.store.ctx, allocator, input);
    }

    if (options.admission) |admission| {
        if (try admission(options.admission_ctx, allocator, input)) |denial| {
            const summary = try zeroResourceSummary(allocator, input);
            const result = try buildFailedResult(allocator, input, options.now_fn, .{
                .reason = denial.reason,
                .message = denial.message,
                .details = denial.details,
                .resource_summary = summary,
            });
            if (options.store.append_result) |append_result| {
                try append_result(options.store.ctx, allocator, result);
            }
            return result;
        }
    }

    if (exhaustedAdmissionLimit(input)) |limit_err| {
        const summary = try zeroResourceSummary(allocator, input);
        const result = try buildResourceLimitResult(allocator, input, options.now_fn, limit_err, summary, null);
        if (options.store.append_result) |append_result| {
            try append_result(options.store.ctx, allocator, result);
        }
        return result;
    }

    var runtime = RuntimeAccounting{};
    var context = ExecutionContext{
        .invocation = input,
        .runtime = &runtime,
        .tools = options.tools,
        .abort_flag = options.abort_flag,
        .deadline_ns = options.deadline_ns,
    };

    // Mid-flight cancellation / timeout race vs executor. Zig is
    // synchronous, so we just check before and after the executor call.
    if (context.aborted()) return try buildAbortResult(allocator, input, options, &runtime);

    const executor = options.executor orelse defaultBoundedSubAgentExecutor;
    var executor_failed: bool = false;
    var executor_value: ?std.json.Value = null;
    var captured_limit_err: ?ResourceLimitError = null;
    var captured_error_message: ?[]u8 = null;
    defer if (captured_error_message) |m| allocator.free(m);

    if (executor(options.executor_ctx, allocator, input, &context)) |value| {
        executor_value = value;
    } else |err| {
        executor_failed = true;
        switch (err) {
            error.ResourceLimitTurns,
            error.ResourceLimitMaxChildren,
            error.ResourceLimitOutputBytes,
            error.ResourceLimitOutputLines,
            error.ResourceLimitTimeout,
            error.ResourceLimitDepth,
            error.ResourceLimitToolScopes,
            => captured_limit_err = @errorCast(err),
            else => captured_error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
        }
    }

    // Post-execution: cancellation/deadline wins over executor success.
    if (context.aborted() and executor_value != null) {
        provider_json.freeValue(allocator, executor_value.?);
        executor_value = null;
        return try buildAbortResult(allocator, input, options, &runtime);
    }

    if (executor_failed) {
        const summary = try summaryFromRuntime(allocator, input, runtime);
        if (captured_limit_err) |limit_err| {
            const result = try buildResourceLimitResult(allocator, input, options.now_fn, limit_err, summary, null);
            if (options.store.append_result) |append_result| {
                try append_result(options.store.ctx, allocator, result);
            }
            return result;
        }
        if (context.aborted()) return try buildAbortResult(allocator, input, options, &runtime);
        const msg = captured_error_message orelse try allocator.dupe(u8, "child execution failed");
        const result = try buildFailedResult(allocator, input, options.now_fn, .{
            .reason = "child_execution_failed",
            .message = msg,
            .details = null,
            .resource_summary = summary,
        });
        if (options.store.append_result) |append_result| {
            try append_result(options.store.ctx, allocator, result);
        }
        return result;
    }

    // Validate and renormalize the executor's result envelope.
    var raw_result = executor_value.?;
    errdefer provider_json.freeValue(allocator, raw_result);
    var raw_object = switch (raw_result) {
        .object => |o| o,
        else => return error.InvalidSubAgentEnvelope,
    };
    var result_validation = try subagent_readiness.validateSubAgentTaskResultEnvelope(allocator, raw_object);
    defer result_validation.deinit(allocator);
    if (result_validation == .invalid) return error.InvalidSubAgentEnvelope;

    // Normalize correlation IDs to those of the invocation (the
    // executor may have echoed back a different shape).
    try copyCorrelationFields(allocator, &raw_object, input);
    raw_result = .{ .object = raw_object };

    // Apply runtime boundaries (turn/maxChildren/toolScopes/output limits).
    const bounded = try enforceRuntimeBoundaries(allocator, input, raw_result, &runtime, options.now_fn);
    if (options.store.append_result) |append_result| {
        try append_result(options.store.ctx, allocator, bounded);
    }
    return bounded;
}

/// Built-in fallback executor: echoes a deterministic
/// `delegated:<route>:<input-json>` text result. Mirrors TS
/// `defaultBoundedSubAgentExecutor`.
pub fn defaultBoundedSubAgentExecutor(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    context: *ExecutionContext,
) anyerror!std.json.Value {
    _ = ctx;
    _ = context;
    const route = readOptionalString(invocation, "route") orelse "default";
    const input_value = invocation.object.get("input") orelse .null;
    const input_json = try std.json.Stringify.valueAlloc(allocator, input_value, .{});
    defer allocator.free(input_json);
    const text = try std.fmt.allocPrint(allocator, "delegated:{s}:{s}", .{ route, input_json });
    defer allocator.free(text);
    const bytes_count: u64 = text.len;
    const lines_count: u64 = countLines(text);

    var result_object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = result_object });

    try copyCorrelationFields(allocator, &result_object, invocation);
    try putStr(allocator, &result_object, "type", "sub_agent_task_result");
    try putStr(allocator, &result_object, "status", "completed");

    // content: [ { type: "text", text } ]
    var content_array = std.json.Array.init(allocator);
    errdefer provider_json.freeValue(allocator, .{ .array = content_array });
    var text_block = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = text_block });
    try putStr(allocator, &text_block, "type", "text");
    try putStr(allocator, &text_block, "text", text);
    try content_array.append(.{ .object = text_block });
    try putObj(allocator, &result_object, "content", .{ .array = content_array });

    const timestamp: i64 = std.time.milliTimestamp();
    try putInt(allocator, &result_object, "startedAt", timestamp);
    try putInt(allocator, &result_object, "completedAt", timestamp);

    // details: { capability, operation, route }
    var details = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = details });
    try putStr(allocator, &details, "capability", "agent.delegate");
    try putStr(allocator, &details, "operation", "agent.delegate");
    if (readOptionalString(invocation, "route")) |route_str| {
        try putStr(allocator, &details, "route", route_str);
    }
    try putObj(allocator, &result_object, "details", .{ .object = details });

    // resourceSummary: include all actuals as limit details.
    const summary = try buildResourceSummaryObject(allocator, invocation, 1, bytes_count, lines_count, 1);
    errdefer provider_json.freeValue(allocator, summary);
    try putObj(allocator, &result_object, "resourceSummary", summary);

    return .{ .object = result_object };
}

// =============================================================================
// Result builders.
// =============================================================================

const FailedResultOpts = struct {
    reason: []const u8,
    message: []const u8,
    details: ?std.json.Value, // borrowed; cloned in
    resource_summary: std.json.Value, // taken (we own it after this call)
};

fn buildFailedResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    now_fn: ?*const fn () i64,
    opts: FailedResultOpts,
) !std.json.Value {
    var result_object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = result_object });

    try copyCorrelationFields(allocator, &result_object, invocation);
    try putStr(allocator, &result_object, "type", "sub_agent_task_result");
    try putStr(allocator, &result_object, "status", "failed");
    const timestamp = nowMillis(now_fn);
    try putInt(allocator, &result_object, "startedAt", timestamp);
    try putInt(allocator, &result_object, "completedAt", timestamp);

    var details_obj = try buildAuditDetails(allocator, invocation, opts.reason, opts.message);
    errdefer provider_json.freeValue(allocator, details_obj);
    // Merge optional opts.details into details (opts.details fields win).
    if (opts.details) |extra| if (extra == .object) {
        var iterator = extra.object.iterator();
        while (iterator.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            const value_copy = try provider_json.cloneValue(allocator, entry.value_ptr.*);
            try details_obj.object.put(allocator, key_copy, value_copy);
        }
    };

    // error: { reason, message, details: <details_obj> }
    var error_obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = error_obj });
    try putStr(allocator, &error_obj, "reason", opts.reason);
    try putStr(allocator, &error_obj, "message", opts.message);
    // Clone details_obj for error.details (so result.details and
    // result.error.details are independent trees).
    const error_details_clone = try provider_json.cloneValue(allocator, details_obj);
    try error_obj.put(allocator, try allocator.dupe(u8, "details"), error_details_clone);
    try putObj(allocator, &result_object, "error", .{ .object = error_obj });

    // details: <details_obj> + { replayed: false }
    try details_obj.object.put(allocator, try allocator.dupe(u8, "replayed"), .{ .bool = false });
    try putObj(allocator, &result_object, "details", details_obj);

    try putObj(allocator, &result_object, "resourceSummary", opts.resource_summary);
    return .{ .object = result_object };
}

fn buildCancelledResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    now_fn: ?*const fn () i64,
    resource_summary: std.json.Value,
) !std.json.Value {
    var result_object = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = result_object });

    try copyCorrelationFields(allocator, &result_object, invocation);
    try putStr(allocator, &result_object, "type", "sub_agent_task_result");
    try putStr(allocator, &result_object, "status", "cancelled");
    const timestamp = nowMillis(now_fn);
    try putInt(allocator, &result_object, "startedAt", timestamp);
    try putInt(allocator, &result_object, "completedAt", timestamp);

    const cancellation_value = invocation.object.get("cancellation");
    const reason: []const u8 = blk: {
        if (cancellation_value) |cv| {
            if (cv == .object) if (cv.object.get("reason")) |r| {
                if (r == .string) break :blk r.string;
            };
        }
        break :blk "delegation cancelled";
    };

    var error_obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = error_obj });
    try putStr(allocator, &error_obj, "reason", "cancelled");
    try putStr(allocator, &error_obj, "message", reason);
    var error_details = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = error_details });
    if (cancellation_value) |cv| {
        try error_details.put(
            allocator,
            try allocator.dupe(u8, "cancellation"),
            try provider_json.cloneValue(allocator, cv),
        );
    }
    try putObj(allocator, &error_obj, "details", .{ .object = error_details });
    try putObj(allocator, &result_object, "error", .{ .object = error_obj });

    var details_obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = details_obj });
    try putStr(allocator, &details_obj, "capability", "agent.delegate");
    try putStr(allocator, &details_obj, "operation", "agent.delegate");
    if (cancellation_value) |cv| {
        try details_obj.put(
            allocator,
            try allocator.dupe(u8, "cancellation"),
            try provider_json.cloneValue(allocator, cv),
        );
    }
    try putObj(allocator, &result_object, "details", .{ .object = details_obj });

    try putObj(allocator, &result_object, "resourceSummary", resource_summary);
    return .{ .object = result_object };
}

fn buildResourceLimitResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    now_fn: ?*const fn () i64,
    err: ResourceLimitError,
    resource_summary: std.json.Value, // we own it
    extra_details_kv: ?std.json.Value, // optional object whose fields merge in
) !std.json.Value {
    const limit_name = limitFromError(err);
    const message = try std.fmt.allocPrint(allocator, "resource limit exceeded: {s}", .{limit_name.asString()});
    defer allocator.free(message);

    var summary = resource_summary;
    // Append/overwrite the specific limit's detail entry inside summary.limitDetails.
    if (summary == .object) {
        if (summary.object.getPtr("limitDetails")) |details_ptr| {
            if (details_ptr.* == .object) {
                try mergeLimitFailureDetail(allocator, &details_ptr.object, limit_name, invocation, message);
            }
        } else {
            var details = try provider_json.initObject(allocator);
            errdefer provider_json.freeValue(allocator, .{ .object = details });
            try mergeLimitFailureDetail(allocator, &details, limit_name, invocation, message);
            try summary.object.put(allocator, try allocator.dupe(u8, "limitDetails"), .{ .object = details });
        }
    }

    var details_obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = details_obj });
    try putStr(allocator, &details_obj, "limit", limit_name.asString());
    if (extra_details_kv) |extras| if (extras == .object) {
        var iter = extras.object.iterator();
        while (iter.next()) |entry| {
            try details_obj.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try provider_json.cloneValue(allocator, entry.value_ptr.*),
            );
        }
    };

    return try buildFailedResult(allocator, invocation, now_fn, .{
        .reason = "resource_limit_exceeded",
        .message = message,
        .details = .{ .object = details_obj.* },
        .resource_summary = summary,
    });
}

fn buildAbortResult(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    options: ExecutionOptions,
    runtime: *RuntimeAccounting,
) !std.json.Value {
    const deadline_exceeded = if (options.deadline_ns) |d| std.time.nanoTimestamp() >= d else false;
    if (deadline_exceeded) {
        const summary = try summaryFromRuntime(allocator, invocation, runtime.*);
        return try buildResourceLimitResult(
            allocator,
            invocation,
            options.now_fn,
            error.ResourceLimitTimeout,
            summary,
            null,
        );
    }
    const propagated = try propagateCancellation(allocator, invocation, options.abort_reason);
    defer provider_json.freeValue(allocator, propagated);
    const summary = try summaryFromRuntime(allocator, invocation, runtime.*);
    return try buildCancelledResult(allocator, propagated, options.now_fn, summary);
}

// =============================================================================
// enforceRuntimeBoundaries: post-success limit checks + output truncation.
// =============================================================================

fn enforceRuntimeBoundaries(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    result: std.json.Value,
    runtime: *RuntimeAccounting,
    now_fn: ?*const fn () i64,
) !std.json.Value {
    // Build merged summary first.
    var summary_object = try buildMergedSummary(allocator, invocation, result, runtime.*);
    errdefer provider_json.freeValue(allocator, .{ .object = summary_object });

    if (runtime.denied_tool) |denied| {
        provider_json.freeValue(allocator, result);
        // Build extras { tool: denied, toolScopes: invocation.limits.toolScopes }
        var extras = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = extras });
        try putStr(allocator, &extras, "tool", denied);
        if (readLimitArray(invocation, "toolScopes")) |scopes| {
            try extras.put(
                allocator,
                try allocator.dupe(u8, "toolScopes"),
                try provider_json.cloneValue(allocator, .{ .array = scopes.* }),
            );
        }
        return try buildResourceLimitResult(
            allocator,
            invocation,
            now_fn,
            error.ResourceLimitToolScopes,
            .{ .object = summary_object },
            .{ .object = extras.* },
        );
    }

    if (readLimitU64(invocation, "turns")) |turn_limit| {
        const turns_actual = readSummaryU64(.{ .object = summary_object }, "turns") orelse 0;
        if (turns_actual > turn_limit) {
            provider_json.freeValue(allocator, result);
            try setSummaryField(allocator, &summary_object, "turns", @intCast(turn_limit));
            return try buildResourceLimitResult(
                allocator,
                invocation,
                now_fn,
                error.ResourceLimitTurns,
                .{ .object = summary_object },
                null,
            );
        }
    }
    if (readLimitU64(invocation, "maxChildren")) |child_limit| {
        const children_actual = readSummaryU64(.{ .object = summary_object }, "childrenStarted") orelse 0;
        if (children_actual > child_limit) {
            provider_json.freeValue(allocator, result);
            try setSummaryField(allocator, &summary_object, "childrenStarted", @intCast(child_limit));
            return try buildResourceLimitResult(
                allocator,
                invocation,
                now_fn,
                error.ResourceLimitMaxChildren,
                .{ .object = summary_object },
                null,
            );
        }
    }

    // Output bounding.
    const bound_info = try boundOutput(allocator, result, invocation);
    var bounded_result = bound_info.new_result;
    errdefer provider_json.freeValue(allocator, bounded_result);

    try setSummaryField(allocator, &summary_object, "outputBytes", @intCast(bound_info.bounded_bytes));
    try setSummaryField(allocator, &summary_object, "outputLines", @intCast(bound_info.bounded_lines));
    if (readLimitU64(invocation, "outputBytes")) |out_limit| {
        try setLimitDetail(allocator, &summary_object, "outputBytes", out_limit, bound_info.actual_bytes, bound_info.truncated_bytes);
    }
    if (readLimitU64(invocation, "outputLines")) |out_limit| {
        try setLimitDetail(allocator, &summary_object, "outputLines", out_limit, bound_info.actual_lines, bound_info.truncated_lines);
    }

    // Splice updated summary into bounded_result.
    if (bounded_result == .object) {
        if (bounded_result.object.getPtr("resourceSummary")) |existing| {
            provider_json.freeValue(allocator, existing.*);
        }
        try bounded_result.object.put(
            allocator,
            try allocator.dupe(u8, "resourceSummary"),
            .{ .object = summary_object },
        );
    }
    return bounded_result;
}

const BoundedOutput = struct {
    new_result: std.json.Value,
    actual_bytes: u64,
    actual_lines: u64,
    bounded_bytes: u64,
    bounded_lines: u64,
    truncated_bytes: bool,
    truncated_lines: bool,
};

fn boundOutput(
    allocator: std.mem.Allocator,
    result: std.json.Value,
    invocation: std.json.Value,
) !BoundedOutput {
    // Extract text from result.content if it's an array containing one
    // text block (TS contract). Otherwise treat content as a JSON blob
    // and account for its serialized size without rewriting.
    const content_value = if (result == .object) result.object.get("content") else null;
    const single_text = extractSingleText(content_value);

    const actual_text: []const u8 = single_text orelse blk: {
        if (content_value) |cv| {
            const stringified = std.json.Stringify.valueAlloc(allocator, cv, .{}) catch break :blk "";
            // Free later; we only need the length and to compare bounded text.
            // But we can't free yet — return as owned and free below.
            break :blk stringified;
        }
        break :blk "";
    };
    const free_actual_text = single_text == null and actual_text.len > 0;
    defer if (free_actual_text) allocator.free(actual_text);

    const actual_bytes: u64 = actual_text.len;
    const actual_lines: u64 = countLines(actual_text);

    // Apply lines truncation first, then bytes.
    const lines_limit = readLimitU64(invocation, "outputLines");
    const lines_bounded = truncateLines(actual_text, lines_limit);
    defer if (lines_bounded.owned) allocator.free(lines_bounded.text);

    const bytes_limit = readLimitU64(invocation, "outputBytes");
    const bytes_bounded = truncateUtf8(lines_bounded.text, bytes_limit);
    defer if (bytes_bounded.owned) allocator.free(bytes_bounded.text);

    const bounded_text = bytes_bounded.text;
    const bounded_bytes: u64 = bounded_text.len;
    const bounded_lines: u64 = countLines(bounded_text);

    // Rebuild content if we had a single text block AND text changed.
    var new_result = result;
    if (single_text != null and !std.mem.eql(u8, actual_text, bounded_text)) {
        new_result = try replaceSingleText(allocator, result, bounded_text);
    }
    return .{
        .new_result = new_result,
        .actual_bytes = actual_bytes,
        .actual_lines = actual_lines,
        .bounded_bytes = bounded_bytes,
        .bounded_lines = bounded_lines,
        .truncated_bytes = bytes_bounded.truncated,
        .truncated_lines = lines_bounded.truncated,
    };
}

fn extractSingleText(content: ?std.json.Value) ?[]const u8 {
    const c = content orelse return null;
    if (c == .string) return c.string;
    if (c != .array) return null;
    var found: ?[]const u8 = null;
    var count: usize = 0;
    for (c.array.items) |block| {
        if (block != .object) continue;
        const text = block.object.get("text") orelse continue;
        if (text != .string) continue;
        if (count == 0) found = text.string;
        count += 1;
    }
    return if (count == 1) found else null;
}

fn replaceSingleText(allocator: std.mem.Allocator, result: std.json.Value, new_text: []const u8) !std.json.Value {
    var cloned = try provider_json.cloneValue(allocator, result);
    errdefer provider_json.freeValue(allocator, cloned);
    if (cloned != .object) return cloned;
    const content_ptr = cloned.object.getPtr("content") orelse return cloned;
    if (content_ptr.* == .string) {
        allocator.free(content_ptr.string);
        content_ptr.* = .{ .string = try allocator.dupe(u8, new_text) };
        return cloned;
    }
    if (content_ptr.* != .array) return cloned;
    for (content_ptr.array.items) |*block| {
        if (block.* != .object) continue;
        const text_ptr = block.object.getPtr("text") orelse continue;
        if (text_ptr.* != .string) continue;
        allocator.free(text_ptr.string);
        text_ptr.* = .{ .string = try allocator.dupe(u8, new_text) };
        return cloned;
    }
    return cloned;
}

const TruncationResult = struct { text: []const u8, owned: bool, truncated: bool };

fn truncateLines(text: []const u8, limit: ?u64) TruncationResult {
    if (limit == null) return .{ .text = text, .owned = false, .truncated = false };
    const max_lines = limit.?;
    if (max_lines == 0) {
        return .{ .text = "", .owned = false, .truncated = text.len > 0 };
    }
    if (countLines(text) <= max_lines) return .{ .text = text, .owned = false, .truncated = false };
    // Find the offset after `max_lines` lines.
    var seen: u64 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\n') {
            seen += 1;
            if (seen == max_lines) {
                return .{ .text = text[0..i], .owned = false, .truncated = true };
            }
        } else if (ch == '\r') {
            // Treat \r\n and \r as one line terminator.
            seen += 1;
            if (seen == max_lines) {
                return .{ .text = text[0..i], .owned = false, .truncated = true };
            }
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        }
    }
    return .{ .text = text, .owned = false, .truncated = false };
}

fn truncateUtf8(text: []const u8, limit: ?u64) TruncationResult {
    if (limit == null or text.len <= limit.?) return .{ .text = text, .owned = false, .truncated = false };
    // Truncate at UTF-8 codepoint boundary <= limit.
    var end: usize = @intCast(limit.?);
    if (end > text.len) end = text.len;
    while (end > 0 and (text[end] & 0xC0) == 0x80) : (end -= 1) {}
    return .{ .text = text[0..end], .owned = false, .truncated = true };
}

fn countLines(text: []const u8) u64 {
    if (text.len == 0) return 0;
    var count: u64 = 1;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\n') {
            count += 1;
        } else if (ch == '\r') {
            count += 1;
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        }
    }
    // The TS `split(/\r\n|\r|\n/).length` returns N+1 for N separators;
    // we count separators as transitions, so add adjustment if last char
    // is NOT a line terminator (split's final empty piece).
    if (text.len > 0) {
        const last = text[text.len - 1];
        if (last != '\n' and last != '\r') {
            // We already counted N+1 above (initial 1 + each separator
            // adds 1), matching TS exactly.
            return count;
        }
        // If text ends in a separator, our count is N+1 but TS's split
        // would also return N+1 (the trailing empty piece). So same.
        return count;
    }
    return count;
}

// =============================================================================
// Summary / limitDetails helpers.
// =============================================================================

fn buildResourceSummaryObject(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    turns: u64,
    output_bytes: u64,
    output_lines: u64,
    children_started: u64,
) !std.json.Value {
    var summary = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = summary });
    try putInt(allocator, &summary, "turns", @intCast(turns));
    try putInt(allocator, &summary, "outputBytes", @intCast(output_bytes));
    try putInt(allocator, &summary, "outputLines", @intCast(output_lines));
    try putInt(allocator, &summary, "childrenStarted", @intCast(children_started));
    if (try buildLimitDetailsForActuals(allocator, invocation, turns, output_bytes, output_lines, children_started)) |details| {
        try putObj(allocator, &summary, "limitDetails", details);
    }
    return .{ .object = summary };
}

fn buildLimitDetailsForActuals(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    turns: u64,
    output_bytes: u64,
    output_lines: u64,
    children_started: u64,
) !?std.json.Value {
    const limits = readLimitsObject(invocation) orelse return null;
    var details = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = details });

    if (readObjectIntField(limits.*, "turns")) |limit| {
        try details.put(allocator, try allocator.dupe(u8, "turns"), try buildLimitDetail(allocator, limit, turns, turns > limit, "turns"));
    }
    if (readObjectIntField(limits.*, "outputBytes")) |limit| {
        try details.put(allocator, try allocator.dupe(u8, "outputBytes"), try buildLimitDetail(allocator, limit, output_bytes, output_bytes > limit, "outputBytes"));
    }
    if (readObjectIntField(limits.*, "outputLines")) |limit| {
        try details.put(allocator, try allocator.dupe(u8, "outputLines"), try buildLimitDetail(allocator, limit, output_lines, output_lines > limit, "outputLines"));
    }
    if (readObjectIntField(limits.*, "maxChildren")) |limit| {
        try details.put(allocator, try allocator.dupe(u8, "maxChildren"), try buildLimitDetail(allocator, limit, children_started, children_started > limit, "maxChildren"));
    }
    if (readObjectIntField(limits.*, "depth")) |limit| {
        try details.put(allocator, try allocator.dupe(u8, "depth"), try buildLimitDetail(allocator, limit, limit, false, "depth"));
    }
    if (readObjectIntField(limits.*, "timeoutMs")) |limit| {
        try details.put(allocator, try allocator.dupe(u8, "timeoutMs"), try buildLimitDetail(allocator, limit, limit, false, "timeoutMs"));
    }
    if (limits.*.object.get("toolScopes")) |scopes| if (scopes == .array) {
        try details.put(allocator, try allocator.dupe(u8, "toolScopes"), try provider_json.cloneValue(allocator, scopes));
    };
    return .{ .object = details };
}

fn buildLimitDetail(
    allocator: std.mem.Allocator,
    limit: u64,
    actual: u64,
    truncated: bool,
    field: []const u8,
) !std.json.Value {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putInt(allocator, &obj, "limit", @intCast(limit));
    try putInt(allocator, &obj, "actual", @intCast(actual));
    try obj.put(allocator, try allocator.dupe(u8, "truncated"), .{ .bool = truncated });
    if (truncated) {
        const reason = try std.fmt.allocPrint(allocator, "resource limit exceeded: {s}", .{field});
        try obj.put(allocator, try allocator.dupe(u8, "reason"), .{ .string = reason });
    }
    return .{ .object = obj };
}

fn buildMergedSummary(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    result: std.json.Value,
    runtime: RuntimeAccounting,
) !std.json.ObjectMap {
    const result_summary = if (result == .object) result.object.get("resourceSummary") else null;
    var turns: u64 = 0;
    var output_bytes: u64 = 0;
    var output_lines: u64 = 0;
    var children_started: u64 = runtime.children_started;
    if (result_summary) |s| if (s == .object) {
        if (readObjectIntField(s.object, "turns")) |v| turns = v;
        if (readObjectIntField(s.object, "outputBytes")) |v| output_bytes = v;
        if (readObjectIntField(s.object, "outputLines")) |v| output_lines = v;
        if (readObjectIntField(s.object, "childrenStarted")) |v| children_started = v;
    };
    if (runtime.turns > turns) turns = runtime.turns;

    var summary = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = summary });
    try putInt(allocator, &summary, "turns", @intCast(turns));
    try putInt(allocator, &summary, "outputBytes", @intCast(output_bytes));
    try putInt(allocator, &summary, "outputLines", @intCast(output_lines));
    try putInt(allocator, &summary, "childrenStarted", @intCast(children_started));
    if (try buildLimitDetailsForActuals(allocator, invocation, turns, output_bytes, output_lines, children_started)) |details| {
        // Then overlay any executor-supplied limitDetails on top.
        var merged = details.object;
        if (result_summary) |s| if (s == .object) if (s.object.get("limitDetails")) |existing| if (existing == .object) {
            var iter = existing.object.iterator();
            while (iter.next()) |entry| {
                if (merged.fetchOrderedRemove(entry.key_ptr.*)) |kv_const| {
                    allocator.free(kv_const.key);
                    provider_json.freeValue(allocator, kv_const.value);
                }
                try merged.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try provider_json.cloneValue(allocator, entry.value_ptr.*),
                );
            }
        };
        try summary.put(allocator, try allocator.dupe(u8, "limitDetails"), .{ .object = merged });
    }
    return summary;
}

fn zeroResourceSummary(allocator: std.mem.Allocator, invocation: std.json.Value) !std.json.Value {
    return buildResourceSummaryObject(allocator, invocation, 0, 0, 0, 0);
}

fn summaryFromRuntime(allocator: std.mem.Allocator, invocation: std.json.Value, runtime: RuntimeAccounting) !std.json.Value {
    return buildResourceSummaryObject(allocator, invocation, runtime.turns, 0, 0, runtime.children_started);
}

fn mergeLimitFailureDetail(
    allocator: std.mem.Allocator,
    details: *std.json.ObjectMap,
    limit_name: LimitName,
    invocation: std.json.Value,
    message: []const u8,
) !void {
    if (limit_name == .toolScopes) {
        if (readLimitArray(invocation, "toolScopes")) |scopes| {
            if (details.fetchOrderedRemove("toolScopes")) |kv_const| {
                allocator.free(kv_const.key);
                provider_json.freeValue(allocator, kv_const.value);
            }
            try details.put(
                allocator,
                try allocator.dupe(u8, "toolScopes"),
                try provider_json.cloneValue(allocator, .{ .array = scopes.* }),
            );
        }
        return;
    }
    const key_owned = try allocator.dupe(u8, limit_name.asString());
    errdefer allocator.free(key_owned);
    var entry_obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = entry_obj });
    const limit_val: u64 = readLimitU64(invocation, limit_name.asString()) orelse 0;
    try putInt(allocator, &entry_obj, "limit", @intCast(limit_val));
    try entry_obj.put(allocator, try allocator.dupe(u8, "truncated"), .{ .bool = true });
    try entry_obj.put(allocator, try allocator.dupe(u8, "reason"), .{ .string = try allocator.dupe(u8, message) });
    if (details.fetchOrderedRemove(limit_name.asString())) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try details.put(allocator, key_owned, .{ .object = entry_obj });
}

fn setSummaryField(
    allocator: std.mem.Allocator,
    summary: *std.json.ObjectMap,
    name: []const u8,
    value: i64,
) !void {
    if (summary.fetchOrderedRemove(name)) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try summary.put(allocator, try allocator.dupe(u8, name), .{ .integer = value });
}

fn setLimitDetail(
    allocator: std.mem.Allocator,
    summary: *std.json.ObjectMap,
    field: []const u8,
    limit: u64,
    actual: u64,
    truncated: bool,
) !void {
    var details_ptr = summary.getPtr("limitDetails");
    if (details_ptr == null) {
        const details = try provider_json.initObject(allocator);
        errdefer provider_json.freeValue(allocator, .{ .object = details });
        try summary.put(allocator, try allocator.dupe(u8, "limitDetails"), .{ .object = details });
        details_ptr = summary.getPtr("limitDetails");
    }
    if (details_ptr.?.* != .object) return;
    if (details_ptr.?.object.fetchOrderedRemove(field)) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try details_ptr.?.object.put(
        allocator,
        try allocator.dupe(u8, field),
        try buildLimitDetail(allocator, limit, actual, truncated, field),
    );
}

// =============================================================================
// Replay / cancellation helpers.
// =============================================================================

fn replayKeyMatches(invocation: std.json.Value, result: std.json.Value) bool {
    const inv_obj = if (invocation == .object) invocation.object else return false;
    const res_obj = if (result == .object) result.object else return false;
    return strEqOpt(inv_obj.get("agentId"), res_obj.get("agentId")) and
        strEqOpt(inv_obj.get("runId"), res_obj.get("runId")) and
        strEqOpt(inv_obj.get("taskId"), res_obj.get("taskId")) and
        strEqOpt(inv_obj.get("sessionId"), res_obj.get("sessionId"));
}

fn isCancellationRequested(invocation: std.json.Value) bool {
    const cancellation = if (invocation == .object) invocation.object.get("cancellation") orelse return false else return false;
    if (cancellation != .object) return false;
    const state = cancellation.object.get("state") orelse return false;
    if (state != .string) return false;
    return std.mem.eql(u8, state.string, "requested");
}

fn propagateCancellation(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    abort_reason: ?[]const u8,
) !std.json.Value {
    var clone = try provider_json.cloneValue(allocator, invocation);
    errdefer provider_json.freeValue(allocator, clone);
    if (clone != .object) return clone;

    var cancellation = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = cancellation });

    if (clone.object.get("cancellation")) |existing| if (existing == .object) {
        var iter = existing.object.iterator();
        while (iter.next()) |entry| {
            try cancellation.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try provider_json.cloneValue(allocator, entry.value_ptr.*),
            );
        }
    };

    // state = "propagated"
    if (cancellation.fetchOrderedRemove("state")) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try cancellation.put(allocator, try allocator.dupe(u8, "state"), .{ .string = try allocator.dupe(u8, "propagated") });

    // reason = existing.reason || abort_reason || "cancelled"
    if (!cancellation.contains("reason")) {
        const r = abort_reason orelse "cancelled";
        try cancellation.put(allocator, try allocator.dupe(u8, "reason"), .{ .string = try allocator.dupe(u8, r) });
    }

    // propagatedFrom = existing.propagatedFrom || invocation.parentRunId || invocation.runId
    if (!cancellation.contains("propagatedFrom")) {
        const fallback: []const u8 = blk: {
            if (clone.object.get("parentRunId")) |v| if (v == .string) break :blk v.string;
            if (clone.object.get("runId")) |v| if (v == .string) break :blk v.string;
            break :blk "";
        };
        if (fallback.len > 0) {
            try cancellation.put(
                allocator,
                try allocator.dupe(u8, "propagatedFrom"),
                .{ .string = try allocator.dupe(u8, fallback) },
            );
        }
    }

    if (clone.object.fetchOrderedRemove("cancellation")) |kv_const| {
        allocator.free(kv_const.key);
        provider_json.freeValue(allocator, kv_const.value);
    }
    try clone.object.put(allocator, try allocator.dupe(u8, "cancellation"), .{ .object = cancellation });
    return clone;
}

// =============================================================================
// Audit details / correlation copying.
// =============================================================================

fn buildAuditDetails(
    allocator: std.mem.Allocator,
    invocation: std.json.Value,
    category: []const u8,
    reason: []const u8,
) !std.json.Value {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStr(allocator, &obj, "category", category);
    try putStr(allocator, &obj, "capability", "agent.delegate");
    try putStr(allocator, &obj, "operation", "agent.delegate");
    try putStr(allocator, &obj, "branch", "agent.delegate");
    try putStr(allocator, &obj, "phase", "call");
    try putStr(allocator, &obj, "mode", "zig/sub-agent-execution");
    try putStr(allocator, &obj, "reason", reason);
    var target = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = target });
    try putStr(allocator, &target, "id", "sub_agent.delegate");
    try putObj(allocator, &obj, "target", .{ .object = target });

    // Merge invocation.metadata.policyDiagnostics if present.
    if (invocation == .object) if (invocation.object.get("metadata")) |meta| if (meta == .object) {
        if (meta.object.get("policyDiagnostics")) |pd| if (pd == .object) {
            var iter = pd.object.iterator();
            while (iter.next()) |entry| {
                try obj.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try provider_json.cloneValue(allocator, entry.value_ptr.*),
                );
            }
        };
    };
    return .{ .object = obj };
}

fn copyCorrelationFields(
    allocator: std.mem.Allocator,
    dst: *std.json.ObjectMap,
    invocation: std.json.Value,
) !void {
    if (invocation != .object) return;
    const fields = [_][]const u8{
        "agentId",         "runId",         "taskId",      "sessionId",
        "toolCallId",      "parentAgentId", "parentRunId", "parentTaskId",
        "parentSessionId", "parentId",
    };
    for (fields) |field| {
        if (invocation.object.get(field)) |value| {
            if (dst.fetchOrderedRemove(field)) |kv_const| {
                allocator.free(kv_const.key);
                provider_json.freeValue(allocator, kv_const.value);
            }
            try dst.put(
                allocator,
                try allocator.dupe(u8, field),
                try provider_json.cloneValue(allocator, value),
            );
        }
    }
}

// =============================================================================
// Admission-time limit exhaustion (mirrors TS exhaustedAdmissionLimit).
// =============================================================================

fn exhaustedAdmissionLimit(invocation: std.json.Value) ?ResourceLimitError {
    const limits = readLimitsObject(invocation) orelse return null;
    if (readObjectIntField(limits.*, "maxChildren")) |limit| if (limit < 1) return error.ResourceLimitMaxChildren;
    if (readObjectIntField(limits.*, "depth")) |limit| if (limit < 1) return error.ResourceLimitDepth;
    if (readObjectIntField(limits.*, "turns")) |limit| if (limit < 1) return error.ResourceLimitTurns;
    if (readObjectIntField(limits.*, "timeoutMs")) |limit| if (limit < 1) return error.ResourceLimitTimeout;
    return null;
}

// =============================================================================
// Small accessors / put-helpers.
// =============================================================================

fn putStr(allocator: std.mem.Allocator, dst: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try dst.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putInt(allocator: std.mem.Allocator, dst: *std.json.ObjectMap, key: []const u8, value: i64) !void {
    try dst.put(allocator, try allocator.dupe(u8, key), .{ .integer = value });
}

fn putObj(allocator: std.mem.Allocator, dst: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try dst.put(allocator, try allocator.dupe(u8, key), value);
}

fn readLimitsObject(invocation: std.json.Value) ?*const std.json.ObjectMap {
    if (invocation != .object) return null;
    const limits = invocation.object.getPtr("limits") orelse return null;
    if (limits.* != .object) return null;
    return &limits.object;
}

fn readLimitU64(invocation: std.json.Value, name: []const u8) ?u64 {
    const limits = readLimitsObject(invocation) orelse return null;
    return readObjectIntField(limits.*, name);
}

fn readLimitArray(invocation: std.json.Value, name: []const u8) ?*const std.json.Array {
    const limits = readLimitsObject(invocation) orelse return null;
    const value_ptr = limits.*.getPtr(name) orelse return null;
    if (value_ptr.* != .array) return null;
    return &value_ptr.array;
}

fn readObjectIntField(map: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = map.get(name) orelse return null;
    return switch (value) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn readSummaryU64(summary: std.json.Value, name: []const u8) ?u64 {
    if (summary != .object) return null;
    return readObjectIntField(summary.object, name);
}

fn readOptionalString(invocation: std.json.Value, name: []const u8) ?[]const u8 {
    if (invocation != .object) return null;
    const v = invocation.object.get(name) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn strEqOpt(a: ?std.json.Value, b: ?std.json.Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    if (a.? != .string or b.? != .string) return false;
    return std.mem.eql(u8, a.?.string, b.?.string);
}

fn nowMillis(now_fn: ?*const fn () i64) i64 {
    if (now_fn) |f| return f();
    return std.time.milliTimestamp();
}

fn toolScopesDenies(invocation: std.json.Value, name: []const u8) bool {
    const scopes = readLimitArray(invocation, "toolScopes") orelse return false;
    for (scopes.items) |item| {
        if (item != .string) continue;
        if (std.mem.eql(u8, item.string, name)) return false;
    }
    return true;
}

fn buildToolDenialDetails(allocator: std.mem.Allocator, name: []const u8, invocation: std.json.Value) !std.json.Value {
    var obj = try provider_json.initObject(allocator);
    errdefer provider_json.freeValue(allocator, .{ .object = obj });
    try putStr(allocator, &obj, "tool", name);
    if (readLimitArray(invocation, "toolScopes")) |scopes| {
        try obj.put(
            allocator,
            try allocator.dupe(u8, "toolScopes"),
            try provider_json.cloneValue(allocator, .{ .array = scopes.* }),
        );
    }
    return .{ .object = obj };
}

// =============================================================================
// Tests.
// =============================================================================

const testing = std.testing;

fn parseInvocation(allocator: std.mem.Allocator, comptime body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

test "executor returns delegated text envelope for the default executor" {
    const allocator = testing.allocator;
    var parsed = try parseInvocation(allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "agent-1",
        \\  "runId": "run-1",
        \\  "taskId": "task-1",
        \\  "sessionId": "session-1",
        \\  "input": { "prompt": "hi" }
        \\}
    );
    defer parsed.deinit();
    var result = try executeBoundedSubAgentTask(allocator, parsed.value, .{});
    defer provider_json.freeValue(allocator, result);
    try testing.expect(result == .object);
    try testing.expectEqualStrings("completed", result.object.get("status").?.string);
    const content = result.object.get("content").?.array;
    try testing.expectEqual(@as(usize, 1), content.items.len);
    try testing.expectEqualStrings("text", content.items[0].object.get("type").?.string);
    const text = content.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "delegated:default:") != null);
    try testing.expectEqualStrings("sub_agent_task_result", result.object.get("type").?.string);
}

test "executor honors admission denial" {
    const allocator = testing.allocator;
    var parsed = try parseInvocation(allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "a", "runId": "r", "taskId": "t", "sessionId": "s",
        \\  "input": {}
        \\}
    );
    defer parsed.deinit();

    const Denier = struct {
        fn deny(_: ?*anyopaque, _: std.mem.Allocator, _: std.json.Value) anyerror!?AdmissionDenial {
            return AdmissionDenial{ .reason = "blocked", .message = "policy says no" };
        }
    };

    var result = try executeBoundedSubAgentTask(allocator, parsed.value, .{
        .admission = Denier.deny,
    });
    defer provider_json.freeValue(allocator, result);
    try testing.expectEqualStrings("failed", result.object.get("status").?.string);
    const err = result.object.get("error").?.object;
    try testing.expectEqualStrings("blocked", err.get("reason").?.string);
    try testing.expectEqualStrings("policy says no", err.get("message").?.string);
}

test "executor flips status to cancelled when cancellation.state == requested" {
    const allocator = testing.allocator;
    var parsed = try parseInvocation(allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "a", "runId": "r", "taskId": "t", "sessionId": "s",
        \\  "input": {},
        \\  "cancellation": { "state": "requested", "reason": "user-abort" }
        \\}
    );
    defer parsed.deinit();
    var result = try executeBoundedSubAgentTask(allocator, parsed.value, .{});
    defer provider_json.freeValue(allocator, result);
    try testing.expectEqualStrings("cancelled", result.object.get("status").?.string);
    const err = result.object.get("error").?.object;
    try testing.expectEqualStrings("cancelled", err.get("reason").?.string);
    try testing.expectEqualStrings("user-abort", err.get("message").?.string);
}

test "executor surfaces admission-time limit exhaustion" {
    const allocator = testing.allocator;
    var parsed = try parseInvocation(allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "a", "runId": "r", "taskId": "t", "sessionId": "s",
        \\  "input": {},
        \\  "limits": { "turns": 0 }
        \\}
    );
    defer parsed.deinit();
    var result = try executeBoundedSubAgentTask(allocator, parsed.value, .{});
    defer provider_json.freeValue(allocator, result);
    try testing.expectEqualStrings("failed", result.object.get("status").?.string);
    const err = result.object.get("error").?.object;
    try testing.expectEqualStrings("resource_limit_exceeded", err.get("reason").?.string);
    try testing.expectEqualStrings("resource limit exceeded: turns", err.get("message").?.string);
}

test "boundOutput truncates over-byte text" {
    const allocator = testing.allocator;
    var parsed = try parseInvocation(allocator,
        \\{
        \\  "type": "sub_agent_task_invocation",
        \\  "agentId": "a", "runId": "r", "taskId": "t", "sessionId": "s",
        \\  "input": { "prompt": "hi" },
        \\  "limits": { "outputBytes": 12 }
        \\}
    );
    defer parsed.deinit();
    var result = try executeBoundedSubAgentTask(allocator, parsed.value, .{});
    defer provider_json.freeValue(allocator, result);
    const content = result.object.get("content").?.array;
    const text = content.items[0].object.get("text").?.string;
    try testing.expect(text.len <= 12);
    const limits = result.object.get("resourceSummary").?.object.get("limitDetails").?.object.get("outputBytes").?.object;
    try testing.expectEqual(true, limits.get("truncated").?.bool);
}

test "countLines matches TS split semantics" {
    try testing.expectEqual(@as(u64, 0), countLines(""));
    try testing.expectEqual(@as(u64, 1), countLines("hello"));
    try testing.expectEqual(@as(u64, 2), countLines("a\nb"));
    try testing.expectEqual(@as(u64, 3), countLines("a\nb\nc"));
    try testing.expectEqual(@as(u64, 3), countLines("a\r\nb\r\nc"));
    try testing.expectEqual(@as(u64, 3), countLines("a\rb\rc"));
}

test "isCancellationRequested detects the requested state only" {
    const allocator = testing.allocator;
    {
        var parsed = try parseInvocation(allocator, "{\"cancellation\":{\"state\":\"requested\"}}");
        defer parsed.deinit();
        try testing.expect(isCancellationRequested(parsed.value));
    }
    {
        var parsed = try parseInvocation(allocator, "{\"cancellation\":{\"state\":\"pending\"}}");
        defer parsed.deinit();
        try testing.expect(!isCancellationRequested(parsed.value));
    }
    {
        var parsed = try parseInvocation(allocator, "{}");
        defer parsed.deinit();
        try testing.expect(!isCancellationRequested(parsed.value));
    }
}
