const std = @import("std");
const common = @import("../tools/common.zig");
const extension_registry_snapshot = @import("extension_registry_snapshot.zig");
const extension_events = @import("extension_events.zig");

/// In-memory mirrors of the registration surfaces a Bun-hosted
/// extension contributes through the JSONL host protocol.
///
/// Each registry takes ownership of the strings it stores and exposes
/// stable, deterministic listings so CLI / TS-RPC consumers can render
/// registry output in fixture tests.
///
/// Mirrors the TypeScript `ExtensionAPI` registration surfaces in
/// `packages/coding-agent/src/core/extensions/types.ts`:
///   * `registerTool`
///   * `registerCommand`
///   * `registerShortcut`
///   * `registerFlag` (defaults; CLI parsing/help integration lives in
///     `extension_flags.zig`)
///   * `registerProvider` / `unregisterProvider`
///
/// Live Bun JSONL frames are appended via `applyHostFrame`; the same
/// registries can be inspected before and after an extension reload to
/// validate dynamic registry refresh behavior (VAL-M11-EXT-008,
/// VAL-M11-EXT-012). Existing CLI-flag passthrough lives in
/// `extension_flags.zig`; this module deliberately mirrors the flag
/// types so JSONL `register_flag` frames can populate both registries
/// from a single live source.
/// Supported flag kinds. Matches `extension_flags.FlagKind` byte-for-byte.
pub const FlagKind = enum { boolean, string };

pub const FlagDefault = union(enum) {
    none,
    boolean: bool,
    string: []u8,

    pub fn deinit(self: *FlagDefault, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .none, .boolean => {},
        }
        self.* = .none;
    }

    pub fn clone(allocator: std.mem.Allocator, source: FlagDefault) !FlagDefault {
        return switch (source) {
            .none => .none,
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
        };
    }
};

