pub const std = @import("std");
pub const ai = @import("ai");
pub const agent = @import("agent");
const cli_mod = @import("cli");
pub const cli = cli_mod.args;
pub const bootstrap = cli_mod.bootstrap;
pub const input_prep = cli_mod.input_prep;
pub const runtime_prep = cli_mod.runtime_prep;
pub const cli_test = cli_mod.test_harness;
pub const main = @import("../main.zig");
pub const coding_agent = @import("coding_agent");
pub const config_mod = coding_agent.config_impl;
pub const resources_mod = coding_agent.resources;
pub const tools_common = coding_agent.tools.common;
pub const extension_runtime = coding_agent.extension_runtime;
pub const tool_adapters = coding_agent.tool_adapters;
pub const json_event_wire = coding_agent.json_event_wire;
pub const json_format = coding_agent.json_format;

pub const writeJsonStringValue = json_format.writeJsonString;
pub const CliStdin = main.testing.CliStdin;
pub const VERSION = main.testing.version;
pub const effectiveToolSelection = bootstrap.effectiveToolSelection;
pub const prepareCliRuntime = runtime_prep.prepareCliRuntime;
pub const prepareEffectiveEnvMap = main.testing.prepareEffectiveEnvMap;
pub const runCli = main.runCli;
pub const runCliWithInput = main.testing.runCliWithInput;
pub const startupNetworkOperationsEnabled = bootstrap.startupNetworkOperationsEnabled;

pub const LifecyclePackageFixture = struct {
    root: []const u8,
    source: []const u8,
    script_rel: []const u8,
    script_abs: []const u8,
    manifest: []const u8,
    initial_script: []const u8,
    manifest_id: []const u8,
    runtime_kind: coding_agent.extension_manifest.RuntimeKind,
    tool_name: ?[]const u8 = null,
    hook_event: ?[]const u8 = null,
    workflow_id: ?[]const u8 = null,
};

pub fn readSettingsPackageSources(allocator: std.mem.Allocator, settings_text: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, settings_text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const packages = parsed.value.object.get("packages") orelse return error.ExpectedSettingsPackages;
    try std.testing.expect(packages == .array);

    var sources = std.ArrayList([]u8).empty;
    errdefer freeOwnedStringSlice(allocator, sources.items);
    for (packages.array.items) |entry| {
        switch (entry) {
            .string => |source| try sources.append(allocator, try allocator.dupe(u8, source)),
            .object => |object| {
                const source_value = object.get("source") orelse return error.ExpectedSettingsPackageSource;
                try std.testing.expect(source_value == .string);
                try sources.append(allocator, try allocator.dupe(u8, source_value.string));
            },
            else => return error.ExpectedSettingsPackageSource,
        }
    }
    return try sources.toOwnedSlice(allocator);
}

pub fn freeOwnedStringSlice(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

pub fn expectInstalledPackageSources(actual: []const []u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |actual_source, expected_source| {
        try std.testing.expectEqualStrings(expected_source, actual_source);
    }
}

pub fn settingsWithInstalledPackagePolicies(
    allocator: std.mem.Allocator,
    installed_settings_text: []const u8,
    policy_keys: [4][]const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, installed_settings_text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    var root = try tools_common.cloneJsonValue(allocator, parsed.value);
    defer tools_common.deinitJsonValue(allocator, root);
    try std.testing.expect(root == .object);

    var policies = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = policies });
    for (policy_keys, 0..) |policy_key, index| {
        _ = index;
        var policy = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer tools_common.deinitJsonValue(allocator, .{ .object = policy });
        try policy.put(allocator, try allocator.dupe(u8, "approved"), .{ .bool = true });
        var grants = std.json.Array.init(allocator);
        errdefer tools_common.deinitJsonValue(allocator, .{ .array = grants });
        try grants.append(.{ .string = try allocator.dupe(u8, "tool.use") });
        try policy.put(allocator, try allocator.dupe(u8, "approvedGrants"), .{ .array = grants });
        var limits = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer tools_common.deinitJsonValue(allocator, .{ .object = limits });
        try limits.put(allocator, try allocator.dupe(u8, "timeoutMs"), .{ .integer = 500 });
        try policy.put(allocator, try allocator.dupe(u8, "resourceLimits"), .{ .object = limits });
        try policies.put(allocator, try allocator.dupe(u8, policy_key), .{ .object = policy });
    }
    if (root.object.getPtr("extensionPolicies")) |existing| {
        tools_common.deinitJsonValue(allocator, existing.*);
        existing.* = .{ .object = policies };
    } else {
        try root.object.put(allocator, try allocator.dupe(u8, "extensionPolicies"), .{ .object = policies });
    }
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}

