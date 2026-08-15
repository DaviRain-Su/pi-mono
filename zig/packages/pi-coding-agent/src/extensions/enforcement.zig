const std = @import("std");
const capability = @import("capability.zig");

pub const Grant = capability.Capability;
pub const Branch = capability.CapabilityEnforcementBranch;
pub const Phase = capability.LifecyclePhase;
pub const CANONICAL_GRANTS = capability.CANONICAL_CAPABILITIES;

pub const Principal = struct {
    runtime_kind: []const u8,
    extension_id: []const u8,
    policy_lookup_key: ?[]const u8 = null,
    package_root: ?[]const u8 = null,
    invocation_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const ResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: []const []const u8 = &.{},

    pub fn validate(self: ResourceLimits) !void {
        _ = self.max_children;
        _ = self.depth;
        _ = self.turns;
        _ = self.timeout_ms;
        _ = self.output_bytes;
        _ = self.output_lines;
        for (self.tool_scopes) |scope| {
            if (scope.len == 0) return error.InvalidResourceLimit;
        }
    }
};

pub const Policy = struct {
    approved_grants: []const Grant = &.{},
    resource_limits: ResourceLimits = .{},
};

pub const Operation = enum {
    file_read,
    file_write,
    network_request,
    shell_run,
    env_read,
    model_call,
    session_read,
    session_write,
    ui_notify,
    tool_use,
    agent_spawn,
    agent_delegate,

    pub fn jsonName(self: Operation) []const u8 {
        return switch (self) {
            .file_read => "file.read",
            .file_write => "file.write",
            .network_request => "network.request",
            .shell_run => "shell.run",
            .env_read => "env.read",
            .model_call => "model.call",
            .session_read => "session.read",
            .session_write => "session.write",
            .ui_notify => "ui.notify",
            .tool_use => "tool.use",
            .agent_spawn => "agent.spawn",
            .agent_delegate => "agent.delegate",
        };
    }

    pub fn requiredGrant(self: Operation) Grant {
        return switch (self) {
            .file_read => .file_read,
            .file_write => .file_write,
            .network_request => .network_request,
            .shell_run => .shell_run,
            .env_read => .env_read,
            .model_call => .model_call,
            .session_read => .session_read,
            .session_write => .session_write,
            .ui_notify => .ui_notify,
            .tool_use => .tool_use,
            .agent_spawn => .agent_spawn,
            .agent_delegate => .agent_delegate,
        };
    }

    pub fn branch(self: Operation) Branch {
        return self.requiredGrant().enforcementBranch();
    }
};

pub const OperationTarget = struct {
    id: ?[]const u8 = null,
};

pub const UsageDelta = struct {
    turns: u64 = 0,
    elapsed_ms: u64 = 0,
    output_bytes: u64 = 0,
    output_lines: u64 = 0,
    children_started: u64 = 0,
    depth: u64 = 0,
    replay_key: ?[]const u8 = null,
};

pub const Accounting = struct {
    allowed_operations: u64 = 0,
    denied_operations: u64 = 0,
    turns: u64 = 0,
    elapsed_ms: u64 = 0,
    output_bytes: u64 = 0,
    output_lines: u64 = 0,
    children_started: u64 = 0,
    max_depth_observed: u64 = 0,
    replay_keys_recorded: usize = 0,
    replay_key_hashes: [64]u64 = [_]u64{0} ** 64,

    pub fn applyAllowed(self: *Accounting, delta: UsageDelta) void {
        self.allowed_operations += 1;
        self.turns += delta.turns;
        self.elapsed_ms += delta.elapsed_ms;
        self.output_bytes += delta.output_bytes;
        self.output_lines += delta.output_lines;
        self.children_started += delta.children_started;
        self.max_depth_observed = @max(self.max_depth_observed, delta.depth);
        if (delta.replay_key) |replay_key| self.recordReplayKey(replay_key);
    }

    pub fn recordDenied(self: *Accounting) void {
        self.denied_operations += 1;
    }

    pub fn hasReplayKey(self: Accounting, replay_key: []const u8) bool {
        const hash = replayKeyHash(replay_key);
        for (self.replay_key_hashes[0..self.replay_keys_recorded]) |recorded_hash| {
            if (recorded_hash == hash) return true;
        }
        return false;
    }

    fn recordReplayKey(self: *Accounting, replay_key: []const u8) void {
        if (self.hasReplayKey(replay_key)) return;
        if (self.replay_keys_recorded >= self.replay_key_hashes.len) return;
        self.replay_key_hashes[self.replay_keys_recorded] = replayKeyHash(replay_key);
        self.replay_keys_recorded += 1;
    }
};

