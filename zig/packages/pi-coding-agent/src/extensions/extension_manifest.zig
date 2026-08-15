const std = @import("std");
const common = @import("../tools/common.zig");
const extension_events = @import("extension_events.zig");

pub const SCHEMA_VERSION = "pi-extension.v1";

pub const Diagnostic = struct {
    code: []u8,
    path: []u8,
    message: []u8,
    manifest_path: []u8,
    severity: []u8,
    phase: []u8,
    correlation_id: []u8,
    span_id: []u8,
    package_id: ?[]u8 = null,
    runtime: ?[]u8 = null,
    capability_id: ?[]u8 = null,
    policy_source: ?[]u8 = null,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.path);
        allocator.free(self.message);
        allocator.free(self.manifest_path);
        allocator.free(self.severity);
        allocator.free(self.phase);
        allocator.free(self.correlation_id);
        allocator.free(self.span_id);
        if (self.package_id) |value| allocator.free(value);
        if (self.runtime) |value| allocator.free(value);
        if (self.capability_id) |value| allocator.free(value);
        if (self.policy_source) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const RuntimeKind = enum {
    typescript,
    javascript,
    process_jsonl,
    future,

    pub fn jsonName(self: RuntimeKind) []const u8 {
        return switch (self) {
            .typescript => "typescript",
            .javascript => "javascript",
            .process_jsonl => "process_jsonl",
            .future => "future",
        };
    }

    pub fn adapterName(self: RuntimeKind) []const u8 {
        return switch (self) {
            .typescript, .javascript => "ts-js-extension-loader",
            .process_jsonl => "process-jsonl-host",
            .future => "future-runtime-placeholder",
        };
    }

    pub fn executable(self: RuntimeKind) bool {
        return switch (self) {
            .future => false,
            else => true,
        };
    }
};

pub const NormalizedManifest = struct {
    package_root: []u8,
    manifest_path: []u8,
    schema_version: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    runtime_kind: RuntimeKind,
    runtime_entrypoint: std.json.Value,
    runtime_limits: std.json.Value,
    lifecycle: std.json.Value,
    exposure: std.json.Value,
    tools: std.json.Value,
    commands: std.json.Value,
    resources: std.json.Value,
    providers: std.json.Value,
    hooks: std.json.Value,
    capabilities: std.json.Value,
    permissions: std.json.Value,
    dependencies: std.json.Value,
    workflows: std.json.Value,
    diagnostics: []Diagnostic = &.{},

    pub fn deinit(self: *NormalizedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.schema_version);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        common.deinitJsonValue(allocator, self.runtime_entrypoint);
        common.deinitJsonValue(allocator, self.runtime_limits);
        common.deinitJsonValue(allocator, self.lifecycle);
        common.deinitJsonValue(allocator, self.exposure);
        common.deinitJsonValue(allocator, self.tools);
        common.deinitJsonValue(allocator, self.commands);
        common.deinitJsonValue(allocator, self.resources);
        common.deinitJsonValue(allocator, self.providers);
        common.deinitJsonValue(allocator, self.hooks);
        common.deinitJsonValue(allocator, self.capabilities);
        common.deinitJsonValue(allocator, self.permissions);
        common.deinitJsonValue(allocator, self.dependencies);
        common.deinitJsonValue(allocator, self.workflows);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn registrySnapshotJson(self: *const NormalizedManifest, allocator: std.mem.Allocator) ![]u8 {
        const value = try self.registryJsonValue(allocator, true, null, null, null);
        defer common.deinitJsonValue(allocator, value);
        return std.json.Stringify.valueAlloc(allocator, value, .{});
    }

    fn registryJsonValue(
        self: *const NormalizedManifest,
        allocator: std.mem.Allocator,
        active: bool,
        inactive_reason: ?[]const u8,
        source_scope: ?[]const u8,
        precedence_rank: ?u16,
    ) !std.json.Value {
        var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = entry });

        try common.putString(allocator, &entry, "id", self.id);
        try common.putString(allocator, &entry, "name", self.name);
        try common.putString(allocator, &entry, "version", self.version);
        try common.putString(allocator, &entry, "description", self.description);
        try common.putString(allocator, &entry, "schemaVersion", self.schema_version);
        try common.putString(allocator, &entry, "manifestPath", self.manifest_path);
        try common.putString(allocator, &entry, "packageRoot", self.package_root);
        try common.putBool(allocator, &entry, "active", active);
        try common.putValue(allocator, &entry, "inactiveReason", if (inactive_reason) |reason| .{ .string = try allocator.dupe(u8, reason) } else .null);
        try common.putValue(allocator, &entry, "sourceScope", if (source_scope) |scope| .{ .string = try allocator.dupe(u8, scope) } else .null);
        try common.putValue(allocator, &entry, "precedenceRank", if (precedence_rank) |rank| .{ .integer = rank } else .null);

        var runtime = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = runtime });
        try common.putString(allocator, &runtime, "kind", self.runtime_kind.jsonName());
        try common.putString(allocator, &runtime, "adapter", self.runtime_kind.adapterName());
        try common.putBool(allocator, &runtime, "executable", self.runtime_kind.executable());
        try common.putValue(allocator, &runtime, "entrypoint", try common.cloneJsonValue(allocator, self.runtime_entrypoint));
        try common.putValue(allocator, &runtime, "limits", try common.cloneJsonValue(allocator, self.runtime_limits));
        try common.putValue(allocator, &runtime, "lifecycle", try common.cloneJsonValue(allocator, self.lifecycle));
        try common.putValue(allocator, &runtime, "exposure", try common.cloneJsonValue(allocator, self.exposure));
        try common.putValue(allocator, &entry, "runtime", .{ .object = runtime });

        var declarations = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = declarations });
        try common.putValue(allocator, &declarations, "tools", try common.cloneJsonValue(allocator, self.tools));
        try common.putValue(allocator, &declarations, "commands", try common.cloneJsonValue(allocator, self.commands));
        try common.putValue(allocator, &declarations, "resources", try common.cloneJsonValue(allocator, self.resources));
        try common.putValue(allocator, &declarations, "providers", try common.cloneJsonValue(allocator, self.providers));
        try common.putValue(allocator, &declarations, "hooks", try common.cloneJsonValue(allocator, self.hooks));
        try common.putValue(allocator, &declarations, "capabilities", try common.cloneJsonValue(allocator, self.capabilities));
        try common.putValue(allocator, &declarations, "permissions", try common.cloneJsonValue(allocator, self.permissions));
        try common.putValue(allocator, &declarations, "dependencies", try common.cloneJsonValue(allocator, self.dependencies));
        try common.putValue(allocator, &declarations, "workflows", try common.cloneJsonValue(allocator, self.workflows));
        try common.putValue(allocator, &entry, "declarations", .{ .object = declarations });

        try common.putValue(allocator, &entry, "hookChains", try hookChainsJsonValue(allocator, self.hooks));
        try common.putValue(allocator, &entry, "workflowRegistry", try workflowRegistryJsonValue(allocator, self.workflows));

        var diagnostics = std.json.Array.init(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .array = diagnostics });
        for (self.diagnostics) |diagnostic| {
            try diagnostics.append(try diagnosticJsonValue(allocator, diagnostic));
        }
        try common.putValue(allocator, &entry, "diagnostics", .{ .array = diagnostics });

        return .{ .object = entry };
    }
};

pub const ValidationResult = union(enum) {
    valid: NormalizedManifest,
    invalid: []Diagnostic,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .valid => |*manifest| manifest.deinit(allocator),
            .invalid => |diagnostics| {
                for (diagnostics) |*diagnostic| diagnostic.deinit(allocator);
                allocator.free(diagnostics);
            },
        }
        self.* = undefined;
    }
};

pub const ManifestSource = struct {
    package_root: []const u8,
    manifest_path: []const u8,
    manifest_text: []const u8,
    source_scope: []const u8,
    precedence_rank: u16,
};

pub const ManifestRecord = struct {
    manifest: NormalizedManifest,
    active: bool,
    inactive_reason: ?[]u8 = null,
    source_scope: []u8,
    precedence_rank: u16,

    fn deinit(self: *ManifestRecord, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);
        if (self.inactive_reason) |reason| allocator.free(reason);
        allocator.free(self.source_scope);
        self.* = undefined;
    }
};

pub const ManifestSet = struct {
    records: []ManifestRecord,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *ManifestSet, allocator: std.mem.Allocator) void {
        for (self.records) |*record| record.deinit(allocator);
        allocator.free(self.records);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn registrySnapshotJson(self: *const ManifestSet, allocator: std.mem.Allocator) ![]u8 {
        var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = root });

        var packages = std.json.Array.init(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .array = packages });
        for (self.records) |*record| {
            try packages.append(try record.manifest.registryJsonValue(
                allocator,
                record.active,
                record.inactive_reason,
                record.source_scope,
                record.precedence_rank,
            ));
        }
        try common.putValue(allocator, &root, "packages", .{ .array = packages });

        var diagnostics = std.json.Array.init(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .array = diagnostics });
        for (self.records) |record| {
            for (record.manifest.diagnostics) |diagnostic| {
                try diagnostics.append(try diagnosticJsonValue(allocator, diagnostic));
            }
        }
        for (self.diagnostics) |diagnostic| {
            try diagnostics.append(try diagnosticJsonValue(allocator, diagnostic));
        }
        try common.putValue(allocator, &root, "diagnostics", .{ .array = diagnostics });
        try common.putValue(allocator, &root, "resolvedResources", try resolvedResourcesJsonValue(allocator, self.records));
        try common.putValue(allocator, &root, "hookChains", try manifestSetHookChainsJsonValue(allocator, self.records));
        try common.putValue(allocator, &root, "workflowRegistry", try manifestSetWorkflowRegistryJsonValue(allocator, self.records));
        try common.putValue(allocator, &root, "composition", try compositionJsonValue(allocator, self.records, self.diagnostics));

        const value = std.json.Value{ .object = root };
        defer common.deinitJsonValue(allocator, value);
        return std.json.Stringify.valueAlloc(allocator, value, .{});
    }
};

