const std = @import("std");

/// Type of an extension-registered flag.
pub const FlagKind = enum { boolean, string };

/// Mirrors `cli.UnknownFlagValue`. Duplicated here so this module does
/// not depend on the CLI module (the coding-agent module cannot import
/// files outside its own root). The CLI layer converts its own
/// `UnknownFlag` slice into `[]const ParsedUnknownFlag` before invoking
/// `applyUnknownFlags`.
pub const ParsedUnknownFlagValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

pub const ParsedUnknownFlag = struct {
    name: []const u8,
    value: ParsedUnknownFlagValue,
};

/// Mirrors `cli.ExtensionFlagInfo`. Returned by
/// `Registry.snapshotForHelp`; the CLI layer copies these into its own
/// shape to render help text.
pub const ExtensionFlagInfo = struct {
    name: []const u8,
    description: ?[]const u8,
    type_kind: FlagKind,
    extension_path: []const u8,
};

/// Extension-registered CLI flag. Mirrors the subset of TypeScript
/// `ExtensionFlag` (`packages/coding-agent/src/core/extensions/types.ts`)
/// needed for CLI passthrough and help rendering.
pub const ExtensionFlag = struct {
    name: []u8,
    description: ?[]u8,
    type_kind: FlagKind,
    extension_path: []u8,

    pub fn deinit(self: *ExtensionFlag, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.extension_path);
        self.* = undefined;
    }
};

pub const DiagnosticSeverity = enum { warning, @"error" };

pub const Diagnostic = struct {
    severity: DiagnosticSeverity,
    code: []u8,
    owner: []u8,
    source: []u8,
    flag_name: []u8,
    reason: []u8,
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.owner);
        allocator.free(self.source);
        allocator.free(self.flag_name);
        allocator.free(self.reason);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const FlagValue = union(enum) {
    boolean: bool,
    string: []u8,

    pub fn deinit(self: *FlagValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .boolean => {},
        }
        self.* = undefined;
    }
};

pub const FlagValueEntry = struct {
    name: []u8,
    value: FlagValue,

    pub fn deinit(self: *FlagValueEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const ApplyResult = struct {
    values: []FlagValueEntry,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.values) |*entry| entry.deinit(allocator);
        allocator.free(self.values);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

/// In-memory registry of extension CLI flags. Owns the underlying
/// allocations for each registered flag.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList(ExtensionFlag) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.flags.items) |*flag| flag.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    fn addDiagnostic(
        self: *Registry,
        severity: DiagnosticSeverity,
        code: []const u8,
        owner: []const u8,
        source: []const u8,
        flag_name: []const u8,
        reason: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);
        try self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .code = try self.allocator.dupe(u8, code),
            .owner = try self.allocator.dupe(u8, owner),
            .source = try self.allocator.dupe(u8, source),
            .flag_name = try self.allocator.dupe(u8, flag_name),
            .reason = try self.allocator.dupe(u8, reason),
            .message = message,
        });
    }

    pub fn register(
        self: *Registry,
        name: []const u8,
        type_kind: FlagKind,
        description: ?[]const u8,
        extension_path: []const u8,
    ) !void {
        // Reject duplicate registrations to keep behavior deterministic.
        for (self.flags.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateExtensionFlag;
        }
        var flag: ExtensionFlag = .{
            .name = try self.allocator.dupe(u8, name),
            .description = if (description) |desc| try self.allocator.dupe(u8, desc) else null,
            .type_kind = type_kind,
            .extension_path = try self.allocator.dupe(u8, extension_path),
        };
        errdefer flag.deinit(self.allocator);
        try self.flags.append(self.allocator, flag);
    }

    pub fn list(self: *const Registry) []const ExtensionFlag {
        return self.flags.items;
    }

    /// Returns a stable snapshot of the registry as plain
    /// `ExtensionFlagInfo` records. The caller owns the returned slice
    /// but must not free the inner string pointers because they
    /// reference registry-owned memory.
    pub fn snapshotForHelp(
        self: *const Registry,
        allocator: std.mem.Allocator,
    ) ![]ExtensionFlagInfo {
        const out = try allocator.alloc(ExtensionFlagInfo, self.flags.items.len);
        errdefer allocator.free(out);
        for (self.flags.items, 0..) |flag, idx| {
            out[idx] = .{
                .name = flag.name,
                .description = if (flag.description) |desc| desc else null,
                .type_kind = flag.type_kind,
                .extension_path = flag.extension_path,
            };
        }
        return out;
    }

    pub fn lookup(self: *const Registry, name: []const u8) ?ExtensionFlag {
        for (self.flags.items) |flag| {
            if (std.mem.eql(u8, flag.name, name)) return flag;
        }
        return null;
    }
};

