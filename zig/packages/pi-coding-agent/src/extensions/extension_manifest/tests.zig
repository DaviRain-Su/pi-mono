const std = @import("std");
const manifest = @import("../extension_manifest.zig");

const RuntimeKind = manifest.RuntimeKind;
const ValidationResult = manifest.ValidationResult;
const parseManifestText = manifest.parseManifestText;
const resolveManifestSources = manifest.resolveManifestSources;
const versionSatisfies = manifest.testing.version_satisfies;

fn expectInvalid(result: *ValidationResult, expected_path: []const u8, expected_code: []const u8) !void {
    try std.testing.expect(result.* == .invalid);
    try std.testing.expectEqual(@as(usize, 1), result.invalid.len);
    try std.testing.expectEqualStrings(expected_path, result.invalid[0].path);
    try std.testing.expectEqualStrings(expected_code, result.invalid[0].code);
    try std.testing.expect(result.invalid[0].message.len > 0);
}

const COMPLETE_MANIFEST =
    \\{
    \\  "schemaVersion": "pi-extension.v1",
    \\  "id": "com.example.composable",
    \\  "name": "Composable Example",
    \\  "version": "1.2.3",
    \\  "description": "Full manifest",
    \\  "runtime": {
    \\    "kind": "typescript",
    \\    "entrypoint": "src/index.ts",
    \\    "limits": {"timeoutMs": 12000, "toolScopes": ["read"]}
    \\  },
    \\  "lifecycle": {"required": true},
    \\  "tools": [{"name": "example.tool", "description": "Tool", "inputSchema": {"type": "object"}, "permissions": ["file.read"]}],
    \\  "commands": [{"name": "example", "description": "Command", "permissions": ["session.read"]}],
    \\  "resources": [{"kind": "prompt", "name": "review", "path": "prompts/review.md", "precedence": "package"}],
    \\  "providers": [{"id": "example-provider", "displayName": "Example Provider", "models": [{"id": "faux", "name": "Faux"}], "credentialRequired": false}],
    \\  "hooks": [{"event": "input", "priority": 5, "errorPolicy": "fatal"}],
    \\  "capabilities": {"exports": [{"id": "cap.review", "kind": "tool"}], "imports": [{"id": "cap.plan", "version": "^1.0.0"}]},
    \\  "permissions": [{"grant": "file.read", "reason": "Read fixtures"}],
    \\  "dependencies": [{"id": "com.example.base", "version": "^1.0.0"}],
    \\  "workflows": [{"id": "review-flow", "description": "Review", "timeoutMs": 1000}]
    \\}
;

test "unified manifest accepts complete declarations without dropping fields" {
    const allocator = std.testing.allocator;
    var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", COMPLETE_MANIFEST);
    defer result.deinit(allocator);

    try std.testing.expect(result == .valid);
    try std.testing.expectEqual(.typescript, result.valid.runtime_kind);
    try std.testing.expectEqual(@as(usize, 1), result.valid.tools.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.commands.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.resources.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.providers.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.hooks.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.permissions.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.dependencies.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.workflows.array.items.len);

    const snapshot = try result.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"example.tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"example-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"cap.review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"review-flow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"declarationOrder\":0") != null);
}

