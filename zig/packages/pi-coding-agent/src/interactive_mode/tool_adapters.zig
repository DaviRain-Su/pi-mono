const runtime_tool_registry = @import("../runtime/tool_registry.zig");

pub const AppContext = runtime_tool_registry.AppContext;
pub const BuiltTools = runtime_tool_registry.BuiltTools;
pub const ToolBuildOptions = runtime_tool_registry.ToolBuildOptions;
pub const ExtensionBootstrapContributions = runtime_tool_registry.ExtensionBootstrapContributions;
pub const ExtensionStartupDiagnostic = runtime_tool_registry.ExtensionStartupDiagnostic;
pub const ExtensionStartupSeverity = runtime_tool_registry.ExtensionStartupSeverity;
pub const ExtensionToolHostOptions = runtime_tool_registry.ExtensionToolHostOptions;
pub const ProviderCollisionDiagnostic = runtime_tool_registry.ProviderCollisionDiagnostic;
pub const BashToolUpdateForwardContext = runtime_tool_registry.BashToolUpdateForwardContext;

pub const buildAgentTools = runtime_tool_registry.buildAgentTools;
pub const buildAgentToolsWithOptions = runtime_tool_registry.buildAgentToolsWithOptions;
pub const buildAgentToolsWithSelection = runtime_tool_registry.buildAgentToolsWithSelection;
pub const buildAgentToolsWithExtensions = runtime_tool_registry.buildAgentToolsWithExtensions;
pub const buildAgentToolsWithExtensionsSelection = runtime_tool_registry.buildAgentToolsWithExtensionsSelection;
pub const registerExtensionProvidersAndCollectResources = runtime_tool_registry.registerExtensionProvidersAndCollectResources;
pub const replaceAgentToolsForReload = runtime_tool_registry.replaceAgentToolsForReload;
pub const writeStartupDiagnostics = runtime_tool_registry.writeStartupDiagnostics;
pub const pathExists = runtime_tool_registry.pathExists;
pub const forwardBashToolUpdate = runtime_tool_registry.forwardBashToolUpdate;

test {
    _ = @import("../runtime/tool_registry.zig");
}
