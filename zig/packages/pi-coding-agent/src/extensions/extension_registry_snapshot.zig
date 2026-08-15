const std = @import("std");
const common = @import("../tools/common.zig");

/// Render a deterministic JSON snapshot of the registry to `writer` for
/// CLI/TS-RPC observability. The snapshot includes tools/labels/
/// descriptions, commands/descriptions, shortcuts, flag definitions
/// with parsed CLI values resolved through `getFlag()`, providers +
/// models, and the captured UI request ids. Order is registration
/// order to match the underlying ArrayList storage and the
/// TypeScript listing order.
pub fn writeRegistrySnapshotJson(
    allocator: std.mem.Allocator,
    registry: anytype,
    writer: *std.Io.Writer,
) !void {
    const value = try buildRegistryJsonValue(allocator, registry);
    defer common.deinitJsonValue(allocator, value);
    try std.json.Stringify.value(value, .{}, writer);
}

pub fn buildRegistryJsonValue(allocator: std.mem.Allocator, registry: anytype) !std.json.Value {
    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});

    try putTools(allocator, &root, registry);
    try putCommands(allocator, &root, registry);
    try putShortcuts(allocator, &root, registry);
    try putCapabilities(allocator, &root, registry);
    try putWorkflows(allocator, &root, registry);
    try putWorkflowDiagnostics(allocator, &root, registry);
    try putCollisionDiagnostics(allocator, &root, registry);
    try putSubAgentPresets(allocator, &root, registry);
    try putFlags(allocator, &root, registry);
    try putProviders(allocator, &root, registry);
    try putResourceDiscoveries(allocator, &root, registry);
    try putUiRequestIds(allocator, &root, registry);
    try putInjectionHooks(allocator, &root, registry);
    try putTerminalInputSubscriptions(allocator, &root, registry);
    try putEditorComponentHook(allocator, &root, registry);
    try putWidgets(allocator, &root, registry);
    try putHooks(allocator, &root, registry);
    try putMessageRenderers(allocator, &root, registry);

    return .{ .object = root };
}

fn putTools(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var tools_array = std.json.Array.init(allocator);
    for (registry.tools.items) |tool| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "name", tool.name);
        try common.putString(allocator, &entry, "label", tool.label);
        try common.putString(allocator, &entry, "description", tool.description);
        try common.putValue(allocator, &entry, "parameters", try common.cloneJsonValue(allocator, tool.parameters));
        try common.putValue(allocator, &entry, "executionMode", try optionalStringJson(allocator, tool.execution_mode));
        try common.putValue(allocator, &entry, "renderShell", try optionalStringJson(allocator, tool.render_shell));
        try common.putString(allocator, &entry, "extensionPath", tool.extension_path);
        try tools_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "tools", .{ .array = tools_array });
}

fn putCommands(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var commands_array = std.json.Array.init(allocator);
    const resolved_commands = try registry.resolveCommands(allocator);
    defer deinitResolvedCommandsLocal(allocator, resolved_commands);
    for (resolved_commands) |cmd| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "name", cmd.name);
        try common.putString(allocator, &entry, "invocationName", cmd.invocation_name);
        try common.putValue(allocator, &entry, "description", try optionalStringJson(allocator, cmd.description));
        try common.putString(allocator, &entry, "extensionPath", cmd.extension_path);
        try commands_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "commands", .{ .array = commands_array });
}

fn putShortcuts(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var shortcuts_array = std.json.Array.init(allocator);
    for (registry.shortcuts.items) |sc| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "shortcut", sc.shortcut);
        try common.putValue(allocator, &entry, "description", try optionalStringJson(allocator, sc.description));
        try common.putValue(allocator, &entry, "command", try optionalStringJson(allocator, sc.command));
        try common.putString(allocator, &entry, "extensionPath", sc.extension_path);
        try shortcuts_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "shortcuts", .{ .array = shortcuts_array });
}

fn putCapabilities(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var capabilities_array = std.json.Array.init(allocator);
    for (registry.capabilities.items) |capability| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "id", capability.id);
        try common.putString(allocator, &entry, "kind", capability.kind);
        try common.putString(allocator, &entry, "title", capability.title);
        try common.putString(allocator, &entry, "description", capability.description);
        try common.putValue(allocator, &entry, "command", try optionalStringJson(allocator, capability.command));
        try common.putValue(allocator, &entry, "resourcePath", try optionalStringJson(allocator, capability.resource_path));
        try common.putString(allocator, &entry, "extensionPath", capability.extension_path);
        try capabilities_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "capabilities", .{ .array = capabilities_array });
}

