const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const config = @import("../config.zig");
const config_errors = @import("../config_errors.zig");
const keybindings_mod = @import("../../shared/keybindings.zig");

const ConfigError = config.ConfigError;
const ConfigErrorSource = config.ConfigErrorSource;
const DoubleEscapeAction = config.DoubleEscapeAction;
const ExtensionPolicy = config.ExtensionPolicy;
const ExtensionPolicyMap = config.ExtensionPolicyMap;

const loadRuntimeConfig = config.loadRuntimeConfig;
const loadRuntimeConfigWithOptions = config.loadRuntimeConfigWithOptions;
const validateExtensionPoliciesForSettingsWrite = config.validateExtensionPoliciesForSettingsWrite;
const stripJsonComments = config.testing.callStripJsonComments;
const mergeExtensionPolicy = config.testing.callMergeExtensionPolicy;
const mergeExtensionPolicyMaps = config.testing.callMergeExtensionPolicyMaps;
const cloneStringList = config.testing.callCloneStringList;
const deinitExtensionPolicyMapRequired = config.testing.callDeinitExtensionPolicyMapRequired;
const cloneExtensionPolicyMap = config.testing.callCloneExtensionPolicyMap;
const parseApprovedGrants = config.testing.callParseApprovedGrants;
const parseOptionalToolScopes = config.testing.callParseOptionalToolScopes;
const parseStringList = config.testing.callParseStringList;
const freeStringList = config.testing.callFreeStringList;
const parseSettingsContent = config.testing.callParseSettingsContent;
const loadLegacySettingsApiKeys = config.testing.callLoadLegacySettingsApiKeys;
const loadModelsConfig = config.testing.callLoadModelsConfig;
const deinitStringMap = config.testing.callDeinitStringMap;

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, name });
    defer allocator.free(relative_path);
    return makeAbsoluteTestPath(allocator, relative_path);
}

