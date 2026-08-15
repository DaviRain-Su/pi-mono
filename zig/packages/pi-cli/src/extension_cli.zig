const std = @import("std");
const builtin = @import("builtin");
const cli = @import("args.zig");
const enforcement = @import("coding_agent").enforcement;
const extension_flags = @import("coding_agent").extension_flags;
const extension_registry = @import("coding_agent").extension_registry;
const extension_runtime = @import("coding_agent").extension_runtime;
const cli_test = if (builtin.is_test) @import("test_harness.zig") else struct {};

/// Owns extension-specific CLI preprocessing state for a parsed invocation.
///
/// `main.zig` keeps high-level CLI ordering, while this helper owns the
/// sidecar flag registry, unknown-flag validation, retained parsed flag values,
/// and the live registry-dump hook used by deterministic extension tests.
pub const PreparedExtensionCli = struct {
    allocator: std.mem.Allocator,
    registry: extension_flags.Registry,
    parsed_flag_owned_names: std.ArrayList([]u8) = .empty,
    parsed_flag_owned_strings: std.ArrayList([]u8) = .empty,
    parsed_cli_flag_values: std.ArrayList(extension_registry.ParsedCliFlag) = .empty,

    pub fn init(allocator: std.mem.Allocator) PreparedExtensionCli {
        return .{
            .allocator = allocator,
            .registry = extension_flags.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *PreparedExtensionCli) void {
        self.parsed_cli_flag_values.deinit(self.allocator);
        for (self.parsed_flag_owned_names.items) |s| self.allocator.free(s);
        self.parsed_flag_owned_names.deinit(self.allocator);
        for (self.parsed_flag_owned_strings.items) |s| self.allocator.free(s);
        self.parsed_flag_owned_strings.deinit(self.allocator);
        self.registry.deinit();
        self.* = undefined;
    }

    pub fn loadFlagSidecars(
        self: *PreparedExtensionCli,
        io: std.Io,
        extension_paths: ?[]const []const u8,
    ) !void {
        if (extension_paths) |paths| {
            try extension_flags.loadFromExtensionPaths(&self.registry, io, paths);
        }
    }

    /// Return CLI help records copied from the extension flag registry.
    /// The returned slice is caller-owned; inner strings remain registry-owned.
    pub fn snapshotHelpFlags(
        self: *PreparedExtensionCli,
        allocator: std.mem.Allocator,
    ) ![]cli.ExtensionFlagInfo {
        const ext_flags_snapshot = try self.registry.snapshotForHelp(allocator);
        defer allocator.free(ext_flags_snapshot);

        const help_flags = try allocator.alloc(cli.ExtensionFlagInfo, ext_flags_snapshot.len);
        errdefer allocator.free(help_flags);
        for (ext_flags_snapshot, 0..) |flag, idx| {
            help_flags[idx] = .{
                .name = flag.name,
                .description = flag.description,
                .type_kind = switch (flag.type_kind) {
                    .boolean => .boolean,
                    .string => .string,
                },
                .extension_path = flag.extension_path,
            };
        }
        return help_flags;
    }

    pub fn snapshotHelpDiagnostics(
        self: *PreparedExtensionCli,
        allocator: std.mem.Allocator,
    ) ![]cli.ExtensionFlagDiagnosticInfo {
        const diagnostics = self.registry.diagnostics.items;
        const out = try allocator.alloc(cli.ExtensionFlagDiagnosticInfo, diagnostics.len);
        errdefer allocator.free(out);
        for (diagnostics, 0..) |diagnostic, idx| {
            out[idx] = .{
                .severity = switch (diagnostic.severity) {
                    .warning => "warning",
                    .@"error" => "error",
                },
                .code = diagnostic.code,
                .owner = diagnostic.owner,
                .source = diagnostic.source,
                .flag_name = diagnostic.flag_name,
                .reason = diagnostic.reason,
                .message = diagnostic.message,
            };
        }
        return out;
    }

    /// Validate parser-collected unknown long flags against extension flag
    /// sidecars. Returns false when any error diagnostic was written.
    pub fn applyUnknownFlags(
        self: *PreparedExtensionCli,
        unknown_flags: ?[]const cli.UnknownFlag,
        stderr: *std.Io.Writer,
    ) !bool {
        return self.applyUnknownFlagsWithOptions(unknown_flags, stderr, false);
    }

    pub fn applyUnknownFlagsForRegistryDump(
        self: *PreparedExtensionCli,
        unknown_flags: ?[]const cli.UnknownFlag,
        stderr: *std.Io.Writer,
    ) !bool {
        return self.applyUnknownFlagsWithOptions(unknown_flags, stderr, true);
    }

    fn applyUnknownFlagsWithOptions(
        self: *PreparedExtensionCli,
        unknown_flags: ?[]const cli.UnknownFlag,
        stderr: *std.Io.Writer,
        allow_registry_diagnostics: bool,
    ) !bool {
        const raw_unknown_flags = unknown_flags orelse &.{};

        const parsed = try self.allocator.alloc(extension_flags.ParsedUnknownFlag, raw_unknown_flags.len);
        defer self.allocator.free(parsed);
        for (raw_unknown_flags, 0..) |raw, idx| {
            parsed[idx] = .{
                .name = raw.name,
                .value = switch (raw.value) {
                    .boolean => |b| .{ .boolean = b },
                    .string => |s| .{ .string = s },
                },
            };
        }

        var apply_result = try extension_flags.applyUnknownFlags(
            self.allocator,
            &self.registry,
            parsed,
        );
        defer apply_result.deinit(self.allocator);

        var saw_error = false;
        for (apply_result.diagnostics) |diagnostic| {
            if (allow_registry_diagnostics and self.isRegistryDiagnostic(diagnostic)) continue;
            if (diagnostic.severity == .@"error") saw_error = true;
            try stderr.print(
                "Error: {s} owner={s} source={s} flag=--{s} reason={s}: {s}\n",
                .{
                    diagnostic.code,
                    diagnostic.owner,
                    diagnostic.source,
                    diagnostic.flag_name,
                    diagnostic.reason,
                    diagnostic.message,
                },
            );
        }
        if (saw_error) return false;

        for (apply_result.values) |entry| {
            try self.storeParsedCliFlagValue(entry);
        }

        return true;
    }

    fn storeParsedCliFlagValue(
        self: *PreparedExtensionCli,
        entry: extension_flags.FlagValueEntry,
    ) !void {
        const name_owned = try self.allocator.dupe(u8, entry.name);
        var name_stored = false;
        errdefer if (!name_stored) self.allocator.free(name_owned);

        switch (entry.value) {
            .boolean => |b| {
                try self.parsed_flag_owned_names.append(self.allocator, name_owned);
                name_stored = true;
                try self.parsed_cli_flag_values.append(self.allocator, .{
                    .name = name_owned,
                    .value = .{ .boolean = b },
                });
            },
            .string => |s| {
                const value_owned = try self.allocator.dupe(u8, s);
                var value_stored = false;
                errdefer if (!value_stored) self.allocator.free(value_owned);
                try self.parsed_flag_owned_names.append(self.allocator, name_owned);
                name_stored = true;
                try self.parsed_flag_owned_strings.append(self.allocator, value_owned);
                value_stored = true;
                try self.parsed_cli_flag_values.append(self.allocator, .{
                    .name = name_owned,
                    .value = .{ .string = value_owned },
                });
            },
        }
    }

    fn isRegistryDiagnostic(self: *const PreparedExtensionCli, diagnostic: extension_flags.Diagnostic) bool {
        for (self.registry.diagnostics.items) |registry_diagnostic| {
            if (!std.mem.eql(u8, registry_diagnostic.code, diagnostic.code)) continue;
            if (!std.mem.eql(u8, registry_diagnostic.owner, diagnostic.owner)) continue;
            if (!std.mem.eql(u8, registry_diagnostic.flag_name, diagnostic.flag_name)) continue;
            return true;
        }
        return false;
    }

    pub fn parsedCliFlagValues(self: *const PreparedExtensionCli) []const extension_registry.ParsedCliFlag {
        return self.parsed_cli_flag_values.items;
    }

    pub fn rejectedFlagDiagnostics(self: *const PreparedExtensionCli) []const extension_flags.Diagnostic {
        return self.registry.diagnostics.items;
    }
};

pub fn shouldRunRegistryDump(
    env_map: *const std.process.Environ.Map,
    extension_paths: ?[]const []const u8,
) bool {
    const paths = extension_paths orelse return false;
    if (paths.len == 0) return false;
    const dump_value = env_map.get("PI_M11_EXTENSION_REGISTRY_DUMP") orelse return false;
    return isEnabledValue(dump_value);
}

/// Start a Bun-hosted extension via the M11 registry-dump CLI hook,
/// drain live register_* JSONL frames into the runtime registry, plumb
/// parsed CLI flag values into `extensionState`, and write the
/// deterministic snapshot to stdout. The runtime is configurable via
/// `PI_M11_EXTENSION_HOST_RUNTIME` (default `bun`) so deterministic
/// validation can substitute a local shell stub for the live Bun
/// runtime when needed. Always exits cleanly with the host shut down.
pub fn runExtensionRegistryDump(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    extension_paths: []const []const u8,
    rejected_flag_diagnostics: []const extension_flags.Diagnostic,
    parsed_flag_values: []const extension_registry.ParsedCliFlag,
    cwd_override: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (extension_paths.len == 0) return 0;
    const runtime = env_map.get("PI_M11_EXTENSION_HOST_RUNTIME") orelse "bun";
    const marker = env_map.get("PI_M11_EXTENSION_HOST_MARKER") orelse "pi-m11-extension-host";
    const fixture = env_map.get("PI_M11_EXTENSION_HOST_FIXTURE") orelse "m11-fixture";
    const ready_timeout_ms: u64 = std.fmt.parseInt(u64, env_map.get("PI_M11_EXTENSION_READY_TIMEOUT_MS") orelse "1500", 10) catch 1500;
    const drain_timeout_ms: u64 = std.fmt.parseInt(u64, env_map.get("PI_M11_EXTENSION_DRAIN_TIMEOUT_MS") orelse "1500", 10) catch 1500;
    const shutdown_timeout_ms: u64 = std.fmt.parseInt(u64, env_map.get("PI_M11_EXTENSION_SHUTDOWN_TIMEOUT_MS") orelse "1000", 10) catch 1000;

    // Prefer the first --extension path as the entry point; additional
    // paths are forwarded as host argv tail so a local shell stub can
    // observe them. Bun ignores trailing argv after the entry script.
    const cwd = if (cwd_override) |override| try allocator.dupe(u8, override) else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, runtime);
    for (extension_paths) |p| try argv.append(allocator, p);
    try argv.append(allocator, marker);

    const host = extension_runtime.startRuntimeAdapter(allocator, io, .{ .process_jsonl = .{
        .argv = argv.items,
        .cwd = cwd,
        .extension_path = extension_paths[0],
        .initialize = .{
            .marker = marker,
            .cwd = cwd,
            .fixture = fixture,
        },
        .shutdown_timeout_ms = shutdown_timeout_ms,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
    } }) catch |err| {
        try stderr.print("Error: failed to start extension host: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer host.deinit();

    host.waitForReady(ready_timeout_ms) catch {
        try stderr.writeAll("Error: extension host did not become ready\n");
        return 1;
    };

    // Wait until the host has been quiescent for >100ms with no new
    // registry frames arriving, or `drain_timeout_ms` has elapsed.
    var elapsed: u64 = 0;
    var last_count: usize = 0;
    var quiet: u64 = 0;
    const tick_ms: u64 = 10;
    while (elapsed < drain_timeout_ms) : (elapsed += tick_ms) {
        const cur = host.registryFramesApplied();
        if (cur != last_count) {
            last_count = cur;
            quiet = 0;
        } else {
            quiet += tick_ms;
            if (quiet >= 100 and last_count != 0) break;
        }
        std.Io.sleep(io, .fromMilliseconds(@intCast(tick_ms)), .awake) catch {};
    }

    // Plumb parsed CLI flag values into the live registry so
    // extensions can observe them through `getFlag()`.
    if (parsed_flag_values.len > 0) {
        host.applyCliFlagValues(parsed_flag_values) catch {};
    }

    const snapshot = try host.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    const snapshot_with_diagnostics = try snapshotWithRejectedFlagDiagnostics(allocator, snapshot, rejected_flag_diagnostics);
    defer allocator.free(snapshot_with_diagnostics);
    try stdout.print("{s}\n", .{snapshot_with_diagnostics});

    host.shutdown() catch |err| {
        try stderr.print("Error: extension host shutdown failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn snapshotWithRejectedFlagDiagnostics(
    allocator: std.mem.Allocator,
    snapshot: []const u8,
    diagnostics: []const extension_flags.Diagnostic,
) ![]u8 {
    if (diagnostics.len == 0) return try allocator.dupe(u8, snapshot);

    const trimmed = std.mem.trimEnd(u8, snapshot, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') return try allocator.dupe(u8, snapshot);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll(trimmed[0 .. trimmed.len - 1]);
    if (trimmed.len > 2) try writer.writer.writeAll(",");
    try writer.writer.writeAll("\"extensionFlagDiagnostics\":[");
    for (diagnostics, 0..) |diagnostic, index| {
        if (index > 0) try writer.writer.writeAll(",");
        try writer.writer.writeAll("{\"severity\":");
        try std.json.Stringify.value(std.json.Value{ .string = switch (diagnostic.severity) {
            .warning => "warning",
            .@"error" => "error",
        } }, .{}, &writer.writer);
        try writer.writer.writeAll(",\"code\":");
        try std.json.Stringify.value(std.json.Value{ .string = diagnostic.code }, .{}, &writer.writer);
        try writer.writer.writeAll(",\"owner\":");
        try std.json.Stringify.value(std.json.Value{ .string = diagnostic.owner }, .{}, &writer.writer);
        try writer.writer.writeAll(",\"source\":");
        try std.json.Stringify.value(std.json.Value{ .string = diagnostic.source }, .{}, &writer.writer);
        try writer.writer.writeAll(",\"flag\":");
        try std.json.Stringify.value(std.json.Value{ .string = diagnostic.flag_name }, .{}, &writer.writer);
        try writer.writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(std.json.Value{ .string = diagnostic.reason }, .{}, &writer.writer);
        try writer.writer.writeAll(",\"message\":");
        try std.json.Stringify.value(std.json.Value{ .string = diagnostic.message }, .{}, &writer.writer);
        try writer.writer.writeAll("}");
    }
    try writer.writer.writeAll("]}");
    return try allocator.dupe(u8, writer.writer.buffered());
}

fn isEnabledValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
}

test "PreparedExtensionCli loads sidecar flags and keeps parsed registry-dump values" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "plan", "type": "boolean", "description": "Enable plan mode" },
        \\  { "name": "model-alias", "type": "string" }
        \\] }
        ,
    });
    const ext_path = try cli_test.makeTmpPath(allocator, tmp, "extension.ts");
    defer allocator.free(ext_path);

    var prepared = PreparedExtensionCli.init(allocator);
    defer prepared.deinit();
    try prepared.loadFlagSidecars(std.testing.io, &.{ext_path});

    const help_flags = try prepared.snapshotHelpFlags(allocator);
    defer allocator.free(help_flags);
    try std.testing.expectEqual(@as(usize, 2), help_flags.len);
    try std.testing.expectEqualStrings("plan", help_flags[0].name);
    try std.testing.expectEqual(.boolean, help_flags[0].type_kind);
    try std.testing.expectEqualStrings("model-alias", help_flags[1].name);
    try std.testing.expectEqual(.string, help_flags[1].type_kind);

    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const ok = try prepared.applyUnknownFlags(
        &.{
            .{ .name = "plan", .value = .{ .boolean = true } },
            .{ .name = "model-alias", .value = .{ .string = "claude-opus" } },
        },
        &stderr_capture.writer,
    );
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const values = prepared.parsedCliFlagValues();
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("plan", values[0].name);
    try std.testing.expectEqual(true, values[0].value.boolean);
    try std.testing.expectEqualStrings("model-alias", values[1].name);
    try std.testing.expectEqualStrings("claude-opus", values[1].value.string);
}