pub fn parseManifestText(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    manifest_path: []const u8,
    manifest_text: []const u8,
) !ValidationResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch {
        return invalidOne(allocator, manifest_path, "$", "manifest.malformed_json", "malformed JSON");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return invalidOne(allocator, manifest_path, "$", "manifest.expected_object", "expected object"),
    };

    if (try requiredString(allocator, manifest_path, root, "$", "schemaVersion")) |diagnostic| return diagnostic;
    const schema_version = stringValue(root, "schemaVersion");
    if (!std.mem.eql(u8, schema_version, SCHEMA_VERSION)) {
        const message = try std.fmt.allocPrint(allocator, "unsupported schema version \"{s}\"; expected " ++ SCHEMA_VERSION, .{schema_version});
        defer allocator.free(message);
        return invalidOne(allocator, manifest_path, "$.schemaVersion", "manifest.unsupported_schema_version", message);
    }

    if (try requiredString(allocator, manifest_path, root, "$", "id")) |diagnostic| return diagnostic;
    if (try requiredString(allocator, manifest_path, root, "$", "name")) |diagnostic| return diagnostic;
    if (try requiredString(allocator, manifest_path, root, "$", "version")) |diagnostic| return diagnostic;
    const description = if (root.get("description")) |value| switch (value) {
        .string => |text| text,
        else => return invalidOne(allocator, manifest_path, "$.description", "manifest.expected_string", "expected string"),
    } else "";

    if (try requiredObject(allocator, manifest_path, root, "$", "runtime")) |diagnostic| return diagnostic;
    const runtime_object = objectValue(root, "runtime");
    if (try requiredString(allocator, manifest_path, runtime_object, "$.runtime", "kind")) |diagnostic| return diagnostic;
    const runtime_kind_text = stringValue(runtime_object, "kind");
    const runtime_kind = parseRuntimeKind(runtime_kind_text) orelse {
        const message = try std.fmt.allocPrint(allocator, "unsupported runtime kind \"{s}\"", .{runtime_kind_text});
        defer allocator.free(message);
        return invalidOne(allocator, manifest_path, "$.runtime.kind", "manifest.unsupported_runtime", message);
    };
    if (try requiredAny(allocator, manifest_path, runtime_object, "$.runtime", "entrypoint")) |diagnostic| return diagnostic;
    const entrypoint = runtime_object.get("entrypoint").?;
    if (try validateRuntimeEntrypoint(allocator, manifest_path, runtime_kind, entrypoint)) |diagnostic| return diagnostic;

    const runtime_limits = switch (try normalizeRuntimeLimits(allocator, manifest_path, runtime_object.get("limits"))) {
        .valid => |value| value,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer common.deinitJsonValue(allocator, runtime_limits);
    const lifecycle = switch (try normalizeLifecycle(allocator, manifest_path, root.get("lifecycle"))) {
        .valid => |value| value,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer common.deinitJsonValue(allocator, lifecycle);
    const exposure = switch (try normalizeExposure(allocator, manifest_path, root.get("exposure"))) {
        .valid => |value| value,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer common.deinitJsonValue(allocator, exposure);

    const capabilities = switch (try normalizeCapabilities(allocator, manifest_path, root.get("capabilities"))) {
        .valid => |value| value,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer common.deinitJsonValue(allocator, capabilities);
    const permissions = switch (try arraySection(allocator, manifest_path, root, "permissions")) {
        .valid => |value| value,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer common.deinitJsonValue(allocator, permissions);
    const dependencies = switch (try arraySection(allocator, manifest_path, root, "dependencies")) {
        .valid => |value| value,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer common.deinitJsonValue(allocator, dependencies);
    var diagnostics = std.ArrayList(Diagnostic).empty;
    errdefer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
        diagnostics.deinit(allocator);
    }

    const owner = DeclarationOwner{
        .id = stringValue(root, "id"),
        .name = stringValue(root, "name"),
        .version = stringValue(root, "version"),
        .package_root = package_root,
        .manifest_path = manifest_path,
        .runtime_kind = runtime_kind,
    };

    const tools = try normalizeDeclarationArray(allocator, manifest_path, root.get("tools"), .tools, owner, &diagnostics);
    errdefer common.deinitJsonValue(allocator, tools);
    const commands = try normalizeDeclarationArray(allocator, manifest_path, root.get("commands"), .commands, owner, &diagnostics);
    errdefer common.deinitJsonValue(allocator, commands);
    const resources = try normalizeDeclarationArray(allocator, manifest_path, root.get("resources"), .resources, owner, &diagnostics);
    errdefer common.deinitJsonValue(allocator, resources);
    const providers = try normalizeDeclarationArray(allocator, manifest_path, root.get("providers"), .providers, owner, &diagnostics);
    errdefer common.deinitJsonValue(allocator, providers);
    const hooks = try normalizeHooks(allocator, manifest_path, root.get("hooks"), owner, &diagnostics);
    errdefer common.deinitJsonValue(allocator, hooks);
    const workflows = try normalizeWorkflows(allocator, manifest_path, root.get("workflows"), owner, &diagnostics);
    errdefer common.deinitJsonValue(allocator, workflows);

    return .{ .valid = .{
        .package_root = try allocator.dupe(u8, package_root),
        .manifest_path = try allocator.dupe(u8, manifest_path),
        .schema_version = try allocator.dupe(u8, schema_version),
        .id = try allocator.dupe(u8, stringValue(root, "id")),
        .name = try allocator.dupe(u8, stringValue(root, "name")),
        .version = try allocator.dupe(u8, stringValue(root, "version")),
        .description = try allocator.dupe(u8, description),
        .runtime_kind = runtime_kind,
        .runtime_entrypoint = try common.cloneJsonValue(allocator, entrypoint),
        .runtime_limits = runtime_limits,
        .lifecycle = lifecycle,
        .exposure = exposure,
        .tools = tools,
        .commands = commands,
        .resources = resources,
        .providers = providers,
        .hooks = hooks,
        .capabilities = capabilities,
        .permissions = permissions,
        .dependencies = dependencies,
        .workflows = workflows,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    } };
}

pub fn resolveManifestSources(
    allocator: std.mem.Allocator,
    sources: []const ManifestSource,
) !ManifestSet {
    var records = std.ArrayList(ManifestRecord).empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }
    var diagnostics = std.ArrayList(Diagnostic).empty;
    errdefer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(allocator);
        diagnostics.deinit(allocator);
    }

    for (sources) |source| {
        const parsed = try parseManifestText(allocator, source.package_root, source.manifest_path, source.manifest_text);
        switch (parsed) {
            .valid => |manifest| {
                try records.append(allocator, .{
                    .manifest = manifest,
                    .active = true,
                    .source_scope = try allocator.dupe(u8, source.source_scope),
                    .precedence_rank = source.precedence_rank,
                });
            },
            .invalid => |items| {
                for (items) |diagnostic| {
                    try diagnostics.append(allocator, diagnostic);
                }
                allocator.free(items);
            },
        }
    }

    for (records.items, 0..) |*candidate, index| {
        if (!candidate.active) continue;
        var selected_index = index;
        for (records.items[index + 1 ..], index + 1..) |*other, other_index| {
            if (!std.mem.eql(u8, candidate.manifest.id, other.manifest.id)) continue;
            const selected = &records.items[selected_index];
            const conflict = !std.mem.eql(u8, selected.manifest.version, other.manifest.version) or
                !std.mem.eql(u8, selected.manifest.package_root, other.manifest.package_root);
            if (!conflict) {
                other.active = false;
                other.inactive_reason = try allocator.dupe(u8, "duplicate-equivalent-package");
                continue;
            }
            if (other.precedence_rank < selected.precedence_rank) {
                selected_index = other_index;
            }
        }
        if (selected_index != index) {
            records.items[index].active = false;
            records.items[index].inactive_reason = try allocator.dupe(u8, "duplicate-package-identity");
        }
        const winner = &records.items[selected_index];
        for (records.items[index + 1 ..]) |*other| {
            if (!std.mem.eql(u8, winner.manifest.id, other.manifest.id)) continue;
            if (&other.manifest == &winner.manifest) continue;
            if (other.active and (other.precedence_rank > winner.precedence_rank or selected_index != index)) {
                other.active = false;
                other.inactive_reason = try allocator.dupe(u8, "duplicate-package-identity");
            }
            const message = try std.fmt.allocPrint(
                allocator,
                "duplicate package identity \"{s}\" from {s} conflicts with selected source {s}",
                .{ other.manifest.id, other.manifest.manifest_path, winner.manifest.manifest_path },
            );
            defer allocator.free(message);
            try diagnostics.append(allocator, try makeDiagnostic(
                allocator,
                other.manifest.manifest_path,
                "$.id",
                "manifest.duplicate_package_identity",
                message,
            ));
        }
    }

    try resolveDependencyGraph(allocator, records.items, &diagnostics);

    return .{
        .records = try records.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

const JsonValueResult = union(enum) {
    valid: std.json.Value,
    invalid: ValidationResult,
};

const DeclarationSection = enum {
    tools,
    commands,
    resources,
    providers,

    fn fieldName(self: DeclarationSection) []const u8 {
        return switch (self) {
            .tools => "tools",
            .commands => "commands",
            .resources => "resources",
            .providers => "providers",
        };
    }
};

const DeclarationOwner = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    package_root: []const u8,
    manifest_path: []const u8,
    runtime_kind: RuntimeKind,
};

fn parseRuntimeKind(value: []const u8) ?RuntimeKind {
    inline for (@typeInfo(RuntimeKind).@"enum".fields) |field| {
        const kind: RuntimeKind = @enumFromInt(field.value);
        if (std.mem.eql(u8, value, kind.jsonName())) return kind;
    }
    return null;
}

fn validateRuntimeEntrypoint(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    kind: RuntimeKind,
    entrypoint: std.json.Value,
) !?ValidationResult {
    switch (kind) {
        .typescript => {
            const path = try stringEntrypoint(allocator, manifest_path, entrypoint);
            if (path) |diagnostic| return diagnostic;
            const value = entrypoint.string;
            if (!std.mem.endsWith(u8, value, ".ts") and !std.mem.endsWith(u8, value, ".js")) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint", "manifest.invalid_entrypoint", "typescript entrypoint must end in .ts or .js");
            }
            return validatePackageRelativePath(allocator, manifest_path, "$.runtime.entrypoint", value, null);
        },
        .javascript => {
            const path = try stringEntrypoint(allocator, manifest_path, entrypoint);
            if (path) |diagnostic| return diagnostic;
            const value = entrypoint.string;
            if (!std.mem.endsWith(u8, value, ".js")) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint", "manifest.invalid_entrypoint", "javascript entrypoint must end in .js");
            }
            return validatePackageRelativePath(allocator, manifest_path, "$.runtime.entrypoint", value, null);
        },
        .process_jsonl => {
            if (entrypoint != .object) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint", "manifest.expected_object", "process_jsonl entrypoint must be an object");
            }
            const argv = entrypoint.object.get("argv") orelse
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint.argv", "manifest.missing_required_field", "missing required field");
            if (argv != .array) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint.argv", "manifest.expected_array", "expected array");
            }
            if (argv.array.items.len == 0) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint.argv", "manifest.invalid_entrypoint", "process_jsonl argv must not be empty");
            }
            for (argv.array.items, 0..) |arg, index| {
                if (arg != .string or arg.string.len == 0) {
                    const json_path = try std.fmt.allocPrint(allocator, "$.runtime.entrypoint.argv[{d}]", .{index});
                    defer allocator.free(json_path);
                    return try invalidOne(allocator, manifest_path, json_path, "manifest.expected_string", "expected non-empty string");
                }
            }
            return null;
        },
        .future => {
            if (entrypoint != .object) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint", "manifest.expected_object", "future runtime entrypoint must be an object");
            }
            const contract = entrypoint.object.get("contract") orelse
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint.contract", "manifest.missing_required_field", "missing required field");
            if (contract != .string or contract.string.len == 0) {
                return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint.contract", "manifest.expected_string", "expected non-empty string");
            }
            return null;
        },
    }
}

fn stringEntrypoint(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    entrypoint: std.json.Value,
) !?ValidationResult {
    if (entrypoint == .string and entrypoint.string.len > 0) return null;
    return try invalidOne(allocator, manifest_path, "$.runtime.entrypoint", "manifest.expected_string", "expected non-empty string");
}

fn validatePackageRelativePath(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    json_path: []const u8,
    value: []const u8,
    required_suffix: ?[]const u8,
) !?ValidationResult {
    if (value.len == 0) return try invalidOne(allocator, manifest_path, json_path, "manifest.invalid_entrypoint", "path must not be empty");
    if (std.fs.path.isAbsolute(value)) return try invalidOne(allocator, manifest_path, json_path, "manifest.invalid_entrypoint", "path must be package-relative");
    if (std.mem.indexOf(u8, value, "\\") != null) return try invalidOne(allocator, manifest_path, json_path, "manifest.invalid_entrypoint", "path must use '/' separators");
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return try invalidOne(allocator, manifest_path, json_path, "manifest.invalid_entrypoint", "path must be normalized and stay within the package root");
        }
    }
    if (required_suffix) |suffix| {
        if (!std.mem.endsWith(u8, value, suffix)) {
            const message = try std.fmt.allocPrint(allocator, "path must end in {s}", .{suffix});
            defer allocator.free(message);
            return try invalidOne(allocator, manifest_path, json_path, "manifest.invalid_entrypoint", message);
        }
    }
    return null;
}

fn normalizeRuntimeLimits(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
) !JsonValueResult {
    var object = if (maybe_value) |value| blk: {
        if (value != .object) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.runtime.limits", "manifest.expected_object", "expected object") };
        break :blk (try common.cloneJsonValue(allocator, value)).object;
    } else try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    if (object.get("toolScopes")) |tool_scopes| {
        if (tool_scopes != .array) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.runtime.limits.toolScopes", "manifest.expected_array", "expected array") };
    } else {
        try common.putValue(allocator, &object, "toolScopes", try emptyArrayValue(allocator));
    }
    if (object.get("timeoutMs")) |timeout| {
        if (!isNonNegativeInteger(timeout)) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.runtime.limits.timeoutMs", "manifest.expected_non_negative_integer", "expected non-negative integer") };
    } else {
        try common.putInt(allocator, &object, "timeoutMs", 30000);
    }
    if (object.get("outputBytes")) |output_bytes| {
        if (!isNonNegativeInteger(output_bytes)) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.runtime.limits.outputBytes", "manifest.expected_non_negative_integer", "expected non-negative integer") };
    } else {
        try common.putInt(allocator, &object, "outputBytes", 1048576);
    }
    return .{ .valid = .{ .object = object } };
}