test "runtime config merges global and project settings with nested overrides" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "openai",
        \\  "defaultModel": "gpt-5.4",
        \\  "defaultThinkingLevel": "low",
        \\  "sessionDir": "~/sessions",
        \\  "doubleEscapeAction": "fork",
        \\  "editorPaddingX": 1,
        \\  "compaction": {
        \\    "enabled": true,
        \\    "reserveTokens": 5000,
        \\    "keepRecentTokens": 20000
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "doubleEscapeAction": "none",
        \\  "editorPaddingX": 3,
        \\  "autocompleteMaxVisible": 9,
        \\  "compaction": {
        \\    "enabled": false,
        \\    "reserveTokens": 1200,
        \\    "keepRecentTokens": 6400
        \\  },
        \\  "retry": {
        \\    "enabled": true,
        \\    "maxRetries": 4,
        \\    "baseDelayMs": 2500
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("faux", runtime.settings.default_provider.?);
    try std.testing.expectEqualStrings("gpt-5.4", runtime.settings.default_model.?);
    try std.testing.expectEqual(agent.ThinkingLevel.low, runtime.settings.default_thinking_level.?);
    try std.testing.expectEqual(DoubleEscapeAction.none, runtime.doubleEscapeAction());
    try std.testing.expectEqual(@as(usize, 3), runtime.settings.editor_padding_x.?);
    try std.testing.expectEqual(@as(usize, 9), runtime.settings.autocomplete_max_visible.?);
    try std.testing.expectEqual(@as(usize, 0), runtime.errors.len);
    try std.testing.expect(runtime.settings.compaction != null);
    try std.testing.expectEqual(false, runtime.settings.compaction.?.enabled);
    try std.testing.expectEqual(@as(u32, 1200), runtime.settings.compaction.?.reserve_tokens);
    try std.testing.expectEqual(@as(u32, 6400), runtime.settings.compaction.?.keep_recent_tokens);
    try std.testing.expect(runtime.settings.retry != null);
    try std.testing.expectEqual(true, runtime.settings.retry.?.enabled);
    try std.testing.expectEqual(@as(u32, 4), runtime.settings.retry.?.max_retries);
    try std.testing.expectEqual(@as(u64, 2500), runtime.settings.retry.?.base_delay_ms);

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    const expected_session_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions" });
    defer allocator.free(expected_session_dir);
    try std.testing.expectEqualStrings(expected_session_dir, session_dir);
}

test "runtime config parses merges and looks up extension policies" {
    const allocator = std.testing.allocator;
    const identity_a = "typescript:local:project:/tmp/policy-a.ts";
    const identity_b = "typescript:local:project:/tmp/policy-b.ts";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-b.ts": { "approvedGrants": ["file.read"], "approved": false, "enabled": false },
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["agent.delegate", "tool.use"],
        \\      "approved": true,
        \\      "enabled": true,
        \\      "required": false,
        \\      "resourceLimits": {
        \\        "turns": 5,
        \\        "timeoutMs": 1000,
        \\        "outputLines": 20,
        \\        "toolScopes": ["fixture.echo", "fixture.read"]
        \\      }
        \\    }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["tool.use"],
        \\      "required": true,
        \\      "resourceLimits": {
        \\        "turns": 1,
        \\        "toolScopes": []
        \\      }
        \\    }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqual(@as(usize, 0), runtime.errors.len);
    try std.testing.expect(runtime.settings.extension_policies != null);
    try std.testing.expectEqual(@as(u32, 2), runtime.settings.extension_policies.?.count());
    const policy_a = runtime.getExtensionPolicy(identity_a).?;
    try std.testing.expectEqual(@as(usize, 1), policy_a.approved_grants.?.len);
    try std.testing.expectEqualStrings("tool.use", policy_a.approved_grants.?[0]);
    try std.testing.expectEqual(@as(u64, 1), policy_a.resource_limits.?.turns.?);
    try std.testing.expectEqual(@as(u64, 1000), policy_a.resource_limits.?.timeout_ms.?);
    try std.testing.expectEqual(@as(u64, 20), policy_a.resource_limits.?.output_lines.?);
    try std.testing.expectEqual(@as(usize, 0), policy_a.resource_limits.?.tool_scopes.?.len);
    try std.testing.expectEqual(true, policy_a.approved.?);
    try std.testing.expectEqual(true, policy_a.enabled.?);
    try std.testing.expectEqual(true, policy_a.required.?);

    const policy_b = runtime.getExtensionPolicy(identity_b).?;
    try std.testing.expectEqual(@as(usize, 1), policy_b.approved_grants.?.len);
    try std.testing.expectEqualStrings("file.read", policy_b.approved_grants.?[0]);
    try std.testing.expectEqual(false, policy_b.approved.?);
    try std.testing.expectEqual(false, policy_b.enabled.?);
}

