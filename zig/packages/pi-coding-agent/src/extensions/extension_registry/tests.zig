const std = @import("std");
const registry_mod = @import("../extension_registry.zig");

const Registry = registry_mod.Registry;
const BuiltinShortcutBinding = registry_mod.BuiltinShortcutBinding;
const HookErrorPolicy = registry_mod.HookErrorPolicy;
const ProviderOAuth = registry_mod.ProviderOAuth;
const applyHostFrameStream = registry_mod.applyHostFrameStream;
const deinitResolvedCommands = registry_mod.deinitResolvedCommands;
const loadFromExtensionPaths = registry_mod.loadFromExtensionPaths;
const registrySurfaceCounts = registry_mod.registrySurfaceCounts;
const registrySurfaceNames = registry_mod.registrySurfaceNames;
const writeRegistrySnapshotJson = registry_mod.writeRegistrySnapshotJson;

test "registry registers tools/commands/shortcuts/flags/providers and round-trips" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerTool("greet", "Greet", "Greets the world", "/tmp/greet.ts");
    try registry.registerCommand("greet", "Greets via slash command", "/tmp/greet.ts");
    try registry.registerShortcut("ctrl+g", "Trigger greet", "greet", "/tmp/greet.ts");
    try registry.registerFlag("plan", .boolean, "Enable plan mode", .{ .boolean = true }, "/tmp/greet.ts");
    try registry.registerFlag("alias", .string, null, .{ .string = "claude" }, "/tmp/greet.ts");
    try registry.registerProvider(
        "fake-provider",
        "Fake Provider",
        "http://localhost:0",
        "openai-completions",
        &.{
            .{ .id = "fake-1", .name = "Fake Model 1" },
            .{ .id = "fake-2", .name = "Fake Model 2" },
        },
        "/tmp/fake.ts",
    );

    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("greet", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("Greets the world", registry.tools.items[0].description);

    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqualStrings("greet", registry.commands.items[0].name);

    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqualStrings("ctrl+g", registry.shortcuts.items[0].shortcut);
    try std.testing.expectEqualStrings("greet", registry.shortcuts.items[0].command.?);

    try std.testing.expectEqual(@as(usize, 2), registry.flags.items.len);
    try std.testing.expect(registry.flags.items[0].type_kind == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value.boolean);
    try std.testing.expect(registry.flags.items[1].type_kind == .string);
    try std.testing.expectEqualStrings("claude", registry.flags.items[1].default_value.string);

    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("fake-provider", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), registry.providers.items[0].models.len);
    try std.testing.expectEqualStrings("fake-1", registry.providers.items[0].models[0].id);

    // Re-register the tool and ensure the listing still has only one
    // entry but with updated metadata.
    try registry.registerTool("greet", "Greet v2", "Greets the world (v2)", "/tmp/greet.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Greet v2", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("Greets the world (v2)", registry.tools.items[0].description);

    // Re-register the provider and ensure model list is replaced.
    try registry.registerProvider(
        "fake-provider",
        "Fake Provider",
        "http://localhost:0",
        "openai-completions",
        &.{.{ .id = "fake-only", .name = "Fake Only" }},
        "/tmp/fake.ts",
    );
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items[0].models.len);
    try std.testing.expectEqualStrings("fake-only", registry.providers.items[0].models[0].id);

    // unregisterProvider removes the entry deterministically and a
    // second call returns false.
    try std.testing.expect(registry.unregisterProvider("fake-provider"));
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expect(!registry.unregisterProvider("fake-provider"));
}

test "extension command collisions preserve incumbent command in insertion order" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerCommand("shared-cmd", "First command", "/tmp/cmd-a.ts");
    try registry.registerCommand("solo-cmd", "Solo command", "/tmp/cmd-c.ts");
    try registry.registerCommand("shared-cmd", "Second command", "/tmp/cmd-b.ts");
    try registry.registerCommand("same-extension", "old", "/tmp/cmd-a.ts");
    try registry.registerCommand("same-extension", "new", "/tmp/cmd-a.ts");

    try std.testing.expectEqual(@as(usize, 3), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.collision_diagnostics.items.len);

    const commands = try registry.resolveCommands(allocator);
    defer deinitResolvedCommands(allocator, commands);

    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqualStrings("shared-cmd", commands[0].name);
    try std.testing.expectEqualStrings("shared-cmd", commands[0].invocation_name);
    try std.testing.expectEqualStrings("First command", commands[0].description.?);
    try std.testing.expectEqualStrings("solo-cmd", commands[1].invocation_name);
    try std.testing.expectEqualStrings("same-extension", commands[2].invocation_name);
    try std.testing.expectEqualStrings("new", commands[2].description.?);

    try std.testing.expect(registry.hasCommandInvocation("shared-cmd"));
    try std.testing.expect(!registry.hasCommandInvocation("shared-cmd:1"));
    try std.testing.expectEqualStrings("command", registry.collision_diagnostics.items[0].surface);
    try std.testing.expectEqualStrings("shared-cmd", registry.collision_diagnostics.items[0].id);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"invocationName\":\"shared-cmd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"collisionDiagnostics\":[{\"surface\":\"command\",\"id\":\"shared-cmd\"") != null);
}

test "extension shortcut conflict parity resolves built-in and extension collisions" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const builtins = [_]BuiltinShortcutBinding{
        .{ .shortcut = "ctrl+c", .keybinding = "app.clear", .restrict_override = true },
        .{ .shortcut = "ctrl+v", .keybinding = "app.clipboard.pasteImage", .restrict_override = false },
    };

    try registry.registerShortcut("ctrl+c", "Reserved conflict", "reserved", "/tmp/reserved.ts");
    try registry.registerShortcut("ctrl+v", "Allowed built-in override", "paste", "/tmp/non-reserved.ts");
    try registry.registerShortcut("ctrl+shift+x", "First extension", "first", "/tmp/ext1.ts");
    try registry.registerShortcut("Ctrl+Shift+X", "Second extension", "second", "/tmp/ext2.ts");
    try registry.registerShortcut("ctrl+k", "Original same extension", "old", "/tmp/same.ts");
    try registry.registerShortcut("CTRL+K", "Replacement same extension", "new", "/tmp/same.ts");
    try registry.registerShortcut("ctrl+y", "No conflict", "free", "/tmp/free.ts");

    const resolution = try registry.resolveShortcuts(allocator, &builtins);
    defer {
        var mutable = resolution;
        mutable.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 4), resolution.shortcuts.len);
    try std.testing.expectEqualStrings("ctrl+v", resolution.shortcuts[0].shortcut);
    try std.testing.expectEqualStrings("/tmp/non-reserved.ts", resolution.shortcuts[0].extension_path);
    try std.testing.expectEqualStrings("Ctrl+Shift+X", resolution.shortcuts[1].shortcut);
    try std.testing.expectEqualStrings("second", resolution.shortcuts[1].command.?);
    try std.testing.expectEqualStrings("CTRL+K", resolution.shortcuts[2].shortcut);
    try std.testing.expectEqualStrings("new", resolution.shortcuts[2].command.?);
    try std.testing.expectEqualStrings("ctrl+y", resolution.shortcuts[3].shortcut);

    try std.testing.expectEqual(@as(usize, 3), resolution.diagnostics.len);
    try std.testing.expectEqualStrings("warning", resolution.diagnostics[0].type_name);
    try std.testing.expectEqualStrings("/tmp/reserved.ts", resolution.diagnostics[0].path);
    try std.testing.expectEqualStrings(
        "Extension shortcut 'ctrl+c' from /tmp/reserved.ts conflicts with built-in shortcut. Skipping.",
        resolution.diagnostics[0].message,
    );
    try std.testing.expectEqualStrings(
        "Extension shortcut conflict: 'ctrl+v' is built-in shortcut for app.clipboard.pasteImage and /tmp/non-reserved.ts. Using /tmp/non-reserved.ts.",
        resolution.diagnostics[1].message,
    );
    try std.testing.expectEqualStrings(
        "Extension shortcut conflict: 'Ctrl+Shift+X' registered by both /tmp/ext1.ts and /tmp/ext2.ts. Using /tmp/ext2.ts.",
        resolution.diagnostics[2].message,
    );
}