fn putWorkflows(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var workflows_array = std.json.Array.init(allocator);
    for (registry.workflows.items) |workflow| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "id", workflow.id);
        try common.putString(allocator, &entry, "description", workflow.description);
        try common.putValue(allocator, &entry, "inputSchema", try common.cloneJsonValue(allocator, workflow.input_schema));
        try common.putValue(allocator, &entry, "outputSchema", try common.cloneJsonValue(allocator, workflow.output_schema));
        try common.putString(allocator, &entry, "executionMode", workflow.execution_mode);
        try common.putValue(allocator, &entry, "permissions", try common.cloneJsonValue(allocator, workflow.permissions));
        try common.putValue(allocator, &entry, "dependencies", try common.cloneJsonValue(allocator, workflow.dependencies));
        try common.putInt(allocator, &entry, "timeoutMs", @intCast(workflow.timeout_ms));
        try common.putValue(allocator, &entry, "cancellation", try common.cloneJsonValue(allocator, workflow.cancellation));
        try common.putValue(allocator, &entry, "replay", try common.cloneJsonValue(allocator, workflow.replay));
        try common.putValue(allocator, &entry, "childAgentLimits", try common.cloneJsonValue(allocator, workflow.child_agent_limits));
        try common.putValue(allocator, &entry, "commandName", try optionalStringJson(allocator, workflow.command_name));
        try common.putValue(allocator, &entry, "toolName", try optionalStringJson(allocator, workflow.tool_name));
        try common.putValue(allocator, &entry, "presetId", try optionalStringJson(allocator, workflow.preset_id));
        try common.putString(allocator, &entry, "extensionPath", workflow.extension_path);
        try workflows_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "workflows", .{ .array = workflows_array });
}

fn putSubAgentPresets(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var presets_array = std.json.Array.init(allocator);
    for (registry.workflows.items) |workflow| {
        const preset_id = workflow.preset_id orelse continue;
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "id", preset_id);
        try common.putString(allocator, &entry, "workflowId", workflow.id);
        try common.putString(allocator, &entry, "description", workflow.description);
        try common.putValue(allocator, &entry, "permissions", try common.cloneJsonValue(allocator, workflow.permissions));
        try common.putInt(allocator, &entry, "timeoutMs", @intCast(workflow.timeout_ms));
        try common.putValue(allocator, &entry, "childAgentLimits", try common.cloneJsonValue(allocator, workflow.child_agent_limits));
        try common.putValue(allocator, &entry, "replay", try common.cloneJsonValue(allocator, workflow.replay));
        try common.putString(allocator, &entry, "extensionPath", workflow.extension_path);
        try presets_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "subAgentPresets", .{ .array = presets_array });
}

fn putWorkflowDiagnostics(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var diagnostics_array = std.json.Array.init(allocator);
    for (registry.workflow_surface_diagnostics.items) |diagnostic| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "code", diagnostic.code);
        try common.putString(allocator, &entry, "severity", diagnostic.severity);
        try common.putString(allocator, &entry, "workflowId", diagnostic.workflow_id);
        try common.putString(allocator, &entry, "surface", diagnostic.surface);
        try common.putValue(allocator, &entry, "name", try optionalStringJson(allocator, diagnostic.name));
        try common.putString(allocator, &entry, "extensionPath", diagnostic.extension_path);
        try common.putString(allocator, &entry, "path", diagnostic.path);
        try common.putString(allocator, &entry, "message", diagnostic.message);
        try diagnostics_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "workflowDiagnostics", .{ .array = diagnostics_array });
}

fn putCollisionDiagnostics(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var diagnostics_array = std.json.Array.init(allocator);
    for (registry.collision_diagnostics.items) |diagnostic| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "surface", diagnostic.surface);
        try common.putString(allocator, &entry, "id", diagnostic.id);
        try common.putString(allocator, &entry, "incumbentExtensionPath", diagnostic.incumbent_extension_path);
        try common.putString(allocator, &entry, "rejectedExtensionPath", diagnostic.rejected_extension_path);
        try common.putString(allocator, &entry, "message", diagnostic.message);
        try diagnostics_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "collisionDiagnostics", .{ .array = diagnostics_array });
}

