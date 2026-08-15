const std = @import("std");
const ai = @import("ai");
const coding_agent = @import("coding_agent");
const auth = coding_agent.auth;
const common = coding_agent.tools.common;
const config_mod = coding_agent.config_impl;
const cli = @import("args.zig");
const auth_command = @import("auth_command.zig");
const model_resolver = @import("model_resolver.zig");

const AuthCommandKind = auth_command.AuthCommandKind;

pub fn dispatchAuthCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?u8 {
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "auth")) return null;
    if (auth_command.isAuthCommandHelp(argv)) {
        try auth_command.printAuthCommandHelp(stdout);
        return 0;
    }

    var command = auth_command.parseAuthCommand(allocator, argv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try stderr.print("Error: {s}\n", .{auth_command.parseAuthCommandErrorMessage(err, argv)});
            return 1;
        },
    } orelse return null;
    defer command.deinit(allocator);

    var parsed = cli.parseArgs(allocator, command.args) catch |err| {
        try stderr.print("Error: {s}\n", .{parseArgsErrorMessage(err)});
        return if (command.kind == .check) 2 else 1;
    };
    defer parsed.deinit(allocator);

    if (parsed.unknown_flags) |flags| {
        if (flags.len > 0) {
            try stderr.print("Unknown option --{s} for \"{s}\".\n", .{ flags[0].name, auth_command.getAuthCommandName(command.kind) });
            try stderr.print("Use \"pi --help\" or \"{s}\".\n", .{auth_command.getAuthCommandUsage(command.kind)});
            return 1;
        }
    }

    const requested = auth_command.validateAuthCommandArgs(&parsed, command.kind) catch |err| {
        try stderr.print("Error: {s}\n", .{validateErrorMessage(err, command.kind)});
        return if (command.kind == .check) 2 else 1;
    };

    const agent_dir = try config_mod.resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    const auth_path = try std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    const stored_file = try auth.readStoredCredentialsObject(allocator, io, auth_path);
    defer common.deinitJsonValue(allocator, stored_file);

    const auth_probe_ctx = AuthProbe{
        .allocator = allocator,
        .env_map = env_map,
        .stored = stored_file,
    };
    const has_auth = model_resolver.HasConfiguredAuth{
        .ctx = @ptrCast(&auth_probe_ctx),
        .func = authProbeFn,
    };

    if (command.kind == .check) {
        const provider = try resolveCheckProvider(allocator, requested.provider, requested.model, has_auth) orelse {
            if (requested.provider) |provider_id| {
                return try writeCheckResult(stdout, command, .{
                    .status = .not_ready,
                    .provider = provider_id,
                    .reason = "provider_not_found",
                }, null);
            }
            try stderr.print("Error: Model \"{s}\" not found. Use --list-models to see available models.\n", .{requested.model.?});
            return 2;
        };
        defer if (provider.owned) allocator.free(provider.id);
        defer if (provider.error_message) |message| allocator.free(message);
        if (provider.error_message) |message| {
            try stderr.print("Error: {s}\n", .{message});
            return 2;
        }
        return try runAuthCheck(
            allocator,
            io,
            env_map,
            auth_path,
            provider.id,
            command,
            stdout,
        );
    }

    const candidates = collectPrintProviders(allocator, requested.provider, requested.model, stored_file) catch |err| switch (err) {
        error.UnknownProvider => {
            try stderr.print("Error: Unknown provider \"{s}\". Use --list-models to see available providers.\n", .{requested.provider.?});
            return 1;
        },
        error.ModelNotFound => {
            try stderr.print("Error: Model \"{s}\" not found. Use --list-models to see available models.\n", .{requested.model.?});
            return 1;
        },
        else => return err,
    };
    defer freeStringList(allocator, candidates);

    return try printCredentials(
        allocator,
        io,
        env_map,
        auth_path,
        stored_file,
        candidates,
        command.kind,
        command.min_expiry_ms,
        stdout,
        stderr,
    );
}

const CheckStatus = enum { ready, not_ready, invalid };

const CheckResult = struct {
    status: CheckStatus,
    provider: []const u8,
    reason: ?[]const u8 = null,
    auth_type: ?[]const u8 = null,
};

const PrintedCredential = struct {
    provider_id: []const u8,
    value: []u8,
};

