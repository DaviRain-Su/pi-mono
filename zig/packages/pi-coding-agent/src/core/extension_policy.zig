const std = @import("std");
const capability = @import("../extensions/capability.zig");

pub const CANONICAL_EXTENSION_GRANTS = capability.CANONICAL_CAPABILITIES;
pub const CanonicalExtensionGrant = capability.Capability;
pub const ExtensionPolicyRuntimeKind = enum { typescript, wasm, native, process_jsonl };

pub const ExtensionResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: []const []const u8 = &.{},
};

pub const ExtensionPolicy = struct {
    approved_grants: []const CanonicalExtensionGrant = &.{},
    resource_limits: ?ExtensionResourceLimits = null,

    pub fn deinit(self: *ExtensionPolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.approved_grants);
        if (self.resource_limits) |limits| allocator.free(limits.tool_scopes);
        self.* = undefined;
    }
};

pub const CanonicalExtensionIdentity = struct {
    key: []const u8,
    runtime_kind: ExtensionPolicyRuntimeKind,
    display_name: []const u8,
};

pub const ExtensionPolicyDenialDetails = struct {
    category: []const u8 = "denied_capability",
    capability: CanonicalExtensionGrant,
    operation: []const u8,
    phase: []const u8 = "call",
    runtime_kind: ExtensionPolicyRuntimeKind,
    extension_identity: []const u8,
};

pub const ExtensionPolicyDeniedError = error{ExtensionPolicyDenied};
pub const ExtensionPolicyValidationError = error{
    ExpectedObject,
    ExpectedArray,
    ExpectedString,
    EmptyIdentity,
    UnsupportedPolicyField,
    UnsupportedResourceLimit,
    UnknownGrant,
    ExpectedNonNegativeInteger,
    EmptyToolScope,
};

pub fn isCanonicalExtensionGrant(value: []const u8) bool {
    return parseCanonicalExtensionGrant(value) != null;
}

pub fn parseCanonicalExtensionGrant(value: []const u8) ?CanonicalExtensionGrant {
    inline for (CANONICAL_EXTENSION_GRANTS) |grant| {
        if (std.mem.eql(u8, value, grant.jsonName())) return grant;
    }
    return null;
}

pub fn hasExtensionGrant(policy: ?ExtensionPolicy, grant: CanonicalExtensionGrant) bool {
    const actual = policy orelse return false;
    for (actual.approved_grants) |approved| {
        if (approved == grant) return true;
    }
    return false;
}

pub fn createExtensionPolicyDenialDetails(
    identity: CanonicalExtensionIdentity,
    grant: CanonicalExtensionGrant,
    operation: []const u8,
) ExtensionPolicyDenialDetails {
    return .{
        .capability = grant,
        .operation = operation,
        .runtime_kind = identity.runtime_kind,
        .extension_identity = identity.key,
    };
}

pub fn assertExtensionGrant(
    identity: CanonicalExtensionIdentity,
    policy: ?ExtensionPolicy,
    grant: CanonicalExtensionGrant,
    operation: []const u8,
) ExtensionPolicyDeniedError!void {
    _ = identity;
    _ = operation;
    if (!hasExtensionGrant(policy, grant)) return error.ExtensionPolicyDenied;
}

pub fn createWasmExtensionPolicyPrefix(allocator: std.mem.Allocator, schema_version: []const u8, id: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "wasm:package:{s}:{s}:{s}:", .{ schema_version, id, version });
}

pub fn createWasmExtensionManifestPolicyKey(
    allocator: std.mem.Allocator,
    schema_version: []const u8,
    id: []const u8,
    version: []const u8,
    manifest_path: []const u8,
    package_root: []const u8,
    artifact_path: []const u8,
) ![]u8 {
    const normalized_manifest = try toPolicyPathAlloc(allocator, manifest_path);
    defer allocator.free(normalized_manifest);
    const normalized_root = try toPolicyPathAlloc(allocator, package_root);
    defer allocator.free(normalized_root);
    const normalized_artifact = try toPolicyPathAlloc(allocator, artifact_path);
    defer allocator.free(normalized_artifact);
    return std.fmt.allocPrint(
        allocator,
        "wasm:manifest:{s}:{s}:{s}:{s}:{s}:{s}",
        .{ schema_version, id, version, normalized_root, normalized_manifest, normalized_artifact },
    );
}

pub fn validateExtensionPolicyShape(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) (ExtensionPolicyValidationError || error{OutOfMemory})!ExtensionPolicy {
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isPolicyField(entry.key_ptr.*)) return error.UnsupportedPolicyField;
    }

    var grants: []CanonicalExtensionGrant = &.{};
    errdefer allocator.free(grants);
    if (object.get("approvedGrants")) |approved_grants| {
        const array = switch (approved_grants) {
            .array => |array| array,
            else => return error.ExpectedArray,
        };
        grants = try allocator.alloc(CanonicalExtensionGrant, array.items.len);
        for (array.items, 0..) |grant_value, index| {
            const grant_name = switch (grant_value) {
                .string => |text| text,
                else => return error.ExpectedString,
            };
            grants[index] = parseCanonicalExtensionGrant(grant_name) orelse return error.UnknownGrant;
        }
    }

    var resource_limits: ?ExtensionResourceLimits = null;
    errdefer if (resource_limits) |limits| allocator.free(limits.tool_scopes);
    if (object.get("resourceLimits")) |limits_value| {
        resource_limits = try validateResourceLimits(allocator, limits_value);
    }

    return .{
        .approved_grants = grants,
        .resource_limits = resource_limits,
    };
}