fn putFlags(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var flags_array = std.json.Array.init(allocator);
    for (registry.flags.items) |flag| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "name", flag.name);
        try common.putString(allocator, &entry, "type", switch (flag.type_kind) {
            .boolean => "boolean",
            .string => "string",
        });
        try common.putValue(allocator, &entry, "description", try optionalStringJson(allocator, flag.description));
        try common.putValue(allocator, &entry, "default", try flagDefaultToJson(allocator, flag.default_value));
        const resolved = registry.getFlag(flag.name);
        try common.putValue(allocator, &entry, "value", try flagValueToJson(allocator, resolved));
        try common.putString(allocator, &entry, "extensionPath", flag.extension_path);
        try flags_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "flags", .{ .array = flags_array });
}

fn putProviders(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var providers_array = std.json.Array.init(allocator);
    for (registry.providers.items) |p| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "name", p.name);
        try common.putValue(allocator, &entry, "displayName", try optionalStringJson(allocator, p.display_name));
        try common.putValue(allocator, &entry, "baseUrl", try optionalStringJson(allocator, p.base_url));
        try common.putValue(allocator, &entry, "api", try optionalStringJson(allocator, p.api));
        try common.putValue(allocator, &entry, "defaultModelId", try optionalStringJson(allocator, if (p.models.len > 0) p.models[0].id else null));
        try common.putBool(allocator, &entry, "authHeader", p.auth_header);
        try common.putBool(allocator, &entry, "apiKeyConfigured", p.api_key_configured);
        const credential_required = p.auth_header or p.oauth != null;
        try common.putBool(allocator, &entry, "credentialRequired", credential_required);
        try common.putString(allocator, &entry, "authType", if (p.oauth != null) "oauth" else if (p.auth_header) "api_key" else "none");
        try common.putBool(allocator, &entry, "available", !credential_required or p.api_key_configured);
        if (p.oauth) |oauth| {
            var oauth_entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try common.putString(allocator, &oauth_entry, "name", oauth.name);
            try common.putValue(allocator, &entry, "oauth", .{ .object = oauth_entry });
        } else {
            try common.putNull(allocator, &entry, "oauth");
        }
        var models_array = std.json.Array.init(allocator);
        for (p.models) |m| {
            var m_entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try common.putString(allocator, &m_entry, "id", m.id);
            try common.putString(allocator, &m_entry, "name", m.name);
            try models_array.append(.{ .object = m_entry });
        }
        try common.putValue(allocator, &entry, "models", .{ .array = models_array });
        try common.putString(allocator, &entry, "extensionPath", p.extension_path);
        try providers_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "providers", .{ .array = providers_array });
}

fn putResourceDiscoveries(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var discoveries_array = std.json.Array.init(allocator);
    for (registry.resource_discoveries.items) |discovery| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "extensionPath", discovery.extension_path);

        var skill_paths = std.json.Array.init(allocator);
        for (discovery.skill_paths.items) |path| {
            try skill_paths.append(.{ .string = try allocator.dupe(u8, path) });
        }
        try common.putValue(allocator, &entry, "skillPaths", .{ .array = skill_paths });

        var prompt_paths = std.json.Array.init(allocator);
        for (discovery.prompt_paths.items) |path| {
            try prompt_paths.append(.{ .string = try allocator.dupe(u8, path) });
        }
        try common.putValue(allocator, &entry, "promptPaths", .{ .array = prompt_paths });

        var theme_paths = std.json.Array.init(allocator);
        for (discovery.theme_paths.items) |path| {
            try theme_paths.append(.{ .string = try allocator.dupe(u8, path) });
        }
        try common.putValue(allocator, &entry, "themePaths", .{ .array = theme_paths });
        try discoveries_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "resourceDiscoveries", .{ .array = discoveries_array });
}

fn putUiRequestIds(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var ids_array = std.json.Array.init(allocator);
    for (registry.ui_request_ids.items) |id| {
        try ids_array.append(.{ .string = try allocator.dupe(u8, id) });
    }
    try common.putValue(allocator, &root, "uiRequestIds", .{ .array = ids_array });
}