fn normalizeLifecycle(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
) !JsonValueResult {
    var object = if (maybe_value) |value| blk: {
        if (value != .object) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.lifecycle", "manifest.expected_object", "expected object") };
        break :blk (try common.cloneJsonValue(allocator, value)).object;
    } else try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    if (object.get("required") == null) try common.putBool(allocator, &object, "required", false);
    if (object.get("startupTimeoutMs") == null) try common.putInt(allocator, &object, "startupTimeoutMs", 30000);
    if (object.get("shutdownTimeoutMs") == null) try common.putInt(allocator, &object, "shutdownTimeoutMs", 5000);
    return .{ .valid = .{ .object = object } };
}

fn normalizeExposure(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
) !JsonValueResult {
    var object = if (maybe_value) |value| blk: {
        if (value != .object) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.exposure", "manifest.expected_object", "expected object") };
        break :blk (try common.cloneJsonValue(allocator, value)).object;
    } else try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    inline for (.{ "tools", "commands", "providers", "hooks" }) |field| {
        if (object.get(field) == null) try common.putBool(allocator, &object, field, true);
    }
    if (object.get("workflows") == null) try common.putBool(allocator, &object, "workflows", false);
    return .{ .valid = .{ .object = object } };
}

fn normalizeCapabilities(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
) !JsonValueResult {
    var object = if (maybe_value) |value| blk: {
        if (value != .object) return .{ .invalid = try invalidOne(allocator, manifest_path, "$.capabilities", "manifest.expected_object", "expected object") };
        break :blk (try common.cloneJsonValue(allocator, value)).object;
    } else try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try ensureArrayDefault(allocator, &object, "exports");
    try ensureArrayDefault(allocator, &object, "imports");
    return .{ .valid = .{ .object = object } };
}

fn normalizeHooks(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
    owner: DeclarationOwner,
    diagnostics: *std.ArrayList(Diagnostic),
) !std.json.Value {
    const value = maybe_value orelse return try emptyArrayValue(allocator);
    if (value != .array) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, "$.hooks", "manifest.expected_array", "expected array"));
        return try emptyArrayValue(allocator);
    }
    var normalized = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = normalized });
    for (value.array.items, 0..) |item, index| {
        if (item != .object) {
            const path = try std.fmt.allocPrint(allocator, "$.hooks[{d}]", .{index});
            defer allocator.free(path);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_object", "expected object"));
            continue;
        }
        const event = try requiredDeclarationString(allocator, manifest_path, item.object, "hooks", index, "event", diagnostics) orelse continue;
        if (!isSupportedHookEvent(event)) {
            const path = try std.fmt.allocPrint(allocator, "$.hooks[{d}].event", .{index});
            defer allocator.free(path);
            const message = try std.fmt.allocPrint(allocator, "unsupported hook event \"{s}\"", .{event});
            defer allocator.free(message);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.unsupported_hook_event", message));
            continue;
        }
        if (try optionalIntegerDiagnostic(allocator, manifest_path, item.object, "hooks", index, "priority", diagnostics)) continue;
        if (try optionalIntegerDiagnostic(allocator, manifest_path, item.object, "hooks", index, "declarationOrder", diagnostics)) continue;
        if (try optionalHookErrorPolicyDiagnostic(allocator, manifest_path, item.object, index, diagnostics)) continue;

        var hook = (try common.cloneJsonValue(allocator, item)).object;
        errdefer common.deinitJsonValue(allocator, .{ .object = hook });
        if (hook.get("priority") == null) try common.putInt(allocator, &hook, "priority", 0);
        if (hook.get("declarationOrder") == null) try common.putInt(allocator, &hook, "declarationOrder", @intCast(index));
        if (hook.get("errorPolicy") == null) try common.putString(allocator, &hook, "errorPolicy", "continue");
        try common.putInt(allocator, &hook, "chainOrder", @intCast(normalized.items.len));
        try putOwnerRuntimeMetadata(allocator, &hook, owner);
        try normalized.append(.{ .object = hook });
    }
    return .{ .array = normalized };
}

fn normalizeDeclarationArray(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
    section: DeclarationSection,
    owner: DeclarationOwner,
    diagnostics: *std.ArrayList(Diagnostic),
) !std.json.Value {
    const value = maybe_value orelse return try emptyArrayValue(allocator);
    const field = section.fieldName();
    if (value != .array) {
        const path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
        defer allocator.free(path);
        try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_array", "expected array"));
        return try emptyArrayValue(allocator);
    }

    var normalized = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = normalized });
    for (value.array.items, 0..) |item, index| {
        if (item != .object) {
            const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}]", .{ field, index });
            defer allocator.free(path);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_object", "expected object"));
            continue;
        }
        if (try declarationEntryInvalid(allocator, manifest_path, item.object, section, index, diagnostics)) continue;

        var entry = (try common.cloneJsonValue(allocator, item)).object;
        errdefer common.deinitJsonValue(allocator, .{ .object = entry });
        try normalizeDeclarationDefaults(allocator, &entry, section, owner);
        try putOwnerRuntimeMetadata(allocator, &entry, owner);
        try normalized.append(.{ .object = entry });
    }
    return .{ .array = normalized };
}

fn normalizeWorkflows(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    maybe_value: ?std.json.Value,
    owner: DeclarationOwner,
    diagnostics: *std.ArrayList(Diagnostic),
) !std.json.Value {
    const value = maybe_value orelse return try emptyArrayValue(allocator);
    if (value != .array) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, "$.workflows", "manifest.expected_array", "expected array"));
        return try emptyArrayValue(allocator);
    }

    var normalized = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = normalized });
    for (value.array.items, 0..) |item, index| {
        if (item != .object) {
            const path = try std.fmt.allocPrint(allocator, "$.workflows[{d}]", .{index});
            defer allocator.free(path);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_object", "expected object"));
            continue;
        }
        const id = try requiredDeclarationString(allocator, manifest_path, item.object, "workflows", index, "id", diagnostics) orelse continue;
        if (try optionalDeclarationStringDiagnostic(allocator, manifest_path, item.object, "workflows", index, "description", diagnostics)) continue;
        if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, item.object, "workflows", index, "inputSchema", diagnostics)) continue;
        if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, item.object, "workflows", index, "outputSchema", diagnostics)) continue;
        if (try optionalDeclarationStringDiagnostic(allocator, manifest_path, item.object, "workflows", index, "executionMode", diagnostics)) continue;
        if (try optionalWorkflowArrayDiagnostic(allocator, manifest_path, item.object, index, "permissions", diagnostics)) continue;
        if (try optionalWorkflowArrayDiagnostic(allocator, manifest_path, item.object, index, "dependencies", diagnostics)) continue;
        if (try optionalWorkflowNonNegativeIntegerDiagnostic(allocator, manifest_path, item.object, index, "timeoutMs", diagnostics)) continue;
        if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, item.object, "workflows", index, "cancellation", diagnostics)) continue;
        if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, item.object, "workflows", index, "replay", diagnostics)) continue;
        if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, item.object, "workflows", index, "childAgentLimits", diagnostics)) continue;

        var workflow = (try common.cloneJsonValue(allocator, item)).object;
        errdefer common.deinitJsonValue(allocator, .{ .object = workflow });
        if (workflow.get("description") == null) try common.putString(allocator, &workflow, "description", "");
        if (workflow.get("inputSchema") == null) try common.putValue(allocator, &workflow, "inputSchema", try emptyObjectValue(allocator));
        if (workflow.get("outputSchema") == null) try common.putValue(allocator, &workflow, "outputSchema", try emptyObjectValue(allocator));
        if (workflow.get("executionMode") == null) try common.putString(allocator, &workflow, "executionMode", "agent");
        try ensureArrayDefault(allocator, &workflow, "permissions");
        try ensureArrayDefault(allocator, &workflow, "dependencies");
        if (workflow.get("timeoutMs") == null) try common.putInt(allocator, &workflow, "timeoutMs", 30000);
        if (workflow.get("cancellation") == null) try common.putValue(allocator, &workflow, "cancellation", try workflowCancellationDefault(allocator));
        if (workflow.get("replay") == null) try common.putValue(allocator, &workflow, "replay", try workflowReplayDefault(allocator));
        if (workflow.get("childAgentLimits") == null) {
            const timeout_ms = workflow.get("timeoutMs").?.integer;
            try common.putValue(allocator, &workflow, "childAgentLimits", try workflowChildAgentLimitsDefault(allocator, timeout_ms));
        } else if (workflow.getPtr("childAgentLimits")) |limits| switch (limits.*) {
            .object => |*object| try fillWorkflowChildAgentLimitDefaults(allocator, object, workflow.get("timeoutMs").?.integer),
            else => {},
        };
        try common.putString(allocator, &workflow, "sourceManifest", owner.manifest_path);
        try common.putString(allocator, &workflow, "status", if (entryPolicyDenied(.{ .object = workflow })) "denied" else "active");
        try common.putValue(allocator, &workflow, "commandName", try workflowSurfaceNameValue(allocator, item.object, "command", "commandName", id));
        try common.putValue(allocator, &workflow, "toolName", try workflowSurfaceNameValue(allocator, item.object, "tool", "toolName", id));
        try common.putValue(allocator, &workflow, "presetId", try workflowSurfaceNameValue(allocator, item.object, "subAgentPreset", "presetId", id));
        try putOwnerRuntimeMetadata(allocator, &workflow, owner);
        try normalized.append(.{ .object = workflow });
    }
    return .{ .array = normalized };
}

fn optionalWorkflowArrayDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    index: usize,
    field: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    const value = object.get(field) orelse return false;
    if (value == .array) return false;
    const path = try std.fmt.allocPrint(allocator, "$.workflows[{d}].{s}", .{ index, field });
    defer allocator.free(path);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_array", "expected array"));
    return true;
}

fn optionalWorkflowNonNegativeIntegerDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    index: usize,
    field: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    const value = object.get(field) orelse return false;
    if (isNonNegativeInteger(value)) return false;
    const path = try std.fmt.allocPrint(allocator, "$.workflows[{d}].{s}", .{ index, field });
    defer allocator.free(path);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_non_negative_integer", "expected non-negative integer"));
    return true;
}

fn workflowCancellationDefault(allocator: std.mem.Allocator) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putBool(allocator, &object, "propagate", true);
    return .{ .object = object };
}

fn workflowReplayDefault(allocator: std.mem.Allocator) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putBool(allocator, &object, "enabled", true);
    try common.putString(allocator, &object, "mode", "recorded");
    return .{ .object = object };
}

fn workflowChildAgentLimitsDefault(allocator: std.mem.Allocator, timeout_ms: i64) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try fillWorkflowChildAgentLimitDefaults(allocator, &object, timeout_ms);
    return .{ .object = object };
}

fn fillWorkflowChildAgentLimitDefaults(allocator: std.mem.Allocator, object: *std.json.ObjectMap, timeout_ms: i64) !void {
    if (object.get("maxChildren") == null) try common.putInt(allocator, &object, "maxChildren", 1);
    if (object.get("maxTurns") == null) try common.putInt(allocator, &object, "maxTurns", 1);
    if (object.get("maxToolCalls") == null) try common.putInt(allocator, &object, "maxToolCalls", 0);
    if (object.get("maxTokens") == null) try common.putInt(allocator, &object, "maxTokens", 0);
    if (object.get("timeoutMs") == null) try common.putInt(allocator, &object, "timeoutMs", timeout_ms);
}

