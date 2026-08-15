const std = @import("std");
const config_errors = @import("../config/config_errors.zig");
const theme_mod = @import("shared").theme;

const resource_types = @import("types.zig");
const resource_commands = @import("commands.zig");
const resource_diagnostics = @import("diagnostics.zig");
const resource_environment = @import("environment.zig");
const resource_frontmatter = @import("frontmatter.zig");
const resource_files = @import("file_helpers.zig");

pub const SourceScope = resource_types.SourceScope;
pub const SourceOrigin = resource_types.SourceOrigin;
pub const SourceProvenanceBinding = resource_types.SourceProvenanceBinding;
pub const ResourceKind = resource_types.ResourceKind;
pub const Diagnostic = resource_types.Diagnostic;
pub const SourceInfo = resource_types.SourceInfo;
pub const ResolvedResource = resource_types.ResolvedResource;
pub const ResolvedPaths = resource_types.ResolvedPaths;
pub const PackageSourceConfig = resource_types.PackageSourceConfig;
pub const SettingsResources = resource_types.SettingsResources;
pub const ExtensionDiscoveredResources = resource_types.ExtensionDiscoveredResources;
pub const LoadedExtension = resource_types.LoadedExtension;
pub const Skill = resource_types.Skill;
pub const PromptTemplate = resource_types.PromptTemplate;
pub const ThemeColor = resource_types.ThemeColor;
pub const ThemeToken = resource_types.ThemeToken;
pub const StyleSpec = resource_types.StyleSpec;
pub const ThemeColors = resource_types.ThemeColors;
pub const Theme = resource_types.Theme;
pub const ResourceBundle = resource_types.ResourceBundle;
pub const ResolveResourcesOptions = resource_types.ResolveResourcesOptions;

pub const formatSkillsForPrompt = resource_commands.formatSkillsForPrompt;
pub const parseCommandArgs = resource_commands.parseCommandArgs;
pub const freeParsedArgs = resource_commands.freeParsedArgs;
pub const substituteArgs = resource_commands.substituteArgs;
pub const expandPromptTemplate = resource_commands.expandPromptTemplate;
pub const expandSkillCommand = resource_commands.expandSkillCommand;
pub const resolveThemeIndex = resource_environment.resolveThemeIndex;
pub const findThemeIndex = resource_environment.findThemeIndex;
pub const redactDiagnosticValue = resource_diagnostics.redactDiagnosticValue;

const makeDiagnostic = resource_diagnostics.makeDiagnostic;
const cloneDiagnostic = resource_diagnostics.cloneDiagnostic;
const deinitDiagnosticsList = resource_diagnostics.deinitDiagnosticsList;
const parseFrontmatter = resource_frontmatter.parseFrontmatter;
const firstNonEmptyLine = resource_frontmatter.firstNonEmptyLine;
const resolvePath = resource_files.resolvePath;
const pathExists = resource_files.pathExists;
const readOptionalFile = resource_files.readOptionalFile;
const resourceEnvValue = resource_environment.resourceEnvValue;
const detectTerminalName = resource_environment.detectTerminalName;
const deinitSkills = resource_types.deinitSkills;
const deinitPromptTemplates = resource_types.deinitPromptTemplates;
const deinitThemes = resource_types.deinitThemes;

pub fn resolveConfiguredResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResolveResourcesOptions,
) !ResolvedPaths {
    var diagnostics = std.ArrayList(Diagnostic).empty;
    errdefer deinitDiagnosticsList(allocator, &diagnostics);

    const project_base_dir = try std.fs.path.join(allocator, &[_][]const u8{ options.cwd, ".pi" });
    defer allocator.free(project_base_dir);

    var extensions = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &extensions);
    var skills = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &skills);
    var prompts = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &prompts);
    var themes = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &themes);

    try addLocalEntries(allocator, io, &extensions, &diagnostics, options.project.extensions, .extension, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });
    try addLocalEntries(allocator, io, &skills, &diagnostics, options.project.skills, .skill, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });
    try addLocalEntries(allocator, io, &prompts, &diagnostics, options.project.prompts, .prompt, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });
    try addLocalEntries(allocator, io, &themes, &diagnostics, options.project.themes, .theme, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });

    try addLocalEntries(allocator, io, &extensions, &diagnostics, options.global.extensions, .extension, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });
    try addLocalEntries(allocator, io, &skills, &diagnostics, options.global.skills, .skill, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });
    try addLocalEntries(allocator, io, &prompts, &diagnostics, options.global.prompts, .prompt, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });
    try addLocalEntries(allocator, io, &themes, &diagnostics, options.global.themes, .theme, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });

    try addPackageSources(allocator, io, &extensions, &skills, &prompts, &themes, &diagnostics, options.project.packages, .project, options.cwd, options.agent_dir);
    try addPackageSources(allocator, io, &extensions, &skills, &prompts, &themes, &diagnostics, options.global.packages, .user, options.cwd, options.agent_dir);

    if (options.include_default_extensions) try addAutoDiscovered(allocator, io, &extensions, &diagnostics, .extension, .project, project_base_dir);
    if (options.include_default_skills) try addAutoDiscovered(allocator, io, &skills, &diagnostics, .skill, .project, project_base_dir);
    if (options.include_default_skills) try addAutoDiscoveredProjectAgentSkills(allocator, io, &skills, &diagnostics, options.cwd, options.env_map);
    if (options.include_default_prompts) try addAutoDiscovered(allocator, io, &prompts, &diagnostics, .prompt, .project, project_base_dir);
    if (options.include_default_themes) try addAutoDiscovered(allocator, io, &themes, &diagnostics, .theme, .project, project_base_dir);

    if (options.include_default_extensions) try addAutoDiscovered(allocator, io, &extensions, &diagnostics, .extension, .user, options.agent_dir);
    if (options.include_default_skills) try addAutoDiscovered(allocator, io, &skills, &diagnostics, .skill, .user, options.agent_dir);
    if (options.include_default_skills) try addAutoDiscoveredUserAgentSkills(allocator, io, &skills, &diagnostics, options.env_map);
    if (options.include_default_prompts) try addAutoDiscovered(allocator, io, &prompts, &diagnostics, .prompt, .user, options.agent_dir);
    if (options.include_default_themes) try addAutoDiscovered(allocator, io, &themes, &diagnostics, .theme, .user, options.agent_dir);

    try addExtensionDiscoveredResources(allocator, io, &skills, &prompts, &themes, &diagnostics, options.extension_discoveries);

    try addLocalEntries(allocator, io, &extensions, &diagnostics, if (options.cli_extensions.len > 0) options.cli_extensions else null, .extension, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });
    try addLocalEntries(allocator, io, &skills, &diagnostics, if (options.cli_skills.len > 0) options.cli_skills else null, .skill, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });
    try addLocalEntries(allocator, io, &prompts, &diagnostics, if (options.cli_prompts.len > 0) options.cli_prompts else null, .prompt, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });
    try addLocalEntries(allocator, io, &themes, &diagnostics, if (options.cli_themes.len > 0) options.cli_themes else null, .theme, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });

    sortResolved(extensions.items);
    sortResolved(skills.items);
    sortResolved(prompts.items);
    sortResolved(themes.items);

    return .{
        .extensions = try extensions.toOwnedSlice(allocator),
        .skills = try skills.toOwnedSlice(allocator),
        .prompts = try prompts.toOwnedSlice(allocator),
        .themes = try themes.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn addExtensionDiscoveredResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    skills: *std.ArrayList(ResolvedResource),
    prompts: *std.ArrayList(ResolvedResource),
    themes: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    discoveries: []const ExtensionDiscoveredResources,
) !void {
    for (discoveries) |discovery| {
        const base_dir = discovery.source_info.base_dir orelse std.fs.path.dirname(discovery.extension_path) orelse ".";
        const seed = MetadataSeed{
            .source = "extension",
            .scope = discovery.source_info.scope,
            .origin = discovery.source_info.origin,
            .base_dir = base_dir,
        };
        try collectEntriesFromBase(allocator, io, skills, diagnostics, discovery.skill_paths, .skill, seed);
        try collectEntriesFromBase(allocator, io, prompts, diagnostics, discovery.prompt_paths, .prompt, seed);
        try collectEntriesFromBase(allocator, io, themes, diagnostics, discovery.theme_paths, .theme, seed);
    }
}