test "extension policy merge replacement clones are OOM safe" {
    const base_policy = ExtensionPolicy{
        .approved_grants = &.{"file.read"},
        .resource_limits = .{
            .turns = 5,
            .tool_scopes = &.{"base.scope"},
        },
    };
    const override_policy = ExtensionPolicy{
        .approved_grants = &.{"tool.use"},
        .resource_limits = .{
            .turns = 1,
            .tool_scopes = &.{"override.scope"},
        },
    };

    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();

        if (mergeExtensionPolicy(failing_allocator, base_policy, override_policy)) |merged| {
            var owned = merged;
            defer owned.deinit(failing_allocator);

            try std.testing.expectEqual(@as(usize, 1), owned.approved_grants.?.len);
            try std.testing.expectEqualStrings("tool.use", owned.approved_grants.?[0]);
            try std.testing.expectEqual(@as(u64, 1), owned.resource_limits.?.turns.?);
            try std.testing.expectEqual(@as(usize, 1), owned.resource_limits.?.tool_scopes.?.len);
            try std.testing.expectEqualStrings("override.scope", owned.resource_limits.?.tool_scopes.?[0]);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
}

fn putOwnedTestPolicy(
    allocator: std.mem.Allocator,
    map: *ExtensionPolicyMap,
    identity: []const u8,
    grants: []const []const u8,
    tool_scopes: ?[]const []const u8,
) !void {
    var policy = ExtensionPolicy{};
    errdefer policy.deinit(allocator);
    policy.approved_grants = (try cloneStringList(allocator, grants)).?;
    if (tool_scopes) |scopes| {
        policy.resource_limits = .{
            .tool_scopes = (try cloneStringList(allocator, scopes)).?,
        };
    }
    const owned_identity = try allocator.dupe(u8, identity);
    errdefer allocator.free(owned_identity);
    try map.put(owned_identity, policy);
}

fn expectBasePolicyUnchanged(base: ExtensionPolicyMap, identity_a: []const u8, identity_b: []const u8) !void {
    const retained = base.get(identity_a).?;
    try std.testing.expectEqual(@as(usize, 1), retained.approved_grants.?.len);
    try std.testing.expectEqualStrings("file.read", retained.approved_grants.?[0]);
    try std.testing.expectEqual(@as(usize, 1), retained.resource_limits.?.tool_scopes.?.len);
    try std.testing.expectEqualStrings("base.scope", retained.resource_limits.?.tool_scopes.?[0]);
    try std.testing.expect(base.get(identity_b) == null);
}

test "extension policy map merge preserves caller-owned base map on OOM" {
    const allocator = std.testing.allocator;
    const identity_a = "typescript:local:project:/tmp/policy-a.ts";
    const identity_b = "typescript:local:project:/tmp/policy-b.ts";

    var base = ExtensionPolicyMap.init(allocator);
    defer deinitExtensionPolicyMapRequired(allocator, &base);
    try putOwnedTestPolicy(allocator, &base, identity_a, &.{"file.read"}, &.{"base.scope"});

    var overrides = ExtensionPolicyMap.init(allocator);
    defer deinitExtensionPolicyMapRequired(allocator, &overrides);
    try putOwnedTestPolicy(allocator, &overrides, identity_a, &.{"tool.use"}, &.{"override.scope"});
    try putOwnedTestPolicy(allocator, &overrides, identity_b, &.{"agent.delegate"}, null);

    var fail_index: usize = 0;
    while (fail_index < 96) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (mergeExtensionPolicyMaps(failing_allocator, base, overrides)) |maybe_merged| {
            var merged = maybe_merged.?;
            defer deinitExtensionPolicyMapRequired(failing_allocator, &merged);

            const policy_a = merged.get(identity_a).?;
            try std.testing.expectEqual(@as(usize, 1), policy_a.approved_grants.?.len);
            try std.testing.expectEqualStrings("tool.use", policy_a.approved_grants.?[0]);
            try std.testing.expectEqual(@as(usize, 1), policy_a.resource_limits.?.tool_scopes.?.len);
            try std.testing.expectEqualStrings("override.scope", policy_a.resource_limits.?.tool_scopes.?[0]);
            const policy_b = merged.get(identity_b).?;
            try std.testing.expectEqual(@as(usize, 1), policy_b.approved_grants.?.len);
            try std.testing.expectEqualStrings("agent.delegate", policy_b.approved_grants.?[0]);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }

        try expectBasePolicyUnchanged(base, identity_a, identity_b);
    }
}