fn putInjectionHooks(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    try common.putValue(allocator, &root, "headerHook", try injectionHookJson(allocator, registry.header_hook));
    try common.putValue(allocator, &root, "footerHook", try injectionHookJson(allocator, registry.footer_hook));
}

fn putTerminalInputSubscriptions(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var subs_array = std.json.Array.init(allocator);
    for (registry.terminal_input_subs.items) |sub| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "id", sub.id);
        try common.putBool(allocator, &entry, "consume", sub.consume);
        try common.putValue(allocator, &entry, "transformTo", try optionalStringJson(allocator, sub.transform_to));
        try common.putString(allocator, &entry, "extensionPath", sub.extension_path);
        try subs_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "terminalInputSubscriptions", .{ .array = subs_array });
}

fn putEditorComponentHook(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    if (registry.editor_component_hook) |hook| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "label", hook.label);
        try common.putString(allocator, &entry, "extensionPath", hook.extension_path);
        try common.putValue(allocator, &root, "editorComponentHook", .{ .object = entry });
    } else {
        try common.putNull(allocator, &root, "editorComponentHook");
    }
}

fn putWidgets(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var widgets_array = std.json.Array.init(allocator);
    for (registry.widgets.items) |widget| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "key", widget.key);
        var lines_array = std.json.Array.init(allocator);
        for (widget.lines) |line| {
            try lines_array.append(.{ .string = try allocator.dupe(u8, line) });
        }
        try common.putValue(allocator, &entry, "lines", .{ .array = lines_array });
        try common.putString(allocator, &entry, "placement", switch (widget.placement) {
            .above_editor => "aboveEditor",
            .below_editor => "belowEditor",
        });
        try common.putString(allocator, &entry, "extensionPath", widget.extension_path);
        try widgets_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "widgets", .{ .array = widgets_array });
}

fn putMessageRenderers(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var mr_array = std.json.Array.init(allocator);
    for (registry.message_renderers.items) |mr| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "customType", mr.custom_type);
        try common.putString(allocator, &entry, "extensionPath", mr.extension_path);
        try mr_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "messageRenderers", .{ .array = mr_array });
}

fn putHooks(allocator: std.mem.Allocator, root: *std.json.ObjectMap, registry: anytype) !void {
    var hooks_array = std.json.Array.init(allocator);
    for (registry.hooks.items) |hook| {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try common.putString(allocator, &entry, "eventName", hook.event_name);
        try common.putString(allocator, &entry, "extensionPath", hook.extension_path);
        try common.putInt(allocator, &entry, "priority", hook.priority);
        try common.putInt(allocator, &entry, "declarationOrder", @intCast(hook.declaration_order));
        try common.putString(allocator, &entry, "errorPolicy", hook.error_policy.jsonName());
        try hooks_array.append(.{ .object = entry });
    }
    try common.putValue(allocator, &root, "hooks", .{ .array = hooks_array });
}

fn injectionHookJson(allocator: std.mem.Allocator, hook: anytype) !std.json.Value {
    const value = hook orelse return .null;
    var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    var lines_array = std.json.Array.init(allocator);
    for (value.lines) |line| {
        try lines_array.append(.{ .string = try allocator.dupe(u8, line) });
    }
    try common.putValue(allocator, &entry, "lines", .{ .array = lines_array });
    try common.putString(allocator, &entry, "extensionPath", value.extension_path);
    return .{ .object = entry };
}

fn optionalStringJson(allocator: std.mem.Allocator, value: ?[]const u8) !std.json.Value {
    if (value) |s| return .{ .string = try allocator.dupe(u8, s) };
    return .null;
}

fn flagDefaultToJson(allocator: std.mem.Allocator, default: anytype) !std.json.Value {
    return switch (default) {
        .none => .null,
        .boolean => |b| .{ .bool = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

fn flagValueToJson(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    return switch (value) {
        .none => .null,
        .boolean => |b| .{ .bool = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

fn deinitResolvedCommandsLocal(allocator: std.mem.Allocator, commands: anytype) void {
    for (commands) |command| allocator.free(command.invocation_name);
    allocator.free(commands);
}
