const std = @import("std");

/// Lifecycle phases for extension loading and operation.
pub const LifecyclePhase = enum {
    discover,
    validate,
    load,
    initialize,
    call,
    unload,

    pub fn jsonName(self: LifecyclePhase) []const u8 {
        // All LifecyclePhase tag names are valid JSON names verbatim.
        return @tagName(self);
    }
};

/// Capability identifiers for extension sandbox enforcement.
/// These are default-deny; requested capabilities remain denied until
/// an explicit approval record grants that exact capability.
pub const Capability = enum {
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

    pub fn jsonName(self: Capability) []const u8 {
        return capabilitySpec(self).json_name;
    }

    pub fn enforcementBranch(self: Capability) CapabilityEnforcementBranch {
        return capabilitySpec(self).branch;
    }
};

pub const CapabilityEnforcementBranch = enum {
    filesystem_read,
    filesystem_write,
    network_request,
    shell_process,
    environment_variable,
    model_call,
    session_read,
    session_write,
    ui_notification,
    tool_execution,
    agent_spawn,
    agent_delegate,

    pub fn jsonName(self: CapabilityEnforcementBranch) []const u8 {
        // Every CapabilityEnforcementBranch tag is `<area>_<verb>` and
        // maps to JSON `<area>.<verb>`. Build the dotted form at
        // comptime per variant — saves a hand-written switch table.
        return switch (self) {
            inline else => |tag| comptime underscoreToDot(@tagName(tag)),
        };
    }
};

fn underscoreToDot(comptime name: []const u8) []const u8 {
    comptime {
        var arr: [name.len]u8 = undefined;
        for (name, 0..) |c, i| arr[i] = if (c == '_') '.' else c;
        const result = arr;
        return &result;
    }
}

const CapabilitySpec = struct {
    capability: Capability,
    json_name: []const u8,
    branch: CapabilityEnforcementBranch,
};

const CAPABILITY_SPECS = [_]CapabilitySpec{
    .{ .capability = .file_read, .json_name = "file.read", .branch = .filesystem_read },
    .{ .capability = .file_write, .json_name = "file.write", .branch = .filesystem_write },
    .{ .capability = .network_request, .json_name = "network.request", .branch = .network_request },
    .{ .capability = .shell_run, .json_name = "shell.run", .branch = .shell_process },
    .{ .capability = .env_read, .json_name = "env.read", .branch = .environment_variable },
    .{ .capability = .model_call, .json_name = "model.call", .branch = .model_call },
    .{ .capability = .session_read, .json_name = "session.read", .branch = .session_read },
    .{ .capability = .session_write, .json_name = "session.write", .branch = .session_write },
    .{ .capability = .ui_notify, .json_name = "ui.notify", .branch = .ui_notification },
    .{ .capability = .tool_use, .json_name = "tool.use", .branch = .tool_execution },
    .{ .capability = .agent_spawn, .json_name = "agent.spawn", .branch = .agent_spawn },
    .{ .capability = .agent_delegate, .json_name = "agent.delegate", .branch = .agent_delegate },
};

comptime {
    validateCapabilitySpecs();
}

pub const CANONICAL_CAPABILITIES = blk: {
    var capabilities: [CAPABILITY_SPECS.len]Capability = undefined;
    for (CAPABILITY_SPECS, 0..) |spec, index| {
        capabilities[index] = spec.capability;
    }
    break :blk capabilities;
};

const CAPABILITY_BY_JSON_NAME = blk: {
    var entries: [CAPABILITY_SPECS.len]struct { []const u8, Capability } = undefined;
    for (CAPABILITY_SPECS, 0..) |spec, index| {
        entries[index] = .{ spec.json_name, spec.capability };
    }
    break :blk std.StaticStringMap(Capability).initComptime(entries);
};

fn validateCapabilitySpecs() void {
    const fields = @typeInfo(Capability).@"enum".fields;
    if (CAPABILITY_SPECS.len != fields.len) {
        @compileError("CAPABILITY_SPECS must cover every Capability enum field exactly once");
    }

    inline for (fields) |field| {
        const capability: Capability = @enumFromInt(field.value);
        comptime var count = 0;
        inline for (CAPABILITY_SPECS) |spec| {
            if (spec.capability == capability) count += 1;
        }
        if (count == 0) {
            @compileError("missing capability spec for " ++ field.name);
        }
        if (count > 1) {
            @compileError("duplicate capability spec for " ++ field.name);
        }
    }

    inline for (CAPABILITY_SPECS, 0..) |left, left_index| {
        inline for (CAPABILITY_SPECS[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left.json_name, right.json_name)) {
                @compileError("duplicate capability json name: " ++ left.json_name);
            }
        }
    }
}