fn printCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    auth_path: []const u8,
    stored_file: std.json.Value,
    providers: []const []u8,
    kind: AuthCommandKind,
    min_expiry_ms: ?u64,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var credentials: std.ArrayList(PrintedCredential) = .empty;
    defer {
        for (credentials.items) |item| allocator.free(item.value);
        credentials.deinit(allocator);
    }

    for (providers) |provider| {
        const entry = storedEntryFromFile(stored_file, provider);
        const stored_type = if (entry) |value| storedAuthType(value) else null;
        if (kind == .api_key and stored_type == .oauth) continue;
        if (kind == .bearer_token and stored_type != .oauth) continue;

        if (kind == .api_key) {
            const stored_key = if (entry) |value| auth.buildApiKeyFromStoredEntry(allocator, provider, value) catch null else null;
            defer if (stored_key) |key| allocator.free(key);
            const resolved = try auth.resolveApiKey(allocator, io, env_map, provider, null, if (stored_key) |key| key else null);
            if (resolved) |value| {
                const owned = value.owned_api_key orelse try allocator.dupe(u8, value.api_key);
                try credentials.append(allocator, .{ .provider_id = provider, .value = owned });
            }
            continue;
        }

        if (entry) |value| {
            const min_validity_ms = min_expiry_ms orelse auth_command.DEFAULT_BEARER_TOKEN_MIN_EXPIRY_MS;
            if (try auth.buildApiKeyFromStoredEntryRefreshingWithMinValidity(
                allocator,
                io,
                env_map,
                auth_path,
                provider,
                value,
                min_validity_ms,
            )) |access| {
                try credentials.append(allocator, .{ .provider_id = provider, .value = access });
            }
        }
    }

    if (credentials.items.len == 1) {
        try stdout.print("{s}\n", .{credentials.items[0].value});
        return 0;
    }
    if (credentials.items.len > 1) {
        const joined = try joinProviderIds(allocator, credentials.items);
        defer allocator.free(joined);
        try stderr.print("Error: Multiple configured providers matched ({s}). Specify --provider.\n", .{joined});
        return 1;
    }

    if (providers.len == 1) {
        const provider = providers[0];
        const stored_type = if (storedEntryFromFile(stored_file, provider)) |value| storedAuthType(value) else null;
        if (kind == .api_key and stored_type == .oauth) {
            try stderr.print("Error: Provider \"{s}\" is configured with OAuth, not an API key\n", .{provider});
            return 1;
        }
        if (kind == .bearer_token and stored_type != .oauth) {
            try stderr.print("Error: Provider \"{s}\" is not configured with an OAuth bearer token\n", .{provider});
            return 1;
        }
    }
    try stderr.print("Error: No usable {s} is configured\n", .{
        if (kind == .api_key) "API key" else "OAuth bearer token",
    });
    return 1;
}

fn runAuthCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    auth_path: []const u8,
    provider: []const u8,
    command: auth_command.AuthCommand,
    stdout: *std.Io.Writer,
) !u8 {
    if (ai.provider_info.providerInfoFor(provider) == null) {
        return writeCheckResult(stdout, command, .{
            .status = .not_ready,
            .provider = provider,
            .reason = "provider_not_found",
        }, null);
    }

    var stored = try loadStoredEntry(allocator, io, auth_path, provider);
    defer if (stored) |*value| value.deinit(allocator);
    const stored_type = if (stored) |value| storedAuthType(value.entry) else null;

    const env_key = try auth.resolveApiKey(allocator, io, env_map, provider, null, null);
    defer if (env_key) |value| {
        if (value.owned_api_key) |owned| allocator.free(owned);
    };

    if (stored_type == null and env_key == null) {
        return writeCheckResult(stdout, command, .{
            .status = .not_ready,
            .provider = provider,
            .reason = "credentials_not_configured",
        }, null);
    }

    const auth_type: []const u8 = if (stored_type) |value|
        switch (value) {
            .oauth => "oauth",
            .api_key => "api_key",
        }
    else
        "api_key";

    var credential: ?[]u8 = null;
    defer if (credential) |value| allocator.free(value);
    if (command.credentials) {
        if (stored) |value| {
                credential = if (command.no_refresh)
                try auth.buildApiKeyFromStoredEntry(allocator, provider, value.entry)
            else
                try auth.buildApiKeyFromStoredEntryRefreshing(allocator, io, env_map, auth_path, provider, value.entry);
        } else if (env_key) |value| {
            credential = try allocator.dupe(u8, value.api_key);
        }
        if (credential == null) {
            return writeCheckResult(stdout, command, .{
                .status = .not_ready,
                .provider = provider,
                .reason = "credential_not_available",
            }, null);
        }
    }

    return writeCheckResult(stdout, command, .{
        .status = .ready,
        .provider = provider,
        .auth_type = auth_type,
    }, credential);
}