pub const ExtensionFlag = struct {
    name: []u8,
    description: ?[]u8,
    type_kind: FlagKind,
    default_value: FlagDefault,
    /// Parsed CLI value for this flag, set by `setFlagValue` when the
    /// CLI parser observes `--<name>` (and optional value) on the
    /// command line. Mirrors TypeScript `extensionState.flags[name]`
    /// so extensions can observe CLI flag values via `getFlag()`.
    cli_value: FlagDefault = .none,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionFlag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        self.default_value.deinit(allocator);
        self.cli_value.deinit(allocator);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Resolved CLI/runtime flag value used by `Registry.getFlag`. Mirrors
/// the TypeScript `extensionState.flags[name]` shape: explicit CLI
/// value wins, else the registered default, else `.none`.
pub const FlagValue = union(enum) {
    none,
    boolean: bool,
    string: []const u8,
};

/// Tool render hook types mirroring TS ToolDefinition.renderCall/renderResult
pub const ToolRenderHook = struct {
    /// JSON-serialized render configuration from the extension
    render_config: []u8,
    /// Tool name this render hook belongs to
    tool_name: []u8,
    /// Extension path for cleanup
    extension_path: []u8,

    pub fn deinit(self: *ToolRenderHook, allocator: std.mem.Allocator) void {
        allocator.free(self.render_config);
        allocator.free(self.tool_name);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ExtensionTool = struct {
    name: []u8,
    label: []u8,
    description: []u8,
    parameters: std.json.Value,
    extension_path: []u8,
    /// Optional per-tool execution capability ("sequential" or "parallel")
    execution_mode: ?[]u8 = null,
    /// Optional render shell mode ("default" or "self")
    render_shell: ?[]u8 = null,
    /// Optional render hook configuration
    render_hook: ?ToolRenderHook = null,

    pub fn deinit(self: *ExtensionTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.label);
        allocator.free(self.description);
        common.deinitJsonValue(allocator, self.parameters);
        allocator.free(self.extension_path);
        if (self.execution_mode) |mode| allocator.free(mode);
        if (self.render_shell) |rs| allocator.free(rs);
        if (self.render_hook) |*rh| rh.deinit(allocator);
        self.* = undefined;
    }
};

pub const ExtensionCommand = struct {
    name: []u8,
    description: ?[]u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ExtensionShortcut = struct {
    shortcut: []u8,
    description: ?[]u8,
    command: ?[]u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionShortcut, allocator: std.mem.Allocator) void {
        allocator.free(self.shortcut);
        if (self.description) |desc| allocator.free(desc);
        if (self.command) |cmd| allocator.free(cmd);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ResolvedCommand = struct {
    name: []const u8,
    invocation_name: []u8,
    description: ?[]const u8,
    extension_path: []const u8,
};

pub const ResolvedShortcut = struct {
    shortcut: []const u8,
    description: ?[]const u8,
    command: ?[]const u8,
    extension_path: []const u8,
};

pub const ShortcutDiagnostic = struct {
    type_name: []const u8 = "warning",
    message: []u8,
    path: []u8,

    pub fn deinit(self: *ShortcutDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const WorkflowSurfaceDiagnostic = struct {
    code: []u8,
    severity: []u8,
    workflow_id: []u8,
    surface: []u8,
    name: ?[]u8,
    extension_path: []u8,
    path: []u8,
    message: []u8,

    pub fn deinit(self: *WorkflowSurfaceDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.severity);
        allocator.free(self.workflow_id);
        allocator.free(self.surface);
        if (self.name) |name| allocator.free(name);
        allocator.free(self.extension_path);
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const RegistryCollisionDiagnostic = struct {
    surface: []u8,
    id: []u8,
    incumbent_extension_path: []u8,
    rejected_extension_path: []u8,
    message: []u8,

    pub fn deinit(self: *RegistryCollisionDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.surface);
        allocator.free(self.id);
        allocator.free(self.incumbent_extension_path);
        allocator.free(self.rejected_extension_path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const BuiltinShortcutBinding = struct {
    shortcut: []const u8,
    keybinding: []const u8,
    restrict_override: bool,
};

pub const ShortcutResolution = struct {
    shortcuts: []ResolvedShortcut,
    diagnostics: []ShortcutDiagnostic,

    pub fn deinit(self: *ShortcutResolution, allocator: std.mem.Allocator) void {
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        allocator.free(self.shortcuts);
        self.* = undefined;
    }
};

pub const ExtensionCapability = struct {
    id: []u8,
    kind: []u8,
    title: []u8,
    description: []u8,
    command: ?[]u8,
    resource_path: ?[]u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionCapability, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        allocator.free(self.title);
        allocator.free(self.description);
        if (self.command) |command| allocator.free(command);
        if (self.resource_path) |path| allocator.free(path);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ExtensionWorkflow = struct {
    id: []u8,
    description: []u8,
    input_schema: std.json.Value,
    output_schema: std.json.Value,
    execution_mode: []u8,
    permissions: std.json.Value,
    dependencies: std.json.Value,
    timeout_ms: u64,
    cancellation: std.json.Value,
    replay: std.json.Value,
    child_agent_limits: std.json.Value,
    steps: std.json.Value,
    command_name: ?[]u8,
    tool_name: ?[]u8,
    preset_id: ?[]u8,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionWorkflow, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        common.deinitJsonValue(allocator, self.input_schema);
        common.deinitJsonValue(allocator, self.output_schema);
        allocator.free(self.execution_mode);
        common.deinitJsonValue(allocator, self.permissions);
        common.deinitJsonValue(allocator, self.dependencies);
        common.deinitJsonValue(allocator, self.cancellation);
        common.deinitJsonValue(allocator, self.replay);
        common.deinitJsonValue(allocator, self.child_agent_limits);
        common.deinitJsonValue(allocator, self.steps);
        if (self.command_name) |value| allocator.free(value);
        if (self.tool_name) |value| allocator.free(value);
        if (self.preset_id) |value| allocator.free(value);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const ProviderModel = struct {
    id: []u8,
    name: []u8,

    pub fn deinit(self: *ProviderModel, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// OAuth configuration for extension providers.
/// Mirrors TypeScript `ProviderConfig.oauth` field.
pub const ProviderOAuth = struct {
    /// Display name for the provider in login UI
    name: []u8,

    pub fn deinit(self: *ProviderOAuth, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ExtensionProvider = struct {
    name: []u8,
    display_name: ?[]u8,
    base_url: ?[]u8,
    api: ?[]u8,
    models: []ProviderModel,
    extension_path: []u8,
    /// OAuth configuration for /login support
    oauth: ?ProviderOAuth = null,
    /// Custom headers to include in requests
    headers: ?std.StringHashMap([]u8) = null,
    /// If true, adds Authorization: Bearer header with resolved API key
    auth_header: bool = false,
    /// True when extension-provided provider config includes an API key source
    api_key_configured: bool = false,

    pub fn deinit(self: *ExtensionProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.display_name) |n| allocator.free(n);
        if (self.base_url) |u| allocator.free(u);
        if (self.api) |a| allocator.free(a);
        for (self.models) |*model| model.deinit(allocator);
        allocator.free(self.models);
        if (self.oauth) |*oauth| oauth.deinit(allocator);
        if (self.headers) |*headers| {
            var iter = headers.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Header / footer hook captured from the live Bun host. Mirrors the
/// TS `ExtensionUIContext.setHeader` / `setFooter` factories: at the
/// JSONL protocol layer the host serializes a deterministic content
/// preview (line array) plus the owning extension path so cleanup on
/// reload / session replacement can target hooks by extension.
pub const InjectionHook = struct {
    lines: [][]u8,
    extension_path: []u8,

    pub fn deinit(self: *InjectionHook, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Terminal input subscription. The host serializes the consume +
/// transform behavior so cleanup/unsubscribe can be observed without a
/// real TUI: `consume = true` mirrors `{ consume: true }` returned from
/// the TS handler; `transform_to` mirrors `{ data: <new> }`. A pure
/// observer subscription has both `consume = false` and
/// `transform_to == null`.
pub const TerminalInputSubscription = struct {
    id: []u8,
    consume: bool = false,
    transform_to: ?[]u8 = null,
    extension_path: []u8,

    pub fn deinit(self: *TerminalInputSubscription, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.transform_to) |t| allocator.free(t);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Custom editor component hook. The host serializes a deterministic
/// label (the registered editor name) so reload/cleanup can confirm
/// the previous custom editor did not survive.
pub const EditorComponentHook = struct {
    label: []u8,
    extension_path: []u8,

    pub fn deinit(self: *EditorComponentHook, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Message renderer hook for CustomMessage entries. Mirrors the TypeScript
/// `MessageRenderer` registration surface in `types.ts`: extensions call
/// `registerMessageRenderer(customType, renderer)` to supply a custom
/// rendering component for entries with that `customType`.
pub const MessageRenderer = struct {
    custom_type: []u8,
    extension_path: []u8,

    pub fn deinit(self: *MessageRenderer, allocator: std.mem.Allocator) void {
        allocator.free(self.custom_type);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const HookErrorPolicy = enum {
    @"continue",
    fatal,

    pub fn jsonName(self: HookErrorPolicy) []const u8 {
        return switch (self) {
            .@"continue" => "continue",
            .fatal => "fatal",
        };
    }
};

/// Event hook subscription captured from a live extension host.
/// Process JSONL hosts emit this when an extension registers an event
/// interceptor. The runtime uses this registry surface to avoid sending
/// correlated interception requests to hosts that cannot answer them.
pub const ExtensionHook = struct {
    event_name: []u8,
    extension_path: []u8,
    priority: i64 = 0,
    declaration_order: usize = 0,
    error_policy: HookErrorPolicy = .@"continue",

    pub fn deinit(self: *ExtensionHook, allocator: std.mem.Allocator) void {
        allocator.free(self.event_name);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Widget placement options
pub const WidgetPlacement = enum {
    above_editor,
    below_editor,
};

/// Extension widget hook. Mirrors TS `setWidget`.
pub const WidgetHook = struct {
    key: []u8,
    lines: [][]u8,
    placement: WidgetPlacement,
    extension_path: []u8,

    pub fn deinit(self: *WidgetHook, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

/// Result of feeding terminal input bytes through the registered
/// subscriptions. `consumed` blocks the default editor; `data` is the
/// final transformed bytes (caller borrows).
pub const TerminalInputResult = struct {
    consumed: bool,
    data: []const u8,
};

/// Resource discovery paths from extensions
pub const ResourceDiscovery = struct {
    skill_paths: std.ArrayList([]u8) = .empty,
    prompt_paths: std.ArrayList([]u8) = .empty,
    theme_paths: std.ArrayList([]u8) = .empty,
    extension_path: []u8,

    pub fn deinit(self: *ResourceDiscovery, allocator: std.mem.Allocator) void {
        for (self.skill_paths.items) |path| allocator.free(path);
        self.skill_paths.deinit(allocator);
        for (self.prompt_paths.items) |path| allocator.free(path);
        self.prompt_paths.deinit(allocator);
        for (self.theme_paths.items) |path| allocator.free(path);
        self.theme_paths.deinit(allocator);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList(ExtensionFlag) = .empty,
    tools: std.ArrayList(ExtensionTool) = .empty,
    commands: std.ArrayList(ExtensionCommand) = .empty,
    shortcuts: std.ArrayList(ExtensionShortcut) = .empty,
    capabilities: std.ArrayList(ExtensionCapability) = .empty,
    workflows: std.ArrayList(ExtensionWorkflow) = .empty,
    workflow_surface_diagnostics: std.ArrayList(WorkflowSurfaceDiagnostic) = .empty,
    collision_diagnostics: std.ArrayList(RegistryCollisionDiagnostic) = .empty,
    providers: std.ArrayList(ExtensionProvider) = .empty,
    /// Captured `extension_ui_request` ids in arrival order. Mirrors the
    /// host-side bridge log so UI bridge correlation can be asserted by
    /// fixture tests (VAL-M11-EXT-013).
    ui_request_ids: std.ArrayList([]u8) = .empty,
    /// Currently-installed extension header hook (TS `setHeader`).
    /// Single-slot to mirror the TS interactive runtime contract:
    /// later setHeader frames replace the previous one. `null` means
    /// the built-in header is in use.
    header_hook: ?InjectionHook = null,
    /// Currently-installed extension footer hook (TS `setFooter`).
    footer_hook: ?InjectionHook = null,
    /// Terminal input subscriptions in registration order. Each
    /// subscription has a stable id so unsubscribe frames can target
    /// the exact handler.
    terminal_input_subs: std.ArrayList(TerminalInputSubscription) = .empty,
    /// Custom editor component hook (TS `setEditorComponent`).
    /// Single-slot; `null` means the default editor is in use.
    editor_component_hook: ?EditorComponentHook = null,
    /// Resource discoveries from extensions (TS `resources_discover`)
    resource_discoveries: std.ArrayList(ResourceDiscovery) = .empty,
    /// Extension widgets (TS `setWidget`). Keyed by widget key for replacement.
    widgets: std.ArrayList(WidgetHook) = .empty,
    /// Message renderers registered via `registerMessageRenderer`. Keyed by
    /// customType; re-registering the same customType replaces the entry.
    message_renderers: std.ArrayList(MessageRenderer) = .empty,
    /// Event interception hooks registered by extensions. Kept in registration
    /// order so dispatch can follow deterministic extension composition order.
    hooks: std.ArrayList(ExtensionHook) = .empty,
    next_hook_declaration_order: usize = 0,
    /// Event bus for extension event handling
    event_bus: extension_events.EventBus,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .event_bus = extension_events.EventBus.init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        for (self.flags.items) |*flag| flag.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        for (self.commands.items) |*cmd| cmd.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        for (self.shortcuts.items) |*sc| sc.deinit(self.allocator);
        self.shortcuts.deinit(self.allocator);
        for (self.capabilities.items) |*capability| capability.deinit(self.allocator);
        self.capabilities.deinit(self.allocator);
        for (self.workflows.items) |*workflow| workflow.deinit(self.allocator);
        self.workflows.deinit(self.allocator);
        for (self.workflow_surface_diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.workflow_surface_diagnostics.deinit(self.allocator);
        for (self.collision_diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.collision_diagnostics.deinit(self.allocator);
        for (self.providers.items) |*p| p.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        for (self.ui_request_ids.items) |id| self.allocator.free(id);
        self.ui_request_ids.deinit(self.allocator);
        if (self.header_hook) |*h| h.deinit(self.allocator);
        if (self.footer_hook) |*h| h.deinit(self.allocator);
        for (self.terminal_input_subs.items) |*sub| sub.deinit(self.allocator);
        self.terminal_input_subs.deinit(self.allocator);
        if (self.editor_component_hook) |*h| h.deinit(self.allocator);
        for (self.resource_discoveries.items) |*discovery| discovery.deinit(self.allocator);
        self.resource_discoveries.deinit(self.allocator);
        for (self.widgets.items) |*widget| widget.deinit(self.allocator);
        self.widgets.deinit(self.allocator);
        for (self.message_renderers.items) |*mr| mr.deinit(self.allocator);
        self.message_renderers.deinit(self.allocator);
        for (self.hooks.items) |*hook| hook.deinit(self.allocator);
        self.hooks.deinit(self.allocator);
        self.event_bus.deinit();
        self.* = undefined;
    }

    fn findToolIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.tools.items, 0..) |tool, idx| {
            if (std.mem.eql(u8, tool.name, name)) return idx;
        }
        return null;
    }

    fn findCommandIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.commands.items, 0..) |cmd, idx| {
            if (std.mem.eql(u8, cmd.name, name)) return idx;
        }
        return null;
    }

    fn findCommandForExtensionIndex(self: *const Registry, name: []const u8, extension_path: []const u8) ?usize {
        for (self.commands.items, 0..) |cmd, idx| {
            if (std.mem.eql(u8, cmd.name, name) and std.mem.eql(u8, cmd.extension_path, extension_path)) return idx;
        }
        return null;
    }

    fn findShortcutIndex(self: *const Registry, shortcut: []const u8) ?usize {
        for (self.shortcuts.items, 0..) |sc, idx| {
            if (asciiEqlIgnoreCase(sc.shortcut, shortcut)) return idx;
        }
        return null;
    }

    fn findShortcutForExtensionIndex(self: *const Registry, shortcut: []const u8, extension_path: []const u8) ?usize {
        for (self.shortcuts.items, 0..) |sc, idx| {
            if (asciiEqlIgnoreCase(sc.shortcut, shortcut) and std.mem.eql(u8, sc.extension_path, extension_path)) return idx;
        }
        return null;
    }

    pub fn findCapabilityIndex(self: *const Registry, id: []const u8) ?usize {
        for (self.capabilities.items, 0..) |capability, idx| {
            if (std.mem.eql(u8, capability.id, id)) return idx;
        }
        return null;
    }

    fn findWorkflowIndex(self: *const Registry, id: []const u8) ?usize {
        for (self.workflows.items, 0..) |workflow, idx| {
            if (std.mem.eql(u8, workflow.id, id)) return idx;
        }
        return null;
    }

    pub fn workflowForId(self: *const Registry, id: []const u8) ?*const ExtensionWorkflow {
        const idx = self.findWorkflowIndex(id) orelse return null;
        return &self.workflows.items[idx];
    }

    pub fn workflowForCommandName(self: *const Registry, name: []const u8) ?*const ExtensionWorkflow {
        for (self.workflows.items) |*workflow| {
            const command_name = workflow.command_name orelse continue;
            if (std.mem.eql(u8, command_name, name)) return workflow;
        }
        return null;
    }

    fn clearWorkflowSurfaceDiagnostics(self: *Registry, id: []const u8, extension_path: []const u8) void {
        var index = self.workflow_surface_diagnostics.items.len;
        while (index > 0) {
            index -= 1;
            const diagnostic = self.workflow_surface_diagnostics.items[index];
            if (std.mem.eql(u8, diagnostic.workflow_id, id) and std.mem.eql(u8, diagnostic.extension_path, extension_path)) {
                var removed = self.workflow_surface_diagnostics.orderedRemove(index);
                removed.deinit(self.allocator);
            }
        }
    }

    fn appendCollisionDiagnostic(
        self: *Registry,
        surface: []const u8,
        id: []const u8,
        incumbent_extension_path: []const u8,
        rejected_extension_path: []const u8,
    ) !void {
        const surface_dup = try self.allocator.dupe(u8, surface);
        errdefer self.allocator.free(surface_dup);
        const id_dup = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_dup);
        const incumbent_dup = try self.allocator.dupe(u8, incumbent_extension_path);
        errdefer self.allocator.free(incumbent_dup);
        const rejected_dup = try self.allocator.dupe(u8, rejected_extension_path);
        errdefer self.allocator.free(rejected_dup);
        const message = try std.fmt.allocPrint(
            self.allocator,
            "Extension {s} registration '{s}' from {s} conflicts with incumbent registration from {s}; keeping incumbent.",
            .{ surface, id, rejected_extension_path, incumbent_extension_path },
        );
        errdefer self.allocator.free(message);

        const diagnostic = RegistryCollisionDiagnostic{
            .surface = surface_dup,
            .id = id_dup,
            .incumbent_extension_path = incumbent_dup,
            .rejected_extension_path = rejected_dup,
            .message = message,
        };
        try self.collision_diagnostics.append(self.allocator, diagnostic);
    }

    fn removeCollisionDiagnosticsForExtension(self: *Registry, extension_path: []const u8) void {
        var index = self.collision_diagnostics.items.len;
        while (index > 0) {
            index -= 1;
            const diagnostic = self.collision_diagnostics.items[index];
            if (std.mem.eql(u8, diagnostic.incumbent_extension_path, extension_path) or
                std.mem.eql(u8, diagnostic.rejected_extension_path, extension_path))
            {
                var removed = self.collision_diagnostics.orderedRemove(index);
                removed.deinit(self.allocator);
            }
        }
    }

    fn appendWorkflowSurfaceDiagnostic(
        self: *Registry,
        id: []const u8,
        surface: []const u8,
        name: ?[]const u8,
        extension_path: []const u8,
        path: []const u8,
        message: []const u8,
    ) !void {
        try self.workflow_surface_diagnostics.append(self.allocator, .{
            .code = try self.allocator.dupe(u8, "workflow.surface_denied"),
            .severity = try self.allocator.dupe(u8, "warning"),
            .workflow_id = try self.allocator.dupe(u8, id),
            .surface = try self.allocator.dupe(u8, surface),
            .name = if (name) |value| try self.allocator.dupe(u8, value) else null,
            .extension_path = try self.allocator.dupe(u8, extension_path),
            .path = try self.allocator.dupe(u8, path),
            .message = try self.allocator.dupe(u8, message),
        });
    }

    pub fn workflowForToolName(self: *const Registry, name: []const u8) ?*const ExtensionWorkflow {
        for (self.workflows.items) |*workflow| {
            const tool_name = workflow.tool_name orelse continue;
            if (std.mem.eql(u8, tool_name, name)) return workflow;
        }
        return null;
    }

    pub fn workflowForPresetId(self: *const Registry, id: []const u8) ?*const ExtensionWorkflow {
        for (self.workflows.items) |*workflow| {
            const preset_id = workflow.preset_id orelse continue;
            if (std.mem.eql(u8, preset_id, id)) return workflow;
        }
        return null;
    }

    fn findFlagIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.flags.items, 0..) |flag, idx| {
            if (std.mem.eql(u8, flag.name, name)) return idx;
        }
        return null;
    }

    fn findProviderIndex(self: *const Registry, name: []const u8) ?usize {
        for (self.providers.items, 0..) |p, idx| {
            if (std.mem.eql(u8, p.name, name)) return idx;
        }
        return null;
    }

    fn findMessageRendererIndex(self: *const Registry, custom_type: []const u8) ?usize {
        for (self.message_renderers.items, 0..) |mr, idx| {
            if (std.mem.eql(u8, mr.custom_type, custom_type)) return idx;
        }
        return null;
    }

    fn findHookIndex(self: *const Registry, event_name: []const u8, extension_path: []const u8) ?usize {
        for (self.hooks.items, 0..) |hook, idx| {
            if (std.mem.eql(u8, hook.event_name, event_name) and std.mem.eql(u8, hook.extension_path, extension_path)) return idx;
        }
        return null;
    }

    pub fn registerHook(self: *Registry, event_name: []const u8, extension_path: []const u8) !void {
        try self.registerHookFull(event_name, extension_path, 0, null, .@"continue");
    }

    pub fn registerHookFull(
        self: *Registry,
        event_name: []const u8,
        extension_path: []const u8,
        priority: i64,
        declaration_order: ?usize,
        error_policy: HookErrorPolicy,
    ) !void {
        if (event_name.len == 0) return;
        if (self.findHookIndex(event_name, extension_path)) |_| return;
        const assigned_order = declaration_order orelse self.next_hook_declaration_order;
        self.next_hook_declaration_order += 1;
        try self.hooks.append(self.allocator, .{
            .event_name = try self.allocator.dupe(u8, event_name),
            .extension_path = try self.allocator.dupe(u8, extension_path),
            .priority = priority,
            .declaration_order = assigned_order,
            .error_policy = error_policy,
        });
    }

    pub fn unregisterHook(self: *Registry, event_name: []const u8, extension_path: []const u8) bool {
        const idx = self.findHookIndex(event_name, extension_path) orelse return false;
        var removed = self.hooks.orderedRemove(idx);
        removed.deinit(self.allocator);
        return true;
    }

    pub fn hasHook(self: *const Registry, event_name: []const u8) bool {
        for (self.hooks.items) |hook| {
            if (std.mem.eql(u8, hook.event_name, event_name)) return true;
        }
        return false;
    }

    pub fn hookForEvent(self: *const Registry, event_name: []const u8) ?*const ExtensionHook {
        for (self.hooks.items) |*hook| {
            if (std.mem.eql(u8, hook.event_name, event_name)) return hook;
        }
        return null;
    }

    pub fn hookErrorPolicyForEvent(self: *const Registry, event_name: []const u8) HookErrorPolicy {
        return if (self.hookForEvent(event_name)) |hook| hook.error_policy else .@"continue";
    }

    pub fn registerMessageRenderer(
        self: *Registry,
        custom_type: []const u8,
        extension_path: []const u8,
    ) !void {
        if (isSubAgentReservedName(custom_type)) return error.ReservedSubAgentName;
        if (self.findMessageRendererIndex(custom_type)) |idx| {
            if (!std.mem.eql(u8, self.message_renderers.items[idx].extension_path, extension_path)) {
                try self.appendCollisionDiagnostic("message_renderer", custom_type, self.message_renderers.items[idx].extension_path, extension_path);
                return;
            }
            self.message_renderers.items[idx].deinit(self.allocator);
            self.message_renderers.items[idx] = try makeMessageRenderer(self.allocator, custom_type, extension_path);
            return;
        }
        const mr = try makeMessageRenderer(self.allocator, custom_type, extension_path);
        try self.message_renderers.append(self.allocator, mr);
    }

    pub fn unregisterMessageRenderer(self: *Registry, custom_type: []const u8) bool {
        if (self.findMessageRendererIndex(custom_type)) |idx| {
            var removed = self.message_renderers.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    /// Returns a pointer to the MessageRenderer for the given customType, or
    /// null if no renderer is registered. The pointer is valid until the next
    /// mutation of `message_renderers`.
    pub fn findMessageRenderer(self: *const Registry, custom_type: []const u8) ?*const MessageRenderer {
        if (self.findMessageRendererIndex(custom_type)) |idx| {
            return &self.message_renderers.items[idx];
        }
        return null;
    }

    pub fn registerTool(
        self: *Registry,
        name: []const u8,
        label: []const u8,
        description: []const u8,
        extension_path: []const u8,
    ) !void {
        try self.registerToolFull(name, label, description, .null, null, null, extension_path);
    }

    pub fn registerToolFull(
        self: *Registry,
        name: []const u8,
        label: []const u8,
        description: []const u8,
        parameters: std.json.Value,
        execution_mode: ?[]const u8,
        render_shell: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        if (isSubAgentReservedName(name)) return error.ReservedSubAgentName;
        if (self.findToolIndex(name)) |idx| {
            if (!std.mem.eql(u8, self.tools.items[idx].extension_path, extension_path)) {
                try self.appendCollisionDiagnostic("tool", name, self.tools.items[idx].extension_path, extension_path);
                return;
            }
            self.tools.items[idx].deinit(self.allocator);
            self.tools.items[idx] = try makeTool(self.allocator, name, label, description, parameters, execution_mode, render_shell, extension_path);
            return;
        }
        const tool = try makeTool(self.allocator, name, label, description, parameters, execution_mode, render_shell, extension_path);
        try self.tools.append(self.allocator, tool);
    }

    pub fn unregisterTool(self: *Registry, name: []const u8) bool {
        if (self.findToolIndex(name)) |idx| {
            var removed = self.tools.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn registerCommand(
        self: *Registry,
        name: []const u8,
        description: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        if (isSubAgentReservedName(name)) return error.ReservedSubAgentName;
        if (self.findCommandForExtensionIndex(name, extension_path)) |idx| {
            self.commands.items[idx].deinit(self.allocator);
            self.commands.items[idx] = try makeCommand(self.allocator, name, description, extension_path);
            return;
        }
        if (self.findCommandIndex(name)) |idx| {
            try self.appendCollisionDiagnostic("command", name, self.commands.items[idx].extension_path, extension_path);
            return;
        }
        const cmd = try makeCommand(self.allocator, name, description, extension_path);
        try self.commands.append(self.allocator, cmd);
    }

    pub fn registerShortcut(
        self: *Registry,
        shortcut: []const u8,
        description: ?[]const u8,
        command: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        // TypeScript stores shortcuts in a per-extension map keyed by
        // shortcut. Cross-extension conflicts are diagnosed and resolved
        // only when shortcuts are listed; last extension wins there.
        if (self.findShortcutForExtensionIndex(shortcut, extension_path)) |idx| {
            self.shortcuts.items[idx].deinit(self.allocator);
            self.shortcuts.items[idx] = try makeShortcut(self.allocator, shortcut, description, command, extension_path);
            return;
        }
        const sc = try makeShortcut(self.allocator, shortcut, description, command, extension_path);
        try self.shortcuts.append(self.allocator, sc);
    }

    pub fn resolveCommands(self: *const Registry, allocator: std.mem.Allocator) ![]ResolvedCommand {
        var resolved = std.ArrayList(ResolvedCommand).empty;
        errdefer {
            for (resolved.items) |command| allocator.free(command.invocation_name);
            resolved.deinit(allocator);
        }

        for (self.commands.items, 0..) |cmd, idx| {
            const occurrence = self.commandOccurrenceThroughIndex(idx);
            const total = self.commandNameCount(cmd.name);
            var invocation_name = if (total > 1)
                try std.fmt.allocPrint(allocator, "{s}:{d}", .{ cmd.name, occurrence })
            else
                try allocator.dupe(u8, cmd.name);
            errdefer allocator.free(invocation_name);

            if (resolvedInvocationTaken(resolved.items, invocation_name)) {
                var suffix = occurrence;
                while (true) {
                    suffix += 1;
                    allocator.free(invocation_name);
                    invocation_name = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ cmd.name, suffix });
                    if (!resolvedInvocationTaken(resolved.items, invocation_name)) break;
                }
            }

            try resolved.append(allocator, .{
                .name = cmd.name,
                .invocation_name = invocation_name,
                .description = cmd.description,
                .extension_path = cmd.extension_path,
            });
        }

        return try resolved.toOwnedSlice(allocator);
    }

    pub fn hasCommandInvocation(self: *const Registry, invocation_name: []const u8) bool {
        const allocator = self.allocator;
        const resolved = self.resolveCommands(allocator) catch return false;
        defer deinitResolvedCommands(allocator, resolved);
        for (resolved) |command| {
            if (std.mem.eql(u8, command.invocation_name, invocation_name)) return true;
        }
        return false;
    }

    fn commandNameCount(self: *const Registry, name: []const u8) usize {
        var count: usize = 0;
        for (self.commands.items) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) count += 1;
        }
        return count;
    }

    fn commandOccurrenceThroughIndex(self: *const Registry, index: usize) usize {
        const name = self.commands.items[index].name;
        var occurrence: usize = 0;
        for (self.commands.items[0 .. index + 1]) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) occurrence += 1;
        }
        return occurrence;
    }

    pub fn resolveShortcuts(
        self: *const Registry,
        allocator: std.mem.Allocator,
        builtin_keybindings: []const BuiltinShortcutBinding,
    ) !ShortcutResolution {
        var shortcuts = std.ArrayList(ResolvedShortcut).empty;
        errdefer shortcuts.deinit(allocator);
        var diagnostics = std.ArrayList(ShortcutDiagnostic).empty;
        errdefer {
            for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
            diagnostics.deinit(allocator);
        }

        for (self.shortcuts.items) |shortcut| {
            if (findBuiltinShortcut(builtin_keybindings, shortcut.shortcut)) |builtin| {
                if (builtin.restrict_override) {
                    try appendShortcutDiagnostic(
                        allocator,
                        &diagnostics,
                        shortcut.extension_path,
                        "Extension shortcut '{s}' from {s} conflicts with built-in shortcut. Skipping.",
                        .{ shortcut.shortcut, shortcut.extension_path },
                    );
                    continue;
                }

                try appendShortcutDiagnostic(
                    allocator,
                    &diagnostics,
                    shortcut.extension_path,
                    "Extension shortcut conflict: '{s}' is built-in shortcut for {s} and {s}. Using {s}.",
                    .{ shortcut.shortcut, builtin.keybinding, shortcut.extension_path, shortcut.extension_path },
                );
            }

            if (findResolvedShortcutIndex(shortcuts.items, shortcut.shortcut)) |idx| {
                const previous = shortcuts.items[idx];
                try appendShortcutDiagnostic(
                    allocator,
                    &diagnostics,
                    shortcut.extension_path,
                    "Extension shortcut conflict: '{s}' registered by both {s} and {s}. Using {s}.",
                    .{ shortcut.shortcut, previous.extension_path, shortcut.extension_path, shortcut.extension_path },
                );
                shortcuts.items[idx] = .{
                    .shortcut = shortcut.shortcut,
                    .description = shortcut.description,
                    .command = shortcut.command,
                    .extension_path = shortcut.extension_path,
                };
                continue;
            }

            try shortcuts.append(allocator, .{
                .shortcut = shortcut.shortcut,
                .description = shortcut.description,
                .command = shortcut.command,
                .extension_path = shortcut.extension_path,
            });
        }

        return .{
            .shortcuts = try shortcuts.toOwnedSlice(allocator),
            .diagnostics = try diagnostics.toOwnedSlice(allocator),
        };
    }

    pub fn registerCapability(
        self: *Registry,
        id: []const u8,
        kind: []const u8,
        title: []const u8,
        description: ?[]const u8,
        command: ?[]const u8,
        resource_path: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        if (isSubAgentReservedName(id) or (command != null and isSubAgentReservedName(command.?)) or (resource_path != null and isSubAgentReservedName(resource_path.?))) return error.ReservedSubAgentName;
        if (self.findCapabilityIndex(id)) |idx| {
            if (!std.mem.eql(u8, self.capabilities.items[idx].extension_path, extension_path)) {
                try self.appendCollisionDiagnostic("capability", id, self.capabilities.items[idx].extension_path, extension_path);
                return;
            }
            self.capabilities.items[idx].deinit(self.allocator);
            self.capabilities.items[idx] = try makeCapability(self.allocator, id, kind, title, description, command, resource_path, extension_path);
            return;
        }
        const capability = try makeCapability(self.allocator, id, kind, title, description, command, resource_path, extension_path);
        try self.capabilities.append(self.allocator, capability);
    }

    pub fn unregisterCapability(self: *Registry, id: []const u8) bool {
        if (self.findCapabilityIndex(id)) |idx| {
            var removed = self.capabilities.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn registerWorkflowFull(
        self: *Registry,
        id: []const u8,
        description: []const u8,
        input_schema: std.json.Value,
        output_schema: std.json.Value,
        execution_mode: []const u8,
        permissions: std.json.Value,
        dependencies: std.json.Value,
        timeout_ms: u64,
        cancellation: std.json.Value,
        replay: std.json.Value,
        child_agent_limits: std.json.Value,
        steps: std.json.Value,
        command_name: ?[]const u8,
        tool_name: ?[]const u8,
        preset_id: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        if (self.findWorkflowIndex(id)) |idx| {
            try self.clearWorkflowDerivedSurfaces(self.workflows.items[idx]);
            self.workflows.items[idx].deinit(self.allocator);
            self.workflows.items[idx] = try makeWorkflow(
                self.allocator,
                id,
                description,
                input_schema,
                output_schema,
                execution_mode,
                permissions,
                dependencies,
                timeout_ms,
                cancellation,
                replay,
                child_agent_limits,
                steps,
                command_name,
                tool_name,
                preset_id,
                extension_path,
            );
        } else {
            const workflow = try makeWorkflow(
                self.allocator,
                id,
                description,
                input_schema,
                output_schema,
                execution_mode,
                permissions,
                dependencies,
                timeout_ms,
                cancellation,
                replay,
                child_agent_limits,
                steps,
                command_name,
                tool_name,
                preset_id,
                extension_path,
            );
            try self.workflows.append(self.allocator, workflow);
        }

        const workflow = self.workflows.items[self.findWorkflowIndex(id).?];
        try self.registerCapability(workflow.id, "workflow", workflow.id, workflow.description, workflow.command_name, null, workflow.extension_path);
        if (workflow.command_name) |name| try self.registerCommand(name, workflow.description, workflow.extension_path);
        if (workflow.tool_name) |name| {
            try self.registerToolFull(
                name,
                name,
                workflow.description,
                workflow.input_schema,
                "sequential",
                null,
                workflow.extension_path,
            );
        }
    }

    fn clearWorkflowDerivedSurfaces(self: *Registry, workflow: ExtensionWorkflow) !void {
        _ = self.unregisterCapability(workflow.id);
        if (workflow.tool_name) |name| _ = self.unregisterTool(name);
        if (workflow.command_name) |name| {
            if (self.findCommandForExtensionIndex(name, workflow.extension_path)) |idx| {
                var removed = self.commands.orderedRemove(idx);
                removed.deinit(self.allocator);
            }
        }
    }

    pub fn unregisterWorkflow(self: *Registry, id: []const u8) bool {
        const idx = self.findWorkflowIndex(id) orelse return false;
        self.clearWorkflowSurfaceDiagnostics(self.workflows.items[idx].id, self.workflows.items[idx].extension_path);
        self.clearWorkflowDerivedSurfaces(self.workflows.items[idx]) catch {};
        var removed = self.workflows.orderedRemove(idx);
        removed.deinit(self.allocator);
        return true;
    }

    /// Register a flag with an optional default. Strings are borrowed;
    /// the registry always clones what it needs.
    pub fn registerFlag(
        self: *Registry,
        name: []const u8,
        type_kind: FlagKind,
        description: ?[]const u8,
        default_value: FlagDefaultInput,
        extension_path: []const u8,
    ) !void {
        if (self.findFlagIndex(name)) |idx| {
            if (!std.mem.eql(u8, self.flags.items[idx].extension_path, extension_path)) {
                try self.appendCollisionDiagnostic("flag", name, self.flags.items[idx].extension_path, extension_path);
                return;
            }
            self.flags.items[idx].deinit(self.allocator);
            self.flags.items[idx] = try makeFlag(self.allocator, name, type_kind, description, default_value, extension_path);
            return;
        }
        const flag = try makeFlag(self.allocator, name, type_kind, description, default_value, extension_path);
        try self.flags.append(self.allocator, flag);
    }

    pub fn registerProvider(
        self: *Registry,
        name: []const u8,
        display_name: ?[]const u8,
        base_url: ?[]const u8,
        api: ?[]const u8,
        models: []const ProviderModelInput,
        extension_path: []const u8,
    ) !void {
        try self.registerProviderFull(name, display_name, base_url, api, models, extension_path, null, null, false);
    }

    pub fn registerProviderFull(
        self: *Registry,
        name: []const u8,
        display_name: ?[]const u8,
        base_url: ?[]const u8,
        api: ?[]const u8,
        models: []const ProviderModelInput,
        extension_path: []const u8,
        oauth: ?ProviderOAuth,
        headers: ?std.StringHashMap([]u8),
        auth_header: bool,
    ) !void {
        try self.registerProviderFullWithAuthState(name, display_name, base_url, api, models, extension_path, oauth, headers, auth_header, false);
    }

    pub fn registerProviderFullWithAuthState(
        self: *Registry,
        name: []const u8,
        display_name: ?[]const u8,
        base_url: ?[]const u8,
        api: ?[]const u8,
        models: []const ProviderModelInput,
        extension_path: []const u8,
        oauth: ?ProviderOAuth,
        headers: ?std.StringHashMap([]u8),
        auth_header: bool,
        api_key_configured: bool,
    ) !void {
        if (self.findProviderIndex(name)) |idx| {
            if (!std.mem.eql(u8, self.providers.items[idx].extension_path, extension_path)) {
                try self.appendCollisionDiagnostic("provider", name, self.providers.items[idx].extension_path, extension_path);
                return;
            }
            var removed = self.providers.orderedRemove(idx);
            removed.deinit(self.allocator);
        }

        const owned_models = try self.allocator.alloc(ProviderModel, models.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_models[0..initialized]) |*m| m.deinit(self.allocator);
            self.allocator.free(owned_models);
        }
        for (models, 0..) |m, idx| {
            owned_models[idx] = .{
                .id = try self.allocator.dupe(u8, m.id),
                .name = try self.allocator.dupe(u8, m.name),
            };
            initialized = idx + 1;
        }

        const display_dup = if (display_name) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (display_dup) |n| self.allocator.free(n);
        const base_dup = if (base_url) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (base_dup) |n| self.allocator.free(n);
        const api_dup = if (api) |n| try self.allocator.dupe(u8, n) else null;
        errdefer if (api_dup) |n| self.allocator.free(n);

        var oauth_dup: ?ProviderOAuth = null;
        if (oauth) |o| {
            oauth_dup = .{
                .name = try self.allocator.dupe(u8, o.name),
            };
        }
        errdefer if (oauth_dup) |*o| o.deinit(self.allocator);

        const provider: ExtensionProvider = .{
            .name = try self.allocator.dupe(u8, name),
            .display_name = display_dup,
            .base_url = base_dup,
            .api = api_dup,
            .models = owned_models,
            .extension_path = try self.allocator.dupe(u8, extension_path),
            .oauth = oauth_dup,
            .headers = headers,
            .auth_header = auth_header,
            .api_key_configured = api_key_configured,
        };
        try self.providers.append(self.allocator, provider);
    }

    pub fn unregisterProvider(self: *Registry, name: []const u8) bool {
        if (self.findProviderIndex(name)) |idx| {
            var removed = self.providers.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    /// Remove static registrations owned by one extension path before a
    /// reload or replacement replays that extension's register_* frames.
    /// UI hooks and widgets are intentionally left to
    /// clearUiHooksForReload because they have separate lifecycle
    /// semantics.
    pub fn clearStaticRegistrationsForExtension(self: *Registry, extension_path: []const u8) void {
        inline for (&[_][]const u8{
            "tools",
            "commands",
            "shortcuts",
            "flags",
            "providers",
            "capabilities",
            "workflow_surface_diagnostics",
            "message_renderers",
            "hooks",
            "resource_discoveries",
        }) |field_name| {
            var index = @field(self, field_name).items.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, @field(self, field_name).items[index].extension_path, extension_path)) {
                    var removed = @field(self, field_name).orderedRemove(index);
                    removed.deinit(self.allocator);
                }
            }
        }

        var workflow_index = self.workflows.items.len;
        while (workflow_index > 0) {
            workflow_index -= 1;
            if (std.mem.eql(u8, self.workflows.items[workflow_index].extension_path, extension_path)) {
                self.clearWorkflowSurfaceDiagnostics(self.workflows.items[workflow_index].id, extension_path);
                var removed = self.workflows.orderedRemove(workflow_index);
                removed.deinit(self.allocator);
            }
        }

        self.removeCollisionDiagnosticsForExtension(extension_path);
    }

    /// Set the parsed CLI value for a registered flag. Mirrors the TS
    /// `extensionState.flags[name] = value` step the runtime performs
    /// after parsing the CLI. Returns `true` when the flag is known
    /// (the value is stored regardless of registration order, but
    /// callers should register the flag first).
    pub fn setFlagValue(self: *Registry, name: []const u8, value: FlagDefaultInput) !bool {
        const idx = self.findFlagIndex(name) orelse return false;
        var new_value: FlagDefault = switch (value) {
            .none => .none,
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
        };
        errdefer new_value.deinit(self.allocator);
        self.flags.items[idx].cli_value.deinit(self.allocator);
        self.flags.items[idx].cli_value = new_value;
        return true;
    }

    /// Return the resolved flag value: explicit CLI value if set, else
    /// the registered default, else `.none`. The returned `.string`
    /// borrow is valid for the registry lifetime.
    pub fn getFlag(self: *const Registry, name: []const u8) FlagValue {
        const idx = self.findFlagIndex(name) orelse return .none;
        const flag = self.flags.items[idx];
        switch (flag.cli_value) {
            .boolean => |b| return .{ .boolean = b },
            .string => |s| return .{ .string = s },
            .none => {},
        }
        return switch (flag.default_value) {
            .none => .none,
            .boolean => |b| .{ .boolean = b },
            .string => |s| .{ .string = s },
        };
    }

    pub fn recordUiRequest(self: *Registry, id: []const u8) !void {
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.ui_request_ids.append(self.allocator, owned);
    }

    /// Install the extension header hook. Replaces any previous header
    /// hook (TS `setHeader` is single-slot per runtime).
    pub fn setHeaderHook(
        self: *Registry,
        lines: []const []const u8,
        extension_path: []const u8,
    ) !void {
        var owned_lines = try self.allocator.alloc([]u8, lines.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_lines[0..initialized]) |line| self.allocator.free(line);
            self.allocator.free(owned_lines);
        }
        for (lines, 0..) |line, idx| {
            owned_lines[idx] = try self.allocator.dupe(u8, line);
            initialized = idx + 1;
        }
        const path_dup = try self.allocator.dupe(u8, extension_path);
        if (self.header_hook) |*existing| existing.deinit(self.allocator);
        self.header_hook = .{ .lines = owned_lines, .extension_path = path_dup };
    }

    /// Remove the extension header hook (TS `setHeader(undefined)` /
    /// session replacement clears the hook).
    pub fn clearHeaderHook(self: *Registry) bool {
        if (self.header_hook) |*existing| {
            existing.deinit(self.allocator);
            self.header_hook = null;
            return true;
        }
        return false;
    }

    /// Install the extension footer hook. Replaces any previous footer
    /// hook (TS `setFooter` is single-slot per runtime).
    pub fn setFooterHook(
        self: *Registry,
        lines: []const []const u8,
        extension_path: []const u8,
    ) !void {
        var owned_lines = try self.allocator.alloc([]u8, lines.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_lines[0..initialized]) |line| self.allocator.free(line);
            self.allocator.free(owned_lines);
        }
        for (lines, 0..) |line, idx| {
            owned_lines[idx] = try self.allocator.dupe(u8, line);
            initialized = idx + 1;
        }
        const path_dup = try self.allocator.dupe(u8, extension_path);
        if (self.footer_hook) |*existing| existing.deinit(self.allocator);
        self.footer_hook = .{ .lines = owned_lines, .extension_path = path_dup };
    }

    pub fn clearFooterHook(self: *Registry) bool {
        if (self.footer_hook) |*existing| {
            existing.deinit(self.allocator);
            self.footer_hook = null;
            return true;
        }
        return false;
    }

    /// Register a terminal input subscription with a stable id. Later
    /// frames with the same id replace the previous behavior so
    /// extensions can change consume/transform behavior at runtime.
    pub fn registerTerminalInput(
        self: *Registry,
        id: []const u8,
        consume: bool,
        transform_to: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        // Replace existing subscription with the same id (TS unsubscribe
        // is by closure identity, but the JSONL protocol surfaces the
        // id explicitly so the runtime can route updates).
        for (self.terminal_input_subs.items, 0..) |*sub, idx| {
            if (std.mem.eql(u8, sub.id, id)) {
                sub.deinit(self.allocator);
                self.terminal_input_subs.items[idx] = try makeTerminalInputSubscription(self.allocator, id, consume, transform_to, extension_path);
                return;
            }
        }
        const sub = try makeTerminalInputSubscription(self.allocator, id, consume, transform_to, extension_path);
        try self.terminal_input_subs.append(self.allocator, sub);
    }

    /// Remove a terminal input subscription by id. Mirrors calling the
    /// TS unsubscribe closure returned from `onTerminalInput`. Returns
    /// `true` when an entry was removed.
    pub fn unregisterTerminalInput(self: *Registry, id: []const u8) bool {
        for (self.terminal_input_subs.items, 0..) |*sub, idx| {
            if (std.mem.eql(u8, sub.id, id)) {
                var removed = self.terminal_input_subs.orderedRemove(idx);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Apply terminal input bytes through the registered subscriptions
    /// in registration order. Mirrors TS behavior:
    ///   * If a subscription returns `{ consume: true }`, propagation
    ///     stops and the default editor does not see the bytes.
    ///   * If a subscription returns `{ data: <new> }` without consume,
    ///     the bytes are rewritten and propagation continues to later
    ///     subscriptions and finally the default editor.
    ///   * If a subscription returns nothing, propagation continues
    ///     unchanged.
    /// `scratch` is filled with owned bytes when a transform happens
    /// across multiple subscriptions; the returned `data` slice
    /// borrows from `scratch.items` or the original `bytes` slice.
    pub fn applyTerminalInput(
        self: *Registry,
        bytes: []const u8,
        scratch: *std.ArrayList(u8),
    ) !TerminalInputResult {
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(self.allocator, bytes);
        var consumed = false;
        for (self.terminal_input_subs.items) |sub| {
            if (sub.consume) {
                consumed = true;
                break;
            }
            if (sub.transform_to) |new_data| {
                scratch.clearRetainingCapacity();
                try scratch.appendSlice(self.allocator, new_data);
            }
        }
        return .{ .consumed = consumed, .data = scratch.items };
    }

    /// Install the custom editor component hook. Replaces any previous
    /// editor hook (TS `setEditorComponent` is single-slot per runtime).
    pub fn setEditorComponentHook(
        self: *Registry,
        label: []const u8,
        extension_path: []const u8,
    ) !void {
        const label_dup = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(label_dup);
        const path_dup = try self.allocator.dupe(u8, extension_path);
        if (self.editor_component_hook) |*existing| existing.deinit(self.allocator);
        self.editor_component_hook = .{ .label = label_dup, .extension_path = path_dup };
    }

    pub fn clearEditorComponentHook(self: *Registry) bool {
        if (self.editor_component_hook) |*existing| {
            existing.deinit(self.allocator);
            self.editor_component_hook = null;
            return true;
        }
        return false;
    }

    /// Install or replace a widget hook (TS `setWidget`). Replaces any
    /// existing widget with the same key.
    pub fn setWidgetHook(
        self: *Registry,
        key: []const u8,
        lines: []const []const u8,
        placement: WidgetPlacement,
        extension_path: []const u8,
    ) !void {
        if (isSubAgentReservedName(key)) return error.ReservedSubAgentName;
        // Replace existing widget with the same key
        for (self.widgets.items, 0..) |*widget, idx| {
            if (std.mem.eql(u8, widget.key, key)) {
                widget.deinit(self.allocator);
                self.widgets.items[idx] = try makeWidgetHook(self.allocator, key, lines, placement, extension_path);
                return;
            }
        }
        const widget = try makeWidgetHook(self.allocator, key, lines, placement, extension_path);
        try self.widgets.append(self.allocator, widget);
    }

    /// Remove a widget by key. Returns true if a widget was removed.
    pub fn clearWidgetHook(self: *Registry, key: []const u8) bool {
        for (self.widgets.items, 0..) |*widget, idx| {
            if (std.mem.eql(u8, widget.key, key)) {
                var removed = self.widgets.orderedRemove(idx);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    /// Remove all widgets for a given extension path.
    pub fn clearWidgetsForExtension(self: *Registry, extension_path: []const u8) void {
        var i: usize = self.widgets.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.widgets.items[i].extension_path, extension_path)) {
                var removed = self.widgets.orderedRemove(i);
                removed.deinit(self.allocator);
            }
        }
    }

    /// Drop every UI hook that should not survive an extension reload
    /// or session replacement. This mirrors the TS interactive runtime
    /// teardown that clears extension header/footer factories,
    /// extension terminal input listeners, and the custom editor
    /// component before re-binding extensions on the new session.
    /// Static registrations (tools, commands, shortcuts, flags,
    /// providers) are left intact and re-asserted by the next round of
    /// register_* frames; UI hooks are NOT, by design.
    pub fn clearUiHooksForReload(self: *Registry) void {
        if (self.header_hook) |*existing| {
            existing.deinit(self.allocator);
            self.header_hook = null;
        }
        if (self.footer_hook) |*existing| {
            existing.deinit(self.allocator);
            self.footer_hook = null;
        }
        for (self.terminal_input_subs.items) |*sub| sub.deinit(self.allocator);
        self.terminal_input_subs.clearRetainingCapacity();
        if (self.editor_component_hook) |*existing| {
            existing.deinit(self.allocator);
            self.editor_component_hook = null;
        }
        for (self.widgets.items) |*widget| widget.deinit(self.allocator);
        self.widgets.clearRetainingCapacity();
    }
};

pub const RegistrySurfaceCounts = struct {
    tools: usize,
    commands: usize,
    shortcuts: usize,
    flags: usize,
    providers: usize,
    capabilities: usize,
    workflows: usize,
    resource_discoveries: usize,
    header_hooks: usize,
    footer_hooks: usize,
    terminal_input_subscriptions: usize,
    editor_component_hooks: usize,
    widgets: usize,
    hooks: usize,
    message_renderers: usize,
    ui_request_ids: usize,
};

fn isSubAgentReservedName(name: []const u8) bool {
    return std.mem.eql(u8, name, "sub_agent.delegate") or
        std.mem.eql(u8, name, "sub_agent.readiness") or
        std.mem.eql(u8, name, "sub_agent.delegation.result") or
        std.mem.eql(u8, name, "sub_agent.status") or
        std.mem.eql(u8, name, "sub_agent_readiness") or
        std.mem.eql(u8, name, "sub-agent") or
        std.mem.eql(u8, name, "/sub-agent") or
        std.mem.startsWith(u8, name, "sub_agent.");
}

pub fn registrySurfaceNames() []const []const u8 {
    return &.{
        "tools",
        "commands",
        "shortcuts",
        "flags",
        "providers",
        "capabilities",
        "workflows",
        "resourceDiscoveries",
        "headerHook",
        "footerHook",
        "terminalInputSubscriptions",
        "editorComponentHook",
        "widgets",
        "hooks",
        "messageRenderers",
        "uiRequestIds",
    };
}

pub fn registrySurfaceCounts(registry: *const Registry) RegistrySurfaceCounts {
    return .{
        .tools = registry.tools.items.len,
        .commands = registry.commands.items.len,
        .shortcuts = registry.shortcuts.items.len,
        .flags = registry.flags.items.len,
        .providers = registry.providers.items.len,
        .capabilities = registry.capabilities.items.len,
        .workflows = registry.workflows.items.len,
        .resource_discoveries = registry.resource_discoveries.items.len,
        .header_hooks = if (registry.header_hook != null) 1 else 0,
        .footer_hooks = if (registry.footer_hook != null) 1 else 0,
        .terminal_input_subscriptions = registry.terminal_input_subs.items.len,
        .editor_component_hooks = if (registry.editor_component_hook != null) 1 else 0,
        .widgets = registry.widgets.items.len,
        .hooks = registry.hooks.items.len,
        .message_renderers = registry.message_renderers.items.len,
        .ui_request_ids = registry.ui_request_ids.items.len,
    };
}

fn makeTerminalInputSubscription(
    allocator: std.mem.Allocator,
    id: []const u8,
    consume: bool,
    transform_to: ?[]const u8,
    extension_path: []const u8,
) !TerminalInputSubscription {
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const transform_dup = if (transform_to) |t| try allocator.dupe(u8, t) else null;
    errdefer if (transform_dup) |t| allocator.free(t);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .id = id_dup,
        .consume = consume,
        .transform_to = transform_dup,
        .extension_path = path_dup,
    };
}

fn makeWidgetHook(
    allocator: std.mem.Allocator,
    key: []const u8,
    lines: []const []const u8,
    placement: WidgetPlacement,
    extension_path: []const u8,
) !WidgetHook {
    const key_dup = try allocator.dupe(u8, key);
    errdefer allocator.free(key_dup);
    var owned_lines = try allocator.alloc([]u8, lines.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_lines[0..initialized]) |line| allocator.free(line);
        allocator.free(owned_lines);
    }
    for (lines, 0..) |line, idx| {
        owned_lines[idx] = try allocator.dupe(u8, line);
        initialized = idx + 1;
    }
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .key = key_dup,
        .lines = owned_lines,
        .placement = placement,
        .extension_path = path_dup,
    };
}

fn makeMessageRenderer(
    allocator: std.mem.Allocator,
    custom_type: []const u8,
    extension_path: []const u8,
) !MessageRenderer {
    const type_dup = try allocator.dupe(u8, custom_type);
    errdefer allocator.free(type_dup);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .custom_type = type_dup,
        .extension_path = path_dup,
    };
}

/// Lightweight provider/model descriptor used as input to
/// `Registry.registerProvider`. Strings are borrowed; the registry
/// owns its own copies.
pub const ProviderModelInput = struct {
    id: []const u8,
    name: []const u8,
};

/// Input variant of `FlagDefault` whose string is borrowed. `Registry`
/// always clones what it stores; the caller retains ownership of any
/// `.string` payload it passed in.
pub const FlagDefaultInput = union(enum) {
    none,
    boolean: bool,
    string: []const u8,
};

/// CLI-parsed flag value the runtime layer hands back to the registry
/// after parsing `--<name> [value]`. The string payload is borrowed;
/// `Registry.setFlagValue` clones what it stores.
pub const ParsedCliFlag = struct {
    name: []const u8,
    value: FlagDefaultInput,
};

fn makeTool(
    allocator: std.mem.Allocator,
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    execution_mode: ?[]const u8,
    render_shell: ?[]const u8,
    extension_path: []const u8,
) !ExtensionTool {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const label_dup = try allocator.dupe(u8, label);
    errdefer allocator.free(label_dup);
    const desc_dup = try allocator.dupe(u8, description);
    errdefer allocator.free(desc_dup);
    const parameters_dup = try common.cloneJsonValue(allocator, parameters);
    errdefer common.deinitJsonValue(allocator, parameters_dup);
    const execution_mode_dup = if (execution_mode) |mode| try allocator.dupe(u8, mode) else null;
    errdefer if (execution_mode_dup) |mode| allocator.free(mode);
    const render_shell_dup = if (render_shell) |mode| try allocator.dupe(u8, mode) else null;
    errdefer if (render_shell_dup) |mode| allocator.free(mode);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .name = name_dup,
        .label = label_dup,
        .description = desc_dup,
        .parameters = parameters_dup,
        .extension_path = path_dup,
        .execution_mode = execution_mode_dup,
        .render_shell = render_shell_dup,
    };
}

fn makeCommand(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: ?[]const u8,
    extension_path: []const u8,
) !ExtensionCommand {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const desc_dup = if (description) |d| try allocator.dupe(u8, d) else null;
    errdefer if (desc_dup) |d| allocator.free(d);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .name = name_dup,
        .description = desc_dup,
        .extension_path = path_dup,
    };
}

fn makeShortcut(
    allocator: std.mem.Allocator,
    shortcut: []const u8,
    description: ?[]const u8,
    command: ?[]const u8,
    extension_path: []const u8,
) !ExtensionShortcut {
    const sc_dup = try allocator.dupe(u8, shortcut);
    errdefer allocator.free(sc_dup);
    const desc_dup = if (description) |d| try allocator.dupe(u8, d) else null;
    errdefer if (desc_dup) |d| allocator.free(d);
    const cmd_dup = if (command) |c| try allocator.dupe(u8, c) else null;
    errdefer if (cmd_dup) |c| allocator.free(c);
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .shortcut = sc_dup,
        .description = desc_dup,
        .command = cmd_dup,
        .extension_path = path_dup,
    };
}

fn makeCapability(
    allocator: std.mem.Allocator,
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    description: ?[]const u8,
    command: ?[]const u8,
    resource_path: ?[]const u8,
    extension_path: []const u8,
) !ExtensionCapability {
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const kind_dup = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_dup);
    const title_dup = try allocator.dupe(u8, title);
    errdefer allocator.free(title_dup);
    const description_dup = try allocator.dupe(u8, description orelse "");
    errdefer allocator.free(description_dup);
    const command_dup = if (command) |value| try allocator.dupe(u8, value) else null;
    errdefer if (command_dup) |value| allocator.free(value);
    const resource_path_dup = if (resource_path) |value| try allocator.dupe(u8, value) else null;
    errdefer if (resource_path_dup) |value| allocator.free(value);
    const extension_path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .id = id_dup,
        .kind = kind_dup,
        .title = title_dup,
        .description = description_dup,
        .command = command_dup,
        .resource_path = resource_path_dup,
        .extension_path = extension_path_dup,
    };
}

fn makeWorkflow(
    allocator: std.mem.Allocator,
    id: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    output_schema: std.json.Value,
    execution_mode: []const u8,
    permissions: std.json.Value,
    dependencies: std.json.Value,
    timeout_ms: u64,
    cancellation: std.json.Value,
    replay: std.json.Value,
    child_agent_limits: std.json.Value,
    steps: std.json.Value,
    command_name: ?[]const u8,
    tool_name: ?[]const u8,
    preset_id: ?[]const u8,
    extension_path: []const u8,
) !ExtensionWorkflow {
    const id_dup = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dup);
    const description_dup = try allocator.dupe(u8, description);
    errdefer allocator.free(description_dup);
    const input_schema_dup = try common.cloneJsonValue(allocator, input_schema);
    errdefer common.deinitJsonValue(allocator, input_schema_dup);
    const output_schema_dup = try common.cloneJsonValue(allocator, output_schema);
    errdefer common.deinitJsonValue(allocator, output_schema_dup);
    const execution_mode_dup = try allocator.dupe(u8, execution_mode);
    errdefer allocator.free(execution_mode_dup);
    const permissions_dup = try common.cloneJsonValue(allocator, permissions);
    errdefer common.deinitJsonValue(allocator, permissions_dup);
    const dependencies_dup = try common.cloneJsonValue(allocator, dependencies);
    errdefer common.deinitJsonValue(allocator, dependencies_dup);
    const cancellation_dup = try common.cloneJsonValue(allocator, cancellation);
    errdefer common.deinitJsonValue(allocator, cancellation_dup);
    const replay_dup = try common.cloneJsonValue(allocator, replay);
    errdefer common.deinitJsonValue(allocator, replay_dup);
    const child_agent_limits_dup = try common.cloneJsonValue(allocator, child_agent_limits);
    errdefer common.deinitJsonValue(allocator, child_agent_limits_dup);
    const steps_dup = try common.cloneJsonValue(allocator, steps);
    errdefer common.deinitJsonValue(allocator, steps_dup);
    const command_name_dup = if (command_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (command_name_dup) |value| allocator.free(value);
    const tool_name_dup = if (tool_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (tool_name_dup) |value| allocator.free(value);
    const preset_id_dup = if (preset_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (preset_id_dup) |value| allocator.free(value);
    const extension_path_dup = try allocator.dupe(u8, extension_path);

    return .{
        .id = id_dup,
        .description = description_dup,
        .input_schema = input_schema_dup,
        .output_schema = output_schema_dup,
        .execution_mode = execution_mode_dup,
        .permissions = permissions_dup,
        .dependencies = dependencies_dup,
        .timeout_ms = timeout_ms,
        .cancellation = cancellation_dup,
        .replay = replay_dup,
        .child_agent_limits = child_agent_limits_dup,
        .steps = steps_dup,
        .command_name = command_name_dup,
        .tool_name = tool_name_dup,
        .preset_id = preset_id_dup,
        .extension_path = extension_path_dup,
    };
}

fn makeFlag(
    allocator: std.mem.Allocator,
    name: []const u8,
    type_kind: FlagKind,
    description: ?[]const u8,
    default_value: FlagDefaultInput,
    extension_path: []const u8,
) !ExtensionFlag {
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const desc_dup = if (description) |d| try allocator.dupe(u8, d) else null;
    errdefer if (desc_dup) |d| allocator.free(d);
    const default_dup: FlagDefault = switch (default_value) {
        .none => .none,
        .boolean => |b| .{ .boolean = b },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
    errdefer {
        var d = default_dup;
        d.deinit(allocator);
    }
    const path_dup = try allocator.dupe(u8, extension_path);
    return .{
        .name = name_dup,
        .description = desc_dup,
        .type_kind = type_kind,
        .default_value = default_dup,
        .extension_path = path_dup,
    };
}

/// Render a deterministic JSON snapshot of the registry to `writer` for
/// CLI/TS-RPC observability. Snapshot construction lives in
/// `extension_registry_snapshot.zig`; this wrapper preserves the registry API
/// used by host/runtime callers while keeping mutation logic in this module.
pub fn writeRegistrySnapshotJson(
    allocator: std.mem.Allocator,
    registry: *const Registry,
    writer: *std.Io.Writer,
) !void {
    try extension_registry_snapshot.writeRegistrySnapshotJson(allocator, registry, writer);
}

/// Outcome of feeding a single JSONL frame into the registry. Used by
/// fixture tests (and the live host driver) to surface deterministic
/// diagnostics for unsupported / malformed register frames without
/// aborting the whole stream.
pub const FrameOutcome = enum {
    none,
    registered_tool,
    registered_command,
    registered_shortcut,
    registered_flag,
    registered_provider,
    unregistered_provider,
    registered_capability,
    unregistered_capability,
    registered_workflow,
    unregistered_workflow,
    registered_hook,
    unregistered_hook,
    resources_discovered,
    set_header_hook,
    cleared_header_hook,
    set_footer_hook,
    cleared_footer_hook,
    registered_terminal_input,
    unregistered_terminal_input,
    set_editor_component_hook,
    cleared_editor_component_hook,
    set_widget_hook,
    cleared_widget_hook,
    cleared_ui_hooks_for_reload,
    cleared_extension_registrations,
    registered_message_renderer,
    unregistered_message_renderer,
    ignored_unsupported,
    ignored_malformed,
    ignored_collision,
};

/// Apply a single JSONL host frame (already JSON-decoded) to the
/// registry. Unknown / malformed frames are reported via the returned
/// `FrameOutcome` rather than throwing so a single bad frame does not
/// break the whole extension stream.
pub fn applyHostFrame(
    registry: *Registry,
    frame: std.json.Value,
) !FrameOutcome {
    if (frame != .object) return .ignored_malformed;
    const object = frame.object;

    const type_value = object.get("type") orelse return .ignored_malformed;
    if (type_value != .string) return .ignored_malformed;
    const type_name = type_value.string;

    const extension_path = optionalString(object, "extensionPath") orelse "";

    if (std.mem.eql(u8, type_name, "register_tool")) return try applyRegisterToolFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "register_command")) return try applyRegisterCommandFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "register_shortcut")) return try applyRegisterShortcutFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "register_flag")) return try applyRegisterFlagFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "register_provider")) return try applyRegisterProviderFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "unregister_provider")) return applyUnregisterProviderFrame(registry, object);
    if (std.mem.eql(u8, type_name, "register_capability")) return try applyRegisterCapabilityFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "unregister_capability")) return applyUnregisterCapabilityFrame(registry, object);
    if (std.mem.eql(u8, type_name, "register_workflow")) return try applyRegisterWorkflowFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "unregister_workflow")) return applyUnregisterWorkflowFrame(registry, object);
    if (std.mem.eql(u8, type_name, "register_hook")) return try applyRegisterHookFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "unregister_hook")) return applyUnregisterHookFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "resources_discover")) return try applyResourcesDiscoverFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "extension_ui_request")) return try applyExtensionUiRequestFrame(registry, object);
    if (std.mem.eql(u8, type_name, "set_header")) return try applySetHeaderFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "clear_header")) return applyClearHeaderFrame(registry);
    if (std.mem.eql(u8, type_name, "set_footer")) return try applySetFooterFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "clear_footer")) return applyClearFooterFrame(registry);
    if (std.mem.eql(u8, type_name, "register_terminal_input")) return try applyRegisterTerminalInputFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "unregister_terminal_input")) return applyUnregisterTerminalInputFrame(registry, object);
    if (std.mem.eql(u8, type_name, "set_editor_component")) return try applySetEditorComponentFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "clear_editor_component")) return applyClearEditorComponentFrame(registry);
    if (std.mem.eql(u8, type_name, "set_widget")) return try applySetWidgetFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "clear_widget")) return applyClearWidgetFrame(registry, object);
    if (std.mem.eql(u8, type_name, "clear_ui_hooks_for_reload")) return applyClearUiHooksForReloadFrame(registry);
    if (std.mem.eql(u8, type_name, "clear_extension_registrations")) return applyClearExtensionRegistrationsFrame(registry, object);
    if (std.mem.eql(u8, type_name, "register_message_renderer")) return try applyRegisterMessageRendererFrame(registry, object, extension_path);
    if (std.mem.eql(u8, type_name, "unregister_message_renderer")) return applyUnregisterMessageRendererFrame(registry, object);

    return .ignored_unsupported;
}