fn capabilitySpec(capability: Capability) CapabilitySpec {
    inline for (CAPABILITY_SPECS) |spec| {
        if (spec.capability == capability) return spec;
    }
    unreachable;
}

pub const CapabilityDenialDiagnostic = struct {
    category: []const u8 = "denied_capability",
    capability: Capability,
    branch: CapabilityEnforcementBranch,
    phase: LifecyclePhase,
    mode: []const u8,

    pub fn capabilityId(self: CapabilityDenialDiagnostic) []const u8 {
        return self.capability.jsonName();
    }
};

pub fn denyFirstUnapprovedCapability(
    requested_capabilities: []const Capability,
    approved_capabilities: []const Capability,
    phase: LifecyclePhase,
    mode: []const u8,
) ?CapabilityDenialDiagnostic {
    for (requested_capabilities) |capability| {
        if (hasCapability(approved_capabilities, capability)) continue;
        return denyCapability(capability, phase, mode);
    }
    return null;
}

pub fn denyRuntimeCapability(
    capability: Capability,
    phase: LifecyclePhase,
    mode: []const u8,
) CapabilityDenialDiagnostic {
    return denyCapability(capability, phase, mode);
}

pub fn runtimeImportCapability(module_name: []const u8, field_name: []const u8) ?Capability {
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

pub fn denyRuntimeImport(
    module_name: []const u8,
    field_name: []const u8,
    phase: LifecyclePhase,
    mode: []const u8,
) ?CapabilityDenialDiagnostic {
    const capability = runtimeImportCapability(module_name, field_name) orelse return null;
    return denyRuntimeCapability(capability, phase, mode);
}

fn denyCapability(capability: Capability, phase: LifecyclePhase, mode: []const u8) CapabilityDenialDiagnostic {
    return .{
        .capability = capability,
        .branch = capability.enforcementBranch(),
        .phase = phase,
        .mode = mode,
    };
}

fn hasCapability(capabilities: []const Capability, needle: Capability) bool {
    for (capabilities) |capability| {
        if (capability == needle) return true;
    }
    return false;
}

pub fn parseCapability(value: []const u8) ?Capability {
    return CAPABILITY_BY_JSON_NAME.get(value);
}

pub const ResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: [][]u8,

    pub fn initEmpty(allocator: std.mem.Allocator) !ResourceLimits {
        return .{ .tool_scopes = try allocator.alloc([]u8, 0) };
    }

    pub fn deinit(self: *ResourceLimits, allocator: std.mem.Allocator) void {
        for (self.tool_scopes) |scope| allocator.free(scope);
        allocator.free(self.tool_scopes);
        self.* = undefined;
    }
};

test "capability canonical ids map to explicit enforcement branches" {
    const expected = [_]struct {
        capability: Capability,
        id: []const u8,
        branch: CapabilityEnforcementBranch,
    }{
        .{ .capability = .file_read, .id = "file.read", .branch = .filesystem_read },
        .{ .capability = .file_write, .id = "file.write", .branch = .filesystem_write },
        .{ .capability = .network_request, .id = "network.request", .branch = .network_request },
        .{ .capability = .shell_run, .id = "shell.run", .branch = .shell_process },
        .{ .capability = .env_read, .id = "env.read", .branch = .environment_variable },
        .{ .capability = .model_call, .id = "model.call", .branch = .model_call },
        .{ .capability = .session_read, .id = "session.read", .branch = .session_read },
        .{ .capability = .session_write, .id = "session.write", .branch = .session_write },
        .{ .capability = .ui_notify, .id = "ui.notify", .branch = .ui_notification },
        .{ .capability = .tool_use, .id = "tool.use", .branch = .tool_execution },
        .{ .capability = .agent_spawn, .id = "agent.spawn", .branch = .agent_spawn },
        .{ .capability = .agent_delegate, .id = "agent.delegate", .branch = .agent_delegate },
    };

    try std.testing.expectEqual(CANONICAL_CAPABILITIES.len, expected.len);
    try std.testing.expectEqual(@typeInfo(Capability).@"enum".fields.len, expected.len);
    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry.id, entry.capability.jsonName());
        try std.testing.expectEqual(entry.capability, parseCapability(entry.id).?);
        try std.testing.expectEqual(entry.branch, entry.capability.enforcementBranch());
    }
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("filesystem"));
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("session"));
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("cap-wiki"));
}