pub fn temporaryTypeScriptPolicyKey(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const source_info = resources_mod.SourceInfo{
        .path = @constCast(path),
        .source = @constCast("local"),
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = @constCast(std.fs.path.dirname(path) orelse "."),
    };
    return extension_runtime.typeScriptPolicyLookupKey(allocator, .{
        .configured_path = path,
        .resolved_path = path,
        .source_info = source_info,
    });
}

pub fn settingsWithTemporaryExtensionPolicies(
    allocator: std.mem.Allocator,
    policy_keys: []const []const u8,
    grants: []const []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("{\n  \"extensionPolicies\": {\n");
    for (policy_keys, 0..) |policy_key, index| {
        if (index > 0) try writer.writer.writeAll(",\n");
        try writer.writer.writeAll("    ");
        try writeJsonStringValue(allocator, &writer.writer, policy_key);
        try writer.writer.writeAll(": { \"approved\": true, \"approvedGrants\": [");
        for (grants, 0..) |grant, grant_index| {
            if (grant_index > 0) try writer.writer.writeAll(", ");
            try writeJsonStringValue(allocator, &writer.writer, grant);
        }
        try writer.writer.writeAll("] }");
    }
    try writer.writer.writeAll("\n  }\n}\n");
    return try allocator.dupe(u8, writer.writer.buffered());
}

pub fn expectPackageConfigSources(packages: ?[]const resources_mod.PackageSourceConfig, installed_sources: []const []u8) !void {
    const package_config = packages orelse return error.ExpectedSettingsPackages;
    try std.testing.expectEqual(installed_sources.len, package_config.len);
    for (package_config, installed_sources) |package_source, installed_source| {
        try std.testing.expectEqualStrings(installed_source, package_source.source);
    }
}

pub fn expectLoadedExtensionsMatchInstalledPackages(
    allocator: std.mem.Allocator,
    extensions: []const resources_mod.LoadedExtension,
    fixtures: []const LifecyclePackageFixture,
    installed_sources: []const []u8,
) !void {
    try std.testing.expectEqual(fixtures.len, installed_sources.len);
    for (fixtures, installed_sources) |fixture, installed_source| {
        const extension = loadedExtensionForSource(extensions, installed_source) orelse return error.ExpectedLoadedPackageExtension;
        try std.testing.expectEqualStrings(fixture.script_abs, extension.path);
        try std.testing.expectEqualStrings("package", @tagName(extension.source_info.origin));
        try std.testing.expectEqualStrings("project", @tagName(extension.source_info.scope));
        try std.testing.expectEqualStrings(installed_source, extension.source_info.source);
        try std.testing.expect(extension.source_info.base_dir != null);
        try std.testing.expectEqualStrings(fixture.root, extension.source_info.base_dir.?);
        try expectLoadedExtensionManifestMetadata(allocator, extension.*, fixture);
    }
}

pub fn loadedExtensionForSource(
    extensions: []const resources_mod.LoadedExtension,
    source: []const u8,
) ?*const resources_mod.LoadedExtension {
    for (extensions) |*extension| {
        if (std.mem.eql(u8, extension.source_info.source, source)) return extension;
    }
    return null;
}