fn applyRegisterToolFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const name = optionalString(object, "name") orelse return .ignored_malformed;
    if (isSubAgentReservedName(name)) return .ignored_malformed;
    const label = optionalString(object, "label") orelse name;
    const description = optionalString(object, "description") orelse "";
    const parameters = object.get("parameters") orelse .null;
    const execution_mode = optionalString(object, "executionMode");
    const render_shell = optionalString(object, "renderShell");
    const collision_count_before = registry.collision_diagnostics.items.len;
    try registry.registerToolFull(name, label, description, parameters, execution_mode, render_shell, extension_path);
    if (registry.collision_diagnostics.items.len != collision_count_before) return .ignored_collision;
    try applyToolRenderHook(registry, object, name, extension_path);
    return .registered_tool;
}

fn applyToolRenderHook(registry: *Registry, object: std.json.ObjectMap, name: []const u8, extension_path: []const u8) !void {
    const idx = registry.findToolIndex(name) orelse return;
    const render_hook_val = object.get("renderHook") orelse return;
    if (render_hook_val != .object) return;

    var render_config_buf: std.Io.Writer.Allocating = .init(registry.allocator);
    defer render_config_buf.deinit();
    try std.json.Stringify.value(render_hook_val, .{}, &render_config_buf.writer);

    const render_config = try registry.allocator.dupe(u8, render_config_buf.written());
    errdefer registry.allocator.free(render_config);
    const tool_name = try registry.allocator.dupe(u8, name);
    errdefer registry.allocator.free(tool_name);
    const hook_extension_path = try registry.allocator.dupe(u8, extension_path);
    errdefer registry.allocator.free(hook_extension_path);

    registry.tools.items[idx].render_hook = .{
        .render_config = render_config,
        .tool_name = tool_name,
        .extension_path = hook_extension_path,
    };
}