test "capability canonical ids match TypeScript parity fixture" {
    const fixture_path = "../packages/coding-agent/test/fixtures/extension-security-grants.json";
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, fixture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const fixture_capabilities = parsed.value.array.items;
    try std.testing.expectEqual(CANONICAL_CAPABILITIES.len, fixture_capabilities.len);

    for (CANONICAL_CAPABILITIES, fixture_capabilities) |cap, fixture| {
        try std.testing.expect(fixture == .string);
        try std.testing.expectEqualStrings(cap.jsonName(), fixture.string);
    }
}

test "capability requested but unapproved declarations are denied deterministically" {
    for (CANONICAL_CAPABILITIES) |cap| {
        const diagnostic = denyFirstUnapprovedCapability(&.{cap}, &.{}, .initialize, "manifest-request").?;
        try std.testing.expectEqualStrings("denied_capability", diagnostic.category);
        try std.testing.expectEqual(cap, diagnostic.capability);
        try std.testing.expectEqual(cap.enforcementBranch(), diagnostic.branch);
        try std.testing.expectEqual(.initialize, diagnostic.phase);
        try std.testing.expectEqualStrings("manifest-request", diagnostic.mode);
    }

    try std.testing.expectEqual(
        @as(?CapabilityDenialDiagnostic, null),
        denyFirstUnapprovedCapability(&.{ .shell_run, .network_request }, &.{ .shell_run, .network_request }, .initialize, "manifest-request"),
    );
    try std.testing.expectEqual(
        Capability.shell_run,
        denyFirstUnapprovedCapability(&.{.shell_run}, &.{.network_request}, .initialize, "manifest-request").?.capability,
    );
}

test "capability runtime denials use same ids and category as manifest requests" {
    for (CANONICAL_CAPABILITIES) |cap| {
        const diagnostic = denyRuntimeCapability(cap, .call, "runtime/import");
        try std.testing.expectEqualStrings("denied_capability", diagnostic.category);
        try std.testing.expectEqualStrings(cap.jsonName(), diagnostic.capability.jsonName());
        try std.testing.expectEqual(cap.enforcementBranch(), diagnostic.branch);
        try std.testing.expectEqual(.call, diagnostic.phase);
        try std.testing.expectEqualStrings("runtime/import", diagnostic.mode);
    }
}

test "capability runtime import mappings share canonical denial vocabulary" {
    const expected = [_]struct {
        module_name: []const u8,
        field_name: []const u8,
        capability: Capability,
    }{
        .{ .module_name = "pi:filesystem", .field_name = "read", .capability = .file_read },
        .{ .module_name = "pi:filesystem", .field_name = "write", .capability = .file_write },
        .{ .module_name = "pi:network", .field_name = "fetch", .capability = .network_request },
        .{ .module_name = "pi:shell", .field_name = "run", .capability = .shell_run },
        .{ .module_name = "pi:environment", .field_name = "get", .capability = .env_read },
        .{ .module_name = "pi:model", .field_name = "call", .capability = .model_call },
        .{ .module_name = "pi:session", .field_name = "get", .capability = .session_read },
        .{ .module_name = "pi:session", .field_name = "set", .capability = .session_write },
        .{ .module_name = "pi:ui", .field_name = "notify", .capability = .ui_notify },
        .{ .module_name = "pi:tool", .field_name = "use", .capability = .tool_use },
        .{ .module_name = "pi:agent", .field_name = "spawn", .capability = .agent_spawn },
        .{ .module_name = "pi:agent", .field_name = "delegate", .capability = .agent_delegate },
    };

    for (expected) |entry| {
        const diagnostic = denyRuntimeImport(entry.module_name, entry.field_name, .load, "runtime/import").?;
        try std.testing.expectEqualStrings("denied_capability", diagnostic.category);
        try std.testing.expectEqual(entry.capability, diagnostic.capability);
        try std.testing.expectEqualStrings(entry.capability.jsonName(), diagnostic.capabilityId());
        try std.testing.expectEqual(entry.capability.enforcementBranch(), diagnostic.branch);
        try std.testing.expectEqual(.load, diagnostic.phase);
        try std.testing.expectEqualStrings("runtime/import", diagnostic.mode);
    }
    try std.testing.expectEqual(@as(?CapabilityDenialDiagnostic, null), denyRuntimeImport("pi:unknown", "call", .load, "runtime/import"));
}
