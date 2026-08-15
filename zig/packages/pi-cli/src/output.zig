const std = @import("std");
const cli = @import("args.zig");
const config_mod = @import("coding_agent").config_impl;
const resources_mod = @import("coding_agent").resources;
const session_advanced = @import("coding_agent").session_advanced;
const coding_agent = @import("coding_agent");

pub fn runSessionExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd_override: ?[]const u8,
    session_file: []const u8,
    output_path: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const cwd = if (cwd_override) |override| blk: {
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    const resolved_session_file = try config_mod.expandPath(allocator, env_map, session_file, cwd);
    defer allocator.free(resolved_session_file);
    const resolved_output_path = if (output_path) |path|
        try config_mod.expandPath(allocator, env_map, path, cwd)
    else
        null;
    defer if (resolved_output_path) |path| allocator.free(path);

    const exported_path = session_advanced.exportFromFile(
        allocator,
        io,
        cwd,
        resolved_session_file,
        resolved_output_path,
    ) catch |err| {
        _ = stderr;
        return err;
    };
    defer allocator.free(exported_path);

    try stdout.print("Exported to: {s}\n", .{exported_path});
    return 0;
}

pub fn exportErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "File not found",
        error.UnsupportedExportPath => "Unsupported export path. Use a .html, .jsonl, .json, or .md output path",
        error.SessionExportRequiresPersistentFile => "Cannot export JSONL from an in-memory session",
        else => @errorName(err),
    };
}

pub fn printUsage(allocator: std.mem.Allocator, version: []const u8, stdout: *std.Io.Writer) !void {
    const text = try cli.helpText(allocator, version);
    defer allocator.free(text);
    try stdout.writeAll(text);
}

pub fn printUsageWithExtensions(
    allocator: std.mem.Allocator,
    version: []const u8,
    extension_flags: []const cli.ExtensionFlagInfo,
    stdout: *std.Io.Writer,
) !void {
    const text = try cli.helpTextWithExtensions(allocator, version, extension_flags);
    defer allocator.free(text);
    try stdout.writeAll(text);
}

pub fn printUsageWithExtensionDiagnostics(
    allocator: std.mem.Allocator,
    version: []const u8,
    extension_flags: []const cli.ExtensionFlagInfo,
    extension_flag_diagnostics: []const cli.ExtensionFlagDiagnosticInfo,
    stdout: *std.Io.Writer,
) !void {
    const text = try cli.helpTextWithExtensionDiagnostics(allocator, version, extension_flags, extension_flag_diagnostics);
    defer allocator.free(text);
    try stdout.writeAll(text);
}

pub fn printVersion(allocator: std.mem.Allocator, version: []const u8, stdout: *std.Io.Writer) !void {
    const text = try cli.versionText(allocator, version);
    defer allocator.free(text);
    try stdout.writeAll(text);
}