test "applyHostFrame supports register and unregister surfaces with malformed frame fallback" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "say", "label": "Say", "description": "Says hi", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command", "name": "say", "description": "Slash command", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+s", "description": "Trigger say", "command": "say", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_flag", "name": "plan", "valueType": "boolean", "default": true, "description": "Plan mode", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_flag", "name": "alias", "valueType": "string", "default": "claude", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_provider", "name": "fake-provider", "displayName": "Fake", "api": "openai-completions", "baseUrl": "http://localhost:0", "models": [{ "id": "fake-1", "name": "Fake 1" }, { "id": "fake-2", "name": "Fake 2" }], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_tool", "name": "say", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "unsupported_frame" }
        \\{ "type": "unregister_provider", "name": "fake-provider" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    // 6 distinct register_* frames + 1 re-register tool + 1 unregister
    // = 8 successful applies; the unsupported_frame is counted as
    // ignored.
    try std.testing.expectEqual(@as(usize, 8), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("say", registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 2), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
}

test "sub-agent reserved names cannot mutate generic registry namespaces" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try std.testing.expectError(error.ReservedSubAgentName, registry.registerTool("sub_agent.delegate", "Delegate", "spoofed", "/tmp/ext.ts"));
    try std.testing.expectError(error.ReservedSubAgentName, registry.registerCommand("sub-agent", "spoofed", "/tmp/ext.ts"));
    try std.testing.expectError(error.ReservedSubAgentName, registry.registerCapability("sub_agent.readiness", "status", "Readiness", null, null, null, "/tmp/ext.ts"));
    try std.testing.expectError(error.ReservedSubAgentName, registry.setWidgetHook("sub_agent.status", &.{"spoofed"}, .above_editor, "/tmp/ext.ts"));
    try std.testing.expectError(error.ReservedSubAgentName, registry.registerMessageRenderer("sub_agent.delegation.result", "/tmp/ext.ts"));

    const frames =
        \\{ "type": "register_tool", "name": "sub_agent.delegate", "label": "Delegate", "description": "spoofed", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command", "name": "sub-agent", "description": "spoofed", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_capability", "id": "sub_agent.readiness", "kind": "status", "title": "Readiness", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "sub_agent.status", "lines": ["spoofed"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_message_renderer", "customType": "sub_agent.delegation.result", "extensionPath": "/tmp/ext.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 0), applied);
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.widgets.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);
}

test "applyHostFrame replaces re-registered tool metadata for dynamic refresh" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const initial_frames =
        \\{ "type": "register_tool", "name": "greet", "label": "Greet", "description": "v1", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, initial_frames);
    try std.testing.expectEqualStrings("Greet", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("v1", registry.tools.items[0].description);

    // Simulate dynamic refresh: same tool name re-registered with new
    // metadata; registry refreshes in place without leaking stale
    // entries.
    const refresh_frames =
        \\{ "type": "register_tool", "name": "greet", "label": "Greet v2", "description": "v2", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, refresh_frames);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Greet v2", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("v2", registry.tools.items[0].description);
}

test "applyHostFrame ignores malformed JSON lines without aborting the stream" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\not-json
        \\{ "type": 42 }
        \\{ "type": "register_tool", "name": "say", "label": "Say", "description": "ok", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command" }
        \\
    ;
    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
}

const FIXTURE_REGISTRY_JSONL =
    \\{"type":"register_tool","name":"say-hello","label":"Say Hello","description":"Greets the world (fixture tool)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_command","name":"say-hello","description":"Slash command for say-hello","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_shortcut","shortcut":"ctrl+h","description":"Trigger say-hello","command":"say-hello","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_flag","name":"plan","valueType":"boolean","default":true,"description":"Enable plan mode (fixture flag)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_flag","name":"model-alias","valueType":"string","default":"claude-haiku","description":"Model alias override (fixture flag)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_provider","name":"fake-provider","displayName":"Fake Provider","api":"openai-completions","baseUrl":"http://localhost:0","models":[{"id":"fake-model-1","name":"Fake Model 1"},{"id":"fake-model-2","name":"Fake Model 2"}],"extensionPath":"registration-fixture/extension.ts"}
;

const FIXTURE_REFRESH_JSONL =
    \\{"type":"register_tool","name":"say-hello","label":"Say Hello v2","description":"Greets the world (refreshed)","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"register_tool","name":"new-tool","label":"New Tool","description":"Added on refresh","extensionPath":"registration-fixture/extension.ts"}
    \\{"type":"unregister_provider","name":"fake-provider"}
;

test "loadFromExtensionPaths reads registration fixture sidecar" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = "extension.ts";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ext_path, .data = "// extension stub" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "extension.ts.registry.jsonl", .data = FIXTURE_REGISTRY_JSONL });

    const tmp_relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        ext_path,
    });
    defer allocator.free(tmp_relative);

    var registry = Registry.init(allocator);
    defer registry.deinit();
    try loadFromExtensionPaths(&registry, std.testing.io, &.{tmp_relative});

    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("say-hello", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("Say Hello", registry.tools.items[0].label);

    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqualStrings("say-hello", registry.commands.items[0].name);

    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqualStrings("ctrl+h", registry.shortcuts.items[0].shortcut);
    try std.testing.expectEqualStrings("say-hello", registry.shortcuts.items[0].command.?);

    try std.testing.expectEqual(@as(usize, 2), registry.flags.items.len);
    try std.testing.expect(registry.flags.items[0].type_kind == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value == .boolean);
    try std.testing.expect(registry.flags.items[0].default_value.boolean);
    try std.testing.expect(registry.flags.items[1].type_kind == .string);
    try std.testing.expectEqualStrings("claude-haiku", registry.flags.items[1].default_value.string);

    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("fake-provider", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), registry.providers.items[0].models.len);
}

test "registration fixture refresh updates tools and removes provider" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    _ = try applyHostFrameStream(&registry, FIXTURE_REGISTRY_JSONL);

    // Sanity-check the initial state.
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Say Hello", registry.tools.items[0].label);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);

    // Simulate dynamic refresh by replaying the refresh JSONL frames
    // against the same registry. Existing tools refresh in place; a new
    // tool is added; the provider is unregistered.
    _ = try applyHostFrameStream(&registry, FIXTURE_REFRESH_JSONL);

    try std.testing.expectEqual(@as(usize, 2), registry.tools.items.len);
    try std.testing.expectEqualStrings("Say Hello v2", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("Greets the world (refreshed)", registry.tools.items[0].description);
    try std.testing.expectEqualStrings("new-tool", registry.tools.items[1].name);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
}

test "provider unregister and re-register ordering keeps only latest models" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_provider", "name": "dynamic-provider", "displayName": "Dynamic", "api": "openai-completions", "baseUrl": "http://localhost:0", "models": [{ "id": "first", "name": "First" }], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "unregister_provider", "name": "dynamic-provider" }
        \\{ "type": "register_provider", "name": "dynamic-provider", "displayName": "Dynamic", "api": "openai-completions", "baseUrl": "http://localhost:0", "models": [{ "id": "second", "name": "Second" }], "extensionPath": "/tmp/ext.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 3), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("dynamic-provider", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items[0].models.len);
    try std.testing.expectEqualStrings("second", registry.providers.items[0].models[0].id);
}

test "malformed provider registration is isolated from subsequent valid refresh frames" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_provider", "displayName": "Missing name", "models": [{ "id": "bad", "name": "Bad" }], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_tool", "name": "good-tool", "label": "Good Tool", "description": "ok", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_provider", "name": "good-provider", "displayName": "Good", "api": "openai-completions", "models": [{ "id": "good", "name": "Good" }], "extensionPath": "/tmp/ext.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("good-tool", registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("good-provider", registry.providers.items[0].name);
}

test "applyHostFrame records ui request ids for bridge correlation" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "extension_ui_request", "id": "ui-1", "method": "select" }
        \\{ "type": "extension_ui_request", "id": "ui-2", "method": "confirm" }
        \\{ "type": "extension_ui_request" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), registry.ui_request_ids.items.len);
    try std.testing.expectEqualStrings("ui-1", registry.ui_request_ids.items[0]);
    try std.testing.expectEqualStrings("ui-2", registry.ui_request_ids.items[1]);
}

test "applyHostFrame parses OAuth provider registration" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_provider", "name": "oauth-provider", "displayName": "OAuth Provider", "api": "openai-completions", "baseUrl": "https://api.oauth-provider.com", "models": [{ "id": "model-1", "name": "Model 1" }], "oauth": { "name": "OAuth Login" }, "authHeader": true, "extensionPath": "/tmp/oauth.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("oauth-provider", registry.providers.items[0].name);
    try std.testing.expect(registry.providers.items[0].oauth != null);
    try std.testing.expectEqualStrings("OAuth Login", registry.providers.items[0].oauth.?.name);
    try std.testing.expect(registry.providers.items[0].auth_header);
}