fn workflowSurfaceNameValue(
    allocator: std.mem.Allocator,
    workflow: std.json.ObjectMap,
    exposure_field: []const u8,
    direct_field: []const u8,
    default_name: []const u8,
) !std.json.Value {
    if (entryPolicyDenied(.{ .object = workflow })) return .null;
    if (workflow.get(direct_field)) |value| {
        if (value == .string and value.string.len > 0) return .{ .string = try allocator.dupe(u8, value.string) };
    }
    const exposure = workflow.get("exposure") orelse return .null;
    if (exposure != .object) return .null;
    const surface = exposure.object.get(exposure_field) orelse return .null;
    return switch (surface) {
        .bool => |enabled| if (enabled) .{ .string = try allocator.dupe(u8, default_name) } else .null,
        .string => |name| .{ .string = try allocator.dupe(u8, name) },
        .object => |surface_object| blk: {
            if (entryPolicyDenied(.{ .object = surface_object })) break :blk .null;
            const name = if (surface_object.get("name")) |name_value| switch (name_value) {
                .string => |text| text,
                else => default_name,
            } else if (surface_object.get("id")) |id_value| switch (id_value) {
                .string => |text| text,
                else => default_name,
            } else default_name;
            break :blk .{ .string = try allocator.dupe(u8, name) };
        },
        else => .null,
    };
}

fn declarationEntryInvalid(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    section: DeclarationSection,
    index: usize,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    switch (section) {
        .tools => {
            _ = try requiredDeclarationString(allocator, manifest_path, object, section.fieldName(), index, "name", diagnostics) orelse return true;
            if (try optionalDeclarationStringDiagnostic(allocator, manifest_path, object, section.fieldName(), index, "description", diagnostics)) return true;
            if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, object, section.fieldName(), index, "inputSchema", diagnostics)) return true;
            if (try optionalDeclarationObjectDiagnostic(allocator, manifest_path, object, section.fieldName(), index, "parameters", diagnostics)) return true;
        },
        .commands => {
            _ = try requiredDeclarationString(allocator, manifest_path, object, section.fieldName(), index, "name", diagnostics) orelse return true;
            if (try optionalDeclarationStringDiagnostic(allocator, manifest_path, object, section.fieldName(), index, "description", diagnostics)) return true;
        },
        .resources => {
            _ = try requiredDeclarationString(allocator, manifest_path, object, section.fieldName(), index, "kind", diagnostics) orelse return true;
            _ = try requiredDeclarationString(allocator, manifest_path, object, section.fieldName(), index, "name", diagnostics) orelse return true;
            _ = try requiredDeclarationString(allocator, manifest_path, object, section.fieldName(), index, "path", diagnostics) orelse return true;
            if (try optionalDeclarationStringDiagnostic(allocator, manifest_path, object, section.fieldName(), index, "precedence", diagnostics)) return true;
        },
        .providers => {
            _ = try requiredDeclarationString(allocator, manifest_path, object, section.fieldName(), index, "id", diagnostics) orelse return true;
            if (try optionalDeclarationStringDiagnostic(allocator, manifest_path, object, section.fieldName(), index, "displayName", diagnostics)) return true;
            if (object.get("models")) |models| {
                if (models != .array) {
                    const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}].models", .{ section.fieldName(), index });
                    defer allocator.free(path);
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_array", "expected array"));
                    return true;
                }
            }
            if (object.get("credentialRequired")) |credential_required| {
                if (credential_required != .bool) {
                    const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}].credentialRequired", .{ section.fieldName(), index });
                    defer allocator.free(path);
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_boolean", "expected boolean"));
                    return true;
                }
            }
        },
    }
    return false;
}

fn normalizeDeclarationDefaults(
    allocator: std.mem.Allocator,
    entry: *std.json.ObjectMap,
    section: DeclarationSection,
    owner: DeclarationOwner,
) !void {
    switch (section) {
        .tools => {
            const name = entry.get("name").?.string;
            if (entry.get("label") == null) try common.putString(allocator, &entry, "label", name);
            if (entry.get("description") == null) try common.putString(allocator, &entry, "description", "");
            if (entry.get("inputSchema") == null and entry.get("parameters") == null) {
                try common.putValue(allocator, &entry, "inputSchema", try emptyObjectValue(allocator));
            }
        },
        .commands => {
            if (entry.get("description") == null) try common.putNull(allocator, &entry, "description");
        },
        .resources => {
            if (entry.get("precedence") == null) try common.putString(allocator, &entry, "precedence", "package");
        },
        .providers => {
            const id = entry.get("id").?.string;
            if (entry.get("name") == null) try common.putString(allocator, &entry, "name", id);
            if (entry.get("displayName") == null) try common.putString(allocator, &entry, "displayName", id);
            try ensureArrayDefault(allocator, &entry, "models");
            if (entry.get("credentialRequired") == null) try common.putBool(allocator, &entry, "credentialRequired", false);
        },
    }
    try common.putString(allocator, &entry, "sourceManifest", owner.manifest_path);
}

fn putOwnerRuntimeMetadata(
    allocator: std.mem.Allocator,
    entry: *std.json.ObjectMap,
    owner: DeclarationOwner,
) !void {
    var owner_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = owner_object });
    try common.putString(allocator, &owner_object, "id", owner.id);
    try common.putString(allocator, &owner_object, "name", owner.name);
    try common.putString(allocator, &owner_object, "version", owner.version);
    try common.putString(allocator, &owner_object, "manifestPath", owner.manifest_path);
    try common.putString(allocator, &owner_object, "packageRoot", owner.package_root);

    var runtime_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = runtime_object });
    try common.putString(allocator, &runtime_object, "kind", owner.runtime_kind.jsonName());
    try common.putString(allocator, &runtime_object, "adapter", owner.runtime_kind.adapterName());
    try common.putBool(allocator, &runtime_object, "executable", owner.runtime_kind.executable());

    try common.putValue(allocator, &entry, "owner", .{ .object = owner_object });
    try common.putValue(allocator, &entry, "runtime", .{ .object = runtime_object });
}

fn arraySection(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    root: std.json.ObjectMap,
    field: []const u8,
) !JsonValueResult {
    const value = root.get(field) orelse return .{ .valid = try emptyArrayValue(allocator) };
    if (value != .array) {
        const path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
        defer allocator.free(path);
        return .{ .invalid = try invalidOne(allocator, manifest_path, path, "manifest.expected_array", "expected array") };
    }
    return .{ .valid = try common.cloneJsonValue(allocator, value) };
}

fn emptyArrayValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

/// Adds `field -> []` to `object` when the key is currently absent. Used to
/// canonicalize manifest objects so consumers can treat missing arrays and
/// empty arrays identically. `object` accepts either `*ObjectMap` or
/// `**ObjectMap` to match the calling-convention used by call sites that
/// already hold a pointer.
fn ensureArrayDefault(
    allocator: std.mem.Allocator,
    object: anytype,
    field: []const u8,
) !void {
    const map_ptr = mapPtrFromAny(object);
    if (map_ptr.get(field) != null) return;
    try common.putValue(allocator, map_ptr, field, try emptyArrayValue(allocator));
}

inline fn mapPtrFromAny(object: anytype) *std.json.ObjectMap {
    const T = @TypeOf(object);
    const info = @typeInfo(T).pointer;
    if (info.child == std.json.ObjectMap) return object;
    // Otherwise it's already a `*ObjectMap` pointed-to via another pointer.
    return object.*;
}

fn emptyObjectValue(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
}

fn isNonNegativeInteger(value: std.json.Value) bool {
    return switch (value) {
        .integer => |number| number >= 0,
        else => false,
    };
}

fn invalidOne(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    path: []const u8,
    code: []const u8,
    message: []const u8,
) !ValidationResult {
    const diagnostics = try allocator.alloc(Diagnostic, 1);
    errdefer allocator.free(diagnostics);
    diagnostics[0] = try makeDiagnostic(allocator, manifest_path, path, code, message);
    return .{ .invalid = diagnostics };
}

fn makeDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    path: []const u8,
    code: []const u8,
    message: []const u8,
) !Diagnostic {
    const correlation_id = try std.fmt.allocPrint(allocator, "manifest:{s}", .{manifest_path});
    errdefer allocator.free(correlation_id);
    const span_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ code, path });
    errdefer allocator.free(span_id);
    return .{
        .code = try allocator.dupe(u8, code),
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
        .manifest_path = try allocator.dupe(u8, manifest_path),
        .severity = try allocator.dupe(u8, "error"),
        .phase = try allocator.dupe(u8, if (std.mem.startsWith(u8, code, "graph.")) "graph" else "manifest"),
        .correlation_id = correlation_id,
        .span_id = span_id,
    };
}

fn makeGraphDiagnostic(
    allocator: std.mem.Allocator,
    record: ManifestRecord,
    path: []const u8,
    code: []const u8,
    message: []const u8,
    capability_id: ?[]const u8,
    policy_source: ?[]const u8,
) !Diagnostic {
    var diagnostic = try makeDiagnostic(allocator, record.manifest.manifest_path, path, code, message);
    errdefer diagnostic.deinit(allocator);
    diagnostic.package_id = try allocator.dupe(u8, record.manifest.id);
    diagnostic.runtime = try allocator.dupe(u8, record.manifest.runtime_kind.jsonName());
    if (capability_id) |value| diagnostic.capability_id = try allocator.dupe(u8, value);
    if (policy_source) |value| diagnostic.policy_source = try allocator.dupe(u8, value);
    return diagnostic;
}

fn diagnosticJsonValue(allocator: std.mem.Allocator, diagnostic: Diagnostic) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putString(allocator, &object, "code", diagnostic.code);
    try common.putString(allocator, &object, "severity", diagnostic.severity);
    try common.putString(allocator, &object, "path", diagnostic.path);
    try common.putString(allocator, &object, "message", diagnostic.message);
    try common.putString(allocator, &object, "manifestPath", diagnostic.manifest_path);
    try common.putString(allocator, &object, "phase", diagnostic.phase);
    try common.putString(allocator, &object, "correlationId", diagnostic.correlation_id);
    try common.putString(allocator, &object, "spanId", diagnostic.span_id);
    try common.putValue(allocator, &object, "packageId", if (diagnostic.package_id) |value| .{ .string = try allocator.dupe(u8, value) } else .null);
    try common.putValue(allocator, &object, "runtime", if (diagnostic.runtime) |value| .{ .string = try allocator.dupe(u8, value) } else .null);
    try common.putValue(allocator, &object, "capabilityId", if (diagnostic.capability_id) |value| .{ .string = try allocator.dupe(u8, value) } else .null);
    try common.putValue(allocator, &object, "policySource", if (diagnostic.policy_source) |value| .{ .string = try allocator.dupe(u8, value) } else .null);
    return .{ .object = object };
}

fn requiredDeclarationString(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    section: []const u8,
    index: usize,
    field: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}].{s}", .{ section, index, field });
    defer allocator.free(path);
    const value = object.get(field) orelse {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.missing_required_field", "missing required field"));
        return null;
    };
    if (value != .string or value.string.len == 0) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_string", "expected non-empty string"));
        return null;
    }
    return value.string;
}

fn optionalDeclarationStringDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    section: []const u8,
    index: usize,
    field: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    const value = object.get(field) orelse return false;
    if (value == .string) return false;
    const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}].{s}", .{ section, index, field });
    defer allocator.free(path);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_string", "expected string"));
    return true;
}

fn optionalDeclarationObjectDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    section: []const u8,
    index: usize,
    field: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    const value = object.get(field) orelse return false;
    if (value == .object) return false;
    const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}].{s}", .{ section, index, field });
    defer allocator.free(path);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_object", "expected object"));
    return true;
}

fn optionalIntegerDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    section: []const u8,
    index: usize,
    field: []const u8,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    const value = object.get(field) orelse return false;
    if (value == .integer) return false;
    const path = try std.fmt.allocPrint(allocator, "$.{s}[{d}].{s}", .{ section, index, field });
    defer allocator.free(path);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.expected_integer", "expected integer"));
    return true;
}

fn optionalHookErrorPolicyDiagnostic(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    index: usize,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    const value = object.get("errorPolicy") orelse return false;
    if (value == .string and (std.mem.eql(u8, value.string, "continue") or std.mem.eql(u8, value.string, "fatal"))) return false;
    const path = try std.fmt.allocPrint(allocator, "$.hooks[{d}].errorPolicy", .{index});
    defer allocator.free(path);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, manifest_path, path, "manifest.unsupported_hook_error_policy", "expected \"continue\" or \"fatal\""));
    return true;
}