fn applyRegisterCommandFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const name = optionalString(object, "name") orelse return .ignored_malformed;
    if (isSubAgentReservedName(name)) return .ignored_malformed;
    const description = optionalString(object, "description");
    const collision_count_before = registry.collision_diagnostics.items.len;
    try registry.registerCommand(name, description, extension_path);
    if (registry.collision_diagnostics.items.len != collision_count_before) return .ignored_collision;
    return .registered_command;
}

fn applyRegisterShortcutFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const shortcut = optionalString(object, "shortcut") orelse return .ignored_malformed;
    const description = optionalString(object, "description");
    const command = optionalString(object, "command");
    try registry.registerShortcut(shortcut, description, command, extension_path);
    return .registered_shortcut;
}

fn applyRegisterFlagFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const name = optionalString(object, "name") orelse return .ignored_malformed;
    const type_kind = parseFlagKind(optionalString(object, "valueType") orelse optionalString(object, "type") orelse "boolean") orelse return .ignored_malformed;
    const description = optionalString(object, "description");
    const default_value = parseFlagDefault(object);
    const collision_count_before = registry.collision_diagnostics.items.len;
    try registry.registerFlag(name, type_kind, description, default_value, extension_path);
    if (registry.collision_diagnostics.items.len != collision_count_before) return .ignored_collision;
    return .registered_flag;
}