test "extension provider metadata parity preserves auth availability and default model shape" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_provider", "name": "api-provider", "displayName": "API Provider", "api": "openai-completions", "baseUrl": "https://api.provider.test/v1", "authHeader": true, "apiKeyConfigured": true, "models": [{ "id": "first-model", "name": "First Model" }, { "id": "second-model", "name": "Second Model" }], "extensionPath": "/tmp/api-provider.ts" }
        \\{ "type": "register_provider", "name": "oauth-provider", "displayName": "OAuth Provider", "api": "anthropic-messages", "baseUrl": "https://oauth.provider.test", "oauth": { "name": "OAuth Login" }, "models": [{ "id": "oauth-model", "name": "OAuth Model" }], "extensionPath": "/tmp/oauth-provider.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), applied);
    try std.testing.expectEqual(@as(usize, 2), registry.providers.items.len);

    const api_provider = registry.providers.items[0];
    try std.testing.expectEqualStrings("api-provider", api_provider.name);
    try std.testing.expectEqualStrings("API Provider", api_provider.display_name.?);
    try std.testing.expectEqualStrings("openai-completions", api_provider.api.?);
    try std.testing.expectEqualStrings("https://api.provider.test/v1", api_provider.base_url.?);
    try std.testing.expect(api_provider.auth_header);
    try std.testing.expect(api_provider.api_key_configured);
    try std.testing.expectEqual(@as(usize, 2), api_provider.models.len);
    try std.testing.expectEqualStrings("first-model", api_provider.models[0].id);
    try std.testing.expectEqualStrings("second-model", api_provider.models[1].id);

    const oauth_provider = registry.providers.items[1];
    try std.testing.expectEqualStrings("oauth-provider", oauth_provider.name);
    try std.testing.expect(oauth_provider.oauth != null);
    try std.testing.expectEqualStrings("OAuth Login", oauth_provider.oauth.?.name);
    try std.testing.expect(!oauth_provider.api_key_configured);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"providers\":[{\"name\":\"api-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"displayName\":\"API Provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"defaultModelId\":\"first-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"authHeader\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"apiKeyConfigured\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"credentialRequired\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"authType\":\"api_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"oauth-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"authType\":\"oauth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"oauth\":{\"name\":\"OAuth Login\"}") != null);
}

test "extension tool metadata parity preserves schema capability flags and registration order" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "alpha", "label": "Alpha", "description": "Alpha tool", "parameters": { "type": "object", "properties": { "path": { "type": "string", "description": "Path to inspect" }, "force": { "type": "boolean" } }, "required": ["path"], "additionalProperties": false }, "executionMode": "sequential", "renderShell": "self", "extensionPath": "/tmp/tools.ts" }
        \\{ "type": "register_tool", "name": "beta", "label": "Beta", "description": "Beta tool", "parameters": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }, "executionMode": "parallel", "extensionPath": "/tmp/tools.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), applied);
    try std.testing.expectEqual(@as(usize, 2), registry.tools.items.len);
    try std.testing.expectEqualStrings("alpha", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("beta", registry.tools.items[1].name);

    const alpha = registry.tools.items[0];
    try std.testing.expectEqualStrings("Alpha tool", alpha.description);
    try std.testing.expectEqualStrings("sequential", alpha.execution_mode.?);
    try std.testing.expectEqualStrings("self", alpha.render_shell.?);
    const alpha_schema = alpha.parameters.object;
    try std.testing.expectEqualStrings("object", alpha_schema.get("type").?.string);
    try std.testing.expect(!alpha_schema.get("additionalProperties").?.bool);
    const alpha_properties = alpha_schema.get("properties").?.object;
    try std.testing.expectEqualStrings("string", alpha_properties.get("path").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("Path to inspect", alpha_properties.get("path").?.object.get("description").?.string);
    try std.testing.expectEqualStrings("boolean", alpha_properties.get("force").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("path", alpha_schema.get("required").?.array.items[0].string);

    const beta = registry.tools.items[1];
    try std.testing.expectEqualStrings("parallel", beta.execution_mode.?);
    try std.testing.expect(beta.render_shell == null);
    try std.testing.expectEqualStrings("query", beta.parameters.object.get("required").?.array.items[0].string);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();
    const alpha_index = std.mem.indexOf(u8, snapshot, "\"name\":\"alpha\"") orelse return error.MissingAlphaTool;
    const beta_index = std.mem.indexOf(u8, snapshot, "\"name\":\"beta\"") orelse return error.MissingBetaTool;
    try std.testing.expect(alpha_index < beta_index);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"parameters\":{\"type\":\"object\",\"properties\":{\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"required\":[\"path\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"executionMode\":\"sequential\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"renderShell\":\"self\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"executionMode\":\"parallel\"") != null);
}

test "applyHostFrame handles resources_discover with skill/prompt/theme paths" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "resources_discover", "skillPaths": ["/path/to/skills", 42], "promptPaths": ["/path/to/prompts", false], "themePaths": ["/path/to/themes", null], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/another/skill"], "promptPaths": [13], "themePaths": ["theme-two"], "extensionPath": "/tmp/ext2.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), applied);
    try std.testing.expectEqual(@as(usize, 2), registry.resource_discoveries.items.len);

    const discovery1 = registry.resource_discoveries.items[0];
    try std.testing.expectEqualStrings("/tmp/ext.ts", discovery1.extension_path);
    try std.testing.expectEqual(@as(usize, 1), discovery1.skill_paths.items.len);
    try std.testing.expectEqualStrings("/path/to/skills", discovery1.skill_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), discovery1.prompt_paths.items.len);
    try std.testing.expectEqualStrings("/path/to/prompts", discovery1.prompt_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), discovery1.theme_paths.items.len);
    try std.testing.expectEqualStrings("/path/to/themes", discovery1.theme_paths.items[0]);

    const discovery2 = registry.resource_discoveries.items[1];
    try std.testing.expectEqualStrings("/tmp/ext2.ts", discovery2.extension_path);
    try std.testing.expectEqual(@as(usize, 1), discovery2.skill_paths.items.len);
    try std.testing.expectEqualStrings("/another/skill", discovery2.skill_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 0), discovery2.prompt_paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), discovery2.theme_paths.items.len);
    try std.testing.expectEqualStrings("theme-two", discovery2.theme_paths.items[0]);
}

test "Registry clearStaticRegistrationsForExtension removes only target static registrations" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const target = "/tmp/target.ts";
    const other = "/tmp/other.ts";

    try registry.registerTool("target-tool", "Target Tool", "target", target);
    try registry.registerTool("other-tool", "Other Tool", "other", other);
    try registry.registerCommand("target-command", "target", target);
    try registry.registerCommand("other-command", "other", other);
    try registry.registerShortcut("ctrl+t", "target", "target-command", target);
    try registry.registerShortcut("ctrl+o", "other", "other-command", other);
    try registry.registerFlag("target-flag", .boolean, "target", .{ .boolean = true }, target);
    try registry.registerFlag("other-flag", .string, "other", .{ .string = "kept" }, other);
    try registry.registerProvider("target-provider", "Target", null, "openai-completions", &.{.{ .id = "target-model", .name = "Target Model" }}, target);
    try registry.registerProvider("other-provider", "Other", null, "openai-completions", &.{.{ .id = "other-model", .name = "Other Model" }}, other);
    try registry.registerCapability("target-capability", "workflow", "Target", null, "target-command", "target/resource", target);
    try registry.registerCapability("other-capability", "workflow", "Other", null, "other-command", "other/resource", other);
    try registry.registerMessageRenderer("target-message", target);
    try registry.registerMessageRenderer("other-message", other);

    const lines = [_][]const u8{"UI hook"};
    try registry.setHeaderHook(&lines, target);
    try registry.setFooterHook(&lines, target);
    try registry.registerTerminalInput("target-input", true, "rewritten", target);
    try registry.setEditorComponentHook("target-editor", target);
    try registry.setWidgetHook("target-widget", &lines, .above_editor, target);
    try registry.recordUiRequest("ui-target");

    const discovery_frames =
        \\{ "type": "resources_discover", "skillPaths": ["/target/skills"], "promptPaths": ["/target/prompts"], "themePaths": ["/target/themes"], "extensionPath": "/tmp/target.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/other/skills"], "extensionPath": "/tmp/other.ts" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, discovery_frames);

    registry.clearStaticRegistrationsForExtension(target);

    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("other-tool", registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqualStrings("other-command", registry.commands.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqualStrings("ctrl+o", registry.shortcuts.items[0].shortcut);
    try std.testing.expectEqual(@as(usize, 1), registry.flags.items.len);
    try std.testing.expectEqualStrings("other-flag", registry.flags.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("other-provider", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqualStrings("other-capability", registry.capabilities.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("other-message", registry.message_renderers.items[0].custom_type);
    try std.testing.expectEqual(@as(usize, 1), registry.resource_discoveries.items.len);
    try std.testing.expectEqualStrings(other, registry.resource_discoveries.items[0].extension_path);

    try std.testing.expect(registry.header_hook != null);
    try std.testing.expectEqualStrings(target, registry.header_hook.?.extension_path);
    try std.testing.expect(registry.footer_hook != null);
    try std.testing.expectEqualStrings(target, registry.footer_hook.?.extension_path);
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);
    try std.testing.expectEqualStrings("target-input", registry.terminal_input_subs.items[0].id);
    try std.testing.expect(registry.editor_component_hook != null);
    try std.testing.expectEqualStrings("target-editor", registry.editor_component_hook.?.label);
    try std.testing.expectEqual(@as(usize, 1), registry.widgets.items.len);
    try std.testing.expectEqualStrings("target-widget", registry.widgets.items[0].key);
    try std.testing.expectEqual(@as(usize, 1), registry.ui_request_ids.items.len);
    try std.testing.expectEqualStrings("ui-target", registry.ui_request_ids.items[0]);

    registry.clearStaticRegistrationsForExtension(target);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.resource_discoveries.items.len);
}

test "clear_extension_registrations frame handles missing paths as no-op" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "tool", "label": "Tool", "description": "kept", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command", "name": "command", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+x", "command": "command", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_flag", "name": "flag", "valueType": "boolean", "default": true, "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_provider", "name": "provider", "models": [{ "id": "model", "name": "Model" }], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_capability", "id": "capability", "kind": "workflow", "title": "Capability", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_message_renderer", "customType": "message", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/skills"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "clear_extension_registrations", "extensionPath": "/tmp/missing.ts" }
        \\
    ;
    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 9), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.resource_discoveries.items.len);

    const cleared_frame =
        \\{ "type": "clear_extension_registrations", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    const cleared = try applyHostFrameStream(&registry, cleared_frame);
    try std.testing.expectEqual(@as(usize, 1), cleared);
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.resource_discoveries.items.len);
}

