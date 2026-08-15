const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tools = @import("../tools/root.zig");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const shared = @import("../interactive_mode/shared.zig");
const tool_selection_mod = @import("../tool_selection.zig");

pub const AppContext = shared.AppContext;

pub const BuiltTools = struct {
    allocator: std.mem.Allocator,
    items: []agent.AgentTool,
    extension_hosts: []extension_runtime.RuntimeAdapter = &.{},
    startup_diagnostics: []ExtensionStartupDiagnostic = &.{},
    startup_manifest_registry_snapshot: ?[]u8 = null,
    required_startup_failed: bool = false,

    pub fn deinit(self: *BuiltTools) void {
        for (self.items) |item| {
            common.deinitJsonValue(self.allocator, item.parameters);
            if (item.deinit_execute_context) |deinit_context| {
                deinit_context(self.allocator, item.execute_context);
            }
        }
        self.allocator.free(self.items);
        for (self.extension_hosts) |host| host.deinit();
        if (self.extension_hosts.len > 0) self.allocator.free(self.extension_hosts);
        for (self.startup_diagnostics) |*diagnostic| diagnostic.deinit(self.allocator);
        if (self.startup_diagnostics.len > 0) self.allocator.free(self.startup_diagnostics);
        if (self.startup_manifest_registry_snapshot) |snapshot| self.allocator.free(snapshot);
        self.* = undefined;
    }
};

pub const ToolBuildOptions = struct {
    selected_tools: tool_selection_mod.ToolSelection = .{},
    include_builtin_tools: bool = true,
    include_installed_wasm_tools: bool = false,
    include_installed_native_tools: bool = false,
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    resource_options: ?resources_mod.ResolveResourcesOptions = null,
    extension_options: ExtensionToolHostOptions = .{},
};