fn writeCheckResult(
    stdout: *std.Io.Writer,
    command: auth_command.AuthCommand,
    result: CheckResult,
    credential: ?[]const u8,
) !u8 {
    if (command.json) {
        try stdout.writeAll("{\"status\":\"");
        try stdout.writeAll(@tagName(result.status));
        try stdout.writeAll("\",\"provider\":");
        try writeJsonString(stdout, result.provider);
        if (result.reason) |reason| {
            try stdout.writeAll(",\"reason\":");
            try writeJsonString(stdout, reason);
        }
        if (result.auth_type) |auth_type| {
            try stdout.writeAll(",\"authType\":");
            try writeJsonString(stdout, auth_type);
        }
        if (credential) |value| {
            try stdout.writeAll(",\"credentials\":");
            try writeJsonString(stdout, value);
        }
        try stdout.writeAll("}\n");
    } else if (credential) |value| {
        try stdout.print("{s}\n", .{value});
    } else {
        try stdout.print("{s}\n", .{@tagName(result.status)});
    }
    return switch (result.status) {
        .ready => 0,
        .not_ready => 1,
        .invalid => 2,
    };
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

const AuthProbe = struct {
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    stored: std.json.Value,
};

const ResolvedCheckProvider = struct {
    id: []const u8,
    owned: bool = false,
    error_message: ?[]u8 = null,
};

fn authProbeFn(ctx: *const anyopaque, provider: []const u8) bool {
    const probe: *const AuthProbe = @ptrCast(@alignCast(ctx));
    if (storedEntryFromFile(probe.stored, provider) != null) return true;
    const env_key = ai.env_api_keys.getEnvApiKeyFromMap(probe.allocator, probe.env_map, provider) catch return false;
    defer if (env_key) |value| probe.allocator.free(value);
    return env_key != null;
}

fn resolveCheckProvider(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
    has_auth: model_resolver.HasConfiguredAuth,
) !?ResolvedCheckProvider {
    if (cli_provider) |provider| {
        if (ai.provider_info.providerInfoFor(provider) != null and cli_model == null) {
            return .{ .id = provider };
        }
        if (cli_model == null) return null;
    }
    if (cli_model) |model| {
        var resolved = try model_resolver.resolveCliModelWithAuth(allocator, cli_provider, model, has_auth);
        defer resolved.deinit(allocator);
        if (resolved.error_message) |message| {
            return .{
                .id = cli_provider orelse model,
                .error_message = try allocator.dupe(u8, message),
            };
        }
        if (resolved.provider_name == null) return null;
        return .{
            .id = try allocator.dupe(u8, resolved.provider_name.?),
            .owned = true,
        };
    }
    return null;
}

fn collectPrintProviders(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: ?[]const u8,
    stored_file: std.json.Value,
) ![][]u8 {
    if (cli_provider) |provider| {
        if (ai.provider_info.providerInfoFor(provider) == null) return error.UnknownProvider;
        const ids = try allocator.alloc([]u8, 1);
        errdefer allocator.free(ids);
        ids[0] = try allocator.dupe(u8, provider);
        return ids;
    }

    const model = cli_model orelse return error.ModelNotFound;
    var ids: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, ids.items);

    if (stored_file == .object) {
        var iterator = stored_file.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            var resolved = try model_resolver.resolveCliModel(allocator, entry.key_ptr.*, model);
            defer resolved.deinit(allocator);
            if (resolved.error_message != null or resolved.provider_name == null) continue;
            if (resolved.warning) |warning| {
                if (std.mem.indexOf(u8, warning, "Using custom model id") != null) continue;
            }
            try ids.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }
    }

    if (ids.items.len == 0) return error.ModelNotFound;
    return ids.toOwnedSlice(allocator);
}

fn storedEntryFromFile(stored_file: std.json.Value, provider: []const u8) ?std.json.ObjectMap {
    if (stored_file != .object) return null;
    const entry = stored_file.object.get(provider) orelse return null;
    return if (entry == .object) entry.object else null;
}