test "clear_extension_registrations frame matches direct cleanup semantics" {
    const allocator = std.testing.allocator;
    var direct = Registry.init(allocator);
    defer direct.deinit();
    var framed = Registry.init(allocator);
    defer framed.deinit();

    const seed_frames =
        \\{ "type": "register_tool", "name": "target-tool", "label": "Target", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_tool", "name": "other-tool", "label": "Other", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_command", "name": "target-command", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_command", "name": "other-command", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+t", "command": "target-command", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+o", "command": "other-command", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_flag", "name": "target-flag", "valueType": "boolean", "default": true, "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_flag", "name": "other-flag", "valueType": "string", "default": "other", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_provider", "name": "target-provider", "models": [{ "id": "target-model" }], "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_provider", "name": "other-provider", "models": [{ "id": "other-model" }], "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_capability", "id": "target-capability", "kind": "workflow", "title": "Target", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_capability", "id": "other-capability", "kind": "workflow", "title": "Other", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_message_renderer", "customType": "target-message", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_message_renderer", "customType": "other-message", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/target/skills"], "extensionPath": "/tmp/target.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/other/skills"], "extensionPath": "/tmp/other.ts" }
        \\
    ;
    _ = try applyHostFrameStream(&direct, seed_frames);
    _ = try applyHostFrameStream(&framed, seed_frames);

    direct.clearStaticRegistrationsForExtension("/tmp/target.ts");
    const clear_frame =
        \\{ "type": "clear_extension_registrations", "extensionPath": "/tmp/target.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try applyHostFrameStream(&framed, clear_frame));

    try std.testing.expectEqual(direct.tools.items.len, framed.tools.items.len);
    try std.testing.expectEqualStrings(direct.tools.items[0].name, framed.tools.items[0].name);
    try std.testing.expectEqual(direct.commands.items.len, framed.commands.items.len);
    try std.testing.expectEqualStrings(direct.commands.items[0].name, framed.commands.items[0].name);
    try std.testing.expectEqual(direct.shortcuts.items.len, framed.shortcuts.items.len);
    try std.testing.expectEqualStrings(direct.shortcuts.items[0].shortcut, framed.shortcuts.items[0].shortcut);
    try std.testing.expectEqual(direct.flags.items.len, framed.flags.items.len);
    try std.testing.expectEqualStrings(direct.flags.items[0].name, framed.flags.items[0].name);
    try std.testing.expectEqual(direct.providers.items.len, framed.providers.items.len);
    try std.testing.expectEqualStrings(direct.providers.items[0].name, framed.providers.items[0].name);
    try std.testing.expectEqual(direct.capabilities.items.len, framed.capabilities.items.len);
    try std.testing.expectEqualStrings(direct.capabilities.items[0].id, framed.capabilities.items[0].id);
    try std.testing.expectEqual(direct.message_renderers.items.len, framed.message_renderers.items.len);
    try std.testing.expectEqualStrings(direct.message_renderers.items[0].custom_type, framed.message_renderers.items[0].custom_type);
    try std.testing.expectEqual(direct.resource_discoveries.items.len, framed.resource_discoveries.items.len);
    try std.testing.expectEqualStrings(direct.resource_discoveries.items[0].extension_path, framed.resource_discoveries.items[0].extension_path);
}

test "unregister provider capability and message renderer frames are targeted no-ops for missing keys" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_provider", "name": "provider-a", "models": [{ "id": "model-a" }], "extensionPath": "/tmp/a.ts" }
        \\{ "type": "register_provider", "name": "provider-b", "models": [{ "id": "model-b" }], "extensionPath": "/tmp/b.ts" }
        \\{ "type": "register_capability", "id": "cap-a", "kind": "workflow", "title": "A", "extensionPath": "/tmp/a.ts" }
        \\{ "type": "register_capability", "id": "cap-b", "kind": "workflow", "title": "B", "extensionPath": "/tmp/b.ts" }
        \\{ "type": "register_message_renderer", "customType": "message-a", "extensionPath": "/tmp/a.ts" }
        \\{ "type": "register_message_renderer", "customType": "message-b", "extensionPath": "/tmp/b.ts" }
        \\{ "type": "unregister_provider", "name": "missing-provider" }
        \\{ "type": "unregister_capability", "id": "missing-cap" }
        \\{ "type": "unregister_message_renderer", "customType": "missing-message" }
        \\{ "type": "unregister_provider", "name": "provider-a" }
        \\{ "type": "unregister_capability", "id": "cap-a" }
        \\{ "type": "unregister_message_renderer", "customType": "message-a" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 12), try applyHostFrameStream(&registry, frames));
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("provider-b", registry.providers.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqualStrings("cap-b", registry.capabilities.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("message-b", registry.message_renderers.items[0].custom_type);
}

test "cross-extension collisions keep incumbent provenance for cleanup" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "same-tool", "label": "Target Tool", "description": "old", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_tool", "name": "same-tool", "label": "Other Tool", "description": "new", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_command", "name": "same-command", "description": "old", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_command", "name": "same-command", "description": "new", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+s", "description": "old", "command": "old", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+s", "description": "new", "command": "new", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_flag", "name": "same-flag", "valueType": "boolean", "default": false, "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_flag", "name": "same-flag", "valueType": "string", "default": "new", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_provider", "name": "same-provider", "models": [{ "id": "old" }], "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_provider", "name": "same-provider", "models": [{ "id": "new" }], "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_capability", "id": "same-capability", "kind": "workflow", "title": "Old", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_capability", "id": "same-capability", "kind": "workflow", "title": "New", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_message_renderer", "customType": "same-message", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_message_renderer", "customType": "same-message", "extensionPath": "/tmp/other.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 8), try applyHostFrameStream(&registry, frames));

    registry.clearStaticRegistrationsForExtension("/tmp/target.ts");
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.shortcuts.items.len);
    try std.testing.expectEqualStrings("new", registry.shortcuts.items[0].command.?);
    try std.testing.expectEqual(@as(usize, 0), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.collision_diagnostics.items.len);

    registry.clearStaticRegistrationsForExtension("/tmp/other.ts");
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);
}