pub const AllowDecision = struct {
    capability: Grant,
    branch: Branch,
    phase: Phase,
    mode: []const u8,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    usage_delta: UsageDelta,
    replayed: bool = false,
};

pub const DenyDecision = struct {
    category: []const u8 = "denied_capability",
    capability: Grant,
    branch: Branch,
    phase: Phase,
    mode: []const u8,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    reason: []const u8,
    limit_name: ?[]const u8 = null,
    limit_value: ?u64 = null,
};

pub const Decision = union(enum) {
    allow: AllowDecision,
    deny: DenyDecision,
};

pub fn parseGrantId(value: []const u8) ?Grant {
    inline for (@typeInfo(Grant).@"enum".fields) |field| {
        const grant: Grant = @enumFromInt(field.value);
        if (std.mem.eql(u8, value, grant.jsonName())) return grant;
    }
    return null;
}

pub fn operationForRuntimeImport(module_name: []const u8, field_name: []const u8) ?Operation {
    if (std.mem.eql(u8, module_name, "pi:filesystem") and std.mem.eql(u8, field_name, "read")) return .file_read;
    if (std.mem.eql(u8, module_name, "pi:filesystem") and std.mem.eql(u8, field_name, "write")) return .file_write;
    if (std.mem.eql(u8, module_name, "pi:network") and std.mem.eql(u8, field_name, "fetch")) return .network_request;
    if (std.mem.eql(u8, module_name, "pi:shell") and std.mem.eql(u8, field_name, "run")) return .shell_run;
    if (std.mem.eql(u8, module_name, "pi:environment") and std.mem.eql(u8, field_name, "get")) return .env_read;
    if (std.mem.eql(u8, module_name, "pi:model") and std.mem.eql(u8, field_name, "call")) return .model_call;
    if (std.mem.eql(u8, module_name, "pi:session") and std.mem.eql(u8, field_name, "get")) return .session_read;
    if (std.mem.eql(u8, module_name, "pi:session") and std.mem.eql(u8, field_name, "set")) return .session_write;
    if (std.mem.eql(u8, module_name, "pi:ui") and std.mem.eql(u8, field_name, "notify")) return .ui_notify;
    if (std.mem.eql(u8, module_name, "pi:tool") and std.mem.eql(u8, field_name, "use")) return .tool_use;
    if (std.mem.eql(u8, module_name, "pi:agent") and std.mem.eql(u8, field_name, "spawn")) return .agent_spawn;
    if (std.mem.eql(u8, module_name, "pi:agent") and std.mem.eql(u8, field_name, "delegate")) return .agent_delegate;
    return null;
}

pub fn diagnosticTargetId(operation: Operation, target: OperationTarget) ?[]const u8 {
    const id = target.id orelse return null;
    if (isSensitiveOperationTarget(operation) or containsSensitiveMarker(id)) return "[redacted]";
    return id;
}

fn isSensitiveOperationTarget(operation: Operation) bool {
    return switch (operation) {
        .shell_run,
        .session_write,
        .ui_notify,
        .agent_spawn,
        .agent_delegate,
        => true,
        else => false,
    };
}

fn containsSensitiveMarker(value: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(value, "secret") != null or
        std.ascii.indexOfIgnoreCase(value, "token") != null or
        std.ascii.indexOfIgnoreCase(value, "key") != null or
        std.ascii.indexOfIgnoreCase(value, "password") != null or
        std.ascii.indexOfIgnoreCase(value, "credential") != null;
}

pub fn decide(
    principal: Principal,
    policy: Policy,
    operation: Operation,
    target: OperationTarget,
    phase: Phase,
    mode: []const u8,
    delta: UsageDelta,
    accounting: *Accounting,
) Decision {
    const grant = operation.requiredGrant();
    if (!hasGrant(policy.approved_grants, grant)) {
        return deny(accounting, principal, operation, target, phase, mode, "grant is not approved");
    }

    if (operation == .tool_use and policy.resource_limits.tool_scopes.len > 0) {
        const target_id = target.id orelse return denyResourceScope(accounting, principal, operation, target, phase, mode, "tool target is required when toolScopes are constrained");
        if (!containsString(policy.resource_limits.tool_scopes, target_id)) {
            return denyResourceScope(accounting, principal, operation, target, phase, mode, "tool target is outside toolScopes");
        }
    }

    if (delta.replay_key) |replay_key| {
        if (accounting.hasReplayKey(replay_key)) {
            return .{ .allow = .{
                .capability = grant,
                .branch = operation.branch(),
                .phase = phase,
                .mode = mode,
                .principal = principal,
                .operation = operation,
                .target = target,
                .usage_delta = delta,
                .replayed = true,
            } };
        }
    }

    if (limitExceeded(policy.resource_limits, accounting.*, delta)) |limit| {
        return denyLimitExceeded(accounting, principal, operation, target, phase, mode, limit);
    }

    accounting.applyAllowed(delta);
    return .{ .allow = .{
        .capability = grant,
        .branch = operation.branch(),
        .phase = phase,
        .mode = mode,
        .principal = principal,
        .operation = operation,
        .target = target,
        .usage_delta = delta,
    } };
}