pub fn loadResourceBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResolveResourcesOptions,
) !ResourceBundle {
    var resolved = try resolveConfiguredResources(allocator, io, options);
    defer resolved.deinit(allocator);

    var extensions = std.ArrayList(LoadedExtension).empty;
    defer deinitLoadedExtensionsList(allocator, &extensions);
    for (resolved.extensions) |resource| {
        if (!resource.enabled) continue;
        try extensions.append(allocator, .{
            .path = try allocator.dupe(u8, resource.path),
            .source_info = try resource.source_info.clone(allocator),
        });
    }

    var diagnostics = std.ArrayList(Diagnostic).empty;
    defer deinitDiagnosticsList(allocator, &diagnostics);
    var collected_config_errors = std.ArrayList(config_errors.ConfigError).empty;
    errdefer config_errors.deinitList(allocator, &collected_config_errors);
    for (resolved.diagnostics) |diagnostic| {
        try diagnostics.append(allocator, try cloneDiagnostic(allocator, diagnostic));
    }

    const skills = try loadSkills(allocator, io, resolved.skills, &diagnostics, &collected_config_errors);
    errdefer deinitSkills(allocator, skills);
    const templates = try loadPromptTemplates(allocator, io, resolved.prompts, &diagnostics, &collected_config_errors);
    errdefer deinitPromptTemplates(allocator, templates);
    const themes = try loadThemes(allocator, io, resolved.themes, &diagnostics, &collected_config_errors);
    errdefer deinitThemes(allocator, themes);

    var all_themes = std.ArrayList(Theme).empty;
    errdefer deinitThemesList(allocator, &all_themes);
    for (themes) |theme| {
        try all_themes.append(allocator, theme);
    }
    allocator.free(themes);
    if (findThemeIndex(all_themes.items, "dark") == null) {
        try all_themes.append(allocator, try Theme.initDefault(allocator));
    }
    if (findThemeIndex(all_themes.items, "light") == null) {
        try all_themes.append(allocator, try Theme.initLight(allocator));
    }
    if (findThemeIndex(all_themes.items, "codex") == null) {
        try all_themes.append(allocator, try Theme.initCodex(allocator));
    }

    const selected_index = resolveThemeIndex(
        all_themes.items,
        options.env_map,
        options.runtime_theme,
        options.project.theme,
        options.global.theme,
    );
    const terminal_name = try detectTerminalName(allocator, options.env_map);
    errdefer allocator.free(terminal_name);
    const owned_config_errors = try collected_config_errors.toOwnedSlice(allocator);
    errdefer config_errors.deinitSlice(allocator, owned_config_errors);

    return .{
        .extensions = try extensions.toOwnedSlice(allocator),
        .skills = skills,
        .prompt_templates = templates,
        .themes = try all_themes.toOwnedSlice(allocator),
        .selected_theme_index = selected_index,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .config_errors = owned_config_errors,
        .terminal_name = terminal_name,
    };
}

fn defaultThemeStyles() [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec {
    var styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = undefined;
    for (&styles) |*style| style.* = .{};
    return styles;
}

const StyleTemplate = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn owned(self: StyleTemplate, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
        };
    }
};

const PaletteTemplate = struct {
    primary: []const u8,
    secondary: []const u8,
    success: []const u8,
    warning: []const u8,
    @"error": []const u8,
    background: []const u8,
    foreground: []const u8,
    border: []const u8,
    muted: []const u8,
};

fn defaultDarkPalette() PaletteTemplate {
    return .{
        .primary = "#7aa2f7",
        .secondary = "#bb9af7",
        .success = "#9ece6a",
        .warning = "#e0af68",
        .@"error" = "#f7768e",
        .background = "#1a1b26",
        .foreground = "#c0caf5",
        .border = "#414868",
        .muted = "#7f849c",
    };
}

fn defaultLightPalette() PaletteTemplate {
    return .{
        .primary = "#3451b2",
        .secondary = "#6f42c1",
        .success = "#2f8f4e",
        .warning = "#a05a00",
        .@"error" = "#c1392b",
        .background = "#f6f8fa",
        .foreground = "#1f2328",
        .border = "#afb8c1",
        .muted = "#57606a",
    };
}

fn initNamed(allocator: std.mem.Allocator, name: []const u8, palette: PaletteTemplate) !Theme {
    var theme = Theme{
        .name = try allocator.dupe(u8, name),
    };
    errdefer theme.deinit(allocator);

    try theme.setColor(allocator, .primary, palette.primary);
    try theme.setColor(allocator, .secondary, palette.secondary);
    try theme.setColor(allocator, .success, palette.success);
    try theme.setColor(allocator, .warning, palette.warning);
    try theme.setColor(allocator, .@"error", palette.@"error");
    try theme.setColor(allocator, .background, palette.background);
    try theme.setColor(allocator, .foreground, palette.foreground);
    try theme.setColor(allocator, .border, palette.border);
    try theme.setColor(allocator, .muted, palette.muted);
    try theme.applyDerivedStyles(allocator);
    return theme;
}

const ParsedSource = union(enum) {
    npm: struct {
        name: []const u8,
        spec: []const u8,
    },
    git: struct {
        normalized: []const u8,
    },
    local: struct {
        path: []const u8,
    },
};

const FilterSet = struct {
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,

    fn forKind(self: FilterSet, kind: ResourceKind) ?[]const []const u8 {
        return switch (kind) {
            .extension => self.extensions,
            .skill => self.skills,
            .prompt => self.prompts,
            .theme => self.themes,
        };
    }
};

const MetadataSeed = struct {
    source: []const u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: []const u8,
    provenance: ?SourceProvenanceBinding = null,

    fn deinit(self: *MetadataSeed, allocator: std.mem.Allocator) void {
        if (self.provenance) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

fn addPackageSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    extensions: *std.ArrayList(ResolvedResource),
    skills: *std.ArrayList(ResolvedResource),
    prompts: *std.ArrayList(ResolvedResource),
    themes: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    packages: ?[]const PackageSourceConfig,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) !void {
    const package_list = packages orelse return;
    for (package_list) |pkg| {
        const parsed = parseSource(pkg.source);
        const filter = FilterSet{
            .extensions = pkg.extensions,
            .skills = pkg.skills,
            .prompts = pkg.prompts,
            .themes = pkg.themes,
        };
        switch (parsed) {
            .local => |local| {
                const base_dir = switch (scope) {
                    .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" }),
                    .user => agent_dir,
                    .temporary => cwd,
                };
                defer if (scope == .project) allocator.free(base_dir);
                const resolved = try resolvePath(allocator, base_dir, local.path);
                defer allocator.free(resolved);
                var seed = MetadataSeed{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = resolved,
                    .provenance = try readPackageProvenanceBinding(allocator, io, scope, cwd, agent_dir, pkg.source, resolved),
                };
                defer seed.deinit(allocator);
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, resolved, filter, seed);
            },
            .npm => |npm| {
                const install_path = try npmInstallPath(allocator, scope, cwd, agent_dir, npm.name);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "npm source is not installed", install_path));
                    continue;
                }
                var seed = MetadataSeed{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = install_path,
                    .provenance = try readPackageProvenanceBinding(allocator, io, scope, cwd, agent_dir, pkg.source, install_path),
                };
                defer seed.deinit(allocator);
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, install_path, filter, seed);
            },
            .git => |git| {
                const install_path = try gitInstallPath(allocator, scope, cwd, agent_dir, git.normalized);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "git source is not installed", install_path));
                    continue;
                }
                var seed = MetadataSeed{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = install_path,
                    .provenance = try readPackageProvenanceBinding(allocator, io, scope, cwd, agent_dir, pkg.source, install_path),
                };
                defer seed.deinit(allocator);
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, install_path, filter, seed);
            },
        }
    }
}

fn collectPackageResourceRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    extensions: *std.ArrayList(ResolvedResource),
    skills: *std.ArrayList(ResolvedResource),
    prompts: *std.ArrayList(ResolvedResource),
    themes: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    filter: FilterSet,
    seed: MetadataSeed,
) !void {
    var package_manifest = try readPiManifest(allocator, io, package_root);
    defer package_manifest.deinit(allocator);

    try collectKindFromPackage(allocator, io, extensions, diagnostics, package_root, .extension, filter.forKind(.extension), package_manifest.extension_entries, seed);
    try collectKindFromPackage(allocator, io, skills, diagnostics, package_root, .skill, filter.forKind(.skill), package_manifest.skill_entries, seed);
    try collectKindFromPackage(allocator, io, prompts, diagnostics, package_root, .prompt, filter.forKind(.prompt), package_manifest.prompt_entries, seed);
    try collectKindFromPackage(allocator, io, themes, diagnostics, package_root, .theme, filter.forKind(.theme), package_manifest.theme_entries, seed);
}

const EXTENSION_PROVENANCE_LOCKFILE_NAME = "extensions.lock.json";