fn parseFlagDefault(object: std.json.ObjectMap) FlagDefaultInput {
    const default_val = object.get("default") orelse return .none;
    return switch (default_val) {
        .bool => |b| .{ .boolean = b },
        .string => |s| .{ .string = s },
        else => .none,
    };
}

fn applyRegisterProviderFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const name = optionalString(object, "name") orelse return .ignored_malformed;
    const display_name = optionalString(object, "displayName");
    const base_url = optionalString(object, "baseUrl");
    const api = optionalString(object, "api");

    var inputs = std.ArrayList(ProviderModelInput).empty;
    defer inputs.deinit(registry.allocator);
    try collectProviderModelInputs(registry.allocator, object, &inputs);

    const auth_header = optionalBool(object, "authHeader") orelse false;
    const api_key_configured = (optionalBool(object, "apiKeyConfigured") orelse false) or object.get("apiKey") != null;

    const collision_count_before = registry.collision_diagnostics.items.len;
    try registry.registerProviderFullWithAuthState(name, display_name, base_url, api, inputs.items, extension_path, null, null, auth_header, api_key_configured);
    if (registry.collision_diagnostics.items.len != collision_count_before) return .ignored_collision;
    try applyProviderOAuthFrame(registry, object, name);
    return .registered_provider;
}