test "extension policy map clone releases cloned policy when put fails" {
    const allocator = std.testing.allocator;

    var source = ExtensionPolicyMap.init(allocator);
    defer deinitExtensionPolicyMapRequired(allocator, &source);
    try putOwnedTestPolicy(
        allocator,
        &source,
        "typescript:local:project:/tmp/policy-a.ts",
        &.{ "file.read", "tool.use" },
        &.{ "scope.one", "scope.two" },
    );

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();

        if (cloneExtensionPolicyMap(failing_allocator, source)) |maybe_cloned| {
            if (maybe_cloned) |cloned| {
                var owned = cloned;
                deinitExtensionPolicyMapRequired(failing_allocator, &owned);
            }
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
}

test "extension policy parser list append failures release duplicated strings" {
    const allocator = std.testing.allocator;
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);

    var grants_value = try std.json.parseFromSlice(std.json.Value, allocator,
        \\["file.read", "tool.use"]
    , .{});
    defer grants_value.deinit();
    var tool_scopes_value = try std.json.parseFromSlice(std.json.Value, allocator,
        \\["scope.one", "scope.two"]
    , .{});
    defer tool_scopes_value.deinit();
    var string_list_value = try std.json.parseFromSlice(std.json.Value, allocator,
        \\["extensions", "skills"]
    , .{});
    defer string_list_value.deinit();

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (parseApprovedGrants(
            failing_allocator,
            grants_value.value,
            &errors,
            .settings,
            "settings.json",
            "$.extensionPolicies[\"policy\"]",
        )) |maybe_grants| {
            freeStringList(failing_allocator, maybe_grants);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }

    fail_index = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (parseOptionalToolScopes(
            failing_allocator,
            tool_scopes_value.value,
            &errors,
            .settings,
            "settings.json",
            "$.extensionPolicies[\"policy\"].resourceLimits",
        )) |scopes_result| {
            switch (scopes_result) {
                .absent, .invalid => {},
                .value => |scopes| freeStringList(failing_allocator, scopes),
            }
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }

    fail_index = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (parseStringList(failing_allocator, string_list_value.value)) |maybe_items| {
            freeStringList(failing_allocator, maybe_items);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "runtime config reports malformed extension policies while preserving valid scopes" {
    const allocator = std.testing.allocator;
    const identity_a = "typescript:local:project:/tmp/policy-a.ts";
    const identity_b = "typescript:local:project:/tmp/policy-b.ts";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": { "approvedGrants": ["agent.delegate"] },
        \\    "typescript:local:project:/tmp/policy-b.ts": { "approvedGrants": ["agent"] }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-b.ts": { "resourceLimits": { "turns": 1 } }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqual(@as(usize, 1), runtime.errors.len);
    try std.testing.expectEqualStrings(
        "$.extensionPolicies[\"typescript:local:project:/tmp/policy-b.ts\"].approvedGrants[0]: unknown grant \"agent\"",
        runtime.errors[0].message,
    );
    try std.testing.expect(runtime.global_settings.extension_policies.?.get(identity_a) != null);
    try std.testing.expect(runtime.global_settings.extension_policies.?.get(identity_b) == null);
    const policy_b = runtime.getExtensionPolicy(identity_b).?;
    try std.testing.expectEqual(@as(u64, 1), policy_b.resource_limits.?.turns.?);
}

test "runtime config rejects malformed resource limit policy entries for effective lookup" {
    const allocator = std.testing.allocator;
    const valid_identity = "typescript:local:project:/tmp/policy-valid.ts";
    const timeout_identity = "typescript:local:project:/tmp/policy-timeout.ts";
    const scopes_identity = "typescript:local:project:/tmp/policy-scopes.ts";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-valid.ts": {
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": { "turns": 1, "toolScopes": ["read"] }
        \\    },
        \\    "typescript:local:project:/tmp/policy-timeout.ts": {
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": { "timeoutMs": 9007199254740992 }
        \\    },
        \\    "typescript:local:project:/tmp/policy-scopes.ts": {
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": { "toolScopes": [""] }
        \\    }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqual(@as(usize, 2), runtime.errors.len);
    try std.testing.expectEqualStrings(
        "$.extensionPolicies[\"typescript:local:project:/tmp/policy-timeout.ts\"].resourceLimits.timeoutMs: expected non-negative integer",
        runtime.errors[0].message,
    );
    try std.testing.expectEqualStrings(
        "$.extensionPolicies[\"typescript:local:project:/tmp/policy-scopes.ts\"].resourceLimits.toolScopes[0]: must not be empty",
        runtime.errors[1].message,
    );
    try std.testing.expect(runtime.settings.extension_policies != null);
    try std.testing.expectEqual(@as(u32, 1), runtime.settings.extension_policies.?.count());
    try std.testing.expect(runtime.getExtensionPolicy(timeout_identity) == null);
    try std.testing.expect(runtime.getExtensionPolicy(scopes_identity) == null);

    const valid_policy = runtime.getExtensionPolicy(valid_identity).?;
    try std.testing.expectEqual(@as(usize, 1), valid_policy.approved_grants.?.len);
    try std.testing.expectEqualStrings("file.read", valid_policy.approved_grants.?[0]);
    try std.testing.expectEqual(@as(u64, 1), valid_policy.resource_limits.?.turns.?);
    try std.testing.expectEqual(@as(usize, 1), valid_policy.resource_limits.?.tool_scopes.?.len);
    try std.testing.expectEqualStrings("read", valid_policy.resource_limits.?.tool_scopes.?[0]);
}

test "extension policy write validation blocks malformed active entries" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "theme": "dark",
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": { "approvedGrants": ["network"] }
        \\  }
        \\}
    , .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidExtensionPolicies,
        validateExtensionPoliciesForSettingsWrite(allocator, parsed.value.object, "settings.json"),
    );

    var unsafe_limit = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "resourceLimits": { "timeoutMs": 9007199254740992 }
        \\    }
        \\  }
        \\}
    , .{});
    defer unsafe_limit.deinit();
    try std.testing.expectError(
        error.InvalidExtensionPolicies,
        validateExtensionPoliciesForSettingsWrite(allocator, unsafe_limit.value.object, "settings.json"),
    );

    var valid = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["agent.delegate"],
        \\      "resourceLimits": { "outputLines": 4 }
        \\    }
        \\  }
        \\}
    , .{});
    defer valid.deinit();
    try validateExtensionPoliciesForSettingsWrite(allocator, valid.value.object, "settings.json");
}