fn readPackageProvenanceBinding(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
    source: []const u8,
    package_root: []const u8,
) !?SourceProvenanceBinding {
    if (scope == .temporary) return null;
    const lock_path = try extensionProvenanceLockfilePath(allocator, scope, cwd, agent_dir);
    defer allocator.free(lock_path);
    const lock_text = std.Io.Dir.readFileAlloc(.cwd(), io, lock_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(lock_text);

    const key = try provenanceEntryKeyForSource(allocator, source, package_root);
    defer allocator.free(key);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, lock_text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const entries = parsed.value.object.get("entries") orelse return null;
    if (entries != .array) return null;
    for (entries.array.items) |entry| {
        if (entry != .object) continue;
        const entry_key = jsonStringField(entry.object, "key") orelse continue;
        if (!std.mem.eql(u8, entry_key, key)) continue;
        const source_object = entry.object.get("source") orelse continue;
        if (source_object != .object) continue;
        const source_identity = jsonStringField(source_object.object, "identity") orelse continue;
        const entry_package_root = jsonStringField(entry.object, "packageRoot") orelse package_root;
        const digests = entry.object.get("digests") orelse continue;
        if (digests != .object) continue;
        const package_root_sha256 = jsonStringField(digests.object, "packageRootSha256") orelse continue;
        const artifact_sha256 = if (entry.object.get("artifact")) |artifact| blk: {
            if (artifact != .object) break :blk null;
            break :blk jsonStringField(artifact.object, "sha256");
        } else null;
        return .{
            .lock_entry_key = try allocator.dupe(u8, entry_key),
            .source_identity = try allocator.dupe(u8, source_identity),
            .package_root = try allocator.dupe(u8, entry_package_root),
            .package_root_sha256 = try allocator.dupe(u8, package_root_sha256),
            .artifact_sha256 = if (artifact_sha256) |value| try allocator.dupe(u8, value) else null,
        };
    }
    return null;
}

fn extensionProvenanceLockfilePath(
    allocator: std.mem.Allocator,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    return switch (scope) {
        .project => std.fs.path.join(allocator, &.{ cwd, ".pi", EXTENSION_PROVENANCE_LOCKFILE_NAME }),
        .user => std.fs.path.join(allocator, &.{ agent_dir, EXTENSION_PROVENANCE_LOCKFILE_NAME }),
        .temporary => std.fs.path.join(allocator, &.{ cwd, ".pi", "tmp", EXTENSION_PROVENANCE_LOCKFILE_NAME }),
    };
}

fn provenanceEntryKeyForSource(allocator: std.mem.Allocator, source: []const u8, package_root: []const u8) ![]u8 {
    return switch (parseSource(source)) {
        .npm => |npm| std.fmt.allocPrint(allocator, "npm:{s}", .{npm.name}),
        .git => |git| std.fmt.allocPrint(allocator, "git:{s}", .{git.normalized}),
        .local => {
            const identity = realpathAlloc(allocator, package_root) catch try allocator.dupe(u8, package_root);
            defer allocator.free(identity);
            return std.fmt.allocPrint(allocator, "local:{s}", .{identity});
        },
    };
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch allocator.dupe(u8, path);
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn collectKindFromPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    kind: ResourceKind,
    filter_entries: ?[]const []const u8,
    manifest_entries: ?[][]u8,
    seed: MetadataSeed,
) !void {
    if (filter_entries) |entries| {
        if (entries.len == 0) return;
        try collectEntriesFromBase(allocator, io, target, diagnostics, entries, kind, seed);
        return;
    }

    if (manifest_entries) |entries| {
        try collectEntriesFromBase(allocator, io, target, diagnostics, sliceConst(entries), kind, seed);
        return;
    }

    const convention_dir = try std.fs.path.join(allocator, &[_][]const u8{ package_root, kind.directoryName() });
    defer allocator.free(convention_dir);
    if (!pathExists(io, convention_dir)) return;
    try collectEntriesFromBase(allocator, io, target, diagnostics, &.{kind.directoryName()}, kind, seed);
}

fn addAutoDiscovered(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    kind: ResourceKind,
    scope: SourceScope,
    base_dir: []const u8,
) !void {
    const resource_dir = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, kind.directoryName() });
    defer allocator.free(resource_dir);
    if (!pathExists(io, resource_dir)) return;
    try collectPaths(
        allocator,
        io,
        target,
        diagnostics,
        resource_dir,
        kind,
        true,
        .{
            .source = "auto",
            .scope = scope,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    );
}

fn addAutoDiscoveredProjectAgentSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    cwd: []const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    const user_agents_skills_dir = try userAgentsSkillsDir(allocator, env_map);
    defer if (user_agents_skills_dir) |path| allocator.free(path);

    var skill_dirs = std.ArrayList([]u8).empty;
    defer {
        for (skill_dirs.items) |path| allocator.free(path);
        skill_dirs.deinit(allocator);
    }
    try collectAncestorAgentSkillDirs(allocator, io, cwd, &skill_dirs);

    for (skill_dirs.items) |agents_skills_dir| {
        if (user_agents_skills_dir) |user_dir| {
            if (std.mem.eql(u8, agents_skills_dir, user_dir)) continue;
        }
        const agents_base_dir = std.fs.path.dirname(agents_skills_dir) orelse continue;
        try addAutoDiscoveredAgentSkillDir(allocator, io, target, diagnostics, agents_skills_dir, .project, agents_base_dir);
    }
}

fn addAutoDiscoveredUserAgentSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    env_map: ?*const std.process.Environ.Map,
) !void {
    const agents_skills_dir = try userAgentsSkillsDir(allocator, env_map) orelse return;
    defer allocator.free(agents_skills_dir);
    const agents_base_dir = std.fs.path.dirname(agents_skills_dir) orelse return;
    try addAutoDiscoveredAgentSkillDir(allocator, io, target, diagnostics, agents_skills_dir, .user, agents_base_dir);
}

fn addAutoDiscoveredAgentSkillDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    agents_skills_dir: []const u8,
    scope: SourceScope,
    agents_base_dir: []const u8,
) !void {
    if (!pathExists(io, agents_skills_dir)) return;
    try collectAgentSkillFiles(allocator, io, target, diagnostics, agents_skills_dir, true, .{
        .source = "auto",
        .scope = scope,
        .origin = .top_level,
        .base_dir = agents_base_dir,
    });
}

fn addLocalEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    entries: ?[]const []const u8,
    kind: ResourceKind,
    seed: MetadataSeed,
) !void {
    const path_entries = entries orelse return;
    try collectEntriesFromBase(allocator, io, target, diagnostics, path_entries, kind, seed);
}

fn collectEntriesFromBase(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    entries: []const []const u8,
    kind: ResourceKind,
    seed: MetadataSeed,
) !void {
    if (isExplicitCliResource(kind, seed)) {
        try collectExplicitExtensionEntries(allocator, io, target, diagnostics, entries, seed);
        return;
    }

    for (entries) |entry| {
        const resolved = try resolvePath(allocator, seed.base_dir, entry);
        defer allocator.free(resolved);
        if (!pathExists(io, resolved)) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "resource path does not exist", resolved));
            continue;
        }
        try collectPaths(allocator, io, target, diagnostics, resolved, kind, true, seed);
    }
}

fn collectExplicitExtensionEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    entries: []const []const u8,
    seed: MetadataSeed,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = seen.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (entries) |entry| {
        const resolved = try resolvePath(allocator, seed.base_dir, entry);
        defer allocator.free(resolved);

        if (seen.contains(resolved)) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "duplicate explicit --extension path skipped", resolved));
            continue;
        }
        const seen_key = try allocator.dupe(u8, resolved);
        errdefer allocator.free(seen_key);
        try seen.put(seen_key, {});

        if (!pathExists(io, resolved)) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "explicit --extension path does not exist", resolved));
            continue;
        }

        const stat = std.Io.Dir.statFile(.cwd(), io, resolved, .{}) catch {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to stat explicit --extension path", resolved));
            continue;
        };
        if (stat.kind != .directory and (stat.kind != .file or !hasSupportedExtensionFile(resolved))) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "explicit --extension path is not a supported extension file or directory", resolved));
            continue;
        }

        try collectPaths(allocator, io, target, diagnostics, resolved, .extension, true, seed);
    }
}

fn collectPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    path: []const u8,
    kind: ResourceKind,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    const stat = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to stat resource path", path));
        return;
    };
    if (stat.kind == .file) {
        const package_extension_file = kind == .extension and seed.origin == .package;
        if (kind != .extension or hasSupportedExtensionFile(path) or package_extension_file) {
            if (kind == .skill or kind == .prompt or kind == .theme or hasSupportedExtensionFile(path) or package_extension_file) {
                try appendResolvedResource(allocator, target, path, enabled, seed);
            }
        }
        return;
    }
    if (stat.kind != .directory) return;

    if (kind == .skill) {
        try collectSkillFiles(allocator, io, target, diagnostics, path, enabled, seed);
        return;
    }

    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |item| allocator.free(item);
        files.deinit(allocator);
    }
    try collectRecursiveFiles(allocator, io, path, kind, &files);
    for (files.items) |file_path| {
        try appendResolvedResource(allocator, target, file_path, enabled, seed);
    }
}