fn collectProviderModelInputs(allocator: std.mem.Allocator, object: std.json.ObjectMap, inputs: *std.ArrayList(ProviderModelInput)) !void {
    const models_value = object.get("models") orelse return;
    if (models_value != .array) return;
    for (models_value.array.items) |model_value| {
        if (model_value != .object) continue;
        const id = optionalString(model_value.object, "id") orelse continue;
        const display = optionalString(model_value.object, "name") orelse id;
        try inputs.append(allocator, .{ .id = id, .name = display });
    }
}

fn applyProviderOAuthFrame(registry: *Registry, object: std.json.ObjectMap, name: []const u8) !void {
    const oauth_val = object.get("oauth") orelse return;
    if (oauth_val != .object) return;
    const idx = registry.findProviderIndex(name) orelse return;

    const oauth_name = optionalString(oauth_val.object, "name") orelse name;
    const oauth_name_dup = try registry.allocator.dupe(u8, oauth_name);
    errdefer registry.allocator.free(oauth_name_dup);
    registry.providers.items[idx].oauth = .{
        .name = oauth_name_dup,
    };
}

fn applyUnregisterProviderFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const name = optionalString(object, "name") orelse return .ignored_malformed;
    _ = registry.unregisterProvider(name);
    return .unregistered_provider;
}