test "PreparedExtensionCli reports unregistered extension flags without parsed values" {
    const allocator = std.testing.allocator;

    var prepared = PreparedExtensionCli.init(allocator);
    defer prepared.deinit();

    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const ok = try prepared.applyUnknownFlags(
        &.{.{ .name = "bogus-flag", .value = .{ .boolean = true } }},
        &stderr_capture.writer,
    );
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 0), prepared.parsedCliFlagValues().len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Error: extension_flag.unknown owner=unowned source=cli flag=--bogus-flag reason=no approved extension owns flag: Unknown option: --bogus-flag\n") != null);
}

test "shouldRunRegistryDump requires an enabled env value and extension path" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try std.testing.expect(!shouldRunRegistryDump(&env_map, null));
    try std.testing.expect(!shouldRunRegistryDump(&env_map, &.{"extension.ts"}));

    try env_map.put("PI_M11_EXTENSION_REGISTRY_DUMP", "0");
    try std.testing.expect(!shouldRunRegistryDump(&env_map, &.{"extension.ts"}));

    try env_map.put("PI_M11_EXTENSION_REGISTRY_DUMP", "yes");
    try std.testing.expect(shouldRunRegistryDump(&env_map, &.{"extension.ts"}));
    try std.testing.expect(!shouldRunRegistryDump(&env_map, &.{}));
}