fn collectSkillFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    dir_path: []const u8,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    const skill_marker = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "SKILL.md" });
    defer allocator.free(skill_marker);
    if (pathExists(io, skill_marker)) {
        try appendResolvedResource(allocator, target, skill_marker, enabled, seed);
        return;
    }

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to open skills directory", dir_path));
        return;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) {
            const subdir = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(subdir);
            try collectSkillFiles(allocator, io, target, diagnostics, subdir, enabled, seed);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(file_path);
        try appendResolvedResource(allocator, target, file_path, enabled, seed);
    }
}

fn collectAgentSkillFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    dir_path: []const u8,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    const skill_marker = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "SKILL.md" });
    defer allocator.free(skill_marker);
    if (pathExists(io, skill_marker)) {
        try appendResolvedResource(allocator, target, skill_marker, enabled, seed);
        return;
    }

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to open skills directory", dir_path));
        return;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;

        const subdir = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(subdir);
        try collectAgentSkillFiles(allocator, io, target, diagnostics, subdir, enabled, seed);
    }
}

fn collectRecursiveFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    kind: ResourceKind,
    files: *std.ArrayList([]u8),
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => try collectRecursiveFiles(allocator, io, child_path, kind, files),
            .file => {
                if (kind == .extension) {
                    if (!hasSupportedExtensionFile(entry.name)) continue;
                } else if (!std.mem.endsWith(u8, entry.name, kind.fileExtension())) {
                    continue;
                }
                try files.append(allocator, try allocator.dupe(u8, child_path));
            },
            else => {},
        }
    }
}

fn appendResolvedResource(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(ResolvedResource),
    path: []const u8,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    for (target.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try target.append(allocator, .{
        .path = owned_path,
        .enabled = enabled,
        .source_info = .{
            .path = try allocator.dupe(u8, path),
            .source = try allocator.dupe(u8, seed.source),
            .scope = seed.scope,
            .origin = seed.origin,
            .base_dir = try allocator.dupe(u8, seed.base_dir),
            .provenance = if (seed.provenance) |value| try value.clone(allocator) else null,
        },
        .discovery_index = target.items.len,
    });
}

fn precedence(resource: ResolvedResource) usize {
    if (resource.source_info.scope == .temporary) return 0;
    if (resource.source_info.origin == .package) return 5;
    if (resource.source_info.scope == .project) {
        if (std.mem.eql(u8, resource.source_info.source, "local")) return 1;
        return 2;
    }
    if (std.mem.eql(u8, resource.source_info.source, "local")) return 3;
    return 4;
}

fn sortResolved(items: []ResolvedResource) void {
    std.mem.sort(ResolvedResource, items, {}, struct {
        fn lessThan(_: void, lhs: ResolvedResource, rhs: ResolvedResource) bool {
            const left_rank = precedence(lhs);
            const right_rank = precedence(rhs);
            if (left_rank != right_rank) return left_rank < right_rank;
            if (isExplicitCliResolvedResource(lhs) and isExplicitCliResolvedResource(rhs)) {
                return lhs.discovery_index < rhs.discovery_index;
            }
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
}

fn isExplicitCliResource(kind: ResourceKind, seed: MetadataSeed) bool {
    return kind == .extension and
        seed.scope == .temporary and
        seed.origin == .top_level and
        std.mem.eql(u8, seed.source, "local");
}

fn isExplicitCliResolvedResource(resource: ResolvedResource) bool {
    return resource.source_info.scope == .temporary and
        resource.source_info.origin == .top_level and
        std.mem.eql(u8, resource.source_info.source, "local");
}

const Manifest = struct {
    extension_entries: ?[][]u8 = null,
    skill_entries: ?[][]u8 = null,
    prompt_entries: ?[][]u8 = null,
    theme_entries: ?[][]u8 = null,

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        if (self.extension_entries) |entries| freeOwnedStringArray(allocator, entries);
        if (self.skill_entries) |entries| freeOwnedStringArray(allocator, entries);
        if (self.prompt_entries) |entries| freeOwnedStringArray(allocator, entries);
        if (self.theme_entries) |entries| freeOwnedStringArray(allocator, entries);
        self.* = .{};
    }
};

fn readPiManifest(allocator: std.mem.Allocator, io: std.Io, package_root: []const u8) !Manifest {
    const package_json_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, "package.json" });
    defer allocator.free(package_json_path);

    const bytes = readOptionalFile(allocator, io, package_json_path) catch return .{};
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return .{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes.?, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const pi_value = parsed.value.object.get("pi") orelse return .{};
    if (pi_value != .object) return .{};

    return .{
        .extension_entries = try parseStringArrayOwned(allocator, pi_value.object.get("extensions")),
        .skill_entries = try parseStringArrayOwned(allocator, pi_value.object.get("skills")),
        .prompt_entries = try parseStringArrayOwned(allocator, pi_value.object.get("prompts")),
        .theme_entries = try parseStringArrayOwned(allocator, pi_value.object.get("themes")),
    };
}

fn loadSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: []const ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) ![]Skill {
    var skills = std.ArrayList(Skill).empty;
    errdefer deinitSkillsList(allocator, &skills);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const skill = try loadSkillFromFile(allocator, io, resource, diagnostics, errors) orelse continue;
        const gop = try seen.getOrPut(skill.name);
        if (gop.found_existing) {
            var duplicate = skill;
            duplicate.deinit(allocator);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "collision", "skill name collision", resource.path));
            continue;
        }
        try skills.append(allocator, skill);
    }

    return try skills.toOwnedSlice(allocator);
}

fn loadPromptTemplates(
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: []const ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) ![]PromptTemplate {
    var templates = std.ArrayList(PromptTemplate).empty;
    errdefer deinitPromptTemplatesList(allocator, &templates);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const template = try loadPromptTemplateFromFile(allocator, io, resource, errors) orelse continue;
        const gop = try seen.getOrPut(template.name);
        if (gop.found_existing) {
            var duplicate = template;
            duplicate.deinit(allocator);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "collision", "prompt template name collision", resource.path));
            continue;
        }
        try templates.append(allocator, template);
    }

    return try templates.toOwnedSlice(allocator);
}

fn loadThemes(
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: []const ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) ![]Theme {
    var themes = std.ArrayList(Theme).empty;
    errdefer deinitThemesList(allocator, &themes);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const theme = try loadThemeFromFile(allocator, io, resource, errors) orelse continue;
        const gop = try seen.getOrPut(theme.name);
        if (gop.found_existing) {
            var duplicate = theme;
            duplicate.deinit(allocator);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "collision", "theme name collision", resource.path));
            continue;
        }
        try themes.append(allocator, theme);
    }

    return try themes.toOwnedSlice(allocator);
}

fn loadSkillFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) !?Skill {
    const bytes = readOptionalFile(allocator, io, resource.path) catch |err| {
        try config_errors.appendError(allocator, errors, .skill, resource.path, err);
        return null;
    };
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    const parsed = try parseFrontmatter(allocator, bytes.?);
    defer parsed.deinit(allocator);
    const description = parsed.description orelse {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "skill description is required", resource.path));
        return null;
    };

    const base_dir = std.fs.path.dirname(resource.path) orelse ".";
    const parent_name = std.fs.path.basename(base_dir);
    const skill_name = parsed.name orelse parent_name;

    return .{
        .name = try allocator.dupe(u8, skill_name),
        .description = try allocator.dupe(u8, description),
        .file_path = try allocator.dupe(u8, resource.path),
        .base_dir = try allocator.dupe(u8, base_dir),
        .source_info = try resource.source_info.clone(allocator),
        .disable_model_invocation = parsed.disable_model_invocation,
    };
}

fn loadPromptTemplateFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: ResolvedResource,
    errors: *std.ArrayList(config_errors.ConfigError),
) !?PromptTemplate {
    const bytes = readOptionalFile(allocator, io, resource.path) catch |err| {
        try config_errors.appendError(allocator, errors, .prompt, resource.path, err);
        return null;
    };
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    const parsed = try parseFrontmatter(allocator, bytes.?);
    defer parsed.deinit(allocator);

    const name = trimExtension(std.fs.path.basename(resource.path), ".md");
    const description = if (parsed.description) |value|
        value
    else
        firstNonEmptyLine(parsed.body) orelse name;

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .argument_hint = if (parsed.argument_hint) |value| try allocator.dupe(u8, value) else null,
        .content = try allocator.dupe(u8, parsed.body),
        .file_path = try allocator.dupe(u8, resource.path),
        .source_info = try resource.source_info.clone(allocator),
    };
}