fn applyRegisterCapabilityFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const id = optionalString(object, "id") orelse return .ignored_malformed;
    if (isSubAgentReservedName(id)) return .ignored_malformed;
    const kind = optionalString(object, "kind") orelse return .ignored_malformed;
    const title = optionalString(object, "title") orelse return .ignored_malformed;
    const description = optionalString(object, "description");
    const command = optionalString(object, "command");
    if (command != null and isSubAgentReservedName(command.?)) return .ignored_malformed;
    const resource_path = optionalString(object, "resourcePath");
    if (resource_path != null and isSubAgentReservedName(resource_path.?)) return .ignored_malformed;
    const collision_count_before = registry.collision_diagnostics.items.len;
    try registry.registerCapability(id, kind, title, description, command, resource_path, extension_path);
    if (registry.collision_diagnostics.items.len != collision_count_before) return .ignored_collision;
    return .registered_capability;
}

fn applyUnregisterCapabilityFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const id = optionalString(object, "id") orelse return .ignored_malformed;
    _ = registry.unregisterCapability(id);
    return .unregistered_capability;
}

fn applyRegisterWorkflowFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const id = optionalString(object, "id") orelse return .ignored_malformed;
    const description = optionalString(object, "description") orelse "";
    const input_schema = optionalObjectValue(object, "inputSchema") orelse optionalObjectValue(object, "parameters") orelse try emptyObjectJsonValue(registry.allocator);
    defer if (object.get("inputSchema") == null and object.get("parameters") == null) common.deinitJsonValue(registry.allocator, input_schema);
    const output_schema = optionalObjectValue(object, "outputSchema") orelse try emptyObjectJsonValue(registry.allocator);
    defer if (object.get("outputSchema") == null) common.deinitJsonValue(registry.allocator, output_schema);
    const execution_mode = optionalString(object, "executionMode") orelse "agent";
    const timeout_ms = optionalUnsigned64(object, "timeoutMs") orelse 30000;
    const permissions = optionalArrayValue(object, "permissions") orelse try emptyArrayJsonValue(registry.allocator);
    defer if (object.get("permissions") == null) common.deinitJsonValue(registry.allocator, permissions);
    const dependencies = optionalArrayValue(object, "dependencies") orelse try emptyArrayJsonValue(registry.allocator);
    defer if (object.get("dependencies") == null) common.deinitJsonValue(registry.allocator, dependencies);
    const cancellation = optionalObjectValue(object, "cancellation") orelse try defaultCancellationJsonValue(registry.allocator);
    defer if (object.get("cancellation") == null) common.deinitJsonValue(registry.allocator, cancellation);
    const replay = optionalObjectValue(object, "replay") orelse try defaultReplayJsonValue(registry.allocator);
    defer if (object.get("replay") == null) common.deinitJsonValue(registry.allocator, replay);
    const child_agent_limits = optionalObjectValue(object, "childAgentLimits") orelse try defaultChildAgentLimitsJsonValue(registry.allocator, timeout_ms);
    defer if (object.get("childAgentLimits") == null) common.deinitJsonValue(registry.allocator, child_agent_limits);
    const steps = optionalArrayValue(object, "steps") orelse try emptyArrayJsonValue(registry.allocator);
    defer if (object.get("steps") == null) common.deinitJsonValue(registry.allocator, steps);
    const exposure = object.get("exposure");

    registry.clearWorkflowSurfaceDiagnostics(id, extension_path);
    const workflow_denial = workflowPolicyDenial(object);
    const command_name = try resolveWorkflowSurfaceName(registry, object, exposure, workflow_denial, id, "command", "commandName", id, extension_path);
    const tool_name = try resolveWorkflowSurfaceName(registry, object, exposure, workflow_denial, id, "tool", "toolName", id, extension_path);
    const preset_id = try resolveWorkflowSurfaceName(registry, object, exposure, workflow_denial, id, "subAgentPreset", "presetId", id, extension_path);

    try registry.registerWorkflowFull(
        id,
        description,
        input_schema,
        output_schema,
        execution_mode,
        permissions,
        dependencies,
        timeout_ms,
        cancellation,
        replay,
        child_agent_limits,
        steps,
        command_name,
        tool_name,
        preset_id,
        extension_path,
    );
    return .registered_workflow;
}

fn applyUnregisterWorkflowFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const id = optionalString(object, "id") orelse return .ignored_malformed;
    _ = registry.unregisterWorkflow(id);
    return .unregistered_workflow;
}

fn applyRegisterHookFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const event_name = optionalString(object, "event") orelse optionalString(object, "eventName") orelse return .ignored_malformed;
    const priority = optionalInteger(object, "priority") orelse optionalInteger(object, "order") orelse 0;
    const declaration_order = optionalUnsigned(object, "declarationOrder") orelse optionalUnsigned(object, "declaration_order");
    const error_policy = parseHookErrorPolicy(object);
    try registry.registerHookFull(event_name, extension_path, priority, declaration_order, error_policy);
    return .registered_hook;
}

fn applyUnregisterHookFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) FrameOutcome {
    const event_name = optionalString(object, "event") orelse optionalString(object, "eventName") orelse return .ignored_malformed;
    _ = registry.unregisterHook(event_name, extension_path);
    return .unregistered_hook;
}

fn applyResourcesDiscoverFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    var discovery = ResourceDiscovery{
        .extension_path = try registry.allocator.dupe(u8, extension_path),
    };
    errdefer discovery.deinit(registry.allocator);

    try appendResourcePathFrameItems(registry.allocator, object, "skillPaths", &discovery.skill_paths);
    try appendResourcePathFrameItems(registry.allocator, object, "promptPaths", &discovery.prompt_paths);
    try appendResourcePathFrameItems(registry.allocator, object, "themePaths", &discovery.theme_paths);

    try registry.resource_discoveries.append(registry.allocator, discovery);
    return .resources_discovered;
}

fn appendResourcePathFrameItems(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
    list: *std.ArrayList([]u8),
) !void {
    const paths = object.get(field) orelse return;
    if (paths != .array) return;
    for (paths.array.items) |item| {
        if (item != .string) continue;
        const owned_path = try allocator.dupe(u8, item.string);
        errdefer allocator.free(owned_path);
        try list.append(allocator, owned_path);
    }
}

fn applyExtensionUiRequestFrame(registry: *Registry, object: std.json.ObjectMap) !FrameOutcome {
    if (optionalString(object, "id")) |id| {
        try registry.recordUiRequest(id);
    }
    return .none;
}

fn applySetHeaderFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const lines = try optionalLinesArray(registry.allocator, object, "lines");
    defer registry.allocator.free(lines);
    try registry.setHeaderHook(lines, extension_path);
    return .set_header_hook;
}

fn applyClearHeaderFrame(registry: *Registry) FrameOutcome {
    _ = registry.clearHeaderHook();
    return .cleared_header_hook;
}

fn applySetFooterFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const lines = try optionalLinesArray(registry.allocator, object, "lines");
    defer registry.allocator.free(lines);
    try registry.setFooterHook(lines, extension_path);
    return .set_footer_hook;
}

fn applyClearFooterFrame(registry: *Registry) FrameOutcome {
    _ = registry.clearFooterHook();
    return .cleared_footer_hook;
}

fn applyRegisterTerminalInputFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const id = optionalString(object, "id") orelse return .ignored_malformed;
    const consume = optionalBool(object, "consume") orelse false;
    const transform_to = optionalString(object, "transformTo");
    try registry.registerTerminalInput(id, consume, transform_to, extension_path);
    return .registered_terminal_input;
}

fn applyUnregisterTerminalInputFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const id = optionalString(object, "id") orelse return .ignored_malformed;
    _ = registry.unregisterTerminalInput(id);
    return .unregistered_terminal_input;
}

fn applySetEditorComponentFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const label = optionalString(object, "label") orelse return .ignored_malformed;
    try registry.setEditorComponentHook(label, extension_path);
    return .set_editor_component_hook;
}

fn applyClearEditorComponentFrame(registry: *Registry) FrameOutcome {
    _ = registry.clearEditorComponentHook();
    return .cleared_editor_component_hook;
}

fn applySetWidgetFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const key = optionalString(object, "key") orelse return .ignored_malformed;
    if (isSubAgentReservedName(key)) return .ignored_malformed;
    const lines = try optionalLinesArray(registry.allocator, object, "lines");
    defer registry.allocator.free(lines);
    const placement = parseWidgetPlacement(optionalString(object, "placement") orelse "aboveEditor");
    try registry.setWidgetHook(key, lines, placement, extension_path);
    return .set_widget_hook;
}

fn parseWidgetPlacement(placement: []const u8) WidgetPlacement {
    if (std.mem.eql(u8, placement, "belowEditor")) return .below_editor;
    return .above_editor;
}

fn applyClearWidgetFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const key = optionalString(object, "key") orelse return .ignored_malformed;
    _ = registry.clearWidgetHook(key);
    return .cleared_widget_hook;
}

fn applyClearUiHooksForReloadFrame(registry: *Registry) FrameOutcome {
    registry.clearUiHooksForReload();
    return .cleared_ui_hooks_for_reload;
}

fn applyClearExtensionRegistrationsFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const target_extension_path = optionalString(object, "extensionPath") orelse return .ignored_malformed;
    registry.clearStaticRegistrationsForExtension(target_extension_path);
    return .cleared_extension_registrations;
}

