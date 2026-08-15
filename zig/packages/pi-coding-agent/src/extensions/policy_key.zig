const std = @import("std");
const resources_mod = @import("../resources/resources.zig");

pub const TypeScriptPolicyLookupOptions = struct {
    configured_path: []const u8,
    resolved_path: []const u8,
    source_info: resources_mod.SourceInfo,
};

pub fn typeScriptPolicyLookupKey(allocator: std.mem.Allocator, options: TypeScriptPolicyLookupOptions) ![]u8 {
    const configured_path = try toPolicyPathAlloc(allocator, options.configured_path);
    defer allocator.free(configured_path);
    const resolved_path = try toPolicyPathAlloc(allocator, options.resolved_path);
    defer allocator.free(resolved_path);

    if (configured_path.len >= 2 and configured_path[0] == '<' and configured_path[configured_path.len - 1] == '>') {
        const source = if (options.source_info.source.len > 0) options.source_info.source else "temporary";
        return std.fmt.allocPrint(allocator, "typescript:inline:{s}:{s}", .{ source, configured_path });
    }

    const scope = sourceScopeName(options.source_info.scope);
    if (options.source_info.origin == .package) {
        const entry_path = try relativePolicyPathAlloc(allocator, options.source_info.base_dir, resolved_path) orelse
            try allocator.dupe(u8, resolved_path);
        defer allocator.free(entry_path);
        return std.fmt.allocPrint(
            allocator,
            "typescript:package:{s}:{s}:{s}:{s}",
            .{ scope, options.source_info.source, entry_path, resolved_path },
        );
    }

    return std.fmt.allocPrint(allocator, "typescript:local:{s}:{s}", .{ scope, resolved_path });
}

pub fn processJsonlPolicyLookupKey(allocator: std.mem.Allocator, options: anytype) ![]u8 {
    const argv: []const []const u8 = options.argv;
    const extension_path: ?[]const u8 = options.extension_path;
    const cwd: ?[]const u8 = options.cwd;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("process_jsonl:{\"argv\":[");
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.writer.writeAll(",");
        const normalized = try toPolicyPathAlloc(allocator, arg);
        defer allocator.free(normalized);
        try writeJsonString(&out.writer, normalized);
    }
    try out.writer.writeAll("]");
    if (extension_path) |path| {
        const normalized = try toPolicyPathAlloc(allocator, path);
        defer allocator.free(normalized);
        try out.writer.writeAll(",\"extensionPath\":");
        try writeJsonString(&out.writer, normalized);
    }
    if (cwd) |path| {
        const resolved = try std.fs.path.resolve(allocator, &.{path});
        defer allocator.free(resolved);
        const normalized = try toPolicyPathAlloc(allocator, resolved);
        defer allocator.free(normalized);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonString(&out.writer, normalized);
    }
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn toPolicyPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, value);
    for (normalized) |*char| {
        if (char.* == '\\') char.* = '/';
    }
    return normalized;
}

fn sourceScopeName(scope: resources_mod.SourceScope) []const u8 {
    return switch (scope) {
        .temporary => "temporary",
        .project => "project",
        .user => "user",
    };
}

fn relativePolicyPathAlloc(allocator: std.mem.Allocator, base_dir: ?[]const u8, file_path: []const u8) !?[]u8 {
    const raw_base = base_dir orelse return null;
    const base = try toPolicyPathAlloc(allocator, raw_base);
    defer allocator.free(base);
    var base_len = base.len;
    while (base_len > 0 and base[base_len - 1] == '/') base_len -= 1;
    const trimmed_base = base[0..base_len];
    if (trimmed_base.len == 0) return null;
    if (std.mem.eql(u8, trimmed_base, file_path)) return null;
    if (!std.mem.startsWith(u8, file_path, trimmed_base)) return null;
    if (file_path.len <= trimmed_base.len or file_path[trimmed_base.len] != '/') return null;
    return try allocator.dupe(u8, file_path[trimmed_base.len + 1 ..]);
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}