pub fn expectLoadedExtensionManifestMetadata(
    allocator: std.mem.Allocator,
    extension: resources_mod.LoadedExtension,
    fixture: LifecyclePackageFixture,
) !void {
    const package_root = extension.source_info.base_dir orelse return error.ExpectedLoadedPackageExtension;
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, "pi-extension.json" });
    defer allocator.free(manifest_path);
    const manifest_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(manifest_text);
    var sources = [_]coding_agent.extension_manifest.ManifestSource{.{
        .package_root = package_root,
        .manifest_path = manifest_path,
        .manifest_text = manifest_text,
        .source_scope = "project-installed-settings",
        .precedence_rank = 0,
    }};
    var manifest_set = try coding_agent.extension_manifest.resolveManifestSources(allocator, sources[0..]);
    defer manifest_set.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest_set.records.len);
    try std.testing.expectEqualStrings(fixture.manifest_id, manifest_set.records[0].manifest.id);
    try std.testing.expectEqual(fixture.runtime_kind, manifest_set.records[0].manifest.runtime_kind);
}

pub fn expectRegistrySnapshotsMatchLoadedPackages(
    allocator: std.mem.Allocator,
    hosts: []const coding_agent.extension_runtime.RuntimeAdapter,
    extensions: []const resources_mod.LoadedExtension,
    fixtures: []const LifecyclePackageFixture,
    installed_sources: []const []u8,
) !void {
    for (fixtures, installed_sources) |fixture, installed_source| {
        const extension = loadedExtensionForSource(extensions, installed_source) orelse return error.ExpectedLoadedPackageExtension;
        var found = false;
        for (hosts) |host| {
            const snapshot = try host.snapshotRegistryJson(allocator);
            defer allocator.free(snapshot);
            if (std.mem.indexOf(u8, snapshot, extension.path) == null) continue;
            if (fixture.tool_name) |tool_name| try std.testing.expect(std.mem.indexOf(u8, snapshot, tool_name) != null);
            if (fixture.hook_event) |hook_event| try std.testing.expect(std.mem.indexOf(u8, snapshot, hook_event) != null);
            if (fixture.workflow_id) |workflow_id| try std.testing.expect(std.mem.indexOf(u8, snapshot, workflow_id) != null);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

pub fn expectInstallLockSettingsMetadataMatchesLoadedRegistry(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    extensions: []const resources_mod.LoadedExtension,
    startup_manifest_registry_snapshot: []const u8,
    fixtures: []const LifecyclePackageFixture,
    installed_sources: []const []u8,
) !void {
    const settings_path = try std.fs.path.join(allocator, &.{ project_dir, ".pi/settings.json" });
    defer allocator.free(settings_path);
    const settings_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .unlimited);
    defer allocator.free(settings_text);
    var settings = try std.json.parseFromSlice(std.json.Value, allocator, settings_text, .{});
    defer settings.deinit();

    const lock_path = try std.fs.path.join(allocator, &.{ project_dir, ".pi/extensions.lock.json" });
    defer allocator.free(lock_path);
    const lock_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, lock_path, allocator, .unlimited);
    defer allocator.free(lock_text);
    var lock = try std.json.parseFromSlice(std.json.Value, allocator, lock_text, .{});
    defer lock.deinit();

    var startup_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, startup_manifest_registry_snapshot, .{});
    defer startup_snapshot.deinit();
    const startup_packages = jsonArrayField(startup_snapshot.value, "packages");
    try std.testing.expect(startup_packages.len == fixtures.len);

    for (fixtures, installed_sources) |fixture, installed_source| {
        const extension = loadedExtensionForSource(extensions, installed_source) orelse return error.ExpectedLoadedPackageExtension;
        const provenance = extension.source_info.provenance orelse return error.ExpectedLoadedPackageProvenance;
        const settings_entry = settingsPackageEntry(settings.value, installed_source) orelse return error.ExpectedSettingsPackageSource;
        const install_metadata = jsonObjectField(settings_entry, "installMetadata") orelse return error.ExpectedInstallMetadata;
        try expectJsonStringFieldValue(install_metadata, "key", provenance.lock_entry_key);
        try expectJsonStringFieldValue(install_metadata, "packageRoot", provenance.package_root);

        const lock_entry = lockEntryForKey(lock.value, provenance.lock_entry_key) orelse return error.ExpectedProvenanceLockEntry;
        try expectJsonStringFieldValue(lock_entry, "key", provenance.lock_entry_key);
        try expectJsonStringFieldValue(lock_entry, "packageRoot", provenance.package_root);
        const source = jsonObjectField(lock_entry, "source") orelse return error.ExpectedProvenanceSource;
        try expectJsonStringFieldValue(source, "identity", provenance.source_identity);
        const digests = jsonObjectField(lock_entry, "digests") orelse return error.ExpectedProvenanceDigests;
        try expectJsonStringFieldValue(digests, "packageRootSha256", provenance.package_root_sha256);
        const install_digests = jsonObjectField(install_metadata, "digests") orelse return error.ExpectedProvenanceDigests;
        try expectJsonFieldEqual(allocator, install_digests, digests, "packageRootSha256");
        try expectJsonFieldEqual(allocator, install_digests, digests, "manifestSha256");

        const manifest = jsonObjectField(lock_entry, "manifest") orelse return error.ExpectedManifestMetadata;
        try expectJsonStringFieldValue(manifest, "id", fixture.manifest_id);
        try expectJsonStringFieldValue(manifest, "runtime", fixture.runtime_kind.jsonName());
        const loaded_package = packageSnapshotForId(startup_packages, fixture.manifest_id) orelse return error.ExpectedLoadedRegistryPackage;
        try expectJsonFieldEqual(allocator, manifest, loaded_package, "id");
        try expectJsonFieldEqual(allocator, manifest, loaded_package, "version");
        try expectJsonFieldEqual(allocator, manifest, loaded_package, "schemaVersion");
        const loaded_runtime = jsonObjectField(loaded_package, "runtime") orelse return error.ExpectedRuntimeMetadata;
        try expectJsonStringFieldValue(loaded_runtime, "kind", fixture.runtime_kind.jsonName());
        try expectJsonStringFieldValue(loaded_runtime, "adapter", fixture.runtime_kind.adapterName());

        const lock_declarations = jsonObjectField(lock_entry, "declarations") orelse return error.ExpectedDeclarationMetadata;
        const loaded_declarations = jsonObjectField(loaded_package, "declarations") orelse return error.ExpectedDeclarationMetadata;
        inline for (.{ "tools", "hooks", "capabilities", "permissions", "dependencies", "workflows" }) |field| {
            try expectJsonFieldEqual(allocator, lock_declarations, loaded_declarations, field);
        }
    }

    const final_extension = loadedExtensionForSource(extensions, installed_sources[installed_sources.len - 1]) orelse return error.ExpectedLoadedPackageExtension;
    const final_provenance = final_extension.source_info.provenance orelse return error.ExpectedLoadedPackageProvenance;
    const final_lock_entry = lockEntryForKey(lock.value, final_provenance.lock_entry_key) orelse return error.ExpectedProvenanceLockEntry;
    _ = jsonObjectField(final_lock_entry, "installGraph") orelse return error.ExpectedInstallGraphMetadata;
    const startup_composition = jsonObjectField(startup_snapshot.value, "composition") orelse return error.ExpectedInstallGraphMetadata;
    const startup_active_nodes = jsonArrayField(startup_composition, "activeNodes");
    try std.testing.expect(startup_active_nodes.len == fixtures.len);
    for (fixtures) |fixture| {
        var found = false;
        for (startup_active_nodes) |node| {
            if (node != .object) continue;
            const package_id = node.object.get("packageId") orelse continue;
            if (package_id == .string and std.mem.eql(u8, package_id.string, fixture.manifest_id)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

pub fn settingsPackageEntry(settings: std.json.Value, source: []const u8) ?std.json.Value {
    const packages = jsonArrayField(settings, "packages");
    for (packages) |entry| {
        if (entry == .object) {
            const source_value = entry.object.get("source") orelse continue;
            if (source_value == .string and std.mem.eql(u8, source_value.string, source)) return entry;
        }
    }
    return null;
}

pub fn lockEntryForKey(lock: std.json.Value, key: []const u8) ?std.json.Value {
    const entries = jsonArrayField(lock, "entries");
    for (entries) |entry| {
        if (entry != .object) continue;
        const value = entry.object.get("key") orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, key)) return entry;
    }
    return null;
}

pub fn packageSnapshotForId(packages: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (packages) |entry| {
        if (entry != .object) continue;
        const value = entry.object.get("id") orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, id)) return entry;
    }
    return null;
}