fn deny(
    accounting: *Accounting,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    phase: Phase,
    mode: []const u8,
    reason: []const u8,
) Decision {
    accounting.recordDenied();
    return .{ .deny = .{
        .capability = operation.requiredGrant(),
        .branch = operation.branch(),
        .phase = phase,
        .mode = mode,
        .principal = principal,
        .operation = operation,
        .target = target,
        .reason = reason,
    } };
}

fn denyResourceScope(
    accounting: *Accounting,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    phase: Phase,
    mode: []const u8,
    reason: []const u8,
) Decision {
    accounting.recordDenied();
    return .{ .deny = .{
        .category = "resource_limit_exceeded",
        .capability = operation.requiredGrant(),
        .branch = operation.branch(),
        .phase = phase,
        .mode = mode,
        .principal = principal,
        .operation = operation,
        .target = target,
        .reason = reason,
        .limit_name = "toolScopes",
    } };
}

const LimitExceeded = struct {
    name: []const u8,
    configured_value: u64,
    reason: []const u8,
};

fn denyLimitExceeded(
    accounting: *Accounting,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    phase: Phase,
    mode: []const u8,
    limit: LimitExceeded,
) Decision {
    accounting.recordDenied();
    return .{ .deny = .{
        .category = "resource_limit_exceeded",
        .capability = operation.requiredGrant(),
        .branch = operation.branch(),
        .phase = phase,
        .mode = mode,
        .principal = principal,
        .operation = operation,
        .target = target,
        .reason = limit.reason,
        .limit_name = limit.name,
        .limit_value = limit.configured_value,
    } };
}

fn limitExceeded(limits: ResourceLimits, accounting: Accounting, delta: UsageDelta) ?LimitExceeded {
    if (limits.turns) |limit| {
        if (wouldExceed(accounting.turns, delta.turns, limit)) return .{ .name = "turns", .configured_value = limit, .reason = "resource limit exceeded: turns" };
    }
    if (limits.timeout_ms) |limit| {
        if (wouldExceed(accounting.elapsed_ms, delta.elapsed_ms, limit)) return .{ .name = "timeoutMs", .configured_value = limit, .reason = "resource limit exceeded: timeoutMs" };
    }
    if (limits.output_bytes) |limit| {
        if (wouldExceed(accounting.output_bytes, delta.output_bytes, limit)) return .{ .name = "outputBytes", .configured_value = limit, .reason = "resource limit exceeded: outputBytes" };
    }
    if (limits.output_lines) |limit| {
        if (wouldExceed(accounting.output_lines, delta.output_lines, limit)) return .{ .name = "outputLines", .configured_value = limit, .reason = "resource limit exceeded: outputLines" };
    }
    if (limits.max_children) |limit| {
        if (wouldExceed(accounting.children_started, delta.children_started, limit)) return .{ .name = "maxChildren", .configured_value = limit, .reason = "resource limit exceeded: maxChildren" };
    }
    if (limits.depth) |limit| {
        if (@max(accounting.max_depth_observed, delta.depth) > limit) return .{ .name = "depth", .configured_value = limit, .reason = "resource limit exceeded: depth" };
    }
    return null;
}

fn wouldExceed(current: u64, delta: u64, limit: u64) bool {
    if (current > limit) return true;
    return delta > limit - current;
}

fn replayKeyHash(replay_key: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0, replay_key);
    if (hash == 0) return 1;
    return hash;
}