fn loadThemeFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: ResolvedResource,
    errors: *std.ArrayList(config_errors.ConfigError),
) !?Theme {
    const bytes = readOptionalFile(allocator, io, resource.path) catch |err| {
        try config_errors.appendError(allocator, errors, .theme, resource.path, err);
        return null;
    };
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes.?, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, .theme, resource.path, err);
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const base_theme_name = if (parsed.value.object.get("base")) |value|
        if (value == .string) value.string else "dark"
    else
        "dark";

    var theme = if (std.mem.eql(u8, base_theme_name, "light"))
        try Theme.initLight(allocator)
    else if (std.mem.eql(u8, base_theme_name, "codex"))
        try Theme.initCodex(allocator)
    else
        try Theme.initDefault(allocator);
    errdefer theme.deinit(allocator);
    allocator.free(theme.name);
    theme.name = try allocator.dupe(u8, trimExtension(std.fs.path.basename(resource.path), ".json"));

    if (parsed.value.object.get("name")) |value| {
        if (value == .string) {
            allocator.free(theme.name);
            theme.name = try allocator.dupe(u8, value.string);
        }
    }

    if (parsed.value.object.get("colors")) |value| {
        if (value == .object) {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                const color = parseThemeColor(entry.key_ptr.*) orelse continue;
                if (entry.value_ptr.* != .string) continue;
                try theme.setColor(allocator, color, entry.value_ptr.string);
            }
            try theme.applyDerivedStyles(allocator);
        }
    }

    if (parsed.value.object.get("tokens")) |value| {
        if (value == .object) {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                const token = parseThemeToken(entry.key_ptr.*) orelse continue;
                if (entry.value_ptr.* != .object) continue;
                const object = entry.value_ptr.object;
                var style = &theme.styles[@intFromEnum(token)];
                if (object.get("fg")) |field| {
                    if (field == .string) {
                        if (style.fg) |existing| allocator.free(existing);
                        style.fg = try allocator.dupe(u8, field.string);
                    }
                }
                if (object.get("bg")) |field| {
                    if (field == .string) {
                        if (style.bg) |existing| allocator.free(existing);
                        style.bg = try allocator.dupe(u8, field.string);
                    }
                }
                if (object.get("bold")) |field| {
                    if (field == .bool) style.bold = field.bool;
                }
                if (object.get("dim")) |field| {
                    if (field == .bool) style.dim = field.bool;
                }
                if (object.get("italic")) |field| {
                    if (field == .bool) style.italic = field.bool;
                }
                if (object.get("underline")) |field| {
                    if (field == .bool) style.underline = field.bool;
                }
            }
        }
    }

    return theme;
}

fn parseSource(source: []const u8) ParsedSource {
    if (std.mem.startsWith(u8, source, "npm:")) {
        const spec = std.mem.trim(u8, source["npm:".len..], " ");
        return .{ .npm = .{ .name = parseNpmName(spec), .spec = spec } };
    }
    if (std.mem.startsWith(u8, source, "git:")) {
        return .{ .git = .{ .normalized = std.mem.trim(u8, source["git:".len..], " ") } };
    }
    if (isGitUrlSource(source)) {
        return .{ .git = .{ .normalized = std.mem.trim(u8, source, " ") } };
    }
    if (std.mem.startsWith(u8, source, "local:")) {
        return .{ .local = .{ .path = std.mem.trim(u8, source["local:".len..], " ") } };
    }
    return .{ .local = .{ .path = source } };
}

fn isGitUrlSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "https://") or
        std.mem.startsWith(u8, source, "http://") or
        std.mem.startsWith(u8, source, "ssh://") or
        std.mem.startsWith(u8, source, "git://");
}

fn parseNpmName(spec: []const u8) []const u8 {
    if (spec.len == 0) return spec;
    if (spec[0] == '@') {
        const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash_index| {
            if (at_index > slash_index) return spec[0..at_index];
        }
        return spec;
    }
    const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
    return spec[0..at_index];
}

fn npmInstallPath(
    allocator: std.mem.Allocator,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
    package_name: []const u8,
) ![]u8 {
    const base = switch (scope) {
        .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "npm", "node_modules" }),
        .user => try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "npm", "node_modules" }),
        .temporary => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "tmp", "npm", "node_modules" }),
    };
    defer allocator.free(base);
    return std.fs.path.join(allocator, &[_][]const u8{ base, package_name });
}

fn gitInstallPath(
    allocator: std.mem.Allocator,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
    normalized_source: []const u8,
) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized_source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
    defer allocator.free(hex);
    const base = switch (scope) {
        .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "git" }),
        .user => try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "git" }),
        .temporary => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "tmp", "git" }),
    };
    defer allocator.free(base);
    return std.fs.path.join(allocator, &[_][]const u8{ base, hex });
}

fn userAgentsSkillsDir(allocator: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) !?[]u8 {
    const home = resourceEnvValue(env_map, "HOME") orelse return null;
    return @as(?[]u8, try std.fs.path.join(allocator, &[_][]const u8{ home, ".agents", "skills" }));
}

fn collectAncestorAgentSkillDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    var current = if (std.fs.path.isAbsolute(start_dir))
        try allocator.dupe(u8, start_dir)
    else
        try std.fs.path.resolve(allocator, &[_][]const u8{start_dir});
    defer allocator.free(current);

    const git_root = try findGitRepoRoot(allocator, io, current);
    defer if (git_root) |path| allocator.free(path);

    while (true) {
        try out.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ current, ".agents", "skills" }));
        if (git_root) |root| {
            if (std.mem.eql(u8, current, root)) break;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn findGitRepoRoot(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        const git_path = try std.fs.path.join(allocator, &[_][]const u8{ current, ".git" });
        defer allocator.free(git_path);
        if (pathExists(io, git_path)) {
            return try allocator.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

fn hasSupportedExtensionFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".js");
}

fn trimExtension(name: []const u8, extension: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, extension)) return name[0 .. name.len - extension.len];
    return name;
}

const THEME_TOKEN_ALIASES = [_]struct { []const u8, ThemeToken }{
    .{ "welcome", .welcome },
    .{ "user", .user },
    .{ "assistant", .assistant },
    .{ "toolCall", .tool_call },
    .{ "toolResult", .tool_result },
    .{ "error", .@"error" },
    .{ "status", .status },
    .{ "footer", .footer },
    .{ "prompt", .prompt },
    .{ "boxBorder", .box_border },
    .{ "text", .text },
    .{ "editor", .editor },
    .{ "editorCursor", .editor_cursor },
    .{ "selectSelected", .select_selected },
    .{ "selectDescription", .select_description },
    .{ "selectScroll", .select_scroll },
    .{ "selectEmpty", .select_empty },
    .{ "markdownText", .markdown_text },
    .{ "markdownHeading", .markdown_heading },
    .{ "markdownLink", .markdown_link },
    .{ "markdownCode", .markdown_code },
    .{ "markdownCodeBorder", .markdown_code_border },
    .{ "markdownQuote", .markdown_quote },
    .{ "markdownQuoteBorder", .markdown_quote_border },
    .{ "markdownListBullet", .markdown_list_bullet },
    .{ "markdownRule", .markdown_rule },
    .{ "overlayTitle", .overlay_title },
    .{ "overlayHint", .overlay_hint },
    .{ "promptGlyph", .prompt_glyph },
    .{ "promptBorder", .prompt_border },
    .{ "taskHeader", .task_header },
    .{ "taskHeaderAccent", .task_header_accent },
    .{ "taskHeaderSeparator", .task_header_separator },
    .{ "role_user", .role_user },
    .{ "roleUser", .role_user },
    .{ "role_assistant", .role_assistant },
    .{ "roleAssistant", .role_assistant },
    .{ "role_thinking", .role_thinking },
    .{ "roleThinking", .role_thinking },
    .{ "role_tool_call", .role_tool_call },
    .{ "roleToolCall", .role_tool_call },
    .{ "role_tool_result", .role_tool_result },
    .{ "roleToolResult", .role_tool_result },
    .{ "role_thinking_glyph", .role_thinking_glyph },
    .{ "roleThinkingGlyph", .role_thinking_glyph },
    .{ "terminalBadge", .terminal_badge },
};

const THEME_TOKEN_MAP = initThemeTokenMap();

fn initThemeTokenMap() std.StaticStringMap(ThemeToken) {
    @setEvalBranchQuota(10_000);
    validateThemeTokenAliases();
    return std.StaticStringMap(ThemeToken).initComptime(THEME_TOKEN_ALIASES);
}

fn validateThemeTokenAliases() void {
    for (THEME_TOKEN_ALIASES, 0..) |left, left_index| {
        for (THEME_TOKEN_ALIASES[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, left[0], right[0])) {
                @compileError("duplicate theme token alias: " ++ left[0]);
            }
        }
    }

    for (@typeInfo(ThemeToken).@"enum".fields) |field| {
        const token: ThemeToken = @enumFromInt(field.value);
        for (THEME_TOKEN_ALIASES) |entry| {
            if (entry[1] == token) break;
        } else {
            @compileError("missing theme token alias for: " ++ field.name);
        }
    }
}

fn parseThemeToken(name: []const u8) ?ThemeToken {
    return THEME_TOKEN_MAP.get(name);
}