pub fn compositionNodeForPackageId(nodes: []const std.json.Value, package_id: []const u8) ?std.json.Value {
    for (nodes) |entry| {
        if (entry != .object) continue;
        const value = entry.object.get("packageId") orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, package_id)) return entry;
    }
    return null;
}

pub fn jsonArrayField(value: std.json.Value, field: []const u8) []const std.json.Value {
    if (value != .object) return &.{};
    const field_value = value.object.get(field) orelse return &.{};
    if (field_value != .array) return &.{};
    return field_value.array.items;
}

pub fn jsonObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field_value = value.object.get(field) orelse return null;
    if (field_value != .object) return null;
    return field_value;
}

pub fn expectJsonStringFieldValue(value: std.json.Value, field: []const u8, expected: []const u8) !void {
    if (value != .object) return error.ExpectedJsonObject;
    const field_value = value.object.get(field) orelse return error.ExpectedJsonField;
    try std.testing.expect(field_value == .string);
    try std.testing.expectEqualStrings(expected, field_value.string);
}

pub fn expectJsonFieldEqual(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value, field: []const u8) !void {
    if (left != .object or right != .object) return error.ExpectedJsonObject;
    const left_field = left.object.get(field) orelse return error.ExpectedJsonField;
    const right_field = right.object.get(field) orelse return error.ExpectedJsonField;
    const left_json = try std.json.Stringify.valueAlloc(allocator, left_field, .{});
    defer allocator.free(left_json);
    const right_json = try std.json.Stringify.valueAlloc(allocator, right_field, .{});
    defer allocator.free(right_json);
    try std.testing.expectEqualStrings(left_json, right_json);
}