test "workflow manifests normalize registry commands tools and sub-agent presets" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "schemaVersion":"pi-extension.v1",
        \\  "id":"workflow.pkg",
        \\  "name":"Workflow Package",
        \\  "version":"1.0.0",
        \\  "runtime":{"kind":"typescript","entrypoint":"index.ts"},
        \\  "workflows":[
        \\    {
        \\      "id":"triage",
        \\      "description":"Triage issue",
        \\      "inputSchema":{"type":"object","properties":{"issue":{"type":"string"}},"required":["issue"]},
        \\      "outputSchema":{"type":"object"},
        \\      "permissions":["session.read"],
        \\      "dependencies":[{"id":"cap.issue","kind":"tool"}],
        \\      "timeoutMs":1500,
        \\      "replay":{"enabled":true,"mode":"recorded"},
        \\      "childAgentLimits":{"maxChildren":1,"maxTurns":3,"maxToolCalls":2,"maxTokens":4096,"timeoutMs":1500},
        \\      "exposure":{"command":{"name":"triage"},"tool":{"name":"workflow.triage"},"subAgentPreset":{"id":"triage-agent"}}
        \\    },
        \\    {
        \\      "id":"denied-command",
        \\      "description":"Denied command",
        \\      "inputSchema":{"type":"object"},
        \\      "exposure":{"command":{"name":"denied","policy":{"approved":false}},"tool":false,"subAgentPreset":false}
        \\    },
        \\    {
        \\      "id":"invalid-workflow",
        \\      "inputSchema":false,
        \\      "exposure":{"command":true}
        \\    }
        \\  ]
        \\}
    ;

    var result = try parseManifestText(allocator, "/tmp/workflow", "/tmp/workflow/pi-extension.json", source);
    defer result.deinit(allocator);
    try std.testing.expect(result == .valid);
    try std.testing.expectEqual(@as(usize, 2), result.valid.workflows.array.items.len);
    try std.testing.expect(result.valid.diagnostics.len >= 1);

    const snapshot = try result.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflowRegistry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"descriptors\":[{\"workflowId\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"commands\":[{\"workflowId\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tools\":[{\"workflowId\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"workflow.triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"subAgentPresets\":[{\"workflowId\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"triage-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"maxTurns\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflowId\":\"denied-command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"commandName\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"invalid-workflow\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"manifest.expected_object\"") != null);
}

test "unified manifest rejects malformed required fields with field diagnostics" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        path: []const u8,
        code: []const u8,
    }{
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"name\":\"Missing Id\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.ts\"}}",
            .path = "$.id",
            .code = "manifest.missing_required_field",
        },
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"x\",\"name\":\"X\",\"version\":\"1.0.0\"}",
            .path = "$.runtime",
            .code = "manifest.missing_required_field",
        },
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"x\",\"name\":\"X\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\"}}",
            .path = "$.runtime.entrypoint",
            .code = "manifest.missing_required_field",
        },
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"x\",\"name\":\"X\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"mystery\",\"entrypoint\":\"index.ts\"}}",
            .path = "$.runtime.kind",
            .code = "manifest.unsupported_runtime",
        },
    };

    for (cases) |case| {
        var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", case.text);
        defer result.deinit(allocator);
        try expectInvalid(&result, case.path, case.code);
    }
}

test "unified manifest validates runtime-specific entrypoint matrix" {
    const allocator = std.testing.allocator;
    const valid_cases = [_]struct {
        kind: RuntimeKind,
        text: []const u8,
    }{
        .{ .kind = .typescript, .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"ts\",\"name\":\"TS\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"src/index.ts\"}}" },
        .{ .kind = .javascript, .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"js\",\"name\":\"JS\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"javascript\",\"entrypoint\":\"dist/index.js\"}}" },
        .{ .kind = .process_jsonl, .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"proc\",\"name\":\"Proc\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"process_jsonl\",\"entrypoint\":{\"argv\":[\"node\",\"host.js\"]}}}" },
        .{ .kind = .future, .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"future\",\"name\":\"Future\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"future\",\"entrypoint\":{\"contract\":\"future-runtime.v1\"}}}" },
    };
    for (valid_cases) |case| {
        var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", case.text);
        defer result.deinit(allocator);
        try std.testing.expect(result == .valid);
        try std.testing.expectEqual(case.kind, result.valid.runtime_kind);
    }

    const invalid_cases = [_]struct {
        text: []const u8,
        path: []const u8,
    }{
        .{ .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"ts\",\"name\":\"TS\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"src/index.txt\"}}", .path = "$.runtime.entrypoint" },
        .{ .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"proc\",\"name\":\"Proc\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"process_jsonl\",\"entrypoint\":{\"argv\":[]}}}", .path = "$.runtime.entrypoint.argv" },
    };
    for (invalid_cases) |case| {
        var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", case.text);
        defer result.deinit(allocator);
        try std.testing.expect(result == .invalid);
        try std.testing.expectEqualStrings(case.path, result.invalid[0].path);
    }
}