/// Validate the parser-collected `unknown_flags` against the registry.
/// Returns:
///   - `values`: ordered list of `(name, value)` for every registered flag
///     that appeared on the CLI. Boolean flags resolve to `true` whether
///     or not the parser captured a string value (mirrors TS where the
///     boolean-typed flag ignores any explicit token).
///   - `diagnostics`: one `Unknown option:` error grouping all
///     unregistered flag names (mirrors TS), plus any `requires a value`
///     diagnostics for string flags whose only captured value was the
///     bare boolean form.
pub fn applyUnknownFlags(
    allocator: std.mem.Allocator,
    registry: *const Registry,
    unknown_flags: []const ParsedUnknownFlag,
) !ApplyResult {
    var values_builder = std.ArrayList(FlagValueEntry).empty;
    errdefer {
        for (values_builder.items) |*entry| entry.deinit(allocator);
        values_builder.deinit(allocator);
    }

    var diagnostics_builder = std.ArrayList(Diagnostic).empty;
    errdefer {
        for (diagnostics_builder.items) |*d| d.deinit(allocator);
        diagnostics_builder.deinit(allocator);
    }

    var unknown_names = std.ArrayList([]const u8).empty;
    defer unknown_names.deinit(allocator);

    for (registry.diagnostics.items) |diagnostic| {
        try diagnostics_builder.append(allocator, .{
            .severity = diagnostic.severity,
            .code = try allocator.dupe(u8, diagnostic.code),
            .owner = try allocator.dupe(u8, diagnostic.owner),
            .source = try allocator.dupe(u8, diagnostic.source),
            .flag_name = try allocator.dupe(u8, diagnostic.flag_name),
            .reason = try allocator.dupe(u8, diagnostic.reason),
            .message = try allocator.dupe(u8, diagnostic.message),
        });
    }

    for (unknown_flags) |raw_flag| {
        const registered = registry.lookup(raw_flag.name) orelse {
            try unknown_names.append(allocator, raw_flag.name);
            continue;
        };

        switch (registered.type_kind) {
            .boolean => {
                try values_builder.append(allocator, .{
                    .name = try allocator.dupe(u8, raw_flag.name),
                    .value = .{ .boolean = true },
                });
            },
            .string => switch (raw_flag.value) {
                .string => |s| {
                    try values_builder.append(allocator, .{
                        .name = try allocator.dupe(u8, raw_flag.name),
                        .value = .{ .string = try allocator.dupe(u8, s) },
                    });
                },
                .boolean => {
                    const message = try std.fmt.allocPrint(
                        allocator,
                        "Extension flag \"--{s}\" requires a value",
                        .{raw_flag.name},
                    );
                    errdefer allocator.free(message);
                    try diagnostics_builder.append(allocator, .{
                        .severity = .@"error",
                        .code = try allocator.dupe(u8, "extension_flag.missing_value"),
                        .owner = try allocator.dupe(u8, registered.extension_path),
                        .source = try allocator.dupe(u8, "cli"),
                        .flag_name = try allocator.dupe(u8, raw_flag.name),
                        .reason = try allocator.dupe(u8, "missing string value"),
                        .message = message,
                    });
                },
            },
        }
    }

    if (unknown_names.items.len > 0) {
        var msg_builder = std.ArrayList(u8).empty;
        defer msg_builder.deinit(allocator);
        try msg_builder.appendSlice(allocator, "Unknown option");
        if (unknown_names.items.len != 1) try msg_builder.append(allocator, 's');
        try msg_builder.appendSlice(allocator, ": ");
        for (unknown_names.items, 0..) |name, idx| {
            if (idx > 0) try msg_builder.appendSlice(allocator, ", ");
            try msg_builder.appendSlice(allocator, "--");
            try msg_builder.appendSlice(allocator, name);
        }
        const owned_message = try msg_builder.toOwnedSlice(allocator);
        errdefer allocator.free(owned_message);
        const flag_name = try joinUnknownFlagNames(allocator, unknown_names.items);
        errdefer allocator.free(flag_name);
        try diagnostics_builder.append(allocator, .{
            .severity = .@"error",
            .code = try allocator.dupe(u8, "extension_flag.unknown"),
            .owner = try allocator.dupe(u8, "unowned"),
            .source = try allocator.dupe(u8, "cli"),
            .flag_name = flag_name,
            .reason = try allocator.dupe(u8, "no approved extension owns flag"),
            .message = owned_message,
        });
    }

    return .{
        .values = try values_builder.toOwnedSlice(allocator),
        .diagnostics = try diagnostics_builder.toOwnedSlice(allocator),
    };
}