test "runtime config loads auth and custom models from agent files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/auth.json",
        .data =
        \\{
        \\  "openai": { "type": "api_key", "key": "stored-openai-key" },
        \\  "anthropic": { "type": "oauth", "access_token": "oauth-token" }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "faux": {
        \\      "models": [
        \\        {
        \\          "id": "faux-custom",
        \\          "name": "Faux Custom",
        \\          "contextWindow": 16000,
        \\          "maxTokens": 2048
        \\        }
        \\      ]
        \\    },
        \\    "local-openai": {
        \\      "api": "openai-completions",
        \\      "baseUrl": "http://localhost:11434/v1",
        \\      "apiKey": "local-key",
        \\      "models": [
        \\        {
        \\          "id": "llama-3.3-70b",
        \\          "name": "Local Llama 3.3 70B",
        \\          "headers": {
        \\            "x-test": "1"
        \\          }
        \\        }
        \\      ]
        \\    },
        \\    "local-default": {
        \\      "baseUrl": "http://localhost:1234/v1",
        \\      "models": [
        \\        {
        \\          "id": "local-default-model"
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("stored-openai-key", runtime.lookupApiKey("openai").?);
    try std.testing.expectEqualStrings("oauth-token", runtime.lookupApiKey("anthropic").?);
    try std.testing.expectEqualStrings("local-key", runtime.lookupApiKey("local-openai").?);

    const faux_model = ai.model_registry.find("faux", "faux-custom").?;
    try std.testing.expectEqualStrings("Faux Custom", faux_model.name);
    try std.testing.expectEqual(@as(u32, 16000), faux_model.context_window);

    const local_provider = ai.model_registry.getProviderConfig("local-openai").?;
    try std.testing.expectEqualStrings("openai-completions", local_provider.api);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", local_provider.base_url);
    try std.testing.expectEqualStrings("llama-3.3-70b", local_provider.default_model_id.?);

    const local_model = ai.model_registry.find("local-openai", "llama-3.3-70b").?;
    try std.testing.expectEqualStrings("Local Llama 3.3 70B", local_model.name);
    try std.testing.expect(local_model.headers != null);

    const local_default_provider = ai.model_registry.getProviderConfig("local-default").?;
    try std.testing.expectEqualStrings("openai-completions", local_default_provider.api);
    try std.testing.expectEqualStrings("local-default-model", local_default_provider.default_model_id.?);
    const local_default_model = ai.model_registry.find("local-default", "local-default-model").?;
    try std.testing.expectEqualStrings("openai-completions", local_default_model.api);
    try std.testing.expect(runtime.lookupApiKey("local-default") == null);
}

test "runtime config reads legacy settings api keys" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "apiKeys": {
        \\    "kimi": "legacy-kimi-key"
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("legacy-kimi-key", runtime.lookupApiKey("kimi").?);
}

test "runtime config honors PI_CODING_AGENT_DIR and loads keybindings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "custom-agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "custom-agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "custom-agent/keybindings.json",
        .data =
        \\{
        \\  "app.clear": "ctrl+x",
        \\  "app.exit": ["ctrl+q"]
        \\}
        ,
    });

    const agent_dir = try makeTmpPath(allocator, tmp, "custom-agent");
    defer allocator.free(agent_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("faux", runtime.settings.default_provider.?);
    try std.testing.expectEqualStrings("faux-1", runtime.settings.default_model.?);
    try std.testing.expectEqual(keybindings_mod.Action.clear, runtime.keybindings.actionForKey(.{ .ctrl = 'x' }).?);
    // ctrl+l is now model_select by default (was app.clear in old Zig defaults)
    try std.testing.expectEqual(keybindings_mod.Action.model_select, runtime.keybindings.actionForKey(.{ .ctrl = 'l' }).?);
    try std.testing.expectEqual(keybindings_mod.Action.exit, runtime.keybindings.actionForKey(.{ .ctrl = 'q' }).?);
}

test "loadRuntimeConfig runs one-time migrations before loading credentials" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "apiKeys": {
        \\    "openai": "migrated-openai-key"
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".pi", "agent", "auth.json" });
    defer allocator.free(auth_path);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".pi", "agent", "settings.json" });
    defer allocator.free(settings_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("migrated-openai-key", runtime.lookupApiKey("openai").?);

    const auth_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(auth_bytes);
    try std.testing.expect(std.mem.indexOf(u8, auth_bytes, "\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_bytes, "\"migrated-openai-key\"") != null);

    const settings_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(settings_bytes);
    try std.testing.expect(std.mem.indexOf(u8, settings_bytes, "\"apiKeys\"") == null);
}