fn hasGrant(grants: []const Grant, needle: Grant) bool {
    for (grants) |grant| {
        if (grant == needle) return true;
    }
    return false;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

const all_operations = [_]Operation{
    .file_read,
    .file_write,
    .network_request,
    .shell_run,
    .env_read,
    .model_call,
    .session_read,
    .session_write,
    .ui_notify,
    .tool_use,
    .agent_spawn,
    .agent_delegate,
};

const test_principal: Principal = .{
    .runtime_kind = "native",
    .extension_id = "com.pi.enforcement-fixture",
    .package_root = "native://enforcement-fixture",
    .invocation_id = "invocation-1",
    .session_id = "session-1",
};

test "enforcement canonical grants are security permissions only" {
    const expected = [_]struct {
        grant: Grant,
        id: []const u8,
        operation: Operation,
        branch: Branch,
    }{
        .{ .grant = .file_read, .id = "file.read", .operation = .file_read, .branch = .filesystem_read },
        .{ .grant = .file_write, .id = "file.write", .operation = .file_write, .branch = .filesystem_write },
        .{ .grant = .network_request, .id = "network.request", .operation = .network_request, .branch = .network_request },
        .{ .grant = .shell_run, .id = "shell.run", .operation = .shell_run, .branch = .shell_process },
        .{ .grant = .env_read, .id = "env.read", .operation = .env_read, .branch = .environment_variable },
        .{ .grant = .model_call, .id = "model.call", .operation = .model_call, .branch = .model_call },
        .{ .grant = .session_read, .id = "session.read", .operation = .session_read, .branch = .session_read },
        .{ .grant = .session_write, .id = "session.write", .operation = .session_write, .branch = .session_write },
        .{ .grant = .ui_notify, .id = "ui.notify", .operation = .ui_notify, .branch = .ui_notification },
        .{ .grant = .tool_use, .id = "tool.use", .operation = .tool_use, .branch = .tool_execution },
        .{ .grant = .agent_spawn, .id = "agent.spawn", .operation = .agent_spawn, .branch = .agent_spawn },
        .{ .grant = .agent_delegate, .id = "agent.delegate", .operation = .agent_delegate, .branch = .agent_delegate },
    };

    try std.testing.expectEqual(expected.len, CANONICAL_GRANTS.len);
    try std.testing.expectEqual(expected.len, @typeInfo(Grant).@"enum".fields.len);
    try std.testing.expectEqual(expected.len, @typeInfo(Operation).@"enum".fields.len);
    for (expected) |entry| {
        try std.testing.expectEqual(entry.grant, parseGrantId(entry.id).?);
        try std.testing.expectEqualStrings(entry.id, entry.grant.jsonName());
        try std.testing.expectEqual(entry.grant, entry.operation.requiredGrant());
        try std.testing.expectEqual(entry.branch, entry.operation.branch());
        try std.testing.expectEqual(entry.branch, entry.grant.enforcementBranch());
    }
    try std.testing.expectEqual(@as(?Grant, null), parseGrantId("tool"));
    try std.testing.expectEqual(@as(?Grant, null), parseGrantId("workflow.run"));
    try std.testing.expectEqual(@as(?Grant, null), parseGrantId("database.query"));
}

test "enforcement runtime imports map to exactly one operation branch" {
    const expected = [_]struct {
        module_name: []const u8,
        field_name: []const u8,
        operation: Operation,
    }{
        .{ .module_name = "pi:filesystem", .field_name = "read", .operation = .file_read },
        .{ .module_name = "pi:filesystem", .field_name = "write", .operation = .file_write },
        .{ .module_name = "pi:network", .field_name = "fetch", .operation = .network_request },
        .{ .module_name = "pi:shell", .field_name = "run", .operation = .shell_run },
        .{ .module_name = "pi:environment", .field_name = "get", .operation = .env_read },
        .{ .module_name = "pi:model", .field_name = "call", .operation = .model_call },
        .{ .module_name = "pi:session", .field_name = "get", .operation = .session_read },
        .{ .module_name = "pi:session", .field_name = "set", .operation = .session_write },
        .{ .module_name = "pi:ui", .field_name = "notify", .operation = .ui_notify },
        .{ .module_name = "pi:tool", .field_name = "use", .operation = .tool_use },
        .{ .module_name = "pi:agent", .field_name = "spawn", .operation = .agent_spawn },
        .{ .module_name = "pi:agent", .field_name = "delegate", .operation = .agent_delegate },
    };

    for (expected) |entry| {
        const operation = operationForRuntimeImport(entry.module_name, entry.field_name).?;
        try std.testing.expectEqual(entry.operation, operation);
        try std.testing.expectEqual(entry.operation.requiredGrant(), capability.runtimeImportCapability(entry.module_name, entry.field_name).?);
        try std.testing.expectEqual(entry.operation.requiredGrant().enforcementBranch(), operation.branch());
    }
    try std.testing.expectEqual(@as(?Operation, null), operationForRuntimeImport("pi:agent", "unknown"));
    try std.testing.expectEqual(@as(?Operation, null), operationForRuntimeImport("pi:unknown", "read"));
}

test "enforcement diagnostic target redaction protects secret-like runtime data" {
    try std.testing.expectEqualStrings(
        "[redacted]",
        diagnosticTargetId(.env_read, .{ .id = "OPENAI_API_KEY" }).?,
    );
    try std.testing.expectEqualStrings(
        "[redacted]",
        diagnosticTargetId(.shell_run, .{ .id = "echo harmless" }).?,
    );
    try std.testing.expectEqualStrings(
        "[redacted]",
        diagnosticTargetId(.agent_spawn, .{ .id = "{\"task\":\"contains user context\"}" }).?,
    );
    try std.testing.expectEqualStrings(
        "safe-model",
        diagnosticTargetId(.model_call, .{ .id = "safe-model" }).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), diagnosticTargetId(.file_read, .{}));
}