/// Discover registered flags declared by Bun-hosted extensions through a
/// deterministic local manifest sidecar (`<extension>.flags.json` next
/// to the extension's main file, or `flags.json` inside an extension
/// directory). This is the local-fixture compatibility hook used by M11
/// extension tests; live Bun JSONL flag registration is handled by the
/// sibling registration-surfaces feature.
///
/// Manifest schema:
///   {
///     "flags": [
///       { "name": "plan", "type": "boolean", "description": "..." },
///       { "name": "model-alias", "type": "string" }
///     ]
///   }
pub fn loadFromExtensionPaths(
    registry: *Registry,
    io: std.Io,
    extension_paths: []const []const u8,
) !void {
    const allocator = registry.allocator;

    for (extension_paths) |path| {
        const manifest_text = readManifestForPath(allocator, io, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(manifest_text);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch {
            // Ignore malformed manifest deterministically. The caller may
            // surface the diagnostic separately if needed.
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const flags_value = root.get("flags") orelse continue;
        if (flags_value != .array) continue;

        for (flags_value.array.items) |entry| {
            if (entry != .object) continue;
            const obj = entry.object;
            const name_value = obj.get("name") orelse continue;
            if (name_value != .string) continue;
            const type_value = obj.get("type") orelse continue;
            if (type_value != .string) continue;

            const type_kind: FlagKind = if (std.mem.eql(u8, type_value.string, "string"))
                .string
            else if (std.mem.eql(u8, type_value.string, "boolean"))
                .boolean
            else
                continue;

            const description_value = obj.get("description");
            const description: ?[]const u8 = if (description_value) |dv| switch (dv) {
                .string => |s| s,
                else => null,
            } else null;

            if (isBuiltinFlagName(name_value.string)) {
                try registry.addDiagnostic(
                    .@"error",
                    "extension_flag.builtin_collision",
                    path,
                    path,
                    name_value.string,
                    "collides with built-in option",
                    "Extension flag \"--{s}\" from {s} collides with a built-in option",
                    .{ name_value.string, path },
                );
                continue;
            }

            registry.register(name_value.string, type_kind, description, path) catch |err| switch (err) {
                error.DuplicateExtensionFlag => try registry.addDiagnostic(
                    .@"error",
                    "extension_flag.owner_collision",
                    path,
                    path,
                    name_value.string,
                    "collides with another extension flag owner",
                    "Extension flag \"--{s}\" from {s} collides with another extension flag owner",
                    .{ name_value.string, path },
                ),
                else => return err,
            };
        }
    }
}

fn isBuiltinFlagName(name: []const u8) bool {
    const builtin_flags = [_][]const u8{
        "help",
        "version",
        "api-key",
        "extension",
        "no-extensions",
        "skill",
        "no-skills",
        "prompt-template",
        "no-prompt-templates",
        "prompt",
        "append-system-prompt",
        "theme",
        "no-themes",
        "thinking",
        "continue",
        "resume",
        "fork",
        "print",
        "provider",
        "model",
        "models",
        "list-models",
        "profile",
        "mode",
        "tools",
        "no-tools",
        "no-builtin-tools",
        "system-prompt",
        "system",
        "no-context-files",
        "offline",
        "verbose",
        "export",
        "session",
        "session-dir",
    };
    for (builtin_flags) |flag| {
        if (std.mem.eql(u8, name, flag)) return true;
    }
    return false;
}

fn readManifestForPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Try `<path>.flags.json` first (file extension form), then
    // `<path>/flags.json` for directory-style extensions. Matches the
    // local fixture layout used in tests. Treat NotDir / IsDir as
    // FileNotFound so callers can keep iterating extension paths.
    const sidecar = try std.fmt.allocPrint(allocator, "{s}.flags.json", .{path});
    defer allocator.free(sidecar);

    if (std.Io.Dir.readFileAlloc(.cwd(), io, sidecar, allocator, .limited(64 * 1024))) |bytes| {
        return bytes;
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => {},
        else => return err,
    }

    const dir_manifest = try std.fs.path.join(allocator, &[_][]const u8{ path, "flags.json" });
    defer allocator.free(dir_manifest);
    return std.Io.Dir.readFileAlloc(.cwd(), io, dir_manifest, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.NotDir, error.IsDir => return error.FileNotFound,
        else => return err,
    };
}

fn joinUnknownFlagNames(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

test "Registry registers and lists flags" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try registry.register("plan", .boolean, "Enable plan mode", "/tmp/plan.ts");
    try registry.register("model-alias", .string, null, "/tmp/alias.ts");

    try std.testing.expectEqual(@as(usize, 2), registry.list().len);
    try std.testing.expectEqualStrings("plan", registry.list()[0].name);
    try std.testing.expectEqualStrings("model-alias", registry.list()[1].name);
    try std.testing.expectError(error.DuplicateExtensionFlag, registry.register(
        "plan",
        .boolean,
        null,
        "/tmp/other.ts",
    ));
}

test "applyUnknownFlags accepts registered boolean and string flags" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register("plan", .boolean, "Plan mode", "/tmp/plan.ts");
    try registry.register("alias", .string, "Model alias", "/tmp/alias.ts");

    const unknown_flags = [_]ParsedUnknownFlag{
        .{ .name = "plan", .value = .{ .boolean = true } },
        .{ .name = "alias", .value = .{ .string = "claude-haiku" } },
    };
    var result = try applyUnknownFlags(allocator, &registry, &unknown_flags);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.values.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    try std.testing.expectEqualStrings("plan", result.values[0].name);
    try std.testing.expect(result.values[0].value == .boolean);
    try std.testing.expect(result.values[0].value.boolean);

    try std.testing.expectEqualStrings("alias", result.values[1].name);
    try std.testing.expect(result.values[1].value == .string);
    try std.testing.expectEqualStrings("claude-haiku", result.values[1].value.string);
}