fn isSupportedHookEvent(event: []const u8) bool {
    for (extension_events.eventSurfaceNames()) |supported| {
        if (std.mem.eql(u8, event, supported)) return true;
    }
    return false;
}

const HookChainSortEntry = struct {
    hook: std.json.Value,
    event_name: []const u8,
    event_order: usize,
    priority: i64,
    declaration_order: i64,
    original_chain_order: i64,
    source_index: usize,
    hook_index: usize,
    source_scope: ?[]const u8 = null,
    precedence_rank: ?u16 = null,
};

fn hookChainsJsonValue(allocator: std.mem.Allocator, hooks: std.json.Value) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    var entries = std.ArrayList(HookChainSortEntry).empty;
    defer entries.deinit(allocator);
    try appendHookChainSortEntries(allocator, &entries, hooks, 0, null, null);
    std.sort.insertion(HookChainSortEntry, entries.items, {}, hookChainEntryLessThan);
    try appendSortedHookChainValues(allocator, &array, entries.items);
    return .{ .array = array };
}

fn manifestSetHookChainsJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    var entries = std.ArrayList(HookChainSortEntry).empty;
    defer entries.deinit(allocator);
    for (records, 0..) |record, record_index| {
        if (!record.active) continue;
        try appendHookChainSortEntries(allocator, &entries, record.manifest.hooks, record_index, record.source_scope, record.precedence_rank);
    }
    std.sort.insertion(HookChainSortEntry, entries.items, {}, hookChainEntryLessThan);
    try appendSortedHookChainValues(allocator, &array, entries.items);
    return .{ .array = array };
}

fn workflowRegistryJsonValue(allocator: std.mem.Allocator, workflows: std.json.Value) !std.json.Value {
    var records = [_]WorkflowRegistrySource{.{ .workflows = workflows }};
    return workflowRegistryFromSourcesJsonValue(allocator, &records);
}

fn manifestSetWorkflowRegistryJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var sources = std.ArrayList(WorkflowRegistrySource).empty;
    defer sources.deinit(allocator);
    for (records) |record| {
        if (!record.active) continue;
        try sources.append(allocator, .{
            .workflows = record.manifest.workflows,
            .source_scope = record.source_scope,
            .precedence_rank = record.precedence_rank,
        });
    }
    return workflowRegistryFromSourcesJsonValue(allocator, sources.items);
}

const WorkflowRegistrySource = struct {
    workflows: std.json.Value,
    source_scope: ?[]const u8 = null,
    precedence_rank: ?u16 = null,
};

fn workflowRegistryFromSourcesJsonValue(allocator: std.mem.Allocator, sources: []const WorkflowRegistrySource) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    var descriptors = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = descriptors });
    var commands = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = commands });
    var tools = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = tools });
    var presets = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = presets });

    for (sources) |source| {
        if (source.workflows != .array) continue;
        for (source.workflows.array.items) |workflow| {
            if (workflow != .object) continue;
            try descriptors.append(try workflowDescriptorJsonValue(allocator, workflow, source));
            if (jsonEntryString(workflow, "commandName")) |_| try commands.append(try workflowCommandJsonValue(allocator, workflow, source));
            if (jsonEntryString(workflow, "toolName")) |_| try tools.append(try workflowToolJsonValue(allocator, workflow, source));
            if (jsonEntryString(workflow, "presetId")) |_| try presets.append(try workflowPresetJsonValue(allocator, workflow, source));
        }
    }

    try common.putValue(allocator, &object, "descriptors", .{ .array = descriptors });
    try common.putValue(allocator, &object, "commands", .{ .array = commands });
    try common.putValue(allocator, &object, "tools", .{ .array = tools });
    try common.putValue(allocator, &object, "subAgentPresets", .{ .array = presets });
    return .{ .object = object };
}

fn workflowDescriptorJsonValue(allocator: std.mem.Allocator, workflow: std.json.Value, source: WorkflowRegistrySource) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try putWorkflowCommonFields(allocator, &object, workflow, source);
    try common.putValue(allocator, &object, "inputSchema", try common.cloneJsonValue(allocator, workflow.object.get("inputSchema") orelse .null));
    try common.putValue(allocator, &object, "outputSchema", try common.cloneJsonValue(allocator, workflow.object.get("outputSchema") orelse .null));
    try common.putValue(allocator, &object, "dependencies", try common.cloneJsonValue(allocator, workflow.object.get("dependencies") orelse .null));
    try common.putValue(allocator, &object, "cancellation", try common.cloneJsonValue(allocator, workflow.object.get("cancellation") orelse .null));
    try common.putValue(allocator, &object, "commandName", try optionalJsonString(allocator, jsonEntryString(workflow, "commandName")));
    try common.putValue(allocator, &object, "toolName", try optionalJsonString(allocator, jsonEntryString(workflow, "toolName")));
    try common.putValue(allocator, &object, "presetId", try optionalJsonString(allocator, jsonEntryString(workflow, "presetId")));
    return .{ .object = object };
}

fn workflowCommandJsonValue(allocator: std.mem.Allocator, workflow: std.json.Value, source: WorkflowRegistrySource) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try putWorkflowCommonFields(allocator, &object, workflow, source);
    try common.putString(allocator, &object, "name", jsonEntryString(workflow, "commandName") orelse "");
    try common.putValue(allocator, &object, "argumentSchema", try common.cloneJsonValue(allocator, workflow.object.get("inputSchema") orelse .null));
    return .{ .object = object };
}

fn workflowToolJsonValue(allocator: std.mem.Allocator, workflow: std.json.Value, source: WorkflowRegistrySource) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try putWorkflowCommonFields(allocator, &object, workflow, source);
    try common.putString(allocator, &object, "name", jsonEntryString(workflow, "toolName") orelse "");
    try common.putValue(allocator, &object, "inputSchema", try common.cloneJsonValue(allocator, workflow.object.get("inputSchema") orelse .null));
    try common.putValue(allocator, &object, "outputSchema", try common.cloneJsonValue(allocator, workflow.object.get("outputSchema") orelse .null));
    return .{ .object = object };
}

fn workflowPresetJsonValue(allocator: std.mem.Allocator, workflow: std.json.Value, source: WorkflowRegistrySource) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try putWorkflowCommonFields(allocator, &object, workflow, source);
    try common.putString(allocator, &object, "id", jsonEntryString(workflow, "presetId") orelse "");
    try common.putValue(allocator, &object, "childAgentLimits", try common.cloneJsonValue(allocator, workflow.object.get("childAgentLimits") orelse .null));
    try common.putValue(allocator, &object, "replay", try common.cloneJsonValue(allocator, workflow.object.get("replay") orelse .null));
    return .{ .object = object };
}

fn putWorkflowCommonFields(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    workflow: std.json.Value,
    source: WorkflowRegistrySource,
) !void {
    try common.putString(allocator, &object, "workflowId", jsonEntryString(workflow, "id") orelse "");
    try common.putString(allocator, &object, "description", jsonEntryString(workflow, "description") orelse "");
    try common.putString(allocator, &object, "executionMode", jsonEntryString(workflow, "executionMode") orelse "agent");
    try common.putString(allocator, &object, "status", jsonEntryString(workflow, "status") orelse "active");
    try common.putValue(allocator, &object, "permissions", try common.cloneJsonValue(allocator, workflow.object.get("permissions") orelse .null));
    try common.putValue(allocator, &object, "timeoutMs", try common.cloneJsonValue(allocator, workflow.object.get("timeoutMs") orelse .null));
    if (source.source_scope) |scope| try common.putString(allocator, &object, "sourceScope", scope);
    if (source.precedence_rank) |rank| try common.putInt(allocator, &object, "precedenceRank", rank);
    if (workflow.object.get("owner")) |owner| try common.putValue(allocator, &object, "owner", try common.cloneJsonValue(allocator, owner));
    if (workflow.object.get("runtime")) |runtime| try common.putValue(allocator, &object, "runtime", try common.cloneJsonValue(allocator, runtime));
}

fn appendHookChainSortEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(HookChainSortEntry),
    hooks: std.json.Value,
    source_index: usize,
    source_scope: ?[]const u8,
    precedence_rank: ?u16,
) !void {
    if (hooks != .array) return;
    for (hooks.array.items, 0..) |hook, hook_index| {
        if (hook != .object) continue;
        const event_name = hookEntryString(hook, "event") orelse "";
        try entries.append(allocator, .{
            .hook = hook,
            .event_name = event_name,
            .event_order = hookEventOrder(event_name),
            .priority = hookEntryInteger(hook, "priority", 0),
            .declaration_order = hookEntryInteger(hook, "declarationOrder", @intCast(hook_index)),
            .original_chain_order = hookEntryInteger(hook, "chainOrder", @intCast(hook_index)),
            .source_index = source_index,
            .hook_index = hook_index,
            .source_scope = source_scope,
            .precedence_rank = precedence_rank,
        });
    }
}

fn appendSortedHookChainValues(
    allocator: std.mem.Allocator,
    array: *std.json.Array,
    entries: []const HookChainSortEntry,
) !void {
    var current_event: ?[]const u8 = null;
    var event_chain_order: usize = 0;
    for (entries) |entry| {
        if (current_event == null or !std.mem.eql(u8, current_event.?, entry.event_name)) {
            current_event = entry.event_name;
            event_chain_order = 0;
        }
        try array.append(try hookChainEntryJsonValue(allocator, entry, event_chain_order));
        event_chain_order += 1;
    }
}

fn hookChainEntryJsonValue(
    allocator: std.mem.Allocator,
    entry: HookChainSortEntry,
    event_chain_order: usize,
) !std.json.Value {
    var object = (try common.cloneJsonValue(allocator, entry.hook)).object;
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    if (object.getPtr("chainOrder")) |value| {
        value.* = .{ .integer = @intCast(event_chain_order) };
    } else {
        try common.putInt(allocator, &object, "chainOrder", @intCast(event_chain_order));
    }
    if (entry.source_scope) |source_scope| {
        try common.putString(allocator, &object, "sourceScope", source_scope);
    }
    if (entry.precedence_rank) |precedence_rank| {
        try common.putInt(allocator, &object, "precedenceRank", precedence_rank);
    }
    return .{ .object = object };
}

fn hookChainEntryLessThan(_: void, lhs: HookChainSortEntry, rhs: HookChainSortEntry) bool {
    if (lhs.event_order != rhs.event_order) return lhs.event_order < rhs.event_order;
    const event_order_unknown = std.math.maxInt(usize);
    if (lhs.event_order == event_order_unknown and !std.mem.eql(u8, lhs.event_name, rhs.event_name)) {
        return std.mem.lessThan(u8, lhs.event_name, rhs.event_name);
    }
    if (lhs.priority != rhs.priority) return lhs.priority < rhs.priority;
    if (lhs.declaration_order != rhs.declaration_order) return lhs.declaration_order < rhs.declaration_order;
    if (lhs.source_index != rhs.source_index) return lhs.source_index < rhs.source_index;
    if (lhs.original_chain_order != rhs.original_chain_order) return lhs.original_chain_order < rhs.original_chain_order;
    return lhs.hook_index < rhs.hook_index;
}

fn hookEventOrder(event_name: []const u8) usize {
    for (extension_events.eventSurfaceNames(), 0..) |supported, index| {
        if (std.mem.eql(u8, event_name, supported)) return index;
    }
    return std.math.maxInt(usize);
}

fn hookEntryString(hook: std.json.Value, field: []const u8) ?[]const u8 {
    if (hook != .object) return null;
    const value = hook.object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn hookEntryInteger(hook: std.json.Value, field: []const u8, default_value: i64) i64 {
    if (hook != .object) return default_value;
    const value = hook.object.get(field) orelse return default_value;
    return switch (value) {
        .integer => |number| number,
        else => default_value,
    };
}

fn resolvedResourcesJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = seen.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (records) |record| {
        if (!record.active or record.manifest.resources != .array) continue;
        for (record.manifest.resources.array.items) |resource| {
            const kind = resourceEntryString(resource, "kind") orelse continue;
            const name = resourceEntryString(resource, "name") orelse continue;
            const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind, name });
            if (seen.contains(key)) {
                allocator.free(key);
                continue;
            }
            try seen.put(key, {});
            try array.append(try resourceResolutionJsonValue(allocator, records, kind, name));
        }
    }
    return .{ .array = array };
}