test "enforcement decisions deny unapproved grants before accounting" {
    var accounting = Accounting{};
    for (all_operations) |operation| {
        const before = accounting;
        const decision = decide(
            test_principal,
            .{ .approved_grants = &.{}, .resource_limits = .{ .turns = 1, .tool_scopes = &.{"safe.tool"} } },
            operation,
            .{ .id = "safe.tool" },
            .initialize,
            "runtime/import",
            .{ .turns = 1, .output_bytes = 10, .children_started = 1 },
            &accounting,
        );
        try std.testing.expect(decision == .deny);
        try std.testing.expectEqualStrings("denied_capability", decision.deny.category);
        try std.testing.expectEqual(operation.requiredGrant(), decision.deny.capability);
        try std.testing.expectEqual(operation.branch(), decision.deny.branch);
        try std.testing.expectEqual(.initialize, decision.deny.phase);
        try std.testing.expectEqualStrings("runtime/import", decision.deny.mode);
        try std.testing.expectEqual(operation, decision.deny.operation);
        try std.testing.expectEqual(@as(u64, before.denied_operations + 1), accounting.denied_operations);
        try std.testing.expectEqual(before.allowed_operations, accounting.allowed_operations);
        try std.testing.expectEqual(before.turns, accounting.turns);
        try std.testing.expectEqual(before.elapsed_ms, accounting.elapsed_ms);
        try std.testing.expectEqual(before.output_bytes, accounting.output_bytes);
        try std.testing.expectEqual(before.output_lines, accounting.output_lines);
        try std.testing.expectEqual(before.children_started, accounting.children_started);
        try std.testing.expectEqual(before.max_depth_observed, accounting.max_depth_observed);
    }
}

test "enforcement approved grant allows only its matching operation branch and records accounting" {
    for (all_operations) |approved_operation| {
        var accounting = Accounting{};
        for (all_operations) |requested_operation| {
            const before = accounting;
            const decision = decide(
                test_principal,
                .{ .approved_grants = &.{approved_operation.requiredGrant()} },
                requested_operation,
                .{ .id = "safe.tool" },
                .call,
                "policy/decision",
                .{ .turns = 2, .output_bytes = 7, .output_lines = 1 },
                &accounting,
            );
            if (requested_operation == approved_operation) {
                try std.testing.expect(decision == .allow);
                try std.testing.expectEqual(approved_operation.requiredGrant(), decision.allow.capability);
                try std.testing.expectEqual(approved_operation.branch(), decision.allow.branch);
                try std.testing.expectEqual(@as(u64, before.allowed_operations + 1), accounting.allowed_operations);
                try std.testing.expectEqual(@as(u64, before.turns + 2), accounting.turns);
                try std.testing.expectEqual(@as(u64, before.output_bytes + 7), accounting.output_bytes);
                try std.testing.expectEqual(@as(u64, before.output_lines + 1), accounting.output_lines);
            } else {
                try std.testing.expect(decision == .deny);
                try std.testing.expectEqual(requested_operation.requiredGrant(), decision.deny.capability);
                try std.testing.expectEqual(@as(u64, before.denied_operations + 1), accounting.denied_operations);
                try std.testing.expectEqual(before.allowed_operations, accounting.allowed_operations);
                try std.testing.expectEqual(before.turns, accounting.turns);
                try std.testing.expectEqual(before.elapsed_ms, accounting.elapsed_ms);
                try std.testing.expectEqual(before.output_bytes, accounting.output_bytes);
                try std.testing.expectEqual(before.output_lines, accounting.output_lines);
                try std.testing.expectEqual(before.children_started, accounting.children_started);
                try std.testing.expectEqual(before.max_depth_observed, accounting.max_depth_observed);
            }
        }
    }
}