pub fn validateResourceLimits(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) (ExtensionPolicyValidationError || error{OutOfMemory})!ExtensionResourceLimits {
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isResourceLimitField(entry.key_ptr.*)) return error.UnsupportedResourceLimit;
    }
    return .{
        .max_children = try optionalResourceLimitInteger(object, "maxChildren"),
        .depth = try optionalResourceLimitInteger(object, "depth"),
        .turns = try optionalResourceLimitInteger(object, "turns"),
        .timeout_ms = try optionalResourceLimitInteger(object, "timeoutMs"),
        .output_bytes = try optionalResourceLimitInteger(object, "outputBytes"),
        .output_lines = try optionalResourceLimitInteger(object, "outputLines"),
        .tool_scopes = try optionalToolScopes(allocator, object),
    };
}

pub fn mergeExtensionPolicy(
    allocator: std.mem.Allocator,
    base: ?ExtensionPolicy,
    override: ExtensionPolicy,
) !ExtensionPolicy {
    var grants: []CanonicalExtensionGrant = &.{};
    var limits: ?ExtensionResourceLimits = null;

    if (base) |base_policy| {
        grants = try allocator.dupe(CanonicalExtensionGrant, base_policy.approved_grants);
        limits = try cloneResourceLimits(allocator, base_policy.resource_limits);
    }
    errdefer allocator.free(grants);
    errdefer if (limits) |actual| allocator.free(actual.tool_scopes);

    if (override.approved_grants.len > 0) {
        allocator.free(grants);
        grants = try allocator.dupe(CanonicalExtensionGrant, override.approved_grants);
    }
    if (override.resource_limits) |override_limits| {
        if (limits) |actual| allocator.free(actual.tool_scopes);
        limits = try cloneResourceLimits(allocator, override_limits);
    }
    return .{ .approved_grants = grants, .resource_limits = limits };
}

pub fn normalizeWasmResourceLimits(limits: ExtensionResourceLimits) ExtensionResourceLimits {
    return limits;
}

fn cloneResourceLimits(allocator: std.mem.Allocator, maybe_limits: ?ExtensionResourceLimits) !?ExtensionResourceLimits {
    const limits = maybe_limits orelse return null;
    var cloned = limits;
    cloned.tool_scopes = try allocator.dupe([]const u8, limits.tool_scopes);
    return cloned;
}

fn optionalResourceLimitInteger(object: std.json.ObjectMap, field: []const u8) ExtensionPolicyValidationError!?u64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.ExpectedNonNegativeInteger,
        else => error.ExpectedNonNegativeInteger,
    };
}

fn optionalToolScopes(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) (ExtensionPolicyValidationError || error{OutOfMemory})![]const []const u8 {
    const value = object.get("toolScopes") orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return error.ExpectedArray,
    };
    const scopes = try allocator.alloc([]const u8, array.items.len);
    errdefer allocator.free(scopes);
    for (array.items, 0..) |scope_value, index| {
        const scope = switch (scope_value) {
            .string => |text| text,
            else => return error.ExpectedString,
        };
        if (scope.len == 0) return error.EmptyToolScope;
        scopes[index] = scope;
    }
    return scopes;
}

fn isPolicyField(field: []const u8) bool {
    return std.mem.eql(u8, field, "approvedGrants") or std.mem.eql(u8, field, "resourceLimits");
}

pub fn isResourceLimitField(field: []const u8) bool {
    inline for (.{ "maxChildren", "depth", "turns", "timeoutMs", "outputBytes", "outputLines", "toolScopes" }) |allowed| {
        if (std.mem.eql(u8, field, allowed)) return true;
    }
    return false;
}

pub fn toPolicyPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, value);
    for (output) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return output;
}

test "extension policy validates approved grants and resource limits" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "approvedGrants": ["file.read", "agent.delegate"],
        \\  "resourceLimits": { "turns": 4, "toolScopes": ["read"] }
        \\}
    , .{});
    defer parsed.deinit();

    var policy = try validateExtensionPolicyShape(allocator, parsed.value);
    defer policy.deinit(allocator);
    try std.testing.expect(hasExtensionGrant(policy, .file_read));
    try std.testing.expectEqual(@as(u64, 4), policy.resource_limits.?.turns.?);
}

test "extension policy rejects unknown grants" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"approvedGrants\":[\"nope\"]}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.UnknownGrant, validateExtensionPolicyShape(allocator, parsed.value));
}