fn resourceResolutionJsonValue(
    allocator: std.mem.Allocator,
    records: []const ManifestRecord,
    kind: []const u8,
    name: []const u8,
) !std.json.Value {
    var selected_record_index: usize = 0;
    var selected_resource_index: usize = 0;
    var selected_found = false;

    for (records, 0..) |record, record_index| {
        if (!record.active or record.manifest.resources != .array) continue;
        for (record.manifest.resources.array.items, 0..) |resource, resource_index| {
            if (!resourceMatches(resource, kind, name)) continue;
            if (!selected_found or record.precedence_rank < records[selected_record_index].precedence_rank) {
                selected_record_index = record_index;
                selected_resource_index = resource_index;
                selected_found = true;
            }
        }
    }

    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putString(allocator, &object, "kind", kind);
    try common.putString(allocator, &object, "name", name);

    const selected_record = records[selected_record_index];
    const selected_resource = selected_record.manifest.resources.array.items[selected_resource_index];
    try common.putString(allocator, &object, "selectedSource", selected_record.source_scope);
    try common.putValue(allocator, &object, "selected", try resourceCandidateJsonValue(allocator, selected_record, selected_resource));

    var shadowed = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = shadowed });
    var trace = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = trace });

    for (records, 0..) |record, record_index| {
        if (!record.active or record.manifest.resources != .array) continue;
        for (record.manifest.resources.array.items, 0..) |resource, resource_index| {
            if (!resourceMatches(resource, kind, name)) continue;
            const selected = record_index == selected_record_index and resource_index == selected_resource_index;
            if (!selected) try shadowed.append(try resourceCandidateJsonValue(allocator, record, resource));
            try trace.append(try resourceTraceJsonValue(allocator, record, resource, if (selected) "selected" else "shadowed"));
        }
    }

    try common.putValue(allocator, &object, "shadowedCandidates", .{ .array = shadowed });
    try common.putValue(allocator, &object, "trace", .{ .array = trace });
    return .{ .object = object };
}

fn resourceCandidateJsonValue(allocator: std.mem.Allocator, record: ManifestRecord, resource: std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putString(allocator, &object, "kind", resourceEntryString(resource, "kind") orelse "");
    try common.putString(allocator, &object, "name", resourceEntryString(resource, "name") orelse "");
    try common.putString(allocator, &object, "path", resourceEntryString(resource, "path") orelse "");
    try common.putString(allocator, &object, "ownerId", record.manifest.id);
    try common.putString(allocator, &object, "runtime", record.manifest.runtime_kind.jsonName());
    try common.putString(allocator, &object, "sourceScope", record.source_scope);
    try common.putInt(allocator, &object, "precedenceRank", record.precedence_rank);
    try common.putString(allocator, &object, "manifestPath", record.manifest.manifest_path);
    return .{ .object = object };
}

fn resourceTraceJsonValue(allocator: std.mem.Allocator, record: ManifestRecord, resource: std.json.Value, action: []const u8) !std.json.Value {
    var object = (try resourceCandidateJsonValue(allocator, record, resource)).object;
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putString(allocator, &object, "action", action);
    try common.putString(allocator, &object, "reason", if (std.mem.eql(u8, action, "selected")) "highest-precedence-candidate" else "shadowed-by-selected-source");
    return .{ .object = object };
}

fn resourceMatches(resource: std.json.Value, kind: []const u8, name: []const u8) bool {
    const resource_kind = resourceEntryString(resource, "kind") orelse return false;
    const resource_name = resourceEntryString(resource, "name") orelse return false;
    return std.mem.eql(u8, resource_kind, kind) and std.mem.eql(u8, resource_name, name);
}

fn resourceEntryString(resource: std.json.Value, field: []const u8) ?[]const u8 {
    if (resource != .object) return null;
    const value = resource.object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

const ProviderSelection = struct {
    provider_index: usize,
    export_index: usize,
    duplicate: bool = false,
    any_same_id: bool = false,
    any_version_incompatible: bool = false,
    denied: bool = false,
    denied_candidate: bool = false,
    denied_source: ?[]const u8 = null,
};

fn resolveDependencyGraph(
    allocator: std.mem.Allocator,
    records: []ManifestRecord,
    diagnostics: *std.ArrayList(Diagnostic),
) !void {
    var pass: usize = 0;
    var changed = true;
    while (changed and pass <= records.len + 1) : (pass += 1) {
        changed = false;
        if (try validatePackageDependencies(allocator, records, diagnostics)) changed = true;
        if (try validateCapabilityImports(allocator, records, diagnostics)) changed = true;
        if (try validateAcyclicGraph(allocator, records, diagnostics)) changed = true;
    }
}

fn validatePackageDependencies(
    allocator: std.mem.Allocator,
    records: []ManifestRecord,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    var changed = false;
    for (records, 0..) |*record, record_index| {
        if (!record.active or record.manifest.dependencies != .array) continue;
        for (record.manifest.dependencies.array.items, 0..) |dependency, dep_index| {
            if (dependency != .object) continue;
            const dep_id = jsonEntryString(dependency, "id") orelse continue;
            const range = dependencyVersionRange(dependency);
            const path = try std.fmt.allocPrint(allocator, "$.dependencies[{d}]", .{dep_index});
            defer allocator.free(path);

            if (entryPolicyDenied(dependency)) {
                const source = entryPolicySource(dependency) orelse "policy";
                const message = try std.fmt.allocPrint(
                    allocator,
                    "dependency package \"{s}\" denied by {s} policy for requesting package \"{s}\"",
                    .{ dep_id, source, record.manifest.id },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.policy_denied_dependency", message, dep_id, source));
                if (try deactivateRecord(allocator, record, "policy-denied-dependency")) changed = true;
                continue;
            }

            const provider_index = findPackageProvider(records, dep_id, range, record_index);
            if (provider_index == null) {
                const has_same_id = packageIdExists(records, dep_id);
                const code = if (has_same_id) "graph.version_incompatible_dependency" else "graph.missing_dependency";
                const message = try dependencyDiagnosticMessage(allocator, dep_id, range, has_same_id, records);
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, code, message, dep_id, null));
                if (try deactivateRecord(allocator, record, if (has_same_id) "version-incompatible-dependency" else "missing-dependency")) changed = true;
            }
        }
    }
    return changed;
}

fn validateCapabilityImports(
    allocator: std.mem.Allocator,
    records: []ManifestRecord,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    var changed = false;
    for (records) |*record| {
        if (!record.active) continue;
        const imports = capabilityImports(record.manifest) orelse continue;
        for (imports.items, 0..) |import_entry, import_index| {
            if (import_entry != .object) continue;
            const capability_id = jsonEntryString(import_entry, "id") orelse continue;
            const path = try std.fmt.allocPrint(allocator, "$.capabilities.imports[{d}]", .{import_index});
            defer allocator.free(path);

            if (entryPolicyDenied(import_entry)) {
                const source = entryPolicySource(import_entry) orelse "policy";
                const message = try std.fmt.allocPrint(
                    allocator,
                    "capability import \"{s}\" denied by {s} policy for requesting package \"{s}\"",
                    .{ capability_id, source, record.manifest.id },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.policy_denied_capability", message, capability_id, source));
                if (try deactivateRecord(allocator, record, "policy-denied-capability")) changed = true;
                continue;
            }

            const selection = try selectCapabilityProvider(allocator, records, record.manifest.id, import_entry);
            if (selection.denied) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "selected capability provider for \"{s}\" denied by {s} policy for requesting package \"{s}\"",
                    .{ capability_id, selection.denied_source orelse "policy", record.manifest.id },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.policy_denied_capability", message, capability_id, selection.denied_source orelse "policy"));
                if (try deactivateRecord(allocator, record, "policy-denied-capability")) changed = true;
            } else if (selection.denied_candidate) {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "denied capability provider candidate for \"{s}\" ignored because an approved compatible provider resolved for requesting package \"{s}\"",
                    .{ capability_id, record.manifest.id },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.policy_denied_capability_candidate", message, capability_id, selection.denied_source orelse "policy"));
            } else if (selection.duplicate) {
                const message = try duplicateProviderMessage(allocator, records, import_entry);
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.duplicate_capability_provider", message, capability_id, null));
                if (try deactivateRecord(allocator, record, "duplicate-capability-provider")) changed = true;
            } else if (selection.any_same_id and selection.provider_index == std.math.maxInt(usize)) {
                const message = try capabilityVersionDiagnosticMessage(allocator, records, import_entry);
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.version_incompatible_capability", message, capability_id, null));
                if (try deactivateRecord(allocator, record, "version-incompatible-capability")) changed = true;
            } else if (selection.provider_index == std.math.maxInt(usize)) {
                const range = importVersionRange(import_entry) orelse "*";
                const message = try std.fmt.allocPrint(
                    allocator,
                    "missing capability import id=\"{s}\" kind=\"{s}\" range=\"{s}\" requested by package \"{s}\"",
                    .{ capability_id, jsonEntryString(import_entry, "kind") orelse "*", range, record.manifest.id },
                );
                defer allocator.free(message);
                try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, path, "graph.missing_capability_import", message, capability_id, null));
                if (try deactivateRecord(allocator, record, "missing-capability-import")) changed = true;
            }
        }
    }
    return changed;
}

fn validateAcyclicGraph(
    allocator: std.mem.Allocator,
    records: []ManifestRecord,
    diagnostics: *std.ArrayList(Diagnostic),
) !bool {
    var active_count: usize = 0;
    for (records) |record| {
        if (record.active) active_count += 1;
    }
    if (active_count == 0) return false;

    var indegree = try allocator.alloc(usize, records.len);
    defer allocator.free(indegree);
    @memset(indegree, 0);
    var removed = try allocator.alloc(bool, records.len);
    defer allocator.free(removed);
    @memset(removed, false);

    for (records, 0..) |record, consumer_index| {
        if (!record.active) continue;
        for (records, 0..) |provider, provider_index| {
            if (!provider.active) continue;
            if (try hasGraphEdge(allocator, records, provider_index, consumer_index)) indegree[consumer_index] += 1;
        }
    }

    var processed: usize = 0;
    var progress = true;
    while (progress) {
        progress = false;
        for (records, 0..) |record, index| {
            if (!record.active or removed[index] or indegree[index] != 0) continue;
            removed[index] = true;
            processed += 1;
            progress = true;
            for (records, 0..) |consumer, consumer_index| {
                if (!consumer.active or removed[consumer_index]) continue;
                if (try hasGraphEdge(allocator, records, index, consumer_index)) indegree[consumer_index] -= 1;
            }
        }
    }
    if (processed == active_count) return false;

    const path = try cyclePathString(allocator, records, removed);
    defer allocator.free(path);
    var changed = false;
    for (records, 0..) |*record, index| {
        if (!record.active or removed[index]) continue;
        const message = try std.fmt.allocPrint(allocator, "cyclic dependency graph rejected before activation; cycle path: {s}", .{path});
        defer allocator.free(message);
        try diagnostics.append(allocator, try makeGraphDiagnostic(allocator, record.*, "$.dependencies", "graph.cyclic_dependency", message, null, null));
        if (try deactivateRecord(allocator, record, "cyclic-dependency")) changed = true;
    }
    return changed;
}

fn deactivateRecord(allocator: std.mem.Allocator, record: *ManifestRecord, reason: []const u8) !bool {
    if (!record.active) return false;
    record.active = false;
    if (record.inactive_reason) |old| allocator.free(old);
    record.inactive_reason = try allocator.dupe(u8, reason);
    return true;
}

fn findPackageProvider(records: []const ManifestRecord, id: []const u8, range: ?[]const u8, consumer_index: usize) ?usize {
    for (records, 0..) |record, index| {
        if (!record.active or index == consumer_index) continue;
        if (!std.mem.eql(u8, record.manifest.id, id)) continue;
        if (versionSatisfies(record.manifest.version, range)) return index;
    }
    return null;
}

