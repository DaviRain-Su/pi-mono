const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;

pub fn makeTextContent(allocator: std.mem.Allocator, text: []const u8) ![]const ai.ContentBlock {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, text),
        },
    };
    return blocks;
}

pub fn deinitContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.thinking_signature) |signature| allocator.free(signature);
                if (thinking.signature) |signature| allocator.free(signature);
            },
            .tool_call => |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                if (tool_call.thought_signature) |signature| allocator.free(signature);
                provider_json.freeValue(allocator, tool_call.arguments);
            },
        }
    }
    allocator.free(blocks);
}

pub fn resolvePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

pub fn writeFileAbsolute(io: std.Io, absolute_path: []const u8, data: []const u8, make_path: bool) !void {
    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, absolute_path, .{
        .make_path = make_path,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.flush();
    try atomic_file.replace(io);
}

pub const cloneJsonValue = provider_json.cloneValue;
pub const deinitJsonValue = provider_json.freeValue;

/// Schema helpers — shared across all built-in tools.
pub fn schemaProperty(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    description: []const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try putString(allocator, &object, "type", type_name);
    try putString(allocator, &object, "description", description);
    return .{ .object = object };
}

pub const SchemaField = struct {
    name: []const u8,
    type_name: []const u8,
    description: []const u8,
    required: bool = false,
};

pub fn objectSchema(allocator: std.mem.Allocator, comptime fields: []const SchemaField) !std.json.Value {
    var properties = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const value = std.json.Value{ .object = properties };
        deinitJsonValue(allocator, value);
    }

    var required = std.json.Array.init(allocator);
    errdefer required.deinit();

    inline for (fields) |field| {
        try putValue(allocator, &properties, field.name, try schemaProperty(allocator, field.type_name, field.description));
        if (field.required) {
            try required.append(.{ .string = try allocator.dupe(u8, field.name) });
        }
    }

    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try putString(allocator, &root, "type", "object");
    try putValue(allocator, &root, "properties", .{ .object = properties });
    if (required.items.len > 0) {
        try putValue(allocator, &root, "required", .{ .array = required });
    } else {
        required.deinit();
    }
    return .{ .object = root };
}

/// Reflection-driven JSON Schema builder for tool argument structs.
///
/// Derives an `object`-typed schema from `T`'s fields:
///   * Field NAME comes from `T.json_schema_names.<field>` if declared, else the Zig field name.
///   * Field TYPE comes from `@typeInfo(field.type)` — `[]const u8` → "string", any int → "integer",
///     `bool` → "boolean"; optional fields unwrap to their child type and become non-required.
///   * Field DESCRIPTION must be supplied via `pub const json_field_docs = .{ .field = "..." };`.
///     A missing entry is a compile error. There is no fallback — descriptions are part of the
///     on-wire contract and must be authored explicitly.
///   * Required-ness: a field is required iff it has no default value AND is not optional.
///
/// Optional decl `pub const json_extra_schema_fields = .{ .alias = .{ .name = "...", .type_name = "...", .description = "..." } }`
/// lets a tool advertise additional schema entries that do not correspond to a struct field
/// (e.g., an alternate spelling accepted via `json_aliases`).
pub fn schemaFromArgs(comptime T: type, allocator: std.mem.Allocator) !std.json.Value {
    comptime validateSchemaArgs(T);

    var properties = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const value = std.json.Value{ .object = properties };
        deinitJsonValue(allocator, value);
    }

    var required = std.json.Array.init(allocator);
    errdefer required.deinit();

    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const schema_name = comptime schemaFieldName(T, field.name);
        const type_name = comptime schemaTypeName(field.type);
        const description: []const u8 = @field(T.json_field_docs, field.name);
        const is_required = comptime schemaFieldRequired(field);

        try putValue(
            allocator,
            &properties,
            schema_name,
            try schemaProperty(allocator, type_name, description),
        );
        if (is_required) {
            try required.append(.{ .string = try allocator.dupe(u8, schema_name) });
        }
    }

    if (comptime @hasDecl(T, "json_extra_schema_fields")) {
        const extras = T.json_extra_schema_fields;
        inline for (@typeInfo(@TypeOf(extras)).@"struct".fields) |extra_field| {
            const entry = @field(extras, extra_field.name);
            const entry_name: []const u8 = entry.name;
            const entry_type: []const u8 = entry.type_name;
            const entry_desc: []const u8 = entry.description;
            try putValue(
                allocator,
                &properties,
                entry_name,
                try schemaProperty(allocator, entry_type, entry_desc),
            );
            if (comptime @hasField(@TypeOf(entry), "required") and entry.required) {
                try required.append(.{ .string = try allocator.dupe(u8, entry_name) });
            }
        }
    }

    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try putString(allocator, &root, "type", "object");
    try putValue(allocator, &root, "properties", .{ .object = properties });
    if (required.items.len > 0) {
        try putValue(allocator, &root, "required", .{ .array = required });
    } else {
        required.deinit();
    }
    return .{ .object = root };
}

fn schemaFieldName(comptime T: type, comptime name: [:0]const u8) []const u8 {
    if (@hasDecl(T, "json_schema_names") and @hasField(@TypeOf(T.json_schema_names), name)) {
        return @field(T.json_schema_names, name);
    }
    return name;
}