fn joinProviderIds(allocator: std.mem.Allocator, credentials: []const PrintedCredential) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (credentials, 0..) |item, index| {
        if (index > 0) try joined.appendSlice(allocator, ", ");
        try joined.appendSlice(allocator, item.provider_id);
    }
    return joined.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |id| allocator.free(id);
    allocator.free(ids);
}

const StoredLookup = struct {
    file: std.json.Value,
    entry: std.json.ObjectMap,

    fn deinit(self: *StoredLookup, allocator: std.mem.Allocator) void {
        common.deinitJsonValue(allocator, self.file);
        self.* = undefined;
    }
};

fn loadStoredEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider: []const u8,
) !?StoredLookup {
    const stored = try auth.readStoredCredentialsObject(allocator, io, auth_path);
    if (stored != .object) {
        common.deinitJsonValue(allocator, stored);
        return null;
    }
    const entry = stored.object.get(provider) orelse {
        common.deinitJsonValue(allocator, stored);
        return null;
    };
    if (entry != .object) {
        common.deinitJsonValue(allocator, stored);
        return null;
    }
    return .{ .file = stored, .entry = entry.object };
}

fn storedAuthType(object: std.json.ObjectMap) ?auth.ProviderAuthType {
    const type_value = if (object.get("type")) |value|
        switch (value) {
            .string => |text| text,
            else => null,
        }
    else
        null;
    if (type_value) |text| {
        if (std.mem.eql(u8, text, "oauth")) return .oauth;
        if (std.mem.eql(u8, text, "api_key")) return .api_key;
    }
    if (object.get("key") != null) return .api_key;
    return null;
}

fn parseArgsErrorMessage(err: cli.ParseArgsError) []const u8 {
    return switch (err) {
        error.UnknownOption => "Auth commands only accept --provider and --model",
        error.MissingOptionValue => "Missing option value",
        error.InvalidMode, error.InvalidThinkingLevel, error.InvalidTuiMode => "Invalid option value",
        error.OutOfMemory => "Out of memory",
    };
}

fn validateErrorMessage(err: auth_command.AuthCommandError, kind: AuthCommandKind) []const u8 {
    return switch (err) {
        error.MissingProviderOrModel => if (kind == .check)
            "Auth checks require --provider <provider> or --model <model>"
        else
            "Credential printing requires --provider <provider> or --model <model>",
        error.UnexpectedAuthArgs => "Auth commands only accept --provider and --model",
        else => auth_command.parseAuthCommandErrorMessage(err, &.{}),
    };
}

test "dispatchAuthCommand prints a stored API key" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"openai\":{\"type\":\"api_key\",\"key\":\"test-api-key\"}}\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const agent_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    defer allocator.free(agent_rel);
    const agent_dir = try std.fs.path.resolve(allocator, &.{ cwd, agent_rel });
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const code = try dispatchAuthCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "auth", "print-api-key", "--provider", "openai" },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code.?);
    try std.testing.expectEqualStrings("test-api-key\n", stdout_capture.writer.buffered());
}

test "dispatchAuthCommand print-api-key resolves --model to the sole stored provider" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"openai\":{\"type\":\"api_key\",\"key\":\"openai-from-model\"}}\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const agent_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    defer allocator.free(agent_rel);
    const agent_dir = try std.fs.path.resolve(allocator, &.{ cwd, agent_rel });
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const code = try dispatchAuthCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "auth", "print-api-key", "--model", "gpt-5.4" },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code.?);
    try std.testing.expectEqualStrings("openai-from-model\n", stdout_capture.writer.buffered());
}

test "dispatchAuthCommand print-api-key requires --provider when multiple stored providers match" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/auth.json",
        .data = "{\"openai\":{\"type\":\"api_key\",\"key\":\"openai-key\"},\"opencode\":{\"type\":\"api_key\",\"key\":\"opencode-key\"}}\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const agent_rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    defer allocator.free(agent_rel);
    const agent_dir = try std.fs.path.resolve(allocator, &.{ cwd, agent_rel });
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const code = try dispatchAuthCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "auth", "print-api-key", "--model", "gpt-5.4" },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code.?);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Specify --provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "opencode") != null);
}

test "dispatchAuthCommand help does not require credentials" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const code = try dispatchAuthCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "auth", "--help" },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code.?);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "pi auth print-api-key") != null);
}