fn packageIdExists(records: []const ManifestRecord, id: []const u8) bool {
    for (records) |record| {
        if (std.mem.eql(u8, record.manifest.id, id)) return true;
    }
    return false;
}

fn dependencyDiagnosticMessage(allocator: std.mem.Allocator, id: []const u8, range: ?[]const u8, version_problem: bool, records: []const ManifestRecord) ![]u8 {
    if (!version_problem) {
        return std.fmt.allocPrint(allocator, "missing package dependency id=\"{s}\" range=\"{s}\"", .{ id, range orelse "*" });
    }
    var versions = std.ArrayList(u8).empty;
    defer versions.deinit(allocator);
    for (records) |record| {
        if (!std.mem.eql(u8, record.manifest.id, id)) continue;
        if (versions.items.len > 0) try versions.appendSlice(allocator, ",");
        try versions.appendSlice(allocator, record.manifest.version);
    }
    return std.fmt.allocPrint(allocator, "version-incompatible package dependency id=\"{s}\" requested=\"{s}\" available=\"{s}\"", .{ id, range orelse "*", versions.items });
}

fn selectCapabilityProvider(
    allocator: std.mem.Allocator,
    records: []const ManifestRecord,
    importer_id: []const u8,
    import_entry: std.json.Value,
) !ProviderSelection {
    _ = allocator;
    var result = ProviderSelection{ .provider_index = std.math.maxInt(usize), .export_index = std.math.maxInt(usize) };
    const capability_id = jsonEntryString(import_entry, "id") orelse return result;
    const capability_kind = jsonEntryString(import_entry, "kind");
    const range = importVersionRange(import_entry);
    const explicit_provider = explicitProvider(import_entry);
    var best_rank: ?u16 = null;

    for (records, 0..) |record, record_index| {
        if (!record.active) continue;
        if (std.mem.eql(u8, record.manifest.id, importer_id)) continue;
        if (explicit_provider) |provider| {
            if (!std.mem.eql(u8, record.manifest.id, provider)) continue;
        }
        const exports = capabilityExports(record.manifest) orelse continue;
        for (exports.items, 0..) |export_entry, export_index| {
            if (!capabilityExportMatchesIdentity(export_entry, capability_id, capability_kind)) continue;
            result.any_same_id = true;
            const export_version = exportVersion(record, export_entry);
            if (!versionSatisfies(export_version, range)) {
                result.any_version_incompatible = true;
                continue;
            }
            if (entryPolicyDenied(export_entry)) {
                result.denied_candidate = true;
                result.denied_source = entryPolicySource(export_entry);
                if (explicit_provider != null) result.denied = true;
                continue;
            }
            if (best_rank == null or record.precedence_rank < best_rank.?) {
                best_rank = record.precedence_rank;
                result.provider_index = record_index;
                result.export_index = export_index;
                result.duplicate = false;
            } else if (record.precedence_rank == best_rank.?) {
                result.duplicate = true;
            }
        }
    }
    if (result.provider_index == std.math.maxInt(usize) and result.denied_candidate) result.denied = true;
    return result;
}

fn capabilityExportMatchesIdentity(export_entry: std.json.Value, id: []const u8, kind: ?[]const u8) bool {
    if (export_entry != .object) return false;
    const export_id = jsonEntryString(export_entry, "id") orelse return false;
    if (!std.mem.eql(u8, export_id, id)) return false;
    if (kind) |requested_kind| {
        const export_kind = jsonEntryString(export_entry, "kind") orelse return false;
        if (!std.mem.eql(u8, export_kind, requested_kind)) return false;
    }
    return true;
}

fn duplicateProviderMessage(allocator: std.mem.Allocator, records: []const ManifestRecord, import_entry: std.json.Value) ![]u8 {
    const capability_id = jsonEntryString(import_entry, "id") orelse "";
    var providers = std.ArrayList(u8).empty;
    defer providers.deinit(allocator);
    const range = importVersionRange(import_entry);
    const kind = jsonEntryString(import_entry, "kind");
    var best_rank: ?u16 = null;
    for (records) |record| {
        if (!record.active) continue;
        const exports = capabilityExports(record.manifest) orelse continue;
        for (exports.items) |export_entry| {
            if (!capabilityExportMatchesIdentity(export_entry, capability_id, kind)) continue;
            if (!versionSatisfies(exportVersion(record, export_entry), range)) continue;
            if (entryPolicyDenied(export_entry)) continue;
            if (best_rank == null or record.precedence_rank < best_rank.?) {
                providers.clearRetainingCapacity();
                best_rank = record.precedence_rank;
            }
            if (record.precedence_rank == best_rank.?) {
                if (providers.items.len > 0) try providers.appendSlice(allocator, ",");
                try providers.appendSlice(allocator, record.manifest.id);
            }
        }
    }
    return std.fmt.allocPrint(allocator, "duplicate capability providers for id=\"{s}\" candidates=\"{s}\"", .{ capability_id, providers.items });
}

fn capabilityVersionDiagnosticMessage(allocator: std.mem.Allocator, records: []const ManifestRecord, import_entry: std.json.Value) ![]u8 {
    const capability_id = jsonEntryString(import_entry, "id") orelse "";
    var versions = std.ArrayList(u8).empty;
    defer versions.deinit(allocator);
    const kind = jsonEntryString(import_entry, "kind");
    for (records) |record| {
        const exports = capabilityExports(record.manifest) orelse continue;
        for (exports.items) |export_entry| {
            if (!capabilityExportMatchesIdentity(export_entry, capability_id, kind)) continue;
            if (versions.items.len > 0) try versions.appendSlice(allocator, ",");
            try versions.appendSlice(allocator, record.manifest.id);
            try versions.appendSlice(allocator, "@");
            try versions.appendSlice(allocator, exportVersion(record, export_entry));
        }
    }
    return std.fmt.allocPrint(allocator, "version-incompatible capability import id=\"{s}\" requested=\"{s}\" available=\"{s}\"", .{ capability_id, importVersionRange(import_entry) orelse "*", versions.items });
}

fn hasGraphEdge(allocator: std.mem.Allocator, records: []const ManifestRecord, provider_index: usize, consumer_index: usize) !bool {
    if (provider_index == consumer_index) return false;
    const consumer = records[consumer_index];
    const provider = records[provider_index];
    if (!consumer.active or !provider.active) return false;
    if (consumer.manifest.dependencies == .array) {
        for (consumer.manifest.dependencies.array.items) |dependency| {
            if (dependency != .object or entryPolicyDenied(dependency)) continue;
            const dep_id = jsonEntryString(dependency, "id") orelse continue;
            if (!std.mem.eql(u8, dep_id, provider.manifest.id)) continue;
            if (versionSatisfies(provider.manifest.version, dependencyVersionRange(dependency))) return true;
        }
    }
    const imports = capabilityImports(consumer.manifest) orelse return false;
    for (imports.items) |import_entry| {
        if (import_entry != .object or entryPolicyDenied(import_entry)) continue;
        const selection = try selectCapabilityProvider(allocator, records, consumer.manifest.id, import_entry);
        if (!selection.duplicate and selection.provider_index == provider_index) return true;
    }
    return false;
}

fn cyclePathString(allocator: std.mem.Allocator, records: []const ManifestRecord, removed: []const bool) ![]u8 {
    var path = std.ArrayList(u8).empty;
    defer path.deinit(allocator);
    for (records, 0..) |record, index| {
        if (!record.active or removed[index]) continue;
        if (path.items.len > 0) try path.appendSlice(allocator, " -> ");
        try path.appendSlice(allocator, record.manifest.id);
    }
    if (path.items.len > 0) try path.appendSlice(allocator, " -> ");
    for (records, 0..) |record, index| {
        if (!record.active or removed[index]) continue;
        try path.appendSlice(allocator, record.manifest.id);
        break;
    }
    return path.toOwnedSlice(allocator);
}

fn compositionJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord, diagnostics: []const Diagnostic) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });
    try common.putValue(allocator, &object, "activeNodes", try graphNodesJsonValue(allocator, records, true));
    try common.putValue(allocator, &object, "inactiveNodes", try graphNodesJsonValue(allocator, records, false));
    try common.putValue(allocator, &object, "edges", try graphEdgesJsonValue(allocator, records));
    try common.putValue(allocator, &object, "selectedProviders", try selectedProvidersJsonValue(allocator, records));
    try common.putValue(allocator, &object, "unresolvedImports", try unresolvedImportsJsonValue(allocator, records));
    try common.putValue(allocator, &object, "activationOrder", try activationOrderJsonValue(allocator, records));

    var diagnostic_array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = diagnostic_array });
    for (diagnostics) |diagnostic| {
        try diagnostic_array.append(try diagnosticJsonValue(allocator, diagnostic));
    }
    try common.putValue(allocator, &object, "diagnostics", .{ .array = diagnostic_array });
    return .{ .object = object };
}

fn graphNodesJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord, active: bool) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    for (records) |record| {
        if (record.active != active) continue;
        var node = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = node });
        try common.putString(allocator, &node, "packageId", record.manifest.id);
        try common.putString(allocator, &node, "version", record.manifest.version);
        try common.putString(allocator, &node, "runtime", record.manifest.runtime_kind.jsonName());
        try common.putString(allocator, &node, "manifestPath", record.manifest.manifest_path);
        try common.putString(allocator, &node, "sourceScope", record.source_scope);
        try common.putInt(allocator, &node, "precedenceRank", record.precedence_rank);
        try common.putBool(allocator, &node, "active", record.active);
        try common.putValue(allocator, &node, "inactiveReason", if (record.inactive_reason) |reason| .{ .string = try allocator.dupe(u8, reason) } else .null);
        try array.append(.{ .object = node });
    }
    return .{ .array = array };
}

fn graphEdgesJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    for (records, 0..) |consumer, consumer_index| {
        if (!consumer.active) continue;
        if (consumer.manifest.dependencies == .array) {
            for (consumer.manifest.dependencies.array.items) |dependency| {
                if (dependency != .object or entryPolicyDenied(dependency)) continue;
                const dep_id = jsonEntryString(dependency, "id") orelse continue;
                const provider_index = findPackageProvider(records, dep_id, dependencyVersionRange(dependency), consumer_index) orelse continue;
                try array.append(try packageEdgeJsonValue(allocator, records[provider_index], consumer, dependency));
            }
        }
        const imports = capabilityImports(consumer.manifest) orelse continue;
        for (imports.items) |import_entry| {
            if (import_entry != .object or entryPolicyDenied(import_entry)) continue;
            const selection = try selectCapabilityProvider(allocator, records, consumer.manifest.id, import_entry);
            if (selection.provider_index == std.math.maxInt(usize) or selection.duplicate) continue;
            const provider = records[selection.provider_index];
            const export_entry = capabilityExports(provider.manifest).?.items[selection.export_index];
            try array.append(try capabilityEdgeJsonValue(allocator, provider, consumer, import_entry, export_entry));
        }
    }
    return .{ .array = array };
}

fn packageEdgeJsonValue(allocator: std.mem.Allocator, provider: ManifestRecord, consumer: ManifestRecord, dependency: std.json.Value) !std.json.Value {
    var edge = try baseEdgeJsonValue(allocator, provider, consumer, "package_dependency");
    errdefer common.deinitJsonValue(allocator, .{ .object = edge });
    try common.putString(allocator, &edge, "dependencyId", jsonEntryString(dependency, "id") orelse "");
    try common.putValue(allocator, &edge, "versionRange", try optionalJsonString(allocator, dependencyVersionRange(dependency)));
    try common.putString(allocator, &edge, "providerVersion", provider.manifest.version);
    return .{ .object = edge };
}

fn capabilityEdgeJsonValue(allocator: std.mem.Allocator, provider: ManifestRecord, consumer: ManifestRecord, import_entry: std.json.Value, export_entry: std.json.Value) !std.json.Value {
    var edge = try baseEdgeJsonValue(allocator, provider, consumer, "capability_import");
    errdefer common.deinitJsonValue(allocator, .{ .object = edge });
    try common.putString(allocator, &edge, "capabilityId", jsonEntryString(import_entry, "id") orelse "");
    try common.putValue(allocator, &edge, "capabilityKind", try optionalJsonString(allocator, jsonEntryString(import_entry, "kind") orelse jsonEntryString(export_entry, "kind")));
    try common.putValue(allocator, &edge, "versionRange", try optionalJsonString(allocator, importVersionRange(import_entry)));
    try common.putString(allocator, &edge, "providerCapabilityVersion", exportVersion(provider, export_entry));
    return .{ .object = edge };
}