fn schemaTypeName(comptime FieldT: type) []const u8 {
    return switch (@typeInfo(FieldT)) {
        .optional => |opt| schemaTypeName(opt.child),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) break :blk "string";
            @compileError("schemaFromArgs: unsupported pointer field type " ++ @typeName(FieldT));
        },
        .bool => "boolean",
        .int => "integer",
        else => @compileError("schemaFromArgs: unsupported field type " ++ @typeName(FieldT)),
    };
}

fn schemaFieldRequired(comptime field: std.builtin.Type.StructField) bool {
    if (@typeInfo(field.type) == .optional) return false;
    if (field.defaultValue() != null) return false;
    return true;
}

fn validateSchemaArgs(comptime T: type) void {
    if (!@hasDecl(T, "json_field_docs")) {
        @compileError("schemaFromArgs: type " ++ @typeName(T) ++ " must declare `pub const json_field_docs`");
    }
    const docs_type = @TypeOf(T.json_field_docs);
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        if (!@hasField(docs_type, field.name)) {
            @compileError("schemaFromArgs: " ++ @typeName(T) ++ " is missing `json_field_docs." ++ field.name ++ "`");
        }
    }
}

pub fn schemaArrayProperty(
    allocator: std.mem.Allocator,
    description_text: []const u8,
    item_schema: std.json.Value,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const value = std.json.Value{ .object = object };
        deinitJsonValue(allocator, value);
    }
    try putString(allocator, &object, "type", "array");
    try putString(allocator, &object, "description", description_text);
    try putValue(allocator, &object, "items", item_schema);
    return .{ .object = object };
}

pub fn parseRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try parseOptionalString(object, key)) orelse error.InvalidToolArguments;
}

pub fn parseOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

pub fn getOptionalPositiveInt(object: std.json.ObjectMap, key: []const u8) !?usize {
    const value = object.get(key) orelse return null;
    if (value != .integer) return error.InvalidToolArguments;
    if (value.integer <= 0) return error.InvalidToolArguments;
    return @intCast(value.integer);
}

pub fn jsonObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

/// JSON ObjectMap put helpers re-exported from coding_agent.json_utils.
/// Tools historically used this module; non-tool callers should import json_utils directly.
const json_utils = @import("../json_utils.zig");
pub const putString = json_utils.putString;
pub const putBool = json_utils.putBool;
pub const putInt = json_utils.putInt;
pub const putFloat = json_utils.putFloat;
pub const putNull = json_utils.putNull;
pub const putValue = json_utils.putValue;

/// Test helpers — only available in test builds.
/// Resolves a relative test path against the current working directory.
pub fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

test "resolvePath returns absolute paths unchanged" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user", "/etc/config");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/etc/config", result);
}

test "resolvePath resolves relative paths against cwd" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user", "src/file.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/src/file.zig", result);
}

test "resolvePath resolves dot paths" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user", "./file.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/file.zig", result);
}

test "resolvePath resolves parent traversal" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user/project", "../file.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/file.zig", result);
}

test "makeTextContent allocates owned text block" {
    const allocator = std.testing.allocator;
    const blocks = try makeTextContent(allocator, "hello");
    defer deinitContentBlocks(allocator, blocks);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("hello", blocks[0].text.text);
}

test "schemaFromArgs reflects field names, types, and required-ness" {
    const Args = struct {
        path: []const u8,
        offset: ?usize = null,
        flag: bool = false,

        pub const json_field_docs = .{
            .path = "The path",
            .offset = "Optional offset",
            .flag = "A flag",
        };
    };

    const value = try schemaFromArgs(Args, std.testing.allocator);
    defer deinitJsonValue(std.testing.allocator, value);

    try std.testing.expectEqualStrings("object", value.object.get("type").?.string);
    const properties = value.object.get("properties").?.object;

    try std.testing.expectEqualStrings("string", properties.get("path").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("The path", properties.get("path").?.object.get("description").?.string);

    try std.testing.expectEqualStrings("integer", properties.get("offset").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("boolean", properties.get("flag").?.object.get("type").?.string);

    const required = value.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("path", required.items[0].string);
}

test "schemaFromArgs honors json_schema_names override" {
    const Args = struct {
        ignore_case: bool = false,

        pub const json_schema_names = .{ .ignore_case = "ignoreCase" };
        pub const json_field_docs = .{ .ignore_case = "Case-insensitive" };
    };

    const value = try schemaFromArgs(Args, std.testing.allocator);
    defer deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try std.testing.expect(properties.get("ignoreCase") != null);
    try std.testing.expect(properties.get("ignore_case") == null);
    try std.testing.expect(value.object.get("required") == null);
}

test "schemaFromArgs adds json_extra_schema_fields entries" {
    const Args = struct {
        command: []const u8,

        pub const json_field_docs = .{ .command = "Cmd" };

        pub const json_extra_schema_fields = .{
            .alias_a = .{
                .name = "alias_a",
                .type_name = "integer",
                .description = "Alias A",
            },
        };
    };

    const value = try schemaFromArgs(Args, std.testing.allocator);
    defer deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try std.testing.expect(properties.get("command") != null);
    try std.testing.expectEqualStrings("integer", properties.get("alias_a").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("Alias A", properties.get("alias_a").?.object.get("description").?.string);
}