pub fn expectFileContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) !void {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
}

pub fn writeAbsoluteTestFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = path, .data = data });
}

pub fn packagePolicyKey(allocator: std.mem.Allocator, source: []const u8, script_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "typescript:package:project:{s}:extensions/host.ts:{s}",
        .{ source, script_path },
    );
}

pub fn packageHostScript(
    allocator: std.mem.Allocator,
    capture_path: []const u8,
    tool_name: []const u8,
    runtime_label: []const u8,
    version: []const u8,
    register_hook: bool,
    register_workflow: bool,
) ![]u8 {
    const hook_frame = if (register_hook)
        "emit({'type':'register_hook','event':'input','hookId':'" ++ "input" ++ "','priority':0,'declarationOrder':0,'extensionPath':sys.argv[0]})\n"
    else
        "";
    const workflow_frame = if (register_workflow)
        "emit({'type':'register_workflow','id':'workflow.cross','description':'Settings backed mixed workflow','toolName':'workflow.cross','inputSchema':{'type':'object','required':['issue'],'properties':{'issue':{'type':'string'}},'additionalProperties':False},'outputSchema':{'type':'object'},'steps':[{'id':'process','kind':'side_effect','input':{'value':'workflow-process'},'selectedCapability':'process.cross','replayMode':'recorded'},{'id':'wasm','kind':'side_effect','input':{'value':'workflow-wasm'},'selectedCapability':'wasm.cross','replayMode':'recorded'},{'id':'native','kind':'side_effect','input':{'value':'workflow-native'},'selectedCapability':'native.cross','replayMode':'recorded'}],'extensionPath':sys.argv[0]})\n"
    else
        "";
    return try std.fmt.allocPrint(allocator,
        \\import json
        \\import sys
        \\
        \\capture = open("{s}", "a", encoding="utf-8")
        \\init = sys.stdin.readline()
        \\capture.write(init)
        \\capture.flush()
        \\
        \\def emit(value):
        \\    print(json.dumps(value, separators=(",", ":")), flush=True)
        \\
        \\TOOL_NAME = "{s}"
        \\RUNTIME = "{s}"
        \\VERSION = "{s}"
        \\emit({{'type':'ready'}})
        \\emit({{'type':'register_tool','name':TOOL_NAME,'label':TOOL_NAME,'description':RUNTIME + ' package tool','parameters':{{'type':'object','required':['value'],'properties':{{'value':{{'type':'string'}}}},'additionalProperties':False}},'extensionPath':sys.argv[0]}})
        \\{s}{s}
        \\for line in sys.stdin:
        \\    capture.write(line)
        \\    capture.flush()
        \\    try:
        \\        frame = json.loads(line)
        \\    except Exception:
        \\        continue
        \\    if frame.get('type') == 'shutdown':
        \\        emit({{'type':'shutdown_complete'}})
        \\        break
        \\    if frame.get('type') == 'extension_event':
        \\        event = frame.get('event') or {{}}
        \\        text = event.get('text', '')
        \\        emit({{'type':'extension_event_result','eventId':frame.get('eventId'),'result':{{'text':text + '|' + RUNTIME,'runtime':RUNTIME,'version':VERSION}}}})
        \\        continue
        \\    if frame.get('type') == 'tool_call' and frame.get('toolName') == TOOL_NAME:
        \\        value = (frame.get('input') or {{}}).get('value', '')
        \\        emit({{'type':'tool_result','toolCallId':frame.get('toolCallId'),'content':[{{'type':'text','text':RUNTIME + ':' + VERSION + ':' + value}}],'details':{{'runtime':RUNTIME,'version':VERSION,'toolName':TOOL_NAME}}}})
        \\
    , .{ capture_path, tool_name, runtime_label, version, hook_frame, workflow_frame });
}