test "unified manifest defaults are stable visible and do not mutate source bytes" {
    const allocator = std.testing.allocator;
    const source =
        \\{"schemaVersion":"pi-extension.v1","id":"minimal","name":"Minimal","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"}}
    ;
    const before = try allocator.dupe(u8, source);
    defer allocator.free(before);

    var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", source);
    defer result.deinit(allocator);
    try std.testing.expect(result == .valid);
    try std.testing.expectEqualStrings(before, source);

    const snapshot = try result.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"tools\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"commands\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"toolScopes\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"required\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"startupTimeoutMs\":30000") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflows\":false") != null);
}

test "unified manifest fills partial runtime limits without mutating source bytes" {
    const allocator = std.testing.allocator;
    const source =
        \\{"schemaVersion":"pi-extension.v1","id":"partial-limits","name":"Partial Limits","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["node","host.js"]},"limits":{"timeoutMs":42}}}
    ;
    const before = try allocator.dupe(u8, source);
    defer allocator.free(before);

    var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", source);
    defer result.deinit(allocator);
    try std.testing.expect(result == .valid);
    try std.testing.expectEqualStrings(before, source);

    const snapshot = try result.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"timeoutMs\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"outputBytes\":1048576") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"toolScopes\":[]") != null);
}

test "unified manifest normalizes declarations with owner runtime metadata and diagnostics" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "schemaVersion":"pi-extension.v1",
        \\  "id":"normalized.pkg",
        \\  "name":"Normalized Package",
        \\  "version":"1.0.0",
        \\  "runtime":{"kind":"typescript","entrypoint":"index.ts"},
        \\  "tools":[
        \\    {"name":"valid.tool","description":"Valid tool","inputSchema":{"type":"object"}},
        \\    {"description":"missing name"},
        \\    42
        \\  ],
        \\  "commands":[{"name":"valid-command"},{"description":"missing name"}],
        \\  "providers":[{"id":"valid-provider","models":[]},{"displayName":"missing id"}],
        \\  "hooks":[
        \\    {"event":"input","priority":2,"errorPolicy":"fatal"},
        \\    {"event":"not_real_event"},
        \\    {"event":"context","errorPolicy":"panic"}
        \\  ]
        \\}
    ;

    var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", source);
    defer result.deinit(allocator);
    try std.testing.expect(result == .valid);
    try std.testing.expectEqual(@as(usize, 1), result.valid.tools.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.commands.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.providers.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.valid.hooks.array.items.len);
    try std.testing.expect(result.valid.diagnostics.len >= 5);

    const snapshot = try result.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"owner\":{\"id\":\"normalized.pkg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"runtime\":{\"kind\":\"typescript\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"manifest.unsupported_hook_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"manifest.unsupported_hook_error_policy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"chainOrder\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"errorPolicy\":\"fatal\"") != null);
}