test "cross-extension registry collisions preserve incumbent and diagnose deterministically" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "same-tool", "label": "Target Tool", "description": "first", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_tool", "name": "same-tool", "label": "Other Tool", "description": "second", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_command", "name": "same-command", "description": "first", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_command", "name": "same-command", "description": "second", "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_provider", "name": "same-provider", "models": [{ "id": "first" }], "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_provider", "name": "same-provider", "models": [{ "id": "second" }], "extensionPath": "/tmp/other.ts" }
        \\{ "type": "register_capability", "id": "same-capability", "kind": "workflow", "title": "First", "extensionPath": "/tmp/target.ts" }
        \\{ "type": "register_capability", "id": "same-capability", "kind": "workflow", "title": "Second", "extensionPath": "/tmp/other.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 4), try applyHostFrameStream(&registry, frames));

    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("Target Tool", registry.tools.items[0].label);
    try std.testing.expectEqualStrings("/tmp/target.ts", registry.tools.items[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqualStrings("first", registry.commands.items[0].description.?);
    try std.testing.expectEqualStrings("/tmp/target.ts", registry.commands.items[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("first", registry.providers.items[0].models[0].id);
    try std.testing.expectEqualStrings("/tmp/target.ts", registry.providers.items[0].extension_path);
    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqualStrings("First", registry.capabilities.items[0].title);
    try std.testing.expectEqualStrings("/tmp/target.ts", registry.capabilities.items[0].extension_path);
    try std.testing.expectEqual(@as(usize, 4), registry.collision_diagnostics.items.len);

    try std.testing.expectEqualStrings("tool", registry.collision_diagnostics.items[0].surface);
    try std.testing.expectEqualStrings("same-tool", registry.collision_diagnostics.items[0].id);
    try std.testing.expectEqualStrings("/tmp/target.ts", registry.collision_diagnostics.items[0].incumbent_extension_path);
    try std.testing.expectEqualStrings("/tmp/other.ts", registry.collision_diagnostics.items[0].rejected_extension_path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"collisionDiagnostics\":[{\"surface\":\"tool\",\"id\":\"same-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"surface\":\"command\",\"id\":\"same-command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"surface\":\"provider\",\"id\":\"same-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"surface\":\"capability\",\"id\":\"same-capability\"") != null);

    registry.clearStaticRegistrationsForExtension("/tmp/target.ts");
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.collision_diagnostics.items.len);
}

test "missing or non-string extensionPath has deterministic empty provenance" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_tool", "name": "empty-tool", "label": "Empty Tool" }
        \\{ "type": "register_command", "name": "empty-command", "extensionPath": 42 }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+e", "extensionPath": false }
        \\{ "type": "register_flag", "name": "empty-flag", "valueType": "boolean", "extensionPath": null }
        \\{ "type": "register_provider", "name": "empty-provider", "extensionPath": {} }
        \\{ "type": "register_capability", "id": "empty-capability", "kind": "workflow", "title": "Empty", "extensionPath": [] }
        \\{ "type": "register_message_renderer", "customType": "empty-message", "extensionPath": 42 }
        \\{ "type": "resources_discover", "skillPaths": ["/empty/skills"], "extensionPath": false }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 8), try applyHostFrameStream(&registry, frames));
    try std.testing.expectEqualStrings("", registry.tools.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.commands.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.shortcuts.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.flags.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.providers.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.capabilities.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.message_renderers.items[0].extension_path);
    try std.testing.expectEqualStrings("", registry.resource_discoveries.items[0].extension_path);

    registry.clearStaticRegistrationsForExtension("");
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.resource_discoveries.items.len);
}

test "malformed registry lifecycle frames do not partially mutate state" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const seed_frames =
        \\{ "type": "register_tool", "name": "tool", "label": "Tool", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_command", "name": "command", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+x", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_flag", "name": "flag", "valueType": "boolean", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_provider", "name": "provider", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_capability", "id": "capability", "kind": "workflow", "title": "Capability", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "register_message_renderer", "customType": "message", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/skills"], "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 8), try applyHostFrameStream(&registry, seed_frames));

    const before_counts = .{
        .tools = registry.tools.items.len,
        .commands = registry.commands.items.len,
        .shortcuts = registry.shortcuts.items.len,
        .flags = registry.flags.items.len,
        .providers = registry.providers.items.len,
        .capabilities = registry.capabilities.items.len,
        .message_renderers = registry.message_renderers.items.len,
        .resource_discoveries = registry.resource_discoveries.items.len,
    };

    const malformed_frames =
        \\{ "type": "register_tool", "label": "missing name", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "register_command", "description": "missing name", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "register_shortcut", "description": "missing shortcut", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "register_flag", "name": "bad-flag", "valueType": "number", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "register_capability", "id": "bad-capability", "kind": "workflow", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "register_message_renderer", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "unregister_provider", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "unregister_capability", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "unregister_message_renderer", "extensionPath": "/tmp/bad.ts" }
        \\{ "type": "clear_extension_registrations" }
        \\{ "type": "clear_extension_registrations", "extensionPath": 42 }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try applyHostFrameStream(&registry, malformed_frames));

    try std.testing.expectEqual(before_counts.tools, registry.tools.items.len);
    try std.testing.expectEqual(before_counts.commands, registry.commands.items.len);
    try std.testing.expectEqual(before_counts.shortcuts, registry.shortcuts.items.len);
    try std.testing.expectEqual(before_counts.flags, registry.flags.items.len);
    try std.testing.expectEqual(before_counts.providers, registry.providers.items.len);
    try std.testing.expectEqual(before_counts.capabilities, registry.capabilities.items.len);
    try std.testing.expectEqual(before_counts.message_renderers, registry.message_renderers.items.len);
    try std.testing.expectEqual(before_counts.resource_discoveries, registry.resource_discoveries.items.len);
    try std.testing.expectEqualStrings("tool", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("provider", registry.providers.items[0].name);
    try std.testing.expectEqualStrings("capability", registry.capabilities.items[0].id);
    try std.testing.expectEqualStrings("message", registry.message_renderers.items[0].custom_type);
}

test "registerProvider with OAuth round-trips" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var oauth = ProviderOAuth{
        .name = try allocator.dupe(u8, "Test OAuth"),
    };
    defer oauth.deinit(allocator);

    try registry.registerProviderFull(
        "test-oauth",
        "Test Provider",
        "https://api.test.com",
        "openai-completions",
        &.{.{ .id = "test-model", .name = "Test Model" }},
        "/tmp/test.ts",
        oauth,
        null,
        true,
    );

    try std.testing.expectEqual(@as(usize, 1), registry.providers.items.len);
    try std.testing.expectEqualStrings("test-oauth", registry.providers.items[0].name);
    try std.testing.expect(registry.providers.items[0].oauth != null);
    try std.testing.expectEqualStrings("Test OAuth", registry.providers.items[0].oauth.?.name);
    try std.testing.expect(registry.providers.items[0].auth_header);
}

test "applyHostFrame handles set_widget and clear_widget" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "set_widget", "key": "status", "lines": ["Line 1", "Line 2"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "status", "lines": ["Updated"], "placement": "belowEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "other", "lines": ["Other widget"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "clear_widget", "key": "other", "extensionPath": "/tmp/ext.ts" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 4), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.widgets.items.len);
    try std.testing.expectEqualStrings("status", registry.widgets.items[0].key);
    try std.testing.expectEqualStrings("Updated", registry.widgets.items[0].lines[0]);
    try std.testing.expect(registry.widgets.items[0].placement == .below_editor);
}

test "Registry clearUiHooksForReload drops widgets" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const lines = [_][]const u8{"Widget line"};
    try registry.setWidgetHook("test", &lines, .above_editor, "/tmp/ext.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.widgets.items.len);

    registry.clearUiHooksForReload();
    try std.testing.expectEqual(@as(usize, 0), registry.widgets.items.len);
}