test "applyUnknownFlags reports unregistered flags with combined message" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register("plan", .boolean, null, "/tmp/plan.ts");

    const unknown_flags = [_]ParsedUnknownFlag{
        .{ .name = "bogus", .value = .{ .boolean = true } },
        .{ .name = "another", .value = .{ .string = "v" } },
    };
    var result = try applyUnknownFlags(allocator, &registry, &unknown_flags);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.values.len);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqualStrings("extension_flag.unknown", result.diagnostics[0].code);
    try std.testing.expectEqualStrings("unowned", result.diagnostics[0].owner);
    try std.testing.expectEqualStrings("cli", result.diagnostics[0].source);
    try std.testing.expectEqualStrings("bogus,another", result.diagnostics[0].flag_name);
    try std.testing.expectEqualStrings("no approved extension owns flag", result.diagnostics[0].reason);
    try std.testing.expectEqualStrings(
        "Unknown options: --bogus, --another",
        result.diagnostics[0].message,
    );
}

test "applyUnknownFlags produces requires-a-value diagnostic for bare string flags" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    try registry.register("alias", .string, null, "/tmp/alias.ts");

    const unknown_flags = [_]ParsedUnknownFlag{
        .{ .name = "alias", .value = .{ .boolean = true } },
    };
    var result = try applyUnknownFlags(allocator, &registry, &unknown_flags);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.values.len);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqualStrings("extension_flag.missing_value", result.diagnostics[0].code);
    try std.testing.expectEqualStrings("/tmp/alias.ts", result.diagnostics[0].owner);
    try std.testing.expectEqualStrings("cli", result.diagnostics[0].source);
    try std.testing.expectEqualStrings("alias", result.diagnostics[0].flag_name);
    try std.testing.expectEqualStrings("missing string value", result.diagnostics[0].reason);
    try std.testing.expectEqualStrings(
        "Extension flag \"--alias\" requires a value",
        result.diagnostics[0].message,
    );
}

test "loadFromExtensionPaths reads sidecar manifest and registers flags" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ext_path = "extension.ts";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ext_path,
        .data = "// extension stub",
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

    try std.testing.expectEqual(@as(usize, 2), registry.list().len);
    try std.testing.expectEqualStrings("plan", registry.list()[0].name);
    try std.testing.expect(registry.list()[0].type_kind == .boolean);
    try std.testing.expectEqualStrings("model-alias", registry.list()[1].name);
    try std.testing.expect(registry.list()[1].type_kind == .string);
}

test "loadFromExtensionPaths diagnoses built-in and extension flag collisions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "first.ts",
        .data = "// first extension",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "first.ts.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "plan", "type": "boolean" },
        \\  { "name": "model", "type": "string" },
        \\  { "name": "print", "type": "boolean" }
        \\] }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "second.ts",
        .data = "// second extension",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "second.ts.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "plan", "type": "string" }
        \\] }
        ,
    });

    const first_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "first.ts" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "second.ts" });
    defer allocator.free(second_path);

    var registry = Registry.init(allocator);
    defer registry.deinit();
    try loadFromExtensionPaths(&registry, std.testing.io, &.{ first_path, second_path });

    try std.testing.expectEqual(@as(usize, 1), registry.list().len);
    try std.testing.expectEqualStrings("plan", registry.list()[0].name);

    var result = try applyUnknownFlags(allocator, &registry, &.{});
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.values.len);
    try std.testing.expectEqual(@as(usize, 3), result.diagnostics.len);
    try std.testing.expectEqualStrings("extension_flag.builtin_collision", result.diagnostics[0].code);
    try std.testing.expectEqualStrings("extension_flag.builtin_collision", result.diagnostics[1].code);
    try std.testing.expectEqualStrings("extension_flag.owner_collision", result.diagnostics[2].code);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics[0].message, "collides with a built-in option") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics[1].message, "--print") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.diagnostics[2].message, "collides with another extension flag owner") != null);
}