pub fn makeManifestSources(
    allocator: std.mem.Allocator,
    fixtures: []const LifecyclePackageFixture,
    source_scope: []const u8,
) ![]coding_agent.extension_manifest.ManifestSource {
    const sources = try allocator.alloc(coding_agent.extension_manifest.ManifestSource, fixtures.len);
    errdefer allocator.free(sources);
    for (fixtures, 0..) |fixture, index| {
        const manifest_path = try std.fs.path.join(allocator, &.{ fixture.root, "pi-extension.json" });
        errdefer allocator.free(manifest_path);
        const manifest_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, manifest_path, allocator, .limited(256 * 1024));
        errdefer allocator.free(manifest_text);
        sources[index] = .{
            .package_root = fixture.root,
            .manifest_path = manifest_path,
            .manifest_text = manifest_text,
            .source_scope = source_scope,
            .precedence_rank = @intCast(index),
        };
    }
    return sources;
}

pub fn freeManifestSources(allocator: std.mem.Allocator, sources: []coding_agent.extension_manifest.ManifestSource) void {
    for (sources) |source| {
        allocator.free(@constCast(source.manifest_path));
        allocator.free(@constCast(source.manifest_text));
    }
    allocator.free(sources);
}

pub fn jsonObjectWithString(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
    return .{ .object = object };
}

pub fn expectToolResultContainsMain(messages: []const agent.AgentMessage, tool_name: []const u8, expected: []const u8) !void {
    for (messages) |message| {
        if (message != .tool_result) continue;
        if (!std.mem.eql(u8, message.tool_result.tool_name, tool_name)) continue;
        for (message.tool_result.content) |block| {
            if (block != .text) continue;
            if (std.mem.indexOf(u8, block.text.text, expected) != null) return;
        }
    }
    return error.ExpectedToolResultNotFound;
}

pub fn findToolByName(tools: []const agent.AgentTool, name: []const u8) ?agent.AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}