fn parseThemeColor(name: []const u8) ?ThemeColor {
    const aliases = [_]struct { []const u8, ThemeColor }{
        .{ "primary", .primary },
        .{ "secondary", .secondary },
        .{ "success", .success },
        .{ "warning", .warning },
        .{ "error", .@"error" },
        .{ "background", .background },
        .{ "foreground", .foreground },
        .{ "border", .border },
        .{ "muted", .muted },
        .{ "dim", .dim },
        .{ "thinkingText", .thinking_text },
        .{ "thinking_text", .thinking_text },
        .{ "selectedBg", .selected_bg },
        .{ "selected_bg", .selected_bg },
        .{ "userMessageBg", .user_message_bg },
        .{ "user_message_bg", .user_message_bg },
        .{ "customMessageBg", .custom_message_bg },
        .{ "custom_message_bg", .custom_message_bg },
        .{ "toolPendingBg", .tool_pending_bg },
        .{ "tool_pending_bg", .tool_pending_bg },
        .{ "toolSuccessBg", .tool_success_bg },
        .{ "tool_success_bg", .tool_success_bg },
        .{ "toolErrorBg", .tool_error_bg },
        .{ "tool_error_bg", .tool_error_bg },
        .{ "borderAccent", .border_accent },
        .{ "border_accent", .border_accent },
        .{ "borderMuted", .border_muted },
        .{ "border_muted", .border_muted },
        .{ "mdHeading", .markdown_heading },
        .{ "markdownHeading", .markdown_heading },
        .{ "markdown_heading", .markdown_heading },
        .{ "mdLink", .markdown_link },
        .{ "markdownLink", .markdown_link },
        .{ "markdown_link", .markdown_link },
        .{ "mdCode", .markdown_code },
        .{ "markdownCode", .markdown_code },
        .{ "markdown_code", .markdown_code },
        .{ "mdCodeBlockBorder", .markdown_code_border },
        .{ "markdownCodeBorder", .markdown_code_border },
        .{ "markdown_code_border", .markdown_code_border },
        .{ "mdQuote", .markdown_quote },
        .{ "markdownQuote", .markdown_quote },
        .{ "markdown_quote", .markdown_quote },
        .{ "mdQuoteBorder", .markdown_quote_border },
        .{ "markdownQuoteBorder", .markdown_quote_border },
        .{ "markdown_quote_border", .markdown_quote_border },
        .{ "mdHr", .markdown_rule },
        .{ "markdownRule", .markdown_rule },
        .{ "markdown_rule", .markdown_rule },
        .{ "mdListBullet", .markdown_list_bullet },
        .{ "markdownListBullet", .markdown_list_bullet },
        .{ "markdown_list_bullet", .markdown_list_bullet },
        .{ "toolOutput", .tool_output },
        .{ "tool_output", .tool_output },
    };
    for (aliases) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

test "roles m0 parseThemeToken accepts role token names" {
    try std.testing.expectEqual(ThemeToken.role_user, parseThemeToken("role_user").?);
    try std.testing.expectEqual(ThemeToken.role_assistant, parseThemeToken("role_assistant").?);
    try std.testing.expectEqual(ThemeToken.role_thinking, parseThemeToken("role_thinking").?);
    try std.testing.expectEqual(ThemeToken.role_tool_call, parseThemeToken("role_tool_call").?);
    try std.testing.expectEqual(ThemeToken.role_tool_result, parseThemeToken("role_tool_result").?);
    try std.testing.expectEqual(ThemeToken.role_thinking_glyph, parseThemeToken("role_thinking_glyph").?);
    try std.testing.expectEqual(ThemeToken.role_tool_result, parseThemeToken("roleToolResult").?);
}

fn appendColorAnsi(allocator: std.mem.Allocator, builder: *std.ArrayList(u8), value: []const u8, foreground: bool) !void {
    if (theme_mod.parseNamedColor(value)) |named| {
        const prefix = if (foreground) "\x1b[3" else "\x1b[4";
        const color_text = try std.fmt.allocPrint(allocator, "{s}{d}m", .{ prefix, named });
        defer allocator.free(color_text);
        try builder.appendSlice(allocator, color_text);
        return;
    }
    if (value.len == 7 and value[0] == '#') {
        const r = std.fmt.parseInt(u8, value[1..3], 16) catch return;
        const g = std.fmt.parseInt(u8, value[3..5], 16) catch return;
        const b = std.fmt.parseInt(u8, value[5..7], 16) catch return;
        const ansi_text = if (foreground)
            try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b })
        else
            try std.fmt.allocPrint(allocator, "\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
        defer allocator.free(ansi_text);
        try builder.appendSlice(allocator, ansi_text);
    }
}

fn parseStringArrayOwned(allocator: std.mem.Allocator, value: ?std.json.Value) !?[][]u8 {
    const actual = value orelse return null;
    if (actual != .array) return null;

    var items = std.ArrayList([]u8).empty;
    errdefer freeOwnedStringArrayList(allocator, &items);
    for (actual.array.items) |item| {
        if (item != .string) continue;
        try items.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try items.toOwnedSlice(allocator);
}

const freeOwnedStringArray = @import("../slice_utils.zig").freeStringSlice;

fn freeOwnedStringArrayList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn sliceConst(items: [][]u8) []const []const u8 {
    return @ptrCast(items);
}

fn deinitResolvedList(allocator: std.mem.Allocator, items: *std.ArrayList(ResolvedResource)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitLoadedExtensionsList(allocator: std.mem.Allocator, items: *std.ArrayList(LoadedExtension)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitSkillsList(allocator: std.mem.Allocator, items: *std.ArrayList(Skill)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitPromptTemplatesList(allocator: std.mem.Allocator, items: *std.ArrayList(PromptTemplate)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitThemesList(allocator: std.mem.Allocator, items: *std.ArrayList(Theme)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

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

fn findResolvedResource(items: []const ResolvedResource, path: []const u8) ?ResolvedResource {
    for (items) |item| {
        if (std.mem.eql(u8, item.path, path)) return item;
    }
    return null;
}

test "explicit extension paths preserve order and diagnose invalid entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/first");
    try tmp.dir.createDirPath(std.testing.io, "repo/second");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/first/index.js", .data = "export default {};\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/second/index.js", .data = "export default {};\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/not-extension.txt", .data = "nope\n" });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const first = try makeTmpPath(allocator, tmp, "repo/first");
    defer allocator.free(first);
    const second = try makeTmpPath(allocator, tmp, "repo/second");
    defer allocator.free(second);
    const missing = try makeTmpPath(allocator, tmp, "repo/missing");
    defer allocator.free(missing);
    const invalid_file = try makeTmpPath(allocator, tmp, "repo/not-extension.txt");
    defer allocator.free(invalid_file);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = cwd,
        .cli_extensions = &.{ second, missing, first, second, invalid_file },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), resolved.extensions.len);
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[0].path, "second/index.js"));
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[1].path, "first/index.js"));
    try std.testing.expect(resourceDiagnosticContains(resolved.diagnostics, "explicit --extension path does not exist"));
    try std.testing.expect(resourceDiagnosticContains(resolved.diagnostics, "duplicate explicit --extension path skipped"));
    try std.testing.expect(resourceDiagnosticContains(resolved.diagnostics, "explicit --extension path is not a supported extension file or directory"));
}