test "extension registry conformance helper snapshots every supported surface" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const surface_names = registrySurfaceNames();
    try std.testing.expectEqual(@as(usize, 16), surface_names.len);
    try std.testing.expectEqualStrings("tools", surface_names[0]);
    try std.testing.expectEqualStrings("uiRequestIds", surface_names[surface_names.len - 1]);

    const frames =
        \\{ "type": "register_tool", "name": "tool", "label": "Tool", "description": "Tool desc", "parameters": { "type": "object" }, "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_command", "name": "command", "description": "Command desc", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_shortcut", "shortcut": "ctrl+f", "command": "command", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_flag", "name": "flag", "valueType": "string", "default": "default", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_provider", "name": "provider", "models": [{ "id": "model", "name": "Model" }], "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_capability", "id": "capability", "kind": "workflow", "title": "Capability", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_workflow", "id": "review-flow", "description": "Review workflow", "inputSchema": { "type": "object" }, "outputSchema": { "type": "object" }, "exposure": { "command": { "name": "review-flow" }, "tool": { "name": "workflow.review" }, "subAgentPreset": { "id": "review-agent" } }, "childAgentLimits": { "maxChildren": 1, "maxTurns": 2, "timeoutMs": 1000 }, "extensionPath": "/tmp/full.ts" }
        \\{ "type": "resources_discover", "skillPaths": ["/skills"], "promptPaths": ["/prompts"], "themePaths": ["/themes"], "extensionPath": "/tmp/full.ts" }
        \\{ "type": "set_header", "lines": ["Header"], "extensionPath": "/tmp/full.ts" }
        \\{ "type": "set_footer", "lines": ["Footer"], "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_terminal_input", "id": "terminal", "consume": false, "transformTo": "rewritten", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "set_editor_component", "label": "Editor", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "set_widget", "key": "widget", "lines": ["Widget"], "placement": "belowEditor", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_hook", "event": "before_agent_start", "priority": -10, "declarationOrder": 7, "errorPolicy": "fatal", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "register_message_renderer", "customType": "custom", "extensionPath": "/tmp/full.ts" }
        \\{ "type": "extension_ui_request", "id": "ui-request" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 15), try applyHostFrameStream(&registry, frames));

    const counts = registrySurfaceCounts(&registry);
    try std.testing.expectEqual(@as(usize, 2), counts.tools);
    try std.testing.expectEqual(@as(usize, 2), counts.commands);
    try std.testing.expectEqual(@as(usize, 1), counts.shortcuts);
    try std.testing.expectEqual(@as(usize, 1), counts.flags);
    try std.testing.expectEqual(@as(usize, 1), counts.providers);
    try std.testing.expectEqual(@as(usize, 2), counts.capabilities);
    try std.testing.expectEqual(@as(usize, 1), counts.workflows);
    try std.testing.expectEqual(@as(usize, 1), counts.resource_discoveries);
    try std.testing.expectEqual(@as(usize, 1), counts.header_hooks);
    try std.testing.expectEqual(@as(usize, 1), counts.footer_hooks);
    try std.testing.expectEqual(@as(usize, 1), counts.terminal_input_subscriptions);
    try std.testing.expectEqual(@as(usize, 1), counts.editor_component_hooks);
    try std.testing.expectEqual(@as(usize, 1), counts.widgets);
    try std.testing.expectEqual(@as(usize, 1), counts.hooks);
    try std.testing.expectEqual(@as(usize, 1), counts.message_renderers);
    try std.testing.expectEqual(@as(usize, 1), counts.ui_request_ids);

    _ = try registry.setFlagValue("flag", .{ .string = "cli" });
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"resourceDiscoveries\":[{\"extensionPath\":\"/tmp/full.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflows\":[{\"id\":\"review-flow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"subAgentPresets\":[{\"id\":\"review-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"workflow.review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"widgets\":[{\"key\":\"widget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"placement\":\"belowEditor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"hooks\":[{\"eventName\":\"before_agent_start\",\"extensionPath\":\"/tmp/full.ts\",\"priority\":-10,\"declarationOrder\":7,\"errorPolicy\":\"fatal\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"value\":\"cli\"") != null);
}

test "workflow registry surfaces expose validated commands tools and sub-agent presets" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_workflow", "id": "triage", "description": "Triage issue", "inputSchema": { "type": "object", "properties": { "issue": { "type": "string" } }, "required": ["issue"] }, "outputSchema": { "type": "object" }, "permissions": ["session.read"], "dependencies": [{ "id": "cap.issue" }], "timeoutMs": 1500, "replay": { "enabled": true, "mode": "recorded" }, "childAgentLimits": { "maxChildren": 1, "maxTurns": 3, "maxToolCalls": 2, "timeoutMs": 1500 }, "exposure": { "command": { "name": "triage" }, "tool": { "name": "workflow.triage" }, "subAgentPreset": { "id": "triage-agent" } }, "extensionPath": "/tmp/workflows.ts" }
        \\{ "type": "register_workflow", "id": "denied", "description": "Denied", "exposure": { "command": { "name": "denied", "policy": { "approved": false } }, "tool": false, "subAgentPreset": false }, "extensionPath": "/tmp/workflows.ts" }
        \\{ "type": "register_workflow", "id": "denied-direct", "description": "Denied direct", "denied": true, "commandName": "denied-direct", "toolName": "workflow.denied-direct", "presetId": "denied-direct-agent", "extensionPath": "/tmp/workflows.ts" }
        \\{ "type": "register_workflow", "id": "permission-denied", "description": "Permission denied", "permissions": [{ "id": "session.write", "policy": { "approved": false } }], "commandName": "permission-denied", "toolName": "workflow.permission-denied", "presetId": "permission-denied-agent", "extensionPath": "/tmp/workflows.ts" }
        \\{ "type": "register_workflow", "id": "direct-surface-denied", "description": "Direct surface denied", "commandName": "direct-command", "toolName": "workflow.direct-tool", "presetId": "direct-preset", "exposure": { "command": { "policy": { "decision": "deny" } }, "tool": { "policyDenied": true }, "subAgentPreset": false }, "extensionPath": "/tmp/workflows.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 5), try applyHostFrameStream(&registry, frames));

    try std.testing.expectEqual(@as(usize, 5), registry.workflows.items.len);
    try std.testing.expect(registry.hasCommandInvocation("triage"));
    try std.testing.expect(!registry.hasCommandInvocation("denied"));
    try std.testing.expect(!registry.hasCommandInvocation("denied-direct"));
    try std.testing.expect(!registry.hasCommandInvocation("permission-denied"));
    try std.testing.expect(!registry.hasCommandInvocation("direct-command"));
    try std.testing.expectEqual(@as(?usize, 0), registry.findCapabilityIndex("triage"));
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings("workflow.triage", registry.tools.items[0].name);
    try std.testing.expectEqualStrings("issue", registry.tools.items[0].parameters.object.get("required").?.array.items[0].string);
    try std.testing.expect(registry.workflowForCommandName("triage") != null);
    try std.testing.expect(registry.workflowForToolName("workflow.triage") != null);
    try std.testing.expect(registry.workflowForPresetId("triage-agent") != null);
    try std.testing.expect(registry.workflowForCommandName("denied-direct") == null);
    try std.testing.expect(registry.workflowForToolName("workflow.denied-direct") == null);
    try std.testing.expect(registry.workflowForPresetId("permission-denied-agent") == null);
    try std.testing.expect(registry.workflowForCommandName("direct-command") == null);
    try std.testing.expect(registry.workflowForToolName("workflow.direct-tool") == null);
    try std.testing.expect(registry.workflowForPresetId("direct-preset") == null);
    try std.testing.expect(registry.workflow_surface_diagnostics.items.len >= 6);
    try std.testing.expectEqualStrings("workflow.surface_denied", registry.workflow_surface_diagnostics.items[0].code);
    try std.testing.expectEqualStrings("denied", registry.workflow_surface_diagnostics.items[0].workflow_id);
    try std.testing.expectEqualStrings("command", registry.workflow_surface_diagnostics.items[0].surface);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflows\":[{\"id\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"commandName\":\"triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"toolName\":\"workflow.triage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"subAgentPresets\":[{\"id\":\"triage-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"maxTurns\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"commandName\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"toolName\":\"workflow.denied-direct\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"presetId\":\"permission-denied-agent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"toolName\":\"workflow.direct-tool\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflowDiagnostics\":[{\"code\":\"workflow.surface_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"workflowId\":\"direct-surface-denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"surface\":\"tool\"") != null);

    const unregister_denied =
        \\{ "type": "unregister_workflow", "id": "denied" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 1), try applyHostFrameStream(&registry, unregister_denied));
    for (registry.workflow_surface_diagnostics.items) |diagnostic| {
        try std.testing.expect(!std.mem.eql(u8, diagnostic.workflow_id, "denied"));
    }
}

test "register_hook metadata preserves ordering and error policy" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_hook", "event": "message_end", "priority": 20, "declarationOrder": 4, "errorPolicy": "continue", "extensionPath": "/tmp/later.ts" }
        \\{ "type": "register_hook", "eventName": "before_agent_start", "priority": -1, "declaration_order": 2, "fatal": true, "extensionPath": "/tmp/startup.ts" }
        \\{ "type": "register_hook", "event": "turn_end", "extensionPath": "/tmp/default.ts" }
        \\
    ;
    try std.testing.expectEqual(@as(usize, 3), try applyHostFrameStream(&registry, frames));
    try std.testing.expectEqual(@as(usize, 3), registry.hooks.items.len);

    try std.testing.expectEqualStrings("message_end", registry.hooks.items[0].event_name);
    try std.testing.expectEqual(@as(i64, 20), registry.hooks.items[0].priority);
    try std.testing.expectEqual(@as(usize, 4), registry.hooks.items[0].declaration_order);
    try std.testing.expectEqual(HookErrorPolicy.@"continue", registry.hooks.items[0].error_policy);

    try std.testing.expectEqualStrings("before_agent_start", registry.hooks.items[1].event_name);
    try std.testing.expectEqual(@as(i64, -1), registry.hooks.items[1].priority);
    try std.testing.expectEqual(@as(usize, 2), registry.hooks.items[1].declaration_order);
    try std.testing.expectEqual(HookErrorPolicy.fatal, registry.hooks.items[1].error_policy);
    try std.testing.expectEqual(HookErrorPolicy.fatal, registry.hookErrorPolicyForEvent("before_agent_start"));

    try std.testing.expectEqualStrings("turn_end", registry.hooks.items[2].event_name);
    try std.testing.expectEqual(@as(i64, 0), registry.hooks.items[2].priority);
    try std.testing.expectEqual(@as(usize, 2), registry.hooks.items[2].declaration_order);
    try std.testing.expectEqual(HookErrorPolicy.@"continue", registry.hooks.items[2].error_policy);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"eventName\":\"message_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"priority\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"declarationOrder\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"errorPolicy\":\"continue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"errorPolicy\":\"fatal\"") != null);
}