test "unified manifest hook chains use execution ordering instead of source order" {
    const allocator = std.testing.allocator;
    const source =
        \\{
        \\  "schemaVersion":"pi-extension.v1",
        \\  "id":"hook.ordering",
        \\  "name":"Hook Ordering",
        \\  "version":"1.0.0",
        \\  "runtime":{"kind":"typescript","entrypoint":"index.ts"},
        \\  "hooks":[
        \\    {"event":"input","hookId":"source-first-priority-late","priority":20,"declarationOrder":0},
        \\    {"event":"input","hookId":"source-second-declaration-late","priority":-5,"declarationOrder":9},
        \\    {"event":"input","hookId":"source-third-exec-first","priority":-5,"declarationOrder":1},
        \\    {"event":"tool_result","hookId":"separate-event","priority":-100,"declarationOrder":0}
        \\  ]
        \\}
    ;

    var result = try parseManifestText(allocator, "/tmp/pkg", "/tmp/pkg/pi-extension.json", source);
    defer result.deinit(allocator);
    try std.testing.expect(result == .valid);

    const snapshot = try result.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, snapshot, .{});
    defer parsed.deinit();
    const hook_chains = parsed.value.object.get("hookChains").?.array.items;

    var input_hook_ids = std.ArrayList([]const u8).empty;
    defer input_hook_ids.deinit(allocator);
    var input_chain_orders = std.ArrayList(i64).empty;
    defer input_chain_orders.deinit(allocator);
    for (hook_chains) |hook| {
        const object = hook.object;
        if (!std.mem.eql(u8, object.get("event").?.string, "input")) continue;
        try input_hook_ids.append(allocator, object.get("hookId").?.string);
        try input_chain_orders.append(allocator, object.get("chainOrder").?.integer);
    }

    try std.testing.expectEqual(@as(usize, 3), input_hook_ids.items.len);
    try std.testing.expectEqualStrings("source-third-exec-first", input_hook_ids.items[0]);
    try std.testing.expectEqualStrings("source-second-declaration-late", input_hook_ids.items[1]);
    try std.testing.expectEqualStrings("source-first-priority-late", input_hook_ids.items[2]);
    try std.testing.expectEqual(@as(i64, 0), input_chain_orders.items[0]);
    try std.testing.expectEqual(@as(i64, 1), input_chain_orders.items[1]);
    try std.testing.expectEqual(@as(i64, 2), input_chain_orders.items[2]);
}

test "unified manifest resource precedence exposes selected shadowed and trace" {
    const allocator = std.testing.allocator;
    const package_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"pkg.resource","name":"Pkg Resource","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"resources":[{"kind":"prompt","name":"review","path":"package/review.md"}]}
    ;
    const project_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"project.resource","name":"Project Resource","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"resources":[{"kind":"prompt","name":"review","path":"project/review.md"}]}
    ;
    const user_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"user.resource","name":"User Resource","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"resources":[{"kind":"prompt","name":"review","path":"user/review.md"}]}
    ;
    const cli_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"cli.resource","name":"Cli Resource","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"resources":[{"kind":"prompt","name":"review","path":"cli/review.md"}]}
    ;

    var set = try resolveManifestSources(allocator, &.{
        .{ .package_root = "/tmp/package", .manifest_path = "/tmp/package/pi-extension.json", .manifest_text = package_manifest, .source_scope = "package", .precedence_rank = 3 },
        .{ .package_root = "/tmp/project", .manifest_path = "/tmp/project/pi-extension.json", .manifest_text = project_manifest, .source_scope = "project", .precedence_rank = 2 },
        .{ .package_root = "/tmp/user", .manifest_path = "/tmp/user/pi-extension.json", .manifest_text = user_manifest, .source_scope = "user", .precedence_rank = 1 },
        .{ .package_root = "/tmp/cli", .manifest_path = "/tmp/cli/pi-extension.json", .manifest_text = cli_manifest, .source_scope = "cli", .precedence_rank = 0 },
    });
    defer set.deinit(allocator);

    const snapshot = try set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"resolvedResources\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"selectedSource\":\"cli\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"path\":\"cli/review.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"shadowedCandidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"path\":\"package/review.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"action\":\"selected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"action\":\"shadowed\"") != null);
}