test "runtime config collects malformed settings without aborting" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data = "{ malformed",
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expect(runtime.errors.len >= 1);
    try std.testing.expectEqual(ConfigErrorSource.settings, runtime.errors[0].source);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errors[0].message, "SyntaxError") != null or
        std.mem.indexOf(u8, runtime.errors[0].message, "Unexpected") != null);
}

test "runtime config parse helpers keep OOM hard" {
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(std.testing.allocator, &errors);

    var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const failing_allocator = failing_allocator_state.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        parseSettingsContent(failing_allocator, "settings.json", "{}", &errors, .settings),
    );
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "runtime config collects legacy settings and models parse failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data = "{ malformed",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "models.json",
        .data = "{ malformed",
    });

    const settings_path = try makeTmpPath(allocator, tmp, "settings.json");
    defer allocator.free(settings_path);
    const models_path = try makeTmpPath(allocator, tmp, "models.json");
    defer allocator.free(models_path);

    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try loadLegacySettingsApiKeys(allocator, std.testing.io, settings_path, &auth_tokens, &errors);

    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer deinitStringMap(allocator, &provider_api_keys);
    try loadModelsConfig(allocator, std.testing.io, models_path, &provider_api_keys, false, &errors);

    try std.testing.expectEqual(@as(usize, 2), errors.items.len);
    try std.testing.expectEqual(ConfigErrorSource.legacy_settings, errors.items[0].source);
    try std.testing.expectEqual(ConfigErrorSource.models, errors.items[1].source);
}

test "runtime config collects model discovery failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "local-fail": {
        \\      "api": "openai-completions",
        \\      "baseUrl": "http://127.0.0.1:1/v1",
        \\      "discoverModels": true
        \\    }
        \\  }
        \\}
        ,
    });

    const models_path = try makeTmpPath(allocator, tmp, "models.json");
    defer allocator.free(models_path);

    ai.model_registry.clearDefault();
    defer ai.model_registry.resetForTesting();

    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer deinitStringMap(allocator, &provider_api_keys);

    try loadModelsConfig(allocator, std.testing.io, models_path, &provider_api_keys, true, &errors);

    var saw_discovery = false;
    for (errors.items) |config_error| {
        if (config_error.source == .discovery) saw_discovery = true;
    }
    try std.testing.expect(saw_discovery);
}

test "RuntimeConfig.effectiveSessionDir honors PI_CODING_AGENT_SESSION_DIR before settings sessionDir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.createDirPath(std.testing.io, "envvar-sessions");
    // Settings explicitly point at a different directory so we can prove the
    // env var wins.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "/tmp/should-be-ignored-by-env-var" }
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const env_dir = try makeTmpPath(allocator, tmp, "envvar-sessions");
    defer allocator.free(env_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", env_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    try std.testing.expectEqualStrings(env_dir, session_dir);
}

test "RuntimeConfig.effectiveSessionDir falls back to settings sessionDir when env is empty" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "~/sessions-from-settings" }
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    // Empty env value must not preempt settings sessionDir; mirrors TS
    // `process.env[ENV_SESSION_DIR]` truthiness check.
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", "");

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    const expected = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions-from-settings" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session_dir);
}

test "RuntimeConfig.effectiveSessionDir falls back to default when env and settings are absent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    const expected = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".pi", "sessions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session_dir);
}