fn resourceDiagnosticContains(diagnostics: []const Diagnostic, needle: []const u8) bool {
    for (diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

test "resolveConfiguredResources loads local, npm, and git resource sources" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent/packages/npm/node_modules/@demo/pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent/packages/npm/node_modules/@demo/pkg/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent/packages/npm/node_modules/@demo/pkg/themes");

    const git_hash_source = "github.com/example/pi-theme";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(git_hash_source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const git_hash = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
    defer allocator.free(git_hash);
    const git_theme_dir = try std.fmt.allocPrint(allocator, "repo/.pi/packages/git/{s}/themes", .{git_hash});
    defer allocator.free(git_theme_dir);
    try tmp.dir.createDirPath(std.testing.io, git_theme_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/extensions/local-extension.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/summarize.md",
        .data = "Summarize $ARGUMENTS",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/package.json",
        .data =
        \\{
        \\  "pi": {
        \\    "extensions": ["extensions"],
        \\    "skills": ["skills"],
        \\    "themes": ["themes"]
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/extensions/pkg-extension.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review code carefully
        \\---
        \\Read the diff before replying.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/themes/pkg.json",
        .data =
        \\{
        \\  "name": "pkg-theme",
        \\  "tokens": {
        \\    "footer": { "fg": "cyan", "bold": true }
        \\  }
        \\}
        ,
    });
    const git_theme_file = try std.fmt.allocPrint(allocator, "{s}/theme.json", .{git_theme_dir});
    defer allocator.free(git_theme_file);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = git_theme_file,
        .data =
        \\{
        \\  "name": "git-theme"
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    const npm_pkg = PackageSourceConfig{ .source = try allocator.dupe(u8, "npm:@demo/pkg") };
    defer {
        var owned = npm_pkg;
        owned.deinit(allocator);
    }
    const git_pkg = PackageSourceConfig{ .source = try allocator.dupe(u8, "git:github.com/example/pi-theme") };
    defer {
        var owned = git_pkg;
        owned.deinit(allocator);
    }

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{
            .packages = &.{npm_pkg},
        },
        .project = .{
            .extensions = &.{"extensions/local-extension.ts"},
            .prompts = &.{"prompts"},
            .packages = &.{git_pkg},
        },
        .include_default_skills = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), resolved.extensions.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.extensions[0].path, "local-extension.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.extensions[1].path, "pkg-extension.ts") != null);
    try std.testing.expectEqual(@as(usize, 1), resolved.skills.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.skills[0].path, "SKILL.md") != null);
    try std.testing.expectEqual(@as(usize, 1), resolved.prompts.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.prompts[0].path, "summarize.md") != null);
    try std.testing.expectEqual(@as(usize, 2), resolved.themes.len);
}

test "resolveConfiguredResources loads unified extension package resources without wasm lock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/unified-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/unified-pkg/package.json",
        .data =
        \\{
        \\  "pi": { "extensions": ["extensions/extension.ts"] }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/unified-pkg/pi-extension.json",
        .data =
        \\{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "com.example.unified",
        \\  "name": "Unified Package",
        \\  "version": "1.0.0",
        \\  "runtime": {
        \\    "kind": "process_jsonl",
        \\    "entrypoint": { "argv": ["node", "extensions/extension.ts"] }
        \\  },
        \\  "tools": []
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/unified-pkg/extensions/extension.ts",
        .data = "export default {};\n",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const fixture_root = try makeTmpPath(allocator, tmp, "repo/fixtures/unified-pkg");
    defer allocator.free(fixture_root);

    var package_config = PackageSourceConfig{ .source = try allocator.dupe(u8, fixture_root) };
    defer package_config.deinit(allocator);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolved.extensions.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[0].path, "extensions/extension.ts"));
    try std.testing.expect(resolved.extensions[0].source_info.provenance == null);
}

test "resolveConfiguredResources discovers project .agents skills up to git root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/packages/feature");
    try tmp.dir.createDirPath(std.testing.io, "repo/.agents/skills/repo");
    try tmp.dir.createDirPath(std.testing.io, "repo/packages/.agents/skills/package");
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/above-repo");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.agents/skills/repo/SKILL.md",
        .data = "---\nname: repo\ndescription: repo\n---\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/packages/.agents/skills/package/SKILL.md",
        .data = "---\nname: package\ndescription: package\n---\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".agents/skills/above-repo/SKILL.md",
        .data = "---\nname: above\ndescription: above\n---\n",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo/packages/feature");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const repo_skill = try makeTmpPath(allocator, tmp, "repo/.agents/skills/repo/SKILL.md");
    defer allocator.free(repo_skill);
    const package_skill = try makeTmpPath(allocator, tmp, "repo/packages/.agents/skills/package/SKILL.md");
    defer allocator.free(package_skill);
    const above_repo_skill = try makeTmpPath(allocator, tmp, ".agents/skills/above-repo/SKILL.md");
    defer allocator.free(above_repo_skill);
    const repo_agents_base = try makeTmpPath(allocator, tmp, "repo/.agents");
    defer allocator.free(repo_agents_base);
    const package_agents_base = try makeTmpPath(allocator, tmp, "repo/packages/.agents");
    defer allocator.free(package_agents_base);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .include_default_extensions = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    const repo_resource = findResolvedResource(resolved.skills, repo_skill).?;
    const package_resource = findResolvedResource(resolved.skills, package_skill).?;
    try std.testing.expect(findResolvedResource(resolved.skills, above_repo_skill) == null);
    try std.testing.expectEqual(.project, repo_resource.source_info.scope);
    try std.testing.expectEqual(.project, package_resource.source_info.scope);
    try std.testing.expectEqualStrings(repo_agents_base, repo_resource.source_info.base_dir.?);
    try std.testing.expectEqualStrings(package_agents_base, package_resource.source_info.base_dir.?);
}

test "resolveConfiguredResources discovers user .agents skills with .agents base dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/scratch/nested");
    try tmp.dir.createDirPath(std.testing.io, "home/.agents/skills/home-skill");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.agents/skills/home-skill/SKILL.md",
        .data = "---\nname: home-skill\ndescription: home\n---\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.agents/skills/root-file.md",
        .data = "---\nname: root-file\ndescription: root file\n---\n",
    });

    const home = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home);
    const cwd = try makeTmpPath(allocator, tmp, "home/scratch/nested");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const skill_path = try makeTmpPath(allocator, tmp, "home/.agents/skills/home-skill/SKILL.md");
    defer allocator.free(skill_path);
    const root_markdown = try makeTmpPath(allocator, tmp, "home/.agents/skills/root-file.md");
    defer allocator.free(root_markdown);
    const agents_base = try makeTmpPath(allocator, tmp, "home/.agents");
    defer allocator.free(agents_base);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .env_map = &env_map,
        .include_default_extensions = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    const resource = findResolvedResource(resolved.skills, skill_path).?;
    try std.testing.expect(findResolvedResource(resolved.skills, root_markdown) == null);
    try std.testing.expectEqual(@as(usize, 1), resolved.skills.len);
    try std.testing.expectEqual(.user, resource.source_info.scope);
    try std.testing.expectEqualStrings("auto", resource.source_info.source);
    try std.testing.expectEqualStrings(agents_base, resource.source_info.base_dir.?);
}

test "loadResourceBundle loads skills templates and themes with selected theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review changes before finalizing
        \\---
        \\Review the diff carefully.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data =
        \\---
        \\description: Create a fix prompt
        \\argument-hint: issue
        \\---
        \\Fix $1 using $ARGUMENTS
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "#00ffcc", "bold": true },
        \\    "footer": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("TERM_PROGRAM", "Ghostty");

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .env_map = &env_map,
        .project = .{
            .skills = &.{"skills"},
            .prompts = &.{"prompts"},
            .themes = &.{"themes"},
            .theme = "night",
        },
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.skills.len);
    try std.testing.expectEqualStrings("reviewer", bundle.skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("fix", bundle.prompt_templates[0].name);
    try std.testing.expectEqualStrings("night", bundle.selectedTheme().name);
    try std.testing.expectEqualStrings("ghostty", bundle.terminal_name);

    const expanded = try expandPromptTemplate(allocator, "/fix parser bug", bundle.prompt_templates);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("Fix parser using parser bug", expanded);

    const prompt_text = try formatSkillsForPrompt(allocator, bundle.skills);
    defer allocator.free(prompt_text);
    try std.testing.expect(std.mem.indexOf(u8, prompt_text, "<available_skills>") != null);

    const styled = try bundle.selectedTheme().applyAlloc(allocator, .assistant, "Pi:");
    defer allocator.free(styled);
    try std.testing.expectEqualStrings("Pi:", styled);
}

test "expandSkillCommand strips frontmatter and appends arguments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "skills/reviewer");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "skills/reviewer/SKILL.md",
        .data =
        \\---
        \\name: reviewer
        \\description: Review code
        \\---
        \\Use this skill body.
        \\
        ,
    });

    const skill_path = try makeTmpPath(allocator, tmp, "skills/reviewer/SKILL.md");
    defer allocator.free(skill_path);
    const base_dir = try makeTmpPath(allocator, tmp, "skills/reviewer");
    defer allocator.free(base_dir);
    var skill = Skill{
        .name = try allocator.dupe(u8, "reviewer"),
        .description = try allocator.dupe(u8, "Review code"),
        .file_path = try allocator.dupe(u8, skill_path),
        .base_dir = try allocator.dupe(u8, base_dir),
        .source_info = .{
            .path = try allocator.dupe(u8, skill_path),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = try allocator.dupe(u8, base_dir),
        },
    };
    defer skill.deinit(allocator);

    const expanded = try expandSkillCommand(allocator, std.testing.io, "/skill:reviewer focus src", &.{skill});
    defer allocator.free(expanded);
    const expected = try std.fmt.allocPrint(
        allocator,
        "<skill name=\"reviewer\" location=\"{s}\">\nReferences are relative to {s}.\n\nUse this skill body.\n</skill>\n\nfocus src",
        .{ skill_path, base_dir },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, expanded);

    const unknown = try expandSkillCommand(allocator, std.testing.io, "/skill:missing", &.{skill});
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("/skill:missing", unknown);
}

test "loadResourceBundle exposes built-in dark light and codex themes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
    });
    defer bundle.deinit(allocator);

    try std.testing.expect(findThemeIndex(bundle.themes, "dark") != null);
    try std.testing.expect(findThemeIndex(bundle.themes, "light") != null);
    try std.testing.expect(findThemeIndex(bundle.themes, "codex") != null);
}