test "enforcement resource limits constrain without granting and tool scopes narrow allowed tool use" {
    try (ResourceLimits{ .tool_scopes = &.{"safe.tool"} }).validate();
    try std.testing.expectError(error.InvalidResourceLimit, (ResourceLimits{ .tool_scopes = &.{""} }).validate());

    var denied_accounting = Accounting{};
    const no_grant = decide(
        test_principal,
        .{ .approved_grants = &.{}, .resource_limits = .{ .tool_scopes = &.{"safe.tool"} } },
        .tool_use,
        .{ .id = "safe.tool" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &denied_accounting,
    );
    try std.testing.expect(no_grant == .deny);
    try std.testing.expectEqual(Grant.tool_use, no_grant.deny.capability);
    try std.testing.expectEqual(@as(u64, 1), denied_accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.turns);

    var scoped_accounting = Accounting{};
    const out_of_scope = decide(
        test_principal,
        .{ .approved_grants = &.{.tool_use}, .resource_limits = .{ .tool_scopes = &.{"safe.tool"} } },
        .tool_use,
        .{ .id = "other.tool" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &scoped_accounting,
    );
    try std.testing.expect(out_of_scope == .deny);
    try std.testing.expectEqualStrings("resource_limit_exceeded", out_of_scope.deny.category);
    try std.testing.expectEqualStrings("tool target is outside toolScopes", out_of_scope.deny.reason);
    try std.testing.expectEqualStrings("toolScopes", out_of_scope.deny.limit_name.?);
    try std.testing.expectEqual(@as(u64, 1), scoped_accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 0), scoped_accounting.allowed_operations);

    const in_scope = decide(
        test_principal,
        .{ .approved_grants = &.{.tool_use}, .resource_limits = .{ .tool_scopes = &.{"safe.tool"} } },
        .tool_use,
        .{ .id = "safe.tool" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &scoped_accounting,
    );
    try std.testing.expect(in_scope == .allow);
    try std.testing.expectEqual(@as(u64, 1), scoped_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 1), scoped_accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 1), scoped_accounting.turns);
}

test "enforcement accounting is replay-safe for repeated operation id" {
    var accounting = Accounting{};
    const first = decide(
        test_principal,
        .{ .approved_grants = &.{.model_call}, .resource_limits = .{ .turns = 2, .output_bytes = 20 } },
        .model_call,
        .{ .id = "fake-model" },
        .call,
        "policy/decision",
        .{ .turns = 1, .output_bytes = 10, .replay_key = "model-call-1" },
        &accounting,
    );
    try std.testing.expect(first == .allow);
    try std.testing.expect(!first.allow.replayed);
    try std.testing.expectEqual(@as(u64, 1), accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 1), accounting.turns);
    try std.testing.expectEqual(@as(u64, 10), accounting.output_bytes);
    try std.testing.expectEqual(@as(usize, 1), accounting.replay_keys_recorded);

    const replay = decide(
        test_principal,
        .{ .approved_grants = &.{.model_call}, .resource_limits = .{ .turns = 2, .output_bytes = 20 } },
        .model_call,
        .{ .id = "fake-model" },
        .call,
        "policy/replay",
        .{ .turns = 1, .output_bytes = 10, .replay_key = "model-call-1" },
        &accounting,
    );
    try std.testing.expect(replay == .allow);
    try std.testing.expect(replay.allow.replayed);
    try std.testing.expectEqual(@as(u64, 1), accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 1), accounting.turns);
    try std.testing.expectEqual(@as(u64, 10), accounting.output_bytes);
    try std.testing.expectEqual(@as(usize, 1), accounting.replay_keys_recorded);
}