test "stripJsonComments removes line comments outside strings" {
    const allocator = std.testing.allocator;
    const input =
        \\// header comment
        \\{
        \\  "id": "x" // trailing comment
        \\}
    ;
    const stripped = try stripJsonComments(allocator, input);
    defer allocator.free(stripped);
    const expected =
        \\
        \\{
        \\  "id": "x"
        \\}
    ;
    try std.testing.expectEqualStrings(expected, stripped);
}

test "stripJsonComments removes block comments outside strings" {
    const allocator = std.testing.allocator;
    const input = "{/* block */ \"a\": /* mid */ 1 /* tail */}";
    const stripped = try stripJsonComments(allocator, input);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("{ \"a\":  1 }", stripped);
}

test "stripJsonComments removes trailing commas before } and ]" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "a": [1, 2, 3,],
        \\  "b": 4,
        \\}
    ;
    const stripped = try stripJsonComments(allocator, input);
    defer allocator.free(stripped);
    const expected =
        \\{
        \\  "a": [1, 2, 3],
        \\  "b": 4
        \\}
    ;
    try std.testing.expectEqualStrings(expected, stripped);
}

test "stripJsonComments preserves // and trailing commas inside string literals" {
    const allocator = std.testing.allocator;
    const input =
        \\{ "url": "https://example.com/path", "note": "ends with comma," }
    ;
    const stripped = try stripJsonComments(allocator, input);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings(input, stripped);
}

test "stripJsonComments handles escaped quotes inside string literals" {
    const allocator = std.testing.allocator;
    const input =
        \\{ "quote": "He said \"// not a comment\" today" }
    ;
    const stripped = try stripJsonComments(allocator, input);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings(input, stripped);
}

test "stripJsonComments strips trailing comma even with comment between" {
    // Regression for the second commit in TS bb25a394: a `//` between a
    // trailing comma and its closer must not hide the comma from the
    // trailing-comma pass.
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "a": 1, // trailing
        \\}
    ;
    const stripped = try stripJsonComments(allocator, input);
    defer allocator.free(stripped);
    const expected =
        \\{
        \\  "a": 1
        \\}
    ;
    try std.testing.expectEqualStrings(expected, stripped);
}

test "loadModelsConfig parses JSONC with comments and trailing commas" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "models.json",
        .data =
        \\// User-supplied models.json with JSONC niceties.
        \\{
        \\  /* providers map */
        \\  "providers": {
        \\    "local-jsonc": {
        \\      "api": "openai-completions",
        \\      "baseUrl": "http://localhost:1234/v1", // local server
        \\      "apiKey": "jsonc-key",
        \\      "models": [
        \\        {
        \\          "id": "jsonc-model",
        \\          "name": "JSONC Model",
        \\        },
        \\      ],
        \\    },
        \\  },
        \\}
        ,
    });

    const models_path = try makeTmpPath(allocator, tmp, "models.json");
    defer allocator.free(models_path);

    ai.model_registry.clearDefault();
    defer ai.model_registry.resetForTesting();

    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer deinitStringMap(allocator, &provider_api_keys);

    try loadModelsConfig(allocator, std.testing.io, models_path, &provider_api_keys, false, &errors);

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
    try std.testing.expectEqualStrings("jsonc-key", provider_api_keys.get("local-jsonc").?);
    const model = ai.model_registry.find("local-jsonc", "jsonc-model").?;
    try std.testing.expectEqualStrings("JSONC Model", model.name);
}

test "loadModelsConfig preserves // inside string values" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "with-url": {
        \\      "api": "openai-completions",
        \\      "baseUrl": "https://example.com/v1",
        \\      "models": [
        \\        { "id": "url-model" }
        \\      ]
        \\    }
        \\  }
        \\}
        ,
    });

    const models_path = try makeTmpPath(allocator, tmp, "models.json");
    defer allocator.free(models_path);

    ai.model_registry.clearDefault();
    defer ai.model_registry.resetForTesting();

    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer deinitStringMap(allocator, &provider_api_keys);

    try loadModelsConfig(allocator, std.testing.io, models_path, &provider_api_keys, false, &errors);

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
    const provider = ai.model_registry.getProviderConfig("with-url").?;
    try std.testing.expectEqualStrings("https://example.com/v1", provider.base_url);
}