test "unified manifest duplicate package identities are inactive and diagnosed" {
    const allocator = std.testing.allocator;
    const first =
        \\{"schemaVersion":"pi-extension.v1","id":"dup.pkg","name":"Dup","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"}}
    ;
    const second =
        \\{"schemaVersion":"pi-extension.v1","id":"dup.pkg","name":"Dup","version":"2.0.0","runtime":{"kind":"javascript","entrypoint":"index.js"}}
    ;
    var set = try resolveManifestSources(allocator, &.{
        .{ .package_root = "/tmp/project/dup", .manifest_path = "/tmp/project/dup/pi-extension.json", .manifest_text = first, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/user/dup", .manifest_path = "/tmp/user/dup/pi-extension.json", .manifest_text = second, .source_scope = "user", .precedence_rank = 2 },
    });
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.records.len);
    try std.testing.expect(set.records[0].active);
    try std.testing.expect(!set.records[1].active);
    try std.testing.expect(set.records[1].inactive_reason != null);
    try std.testing.expectEqual(@as(usize, 1), set.diagnostics.len);
    try std.testing.expectEqualStrings("manifest.duplicate_package_identity", set.diagnostics[0].code);
    try std.testing.expectEqualStrings("$.id", set.diagnostics[0].path);

    const snapshot = try set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"active\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"duplicate-package-identity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"manifest.duplicate_package_identity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"severity\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"phase\":\"manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"correlationId\":\"manifest:/tmp/user/dup/pi-extension.json\"") != null);
}

test "capability graph resolves imports dependencies and topological activation order" {
    const allocator = std.testing.allocator;
    const base =
        \\{"schemaVersion":"pi-extension.v1","id":"base.pkg","name":"Base","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"}}
    ;
    const preferred_provider =
        \\{"schemaVersion":"pi-extension.v1","id":"provider.preferred","name":"Preferred Provider","version":"1.2.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.review","kind":"tool","version":"1.2.0"}]}}
    ;
    const shadowed_provider =
        \\{"schemaVersion":"pi-extension.v1","id":"provider.shadowed","name":"Shadowed Provider","version":"1.1.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.review","kind":"tool","version":"1.1.0"}]}}
    ;
    const consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"consumer.pkg","name":"Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"dependencies":[{"id":"base.pkg","version":"^1.0.0"}],"capabilities":{"imports":[{"id":"cap.review","kind":"tool","version":"^1.0.0"}]}}
    ;

    var set = try resolveManifestSources(allocator, &.{
        .{ .package_root = "/tmp/base", .manifest_path = "/tmp/base/pi-extension.json", .manifest_text = base, .source_scope = "package", .precedence_rank = 2 },
        .{ .package_root = "/tmp/preferred", .manifest_path = "/tmp/preferred/pi-extension.json", .manifest_text = preferred_provider, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/shadowed", .manifest_path = "/tmp/shadowed/pi-extension.json", .manifest_text = shadowed_provider, .source_scope = "user", .precedence_rank = 3 },
        .{ .package_root = "/tmp/consumer", .manifest_path = "/tmp/consumer/pi-extension.json", .manifest_text = consumer, .source_scope = "cli", .precedence_rank = 1 },
    });
    defer set.deinit(allocator);

    for (set.records) |record| try std.testing.expect(record.active);

    const snapshot = try set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"composition\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"activeNodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveNodes\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"package_dependency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"capability_import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"providerPackageId\":\"provider.preferred\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"providerPackageVersion\":\"1.2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"activationOrder\":[\"base.pkg\",\"provider.preferred\",\"provider.shadowed\",\"consumer.pkg\"]") != null);
}

test "semver caret ranges enforce pre-1.0 upper bounds" {
    try std.testing.expect(versionSatisfies("1.9.9", "^1.2.3"));
    try std.testing.expect(!versionSatisfies("2.0.0", "^1.2.3"));
    try std.testing.expect(versionSatisfies("0.2.9", "^0.2.0"));
    try std.testing.expect(!versionSatisfies("0.3.0", "^0.2.0"));
    try std.testing.expect(versionSatisfies("0.0.3", "^0.0.3"));
    try std.testing.expect(!versionSatisfies("0.0.4", "^0.0.3"));
    try std.testing.expect(!versionSatisfies("0.2.1-beta.1", "^0.2.0"));
    try std.testing.expect(versionSatisfies("0.2.1-beta.1", "^0.2.0-beta.1"));
}