test "sub-agent spawn and delegation stay separate default-deny operations with replay-safe delegate accounting" {
    var denied_accounting = Accounting{};
    const denied_delegate = decide(
        test_principal,
        .{ .approved_grants = &.{}, .resource_limits = .{ .turns = 0, .max_children = 0 } },
        .agent_delegate,
        .{ .id = "sub-agent-task" },
        .call,
        "sub-agent/delegate",
        .{ .turns = 1, .output_bytes = 12, .output_lines = 1, .children_started = 1 },
        &denied_accounting,
    );
    try std.testing.expect(denied_delegate == .deny);
    try std.testing.expectEqual(Grant.agent_delegate, denied_delegate.deny.capability);
    try std.testing.expectEqualStrings("grant is not approved", denied_delegate.deny.reason);
    try std.testing.expectEqual(@as(u64, 1), denied_accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.turns);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.output_bytes);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.children_started);

    var spawn_only_accounting = Accounting{};
    const spawn_only_delegate = decide(
        test_principal,
        .{ .approved_grants = &.{.agent_spawn}, .resource_limits = .{ .turns = 1, .max_children = 1 } },
        .agent_delegate,
        .{ .id = "sub-agent-task" },
        .call,
        "sub-agent/delegate",
        .{ .turns = 1, .children_started = 1 },
        &spawn_only_accounting,
    );
    try std.testing.expect(spawn_only_delegate == .deny);
    try std.testing.expectEqual(Grant.agent_delegate, spawn_only_delegate.deny.capability);
    try std.testing.expectEqual(@as(u64, 0), spawn_only_accounting.children_started);

    var delegate_only_accounting = Accounting{};
    const delegate_only_spawn = decide(
        test_principal,
        .{ .approved_grants = &.{.agent_delegate}, .resource_limits = .{ .turns = 2, .max_children = 1 } },
        .agent_spawn,
        .{ .id = "sub-agent-task" },
        .call,
        "sub-agent/spawn",
        .{ .children_started = 1 },
        &delegate_only_accounting,
    );
    try std.testing.expect(delegate_only_spawn == .deny);
    try std.testing.expectEqual(Grant.agent_spawn, delegate_only_spawn.deny.capability);
    try std.testing.expectEqual(@as(u64, 0), delegate_only_accounting.children_started);

    const allowed_delegate = decide(
        test_principal,
        .{ .approved_grants = &.{.agent_delegate}, .resource_limits = .{ .turns = 2, .output_bytes = 24, .output_lines = 2 } },
        .agent_delegate,
        .{ .id = "sub-agent-task" },
        .call,
        "sub-agent/delegate",
        .{ .turns = 1, .output_bytes = 12, .output_lines = 1, .replay_key = "sub-agent-task/run-1" },
        &delegate_only_accounting,
    );
    try std.testing.expect(allowed_delegate == .allow);
    try std.testing.expect(!allowed_delegate.allow.replayed);
    try std.testing.expectEqual(@as(u64, 1), delegate_only_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 1), delegate_only_accounting.turns);
    try std.testing.expectEqual(@as(u64, 12), delegate_only_accounting.output_bytes);
    try std.testing.expectEqual(@as(u64, 1), delegate_only_accounting.output_lines);

    const replayed_delegate = decide(
        test_principal,
        .{ .approved_grants = &.{.agent_delegate}, .resource_limits = .{ .turns = 1, .output_bytes = 12, .output_lines = 1 } },
        .agent_delegate,
        .{ .id = "sub-agent-task" },
        .call,
        "sub-agent/replay",
        .{ .turns = 1, .output_bytes = 12, .output_lines = 1, .replay_key = "sub-agent-task/run-1" },
        &delegate_only_accounting,
    );
    try std.testing.expect(replayed_delegate == .allow);
    try std.testing.expect(replayed_delegate.allow.replayed);
    try std.testing.expectEqual(@as(u64, 1), delegate_only_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 1), delegate_only_accounting.turns);
    try std.testing.expectEqual(@as(u64, 12), delegate_only_accounting.output_bytes);
    try std.testing.expectEqual(@as(u64, 1), delegate_only_accounting.output_lines);
}

test "enforcement denied attempts record deterministic counter without usage accounting" {
    var accounting = Accounting{};
    const denied = decide(
        test_principal,
        .{ .approved_grants = &.{}, .resource_limits = .{ .turns = 0, .output_bytes = 0, .max_children = 0 } },
        .agent_spawn,
        .{ .id = "child-task" },
        .call,
        "policy/decision",
        .{ .turns = 1, .output_bytes = 10, .children_started = 1 },
        &accounting,
    );
    try std.testing.expect(denied == .deny);
    try std.testing.expectEqualStrings("grant is not approved", denied.deny.reason);
    try std.testing.expectEqual(@as(u64, 1), accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 0), accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 0), accounting.turns);
    try std.testing.expectEqual(@as(u64, 0), accounting.output_bytes);
    try std.testing.expectEqual(@as(u64, 0), accounting.children_started);
}

test "enforcement checks grants before numeric resource limits" {
    var accounting = Accounting{};
    const denied = decide(
        test_principal,
        .{ .approved_grants = &.{}, .resource_limits = .{ .turns = 0, .output_bytes = 0, .max_children = 0 } },
        .model_call,
        .{ .id = "fake-model" },
        .call,
        "policy/decision",
        .{ .turns = 1, .output_bytes = 1, .children_started = 1 },
        &accounting,
    );
    try std.testing.expect(denied == .deny);
    try std.testing.expectEqualStrings("grant is not approved", denied.deny.reason);
    try std.testing.expectEqual(@as(u64, 1), accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 0), accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 0), accounting.turns);
    try std.testing.expectEqual(@as(u64, 0), accounting.output_bytes);
    try std.testing.expectEqual(@as(u64, 0), accounting.children_started);
}