fn baseEdgeJsonValue(allocator: std.mem.Allocator, provider: ManifestRecord, consumer: ManifestRecord, type_name: []const u8) !std.json.ObjectMap {
    var edge = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = edge });
    try common.putString(allocator, &edge, "type", type_name);
    try common.putString(allocator, &edge, "fromPackageId", provider.manifest.id);
    try common.putString(allocator, &edge, "toPackageId", consumer.manifest.id);
    try common.putString(allocator, &edge, "providerManifestPath", provider.manifest.manifest_path);
    try common.putString(allocator, &edge, "consumerManifestPath", consumer.manifest.manifest_path);
    return edge;
}

fn selectedProvidersJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    for (records) |consumer| {
        if (!consumer.active) continue;
        const imports = capabilityImports(consumer.manifest) orelse continue;
        for (imports.items) |import_entry| {
            if (import_entry != .object or entryPolicyDenied(import_entry)) continue;
            const selection = try selectCapabilityProvider(allocator, records, consumer.manifest.id, import_entry);
            if (selection.provider_index == std.math.maxInt(usize) or selection.duplicate) continue;
            const provider = records[selection.provider_index];
            const export_entry = capabilityExports(provider.manifest).?.items[selection.export_index];
            var selected = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer common.deinitJsonValue(allocator, .{ .object = selected });
            try common.putString(allocator, &selected, "consumerPackageId", consumer.manifest.id);
            try common.putString(allocator, &selected, "providerPackageId", provider.manifest.id);
            try common.putString(allocator, &selected, "providerPackageVersion", provider.manifest.version);
            try common.putString(allocator, &selected, "capabilityId", jsonEntryString(import_entry, "id") orelse "");
            try common.putValue(allocator, &selected, "capabilityKind", try optionalJsonString(allocator, jsonEntryString(import_entry, "kind") orelse jsonEntryString(export_entry, "kind")));
            try common.putString(allocator, &selected, "providerCapabilityVersion", exportVersion(provider, export_entry));
            try common.putString(allocator, &selected, "providerManifestPath", provider.manifest.manifest_path);
            try array.append(.{ .object = selected });
        }
    }
    return .{ .array = array };
}

fn unresolvedImportsJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    for (records) |record| {
        const imports = capabilityImports(record.manifest) orelse continue;
        for (imports.items) |import_entry| {
            if (import_entry != .object) continue;
            var unresolved = false;
            if (!record.active) {
                unresolved = true;
            } else {
                const selection = try selectCapabilityProvider(allocator, records, record.manifest.id, import_entry);
                unresolved = selection.provider_index == std.math.maxInt(usize) or selection.duplicate or selection.denied;
            }
            if (!unresolved) continue;
            var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer common.deinitJsonValue(allocator, .{ .object = entry });
            try common.putString(allocator, &entry, "packageId", record.manifest.id);
            try common.putString(allocator, &entry, "capabilityId", jsonEntryString(import_entry, "id") orelse "");
            try common.putValue(allocator, &entry, "kind", try optionalJsonString(allocator, jsonEntryString(import_entry, "kind")));
            try common.putValue(allocator, &entry, "versionRange", try optionalJsonString(allocator, importVersionRange(import_entry)));
            try common.putString(allocator, &entry, "manifestPath", record.manifest.manifest_path);
            try common.putValue(allocator, &entry, "reason", if (record.inactive_reason) |reason| .{ .string = try allocator.dupe(u8, reason) } else .{ .string = try allocator.dupe(u8, "unresolved") });
            try array.append(.{ .object = entry });
        }
    }
    return .{ .array = array };
}

pub fn activationOrderIndices(allocator: std.mem.Allocator, records: []const ManifestRecord) ![]usize {
    var indices = std.ArrayList(usize).empty;
    errdefer indices.deinit(allocator);
    var indegree = try allocator.alloc(usize, records.len);
    defer allocator.free(indegree);
    @memset(indegree, 0);
    var emitted = try allocator.alloc(bool, records.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    for (records, 0..) |consumer, consumer_index| {
        if (!consumer.active) continue;
        for (records, 0..) |provider, provider_index| {
            if (!provider.active) continue;
            if (try hasGraphEdge(allocator, records, provider_index, consumer_index)) indegree[consumer_index] += 1;
        }
    }

    var progress = true;
    while (progress) {
        progress = false;
        for (records, 0..) |record, index| {
            if (!record.active or emitted[index] or indegree[index] != 0) continue;
            emitted[index] = true;
            progress = true;
            try indices.append(allocator, index);
            for (records, 0..) |consumer, consumer_index| {
                if (!consumer.active or emitted[consumer_index]) continue;
                if (try hasGraphEdge(allocator, records, index, consumer_index)) indegree[consumer_index] -= 1;
            }
        }
    }
    return indices.toOwnedSlice(allocator);
}

fn activationOrderJsonValue(allocator: std.mem.Allocator, records: []const ManifestRecord) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = array });
    const indices = try activationOrderIndices(allocator, records);
    defer allocator.free(indices);
    for (indices) |index| {
        try array.append(.{ .string = try allocator.dupe(u8, records[index].manifest.id) });
    }
    return .{ .array = array };
}

fn capabilityExports(manifest: NormalizedManifest) ?std.json.Array {
    if (manifest.capabilities != .object) return null;
    const value = manifest.capabilities.object.get("exports") orelse return null;
    if (value != .array) return null;
    return value.array;
}

fn capabilityImports(manifest: NormalizedManifest) ?std.json.Array {
    if (manifest.capabilities != .object) return null;
    const value = manifest.capabilities.object.get("imports") orelse return null;
    if (value != .array) return null;
    return value.array;
}

fn dependencyVersionRange(dependency: std.json.Value) ?[]const u8 {
    return jsonEntryString(dependency, "version") orelse jsonEntryString(dependency, "versionRange") orelse jsonEntryString(dependency, "range");
}

fn importVersionRange(import_entry: std.json.Value) ?[]const u8 {
    return jsonEntryString(import_entry, "version") orelse jsonEntryString(import_entry, "versionRange") orelse jsonEntryString(import_entry, "range");
}

fn explicitProvider(import_entry: std.json.Value) ?[]const u8 {
    return jsonEntryString(import_entry, "provider") orelse jsonEntryString(import_entry, "from") orelse jsonEntryString(import_entry, "package");
}

fn exportVersion(record: ManifestRecord, export_entry: std.json.Value) []const u8 {
    return jsonEntryString(export_entry, "version") orelse record.manifest.version;
}

fn jsonEntryString(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(field) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn jsonEntryBool(value: std.json.Value, field: []const u8) ?bool {
    if (value != .object) return null;
    const field_value = value.object.get(field) orelse return null;
    if (field_value != .bool) return null;
    return field_value.bool;
}

fn entryPolicyDenied(value: std.json.Value) bool {
    if (jsonEntryBool(value, "denied") orelse false) return true;
    if (jsonEntryBool(value, "policyDenied") orelse false) return true;
    if (value != .object) return false;
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

fn entryPolicySource(value: std.json.Value) ?[]const u8 {
    if (jsonEntryString(value, "policySource")) |source| return source;
    if (value != .object) return null;
    const policy = value.object.get("policy") orelse return null;
    if (policy != .object) return null;
    const source = policy.object.get("source") orelse return null;
    if (source != .string) return null;
    return source.string;
}

fn optionalJsonString(allocator: std.mem.Allocator, maybe_value: ?[]const u8) !std.json.Value {
    if (maybe_value) |value| return .{ .string = try allocator.dupe(u8, value) };
    return .null;
}

const Semver = struct {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: ?[]const u8 = null,
};

fn versionSatisfies(version_text: []const u8, maybe_range: ?[]const u8) bool {
    const range_text = maybe_range orelse return true;
    if (range_text.len == 0 or std.mem.eql(u8, range_text, "*")) return true;
    const version = parseSemver(version_text) orelse return std.mem.eql(u8, version_text, range_text);
    if (std.mem.startsWith(u8, range_text, "^")) {
        const lower = parseSemver(range_text[1..]) orelse return false;
        if (version.prerelease != null and lower.prerelease == null) return false;
        const upper = caretUpperBound(lower);
        return compareSemver(version, lower) >= 0 and compareSemver(version, upper) < 0;
    }
    if (std.mem.startsWith(u8, range_text, ">=")) {
        const lower = parseSemver(range_text[2..]) orelse return false;
        return compareSemver(version, lower) >= 0;
    }
    const exact = parseSemver(range_text) orelse return std.mem.eql(u8, version_text, range_text);
    return compareSemver(version, exact) == 0;
}

fn parseSemver(text: []const u8) ?Semver {
    var core = text;
    var prerelease: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
        core = text[0..dash];
        prerelease = text[dash + 1 ..];
    }
    var parts = std.mem.splitScalar(u8, core, '.');
    const major_text = parts.next() orelse return null;
    const minor_text = parts.next() orelse "0";
    const patch_text = parts.next() orelse "0";
    if (parts.next() != null) return null;
    return .{
        .major = std.fmt.parseInt(u64, major_text, 10) catch return null,
        .minor = std.fmt.parseInt(u64, minor_text, 10) catch return null,
        .patch = std.fmt.parseInt(u64, patch_text, 10) catch return null,
        .prerelease = prerelease,
    };
}

fn compareSemver(lhs: Semver, rhs: Semver) i8 {
    if (lhs.major != rhs.major) return if (lhs.major < rhs.major) -1 else 1;
    if (lhs.minor != rhs.minor) return if (lhs.minor < rhs.minor) -1 else 1;
    if (lhs.patch != rhs.patch) return if (lhs.patch < rhs.patch) -1 else 1;
    if (lhs.prerelease == null and rhs.prerelease != null) return 1;
    if (lhs.prerelease != null and rhs.prerelease == null) return -1;
    if (lhs.prerelease == null and rhs.prerelease == null) return 0;
    if (std.mem.eql(u8, lhs.prerelease.?, rhs.prerelease.?)) return 0;
    return if (std.mem.lessThan(u8, lhs.prerelease.?, rhs.prerelease.?)) -1 else 1;
}

fn caretUpperBound(lower: Semver) Semver {
    if (lower.major > 0) {
        return .{ .major = lower.major + 1, .minor = 0, .patch = 0 };
    }
    if (lower.minor > 0) {
        return .{ .major = 0, .minor = lower.minor + 1, .patch = 0 };
    }
    return .{ .major = 0, .minor = 0, .patch = lower.patch + 1 };
}

fn requiredString(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field: []const u8,
) !?ValidationResult {
    const value = object.get(field) orelse {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, manifest_path, path, "manifest.missing_required_field", "missing required field");
    };
    if (value != .string or value.string.len == 0) {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, manifest_path, path, "manifest.expected_string", "expected non-empty string");
    }
    return null;
}

fn requiredObject(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field: []const u8,
) !?ValidationResult {
    const value = object.get(field) orelse {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, manifest_path, path, "manifest.missing_required_field", "missing required field");
    };
    if (value != .object) {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, manifest_path, path, "manifest.expected_object", "expected object");
    }
    return null;
}

fn requiredAny(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field: []const u8,
) !?ValidationResult {
    _ = object.get(field) orelse {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, manifest_path, path, "manifest.missing_required_field", "missing required field");
    };
    return null;
}

fn stringValue(object: std.json.ObjectMap, field: []const u8) []const u8 {
    return object.get(field).?.string;
}

fn objectValue(object: std.json.ObjectMap, field: []const u8) std.json.ObjectMap {
    return object.get(field).?.object;
}

fn joinJsonPath(allocator: std.mem.Allocator, parent_path: []const u8, field: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
}

pub const testing = struct {
    pub const version_satisfies = versionSatisfies;
};

test {
    _ = @import("extension_manifest/tests.zig");
}