// --------------------------------------------------------------------------
// M11 extension UI hooks tests
// --------------------------------------------------------------------------

test "M11 setHeaderHook and setFooterHook are single-slot and replaceable" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const v1 = [_][]const u8{ "Header v1 line 1", "Header v1 line 2" };
    try registry.setHeaderHook(&v1, "fixture/extension.ts");
    try std.testing.expect(registry.header_hook != null);
    try std.testing.expectEqual(@as(usize, 2), registry.header_hook.?.lines.len);
    try std.testing.expectEqualStrings("Header v1 line 1", registry.header_hook.?.lines[0]);

    // Replace; previous hook bytes are freed and the new content wins.
    const v2 = [_][]const u8{"Header v2 only line"};
    try registry.setHeaderHook(&v2, "fixture/extension.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.header_hook.?.lines.len);
    try std.testing.expectEqualStrings("Header v2 only line", registry.header_hook.?.lines[0]);

    // Footer mirrors the header API.
    const f1 = [_][]const u8{ "Footer A", "Footer B" };
    try registry.setFooterHook(&f1, "fixture/extension.ts");
    try std.testing.expect(registry.footer_hook != null);
    try std.testing.expectEqualStrings("Footer A", registry.footer_hook.?.lines[0]);

    // Clearing returns true the first time and false the second.
    try std.testing.expect(registry.clearHeaderHook());
    try std.testing.expect(!registry.clearHeaderHook());
    try std.testing.expect(registry.clearFooterHook());
    try std.testing.expect(!registry.clearFooterHook());
}

test "M11 terminal input subscriptions support consume / transform / unsubscribe" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Pure observer (no consume, no transform) leaves bytes intact.
    try registry.registerTerminalInput("observer", false, null, "fixture/extension.ts");

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);
    var result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("hello", result.data);

    // Transform handler rewrites bytes.
    try registry.registerTerminalInput("transform", false, "world", "fixture/extension.ts");
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("world", result.data);

    // Consume handler stops propagation.
    try registry.registerTerminalInput("consumer", true, null, "fixture/extension.ts");
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(result.consumed);

    // Unsubscribing the consumer restores propagation through the
    // remaining transform handler.
    try std.testing.expect(registry.unregisterTerminalInput("consumer"));
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("world", result.data);

    // Unsubscribing the transform handler returns to the original
    // observer-only behavior.
    try std.testing.expect(registry.unregisterTerminalInput("transform"));
    result = try registry.applyTerminalInput("hello", &scratch);
    try std.testing.expect(!result.consumed);
    try std.testing.expectEqualStrings("hello", result.data);

    // Unsubscribe returns false for an unknown id and the registry is
    // left intact.
    try std.testing.expect(!registry.unregisterTerminalInput("does-not-exist"));
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);
}

test "M11 setEditorComponentHook is single-slot and clearable" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.setEditorComponentHook("VimEditor", "fixture/extension.ts");
    try std.testing.expect(registry.editor_component_hook != null);
    try std.testing.expectEqualStrings("VimEditor", registry.editor_component_hook.?.label);

    try registry.setEditorComponentHook("EmacsEditor", "fixture/extension.ts");
    try std.testing.expectEqualStrings("EmacsEditor", registry.editor_component_hook.?.label);

    try std.testing.expect(registry.clearEditorComponentHook());
    try std.testing.expect(!registry.clearEditorComponentHook());
    try std.testing.expect(registry.editor_component_hook == null);
}

test "M11 clearUiHooksForReload drops UI hooks but keeps static registrations" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Static surfaces.
    try registry.registerTool("greet", "Greet", "Greets", "fixture/extension.ts");
    try registry.registerCommand("greet", "Slash command", "fixture/extension.ts");
    try registry.registerFlag("plan", .boolean, null, .{ .boolean = true }, "fixture/extension.ts");

    // UI hooks.
    const lines = [_][]const u8{"Header"};
    try registry.setHeaderHook(&lines, "fixture/extension.ts");
    try registry.setFooterHook(&lines, "fixture/extension.ts");
    try registry.registerTerminalInput("sub-1", true, null, "fixture/extension.ts");
    try registry.setEditorComponentHook("VimEditor", "fixture/extension.ts");

    registry.clearUiHooksForReload();

    // Hooks gone.
    try std.testing.expect(registry.header_hook == null);
    try std.testing.expect(registry.footer_hook == null);
    try std.testing.expectEqual(@as(usize, 0), registry.terminal_input_subs.items.len);
    try std.testing.expect(registry.editor_component_hook == null);

    // Static registrations preserved.
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.flags.items.len);
}

test "M11 applyHostFrameStream covers UI hook frame types end-to-end" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "set_header", "lines": ["Header line A", "Header line B"], "extensionPath": "fixture/extension.ts" }
        \\{ "type": "set_footer", "lines": ["Footer line"], "extensionPath": "fixture/extension.ts" }
        \\{ "type": "register_terminal_input", "id": "consumer", "consume": true, "extensionPath": "fixture/extension.ts" }
        \\{ "type": "register_terminal_input", "id": "transform", "consume": false, "transformTo": "rewritten", "extensionPath": "fixture/extension.ts" }
        \\{ "type": "set_editor_component", "label": "VimEditor", "extensionPath": "fixture/extension.ts" }
        \\
    ;
    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 5), applied);

    try std.testing.expect(registry.header_hook != null);
    try std.testing.expectEqualStrings("Header line A", registry.header_hook.?.lines[0]);
    try std.testing.expect(registry.footer_hook != null);
    try std.testing.expectEqual(@as(usize, 2), registry.terminal_input_subs.items.len);
    try std.testing.expect(registry.editor_component_hook != null);
    try std.testing.expectEqualStrings("VimEditor", registry.editor_component_hook.?.label);

    // Removing one terminal input subscription via JSONL.
    const remove_frame =
        \\{ "type": "unregister_terminal_input", "id": "consumer" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, remove_frame);
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);
    try std.testing.expectEqualStrings("transform", registry.terminal_input_subs.items[0].id);

    // clear_header / clear_footer / clear_editor_component frames.
    const clear_frames =
        \\{ "type": "clear_header" }
        \\{ "type": "clear_footer" }
        \\{ "type": "clear_editor_component" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, clear_frames);
    try std.testing.expect(registry.header_hook == null);
    try std.testing.expect(registry.footer_hook == null);
    try std.testing.expect(registry.editor_component_hook == null);
    // Static surfaces and the surviving subscription remain.
    try std.testing.expectEqual(@as(usize, 1), registry.terminal_input_subs.items.len);

    // clear_ui_hooks_for_reload drops the surviving subscription too.
    const reload_frame =
        \\{ "type": "clear_ui_hooks_for_reload" }
        \\
    ;
    _ = try applyHostFrameStream(&registry, reload_frame);
    try std.testing.expectEqual(@as(usize, 0), registry.terminal_input_subs.items.len);
}

test "M11 snapshot JSON includes UI hook state" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const lines = [_][]const u8{ "Header A", "Header B" };
    const single_line = [_][]const u8{"Header A"};
    try registry.setHeaderHook(&lines, "fixture/extension.ts");
    try registry.setFooterHook(&single_line, "fixture/extension.ts");
    try registry.registerTerminalInput("consumer", true, null, "fixture/extension.ts");
    try registry.registerTerminalInput("transform", false, "rewritten", "fixture/extension.ts");
    try registry.setEditorComponentHook("VimEditor", "fixture/extension.ts");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);

    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"headerHook\":{\"lines\":[\"Header A\",\"Header B\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"footerHook\":{\"lines\":[\"Header A\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"terminalInputSubscriptions\":[{\"id\":\"consumer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"transformTo\":\"rewritten\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"editorComponentHook\":{\"label\":\"VimEditor\"") != null);

    // After clearUiHooksForReload, the snapshot reflects empty hooks.
    registry.clearUiHooksForReload();
    var out2: std.Io.Writer.Allocating = .init(allocator);
    defer out2.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out2.writer);
    const snapshot2 = out2.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"headerHook\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"footerHook\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"terminalInputSubscriptions\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot2, "\"editorComponentHook\":null") != null);
}