test "enforcement allows exact numeric limits and denies exceeded limits" {
    var accounting = Accounting{};
    const exact = decide(
        test_principal,
        .{ .approved_grants = &.{.model_call}, .resource_limits = .{ .turns = 2, .timeout_ms = 50, .output_bytes = 12, .output_lines = 3, .depth = 1 } },
        .model_call,
        .{ .id = "fake-model" },
        .call,
        "policy/decision",
        .{ .turns = 2, .elapsed_ms = 50, .output_bytes = 12, .output_lines = 3, .depth = 1 },
        &accounting,
    );
    try std.testing.expect(exact == .allow);
    try std.testing.expectEqual(@as(u64, 1), accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 2), accounting.turns);
    try std.testing.expectEqual(@as(u64, 50), accounting.elapsed_ms);
    try std.testing.expectEqual(@as(u64, 12), accounting.output_bytes);
    try std.testing.expectEqual(@as(u64, 3), accounting.output_lines);
    try std.testing.expectEqual(@as(u64, 1), accounting.max_depth_observed);

    const exceeded = decide(
        test_principal,
        .{ .approved_grants = &.{.model_call}, .resource_limits = .{ .turns = 2 } },
        .model_call,
        .{ .id = "fake-model" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &accounting,
    );
    try std.testing.expect(exceeded == .deny);
    try std.testing.expectEqualStrings("resource_limit_exceeded", exceeded.deny.category);
    try std.testing.expectEqualStrings("resource limit exceeded: turns", exceeded.deny.reason);
    try std.testing.expectEqualStrings("turns", exceeded.deny.limit_name.?);
    try std.testing.expectEqual(@as(u64, 2), exceeded.deny.limit_value.?);
    try std.testing.expectEqual(@as(u64, 1), accounting.denied_operations);
    try std.testing.expectEqual(@as(u64, 1), accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 2), accounting.turns);

    var child_accounting = Accounting{};
    const child_exact = decide(
        test_principal,
        .{ .approved_grants = &.{.agent_spawn}, .resource_limits = .{ .max_children = 2 } },
        .agent_spawn,
        .{ .id = "child-task" },
        .call,
        "policy/decision",
        .{ .children_started = 2 },
        &child_accounting,
    );
    try std.testing.expect(child_exact == .allow);
    const child_exceeded = decide(
        test_principal,
        .{ .approved_grants = &.{.agent_spawn}, .resource_limits = .{ .max_children = 2 } },
        .agent_spawn,
        .{ .id = "child-task" },
        .call,
        "policy/decision",
        .{ .children_started = 1 },
        &child_accounting,
    );
    try std.testing.expect(child_exceeded == .deny);
    try std.testing.expectEqualStrings("resource_limit_exceeded", child_exceeded.deny.category);
    try std.testing.expectEqualStrings("resource limit exceeded: maxChildren", child_exceeded.deny.reason);
    try std.testing.expectEqualStrings("maxChildren", child_exceeded.deny.limit_name.?);
    try std.testing.expectEqual(@as(u64, 2), child_exceeded.deny.limit_value.?);
    try std.testing.expectEqual(@as(u64, 2), child_accounting.children_started);

    const exceeded_cases = [_]struct {
        limits: ResourceLimits,
        delta: UsageDelta,
        reason: []const u8,
    }{
        .{
            .limits = .{ .timeout_ms = 10 },
            .delta = .{ .elapsed_ms = 11 },
            .reason = "resource limit exceeded: timeoutMs",
        },
        .{
            .limits = .{ .output_bytes = 10 },
            .delta = .{ .output_bytes = 11 },
            .reason = "resource limit exceeded: outputBytes",
        },
        .{
            .limits = .{ .output_lines = 2 },
            .delta = .{ .output_lines = 3 },
            .reason = "resource limit exceeded: outputLines",
        },
        .{
            .limits = .{ .depth = 1 },
            .delta = .{ .depth = 2 },
            .reason = "resource limit exceeded: depth",
        },
    };
    for (exceeded_cases) |case| {
        var case_accounting = Accounting{};
        const decision = decide(
            test_principal,
            .{ .approved_grants = &.{.model_call}, .resource_limits = case.limits },
            .model_call,
            .{ .id = "fake-model" },
            .call,
            "policy/decision",
            case.delta,
            &case_accounting,
        );
        try std.testing.expect(decision == .deny);
        try std.testing.expectEqualStrings("resource_limit_exceeded", decision.deny.category);
        try std.testing.expectEqualStrings(case.reason, decision.deny.reason);
        try std.testing.expect(decision.deny.limit_name != null);
        try std.testing.expect(decision.deny.limit_value != null);
        try std.testing.expectEqual(@as(u64, 1), case_accounting.denied_operations);
        try std.testing.expectEqual(@as(u64, 0), case_accounting.allowed_operations);
    }
}
