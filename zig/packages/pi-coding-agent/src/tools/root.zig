const std = @import("std");

pub const registry = @import("registry.zig");
pub const common = @import("common.zig");
pub const args_parser = @import("args_parser.zig");
pub const parseArgsFromJson = args_parser.parseArgsFromJson;
pub const file_mutation_queue = @import("file_mutation_queue.zig");
pub const edit_diff = @import("edit_diff.zig");
pub const output_accumulator = @import("output_accumulator.zig");
pub const path_utils = @import("path_utils.zig");
pub const render_utils = @import("render_utils.zig");
pub const tool_definition_wrapper = @import("tool_definition_wrapper.zig");
pub const truncate = @import("truncate.zig");
pub const read = @import("read.zig");
pub const bash = @import("bash.zig");
pub const write = @import("write.zig");
pub const edit = @import("edit.zig");
pub const grep = @import("grep.zig");
pub const find = @import("find.zig");
pub const ls = @import("ls.zig");

pub const deinitContentBlocks = common.deinitContentBlocks;
pub const makeTextContent = common.makeTextContent;
pub const resolvePath = common.resolvePath;
pub const writeFileAbsolute = common.writeFileAbsolute;
pub const OutputAccumulator = output_accumulator.OutputAccumulator;
pub const OutputAccumulatorOptions = output_accumulator.OutputAccumulatorOptions;
pub const OutputSnapshot = output_accumulator.OutputSnapshot;

pub const DEFAULT_MAX_LINES = truncate.DEFAULT_MAX_LINES;
pub const DEFAULT_MAX_BYTES = truncate.DEFAULT_MAX_BYTES;
pub const TruncationOptions = truncate.TruncationOptions;
pub const TruncatedBy = truncate.TruncatedBy;
pub const TruncationResult = truncate.TruncationResult;
pub const truncateHead = truncate.truncateHead;
pub const truncateTail = truncate.truncateTail;

pub const ReadArgs = read.ReadArgs;
pub const ReadDetails = read.ReadDetails;
pub const ReadExecutionResult = read.ReadExecutionResult;
pub const ReadTool = read.ReadTool;

pub const BashArgs = bash.BashArgs;
pub const BashDetails = bash.BashDetails;
pub const BashExecutionResult = bash.BashExecutionResult;
pub const BashTool = bash.BashTool;

pub const WriteArgs = write.WriteArgs;
pub const WriteExecutionResult = write.WriteExecutionResult;
pub const WriteTool = write.WriteTool;

pub const EditArgs = edit.EditArgs;
pub const EditExecutionResult = edit.EditExecutionResult;
pub const EditTool = edit.EditTool;
pub const EditDiffResult = edit_diff.EditDiffResult;
pub const computeEditDiff = edit_diff.computeEditDiff;
pub const computeEditsDiff = edit_diff.computeEditsDiff;

pub const GrepArgs = grep.GrepArgs;
pub const GrepDetails = grep.GrepDetails;
pub const GrepExecutionResult = grep.GrepExecutionResult;
pub const GrepTool = grep.GrepTool;

pub const FindArgs = find.FindArgs;
pub const FindDetails = find.FindDetails;
pub const FindExecutionResult = find.FindExecutionResult;
pub const FindTool = find.FindTool;

pub const LsArgs = ls.LsArgs;
pub const LsDetails = ls.LsDetails;
pub const LsExecutionResult = ls.LsExecutionResult;
pub const LsTool = ls.LsTool;

/// Compile-time list of all built-in tool types, in registration order.
/// Each entry must expose: name, description, fn schema(), and have an `init(cwd, io)` constructor.
pub const BuiltinToolCatalog = registry.BuiltinToolCatalog;
pub const ALL: []const type = BuiltinToolCatalog.all;
pub const schemaFor = registry.schemaFor;
pub const validateNoDuplicateNames = registry.validateNoDuplicateNames;

/// Visitor callback invoked once per built-in tool type at comptime.
/// `ctx` is caller-supplied runtime context; `T` is the tool type.
pub fn forEach(comptime ctx: anytype, comptime callback: fn (comptime ctx: @TypeOf(ctx), comptime T: type) void) void {
    registry.forEachBuiltin(ctx, callback);
}