// --------------------------------------------------------------------------
// capability registry tests
// --------------------------------------------------------------------------

test "registry can register capability" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerCapability("cap-wiki", "wiki", "Wiki", "Browse project wiki", "wiki", "skills/wiki", "/tmp/ext.ts");

    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqualStrings("cap-wiki", registry.capabilities.items[0].id);
    try std.testing.expectEqualStrings("wiki", registry.capabilities.items[0].kind);
    try std.testing.expectEqualStrings("Wiki", registry.capabilities.items[0].title);
    try std.testing.expectEqualStrings("Browse project wiki", registry.capabilities.items[0].description);
    try std.testing.expectEqualStrings("wiki", registry.capabilities.items[0].command.?);
    try std.testing.expectEqualStrings("skills/wiki", registry.capabilities.items[0].resource_path.?);
    try std.testing.expectEqualStrings("/tmp/ext.ts", registry.capabilities.items[0].extension_path);
    try std.testing.expectEqual(@as(?usize, 0), registry.findCapabilityIndex("cap-wiki"));
}

test "same-extension duplicate capability id replaces old metadata" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerCapability("cap-1", "workflow", "Old", "old description", "old", "old/path", "/tmp/old.ts");
    try registry.registerCapability("cap-2", "qa", "QA", null, null, null, "/tmp/qa.ts");
    try registry.registerCapability("cap-1", "review", "New", "new description", "new", "new/path", "/tmp/old.ts");

    try std.testing.expectEqual(@as(usize, 2), registry.capabilities.items.len);
    try std.testing.expectEqualStrings("cap-1", registry.capabilities.items[0].id);
    try std.testing.expectEqualStrings("review", registry.capabilities.items[0].kind);
    try std.testing.expectEqualStrings("New", registry.capabilities.items[0].title);
    try std.testing.expectEqualStrings("new description", registry.capabilities.items[0].description);
    try std.testing.expectEqualStrings("new", registry.capabilities.items[0].command.?);
    try std.testing.expectEqualStrings("new/path", registry.capabilities.items[0].resource_path.?);
    try std.testing.expectEqualStrings("/tmp/old.ts", registry.capabilities.items[0].extension_path);
    try std.testing.expectEqualStrings("cap-2", registry.capabilities.items[1].id);
}

test "unregister capability removes and returns correct bool" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerCapability("cap-1", "workflow", "Workflow", null, null, null, "/tmp/ext.ts");
    try registry.registerCapability("cap-2", "mission", "Mission", null, null, null, "/tmp/ext.ts");

    try std.testing.expect(registry.unregisterCapability("cap-1"));
    try std.testing.expectEqual(@as(usize, 1), registry.capabilities.items.len);
    try std.testing.expectEqualStrings("cap-2", registry.capabilities.items[0].id);
    try std.testing.expect(!registry.unregisterCapability("cap-1"));
    try std.testing.expect(!registry.unregisterCapability("missing"));
}

test "snapshot JSON includes capabilities with optional fields" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerCapability("cap-1", "workflow", "Workflow", "Runs workflow", "workflow", "skills/workflow", "/tmp/workflow.ts");
    try registry.registerCapability("cap-2", "shield", "Shield", null, null, null, "/tmp/shield.ts");

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);

    const snapshot = out.written();
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"capabilities\":[{\"id\":\"cap-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"title\":\"Workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"description\":\"Runs workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"command\":\"workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"resourcePath\":\"skills/workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"extensionPath\":\"/tmp/workflow.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "{\"id\":\"cap-2\",\"kind\":\"shield\",\"title\":\"Shield\",\"description\":\"\",\"command\":null,\"resourcePath\":null,\"extensionPath\":\"/tmp/shield.ts\"}") != null);
}

test "malformed register_capability is ignored" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_capability", "kind": "wiki", "title": "Wiki" }
        \\{ "type": "register_capability", "id": "cap-wiki", "title": "Wiki" }
        \\{ "type": "register_capability", "id": "cap-wiki", "kind": "wiki" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 0), applied);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
}

test "applyHostFrame supports register_capability and unregister_capability" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const frames =
        \\{ "type": "register_capability", "id": "cap-review", "kind": "review", "title": "Review", "description": "Code review", "command": "review", "resourcePath": "skills/review", "extensionPath": "/tmp/review.ts" }
        \\{ "type": "unregister_capability", "id": "cap-review" }
        \\
    ;

    const applied = try applyHostFrameStream(&registry, frames);
    try std.testing.expectEqual(@as(usize, 2), applied);
    try std.testing.expectEqual(@as(usize, 0), registry.capabilities.items.len);
}

// --------------------------------------------------------------------------
// message_renderer tests
// --------------------------------------------------------------------------

test "registerMessageRenderer stores renderer keyed by customType" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerMessageRenderer("my-type", "/tmp/ext.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("my-type", registry.message_renderers.items[0].custom_type);
    try std.testing.expectEqualStrings("/tmp/ext.ts", registry.message_renderers.items[0].extension_path);

    // Re-registering the same customType replaces the existing entry.
    try registry.registerMessageRenderer("my-type", "/tmp/ext.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("/tmp/ext.ts", registry.message_renderers.items[0].extension_path);

    // Registering a different customType adds a new entry.
    try registry.registerMessageRenderer("other-type", "/tmp/ext3.ts");
    try std.testing.expectEqual(@as(usize, 2), registry.message_renderers.items.len);
}

test "unregisterMessageRenderer removes renderer and returns correct bool" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerMessageRenderer("my-type", "/tmp/ext.ts");
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);

    // First unregister returns true and removes the entry.
    try std.testing.expect(registry.unregisterMessageRenderer("my-type"));
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);

    // Second unregister returns false (not found).
    try std.testing.expect(!registry.unregisterMessageRenderer("my-type"));
}

test "findMessageRenderer returns renderer or null" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Not found before registration.
    try std.testing.expect(registry.findMessageRenderer("my-type") == null);

    try registry.registerMessageRenderer("my-type", "/tmp/ext.ts");
    const found = registry.findMessageRenderer("my-type");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("my-type", found.?.custom_type);
    try std.testing.expectEqualStrings("/tmp/ext.ts", found.?.extension_path);

    // Lookup for unregistered type returns null.
    try std.testing.expect(registry.findMessageRenderer("other-type") == null);
}

test "registry snapshot includes messageRenderers array" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Empty registry snapshot must have an empty messageRenderers array.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"messageRenderers\":[]") != null);

    // After registration, the array must contain the entry.
    try registry.registerMessageRenderer("my-type", "/tmp/ext.ts");
    var out2: std.Io.Writer.Allocating = .init(allocator);
    defer out2.deinit();
    try writeRegistrySnapshotJson(allocator, &registry, &out2.writer);
    const snap = out2.written();
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"messageRenderers\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"customType\":\"my-type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"extensionPath\":\"/tmp/ext.ts\"") != null);
}

test "applyHostFrame handles register_message_renderer and unregister_message_renderer JSONL frames" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const register_frame =
        \\{ "type": "register_message_renderer", "customType": "my-type", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    const applied = try applyHostFrameStream(&registry, register_frame);
    try std.testing.expectEqual(@as(usize, 1), applied);
    try std.testing.expectEqual(@as(usize, 1), registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("my-type", registry.message_renderers.items[0].custom_type);

    const unregister_frame =
        \\{ "type": "unregister_message_renderer", "customType": "my-type" }
        \\
    ;
    const applied2 = try applyHostFrameStream(&registry, unregister_frame);
    try std.testing.expectEqual(@as(usize, 1), applied2);
    try std.testing.expectEqual(@as(usize, 0), registry.message_renderers.items.len);

    // Missing customType returns ignored_malformed (not counted).
    const malformed_frame =
        \\{ "type": "register_message_renderer", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    const applied3 = try applyHostFrameStream(&registry, malformed_frame);
    try std.testing.expectEqual(@as(usize, 0), applied3);
}

test "MessageRenderer deinit frees all owned allocations (leak detection)" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.registerMessageRenderer("leak-type", "/tmp/leak.ts");
    try registry.registerMessageRenderer("other-type", "/tmp/other.ts");
    try std.testing.expectEqual(@as(usize, 2), registry.message_renderers.items.len);
    // deinit is called by defer above; std.testing.allocator will fail the
    // test if any allocations are leaked.
}