pub fn printModelList(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    search: ?[]const u8,
    discover_models: bool,
    stdout: *std.Io.Writer,
) !u8 {
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(allocator, io, env_map, ".", .{
        .discover_models = discover_models,
    });
    defer runtime_config.deinit();

    const available = try coding_agent.provider_config.listAvailableModels(allocator, env_map, null, .{
        .auth_tokens = &runtime_config.auth_tokens,
        .provider_api_keys = &runtime_config.provider_api_keys,
    });
    defer allocator.free(available);

    const configured = try coding_agent.provider_config.filterConfiguredModels(allocator, available);
    defer allocator.free(configured);

    const filtered = if (search) |pattern|
        try coding_agent.provider_config.filterAvailableModels(allocator, configured, &.{pattern})
    else
        try allocator.dupe(coding_agent.provider_config.AvailableModel, configured);
    defer allocator.free(filtered);

    if (filtered.len == 0) {
        if (search) |pattern| {
            try stdout.print("No models matching \"{s}\"\n", .{pattern});
        } else {
            try stdout.writeAll("No models available\n");
        }
        return 0;
    }

    const Row = struct {
        provider: []const u8,
        model: []const u8,
        context: []u8,
        max_out: []u8,
        thinking: []const u8,
        tools: []const u8,
        loaded: []const u8,
        images: []const u8,
    };

    const rows = try allocator.alloc(Row, filtered.len);
    defer {
        for (rows) |row| {
            allocator.free(row.context);
            allocator.free(row.max_out);
        }
        allocator.free(rows);
    }

    var provider_width = "provider".len;
    var model_width = "model".len;
    var context_width = "context".len;
    var max_out_width = "max-out".len;
    var thinking_width = "thinking".len;
    var tools_width = "tools".len;
    var loaded_width = "loaded".len;
    var images_width = "images".len;

    for (filtered, 0..) |entry, index| {
        const context = try formatTokenCount(allocator, entry.context_window);
        errdefer allocator.free(context);
        const max_out = try formatTokenCount(allocator, entry.max_tokens);
        errdefer allocator.free(max_out);

        rows[index] = .{
            .provider = entry.provider,
            .model = entry.model_id,
            .context = context,
            .max_out = max_out,
            .thinking = if (entry.reasoning) "yes" else "no",
            .tools = if (entry.tool_calling) "yes" else "no",
            .loaded = if (entry.loaded) "yes" else "no",
            .images = if (entry.supports_images) "yes" else "no",
        };

        provider_width = @max(provider_width, rows[index].provider.len);
        model_width = @max(model_width, rows[index].model.len);
        context_width = @max(context_width, rows[index].context.len);
        max_out_width = @max(max_out_width, rows[index].max_out.len);
        thinking_width = @max(thinking_width, rows[index].thinking.len);
        tools_width = @max(tools_width, rows[index].tools.len);
        loaded_width = @max(loaded_width, rows[index].loaded.len);
        images_width = @max(images_width, rows[index].images.len);
    }

    try writeTableRow(
        stdout,
        "provider",
        provider_width,
        "model",
        model_width,
        "context",
        context_width,
        "max-out",
        max_out_width,
        "thinking",
        thinking_width,
        "tools",
        tools_width,
        "loaded",
        loaded_width,
        "images",
        images_width,
    );

    for (rows) |row| {
        try writeTableRow(
            stdout,
            row.provider,
            provider_width,
            row.model,
            model_width,
            row.context,
            context_width,
            row.max_out,
            max_out_width,
            row.thinking,
            thinking_width,
            row.tools,
            tools_width,
            row.loaded,
            loaded_width,
            row.images,
            images_width,
        );
    }

    return 0;
}

pub fn writeResourceDiagnostics(stderr: *std.Io.Writer, diagnostics: []const resources_mod.Diagnostic) !void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.path) |path| {
            try stderr.print("Warning: {s}: {s} ({s})\n", .{ diagnostic.kind, diagnostic.message, path });
        } else {
            try stderr.print("Warning: {s}: {s}\n", .{ diagnostic.kind, diagnostic.message });
        }
    }
}

pub fn flushWriters(stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    try stdout.flush();
    try stderr.flush();
}

fn writeTableRow(
    stdout: *std.Io.Writer,
    provider: []const u8,
    provider_width: usize,
    model: []const u8,
    model_width: usize,
    context: []const u8,
    context_width: usize,
    max_out: []const u8,
    max_out_width: usize,
    thinking: []const u8,
    thinking_width: usize,
    tools: []const u8,
    tools_width: usize,
    loaded: []const u8,
    loaded_width: usize,
    images: []const u8,
    images_width: usize,
) !void {
    try writePadded(stdout, provider, provider_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, model, model_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, context, context_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, max_out, max_out_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, thinking, thinking_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, tools, tools_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, loaded, loaded_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, images, images_width);
    try stdout.writeByte('\n');
}

fn writePadded(stdout: *std.Io.Writer, value: []const u8, width: usize) !void {
    try stdout.writeAll(value);
    if (width <= value.len) return;

    var remaining = width - value.len;
    var spaces: [32]u8 = [_]u8{' '} ** 32;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try stdout.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}

fn formatTokenCount(allocator: std.mem.Allocator, count: u32) ![]u8 {
    if (count >= 1_000_000) {
        if (count % 1_000_000 == 0) {
            return std.fmt.allocPrint(allocator, "{d}M", .{count / 1_000_000});
        }

        const tenths = @divFloor((@as(u64, count) * 10) + 500_000, 1_000_000);
        if (tenths % 10 == 0) {
            return std.fmt.allocPrint(allocator, "{d}M", .{@as(u32, @intCast(tenths / 10))});
        }
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}M",
            .{
                @as(u32, @intCast(tenths / 10)),
                @as(u32, @intCast(tenths % 10)),
            },
        );
    }

    if (count >= 1_000) {
        if (count % 1_000 == 0) {
            return std.fmt.allocPrint(allocator, "{d}K", .{count / 1_000});
        }

        const tenths = @divFloor((@as(u64, count) * 10) + 500, 1_000);
        if (tenths % 10 == 0) {
            return std.fmt.allocPrint(allocator, "{d}K", .{@as(u32, @intCast(tenths / 10))});
        }
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}K",
            .{
                @as(u32, @intCast(tenths / 10)),
                @as(u32, @intCast(tenths % 10)),
            },
        );
    }

    return std.fmt.allocPrint(allocator, "{d}", .{count});
}