test "loadResourceBundle merges extension discovered skills prompts and themes with normal lookup" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/ext-skills/review");
    try tmp.dir.createDirPath(std.testing.io, "repo/ext-prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/ext-themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/ext-skills/review/SKILL.md",
        .data =
        \\---
        \\name: ext-review
        \\description: Extension review skill
        \\---
        \\Use extension review instructions.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/ext-prompts/ext-review.md",
        .data = "Run the extension review prompt.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/ext-themes/ext-theme.json",
        .data =
        \\{
        \\  "name": "ext-theme",
        \\  "base": "dark",
        \\  "colors": { "primary": "#abcdef" }
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const extension_path = try makeTmpPath(allocator, tmp, "repo/extensions/discoverer.js");
    defer allocator.free(extension_path);
    var source_info = SourceInfo{
        .path = try allocator.dupe(u8, extension_path),
        .source = try allocator.dupe(u8, "extension"),
        .scope = .project,
        .origin = .top_level,
        .base_dir = try allocator.dupe(u8, cwd),
    };
    defer source_info.deinit(allocator);

    const discovery = ExtensionDiscoveredResources{
        .extension_path = extension_path,
        .source_info = source_info,
        .skill_paths = &.{"ext-skills"},
        .prompt_paths = &.{"ext-prompts"},
        .theme_paths = &.{"ext-themes"},
    };

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .runtime_theme = "ext-theme",
        .extension_discoveries = &.{discovery},
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.skills.len);
    try std.testing.expectEqualStrings("ext-review", bundle.skills[0].name);
    try std.testing.expectEqualStrings("Extension review skill", bundle.skills[0].description);
    try std.testing.expectEqual(@as(usize, 1), bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("ext-review", bundle.prompt_templates[0].name);
    try std.testing.expectEqualStrings("ext-theme", bundle.selectedTheme().name);
    try std.testing.expectEqualStrings("#abcdef", bundle.selectedTheme().colors.primary.?);
}

test "loadResourceBundle collects malformed theme config errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/broken.json",
        .data = "{ malformed",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .project = .{ .themes = &.{"themes"} },
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.config_errors.len);
    try std.testing.expectEqual(config_errors.Source.theme, bundle.config_errors[0].source);
}
test "detectTerminalName maps documented terminal fallback chain" {
    const allocator = std.testing.allocator;

    const Case = struct {
        key: []const u8,
        value: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .key = "TERM_PROGRAM", .value = "Apple_Terminal", .expected = "terminal" },
        .{ .key = "TERM_PROGRAM", .value = "iTerm.app", .expected = "iterm" },
        .{ .key = "TERM_PROGRAM", .value = "Ghostty", .expected = "ghostty" },
        .{ .key = "TERM_PROGRAM", .value = "WezTerm", .expected = "wezterm" },
        .{ .key = "TERM_PROGRAM", .value = "vscode", .expected = "vscode" },
        .{ .key = "TERM_PROGRAM", .value = "kitty", .expected = "kitty" },
        .{ .key = "TERM_PROGRAM", .value = "Alacritty", .expected = "alacritty" },
    };

    for (cases) |case| {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put(case.key, case.value);
        const detected = try detectTerminalName(allocator, &env_map);
        defer allocator.free(detected);
        try std.testing.expectEqualStrings(case.expected, detected);
    }

    var kitty_env = std.process.Environ.Map.init(allocator);
    defer kitty_env.deinit();
    try kitty_env.put("KITTY_WINDOW_ID", "42");
    const detected = try detectTerminalName(allocator, &kitty_env);
    defer allocator.free(detected);
    try std.testing.expectEqualStrings("kitty", detected);

    var term_env = std.process.Environ.Map.init(allocator);
    defer term_env.deinit();
    try term_env.put("TERM", "xterm-256color");
    const term_detected = try detectTerminalName(allocator, &term_env);
    defer allocator.free(term_detected);
    try std.testing.expectEqualStrings("xterm", term_detected);

    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    const fallback = try detectTerminalName(allocator, &empty_env);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("term", fallback);
}

test "PI_THEME env var selects built-in codex over settings theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_THEME", "codex");

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .env_map = &env_map,
        .project = .{ .theme = "light" },
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqualStrings("codex", bundle.selectedTheme().name);
}

test "theme resolution priority honors env runtime project global default" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .theme = "light" },
        .project = .{ .theme = "codex" },
        .runtime_theme = "dark",
        .env_map = &env_map,
    });
    defer bundle.deinit(allocator);
    try std.testing.expectEqualStrings("dark", bundle.selectedTheme().name);

    var env_override = std.process.Environ.Map.init(allocator);
    defer env_override.deinit();
    try env_override.put("PI_THEME", "codex");
    const env_index = resolveThemeIndex(bundle.themes, &env_override, "dark", "light", null);
    try std.testing.expectEqualStrings("codex", bundle.themes[env_index].name);

    const runtime_index = resolveThemeIndex(bundle.themes, &env_map, "light", "codex", "dark");
    try std.testing.expectEqualStrings("light", bundle.themes[runtime_index].name);

    const project_index = resolveThemeIndex(bundle.themes, &env_map, null, "codex", "light");
    try std.testing.expectEqualStrings("codex", bundle.themes[project_index].name);

    const global_index = resolveThemeIndex(bundle.themes, &env_map, null, null, "light");
    try std.testing.expectEqualStrings("light", bundle.themes[global_index].name);

    const default_index = resolveThemeIndex(bundle.themes, &env_map, null, null, null);
    try std.testing.expectEqualStrings("dark", bundle.themes[default_index].name);

    try env_map.put("COLORFGBG", "0;15");
    const detected_light_index = resolveThemeIndex(bundle.themes, &env_map, null, null, null);
    try std.testing.expectEqualStrings("light", bundle.themes[detected_light_index].name);

    try env_map.put("PI_THEME", "dark");
    const env_over_detected_index = resolveThemeIndex(bundle.themes, &env_map, null, null, null);
    try std.testing.expectEqualStrings("dark", bundle.themes[env_over_detected_index].name);
}

test "default themes include dark light and codex palettes" {
    const allocator = std.testing.allocator;

    var dark = try Theme.initDefault(allocator);
    defer dark.deinit(allocator);
    var light = try Theme.initLight(allocator);
    defer light.deinit(allocator);
    var codex = try Theme.initCodex(allocator);
    defer codex.deinit(allocator);

    try std.testing.expectEqualStrings("dark", dark.name);
    try std.testing.expectEqualStrings("light", light.name);
    try std.testing.expectEqualStrings("codex", codex.name);
    try std.testing.expectEqualStrings("#d18b50", codex.colors.primary.?);
    try std.testing.expectEqualStrings("#0f1012", codex.colors.background.?);
    try std.testing.expectEqualStrings("#d18b50", codex.styles[@intFromEnum(ThemeToken.prompt_glyph)].fg.?);

    const dark_prompt = try dark.applyAlloc(allocator, .prompt, "> ");
    defer allocator.free(dark_prompt);
    const light_prompt = try light.applyAlloc(allocator, .prompt, "> ");
    defer allocator.free(light_prompt);

    try std.testing.expectEqualStrings("> ", dark_prompt);
    try std.testing.expectEqualStrings("> ", light_prompt);
}

test "theme files can override palette colors and component tokens" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dawn.json",
        .data =
        \\{
        \\  "name": "dawn",
        \\  "base": "light",
        \\  "colors": {
        \\    "primary": "#112233",
        \\    "background": "#faf4ed",
        \\    "foreground": "#302d41",
        \\    "border": "#9988aa"
        \\  },
        \\  "tokens": {
        \\    "overlayTitle": { "underline": true }
        \\  }
        \\}
        ,
    });

    const path = try makeTmpPath(allocator, tmp, "dawn.json");
    defer allocator.free(path);

    var resource = ResolvedResource{
        .path = try allocator.dupe(u8, path),
        .enabled = true,
        .source_info = .{
            .path = try allocator.dupe(u8, path),
            .source = try allocator.dupe(u8, "local"),
            .scope = .user,
            .origin = .top_level,
            .base_dir = null,
        },
    };
    defer resource.deinit(allocator);

    var errors = std.ArrayList(config_errors.ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var theme = (try loadThemeFromFile(allocator, std.testing.io, resource, &errors)).?;
    defer theme.deinit(allocator);

    try std.testing.expectEqualStrings("dawn", theme.name);
    const overlay_title = theme.styles[@intFromEnum(ThemeToken.overlay_title)];
    try std.testing.expect(overlay_title.underline);
    try std.testing.expectEqualStrings("#112233", theme.colors.primary.?);
    try std.testing.expectEqualStrings("#9988aa", theme.colors.border.?);
}