test "capability graph diagnostics include structured observability fields" {
    const allocator = std.testing.allocator;
    const source =
        \\{"schemaVersion":"pi-extension.v1","id":"consumer.pkg","name":"Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.missing","kind":"tool"}]}}
    ;
    var set = try resolveManifestSources(allocator, &.{.{
        .package_root = "/tmp/consumer",
        .manifest_path = "/tmp/consumer/pi-extension.json",
        .manifest_text = source,
        .source_scope = "project-installed",
        .precedence_rank = 1,
    }});
    defer set.deinit(allocator);

    const snapshot = try set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"code\":\"graph.missing_capability_import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"severity\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"packageId\":\"consumer.pkg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"runtime\":\"typescript\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"capabilityId\":\"cap.missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"phase\":\"graph\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"correlationId\":\"manifest:/tmp/consumer/pi-extension.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"spanId\":\"graph.missing_capability_import:$.capabilities.imports[0]\"") != null);
}

test "denied provider candidates do not block unambiguous approved provider" {
    const allocator = std.testing.allocator;
    const denied_provider =
        \\{"schemaVersion":"pi-extension.v1","id":"provider.denied","name":"Denied Provider","version":"0.2.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.review","kind":"tool","version":"0.2.0","policy":{"approved":false,"source":"project"}}]}}
    ;
    const approved_provider =
        \\{"schemaVersion":"pi-extension.v1","id":"provider.approved","name":"Approved Provider","version":"0.2.1","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.review","kind":"tool","version":"0.2.1"}]}}
    ;
    const consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"consumer.approved","name":"Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.review","kind":"tool","version":"^0.2.0"}]}}
    ;
    const explicit_denied_consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"consumer.denied","name":"Explicit Denied Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.review","kind":"tool","version":"^0.2.0","provider":"provider.denied"}]}}
    ;

    var set = try resolveManifestSources(allocator, &.{
        .{ .package_root = "/tmp/denied", .manifest_path = "/tmp/denied/pi-extension.json", .manifest_text = denied_provider, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/approved", .manifest_path = "/tmp/approved/pi-extension.json", .manifest_text = approved_provider, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/consumer", .manifest_path = "/tmp/consumer/pi-extension.json", .manifest_text = consumer, .source_scope = "project", .precedence_rank = 2 },
        .{ .package_root = "/tmp/explicit-denied", .manifest_path = "/tmp/explicit-denied/pi-extension.json", .manifest_text = explicit_denied_consumer, .source_scope = "project", .precedence_rank = 2 },
    });
    defer set.deinit(allocator);

    var consumer_active = false;
    var explicit_denied_active = true;
    for (set.records) |record| {
        if (std.mem.eql(u8, record.manifest.id, "consumer.approved")) consumer_active = record.active;
        if (std.mem.eql(u8, record.manifest.id, "consumer.denied")) explicit_denied_active = record.active;
    }
    try std.testing.expect(consumer_active);
    try std.testing.expect(!explicit_denied_active);

    const snapshot = try set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.policy_denied_capability_candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"consumerPackageId\":\"consumer.approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"providerPackageId\":\"provider.approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"policy-denied-capability\"") != null);
}