pub const ExtensionStartupSeverity = enum {
    info,
    warning,
    @"error",

    pub fn jsonName(self: ExtensionStartupSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const ExtensionStartupDiagnostic = struct {
    severity: ExtensionStartupSeverity,
    phase: []u8,
    extension_id: []u8,
    extension_path: []u8,
    source_path: []u8,
    policy_key: ?[]u8 = null,
    required: bool = false,
    message: []u8,

    pub fn deinit(self: *ExtensionStartupDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.phase);
        allocator.free(self.extension_id);
        allocator.free(self.extension_path);
        allocator.free(self.source_path);
        if (self.policy_key) |policy_key| allocator.free(policy_key);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ExtensionToolHostOptions = struct {
    extensions: []const resources_mod.LoadedExtension = &.{},
    env_map: ?*const std.process.Environ.Map = null,
    cwd: []const u8 = "",
    io: ?std.Io = null,
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    start_without_tools: bool = false,
    include_builtin_tools: bool = true,
    include_installed_wasm_tools: bool = false,
    include_installed_native_tools: bool = false,
    resource_options: ?resources_mod.ResolveResourcesOptions = null,
};

pub fn buildAgentTools(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selected_tools: ?[]const []const u8,
) !BuiltTools {
    return buildAgentToolsWithOptions(allocator, app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(selected_tools),
    });
}

pub fn buildAgentToolsWithOptions(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    options: ToolBuildOptions,
) !BuiltTools {
    var extension_options = options.extension_options;
    extension_options.include_builtin_tools = options.include_builtin_tools;
    return buildAgentToolsWithExtensionsSelection(allocator, app_context, options.selected_tools, extension_options);
}

pub fn buildAgentToolsWithSelection(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selection: tool_selection_mod.ToolSelection,
) !BuiltTools {
    return buildAgentToolsWithExtensionsSelection(allocator, app_context, selection, .{});
}

pub fn buildAgentToolsWithExtensions(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selected_tools: ?[]const []const u8,
    extension_options: ExtensionToolHostOptions,
) !BuiltTools {
    return buildAgentToolsWithExtensionsSelection(
        allocator,
        app_context,
        tool_selection_mod.ToolSelection.fromAllowlist(selected_tools),
        extension_options,
    );
}

pub fn buildAgentToolsWithExtensionsSelection(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    selection: tool_selection_mod.ToolSelection,
    extension_options: ExtensionToolHostOptions,
) !BuiltTools {
    var items = std.ArrayList(agent.AgentTool).empty;
    errdefer deinitToolItems(allocator, items.items);

    if (extension_options.include_builtin_tools) {
        inline for (tools.ALL, 0..) |ToolT, i| {
            try appendToolIfEnabled(allocator, &items, app_context, selection, ToolT.name, ToolT.description, try ToolT.schema(allocator), BUILTIN_TOOL_EXECUTORS[i]);
        }
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn deinitToolItems(allocator: std.mem.Allocator, items: []agent.AgentTool) void {
    for (items) |item| {
        common.deinitJsonValue(allocator, item.parameters);
        if (item.deinit_execute_context) |deinit_context| {
            deinit_context(allocator, item.execute_context);
        }
    }
}

pub fn writeStartupDiagnostics(stderr: *std.Io.Writer, diagnostics: []const ExtensionStartupDiagnostic) !void {
    for (diagnostics) |diagnostic| {
        const prefix = switch (diagnostic.severity) {
            .info => "Info",
            .warning => "Warning",
            .@"error" => "Error",
        };
        try stderr.print("{s}: extension disabled in Zig runtime: {s}\n", .{ prefix, diagnostic.message });
    }
}

pub const ExtensionBootstrapContributions = struct {
    allocator: std.mem.Allocator,
    provider_names: [][]u8 = &.{},
    provider_diagnostics: []ProviderCollisionDiagnostic = &.{},
    resource_discoveries: []resources_mod.ExtensionDiscoveredResources = &.{},

    pub fn deinit(self: *ExtensionBootstrapContributions) void {
        for (self.provider_names) |name| {
            ai.model_registry.unregisterProvider(name);
            self.allocator.free(name);
        }
        if (self.provider_names.len > 0) self.allocator.free(self.provider_names);
        for (self.provider_diagnostics) |*diagnostic| diagnostic.deinit(self.allocator);
        if (self.provider_diagnostics.len > 0) self.allocator.free(self.provider_diagnostics);
        for (self.resource_discoveries) |*discovery| {
            self.allocator.free(@constCast(discovery.extension_path));
            discovery.source_info.deinit(self.allocator);
            freeStringConstList(self.allocator, discovery.skill_paths);
            freeStringConstList(self.allocator, discovery.prompt_paths);
            freeStringConstList(self.allocator, discovery.theme_paths);
        }
        if (self.resource_discoveries.len > 0) self.allocator.free(self.resource_discoveries);
        self.* = undefined;
    }
};

pub const ProviderCollisionDiagnostic = struct {
    code: []u8,
    severity: []u8,
    provider_id: []u8,
    extension_path: []u8,
    source_path: []u8,
    conflict_kind: []u8,
    conflict_with: []u8,
    message: []u8,

    pub fn deinit(self: *ProviderCollisionDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.severity);
        allocator.free(self.provider_id);
        allocator.free(self.extension_path);
        allocator.free(self.source_path);
        allocator.free(self.conflict_kind);
        allocator.free(self.conflict_with);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn registerExtensionProvidersAndCollectResources(
    allocator: std.mem.Allocator,
    built_tools: *const BuiltTools,
    extensions: []const resources_mod.LoadedExtension,
) !ExtensionBootstrapContributions {
    _ = built_tools;
    _ = extensions;
    return .{ .allocator = allocator };
}

pub fn replaceAgentToolsForReload(
    allocator: std.mem.Allocator,
    app_context: *AppContext,
    session: *session_mod.AgentSession,
    built_tools: *BuiltTools,
    selection: tool_selection_mod.ToolSelection,
    extension_options: ExtensionToolHostOptions,
) !void {
    var next_tools = try buildAgentToolsWithExtensionsSelection(
        allocator,
        app_context,
        selection,
        extension_options,
    );
    errdefer next_tools.deinit();

    try session.agent.setTools(next_tools.items);

    var previous_tools = built_tools.*;
    built_tools.* = next_tools;
    previous_tools.deinit();
}

fn appendToolIfEnabled(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    app_context: *AppContext,
    selection: tool_selection_mod.ToolSelection,
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
    execute: agent.types.ExecuteToolFn,
) !void {
    if (!selection.allowsBuiltin(name)) {
        common.deinitJsonValue(allocator, schema);
        return;
    }

    try items.append(allocator, .{
        .name = name,
        .description = description,
        .label = name,
        .parameters = schema,
        .source = .builtin,
        .execute = execute,
        .execute_context = app_context,
    });
}

fn freeStringConstList(allocator: std.mem.Allocator, values: []const []const u8) void {
    if (values.len == 0) return;
    for (values) |value| allocator.free(@constCast(value));
    allocator.free(values);
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn getAppContext(tool_context: ?*anyopaque) !*AppContext {
    return @ptrCast(@alignCast(tool_context orelse return error.InvalidToolContext));
}

const BUILTIN_TOOL_EXECUTORS = blk: {
    var arr: [tools.ALL.len]agent.types.ExecuteToolFn = undefined;
    var seen_names: [tools.ALL.len][]const u8 = undefined;
    for (tools.ALL, 0..) |T, i| {
        for (seen_names[0..i]) |existing| {
            if (std.mem.eql(u8, existing, T.name)) {
                @compileError("duplicate built-in tool name in tools.ALL: " ++ T.name);
            }
        }
        seen_names[i] = T.name;
        arr[i] = if (@hasDecl(T, "use_default_adapter") and !T.use_default_adapter)
            customExecutorFor(T)
        else
            defaultToolAdapter(T);
    }
    break :blk arr;
};

fn customExecutorFor(comptime T: type) agent.types.ExecuteToolFn {
    if (T == tools.BashTool) return runBashTool;
    if (T == tools.EditTool) return runEditTool;
    @compileError("Tool " ++ T.name ++ " opts out of the default adapter but no custom executor is wired in customExecutorFor.");
}

fn defaultToolAdapter(comptime T: type) agent.types.ExecuteToolFn {
    const ArgsT = @typeInfo(@TypeOf(T.execute)).@"fn".params[2].type.?;
    return struct {
        fn run(
            allocator: std.mem.Allocator,
            _: []const u8,
            params: std.json.Value,
            tool_context: ?*anyopaque,
            _: ?*const std.atomic.Value(bool),
            _: ?*anyopaque,
            _: ?agent.types.AgentToolUpdateCallback,
        ) !agent.AgentToolResult {
            const runtime = (try getAppContext(tool_context)).tool_runtime;
            const args = try tools.parseArgsFromJson(ArgsT, allocator, params);
            const result = try T.init(runtime.cwd, runtime.io).execute(allocator, args);
            return .{ .content = result.content };
        }
    }.run;
}

fn runBashTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    const args = try tools.parseArgsFromJson(tools.BashArgs, allocator, params);
    var update_forward = BashToolUpdateForwardContext{
        .allocator = allocator,
        .downstream_context = on_update_context,
        .downstream = on_update,
    };
    var result = try tools.BashTool.init(runtime.cwd, runtime.io).executeWithUpdates(
        allocator,
        args,
        signal,
        &update_forward,
        forwardBashToolUpdate,
    );
    defer if (result.details) |*details| details.deinit(allocator);
    return .{
        .content = result.content,
        .details = if (result.details) |details| try tools.bash.detailsToJsonValue(allocator, details) else null,
    };
}

pub const BashToolUpdateForwardContext = struct {
    allocator: std.mem.Allocator,
    downstream_context: ?*anyopaque,
    downstream: ?agent.types.AgentToolUpdateCallback,
};

pub fn forwardBashToolUpdate(
    context: ?*anyopaque,
    result: tools.BashExecutionResult,
) !void {
    const forward_context: *BashToolUpdateForwardContext = @ptrCast(@alignCast(context.?));
    const callback = forward_context.downstream orelse return;
    const details = if (result.details) |details_value|
        try tools.bash.detailsToJsonValue(forward_context.allocator, details_value)
    else
        null;
    defer if (details) |details_value| common.deinitJsonValue(forward_context.allocator, details_value);

    const partial = agent.AgentToolResult{
        .content = result.content,
        .details = details,
    };

    try callback(forward_context.downstream_context, partial);
}

fn runEditTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = (try getAppContext(tool_context)).tool_runtime;
    var parsed_args_storage = try tools.edit.parseArguments(allocator, params);
    defer parsed_args_storage.deinit(allocator);
    const edit_args = parsed_args_storage.toArgs();
    const result = try tools.EditTool.init(runtime.cwd, runtime.io).execute(allocator, edit_args);
    return .{ .content = result.content };
}

test "runtime tool registry forwards built-in tool construction" {
    var app_context = AppContext.init(".", std.testing.io);
    var built_tools = try buildAgentTools(std.testing.allocator, &app_context, &.{"read"});
    defer built_tools.deinit();

    try std.testing.expectEqual(@as(usize, 1), built_tools.items.len);
    try std.testing.expectEqualStrings("read", built_tools.items[0].name);
}
