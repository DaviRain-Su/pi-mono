const std = @import("std");
const config_errors = @import("../config/config_errors.zig");
const theme_mod = @import("shared").theme;

pub const SourceScope = enum {
    temporary,
    project,
    user,
};

pub const SourceOrigin = enum {
    top_level,
    package,
};

pub const SourceProvenanceBinding = struct {
    lock_entry_key: []u8,
    source_identity: []u8,
    package_root: []u8,
    package_root_sha256: []u8,
    artifact_sha256: ?[]u8 = null,

    pub fn clone(self: SourceProvenanceBinding, allocator: std.mem.Allocator) !SourceProvenanceBinding {
        return .{
            .lock_entry_key = try allocator.dupe(u8, self.lock_entry_key),
            .source_identity = try allocator.dupe(u8, self.source_identity),
            .package_root = try allocator.dupe(u8, self.package_root),
            .package_root_sha256 = try allocator.dupe(u8, self.package_root_sha256),
            .artifact_sha256 = if (self.artifact_sha256) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *SourceProvenanceBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.lock_entry_key);
        allocator.free(self.source_identity);
        allocator.free(self.package_root);
        allocator.free(self.package_root_sha256);
        if (self.artifact_sha256) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ResourceKind = enum {
    extension,
    skill,
    prompt,
    theme,

    pub fn directoryName(self: ResourceKind) []const u8 {
        return switch (self) {
            .extension => "extensions",
            .skill => "skills",
            .prompt => "prompts",
            .theme => "themes",
        };
    }

    pub fn fileExtension(self: ResourceKind) []const u8 {
        return switch (self) {
            .extension => ".ts",
            .skill => ".md",
            .prompt => ".md",
            .theme => ".json",
        };
    }

    pub fn singularName(self: ResourceKind) []const u8 {
        return switch (self) {
            .extension => "extension",
            .skill => "skill",
            .prompt => "prompt",
            .theme => "theme",
        };
    }
};

pub const Diagnostic = struct {
    kind: []u8,
    message: []u8,
    path: ?[]u8 = null,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.message);
        if (self.path) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SourceInfo = struct {
    path: []u8,
    source: []u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: ?[]u8 = null,
    provenance: ?SourceProvenanceBinding = null,

    pub fn clone(self: SourceInfo, allocator: std.mem.Allocator) !SourceInfo {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .source = try allocator.dupe(u8, self.source),
            .scope = self.scope,
            .origin = self.origin,
            .base_dir = if (self.base_dir) |value| try allocator.dupe(u8, value) else null,
            .provenance = if (self.provenance) |value| try value.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *SourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        if (self.base_dir) |value| allocator.free(value);
        if (self.provenance) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResolvedResource = struct {
    path: []u8,
    enabled: bool,
    source_info: SourceInfo,
    discovery_index: usize = 0,

    pub fn deinit(self: *ResolvedResource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResolvedPaths = struct {
    extensions: []ResolvedResource,
    skills: []ResolvedResource,
    prompts: []ResolvedResource,
    themes: []ResolvedResource,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *ResolvedPaths, allocator: std.mem.Allocator) void {
        deinitResolvedSlice(allocator, self.extensions);
        deinitResolvedSlice(allocator, self.skills);
        deinitResolvedSlice(allocator, self.prompts);
        deinitResolvedSlice(allocator, self.themes);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const PackageSourceConfig = struct {
    source: []u8,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,

    pub fn clone(self: PackageSourceConfig, allocator: std.mem.Allocator) !PackageSourceConfig {
        return .{
            .source = try allocator.dupe(u8, self.source),
            .extensions = try cloneStringList(allocator, self.extensions),
            .skills = try cloneStringList(allocator, self.skills),
            .prompts = try cloneStringList(allocator, self.prompts),
            .themes = try cloneStringList(allocator, self.themes),
        };
    }

    pub fn deinit(self: *PackageSourceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        freeStringList(allocator, self.extensions);
        freeStringList(allocator, self.skills);
        freeStringList(allocator, self.prompts);
        freeStringList(allocator, self.themes);
        self.* = undefined;
    }
};

pub const SettingsResources = struct {
    packages: ?[]const PackageSourceConfig = null,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,
    theme: ?[]const u8 = null,
};

pub const ExtensionDiscoveredResources = struct {
    extension_path: []const u8,
    source_info: SourceInfo,
    skill_paths: []const []const u8 = &.{},
    prompt_paths: []const []const u8 = &.{},
    theme_paths: []const []const u8 = &.{},
};

pub const LoadedExtension = struct {
    path: []u8,
    source_info: SourceInfo,

    pub fn deinit(self: *LoadedExtension, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const Skill = struct {
    name: []u8,
    description: []u8,
    file_path: []u8,
    base_dir: []u8,
    source_info: SourceInfo,
    disable_model_invocation: bool = false,

    pub fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.file_path);
        allocator.free(self.base_dir);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const PromptTemplate = struct {
    name: []u8,
    description: []u8,
    argument_hint: ?[]u8 = null,
    content: []u8,
    file_path: []u8,
    source_info: SourceInfo,

    pub fn deinit(self: *PromptTemplate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.argument_hint) |value| allocator.free(value);
        allocator.free(self.content);
        allocator.free(self.file_path);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const ThemeColor = theme_mod.ThemeColor;
pub const ThemeToken = theme_mod.ThemeToken;
pub const StyleSpec = theme_mod.StyleSpec;
pub const ThemeColors = theme_mod.ThemeColors;
pub const Theme = theme_mod.Theme;

pub const ResourceBundle = struct {
    extensions: []LoadedExtension,
    skills: []Skill,
    prompt_templates: []PromptTemplate,
    themes: []Theme,
    selected_theme_index: usize,
    diagnostics: []Diagnostic,
    config_errors: []config_errors.ConfigError = &.{},
    terminal_name: []u8,

    pub fn deinit(self: *ResourceBundle, allocator: std.mem.Allocator) void {
        for (self.extensions) |*item| item.deinit(allocator);
        allocator.free(self.extensions);
        for (self.skills) |*item| item.deinit(allocator);
        allocator.free(self.skills);
        for (self.prompt_templates) |*item| item.deinit(allocator);
        allocator.free(self.prompt_templates);
        for (self.themes) |*item| item.deinit(allocator);
        allocator.free(self.themes);
        for (self.diagnostics) |*item| item.deinit(allocator);
        allocator.free(self.diagnostics);
        config_errors.deinitSlice(allocator, self.config_errors);
        allocator.free(self.terminal_name);
        self.* = undefined;
    }

    pub fn selectedTheme(self: *const ResourceBundle) *const Theme {
        return &self.themes[@min(self.selected_theme_index, self.themes.len - 1)];
    }
};

pub const ResolveResourcesOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    global: SettingsResources = .{},
    project: SettingsResources = .{},
    cli_extensions: []const []const u8 = &.{},
    cli_skills: []const []const u8 = &.{},
    cli_prompts: []const []const u8 = &.{},
    cli_themes: []const []const u8 = &.{},
    runtime_theme: ?[]const u8 = null,
    env_map: ?*const std.process.Environ.Map = null,
    include_default_extensions: bool = true,
    include_default_skills: bool = true,
    include_default_prompts: bool = true,
    include_default_themes: bool = true,
    extension_discoveries: []const ExtensionDiscoveredResources = &.{},
};

fn cloneStringList(allocator: std.mem.Allocator, input: ?[]const []const u8) !?[]const []const u8 {
    const items = input orelse return null;
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    for (items) |item| try list.append(allocator, try allocator.dupe(u8, item));
    return try list.toOwnedSlice(allocator);
}

const freeStringList = @import("../slice_utils.zig").freeOptionalStringSlice;

fn deinitResolvedSlice(allocator: std.mem.Allocator, items: []ResolvedResource) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn deinitSkills(allocator: std.mem.Allocator, items: []Skill) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn deinitPromptTemplates(allocator: std.mem.Allocator, items: []PromptTemplate) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn deinitThemes(allocator: std.mem.Allocator, items: []Theme) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}