test {
    _ = @import("registry.zig");
    _ = @import("common.zig");
    _ = @import("args_parser.zig");
    _ = @import("file_mutation_queue.zig");
    _ = @import("edit_diff.zig");
    _ = @import("output_accumulator.zig");
    _ = @import("path_utils.zig");
    _ = @import("render_utils.zig");
    _ = @import("tool_definition_wrapper.zig");
    _ = @import("truncate.zig");
    _ = @import("read.zig");
    _ = @import("bash.zig");
    _ = @import("write.zig");
    _ = @import("edit.zig");
    _ = @import("grep.zig");
    _ = @import("find.zig");
    _ = @import("ls.zig");
}

fn expectSchemaProperty(
    properties: std.json.ObjectMap,
    name: []const u8,
    expected_type: []const u8,
) !void {
    const entry = properties.get(name) orelse {
        std.debug.print("missing schema property: {s}\n", .{name});
        return error.MissingProperty;
    };
    try std.testing.expectEqualStrings(expected_type, entry.object.get("type").?.string);
    const description = entry.object.get("description").?.string;
    try std.testing.expect(description.len > 0);
}

fn expectRequired(value: std.json.Value, names: []const []const u8) !void {
    if (names.len == 0) {
        try std.testing.expect(value.object.get("required") == null);
        return;
    }
    const required = value.object.get("required").?.array;
    try std.testing.expectEqual(names.len, required.items.len);
    for (names, 0..) |expected, idx| {
        try std.testing.expectEqualStrings(expected, required.items[idx].string);
    }
}

test "read schema describes path, offset, limit" {
    const value = try read.ReadTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    try std.testing.expectEqualStrings("object", value.object.get("type").?.string);
    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "path", "string");
    try expectSchemaProperty(properties, "offset", "integer");
    try expectSchemaProperty(properties, "limit", "integer");
    try expectRequired(value, &.{"path"});
}

test "write schema describes path and content" {
    const value = try write.WriteTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "path", "string");
    try expectSchemaProperty(properties, "content", "string");
    try expectRequired(value, &.{ "path", "content" });
}

test "grep schema exposes ignoreCase (not ignore_case) and required pattern" {
    const value = try grep.GrepTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "pattern", "string");
    try expectSchemaProperty(properties, "path", "string");
    try expectSchemaProperty(properties, "glob", "string");
    try expectSchemaProperty(properties, "ignoreCase", "boolean");
    try std.testing.expect(properties.get("ignore_case") == null);
    try expectSchemaProperty(properties, "literal", "boolean");
    try expectSchemaProperty(properties, "context", "integer");
    try expectSchemaProperty(properties, "limit", "integer");
    try expectRequired(value, &.{"pattern"});
}

test "find schema describes pattern, path, limit" {
    const value = try find.FindTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "pattern", "string");
    try expectSchemaProperty(properties, "path", "string");
    try expectSchemaProperty(properties, "limit", "integer");
    try expectRequired(value, &.{"pattern"});
}

test "ls schema describes optional path and limit with no required entries" {
    const value = try ls.LsTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "path", "string");
    try expectSchemaProperty(properties, "limit", "integer");
    try expectRequired(value, &.{});
}

test "bash schema advertises command, timeout_seconds, and timeout alias" {
    const value = try bash.BashTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "command", "string");
    try expectSchemaProperty(properties, "timeout_seconds", "integer");
    try expectSchemaProperty(properties, "timeout", "integer");
    try expectRequired(value, &.{"command"});
}

test "edit schema describes path, edits array, and legacy oldText/newText" {
    const value = try edit.EditTool.schema(std.testing.allocator);
    defer common.deinitJsonValue(std.testing.allocator, value);

    const properties = value.object.get("properties").?.object;
    try expectSchemaProperty(properties, "path", "string");
    try expectSchemaProperty(properties, "oldText", "string");
    try expectSchemaProperty(properties, "newText", "string");
    const edits_entry = properties.get("edits").?.object;
    try std.testing.expectEqualStrings("array", edits_entry.get("type").?.string);
    try expectRequired(value, &.{"path"});
}