fn applyRegisterMessageRendererFrame(registry: *Registry, object: std.json.ObjectMap, extension_path: []const u8) !FrameOutcome {
    const custom_type = optionalString(object, "customType") orelse return .ignored_malformed;
    if (isSubAgentReservedName(custom_type)) return .ignored_malformed;
    const collision_count_before = registry.collision_diagnostics.items.len;
    try registry.registerMessageRenderer(custom_type, extension_path);
    if (registry.collision_diagnostics.items.len != collision_count_before) return .ignored_collision;
    return .registered_message_renderer;
}

fn applyUnregisterMessageRendererFrame(registry: *Registry, object: std.json.ObjectMap) FrameOutcome {
    const custom_type = optionalString(object, "customType") orelse return .ignored_malformed;
    _ = registry.unregisterMessageRenderer(custom_type);
    return .unregistered_message_renderer;
}

fn optionalBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn optionalObjectValue(object: std.json.ObjectMap, field: []const u8) ?std.json.Value {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .object => value,
        else => null,
    };
}

fn optionalArrayValue(object: std.json.ObjectMap, field: []const u8) ?std.json.Value {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .array => value,
        else => null,
    };
}

fn optionalInteger(object: std.json.ObjectMap, field: []const u8) ?i64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn optionalUnsigned(object: std.json.ObjectMap, field: []const u8) ?usize {
    const number = optionalInteger(object, field) orelse return null;
    if (number < 0) return null;
    return @intCast(number);
}

fn optionalUnsigned64(object: std.json.ObjectMap, field: []const u8) ?u64 {
    const number = optionalInteger(object, field) orelse return null;
    if (number < 0) return null;
    return @intCast(number);
}

const WorkflowDenial = struct {
    path: []const u8,
    message: []const u8,
};

fn resolveWorkflowSurfaceName(
    registry: *Registry,
    object: std.json.ObjectMap,
    maybe_exposure: ?std.json.Value,
    workflow_denial: ?WorkflowDenial,
    workflow_id: []const u8,
    exposure_field: []const u8,
    direct_field: []const u8,
    default_name: []const u8,
    extension_path: []const u8,
) !?[]const u8 {
    const direct_name = optionalString(object, direct_field);
    const exposure = maybe_exposure orelse {
        if (workflow_denial) |denial| {
            if (direct_name) |name| try registry.appendWorkflowSurfaceDiagnostic(workflow_id, exposure_field, name, extension_path, denial.path, denial.message);
            return null;
        }
        return direct_name;
    };
    if (exposure != .object) {
        if (workflow_denial) |denial| {
            if (direct_name) |name| try registry.appendWorkflowSurfaceDiagnostic(workflow_id, exposure_field, name, extension_path, denial.path, denial.message);
            return null;
        }
        return direct_name;
    }
    const surface = exposure.object.get(exposure_field) orelse {
        if (workflow_denial) |denial| {
            if (direct_name) |name| try registry.appendWorkflowSurfaceDiagnostic(workflow_id, exposure_field, name, extension_path, denial.path, denial.message);
            return null;
        }
        return direct_name;
    };
    const requested_name = direct_name orelse surfaceNameForDiagnostic(surface, default_name);
    if (workflow_denial) |denial| {
        if (requested_name) |name| try registry.appendWorkflowSurfaceDiagnostic(workflow_id, exposure_field, name, extension_path, denial.path, denial.message);
        return null;
    }
    if (surfacePolicyDenial(surface, exposure_field)) |denial| {
        if (requested_name) |name| try registry.appendWorkflowSurfaceDiagnostic(workflow_id, exposure_field, name, extension_path, denial.path, denial.message);
        return null;
    }
    if (direct_name) |name| return name;
    return surfaceNameFromExposure(surface, default_name);
}

fn surfaceNameFromExposure(surface: std.json.Value, default_name: []const u8) ?[]const u8 {
    return switch (surface) {
        .bool => |enabled| if (enabled) default_name else null,
        .string => |name| name,
        .object => |surface_object| blk: {
            if (entryPolicyDenied(.{ .object = surface_object })) break :blk null;
            break :blk optionalString(surface_object, "name") orelse optionalString(surface_object, "id") orelse default_name;
        },
        else => null,
    };
}

fn surfaceNameForDiagnostic(surface: std.json.Value, default_name: []const u8) ?[]const u8 {
    return switch (surface) {
        .bool => |enabled| if (enabled) default_name else null,
        .string => |name| name,
        .object => |surface_object| optionalString(surface_object, "name") orelse optionalString(surface_object, "id") orelse default_name,
        else => null,
    };
}

fn workflowPolicyDenial(object: std.json.ObjectMap) ?WorkflowDenial {
    if (entryPolicyDenied(.{ .object = object })) return .{
        .path = "$.policy",
        .message = "workflow exposure denied by workflow policy",
    };
    if (object.get("permissions")) |permissions| {
        switch (permissions) {
            .object => |permission_object| if (entryPolicyDenied(.{ .object = permission_object })) return .{
                .path = "$.permissions",
                .message = "workflow exposure denied by workflow permission policy",
            },
            .array => |permission_array| {
                for (permission_array.items) |permission| {
                    if (entryPolicyDenied(permission)) return .{
                        .path = "$.permissions",
                        .message = "workflow exposure denied by workflow permission policy",
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

fn surfacePolicyDenial(surface: std.json.Value, exposure_field: []const u8) ?WorkflowDenial {
    return switch (surface) {
        .bool => |enabled| if (!enabled) .{
            .path = surfacePolicyPath(exposure_field),
            .message = "workflow surface disabled by exposure policy",
        } else null,
        .object => |surface_object| if (entryPolicyDenied(.{ .object = surface_object })) .{
            .path = surfacePolicyPath(exposure_field),
            .message = "workflow surface denied by exposure policy",
        } else null,
        else => null,
    };
}

fn surfacePolicyPath(exposure_field: []const u8) []const u8 {
    if (std.mem.eql(u8, exposure_field, "command")) return "$.exposure.command";
    if (std.mem.eql(u8, exposure_field, "tool")) return "$.exposure.tool";
    if (std.mem.eql(u8, exposure_field, "subAgentPreset")) return "$.exposure.subAgentPreset";
    return "$.exposure";
}

fn entryPolicyDenied(value: std.json.Value) bool {
    if (value != .object) return false;
    if (optionalBool(value.object, "denied") orelse false) return true;
    if (optionalBool(value.object, "policyDenied") orelse false) return true;
    const policy = value.object.get("policy") orelse return false;
    if (policy != .object) return false;
    if (policy.object.get("approved")) |approved| {
        if (approved == .bool and !approved.bool) return true;
    }
    if (policy.object.get("decision")) |decision| {
        if (decision == .string and (std.mem.eql(u8, decision.string, "deny") or std.mem.eql(u8, decision.string, "denied"))) return true;
    }
    return false;
}

fn emptyObjectJsonValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
}

fn emptyArrayJsonValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

fn defaultCancellationJsonValue(allocator: std.mem.Allocator) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putBool(allocator, &object, "propagate", true);
    return .{ .object = object };
}

fn defaultReplayJsonValue(allocator: std.mem.Allocator) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putBool(allocator, &object, "enabled", true);
    try common.putString(allocator, &object, "mode", "recorded");
    return .{ .object = object };
}

fn defaultChildAgentLimitsJsonValue(allocator: std.mem.Allocator, timeout_ms: u64) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putInt(allocator, &object, "maxChildren", 1);
    try common.putInt(allocator, &object, "maxTurns", 1);
    try common.putInt(allocator, &object, "maxToolCalls", 0);
    try common.putInt(allocator, &object, "maxTokens", 0);
    try common.putInt(allocator, &object, "timeoutMs", @intCast(timeout_ms));
    return .{ .object = object };
}

fn parseHookErrorPolicy(object: std.json.ObjectMap) HookErrorPolicy {
    if (optionalBool(object, "fatal") orelse false) return .fatal;
    const policy = optionalString(object, "errorPolicy") orelse
        optionalString(object, "error_policy") orelse
        optionalString(object, "onError") orelse
        optionalString(object, "on_error") orelse
        return .@"continue";
    if (std.mem.eql(u8, policy, "fatal") or std.mem.eql(u8, policy, "abort") or std.mem.eql(u8, policy, "fail")) return .fatal;
    return .@"continue";
}

fn optionalLinesArray(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) ![][]const u8 {
    const value = object.get(field) orelse return try allocator.alloc([]const u8, 0);
    if (value != .array) return try allocator.alloc([]const u8, 0);
    var collected = std.ArrayList([]const u8).empty;
    defer collected.deinit(allocator);
    for (value.array.items) |item| {
        if (item != .string) continue;
        try collected.append(allocator, item.string);
    }
    return try collected.toOwnedSlice(allocator);
}

/// Load and apply registration frames from a deterministic local
/// sidecar manifest next to a Bun-hosted extension entry. This is the
/// local fixture compatibility hook used by M11 registration tests;
/// live Bun extensions will produce the same frames over the JSONL
/// stdout protocol.
///
/// Tries `<extension>.registry.jsonl` first (file-extension form), then
/// `<extension>/registry.jsonl` for directory-style extensions.
pub fn loadFromExtensionPaths(
    registry: *Registry,
    io: std.Io,
    extension_paths: []const []const u8,
) !void {
    for (extension_paths) |path| {
        const manifest_text = readManifestForPath(registry.allocator, io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer registry.allocator.free(manifest_text);
        _ = try applyHostFrameStream(registry, manifest_text);
    }
}

fn readManifestForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const sidecar = try std.fmt.allocPrint(allocator, "{s}.registry.jsonl", .{path});
    defer allocator.free(sidecar);

    if (std.Io.Dir.readFileAlloc(.cwd(), io, sidecar, allocator, .limited(256 * 1024))) |bytes| {
        return bytes;
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => {},
        else => return err,
    }

    const dir_manifest = try std.fs.path.join(allocator, &[_][]const u8{ path, "registry.jsonl" });
    defer allocator.free(dir_manifest);
    return std.Io.Dir.readFileAlloc(.cwd(), io, dir_manifest, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.NotDir, error.IsDir => return error.FileNotFound,
        else => return err,
    };
}

/// Feed a buffer of JSONL frames (one JSON object per line) into the
/// registry. Returns the number of frames successfully applied.
pub fn applyHostFrameStream(
    registry: *Registry,
    bytes: []const u8,
) !usize {
    var applied: usize = 0;
    var iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (iterator.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, registry.allocator, trimmed, .{}) catch continue;
        defer parsed.deinit();
        const outcome = try applyHostFrame(registry, parsed.value);
        switch (outcome) {
            .none, .ignored_unsupported, .ignored_malformed, .ignored_collision => {},
            else => applied += 1,
        }
    }
    return applied;
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn parseFlagKind(name: []const u8) ?FlagKind {
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "string")) return .string;
    return null;
}

pub fn deinitResolvedCommands(allocator: std.mem.Allocator, commands: []ResolvedCommand) void {
    for (commands) |command| allocator.free(command.invocation_name);
    allocator.free(commands);
}

fn resolvedInvocationTaken(commands: []const ResolvedCommand, invocation_name: []const u8) bool {
    for (commands) |command| {
        if (std.mem.eql(u8, command.invocation_name, invocation_name)) return true;
    }
    return false;
}

fn appendShortcutDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(ShortcutDiagnostic),
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(message);
    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);
    try diagnostics.append(allocator, .{
        .message = message,
        .path = path_dup,
    });
}

fn findBuiltinShortcut(builtins: []const BuiltinShortcutBinding, shortcut: []const u8) ?BuiltinShortcutBinding {
    for (builtins) |builtin| {
        if (asciiEqlIgnoreCase(builtin.shortcut, shortcut)) return builtin;
    }
    return null;
}

fn findResolvedShortcutIndex(shortcuts: []const ResolvedShortcut, shortcut: []const u8) ?usize {
    for (shortcuts, 0..) |existing, idx| {
        if (asciiEqlIgnoreCase(existing.shortcut, shortcut)) return idx;
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test {
    _ = @import("extension_registry/tests.zig");
}