test "capability graph rejects missing duplicate cyclic incompatible and policy-denied imports" {
    const allocator = std.testing.allocator;
    const duplicate_a =
        \\{"schemaVersion":"pi-extension.v1","id":"dup.provider.a","name":"Dup A","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.duplicate","kind":"tool","version":"1.0.0"}]}}
    ;
    const duplicate_b =
        \\{"schemaVersion":"pi-extension.v1","id":"dup.provider.b","name":"Dup B","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.duplicate","kind":"tool","version":"1.0.0"}]}}
    ;
    const incompatible_provider =
        \\{"schemaVersion":"pi-extension.v1","id":"incompatible.provider","name":"Incompatible Provider","version":"2.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.versioned","kind":"tool","version":"2.0.0"}]}}
    ;
    const denied_provider =
        \\{"schemaVersion":"pi-extension.v1","id":"denied.provider","name":"Denied Provider","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"exports":[{"id":"cap.denied","kind":"tool","version":"1.0.0","policy":{"approved":false,"source":"project"}}]}}
    ;
    const missing_consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"missing.consumer","name":"Missing Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.missing","kind":"tool"}]}}
    ;
    const duplicate_consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"duplicate.consumer","name":"Duplicate Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.duplicate","kind":"tool","version":"^1.0.0"}]}}
    ;
    const incompatible_consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"incompatible.consumer","name":"Incompatible Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.versioned","kind":"tool","version":"^1.0.0"}]}}
    ;
    const denied_consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"denied.consumer","name":"Denied Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"capabilities":{"imports":[{"id":"cap.denied","kind":"tool","version":"^1.0.0","provider":"denied.provider"}]}}
    ;
    const policy_dependency_consumer =
        \\{"schemaVersion":"pi-extension.v1","id":"policy.dependency.consumer","name":"Policy Dependency Consumer","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"dependencies":[{"id":"dup.provider.a","version":"^1.0.0","policyDenied":true,"policySource":"user"}]}
    ;
    const cycle_a =
        \\{"schemaVersion":"pi-extension.v1","id":"cycle.a","name":"Cycle A","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"dependencies":[{"id":"cycle.b","version":"^1.0.0"}]}
    ;
    const cycle_b =
        \\{"schemaVersion":"pi-extension.v1","id":"cycle.b","name":"Cycle B","version":"1.0.0","runtime":{"kind":"typescript","entrypoint":"index.ts"},"dependencies":[{"id":"cycle.a","version":"^1.0.0"}]}
    ;

    var set = try resolveManifestSources(allocator, &.{
        .{ .package_root = "/tmp/dup-a", .manifest_path = "/tmp/dup-a/pi-extension.json", .manifest_text = duplicate_a, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/dup-b", .manifest_path = "/tmp/dup-b/pi-extension.json", .manifest_text = duplicate_b, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/incompat-provider", .manifest_path = "/tmp/incompat-provider/pi-extension.json", .manifest_text = incompatible_provider, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/denied-provider", .manifest_path = "/tmp/denied-provider/pi-extension.json", .manifest_text = denied_provider, .source_scope = "project", .precedence_rank = 0 },
        .{ .package_root = "/tmp/missing", .manifest_path = "/tmp/missing/pi-extension.json", .manifest_text = missing_consumer, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/duplicate", .manifest_path = "/tmp/duplicate/pi-extension.json", .manifest_text = duplicate_consumer, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/incompatible", .manifest_path = "/tmp/incompatible/pi-extension.json", .manifest_text = incompatible_consumer, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/denied", .manifest_path = "/tmp/denied/pi-extension.json", .manifest_text = denied_consumer, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/policy-dep", .manifest_path = "/tmp/policy-dep/pi-extension.json", .manifest_text = policy_dependency_consumer, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/cycle-a", .manifest_path = "/tmp/cycle-a/pi-extension.json", .manifest_text = cycle_a, .source_scope = "project", .precedence_rank = 1 },
        .{ .package_root = "/tmp/cycle-b", .manifest_path = "/tmp/cycle-b/pi-extension.json", .manifest_text = cycle_b, .source_scope = "project", .precedence_rank = 1 },
    });
    defer set.deinit(allocator);

    const snapshot = try set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.missing_capability_import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.duplicate_capability_provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.version_incompatible_capability\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.policy_denied_capability\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.policy_denied_dependency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"graph.cyclic_dependency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"missing-capability-import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"duplicate-capability-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"version-incompatible-capability\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"policy-denied-capability\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"policy-denied-dependency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"inactiveReason\":\"cyclic-dependency\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"unresolvedImports\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"capabilityId\":\"cap.missing\"") != null);
}
